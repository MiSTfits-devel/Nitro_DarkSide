-- | The ARM9-facing front end of the 3D engine: the GX MMIO register block,
-- the command FIFO (256 entries) and its 4-entry PIPE, exactly as melonDS
-- @GPU3D@ implements them (@Read8/16/32@, @Write8/16/32@, @WriteToGXFIFO@,
-- @CmdFIFOWrite@, @CmdFIFORead@, @CheckFIFOIRQ@, @CheckFIFODMA@, the
-- @Render*@ latch in @VBlank@, @SetRenderXPos@, @SetEnabled@), plus the
-- ARM9 bus routing of @NDS::ARM9IORead*/ARM9IOWrite*@ for the addresses
-- this block owns: @0x04000060-0x04000063@ (DISP3DCNT) and
-- @0x04000320-0x040006A3@.
--
-- The model is a state record ('GxFront') and one pure step function per
-- event, each a direct transcription of the melonDS routine named in its
-- comment:
--
-- * 'mmioWrite' / 'mmioRead': one ARM9 access (address, 'Size', value).
--   Writes decode to a 'WriteAct' ('writeAction'), which 'applyAct'
--   performs; reads go through 'readLocal' or, for the geometry result
--   registers (0x04000620-0x040006A3), through 'resultWord' /
--   'resultProject' on the neighbour's result read function.
-- * 'popEntry': the geometry engine takes the head entry, as
--   @ExecuteCommand@ does (@CmdFIFORead@ plus its counter bookkeeping,
--   'retireCounts').
-- * 'vblank', 'setRenderXPos', 'setPower' (@SetEnabled@ from POWCNT1),
--   'setDispCntFlags' (the polygon block's RAM-overflow bit, the renderer's
--   underflow bit).
--
-- GXSTAT bits 0, 14 and 27 are shared with the geometry engine in melonDS:
-- they are set here when an entry is queued and cleared by @Run@ once the
-- geometry engine has retired the queued test/push-pop commands and gone
-- idle. The model reports them settled, i.e. as @Run@ leaves them after
-- every event: bit 14 (bit 0) is set when a PUSH/POP (BOX/POS/VEC_TEST)
-- entry is queued and cleared when @NumPushPopCommands@
-- (@NumTestCommands@) is zero, or held by 'gsStackBusy' ('gsTestBusy');
-- bit 27 is "the PIPE is not empty or the geometry engine is busy". The
-- counters are melonDS's own (32-bit, incremented by @CmdFIFOWrite@ and
-- decremented the way @ExecuteCommand@ does when an entry is taken), so a
-- malformed stream wraps them, and leaves the bits clear while they are
-- wrapped, exactly as melonDS does.
--
-- Bus stall: when a write would overflow FIFO+PIPE the entries that do not
-- fit wait in 'gfStallQ' and 'stalled' holds the ARM9 bus until a geometry
-- pop drains them (@CmdFIFORead@'s stall-queue refill). That is the real DS
-- behaviour and the shape of upstream melonDS's 64-entry stall queue; the
-- NDS4MiSTer fork's 16384-entry queue and @ExternalOverflow@ only exist for
-- its hybrid replay. Ordinary writes stop at the stall; an authenticated
-- same-clock continuation of the current atomic ARM9 interpreter handler may
-- append its remaining entries to this same queue before the next instruction.
module Nds.Gpu3D.GxFront
  ( -- * Boundary
    Size (..)
  , FrontIn (..)
  , WriteFx (..)
  , PopFx (..)
    -- * State
  , GxFront (..)
  , Packer (..)
  , initGxFront
  , resetRenderRegs
    -- * Events
  , mmioWrite
  , mmioRead
  , popEntry
  , vblank
  , setRenderXPos
  , setPower
  , setDispCntFlags
    -- * Outputs
  , headEntry
  , gxStat
  , fifoLevel
  , stalled
  , irqLine
  , dmaRequest
  , zeroDotW
  , renderRegs
    -- * Per-step pieces (shared with the hardware)
  , fifoDepth
  , pipeDepth
  , numParams
  , packStart
  , packIter
  , writeToGxFifo
  , cmdFifoWrite
  , settleBits
  , cmdFifoRead
  , retireCounts
  , isPushPop
  , isTest
  , fifoIrqCond
  , composeGxStat
  , readLocal
  , resultWord
  , resultProject
  , Reg32 (..)
  , WriteAct (..)
  , writeAction
  , applyAct
  , dispCntWrite
  , alphaRefOf
  , zeroDotOf
  , tableLaneMask
  ) where

import Prelude

import Data.Bits (bit, clearBit, complement, shiftL, shiftR, testBit, (.&.), (.|.))
import Data.Foldable (toList)
import Data.Sequence (Seq, ViewL (..), viewl, (|>))
import qualified Data.Sequence as Seq
import Data.Word (Word16, Word32, Word8)

import Nds.Gpu3D.Types

-- | Access width of one ARM9 bus access.
data Size = S8 | S16 | S32
  deriving (Eq, Show)

-- | What the neighbours drive into the front end: the geometry engine's
-- GXSTAT part, RAM_COUNT from the polygon block, and the geometry result
-- registers. @fiResult a@ is the 32-bit word at word address @a@ in
-- 0x04000620-0x040006A3 (@Nds.Gpu3D.Geometry.geoReadResult@'s layout:
-- 0x620-0x62C POS_RESULT, 0x630 = VEC_RESULT x | y << 16, 0x634 =
-- VEC_RESULT z, 0x640-0x67C CLIPMTX_RESULT, 0x680-0x6A0 VECMTX_RESULT).
data FrontIn = FrontIn
  { fiGeo    :: !GeoStatus
  , fiPipe   :: !PipeStatus
  , fiResult :: Word32 -> Word32
  }

-- | Side effects of a write: @wfAck@ is the GXSTAT bit-15 acknowledge to
-- the geometry engine (melonDS clears the stack-error flag and zeroes the
-- projection and texture stack pointers); @wfIrqCheck@ is a
-- @CheckFIFOIRQ@ call (IRQ-mode writes), which sets IF bit 21 when
-- 'irqLine' is true and clears it otherwise.
data WriteFx = WriteFx { wfAck :: !Bool, wfIrqCheck :: !Bool }
  deriving (Eq, Show)

-- | Side effects of a pop: @pfRefill@ is the PIPE refill branch of
-- @CmdFIFORead@, which calls @CheckFIFODMA@ and @CheckFIFOIRQ@; @pfDma@ is
-- @CheckFIFODMA@ firing (fewer than 128 FIFO entries after the refill),
-- which starts any ARM9 DMA channel in GXFIFO mode.
data PopFx = PopFx { pfRefill :: !Bool, pfDma :: !Bool }
  deriving (Eq, Show)

-- | @WriteToGXFIFO@'s unpacking state: @NumCommands@, @CurCommand@,
-- @ParamCount@, @TotalParams@. melonDS keeps them as @u32@; the narrow
-- fields are exact because @NumCommands <= 4@ and
-- @ParamCount <= TotalParams <= 32@ always hold.
data Packer = Packer
  { pkNumCommands :: !Word8
  , pkCurCommand  :: !Word32
  , pkParamCount  :: !Word8
  , pkTotalParams :: !Word8
  } deriving (Eq, Show)

-- | The front end's state: every melonDS @GPU3D@ member it owns.
data GxFront = GxFront
  { gfFifo           :: !(Seq CmdEntry)   -- ^ @CmdFIFO@, oldest first
  , gfPipe           :: !(Seq CmdEntry)   -- ^ @CmdPIPE@, head first
  , gfStallQ         :: !(Seq CmdEntry)   -- ^ entries waiting for room
  , gfPack           :: !Packer
  , gfIrqMode        :: !Word32  -- ^ @GXStat & 0xC0000000@
  , gfNumPushPop     :: !Word32  -- ^ @NumPushPopCommands@
  , gfNumTest        :: !Word32  -- ^ @NumTestCommands@
  , gfPushPopBit     :: !Bool    -- ^ @GXStat@ bit 14 (front-end part)
  , gfTestBit        :: !Bool    -- ^ @GXStat@ bit 0 (front-end part)
  , gfExecParamCount :: !Word8   -- ^ @ExecParamCount@ (0..31)
  , gfIrq            :: !Bool    -- ^ IF bit 21 as @CheckFIFOIRQ@ last left it
  , gfGeomEn         :: !Bool    -- ^ @GeometryEnabled@ (POWCNT1 bit 3)
  , gfRendEn         :: !Bool    -- ^ @RenderingEnabled@ (POWCNT1 bit 2)
  , gfDispCnt        :: !Word32
  , gfAlphaRefVal    :: !Word8
  , gfAlphaRef       :: !Word8
  , gfClearAttr1     :: !Word32
  , gfClearAttr2     :: !Word32
  , gfFogColor       :: !Word32
  , gfFogOffset      :: !Word32
  , gfFogDensity     :: !(Seq Word8)    -- ^ 32 entries
  , gfEdge           :: !(Seq Word16)   -- ^ 8 entries
  , gfToon           :: !(Seq Word16)   -- ^ 32 entries
  , gfZeroDotW       :: !Word32         -- ^ @ZeroDotWLimit@
  , gfRender         :: !RenderRegs
  } deriving (Eq, Show)

fifoDepth, pipeDepth :: Int
fifoDepth = 256
pipeDepth = 4

-- | @ResetRenderingState@, keeping @RenderXPos@ (it is not part of it).
resetRenderRegs :: Word16 -> RenderRegs
resetRenderRegs xpos = RenderRegs
  { rrDispCnt    = 0
  , rrAlphaRef   = 0
  , rrClearAttr1 = 0x3F000000
  , rrClearAttr2 = 0x00007FFF
  , rrFogColor   = 0
  , rrFogOffset  = 0
  , rrFogShift   = 0
  , rrFogDensity = replicate 34 0
  , rrEdgeTable  = replicate 8 0
  , rrToonTable  = replicate 32 0
  , rrXPos       = xpos
  }

-- | The state after @GPU3D::Reset@.
initGxFront :: GxFront
initGxFront = GxFront
  { gfFifo = Seq.empty
  , gfPipe = Seq.empty
  , gfStallQ = Seq.empty
  , gfPack = Packer 0 0 0 0
  , gfIrqMode = 0
  , gfNumPushPop = 0
  , gfNumTest = 0
  , gfPushPopBit = False
  , gfTestBit = False
  , gfExecParamCount = 0
  , gfIrq = False
  , gfGeomEn = False
  , gfRendEn = False
  , gfDispCnt = 0
  , gfAlphaRefVal = 0
  , gfAlphaRef = 0
  , gfClearAttr1 = 0x3F000000
  , gfClearAttr2 = 0x00007FFF
  , gfFogColor = 0
  , gfFogOffset = 0
  , gfFogDensity = Seq.replicate 32 0
  , gfEdge = Seq.replicate 8 0
  , gfToon = Seq.replicate 32 0
  , gfZeroDotW = 0xFFFFFF
  , gfRender = resetRenderRegs 0
  }

------------------------------------------------------------------------------
-- Command FIFO

-- | @CmdNumParams[c & 0xFF]@.
numParams :: Word32 -> Word8
numParams c = fromIntegral (cmdNumParams (fromIntegral (c .&. 0xFF)))

isPushPop, isTest :: Word8 -> Bool
isPushPop c = c == 0x11 || c == 0x12
isTest c = c == 0x70 || c == 0x71 || c == 0x72

-- | @CmdFIFOWrite@: into the PIPE while the FIFO is empty and the PIPE has
-- room, else into the FIFO, else (FIFO full) into the stall queue, which
-- neither counts the entry nor marks GXSTAT busy. A queued PUSH/POP or test
-- entry sets GXSTAT bit 14 or bit 0 and its counter.
cmdFifoWrite :: CmdEntry -> GxFront -> GxFront
cmdFifoWrite e st
  | Seq.null fifo && Seq.length pipe < pipeDepth = counted st { gfPipe = pipe |> e }
  | Seq.length fifo >= fifoDepth = st { gfStallQ = gfStallQ st |> e }
  | otherwise = counted st { gfFifo = fifo |> e }
  where
    fifo = gfFifo st
    pipe = gfPipe st
    c = ceCmd e
    counted s
      | isPushPop c = s { gfNumPushPop = gfNumPushPop s + 1, gfPushPopBit = True }
      | isTest c = s { gfNumTest = gfNumTest s + 1, gfTestBit = True }
      | otherwise = s

-- | @Run@'s clears once the geometry engine has caught up: bit 14 / bit 0
-- drop when their counter is zero. Applied after every write and pop.
settleBits :: GxFront -> GxFront
settleBits st = st
  { gfPushPopBit = gfPushPopBit st && gfNumPushPop st /= 0
  , gfTestBit = gfTestBit st && gfNumTest st /= 0 }

-- | @CmdFIFORead@ on a non-empty PIPE: take the head; when the PIPE is left
-- with two entries or fewer, move up to two FIFO entries into it, drain the
-- stall queue into the FIFO while it has room, then @CheckFIFODMA@ and
-- @CheckFIFOIRQ@. The flag says whether that refill branch ran.
cmdFifoRead :: GxFront -> Maybe (CmdEntry, GxFront, Bool)
cmdFifoRead st = case viewl (gfPipe st) of
  EmptyL -> Nothing
  e :< rest
    | Seq.length rest <= 2 ->
        let s1 = drainStall (refill (refill st { gfPipe = rest }))
        in Just (e, checkFifoIrq s1, True)
    | otherwise -> Just (e, st { gfPipe = rest }, False)
  where
    refill s = case viewl (gfFifo s) of
      EmptyL -> s
      x :< xs -> s { gfFifo = xs, gfPipe = pipeWrite x (gfPipe s) }
    -- FIFO::Write ignores a write to a full FIFO.
    pipeWrite x p = if Seq.length p >= pipeDepth then p else p |> x
    drainStall s = case viewl (gfStallQ s) of
      x :< xs | fifoLevel s < fifoDepth -> drainStall (cmdFifoWrite x s { gfStallQ = xs })
      _ -> s

-- | @ExecuteCommand@'s bookkeeping for one taken entry, given its command
-- and @ExecParamCount@: the new @ExecParamCount@ and the decrements of
-- @NumPushPopCommands@ and @NumTestCommands@. Single-parameter commands are
-- retired at once (PUSH, POP, VEC_TEST); a multi-parameter entry adds to
-- @ExecParamCount@ and the command retires when the count reaches its own
-- parameter count (POS_TEST -2, BOX_TEST -3), even if the gathered entries
-- belonged to other commands.
retireCounts :: Word8 -> Word8 -> (Word8, Word32, Word32)
retireCounts c epc
  | n <= 1 = (epc, if isPushPop c then 1 else 0, if c == 0x72 then 1 else 0)
  | epc + 1 >= n = (0, 0, if c == 0x71 then 2 else if c == 0x70 then 3 else 0)
  | otherwise = (epc + 1, 0, 0)
  where
    n = numParams (fromIntegral c)

-- | The geometry engine takes the head entry. 'Nothing' on an empty PIPE
-- (melonDS never reads it then).
popEntry :: GxFront -> Maybe (CmdEntry, GxFront, PopFx)
popEntry st = do
  (e, s, refilled) <- cmdFifoRead st
  let (epc, dpp, dt) = retireCounts (ceCmd e) (gfExecParamCount s)
  pure ( e
       , settleBits s { gfExecParamCount = epc
                      , gfNumPushPop = gfNumPushPop s - dpp
                      , gfNumTest = gfNumTest s - dt }
       , PopFx refilled (refilled && fifoLevel s < 128) )

-- | Prologue of @WriteToGXFIFO@: a new packed command word when
-- @NumCommands == 0@ (the loop runs only if its first command has no
-- parameters), otherwise one more parameter. Returns the packer and
-- whether the loop runs.
packStart :: Word32 -> Packer -> (Packer, Bool)
packStart val pk
  | pkNumCommands pk == 0 =
      let tot = numParams val in (Packer 4 val 0 tot, tot == 0)
  | otherwise = (pk { pkParamCount = pkParamCount pk + 1 }, True)

-- | One pass of the @WriteToGXFIFO@ loop: the entry it queues (a non-zero
-- command byte, or the single NOP of an all-zero packed word), the packer
-- after it, and whether the loop goes round again.
packIter :: Word32 -> Packer -> (Maybe CmdEntry, Packer, Bool)
packIter val (Packer nc cur pc tot)
  | pc >= tot =
      let cur' = cur `shiftR` 8
          nc' = nc - 1
          tot' = numParams cur'
      in if nc' == 0 then (emit, Packer 0 cur' pc tot, False)
         else (emit, Packer nc' cur' 0 tot', tot' == 0)
  | otherwise = (emit, Packer nc cur pc tot, False)
  where
    emit
      | cur .&. 0xFF /= 0 || (nc == 4 && cur == 0) = Just (CmdEntry (fromIntegral cur) val)
      | otherwise = Nothing

-- | @WriteToGXFIFO@.
writeToGxFifo :: Word32 -> GxFront -> GxFront
writeToGxFifo val st =
  let (pk, run) = packStart val (gfPack st)
  in if run then go pk st else st { gfPack = pk }
  where
    go pk s =
      let (me, pk', more) = packIter val pk
          s' = maybe s (`cmdFifoWrite` s) me
      in if more then go pk' s' else s' { gfPack = pk' }

-- | @CheckFIFOIRQ@'s condition for GXSTAT bits 30-31 and a FIFO level.
fifoIrqCond :: Word32 -> Word32 -> Bool
fifoIrqCond mode level = case mode `shiftR` 30 of
  1 -> level < 128
  2 -> level == 0
  _ -> False

checkFifoIrq :: GxFront -> GxFront
checkFifoIrq st = st { gfIrq = fifoIrqCond (gfIrqMode st) (fromIntegral (fifoLevel st)) }

------------------------------------------------------------------------------
-- Reads

-- | GXSTAT as @Read32(0x04000600)@ returns it (settled; see the module
-- header): the push/pop and test bits, PIPE occupancy, IRQ mode and FIFO
-- level from the front end, the rest from the geometry engine.
composeGxStat :: GeoStatus -> Bool -> Bool -> Bool -> Word32 -> Word32 -> Word32
composeGxStat g pushPopBit testBit' pipeBusy irqMode level =
      flag (testBit' || gsTestBusy g) 0
  .|. flag (gsBoxResult g) 1
  .|. ((fromIntegral (gsPosStack g) .&. 0x1F) `shiftL` 8)
  .|. flag (gsProjStack g) 13
  .|. flag (pushPopBit || gsStackBusy g) 14
  .|. flag (gsStackError g) 15
  .|. (level `shiftL` 16)
  .|. flag (level < 128) 25
  .|. flag (level == 0) 26
  .|. flag (pipeBusy || gsBusy g) 27
  .|. (irqMode .&. 0xC0000000)
  where
    flag b n = if b then bit n else 0

-- | The offset of an address inside the 4 KiB I/O page this block decodes
-- (0x04000000-0x04000FFF). Every register compare below is on the offset,
-- which is exact and keeps the hardware compares 12 bits wide.
ioOffset :: Word32 -> Maybe Word16
ioOffset a
  | a .&. 0xFFFFF000 == 0x04000000 = Just (fromIntegral (a .&. 0xFFF))
  | otherwise = Nothing

-- | Every read except the geometry result registers, given the GXSTAT word
-- ('composeGxStat'), DISP3DCNT and RAM_COUNT. Each 8- and 16-bit GXSTAT
-- read is the matching lane of the 32-bit word; 8-bit reads of everything
-- else, including DISP3DCNT (the ARM9 routing never reaches GPU3D) and
-- RAM_COUNT, are 0; 0x04000320 (RDLINES_COUNT) reads 46 at 16 and 32 bits.
readLocal :: Word32 -> Word32 -> PipeStatus -> Size -> Word32 -> Word32
readLocal gx disp ps sz a = case ioOffset a of
  Nothing -> 0
  Just o -> case sz of
    S8
      | o >= 0x600 && o <= 0x603 -> (gx `shiftR` (8 * fromIntegral (o .&. 3))) .&. 0xFF
      | otherwise -> 0
    S16 -> case o of
      0x060 -> disp .&. 0xFFFF
      0x320 -> 46
      0x600 -> gx .&. 0xFFFF
      0x602 -> gx `shiftR` 16
      0x604 -> np
      0x606 -> nv
      _ -> 0
    S32 -> case o of
      0x060 -> disp
      0x320 -> 46
      0x600 -> gx
      0x604 -> np .|. (nv `shiftL` 16)
      _ -> 0
  where
    np = fromIntegral (pcPolygons ps)
    nv = fromIntegral (pcVertices ps)

-- | The result-register word a read needs, if it reads one: @Read32@ of
-- POS_RESULT, CLIPMTX_RESULT, VECMTX_RESULT; @Read16@ of VEC_RESULT.
resultWord :: Size -> Word32 -> Maybe Word32
resultWord sz a = case (sz, ioOffset a) of
  (S32, Just o)
    | o .&. 3 == 0 && ((o >= 0x620 && o <= 0x62C) || (o >= 0x640 && o <= 0x6A0)) -> Just a
  (S16, Just o)
    | o == 0x630 || o == 0x632 -> Just 0x04000630
    | o == 0x634 -> Just 0x04000634
  _ -> Nothing

-- | The read value from the result word 'resultWord' named.
resultProject :: Size -> Word32 -> Word32 -> Word32
resultProject S16 a w = (w `shiftR` (8 * fromIntegral (a .&. 2))) .&. 0xFFFF
resultProject _ _ w = w

-- | One ARM9 read (@ARM9IORead8/16/32@ → @GPU3D::Read8/16/32@). Reads have
-- no side effects here (melonDS's @Run@ is the geometry engine's).
mmioRead :: FrontIn -> Size -> Word32 -> GxFront -> Word32
mmioRead fi sz a st = case resultWord sz a of
  Just w -> resultProject sz a (fiResult fi w)
  Nothing -> readLocal (gxStat (fiGeo fi) st) (gfDispCnt st) (fiPipe fi) sz a

------------------------------------------------------------------------------
-- Writes

-- | The 32-bit registers written by halves or whole.
data Reg32 = RClear1 | RClear2 | RFogColor
  deriving (Eq, Show)

-- | What one write does. 'WaTable' addresses the 28-word live table space
-- (EDGE_COLOR words 0-3, FOG_TABLE 4-11, TOON_TABLE 12-27) with byte
-- enables and lane-aligned data (fog bytes already masked to 7 bits): every
-- melonDS table write is exactly a byte-enabled word write.
data WriteAct
  = WaNone
  | WaDispCnt !Word32                -- ^ value written to DISP3DCNT
  | WaAlphaRef !Word32               -- ^ value written to ALPHA_TEST_REF
  | WaReg !Reg32 !Word32 !Word32     -- ^ register, mask, value in place
  | WaFogOffset !Word32
  | WaTable !Word8 !Word8 !Word32    -- ^ word, byte enables, data
  | WaGxStat !Bool !(Maybe Word32)   -- ^ acknowledge, new IRQ mode bits
  | WaZeroDot !Word32                -- ^ value written to DISP_1DOT_DEPTH
  | WaGxFifo !Word32                 -- ^ GXFIFO word
  | WaDirect !Word8 !Word32          -- ^ command port: command, parameter
  deriving (Eq, Show)

-- | Decode one write (value already truncated to its width): the enable
-- gates at the top of @GPU3D::Write*@ (0x320-0x3FF needs rendering,
-- 0x400-0x6FF geometry), then each function's switch and ranges. 8- and
-- 16-bit writes to the GXFIFO and command ports do nothing, as do 8-bit
-- writes to DISP3DCNT, CLEAR_COLOR, FOG_COLOR, FOG_OFFSET and
-- DISP_1DOT_DEPTH.
writeAction :: Bool -> Bool -> Size -> Word32 -> Word32 -> WriteAct
writeAction geomEn rendEn sz a v = case ioOffset a of
  Nothing -> WaNone
  Just o
    | o >= 0x320 && o < 0x400 && not rendEn -> WaNone
    | o >= 0x400 && o < 0x700 && not geomEn -> WaNone
    | otherwise -> case sz of
        S8 -> w8 o
        S16 -> w16 o
        S32 -> w32 o
  where
    lane = 8 * fromIntegral (a .&. 3)
    table o w be d
      | o >= 0x330 && o < 0x340 = WaTable (word o 0x330 0) be d
      | o >= 0x360 && o < 0x380 = WaTable (word o 0x360 4) be (d .&. 0x7F7F7F7F)
      | o >= 0x380 && o < 0x3C0 = WaTable (word o 0x380 12) be d
      | otherwise = w
    word o base off = off + fromIntegral ((o - base) `shiftR` 2)
    w8 o = case o of
      0x340 -> WaAlphaRef v
      0x601 -> WaGxStat (testBit v 7) Nothing
      0x603 -> WaGxStat False (Just ((v .&. 0xC0) `shiftL` 24))
      _ -> table o WaNone (bit (fromIntegral (a .&. 3))) (v `shiftL` lane)
    w16 o = case o of
      0x060 -> WaDispCnt v
      0x340 -> WaAlphaRef v
      0x350 -> WaReg RClear1 0x0000FFFF v
      0x352 -> WaReg RClear1 0xFFFF0000 (v `shiftL` 16)
      0x354 -> WaReg RClear2 0x0000FFFF v
      0x356 -> WaReg RClear2 0xFFFF0000 (v `shiftL` 16)
      0x358 -> WaReg RFogColor 0x0000FFFF v
      0x35A -> WaReg RFogColor 0xFFFF0000 (v `shiftL` 16)
      0x35C -> WaFogOffset v
      0x600 -> WaGxStat (testBit v 15) Nothing
      0x602 -> WaGxStat False (Just ((v .&. 0xC000) `shiftL` 16))
      0x610 -> WaZeroDot v
      _ -> table o WaNone (3 `shiftL` fromIntegral (a .&. 2)) (v `shiftL` lane)
    w32 o = case o of
      0x060 -> WaDispCnt v
      0x340 -> WaAlphaRef v
      0x350 -> WaReg RClear1 0xFFFFFFFF v
      0x354 -> WaReg RClear2 0xFFFFFFFF v
      0x358 -> WaReg RFogColor 0xFFFFFFFF v
      0x35C -> WaFogOffset v
      0x600 -> WaGxStat (testBit v 15) (Just (v .&. 0xC0000000))
      0x610 -> WaZeroDot v
      _ | o >= 0x400 && o < 0x440 -> WaGxFifo v
        | o >= 0x440 && o < 0x5CC -> WaDirect (fromIntegral ((o .&. 0x1FC) `shiftR` 2)) v
        | otherwise -> table o WaNone 0xF v

-- | DISP3DCNT write: bits 0-11 and 14 are written, bits 12 and 13 kept and
-- cleared by writing 1.
dispCntWrite :: Word32 -> Word32 -> Word32
dispCntWrite old v =
  let d0 = (v .&. 0x4FFF) .|. (old .&. 0x3000)
      d1 = if testBit v 12 then clearBit d0 12 else d0
  in if testBit v 13 then clearBit d1 13 else d1

-- | @AlphaRef = (DispCnt & (1<<2)) ? AlphaRefVal : 0@.
alphaRefOf :: Word32 -> Word8 -> Word8
alphaRefOf disp val = if testBit disp 2 then val else 0

-- | @ZeroDotWLimit = ((val & 0x7FFF) * 0x200) + 0x1FF@ (the low nine bits
-- of the product are zero, so the sum is an OR).
zeroDotOf :: Word32 -> Word32
zeroDotOf v = ((v .&. 0x7FFF) `shiftL` 9) .|. 0x1FF

-- | The bit mask of the lanes a byte-enable nibble selects.
tableLaneMask :: Word8 -> Word32
tableLaneMask be = foldr (\i m -> if testBit be i then m .|. (0xFF `shiftL` (8 * i)) else m) 0 [0 .. 3]

-- | Perform a decoded write.
applyAct :: WriteAct -> GxFront -> (GxFront, WriteFx)
applyAct act st = case act of
  WaNone -> none st
  WaDispCnt v ->
    let d = dispCntWrite (gfDispCnt st) v
    in none st { gfDispCnt = d, gfAlphaRef = alphaRefOf d (gfAlphaRefVal st) }
  WaAlphaRef v ->
    let r = fromIntegral (v .&. 0x1F)
    in none st { gfAlphaRefVal = r, gfAlphaRef = alphaRefOf (gfDispCnt st) r }
  WaReg r m v ->
    let upd old = (old .&. complement m) .|. (v .&. m)
    in none $ case r of
      RClear1 -> st { gfClearAttr1 = upd (gfClearAttr1 st) }
      RClear2 -> st { gfClearAttr2 = upd (gfClearAttr2 st) }
      RFogColor -> st { gfFogColor = upd (gfFogColor st) }
  WaFogOffset v -> none st { gfFogOffset = v .&. 0x7FFF }
  WaTable w be d -> none (tableWrite w be d st)
  WaGxStat ack mode ->
    let s1 = maybe st (\m -> checkFifoIrq st { gfIrqMode = m }) mode
    in (s1, WriteFx ack (mode /= Nothing))
  WaZeroDot v -> none st { gfZeroDotW = zeroDotOf v }
  WaGxFifo v -> none (writeToGxFifo v st)
  WaDirect c v -> none (cmdFifoWrite (CmdEntry c v) st)
  where
    none s = (s, WriteFx False False)

tableWrite :: Word8 -> Word8 -> Word32 -> GxFront -> GxFront
tableWrite w be d st
  | w < 4 = st { gfEdge = halves (fromIntegral w * 2) (gfEdge st) }
  | w < 12 = st { gfFogDensity = bytes (fromIntegral (w - 4) * 4) (gfFogDensity st) }
  | otherwise = st { gfToon = halves (fromIntegral (w - 12) * 2) (gfToon st) }
  where
    byte i = fromIntegral (d `shiftR` (8 * i)) :: Word8
    bytes base t = foldr (\i acc -> if testBit be i then Seq.update (base + i) (byte i) acc else acc) t [0 .. 3]
    halves base t = foldr (\i acc ->
        if testBit be i
          then Seq.adjust' (setByte (i `mod` 2) (byte i)) (base + i `div` 2) acc
          else acc) t [0 .. 3]
    setByte h b old =
      (old .&. complement (0xFF `shiftL` (8 * h))) .|. (fromIntegral b `shiftL` (8 * h))

-- | One ARM9 write (@ARM9IOWrite8/16/32@ → @GPU3D::Write8/16/32@). The
-- value is truncated to the width first. Precondition: not 'stalled' (the
-- bus is held while it is).
mmioWrite :: Size -> Word32 -> Word32 -> GxFront -> (GxFront, WriteFx)
mmioWrite sz a v st =
  let (st', fx) = applyAct (writeAction (gfGeomEn st) (gfRendEn st) sz a v') st
  in (settleBits st', fx)
  where
    v' = case sz of
      S8 -> v .&. 0xFF
      S16 -> v .&. 0xFFFF
      S32 -> v

------------------------------------------------------------------------------
-- Frame events

-- | @VBlank@'s register latch: with geometry and rendering enabled, the
-- @Render*@ registers take the live values (fog offset times 0x200, fog
-- shift from DISP3DCNT bits 8-11, the 34-entry fog table padded with its
-- first and last entries). The FlushRequest bank swap is the polygon
-- block's; the latch does not depend on it.
vblank :: GxFront -> GxFront
vblank st
  | gfGeomEn st && gfRendEn st = st { gfRender = latched }
  | otherwise = st
  where
    fd = toList (gfFogDensity st)
    dc = gfDispCnt st
    latched = RenderRegs
      { rrDispCnt = dc
      , rrAlphaRef = gfAlphaRef st
      , rrClearAttr1 = gfClearAttr1 st
      , rrClearAttr2 = gfClearAttr2 st
      , rrFogColor = gfFogColor st
      , rrFogOffset = gfFogOffset st * 0x200
      , rrFogShift = (dc `shiftR` 8) .&. 0xF
      , rrFogDensity = head fd : fd ++ [last fd]
      , rrEdgeTable = toList (gfEdge st)
      , rrToonTable = toList (gfToon st)
      , rrXPos = rrXPos (gfRender st)
      }

-- | @SetRenderXPos@ (engine A BG0HOFS writes: masks 0x00FF, 0xFF00, 0xFFFF).
setRenderXPos :: Word16 -> Word16 -> GxFront -> GxFront
setRenderXPos xpos mask st
  | gfRendEn st =
      let r = gfRender st
          x = (rrXPos r .&. complement mask) .|. (xpos .&. mask .&. 0x01FF)
      in st { gfRender = r { rrXPos = x } }
  | otherwise = st

-- | @SetEnabled(geometry, rendering)@, called on every POWCNT1 write.
setPower :: Bool -> Bool -> GxFront -> GxFront
setPower geom rend st = st
  { gfGeomEn = geom
  , gfRendEn = rend
  , gfRender = if rend then gfRender st else resetRenderRegs (rrXPos (gfRender st))
  }

-- | DISP3DCNT status bits set by other blocks: bit 12 (colour buffer
-- underflow, never set by melonDS's renderer) and bit 13 (polygon/vertex
-- RAM overflow, @SubmitPolygon@).
setDispCntFlags :: Bool -> Bool -> GxFront -> GxFront
setDispCntFlags under over st = st
  { gfDispCnt = gfDispCnt st .|. (if under then bit 12 else 0) .|. (if over then bit 13 else 0) }

------------------------------------------------------------------------------
-- Outputs

-- | The entry the geometry engine would take next.
headEntry :: GxFront -> Maybe CmdEntry
headEntry st = Seq.lookup 0 (gfPipe st)

fifoLevel :: GxFront -> Int
fifoLevel = Seq.length . gfFifo

-- | GXSTAT as a 32-bit read returns it.
gxStat :: GeoStatus -> GxFront -> Word32
gxStat g st = composeGxStat g (gfPushPopBit st) (gfTestBit st)
  (not (Seq.null (gfPipe st))) (gfIrqMode st) (fromIntegral (fifoLevel st))

-- | The ARM9 bus is held: entries of the last write are waiting for room.
stalled :: GxFront -> Bool
stalled = not . Seq.null . gfStallQ

-- | The GXFIFO interrupt request (IF bit 21) as melonDS leaves it: updated
-- by @CheckFIFOIRQ@ on IRQ-mode writes and PIPE refills only.
irqLine :: GxFront -> Bool
irqLine = gfIrq

-- | Level form of the GXFIFO DMA request: fewer than 128 FIFO entries.
-- melonDS samples it at PIPE refills ('pfDma').
dmaRequest :: GxFront -> Bool
dmaRequest st = fifoLevel st < 128

-- | DISP_1DOT_DEPTH as the geometry engine reads it (@ZeroDotWLimit@).
zeroDotW :: GxFront -> Word32
zeroDotW = gfZeroDotW

renderRegs :: GxFront -> RenderRegs
renderRegs = gfRender
