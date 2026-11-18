{-# LANGUAGE BinaryLiterals #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

-- | Hardware for the geometry engine ('Nds.Gpu3D.Geometry'): command
-- gathering, the matrix unit, vertex transform, lighting, the position,
-- vector and box tests, the result registers and the swap wait. One clock
-- domain (the chip clock); every step is the model's arithmetic at its exact
-- width, sequenced over a shared datapath:
--
-- * __One multiply unit__: four signed lanes, registered products (lane 0 is
--   34x33 bits, lanes 1-3 are 32x32 keeping the low 44 bits), four 44-bit
--   accumulators behind them. Matrix and vector work issues "scalar x row":
--   one scalar times a 4-wide matrix row, so one cycle adds one term to four
--   result elements. Results are bits [12, 44) (matrix, vertex), [24, 40)
--   (texcoord mode 3), [21, 37) (mode 2), [12, 28) (mode 1), [12, 23)
--   (normal, light vector) and [9, 25) (vector test) of the 44-bit sums.
--   Lighting and the box test's clip products drive the lanes separately.
-- * __One divider__: radix-4 restoring, 64-bit dividend, 32-bit divisor; a
--   step that would only produce zero quotient digits brings down 16 or 8
--   dividend bits at once. It serves @LIGHT_VECTOR@'s @2^18 / den@ and every
--   interpolation of the box test's face clipping (the polygon block's
--   'Nds.Gpu3D.Polygon.Clip' arithmetic, including the fork's widened
--   denominator, which is a shift). A segment interpolates only the
--   components a later pass reads (X, Y, W after Z; X, W after Y; W after
--   the X pass's +W half, whose -W half reduces to "some written vertex has
--   x >= -w").
-- * __Storage__: the current matrices in LUT RAM, one 4-lane RAM per group
--   (projection, clip, texture and both one-slot stacks; position; vector,
--   three lanes), each matrix with two slots so that a product writes the
--   other slot and flips; the gathered parameters and the shininess table as
--   4-bank LUT RAMs; the light registers in LUT RAM; the 31-deep position and
--   vector stacks in two 512x32 block RAMs (the vector stack keeps only
--   columns 0-2, the texture matrix and stack only columns 0-1 are ever read);
--   a 32-row LUT RAM for the box test's corners and two clip buffers; a copy
--   of the clip matrix and the 3x3 vector matrix for the bus read port.
--
-- Interface ('geometryHw'):
--
-- * Command entries ('HwEntry', the front end's FIFO order) on a valid/ready
--   stream. A command of at most one parameter runs at once with its entry's
--   parameter; any other entry is appended to the gathered parameters and the
--   command runs when their number reaches its own parameter count
--   (@ExecParams@, 'Nds.Gpu3D.Chip.gatherEntry'). Ready depends on the state
--   only. While a command runs no entry is taken.
-- * 'HwGeoEvent' on a valid/ready stream (one output register).
-- * @stall@: the polygon pipeline is busy. @BEGIN_VTXS@, @LIGHT_VECTOR@ and
--   @BOX_TEST@ do not start while it is high (melonDS's
--   @StallPolygonPipeline@ callers); nothing else waits for it.
-- * @vblank@: after @SWAP_BUFFERS@ no entry is taken until a VBlank pulse
--   arrives in a cycle after the 'HeSwap' event was transferred (the polygon
--   pipeline sees that event before that pulse).
-- * @ack@: a @GXSTAT@ write with bit 15: clears the stack error and the
--   projection and texture stack pointers in that cycle (after any command
--   bookkeeping of the same cycle).
-- * @zeroDotW@: @ZeroDotWLimit@ as the front end holds it (its 'foZeroDotW'),
--   read into each vertex's 'HwPolyState' when the vertex is emitted.
-- * The result port: a bus address (0x04000620-0x040006A3, as the front end's
--   'foResAddr') to the packed result word 'Nds.Gpu3D.Geometry.geoReadResult'
--   would return, combinationally. Valid while 'gsBusy' is low.
-- * 'GeoStatus': 'gsBusy' is high while a command runs, an event waits or
--   the swap waits for VBlank; 'gsTestBusy' / 'gsStackBusy' while a test /
--   push or pop runs.
--
-- The clip matrix is recomputed (16 issues) at the end of every command that
-- changes the projection or position matrix, so it is never stale outside a
-- command: melonDS recomputes it lazily, but the product of the current
-- matrices is the same whenever it is read, and the DS itself charges the
-- update to the matrix commands. A single-entry command starts in the cycle
-- its entry is taken; a gathered one a cycle later.
--
-- After reset the engine spends 512 cycles writing the power-on contents
-- (identity matrices, zero stacks and tables) into its RAMs.
module Nds.Gpu3D.GeometryHw
  ( GeoHwIn (..)
  , GeoHwOut (..)
  , geometryHw
  , geometryHwState
  , Hw (..)
  , Ctl (..)
  , geometryTopEntity
  , numParams
  , geoOut
  , geoControlIdle
  , geoTransactionIdle
  , eventBits
  , statusBits
  ) where

import Clash.Annotations.TopEntity (PortName (..), TopEntity (..))
import Clash.Explicit.Prelude
import Data.Maybe (isJust, isNothing)
import Data.Word (Word32, Word8)
import GHC.Generics (Generic)

import Nds.Gpu3D.GeometryHw.Event
import Nds.Gpu3D.GxFrontHw (HwEntry (..))
import Nds.Gpu3D.Types (GeoStatus (..))

------------------------------------------------------------------------------
-- Ports

-- | Inputs other than the RAM read data.
data GeoHwIn = GeoHwIn
  { giCmd      :: !(Maybe HwEntry)  -- ^ command entry (valid)
  , giEvReady  :: !Bool             -- ^ the polygon pipeline takes the event
  , giStall    :: !Bool             -- ^ the polygon pipeline is busy
  , giVblank   :: !Bool             -- ^ VBlank pulse
  , giAck      :: !Bool             -- ^ GXSTAT bit-15 acknowledge pulse
  , giZeroDotW :: !Word32           -- ^ @ZeroDotWLimit@
  } deriving (Eq, Show, Generic, NFDataX)

-- | Everything the block drives (the result word comes separately).
data GeoHwOut = GeoHwOut
  { goCmdReady :: !Bool
  , goEvent    :: !(Maybe HwGeoEvent)
  , goStatus   :: !GeoStatus
  , goSwapWait :: !Bool              -- ^ @SWAP_BUFFERS@ waits for VBlank
  }

------------------------------------------------------------------------------
-- Types

type S32 = Signed 32
type Row = Vec 4 S32

-- | A matrix with its own slots.
data Tgt = TProj | TPos | TVec | TTex
  deriving (Eq, Show, Generic, NFDataX)

-- | The "scalar x row" programs.
data Prog
  = PgClip            -- ^ clip = pos * proj
  | PgMat !Tgt        -- ^ IDENTITY / LOAD / MULT / SCALE / TRANS on one matrix
  | PgVtx             -- ^ vertex transform
  | PgPosT            -- ^ position test transform
  | PgCorner          -- ^ the eight box corners
  | PgTex3            -- ^ texcoord mode 3 (vertex source)
  | PgTex1            -- ^ texcoord mode 1 (TEXCOORD source)
  | PgTex2            -- ^ texcoord mode 2 (NORMAL source)
  | PgNormT           -- ^ normal times the vector matrix
  | PgLVec            -- ^ light direction times the vector matrix
  | PgVecT            -- ^ vector test
  | PgPush !Bool      -- ^ projection (False) / texture (True) matrix to its stack
  | PgPop !Bool       -- ^ stack to projection / texture matrix
  deriving (Eq, Show, Generic, NFDataX)

data RamSel = RM1 | RM2 | RM3
  deriving (Eq, Show, Generic, NFDataX)

-- | Where a finished accumulation goes.
data Dest
  = DRow !RamSel !(Unsigned 5) !(Maybe (Unsigned 3))  -- ^ matrix row (+ result-copy row)
  | DVPos | DPosT | DCorner !(Unsigned 3)
  | DTex3 | DTex1 | DTex2 | DNormT | DLVec | DVecT
  deriving (Eq, Show, Generic, NFDataX)

-- | What the second stage does with the registered products.
data ATag
  = ANone
  | AMac !Bool !(Maybe Dest)   -- ^ accumulate (first term resets); deliver after the last
  | ALt !(Unsigned 4)          -- ^ lighting step
  | ASeg                       -- ^ box-test interpolation product to the divider
  deriving (Eq, Show, Generic, NFDataX)

-- | One cycle's multiplier operands.
data Issue = Issue
  { isA0  :: !(Signed 34)
  , isB0  :: !(Signed 33)
  , isA   :: !(Vec 3 S32)
  , isB   :: !(Vec 3 S32)
  , isTag :: !ATag
  }

data BoxCtl = BxStart | BxV | BxP | BxN | BxSegF | BxSegMul | BxSegWait | BxSegWrite
  deriving (Eq, Show, Generic, NFDataX)

-- | The controller.
data Ctl
  = CInit !(Unsigned 9)                    -- ^ power-on RAM contents
  | CIdle                                  -- ^ waiting for an entry
  | CStart                                 -- ^ first cycle of a gathered command
  | CProg !Prog !(Unsigned 3) !(Unsigned 2) -- ^ program, row, term
  | CStackW !(Unsigned 4)                  -- ^ position/vector matrix to the stacks
  | CStackR !(Unsigned 5)                  -- ^ stacks to the position/vector matrix
  | CShine !(Unsigned 3)                   -- ^ SHININESS copy
  | CLight !(Unsigned 2) !(Unsigned 4)     -- ^ light, step
  | CColour                                -- ^ lit colour clamp
  | CDiv                                   -- ^ LIGHT_VECTOR reciprocal
  | CBox !BoxCtl                           -- ^ box-test face clipping
  | CEmit                                  -- ^ vertex event
  deriving (Eq, Show, Generic, NFDataX)

-- | Radix-4 divider: 'dvWork' holds the dividend bits not yet brought down,
-- MSB first; 'dvQuo' the low 32 quotient bits. A step brings down 16 or 8
-- bits at once when they leave the partial remainder below the divisor
-- (all those quotient digits are 0), else one radix-4 digit.
data DivSt = DivSt
  { dvRem    :: !(Unsigned 32)
  , dvWork   :: !(Unsigned 64)
  , dvDigits :: !(Unsigned 6)
  , dvQuo    :: !(Unsigned 32)
  , dvDen    :: !(Unsigned 32)
  , dvDen3   :: !(Unsigned 34)
  , dvBusy   :: !Bool
  , dvValid  :: !Bool
  , dvNeg    :: !Bool
  } deriving (Eq, Show, Generic, NFDataX)

-- | Box-test face clipping.
data BoxSt = BoxSt
  { bxFace   :: !(Unsigned 3)
  , bxComp   :: !(Unsigned 2)    -- ^ 2 Z, 1 Y, 0 X
  , bxNeg    :: !Bool            -- ^ the -W half of the pass
  , bxI      :: !(Unsigned 4)
  , bxN      :: !(Unsigned 4)
  , bxC      :: !(Unsigned 4)
  , bxNext   :: !Bool            -- ^ the segment is towards the next neighbour
  , bxK      :: !(Unsigned 2)    -- ^ component being interpolated
  , bxV      :: !Row             -- ^ outside vertex
  , bxO      :: !Row             -- ^ inside neighbour
  , bxR      :: !Row             -- ^ interpolated vertex
  , bxNumMag :: !(Unsigned 33)
  , bxDenMag :: !(Unsigned 32)
  , bxNumNeg :: !Bool
  , bxDenNeg :: !Bool
  , bxWide   :: !Bool
  , bxQNeg   :: !Bool
  } deriving (Eq, Show, Generic, NFDataX)

-- | @Viewport[0..5]@.
data Vp = Vp
  { vpX0, vpY0, vpX1, vpY1 :: !(Unsigned 8)
  , vpW :: !(Unsigned 9)
  , vpH :: !(Unsigned 8)
  } deriving (Eq, Show, Generic, NFDataX)

-- | One light's direction and specular reciprocal.
data LDir = LDir
  { ldDir   :: !(Vec 3 (Signed 11))
  , ldRecip :: !(Signed 20)
  } deriving (Eq, Show, Generic, NFDataX)

-- | The registers.
data Hw = Hw
  { hCtl      :: !Ctl
  , hCmd      :: !(BitVector 8)
  , hP0       :: !(BitVector 32)
  , hCount    :: !(Unsigned 6)            -- ^ @ExecParamCount@
  , hSlot     :: !(Unsigned 5)            -- ^ position/vector stack slot in use
  , hMode     :: !(Unsigned 2)
  , hPtr      :: !(Vec 4 Bool)            -- ^ current slot of proj, pos, vec, tex
  , hProjSP   :: !Bool
  , hTexSP    :: !Bool
  , hPosSP    :: !(Unsigned 6)
  , hErr      :: !Bool
  , hBoxRes   :: !Bool
  , hSwap     :: !Bool
  , hCurV     :: !(Vec 3 (Signed 16))
  , hColor    :: !(Vec 3 (Unsigned 5))
  , hTex      :: !(Vec 2 (Signed 16))
  , hRaw      :: !(Vec 2 (Signed 16))
  , hDif      :: !(Vec 3 (Unsigned 5))
  , hAmb      :: !(Vec 3 (Unsigned 5))
  , hSpe      :: !(Vec 3 (Unsigned 5))
  , hEmi      :: !(Vec 3 (Unsigned 5))
  , hUseShine :: !Bool
  , hPolyAttr :: !(BitVector 32)
  , hCurAttr  :: !(BitVector 32)
  , hTexParam :: !(BitVector 32)
  , hTexPal   :: !(BitVector 13)
  , hVp       :: !Vp
  , hPosTest  :: !Row
  , hVecTest  :: !(Vec 3 (Signed 16))
  , hVPos     :: !Row
  , hVTex     :: !(Vec 2 (Signed 16))
  , hTag      :: !ATag
  , hP        :: !(Signed 64)
  , hPs       :: !(Vec 3 (Signed 44))
  , hAcc      :: !(Vec 4 (Signed 44))
  , hNt       :: !(Vec 3 (Signed 11))
  , hLDot     :: !(Signed 16)
  , hLMdlc    :: !(Vec 3 (Unsigned 10))
  , hLD2      :: !(Unsigned 10)
  , hLDiff    :: !(Vec 3 (Unsigned 20))
  , hLShine   :: !(Unsigned 10)
  , hLMslc    :: !(Vec 3 (Unsigned 10))   -- ^ specular x light colour
  , hLMalc    :: !(Vec 3 (Unsigned 10))   -- ^ ambient x light colour
  , hLBuf     :: !(Vec 3 (Unsigned 24))
  , hLDir     :: !(Vec 3 (Signed 11))
  , hTexR2    :: !(Vec 2 S32)             -- ^ texture matrix row 2, columns 0-1
  , hTexBias  :: !(Vec 2 S32)             -- ^ rows 2 + 3, columns 0-1
  , hDiv      :: !DivSt
  , hBx       :: !BoxSt
  , hOut      :: !(Maybe HwGeoEvent)
  } deriving (Eq, Show, Generic, NFDataX)

hwInit :: Hw
hwInit = Hw
  { hCtl = CInit 0, hCmd = 0, hP0 = 0, hCount = 0, hSlot = 0, hMode = 0
  , hPtr = repeat False, hProjSP = False, hTexSP = False, hPosSP = 0
  , hErr = False, hBoxRes = False, hSwap = False
  , hCurV = repeat 0, hColor = repeat 0, hTex = repeat 0, hRaw = repeat 0
  , hDif = repeat 0, hAmb = repeat 0, hSpe = repeat 0, hEmi = repeat 0, hUseShine = False
  , hPolyAttr = 0, hCurAttr = 0, hTexParam = 0, hTexPal = 0, hVp = Vp 0 0 0 0 0 0
  , hPosTest = repeat 0, hVecTest = repeat 0, hVPos = repeat 0, hVTex = repeat 0
  , hTag = ANone, hP = 0, hPs = repeat 0, hAcc = repeat 0
  , hNt = repeat 0, hLDot = 0, hLMdlc = repeat 0, hLD2 = 0, hLDiff = repeat 0
  , hLShine = 0, hLMslc = repeat 0, hLMalc = repeat 0, hLBuf = repeat 0, hLDir = repeat 0, hTexR2 = repeat 0, hTexBias = repeat 0
  , hDiv = DivSt 0 0 0 0 0 0 False False False
  , hBx = BoxSt 0 2 False 0 4 0 False 0 (repeat 0) (repeat 0) (repeat 0) 0 0 False False False False
  , hOut = Nothing
  }

-- | RAM read data (asynchronous LUT RAMs, the stacks one cycle after their
-- address).
data Rd = Rd
  { rdPR :: Vec 4 S32          -- ^ parameter banks
  , rdM1 :: Row                -- ^ proj / clip / tex / stacks
  , rdM2 :: Row                -- ^ pos
  , rdM3 :: Vec 3 S32          -- ^ vec
  , rdSH :: Vec 4 S32          -- ^ shininess words
  , rdLD :: LDir
  , rdLC :: Vec 3 (Unsigned 5)
  , rdCB :: Row                -- ^ box corners and clip buffers
  , rdPS :: S32                -- ^ position stack
  , rdVS :: S32                -- ^ vector stack
  }

-- | RAM read addresses: a function of the registers only.
data Ad = Ad
  { adPR  :: !(Vec 4 (Unsigned 3))
  , adM1  :: !(Unsigned 5)
  , adM2  :: !(Unsigned 3)
  , adM3  :: !(Unsigned 3)
  , adSH  :: !(Unsigned 3)
  , adL   :: !(Unsigned 2)
  , adCB  :: !(Unsigned 5)
  , adStk :: !(Unsigned 9)
  }

type LaneW n a = Maybe (a, Vec n (Maybe S32))

-- | RAM writes.
data Wr = Wr
  { wPR :: !(Maybe (Unsigned 2, Unsigned 3, S32))
  , wM1 :: !(LaneW 4 (Unsigned 5))
  , wM2 :: !(LaneW 4 (Unsigned 3))
  , wM3 :: !(LaneW 3 (Unsigned 3))
  , wRR :: !(LaneW 4 (Unsigned 3))
  , wSH :: !(LaneW 4 (Unsigned 3))
  , wLD :: !(Maybe (Unsigned 2, LDir))
  , wLC :: !(Maybe (Unsigned 2, Vec 3 (Unsigned 5)))
  , wCB :: !(Maybe (Unsigned 5, Row))
  , wPS :: !(Maybe (Unsigned 9, S32))
  , wVS :: !(Maybe (Unsigned 9, S32))
  }

noW :: Wr
noW = Wr Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing

-- | Writes of two sources that never write the same RAM in one cycle.
mergeW :: Wr -> Wr -> Wr
mergeW a b = Wr
  { wPR = wPR a `orElse` wPR b, wM1 = wM1 a `orElse` wM1 b, wM2 = wM2 a `orElse` wM2 b
  , wM3 = wM3 a `orElse` wM3 b, wRR = wRR a `orElse` wRR b, wSH = wSH a `orElse` wSH b
  , wLD = wLD a `orElse` wLD b, wLC = wLC a `orElse` wLC b, wCB = wCB a `orElse` wCB b
  , wPS = wPS a `orElse` wPS b, wVS = wVS a `orElse` wVS b }
  where
    orElse :: Maybe x -> Maybe x -> Maybe x
    orElse (Just x) _ = Just x
    orElse Nothing y = y

allLanes :: KnownNat n => Vec n S32 -> Vec n (Maybe S32)
allLanes = map Just

------------------------------------------------------------------------------
-- Field helpers

lo16, hi16 :: BitVector 32 -> Signed 16
lo16 p = unpack (truncateB p)
hi16 p = unpack (truncateB (p `shiftR` 16))

-- | The three 10-bit signed fields of a NORMAL, LIGHT_VECTOR, VEC_TEST or
-- VTX_DIFF word.
sext10 :: BitVector 32 -> Vec 3 (Signed 10)
sext10 p = unpack (truncateB p) :> unpack (truncateB (p `shiftR` 10))
             :> unpack (truncateB (p `shiftR` 20)) :> Nil

-- | The three 5-bit colour fields starting at bit @sh@.
rgb5 :: Int -> BitVector 32 -> Vec 3 (Unsigned 5)
rgb5 sh p = unpack (truncateB (p `shiftR` sh)) :> unpack (truncateB (p `shiftR` (sh + 5)))
              :> unpack (truncateB (p `shiftR` (sh + 10))) :> Nil

u2s :: KnownNat n => Unsigned n -> S32
u2s u = unpack (resize (pack u))

s2s :: KnownNat n => Signed n -> S32
s2s = resize

hi12 :: Signed 44 -> S32
hi12 s = truncateB (s `shiftR` 12)

-- | Low bits of a non-negative (or two's-complement wrapped) value.
lowU :: forall n. KnownNat n => Signed 44 -> Unsigned n
lowU s = unpack (resize (pack s))

texMode :: Hw -> BitVector 2
texMode h = truncateB (hTexParam h `shiftR` 30)

identRow :: Unsigned 2 -> Row
identRow r = map (\c -> if c == r then 0x1000 else 0) (0 :> 1 :> 2 :> 3 :> Nil)

-- | @CmdNumParams@ (only whether a command has two or more matters).
numParams :: BitVector 8 -> Unsigned 6
numParams c = case c of
  0x16 -> 16
  0x17 -> 12
  0x18 -> 16
  0x19 -> 12
  0x1A -> 9
  0x1B -> 3
  0x1C -> 3
  0x23 -> 2
  0x34 -> 32
  0x70 -> 3
  0x71 -> 2
  _ -> 1

-- | Single-parameter commands that need more than the accept cycle.
execSingle :: BitVector 8 -> Bool
execSingle c = c == 0x11 || c == 0x12 || c == 0x13 || c == 0x14 || c == 0x15 || c == 0x21
  || (c >= 0x24 && c <= 0x28) || c == 0x32 || c == 0x40 || c == 0x41 || c == 0x50 || c == 0x72

------------------------------------------------------------------------------
-- Matrix slots

tgtIx :: Tgt -> Unsigned 2
tgtIx t = case t of
  TProj -> 0
  TPos -> 1
  TVec -> 2
  TTex -> 3

tgtRam :: Tgt -> RamSel
tgtRam t = case t of
  TPos -> RM2
  TVec -> RM3
  _ -> RM1

slotOf :: Hw -> Tgt -> Bool
slotOf h t = hPtr h !! tgtIx t

-- | Row address of slot @s@: proj 0-7, tex 16-23 (RAM 1); pos, vec 0-7.
rowAddr :: Tgt -> Bool -> Unsigned 2 -> Unsigned 5
rowAddr t s r = base + (if s then 4 else 0) + resize r
  where
    base = case t of
      TTex -> 16
      _ -> 0

curRow, othRow :: Hw -> Tgt -> Unsigned 2 -> Unsigned 5
curRow h t = rowAddr t (slotOf h t)
othRow h t = rowAddr t (not (slotOf h t))

flipPtr :: Tgt -> Hw -> Hw
flipPtr t h = h { hPtr = replace (tgtIx t) (not (slotOf h t)) (hPtr h) }

clipRow, projStackRow, texStackRow :: Unsigned 2 -> Unsigned 5
clipRow r = 12 + resize r
projStackRow r = 8 + resize r
texStackRow r = 24 + resize r

tgtOfMode :: Unsigned 2 -> Tgt
tgtOfMode m = case m of
  0 -> TProj
  3 -> TTex
  _ -> TPos

------------------------------------------------------------------------------
-- Programs

progLastRow :: Prog -> Unsigned 3
progLastRow pg = case pg of
  PgClip -> 3
  PgMat _ -> 3
  PgCorner -> 7
  PgPush _ -> 3
  PgPop _ -> 3
  _ -> 0

progLastTerm :: BitVector 8 -> Prog -> Unsigned 3 -> Unsigned 2
progLastTerm op pg r = case pg of
  PgMat _ -> case op of
    0x18 -> 3
    0x19 -> if r < 3 then 2 else 3
    0x1A -> if r < 3 then 2 else 0
    0x1C -> if r < 3 then 0 else 3
    _ -> 0
  PgTex3 -> 2
  PgTex1 -> 1
  PgTex2 -> 2
  PgNormT -> 2
  PgLVec -> 2
  PgVecT -> 2
  PgPush _ -> 0
  PgPop _ -> 0
  _ -> 3

-- | The parameter index a matrix program's scalar reads (when it reads one).
matParamIx :: BitVector 8 -> Unsigned 3 -> Unsigned 2 -> Unsigned 5
matParamIx op r j = case op of
  0x18 -> 4 * r5 + j5
  0x19 -> if r < 3 then 3 * r5 + j5 else 9 + j5
  0x1A -> 3 * r5 + j5
  0x1B -> r5
  _ -> j5   -- 0x1C
  where
    r5 = resize r :: Unsigned 5
    j5 = resize j :: Unsigned 5

-- | The scalar is the constant 0x1000.
matConstScalar :: BitVector 8 -> Unsigned 3 -> Unsigned 2 -> Bool
matConstScalar op r j = case op of
  0x18 -> False
  0x19 -> r == 3 && j == 3
  0x1A -> r == 3
  0x1B -> r == 3
  0x1C -> r < 3 || j == 3
  _ -> True   -- IDENTITY, LOAD

-- | The source matrix row a term multiplies.
matSrcRow :: BitVector 8 -> Unsigned 3 -> Unsigned 2 -> Unsigned 2
matSrcRow op r j
  | op == 0x1B = truncateB r
  | op == 0x1C && r < 3 = truncateB r
  | op == 0x1A && r == 3 = 3
  | otherwise = j

-- | Per-bank parameter read addresses of a matrix program term.
matPRAddr :: BitVector 8 -> Unsigned 3 -> Unsigned 2 -> Vec 4 (Unsigned 3)
matPRAddr op r j = case op of
  0x16 -> repeat (resize r)
  0x17 -> map (\b -> let c = (b - 3 * resize r) :: Unsigned 2
                     in truncateB ((3 * resize r + resize c :: Unsigned 5) `shiftR` 2))
              (0 :> 1 :> 2 :> 3 :> Nil)
  _ -> repeat (truncateB (matParamIx op r j `shiftR` 2))

-- | The parameter word @i@ from the bank read data.
param :: Rd -> Unsigned 5 -> S32
param rd i = rdPR rd !! (truncateB i :: Unsigned 2)

tgtRead :: Rd -> Tgt -> Row
tgtRead rd t = case t of
  TPos -> rdM2 rd
  TVec -> rdM3 rd ++ (0 :> Nil)
  _ -> rdM1 rd

-- | Corner @r@ of a box test, component @j@ (melonDS @cube[r]@).
cornerCoord :: Rd -> Unsigned 3 -> Unsigned 2 -> Signed 16
cornerCoord rd r j =
  let p0 = pack (param rd 0); p1 = pack (param rd 1); p2 = pack (param rd 2)
      x0 = lo16 p0; y0 = hi16 p0; z0 = lo16 p1
      x1 = hi16 p1 + x0; y1 = lo16 p2 + y0; z1 = hi16 p2 + z0
      xs = (0 :> 1 :> 1 :> 0 :> 0 :> 0 :> 1 :> 1 :> Nil) :: Vec 8 Bit
      ys = (0 :> 0 :> 1 :> 1 :> 1 :> 0 :> 0 :> 1 :> Nil) :: Vec 8 Bit
      zs = (0 :> 0 :> 0 :> 0 :> 1 :> 1 :> 1 :> 1 :> Nil) :: Vec 8 Bit
      pick sel a b = if sel !! r == 1 then b else a
  in case j of
       0 -> pick xs x0 x1
       1 -> pick ys y0 y1
       _ -> pick zs z0 z1

normalScalar :: Hw -> Unsigned 2 -> S32
normalScalar h j = s2s (sext10 (hP0 h) !! j)

progAddr :: Hw -> Prog -> Unsigned 3 -> Unsigned 2 -> Ad -> Ad
progAddr h pg r j base = case pg of
  PgClip -> base { adM1 = curRow h TProj j, adM2 = truncateB (curRow h TPos (truncateB r)) }
  PgMat t ->
    let a = curRow h t (matSrcRow (hCmd h) r j)
        b1 = base { adPR = matPRAddr (hCmd h) r j }
    in case t of
         TPos -> b1 { adM2 = truncateB a }
         TVec -> b1 { adM3 = truncateB a }
         _ -> b1 { adM1 = a }
  PgVtx -> base { adM1 = clipRow j }
  PgPosT -> base { adM1 = clipRow j }
  PgCorner -> base { adM1 = clipRow j, adPR = repeat 0 }
  PgTex3 -> base { adM1 = curRow h TTex j }
  PgTex1 -> base { adM1 = curRow h TTex j }
  PgTex2 -> base { adM1 = curRow h TTex j }
  PgNormT -> base { adM3 = truncateB (curRow h TVec j) }
  PgLVec -> base { adM3 = truncateB (curRow h TVec j) }
  PgVecT -> base { adM3 = truncateB (curRow h TVec j) }
  PgPush t -> base { adM1 = curRow h (if t then TTex else TProj) (truncateB r) }
  PgPop t -> base { adM1 = (if t then texStackRow else projStackRow) (truncateB r) }

-- | Scalar and row of one program term.
progTerm :: Hw -> Rd -> Prog -> Unsigned 3 -> Unsigned 2 -> (S32, Row)
progTerm h rd pg r j = case pg of
  PgClip -> (rdM2 rd !! j, rdM1 rd)
  PgMat t ->
    let op = hCmd h
        sc = if matConstScalar op r j then 0x1000 else param rd (matParamIx op r j)
        row3 = map (\c -> if c == 3 then (if r == 3 then 0x1000 else 0)
                          else param rd (3 * resize r + resize c))
                   (0 :> 1 :> 2 :> 3 :> Nil :: Vec 4 (Unsigned 2))
        row = case op of
          0x15 -> identRow (truncateB r)
          0x16 -> rdPR rd
          0x17 -> row3
          _ -> tgtRead rd t
    in (sc, row)
  PgVtx -> (vtxScalar, rdM1 rd)
  PgPosT -> (vtxScalar, rdM1 rd)
  PgCorner -> (if j == 3 then 0x1000 else s2s (cornerCoord rd r j), rdM1 rd)
  PgTex3 -> (s2s (hCurV h !! j), rdM1 rd)
  PgTex1 -> (case j of
               0 -> s2s (hRaw h !! (0 :: Int))
               1 -> s2s (hRaw h !! (1 :: Int))
               _ -> 1, rdM1 rd)
  PgTex2 -> (normalScalar h j, rdM1 rd)
  PgNormT -> (normalScalar h j, tgtRead rd TVec)
  PgLVec -> (normalScalar h j, tgtRead rd TVec)
  PgVecT -> (normalScalar h j, tgtRead rd TVec)
  PgPush _ -> (0x1000, rdM1 rd)
  PgPop _ -> (0x1000, rdM1 rd)
  where
    vtxScalar = if j == 3 then 0x1000 else s2s (hCurV h !! j)

progDest :: Hw -> Prog -> Unsigned 3 -> Dest
progDest h pg r = case pg of
  PgClip -> DRow RM1 (clipRow r2) (Just r)
  PgMat t -> DRow (tgtRam t) (othRow h t r2)
               (if t == TVec && r < 3 then Just (4 + r) else Nothing)
  PgVtx -> DVPos
  PgPosT -> DPosT
  PgCorner -> DCorner r
  PgTex3 -> DTex3
  PgTex1 -> DTex1
  PgTex2 -> DTex2
  PgNormT -> DNormT
  PgLVec -> DLVec
  PgVecT -> DVecT
  PgPush t -> DRow RM1 ((if t then texStackRow else projStackRow) r2) Nothing
  PgPop t -> DRow RM1 (othRow h (if t then TTex else TProj) r2) Nothing
  where
    r2 = truncateB r :: Unsigned 2

-- | First enabled light at or after @l@ (attribute bits 0-3).
lightFrom :: BitVector 32 -> Unsigned 3 -> Maybe (Unsigned 2)
lightFrom attr l
  | l <= 0 && testBit attr 0 = Just 0
  | l <= 1 && testBit attr 1 = Just 1
  | l <= 2 && testBit attr 2 = Just 2
  | l <= 3 && testBit attr 3 = Just 3
  | otherwise = Nothing

-- | State after a program's last issue.
afterProg :: Hw -> Prog -> Hw
afterProg h pg = case pg of
  PgMat t ->
    let h' = flipPtr t h
    in if t == TPos && hMode h == 2 && hCmd h /= 0x1B
         then h' { hCtl = CProg (PgMat TVec) 0 0 }
         else if t == TTex then h' { hCtl = CIdle }
         else h' { hCtl = CProg PgClip 0 0 }
  PgVtx -> h { hCtl = if texMode h == 3 then CProg PgTex3 0 0 else CEmit }
  PgTex3 -> h { hCtl = CEmit }
  PgCorner -> h { hCtl = CBox BxStart }
  PgTex2 -> h { hCtl = CProg PgNormT 0 0 }
  PgNormT -> h { hCtl = maybe CColour (\l -> CLight l 0) (lightFrom (hCurAttr h) 0) }
  PgLVec -> h { hCtl = CDiv }
  PgPop t -> (flipPtr (if t then TTex else TProj) h) { hCtl = if t then CIdle else CProg PgClip 0 0 }
  _ -> h { hCtl = CIdle }

------------------------------------------------------------------------------
-- Lighting operands

lightDot :: Hw -> Bool
lightDot h = hLDot h > 0

-- | @shinelevel@ before the table, from the registered @d2 * SpecRecip@.
shine0Of :: Hw -> Unsigned 10
shine0Of h =
  let s = truncateB (hP h `shiftR` 8) - 512 :: S32
      e = truncateB s :: Signed 14
  in if not (lightDot h) || s < 0 || e < 0 then 0
     else if e > 0x1FF then 0x1FF else unpack (resize (pack e))

-- | Shininess-table byte index of the registered product.
shineIx :: Hw -> Unsigned 7
shineIx h = truncateB (shine0Of h `shiftR` 2)

lightIssue :: Hw -> Rd -> Unsigned 4 -> Maybe Issue
lightIssue h rd s = case s of
  0 -> lanes (pr (l !! i0) (nt !! i0)) (pr (l !! i1) (nt !! i1)) (pr (l !! i2) (nt !! i2))
             (pu (hDif h !! i0) (lc !! i0))
  1 -> lanes (pu (hSpe h !! i0) (lc !! i0)) (pu (hDif h !! i1) (lc !! i1))
             (pu (hDif h !! i2) (lc !! i2)) (pu (hSpe h !! i1) (lc !! i1))
  2 -> lanes (pr d1 d1) (pu (hAmb h !! i0) (lc !! i0)) (pu (hAmb h !! i1) (lc !! i1))
             (pm (hLMdlc h !! i0))
  3 -> lanes (pu (hSpe h !! i2) (lc !! i2)) (pu (hAmb h !! i2) (lc !! i2))
             (pm (hLMdlc h !! i1)) (pm (hLMdlc h !! i2))
  4 -> lanes (u2s (hLD2 h), s2s (ldRecip (rdLD rd))) z z z
  6 -> lanes (sh (hLMslc h !! i0)) (sh (hLMslc h !! i1)) (sh (hLMslc h !! i2)) z
  _ -> Nothing
  where
    i0 = 0 :: Int
    i1 = 1 :: Int
    i2 = 2 :: Int
    l = ldDir (rdLD rd)
    lc = rdLC rd
    nt = hNt h
    z = (0, 0)
    pr a b = (s2s a, s2s b)
    pu a b = (u2s a, u2s b)
    diffdot = truncateB (hLDot h) :: Signed 11
    d1 = truncateB (hLDot h + resize (nt !! i2)) :: Signed 11
    pm m = (u2s m, s2s diffdot)
    sh m = (u2s m, u2s (hLShine h))
    lanes (a0, b0) (a1, b1) (a2, b2) (a3, b3) =
      Just (Issue (resize a0) (resize b0) (a1 :> a2 :> a3 :> Nil) (b1 :> b2 :> b3 :> Nil) (ALt s))

------------------------------------------------------------------------------
-- Second stage: consume the registered products

-- | The four lane products as 44-bit values.
prods :: Hw -> Vec 4 (Signed 44)
prods h = truncateB (hP h) :> hPs h

-- | Whether the second stage starts the divider this cycle.
startsDiv :: ATag -> Bool
startsDiv t = case t of
  AMac _ (Just DLVec) -> True
  ASeg -> True
  _ -> False

divStart :: Unsigned 64 -> Unsigned 6 -> Unsigned 32 -> Bool -> DivSt
divStart work nd den neg = DivSt
  { dvRem = 0, dvWork = work, dvDigits = nd, dvQuo = 0, dvDen = den
  , dvDen3 = resize den + (resize den `shiftL` 1), dvBusy = True, dvValid = False, dvNeg = neg }

divDone :: Unsigned 32 -> DivSt
divDone q = DivSt 0 0 0 q 0 0 False True False

divStep :: DivSt -> DivSt
divStep d
  | not (dvBusy d) = d
  | otherwise =
      let top16 = truncateB (dvWork d `shiftR` 48) :: Unsigned 16
          x48 = (resize (dvRem d) `shiftL` 16) .|. resize top16 :: Unsigned 48
          skip = dvDigits d >= 8 && x48 < resize (dvDen d)
          top8 = truncateB (dvWork d `shiftR` 56) :: Unsigned 8
          x40 = (resize (dvRem d) `shiftL` 8) .|. resize top8 :: Unsigned 40
          skip8 = dvDigits d >= 4 && x40 < resize (dvDen d)
          top2 = truncateB (dvWork d `shiftR` 62) :: Unsigned 2
          x = (resize (dvRem d) `shiftL` 2) .|. resize top2 :: Unsigned 34
          dn1 = resize (dvDen d) :: Unsigned 34
          dn2 = dn1 `shiftL` 1
          (q, r) | x >= dvDen3 d = (3, x - dvDen3 d)
                 | x >= dn2 = (2, x - dn2)
                 | x >= dn1 = (1, x - dn1)
                 | otherwise = (0 :: Unsigned 2, x)
          digits' | skip = dvDigits d - 8
                  | skip8 = dvDigits d - 4
                  | otherwise = dvDigits d - 1
          d' | skip = d { dvRem = truncateB x48, dvWork = dvWork d `shiftL` 16
                        , dvQuo = dvQuo d `shiftL` 16, dvDigits = digits' }
             | skip8 = d { dvRem = truncateB x40, dvWork = dvWork d `shiftL` 8
                         , dvQuo = dvQuo d `shiftL` 8, dvDigits = digits' }
             | otherwise = d { dvRem = truncateB r, dvWork = dvWork d `shiftL` 2
                             , dvQuo = (dvQuo d `shiftL` 2) .|. resize q, dvDigits = digits' }
      in if digits' == 0 then d' { dvBusy = False, dvValid = True } else d'

aStage :: Hw -> Rd -> (Hw, Wr)
aStage h rd = case hTag h of
  ANone -> (h, noW)
  AMac first md ->
    let sums = zipWith (\a p -> (if first then 0 else a) + p) (hAcc h) (prods h)
        h1 = h { hAcc = sums }
    in maybe (h1, noW) (\d -> deliver d sums h1) md
  ALt k -> (lightA k, noW)
  ASeg ->
    let prod = unpack (pack (hP h)) :: Unsigned 64
        b = hBx h
    in ( h { hDiv = if bxWide b then divDone (truncateB (prod `shiftR` 32))
                    else divStart prod 32 (bxDenMag b) False }
       , noW )
  where
    ps = prods h
    lit = lightDot h
    lightA k = case k of
      0 -> h { hLDot = sum (map (\p -> truncateB (p `shiftR` 9)) (take d3 ps))
             , hLMdlc = replace (0 :: Int) (lowU (ps !! (3 :: Int))) (hLMdlc h) }
      1 -> h { hLMdlc = (hLMdlc h !! (0 :: Int)) :> lowU (ps !! (1 :: Int)) :> lowU (ps !! (2 :: Int)) :> Nil
             , hLMslc = lowU (ps !! (0 :: Int)) :> lowU (ps !! (3 :: Int)) :> (hLMslc h !! (2 :: Int)) :> Nil }
      2 -> h { hLD2 = lowU (ps !! (0 :: Int) `shiftR` 10)
             , hLMalc = lowU (ps !! (1 :: Int)) :> lowU (ps !! (2 :: Int)) :> (hLMalc h !! (2 :: Int)) :> Nil
             , hLDiff = replace (0 :: Int) (difOf (ps !! (3 :: Int))) (hLDiff h) }
      3 -> h { hLMslc = replace (2 :: Int) (lowU (ps !! (0 :: Int))) (hLMslc h)
             , hLMalc = replace (2 :: Int) (lowU (ps !! (1 :: Int))) (hLMalc h)
             , hLDiff = (hLDiff h !! (0 :: Int)) :> difOf (ps !! (2 :: Int)) :> difOf (ps !! (3 :: Int)) :> Nil }
      4 -> let s0 = shine0Of h
               w = rdSH rd !! (truncateB (shineIx h `shiftR` 2) :: Unsigned 2)
               byte = truncateB (pack w `shiftR` (8 * fromEnum (truncateB (shineIx h) :: Unsigned 2))) :: BitVector 8
           in h { hLShine = if hUseShine h then unpack (resize byte) `shiftL` 1 else s0 }
      6 -> h { hLBuf = zipWith4 (\b df p a -> b + resize df + lowU p + (resize a `shiftL` 9))
                         (hLBuf h) (hLDiff h) (take d3 ps) (hLMalc h) }
      _ -> h
    difOf p = if lit then lowU p else 0

deliver :: Dest -> Vec 4 (Signed 44) -> Hw -> (Hw, Wr)
deliver d sums h = case d of
  DRow ram a rr ->
    let w = case ram of
          RM1 -> noW { wM1 = Just (a, allLanes row) }
          RM2 -> noW { wM2 = Just (truncateB a, allLanes row) }
          RM3 -> noW { wM3 = Just (truncateB a, allLanes (take d3 row)) }
        rrLanes = case ram of
          RM3 -> map Just (take d3 row) ++ (Nothing :> Nil)
          _ -> allLanes row
        -- texture rows 2 and 3, columns 0-1: TEXCOORD mode 1's constant terms
        texRow = a >= 16 && a < 24
        tex2 = take d2 row
        h' | texRow && truncateB a == (2 :: Unsigned 2) = h { hTexR2 = tex2 }
           | texRow && truncateB a == (3 :: Unsigned 2) = h { hTexBias = zipWith (+) (hTexR2 h) tex2 }
           | otherwise = h
    in (h', w { wRR = fmap (\r -> (r, rrLanes)) rr })
  DVPos -> (h { hVPos = row }, noW)
  DPosT -> (h { hPosTest = row }, noW)
  DCorner k -> (h, noW { wCB = Just (resize k, row) })
  DTex3 -> (h { hVTex = zipWith (\s r -> truncateB (s `shiftR` 24) + r) (take d2 sums) (hRaw h) }, noW)
  DTex1 -> (h { hTex = zipWith (\s b -> truncateB ((s + resize b) `shiftR` 12)) (take d2 sums) (hTexBias h) }, noW)
  DTex2 -> (h { hTex = zipWith (\s r -> r + truncateB (s `shiftR` 21)) (take d2 sums) (hRaw h) }, noW)
  DNormT -> (h { hNt = map (\s -> truncateB (s `shiftR` 12)) (take d3 sums) }, noW)
  DLVec ->
    let dirs = map (\s -> truncateB (negate (s `shiftR` 12))) (take d3 sums)
        n11 = truncateB (sums !! (2 :: Int) `shiftR` 12) :: Signed 11
        den = 512 - resize n11 :: Signed 12
        mag = unpack (resize (pack (abs den))) :: Unsigned 32
    in ( h { hLDir = dirs
           , hDiv = if den == 0 then divDone 0
                    else divStart (1 `shiftL` 62) 10 mag (den < 0) }
       , noW )
  DVecT ->
    let vt s = let v = truncateB (s `shiftR` 9) :: Signed 16
               in if testBit v 12 then v .|. unpack 0xF000 else v
    in (h { hVecTest = map vt (take d3 sums) }, noW)
  where
    row = map hi12 sums

------------------------------------------------------------------------------
-- Controller

bcast :: S32 -> Row -> ATag -> Issue
bcast s row = Issue (resize s) (resize (head row)) (repeat s) (tail row)

vertexEvent :: Hw -> Word32 -> HwGeoEvent
vertexEvent h zdw =
  let p = hVPos h
      c = hColor h
      t = hVTex h
      vp = hVp h
      i0 = 0 :: Int
      i1 = 1 :: Int
      i2 = 2 :: Int
      i3 = 3 :: Int
  in HeVertex
       (HwVertex (p !! i0) (p !! i1) (p !! i2) (p !! i3) (c !! i0) (c !! i1) (c !! i2) (t !! i0) (t !! i1))
       (HwPolyState (hCurAttr h) (hTexParam h) (hTexPal h) (vpX0 vp) (vpY0 vp) (vpX1 vp) (vpY1 vp)
          (vpW vp) (vpH vp) (unpack (truncateB (pack zdw))))

viewportOf :: BitVector 32 -> Vp
viewportOf p =
  let b k = unpack (truncateB (p `shiftR` (8 * k))) :: Unsigned 8
      v0 = b 0
      v1 = 191 - b 1
      v2 = b 2
      v3 = 191 - b 3
  in Vp v0 v1 v2 v3 (resize v2 - resize v0 + 1) (v1 - v3 + 1)

vtxUpdate :: BitVector 8 -> BitVector 32 -> S32 -> S32 -> Vec 3 (Signed 16) -> Vec 3 (Signed 16)
vtxUpdate op p q0 q1 v = case op of
  0x23 -> lo16 (pack q0) :> hi16 (pack q0) :> lo16 (pack q1) :> Nil
  0x24 -> lo16 ((p .&. 0x3FF) `shiftL` 6) :> lo16 ((p .&. 0xFFC00) `shiftR` 4)
            :> lo16 ((p .&. 0x3FF00000) `shiftR` 14) :> Nil
  0x25 -> lo16 p :> hi16 p :> (v !! i2) :> Nil
  0x26 -> lo16 p :> (v !! i1) :> hi16 p :> Nil
  0x27 -> (v !! i0) :> lo16 p :> hi16 p :> Nil
  _ -> zipWith (\a dlt -> a + resize dlt) v (sext10 p)   -- 0x28
  where
    i0 = 0 :: Int
    i1 = 1 :: Int
    i2 = 2 :: Int

-- | Box faces (front, back, left, right, bottom, top) as corner rows.
faceRow :: Unsigned 3 -> Unsigned 4 -> Unsigned 5
faceRow f i =
  let faces = ((0 :> 1 :> 2 :> 3 :> Nil) :> (4 :> 5 :> 6 :> 7 :> Nil) :> (0 :> 3 :> 4 :> 5 :> Nil)
               :> (1 :> 2 :> 7 :> 6 :> Nil) :> (0 :> 1 :> 6 :> 5 :> Nil) :> (2 :> 3 :> 4 :> 7 :> Nil)
               :> Nil) :: Vec 6 (Vec 4 (Unsigned 5))
  in (faces !! f) !! (truncateB i :: Unsigned 2)

boxPrev, boxNext :: BoxSt -> Unsigned 4
boxPrev b = if bxI b == 0 then bxN b - 1 else bxI b - 1
boxNext b = if bxI b + 1 >= bxN b then 0 else bxI b + 1

boxInRow :: BoxSt -> Unsigned 4 -> Unsigned 5
boxInRow b i
  | not (bxNeg b) && bxComp b == 2 = faceRow (bxFace b) i
  | bxNeg b = 18 + resize i
  | otherwise = 8 + resize i

boxOutRow :: BoxSt -> Unsigned 5
boxOutRow b = (if bxNeg b then 8 else 18) + resize (bxC b)

boxReadRow :: BoxSt -> BoxCtl -> Unsigned 5
boxReadRow b c = case c of
  BxV -> boxInRow b (bxI b)
  BxP -> boxInRow b (boxPrev b)
  BxN -> boxInRow b (boxNext b)
  _ -> 0

-- | The position components a segment interpolates in this pass, and the
-- index of the last.
segComp :: Unsigned 2 -> Unsigned 2 -> Unsigned 2
segComp comp k = case comp of
  2 -> case k of
         0 -> 0
         1 -> 1
         _ -> 3
  1 -> if k == 0 then 0 else 3
  _ -> 3

segLast :: Unsigned 2 -> Unsigned 2
segLast comp = case comp of
  2 -> 2
  1 -> 1
  _ -> 0

boxOutside, boxInside :: BoxSt -> Row -> Bool
boxOutside b v =
  let c = v !! bxComp b
      w = v !! (3 :: Int)
  in if bxNeg b then c < negate w else c > w
boxInside b v = not (boxOutside b v)

-- | The X pass's -W half keeps a polygon exactly when one of the vertices its
-- +W half wrote has @x >= -w@ (a kept vertex, or the neighbour of an
-- intersection), so the box test needs no -W half for X.
insideNegX :: Row -> Bool
insideNegX v = (v !! (0 :: Int)) >= negate (v !! (3 :: Int))

geoAddr :: Hw -> Ad
geoAddr h = case hCtl h of
  CIdle -> base { adM1 = curRow h TTex 0 }
  CProg pg r j -> progAddr h pg r j base
  CStackW k -> base { adM2 = truncateB (curRow h TPos (truncateB (k `shiftR` 2)))
                    , adM3 = truncateB (curRow h TVec (truncateB (k `shiftR` 2))) }
  CStackR k -> base { adStk = (resize (hSlot h) `shiftL` 4) + resize k }
  CShine k -> base { adPR = repeat k }
  CLight l _ -> base { adL = l }
  CBox c -> base { adCB = boxReadRow (hBx h) c }
  _ -> base
  where
    base = Ad (repeat 0) 0 0 0 (truncateB (shineIx h `shiftR` 4)) 0 0 0

-- | The controller: decisions from the registered state @h0@, updates on top
-- of @h@ (the registers after the second stage, which has already delivered
-- the products issued in the previous cycle).
control :: Hw -> Hw -> GeoHwIn -> Rd -> (Hw, Maybe Issue, Wr)
control h0 h i rd = case hCtl h0 of
  CInit k -> (h { hCtl = if k == 511 then CIdle else CInit (k + 1) }, Nothing, initW k)
  CIdle -> case giCmd i of
    Just e | not (hSwap h0) -> accept (pack (heCmd e)) (pack (heParam e))
    _ -> (h, Nothing, noW)
  CStart -> (startCmd (hCmd h0) (hP0 h0) h, Nothing, noW)
  CProg pg r j ->
    let (sc, row) = progTerm h0 rd pg r j
        lastJ = j == progLastTerm (hCmd h0) pg r
        lastR = r == progLastRow pg
        tag = AMac (j == 0) (if lastJ then Just (progDest h0 pg r) else Nothing)
        h' | not lastJ = h { hCtl = CProg pg r (j + 1) }
           | not lastR = h { hCtl = CProg pg (r + 1) 0 }
           | otherwise = afterProg h pg
    in (h', Just (bcast sc row tag), noW)
  CStackW k ->
    let a = (resize (hSlot h0) `shiftL` 4) + resize k :: Unsigned 9
        c = truncateB k :: Unsigned 2
    in ( h { hCtl = if k == 15 then CIdle else CStackW (k + 1) }, Nothing
       , noW { wPS = Just (a, rdM2 rd !! c)
             , wVS = if c == 3 then Nothing else Just (a, rdM3 rd !! c) } )
  CStackR k ->
    let w = truncateB (k - 1) :: Unsigned 4
        r = truncateB (w `shiftR` 2) :: Unsigned 2
        c = truncateB w :: Unsigned 2
        one v = replace c (Just v) (repeat Nothing) :: Vec 4 (Maybe S32)
        wr | k == 0 = noW
           | otherwise = noW
               { wM2 = Just (truncateB (curRow h0 TPos r), one (rdPS rd))
               , wM3 = if c == 3 then Nothing
                       else Just (truncateB (curRow h0 TVec r), take d3 (one (rdVS rd)))
               , wRR = if c == 3 || r == 3 then Nothing
                       else Just (4 + resize r, one (rdVS rd)) }
    in (h { hCtl = if k == 16 then CProg PgClip 0 0 else CStackR (k + 1) }, Nothing, wr)
  CShine k ->
    (h { hCtl = if k == 7 then CIdle else CShine (k + 1) }, Nothing
    , noW { wSH = Just (k, allLanes (rdPR rd)) })
  CLight l s
    | s == 0 && isMac (hTag h0) -> (h, Nothing, noW)
    | otherwise ->
        let nxt | s /= 6 = CLight l (s + 1)
                | otherwise = maybe CColour (\l' -> CLight l' 0) (lightFrom (hCurAttr h0) (resize l + 1))
        in (h { hCtl = nxt }, lightIssue h0 rd s, noW)
  CColour ->
    let clamp v = let x = v `shiftR` 14 in if x > 31 then 31 else truncateB x
    in (h { hColor = map clamp (hLBuf h), hCtl = CIdle }, Nothing, noW)
  CDiv
    | not (isNone (hTag h0)) || not (dvValid (hDiv h0)) -> (h, Nothing, noW)
    | otherwise ->
        let q = unpack (resize (pack (dvQuo (hDiv h0)))) :: Signed 20
            recip = if dvNeg (hDiv h0) then negate q else q
        in ( h { hCtl = CIdle }, Nothing
           , noW { wLD = Just (unpack (truncateB (hP0 h0 `shiftR` 30)), LDir (hLDir h0) recip) } )
  CEmit
    | not (canLoad h) -> (h, Nothing, noW)
    | otherwise -> (h { hOut = Just (vertexEvent h (giZeroDotW i)), hCtl = CIdle }, Nothing, noW)
  CBox c -> box c
  where
    -- the output register is free (or its event is taken this cycle)
    canLoad x = isNothing (hOut x)
    isMac t = case t of
      AMac _ _ -> True
      _ -> False

    -- the cycle an entry is taken
    accept c p
      | n >= 2 =
          let cnt = hCount h0
              cnt' = cnt + 1
              wr = noW { wPR = Just (truncateB cnt, truncateB (cnt `shiftR` 2), unpack p) }
          in if cnt' >= n
               then (h { hCmd = c, hCount = 0, hCtl = CStart }, Nothing, wr)
               else (h { hCount = cnt' }, Nothing, wr)
      | otherwise = fast c p (h { hCmd = c, hP0 = p })
      where
        n = numParams c

    fast c p hb = case c of
      0x10 -> (hb { hMode = truncateB (unpack p :: Unsigned 32) }, Nothing, noW)
      0x20 -> (hb { hColor = rgb5 0 p }, Nothing, noW)
      0x22 -> let raw = lo16 p :> hi16 p :> Nil
              in if texMode h == 1
                   then ( hb { hRaw = raw, hCtl = CProg PgTex1 0 1 }
                        , Just (bcast (s2s (lo16 p)) (rdM1 rd) (AMac True Nothing)), noW )
                 else (hb { hRaw = raw, hTex = raw }, Nothing, noW)
      0x29 -> (hb { hPolyAttr = p }, Nothing, noW)
      0x2A -> (hb { hTexParam = p }, Nothing, noW)
      0x2B -> (hb { hTexPal = truncateB p }, Nothing, noW)
      0x30 -> ( hb { hDif = rgb5 0 p, hAmb = rgb5 16 p
                   , hColor = if testBit p 15 then rgb5 0 p else hColor h }, Nothing, noW )
      0x31 -> (hb { hSpe = rgb5 0 p, hEmi = rgb5 16 p, hUseShine = testBit p 15 }, Nothing, noW)
      0x33 -> (hb, Nothing, noW { wLC = Just (unpack (truncateB (p `shiftR` 30)), rgb5 0 p) })
      0x60 -> (hb { hVp = viewportOf p }, Nothing, noW)
      _ | execSingle c -> (startCmd c p hb, Nothing, noW)
        | otherwise -> (hb, Nothing, noW)

    -- the first step of a command that runs, on the registers @x@: in the
    -- cycle its (only) entry is taken, or in 'CStart' after a gathered
    -- command's last parameter was written (and to retry a stalled start)
    startCmd op p0 x = case op of
      0x11 -> case hMode x of
        0 -> x { hErr = hErr x || hProjSP x, hProjSP = not (hProjSP x), hCtl = CProg (PgPush False) 0 0 }
        3 -> x { hErr = hErr x || hTexSP x, hTexSP = not (hTexSP x), hCtl = CProg (PgPush True) 0 0 }
        _ -> x { hErr = hErr x || hPosSP x > 30, hSlot = truncateB (hPosSP x)
               , hPosSP = hPosSP x + 1, hCtl = CStackW 0 }
      0x12 -> case hMode x of
        0 -> x { hErr = hErr x || not (hProjSP x), hProjSP = not (hProjSP x), hCtl = CProg (PgPop False) 0 0 }
        3 -> x { hErr = hErr x || not (hTexSP x), hTexSP = not (hTexSP x), hCtl = CProg (PgPop True) 0 0 }
        _ -> let sp = hPosSP x - unpack (truncateB p0)
             in x { hPosSP = sp, hErr = hErr x || sp > 30, hSlot = truncateB sp, hCtl = CStackR 0 }
      0x13 -> case hMode x of
        0 -> x { hCtl = CProg (PgPush False) 0 0 }
        3 -> x { hCtl = CProg (PgPush True) 0 0 }
        _ -> let a = unpack (truncateB p0) :: Unsigned 5
             in x { hErr = hErr x || a > 30, hSlot = a, hCtl = CStackW 0 }
      0x14 -> case hMode x of
        0 -> x { hCtl = CProg (PgPop False) 0 0 }
        3 -> x { hCtl = CProg (PgPop True) 0 0 }
        _ -> let a = unpack (truncateB p0) :: Unsigned 5
             in x { hErr = hErr x || a > 30, hSlot = a, hCtl = CStackR 0 }
      _ | op >= 0x15 && op <= 0x1C -> x { hCtl = CProg (PgMat (tgtOfMode (hMode x))) 0 0 }
      0x21 -> x { hLBuf = map (\e -> resize e `shiftL` 14) (hEmi x)
                , hCtl = if texMode x == 2 then CProg PgTex2 0 0 else CProg PgNormT 0 0 }
      _ | op >= 0x23 && op <= 0x28 ->
            x { hCurV = vtxUpdate op p0 (param rd 0) (param rd 1) (hCurV x), hVTex = hTex x
              , hCtl = CProg PgVtx 0 0 }
      0x32 -> if giStall i then x { hCtl = CStart } else x { hCtl = CProg PgLVec 0 0 }
      0x34 -> x { hCtl = CShine 0 }
      0x40 -> if giStall i || not (canLoad x) then x { hCtl = CStart }
              else x { hCurAttr = hPolyAttr x, hOut = Just (HeBegin (truncateB p0)), hCtl = CIdle }
      0x41 -> if not (canLoad x) then x { hCtl = CStart } else x { hOut = Just HeEnd, hCtl = CIdle }
      0x50 -> if not (canLoad x) then x { hCtl = CStart }
              else x { hOut = Just (HeSwap (truncateB p0)), hSwap = True, hCtl = CIdle }
      0x70 -> if giStall i then x { hCtl = CStart } else x { hBoxRes = False, hCtl = CProg PgCorner 0 0 }
      0x71 -> x { hCurV = vtxUpdate 0x23 0 (param rd 0) (param rd 1) (hCurV x), hCtl = CProg PgPosT 0 0 }
      0x72 -> x { hCtl = CProg PgVecT 0 0 }
      _ -> x { hCtl = CIdle }

    -- box-test face clipping: Z, Y, X passes as 'clipPolygon'; the X pass's
    -- -W half is decided while its +W half writes (see 'insideNegX')
    b0 = hBx h0
    setBox b c = h { hBx = b, hCtl = CBox c }
    faceInit f = b0 { bxFace = f, bxComp = 2, bxNeg = False, bxI = 0, bxN = 4, bxC = 0 }
    boxDone res = h { hBoxRes = res, hCtl = CIdle }
    faceFail
      | bxFace b0 == 5 = boxDone False
      | otherwise = setBox (faceInit (bxFace b0 + 1)) BxV
    xPos = bxComp b0 == 0 && not (bxNeg b0)
    halfEnd b
      | bxC b == 0 || xPos = faceFail
      | not (bxNeg b) = setBox b { bxNeg = True, bxN = bxC b, bxI = 0, bxC = 0 } BxV
      | otherwise = setBox b { bxComp = bxComp b - 1, bxNeg = False, bxN = bxC b, bxI = 0, bxC = 0 } BxV
    advance b
      | bxI b + 1 >= bxN b = halfEnd b
      | otherwise = setBox b { bxI = bxI b + 1 } BxV
    -- a vertex the X pass's +W half writes, and the face's result if it
    -- decides it
    written b v wr
      | xPos && insideNegX v = (boxDone True, Nothing, wr)
      | otherwise = (advance b, Nothing, wr)
    row = rdCB rd
    box c = case c of
      BxStart
        | not (isNone (hTag h0)) -> (h, Nothing, noW)
        | otherwise -> (setBox (faceInit 0) BxV, Nothing, noW)
      BxV
        | boxOutside b0 row ->
            if not (bxNeg b0) && bxComp b0 == 2 && not (testBit (hCurAttr h0) 12) then (faceFail, Nothing, noW)
            else (setBox b0 { bxV = row } BxP, Nothing, noW)
        | bxC b0 < 10 -> written b0 { bxC = bxC b0 + 1 } row (noW { wCB = Just (boxOutRow b0, row) })
        | otherwise -> (advance b0, Nothing, noW)
      BxP
        | boxInside b0 row && bxC b0 < 10 -> (setBox b0 { bxO = row, bxNext = False } BxSegF, Nothing, noW)
        | otherwise -> (setBox b0 BxN, Nothing, noW)
      BxN
        | boxInside b0 row && bxC b0 < 10 -> (setBox b0 { bxO = row, bxNext = True } BxSegF, Nothing, noW)
        | otherwise -> (advance b0, Nothing, noW)
      BxSegF ->
        let comp = bxComp b0
            v = bxV b0
            o = bxO b0
            pos = not (bxNeg b0)
            dist :: Row -> S32
            dist x = if pos then (x !! (3 :: Int)) - (x !! comp) else (x !! (3 :: Int)) + (x !! comp)
            wide :: Row -> Signed 34
            wide x = if pos then resize (x !! (3 :: Int)) - resize (x !! comp)
                     else resize (x !! (3 :: Int)) + resize (x !! comp)
            dIn = dist v
            legDen = dIn - dist o
            isWide = legDen == 0
            numS = if isWide then wide v else resize dIn
            denNeg = if isWide then wide v < wide o else legDen < 0
            mag34 x = unpack (truncateB (pack (if x < 0 then negate x else x))) :: Unsigned 33
            denMag = unpack (pack (if legDen < 0 then negate legDen else legDen)) :: Unsigned 32
        in ( setBox b0 { bxNumMag = mag34 numS, bxNumNeg = numS < 0, bxDenMag = denMag
                       , bxDenNeg = denNeg, bxWide = isWide, bxR = v, bxK = 0 } BxSegMul
           , Nothing, noW )
      BxSegMul ->
        let j = segComp (bxComp b0) (bxK b0)
            a = bxV b0 !! j
            bo = bxO b0 !! j
            diff = resize bo - resize a :: Signed 33
            dMag = unpack (truncateB (pack (if diff < 0 then negate diff else diff))) :: Unsigned 32
            iss = Issue (unpack (resize (pack (bxNumMag b0)))) (unpack (resize (pack dMag)))
                        (repeat 0) (repeat 0) ASeg
        in ( h { hBx = b0 { bxQNeg = (diff < 0) /= (bxNumNeg b0 /= bxDenNeg b0) }
               , hDiv = (hDiv h) { dvValid = False }, hCtl = CBox BxSegWait }
           , Just iss, noW )
      BxSegWait
        | not (dvValid (hDiv h0)) -> (h, Nothing, noW)
        | otherwise ->
            let j = segComp (bxComp b0) (bxK b0)
                q = unpack (pack (dvQuo (hDiv h0))) :: S32
                res = (bxV b0 !! j) + (if bxQNeg b0 then negate q else q)
                b' = b0 { bxR = replace j res (bxR b0) }
            in if bxK b0 == segLast (bxComp b0)
                 then (setBox b' BxSegWrite, Nothing, noW)
                 else (setBox b' { bxK = bxK b0 + 1 } BxSegMul, Nothing, noW)
      BxSegWrite ->
        let w3 = bxR b0 !! (3 :: Int)
            r' = replace (bxComp b0) (if bxNeg b0 then negate w3 else w3) (bxR b0)
            b' = b0 { bxC = bxC b0 + 1 }
            wr = noW { wCB = Just (boxOutRow b0, r') }
        in if bxNext b0 then written b' r' wr
           else if xPos && insideNegX r' then (boxDone True, Nothing, wr)
           else (setBox b' BxN, Nothing, wr)

-- | Power-on contents, one row per RAM per cycle.
initW :: Unsigned 9 -> Wr
initW k = Wr
  { wPR = if k < 32 then Just (truncateB k, truncateB (k `shiftR` 2), 0) else Nothing
  , wM1 = if k < 32 then Just (k5, allLanes m1Row) else Nothing
  , wM2 = if k < 8 then Just (truncateB k, allLanes ident) else Nothing
  , wM3 = if k < 8 then Just (truncateB k, allLanes (take d3 ident)) else Nothing
  , wRR = if k < 8 then Just (truncateB k, allLanes rrRow) else Nothing
  , wSH = if k < 8 then Just (truncateB k, allLanes (repeat 0)) else Nothing
  , wLD = if k < 4 then Just (truncateB k, LDir (repeat 0) 0) else Nothing
  , wLC = if k < 4 then Just (truncateB k, repeat 0) else Nothing
  , wCB = if k < 32 then Just (k5, repeat 0) else Nothing
  , wPS = Just (k, 0)
  , wVS = Just (k, 0)
  }
  where
    k5 = truncateB k :: Unsigned 5
    ident = identRow (truncateB k)
    -- proj slots 0-7, clip 12-15, tex slots 16-23 hold the identity; the
    -- stacks and the unused rows hold zero
    m1Row | k5 < 8 || (k5 >= 12 && k5 < 24) = ident
          | otherwise = repeat 0
    rrRow | k < 7 = ident
          | otherwise = repeat 0

geoStep :: Hw -> GeoHwIn -> Rd -> (Hw, Wr)
geoStep h0 i rd = (h4, mergeW aw cw)
  where
    (hA, aw) = aStage h0 rd
    hD = if startsDiv (hTag h0) then hA else hA { hDiv = divStep (hDiv h0) }
    consumed = isJust (hOut h0) && giEvReady i
    hB = hD { hOut = if consumed then Nothing else hOut h0 }
    (hC, iss, cw) = control h0 hB i rd
    hI = case iss of
      Nothing -> hC { hTag = ANone }
      Just is ->
        hC { hTag = isTag is
           , hP = truncateB (isA0 is `mul` isB0 is)
           , hPs = zipWith (\a b -> truncateB (a `mul` b)) (isA is) (isB is) }
    hV = if giVblank i && hSwap h0 && isNothing (hOut h0) then hI { hSwap = False } else hI
    h4 = if giAck i then hV { hErr = False, hProjSP = False, hTexSP = False } else hV

------------------------------------------------------------------------------
-- Outputs

-- | Whether the tag names no command. Pattern-matched, never compared: the
-- packed value's payload bits are undefined when the tag names no command, so a
-- @(\/= ANone)@ would be undefined -- and would make @gsBusy@ undefined.
isNone :: ATag -> Bool
isNone t = case t of
  ANone -> True
  _ -> False

-- | Whether the control is idle.
isIdle :: Ctl -> Bool
isIdle c = case c of
  CIdle -> True
  _ -> False

-- | Control and full transaction completion, for composition scoreboards.
-- These observe progress, independently of the architectural status outputs.
geoControlIdle :: Hw -> Bool
geoControlIdle = isIdle . hCtl

geoTransactionIdle :: Hw -> Bool
geoTransactionIdle h = geoControlIdle h && noTag && isNothing (hOut h)
  where noTag = case hTag h of ANone -> True; _ -> False

geoOut :: Hw -> GeoHwOut
geoOut h = GeoHwOut
  { goCmdReady = isIdle (hCtl h) && not (hSwap h)
  , goEvent = hOut h
  , goStatus = GeoStatus
      { gsTestBusy = running && (hCmd h == 0x70 || hCmd h == 0x71 || hCmd h == 0x72)
      , gsBoxResult = hBoxRes h
      , gsPosStack = unpack (resize (pack (truncateB (hPosSP h) :: Unsigned 5))) :: Word8
      , gsProjStack = hProjSP h
      , gsStackBusy = running && (hCmd h == 0x11 || hCmd h == 0x12)
      , gsStackError = hErr h
      , gsBusy = not (isIdle (hCtl h)) || not (isNone (hTag h)) || isJust (hOut h) || hSwap h
      }
  , goSwapWait = hSwap h
  }
  where
    running = case hCtl h of
      CIdle -> False
      CInit _ -> False
      _ -> True

-- | The result-copy row an address reads: clip rows 0-3, vector rows 4-6.
resultRow :: Word32 -> Unsigned 3
resultRow addr
  | a >= 0x04000640 && a < 0x04000680 = resize (truncateB (a `shiftR` 4) :: Unsigned 2)
  | otherwise = 4 + fst (vecSlot a)
  where
    a = unpack (pack addr .&. complement 3) :: Unsigned 32

-- | Row and lane of @VECMTX_RESULT@ word @(a - 0x04000680) / 4@.
vecSlot :: Unsigned 32 -> (Unsigned 3, Unsigned 2)
vecSlot a = case truncateB ((a - 0x04000680) `shiftR` 2) :: Unsigned 4 of
  0 -> (0, 0)
  1 -> (0, 1)
  2 -> (0, 2)
  3 -> (1, 0)
  4 -> (1, 1)
  5 -> (1, 2)
  6 -> (2, 0)
  7 -> (2, 1)
  _ -> (2, 2)

-- | The result shadows are undefined during execution or outstanding writes,
-- but remain readable during a quiescent SWAP_BUFFERS wait. Architectural
-- GXSTAT busy includes that wait and is not the result-RAM validity signal.
geoResultOut :: Hw -> Row -> Word32 -> Word32
geoResultOut h q a
  | not (geoTransactionIdle h) = 0
  | otherwise = geoResult h q a

-- | 'Nds.Gpu3D.Geometry.geoReadResult' from the registers and the result-copy
-- row of the same address.
geoResult :: Hw -> Row -> Word32 -> Word32
geoResult h q addr
  | a >= 0x04000620 && a <= 0x0400062C = w (hPosTest h !! (truncateB (a `shiftR` 2) :: Unsigned 2))
  | a == 0x04000630 = half (vt !! (0 :: Int)) .|. (half (vt !! (1 :: Int)) `shiftL` 16)
  | a == 0x04000634 = half (vt !! (2 :: Int))
  | a >= 0x04000640 && a < 0x04000680 = w (q !! (truncateB (a `shiftR` 2) :: Unsigned 2))
  | a >= 0x04000680 && a <= 0x040006A0 = w (q !! snd (vecSlot a))
  | otherwise = 0
  where
    a = unpack (pack addr .&. complement 3) :: Unsigned 32
    vt = hVecTest h
    w :: S32 -> Word32
    w = unpack . pack
    half :: Signed 16 -> Word32
    half v = unpack (resize (pack v))

------------------------------------------------------------------------------
-- The block

-- | A RAM of @k@ lanes sharing their addresses, each lane its own write
-- enable (asynchronous read: LUT RAM).
laneRam
  :: forall dom k n addr. (KnownDomain dom, KnownNat k, KnownNat n, Enum addr, NFDataX addr)
  => Clock dom -> Enable dom -> SNat n -> Signal dom addr
  -> Signal dom (Maybe (addr, Vec k (Maybe S32))) -> Signal dom (Vec k S32)
laneRam clk en n rd wr = bundle (map lane indicesI)
  where
    lane :: Index k -> Signal dom S32
    lane ix = asyncRam clk clk en n rd ((\m -> m >>= \(a, ds) -> fmap (\d -> (a, d)) (ds !! ix)) <$> wr)

-- | The geometry engine. Inputs: command entries, event ready, stall,
-- VBlank, acknowledge, @ZeroDotWLimit@, result address. Outputs: entry
-- ready, events, status, swap wait (in 'GeoHwOut') and the result word.
geometryHw
  :: forall dom. KnownDomain dom
  => Clock dom -> Reset dom -> Enable dom
  -> Signal dom GeoHwIn
  -> Signal dom Word32
  -> (Signal dom GeoHwOut, Signal dom Word32)
geometryHw clk rst en inp resAddr =
  let (_, o, r) = geometryHwState clk rst en inp resAddr in (o, r)

-- | 'geometryHw' with its register state, for testbench diagnostics.
geometryHwState
  :: forall dom. KnownDomain dom
  => Clock dom -> Reset dom -> Enable dom
  -> Signal dom GeoHwIn
  -> Signal dom Word32
  -> (Signal dom Hw, Signal dom GeoHwOut, Signal dom Word32)
geometryHwState clk rst en inp resAddr = (st, geoOut <$> st, geoResultOut <$> st <*> rrQ <*> resAddr)
  where
    st = register clk rst en hwInit st'
    ad = geoAddr <$> st
    (st', wr) = unbundle (geoStep <$> st <*> inp <*> rd)
    rd = Rd <$> prQ <*> m1Q <*> m2Q <*> m3Q <*> shQ <*> ldQ <*> lcQ <*> cbQ <*> psQ <*> vsQ

    prQ = bundle (map prBank indicesI)
    prBank :: Index 4 -> Signal dom S32
    prBank b = asyncRam clk clk en (SNat :: SNat 8) ((!! b) . adPR <$> ad)
                 ((\m -> m >>= \(bk, a, v) -> if fromEnum bk == fromEnum b then Just (a, v) else Nothing)
                    . wPR <$> wr)
    m1Q = laneRam clk en (SNat :: SNat 32) (adM1 <$> ad) (wM1 <$> wr)
    m2Q = laneRam clk en (SNat :: SNat 8) (adM2 <$> ad) (wM2 <$> wr)
    m3Q = laneRam clk en (SNat :: SNat 8) (adM3 <$> ad) (wM3 <$> wr)
    shQ = laneRam clk en (SNat :: SNat 8) (adSH <$> ad) (wSH <$> wr)
    cbQ = laneRam clk en (SNat :: SNat 32) (adCB <$> ad) (fmap (fmap (\(a, r) -> (a, allLanes r))) (wCB <$> wr))
    rrQ = laneRam clk en (SNat :: SNat 8) (resultRow <$> resAddr) (wRR <$> wr)
    ldQ = asyncRam clk clk en (SNat :: SNat 4) (adL <$> ad) (wLD <$> wr)
    lcQ = asyncRam clk clk en (SNat :: SNat 4) (adL <$> ad) (wLC <$> wr)
    stack :: Signal dom (Maybe (Unsigned 9, S32)) -> Signal dom S32
    stack = blockRam clk en (replicate (SNat :: SNat 512) 0) (adStk <$> ad)
    psQ = stack (wPS <$> wr)
    vsQ = stack (wVS <$> wr)

------------------------------------------------------------------------------
-- Synthesis top

-- | Flat ports for integration and resource estimation.
data TopOut = TopOut
  { tCmdReady  :: Bool
  , tEvValid   :: Bool
  , tEvent     :: BitVector 330
  , tStatus    :: BitVector 32
  , tSwapWait  :: Bool
  } deriving (Generic, NFDataX)

-- | Event as flat bits: tag (2 bits: 0 begin, 1 vertex, 2 end, 3 swap), then
-- the vertex and polygon state, or the 2-bit parameter in the low bits.
eventBits :: Maybe HwGeoEvent -> BitVector 330
eventBits m = case m of
  Just (HeBegin p) -> (0b00 :: BitVector 2) ++# resize p
  Just (HeVertex v ps) -> (0b01 :: BitVector 2) ++# resize (pack v ++# pack ps)
  Just HeEnd -> (0b10 :: BitVector 2) ++# 0
  Just (HeSwap p) -> (0b11 :: BitVector 2) ++# resize p
  Nothing -> 0

-- | 'GeoStatus' in its @GXSTAT@ bit positions (0, 1, 8-12, 13, 14, 15; busy
-- in bit 27).
statusBits :: GeoStatus -> BitVector 32
statusBits g =
  let b c n = if c then bit n else 0
  in b (gsTestBusy g) 0 .|. b (gsBoxResult g) 1
     .|. (resize (pack (gsPosStack g) .&. 0x1F) `shiftL` 8)
     .|. b (gsProjStack g) 13 .|. b (gsStackBusy g) 14 .|. b (gsStackError g) 15 .|. b (gsBusy g) 27

{-# ANN geometryTopEntity
  (Synthesize
    { t_name = "nds_gpu3d_geometry"
    , t_inputs =
        [ PortName "CLK"
        , PortName "RST"
        , PortName "EN"
        , PortName "CMD_VALID"
        , PortName "CMD_CMD"
        , PortName "CMD_PARAM"
        , PortName "EV_READY"
        , PortName "STALL"
        , PortName "VBLANK"
        , PortName "ACK"
        , PortName "ZERO_DOT_W"
        , PortName "RES_ADDR"
        ]
    , t_output = PortProduct ""
        [ PortProduct "" [ PortName "CMD_READY", PortName "EV_VALID", PortName "EVENT"
                         , PortName "STATUS", PortName "SWAP_WAIT" ]
        , PortName "RES_DATA"
        ]
    }) #-}
geometryTopEntity
  :: Clock System -> Reset System -> Enable System
  -> Signal System Bool -> Signal System (BitVector 8) -> Signal System (BitVector 32)
  -> Signal System Bool -> Signal System Bool -> Signal System Bool -> Signal System Bool
  -> Signal System (BitVector 32) -> Signal System (BitVector 32)
  -> (Signal System TopOut, Signal System (BitVector 32))
geometryTopEntity clk rst en cv cc cp rdy stl vbl ack zdw ra = (top <$> o, pack <$> res)
  where
    entry v c p = if v then Just (HwEntry (unpack c) (unpack p)) else Nothing
    inp = GeoHwIn <$> (entry <$> cv <*> cc <*> cp) <*> rdy <*> stl <*> vbl <*> ack <*> (unpack <$> zdw)
    (o, res) = geometryHw clk rst en inp (unpack <$> ra)
    top g = TopOut (goCmdReady g) (isJust (goEvent g)) (eventBits (goEvent g)) (statusBits (goStatus g))
              (goSwapWait g)
{-# NOINLINE geometryTopEntity #-}
