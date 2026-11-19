-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE BinaryLiterals #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Synthesizable DS 2D tile engine: one mode-0 text background (4bpp or
-- 8bpp tiles on the standard palette) and regular sprites, composed over the
-- backdrop into one 256-pixel scanline per request. The model is
-- 'tileStep', a pure cycle-step function; 'tileHw' is the circuit built from
-- it with its block RAMs around it. The references are "Nds.Gpu2D.Line"
-- (backgrounds, composition) and "Nds.Gpu2D.Sprite" (sprites), which this
-- module does not use.
--
-- __Supported__ (bit-exact against the reference):
--
-- * BG mode 0 with zero or one of BG0-BG3 enabled; BGCNT priority,
--   character base, screen base, 256-colour bit and all four screen sizes;
--   engine A's DISPCNT character and screen base offsets (bits 24-29); 9-bit
--   H/V scroll with wraparound; tile H/V flip; the 4bpp palette number;
--   colour index 0 transparent.
-- * OBJ with 1D tile mapping and its tile-boundary field (DISPCNT bits 20-21):
--   regular (non-affine) sprites of all twelve sizes (and the prohibited
--   shape 3, which the reference draws 8x8), H/V flip, 4bpp with palette
--   number, 8bpp on the standard OBJ palette or, with DISPCNT bit 31, the OBJ
--   extended palette (palette number from attribute 2), clipping at both
--   screen edges and the 8-bit vertical wrap, OAM-order and priority
--   resolution among sprites, priority against the BG (OBJ wins ties), OBJ
--   window sprites (no colour; windows are off) and semi-transparent sprites
--   while BLDCNT has no second target.
-- * The backdrop (BG palette entry 0) everywhere else; engines A and B.
--
-- __Unsupported, fail-closed__: a line start whose registers ask for
-- anything else is refused with a nonzero 'toFault' (one bit per reason, see
-- 'faultNames') and the engine halts until reset: no pixel of that or any
-- later line. A sprite on the line that is affine, a bitmap, mosaic, or
-- semi-transparent while BLDCNT has a second target halts the engine the
-- same way when the OAM scan reaches it, before any pixel of the line. A
-- memory response with no request outstanding is a fault too.
--
-- __Register sampling__: every register is sampled once, in the cycle a
-- line start is accepted ('toReady' high and 'tiStart' valid). Each
-- sprite's OAM attributes are read once, when the OAM scan reaches it; VRAM
-- is read during the fetch phase and the palettes during the output phase of
-- the line. See docs/GPU2D_HW.md for what that does not model.
--
-- __Memory port__: VRAM is outside the engine. 'toReq' is a registered
-- request: a space (BG or OBJ VRAM) and an 8-byte word address in that space
-- (byte address bits 18..3; engine A's OBJ space wraps at 256 KiB, engine
-- B's BG and OBJ spaces at 128 KiB), taken when 'tiReqReady' is high.
-- 'tiResp' returns the 64-bit little-endian word, in request order, at least
-- one cycle after the request was taken and with any latency; the engine
-- never refuses a response. Per line: one map and one row request per BG
-- tile slot, one request per 8-pixel sprite tile column on the line.
--
-- __Pipeline__: a reset sweep clears the OBJ line buffer (256 cycles). Per
-- line: (1) map requests for the 32 BG tile slots (33 with a fine horizontal
-- scroll), responses into the map RAM; (2) one row request per slot, address
-- from its map entry, responses into the row RAM; (3, overlapping 1-2) the
-- OAM scan, one sprite per cycle; a sprite on the line is latched and issues
-- one request per tile column, with a column descriptor into the descriptor
-- RAM; (4) the pixel writer takes each column's response and writes its
-- opaque pixels into the OBJ line buffer, one per cycle, by read-modify-write
-- with OAM-order priority; (5) 256 output cycles: BG decode, line-buffer
-- read (and clear), priority, palette RAM reads, pixel register. Control,
-- datapath and output registers are three separate registers.
--
-- __Time sharing__: the per-line state is latched with an engine index; the
-- standard palette RAM holds both engines' palettes (BG-A, OBJ-A, BG-B,
-- OBJ-B), and OAM and the OBJ extended palettes are indexed by engine, so one
-- instance could serve both screens if the caller presents the selected
-- engine's registers with the start and routes its memory port. That is not
-- built or tested here.
module Nds.Gpu2D.TileHw
  ( -- * Ports
    Regs (..)
  , LineReq (..)
  , JobKind (..)
  , LbAddr
  , TileIn (..)
  , TileOut (..)
  , PixelOut (..)
  , Req (..)
  , VAddr
  , PalAddr
  , OamAddr
  , ExtAddr
  , Slot
  , Desc (..)
  , RamQ (..)
  , RamOps (..)
    -- * Pure step (the testbench models the block RAMs around it)
  , St
  , stInit
  , tileStep
    -- * Circuit
  , tileHw
  , tileHwExtPort
  , tileHwTopEntity
    -- * Encodings
  , layerBackdrop
  , layerObj
  , faultOf
  , faultNames
  , faultProtocol
  , faultAffine
  , faultBitmap
  , faultObjMosaic
  , faultSemiTrans
  ) where

import Clash.Explicit.Prelude
import Data.Maybe (fromMaybe, isJust, isNothing)

------------------------------------------------------------------------------
-- Ports

-- | 8-byte word address into one engine's BG or OBJ VRAM.
type VAddr = Unsigned 16

-- | Halfword index into the 2 KiB standard palette: BG-A 0-255, OBJ-A
-- 256-511, BG-B 512-767, OBJ-B 768-1023.
type PalAddr = Unsigned 10

-- | OAM halfword: bit 9 the engine, bits 8-2 the sprite, bits 1-0 the
-- attribute (attribute 3, the affine parameters, is not stored).
type OamAddr = Unsigned 10

-- | OBJ extended palette entry: bit 12 the engine, bits 11-8 the palette,
-- bits 7-0 the colour.
type ExtAddr = Unsigned 13

-- | Slot of the map/row RAMs (BG tile slot 0-32) or of the descriptor and
-- OBJ row RAMs (sprite tile column, modulo 64).
type Slot = Unsigned 6

-- | OBJ line-buffer entry: bit 9 the engine, bit 8 the half (line bit 0),
-- bits 7-0 the x.
type LbAddr = Unsigned 10

-- | Requests and responses of one line (at most 66 BG and 1,024 OBJ).
type Count = Unsigned 11

-- | The register port, sampled at line start only.
data Regs = Regs
  { rDispCnt :: !(BitVector 32)
  , rBgCnt   :: !(Vec 4 (BitVector 16))
  , rHofs    :: !(Vec 4 (Unsigned 9))     -- ^ BGxHOFS bits 0-8 (the rest do not exist)
  , rVofs    :: !(Vec 4 (Unsigned 9))     -- ^ BGxVOFS bits 0-8
  , rBldCnt  :: !(BitVector 16)
  } deriving (Eq, Show, Generic, NFDataX)

-- | What a job does. 'JBoth' renders a whole line in one job (sprites for
-- line y into its OBJ line-buffer half, then BG and composition reading
-- it). The split kinds let a caller follow the DS's one-line-ahead sprite
-- timing and time-share one engine between engines A and B: 'JObj' renders
-- the sprites of line y into half y&1 of that engine's OBJ line buffer and
-- emits no pixel; 'JBg' fetches line y's BG and composes it with half y&1
-- (reading and clearing it); 'JClear' only clears half y&1, emitting no
-- pixel (for a line whose BG is not drawn). A half must be clear when a
-- 'JObj' or 'JBoth' writes it: every half written is consumed by exactly
-- one 'JBg', 'JBoth' or 'JClear' of the same line before it is written
-- again.
data JobKind = JBoth | JBg | JObj | JClear
  deriving (Eq, Show, Generic, NFDataX)

-- | A line request: engine (0 = A, 1 = B), VCOUNT line and job kind.
data LineReq = LineReq
  { lqEngine :: !Bit
  , lqLine   :: !(Unsigned 8)
  , lqKind   :: !JobKind
  } deriving (Eq, Show, Generic, NFDataX)

-- | Inputs other than the RAM read data.
data TileIn = TileIn
  { tiStart    :: !(Maybe LineReq)          -- ^ line start, valid/ready with 'toReady'
  , tiRegs     :: !Regs                     -- ^ sampled when the start is accepted
  , tiReqReady :: !Bool                     -- ^ the memory port takes 'toReq'
  , tiResp     :: !(Maybe (BitVector 64))   -- ^ in-order response data
  , tiPalWr    :: !(Maybe (PalAddr, BitVector 16))  -- ^ standard palette write
  , tiOamWr    :: !(Maybe (OamAddr, BitVector 16))  -- ^ OAM halfword write
  , tiExtWr    :: !(Maybe (ExtAddr, BitVector 16))  -- ^ OBJ extended palette write
  } deriving (Eq, Show, Generic, NFDataX)

-- | A memory request: OBJ (True) or BG VRAM, and the word address.
data Req = Req
  { rqObj  :: !Bool
  , rqAddr :: !VAddr
  } deriving (Eq, Show, Generic, NFDataX)

-- | One output pixel: x, the 16-bit palette word and the layer (0-3 BG,
-- 4 OBJ, 5 backdrop, as "Nds.Gpu2D.Types".'Layer').
data PixelOut = PixelOut
  { poX     :: !(Unsigned 8)
  , poColor :: !(BitVector 16)
  , poLayer :: !(BitVector 3)
  } deriving (Eq, Show, Generic, NFDataX)

data TileOut = TileOut
  { toReady :: !Bool                 -- ^ idle (or halted): a start is taken this cycle
  , toReq   :: !(Maybe Req)          -- ^ memory request (registered)
  , toPixel :: !(Maybe PixelOut)     -- ^ x = 0..255 in order, one per cycle, no backpressure
  , toFault :: !(BitVector 16)       -- ^ nonzero: halted until reset
  } deriving (Eq, Show, Generic, NFDataX)

-- | One sprite tile column on the line: screen x of its first pixel, the
-- first and last pixel within the 8-pixel column (in screen order), and
-- what the pixel writer needs to decode and rank them.
data Desc = Desc
  { dsX    :: !(Unsigned 8)
  , dsLo   :: !(Unsigned 3)
  , dsHi   :: !(Unsigned 3)
  , dsFlip :: !Bool
  , ds256  :: !Bool
  , dsHalf :: !Bool              -- ^ 4bpp: the row is the upper 4 bytes of the word
  , dsExt  :: !Bool              -- ^ 8bpp on the extended palette
  , dsPal  :: !(BitVector 4)
  , dsPrio :: !(Unsigned 2)
  } deriving (Eq, Show, Generic, NFDataX, BitPack)

-- | Read data of the RAMs for the addresses driven the cycle before.
data RamQ = RamQ
  { qMap  :: !(BitVector 16)
  , qRow  :: !(BitVector 64)
  , qPal  :: !(BitVector 16)
  , qOam  :: !(Vec 3 (BitVector 16))
  , qLb   :: !(BitVector 16)
  , qDesc :: !Desc
  , qObj  :: !(BitVector 64)
  , qExt  :: !(Vec 2 (BitVector 16))
  } deriving (Eq, Show, Generic, NFDataX)

-- | RAM ports: one read address and at most one write per RAM per cycle.
-- Read data is the old contents when the same address is written.
data RamOps = RamOps
  { opMapRd  :: !Slot
  , opMapWr  :: !(Maybe (Slot, BitVector 16))
  , opRowRd  :: !Slot
  , opRowWr  :: !(Maybe (Slot, BitVector 64))
  , opPalRd  :: !PalAddr
  , opPalWr  :: !(Maybe (PalAddr, BitVector 16))
  , opOamRd  :: !(Unsigned 8)
  , opOamWr  :: !(Vec 3 (Maybe (Unsigned 8, BitVector 16)))
  , opLbRd   :: !LbAddr
  , opLbWr   :: !(Maybe (LbAddr, BitVector 16))
  , opDescRd :: !Slot
  , opDescWr :: !(Maybe (Slot, Desc))
  , opObjRd  :: !Slot
  , opObjWr  :: !(Maybe (Slot, BitVector 64))
  , opExtRd  :: !(Unsigned 12)
  , opExtDemand :: !(Maybe ExtAddr) -- ^ only on a selected extended OBJ colour
  , opExtWr  :: !(Vec 2 (Maybe (Unsigned 12, BitVector 16)))
  } deriving (Eq, Show, Generic, NFDataX)

------------------------------------------------------------------------------
-- State

data Phase = PClear | PIdle | PFetch | POut | PHalt
  deriving (Eq, Show, Generic, NFDataX)

-- | A sprite on the line, latched from OAM by the scan, issuing its tile
-- columns in screen order.
data Spr = Spr
  { spX    :: !(Signed 10)       -- ^ screen x of sprite x 0
  , spJ    :: !(Unsigned 3)      -- ^ next tile column (screen order)
  , spJ1   :: !(Unsigned 3)      -- ^ last tile column on screen
  , spXoff :: !(Unsigned 7)      -- ^ first sprite x on screen
  , spXend :: !(Unsigned 7)      -- ^ one past the last sprite x on screen
  , spWl   :: !(Unsigned 2)      -- ^ log2 (width / 8)
  , spFlip :: !Bool
  , sp256  :: !Bool
  , spRow  :: !(Unsigned 19)     -- ^ OBJ VRAM byte address of tile column 0's row
  , spHalf :: !Bool
  , spExt  :: !Bool
  , spPal  :: !(BitVector 4)
  , spPrio :: !(Unsigned 2)
  } deriving (Eq, Show, Generic, NFDataX)

-- | Control registers: sequencer, counters, and the line configuration
-- latched at line start.
data Ctl = Ctl
  { cPhase  :: !Phase
  , cKind   :: !JobKind
  , cEng    :: !Bit
  , cHalf   :: !Bit              -- ^ OBJ line-buffer half (line bit 0)
  , cY      :: !(Unsigned 8)
  , cBgOn   :: !Bool             -- ^ a background is enabled (else backdrop only)
  , cBg     :: !(Index 4)
  , cBgPrio :: !(Unsigned 2)
  , cIs256  :: !Bool
  , cWide   :: !Bool
  , cMapRow :: !(Unsigned 19)    -- ^ byte address of this line's map row, x part excluded
  , cTiles  :: !(Unsigned 19)    -- ^ tile data base
  , cFineY  :: !(Unsigned 3)
  , cScroll :: !(Unsigned 9)
  , cN      :: !Slot             -- ^ BG tile slots this line: 32, 33, or 0 without a BG
  , cScanOn :: !Bool             -- ^ the OAM scan runs (OBJ on, 'JBoth' or 'JObj')
  , cObjOn  :: !Bool             -- ^ composition reads the OBJ line buffer (OBJ on, 'JBoth' or 'JBg')
  , cOut    :: !Bool             -- ^ pixels are emitted ('JBoth' or 'JBg')
  , cExtOn  :: !Bool             -- ^ DISPCNT bit 31
  , cBound  :: !(Unsigned 2)     -- ^ 1D tile boundary
  , cBld2   :: !Bool             -- ^ BLDCNT has a second target (never for 'JObj')
  , cSemi   :: !(Vec 4 Bool)     -- ^ per engine and half: a semi-transparent sprite was drawn into it
  , cLoaded :: !Count            -- ^ requests loaded into the request register
  , cRcv    :: !Count            -- ^ responses received
  , cRdT    :: !Slot             -- ^ map RAM entry on the read port
  , cRdV    :: !Bool             -- ^ ... and it is valid
  , cScan   :: !(Unsigned 8)     -- ^ sprites scanned; OAM of sprite cScan is on the read port
  , cScanV  :: !Bool             -- ^ ... valid
  , cSpr    :: !(Maybe Spr)      -- ^ sprite issuing its columns
  , cWr     :: !Count            -- ^ sprite columns written; descriptor and row of cWr on the read port
  , cWrV    :: !Bool             -- ^ ... valid (its response is in)
  , cPixOn  :: !Bool             -- ^ the writer is inside column cWr
  , cPix    :: !(Unsigned 3)     -- ^ ... at this pixel
  , cOutK   :: !(Unsigned 9)     -- ^ next output pixel to read (256: all read)
  , cClr    :: !LbAddr           -- ^ reset sweep position
  , cFault  :: !(BitVector 16)
  } deriving (Eq, Show, Generic, NFDataX)

-- | Datapath registers: the line-buffer read-modify-write (candidate, last
-- write for forwarding) and the output pipeline after the BG/line-buffer
-- read (x, lane) and after the palette reads (x, layer, extended palette).
data Dp = Dp
  { dW1    :: !(Maybe (Unsigned 8, BitVector 16))
  , dLastW :: !(Maybe (Unsigned 8, BitVector 16))
  , dS1    :: !(Maybe (Unsigned 8, Unsigned 3))
  , dS2    :: !(Maybe (Unsigned 8, BitVector 3, Bool))
  } deriving (Eq, Show, Generic, NFDataX)

-- | Output registers.
data Outs = Outs
  { oReq :: !(Maybe Req)
  , oPix :: !(Maybe PixelOut)
  } deriving (Eq, Show, Generic, NFDataX)

-- | The whole state, as three registers built separately in 'tileHw'.
data St = St { sC :: !Ctl, sD :: !Dp, sO :: !Outs }
  deriving (Eq, Show, Generic, NFDataX)

stInit :: St
stInit = St
  (Ctl { cPhase = PClear, cKind = JBoth, cEng = 0, cHalf = 0, cY = 0, cBgOn = False, cBg = 0
       , cBgPrio = 0, cIs256 = False
       , cWide = False, cMapRow = 0, cTiles = 0, cFineY = 0, cScroll = 0, cN = 0
       , cScanOn = False, cObjOn = False, cOut = False, cExtOn = False, cBound = 0, cBld2 = False
       , cSemi = repeat False
       , cLoaded = 0, cRcv = 0, cRdT = 0, cRdV = False
       , cScan = 0, cScanV = False, cSpr = Nothing, cWr = 0, cWrV = False, cPixOn = False, cPix = 0
       , cOutK = 0, cClr = 0, cFault = 0 })
  (Dp Nothing Nothing Nothing Nothing)
  (Outs Nothing Nothing)

------------------------------------------------------------------------------
-- Encodings

layerObj, layerBackdrop :: BitVector 3
layerObj = 4
layerBackdrop = 5

faultProtocol, faultSemiTrans, faultAffine, faultBitmap, faultObjMosaic :: Int
faultProtocol = 10
faultSemiTrans = 11
faultAffine = 12
faultBitmap = 13
faultObjMosaic = 14

-- | Fault bits.
faultNames :: [(Int, String)]
faultNames =
  [ (0, "BG mode not 0")
  , (1, "more than one BG enabled")
  , (2, "OBJ on with 2D tile mapping")
  , (3, "window enabled")
  , (4, "forced blank")
  , (5, "display mode not 1")
  , (6, "BG0 is 3D")
  , (7, "colour special effect")
  , (8, "BG mosaic")
  , (9, "256-colour BG with extended palettes")
  , (faultProtocol, "memory response with no request outstanding")
  , (faultSemiTrans, "semi-transparent sprite on the line with a BLDCNT second target")
  , (faultAffine, "affine sprite on the line")
  , (faultBitmap, "bitmap sprite on the line")
  , (faultObjMosaic, "mosaic sprite on the line") ]

-- | Fault bits of a line start (bits 0-9 of 'faultNames').
faultOf :: Bit -> Regs -> BitVector 16
faultOf eng r =
      flag 0 (slice d2 d0 d /= 0)
  .|. flag 1 (en .&. (en - 1) /= 0)
  .|. flag 2 (testBit d 12 && not (testBit d 4))
  .|. flag 3 (slice d15 d13 d /= 0)
  .|. flag 4 (testBit d 7)
  .|. flag 5 (if engA then slice d17 d16 d /= 1 else not (testBit d 16))
  .|. flag 6 (engA && testBit d 3 && testBit d 8)
  .|. flag 7 (slice d7 d6 (rBldCnt r) /= 0)
  .|. flag 8 (bgOn && testBit cnt 6)
  .|. flag 9 (bgOn && testBit cnt 7 && testBit d 30)
  where
    d = rDispCnt r
    en = slice d11 d8 d
    engA = eng == 0
    bgOn = en /= 0
    cnt = rBgCnt r !! selBg d

flag :: Int -> Bool -> BitVector 16
flag i b = if b then bit i else 0

-- | The enabled background (the lowest one if several, which faults).
selBg :: BitVector 32 -> Index 4
selBg d
  | testBit d 8 = 0
  | testBit d 9 = 1
  | testBit d 10 = 2
  | otherwise = 3

-- | The line configuration latched at start, counters cleared. The job
-- kind decides what runs: the BG fetch ('JBoth', 'JBg'), the OAM scan
-- ('JBoth', 'JObj'; only with DISPCNT bit 12), composition with the OBJ
-- line buffer ('JBoth', 'JBg'; only with bit 12) and the pixel output
-- ('JBoth', 'JBg'). 'JClear' runs the output phase without emitting pixels.
configOf :: Bit -> Unsigned 8 -> JobKind -> Regs -> Ctl
configOf eng y kind r = Ctl
  { cPhase = PFetch, cKind = kind, cEng = eng, cHalf = lsb y, cY = y, cBgOn = bgOn, cBg = n
  , cBgPrio = unpack (slice d1 d0 cnt)
  , cIs256 = testBit cnt 7, cWide = wide
  , cMapRow = mapBase + rowOff, cTiles = dispChar + charBase
  , cFineY = resize yoff, cScroll = hofs
  , cN = if not bgOn then 0 else if resize hofs == (0 :: Unsigned 3) then 32 else 33
  , cScanOn = objEn && scans, cObjOn = objEn && composes, cOut = composes
  , cExtOn = testBit d 31, cBound = unpack (slice d21 d20 d)
  -- a JObj job never refuses a semi-transparent sprite: the JBg job that
  -- composes it does, against BLDCNT at its own start (see 'tileStep')
  , cBld2 = slice d13 d8 (rBldCnt r) /= 0 && not objOnly
  , cSemi = repeat False
  , cLoaded = 0, cRcv = 0, cRdT = 0, cRdV = False
  , cScan = 0, cScanV = False, cSpr = Nothing, cWr = 0, cWrV = False, cPixOn = False, cPix = 0
  , cOutK = 0, cClr = 0, cFault = 0 }
  where
    d = rDispCnt r
    objEn = testBit d 12
    (fetchesBg, scans, composes, objOnly) = case kind of
      JBoth -> (True, True, True, False)
      JBg -> (True, False, True, False)
      JObj -> (False, True, False, True)
      JClear -> (False, False, False, False)
    bgOn = fetchesBg && slice d11 d8 d /= 0
    n = selBg d
    cnt = rBgCnt r !! n
    hofs = rHofs r !! n
    yoff = (rVofs r !! n) + resize y :: Unsigned 9
    engA = eng == 0
    tall = testBit cnt 15
    wide = testBit cnt 14
    rowOff
      | tall = (resize (yoff .&. 0x1F8) `shiftL` 3)
                 + (if wide then resize (yoff .&. 0x100) `shiftL` 3 else 0)
      | otherwise = resize (yoff .&. 0xF8) `shiftL` 3 :: Unsigned 19
    dispScreen = if engA then resize (unpack (slice d29 d27 d) :: Unsigned 3) `shiftL` 16 else 0 :: Unsigned 19
    screenBase = resize (unpack (slice d12 d8 cnt) :: Unsigned 5) `shiftL` 11 :: Unsigned 19
    mapBase = dispScreen + screenBase
    dispChar = if engA then resize (unpack (slice d26 d24 d) :: Unsigned 3) `shiftL` 16 else 0 :: Unsigned 19
    charBase = resize (unpack (slice d5 d2 cnt) :: Unsigned 4) `shiftL` 14 :: Unsigned 19

------------------------------------------------------------------------------
-- Background

-- | Byte address to word address in the engine's BG VRAM (A 512 KiB, B 128 KiB).
wordOf :: Bit -> Unsigned 19 -> VAddr
wordOf eng a = resize ((if eng == 0 then a else a .&. 0x1FFFF) `shiftR` 3)

-- | Map entry address of tile slot @t@.
mapAddrOf :: Ctl -> Count -> VAddr
mapAddrOf c t = wordOf (cEng c) (cMapRow c + xpart)
  where
    xt = (cScroll c .&. 0x1F8) + (resize t `shiftL` 3) :: Unsigned 9
    xpart = (resize (xt .&. 0xF8) `shiftR` 2)
            + (if cWide c then resize (xt .&. 0x100) `shiftL` 3 else 0) :: Unsigned 19

-- | Halfword lane of slot @t@'s map entry in its 8-byte word.
mapLaneOf :: Ctl -> Count -> Unsigned 2
mapLaneOf c t = resize (cScroll c `shiftR` 3) + resize t

-- | Tile row (after vertical flip) of a map entry on this line.
rowOf :: Ctl -> BitVector 16 -> Unsigned 3
rowOf c e = if testBit e 11 then 7 - cFineY c else cFineY c

-- | Address of the 8-byte word holding a map entry's tile row.
rowAddrOf :: Ctl -> BitVector 16 -> VAddr
rowAddrOf c e = wordOf (cEng c) (cTiles c + tileOff + rowOff)
  where
    tile = resize (unpack (slice d9 d0 e) :: Unsigned 10) :: Unsigned 19
    row = resize (rowOf c e) :: Unsigned 19
    tileOff = if cIs256 c then tile `shiftL` 6 else tile `shiftL` 5
    rowOff = if cIs256 c then row `shiftL` 3 else row `shiftL` 2

-- | Little-endian lanes.
bytesLE :: BitVector 64 -> Vec 8 (BitVector 8)
bytesLE w = reverse (unpack w)

halvesLE :: BitVector 64 -> Vec 4 (BitVector 16)
halvesLE w = reverse (unpack w)

-- | Decode one BG pixel: opaque and standard-palette index (within the BG
-- half) from the slot's map entry and raw row word.
decodePixel :: Ctl -> Unsigned 3 -> BitVector 16 -> BitVector 64 -> (Bool, BitVector 8)
decodePixel c tx e w
  | not (cBgOn c) = (False, 0)
  | cIs256 c = (opaque8, b8)
  | otherwise = (opaque4, slice d15 d12 e ++# nib)
  where
    xx = if testBit e 10 then 7 - tx else tx
    bs = bytesLE w
    b8 = bs !! xx
    opaque8 = b8 /= 0
    half = resize (rowOf c e .&. 1) `shiftL` 2 :: Unsigned 3
    b4 = bs !! (half + (xx `shiftR` 1))
    nib = if testBit xx 0 then slice d7 d4 b4 else slice d3 d0 b4
    opaque4 = nib /= 0

------------------------------------------------------------------------------
-- Sprites

-- | log2 (width / 8) and log2 (height / 8) by size index (shape + 4 * size),
-- as melonDS's tables (shape 3 is drawn 8x8).
widthLog, heightLog :: Vec 16 (Unsigned 2)
widthLog  = 0 :> 1 :> 0 :> 0 :> 1 :> 2 :> 0 :> 0 :> 2 :> 2 :> 1 :> 0 :> 3 :> 3 :> 2 :> 0 :> Nil
heightLog = 0 :> 0 :> 1 :> 0 :> 1 :> 0 :> 2 :> 0 :> 2 :> 1 :> 2 :> 0 :> 3 :> 2 :> 3 :> 0 :> Nil

signed10 :: Unsigned 8 -> Signed 10
signed10 u = unpack (pack (resize u :: Unsigned 10))

data SprEval = SkipSpr | FaultSpr !(BitVector 16) | DrawSpr !Spr

-- | One sprite's OAM attributes against this line.
evalSprite :: Ctl -> Vec 3 (BitVector 16) -> SprEval
evalSprite c attrs
  | typ == 2 = SkipSpr
  | ypos >= resize bh = SkipSpr
  | xpos <= negate (signed10 bw) = SkipSpr
  | mode == 2 = SkipSpr                         -- OBJ window: no colour, windows are off
  | testBit typ 0 = FaultSpr (bit faultAffine)
  | mode == 3 = FaultSpr (bit faultBitmap)
  | testBit a0 12 = FaultSpr (bit faultObjMosaic)
  | mode == 1 && cBld2 c = FaultSpr (bit faultSemiTrans)
  | otherwise = DrawSpr spr
  where
    a0 = attrs !! (0 :: Int)
    a1 = attrs !! (1 :: Int)
    a2 = attrs !! (2 :: Int)
    typ = slice d9 d8 a0
    mode = slice d11 d10 a0
    sz = unpack (slice d15 d14 a1 ++# slice d15 d14 a0) :: Unsigned 4
    wl = widthLog !! sz
    hl = heightLog !! sz
    width = 8 `shiftL` fromEnum wl :: Unsigned 8
    height = 8 `shiftL` fromEnum hl :: Unsigned 8
    dbl = typ == 3
    bw = if dbl then width `shiftL` 1 else width
    bh = if dbl then resize height `shiftL` 1 else resize height :: Unsigned 9
    ypos = resize (cY c - unpack (slice d7 d0 a0)) :: Unsigned 9
    xpos = resize (unpack (slice d8 d0 a1) :: Signed 9) :: Signed 10
    flipX = testBit a1 12
    flipY = testBit a1 13
    is256 = testBit a0 13
    yl = resize ypos :: Unsigned 8
    ypos1 = if flipY then height - 1 - yl else yl
    tile = unpack (slice d9 d0 a2) :: Unsigned 10
    tb = (resize tile `shiftL` fromEnum (cBound c))
         + ((resize (ypos1 `shiftR` 3) `shiftL` fromEnum wl) `shiftL` (if is256 then 1 else 0)) :: Unsigned 14
    rowBase = (resize tb `shiftL` 5) + (resize (ypos1 .&. 7) `shiftL` (if is256 then 3 else 2)) :: Unsigned 19
    w10 = signed10 width
    xoff = if xpos >= 0 then 0 else negate xpos
    xend | xpos < 0 = w10
         | xpos + w10 > 256 = 256 - xpos
         | otherwise = w10
    xoff7 = unpack (resize (pack xoff)) :: Unsigned 7
    xend7 = unpack (resize (pack xend)) :: Unsigned 7
    spr = Spr
      { spX = xpos, spJ = resize (xoff7 `shiftR` 3), spJ1 = resize ((xend7 - 1) `shiftR` 3)
      , spXoff = xoff7, spXend = xend7, spWl = wl, spFlip = flipX, sp256 = is256, spRow = rowBase
      , spHalf = testBit ypos1 0, spExt = is256 && cExtOn c, spPal = slice d15 d12 a2
      , spPrio = unpack (slice d11 d10 a2) }

-- | Byte address to word address in the engine's OBJ VRAM (A 256 KiB, B 128 KiB).
objWordOf :: Bit -> Unsigned 19 -> VAddr
objWordOf eng a = resize ((a .&. (if eng == 0 then 0x3FFFF else 0x1FFFF)) `shiftR` 3)

-- | The request address and descriptor of the sprite's next tile column.
columnOf :: Bit -> Spr -> (VAddr, Desc)
columnOf eng s = (objWordOf eng rowAddr, desc)
  where
    j = spJ s
    w8 = 1 `shiftL` fromEnum (spWl s) :: Unsigned 4
    jj = resize j :: Unsigned 4
    col = if spFlip s then w8 - 1 - jj else jj
    rowAddr = spRow s + (resize col `shiftL` (if sp256 s then 6 else 5))
    j8 = resize j `shiftL` 3 :: Unsigned 7
    xs = max (spXoff s) j8
    xe = min (spXend s) (j8 + 8)
    xs10 = unpack (pack (resize xs :: Unsigned 10)) :: Signed 10
    desc = Desc
      { dsX = unpack (resize (pack (spX s + xs10))), dsLo = resize xs, dsHi = resize (xe - 1)
      , dsFlip = spFlip s, ds256 = sp256 s, dsHalf = spHalf s, dsExt = spExt s
      , dsPal = spPal s, dsPrio = spPrio s }

-- | One sprite pixel as a line-buffer entry: opaque (bit 15), priority
-- (14-13), extended palette (12), palette index (11-0: 4bpp palette number
-- and colour, 8bpp colour, or extended palette number and colour).
objPixel :: Desc -> BitVector 64 -> Unsigned 3 -> (Bool, BitVector 16)
objPixel ds w cur = (opaque, pack opaque ++# pack (dsPrio ds) ++# pack ext ++# idx)
  where
    lx = if dsFlip ds then 7 - cur else cur
    bs = bytesLE w
    c8 = bs !! lx
    b4 = bs !! ((if dsHalf ds then 4 else 0) + (lx `shiftR` 1))
    nib = if testBit lx 0 then slice d7 d4 b4 else slice d3 d0 b4
    ext = ds256 ds && dsExt ds
    (opaque, idx)
      | ds256 ds = (c8 /= 0, (if ext then dsPal ds else 0) ++# c8)
      | otherwise = (nib /= 0, (0 :: BitVector 4) ++# dsPal ds ++# nib)

-- | Index of an engine's half in 'cSemi'.
semiIx :: Bit -> Bit -> Index 4
semiIx e h = fromIntegral (unpack (pack e ++# pack h) :: Unsigned 2)

entryPrio :: BitVector 16 -> Unsigned 2
entryPrio e = unpack (slice d14 d13 e)

------------------------------------------------------------------------------
-- Step

-- | One clock: next state, outputs and RAM ports. @q@ is the RAM data for
-- the addresses driven the cycle before.
tileStep :: St -> TileIn -> RamQ -> (St, TileOut, RamOps)
tileStep (St c d o) inp q = (St c' d' o', out, ops)
  where
    phase = cPhase c
    clearing = case phase of PClear -> True; _ -> False
    idle = case phase of PIdle -> True; _ -> False
    halted = case phase of PHalt -> True; _ -> False
    fetching = case phase of PFetch -> True; _ -> False
    outputting = case phase of POut -> True; _ -> False
    ready = idle || halted
    eng = cEng c

    -- line start: the only cycle the register port is sampled
    LineReq sEng sY sKind = fromMaybe (LineReq 0 0 JBoth) (tiStart inp)
    begin = idle && isJust (tiStart inp)
    sRegs = tiRegs inp
    sSemi = cSemi c !! semiIx sEng (lsb sY)
    -- a JBg job composes a half its JObj job filled: it refuses a
    -- semi-transparent sprite in it when BLDCNT now has a second target
    composeSemi = case sKind of
      JBg -> sSemi && testBit (rDispCnt sRegs) 12 && slice d13 d8 (rBldCnt sRegs) /= 0
      _ -> False
    faults = faultOf sEng sRegs .|. (if composeSemi then bit faultSemiTrans else 0)
    cfg = configOf sEng sY sKind sRegs
    scansKind = case sKind of JBoth -> True; JObj -> True; _ -> False
    lbAddrOf x = unpack (pack eng ++# pack (cHalf c) ++# pack x) :: LbAddr

    -- request port: BG map and row requests, then sprite columns
    n1 = resize (cN c) :: Count
    n2 = n1 `shiftL` 1
    occupied = isJust (oReq o)
    accepted = occupied && tiReqReady inp
    slotFree = not occupied || tiReqReady inp
    mapPhase = cLoaded c < n1
    rowT = resize (cLoaded c - n1) :: Slot
    haveRow = cRdV c && cRdT c == rowT
    bgLoad = fetching && slotFree && cLoaded c < n2 && (mapPhase || haveRow)
    objIss = cLoaded c - n2
    (colAddr, colDesc) = columnOf eng (fromMaybe sprNone (cSpr c))
    objLoad = fetching && slotFree && cLoaded c >= n2 && isJust (cSpr c) && objIss - cWr c < 64
    load = bgLoad || objLoad
    nextReq
      | bgLoad = Req False (if mapPhase then mapAddrOf c (cLoaded c) else rowAddrOf c (qMap q))
      | otherwise = Req True colAddr
    loaded' = cLoaded c + (if load then 1 else 0)
    issued = cLoaded c - (if occupied then 1 else 0)

    -- responses, in request order
    respIn = isJust (tiResp inp)
    respData = fromMaybe 0 (tiResp inp)
    respOk = fetching && cRcv c < issued
    protocolErr = respIn && not respOk && not halted
    take' = respIn && respOk
    isMapResp = cRcv c < n1
    isRowResp = not isMapResp && cRcv c < n2
    rcv' = cRcv c + (if take' then 1 else 0)
    objRcv = if cRcv c >= n2 then cRcv c - n2 else 0   -- sprite responses taken before this cycle

    -- map RAM read port during fetch: present the entry the next row
    -- request needs, once its map response was written in an earlier cycle
    rowT' = resize (loaded' - n1) :: Slot
    rdV' = fetching && loaded' >= n1 && loaded' < n2 && cRcv c > loaded' - n1

    -- OAM scan: the sprite on the read port is skipped, latched or refused
    scanning = fetching && cScanOn c && cScanV c && cScan c < 128 && isNothing (cSpr c)
    (consume, latched, sprFault)
      | not scanning = (False, Nothing, 0)
      | otherwise = case evalSprite c (qOam q) of
          SkipSpr -> (True, Nothing, 0)
          FaultSpr f -> (False, Nothing, f)
          DrawSpr s -> (True, Just s, 0)
    scan' = cScan c + (if consume then 1 else 0)
    semiSpr = isJust latched && slice d11 d10 (qOam q !! (0 :: Int)) == 1
    spr' = case latched of
      Just s -> Just s
      Nothing -> case cSpr c of
        Just s | objLoad -> if spJ s == spJ1 s then Nothing else Just s { spJ = spJ s + 1 }
        other -> other

    -- pixel writer: column cWr's descriptor and row are on the read ports
    writing = fetching && cWrV c
    dsc = qDesc q
    cur = if cPixOn c then cPix c else dsLo dsc
    (wOpaque, wEntry) = objPixel dsc (qObj q) cur
    wx = dsX dsc + resize (cur - dsLo dsc)
    wLast = cur == dsHi dsc
    wr' = cWr c + (if writing && wLast then 1 else 0)
    wrV' = fetching && objRcv > wr'

    -- line-buffer read-modify-write: the candidate read last cycle wins if
    -- the entry is transparent or of lower priority (equal keeps the earlier
    -- sprite); the write of the cycle before is forwarded
    rmwWrite = case dW1 d of
      Just (x, e) ->
        let old = case dLastW d of
              Just (lx, le) | lx == x -> le
              _ -> qLb q
        in if not (testBit old 15) || entryPrio e < entryPrio old then Just (x, e) else Nothing
      Nothing -> Nothing
    w1' = if writing && wOpaque then Just (wx, wEntry) else Nothing

    -- end of the fetch phase: every BG response in, and with OBJ on, the
    -- scan finished, every column written and no write pending
    bgDone = rcv' >= n2
    objDone = not (cScanOn c)
      || (loaded' >= n2 && scan' >= 128 && isNothing spr' && wr' == loaded' - n2 && isNothing w1')
    fetchDone = fetching && bgDone && objDone

    -- output phase: BG RAMs and the line buffer at pixel cOutK (the line
    -- buffer entry is cleared as it is read)
    sx = resize (resize (cScroll c) :: Unsigned 3) + cOutK c :: Unsigned 9
    slot = resize (sx `shiftR` 3) :: Slot
    reading = outputting && cOutK c < 256
    outDone = outputting && not reading && isNothing (dS1 d) && isNothing (dS2 d)

    newFault = (if protocolErr then bit faultProtocol else 0) .|. sprFault
    phase'
      | newFault /= 0 = PHalt
      | otherwise = case phase of
          PClear | cClr c == maxBound -> PIdle
                 | otherwise -> PClear
          PIdle | begin -> if faults /= 0 then PHalt else PFetch
                | otherwise -> PIdle
          PFetch | fetchDone -> case cKind c of JObj -> PIdle; _ -> POut
                 | otherwise -> PFetch
          POut | outDone -> PIdle
               | otherwise -> POut
          PHalt -> PHalt

    -- control register
    c' | begin = cfg { cPhase = phase', cFault = faults
                     , cSemi = if scansKind then replace (semiIx sEng (lsb sY)) False (cSemi c) else cSemi c }
       | otherwise = c
           { cPhase = phase'
           , cLoaded = loaded'
           , cRcv = rcv'
           , cRdT = rowT'
           , cRdV = rdV'
           , cScan = scan'
           , cScanV = fetching
           , cSpr = spr'
           , cWr = wr'
           , cWrV = wrV'
           , cPixOn = writing && not wLast
           , cPix = if writing && not wLast then cur + 1 else 0
           , cOutK = cOutK c + (if reading then 1 else 0)
           , cClr = cClr c + (if clearing then 1 else 0)
           , cSemi = if semiSpr then replace (semiIx eng (cHalf c)) True (cSemi c) else cSemi c
           , cFault = cFault c .|. newFault }

    -- datapath registers
    (bgOpaque, bgIdx) = case dS1 d of
      Just (_, tx) -> decodePixel c tx (qMap q) (qRow q)
      Nothing -> (False, 0)
    -- RAM read data is used only where its read was meant (a block RAM's
    -- output is undefined before its first read)
    out1 = isJust (dS1 d)
    lb = qLb q
    objWins = out1 && cObjOn c && testBit lb 15 && (not bgOpaque || entryPrio lb <= cBgPrio c)
    useExt = objWins && testBit lb 12
    layer | objWins = layerObj
          | bgOpaque = fromIntegral (cBg c)
          | otherwise = layerBackdrop
    palRd | objWins = unpack (pack eng ++# (1 :: BitVector 1) ++# slice d7 d0 lb)
          | otherwise = unpack (pack eng ++# (0 :: BitVector 1) ++# (if bgOpaque then bgIdx else 0))
    d' = Dp
      { dW1 = w1'
      , dLastW = rmwWrite
      , dS1 = if reading && cOut c then Just (resize (cOutK c), resize sx) else Nothing
      , dS2 = case dS1 d of
          Just (x, _) -> Just (x, layer, useExt)
          Nothing -> Nothing }

    -- output registers
    o' = Outs
      { oReq = if halted || newFault /= 0 then Nothing
               else if load then Just nextReq
               else if accepted then Nothing
               else oReq o
      , oPix = case dS2 d of
          Just (x, ly, ext) -> Just (PixelOut x (if ext then qExt q !! eng else qPal q) ly)
          Nothing -> Nothing }

    out = TileOut
      { toReady = ready
      , toReq = oReq o
      , toPixel = oPix o
      , toFault = cFault c }

    oamWr i = case tiOamWr inp of
      Just (a, v) | resize a == (i :: Unsigned 2) ->
        Just (unpack (slice d9 d9 (pack a) ++# slice d8 d2 (pack a)), v)
      _ -> Nothing
    extWr e = case tiExtWr inp of
      Just (a, v) | testBit a 12 == e -> Just (resize a, v)
      _ -> Nothing

    ops = RamOps
      { opMapRd = if outputting then slot else rowT'
      , opMapWr = if take' && isMapResp
                    then Just (resize (cRcv c), halvesLE respData !! mapLaneOf c (cRcv c))
                    else Nothing
      , opRowRd = slot
      , opRowWr = if take' && isRowResp then Just (resize (cRcv c - n1), respData) else Nothing
      , opPalRd = palRd
      , opPalWr = tiPalWr inp
      , opOamRd = unpack (pack eng ++# slice d6 d0 (pack scan'))
      , opOamWr = oamWr 0 :> oamWr 1 :> oamWr 2 :> Nil
      , opLbRd = if outputting then lbAddrOf (resize (cOutK c)) else if writing then lbAddrOf wx else 0
      , opLbWr = if clearing then Just (cClr c, 0)
                 else if reading then Just (lbAddrOf (resize (cOutK c)), 0)
                 else fmap (\(x, e) -> (lbAddrOf x, e)) rmwWrite
      , opDescRd = resize wr'
      , opDescWr = if objLoad then Just (resize objIss, colDesc) else Nothing
      , opObjRd = resize wr'
      , opObjWr = if take' && not isMapResp && not isRowResp then Just (resize objRcv, respData) else Nothing
      , opExtRd = if objWins then unpack (slice d11 d0 lb) else 0
      , opExtDemand = if useExt then Just (unpack (pack eng ++# slice d11 d0 lb)) else Nothing
      , opExtWr = extWr False :> extWr True :> Nil }

-- | A placeholder for the column logic when no sprite is latched (its
-- outputs are not used then).
sprNone :: Spr
sprNone = Spr 0 0 0 0 0 0 False False 0 False False 0 0

------------------------------------------------------------------------------
-- Circuit

-- | The engine with its block RAMs: BG map entries (64 x 16) and tile rows
-- (64 x 64), standard palette (1024 x 16, both engines), OAM attributes 0-2
-- (3 x 256 x 16, both engines), the OBJ line buffer (2 engines x 2 halves x 256 x 16), sprite
-- column descriptors (64 x 24) and rows (64 x 64), and the OBJ extended
-- palettes (2 x 4096 x 16, one per engine: a single 8192-entry RAM's
-- initial-value loop exceeds Quartus 17's 5,000 iterations).
tileHw
  :: forall dom. KnownDomain dom
  => Clock dom -> Reset dom -> Enable dom
  -> Signal dom TileIn -> Signal dom TileOut
tileHw clk rst en inp = out
  where
    (out, ops) = tileHwExtPort clk rst en inp extQ
    extRam i = blockRam clk en (replicate (SNat @4096) 0) (opExtRd <$> ops) ((!! i) . opExtWr <$> ops)
    extQ = bundle (extRam (0 :: Int) :> extRam 1 :> Nil)

-- | Same tile pipeline, without private OBJ extended palette RAM. The
-- caller supplies the previous enabled step's physical palette read and
-- may stall the pipeline (and ALL its internal RAMs) on a missing word.
tileHwExtPort
  :: forall dom. KnownDomain dom
  => Clock dom -> Reset dom -> Enable dom -> Signal dom TileIn
  -> Signal dom (Vec 2 (BitVector 16)) -> (Signal dom TileOut, Signal dom RamOps)
tileHwExtPort clk rst en inp extQ = (out, ops)
  where
    -- control, datapath and output registers built separately (see 'St')
    reg :: NFDataX a => (St -> a) -> Signal dom a
    reg f = register clk rst en (f stInit) (f <$> st')
    st = St <$> reg sC <*> reg sD <*> reg sO
    (st', out, ops) = unbundle (tileStep <$> st <*> inp <*> q)
    q = RamQ <$> mapQ <*> rowQ <*> palQ <*> oamQ <*> lbQ <*> descQ <*> objQ <*> extQ
    mapQ = blockRam clk en (replicate (SNat @64) 0) (opMapRd <$> ops) (opMapWr <$> ops)
    rowQ = blockRam clk en (replicate (SNat @64) 0) (opRowRd <$> ops) (opRowWr <$> ops)
    palQ = blockRam clk en (replicate (SNat @1024) 0) (opPalRd <$> ops) (opPalWr <$> ops)
    oamRam i = blockRam clk en (replicate (SNat @256) 0) (opOamRd <$> ops) ((!! i) . opOamWr <$> ops)
    oamQ = bundle (oamRam (0 :: Int) :> oamRam 1 :> oamRam 2 :> Nil)
    lbQ = blockRam clk en (replicate (SNat @1024) 0) (opLbRd <$> ops) (opLbWr <$> ops)
    descQ = blockRam clk en (replicate (SNat @64) (unpack 0)) (opDescRd <$> ops) (opDescWr <$> ops)
    objQ = blockRam clk en (replicate (SNat @64) 0) (opObjRd <$> ops) (opObjWr <$> ops)

data TopOut = TopOut
  { tReady    :: Bool
  , tReqValid :: Bool
  , tReqObj   :: Bool
  , tReqAddr  :: Unsigned 16
  , tPixValid :: Bool
  , tPixX     :: Unsigned 8
  , tPixColor :: BitVector 16
  , tPixLayer :: BitVector 3
  , tFault    :: BitVector 16
  } deriving (Generic, NFDataX)

-- | Flat ports. BGCNT, HOFS and VOFS pack BG0 in the low bits.
{-# ANN tileHwTopEntity
  (Synthesize
    { t_name = "nds_gpu2d_tilehw"
    , t_inputs =
        [ PortName "CLK", PortName "RST", PortName "EN"
        , PortName "START_VALID", PortName "START_ENGINE", PortName "START_LINE", PortName "START_KIND"
        , PortName "DISPCNT", PortName "BGCNT", PortName "HOFS", PortName "VOFS", PortName "BLDCNT"
        , PortName "REQ_READY", PortName "RESP_VALID", PortName "RESP_DATA"
        , PortName "PAL_WR_VALID", PortName "PAL_WR_ADDR", PortName "PAL_WR_DATA"
        , PortName "OAM_WR_VALID", PortName "OAM_WR_ADDR", PortName "OAM_WR_DATA"
        , PortName "EXT_WR_VALID", PortName "EXT_WR_ADDR", PortName "EXT_WR_DATA" ]
    , t_output = PortProduct ""
        [ PortName "READY", PortName "REQ_VALID", PortName "REQ_OBJ", PortName "REQ_ADDR"
        , PortName "PIX_VALID", PortName "PIX_X", PortName "PIX_COLOR", PortName "PIX_LAYER"
        , PortName "FAULT" ]
    }) #-}
tileHwTopEntity
  :: Clock System -> Reset System -> Enable System
  -> Signal System Bool -> Signal System Bit -> Signal System (Unsigned 8) -> Signal System (BitVector 2)
  -> Signal System (BitVector 32) -> Signal System (BitVector 64)
  -> Signal System (BitVector 36) -> Signal System (BitVector 36) -> Signal System (BitVector 16)
  -> Signal System Bool -> Signal System Bool -> Signal System (BitVector 64)
  -> Signal System Bool -> Signal System (Unsigned 10) -> Signal System (BitVector 16)
  -> Signal System Bool -> Signal System (Unsigned 10) -> Signal System (BitVector 16)
  -> Signal System Bool -> Signal System (Unsigned 13) -> Signal System (BitVector 16)
  -> Signal System TopOut
tileHwTopEntity clk rst en sv se sl sk dc bc hs vs bl rr rv rd pv pa pd ov oa od xv xa xd =
  top <$> tileHw clk rst en inp
  where
    start v e l k = if v then Just (LineReq e l (kindOf k)) else Nothing
    kindOf k = case k of 0 -> JBoth; 1 -> JBg; 2 -> JObj; _ -> JClear
    regs dcv bcv hsv vsv blv = Regs dcv (reverse (unpack bcv)) (map unpack (reverse (unpack hsv)))
                                    (map unpack (reverse (unpack vsv))) blv
    opt v x = if v then Just x else Nothing
    wr v a x = if v then Just (a, x) else Nothing
    inp = TileIn <$> (start <$> sv <*> se <*> sl <*> sk) <*> (regs <$> dc <*> bc <*> hs <*> vs <*> bl)
                 <*> rr <*> (opt <$> rv <*> rd) <*> (wr <$> pv <*> pa <*> pd)
                 <*> (wr <$> ov <*> oa <*> od) <*> (wr <$> xv <*> xa <*> xd)
    top x = TopOut (toReady x) (isJust (toReq x)) (maybe False rqObj (toReq x)) (maybe 0 rqAddr (toReq x))
                   (isJust (toPixel x)) (maybe 0 poX (toPixel x)) (maybe 0 poColor (toPixel x))
                   (maybe 0 poLayer (toPixel x)) (toFault x)
{-# NOINLINE tileHwTopEntity #-}
