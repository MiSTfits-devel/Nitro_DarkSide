{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Hardware for the GX front end ('Nds.Gpu3D.GxFront'): the ARM9 register
-- port, the 256-entry command FIFO in block RAM, the 4-entry PIPE in
-- registers, the live and latched render tables, and the VBlank latch.
-- One clock domain (the chip clock, 3x the ARM9 I/O clock in the core);
-- the integration wrapper owns the clock crossing.
--
-- The decode and per-step arithmetic are the model's own functions
-- ('writeAction', 'packStart', 'packIter', 'retireCounts', 'composeGxStat',
-- 'readLocal', 'resultWord', 'fifoIrqCond', 'dispCntWrite', ...), so the
-- hardware differs from the model only in how it sequences them:
--
-- * One FIFO operation at a time. 'PPack' runs one @WriteToGXFIFO@ loop
--   pass per cycle (at most 4); a pop that leaves the PIPE with two entries
--   or fewer runs the refill: 'PFillA'/'PFillB' move one FIFO entry each
--   (the block RAM read is registered), 'PDrain' moves pending entries into
--   the FIFO one per cycle and ends with @CheckFIFODMA@/@CheckFIFOIRQ@.
-- * The bus stall holds no copies of entries. When an entry would overflow
--   FIFO+PIPE, the write that produced it is suspended where it is: the
--   packed word and the @WriteToGXFIFO@ loop state ('PendPack'), or the one
--   command-port entry ('PendDirect'). 'PDrain' resumes it. melonDS queues
--   the overflowing entries instead; the order and counting of entries are
--   the same, and nothing else can observe the difference because the bus
--   is held until the write has finished.
-- * The tables are block RAM: live EDGE/FOG/TOON as 28 words of four byte
--   lanes (every CPU table write is one byte-enabled word write), latched
--   copies as three RAMs with their own read ports. The VBlank latch copies
--   the 28 words in 29 cycles ('CCopy'); 'foRenderBusy' is high meanwhile
--   and the bus waits. Disabling rendering (POWCNT1 bit 2) resets the
--   latched tables at once through 'sRenderZero'. After reset the live
--   tables are cleared in 28 cycles ('CClear').
--
-- Every event the bus accepts is complete before the next is accepted:
-- 'foBusReady' is low while a FIFO operation, the copy, the clear or the
-- architectural stall ('foStall') is in progress, and the command stream
-- is not offered then. A bus access has priority over a pop in the same
-- cycle. Reads have no side effects and return one cycle later; the
-- geometry engine answers 'foResAddr' combinationally ('iResult').
module Nds.Gpu3D.GxFrontHw
  ( BusReq (..)
  , HwEntry (..)
  , RenderScalars (..)
  , FrontOut (..)
  , busAccess
  , Access (..)
  , lanePlace
  , fogIndex
  , gxFrontHw
  , gxFrontTopEntity
  ) where

import Prelude

import Data.Bits (complement, shiftL, shiftR, testBit, (.&.), (.|.))
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Word (Word16, Word32, Word8)
import GHC.Generics (Generic)

import Clash.Annotations.TopEntity (PortName (..), TopEntity (..))
import Clash.Explicit.Prelude
  ( BitPack (..), BitVector, Clock, Enable, KnownDomain, NFDataX, Reset, ResetStrategy (..)
  , SNat (..), Signal, System, Unsigned, Vec, bitCoerce, blockRamU, errorX, register, resize
  , truncateB, unbundle, zeroExtend )
import qualified Clash.Explicit.Prelude as C

import Nds.Gpu3D.GxFront
import Nds.Gpu3D.Types

------------------------------------------------------------------------------
-- Ports

-- | One ARM9 I/O access, as the core's @proc_bus_gb_type@
-- (@rtl/proc_bus_gba.vhd@) carries it: @Adr@ is the byte address inside the
-- I/O region with bits 1:0 zero, @Din@ holds the write data in its byte
-- lanes, @acc@ is the width (00 8-bit, 01 16-bit, 10 32-bit) and @bEna@
-- names the lanes. @ena@ is the 'Maybe' around it, @rst@ the block reset.
data BusReq = BusReq
  { brAdr  :: !(BitVector 28)
  , brDin  :: !(BitVector 32)
  , brRnw  :: !Bool
  , brAcc  :: !(BitVector 2)
  , brBEna :: !(BitVector 4)
  } deriving (Eq, Show, Generic, NFDataX)

-- | A FIFO entry ('CmdEntry').
data HwEntry = HwEntry
  { heCmd   :: !Word8
  , heParam :: !Word32
  } deriving (Eq, Show, Generic, NFDataX, BitPack)

-- | The latched scalar @Render*@ registers.
data RenderScalars = RenderScalars
  { rsDispCnt    :: !Word32
  , rsAlphaRef   :: !Word8
  , rsClearAttr1 :: !Word32
  , rsClearAttr2 :: !Word32
  , rsFogColor   :: !Word32
  , rsFogOffset  :: !Word32
  , rsFogShift   :: !Word32
  , rsXPos       :: !Word16
  } deriving (Eq, Show, Generic, NFDataX)

-- | Everything the block drives.
data FrontOut = FrontOut
  { foBusReady   :: !Bool                 -- ^ a bus access is accepted this cycle
  , foRdata      :: !(Maybe (BitVector 32))  -- ^ read data, the cycle after the access, in its lanes
  , foResAddr    :: !Word32               -- ^ result word the presented read needs
  , foCmd        :: !(Maybe HwEntry)      -- ^ command stream to the geometry engine
  , foGxStat     :: !Word32               -- ^ GXSTAT as a 32-bit read returns it
  , foStall      :: !Bool                 -- ^ the architectural FIFO-full stall
  , foIrq        :: !Bool                 -- ^ GXFIFO IRQ condition, as last checked
  , foIrqCheck   :: !Bool                 -- ^ pulse: @CheckFIFOIRQ@ ran (IF bit 21 := 'foIrq')
  , foDma        :: !Bool                 -- ^ pulse: @CheckFIFODMA@ fired (start GXFIFO DMA)
  , foFifoLtHalf :: !Bool                 -- ^ fewer than 128 FIFO entries
  , foAck        :: !Bool                 -- ^ GXSTAT bit-15 acknowledge to the geometry engine
  , foGeomEn     :: !Bool                 -- ^ POWCNT1 bit 3
  , foRendEn     :: !Bool                 -- ^ POWCNT1 bit 2
  , foZeroDotW   :: !Word32               -- ^ DISP_1DOT_DEPTH as @ZeroDotWLimit@
  , foRender     :: !RenderScalars
  , foRenderBusy :: !Bool                 -- ^ the latched tables are being copied
  , foToon       :: !Word16               -- ^ @RenderToonTable@ entry, one cycle after its address
  , foEdge       :: !Word16               -- ^ @RenderEdgeTable@ entry
  , foFog        :: !Word8                -- ^ @RenderFogDensityTable@ entry (0..33)
  } deriving (Eq, Show, Generic, NFDataX)

------------------------------------------------------------------------------
-- Bus decode

-- | An access as the model sees it.
data Access = Access
  { acSize  :: !Size
  , acAddr  :: !Word32
  , acValue :: !Word32
  , acWrite :: !Bool
  } deriving (Eq, Show)

-- | Width, full byte address (from @Adr@ and the lane enables) and value
-- (the addressed lanes of @Din@).
busAccess :: BusReq -> Access
busAccess r = Access sz addr val (not (brRnw r))
  where
    sz = case brAcc r of
      0 -> S8
      1 -> S16
      _ -> S32
    be = brBEna r
    low :: Word32
    low = case sz of
      S8 | testBit be 0 -> 0
         | testBit be 1 -> 1
         | testBit be 2 -> 2
         | otherwise -> 3
      S16 -> if testBit be 2 then 2 else 0
      S32 -> 0
    addr = 0x04000000 .|. (bitCoerce (zeroExtend (brAdr r) :: BitVector 32) .&. 0x0FFFFFFC) .|. low
    din = bitCoerce (brDin r) :: Word32
    lane = din `shiftR` (8 * fromIntegral low)
    val = case sz of
      S8 -> lane .&. 0xFF
      S16 -> lane .&. 0xFFFF
      S32 -> din

-- | A read value placed in the lanes of its access.
lanePlace :: Access -> Word32 -> BitVector 32
lanePlace a v = pack (v `shiftL` (8 * fromIntegral (acAddr a .&. 3)))

-- | @RenderFogDensityTable@ index to live-table entry: entry 0 and 1 are
-- @FogDensityTable[0]@, 33 is @[31]@ (indices above 33 read entry 31).
fogIndex :: Unsigned 6 -> Unsigned 5
fogIndex i
  | i == 0 = 0
  | i >= 33 = 31
  | otherwise = resize (i - 1)

------------------------------------------------------------------------------
-- State

data Phase = PIdle | PPack | PFillA | PFillB | PDrain
  deriving (Eq, Show, Generic, NFDataX)

-- | A write suspended by the FIFO-full stall.
data Pend = PendNone | PendPack | PendDirect !Word8
  deriving (Eq, Show, Generic, NFDataX)

-- | The table engine: clearing the live tables after reset, or copying
-- them to the latched tables (word @k-1@ is written while @k@ is read).
data Copy = CNone | CClear !(Unsigned 5) | CCopy !(Unsigned 5)
  deriving (Eq, Show, Generic, NFDataX)

-- | Latched scalars in their stored widths (the fog shift and the scaled
-- fog offset are derived on output).
data RStore = RStore
  { rDisp  :: !(Unsigned 15)
  , rAlpha :: !(Unsigned 5)
  , rC1    :: !Word32
  , rC2    :: !Word32
  , rFc    :: !Word32
  , rFo    :: !(Unsigned 15)
  , rXPos  :: !(Unsigned 9)
  } deriving (Eq, Show, Generic, NFDataX)

-- | Registers, stored in the widths melonDS can actually reach: DISP3DCNT
-- has bits 0-14, ALPHA_TEST_REF 5 bits, FOG_OFFSET and DISP_1DOT_DEPTH 15,
-- the IRQ mode 2, @ExecParamCount@ < 32, and the packer's @NumCommands@
-- <= 4 and @ParamCount@ <= @TotalParams@ <= 32. The push/pop and test
-- counters are full 32-bit like melonDS's, so they wrap identically.
data HwSt = HwSt
  { sPhase      :: !Phase
  , sPipe       :: !(Vec 4 HwEntry)
  , sPipeN      :: !(Unsigned 3)
  , sRd         :: !(Unsigned 8)
  , sWr         :: !(Unsigned 8)
  , sCount      :: !(Unsigned 9)
  , sPend       :: !Pend
  , sVal        :: !Word32       -- ^ packed-word parameter being unpacked / pending parameter
  , sPack       :: !(Unsigned 3, Word32, Unsigned 6, Unsigned 6)  -- ^ 'Packer'
  , sIrqMode    :: !(Unsigned 2)  -- ^ GXSTAT bits 30-31
  , sNumPP      :: !Word32
  , sNumTest    :: !Word32
  , sPPBit      :: !Bool
  , sTestBit    :: !Bool
  , sEpc        :: !(Unsigned 5)
  , sIrq        :: !Bool
  , sIrqCheck   :: !Bool
  , sDma        :: !Bool
  , sGeomEn     :: !Bool
  , sRendEn     :: !Bool
  , sDispCnt    :: !(Unsigned 15)
  , sAlphaVal   :: !(Unsigned 5)
  , sClear1     :: !Word32
  , sClear2     :: !Word32
  , sFogColor   :: !Word32
  , sFogOffset  :: !(Unsigned 15)
  , sZeroRaw    :: !(Unsigned 15)  -- ^ DISP_1DOT_DEPTH & 0x7FFF
  , sR          :: !RStore
  , sRenderZero :: !Bool          -- ^ latched tables read as zero
  , sCopy       :: !Copy
  , sVblPending :: !Bool
  , sRdata      :: !(Maybe (BitVector 32))
  } deriving (Eq, Show, Generic, NFDataX)

resetStore :: Unsigned 9 -> RStore
resetStore = RStore 0 0 0x3F000000 0x00007FFF 0 0

-- | The reset state (@GPU3D::Reset@).
hwInit :: HwSt
hwInit = HwSt
  { sPhase = PIdle
  , sPipe = C.repeat (HwEntry 0 0)
  , sPipeN = 0
  , sRd = 0
  , sWr = 0
  , sCount = 0
  , sPend = PendNone
  , sVal = 0
  , sPack = (0, 0, 0, 0)
  , sIrqMode = 0
  , sNumPP = 0
  , sNumTest = 0
  , sPPBit = False
  , sTestBit = False
  , sEpc = 0
  , sIrq = False
  , sIrqCheck = False
  , sDma = False
  , sGeomEn = False
  , sRendEn = False
  , sDispCnt = 0
  , sAlphaVal = 0
  , sClear1 = 0x3F000000
  , sClear2 = 0x00007FFF
  , sFogColor = 0
  , sFogOffset = 0
  , sZeroRaw = 0x7FFF
  , sR = resetStore 0
  , sRenderZero = True
  , sCopy = CClear 0
  , sVblPending = False
  , sRdata = Nothing
  }

-- Width conversions between the stored fields and the model's words.
w32 :: C.KnownNat n => Unsigned n -> Word32
w32 u = bitCoerce (resize u :: Unsigned 32)

n32 :: C.KnownNat n => Word32 -> Unsigned n
n32 v = resize (bitCoerce v :: Unsigned 32)

w8 :: C.KnownNat n => Unsigned n -> Word8
w8 u = bitCoerce (resize u :: Unsigned 8)

n8 :: C.KnownNat n => Word8 -> Unsigned n
n8 v = resize (bitCoerce v :: Unsigned 8)

w16 :: C.KnownNat n => Unsigned n -> Word16
w16 u = bitCoerce (resize u :: Unsigned 16)

n16 :: C.KnownNat n => Word16 -> Unsigned n
n16 v = resize (bitCoerce v :: Unsigned 16)

toPacker :: (Unsigned 3, Word32, Unsigned 6, Unsigned 6) -> Packer
toPacker (a, b, c, d) = Packer (w8 a) b (w8 c) (w8 d)

fromPacker :: Packer -> (Unsigned 3, Word32, Unsigned 6, Unsigned 6)
fromPacker (Packer a b c d) = (n8 a, b, n8 c, n8 d)

irqModeW :: HwSt -> Word32
irqModeW s = w32 (sIrqMode s) `shiftL` 30

------------------------------------------------------------------------------
-- FIFO machine

type FifoWrite = Maybe (Unsigned 8, HwEntry)

-- | The FIFO side of one cycle, given the write action and pop accepted
-- this cycle and the FIFO RAM's read data. Every phase offers at most one
-- entry to @CmdFIFOWrite@ ('offer'); the PIPE takes at most one entry (the
-- offer while the FIFO is empty, or the RAM data in a refill) or shifts on
-- a pop. Returns the state, the FIFO RAM write and the FIFO RAM read
-- address.
fifoMachine :: HwSt -> WriteAct -> Bool -> HwEntry -> (HwSt, FifoWrite, Unsigned 8)
fifoMachine s act popNow q = (s', fifoWr, rdAddr)
  where
    phase = sPhase s
    -- An entry does not fit when the FIFO is full; it never goes to the
    -- PIPE then (the PIPE only takes entries while the FIFO is empty).
    fits = sCount s /= 256
    (pEmit, pPk, pMore) = packIter (sVal s) (toPacker (sPack s))
    pOffer = (\ce -> HwEntry (ceCmd ce) (ceParam ce)) <$> pEmit
    offer = case phase of
      PIdle -> case act of
        WaDirect c v -> Just (HwEntry c v)
        _ -> Nothing
      PPack -> pOffer
      PDrain -> case sPend s of
        PendDirect c -> Just (HwEntry c (sVal s))
        PendPack -> pOffer
        PendNone -> Nothing
      _ -> Nothing
    enq = if fits then offer else Nothing
    refused = isJust offer && not fits
    toPipe = sCount s == 0 && sPipeN s < 4
    refill = phase == PFillA || phase == PFillB
    pipeIn
      | refill = Just q
      | toPipe = enq
      | otherwise = Nothing
    fifoWr = if toPipe then Nothing else (\e -> (sWr s, e)) <$> enq

    hd = C.head (sPipe s)
    pushes = isJust pipeIn && sPipeN s < 4   -- FIFO::Write ignores a full PIPE
    pipe'
      | popNow = sPipe s C.<<+ hd
      | Just e <- pipeIn, pushes =
          C.imap (\k x -> if fromEnum k == fromEnum (sPipeN s) then e else x) (sPipe s)
      | otherwise = sPipe s
    pipeN'
      | popNow = sPipeN s - 1
      | pushes = sPipeN s + 1
      | otherwise = sPipeN s
    count'
      | isJust fifoWr = sCount s + 1
      | refill = sCount s - 1
      | otherwise = sCount s

    -- counters: CmdFIFOWrite increments, ExecuteCommand's bookkeeping
    -- decrements, and Run's settle clears the GXSTAT bits at zero.
    enqPP = maybe False (isPushPop . heCmd) enq
    enqTest = maybe False (isTest . heCmd) enq
    (epc', dpp, dt)
      | popNow = let (e, a, b) = retireCounts (heCmd hd) (w8 (sEpc s)) in (n8 e, a, b)
      | otherwise = (sEpc s, 0, 0)
    pp' = sNumPP s + (if enqPP then 1 else 0) - dpp
    test' = sNumTest s + (if enqTest then 1 else 0) - dt

    -- control
    finish = case phase of
      PDrain -> case sPend s of
        PendNone -> True
        _ -> refused
      _ -> False
    (phase', pend', pack', val') = case phase of
      PIdle
        | popNow ->
            (if pipeN' > 2 then PIdle else if sCount s /= 0 then PFillA else PDrain, sPend s, sPack s, sVal s)
        | otherwise -> case act of
            WaGxFifo v ->
              let (pk, run) = packStart v (toPacker (sPack s))
              in (if run then PPack else PIdle, sPend s, fromPacker pk, v)
            WaDirect c v | refused -> (PIdle, PendDirect c, sPack s, v)
            _ -> (PIdle, sPend s, sPack s, sVal s)
      PPack
        | refused -> (PIdle, PendPack, sPack s, sVal s)
        | otherwise -> (if pMore then PPack else PIdle, sPend s, fromPacker pPk, sVal s)
      PFillA -> (if sCount s /= 1 then PFillB else PDrain, sPend s, sPack s, sVal s)
      PFillB -> (PDrain, sPend s, sPack s, sVal s)
      PDrain
        | finish -> (PIdle, sPend s, sPack s, sVal s)
        | otherwise -> case sPend s of
            PendPack -> (PDrain, if pMore then PendPack else PendNone, fromPacker pPk, sVal s)
            _ -> (PDrain, PendNone, sPack s, sVal s)

    -- CheckFIFOIRQ / CheckFIFODMA: IRQ-mode writes and the end of a refill.
    modeWrite = case act of
      WaGxStat _ (Just m) -> Just m
      _ -> Nothing
    (mode', irq', chk', dma')
      | finish = (sIrqMode s, fifoIrqCond (irqModeW s) (w32 (sCount s)), True, sCount s < 128)
      | Just m <- modeWrite =
          (n32 (m `shiftR` 30), fifoIrqCond m (w32 (sCount s)), True, False)
      | otherwise = (sIrqMode s, sIrq s, False, False)

    rdAddr = if phase == PFillA then sRd s + 1 else sRd s

    s' = s { sPhase = phase', sPipe = pipe', sPipeN = pipeN'
           , sRd = if refill then sRd s + 1 else sRd s
           , sWr = if isJust fifoWr then sWr s + 1 else sWr s
           , sCount = count', sPend = pend', sVal = val', sPack = pack'
           , sIrqMode = mode', sNumPP = pp', sNumTest = test'
           , sPPBit = (sPPBit s || enqPP) && pp' /= 0
           , sTestBit = (sTestBit s || enqTest) && test' /= 0
           , sEpc = epc', sIrq = irq', sIrqCheck = chk', sDma = dma' }

------------------------------------------------------------------------------
-- Registers and tables

type LaneWrites = Vec 4 (Maybe (Unsigned 5, BitVector 8))

noLanes :: LaneWrites
noLanes = C.repeat Nothing

-- | The register side of a write action.
regWrite :: WriteAct -> HwSt -> (HwSt, LaneWrites)
regWrite act s = case act of
  WaDispCnt v -> (s { sDispCnt = n32 (dispCntWrite (w32 (sDispCnt s)) v) }, noLanes)
  WaAlphaRef v -> (s { sAlphaVal = n32 (v .&. 0x1F) }, noLanes)
  WaReg r m v ->
    let upd old = (old .&. complement m) .|. (v .&. m)
    in case r of
      RClear1 -> (s { sClear1 = upd (sClear1 s) }, noLanes)
      RClear2 -> (s { sClear2 = upd (sClear2 s) }, noLanes)
      RFogColor -> (s { sFogColor = upd (sFogColor s) }, noLanes)
  WaFogOffset v -> (s { sFogOffset = n32 (v .&. 0x7FFF) }, noLanes)
  WaTable w be d ->
    ( s
    , C.imap (\k _ -> if testBit be (fromEnum k)
                        then Just (n8 w, truncateB (pack (d `shiftR` (8 * fromEnum k))))
                        else Nothing)
             (C.repeat () :: Vec 4 ()) )
  WaZeroDot v -> (s { sZeroRaw = n32 (v .&. 0x7FFF) }, noLanes)
  _ -> (s, noLanes)

latchStore :: HwSt -> RStore
latchStore s = RStore
  { rDisp = sDispCnt s
  , rAlpha = n8 (alphaRefOf (w32 (sDispCnt s)) (w8 (sAlphaVal s)))
  , rC1 = sClear1 s
  , rC2 = sClear2 s
  , rFc = sFogColor s
  , rFo = sFogOffset s
  , rXPos = rXPos (sR s)
  }

renderOut :: RStore -> RenderScalars
renderOut r = RenderScalars
  { rsDispCnt = w32 (rDisp r)
  , rsAlphaRef = w8 (rAlpha r)
  , rsClearAttr1 = rC1 r
  , rsClearAttr2 = rC2 r
  , rsFogColor = rFc r
  , rsFogOffset = w32 (rFo r) `shiftL` 9   -- FogOffset * 0x200
  , rsFogShift = (w32 (rDisp r) `shiftR` 8) .&. 0xF
  , rsXPos = w16 (rXPos r)
  }

-- | VBlank latch, table engine, POWCNT1, render X position and the
-- DISP3DCNT status bits, in that order, on top of the bus/FIFO result @t@
-- (the latch reads the registers as the cycle began, @s@). Returns the
-- state, the live-table read word, the clear word and the latched-table
-- write.
sideStep
  :: Bool -> Maybe (Word16, Word16) -> Maybe (Bool, Bool) -> (Bool, Bool) -> Vec 4 (BitVector 8)
  -> HwSt -> HwSt
  -> (HwSt, Unsigned 5, Maybe (Unsigned 5), Maybe (Unsigned 5, BitVector 32))
sideStep vbl xpos power (under, over) live s t =
  ( t { sGeomEn = geom2, sRendEn = rend2, sR = r3, sCopy = copy2, sRenderZero = zero2
      , sVblPending = vbl, sDispCnt = sDispCnt t .|. flagBits }
  , liveRd, clearW, rendW )
  where
    clearing = case sCopy s of
      CClear _ -> True
      _ -> False
    latch = sVblPending s && sGeomEn s && sRendEn s
    -- The live tables are all zero while they are being cleared, so a latch
    -- then leaves the latched tables zero ('sRenderZero' is still set).
    restart = latch && not clearing
    (copyNext, liveRd, clearW, rendW, copyDone) = case sCopy s of
      CNone -> (CNone, 0, Nothing, Nothing, False)
      CClear k -> (if k == 27 then CNone else CClear (k + 1), 0, Just k, Nothing, False)
      CCopy k ->
        ( if k == 28 then CNone else CCopy (k + 1)
        , k
        , Nothing
        , if k /= 0 then Just (k - 1, pack (C.reverse live)) else Nothing
        , k == 28 )
    r1 = if latch then latchStore s else sR s
    copy1 = if restart then CCopy 0 else copyNext
    zero1 = sRenderZero s && not (copyDone && not restart)
    (geom2, rend2, r2, copy2, zero2) = case power of
      Just (g, r)
        | r -> (g, r, r1, copy1, zero1)
        | otherwise -> (g, r, resetStore (rXPos r1), abortCopy copy1, True)
      Nothing -> (sGeomEn s, sRendEn s, r1, copy1, zero1)
    abortCopy c = case c of
      CCopy _ -> CNone
      other -> other
    r3 = case xpos of
      Just (x, m) | rend2 ->
        r2 { rXPos = n16 ((w16 (rXPos r2) .&. complement m) .|. (x .&. m .&. 0x01FF)) }
      _ -> r2
    flagBits = (if under then 0x1000 else 0) .|. (if over then 0x2000 else 0)

------------------------------------------------------------------------------
-- One cycle

-- The per-cycle records are lazy on purpose: the result word answers the
-- result address of the same cycle, and the RAM data feeds back through
-- the RAMs, so a strict field would close a loop in simulation.
data HwIn = HwIn
  { iBus     :: Maybe BusReq
  , iReady   :: Bool
  , iGeo     :: GeoStatus
  , iPipeSt  :: PipeStatus
  , iResult  :: Word32
  , iVblank  :: Bool
  , iXPos    :: Maybe (Word16, Word16)
  , iPower   :: Maybe (Bool, Bool)
  , iFlags   :: (Bool, Bool)
  , iFifoQ   :: HwEntry
  , iLive    :: Vec 4 (BitVector 8)
  }

data HwOut = HwOut
  { oFront  :: FrontOut   -- ^ without the table read data
  , oFifoRd :: Unsigned 8
  , oFifoWr :: FifoWrite
  , oLiveRd :: Unsigned 5
  , oLiveWr :: LaneWrites
  , oRendWr :: Maybe (Unsigned 5, BitVector 32)
  }

hwStep :: HwSt -> HwIn -> (HwSt, HwOut)
hwStep s i = (s4, HwOut front fifoRd fifoWr liveRd liveWr rendW)
  where
    idle = sPhase s == PIdle
    tableBusy = case sCopy s of
      CNone -> False
      _ -> True
    busReady = idle && sPend s == PendNone && not tableBusy && not (sVblPending s)
    presented = busAccess <$> iBus i
    acc = if busReady then presented else Nothing
    cmdValid = idle && sPipeN s /= 0 && isNothing acc
    popNow = cmdValid && iReady i
    act = case acc of
      Just a | acWrite a -> writeAction (sGeomEn s) (sRendEn s) (acSize a) (acAddr a) (acValue a)
      _ -> WaNone
    gx = composeGxStat (iGeo i) (sPPBit s) (sTestBit s) (sPipeN s /= 0) (irqModeW s)
           (w32 (sCount s))
    resAddr = fromMaybe 0 (presented >>= \a -> resultWord (acSize a) (acAddr a))
    readValue a = case resultWord (acSize a) (acAddr a) of
      Just _ -> resultProject (acSize a) (acAddr a) (iResult i)
      Nothing -> readLocal gx (w32 (sDispCnt s)) (iPipeSt i) (acSize a) (acAddr a)
    rdata = case acc of
      Just a | not (acWrite a) -> Just (lanePlace a (readValue a))
      _ -> Nothing

    s0 = s { sIrqCheck = False, sDma = False }
    (s1, fifoWr, fifoRd) = fifoMachine s0 act popNow (iFifoQ i)
    (s2, busLanes) = regWrite act s1
    (s3, liveRd, clearW, rendW) =
      sideStep (iVblank i) (iXPos i) (iPower i) (iFlags i) (iLive i) s s2
    s4 = s3 { sRdata = rdata }
    liveWr = case clearW of
      Just k -> C.repeat (Just (k, 0))
      Nothing -> busLanes

    front = FrontOut
      { foBusReady = busReady
      , foRdata = sRdata s
      , foResAddr = resAddr
      , foCmd = if cmdValid then Just (C.head (sPipe s)) else Nothing
      , foGxStat = gx
      , foStall = sPend s /= PendNone
      , foIrq = sIrq s
      , foIrqCheck = sIrqCheck s
      , foDma = sDma s
      , foFifoLtHalf = sCount s < 128
      , foAck = case act of
          WaGxStat ack _ -> ack
          _ -> False
      , foGeomEn = sGeomEn s
      , foRendEn = sRendEn s
      , foZeroDotW = zeroDotOf (w32 (sZeroRaw s))
      , foRender = renderOut (sR s)
      , foRenderBusy = case sCopy s of
          CCopy _ -> True
          _ -> False
      , foToon = 0
      , foEdge = 0
      , foFog = 0
      }

------------------------------------------------------------------------------
-- The block

-- | The front end. Inputs: bus access (valid; accepted when 'foBusReady'),
-- command-stream ready, the geometry engine's 'GeoStatus', the polygon
-- block's RAM_COUNT, the result word at 'foResAddr' (combinational), the
-- VBlank pulse, engine A BG0HOFS writes (@SetRenderXPos@ value and mask),
-- POWCNT1 writes (geometry, rendering enable), the DISP3DCNT status bits
-- (12: colour buffer underflow, 13: polygon/vertex RAM overflow), and the
-- toon (0..31), edge (0..7) and fog (0..33) read addresses.
gxFrontHw
  :: forall dom. KnownDomain dom
  => Clock dom -> Reset dom -> Enable dom
  -> Signal dom (Maybe BusReq)
  -> Signal dom Bool
  -> Signal dom GeoStatus
  -> Signal dom PipeStatus
  -> Signal dom Word32
  -> Signal dom Bool
  -> Signal dom (Maybe (Word16, Word16))
  -> Signal dom (Maybe (Bool, Bool))
  -> Signal dom (Bool, Bool)
  -> Signal dom (Unsigned 5, Unsigned 3, Unsigned 6)
  -> Signal dom FrontOut
gxFrontHw clk rst en bus ready geo ps res vbl xpos power flags tblAddr =
  finishOut <$> hout <*> toonQ <*> edgeQ <*> fogQ <*> sel
  where
    hin = HwIn <$> bus <*> ready <*> geo <*> ps <*> res <*> vbl <*> xpos <*> power <*> flags
               <*> fifoQ <*> liveQ
    (st', hout) = unbundle (hwStep <$> st <*> hin)
    st = register clk rst en hwInit st'

    ram :: forall n a addr. (C.KnownNat n, 1 C.<= n, NFDataX a, Enum addr, NFDataX addr)
        => SNat n -> Signal dom addr -> Signal dom (Maybe (addr, a)) -> Signal dom a
    ram n = blockRamU clk rst en NoClearOnReset n (const (errorX "gxfront: unwritten RAM word"))
    fifoQ = unpack <$> ram (SNat :: SNat 256)
              (oFifoRd <$> hout) (fmap (fmap (\(a, e) -> (a, pack e)) . oFifoWr) hout)

    lane :: Int -> Signal dom (BitVector 8)
    lane k = ram (SNat :: SNat 32)
               (oLiveRd <$> hout) ((\o -> oLiveWr o C.!! k) <$> hout)
    liveQ = (\a b c d -> a C.:> b C.:> c C.:> d C.:> C.Nil) <$> lane 0 <*> lane 1 <*> lane 2 <*> lane 3

    -- Latched tables, routed by live-table word: 0-3 edge, 4-11 fog,
    -- 12-27 toon.
    rendWr = oRendWr <$> hout
    route :: forall n. C.KnownNat n => Unsigned 5 -> Unsigned 5 -> Maybe (Unsigned 5, BitVector 32)
          -> Maybe (Unsigned n, BitVector 32)
    route lo hi = (>>= \(w, d) -> if w >= lo && w < hi then Just (resize (w - lo), d) else Nothing)
    (toonA, edgeA, fogA) = unbundle tblAddr
    fogJ = fogIndex <$> fogA
    toonQ = ram (SNat :: SNat 16)
              ((\a -> resize (a `shiftR` 1) :: Unsigned 4) <$> toonA) (route 12 28 <$> rendWr)
    edgeQ = ram (SNat :: SNat 4)
              ((\a -> resize (a `shiftR` 1) :: Unsigned 2) <$> edgeA) (route 0 4 <$> rendWr)
    fogQ = ram (SNat :: SNat 8)
              ((\j -> resize (j `shiftR` 2) :: Unsigned 3) <$> fogJ) (route 4 12 <$> rendWr)
    sel = register clk rst en (False, False, 0, True)
            ((\t e j s -> (testBit t 0, testBit e 0, resize j :: Unsigned 2, sRenderZero s))
               <$> toonA <*> edgeA <*> fogJ <*> st)

    finishOut o tq eq fq (tOdd, eOdd, fb, zero) =
      let half upper w = if zero then 0 else bitCoerce (truncateB (if upper then w `shiftR` 16 else w) :: BitVector 16) :: Word16
          byte b w = if zero then 0 else bitCoerce (truncateB (w `shiftR` (8 * fromEnum b)) :: BitVector 8) :: Word8
      in (oFront o) { foToon = half tOdd tq, foEdge = half eOdd eq, foFog = byte fb fq }

------------------------------------------------------------------------------
-- Synthesis top

-- | Flat ports for integration and resource estimation.
data TopOut = TopOut
  { tBusReady   :: Bool
  , tRdValid    :: Bool
  , tRdata      :: BitVector 32
  , tResAddr    :: Word32
  , tCmdValid   :: Bool
  , tCmdCmd     :: Word8
  , tCmdParam   :: Word32
  , tGxStat     :: Word32
  , tStall      :: Bool
  , tIrq        :: Bool
  , tIrqCheck   :: Bool
  , tDma        :: Bool
  , tFifoLtHalf :: Bool
  , tAck        :: Bool
  , tGeomEn     :: Bool
  , tRendEn     :: Bool
  , tZeroDotW   :: Word32
  , tRender     :: RenderScalars
  , tRenderBusy :: Bool
  , tToon       :: Word16
  , tEdge       :: Word16
  , tFog        :: Word8
  } deriving (Generic, NFDataX)

{-# ANN gxFrontTopEntity
  (Synthesize
    { t_name = "nds_gpu3d_gxfront"
    , t_inputs =
        [ PortName "CLK"
        , PortName "RST"
        , PortName "EN"
        , PortName "BUS_ENA"
        , PortName "BUS_RNW"
        , PortName "BUS_ADR"
        , PortName "BUS_DIN"
        , PortName "BUS_ACC"
        , PortName "BUS_BENA"
        , PortName "CMD_READY"
        , PortProduct "GEO"
            [ PortName "TEST_BUSY", PortName "BOX_RESULT", PortName "POS_STACK"
            , PortName "PROJ_STACK", PortName "STACK_BUSY", PortName "STACK_ERROR"
            , PortName "BUSY" ]
        , PortProduct "RAM_COUNT" [PortName "POLYGONS", PortName "VERTICES"]
        , PortName "RESULT"
        , PortName "VBLANK"
        , PortName "XPOS_WE"
        , PortName "XPOS"
        , PortName "XPOS_MASK"
        , PortName "POWER_WE"
        , PortName "POWER_GEOM"
        , PortName "POWER_REND"
        , PortName "FLAG_UNDERFLOW"
        , PortName "FLAG_OVERFLOW"
        , PortName "TOON_ADDR"
        , PortName "EDGE_ADDR"
        , PortName "FOG_ADDR"
        ]
    , t_output = PortProduct ""
        [ PortName "BUS_READY", PortName "RD_VALID", PortName "RD_DATA", PortName "RESULT_ADDR"
        , PortName "CMD_VALID", PortName "CMD_CMD", PortName "CMD_PARAM", PortName "GXSTAT"
        , PortName "STALL", PortName "IRQ", PortName "IRQ_CHECK", PortName "DMA"
        , PortName "FIFO_LT_HALF", PortName "STACK_ACK", PortName "GEOM_EN", PortName "REND_EN"
        , PortName "ZERO_DOT_W"
        , PortProduct "RENDER"
            [ PortName "DISPCNT", PortName "ALPHA_REF", PortName "CLEAR_ATTR1"
            , PortName "CLEAR_ATTR2", PortName "FOG_COLOR", PortName "FOG_OFFSET"
            , PortName "FOG_SHIFT", PortName "XPOS" ]
        , PortName "RENDER_BUSY", PortName "TOON_DATA", PortName "EDGE_DATA", PortName "FOG_DATA"
        ]
    }) #-}
gxFrontTopEntity
  :: Clock System -> Reset System -> Enable System
  -> Signal System Bool -> Signal System Bool -> Signal System (BitVector 28)
  -> Signal System (BitVector 32) -> Signal System (BitVector 2) -> Signal System (BitVector 4)
  -> Signal System Bool
  -> Signal System GeoStatus
  -> Signal System PipeStatus
  -> Signal System Word32
  -> Signal System Bool
  -> Signal System Bool -> Signal System Word16 -> Signal System Word16
  -> Signal System Bool -> Signal System Bool -> Signal System Bool
  -> Signal System Bool -> Signal System Bool
  -> Signal System (Unsigned 5) -> Signal System (Unsigned 3) -> Signal System (Unsigned 6)
  -> Signal System TopOut
gxFrontTopEntity clk rst en ena rnw adr din accw bena ready geo ps res vbl xwe xv xm pwe pg pr fu fo ta ea fa =
  flat <$> gxFrontHw clk rst en bus ready geo ps res vbl xpos power flags tbl
  where
    bus = (\e r a d c b -> if e then Just (BusReq a d r c b) else Nothing)
            <$> ena <*> rnw <*> adr <*> din <*> accw <*> bena
    xpos = (\w x m -> if w then Just (x, m) else Nothing) <$> xwe <*> xv <*> xm
    power = (\w g r -> if w then Just (g, r) else Nothing) <$> pwe <*> pg <*> pr
    flags = (,) <$> fu <*> fo
    tbl = (,,) <$> ta <*> ea <*> fa
    flat o = TopOut
      { tBusReady = foBusReady o
      , tRdValid = maybe False (const True) (foRdata o)
      , tRdata = fromMaybe 0 (foRdata o)
      , tResAddr = foResAddr o
      , tCmdValid = maybe False (const True) (foCmd o)
      , tCmdCmd = maybe 0 heCmd (foCmd o)
      , tCmdParam = maybe 0 heParam (foCmd o)
      , tGxStat = foGxStat o
      , tStall = foStall o
      , tIrq = foIrq o
      , tIrqCheck = foIrqCheck o
      , tDma = foDma o
      , tFifoLtHalf = foFifoLtHalf o
      , tAck = foAck o
      , tGeomEn = foGeomEn o
      , tRendEn = foRendEn o
      , tZeroDotW = foZeroDotW o
      , tRender = foRender o
      , tRenderBusy = foRenderBusy o
      , tToon = foToon o
      , tEdge = foEdge o
      , tFog = foFog o
      }
{-# NOINLINE gxFrontTopEntity #-}
