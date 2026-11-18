{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DeriveGeneric #-}

-- | Flat opaque triangle rasterisation, transcribed from the production
-- melonDS rasteriser.
--
-- This slice deliberately models the narrow case that the first Clash top will
-- implement: three vertices, constant colour, constant depth, no texture, no
-- anti-aliasing, no translucency, no shadows. Under those conditions the
-- rasteriser's per-pixel work collapses to coverage: which pixels the triangle
-- writes. That is still the exact edge fill rule, including the swapped-edge
-- path, the right-edge pull-in and the bottom-scanline exceptions.
module Nds.Gpu3D.Raster
  ( Vertex (..)
  , vertexAt
  , Tri (..)
  , mkTri
  , RasterConfig (..)
  , Raster (..)
  , setupRaster
  , setupRasterFrom
  , setupRasterFast
  , setupRasterFastFrom
  , setupLeftFast
  , setupRightFast
  , prepareRow
  , prepareRowFast
  , RowFill
  , rowFill
  , SpanRule (..)
  , spanRule
  , spanRuleWith
  , alwaysFilled
  , spanPieces
  , rightPullIn
  , rowSpans
  , renderRow
  , rasterTri
  , rasterTriDepth
  , rasterTriFinalDepth
  , SpanZ (..)
  , horizontalSpanZ
  , rowSpanDepth
  , rowSpanDepthWith
  , spanDepths
  ) where

import Prelude

import Data.Bits (shiftL, (.&.))
import Data.Int (Int32)
import GHC.Generics (Generic)

import Clash.Prelude (NFDataX, Unsigned, Vec (..))

import Nds.Gpu3D.Depth (finalZ, interpolateZ, setX, setupInterp)
import Nds.Gpu3D.Slope

screenWidth :: Int32
screenWidth = 256

-- | One final-space vertex. Only the fields the flat path consumes are kept.
data Vertex = Vertex
  { vertexX :: !Int32
  , vertexY :: !Int32
  , vertexZ :: !Int32
  , vertexW :: !Int32
  , vertexR :: !Int32
  , vertexG :: !Int32
  , vertexB :: !Int32
  } deriving (Eq, Generic, Show, NFDataX)

-- | A submitted triangle plus the bounds melonDS derives at submission.
data Tri = Tri
  { triVertices  :: !(Vec 3 Vertex)
  , triFacing    :: !Bool
  , triYTop      :: !Int32
  , triYBottom   :: !Int32
  , triVTop      :: !(Unsigned 2)
  , triVBottom   :: !(Unsigned 2)
  } deriving (Eq, Generic, Show, NFDataX)

-- | Reproduce @GPU3D::SubmitPolygon@'s bounds reduction. The top vertex is
-- the first strict minimum; the bottom vertex prefers the larger X on a tie.
mkTri :: Bool -> Vec 3 Vertex -> Tri
mkTri facing vs =
  let v0 :> v1 :> v2 :> _ = vs
      (yt, _xt, vt, yb, _xb, vb) =
        foldl step
          ( (8 + 8) * (8 + 4), (8 + 8) * (8 + 8), 0
          , 0, 0, 0 )
          [(0, v0), (1, v1), (2, v2)]
      step (!accYt, !accXt, !accVt, !accYb, !accXb, !accVb) (i, v) =
        let (yt', xt', vt')
              | vertexY v < accYt = (vertexY v, vertexX v, i)
              | otherwise = (accYt, accXt, accVt)
            (yb', xb', vb')
              | vertexY v > accYb
                  || (vertexY v == accYb && vertexX v > accXb) =
                    (vertexY v, vertexX v, i)
              | otherwise = (accYb, accXb, accVb)
        in (yt', xt', vt', yb', xb', vb')
  in Tri vs facing yt yb vt vb

-- | The knobs the flat path still reads.
data RasterConfig = RasterConfig
  { cfgDispCnt   :: !Int32
  , cfgPolyAlpha :: !Int32
  , cfgWireframe :: !Bool
  , cfgWidth     :: !Int32
  } deriving (Eq, Generic, Show, NFDataX)

-- | Live rasteriser state for one triangle.
data Raster = Raster
  { rasTri     :: !Tri
  , rasCurVL   :: !(Unsigned 2)
  , rasNextVL  :: !(Unsigned 2)
  , rasCurVR   :: !(Unsigned 2)
  , rasNextVR  :: !(Unsigned 2)
  , rasXL      :: !Int32
  , rasXR      :: !Int32
  , rasSL      :: !Slope
  , rasSR      :: !Slope
  } deriving (Eq, Generic, Show, NFDataX)

wrapSucc :: Unsigned 2 -> Unsigned 2
wrapSucc i = if i == 2 then 0 else i + 1

wrapPred :: Unsigned 2 -> Unsigned 2
wrapPred i = if i == 0 then 2 else i - 1

-- | Select a vertex from the three-vertex primitive.
vertexAt :: Vec 3 Vertex -> Unsigned 2 -> Vertex
vertexAt (v0 :> v1 :> v2 :> _) i
  | i == 0 = v0
  | i == 1 = v1
  | otherwise = v2

-- | Reproduce @SetupPolygon@'s cursor initialisation and first edge setup.
setupRaster :: Tri -> Raster
setupRaster tri = setupRasterFrom tri (triYTop tri)

-- | Set up the full edge walk at an arbitrary scanline inside the triangle.
setupRasterFrom :: Tri -> Int32 -> Raster
setupRasterFrom tri y =
  let vs = triVertices tri
      vtop = triVTop tri
      vbot = triVBottom tri
      (nl, nr)
        | triFacing tri = (wrapSucc vtop, wrapPred vtop)
        | otherwise = (wrapPred vtop, wrapSucc vtop)
      base = Raster tri vtop nl vtop nr 0 0 (setupDummy 0 False) (setupDummy 0 False)
  in if triYTop tri == triYBottom tri
       then base
         { rasXL = vertexX (vertexAt vs vtop)
         , rasXR = vertexX (vertexAt vs vbot)
         , rasSL = setupDummy (vertexX (vertexAt vs vtop)) False
         , rasSR = setupDummy (vertexX (vertexAt vs vbot)) False
         }
       else setupRight (setupLeft base y) y

-- | The flat-opaque setup: no reciprocal or coverage increments.
setupRasterFast :: Tri -> Raster
setupRasterFast tri = setupRasterFastFrom tri (triYTop tri)

-- | Set up the flat-opaque edges at an arbitrary scanline inside the triangle.
-- Starting at the first visible row avoids walking rows that are clipped away.
setupRasterFastFrom :: Tri -> Int32 -> Raster
setupRasterFastFrom tri y =
  let vs = triVertices tri
      vtop = triVTop tri
      vbot = triVBottom tri
      (nl, nr)
        | triFacing tri = (wrapSucc vtop, wrapPred vtop)
        | otherwise = (wrapPred vtop, wrapSucc vtop)
      base = Raster tri vtop nl vtop nr 0 0 (setupDummy 0 False) (setupDummy 0 False)
  in if triYTop tri == triYBottom tri
       then base
         { rasXL = vertexX (vertexAt vs vtop)
         , rasXR = vertexX (vertexAt vs vbot)
         , rasSL = setupDummy (vertexX (vertexAt vs vtop)) False
         , rasSR = setupDummy (vertexX (vertexAt vs vbot)) False
         }
       else setupRightFast (setupLeftFast base y) y

setupLeftFast :: Raster -> Int32 -> Raster
setupLeftFast r y =
  let tri = rasTri r
      vs = triVertices tri
      (cur', next') = advanceLeft r y
      vc = vertexAt vs cur'
      vn = vertexAt vs next'
      (x, s) = setupSlopeFlat False (vertexX vc) (vertexX vn)
        (vertexY vc) (vertexY vn) y
  in r { rasCurVL = cur', rasNextVL = next', rasXL = x, rasSL = s }

setupRightFast :: Raster -> Int32 -> Raster
setupRightFast r y =
  let tri = rasTri r
      vs = triVertices tri
      (cur', next') = advanceRight r y
      vc = vertexAt vs cur'
      vn = vertexAt vs next'
      (x, s) = setupSlopeFlat True (vertexX vc) (vertexX vn)
        (vertexY vc) (vertexY vn) y
  in r { rasCurVR = cur', rasNextVR = next', rasXR = x, rasSR = s }

-- | Advance the left edge cursor until it straddles @y@, then set its slope.
setupLeft :: Raster -> Int32 -> Raster
setupLeft = setupLeftW False

-- | 'setupLeft' with the polygon's W-buffer flag, which decides whether the
-- edge interpolator keeps a perspective factor for W-buffered depth.
setupLeftW :: Bool -> Raster -> Int32 -> Raster
setupLeftW wbuf r y =
  let tri = rasTri r
      vs = triVertices tri
      (cur', next') = advanceLeft r y
      vc = vertexAt vs cur'
      vn = vertexAt vs next'
      (x, s) = setupSlope False (vertexX vc) (vertexX vn)
        (vertexY vc) (vertexY vn) (vertexW vc) (vertexW vn) y wbuf
  in r { rasCurVL = cur', rasNextVL = next', rasXL = x, rasSL = s }

-- | Advance the left cursor at most once per vertex. The three-vertex bound
-- keeps the recursion finite for synthesis.
advanceLeft :: Raster -> Int32 -> (Unsigned 2, Unsigned 2)
advanceLeft r y = go (0 :: Int) r
  where
    tri = rasTri r
    vs = triVertices tri
    go k rr
      | k >= 3 = (rasCurVL rr, rasNextVL rr)
      | y >= vertexY (vertexAt vs (rasNextVL rr))
          && rasCurVL rr /= triVBottom tri =
          let cur' = rasNextVL rr
              next' = if triFacing tri then wrapSucc cur' else wrapPred cur'
          in go (k + 1) (rr { rasCurVL = cur', rasNextVL = next' })
      | otherwise = (rasCurVL rr, rasNextVL rr)

-- | Advance the right edge cursor until it straddles @y@, then set its slope.
setupRight :: Raster -> Int32 -> Raster
setupRight = setupRightW False

setupRightW :: Bool -> Raster -> Int32 -> Raster
setupRightW wbuf r y =
  let tri = rasTri r
      vs = triVertices tri
      (cur', next') = advanceRight r y
      vc = vertexAt vs cur'
      vn = vertexAt vs next'
      (x, s) = setupSlope True (vertexX vc) (vertexX vn)
        (vertexY vc) (vertexY vn) (vertexW vc) (vertexW vn) y wbuf
  in r { rasCurVR = cur', rasNextVR = next', rasXR = x, rasSR = s }

advanceRight :: Raster -> Int32 -> (Unsigned 2, Unsigned 2)
advanceRight r y = go (0 :: Int) r
  where
    tri = rasTri r
    vs = triVertices tri
    go k rr
      | k >= 3 = (rasCurVR rr, rasNextVR rr)
      | y >= vertexY (vertexAt vs (rasNextVR rr))
          && rasCurVR rr /= triVBottom tri =
          let cur' = rasNextVR rr
              next' = if triFacing tri then wrapPred cur' else wrapSucc cur'
          in go (k + 1) (rr { rasCurVR = cur', rasNextVR = next' })
      | otherwise = (rasCurVR rr, rasNextVR rr)

-- | Per-row edge preparation with the depth interpolator refreshed.
prepareRowDepth :: Int32 -> Raster -> (Raster, Int32, Int32, Raster)
prepareRowDepth = prepareRowDepthW False

-- | 'prepareRowDepth' with the polygon's W-buffer flag. Returns the raster at
-- this row (edges advanced, interpolators at @y@), the raw span ends after
-- the right-edge pull-in, and the raster stepped to the next row.
prepareRowDepthW :: Bool -> Int32 -> Raster -> (Raster, Int32, Int32, Raster)
prepareRowDepthW wbuf y r0 =
  let tri = rasTri r0
      vs = triVertices tri
      r1
        | triYTop tri /= triYBottom tri
            && y >= vertexY (vertexAt vs (rasNextVL r0))
            && rasCurVL r0 /= triVBottom tri = setupLeftW wbuf r0 y
        | otherwise = r0
      r2
        | triYTop tri /= triYBottom tri
            && y >= vertexY (vertexAt vs (rasNextVR r1))
            && rasCurVR r1 /= triVBottom tri = setupRightW wbuf r1 y
        | otherwise = r1
      xstart = rasXL r2
      xend = rightPullIn (rasSL r2) (rasSR r2) xstart (rasXR r2)
      (xl, sl') = stepSlopeDepth (rasSL r2)
      (xr, sr') = stepSlopeDepth (rasSR r2)
      r' = r2 { rasXL = xl, rasXR = xr, rasSL = sl', rasSR = sr' }
  in (r2, xstart, xend, r')

edgeZ :: Slope -> Int32 -> Int32 -> Maybe Int32
edgeZ s z0 z1 = fmap (interpolateZ z0 z1) (slopeInterp s)

-- | One depth-carrying row span. Production interpolates Z over the raw edge
-- interval @[xstart, xend + 1)@ (after the right-edge pull-in and the edge
-- swap) and evaluates it only at the visible, clipped pixels.
data SpanZ = SpanZ
  { szX0  :: !Int32  -- ^ first visible X
  , szX1  :: !Int32  -- ^ last visible X, inclusive
  , szIX0 :: !Int32  -- ^ interpolator start: raw @xstart@
  , szIX1 :: !Int32  -- ^ interpolator end: raw @xend + 1@
  , szZ0  :: !Int32  -- ^ Z at the start edge
  , szZ1  :: !Int32  -- ^ Z at the end edge
  } deriving (Eq, Generic, Show, NFDataX)

-- | One depth-carrying span for a row.
rowSpanDepth :: Bool -> Int32 -> Raster -> (Maybe SpanZ, Raster)
rowSpanDepth = rowSpanDepthWith (\wb v -> finalZ wb (vertexZ v) (fromIntegral (vertexW v)))

rowSpanDepthWith :: (Bool -> Vertex -> Int32) -> Bool -> Int32 -> Raster
          -> (Maybe SpanZ, Raster)
rowSpanDepthWith zOf wbuf y r0 =
  let (r2, xstart, xend, r') = prepareRowDepth y r0
      tri = rasTri r0
      vs = triVertices tri
      vz = vertexAt vs
      zOf' v = zOf wbuf v
      zl0 = zOf' (vz (rasCurVL r2))
      zl1 = zOf' (vz (rasNextVL r2))
      zr0 = zOf' (vz (rasCurVR r2))
      zr1 = zOf' (vz (rasNextVR r2))
      zl = maybe 0 id (edgeZ (rasSL r2) zl0 zl1)
      zr = maybe 0 id (edgeZ (rasSR r2) zr0 zr1)
      (a, b, za, zb) = if xstart > xend
                         then (xend, xstart, zr, zl)
                         else (xstart, xend, zl, zr)
      x0 = max 0 a
      x1 = min (screenWidth - 1) b
  in (if x0 <= x1 then Just (SpanZ x0 x1 a (b + 1) za zb) else Nothing, r')

-- | Expand a span's edge Z values to every visible pixel (Z-buffer mode).
--
-- In Z-buffer mode @InterpolateZ@ reads only the X offset, the span length
-- and its reciprocal, never W or the perspective factor, so the interpolator is
-- built with equal weights: it is then linear and 'setX' does no division.
spanDepths :: SpanZ -> [Int32]
spanDepths s
  | szX1 s < szX0 s = []
  | otherwise =
      let i = setupInterp False (szIX0 s) (szIX1 s) 0 0 False
      in [ interpolateZ (szZ0 s) (szZ1 s) (setX x i) | x <- [szX0 s .. szX1 s] ]

-- | Rasterise a triangle with per-pixel depth. The reference starts at the
-- first visible row and returns the same X coverage as 'rasterTri'.
rasterTriDepth :: RasterConfig -> Bool -> Tri -> [[(Int32, Int32)]]
rasterTriDepth = rasterTriDepthWith (\wb v -> finalZ wb (vertexZ v) (fromIntegral (vertexW v)))

-- | Rasterise a triangle whose vertex Z values are already FinalZ.
rasterTriFinalDepth :: RasterConfig -> Tri -> [[(Int32, Int32)]]
rasterTriFinalDepth cfg tri = rasterTriDepthWith (\_ v -> vertexZ v) cfg False tri

-- | The span of a horizontal polygon (@YTop == YBottom@), per production
-- @SetupPolygon@: the left edge is the minimum-X vertex and the right edge the
-- maximum-X vertex (strict comparisons over vertices 1 then 2, so the first
-- vertex wins ties); each dummy edge yields its own vertex's Z; the usual
-- right-edge pull-in applies with both increments zero.
horizontalSpanZ :: (Vertex -> Int32) -> Tri -> Maybe SpanZ
horizontalSpanZ zOf tri
  | y < 0 || y > 191 || x0 > x1 = Nothing
  | otherwise = Just (SpanZ x0 x1 xs (xe + 1) (zOf vl) (zOf vr))
  where
    vs = triVertices tri
    pick better i cur = if better (vertexX (vertexAt vs i)) (vertexX (vertexAt vs cur)) then i else cur
    il = pick (<) 2 (pick (<) 1 0)
    ir = pick (>) 2 (pick (>) 1 0)
    vl = vertexAt vs il
    vr = vertexAt vs ir
    xs = vertexX vl
    xe0 = vertexX vr
    xe = if xs /= xe0 && xe0 /= 0 then xe0 - 1 else xe0
    y = triYTop tri
    x0 = max 0 xs
    x1 = min (screenWidth - 1) xe

rasterTriDepthWith :: (Bool -> Vertex -> Int32) -> RasterConfig -> Bool -> Tri -> [[(Int32, Int32)]]
rasterTriDepthWith zOf _cfg wbuf tri
  | triYTop tri == triYBottom tri =
      case horizontalSpanZ (zOf wbuf) tri of
        Nothing -> []
        Just s -> [ zip [szX0 s .. szX1 s] (spanDepths s) ]
  | startY >= endY = []
  | otherwise = go startY (setupRasterFrom tri startY) []
  where
    startY = max 0 (triYTop tri)
    endY = min 192 (triYBottom tri)
    go y r acc
      | y >= endY = reverse acc
      | otherwise =
          let (sp, r') = rowSpanDepthWith zOf wbuf y r
              row = case sp of
                Nothing -> []
                Just s -> zip [szX0 s .. szX1 s] (spanDepths s)
          in go (y + 1) r' (row : acc)

-- | Fill one scanline and return the covered X coordinates.
-- | Common per-row edge preparation: advance cursors, apply the right-edge
-- pull-in, and step both slopes.
prepareRow :: Int32 -> Raster -> (Raster, Int32, Int32, Raster)
prepareRow y r0 =
  let tri = rasTri r0
      vs = triVertices tri
      r1
        | triYTop tri /= triYBottom tri
            && y >= vertexY (vertexAt vs (rasNextVL r0))
            && rasCurVL r0 /= triVBottom tri = setupLeft r0 y
        | otherwise = r0
      r2
        | triYTop tri /= triYBottom tri
            && y >= vertexY (vertexAt vs (rasNextVR r1))
            && rasCurVR r1 /= triVBottom tri = setupRight r1 y
        | otherwise = r1
      xstart = rasXL r2
      xend = rightPullIn (rasSL r2) (rasSR r2) xstart (rasXR r2)
      (xl, sl') = stepSlope (rasSL r2)
      (xr, sr') = stepSlope (rasSR r2)
      r' = r2 { rasXL = xl, rasXR = xr, rasSL = sl', rasSR = sr' }
  in (r2, xstart, xend, r')

-- | 'prepareRow' with the divider-free flat edge setup.
prepareRowFast :: Int32 -> Raster -> (Raster, Int32, Int32, Raster)
prepareRowFast y r0 =
  let tri = rasTri r0
      vs = triVertices tri
      r1
        | triYTop tri /= triYBottom tri
            && y >= vertexY (vertexAt vs (rasNextVL r0))
            && rasCurVL r0 /= triVBottom tri = setupLeftFast r0 y
        | otherwise = r0
      r2
        | triYTop tri /= triYBottom tri
            && y >= vertexY (vertexAt vs (rasNextVR r1))
            && rasCurVR r1 /= triVBottom tri = setupRightFast r1 y
        | otherwise = r1
      xstart = rasXL r2
      xend = rightPullIn (rasSL r2) (rasSR r2) xstart (rasXR r2)
      (xl, sl') = stepSlope (rasSL r2)
      (xr, sr') = stepSlope (rasSR r2)
      r' = r2 { rasXL = xl, rasXR = xr, rasSL = sl', rasSR = sr' }
  in (r2, xstart, xend, r')

-- | The left-edge, interior and right-edge pieces of one row: inclusive X
-- ranges clipped to @0 .. cfgWidth - 1@, 'Nothing' where a piece is empty or
-- its edge is not filled.
type RowFill = (Maybe (Int32, Int32), Maybe (Int32, Int32), Maybe (Int32, Int32))

-- | The up-to-three filled X ranges for one row, before screen clipping.
-- Mirrors the left-edge, interior and right-edge split of the reference fill.
rowSpans :: RasterConfig -> Int32 -> Raster -> (RowFill, Raster)
rowSpans cfg y r0 =
  let (r2, xstart, xend, r') = prepareRow y r0
  in (rowFill cfg y r2 xstart xend, r')

-- | The production fill rules for one row, given the raster at that row and
-- the raw span ends after the right-edge pull-in (swapped when
-- @xstart > xend@).
rowFill :: RasterConfig -> Int32 -> Raster -> Int32 -> Int32 -> RowFill
rowFill cfg y r2 xstart xend =
  let tri = rasTri r2
      vs = triVertices tri
      nextX i = vertexX (vertexAt vs i)
  in spanPieces cfg
       (spanRule cfg (y == triYBottom tri - 1)
          (nextX (rasNextVL r2) /= nextX (rasNextVR r2))
          (rasSL r2) (rasSR r2) xstart xend)

-- | Production's right-edge pull-in (@RenderPolygonScanline@): a vertical
-- right edge is drawn one pixel further left unless the span is a single
-- column on a vertical left edge, or already at X 0.
rightPullIn :: Slope -> Slope -> Int32 -> Int32 -> Int32
rightPullIn sl sr xstart xend
  | slopeInc sr == 0 && (slopeInc sl /= 0 || xstart /= xend) && xend /= 0 = xend - 1
  | otherwise = xend

-- | One row's edge rules, independent of the polygon's vertex count: the
-- span in drawing order, each edge's 'edgeParams' (length and anti-aliasing
-- coverage word) and whether its pixels are filled. When the edges cross
-- (@xstart > xend@) the span is drawn from the right edge: 'srStart' is
-- then the right edge's X and the start-edge fields come from the right
-- slope's swapped 'edgeParams'.
data SpanRule = SpanRule
  { srSwapped :: !Bool
  , srStart   :: !Int32  -- ^ first X of the span (@xstart@ after the swap)
  , srEnd     :: !Int32  -- ^ last X, inclusive (@xend@ after the swap)
  , srLLen    :: !Int32  -- ^ @l_edgelen@
  , srLCov    :: !Int32  -- ^ @l_edgecov@
  , srRLen    :: !Int32  -- ^ @r_edgelen@
  , srRCov    :: !Int32  -- ^ @r_edgecov@
  , srLFill   :: !Bool   -- ^ @l_filledge@
  , srRFill   :: !Bool   -- ^ @r_filledge@
  } deriving (Eq, Generic, Show, NFDataX)

-- | The edge rules of @RenderPolygonScanline@ (and the shadow-mask
-- scanline, which shares them). @lastRow@ is @y == YBottom - 1@;
-- @nextXDiffer@ is whether the two edges' next vertices have different X.
spanRule :: RasterConfig -> Bool -> Bool -> Slope -> Slope -> Int32 -> Int32 -> SpanRule
spanRule = spanRuleWith edgeParams

-- | 'spanRule' with @EdgeParams@ supplied (the hardware passes
-- 'edgeParamsWith' and its own coverage divider).
spanRuleWith :: (Bool -> Slope -> (Int32, Int32))
             -> RasterConfig -> Bool -> Bool -> Slope -> Slope -> Int32 -> Int32 -> SpanRule
spanRuleWith params cfg lastRow nextXDiffer sl sr xstart xend
  | xstart > xend =
      let (llen, lcov) = params True sr
          (rlen, rcov) = params True sl
          lfill = always
            || slopeNegative sr || not (slopeXMajor sr)
            || (lastRow && slopeXMajor sr && nextXDiffer)
          rfill = always
            || (not (slopeNegative sl) && slopeXMajor sl)
            || (not (slopeNegative sl && slopeXMajor sl) && slopeInc sr == 0)
            || (lastRow && slopeXMajor sl && nextXDiffer)
      in SpanRule True xend xstart llen lcov rlen rcov lfill rfill
  | otherwise =
      let (llen, lcov) = params False sl
          (rlen, rcov) = params False sr
          lfill = always
            || slopeNegative sl || not (slopeXMajor sl)
            || (lastRow && slopeXMajor sl && nextXDiffer)
            || (slopeInc sl == slopeInc sr && xstart + llen == xend + 1)
          rfill = always
            || (not (slopeNegative sr) && slopeXMajor sr)
            || slopeInc sr == 0
            || (lastRow && slopeXMajor sr && nextXDiffer)
      in SpanRule False xstart xend llen lcov rlen rcov lfill rfill
  where
    always = alwaysFilled cfg

-- | The three pieces production's pixel loops visit, as inclusive X ranges
-- clipped to @0 .. cfgWidth - 1@: the start edge (when filled), the
-- interior, and the end edge (when filled). The cursor never moves left, so
-- an interior shorter than the start edge is empty and the end edge begins
-- where the further of the two stopped.
spanPieces :: RasterConfig -> SpanRule -> RowFill
spanPieces cfg r =
  let mk a b = if a <= b then Just (a, b) else Nothing
      clamp v = max 0 (min (cfgWidth cfg) v)
      a0 = srStart r
      b0 = srEnd r
      x0 = max a0 0
      limL = clamp (min (a0 + srLLen r) (b0 + 1))
      limI = clamp (min (b0 - srRLen r + 1) (b0 + 1))
      x2 = max limL limI
      limR = clamp (b0 + 1)
  in ( if srLFill r then mk x0 (limL - 1) else Nothing
     , mk limL (limI - 1)
     , if srRFill r then mk x2 (limR - 1) else Nothing )

-- | Fill one scanline and return the covered X coordinates.
renderRow :: RasterConfig -> Int32 -> Raster -> ([Int32], Raster)
renderRow cfg y r0 =
  let ((sa, sb, sc), r') = rowSpans cfg y r0
      expand (Just (a, b)) = [max 0 a .. min (cfgWidth cfg) b]
      expand Nothing = []
  in (concatMap expand [sa, sb, sc], r')

bit :: Int -> Int32
bit n = 0x1 `shiftL` n

-- | The fill rules reduce to this predicate for the flat configuration.
alwaysFilled :: RasterConfig -> Bool
alwaysFilled cfg =
  (cfgDispCnt cfg .&. (bit 4 + bit 5)) /= 0
    || (cfgPolyAlpha cfg < (bit 5) - 1
        && cfgDispCnt cfg .&. bit 3 /= 0)
    || cfgWireframe cfg

-- | Rasterise the visible portion of a triangle, returning the covered X
-- coordinates per scanline. The production renderer only visits 0..191, so the
-- reference starts at the first visible row instead of walking clipped rows.
rasterTri :: RasterConfig -> Tri -> [[Int32]]
rasterTri cfg tri
  | triYTop tri == triYBottom tri =
      let vs = triVertices tri
          v0 = vertexAt vs 0
          v1 = vertexAt vs 1
          v2 = vertexAt vs 2
          lo = minimum [vertexX v0, vertexX v1, vertexX v2]
          hi = maximum [vertexX v0, vertexX v1, vertexX v2]
          y = triYTop tri
      in if y < 0 || y > 191 then []
         else [ [ max 0 lo .. min 255 (hi - 1) ] ]
  | startY >= endY = []
  | otherwise = go startY (setupRasterFrom tri startY) []
  where
    startY = max 0 (triYTop tri)
    endY = min 192 (triYBottom tri)
    go y r acc
      | y >= endY = reverse acc
      | otherwise =
          let (xs, r') = renderRow cfg y r
          in go (y + 1) r' (xs : acc)
