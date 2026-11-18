{-# LANGUAGE BangPatterns #-}

-- | Exact melonDS polygon pipeline: everything after the vertex transform.
--
-- Input is the 'GeoEvent' stream of "Nds.Gpu3D.Types"; the model reproduces
--
-- * the assembly half of @GPU3D::SubmitVertex@ (@VertexNumInPoly@, the
--   triangle / quad / strip cases and the strip vertex swaps) — 'submitVertex';
-- * @BEGIN_VTXS@'s effect on assembly state — 'beginVtxs'. The attribute
--   latch (@CurPolygonAttr = PolygonAttr@) happens upstream: 'GeBegin'
--   carries only the parameter and every 'GeVertex' carries
--   @CurPolygonAttr@ in 'psAttr';
-- * @GPU3D::SubmitPolygon@ — 'submitPolygon', split into the stages a
--   hardware pipeline follows: 'cullDot', 'stripReuse', 'polygonType',
--   'clipPolygon' (in "Nds.Gpu3D.Polygon.Clip"), the RAM limit, 'viewportVertex',
--   'zeroDotReject', 'finalColour', 'polygonBounds', 'finalZW';
-- * @SWAP_BUFFERS@ (@FlushRequest@ / @FlushAttributes@) — 'swapBuffers';
-- * @GPU3D::VBlank@'s bank swap and @RenderPolygonRAM@ sort — 'vblank'.
--
-- Polygon and vertex RAM are modelled as melonDS lays them out: one
-- 4096-entry polygon array and one 12288-entry vertex array, bank @b@
-- occupying @[b*2048 ..]@ and @[b*6144 ..]@. Polygons hold vertex indices
-- into the whole array because a strip that continues across a swap without
-- a new @BEGIN_VTXS@ shares vertices with a polygon in the other bank.
module Nds.Gpu3D.Polygon
  ( -- * State
    PolyPipeState (..)
  , Poly (..)
  , SubmitResult (..)
  , initPolyPipe
    -- * Boundary
  , step
  , vblank
  , pipeStatus
  , pipeOverflow
  , clearOverflow
  , submitTiming
    -- * Per-event steps
  , beginVtxs
  , submitVertex
  , swapBuffers
  , submitPolygon
    -- * SubmitPolygon stages
  , cullDot
  , cullRejects
  , stripReuse
  , polygonType
  , viewportVertex
  , zeroDotReject
  , finalColour
  , Bounds (..)
  , polygonBounds
  , polygonWSize
  , finalZW
  , isTranslucent
  , sortKey
    -- * Swap
  , renderOrder
  , toGxPolygon
  , fromClipVertex
    -- * RAM geometry
  , polyRamBank
  , vertRamBank
  , maxPolygons
  , maxVertices
  , readVert
  , readPoly
    -- * Re-exports
  , module Nds.Gpu3D.Polygon.Clip
  ) where

import Data.Bits (shiftL, shiftR, testBit, xor, (.&.), (.|.))
import Data.Int (Int32, Int64)
import qualified Data.IntMap.Strict as IM
import Data.List (foldl', sortBy)
import Data.Ord (comparing)
import qualified Data.Sequence as Seq
import Data.Word (Word32)

import Nds.Gpu3D.Depth (divideZ, normalizedWSize)
import Nds.Gpu3D.Polygon.Clip
import Nds.Gpu3D.Types

-- | A melonDS @Polygon@ as stored in polygon RAM.
data Poly = Poly
  { plVerts       :: ![Int]    -- ^ @Vertices[0 .. NumVertices-1]@, indices into vertex RAM
  , plFinalZ      :: ![Int32]
  , plFinalW      :: ![Int32]
  , plWBuffer     :: !Bool
  , plAttr        :: !Word32
  , plTexParam    :: !Word32
  , plTexPalette  :: !Word32
  , plDegenerate  :: !Bool
  , plFacingView  :: !Bool
  , plTranslucent :: !Bool
  , plShadowMask  :: !Bool
  , plShadow      :: !Bool
  , plType        :: !Int
  , plVTop        :: !Int
  , plVBottom     :: !Int
  , plYTop        :: !Int32
  , plYBottom     :: !Int32
  , plXTop        :: !Int32
  , plXBottom     :: !Int32
  , plSortKey     :: !Word32
  } deriving (Eq, Show)

-- | What one @SubmitPolygon@ call did.
data SubmitResult
  = Culled                 -- ^ front/back culling (attribute bits 6/7)
  | ClippedAway !ClipStats -- ^ clipping left no vertex (incl. the far plane)
  | Overflow !ClipStats    -- ^ polygon or vertex RAM full
  | ZeroDot !ClipStats     -- ^ the 1-dot rule
  | Built
      { brVerts  :: !Int       -- ^ vertices after clipping
      , brReused :: !Bool      -- ^ strip vertices 0 and 1 came from the last polygon
      , brClip   :: !ClipStats
      }
  deriving (Eq, Show)

-- | The polygon pipeline's state: melonDS's assembly variables, both RAM
-- banks and the swap request.
data PolyPipeState = PolyPipeState
  { ppMode       :: !Int              -- ^ @PolygonMode@
  , ppVertexNum  :: !Word32           -- ^ @VertexNum@
  , ppVtxInPoly  :: !Int              -- ^ @VertexNumInPoly@
  , ppConsec     :: !Word32           -- ^ @NumConsecutivePolygons@
  , ppTemp       :: !ClipBuf          -- ^ @TempVertexBuffer[4]@
  , ppLastStrip  :: !(Maybe Int)      -- ^ @LastStripPolygon@ (polygon RAM index)
  , ppBank       :: !Int              -- ^ @CurRAMBank@
  , ppVertRam    :: !(IM.IntMap Vtx)  -- ^ @VertexRAM[2*6144]@ (absent = zero)
  , ppPolyRam    :: !(IM.IntMap Poly) -- ^ @PolygonRAM[2*2048]@
  , ppNumVerts   :: !Int              -- ^ @NumVertices@
  , ppNumPolys   :: !Int              -- ^ @NumPolygons@
  , ppNumOpaque  :: !Int              -- ^ @NumOpaquePolygons@
  , ppFlushReq   :: !Bool             -- ^ @FlushRequest@
  , ppFlushAttr  :: !Word32           -- ^ @FlushAttributes@
  , ppOverflow   :: !Bool             -- ^ @DISP3DCNT@ bit 13
  , ppLastSubmit :: !(Maybe SubmitResult) -- ^ the last event's @SubmitPolygon@, if any
  } deriving (Eq, Show)

maxPolygons, maxVertices :: Int
maxPolygons = 2048
maxVertices = 6144

-- | First polygon / vertex RAM index of a bank.
polyRamBank, vertRamBank :: Int -> Int
polyRamBank b = b * maxPolygons
vertRamBank b = b * maxVertices

-- | The state after @GPU3D::Reset@.
initPolyPipe :: PolyPipeState
initPolyPipe = PolyPipeState
  { ppMode = 0, ppVertexNum = 0, ppVtxInPoly = 0, ppConsec = 0
  , ppTemp = Seq.replicate 4 zeroVtx
  , ppLastStrip = Nothing
  , ppBank = 0
  , ppVertRam = IM.empty
  , ppPolyRam = IM.empty
  , ppNumVerts = 0, ppNumPolys = 0, ppNumOpaque = 0
  , ppFlushReq = False, ppFlushAttr = 0
  , ppOverflow = False
  , ppLastSubmit = Nothing
  }

readVert :: PolyPipeState -> Int -> Vtx
readVert st i = IM.findWithDefault zeroVtx i (ppVertRam st)

readPoly :: PolyPipeState -> Int -> Poly
readPoly st i = IM.findWithDefault emptyPoly i (ppPolyRam st)
  where
    emptyPoly = Poly [] [] [] False 0 0 0 False False False False False 0 0 0 0 0 0 0 0

-- | One 'GeoEvent'.
step :: PolyPipeState -> GeoEvent -> PolyPipeState
step st0 ev = case ev of
  GeBegin p     -> beginVtxs p st
  GeVertex v ps -> submitVertex v ps st
  GeEnd         -> st
  GeSwap p      -> swapBuffers p st
  where
    st = st0 { ppLastSubmit = Nothing }

-- | @RAM_COUNT@.
pipeStatus :: PolyPipeState -> PipeStatus
pipeStatus st = PipeStatus (fromIntegral (ppNumPolys st)) (fromIntegral (ppNumVerts st))

-- | @DISP3DCNT@ bit 13, set when a polygon is rejected for lack of RAM.
-- 'PipeStatus' has no field for it.
pipeOverflow :: PolyPipeState -> Bool
pipeOverflow = ppOverflow

-- | Writing 1 to @DISP3DCNT@ bit 13.
clearOverflow :: PolyPipeState -> PolyPipeState
clearOverflow st = st { ppOverflow = False }

-- | @PolygonPipeline@ and @VertexSlotsFree@ as @SubmitPolygon@ leaves them
-- (@VertexSlotCounter@ is always 1), for the geometry engine's timing.
submitTiming :: Int -> SubmitResult -> (Int32, Word32)
submitTiming mode r = case r of
  Built { brVerts = 4 } -> (35, if strip then 0x1C else 0x1E)
  Built {}              -> (26, if strip then 0x08 else 0x0E)
  _                     -> (8, 0x1E)
  where
    strip = testBit mode 1

-- | @BEGIN_VTXS@ (command 0x40), polygon assembly part.
beginVtxs :: Word32 -> PolyPipeState -> PolyPipeState
beginVtxs p st = st
  { ppMode = fromIntegral (p .&. 3)
  , ppVertexNum = 0
  , ppVtxInPoly = 0
  , ppConsec = 0
  , ppLastStrip = Nothing
  }

-- | @SWAP_BUFFERS@ (command 0x50).
swapBuffers :: Word32 -> PolyPipeState -> PolyPipeState
swapBuffers p st = st { ppFlushReq = True, ppFlushAttr = p .&. 3 }

-- | The vertex @SubmitVertex@ writes to @TempVertexBuffer@.
fromClipVertex :: ClipVertex -> Vtx
fromClipVertex cv = zeroVtx
  { vX = cvX cv, vY = cvY cv, vZ = cvZ cv, vW = cvW cv
  , vR = cvR cv, vG = cvG cv, vB = cvB cv
  , vS = cvS cv, vT = cvT cv
  , vClipped = False
  }

-- | The assembly half of @SubmitVertex@.
submitVertex :: ClipVertex -> PolyState -> PolyPipeState -> PolyPipeState
submitVertex cv ps st0 = case ppMode st1 of
  0 | n == 3 -> next (submitPolygon ps st1 { ppVtxInPoly = 0 })
  1 | n == 4 -> next (submitPolygon ps st1 { ppVtxInPoly = 0 })
  2 | odd (ppConsec st1) ->
        let swapped = setT 0 (t1 1) (setT 1 (t1 0) (ppTemp st1))
            st2 = next (submitPolygon ps st1 { ppTemp = swapped, ppVtxInPoly = 2 })
        in st2 { ppTemp = setT 1 (Seq.index (ppTemp st2) 2) (ppTemp st2) }
    | n == 3 ->
        let st2 = next (submitPolygon ps st1 { ppVtxInPoly = 2 })
            tmp = ppTemp st2
        in st2 { ppTemp = setT 1 (Seq.index tmp 2) (setT 0 (Seq.index tmp 1) tmp) }
  3 | n == 4 ->
        let swapped = setT 2 (t1 3) (setT 3 (t1 2) (ppTemp st1))
            st2 = next (submitPolygon ps st1 { ppTemp = swapped, ppVtxInPoly = 2 })
            tmp = ppTemp st2
        in st2 { ppTemp = setT 1 (Seq.index tmp 2) (setT 0 (Seq.index tmp 3) tmp) }
  _ -> st1
  where
    k = ppVtxInPoly st0
    n = k + 1
    st1 = st0
      { ppTemp = Seq.update k (fromClipVertex cv) (ppTemp st0)
      , ppVertexNum = ppVertexNum st0 + 1
      , ppVtxInPoly = n
      }
    t1 = Seq.index (ppTemp st1)
    setT = Seq.update
    next s = s { ppConsec = ppConsec s + 1 }

-- | The culling dot product of @SubmitPolygon@: the normal of
-- @(v0 - v1) x (v2 - v1)@ over (X, Y, W) with 32-bit wrapped differences and
-- 64-bit products, scaled down by 16 until every component fits in 32 bits,
-- dotted with @v1@.
cullDot :: Vtx -> Vtx -> Vtx -> Int64
cullDot v0 v1 v2 =
  fromIntegral (vX v1) * nx' + fromIntegral (vY v1) * ny' + fromIntegral (vW v1) * nz'
  where
    d :: Vtx -> (Vtx -> Int32) -> Int64
    d a sel = fromIntegral (sel a - sel v1)
    nx = d v0 vY * d v2 vW - d v0 vW * d v2 vY
    ny = d v0 vW * d v2 vX - d v0 vX * d v2 vW
    nz = d v0 vX * d v2 vY - d v0 vY * d v2 vX
    fits a = (a `shiftR` 31) `xor` (a `shiftR` 63) == 0
    shrink (!a, !b, !c)
      | fits a && fits b && fits c = (a, b, c)
      | otherwise = shrink (a `shiftR` 4, b `shiftR` 4, c `shiftR` 4)
    (nx', ny', nz') = shrink (nx, ny, nz)

-- | Culling: a negative dot needs attribute bit 7, a positive one bit 6.
cullRejects :: Word32 -> Int64 -> Bool
cullRejects attr dot
  | dot < 0 = not (testBit attr 7)
  | dot > 0 = not (testBit attr 6)
  | otherwise = False

-- | Strip vertex reuse: @(lastpolyverts, Just (vertex 0, vertex 1))@ when
-- the last strip polygon has the expected vertex count and neither shared
-- vertex was produced by clipping.
stripReuse :: PolyPipeState -> (Int, Maybe (Int, Int))
stripReuse st = case ppLastStrip st of
  Just lp | ppMode st >= 2 ->
    let (id0, id1, lastpolyverts)
          | ppMode st == 2 = if odd (ppConsec st) then (2, 1, 3) else (0, 2, 3)
          | otherwise = (3, 2, 4)
        refs = plVerts (readPoly st lp)
        clipped i = vClipped (readVert st (refs !! i))
    in if length refs == lastpolyverts && not (clipped id0) && not (clipped id1)
         then (lastpolyverts, Just (refs !! id0, refs !! id1))
         else (lastpolyverts, Nothing)
  _ -> (0, Nothing)

-- | @Type@: 1 (line) for a triangle with two equal clip-space positions.
polygonType :: Int -> ClipBuf -> Int
polygonType nverts buf
  | nverts == 3 && (same 0 1 || same 0 2 || same 1 2) = 1
  | otherwise = 0
  where
    pos i = let v = Seq.index buf i in (vX v, vY v, vZ v, vW v)
    same a b = pos a == pos b

-- | The viewport transform: W truncated to 24 bits, then
-- @FinalPosition = ((p + w) * size / 2w + origin) & mask@ in unsigned 32-bit
-- arithmetic, halving numerator and denominator first when @w > 0xFFFF@.
viewportVertex :: (Word32, Word32, Word32, Word32, Word32, Word32) -> Vtx -> Vtx
viewportVertex (vp0, _, _, vp3, vp4, vp5) v = v { vW = fromIntegral w, vFX = fx, vFY = fy }
  where
    w = fromIntegral (vW v) .&. 0x00FFFFFF :: Word32
    (fx, fy)
      | w == 0 = (0, 0)
      | otherwise =
          let px0 = fromIntegral (vX v) + w
              py0 = negate (fromIntegral (vY v)) + w
              (px, py, d)
                | w > 0xFFFF = (px0 `shiftR` 1, py0 `shiftR` 1, w `shiftR` 1)
                | otherwise = (px0, py0, w)
              den = d `shiftL` 1
              sx = (px * vp4) `div` den + vp0
              sy = (py * vp5) `div` den + vp3
          in (fromIntegral (sx .&. 0x1FF), fromIntegral (sy .&. 0xFF))

-- | The 1-dot rule (skipped when attribute bit 13 is set): every vertex on
-- vertex 0's screen position and every W above @DISP_1DOT_DEPTH@.
zeroDotReject :: Word32 -> Word32 -> [Vtx] -> Bool
zeroDotReject attr limit vs = case vs of
  v0 : _ | not (testBit attr 13) -> all (ok v0) vs
  _ -> False
  where
    ok v0 v = vFX v == vFX v0 && vFY v == vFY v0 && (fromIntegral (vW v) :: Word32) > limit

-- | @FinalColor@: @Color >> 12@, widened to 9 bits as @(c << 4) + 0xF@ unless 0.
finalColour :: Vtx -> Vtx
finalColour v = v { vFR = f (vR v), vFG = f (vG v), vFB = f (vB v) }
  where
    f c = let c' = c `shiftR` 12 in if c' /= 0 then (c' `shiftL` 4) + 0xF else 0

-- | Top/bottom vertex, the 'Degenerate' contribution of zero W, in
-- @SubmitPolygon@'s scan order.
data Bounds = Bounds
  { bVTop, bVBottom :: !Int
  , bYTop, bYBottom, bXTop, bXBottom :: !Int32
  , bZeroW :: !Bool
  } deriving (Eq, Show)

polygonBounds :: [Vtx] -> Bounds
polygonBounds = foldl' visit (Bounds 0 0 192 0 256 0 False) . zip [0 ..]
  where
    visit b (i, v) =
      let fx = vFX v
          fy = vFY v
          b1 = if fy < bYTop b then b { bXTop = fx, bYTop = fy, bVTop = i } else b
          b2 = if fy > bYBottom b1 || (fy == bYBottom b1 && fx > bXBottom b1)
                 then b1 { bXBottom = fx, bYBottom = fy, bVBottom = i } else b1
      in b2 { bZeroW = bZeroW b2 || vW v == 0 }

-- | The polygon's W normalisation width (largest per-vertex nibble width).
polygonWSize :: [Vtx] -> Word32
polygonWSize = foldl' (\s v -> max s (normalizedWSize (fromIntegral (vW v)))) 0

-- | @(FinalZ, FinalW)@ of one vertex given the polygon's W width and the
-- W-buffer flag, with 32-bit wrap-around before the @[0, 0xFFFFFF]@ clamp.
finalZW :: Bool -> Word32 -> Vtx -> (Int32, Int32)
finalZW wbuffer wsize v = (clamp z, w)
  where
    pw = vW v
    (w, wshifted)
      | wsize < 16 = let s = fromIntegral (16 - wsize)
                         a = pw `shiftL` s
                     in (a, a `shiftR` s)
      | otherwise = let s = fromIntegral (wsize - 16)
                        a = pw `shiftR` s
                    in (a, a `shiftL` s)
    z | wbuffer = wshifted
      | pw /= 0 = (divideZ (vZ v) (fromIntegral pw) + 0x3FFF) * 0x200
      | otherwise = 0x7FFE00
    clamp a
      | a < 0 = 0
      | a > 0xFFFFFF = 0xFFFFFF
      | otherwise = a

-- | @Translucent@: texture format 1 or 6, or alpha in 1..30.
isTranslucent :: Word32 -> Word32 -> Bool
isTranslucent attr texParam = texfmt == 1 || texfmt == 6 || (alpha > 0 && alpha < 31)
  where
    texfmt = (texParam `shiftR` 26) .&. 7
    alpha = (attr `shiftR` 16) .&. 0x1F

-- | @SortKey@.
sortKey :: Bool -> Int32 -> Int32 -> Word32
sortKey translucent ybot ytop =
  ((fromIntegral ybot `shiftL` 8) .|. fromIntegral ytop) .|. (if translucent then 0x10000 else 0)

-- | @SubmitPolygon@ on @TempVertexBuffer[0 .. 2 or 3]@.
submitPolygon :: PolyState -> PolyPipeState -> PolyPipeState
submitPolygon ps st
  | cullRejects attr dot = reject Culled st
  | nverts == 0 = reject (ClippedAway cstats) st
  | ppNumPolys st >= maxPolygons || ppNumVerts st + nverts > maxVertices =
      (reject (Overflow cstats) st) { ppOverflow = True }
  | zeroDotReject attr (psZeroDotW ps) screenVerts = reject (ZeroDot cstats) st
  | otherwise = built
  where
    attr = psAttr ps
    mode = ppMode st
    nverts0 = if odd mode then 4 else 3
    temp = Seq.index (ppTemp st)
    dot = cullDot (temp 0) (temp 1) (temp 2)

    (lastpolyverts, reused) = stripReuse st
    clipstart = maybe 0 (const 2) reused
    buf0 = Seq.replicate maxClipVertices zeroVtx
    buf1 = case reused of
      Just (r0, r1) -> Seq.update 1 (readVert st r1) (Seq.update 0 (readVert st r0) buf0)
      Nothing -> buf0
    buf2 = foldl' (\b i -> Seq.update i (temp i) b) buf1 [clipstart .. nverts0 - 1]
    polytype = polygonType nverts0 buf2

    (buf3, nverts, cstats) = clipPolygon attr clipstart buf2 nverts0
    buf4 = foldl' (\b i -> Seq.adjust' (viewportVertex (psViewport ps)) i b) buf3
             [clipstart .. nverts - 1]
    screenVerts = [Seq.index buf4 i | i <- [0 .. nverts - 1]]

    -- build: vertices 0 and 1 of a reusing strip polygon are the last
    -- polygon's (same count) or copies of them; the rest are new.
    bank = ppBank st
    pidx = polyRamBank bank + ppNumPolys st
    (refs01, vram1, nv1) = case reused of
      Just (r0, r1)
        | nverts == lastpolyverts -> ([r0, r1], ppVertRam st, ppNumVerts st)
        | otherwise ->
            let a = vertRamBank bank + ppNumVerts st
            in ( [a, a + 1]
               , IM.insert (a + 1) (readVert st r1) (IM.insert a (readVert st r0) (ppVertRam st))
               , ppNumVerts st + 2 )
      Nothing -> ([], ppVertRam st, ppNumVerts st)
    (refsNew, vram2, nv2) = foldl' store ([], vram1, nv1) [clipstart .. nverts - 1]
    store (rs, vr, nv) i =
      let a = vertRamBank bank + nv
      in (a : rs, IM.insert a (finalColour (Seq.index buf4 i)) vr, nv + 1)
    refs = refs01 ++ reverse refsNew
    polyVerts = map (\r -> IM.findWithDefault zeroVtx r vram2) refs

    bounds = polygonBounds polyVerts
    wsize = polygonWSize polyVerts
    wbuffer = testBit (ppFlushAttr st) 1
    zw = map (finalZW wbuffer wsize) polyVerts
    translucent = isTranslucent attr (psTexParam ps)
    shadowMask = attr .&. 0x3F000030 == 0x00000030
    poly = Poly
      { plVerts = refs
      , plFinalZ = map fst zw
      , plFinalW = map snd zw
      , plWBuffer = wbuffer
      , plAttr = attr
      , plTexParam = psTexParam ps
      , plTexPalette = psTexPalette ps
      , plDegenerate = bZeroW bounds || bYBottom bounds > 192
      , plFacingView = dot <= 0
      , plTranslucent = translucent
      , plShadowMask = shadowMask
      , plShadow = attr .&. 0x30 == 0x30 && not shadowMask
      , plType = polytype
      , plVTop = bVTop bounds
      , plVBottom = bVBottom bounds
      , plYTop = bYTop bounds
      , plYBottom = bYBottom bounds
      , plXTop = bXTop bounds
      , plXBottom = bXBottom bounds
      , plSortKey = sortKey translucent (bYBottom bounds) (bYTop bounds)
      }
    built = st
      { ppVertRam = vram2
      , ppPolyRam = IM.insert pidx poly (ppPolyRam st)
      , ppNumVerts = nv2
      , ppNumPolys = ppNumPolys st + 1
      , ppNumOpaque = ppNumOpaque st + (if translucent then 0 else 1)
      , ppLastStrip = if mode >= 2 then Just pidx else Nothing
      , ppLastSubmit = Just (Built nverts (clipstart > 0) cstats)
      }

    reject r s = s { ppLastStrip = Nothing, ppLastSubmit = Just r }

-- | The @RenderPolygonRAM@ order of the current bank: opaque polygons then
-- translucent ones, each in submission order, then a stable sort by
-- 'plSortKey' of the whole list, or of the opaque part only when
-- @FlushAttributes@ bit 0 (manual translucent sort) is set.
renderOrder :: PolyPipeState -> [Int]
renderOrder st = sortBy (comparing key) (take k ordered) ++ drop k ordered
  where
    base = polyRamBank (ppBank st)
    idxs = [base .. base + ppNumPolys st - 1]
    ordered = filter (not . plTranslucent . readPoly st) idxs
           ++ filter (plTranslucent . readPoly st) idxs
    k = if testBit (ppFlushAttr st) 0 then ppNumOpaque st else ppNumPolys st
    key = plSortKey . readPoly st

-- | The renderer-visible polygon, vertex values read through the indices.
toGxPolygon :: PolyPipeState -> Poly -> GxPolygon
toGxPolygon st p = GxPolygon
  { gpVerts = map (gxVertex . readVert st) (plVerts p)
  , gpFinalZ = plFinalZ p
  , gpFinalW = plFinalW p
  , gpWBuffer = plWBuffer p
  , gpAttr = plAttr p
  , gpTexParam = plTexParam p
  , gpTexPalette = plTexPalette p
  , gpDegenerate = plDegenerate p
  , gpFacingView = plFacingView p
  , gpTranslucent = plTranslucent p
  , gpShadowMask = plShadowMask p
  , gpShadow = plShadow p
  , gpType = plType p
  , gpVTop = plVTop p
  , gpVBottom = plVBottom p
  , gpYTop = plYTop p
  , gpYBottom = plYBottom p
  , gpXTop = plXTop p
  , gpXBottom = plXBottom p
  , gpSortKey = plSortKey p
  }
  where
    gxVertex v = GxVertex (vFX v) (vFY v) (vFR v) (vFG v) (vFB v) (vS v) (vT v)

-- | @GPU3D::VBlank@ (geometry and rendering enabled): with a pending
-- @SWAP_BUFFERS@, the sorted polygon list of the finished bank, then the
-- bank swap and counter reset. Without one, nothing changes.
vblank :: PolyPipeState -> (PolyPipeState, Maybe [GxPolygon])
vblank st
  | ppFlushReq st =
      ( st { ppBank = 1 - ppBank st
           , ppNumVerts = 0, ppNumPolys = 0, ppNumOpaque = 0
           , ppFlushReq = False
           }
      , Just (map (toGxPolygon st . readPoly st) (renderOrder st)) )
  | otherwise = (st, Nothing)
