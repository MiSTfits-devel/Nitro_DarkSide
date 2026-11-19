-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE BinaryLiterals #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Both-screen DS 2D SoC: the Clash ARM9 ("Nds.WholeCore.Arm9Soc": slice,
-- timers, IME/IE/IF router, card slot) runs a boot-ROM program whose GPU
-- link drives this module's GPU target; one "Nds.Gpu2D.TileHw" engine,
-- time-shared between engines A and B, draws both screens on real DS line
-- timing; both screens are scanned out side by side. docs/GPU2D_SOC.md has
-- the design decisions, the verification and the limits.
--
-- __Line timing__ (as "Nds.Gpu.Live"): 263 lines of 2,130 cycles. At cycle
-- 0 of a line VCOUNT advances, the HBlank flag clears, the VCount match is
-- evaluated, VBlank sets at line 192 and clears at 262; at cycle 1584 the
-- HBlank flag sets. DISPSTAT bits 3/4/5 raise IF bits 0/1/2 through the
-- router's external set mask in the event's cycle. At each HBlank, as Live's
-- @preDraw@, an enabled engine shifts its DISPCNT history and forms the
-- delayed layer enables (BG and composed OBJ: DISPCNT and DISPCNT two
-- HBlanks earlier; sprite rendering: DISPCNT and one HBlank earlier); then
-- line y (y < 192) is drawn and the sprites of line y+1 (or of line 0 at
-- line 262) are rendered, as four engine jobs: BG A, BG B (or a line-buffer
-- clear when the line shows black or white), OBJ A, OBJ B. Live draws at
-- that instant; here the jobs take about a thousand cycles, so every CPU
-- write that the jobs read (engine registers, DISPCNT, POWCNT1, VRAMCNT,
-- palette, OAM, VRAM) is held from two cycles before the HBlank until the
-- jobs are done. The jobs therefore read exactly the state Live draws from.
--
-- __Unsupported, fail-closed__: a CPU access the target does not implement
-- gets a link error (the CPU faults); a display state the target cannot
-- draw sets a bit of 'goFault' and stops all drawing and the picture.
module Nds.WholeCore.TileSoc
  ( -- * GPU target
    Gpu
  , GpuIn (..)
  , GpuOut (..)
  , LinkOut (..)
  , VramQ
  , VramOps (..)
  , Video (..)
  , Txn (..)
  , initialGpu
  , gpuStep
  , gpuLinkOut
  , gpuFaultNames
    -- * Timing and layout
  , lineCycles
  , lineCount
  , hblankCycle
  , pictureLine0
  , activeSlot0
    -- * SoC
  , socInFrom
  , topOf
  , TopOut (..)
  , tileSoc
  , tileSocTopEntity
  ) where

import Clash.Explicit.Prelude hiding (Word)
import Data.Maybe (fromMaybe, isJust)

import Nds.Gpu2D.TileHw
import Nds.WholeCore.Arm9Io (IoOut (..))
import Nds.WholeCore.Arm9Slice (SliceOut (..))
import Nds.WholeCore.Arm9Soc (SocIn (..), SocOut (..), arm9Soc, noCartridge)

type Word = BitVector 32
type Half = BitVector 16
type Byte = BitVector 8

------------------------------------------------------------------------------
-- Timing and layout

lineCycles, lineCount, hblankCycle :: Int
lineCycles = 2130
lineCount = 263
hblankCycle = 1584

-- | DS line (VCOUNT) during which picture line 0 is scanned out: line y is
-- drawn at HBlank y and shown during line y + 2.
pictureLine0 :: Int
pictureLine0 = 2

-- | Video slot (a pixel enable every 3 cycles, 710 per line) of the first
-- active pixel: 512 active (top screen, then bottom screen), sync 0-51.
activeSlot0 :: Int
activeSlot0 = 116

------------------------------------------------------------------------------
-- Ports

-- | Block-RAM read data the cycle after the address: VRAM banks A (BG-A),
-- B (OBJ-A), C (BG-B), D (OBJ-B), four 16-bit lanes each.
type VramQ = Vec 4 (Vec 4 Half)

-- | VRAM bank RAM ports: per bank one read address (BG banks 4,096 x 64 bit
-- = 32 KiB, OBJ banks 512 x 64 bit = 4 KiB) and per lane at most one write.
data VramOps = VramOps
  { voRd :: !(Vec 4 (Unsigned 12))
  , voWr :: !(Vec 4 (Vec 4 (Maybe (Unsigned 12, Half))))
  } deriving (Eq, Show, Generic, NFDataX)

-- | Everything the GPU target sees in a cycle.
data GpuIn = GpuIn
  { giCpu   :: !SocOut      -- ^ the CPU side (only the link request fields are read)
  , giTile  :: !TileOut     -- ^ the engine (registered outputs)
  , giVram  :: !VramQ
  , giDisp  :: !Half        -- ^ display line buffer read data
  } deriving (Generic, NFDataX)

-- | Video, registered: pixel enable every third cycle, picture 512 x 192.
data Video = Video
  { vCe  :: !Bool
  , vDe  :: !Bool
  , vHs  :: !Bool
  , vVs  :: !Bool
  , vRgb :: !(BitVector 24)
  } deriving (Eq, Show, Generic, NFDataX)

-- | A completed link transaction: direction, address, width, write data or
-- read value, error reply. Registered: visible the cycle after it completed.
data Txn = Txn
  { txWrite :: !Bool
  , txAddr  :: !Word
  , txWidth :: !(BitVector 3)
  , txValue :: !Word
  , txFault :: !Bool
  } deriving (Eq, Show, Generic, NFDataX)

-- | Link replies and IRQ set mask: functions of the state only.
data LinkOut = LinkOut
  { loReqReady   :: !Bool
  , loReplyValid :: !Bool
  , loReplyData  :: !Word
  , loReplyFault :: !Bool
  , loIrqSet     :: !Word
  } deriving (Eq, Show, Generic, NFDataX)

data GpuOut = GpuOut
  { goLink  :: !LinkOut
  , goTile  :: !TileIn
  , goVram  :: !VramOps
  , goDispRd :: !(Unsigned 11)
  , goDispWr :: !(Maybe (Unsigned 11, Half))
  , goVideo :: !Video
  , goTxn   :: !(Maybe Txn)
  , goFault :: !(BitVector 16)
  , goVc    :: !(Unsigned 9)
  , goH     :: !(Unsigned 12)
  } deriving (Generic, NFDataX)

------------------------------------------------------------------------------
-- State

data LPhase = LIdle | LExec | LReply
  deriving (Eq, Show, Generic, NFDataX)

-- | The link request being served.
data Link = Link
  { lPhase :: !LPhase
  , lWrite :: !Bool
  , lAddr  :: !Word
  , lWidth :: !(BitVector 3)
  , lData  :: !Word
  , lSub   :: !Bool           -- ^ second half of a split word write
  , lReply :: !Word
  , lFault :: !Bool
  } deriving (Eq, Show, Generic, NFDataX)

-- | One engine's register file (the fields this target implements, as
-- "Nds.Gpu.Live2D" stores them).
data EngRegs = EngRegs
  { erDisp  :: !Word
  , erBgCnt :: !(Vec 4 Half)
  , erHofs  :: !(Vec 4 (Unsigned 9))
  , erVofs  :: !(Vec 4 (Unsigned 9))
  , erBld   :: !Half
  , erHist  :: !(Vec 2 Word)  -- ^ DISPCNT at the last two HBlanks while enabled
  , erLayer :: !(BitVector 5) -- ^ delayed BG0-3/OBJ enables of the last HBlank
  , erObj   :: !Bool          -- ^ delayed OBJ enable for sprite rendering
  } deriving (Eq, Show, Generic, NFDataX)

-- | How a drawn line shows.
data Code = CNormal | CBlack | CWhite
  deriving (Eq, Show, Generic, NFDataX)

-- | Per picture-line slot (y mod 4): code per engine and the screen swap.
data LineInfo = LineInfo
  { liCode :: !(Vec 2 Code)
  , liSwap :: !Bool
  } deriving (Eq, Show, Generic, NFDataX)

-- | Control: link, registers, scheduler, jobs, faults.
data Ctl = Ctl
  { cLink    :: !Link
  , cEng     :: !(Vec 2 EngRegs)
  , cStat    :: !Half           -- ^ DISPSTAT settings (bits 3-5, 7-15)
  , cMatch   :: !Bool           -- ^ VCount match flag of the current line
  , cPower   :: !Half           -- ^ POWCNT1 (& 0x820f)
  , cCnt     :: !(Vec 9 Byte)   -- ^ VRAMCNT_A..I
  , cScreens :: !Bool           -- ^ POWCNT1 bit 0 at frame start
  , cH       :: !(Unsigned 12)
  , cVc      :: !(Unsigned 9)
  , cPend    :: !(Vec 4 Bool)   -- ^ jobs to issue: BG A, BG B, OBJ A, OBJ B
  , cBgKind  :: !(Vec 2 JobKind) -- ^ JBg or JClear per engine
  , cBgLine  :: !(Unsigned 8)
  , cObjLine :: !(Unsigned 8)
  , cRun     :: !Bool           -- ^ an issued job is running
  , cRunEng  :: !Bit
  , cRunBg   :: !Bool           -- ^ ... and it emits pixels
  , cInfo    :: !(Vec 4 LineInfo)
  , cFault   :: !(BitVector 16)
  } deriving (Eq, Show, Generic, NFDataX)

-- | Datapath: the VRAM response in flight and the scanout stage.
data Dp = Dp
  { dResp :: !(Maybe (Index 4, Bool)) -- ^ bank, zero (unmapped space)
  , dScan :: !(Maybe (Code, Bool, Bool, Bool, Bool)) -- ^ code, ce, de, hs, vs of the next video slot
  } deriving (Eq, Show, Generic, NFDataX)

-- | Outputs: video and the transaction probe.
data Outs = Outs
  { oVideo :: !Video
  , oTxn   :: !(Maybe Txn)
  } deriving (Eq, Show, Generic, NFDataX)

-- | The GPU target's state, three registers built separately in 'tileSoc'.
data Gpu = Gpu { gC :: !Ctl, gD :: !Dp, gO :: !Outs }
  deriving (Eq, Show, Generic, NFDataX)

initialGpu :: Gpu
initialGpu = Gpu
  (Ctl { cLink = Link LIdle False 0 0 0 False 0 False
       , cEng = repeat (EngRegs 0 (repeat 0) (repeat 0) (repeat 0) 0 (repeat 0) 0 False)
       , cStat = 0, cMatch = False, cPower = 0, cCnt = repeat 0, cScreens = False
       , cH = 0, cVc = 0, cPend = repeat False, cBgKind = repeat JClear, cBgLine = 0, cObjLine = 0
       , cRun = False, cRunEng = 0, cRunBg = False
       , cInfo = repeat (LineInfo (repeat CBlack) False), cFault = 0 })
  (Dp Nothing Nothing)
  (Outs (Video False False False False 0) Nothing)

-- | Fault bits of 'goFault'.
gpuFaultNames :: [(Int, String)]
gpuFaultNames =
  [ (0, "engine fault (TileHw toFault nonzero)")
  , (1, "display mode 2/3 or forced blank on a drawn line")
  , (2, "OBJ extended palettes without bank F as engine A OBJ extended palette, or on engine B")
  , (3, "engine VRAM read inside a mapped bank but outside its implemented window")
  , (4, "jobs of an HBlank not finished by the next HBlank") ]

------------------------------------------------------------------------------
-- Address decoding

data Target = TDisp Bit | TStat | TEng Bit (Unsigned 7) | TPower | TCnt | TPal | TOam | TVram | TBad
  deriving (Eq, Show, Generic, NFDataX)

target :: Word -> BitVector 3 -> Target
target a w
  | inR 0x04000000 0x04000004 = TDisp 0
  | inR 0x04001000 0x04001004 = TDisp 1
  | inR 0x04000004 0x04000008 = TStat
  | inR 0x04000008 0x04000070 = TEng 0 (resize (unpack (slice d6 d0 a)))
  | inR 0x04001004 0x04001070 = TEng 1 (resize (unpack (slice d6 d0 a)))
  | a == 0x04000304 && w /= 1 = TPower
  | inR 0x04000240 0x04000247 || inR 0x04000248 0x0400024a = TCnt
  | inR 0x05000000 0x05000800 = TPal
  | inR 0x07000000 0x07000800 = TOam
  | slice d31 d24 a == 0x06 = TVram
  | otherwise = TBad
  where
    inR lo hi = a >= lo && a + resize w <= hi

-- | Engine register bytes this target implements (offsets in the engine's
-- 0x00-0x6f I/O window, DISPCNT apart).
engByteOk :: Unsigned 7 -> Bool
engByteOk o = (o >= 0x08 && o < 0x20) || o == 0x50 || o == 0x51

engByte :: EngRegs -> Unsigned 7 -> Byte
engByte e o
  | o >= 0x08 && o < 0x10 = halfByte (erBgCnt e !! (fromIntegral ((o - 8) `shiftR` 1) :: Index 4))
  | o == 0x50 || o == 0x51 = halfByte (erBld e)
  | otherwise = 0                       -- BGxHOFS/VOFS read 0, as Live2D
  where halfByte h = if testBit o 0 then slice d15 d8 h else slice d7 d0 h

writeEngByte :: Unsigned 7 -> Byte -> EngRegs -> EngRegs
writeEngByte o b e
  | o >= 0x08 && o < 0x10 = e { erBgCnt = replace k (setHalf (erBgCnt e !! k)) (erBgCnt e) }
  | o >= 0x10 && o < 0x20 = if testBit o 1
      then e { erVofs = replace j (setScroll (erVofs e !! j)) (erVofs e) }
      else e { erHofs = replace j (setScroll (erHofs e !! j)) (erHofs e) }
  | o == 0x50 || o == 0x51 = e { erBld = setHalf (erBld e) }
  | otherwise = e
  where
    k = fromIntegral (((o - 8) `shiftR` 1) .&. 3) :: Index 4
    j = fromIntegral (((o - 0x10) `shiftR` 2) .&. 3) :: Index 4
    hi = testBit o 0
    setHalf h = if hi then b ++# slice d7 d0 h else slice d15 d8 h ++# b
    setScroll :: Unsigned 9 -> Unsigned 9
    setScroll s = if hi then (if testBit b 0 then 0x100 else 0) .|. (s .&. 0xFF) else (s .&. 0x100) .|. resize (unpack b :: Unsigned 8)

-- | Bytes of a little-endian access: lane i is address + i.
laneByte :: Word -> Index 4 -> Byte
laneByte v i = slice d7 d0 (v `shiftR` (8 * fromEnum i))

-- | VRAMCNT write masks and the mappings this target implements.
cntMask :: Vec 9 Byte
cntMask = 0x9b :> 0x9b :> 0x9f :> 0x9f :> 0x87 :> 0x9f :> 0x9f :> 0x83 :> 0x83 :> Nil

cntIndex :: Word -> Index 9
cntIndex a = let o = slice d3 d0 a in if o <= 6 then fromIntegral (unpack o :: Unsigned 4) else fromIntegral ((unpack o :: Unsigned 4) - 1)

cntSupported :: Index 9 -> Byte -> Bool
cntSupported j v
  | not (testBit v 7) = True
  | otherwise = case j of
      0 -> v == 0x81                     -- A: engine A BG, offset 0
      1 -> v == 0x82                     -- B: engine A OBJ, offset 0
      2 -> v == 0x84                     -- C: engine B BG
      3 -> v == 0x84                     -- D: engine B OBJ
      4 -> v == 0x80 || v == 0x84        -- E: LCDC or engine A BG extended palettes
      5 -> v == 0x80 || v == 0x85        -- F: LCDC or engine A OBJ extended palette
      _ -> False

-- | Bank mapped as this target serves it.
bankMapped :: Vec 9 Byte -> Index 4 -> Bool
bankMapped cnt b = case b of
  0 -> cnt !! (0 :: Int) == 0x81
  1 -> cnt !! (1 :: Int) == 0x82
  2 -> cnt !! (2 :: Int) == 0x84
  _ -> cnt !! (3 :: Int) == 0x84

-- | Implemented window of a bank, in 8-byte words.
bankWords :: Index 4 -> Unsigned 17
bankWords b = if b == 0 || b == 2 then 4096 else 512

-- | Constructor tests are pattern matches, never derived @==@ on sum types
-- with payloads (the generated Verilog leaves unused payload bits
-- undefined; see docs/GPU3D_GEOMTX.md).
isPal, isOam, isVram, isStat, isPower, isCnt :: Target -> Bool
isPal t = case t of TPal -> True; _ -> False
isOam t = case t of TOam -> True; _ -> False
isVram t = case t of TVram -> True; _ -> False
isStat t = case t of TStat -> True; _ -> False
isPower t = case t of TPower -> True; _ -> False
isCnt t = case t of TCnt -> True; _ -> False

isBadDest :: VramDest -> Bool
isBadDest v = case v of VBad -> True; _ -> False

data VramDest = VBank (Index 4) (Unsigned 12) (Index 4) | VDrop | VExt (Unsigned 12) | VBad
  deriving (Eq, Show, Generic, NFDataX)

-- | Where a CPU VRAM write at @a@ goes (lane = halfword in the 8-byte word).
vramDest :: Vec 9 Byte -> Word -> VramDest
vramDest cnt a = case slice d23 d21 a of
  0 -> bank 0
  1 -> bank 2
  2 -> bank 1
  3 -> bank 3
  4 | lcdc >= 0x80000 && lcdc < 0x90000 && cnt !! (4 :: Int) == 0x80 -> VDrop
    | lcdc >= 0x90000 && lcdc < 0x92000 && cnt !! (5 :: Int) == 0x80 -> VExt (resize ((lcdc - 0x90000) `shiftR` 1))
  _ -> VBad
  where
    off = unpack (resize (slice d20 d0 a)) :: Unsigned 21
    lcdc = unpack (resize (slice d19 d0 a)) :: Unsigned 20
    wordIx = resize (off `shiftR` 3) :: Unsigned 17
    bank b | bankMapped cnt b && wordIx < bankWords b = VBank b (resize wordIx) (fromIntegral (unpack (slice d2 d1 a) :: Unsigned 2))
           | otherwise = VBad

------------------------------------------------------------------------------
-- Link outputs

gpuLinkOut :: Gpu -> LinkOut
gpuLinkOut (Gpu c _ _) = LinkOut
  { loReqReady = lPhase l == LIdle
  , loReplyValid = lPhase l == LReply
  , loReplyData = if lPhase l == LReply then lReply l else 0
  , loReplyFault = lPhase l == LReply && lFault l
  , loIrqSet = irqSetOf c }
  where l = cLink c

-- | VCount match setting of DISPSTAT.
matchOf :: Half -> Unsigned 9
matchOf s = unpack (slice d7 d7 s ++# slice d15 d8 s)

-- | IF bits raised by this cycle's line events.
irqSetOf :: Ctl -> Word
irqSetOf c = (if vblankIrq then 1 else 0) .|. (if hblankIrq then 2 else 0) .|. (if vcountIrq then 4 else 0)
  where
    st = cStat c
    lineStart = cH c == 0
    vblankIrq = lineStart && cVc c == 192 && testBit st 3
    hblankIrq = cH c == fromIntegral hblankCycle && testBit st 4
    vcountIrq = lineStart && cVc c == matchOf st && not (cMatch c) && testBit st 5

------------------------------------------------------------------------------
-- Step

-- | One clock of the GPU target: next state and outputs. Reads of the
-- RAM data refer to the addresses driven the cycle before.
gpuStep :: Gpu -> GpuIn -> (Gpu, GpuOut)
gpuStep g@(Gpu c d o) i = (Gpu c' d' o', out)
  where
    link = cLink c
    tout = giTile i
    cpu = giCpu i
    io = socIo cpu
    sl = socCpu cpu
    h = cH c
    vc = cVc c
    faulted = cFault c /= 0
    lineStart = h == 0
    hblank = h == fromIntegral hblankCycle
    frameStart = lineStart && vc == 0

    -- DISPSTAT as it reads this cycle (events of this cycle applied)
    matchNow = if lineStart then vc == matchOf (cStat c) else cMatch c
    vblankFlag = vc >= 192 && vc < 262
    hblankFlag = h >= fromIntegral hblankCycle
    statNow = (cStat c .&. 0xffb8) .|. (if vblankFlag then 1 else 0) .|. (if hblankFlag then 2 else 0)
              .|. (if matchNow then 4 else 0)

    -- jobs ---------------------------------------------------------------
    busy = or (cPend c) || cRun c
    engOn :: Bit -> Bool
    engOn e = testBit (cPower c) (if e == 0 then 1 else 9)
    -- issue the lowest pending job when the engine is idle
    pendIx = let p = cPend c in
      if p !! (0 :: Int) then Just (0 :: Index 4) else if p !! (1 :: Int) then Just 1
      else if p !! (2 :: Int) then Just 2 else if p !! (3 :: Int) then Just 3 else Nothing
    issue = case pendIx of
      Just _ | toReady tout && not faulted && cRunDone -> True
      _ -> False
    cRunDone = not (cRun c) || toReady tout
    jobIx = fromMaybe 0 pendIx
    jobEng = if jobIx == 0 || jobIx == 2 then 0 else 1 :: Bit
    jobIsBg = jobIx < 2
    ej = cEng c !! jobEng
    jobKind = if jobIsBg then cBgKind c !! jobEng else JObj
    jobLine = if jobIsBg then cBgLine c else cObjLine c
    -- engine registers presented with the job (see the module header)
    bgRegs = Regs ((erDisp ej .&. complement 0x1f00) .|. (resize (erLayer ej) `shiftL` 8))
                  (erBgCnt ej) (erHofs ej) (erVofs ej) (erBld ej)
    objRegs = Regs ((erDisp ej .&. 0x80300010) .|. 0x10000 .|. (if erObj ej then 0x1000 else 0))
                   (repeat 0) (repeat 0) (repeat 0) 0
    clearRegs = Regs 0x10000 (repeat 0) (repeat 0) (repeat 0) 0
    jobRegs = case jobKind of
      JBg -> bgRegs
      JObj -> objRegs
      _ -> clearRegs
    running' = issue || (cRun c && not (toReady tout))
    runEng' = if issue then jobEng else cRunEng c
    runBg' = if issue then jobIsBg && jobKind == JBg else cRunBg c

    -- VRAM provider: every engine request is taken at once; the data
    -- comes from the bank RAM the next cycle
    req = toReq tout
    reqBank = case req of
      Just (Req obj _) -> case (obj, cRunEng c) of
        (False, 0) -> 0
        (True, 0) -> 1
        (False, _) -> 2
        (True, _) -> 3
      Nothing -> 0 :: Index 4
    reqAddr = maybe 0 rqAddr req
    reqMapped = bankMapped (cCnt c) reqBank
    reqInWindow = resize reqAddr < bankWords reqBank
    reqOutside = isJust req && reqMapped && not reqInWindow
    resp = case dResp d of
      Just (b, zero) -> Just (if zero then 0 else pack (reverse (giVram i !! b)))
      Nothing -> Nothing

    tileIn = TileIn
      { tiStart = if issue then Just (LineReq jobEng jobLine jobKind) else Nothing
      , tiRegs = jobRegs
      , tiReqReady = True
      , tiResp = resp
      , tiPalWr = palWr
      , tiOamWr = oamWr
      , tiExtWr = extWr }

    -- HBlank: delayed layer enables, line codes, jobs ----------------------
    hbEng :: Bit -> EngRegs
    hbEng e = let r = cEng c !! e
                  dnow = erDisp r
                  l1 = erHist r !! (0 :: Int)
                  l2 = erHist r !! (1 :: Int)
              in if engOn e
                   then r { erHist = dnow :> l1 :> Nil
                          , erLayer = slice d12 d8 (l2 .&. dnow)
                          , erObj = testBit (l1 .&. dnow) 12 }
                   else r
    blankOf, drawFault, extFault, objWill :: Bit -> Bool
    blankOf e = let r = cEng c !! e in testBit (erHist r !! (1 :: Int) .|. erDisp r) 7
    modeOf :: Bit -> BitVector 2
    modeOf e = let dsp = erDisp (cEng c !! e) in if e == 0 then slice d17 d16 dsp else 0 ++# slice d16 d16 dsp
    codeOf :: Bit -> Code
    codeOf e
      | not (cScreens c) = CBlack
      | otherwise = case modeOf e of
          0 -> CWhite
          1 | not (engOn e) -> if e == 0 then CBlack else CWhite
            | otherwise -> CNormal
          _ -> CBlack
    drawFault e = cScreens c && engOn e && (modeOf e > 1 || (modeOf e == 1 && blankOf e))
    -- OBJ extended palettes: engine A needs bank F as its OBJ extended palette
    extFault e = engOn e && testBit (erDisp (cEng c !! e)) 31 && objWill e
                 && (e == 1 || cCnt c !! (5 :: Int) /= 0x85)
    objWill e = let r = cEng c !! e in testBit (erHist r !! (0 :: Int) .&. erDisp r) 12
    drawsLine = vc < 192
    objLine = if vc < 191 then Just (resize vc + 1) else if vc == 262 then Just 0 else Nothing :: Maybe (Unsigned 8)
    hbPend = (drawsLine && engOn 0) :> (drawsLine && engOn 1) :> (isJust objLine && engOn 0) :> (isJust objLine && engOn 1) :> Nil
    hbKind :: Bit -> JobKind
    hbKind e = case codeOf e of CNormal -> JBg; _ -> JClear
    hbInfo = LineInfo (codeOf 0 :> codeOf 1 :> Nil) (testBit (cPower c) 15)
    hbFault = (if drawsLine && (drawFault 0 || drawFault 1) then bit 1 else 0)
          .|. (if isJust objLine && (extFault 0 || extFault 1) then bit 2 else 0)
          .|. (if busy then bit 4 else 0)

    -- link ---------------------------------------------------------------
    a = lAddr link
    w = lWidth link
    wr = lWrite link
    tgt = target a w
    lanes = let wn = unpack w :: Unsigned 3 in (wn > 0) :> (wn > 1) :> (wn > 2) :> (wn > 3) :> Nil
    holdKind = wr && case tgt of
      TStat -> False
      TBad -> False
      _ -> True
    -- a held write waits to start; the second half of a split word write never waits
    holding = holdKind && not (lSub link) && (busy || (h >= fromIntegral hblankCycle - 2 && h <= fromIntegral hblankCycle))
    executing = lPhase link == LExec && not holding
    halfData = if lSub link then slice d31 d16 (lData link) else slice d15 d0 (lData link)
    subAddr = if lSub link then a + 2 else a
    split = w == 4 && (isPal tgt || isOam tgt || (isVram tgt && isExt (vramDest (cCnt c) a)))
    isExt v = case v of VExt _ -> True; _ -> False
    -- the reply value (reads) and the error flag, and register updates
    readVal = case tgt of
      TDisp e -> fold (.|.) (imap (\k on -> if on then resize (laneByte (erDisp (cEng c !! e)) (offIx k)) `shiftL` (8 * fromEnum k) else 0) lanes)
      TStat -> fold (.|.) (imap (\k on -> if on then resize (laneByte (resize statNow .|. (resize (pack vc) `shiftL` 16)) (statIx k)) `shiftL` (8 * fromEnum k) else 0) lanes)
      TEng e o -> fold (.|.) (imap (\k on -> if on then resize (engByte (cEng c !! e) (o + fromIntegral k)) `shiftL` (8 * fromEnum k) else 0) lanes)
      TPower -> resize (cPower c)
      TCnt -> fold (.|.) (imap (\k on -> if on then resize (cCnt c !! cntIndex (a + fromIntegral k)) `shiftL` (8 * fromEnum k) else 0) lanes)
      _ -> 0
    offIx k = fromIntegral (unpack (slice d1 d0 a) :: Unsigned 2) + k
    statIx k = fromIntegral (unpack (slice d1 d0 (a - 4)) :: Unsigned 2) + k
    engRangeOk o = and (imap (\k on -> not on || engByteOk (o + fromIntegral k)) lanes)
    -- a halfword write at 0x50 is masked to 0x3fff (Live2D)
    bldMask o = w == 2 && o == 0x50
    powerNew = slice d15 d0 (lData link) .&. 0x820f
    powerOk = not ((testBit (cPower c) 1 && not (testBit powerNew 1)) || (testBit (cPower c) 9 && not (testBit powerNew 9)))
    cntNew = imap (\j old -> if cntHit j then cntByte j .&. (cntMask !! j) else old) (cCnt c)
    cntHit j = or (imap (\k on -> on && cntIndex (a + fromIntegral k) == j && (a + fromIntegral k) /= 0x04000247) lanes)
    cntByte j = fold (\x y -> x .|. y) (imap (\k on -> if on && cntIndex (a + fromIntegral k) == j then laneByte (lData link) k else 0) lanes)
    vdest = vramDest (cCnt c) subAddr
    palEng = if testBit a 10 then 9 else 1 :: Int
    memOk = w /= 1 && testBit (cPower c) palEng
    -- errors (reply fault)
    bad = faulted || case tgt of
      TDisp _ -> False
      TStat -> wr && a + resize w > 0x04000006
      TEng _ o -> not (engRangeOk o)
      TPower -> wr && not powerOk
      TCnt -> wr && not (and (imap cntSupported cntNew))
      TPal -> not wr || not memOk
      TOam -> not wr || not memOk
      TVram -> not wr || w == 1 || isBadDest (vramDest (cCnt c) a) || (w == 4 && not (sameBankWord (vramDest (cCnt c) a) (vramDest (cCnt c) (a + 2))))
      TBad -> True
    sameBankWord x y = case (x, y) of
      (VBank b1 w1 _, VBank b2 w2 _) -> b1 == b2 && w1 == w2
      (VDrop, VDrop) -> True
      (VExt _, VExt _) -> True
      _ -> False
    commitOk = executing && not bad
    lastSub = not split || lSub link
    complete = executing && (bad || lastSub)
    -- register file updates by this cycle's committed write
    engWrite e r = case tgt of
      TDisp e' | e' == e -> let merged = fold (\x y -> x .|. y) (imap (\k old -> if laneHit k then resize (laneByte (lData link) (lanePos k)) `shiftL` (8 * fromEnum k) else resize old `shiftL` (8 * fromEnum k)) (dispBytes r))
                                masked = if e == 1 then merged .&. 0xc0b1fff7 else merged
                            in r { erDisp = masked }
      TEng e' o | e' == e && engOn e -> foldl (\acc k -> if k < fromEnum w
                                                         then writeEngByte (o + fromIntegral k) (maskB o k (laneByte (lData link) (fromIntegral k))) acc
                                                         else acc) r (0 :> 1 :> 2 :> 3 :> Nil :: Vec 4 Int)
      _ -> r
    dispBytes r = reverse (unpack (erDisp r)) :: Vec 4 Byte   -- lane k = byte k
    firstLane = fromIntegral (unpack (slice d1 d0 a) :: Unsigned 2) :: Index 4
    laneHit k = k >= firstLane && fromEnum k < fromEnum firstLane + fromEnum w
    lanePos k = k - firstLane
    maskB o k b = if bldMask o && k == 1 then b .&. 0x3f else b
    statWrite = foldl (\acc k -> if k < fromEnum w
                                 then let ba = a + fromIntegral k
                                          byte = laneByte (lData link) (fromIntegral k)
                                      in if ba == 0x04000004 then (acc .&. 0xff47) .|. (resize byte .&. 0xb8)
                                         else if ba == 0x04000005 then (acc .&. 0x00ff) .|. (resize byte `shiftL` 8)
                                         else acc
                                 else acc) (cStat c) (0 :> 1 :> 2 :> 3 :> Nil :: Vec 4 Int)

    -- memory writes (palette, OAM, VRAM, extended palette)
    memWrite = commitOk && wr
    palWr = case tgt of
      TPal | memWrite -> Just (unpack (slice d10 d1 subAddr), halfData)
      _ -> Nothing
    oamAttr = slice d2 d1 subAddr
    oamWr = case tgt of
      TOam | memWrite && oamAttr /= 3 -> Just (unpack (slice d10 d1 subAddr), halfData)
      _ -> Nothing
    extWr = case (tgt, vdest) of
      (TVram, VExt ix) | memWrite -> Just (resize ix, halfData)
      _ -> Nothing
    vramWr = case (tgt, vramDest (cCnt c) a) of
      (TVram, VBank b wix lane) | memWrite ->
        let l0 = lane
            hiHalf = slice d31 d16 (lData link)
            loHalf = slice d15 d0 (lData link)
            laneW :: Index 4 -> Maybe (Unsigned 12, Half)
            laneW ln = if ln == l0 then Just (wix, loHalf)
                       else if w == 4 && ln == l0 + 1 then Just (wix, hiHalf) else Nothing
            bankW :: Index 4 -> Vec 4 (Maybe (Unsigned 12, Half))
            bankW bk = if bk == b then laneW 0 :> laneW 1 :> laneW 2 :> laneW 3 :> Nil else repeat Nothing
        in bankW 0 :> bankW 1 :> bankW 2 :> bankW 3 :> Nil
      _ -> repeat (repeat Nothing)

    -- control register --------------------------------------------------------
    link' = case lPhase link of
      LIdle | extReqValid io -> link { lPhase = LExec, lWrite = gpuReqWrite sl, lAddr = gpuReqAddr sl
                                     , lWidth = gpuReqWidth sl, lData = gpuReqData sl, lSub = False }
            | otherwise -> link
      LExec | complete -> link { lPhase = LReply, lReply = if bad || wr then 0 else readVal, lFault = bad, lSub = False }
            | executing && split -> link { lSub = True }
            | otherwise -> link
      LReply | extReplyReady io -> link { lPhase = LIdle }
             | otherwise -> link
    engs1 = zipWith (\e r -> if commitOk && wr then engWrite e r else r) (0 :> 1 :> Nil :: Vec 2 Bit) (cEng c)
    -- at the HBlank no write that reaches the registers commits (it is held)
    engs' = if hblank then zipWith (\e r -> if engOn e then hbEng e else r) (0 :> 1 :> Nil :: Vec 2 Bit) engs1 else engs1
    pend1 = case pendIx of
      Just k | issue -> replace k False (cPend c)
      _ -> cPend c
    pend' = if hblank && not faulted then zipWith (||) pend1 hbPend else pend1
    vc' = if h == fromIntegral (lineCycles - 1) then (if vc == fromIntegral (lineCount - 1) then 0 else vc + 1) else vc
    h' = if h == fromIntegral (lineCycles - 1) then 0 else h + 1
    tileFault = if toFault tout /= 0 then bit 0 else 0
    newFault = tileFault .|. (if hblank then hbFault else 0) .|. (if reqOutside then bit 3 else 0)
    c' = c
      { cLink = link'
      , cEng = engs'
      , cStat = if commitOk && wr && isStat tgt then statWrite else cStat c
      , cMatch = matchNow
      , cPower = if commitOk && wr && isPower tgt then powerNew else cPower c
      , cCnt = if commitOk && wr && isCnt tgt then cntNew else cCnt c
      , cScreens = if frameStart then testBit (cPower c) 0 else cScreens c
      , cH = h'
      , cVc = vc'
      , cPend = pend'
      , cBgKind = if hblank then hbKind 0 :> hbKind 1 :> Nil else cBgKind c
      , cBgLine = if hblank then resize vc else cBgLine c
      , cObjLine = if hblank then fromMaybe 0 objLine else cObjLine c
      , cRun = running'
      , cRunEng = runEng'
      , cRunBg = runBg'
      , cInfo = if hblank && drawsLine then replace (resize vc :: Unsigned 2) hbInfo (cInfo c) else cInfo c
      , cFault = cFault c .|. newFault }

    -- display line buffer: engine pixels of BG jobs; scanout reads
    dispWr = case toPixel tout of
      Just p | cRunBg c -> Just (unpack (pack (cRunEng c) ++# pack (resize (cBgLine c) :: Unsigned 2) ++# pack (poX p)), poColor p)
      _ -> Nothing
    -- scanout: slot p = h / 3; the RAM read for slot p is issued at h = 3p + 1
    -- and the video register loads at h = 3p + 2 (pixel enable visible at 3p + 3)
    slotNext = (h + 1) `div` 3
    issueRd = h `mod` 3 == 1
    pictureVc = vc >= fromIntegral pictureLine0 && vc < fromIntegral pictureLine0 + 192
    py = resize (vc - fromIntegral pictureLine0) :: Unsigned 8
    active = slotNext >= fromIntegral activeSlot0 && slotNext < fromIntegral activeSlot0 + 512
    px = resize (slotNext - fromIntegral activeSlot0) :: Unsigned 9
    right = testBit px 8
    info = cInfo c !! (resize py :: Unsigned 2)
    scrEng = if right == liSwap info then 1 else 0 :: Bit   -- left/top is A when swapped
    dispRd = unpack (pack scrEng ++# pack (resize py :: Unsigned 2) ++# slice d7 d0 (pack px)) :: Unsigned 11
    de = pictureVc && active && not faulted
    hs = slotNext < 52
    vs = vc >= 220 && vc < 223
    code = liCode info !! scrEng
    scan' = if issueRd then Just (code, True, de, hs, vs) else Nothing
    video' = case dScan d of
      Just (cd, _, de1, hs1, vs1) -> Video True de1 hs1 vs1 (if de1 then rgbOf cd (giDisp i) else 0)
      Nothing -> (oVideo o) { vCe = False }

    d' = Dp
      { dResp = case req of
          Just _ -> Just (reqBank, not reqMapped)
          Nothing -> Nothing
      , dScan = scan' }

    txn' = if complete
      then Just (Txn wr a w (if wr then lData link else if bad then 0 else readVal) bad)
      else Nothing
    o' = Outs { oVideo = video', oTxn = txn' }

    out = GpuOut
      { goLink = gpuLinkOut g
      , goTile = tileIn
      , goVram = VramOps (repeat (resize reqAddr)) vramWr
      , goDispRd = dispRd
      , goDispWr = dispWr
      , goVideo = oVideo o
      , goTxn = oTxn o
      , goFault = cFault c
      , goVc = vc
      , goH = h }

-- | A 16-bit palette word through the renderer's 6-bit line word to 8-bit
-- RGB (as "Nds.Gpu2D.Line".@expandColor15@ then TraceRender's @expand@):
-- red and blue @c << 1@, green @(c << 1) | bit 15@, each @(v << 2) | (v >> 4)@.
rgbOf :: Code -> Half -> BitVector 24
rgbOf code c = case code of
  CBlack -> 0
  CWhite -> 0xffffff
  CNormal -> ch r6 ++# ch g6 ++# ch b6
  where
    r6 = slice d4 d0 c ++# (0 :: BitVector 1)
    g6 = slice d9 d5 c ++# slice d15 d15 c
    b6 = slice d14 d10 c ++# (0 :: BitVector 1)
    ch v = v ++# slice d5 d4 v

------------------------------------------------------------------------------
-- SoC

-- | The CPU's inputs from the GPU target's link outputs and the boot ROM
-- word (timer clock every cycle, no cartridge).
socInFrom :: Word -> LinkOut -> SocIn
socInFrom boot l = SocIn
  { socBootWord = boot
  , socGpuReqReady = loReqReady l
  , socGpuReplyValid = loReplyValid l
  , socGpuReplyData = loReplyData l
  , socGpuReplyFault = loReplyFault l
  , socTimerTick = True
  , socIrqSet = loIrqSet l
  , socIrqClear = 0
  , socCardIn = noCartridge }

data TopOut = TopOut
  { tBootAddr  :: Word
  , tVideo     :: BitVector 28
  , tTxnValid  :: Bool
  , tTxnWrite  :: Bool
  , tTxnAddr   :: Word
  , tTxnWidth  :: BitVector 3
  , tTxnValue  :: Word
  , tTxnFault  :: Bool
  , tIrqSet    :: BitVector 3
  , tGpuFault  :: BitVector 16
  , tCpuFault  :: BitVector 3
  , tStoreValid :: Bool
  , tStoreAddr :: Word
  , tStoreData :: Word
  , tRetire    :: Bool
  } deriving (Eq, Show, Generic, NFDataX)

-- | The top-level outputs from the CPU's and the GPU target's outputs.
topOf :: SocOut -> GpuOut -> TopOut
topOf cpu go = TopOut
  { tBootAddr = bootAddr (socCpu cpu)
  , tVideo = let v = goVideo go in pack (vCe v) ++# pack (vDe v) ++# pack (vHs v) ++# pack (vVs v) ++# vRgb v
  , tTxnValid = isJust (goTxn go)
  , tTxnWrite = maybe False txWrite (goTxn go)
  , tTxnAddr = maybe 0 txAddr (goTxn go)
  , tTxnWidth = maybe 0 txWidth (goTxn go)
  , tTxnValue = maybe 0 txValue (goTxn go)
  , tTxnFault = maybe False txFault (goTxn go)
  , tIrqSet = resize (loIrqSet (goLink go))
  , tGpuFault = goFault go
  , tCpuFault = fault (socCpu cpu)
  , tStoreValid = storeValid (socCpu cpu)
  , tStoreAddr = storeAddr (socCpu cpu)
  , tStoreData = storeData (socCpu cpu)
  , tRetire = retireValid (socCpu cpu) }

-- | The ARM9 SoC and the tile engine as netlist modules of their own, so the
-- fit's per-entity report measures each part.
cpuPart
  :: Clock System -> Reset System -> Enable System
  -> Signal System SocIn -> Signal System SocOut
cpuPart = arm9Soc
{-# NOINLINE cpuPart #-}

tilePart
  :: Clock System -> Reset System -> Enable System
  -> Signal System TileIn -> Signal System TileOut
tilePart = tileHw
{-# NOINLINE tilePart #-}

-- | The SoC: ARM9, GPU target, the shared tile engine and the block RAMs
-- (VRAM banks as 16-bit lanes, the 2,048 x 16 display line buffer).
tileSoc
  :: Clock System -> Reset System -> Enable System
  -> Signal System Word -> Signal System TopOut
tileSoc clk rst en bootIn = topOf <$> cpuOut <*> gpuOut
  where
    gpuState = Gpu <$> reg gC <*> reg gD <*> reg gO
    reg :: NFDataX a => (Gpu -> a) -> Signal System a
    reg f = register clk rst en (f initialGpu) (f <$> gpu')
    cpuOut = cpuPart clk rst en (socInFrom <$> bootIn <*> (gpuLinkOut <$> gpuState))
    (gpu', gpuOut) = unbundle (gpuStep <$> gpuState <*> (GpuIn <$> cpuOut <*> tileOut <*> vramQ <*> dispQ))
    tileOut = tilePart clk rst en (goTile <$> gpuOut)
    -- sixteen 16-bit lane RAMs: banks A and C 4,096 words, B and D 512
    vram = goVram <$> gpuOut
    lane :: Index 4 -> Index 4 -> Signal System Half
    lane b l = blockRam clk en (replicate (SNat @4096) 0)
                 ((!! b) . voRd <$> vram) ((!! l) . (!! b) . voWr <$> vram)
    smallLane :: Index 4 -> Index 4 -> Signal System Half
    smallLane b l = blockRam clk en (replicate (SNat @512) 0)
                 (resize . (!! b) . voRd <$> vram)
                 (fmap (\(x, v) -> (resize x :: Unsigned 9, v)) . (!! l) . (!! b) . voWr <$> vram)
    bankQ b = bundle (lane b 0 :> lane b 1 :> lane b 2 :> lane b 3 :> Nil)
    smallQ b = bundle (smallLane b 0 :> smallLane b 1 :> smallLane b 2 :> smallLane b 3 :> Nil)
    vramQ = bundle (bankQ 0 :> smallQ 1 :> bankQ 2 :> smallQ 3 :> Nil)
    dispQ = blockRam clk en (replicate (SNat @2048) 0) (goDispRd <$> gpuOut) (goDispWr <$> gpuOut)

-- Separate Verilog modules for the parts (readable netlist, exact error
-- locations from Clash).
{-# NOINLINE gpuStep #-}
{-# NOINLINE topOf #-}
{-# NOINLINE gpuLinkOut #-}
{-# NOINLINE socInFrom #-}
{-# NOINLINE vramDest #-}
{-# NOINLINE writeEngByte #-}
{-# NOINLINE engByte #-}
{-# NOINLINE irqSetOf #-}
{-# NOINLINE rgbOf #-}
{-# NOINLINE target #-}

{-# ANN tileSocTopEntity
  (Synthesize
    { t_name = "nds_tile_soc"
    , t_inputs = [PortName "CLK", PortName "RST", PortName "EN", PortName "BOOT_WORD"]
    , t_output = PortProduct ""
        [ PortName "BOOT_ADDR", PortName "VIDEO"
        , PortName "TXN_VALID", PortName "TXN_WRITE", PortName "TXN_ADDR", PortName "TXN_WIDTH"
        , PortName "TXN_VALUE", PortName "TXN_FAULT", PortName "IRQ_SET", PortName "GPU_FAULT"
        , PortName "CPU_FAULT", PortName "STORE_VALID", PortName "STORE_ADDR", PortName "STORE_DATA"
        , PortName "RETIRE_VALID" ]
    }) #-}
tileSocTopEntity
  :: Clock System -> Reset System -> Enable System
  -> Signal System Word -> Signal System TopOut
tileSocTopEntity = tileSoc
{-# NOINLINE tileSocTopEntity #-}
