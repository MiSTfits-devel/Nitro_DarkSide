{-# LANGUAGE BinaryLiterals #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Compact geometry-engine experiment: every command of 'Nds.Gpu3D.Geometry'
-- with every matrix, stack slot, light direction, shininess byte, box-test
-- vertex and test result in synchronous block RAM and one shared
-- multiply-accumulate datapath, after the GuardianSoul Pocket core's "state
-- in RAM, logic shared over time" geometry engine. It is an experiment
-- beside 'Nds.Gpu3D.GeometryHw', bit-exact against the same model
-- (@Geometry.step@ after @Chip.gatherEntry@):
--
-- * the matrix and stack commands (0x10-0x1C);
-- * @COLOR@, @NORMAL@ (texture-coordinate mode 2 and up to four lights),
--   @TEXCOORD@ (all four modes), the vertex commands (0x23-0x28),
--   @POLYGON_ATTR@, @TEXIMAGE_PARAM@, @PLTT_BASE@;
-- * @DIF_AMB@, @SPE_EMI@, @LIGHT_VECTOR@, @LIGHT_COLOR@, @SHININESS@;
-- * @BEGIN_VTXS@, @END_VTXS@, @SWAP_BUFFERS@ (with its VBlank wait),
--   @VIEWPORT@;
-- * @BOX_TEST@, @POS_TEST@, @VEC_TEST@ with their result registers;
-- * every opcode the model ignores (no effect), @ExecParams@ gathering
--   including interleaved opcodes, the @GXSTAT@ bit-15 acknowledge, the
--   stack, test and busy status and the @0x04000620@-@0x040006A3@ result
--   reads.
--
-- The model's @Normal@ register is not kept: nothing reads it after its
-- @NORMAL@ has run.
--
-- __Storage__: one 512 x 128-bit simple-dual-port block RAM of rows (four
-- signed 32-bit lanes): projection, position, vector, texture and clip
-- matrices, the one-slot stacks, a temporary matrix, a constant identity, the
-- 32-slot position and vector stacks, one row per light (direction in lanes
-- 0-2, specular reciprocal in lane 3), the shininess table (8 rows), its
-- staging rows, the eight box-test corners, two ten-vertex clip buffers and
-- the @POS_RESULT@ / @VEC_RESULT@ rows. The gathered parameter words are a
-- second 32 x 32 block RAM. The row RAM gets its power-on contents (identity
-- matrices, zeros) from a 512-cycle write sweep after reset. Registers hold
-- the vertex state, the material and light colours, the lighting
-- temporaries, the box-test working vertices and the divider.
--
-- __Arithmetic__: one datapath, four lanes of 32 x 32-bit products (44 bits
-- kept). Matrix, vertex, normal, light-vector and test work is "scalar x
-- row" (a parameter word, a lane of a latched row, a vertex, normal or
-- corner coordinate, 0x1000 or 1, times one RAM row) into four 44-bit
-- accumulators, read as bits [12, 44) (matrices, positions), [24, 40) plus
-- the raw coordinate (texture mode 3), [21, 37) plus the raw coordinate
-- (mode 2), [12, 28) (mode 1), [12, 23) (normal and light directions) or
-- [9, 25) (vector test). Lighting drives the four lanes with separate
-- operands, seven issue cycles per enabled light (see 'litA'). The box
-- test's interpolation product is four partial products in one cycle and
-- its quotient comes from the divider ('Nds.Gpu3D.GeoDiv'), which
-- @LIGHT_VECTOR@'s reciprocal shares.
--
-- __Pipeline__: issue (row and parameter addresses), data (block-RAM output,
-- registered products), accumulate. The clip matrix is recomputed at the end
-- of every command that changes the projection or position matrix, so no
-- command waits for it.
--
-- __Interface__ ('geoMatrix'): command entries ('HwEntry', FIFO order) on a
-- valid/ready stream, ready a function of the state only, high only when no
-- command runs, the pipeline is empty and no swap waits; events
-- ('HwGeoEvent') on a valid/ready stream from one output register: an
-- event-producing command does not finish until its event is in that
-- register, so events leave in command order and backpressure holds the
-- engine; @stall@ (the polygon pipeline is busy) holds @BEGIN_VTXS@'s event
-- and the start of @LIGHT_VECTOR@ and @BOX_TEST@, as melonDS's
-- @StallPolygonPipeline@ callers; @vblank@: after @SWAP_BUFFERS@ no entry is
-- taken until a VBlank pulse in a cycle after the swap event was
-- transferred; @zeroDotW@ is @ZeroDotWLimit@ as the front end holds it;
-- @ack@, the @GXSTAT@ bit-15 write, clears the stack error and the
-- projection and texture stack pointers in its cycle after any command
-- bookkeeping of that cycle; a result read port (address valid/ready, data
-- the next cycle; reads are taken whenever no command runs, also while a
-- swap waits).
module Nds.Gpu3D.GeoMatrix
  ( -- * Ports
    GmIn (..)
  , GmOut (..)
  , RamQ (..)
  , RamOps (..)
    -- * Pure step (the testbench models the block RAMs around it)
  , Gm
  , gmInit
  , gmStep
  , gmMode
  , gmPointers
  , gmVertexRegs
  , gmLightRegs
    -- * Circuit
  , geoMatrix
  , geoMatrixTopEntity
    -- * Row map, encodings
  , RowAddr
  , rowProj, rowPos, rowVec, rowTex, rowClip, rowProjStack, rowTexStack
  , rowPosStack, rowVecStack, rowLight, rowShine, rowPosRes, rowVecRes
  , gmStatusBits
  , gmEventBits
  ) where

import Clash.Explicit.Prelude
import Data.Int (Int16)
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Word (Word32, Word8)

import Nds.Gpu3D.GeoDiv
import Nds.Gpu3D.GeometryHw.Event (HwGeoEvent (..), HwPolyState (..), HwVertex (..))
import Nds.Gpu3D.GxFrontHw (HwEntry (..))
import Nds.Gpu3D.Types (GeoStatus (..))

------------------------------------------------------------------------------
-- Ports

-- | Inputs other than the RAM read data.
data GmIn = GmIn
  { giEntry    :: !(Maybe HwEntry)        -- ^ command entry (valid)
  , giEvReady  :: !Bool                   -- ^ the polygon pipeline takes the event
  , giStall    :: !Bool                   -- ^ the polygon pipeline is busy
  , giVblank   :: !Bool                   -- ^ VBlank pulse
  , giAck      :: !Bool                   -- ^ GXSTAT bit-15 acknowledge pulse
  , giZeroDotW :: !(Unsigned 24)          -- ^ @ZeroDotWLimit@
  , giRead     :: !(Maybe (BitVector 32)) -- ^ result read request (bus address)
  } deriving (Eq, Show, Generic, NFDataX)

data GmOut = GmOut
  { goReady    :: !Bool                 -- ^ an entry offered now is taken
  , goEvent    :: !(Maybe HwGeoEvent)   -- ^ event (valid); taken when @giEvReady@
  , goStatus   :: !GeoStatus
  , goSwapWait :: !Bool                 -- ^ @SWAP_BUFFERS@ waits for VBlank
  , goRdReady  :: !Bool                 -- ^ a read offered now is taken
  , goRdData   :: !(Maybe (Signed 32))  -- ^ the word a read taken last cycle returns
  } deriving (Eq, Show)

-- | Block-RAM read data: the row and the parameter word addressed in the
-- previous cycle.
data RamQ = RamQ
  { rqRow   :: !(Vec 4 (Signed 32))
  , rqParam :: !(Signed 32)
  }

-- | Block-RAM ports driven this cycle.
data RamOps = RamOps
  { opRowRd :: !RowAddr
  , opRowWr :: !(Maybe (RowAddr, Vec 4 (Signed 32)))
  , opPrmRd :: !(Unsigned 5)
  , opPrmWr :: !(Maybe (Unsigned 5, Signed 32))
  } deriving (Eq, Show, Generic, NFDataX)

------------------------------------------------------------------------------
-- Row map

type S32 = Signed 32
type S16 = Signed 16
type S11 = Signed 11
type U5 = Unsigned 5
type Rgb = Vec 3 U5
type Row = Vec 4 S32
type RowAddr = Unsigned 9

rowProj, rowPos, rowVec, rowTex, rowClip, rowProjStack, rowTexStack, rowTemp, rowIdent :: RowAddr
rowProj = 0
rowPos = 4
rowVec = 8
rowTex = 12
rowClip = 16
rowProjStack = 20
rowTexStack = 24
rowTemp = 28
rowIdent = 32

-- | Shininess table (8 rows of four little-endian words), box-test corners
-- (8 rows), @POS_RESULT@ (lanes 0-3), @VEC_RESULT@ (lanes 0-2 as
-- sign-extended halfwords), the two clip buffers (10 rows each) and the
-- staging rows of gathered parameters (8 rows).
rowShine, rowCorner, rowPosRes, rowVecRes, rowBufA, rowBufB, rowShStage :: RowAddr
rowShine = 40
rowCorner = 48
rowPosRes = 56
rowVecRes = 57
rowBufA = 64
rowBufB = 80
rowShStage = 96

-- | Light @l@: direction (sign-extended 11-bit) in lanes 0-2, specular
-- reciprocal in lane 3.
rowLight :: Unsigned 2 -> RowAddr
rowLight l = 36 + resize l

-- | First row of position / vector stack slot @s@.
rowPosStack, rowVecStack :: Unsigned 5 -> RowAddr
rowPosStack s = 128 + 4 * resize s
rowVecStack s = 256 + 4 * resize s

identRow :: Unsigned 2 -> Row
identRow r = map (\c -> if c == r then 0x1000 else 0) (0 :> 1 :> 2 :> 3 :> Nil)

-- | Power-on contents: identity matrices (and the constant identity), zero
-- everywhere else.
initRow :: RowAddr -> Row
initRow a
  | a < 20 || (a >= rowIdent && a < rowIdent + 4) = identRow (truncateB a)
  | otherwise = repeat 0

------------------------------------------------------------------------------
-- Row programs

data Shape
  = ShCopy           -- ^ dst[r] = src[r]
  | ShMul4           -- ^ dst[r] = sum_k P[4r+k] src[k]
  | ShMul43          -- ^ rows 0-2: sum_{k<3} P[3r+k] src[k]; row 3: sum_{k<3} P[9+k] src[k] + 0x1000 src[3]
  | ShMul33          -- ^ rows 0-2: sum_{k<3} P[3r+k] src[k]; row 3: src[3]
  | ShScale          -- ^ rows 0-2 in place: P[r] src[r]
  | ShTrans          -- ^ row 3 in place: sum_{k<3} P[k] src[k] + 0x1000 src[3]
  | ShClip           -- ^ dst[r] = sum_k aux[r][k] src[k] (clip = pos * proj)
  | ShVtx            -- ^ one row: x src[0] + y src[1] + z src[2] + 0x1000 src[3]
  | ShTex3           -- ^ one row: x src[0] + y src[1] + z src[2]
  | ShTc1            -- ^ one row: s src[0] + t src[1] + src[2] + src[3]
  | ShN3             -- ^ one row: n0 src[0] + n1 src[1] + n2 src[2] (the command's 10-bit fields)
  | ShCorner !Bool   -- ^ box corners 0-3 / 4-7 (rows): x src[0] + y src[1] + z src[2] + 0x1000 src[3]
  deriving (Eq, Show, Generic, NFDataX)

-- | Where a finished sum goes.
data Dst
  = DRam !RowAddr   -- ^ a row
  | DPos            -- ^ the vertex's clip-space position
  | DTex3           -- ^ the vertex's texture coordinates (mode 3)
  | DTc1            -- ^ @TexCoords@ (mode 1)
  | DTex2           -- ^ @TexCoords@ (mode 2)
  | DNorm           -- ^ the transformed normal
  | DLVec           -- ^ the light direction, and the reciprocal's division
  | DVecT           -- ^ @VEC_RESULT@
  deriving (Eq, Show, Generic, NFDataX)

data UOp = UOp
  { uShape :: !Shape
  , uSrc   :: !RowAddr
  , uDst   :: !Dst
  } deriving (Eq, Show, Generic, NFDataX)

isClipSh :: Shape -> Bool
isClipSh s = case s of { ShClip -> True; _ -> False }

rowsOf :: Shape -> (Unsigned 2, Unsigned 2)
rowsOf sh = case sh of
  ShScale -> (0, 2)
  ShTrans -> (3, 3)
  ShVtx -> (0, 0)
  ShTex3 -> (0, 0)
  ShTc1 -> (0, 0)
  ShN3 -> (0, 0)
  _ -> (0, 3)

termsOf :: Shape -> Unsigned 2 -> (Unsigned 2, Unsigned 2)
termsOf sh r = case sh of
  ShCopy -> (r, r)
  ShScale -> (r, r)
  ShMul33 -> if r == 3 then (3, 3) else (0, 2)
  ShMul43 -> if r == 3 then (0, 3) else (0, 2)
  ShTex3 -> (0, 2)
  ShN3 -> (0, 2)
  _ -> (0, 3)

-- | Where a term's scalar comes from.
data Sel
  = SelParam                    -- ^ a gathered parameter word
  | SelS !(Index 4)             -- ^ a lane of the latched position row (clip update)
  | SelOne                      -- ^ 0x1000
  | SelUnit                     -- ^ 1
  | SelV !(Index 3)             -- ^ a current-vertex coordinate
  | SelT !(Index 2)             -- ^ a raw texture coordinate
  | SelN !(Index 3)             -- ^ a 10-bit field of the command's parameter
  | SelC !(Unsigned 3) !(Index 3) -- ^ a box-corner coordinate
  deriving (Eq, Show, Generic, NFDataX)

termSel :: Shape -> Unsigned 2 -> Unsigned 2 -> (Sel, Unsigned 4)
termSel sh r k = case sh of
  ShCopy -> (SelOne, 0)
  ShMul4 -> (SelParam, 4 * r4 + k4)
  ShMul43
    | r == 3 && k == 3 -> (SelOne, 0)
    | r == 3 -> (SelParam, 9 + k4)
    | otherwise -> (SelParam, 3 * r4 + k4)
  ShMul33
    | r == 3 -> (SelOne, 0)
    | otherwise -> (SelParam, 3 * r4 + k4)
  ShScale -> (SelParam, r4)
  ShTrans -> if k == 3 then (SelOne, 0) else (SelParam, k4)
  ShClip -> (SelS (fromIntegral k), 0)
  ShVtx -> if k == 3 then (SelOne, 0) else (SelV (fromIntegral k), 0)
  ShTex3 -> (SelV (fromIntegral k), 0)
  ShTc1 -> if k < 2 then (SelT (fromIntegral k), 0) else (SelUnit, 0)
  ShN3 -> (SelN (fromIntegral k), 0)
  ShCorner hi
    | k == 3 -> (SelOne, 0)
    | otherwise -> (SelC ((if hi then 4 else 0) + resize r) (fromIntegral k), 0)
  where
    r4 = resize r
    k4 = resize k

-- | The matrix a mode addresses: projection (0), texture (3), position (1, 2).
target :: Unsigned 2 -> RowAddr
target m = case m of
  0 -> rowProj
  3 -> rowTex
  _ -> rowPos

-- | Vertex commands (0x23-0x28).
isVertex :: BitVector 8 -> Bool
isVertex op = op >= 0x23 && op <= 0x28

-- | Commands that end with an event.
emits :: BitVector 8 -> Bool
emits op = isVertex op || op == 0x40 || op == 0x41 || op == 0x50

-- | The row programs of command @op@ run in mode @m@ with stack slot @slot@
-- and texture-coordinate mode @tm@, in five fixed slots (empty slots are
-- skipped, 'nextProg'): for matrix commands the target matrix's program and
-- its copy back, the vector matrix's program and its copy back (mode 2), and
-- the clip update; a vertex uses the first two (position, then the mode-3
-- texture coordinates); @NORMAL@ the first (mode-2 texture coordinates) and
-- the third (normal transform).
progOf :: BitVector 8 -> Unsigned 2 -> Unsigned 5 -> BitVector 2 -> Vec 8 (Maybe UOp)
progOf op m slot tm = case op of
  0x11 -> toStack
  0x12 -> fromStack
  0x13 -> toStack
  0x14 -> fromStack
  0x15 -> slots (Just (UOp ShCopy rowIdent (DRam t))) Nothing (vecOnly (UOp ShCopy rowIdent (DRam rowVec))) Nothing clipU
  0x16 -> load ShMul4
  0x17 -> load ShMul43
  0x18 -> mult ShMul4
  0x19 -> mult ShMul43
  0x1A -> mult ShMul33
  0x1B -> slots (Just (UOp ShScale t (DRam t))) Nothing Nothing Nothing clipU
  0x1C -> slots (Just (UOp ShTrans t (DRam t))) Nothing (vecOnly (UOp ShTrans rowVec (DRam rowVec))) Nothing clipU
  0x21 -> slots (if tm == 2 then Just (UOp ShN3 rowTex DTex2) else Nothing) Nothing
                (Just (UOp ShN3 rowVec DNorm)) Nothing Nothing
  0x22 -> slots (if tm == 1 then Just (UOp ShTc1 rowTex DTc1) else Nothing) Nothing Nothing Nothing Nothing
  0x32 -> slots (Just (UOp ShN3 rowVec DLVec)) Nothing Nothing Nothing Nothing
  0x34 -> slots (Just (UOp ShCopy rowShStage (DRam rowShine)))
                (Just (UOp ShCopy (rowShStage + 4) (DRam (rowShine + 4)))) Nothing Nothing Nothing
  0x70 -> slots (Just (UOp (ShCorner False) rowClip (DRam rowCorner)))
                (Just (UOp (ShCorner True) rowClip (DRam (rowCorner + 4)))) Nothing Nothing Nothing
  0x71 -> slots (Just (UOp ShVtx rowClip (DRam rowPosRes))) Nothing Nothing Nothing Nothing
  0x72 -> slots (Just (UOp ShN3 rowVec DVecT)) Nothing Nothing Nothing Nothing
  _ | isVertex op ->
        slots (Just (UOp ShVtx rowClip DPos)) (if tm == 3 then Just (UOp ShTex3 rowTex DTex3) else Nothing)
              Nothing Nothing Nothing
    | otherwise -> repeat Nothing
  where
    t = target m
    pv = m == 1 || m == 2
    vecOnly u = if m == 2 then Just u else Nothing
    clipU = if m /= 3 then Just (UOp ShClip rowProj (DRam rowClip)) else Nothing
    slots a b c d e = a :> b :> c :> d :> e :> Nothing :> Nothing :> Nothing :> Nil
    toStack = case m of
      0 -> slots (Just (UOp ShCopy rowProj (DRam rowProjStack))) Nothing Nothing Nothing Nothing
      3 -> slots (Just (UOp ShCopy rowTex (DRam rowTexStack))) Nothing Nothing Nothing Nothing
      _ -> slots (Just (UOp ShCopy rowPos (DRam (rowPosStack slot)))) Nothing
                 (Just (UOp ShCopy rowVec (DRam (rowVecStack slot)))) Nothing Nothing
    fromStack = case m of
      0 -> slots (Just (UOp ShCopy rowProjStack (DRam rowProj))) Nothing Nothing Nothing clipU
      3 -> slots (Just (UOp ShCopy rowTexStack (DRam rowTex))) Nothing Nothing Nothing Nothing
      _ -> slots (Just (UOp ShCopy (rowPosStack slot) (DRam rowPos))) Nothing
                 (if pv then Just (UOp ShCopy (rowVecStack slot) (DRam rowVec)) else Nothing) Nothing clipU
    load sh = slots (Just (UOp sh rowIdent (DRam t))) Nothing (vecOnly (UOp sh rowIdent (DRam rowVec))) Nothing clipU
    mult sh = slots (Just (UOp sh t (DRam rowTemp))) (Just (UOp ShCopy rowTemp (DRam t)))
                    (vecOnly (UOp sh rowVec (DRam rowTemp))) (vecOnly (UOp ShCopy rowTemp (DRam rowVec))) clipU

-- | The first non-empty program slot at or after @i@.
nextProg :: Vec 8 (Maybe UOp) -> Unsigned 3 -> Maybe (Unsigned 3, UOp)
nextProg prog i =
  case findIndex isJust (imap (\j u -> if (fromIntegral j :: Unsigned 3) >= i then u else Nothing) prog) of
    Nothing -> Nothing
    Just j -> fmap (\u -> (fromIntegral j, u)) (prog !! j)

------------------------------------------------------------------------------
-- Commands

-- | @CmdNumParams@ (1 for at most one).
numParams :: Word8 -> Unsigned 6
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

------------------------------------------------------------------------------
-- State

-- | Box-test face clipping phases ('boxStep').
data BoxCtl = BxStart | BxTurn | BxV | BxP | BxN | BxSegF | BxSegMul | BxSegWait | BxSegWrite
  deriving (Eq, Show, Generic, NFDataX)

data Ctl
  = CInit !RowAddr                         -- ^ power-on RAM contents
  | CIdle                                  -- ^ waiting for an entry
  | CRun                                   -- ^ row programs
  | CWait                                  -- ^ @LIGHT_VECTOR@ / @BOX_TEST@ waits for the polygon pipeline
  | CEmit                                  -- ^ the command's event
  | CLight !(Unsigned 2) !(Unsigned 3)     -- ^ light, step ('litA'; 7: the bubble before the first light)
  | CDiv                                   -- ^ @LIGHT_VECTOR@'s reciprocal
  | CBox !BoxCtl                           -- ^ box-test face clipping
  deriving (Eq, Show, Generic, NFDataX)

-- | Box-test face clipping ('Nds.Gpu3D.Polygon.Clip.clipPolygon' on the
-- position-only face, as 'Nds.Gpu3D.GeometryHw').
data BoxSt = BoxSt
  { bxFace  :: !(Unsigned 3)
  , bxComp  :: !(Unsigned 2)    -- ^ 2 Z, 1 Y, 0 X
  , bxNeg   :: !Bool            -- ^ the -W half of the pass
  , bxI     :: !(Unsigned 4)
  , bxN     :: !(Unsigned 4)
  , bxC     :: !(Unsigned 4)
  , bxNext  :: !Bool            -- ^ the segment is towards the next neighbour
  , bxK     :: !(Unsigned 2)    -- ^ component being interpolated
  , bxV     :: !Row             -- ^ the outside vertex
  , bxO     :: !Row             -- ^ the inside neighbour; then the interpolated vertex
  , bxQ     :: !ClipQ
  , bxQNeg  :: !Bool
  } deriving (Eq, Show, Generic, NFDataX)

-- | A read in flight between issue and data.
data Tag
  = TNone
  | TLoadS                                  -- ^ scalar row for the clip program
  | TTerm !Bool !Bool !Sel !Dst             -- ^ first, last, scalar, destination
  | TLit !(Unsigned 2) !(Unsigned 3) !Bool  -- ^ lighting step: light, step, last light
  | TSeg                                    -- ^ box-test interpolation product
  | TRead !(Index 4)                        -- ^ result read, lane
  | TVt0                                    -- ^ @VEC_RESULT@ x | y << 16
  | TVt1                                    -- ^ @VEC_RESULT@ z
  | TZero                                   -- ^ result read of a constant-zero word
  deriving (Eq, Show, Generic, NFDataX)

-- | Products on their way to the accumulate stage.
data ATag = ANone | ATerm !Bool !Bool !Dst | ALit !(Unsigned 2) !(Unsigned 3) !Bool | ASeg
  deriving (Eq, Show, Generic, NFDataX)

-- | Sequencer and matrix-side architectural registers.
data Ctrl = Ctrl
  { gCtl    :: !Ctl
  , gOp     :: !(BitVector 8)
  , gMode   :: !(Unsigned 2)
  , gSlot   :: !(Unsigned 5)
  , gU      :: !(Unsigned 3)
  , gR      :: !(Unsigned 2)
  , gK      :: !(Unsigned 2)
  , gLoadS  :: !Bool                -- ^ the current row starts with its scalar-row read
  , gCount  :: !(Unsigned 6)        -- ^ @ExecParamCount@
  , gP0     :: !(BitVector 32)      -- ^ gathered words 0-2
  , gP1     :: !(BitVector 32)
  , gP2     :: !(BitVector 32)
  , gArg    :: !(BitVector 32)      -- ^ the parameter of the last single-word command
  , gProjSP :: !Bool
  , gTexSP  :: !Bool
  , gPosSP  :: !(Unsigned 6)
  , gErr    :: !Bool
  , gBoxRes :: !Bool
  , gSwap   :: !Bool                -- ^ waiting for VBlank after @SWAP_BUFFERS@
  , gBx     :: !BoxSt
  } deriving (Eq, Show, Generic, NFDataX)

-- | @Viewport[0..5]@.
data Vp = Vp
  { vpX0, vpY0, vpX1, vpY1 :: !(Unsigned 8)
  , vpW :: !(Unsigned 9)
  , vpH :: !(Unsigned 8)
  } deriving (Eq, Show, Generic, NFDataX)

-- | Vertex-side and material architectural registers.
data Regs = Regs
  { rCurV     :: !(Vec 3 S16)            -- ^ @CurVertex@
  , rColor    :: !Rgb                    -- ^ @VertexColor@
  , rTex      :: !(Vec 2 S16)            -- ^ @TexCoords@
  , rRaw      :: !(Vec 2 S16)            -- ^ @RawTexCoords@
  , rAttr     :: !(BitVector 32)         -- ^ @PolygonAttr@
  , rCur      :: !(BitVector 32)         -- ^ @CurPolygonAttr@
  , rTexP     :: !(BitVector 32)         -- ^ @TexParam@
  , rPal      :: !(BitVector 13)         -- ^ @TexPalette@
  , rVp       :: !Vp
  , rDif      :: !Rgb                    -- ^ @MatDiffuse@
  , rAmb      :: !Rgb                    -- ^ @MatAmbient@
  , rSpe      :: !Rgb                    -- ^ @MatSpecular@
  , rEmi      :: !Rgb                    -- ^ @MatEmission@
  , rUseShine :: !Bool                   -- ^ @UseShininessTable@
  , rLCol     :: !(Vec 4 Rgb)            -- ^ @LightColor@
  } deriving (Eq, Show, Generic, NFDataX)

-- | Lighting temporaries, the transformed normal, the light direction of a
-- @LIGHT_VECTOR@ and the divider.
data Aux = Aux
  { aNt     :: !(Vec 3 S11)              -- ^ @normaltrans@
  , aDot    :: !(Signed 16)              -- ^ the light's dot product
  , aMdlc   :: !(Vec 3 (Unsigned 10))    -- ^ diffuse x light colour
  , aMslc   :: !(Vec 3 (Unsigned 10))    -- ^ specular x light colour
  , aMalc   :: !(Vec 3 (Unsigned 10))    -- ^ ambient x light colour
  , aD2     :: !(Unsigned 10)
  , aDiff   :: !(Vec 3 (Unsigned 20))
  , aShine0 :: !(Unsigned 10)            -- ^ @shinelevel@ before the table
  , aBuf    :: !(Vec 3 (Unsigned 24))    -- ^ the colour accumulator
  , aLDir   :: !(Vec 3 S11)
  , aDiv    :: !DivSt
  } deriving (Eq, Show, Generic, NFDataX)

-- | The data and accumulate stages and the vertex results.
data Pipe = Pipe
  { gTagD   :: !Tag
  , gS      :: !Row                   -- ^ latched row (clip update; gathered words for staging)
  , gTagA   :: !ATag
  , gProd   :: !(Vec 4 (Signed 44))
  , gAcc    :: !(Vec 4 (Signed 44))
  , gPosO   :: !Row                   -- ^ clip-space position of the vertex being made
  , gTex3   :: !(Vec 2 S16)           -- ^ its mode-3 texture coordinates
  , gStg    :: !(Vec 3 S32)           -- ^ gathered words of the staging row being filled
  } deriving (Eq, Show, Generic, NFDataX)

-- | The whole register state, as five registers built separately in
-- 'gmStep': were the pipeline, vertex, lighting or event fields a record
-- update of the control state (a case over the sequencer phase), Clash would
-- copy their logic, multipliers included, into every phase's alternative
-- (observed once: 16 multipliers, 49 DSP blocks, where four are needed).
data Gm = Gm { gC :: !Ctrl, gV :: !Regs, gA :: !Aux, gP :: !Pipe, gO :: !(Maybe HwGeoEvent) }
  deriving (Eq, Show, Generic, NFDataX)

gmInit :: Gm
gmInit = Gm
  (Ctrl { gCtl = CInit 0, gOp = 0, gMode = 0, gSlot = 0, gU = 0, gR = 0, gK = 0, gLoadS = False
        , gCount = 0, gP0 = 0, gP1 = 0, gP2 = 0, gArg = 0, gProjSP = False, gTexSP = False, gPosSP = 0
        , gErr = False, gBoxRes = False, gSwap = False
        , gBx = BoxSt 0 2 False 0 4 0 False 0 (repeat 0) (repeat 0) (ClipQ 0 0 False False False) False })
  (Regs { rCurV = repeat 0, rColor = repeat 0, rTex = repeat 0, rRaw = repeat 0, rAttr = 0, rCur = 0
        , rTexP = 0, rPal = 0, rVp = Vp 0 0 0 0 0 0, rDif = repeat 0, rAmb = repeat 0, rSpe = repeat 0
        , rEmi = repeat 0, rUseShine = False, rLCol = repeat (repeat 0) })
  (Aux { aNt = repeat 0, aDot = 0, aMdlc = repeat 0, aMslc = repeat 0, aMalc = repeat 0, aD2 = 0
       , aDiff = repeat 0, aShine0 = 0, aBuf = repeat 0, aLDir = repeat 0, aDiv = divIdle })
  (Pipe { gTagD = TNone, gS = repeat 0, gTagA = ANone, gProd = repeat 0, gAcc = repeat 0
        , gPosO = repeat 0, gTex3 = repeat 0, gStg = repeat 0 })
  Nothing

-- | The architectural matrix mode (testbench diagnostics).
gmMode :: Gm -> Unsigned 2
gmMode = gMode . gC

-- | Projection, position and texture stack pointers and the stack error
-- (testbench diagnostics).
gmPointers :: Gm -> (Word8, Word8, Word8, Bool)
gmPointers (Gm g _ _ _ _) = (if gProjSP g then 1 else 0, fromIntegral (gPosSP g), if gTexSP g then 1 else 0, gErr g)

-- | Current vertex, colour, texture coordinates, raw texture coordinates,
-- polygon attribute, latched attribute, texture parameter, palette and
-- viewport (testbench diagnostics), in the model's integer types.
gmVertexRegs
  :: Gm
  -> ( (Int16, Int16, Int16), (Word8, Word8, Word8), (Int16, Int16), (Int16, Int16)
     , Word32, Word32, Word32, Word32, (Word32, Word32, Word32, Word32, Word32, Word32) )
gmVertexRegs (Gm _ v _ _ _) =
  ( (i (c 0), i (c 1), i (c 2)), rgbW (rColor v)
  , (i (rTex v !! (0 :: Int)), i (rTex v !! (1 :: Int))), (i (rRaw v !! (0 :: Int)), i (rRaw v !! (1 :: Int)))
  , w (rAttr v), w (rCur v), w (rTexP v), w (rPal v)
  , (w (vpX0 vp), w (vpY0 vp), w (vpX1 vp), w (vpY1 vp), w (vpW vp), w (vpH vp)) )
  where
    c k = rCurV v !! (k :: Int)
    vp = rVp v
    i :: S16 -> Int16
    i = fromIntegral
    w :: (BitPack a, KnownNat (BitSize a)) => a -> Word32
    w = fromIntegral . pack

-- | Light colours, diffuse, ambient, specular and emission colours, the
-- shininess-table enable, the box-test result and the swap wait (testbench
-- diagnostics).
gmLightRegs
  :: Gm
  -> ( [(Word8, Word8, Word8)], (Word8, Word8, Word8), (Word8, Word8, Word8), (Word8, Word8, Word8)
     , (Word8, Word8, Word8), Bool, Bool, Bool )
gmLightRegs (Gm g v _ _ _) =
  ( toList (map rgbW (rLCol v)), rgbW (rDif v), rgbW (rAmb v), rgbW (rSpe v), rgbW (rEmi v)
  , rUseShine v, gBoxRes g, gSwap g )

rgbW :: Rgb -> (Word8, Word8, Word8)
rgbW c = (f 0, f 1, f 2)
  where
    f :: Int -> Word8
    f k = fromIntegral (c !! k)

-- Constructor tests by pattern match, never by '==': derived equality on a
-- sum type compares the whole packed word, and the generated Verilog leaves
-- the unused payload bits of a constructor undefined, so an '==' that the
-- Clash simulation answers would be x in the netlist.
isIdleC, isEmitC, isDivC :: Ctl -> Bool
isIdleC c = case c of { CIdle -> True; _ -> False }
isEmitC c = case c of { CEmit -> True; _ -> False }
isDivC c = case c of { CDiv -> True; _ -> False }

isSegMulC :: Ctl -> Bool
isSegMulC c = case c of { CBox BxSegMul -> True; _ -> False }

isNoneD, isLoadS :: Tag -> Bool
isNoneD t = case t of { TNone -> True; _ -> False }
isLoadS t = case t of { TLoadS -> True; _ -> False }

isNoneA :: ATag -> Bool
isNoneA t = case t of { ANone -> True; _ -> False }

pipeEmpty :: Pipe -> Bool
pipeEmpty p = isNoneD (gTagD p) && isNoneA (gTagA p)

idle :: Ctrl -> Pipe -> Bool
idle g p = isIdleC (gCtl g) && pipeEmpty p

texMode :: Regs -> BitVector 2
texMode v = slice d31 d30 (rTexP v)

-- | Sequencer position at the start of the first program at or after slot
-- @i@ (Nothing: the command's programs are done).
startOf :: BitVector 2 -> Ctrl -> Unsigned 3 -> Maybe (Unsigned 3, Unsigned 2, Unsigned 2, Bool)
startOf tm g i = case nextProg (progOf (gOp g) (gMode g) (gSlot g) tm) i of
  Nothing -> Nothing
  Just (j, u) ->
    let (r0, _) = rowsOf (uShape u)
        (k0, _) = termsOf (uShape u) r0
    in Just (j, r0, k0, isClipSh (uShape u))

-- | First enabled light at or after @l@ (latched attribute bits 0-3).
lightFrom :: BitVector 32 -> Unsigned 3 -> Maybe (Unsigned 2)
lightFrom attr l
  | l <= 0 && testBit attr 0 = Just 0
  | l <= 1 && testBit attr 1 = Just 1
  | l <= 2 && testBit attr 2 = Just 2
  | l <= 3 && testBit attr 3 = Just 3
  | otherwise = Nothing

-- | Run the next program, or finish: emit the command's event, light the
-- normal, divide, clip the box faces, or go idle. @attr@ is the latched
-- polygon attribute (its enabled lights).
enter :: BitVector 32 -> Maybe (Unsigned 3, Unsigned 2, Unsigned 2, Bool) -> Ctrl -> Ctrl
enter attr m g = case m of
  Nothing -> g { gCtl = finish }
  Just (i, r, k, s) -> g { gCtl = CRun, gU = i, gR = r, gK = k, gLoadS = s }
  where
    op = gOp g
    finish
      | emits op = CEmit
      | op == 0x21 = maybe CIdle (\l -> CLight l 7) (lightFrom attr 0)
      | op == 0x32 = CDiv
      | op == 0x70 = CBox BxStart
      | otherwise = CIdle

-- | Matrix-side bookkeeping of a command taken with parameter @p@ (the
-- model's pointer and error updates) and the stack slot its programs use.
bookkeep :: Word8 -> Word32 -> Ctrl -> Ctrl
bookkeep c p g = case c of
  0x10 -> g { gMode = unpack (truncateB (pack p)) }
  0x11 -> case m of
    0 -> g { gErr = gErr g || gProjSP g, gProjSP = not (gProjSP g) }
    3 -> g { gErr = gErr g || gTexSP g, gTexSP = not (gTexSP g) }
    _ -> g { gErr = gErr g || sp > 30, gSlot = truncateB sp, gPosSP = sp + 1 }
  0x12 -> case m of
    0 -> g { gErr = gErr g || not (gProjSP g), gProjSP = not (gProjSP g) }
    3 -> g { gErr = gErr g || not (gTexSP g), gTexSP = not (gTexSP g) }
    _ -> let off = unpack (truncateB (pack p)) :: Unsigned 6
             sp' = sp - off
         in g { gErr = gErr g || sp' > 30, gSlot = truncateB sp', gPosSP = sp' }
  _ | c == 0x13 || c == 0x14 -> case m of
        0 -> g
        3 -> g
        _ -> g { gErr = gErr g || a == 31, gSlot = a }
  _ -> g
  where
    m = gMode g
    sp = gPosSP g
    a = unpack (truncateB (pack p)) :: Unsigned 5

lo16, hi16 :: BitVector 32 -> S16
lo16 p = unpack (slice d15 d0 p)
hi16 p = unpack (slice d31 d16 p)

-- | A 10-bit field placed in bits 6-15 (@VTX_10@).
at6 :: BitVector 10 -> S16
at6 f = unpack (f ++# (0 :: BitVector 6))

-- | The three sign-extended 10-bit fields of a @VTX_DIFF@, @NORMAL@,
-- @LIGHT_VECTOR@ or @VEC_TEST@ word.
sext10 :: BitVector 32 -> Vec 3 S16
sext10 p = map (\f -> resize (unpack f :: Signed 10)) (slice d9 d0 p :> slice d19 d10 p :> slice d29 d20 p :> Nil)

-- | The three 5-bit colour fields of a word.
rgb5 :: BitVector 32 -> Rgb
rgb5 p = unpack (slice d4 d0 p) :> unpack (slice d9 d5 p) :> unpack (slice d14 d10 p) :> Nil

-- | @VIEWPORT@ decoded into @Viewport[6]@ (x0, flipped y0, x1, flipped y1,
-- width, height), as 'Nds.Gpu3D.Geometry.cmdViewport'.
viewport :: BitVector 32 -> Vp
viewport p = Vp v0 v1 v2 v3 v4 v5
  where
    v0 = unpack (slice d7 d0 p)
    v1 = 191 - unpack (slice d15 d8 p)
    v2 = unpack (slice d23 d16 p)
    v3 = 191 - unpack (slice d31 d24 p)
    v4 = resize v2 - resize v0 + 1
    v5 = v1 - v3 + 1

-- | Box-test corner @r@ (melonDS @cube[r]@), coordinate @j@: the parameter
-- words hold @x0 y0 z0 w h d@ as signed halfwords; the far corner is
-- @(x0 + w, y0 + h, z0 + d)@ in 16-bit arithmetic.
cornerCoord :: BitVector 32 -> BitVector 32 -> BitVector 32 -> Unsigned 3 -> Index 3 -> S16
cornerCoord p0 p1 p2 r j =
  let x0 = lo16 p0; y0 = hi16 p0; z0 = lo16 p1
      x1 = hi16 p1 + x0; y1 = lo16 p2 + y0; z1 = hi16 p2 + z0
      xs = 0b11000110 :: BitVector 8   -- bit r: corner r takes the far x
      ys = 0b10011100 :: BitVector 8
      zs = 0b11110000 :: BitVector 8
      pick sel a b = if sel ! r == 1 then b else a
  in case j of
       0 -> pick xs x0 x1
       1 -> pick ys y0 y1
       _ -> pick zs z0 z1

-- | Vertex-side effect of a command taken with parameter @p@ and the first
-- two gathered words @p0@, @p1@ (a @VTX_16@ completed by a later entry of an
-- interleaved gather reads words 0 and 1, as @ExecParams@ does).
regsTake :: Word8 -> BitVector 32 -> BitVector 32 -> BitVector 32 -> BitVector 2 -> Regs -> Regs
regsTake c p p0 p1 tm v = case c of
  0x20 -> v { rColor = rgb5 p }
  0x21 -> if slice d3 d0 (rCur v) == 0 then v { rColor = rEmi v } else v
  0x22 -> let raw = lo16 p :> hi16 p :> Nil
          in v { rRaw = raw, rTex = if tm == 1 then rTex v else raw }
  0x23 -> v { rCurV = lo16 p0 :> hi16 p0 :> lo16 p1 :> Nil }
  0x24 -> v { rCurV = at6 (slice d9 d0 p) :> at6 (slice d19 d10 p) :> at6 (slice d29 d20 p) :> Nil }
  0x25 -> v { rCurV = replace (1 :: Int) (hi16 p) (replace (0 :: Int) (lo16 p) cur) }
  0x26 -> v { rCurV = replace (2 :: Int) (hi16 p) (replace (0 :: Int) (lo16 p) cur) }
  0x27 -> v { rCurV = replace (2 :: Int) (hi16 p) (replace (1 :: Int) (lo16 p) cur) }
  0x28 -> v { rCurV = zipWith (+) cur (sext10 p) }
  0x29 -> v { rAttr = p }
  0x2A -> v { rTexP = p }
  0x2B -> v { rPal = slice d12 d0 p }
  0x30 -> v { rDif = rgb5 p, rAmb = rgb5 (p `shiftR` 16), rColor = if testBit p 15 then rgb5 p else rColor v }
  0x31 -> v { rSpe = rgb5 p, rEmi = rgb5 (p `shiftR` 16), rUseShine = testBit p 15 }
  0x33 -> v { rLCol = replace (unpack (slice d31 d30 p) :: Unsigned 2) (rgb5 p) (rLCol v) }
  0x40 -> v { rCur = rAttr v }
  0x60 -> v { rVp = viewport p }
  0x71 -> v { rCurV = lo16 p0 :> hi16 p0 :> lo16 p1 :> Nil }
  _ -> v
  where cur = rCurV v

------------------------------------------------------------------------------
-- Lighting

u2s :: KnownNat n => Unsigned n -> S32
u2s x = unpack (resize (pack x))

-- | Low bits of a non-negative (or two's-complement wrapped) sum.
lowU :: forall n. KnownNat n => Signed 44 -> Unsigned n
lowU x = unpack (resize (pack x))

-- | @shinelevel@ before the table, from @d2 * SpecRecip@ (0 when the light
-- does not reach the surface).
shine0Of :: Signed 44 -> Bool -> Unsigned 10
shine0Of x lit =
  let s = truncateB (x `shiftR` 8) - 512 :: S32
      e = truncateB s :: Signed 14
  in if not lit || s < 0 || e < 0 then 0 else if e > 0x1FF then 0x1FF else unpack (resize (pack e))

-- | The lanes' operands of lighting step @s@ for light @l@ (melonDS
-- @CalculateLighting@, 'Nds.Gpu3D.Geometry.Lighting.lightColour'); @lrow@
-- is the light's row (steps 0-4) or the shininess-table row (step 6).
-- Issue cycles per light, products in the data stage, results in the
-- accumulate stage two cycles after issue:
--
-- * 0: @l . n@ (3 lanes), diffuse x colour (red)
-- * 1: diffuse x colour (green, blue), specular x colour (red, green)
-- * 2: @d1^2@, red diffuse x @diffdot@, specular x colour (blue), ambient x colour (red)
-- * 3: green and blue diffuse x @diffdot@, ambient x colour (green, blue)
-- * 4: @d2 * SpecRecip@
-- * 5: (nothing: @shinelevel@ is formed in the accumulate stage)
-- * 6: the shininess-table row read issued, then specular x colour x shine (3 lanes)
--
-- The two operand vectors are separate functions, never a pair: Clash
-- turns a case over a pair that is then taken apart into one copy of the
-- consumer per alternative, which here is the multipliers.
litA :: Regs -> Aux -> Row -> Unsigned 3 -> Vec 4 S32
litA v a lrow s = case s of
  0 -> (lrow !! i0) :> (lrow !! i1) :> (lrow !! i2) :> u2s (md !! i0) :> Nil
  1 -> u2s (md !! i1) :> u2s (md !! i2) :> u2s (ms !! i0) :> u2s (ms !! i1) :> Nil
  2 -> litD1 a :> u2s (aMdlc a !! i0) :> u2s (ms !! i2) :> u2s (ma !! i0) :> Nil
  3 -> u2s (aMdlc a !! i1) :> u2s (aMdlc a !! i2) :> u2s (ma !! i1) :> u2s (ma !! i2) :> Nil
  4 -> u2s (aD2 a) :> 0 :> 0 :> 0 :> Nil
  _ -> u2s (aMslc a !! i0) :> u2s (aMslc a !! i1) :> u2s (aMslc a !! i2) :> 0 :> Nil
  where
    i0 = 0 :: Int
    i1 = 1 :: Int
    i2 = 2 :: Int
    md = rDif v
    ms = rSpe v
    ma = rAmb v

litB :: Regs -> Aux -> Row -> Unsigned 2 -> Unsigned 3 -> Vec 4 S32
litB v a lrow l s = case s of
  0 -> nt i0 :> nt i1 :> nt i2 :> u2s (lc !! i0) :> Nil
  1 -> u2s (lc !! i1) :> u2s (lc !! i2) :> u2s (lc !! i0) :> u2s (lc !! i1) :> Nil
  2 -> litD1 a :> dd :> u2s (lc !! i2) :> u2s (lc !! i0) :> Nil
  3 -> dd :> dd :> u2s (lc !! i1) :> u2s (lc !! i2) :> Nil
  4 -> (lrow !! (3 :: Int)) :> 0 :> 0 :> 0 :> Nil
  _ -> sh :> sh :> sh :> 0 :> Nil
  where
    i0 = 0 :: Int
    i1 = 1 :: Int
    i2 = 2 :: Int
    lc = rLCol v !! l
    nt i = resize (aNt a !! i) :: S32
    dd = resize (truncateB (aDot a) :: S11) :: S32
    s0 = aShine0 a
    idx = s0 `shiftR` 2
    -- the table byte: word (idx / 4) of the row, byte (idx mod 4), little-endian
    bytes = reverse (unpack (pack (lrow !! (truncateB (idx `shiftR` 2) :: Unsigned 2))) :: Vec 4 (BitVector 8))
    byte = bytes !! (truncateB idx :: Unsigned 2)
    sh = if rUseShine v then u2s (resize (unpack byte :: Unsigned 8) `shiftL` 1 :: Unsigned 10) else u2s s0

-- | @d1 = ((dot + normaltrans[2]) << 21) >> 21@.
litD1 :: Aux -> S32
litD1 a = resize (truncateB (aDot a + resize (aNt a !! (2 :: Int))) :: S11)

------------------------------------------------------------------------------
-- Box test

-- | Box faces (front, back, left, right, bottom, top) as corners.
faceCorner :: Unsigned 3 -> Unsigned 4 -> RowAddr
faceCorner f i = case f of
  0 -> pick 0 1 2 3
  1 -> pick 4 5 6 7
  2 -> pick 0 3 4 5
  3 -> pick 1 2 7 6
  4 -> pick 0 1 6 5
  _ -> pick 2 3 4 7
  where
    pick a b c d = case truncateB i :: Unsigned 2 of
      0 -> a
      1 -> b
      2 -> c
      _ -> d

boxPrev, boxNext :: BoxSt -> Unsigned 4
boxPrev b = if bxI b == 0 then bxN b - 1 else bxI b - 1
boxNext b = if bxI b + 1 >= bxN b then 0 else bxI b + 1

-- | The rows a half reads (the corners, then the clip buffers in turn) and
-- writes.
boxInRow :: BoxSt -> Unsigned 4 -> RowAddr
boxInRow b i
  | not (bxNeg b) && bxComp b == 2 = rowCorner + faceCorner (bxFace b) i
  | bxNeg b = rowBufB + resize i
  | otherwise = rowBufA + resize i

boxOutRow :: BoxSt -> RowAddr
boxOutRow b = (if bxNeg b then rowBufA else rowBufB) + resize (bxC b)

-- | The row a phase reads (issued the cycle before it).
boxReadRow :: BoxSt -> BoxCtl -> RowAddr
boxReadRow b c = case c of
  BxV -> boxInRow b (bxI b)
  BxP -> boxInRow b (boxPrev b)
  BxN -> boxInRow b (boxNext b)
  _ -> 0

-- | The position components a segment interpolates in this pass (only those
-- a later pass reads: X, Y, W after Z; X, W after Y; W after X), and the
-- index of the last.
segComp :: Unsigned 2 -> Unsigned 2 -> Index 4
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

boxOutside :: BoxSt -> Row -> Bool
boxOutside b v =
  let c = v !! bxComp b
      w = v !! (3 :: Int)
  in if bxNeg b then c < negate w else c > w

-- | The X pass's -W half keeps a polygon exactly when one of the vertices its
-- +W half wrote has @x >= -w@ (a kept vertex, or the neighbour of an
-- intersection), so the box test needs no -W half for X.
insideNegX :: Row -> Bool
insideNegX v = (v !! (0 :: Int)) >= negate (v !! (3 :: Int))

data BoxNext = BNext !BoxCtl | BDone !Bool

-- | One cycle of face clipping (Z, then Y, then X, as 'clipPolygon'): the
-- phase, the state, the row read for this phase, the far-plane bit of the
-- latched attribute, whether the pipeline is empty and the divider. Returns
-- the state, the next phase or the result, and a clip-buffer write. A new
-- half or face goes through 'BxTurn', so no row is read in the cycle it is
-- written.
boxStep :: BoxCtl -> BoxSt -> Row -> Bool -> Bool -> DivSt -> (BoxSt, BoxNext, Maybe (RowAddr, Row))
boxStep c b row far quietP dv = case c of
  BxStart
    | quietP -> (faceInit 0, BNext BxTurn, Nothing)
    | otherwise -> (b, BNext BxStart, Nothing)
  BxTurn -> (b, BNext BxV, Nothing)
  BxV
    | boxOutside b row ->
        if not (bxNeg b) && bxComp b == 2 && not far then faceFail Nothing
        else (b { bxV = row }, BNext BxP, Nothing)
    | bxC b < 10 -> written (b { bxC = bxC b + 1 }) row (Just (boxOutRow b, row))
    | otherwise -> advance b Nothing
  BxP
    | not (boxOutside b row) && bxC b < 10 -> (b { bxO = row, bxNext = False }, BNext BxSegF, Nothing)
    | otherwise -> (b, BNext BxN, Nothing)
  BxN
    | not (boxOutside b row) && bxC b < 10 -> (b { bxO = row, bxNext = True }, BNext BxSegF, Nothing)
    | otherwise -> advance b Nothing
  BxSegF ->
    let comp = bxComp b
        q = clipQ (not (bxNeg b)) (bxV b !! comp) (bxV b !! i3) (bxO b !! comp) (bxO b !! i3)
    in (b { bxQ = q, bxK = 0 }, BNext BxSegMul, Nothing)
  BxSegMul -> (b { bxQNeg = segQNeg (bxQ b) (bxV b !! j) (bxO b !! j) }, BNext BxSegWait, Nothing)
  BxSegWait
    | not (quietP && dvValid dv) -> (b, BNext BxSegWait, Nothing)
    | otherwise ->
        let b' = b { bxO = replace j (segResult (bxV b !! j) (bxQNeg b) (dvQuo dv)) (bxO b) }
        in if bxK b == segLast (bxComp b) then (b', BNext BxSegWrite, Nothing)
           else (b' { bxK = bxK b + 1 }, BNext BxSegMul, Nothing)
  BxSegWrite ->
    let w3 = bxO b !! i3
        r' = replace (bxComp b) (if bxNeg b then negate w3 else w3) (bxO b)
        b' = b { bxC = bxC b + 1 }
        wr = Just (boxOutRow b, r')
    in if bxNext b then written b' r' wr
       else if xPos && insideNegX r' then (b', BDone True, wr)
       else (b', BNext BxN, wr)
  where
    i3 = 3 :: Int
    j = segComp (bxComp b) (bxK b)
    xPos = bxComp b == 0 && not (bxNeg b)
    faceInit f = b { bxFace = f, bxComp = 2, bxNeg = False, bxI = 0, bxN = 4, bxC = 0 }
    faceFail wr
      | bxFace b == 5 = (b, BDone False, wr)
      | otherwise = (faceInit (bxFace b + 1), BNext BxTurn, wr)
    written b1 v wr
      | xPos && insideNegX v = (b1, BDone True, wr)
      | otherwise = advance b1 wr
    advance b1 wr
      | bxI b1 + 1 >= bxN b1 = halfEnd b1 wr
      | otherwise = (b1 { bxI = bxI b1 + 1 }, BNext BxV, wr)
    halfEnd b1 wr
      | bxC b1 == 0 || xPos = faceFail wr
      | not (bxNeg b1) = (b1 { bxNeg = True, bxN = bxC b1, bxI = 0, bxC = 0 }, BNext BxTurn, wr)
      | otherwise = (b1 { bxComp = bxComp b1 - 1, bxNeg = False, bxN = bxC b1, bxI = 0, bxC = 0 }, BNext BxTurn, wr)

------------------------------------------------------------------------------
-- Result port

-- | The read a bus address makes: row and how the word is formed.
readOf :: BitVector 32 -> (RowAddr, Tag)
readOf addr
  | a >= 0x04000620 && a <= 0x0400062C = (rowPosRes, TRead (fromIntegral (slice d3 d2 a)))
  | a == 0x04000630 = (rowVecRes, TVt0)
  | a == 0x04000634 = (rowVecRes, TVt1)
  | a >= 0x04000640 && a < 0x04000680 =
      let e = unpack (truncateB (a `shiftR` 2)) :: Unsigned 4
      in (rowClip + resize (e `shiftR` 2), TRead (fromIntegral (e .&. 3)))
  | a >= 0x04000680 && a <= 0x040006A0 =
      let jj = unpack (truncateB ((a - 0x04000680) `shiftR` 2)) :: Unsigned 4
          (rq, lq) = div3 jj
      in (rowVec + resize rq, TRead lq)
  | otherwise = (0, TZero)
  where
    a = addr .&. complement 3
    div3 :: Unsigned 4 -> (Unsigned 2, Index 4)
    div3 jj
      | jj < 3 = (0, fromIntegral jj)
      | jj < 6 = (1, fromIntegral (jj - 3))
      | otherwise = (2, fromIntegral (jj - 6))

------------------------------------------------------------------------------
-- Step

-- | One clock: registers, outputs and RAM ports. @q@ is the RAM data for the
-- addresses the previous cycle drove.
gmStep :: Gm -> GmIn -> RamQ -> (Gm, GmOut, RamOps)
gmStep (Gm g v a p o) inp q = (Gm g' v' a' p' o', out, ops)
  where
    ctl = gCtl g
    quiet = idle g p
    ready = quiet && not (gSwap g)
    tm = texMode v
    attr = rCur v
    rowQ = rqRow q
    i0 = 0 :: Int
    i1 = 1 :: Int
    i2 = 2 :: Int
    i3 = 3 :: Int

    -- issue --------------------------------------------------------------
    u = progOf (gOp g) (gMode g) (gSlot g) tm !! gU g
    sh = maybe ShCopy uShape u
    src = maybe 0 uSrc u
    dst = maybe (DRam 0) uDst u
    r = gR g
    k = gK g
    (_, rLast) = rowsOf sh
    (kFirst, kLast) = termsOf sh r
    (sel, pIx) = termSel sh r k
    dstRow = case dst of
      DRam ad -> DRam (ad + resize r)
      d -> d
    issueRow
      | gLoadS g = rowPos + resize r
      | otherwise = src + resize k
    issueTag
      | gLoadS g = TLoadS
      | otherwise = TTerm (k == kFirst) (k == kLast) sel dstRow
    -- the sequencer after this issue
    advanced
      | gLoadS g = g { gLoadS = False }
      | k /= kLast = g { gK = k + 1 }
      | r /= rLast =
          let r' = r + 1
              (k0, _) = termsOf sh r'
          in g { gR = r', gK = k0, gLoadS = isClipSh sh }
      | otherwise = enter attr (startOf tm g (gU g + 1)) g

    -- lighting sequence ------------------------------------------------------
    lightNext l s
      | s == 7 = CLight l 0
      | s /= 6 = CLight l (s + 1)
      | otherwise = maybe CIdle (\l' -> CLight l' 0) (lightFrom attr (resize l + 1))
    lit = aDot a > 0
    shine0c = shine0Of (gProd p !! i0) lit

    -- box test -----------------------------------------------------------------
    boxR = case ctl of
      CBox c -> Just (boxStep c (gBx g) rowQ (testBit attr 12) (pipeEmpty p) (aDiv a))
      _ -> Nothing
    boxRd = case boxR of
      Just (b', BNext c', _) -> boxReadRow b' c'
      _ -> 0
    boxWr = case boxR of
      Just (_, _, w) -> w
      Nothing -> Nothing

    -- LIGHT_VECTOR: the row once the reciprocal is ready
    lvDone = isDivC ctl && pipeEmpty p && dvValid (aDiv a)
    lvWr
      | lvDone = Just ( rowLight (unpack (slice d31 d30 (gArg g)))
                      , map resize (aLDir a) ++ (divSigned (aDiv a) :> Nil) )
      | otherwise = Nothing

    -- result read ----------------------------------------------------------
    rdTaken = quiet && isJust (giRead inp)
    (rdRow, rdTag) = maybe (0, TNone) readOf (giRead inp)

    -- entry ----------------------------------------------------------------
    taken = ready && isJust (giEntry inp)
    HwEntry ec ep = fromMaybe (HwEntry 0 0) (giEntry inp)
    epB = pack ep
    n = numParams ec
    gathered = n > 1
    cnt = gCount g
    count' = cnt + 1
    runs = not gathered || count' >= n
    execTake = taken && runs
    gatherTake = taken && gathered
    -- a single-parameter command runs without touching the gathered words
    p0' = if gathered && cnt == 0 then epB else gP0 g
    p1' = if gathered && cnt == 1 then epB else gP1 g
    p2' = if gathered && cnt == 2 then epB else gP2 g
    waits = (ec == 0x32 || ec == 0x70) && giStall inp
    afterEntry
      | not taken = g
      | not runs = g { gCount = count', gP0 = p0', gP1 = p1', gP2 = p2' }
      | otherwise =
          let g1 = bookkeep ec ep g { gOp = pack ec, gP0 = p0', gP1 = p1', gP2 = p2'
                                    , gArg = if gathered then gArg g else epB
                                    , gCount = if gathered then 0 else cnt
                                    , gBoxRes = gBoxRes g && ec /= 0x70 }
          in if waits then g1 { gCtl = CWait } else enter attr (startOf tm g1 0) g1
    prmWr
      | gatherTake = Just (truncateB cnt, unpack epB)
      | otherwise = Nothing
    -- every fourth gathered word completes a staging row (SHININESS copies
    -- the eight rows of its 32 words into the table)
    stageWr
      | gatherTake && slice d1 d0 (pack cnt) == 3 =
          Just (rowShStage + resize (cnt `shiftR` 2), gStg p ++ (unpack epB :> Nil))
      | otherwise = Nothing

    -- event ----------------------------------------------------------------
    emitting = isEmitC ctl
    emitNow = emitting && pipeEmpty p && isNothing o && not (gOp g == 0x40 && giStall inp)
    evTaken = isJust o && giEvReady inp
    event
      | gOp g == 0x40 = HeBegin (slice d1 d0 (gArg g))
      | gOp g == 0x41 = HeEnd
      | gOp g == 0x50 = HeSwap (slice d1 d0 (gArg g))
      | otherwise = HeVertex vertex polyState
    vertex = HwVertex
      { hvX = gPosO p !! i0, hvY = gPosO p !! i1, hvZ = gPosO p !! i2, hvW = gPosO p !! i3
      , hvR = rColor v !! i0, hvG = rColor v !! i1, hvB = rColor v !! i2
      , hvS = tex !! i0, hvT = tex !! i1 }
    tex = if tm == 3 then gTex3 p else rTex v
    polyState = HwPolyState
      { hpAttr = rCur v, hpTexParam = rTexP v, hpTexPalette = rPal v
      , hpVpX0 = vpX0 (rVp v), hpVpY0 = vpY0 (rVp v), hpVpX1 = vpX1 (rVp v), hpVpY1 = vpY1 (rVp v)
      , hpVpW = vpW (rVp v), hpVpH = vpH (rVp v), hpZeroDotW = giZeroDotW inp }
    o'
      | emitNow = Just event
      | evTaken = Nothing
      | otherwise = o

    -- data stage -----------------------------------------------------------
    tagD = gTagD p
    selScalar s = case s of
      SelParam -> rqParam q
      SelS i -> gS p !! i
      SelOne -> 0x1000
      SelUnit -> 1
      SelV i -> resize (rCurV v !! i)
      SelT i -> resize (rRaw v !! i)
      SelN i -> resize (sext10 (gArg g) !! i)
      SelC c i -> resize (cornerCoord (gP0 g) (gP1 g) (gP2 g) c i)
    scalar = case tagD of
      TTerm _ _ s _ -> selScalar s
      _ -> 0
    bx = gBx g
    segJ = segComp (bxComp bx) (bxK bx)
    -- the two operand vectors are separate cases, never one case over a
    -- pair (see 'litA')
    opA = case tagD of
      TLit _ s _ -> litA v a rowQ s
      TSeg -> segOpA (bxQ bx)
      _ -> repeat scalar
    opB = case tagD of
      TLit l s _ -> litB v a rowQ l s
      TSeg -> segOpB (bxV bx !! segJ) (bxO bx !! segJ)
      _ -> rowQ
    -- 32 x 32 -> 64-bit signed products, of which the 44 bits the
    -- accumulators keep (a sum of at most four terms, read at most up to
    -- bit 43); the four multipliers of the engine.
    prods = zipWith (\x y -> truncateB (x `mul` y)) opA opB :: Vec 4 (Signed 44)
    s'
      | isLoadS tagD = rowQ
      | otherwise = gS p
    half :: S32 -> BitVector 16
    half x = slice d15 d0 (pack x)
    rdData = case tagD of
      TRead l -> Just (rowQ !! l)
      TVt0 -> Just (unpack (half (rowQ !! i1) ++# half (rowQ !! i0)))
      TVt1 -> Just (unpack ((0 :: BitVector 16) ++# half (rowQ !! i2)))
      TZero -> Just 0
      _ -> Nothing
    tagA' = case tagD of
      TTerm f l _ d -> ATerm f l d
      TLit l s lst -> ALit l s lst
      TSeg -> ASeg
      _ -> ANone

    -- accumulate stage -----------------------------------------------------
    ps = gProd p
    (accFirst, accLast, accDst) = case gTagA p of
      ATerm f l d -> (f, l, Just d)
      _ -> (False, False, Nothing)
    acc' = if accFirst then ps else zipWith (+) (gAcc p) ps
    finished = map (\x -> truncateB (x `shiftR` 12)) acc' :: Row
    lanes01 = take d2 acc'
    lanes3 = take d3 acc'
    tex3 = zipWith (\x raw -> unpack (slice d39 d24 (pack x)) + raw) lanes01 (rRaw v) :: Vec 2 S16
    tex2 = zipWith (\x raw -> unpack (slice d36 d21 (pack x)) + raw) lanes01 (rRaw v) :: Vec 2 S16
    tc1 = map (\x -> unpack (slice d27 d12 (pack x))) lanes01 :: Vec 2 S16
    ntN = map (\x -> unpack (slice d22 d12 (pack x))) lanes3 :: Vec 3 S11
    lvDir = map (\x -> truncateB (negate (x `shiftR` 12))) lanes3 :: Vec 3 S11
    lvDen = 512 - resize (unpack (slice d22 d12 (pack (acc' !! i2))) :: S11) :: Signed 12
    vecT = map (\x -> let w = unpack (slice d24 d9 (pack x)) :: S16
                      in if testBit w 12 then w .|. unpack 0xF000 else w) lanes3
    finishes f = accLast && maybe False f accDst
    isPosD, isTex3D, isTc1D, isTex2D, isNormD, isLVecD :: Dst -> Bool
    isPosD d = case d of { DPos -> True; _ -> False }
    isTex3D d = case d of { DTex3 -> True; _ -> False }
    isTc1D d = case d of { DTc1 -> True; _ -> False }
    isTex2D d = case d of { DTex2 -> True; _ -> False }
    isNormD d = case d of { DNorm -> True; _ -> False }
    isLVecD d = case d of { DLVec -> True; _ -> False }
    accWr = case accDst of
      Just (DRam ad) | accLast -> Just (ad, finished)
      Just DVecT | accLast -> Just (rowVecRes, map resize vecT ++ (0 :> Nil))
      _ -> Nothing
    -- lighting results
    p0L = ps !! i0
    p1L = ps !! i1
    p2L = ps !! i2
    p3L = ps !! i3
    difOf x = if lit then lowU x else 0
    buf' = zipWith4 (\b df x ml -> b + resize df + lowU x + (resize ml `shiftL` 9))
             (aBuf a) (aDiff a) (take d3 ps) (aMalc a) :: Vec 3 (Unsigned 24)
    clampC x = let y = x `shiftR` 14 in if y > 31 then 31 else truncateB y :: U5
    auxLit = case gTagA p of
      ALit _ s _ -> case s of
        0 -> a { aDot = truncateB (sum (map (`shiftR` 9) (take d3 ps)))
               , aMdlc = replace i0 (lowU p3L) (aMdlc a) }
        1 -> a { aMdlc = (aMdlc a !! i0) :> lowU p0L :> lowU p1L :> Nil
               , aMslc = lowU p2L :> lowU p3L :> (aMslc a !! i2) :> Nil }
        2 -> a { aD2 = lowU (p0L `shiftR` 10), aDiff = replace i0 (difOf p1L) (aDiff a)
               , aMslc = replace i2 (lowU p2L) (aMslc a), aMalc = replace i0 (lowU p3L) (aMalc a) }
        3 -> a { aDiff = (aDiff a !! i0) :> difOf p0L :> difOf p1L :> Nil
               , aMalc = (aMalc a !! i0) :> lowU p2L :> lowU p3L :> Nil }
        4 -> a { aShine0 = shine0c }
        _ -> a { aBuf = buf' }
      _ -> a
    lastLight = case gTagA p of
      ALit _ 6 True -> True
      _ -> False
    -- the divider: started by LIGHT_VECTOR's last term or a box-test product
    divNext = case gTagA p of
      ATerm _ True d | isLVecD d -> divRecip lvDen
      ASeg -> segDiv (bxQ bx) (segProduct ps)
      _ | isSegMulC ctl -> (divStep (aDiv a)) { dvValid = False }
        | otherwise -> divStep (aDiv a)
    a1 | finishes isNormD = auxLit { aNt = ntN }
       | finishes isLVecD = auxLit { aLDir = lvDir }
       | otherwise = auxLit
    a2 = a1 { aDiv = divNext }
    a' = if execTake && ec == 0x21 then a2 { aBuf = map (\e -> resize e `shiftL` 14) (rEmi v) } else a2

    -- next state -----------------------------------------------------------
    seqNext = case ctl of
      CInit ad -> if ad == maxBound then g { gCtl = CIdle } else g { gCtl = CInit (ad + 1) }
      CIdle -> afterEntry
      CRun -> advanced
      CWait -> if giStall inp then g else enter attr (startOf tm g 0) g
      CEmit
        | emitNow -> g { gCtl = CIdle, gSwap = gSwap g || gOp g == 0x50 }
        | otherwise -> g
      CLight l s -> g { gCtl = lightNext l s }
      CDiv -> if lvDone then g { gCtl = CIdle } else g
      CBox _ -> case boxR of
        Just (b', BNext c', _) -> g { gCtl = CBox c', gBx = b' }
        Just (b', BDone res, _) -> g { gCtl = CIdle, gBx = b', gBoxRes = res }
        Nothing -> g
    unswapped = if giVblank inp && gSwap g && isNothing o then seqNext { gSwap = False } else seqNext
    g' = if giAck inp then unswapped { gErr = False, gProjSP = False, gTexSP = False } else unswapped
    vTaken = if execTake then regsTake ec epB p0' p1' tm v else v
    v1 | finishes isTc1D = vTaken { rTex = tc1 }
       | finishes isTex2D = vTaken { rTex = tex2 }
       | otherwise = vTaken
    v' = if lastLight then v1 { rColor = map clampC buf' } else v1
    p' = Pipe
      { gTagD = case ctl of
          CRun -> issueTag
          CLight l s
            | s <= 4 -> TLit l s False
            | s == 6 -> TLit l 6 (isNothing (lightFrom attr (resize l + 1)))
          CBox BxSegMul -> TSeg
          _ -> if rdTaken then rdTag else TNone
      , gS = s'
      , gStg = if gatherTake && slice d1 d0 (pack cnt) /= 3
                 then replace (truncateB cnt :: Unsigned 2) (unpack epB) (gStg p) else gStg p
      , gTagA = tagA'
      , gProd = prods
      , gAcc = if isJust accDst then acc' else gAcc p
      , gPosO = if finishes isPosD then finished else gPosO p
      , gTex3 = if finishes isTex3D then tex3 else gTex3 p
      }

    ops = RamOps
      { opRowRd = case ctl of
          CRun -> issueRow
          CLight l s -> if s == 6 then rowShine + resize (shine0c `shiftR` 6) else rowLight l
          CBox _ -> boxRd
          _ -> rdRow
      , opRowWr = case ctl of
          CInit ad -> Just (ad, initRow ad)
          _ -> firstJust (firstJust accWr boxWr) (firstJust lvWr stageWr)
      , opPrmRd = resize pIx
      , opPrmWr = prmWr
      }
    firstJust :: Maybe x -> Maybe x -> Maybe x
    firstJust (Just x) _ = Just x
    firstJust Nothing y = y

    busyCtl = not (isIdleC ctl && pipeEmpty p)
    out = GmOut
      { goReady = ready
      , goEvent = o
      , goStatus = GeoStatus
          { gsTestBusy = busyCtl && (gOp g == 0x70 || gOp g == 0x71 || gOp g == 0x72)
          , gsBoxResult = gBoxRes g
          , gsPosStack = fromIntegral (gPosSP g .&. 0x1F)
          , gsProjStack = gProjSP g
          , gsStackBusy = busyCtl && (gOp g == 0x11 || gOp g == 0x12)
          , gsStackError = gErr g
          , gsBusy = busyCtl || isJust o || gSwap g
          }
      , goSwapWait = gSwap g
      , goRdReady = quiet
      , goRdData = rdData
      }

------------------------------------------------------------------------------
-- Circuit

-- | The engine with its two block RAMs.
geoMatrix
  :: forall dom. KnownDomain dom
  => Clock dom -> Reset dom -> Enable dom
  -> Signal dom GmIn -> Signal dom GmOut
geoMatrix clk rst en inp = out
  where
    -- control, vertex registers, lighting, pipeline and event in their own
    -- registers (see 'Gm')
    reg :: NFDataX x => (Gm -> x) -> Signal dom x
    reg f = register clk rst en (f gmInit) (f <$> st')
    st = Gm <$> reg gC <*> reg gV <*> reg gA <*> reg gP <*> reg gO
    (st', out, ops) = unbundle (gmStep <$> st <*> inp <*> q)
    q = RamQ <$> rowQ <*> prmQ
    rowQ = blockRam clk en (replicate (SNat @512) (repeat 0)) (opRowRd <$> ops) (opRowWr <$> ops)
    prmQ = blockRam clk en (replicate (SNat @32) 0) (opPrmRd <$> ops) (opPrmWr <$> ops)

-- | 'GeoStatus' in its @GXSTAT@ bit positions (0, 1, 8-12, 13, 14, 15; busy
-- in bit 27), as 'Nds.Gpu3D.GeometryHw.statusBits'.
gmStatusBits :: GeoStatus -> BitVector 32
gmStatusBits s =
  let b c i = if c then bit i else 0
  in b (gsTestBusy s) 0 .|. b (gsBoxResult s) 1
     .|. (resize (pack (gsPosStack s) .&. 0x1F) `shiftL` 8)
     .|. b (gsProjStack s) 13 .|. b (gsStackBusy s) 14 .|. b (gsStackError s) 15 .|. b (gsBusy s) 27

-- | An event as flat bits, the same encoding as
-- 'Nds.Gpu3D.GeometryHw.eventBits' (tag 0 begin, 1 vertex, 2 end, 3 swap,
-- then the payload; 0 when there is no event).
gmEventBits :: Maybe HwGeoEvent -> BitVector 330
gmEventBits m = case m of
  Just (HeBegin b) -> (0b00 :: BitVector 2) ++# resize b
  Just (HeVertex x ps) -> (0b01 :: BitVector 2) ++# resize (pack x ++# pack ps)
  Just HeEnd -> (0b10 :: BitVector 2) ++# 0
  Just (HeSwap b) -> (0b11 :: BitVector 2) ++# resize b
  Nothing -> 0

data TopOut = TopOut
  { tReady    :: Bool
  , tEvValid  :: Bool
  , tEvent    :: BitVector 330
  , tStatus   :: BitVector 32
  , tSwapWait :: Bool
  , tRdReady  :: Bool
  , tRdValid  :: Bool
  , tRdData   :: BitVector 32
  } deriving (Generic, NFDataX)

{-# ANN geoMatrixTopEntity
  (Synthesize
    { t_name = "nds_gpu3d_geomtx"
    , t_inputs =
        [ PortName "CLK", PortName "RST", PortName "EN"
        , PortName "CMD_VALID", PortName "CMD_CMD", PortName "CMD_PARAM"
        , PortName "EV_READY", PortName "STALL", PortName "VBLANK", PortName "ACK", PortName "ZERO_DOT_W"
        , PortName "RD_VALID", PortName "RD_ADDR" ]
    , t_output = PortProduct ""
        [ PortName "CMD_READY", PortName "EV_VALID", PortName "EVENT", PortName "STATUS"
        , PortName "SWAP_WAIT", PortName "RD_READY", PortName "RD_DATA_VALID", PortName "RD_DATA" ]
    }) #-}
geoMatrixTopEntity
  :: Clock System -> Reset System -> Enable System
  -> Signal System Bool -> Signal System (BitVector 8) -> Signal System (BitVector 32)
  -> Signal System Bool -> Signal System Bool -> Signal System Bool -> Signal System Bool
  -> Signal System (BitVector 24)
  -> Signal System Bool -> Signal System (BitVector 32)
  -> Signal System TopOut
geoMatrixTopEntity clk rst en cv cc cp evr stl vbl ack zdw rv ra = top <$> geoMatrix clk rst en inp
  where
    entry valid c pr = if valid then Just (HwEntry (unpack c) (unpack pr)) else Nothing
    rd valid ad = if valid then Just ad else Nothing
    inp = GmIn <$> (entry <$> cv <*> cc <*> cp) <*> evr <*> stl <*> vbl <*> ack <*> (unpack <$> zdw)
               <*> (rd <$> rv <*> ra)
    top x = TopOut (goReady x) (isJust (goEvent x)) (gmEventBits (goEvent x)) (gmStatusBits (goStatus x))
                   (goSwapWait x) (goRdReady x) (isJust (goRdData x)) (maybe 0 pack (goRdData x))
{-# NOINLINE geoMatrixTopEntity #-}
