-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric, TypeApplications #-}

-- | Synthesizable engine-A VRAM-display target for the ARM9 slice's GPU
-- link: POWCNT1, VRAMCNT_A/B, DISPCNT_A, two 128 KiB VRAM banks and the
-- top-LCD output of display modes 0 and 2, scanned out as 640x480 VGA.
--
-- This is a prototype CPU-to-pixel slice, not the DS 2D engine. Supported
-- state is checked on write; anything outside it is a GPU reply error, so
-- the CPU halts instead of seeing a silently different machine:
--
-- * VRAMCNT_A/B enabled with MST 2/3 (OBJ, texture), or VRAMCNT_C..I
--   enabled. Disabled banks and A/B as LCDC or engine-A BG are supported.
-- * DISPCNT_A with display mode 1 (BG/OBJ) or 3 (main-memory FIFO), or
--   BG mode 7 (rejected by the authoritative renderer too).
-- * DISPSTAT/VCOUNT reads: this slice has no DS-timed LCD schedule.
--
-- Within that state the CPU view follows "Nds.Gpu.LiveMemory": ARM9 byte
-- writes to VRAM are ignored, overlapping banks OR on read and broadcast on
-- write, and unmapped VRAM reads zero. The top LCD follows the authoritative
-- renderer for these modes: black with the LCDs off (POWCNT1 bit 0, sampled
-- at frame start), engine B (always display mode 0, white) unless POWCNT1
-- bit 15 puts engine A on top, white in display mode 0, and in display mode
-- 2 the halfword at @y*512+x*2@ of the selected bank if it is LCDC-mapped,
-- otherwise black. Engine B's registers, master brightness, BG/OBJ, 3D,
-- capture and DS line timing do not exist here.
module Nds.Gpu2D.VramDisplay
  ( Regs(..), initialRegs, LinkIn(..), Gpu, initialGpu, gpuRegs
  , GpuIn(..), GpuOut(..), VramWrite(..), RamAddr
  , gpuStep, cpuBanks, lcdcMapped, topColor, lcdColor
  , Raster(..), initialRaster, advanceRaster, vramDisplay
  ) where

import Prelude ()
import Clash.Prelude hiding (Word)
import qualified Clash.Explicit.Prelude as E

type Word = BitVector 32
type Width = BitVector 3
type Half = BitVector 16
-- | One 32-bit word of a 128 KiB bank, stored as two 16-bit lanes because
-- ARM9 byte writes never reach VRAM.
type RamAddr = Index 32768

data Regs = Regs
  { power   :: BitVector 16
  , dispcnt :: Word
  , vramcnt :: Vec 9 (BitVector 8)
  } deriving (Eq, Show, Generic, NFDataX)

initialRegs :: Regs
initialRegs = Regs 0 0 (repeat 0)

-- | The slice's request and reply-accept signals.
data LinkIn = LinkIn
  { reqValid   :: Bool
  , reqWrite   :: Bool
  , reqAddr    :: Word
  , reqWidth   :: Width
  , reqData    :: Word
  , replyReady :: Bool
  } deriving (Generic, NFDataX)

data Phase = Idle | Exec | ReadWait | Reply
  deriving (Eq, Show, Generic, NFDataX)

data Request = Request
  { rWrite :: Bool
  , rAddr  :: Word
  , rWidth :: Width
  , rData  :: Word
  } deriving (Show, Generic, NFDataX)

data Gpu = Gpu
  { phase      :: Phase
  , regs       :: Regs
  , request    :: Request
  , replyData  :: Word
  , replyFault :: Bool
  } deriving (Show, Generic, NFDataX)

initialGpu :: Gpu
initialGpu = Gpu Idle initialRegs (Request False 0 0 0) 0 False

gpuRegs :: Gpu -> Regs
gpuRegs = regs

-- | @ramWords@ holds banks A and B at the previous cycle's read address.
-- @displayBusy@ means the scanout owns the shared read address this cycle.
data GpuIn = GpuIn
  { link        :: LinkIn
  , displayBusy :: Bool
  , ramWords    :: Vec 2 Word
  }

-- | Lane enables per bank: bit 0 low halfword, bit 1 high halfword.
data VramWrite = VramWrite
  { wAddr  :: RamAddr
  , wLow   :: Half
  , wHigh  :: Half
  , wLanes :: Vec 2 (BitVector 2)
  } deriving (Eq, Show, Generic, NFDataX)

data GpuOut = GpuOut
  { reqReady   :: Bool
  , replyValid :: Bool
  , replyWord  :: Word
  , replyErr   :: Bool
  , ramRead    :: Maybe RamAddr
  , ramWrite   :: Maybe VramWrite
  } deriving (Generic, NFDataX)

widthMask :: Width -> Word
widthMask width = case width of
  1 -> 0xff
  2 -> 0xffff
  _ -> 0xffffffff

laneShift :: Word -> Int
laneShift addr = fromIntegral (slice d1 d0 addr) * 8

bankMasks :: Vec 9 (BitVector 8)
bankMasks = 0x9b :> 0x9b :> 0x9f :> 0x9f :> 0x87 :> 0x9f :> 0x9f :> 0x83 :> 0x83 :> Nil

-- | Low address byte of VRAMCNT_A..I (0x240..0x246, then 0x248/0x249).
cntOffset :: Index 9 -> BitVector 8
cntOffset j = if j < 7 then 0x40 + fromIntegral j else 0x41 + fromIntegral j

enabledAs :: BitVector 8 -> BitVector 8 -> Bool
enabledAs mst v = testBit v 7 && v .&. 7 == mst

lcdcMapped :: Vec 9 (BitVector 8) -> Index 9 -> Bool
lcdcMapped cnt b = enabledAs 0 (cnt !! b)

supportedBank :: Index 9 -> BitVector 8 -> Bool
supportedBank j v
  | j < 2 = not (testBit v 7) || v .&. 7 <= 1
  | otherwise = not (testBit v 7)

supportedDisplay :: Word -> Bool
supportedDisplay d = (mode == 0 || mode == 2) && slice d2 d0 d /= 7
 where mode = slice d17 d16 d

-- | Banks A and B selected by an ARM9 VRAM address ("Nds.Gpu.LiveMemory"
-- @location@ restricted to the supported mappings: engine-A BG and LCDC).
cpuBanks :: Vec 9 (BitVector 8) -> Word -> Vec 2 Bool
cpuBanks cnt a = map selects (0 :> 1 :> Nil)
 where
  region = slice d23 d21 a
  lcdcOffset = a .&. 0xfffff
  lcdcBank :: Maybe (Index 9)
  lcdcBank
    | lcdcOffset < 0x20000 = Just 0
    | lcdcOffset < 0x40000 = Just 1
    | otherwise = Nothing
  selects b
    | region == 0 = enabledAs 1 v && slice d4 d3 v == slice d18 d17 a
    | region < 4 = False
    | otherwise = lcdcBank == Just b && lcdcMapped cnt b
   where v = cnt !! b

ramIndex :: Word -> RamAddr
ramIndex a = fromIntegral (slice d16 d2 a)

data Target = TVram | TPower | TVramcnt | TDispcnt | TUnsupported
  deriving (Eq)

target :: Word -> Target
target a
  | slice d31 d24 a == 0x06 = TVram
  | a == 0x04000304 = TPower
  | a >= 0x04000240 && a <= 0x04000249 = TVramcnt
  | a >= 0x04000000 && a < 0x04000004 = TDispcnt
  | otherwise = TUnsupported

gpuStep :: Gpu -> GpuIn -> (Gpu, GpuOut)
gpuStep g i = (next, out)
 where
  l = link i
  r = request g
  rg = regs g
  a = rAddr r
  width = rWidth r
  kind = target a
  banks = cpuBanks (vramcnt rg) a
  vramRead = phase g == Exec && kind == TVram && not (rWrite r)
  issueRead = vramRead && not (displayBusy i)
  vramWrite = phase g == Exec && kind == TVram && rWrite r && width /= 1
  lanes = case width of
    4 -> 3
    _ -> if testBit a 1 then 2 else 1
  write = VramWrite (ramIndex a) (slice d15 d0 (rData r))
    (if width == 4 then slice d31 d16 (rData r) else slice d15 d0 (rData r))
    (map (\on -> if on then lanes else 0) banks)
  out = GpuOut
    { reqReady = phase g == Idle
    , replyValid = phase g == Reply
    , replyWord = if phase g == Reply then replyData g else 0
    , replyErr = phase g == Reply && replyFault g
    , ramRead = if issueRead then Just (ramIndex a) else Nothing
    , ramWrite = if vramWrite then Just write else Nothing
    }
  reply value = g { phase = Reply, replyData = value, replyFault = False }
  failed = g { phase = Reply, replyData = 0, replyFault = True }
  commit rg' value = (reply value) { regs = rg' }
  offset = laneShift a
  laneMask = shiftL (widthMask width) offset
  merged old = (old .&. complement laneMask) .|. (shiftL (rData r) offset .&. laneMask)
  extracted value = shiftR value offset .&. widthMask width
  first = slice d7 d0 a
  cntSpan j = cntOffset j >= first && cntOffset j - first < resize width
  cntByte j = slice d7 d0 (shiftR (rData r) (fromIntegral (cntOffset j - first) * 8))
  cntWrite = imap (\j old -> if cntSpan j then cntByte j .&. (bankMasks !! j) else old) (vramcnt rg)
  cntRead = fold (.|.) (imap (\j v -> if cntSpan j
    then shiftL (resize v) (fromIntegral (cntOffset j - first) * 8) else 0) (vramcnt rg))
  execute = case kind of
    TVram
      | rWrite r -> reply 0
      | issueRead -> g { phase = ReadWait }
      | otherwise -> g
    TPower
      | rWrite r -> commit rg { power = slice d15 d0 (rData r) .&. 0x820f } 0
      | otherwise -> reply (resize (power rg))
    TVramcnt
      | not (rWrite r) -> reply cntRead
      | and (imap supportedBank cntWrite) -> commit rg { vramcnt = cntWrite } 0
      | otherwise -> failed
    TDispcnt
      | not (rWrite r) -> reply (extracted (dispcnt rg))
      | supportedDisplay (merged (dispcnt rg)) -> commit rg { dispcnt = merged (dispcnt rg) } 0
      | otherwise -> failed
    TUnsupported -> failed
  readBack = fold (.|.) (zipWith (\on w -> if on then w else 0) banks (ramWords i))
  next = case phase g of
    Idle
      | reqValid l -> g { phase = Exec, request = Request (reqWrite l) (reqAddr l) (reqWidth l) (reqData l) }
      | otherwise -> g
    Exec -> execute
    ReadWait -> reply (extracted readBack)
    Reply
      | replyReady l -> g { phase = Idle }
      | otherwise -> g

-- | BGR555 through the renderer's 6-bit line word (@c << 1@, expanded as
-- @(v << 2) | (v >> 4)@) to 8-bit RGB: @c << 3 | c >> 3@ per channel.
lcdColor :: Half -> BitVector 24
lcdColor c = channel (slice d4 d0 c) ++# channel (slice d9 d5 c) ++# channel (slice d14 d10 c)
 where channel v = v ++# (0 :: BitVector 1) ++# slice d4 d3 v

-- | Display mode 0 is the 6-bit line word 0x3f per channel, so full white.
white :: BitVector 24
white = 0xffffff

-- | Top-LCD colour given the halfword at this pixel in banks A and B.
topColor :: Bool -> Regs -> Vec 2 Half -> BitVector 24
topColor lcdOn rg px
  | not lcdOn = 0
  | not (testBit (power rg) 15) = white
  | mode == 0 = white
  | mode == 2 && bank < 2 && lcdcMapped (vramcnt rg) (resize bank) = lcdColor (px !! (resize bank :: Index 2))
  | otherwise = 0
 where
  mode = slice d17 d16 (dispcnt rg)
  bank = fromIntegral (slice d19 d18 (dispcnt rg)) :: Index 4

-- | 25 MHz pixel enable from the 50 MHz clock; 640x480 active, 800x525.
data Raster = Raster Bool (Index 800) (Index 525)
  deriving (Eq, Generic, NFDataX)

initialRaster :: Raster
initialRaster = Raster False 0 0

advanceRaster :: Raster -> Raster
advanceRaster (Raster pixel x y)
  | not pixel = Raster True x y
  | x < 799 = Raster False (x + 1) y
  | y < 524 = Raster False 0 (y + 1)
  | otherwise = Raster False 0 0

-- The 256x192 LCD is drawn 2x at VGA (64,48). One 32-bit fetch covers two
-- LCD pixels (8 clocks) and is issued one word early, on the first clock of
-- VGA x = 60 + 4w; the scanout owns the read address only then. 60 and 64
-- are multiples of 4, so word and lane phases come straight from x.
inPicture :: Raster -> Bool
inPicture (Raster _ x y) = x >= 64 && x < 576 && y >= 48 && y < 432

fetchAt :: Raster -> Bool
fetchAt (Raster pixel x y) = not pixel && x >= 60 && x < 572 && y >= 48 && y < 432
  && slice d1 d0 (coord x) == 0

loadAt :: Raster -> Bool
loadAt raster@(Raster pixel x _) = not pixel && inPicture raster && slice d1 d0 (coord x) == 0

displayAddr :: Raster -> RamAddr
displayAddr (Raster _ x y) =
  fromIntegral (slice d8 d1 (coord y - 48) ++# slice d8 d2 (coord x - 60))

highLane :: Raster -> Bool
highLane (Raster _ x _) = testBit (coord x) 1

coord :: KnownNat n => Index n -> BitVector 10
coord = fromIntegral

data Scan = Scan
  { lcdOn   :: Bool
  , fetched :: Vec 2 Word
  , current :: Vec 2 Word
  } deriving (Generic, NFDataX)

scanStep :: Scan -> (Raster, Bool, Bool, Vec 2 Word) -> Scan
scanStep s (raster, frameStartPower, captured, wordsIn) = Scan
  { lcdOn = if raster == initialRaster then frameStartPower else lcdOn s
  , fetched = if captured then wordsIn else fetched s
  , current = if loadAt raster then fetched s else current s
  }

-- | CE, DE, HS, VS, RGB as in "Mister.Pong" (active-high syncs).
video :: Scan -> Regs -> Raster -> BitVector 28
video s rg raster@(Raster pixel x y) = pack pixel ++# pack de ++# pack hs ++# pack vs ++# rgb
 where
  de = x < 640 && y < 480
  hs = x >= 656 && x < 752
  vs = y >= 490 && y < 492
  shown = if loadAt raster then fetched s else current s
  half w = if highLane raster then slice d31 d16 w else slice d15 d0 w
  rgb = if inPicture raster then topColor (lcdOn s) rg (map half shown) else 0

-- | VRAM is zero at configuration, like the authoritative model's fresh
-- memory, and CPU reset does not clear it. Each lane loads this file with
-- @$readmemb@: 32768 lines of 16 '0's, generated beside the netlist by
-- sim/run_clash_gfx_soc.sh and fpga/mister_hs_gfx_slice/stage.sh. (Clash's
-- blockRam1 zero-fill loop is 32768 iterations, which Quartus 17 elaborates
-- too slowly to use.)
vramZeroFile :: FilePath
vramZeroFile = "nds_vram_zero.bin"

vramDisplay
  :: KnownDomain dom
  => Clock dom -> Reset dom
  -> Signal dom LinkIn -> (Signal dom GpuOut, Signal dom (BitVector 28))
vramDisplay clk rst linkIn = (out, E.register clk rst en 0 (video <$> scan <*> (regs <$> gpu) <*> raster))
 where
  en = enableGen
  gpu = E.register clk rst en initialGpu next
  (next, out) = unbundle (gpuStep <$> gpu <*> (GpuIn <$> linkIn <*> busy <*> ramOut))
  raster = E.register clk rst en initialRaster (advanceRaster <$> raster)
  busy = fetchAt <$> raster
  wasFetch = E.register clk rst en False busy
  scan = E.register clk rst en (Scan False (repeat 0) (repeat 0))
    (scanStep <$> scan <*> bundle (raster, (\g -> testBit (power (regs g)) 0) <$> gpu, wasFetch, ramOut))
  readAddr = mux busy (displayAddr <$> raster) (maybe 0 id . ramRead <$> out)
  writes = ramWrite <$> out
  laneWrite :: Index 2 -> Bool -> Maybe VramWrite -> Maybe (RamAddr, Half)
  laneWrite b upper w = case w of
    Just x | testBit (wLanes x !! b) (if upper then 1 else 0) ->
      Just (wAddr x, if upper then wHigh x else wLow x)
    _ -> Nothing
  lane b upper = E.blockRamFile clk en (SNat @32768) vramZeroFile readAddr (laneWrite b upper <$> writes)
  bankWord b = (++#) <$> lane b True <*> lane b False
  ramOut = bundle (bankWord 0 :> bankWord 1 :> Nil)
