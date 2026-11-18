-- | Pure model of the NDS geometry engine's command execution, exactly as
-- melonDS's @GPU3D::ExecuteCommand@ and the helpers it calls
-- (@UpdateClipMatrix@, @SubmitVertex@ up to the @TempVertexBuffer@ store,
-- @CalculateLighting@, @BoxTest@, @PosTest@, @VecTest@), plus the two MMIO
-- writes that reach geometry state (@DISP_1DOT_DEPTH@ and the @GXSTAT@
-- bit-15 acknowledge) and the result-register reads at
-- @0x04000620@-@0x040006A3@.
--
-- The model is a state record ('GeoState') and one step per input
-- ('step'); each command is its own small function ('cmdMatrixMode',
-- 'cmdPush', ...) so a hardware datapath can follow it command by command.
-- Cycle timing is not modelled: the busy bits of 'geoStatus' are 'False'.
--
-- A 'GeoCmd' is one whole command, its parameter words gathered the way
-- @ExecuteCommand@ gathers @ExecParams@ (the front end does the gathering);
-- a parameterless command ignores its words. Polygon assembly (the
-- @PolygonMode@ switch, strip swaps and @SubmitPolygon@) is the next block:
-- this one emits a 'GeVertex' with the exact @ClipVertex@ @SubmitVertex@
-- stores and the 'PolyState' @SubmitPolygon@ would read at that moment.
module Nds.Gpu3D.Geometry
  ( GeoState (..)
  , GeoIn (..)
  , initGeoState
  , step
  , geoStatus
  , geoReadResult
  , geoRead32
  , geoRead16
  , polyState
  , currentClip
  , texCoordMode
    -- * Per-command steps
  , execCommand
  , cmdMatrixMode
  , cmdPush
  , cmdPop
  , cmdStore
  , cmdRestore
  , cmdMatrix
  , cmdColor
  , cmdNormal
  , cmdTexCoord
  , cmdVertex
  , cmdDifAmb
  , cmdSpeEmi
  , cmdLightVector
  , cmdLightColor
  , cmdShininess
  , cmdBegin
  , cmdViewport
  , cmdBoxTest
  , cmdPosTest
  , cmdVecTest
  , updateClip
  , submitVertex
  , calculateLighting
  ) where

import Data.Array (Array, elems, listArray, (!), (//))
import qualified Data.Array.Unboxed as U
import Data.Bits (complement, shiftL, shiftR, testBit, (.&.), (.|.))
import Data.Int (Int16, Int32, Int64)
import Data.Word (Word16, Word32, Word8)

import Nds.Gpu3D.Geometry.BoxTest (boxTest)
import Nds.Gpu3D.Geometry.Lighting
import Nds.Gpu3D.Geometry.Matrix
import Nds.Gpu3D.Types

-- | The geometry engine's architectural state (the @GPU3D@ members
-- @ExecuteCommand@ reads or writes, minus timing and polygon assembly).
data GeoState = GeoState
  { gMtxMode      :: !Word8                 -- ^ @MatrixMode@ (0-3)
  , gProj         :: !Mat                   -- ^ @ProjMatrix@
  , gPos          :: !Mat                   -- ^ @PosMatrix@
  , gVec          :: !Mat                   -- ^ @VecMatrix@
  , gTex          :: !Mat                   -- ^ @TexMatrix@
  , gClip         :: !Mat                   -- ^ @ClipMatrix@ as last computed
  , gClipDirty    :: !Bool                  -- ^ @ClipMatrixDirty@
  , gProjStack    :: !Mat                   -- ^ @ProjMatrixStack@ (one slot)
  , gTexStack     :: !Mat                   -- ^ @TexMatrixStack@ (one slot)
  , gPosStack     :: !(Array Int Mat)       -- ^ @PosMatrixStack[32]@
  , gVecStack     :: !(Array Int Mat)       -- ^ @VecMatrixStack[32]@
  , gProjSP       :: !Word8                 -- ^ @ProjMatrixStackPointer@ (0-1)
  , gPosSP        :: !Word8                 -- ^ @PosMatrixStackPointer@ (0-63)
  , gTexSP        :: !Word8                 -- ^ @TexMatrixStackPointer@ (0-1)
  , gStackError   :: !Bool                  -- ^ @GXStat@ bit 15
  , gBoxResult    :: !Bool                  -- ^ @GXStat@ bit 1
  , gCurVertex    :: !V3                    -- ^ @CurVertex@
  , gVertexColor  :: !Rgb5                  -- ^ @VertexColor@
  , gTexCoords    :: !(Int16, Int16)        -- ^ @TexCoords@
  , gRawTexCoords :: !(Int16, Int16)        -- ^ @RawTexCoords@
  , gNormal       :: !V3                    -- ^ @Normal@
  , gLights       :: !(Array Int Light)     -- ^ @LightDirection@, @SpecRecip@, @LightColor@
  , gMaterial     :: !Material              -- ^ @Mat*@, @UseShininessTable@, @ShininessTable@
  , gPolyAttr     :: !Word32                -- ^ @PolygonAttr@
  , gCurPolyAttr  :: !Word32                -- ^ @CurPolygonAttr@ (latched by @BEGIN_VTXS@)
  , gTexParam     :: !Word32                -- ^ @TexParam@
  , gTexPalette   :: !Word32                -- ^ @TexPalette@
  , gViewport     :: !(Word32, Word32, Word32, Word32, Word32, Word32) -- ^ @Viewport[6]@
  , gZeroDotW     :: !Word32                -- ^ @ZeroDotWLimit@
  , gPosTest      :: !(Int32, Int32, Int32, Int32) -- ^ @PosTestResult@
  , gVecTest      :: !V3                    -- ^ @VecTestResult@
  } deriving (Eq, Show)

-- | One input to the geometry engine.
data GeoIn
  = GeoCmd !Word8 ![Word32]
    -- ^ a whole command: opcode and its 'cmdNumParams' parameter words
    -- (missing words read as 0, extra words are ignored)
  | SetZeroDotW !Word32
    -- ^ the value written to @DISP_1DOT_DEPTH@ (16- or 32-bit write to
    -- @0x04000610@); the model masks it as melonDS does
  | AckStackError
    -- ^ a @GXSTAT@ write with bit 15 set (@0x04000600@ bit 15 or
    -- @0x04000601@ bit 7)
  deriving (Eq, Show)

-- | The state after @GPU3D::Reset@.
initGeoState :: GeoState
initGeoState = GeoState
  { gMtxMode = 0
  , gProj = identity, gPos = identity, gVec = identity, gTex = identity
  , gClip = identity, gClipDirty = False
  , gProjStack = zeroMat, gTexStack = zeroMat
  , gPosStack = slots, gVecStack = slots
  , gProjSP = 0, gPosSP = 0, gTexSP = 0
  , gStackError = False, gBoxResult = False
  , gCurVertex = (0, 0, 0), gVertexColor = (0, 0, 0)
  , gTexCoords = (0, 0), gRawTexCoords = (0, 0), gNormal = (0, 0, 0)
  , gLights = listArray (0, 3) (replicate 4 noLight)
  , gMaterial = noMaterial
  , gPolyAttr = 0, gCurPolyAttr = 0, gTexParam = 0, gTexPalette = 0
  , gViewport = (0, 0, 0, 0, 0, 0)
  , gZeroDotW = 0xFFFFFF
  , gPosTest = (0, 0, 0, 0), gVecTest = (0, 0, 0)
  }
  where
    slots = listArray (0, 31) (replicate 32 zeroMat)

-- | Advance the engine by one input.
step :: GeoState -> GeoIn -> (GeoState, [GeoEvent])
step s inp = case inp of
  GeoCmd op ps -> execCommand op ps s
  SetZeroDotW v -> (s { gZeroDotW = (v .&. 0x7FFF) * 0x200 + 0x1FF }, [])
  AckStackError -> (s { gStackError = False, gProjSP = 0, gTexSP = 0 }, [])

-- | The geometry part of @GXSTAT@.
geoStatus :: GeoState -> GeoStatus
geoStatus s = GeoStatus
  { gsTestBusy = False
  , gsBoxResult = gBoxResult s
  , gsPosStack = gPosSP s .&. 0x1F
  , gsProjStack = testBit (gProjSP s) 0
  , gsStackBusy = False
  , gsStackError = gStackError s
  , gsBusy = False
  }

-- | What @SubmitPolygon@ reads from command state.
polyState :: GeoState -> PolyState
polyState s = PolyState
  { psAttr = gCurPolyAttr s
  , psTexParam = gTexParam s
  , psTexPalette = gTexPalette s
  , psViewport = gViewport s
  , psZeroDotW = gZeroDotW s
  }

-- | @TexParam >> 30@: 0 none, 1 TEXCOORD, 2 NORMAL, 3 VERTEX.
texCoordMode :: GeoState -> Word32
texCoordMode s = gTexParam s `shiftR` 30

-- | The clip matrix as @UpdateClipMatrix@ would leave it, without changing
-- state (a result-register read).
currentClip :: GeoState -> Mat
currentClip s
  | gClipDirty s = clipOf (gProj s) (gPos s)
  | otherwise = gClip s

-- | @UpdateClipMatrix@: recompute @Proj * Pos@ only when dirty (64
-- multiply-accumulates).
updateClip :: GeoState -> GeoState
updateClip s
  | gClipDirty s = s { gClip = clipOf (gProj s) (gPos s), gClipDirty = False }
  | otherwise = s

-- | The packed result word at @addr .&. complement 3@ for
-- @0x04000620@-@0x040006A3@ (full bus addresses): @POS_RESULT@ (0x620-0x62C),
-- @VEC_RESULT@ as two halfwords per word (0x630: x | y << 16, 0x634: z),
-- @CLIPMTX_RESULT@ (0x640-0x67C) and @VECMTX_RESULT@ (0x680-0x6A0, the 3x3
-- of the vector matrix); 0 elsewhere.
geoReadResult :: GeoState -> Word32 -> Word32
geoReadResult s addr =
  let a = addr .&. complement 3
      (t0, t1, t2) = gVecTest s
  in case a of
       0x04000630 -> half t0 .|. (half t1 `shiftL` 16)
       0x04000634 -> half t2
       _ -> geoRead32 s a

-- | A signed halfword register as the bus returns it.
half :: Int16 -> Word32
half v = fromIntegral (fromIntegral v :: Word16)

-- | melonDS @GPU3D::Read32@ over @0x04000620@-@0x040006A3@ (0 elsewhere):
-- the vector-test words read as 0 there, and the clip-matrix range ignores
-- the low address bits.
geoRead32 :: GeoState -> Word32 -> Word32
geoRead32 s addr =
  let (r0, r1, r2, r3) = gPosTest s
      v i = fromIntegral (gVec s !. i)
      u :: Int32 -> Word32
      u = fromIntegral
  in case addr of
       0x04000620 -> u r0
       0x04000624 -> u r1
       0x04000628 -> u r2
       0x0400062C -> u r3
       0x04000680 -> v 0
       0x04000684 -> v 1
       0x04000688 -> v 2
       0x0400068C -> v 4
       0x04000690 -> v 5
       0x04000694 -> v 6
       0x04000698 -> v 8
       0x0400069C -> v 9
       0x040006A0 -> v 10
       _ | addr >= 0x04000640 && addr < 0x04000680 ->
             u (currentClip s !. fromIntegral ((addr .&. 0x3C) `shiftR` 2))
         | otherwise -> 0

-- | melonDS @GPU3D::Read16@ over @0x04000620@-@0x040006A3@ (0 elsewhere):
-- only the three @VEC_RESULT@ halfwords are readable.
geoRead16 :: GeoState -> Word32 -> Word32
geoRead16 s addr =
  let (t0, t1, t2) = gVecTest s
  in case addr of
       0x04000630 -> half t0
       0x04000632 -> half t1
       0x04000634 -> half t2
       _ -> 0

-- | Execute one command.
execCommand :: Word8 -> [Word32] -> GeoState -> (GeoState, [GeoEvent])
execCommand op ps s =
  let params = U.listArray (0, 31) (take 32 (ps ++ repeat 0)) :: U.UArray Int Word32
      p i = params U.! i
      p0 = p 0
      ws n = [p i | i <- [0 .. n - 1]]
      only s' = (s', [])
  in case op of
       0x10 -> only (cmdMatrixMode p0 s)
       0x11 -> only (cmdPush s)
       0x12 -> only (cmdPop p0 s)
       0x13 -> only (cmdStore p0 s)
       0x14 -> only (cmdRestore p0 s)
       0x15 -> only (cmdMatrix True (const identity) s)
       0x16 -> only (cmdMatrix True (const (load4x4 (ws 16))) s)
       0x17 -> only (cmdMatrix True (const (load4x3 (ws 12))) s)
       0x18 -> only (cmdMatrix True (mult4x4 (ws 16)) s)
       0x19 -> only (cmdMatrix True (mult4x3 (ws 12)) s)
       0x1A -> only (cmdMatrix True (mult3x3 (ws 9)) s)
       0x1B -> only (cmdMatrix False (scale (ws 3)) s)
       0x1C -> only (cmdMatrix True (translate (ws 3)) s)
       0x20 -> only (cmdColor p0 s)
       0x21 -> only (cmdNormal p0 s)
       0x22 -> only (cmdTexCoord p0 s)
       0x23 -> cmdVertex (vtx16 p0 (p 1)) s
       0x24 -> cmdVertex (const (vtx10 p0)) s
       0x25 -> cmdVertex (\(_, _, z) -> (lo p0, hi p0, z)) s
       0x26 -> cmdVertex (\(_, y, _) -> (lo p0, y, hi p0)) s
       0x27 -> cmdVertex (\(x, _, _) -> (x, lo p0, hi p0)) s
       0x28 -> cmdVertex (vtxDiff p0) s
       0x29 -> only s { gPolyAttr = p0 }
       0x2A -> only s { gTexParam = p0 }
       0x2B -> only s { gTexPalette = p0 .&. 0x1FFF }
       0x30 -> only (cmdDifAmb p0 s)
       0x31 -> only (cmdSpeEmi p0 s)
       0x32 -> only (cmdLightVector p0 s)
       0x33 -> only (cmdLightColor p0 s)
       0x34 -> only (cmdShininess (ws 32) s)
       0x40 -> (cmdBegin s, [GeBegin p0])
       0x41 -> (s, [GeEnd])
       0x50 -> (s, [GeSwap p0])
       0x60 -> only (cmdViewport p0 s)
       0x70 -> only (cmdBoxTest (p 0) (p 1) (p 2) s)
       0x71 -> only (cmdPosTest p0 (p 1) s)
       0x72 -> only (cmdVecTest p0 s)
       _ -> only s
  where
    lo, hi :: Word32 -> Int16
    lo = fromIntegral
    hi w = fromIntegral (w `shiftR` 16)
    vtx16 a b _ = (lo a, hi a, lo b)
    -- VTX_10: each 10-bit field placed in bits 6-15 of the 16-bit coordinate.
    vtx10 w = ( fromIntegral ((w .&. 0x3FF) `shiftL` 6), fromIntegral ((w .&. 0xFFC00) `shiftR` 4)
              , fromIntegral ((w .&. 0x3FF00000) `shiftR` 14) )
    vtxDiff w (x, y, z) =
      let (dx, dy, dz) = sext10 w in (x + dx, y + dy, z + dz)

-- | @MTX_MODE@.
cmdMatrixMode :: Word32 -> GeoState -> GeoState
cmdMatrixMode p s = s { gMtxMode = fromIntegral (p .&. 3) }

-- | @MTX_PUSH@. Projection and texture stacks have one slot (pointer
-- 0-1, error when pushing at 1); the position/vector stack has 31 usable
-- slots, a 6-bit pointer and an error when pushing above 30.
cmdPush :: GeoState -> GeoState
cmdPush s = case gMtxMode s of
  0 -> s { gStackError = gStackError s || gProjSP s > 0
         , gProjStack = gProj s, gProjSP = (gProjSP s + 1) .&. 1 }
  3 -> s { gStackError = gStackError s || gTexSP s > 0
         , gTexStack = gTex s, gTexSP = (gTexSP s + 1) .&. 1 }
  _ -> let sp = gPosSP s
           slot = fromIntegral (sp .&. 0x1F)
       in s { gStackError = gStackError s || sp > 30
            , gPosStack = gPosStack s // [(slot, gPos s)]
            , gVecStack = gVecStack s // [(slot, gVec s)]
            , gPosSP = (sp + 1) .&. 0x3F }

-- | @MTX_POP@: the position/vector pointer moves by the parameter's signed
-- 6-bit offset, then errors when above 30.
cmdPop :: Word32 -> GeoState -> GeoState
cmdPop p s = case gMtxMode s of
  0 -> s { gStackError = gStackError s || gProjSP s == 0
         , gProjSP = (gProjSP s - 1) .&. 1, gProj = gProjStack s, gClipDirty = True }
  3 -> s { gStackError = gStackError s || gTexSP s == 0
         , gTexSP = (gTexSP s - 1) .&. 1, gTex = gTexStack s }
  _ -> let off = fromIntegral (((fromIntegral (p `shiftL` 26) :: Int32) `shiftR` 26)) :: Word8
           sp = (gPosSP s - off) .&. 0x3F
           slot = fromIntegral (sp .&. 0x1F)
       in s { gPosSP = sp, gStackError = gStackError s || sp > 30
            , gPos = gPosStack s ! slot, gVec = gVecStack s ! slot, gClipDirty = True }

-- | @MTX_STORE@: slot @p & 0x1F@ (error at 31) for position/vector.
cmdStore :: Word32 -> GeoState -> GeoState
cmdStore p s = case gMtxMode s of
  0 -> s { gProjStack = gProj s }
  3 -> s { gTexStack = gTex s }
  _ -> let a = fromIntegral (p .&. 0x1F)
       in s { gStackError = gStackError s || a > 30
            , gPosStack = gPosStack s // [(a, gPos s)]
            , gVecStack = gVecStack s // [(a, gVec s)] }

-- | @MTX_RESTORE@.
cmdRestore :: Word32 -> GeoState -> GeoState
cmdRestore p s = case gMtxMode s of
  0 -> s { gProj = gProjStack s, gClipDirty = True }
  3 -> s { gTex = gTexStack s }
  _ -> let a = fromIntegral (p .&. 0x1F)
       in s { gStackError = gStackError s || a > 30
            , gPos = gPosStack s ! a, gVec = gVecStack s ! a, gClipDirty = True }

-- | A matrix-unit command (@MTX_IDENTITY@, @LOAD@, @MULT@, @SCALE@,
-- @TRANS@) applied to the matrix the mode selects: projection (mode 0),
-- texture (mode 3), position (mode 1) or position and vector (mode 2;
-- @vecToo@ is 'False' only for @MTX_SCALE@, which never touches the vector
-- matrix). Projection and position updates mark the clip matrix dirty.
cmdMatrix :: Bool -> (Mat -> Mat) -> GeoState -> GeoState
cmdMatrix vecToo f s = case gMtxMode s of
  0 -> s { gProj = f (gProj s), gClipDirty = True }
  3 -> s { gTex = f (gTex s) }
  m -> s { gPos = f (gPos s)
         , gVec = if m == 2 && vecToo then f (gVec s) else gVec s
         , gClipDirty = True }

-- | @COLOR@.
cmdColor :: Word32 -> GeoState -> GeoState
cmdColor p s = s { gVertexColor = rgb5 0 p }

-- | @NORMAL@: store the normal and run @CalculateLighting@.
cmdNormal :: Word32 -> GeoState -> GeoState
cmdNormal p s = calculateLighting s { gNormal = sext10 p }

-- | @CalculateLighting@: texture-coordinate mode 2 (normal source) and the
-- lit vertex colour.
calculateLighting :: GeoState -> GeoState
calculateLighting s =
  let n@(n0, n1, n2) = gNormal s
      tex = gTex s
      (r0, r1) = gRawTexCoords s
      i64 :: Integral a => a -> Int64
      i64 = fromIntegral
      tc raw c = raw + fromIntegral ((i64 n0 * i64 (tex !. c) + i64 n1 * i64 (tex !. (4 + c))
                                      + i64 n2 * i64 (tex !. (8 + c))) `shiftR` 21)
      tcs = if texCoordMode s == 2 then (tc r0 0, tc r1 1) else gTexCoords s
      nt = normalTransform (gVec s) n
      col = lightColour (gCurPolyAttr s) (elems (gLights s)) (gMaterial s) nt
  in s { gTexCoords = tcs, gVertexColor = col }

-- | @TEXCOORD@: mode 1 transforms @(s, t, 1, 1)@ by the texture matrix in
-- 32-bit arithmetic.
cmdTexCoord :: Word32 -> GeoState -> GeoState
cmdTexCoord p s =
  let rs = fromIntegral p :: Int16
      rt = fromIntegral (p `shiftR` 16) :: Int16
      tex = gTex s
      i32 :: Int16 -> Int32
      i32 = fromIntegral
      t c = fromIntegral ((i32 rs * tex !. c + i32 rt * tex !. (4 + c)
                           + tex !. (8 + c) + tex !. (12 + c)) `shiftR` 12) :: Int16
      tcs = if texCoordMode s == 1 then (t 0, t 1) else (rs, rt)
  in s { gRawTexCoords = (rs, rt), gTexCoords = tcs }

-- | A vertex command: update @CurVertex@ and submit it.
cmdVertex :: (V3 -> V3) -> GeoState -> (GeoState, [GeoEvent])
cmdVertex f s =
  let (s', ev) = submitVertex s { gCurVertex = f (gCurVertex s) }
  in (s', [ev])

-- | @SubmitVertex@ up to the @TempVertexBuffer@ store: the clip-space
-- position (12 multiply-accumulates plus four @0x1000@ terms after the
-- clip-matrix update), the colour and the texture coordinates (texture
-- mode 3 adds 6 multiply-accumulates).
submitVertex :: GeoState -> (GeoState, GeoEvent)
submitVertex s0 =
  let s = updateClip s0
      (vx, vy, vz) = gCurVertex s
      x = fromIntegral vx; y = fromIntegral vy; z = fromIntegral vz
      (px, py, pz, pw) = transformPoint (gClip s) x y z
      (cr, cg, cb) = gVertexColor s
      col c = (fromIntegral c `shiftL` 12) + 0xFFF
      tex = gTex s
      (r0, r1) = gRawTexCoords s
      i64 :: Int32 -> Int64
      i64 = fromIntegral
      tc raw c = fromIntegral (((i64 x * i64 (tex !. c) + i64 y * i64 (tex !. (4 + c))
                                 + i64 z * i64 (tex !. (8 + c))) `shiftR` 24) + fromIntegral raw)
      (ts, tt) = if texCoordMode s == 3 then (tc r0 0, tc r1 1) else gTexCoords s
      cv = ClipVertex px py pz pw (col cr) (col cg) (col cb) ts tt
  in (s, GeVertex cv (polyState s))

-- | @DIF_AMB@: bit 15 also sets the vertex colour to the diffuse colour.
cmdDifAmb :: Word32 -> GeoState -> GeoState
cmdDifAmb p s =
  let d = rgb5 0 p
      m = (gMaterial s) { mDiffuse = d, mAmbient = rgb5 16 p }
  in s { gMaterial = m, gVertexColor = if testBit p 15 then d else gVertexColor s }

-- | @SPE_EMI@: bit 15 enables the shininess table.
cmdSpeEmi :: Word32 -> GeoState -> GeoState
cmdSpeEmi p s =
  s { gMaterial = (gMaterial s) { mSpecular = rgb5 0 p, mEmission = rgb5 16 p
                                , mUseShininess = testBit p 15 } }

-- | @LIGHT_VECTOR@.
cmdLightVector :: Word32 -> GeoState -> GeoState
cmdLightVector p s =
  let (l, dir, recipr) = lightVector (gVec s) p
      old = gLights s ! l
  in s { gLights = gLights s // [(l, old { lDir = dir, lSpecRecip = recipr })] }

-- | @LIGHT_COLOR@.
cmdLightColor :: Word32 -> GeoState -> GeoState
cmdLightColor p s =
  let l = fromIntegral (p `shiftR` 30)
      old = gLights s ! l
  in s { gLights = gLights s // [(l, old { lColor = rgb5 0 p })] }

-- | @SHININESS@: 32 words, four table bytes each, little-endian.
cmdShininess :: [Word32] -> GeoState -> GeoState
cmdShininess ws s =
  let bytes = [fromIntegral (w `shiftR` (8 * k)) | w <- ws, k <- [0 .. 3]]
  in s { gMaterial = (gMaterial s) { mShininess = U.listArray (0, 127) bytes } }

-- | @BEGIN_VTXS@: latch the polygon attribute.
cmdBegin :: GeoState -> GeoState
cmdBegin s = s { gCurPolyAttr = gPolyAttr s }

-- | @VIEWPORT@ decoded into melonDS's @Viewport[6]@ (x0, flipped y0, x1,
-- flipped y1, width, height).
cmdViewport :: Word32 -> GeoState -> GeoState
cmdViewport p s =
  let v0 = p .&. 0xFF
      v1 = (191 - ((p `shiftR` 8) .&. 0xFF)) .&. 0xFF
      v2 = (p `shiftR` 16) .&. 0xFF
      v3 = (191 - (p `shiftR` 24)) .&. 0xFF
      v4 = (v2 - v0 + 1) .&. 0x1FF
      v5 = (v1 - v3 + 1) .&. 0xFF
  in s { gViewport = (v0, v1, v2, v3, v4, v5) }

-- | @BOX_TEST@.
cmdBoxTest :: Word32 -> Word32 -> Word32 -> GeoState -> GeoState
cmdBoxTest a b c s0 =
  let s = updateClip s0
  in s { gBoxResult = boxTest (gClip s) (gCurPolyAttr s) a b c }

-- | @POS_TEST@: sets @CurVertex@ like @VTX_16@, then transforms it (12
-- multiply-accumulates plus four @0x1000@ terms).
cmdPosTest :: Word32 -> Word32 -> GeoState -> GeoState
cmdPosTest a b s0 =
  let v@(x, y, z) = (fromIntegral a, fromIntegral (a `shiftR` 16), fromIntegral b) :: V3
      s = updateClip s0 { gCurVertex = v }
  in s { gPosTest = transformPoint (gClip s) (fromIntegral x) (fromIntegral y) (fromIntegral z) }

-- | @VEC_TEST@: @(n * VecMatrix) >> 9@ in 32-bit arithmetic, truncated to
-- 16 bits, bit 12 copied into bits 13-15 when set (9 multiply-accumulates).
cmdVecTest :: Word32 -> GeoState -> GeoState
cmdVecTest p s =
  let (n0, n1, n2) = sext10 p
      vec = gVec s
      i32 :: Int16 -> Int32
      i32 = fromIntegral
      r c = let v = fromIntegral ((i32 n0 * vec !. c + i32 n1 * vec !. (4 + c)
                                   + i32 n2 * vec !. (8 + c)) `shiftR` 9) :: Int16
            in if testBit v 12 then v .|. fromIntegral (0xF000 :: Word32) else v
  in s { gVecTest = (r 0, r 1, r 2) }
