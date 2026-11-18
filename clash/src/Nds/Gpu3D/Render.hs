{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- | The pure model of @SoftRenderer3D::RenderFrame@: one 'RenderFrame' (the
-- latched @Render*@ registers and the sorted polygon list) and the texture
-- memories in, both colour/depth/attribute layers and the 192 lines
-- @GetLine@ returns out.
--
-- The model is built from the steps production takes, each a pure function
-- the hardware can implement against:
--
-- * 'setupPolygon' (@SetupPolygon@) once per polygon, then per scanline
--   'advanceEdges' (@SetupPolygonLeftEdge@\/@RightEdge@, the n-gon vertex
--   walk), 'spanSetup' (pull-in, edge swap, fill rules, edge lengths and
--   anti-aliasing coverage words, edge attribute values, the span
--   interpolator) and 'stepEdges' (@Slope::Step@).
-- * 'polygonPixel' (one pixel of @RenderPolygonScanline@: shadow stencil,
--   the two-layer depth test, shading, the alpha test, the opaque write with
--   its anti-aliasing coverage and push-down, @PlotTranslucentPixel@ on one
--   or both layers) and 'maskPixel' (one pixel of
--   @RenderShadowMaskScanline@).
-- * 'renderScanline': every active polygon, in list order, over one line of
--   both layers and the two-line stencil buffer.
-- * 'finalPass' (@ScanlineFinalPass@): edge marking, fog and the
--   anti-aliasing blend over one line, given the top layer's polygon IDs and
--   depths on the lines above and below.
-- * 'clearLine' (@ClearBuffers@, colour or rear-plane image) and
--   'outputLine' (@GetLine@ with @RenderXPos@).
--
-- 'renderFrameFrom' threads the state production keeps between frames: the
-- lower layer (which @ClearBuffers@ never clears), the stencil buffer and the
-- "previous polygon was a shadow mask" flag. 'renderFrame' starts from a
-- reset renderer ('resetCarry': zero buffers, no previous mask). A stale
-- stencil line reaches the picture when a frame's first polygon drawn on it
-- is a mask and the previous frame's last polygon drawn was one too.
module Nds.Gpu3D.Render
  ( -- * Frame
    renderFrame
  , renderFrameFrom
  , RenderOut (..)
  , Layer (..)
  , Carry (..)
  , resetCarry
    -- * Polygon setup and the edge walk
  , RPoly (..)
  , setupPolygon
  , polygonActive
  , advanceEdges
  , stepEdges
    -- * One scanline
  , FrameCtx (..)
  , frameCtx
  , LineBuf (..)
  , ScanState (..)
  , renderScanline
  , SpanSetup (..)
  , spanSetup
  , Piece (..)
  , Px (..)
  , polygonPixel
  , pixelTarget
  , pixelCommit
  , startCoverage
  , maskPixel
  , maskPixelWith
  , edgeValue
  , edgeDepth
    -- * Clear, final pass and output
  , clearLine
  , clearColourPixel
  , clearImagePixel
  , clearImageOffset
  , Nbr (..)
  , finalPass
  , finalPixel
  , finalPixelWith
  , fogDensity
  , fogDensityWith
  , outputLine
  , outputSource
  ) where

import Prelude

import Control.Monad (foldM, forM, forM_, unless)
import Control.Monad.ST (ST, runST)
import Data.Array.ST (STUArray, freeze, readArray, thaw, writeArray)
import Data.Array.Unboxed (Array, UArray, listArray, (!))
import qualified Data.Array.Unboxed as A
import Data.Bits (complement, shiftL, shiftR, testBit, (.&.), (.|.))
import Data.Int (Int16, Int32)
import qualified Data.IntMap.Strict as IM
import Data.List (foldl')
import Data.STRef (newSTRef, readSTRef, writeSTRef)
import Data.Word (Word16, Word32, Word8)
import GHC.Generics (Generic)

import Clash.Prelude (NFDataX, Unsigned)

import Nds.Gpu3D.Depth (DepthMode (..), Interp, depthPass, interpolate, interpolateZ, setX, setupInterp)
import Nds.Gpu3D.Raster (RasterConfig (..), RowFill, SpanRule (..), rightPullIn, spanPieces, spanRule)
import Nds.Gpu3D.Shade (PixelWrite (..), expand555, packColour)
import Nds.Gpu3D.ShadePipe (PixelIn (..), PixelOut (..), ShadeCfg (..), pixelWithMemory)
import Nds.Gpu3D.Slope (Slope (..), setupDummy, setupSlope, stepSlopeDepth)
import Nds.Gpu3D.Texture (TexMem (..))
import Nds.Gpu3D.Types (GxPolygon (..), GxVertex (..), RenderFrame (..), RenderRegs (..))

------------------------------------------------------------------------------
-- Frame

-- | One 256x192 layer, row-major (@y * 256 + x@), in the renderer's internal
-- word formats: colour is 6-bit R, G, B in bytes 0-2 and a 5-bit alpha in
-- byte 3; depth is the 24-bit Z or W value; the attribute word holds the
-- edge flags (bits 0-3), back-facing (4), anti-aliasing coverage (8-12),
-- fog (15), translucent polygon ID (16-21), translucent (22) and opaque
-- polygon ID (24-29).
data Layer = Layer
  { lyColour :: !(UArray Int Word32)
  , lyDepth  :: !(UArray Int Word32)
  , lyAttr   :: !(UArray Int Word32)
  } deriving (Eq, Show)

-- | A rendered frame: the top layer and the lower (anti-aliasing) layer
-- after the final pass, and the 192 lines of 256 colour words @GetLine@
-- returns with @RenderXPos@ applied (row-major).
data RenderOut = RenderOut
  { roTop   :: !Layer
  , roLower :: !Layer
  , roLines :: !(UArray Int Word32)
  } deriving (Eq, Show)

-- | What production keeps from one frame to the next: the lower layer, the
-- two-line stencil buffer and @PrevIsShadowMask@.
data Carry = Carry
  { caLower    :: !Layer
  , caStencil  :: !(UArray Int Word8)  -- ^ 512 entries, line @y .&. 1@ at @256 * (y .&. 1)@
  , caPrevMask :: !Bool
  } deriving (Eq, Show)

-- | A freshly reset renderer: zero buffers, no previous shadow mask.
resetCarry :: Carry
resetCarry =
  let z = listArray (0, 256 * 192 - 1) (replicate (256 * 192) 0)
  in Carry (Layer z z z) (listArray (0, 511) (replicate 512 0)) False

-- | Render one frame from a reset renderer.
renderFrame :: TexMem -> RenderFrame -> RenderOut
renderFrame mem rf = fst (renderFrameFrom resetCarry mem rf)

-- | @ClearBuffers@, then @RenderPolygons@: the non-degenerate polygons are
-- set up in list order, every scanline renders its active polygons, and
-- every line gets its final pass. Production runs the final pass of line
-- @y - 1@ after rendering line @y@; the final pass changes neither depth nor
-- polygon IDs, the only values it reads from neighbouring lines, so running
-- it after all lines are rendered is the same.
renderFrameFrom :: Carry -> TexMem -> RenderFrame -> (RenderOut, Carry)
renderFrameFrom carry mem rf =
  let regs = rfRegs rf
      ctx = frameCtx mem regs
      polys0 = IM.fromList (zip [0 ..] [ setupPolygon p | p <- rfPolys rf, not (gpDegenerate p) ])
      lowerRow y =
        let base = fromIntegral (y :: Int32) * 256
            row a = listArray (0, 255) [ a ! (base + i) | i <- [0 .. 255] ]
            lw = caLower carry
        in (row (lyColour lw), row (lyDepth lw), row (lyAttr lw))
      startLine y =
        let (c, d, a) = clearLine regs mem y
            (lc, ld, la) = lowerRow y
        in LineBuf c d a lc ld la
      raster !y ps st acc
        | y > 191 = (reverse acc, st)
        | otherwise =
            let ids = [ i | (i, p) <- IM.toAscList ps, polygonActive y p ]
                (ps', st', lb) = renderScanline ctx y (map (ps IM.!) ids) st (startLine y)
                ps'' = foldl' (\m (i, p) -> IM.insert i p m) ps (zip ids ps')
            in raster (y + 1) ps'' st' (lb : acc)
      (rows, stEnd) = raster 0 polys0 (ScanState (caStencil carry) (caPrevMask carry)) []
      rowArr = A.listArray (0, 191) rows :: Array Int LineBuf
      neighbour y
        | y < 0 || y > 191 = Nothing
        | otherwise = Just (rowArr A.! y)
      finals = [ finalPass regs (neighbour (y - 1)) (neighbour (y + 1)) (rowArr A.! y) | y <- [0 .. 191] ]
      cat f = listArray (0, 256 * 192 - 1) (concatMap (A.elems . f) finals)
      top = Layer (cat lbColour) (cat lbDepth) (cat lbAttr)
      lower = Layer (cat lbLColour) (cat lbLDepth) (cat lbLAttr)
      outLines = listArray (0, 256 * 192 - 1)
        (concatMap (outputLine (rrXPos regs) . lbColour) finals)
  in ( RenderOut top lower outLines
     , Carry lower (ssStencil stEnd) (ssPrevMask stEnd) )

------------------------------------------------------------------------------
-- Polygon setup and the edge walk

-- | @RendererPolygon@: the polygon's vertex data, the per-polygon state
-- @SetupPolygon@ derives, and the live edge walk (current and next vertex
-- of each edge, the edges' X on the current line and their slopes).
data RPoly = RPoly
  { rpPoly   :: !GxPolygon
  , rpN      :: !Int
  , rpX, rpY :: !(UArray Int Int32)        -- ^ @FinalPosition@
  , rpR, rpG, rpB :: !(UArray Int Int32)   -- ^ @FinalColor@
  , rpS, rpT :: !(UArray Int Int32)        -- ^ @TexCoords@, sign-extended
  , rpZ, rpW :: !(UArray Int Int32)        -- ^ @FinalZ@, @FinalW@
  , rpAttr   :: !Word32     -- ^ @PolyAttr@: @Attr .&. 0x3F008000@, bit 4 when back-facing
  , rpMode   :: !DepthMode
  , rpAlpha  :: !Word32     -- ^ polygon alpha, attribute bits 16-20
  , rpWire   :: !Bool       -- ^ polygon alpha 0
  , rpCurVL, rpNextVL, rpCurVR, rpNextVR :: !Int
  , rpXL, rpXR :: !Int32
  , rpSL, rpSR :: !Slope
  } deriving (Show)

-- | @SetupPolygon@. Both edges start at @VTop@; a front-facing polygon walks
-- its left edge forwards through the vertex list and its right edge
-- backwards, a back-facing one the other way round. A horizontal polygon
-- (@YTop == YBottom@) instead gets two dummy edges at the minimum- and
-- maximum-X vertex, chosen among vertices 0, 1 and @n - 1@ only, the first
-- one winning ties.
setupPolygon :: GxPolygon -> RPoly
setupPolygon p =
  let vs = gpVerts p
      n = length vs
      arr :: [Int32] -> UArray Int Int32
      arr = listArray (0, n - 1)
      attr = gpAttr p
      alpha = (attr `shiftR` 16) .&. 0x1F
      wbuf = gpWBuffer p
      mode
        | testBit attr 14 = if wbuf then DepthEqualW else DepthEqualZ
        | gpFacingView p = DepthLessFront
        | otherwise = DepthLess
      xs = arr (map gvX vs)
      vtop = gpVTop p
      (nl, nr)
        | gpFacingView p = (wrapNext n vtop, wrapPrev n vtop)
        | otherwise = (wrapPrev n vtop, wrapNext n vtop)
      base = RPoly
        { rpPoly = p, rpN = n
        , rpX = xs, rpY = arr (map gvY vs)
        , rpR = arr (map gvR vs), rpG = arr (map gvG vs), rpB = arr (map gvB vs)
        , rpS = arr (map (fromIntegral . gvS) vs), rpT = arr (map (fromIntegral . gvT) vs)
        , rpZ = arr (take n (gpFinalZ p)), rpW = arr (take n (gpFinalW p))
        , rpAttr = (attr .&. 0x3F008000) .|. (if gpFacingView p then 0 else 0x10)
        , rpMode = mode
        , rpAlpha = alpha
        , rpWire = alpha == 0
        , rpCurVL = vtop, rpNextVL = nl, rpCurVR = vtop, rpNextVR = nr
        , rpXL = 0, rpXR = 0
        , rpSL = setupDummy 0 wbuf, rpSR = setupDummy 0 wbuf
        }
      pick better i cur = if better (xs ! i) (xs ! cur) then i else cur
      hl = pick (<) (n - 1) (pick (<) 1 0)
      hr = pick (>) (n - 1) (pick (>) 1 0)
      ytop = gpYTop p
  in if gpYBottom p == ytop
       then base
         { rpCurVL = hl, rpNextVL = hl, rpCurVR = hr, rpNextVR = hr
         , rpXL = xs ! hl, rpXR = xs ! hr
         , rpSL = setupDummy (xs ! hl) wbuf, rpSR = setupDummy (xs ! hr) wbuf
         }
       else rightEdge ytop (leftEdge ytop base)

wrapNext, wrapPrev :: Int -> Int -> Int
wrapNext n i = if i + 1 >= n then 0 else i + 1
wrapPrev n i = if i - 1 < 0 then n - 1 else i - 1

-- | @SetupPolygonLeftEdge@: advance the left cursor while line @y@ is at or
-- below its next vertex and it has not reached @VBottom@, then set up the
-- left slope between the two cursor vertices.
leftEdge :: Int32 -> RPoly -> RPoly
leftEdge y rp =
  let step = if gpFacingView (rpPoly rp) then wrapNext (rpN rp) else wrapPrev (rpN rp)
      (c, nx) = walkEdge y rp step (rpCurVL rp) (rpNextVL rp)
      (x, s) = edgeSlope False y rp c nx
  in rp { rpCurVL = c, rpNextVL = nx, rpXL = x, rpSL = s }

-- | @SetupPolygonRightEdge@, walking the other way round.
rightEdge :: Int32 -> RPoly -> RPoly
rightEdge y rp =
  let step = if gpFacingView (rpPoly rp) then wrapPrev (rpN rp) else wrapNext (rpN rp)
      (c, nx) = walkEdge y rp step (rpCurVR rp) (rpNextVR rp)
      (x, s) = edgeSlope True y rp c nx
  in rp { rpCurVR = c, rpNextVR = nx, rpXR = x, rpSR = s }

-- | The cursor loop. It stops at @VBottom@ at the latest, so it takes at
-- most @n@ steps.
walkEdge :: Int32 -> RPoly -> (Int -> Int) -> Int -> Int -> (Int, Int)
walkEdge y rp step = go (rpN rp)
  where
    vbot = gpVBottom (rpPoly rp)
    go k cur next
      | k > 0 && y >= rpY rp ! next && cur /= vbot = go (k - 1) next (step next)
      | otherwise = (cur, next)

edgeSlope :: Bool -> Int32 -> RPoly -> Int -> Int -> (Int32, Slope)
edgeSlope side y rp c nx =
  setupSlope side (rpX rp ! c) (rpX rp ! nx) (rpY rp ! c) (rpY rp ! nx)
    (rpW rp ! c) (rpW rp ! nx) y (gpWBuffer (rpPoly rp))

-- | Is the polygon drawn on line @y@? Lines @YTop .. YBottom - 1@, and the
-- single line of a horizontal polygon.
polygonActive :: Int32 -> RPoly -> Bool
polygonActive y rp =
  let p = rpPoly rp
  in y >= gpYTop p && (y < gpYBottom p || (y == gpYTop p && gpYBottom p == gpYTop p))

-- | The start of every polygon scanline: an edge whose next vertex line
-- has been reached is set up again from the cursor walk.
advanceEdges :: Int32 -> RPoly -> RPoly
advanceEdges y rp0
  | gpYTop p == gpYBottom p = rp0
  | otherwise =
      let rp1 = if y >= rpY rp0 ! rpNextVL rp0 && rpCurVL rp0 /= vbot then leftEdge y rp0 else rp0
      in if y >= rpY rp1 ! rpNextVR rp1 && rpCurVR rp1 /= vbot then rightEdge y rp1 else rp1
  where
    p = rpPoly rp0
    vbot = gpVBottom p

-- | The end of every polygon scanline: both slopes step one line.
stepEdges :: RPoly -> RPoly
stepEdges rp =
  let (xl, sl) = stepSlopeDepth (rpSL rp)
      (xr, sr) = stepSlopeDepth (rpSR rp)
  in rp { rpXL = xl, rpXR = xr, rpSL = sl, rpSR = sr }

------------------------------------------------------------------------------
-- One scanline

-- | The frame-wide state every pixel reads.
data FrameCtx = FrameCtx
  { fcRegs  :: !RenderRegs
  , fcMem   :: !TexMem
  , fcShade :: !ShadeCfg
  , fcToon  :: !(Unsigned 5 -> Word16)
  }

frameCtx :: TexMem -> RenderRegs -> FrameCtx
frameCtx mem regs =
  let toon = listArray (0, 31) (take 32 (rrToonTable regs ++ repeat 0)) :: UArray Int Word16
  in FrameCtx regs mem (ShadeCfg (rrDispCnt regs) (fromIntegral (rrAlphaRef regs)))
       (\i -> toon ! fromIntegral i)

-- | One line of both layers, X 0..255.
data LineBuf = LineBuf
  { lbColour, lbDepth, lbAttr :: !(UArray Int Word32)     -- ^ top layer
  , lbLColour, lbLDepth, lbLAttr :: !(UArray Int Word32)  -- ^ lower layer
  } deriving (Eq, Show)

-- | The rasteriser state that crosses polygons and lines: the two-line
-- stencil buffer (bit 0: the top layer failed a mask's depth test, bit 1:
-- the lower layer did) and whether the last polygon drawn was a mask.
data ScanState = ScanState
  { ssStencil  :: !(UArray Int Word8)
  , ssPrevMask :: !Bool
  } deriving (Eq, Show)

-- | @RenderScanline@: the active polygons of line @y@, in list order, over
-- the line's two layers. Returns the polygons with their edge walk advanced
-- to the next line.
renderScanline :: FrameCtx -> Int32 -> [RPoly] -> ScanState -> LineBuf
               -> ([RPoly], ScanState, LineBuf)
renderScanline ctx y polys st0 lb0 = runST $ do
  topC <- thawU (lbColour lb0)
  topD <- thawU (lbDepth lb0)
  topA <- thawU (lbAttr lb0)
  lowC <- thawU (lbLColour lb0)
  lowD <- thawU (lbLDepth lb0)
  lowA <- thawU (lbLAttr lb0)
  stencil <- thawW8 (ssStencil st0)
  prevRef <- newSTRef (ssPrevMask st0)
  let regs = fcRegs ctx
      disp = rrDispCnt regs
      sbase = fromIntegral ((y .&. 1) * 256) :: Int
      readPx x = do
        let i = fromIntegral x
        Px <$> readArray topC i <*> readArray topD i <*> readArray topA i
           <*> readArray lowC i <*> readArray lowD i <*> readArray lowA i
      writePx x (Px c d a lc ld la) = do
        let i = fromIntegral x
        writeArray topC i c >> writeArray topD i d >> writeArray topA i a
        writeArray lowC i lc >> writeArray lowD i ld >> writeArray lowA i la
      xsOf (l, m, r) = [ (pc, x) | (pc, Just (a, b)) <- [(PLeft, l), (PInner, m), (PRight, r)]
                                 , x <- [a .. b] ]

      maskScan rp = do
        prev <- readSTRef prevRef
        unless prev $ forM_ [0 .. 255] $ \x -> writeArray stencil (sbase + x) 0
        writeSTRef prevRef True
        let rp1 = advanceEdges y rp
            alpha = if rpWire rp1 then 31 else rpAlpha rp1
        if alpha <= fromIntegral (rrAlphaRef regs)
          then pure rp1
          else do
            let sp = spanSetup disp y rp1
            forM_ (xsOf (spPieces sp)) $ \(_, x) -> do
              px <- readPx x
              s <- readArray stencil (sbase + fromIntegral x)
              writeArray stencil (sbase + fromIntegral x) (maskPixel rp1 sp x px s)
            pure (stepEdges rp1)

      polyScan rp = do
        writeSTRef prevRef False
        let rp1 = advanceEdges y rp
            sp = spanSetup disp y rp1
            rule = spRule sp
            (pl, pm, pr) = spPieces sp
            run piece range xc0 = case range of
              Nothing -> pure xc0
              Just (a, b) -> foldM (pixel piece) xc0 [a .. b]
            pixel piece xc x = do
              px <- readPx x
              s <- readArray stencil (sbase + fromIntegral x)
              let (px', xc') = polygonPixel ctx rp1 sp piece x s xc px
              writePx x px'
              pure xc'
        xc1 <- run PLeft pl (startCoverage (srLCov rule) 0)
        xc2 <- run PInner pm xc1
        _ <- run PRight pr (startCoverage (srRCov rule) xc2)
        pure (stepEdges rp1)

  polys' <- forM polys $ \rp ->
    if gpShadowMask (rpPoly rp) then maskScan rp else polyScan rp
  lb' <- LineBuf <$> freezeU topC <*> freezeU topD <*> freezeU topA
                 <*> freezeU lowC <*> freezeU lowD <*> freezeU lowA
  st' <- ScanState <$> freezeW8 stencil <*> readSTRef prevRef
  pure (polys', st', lb')

-- | The coverage accumulator an X-major edge starts its piece with: the
-- start coverage from its coverage word (@0x3FF@ reads as 0). A Y-major
-- edge's word is a plain coverage and leaves the accumulator alone.
startCoverage :: Int32 -> Int32 -> Int32
startCoverage cov xcov
  | cov < 0 = let v = (cov `shiftR` 12) .&. 0x3FF in if v == 0x3FF then 0 else v
  | otherwise = xcov

thawU :: UArray Int Word32 -> ST s (STUArray s Int Word32)
thawU = thaw

thawW8 :: UArray Int Word8 -> ST s (STUArray s Int Word8)
thawW8 = thaw

freezeU :: STUArray s Int Word32 -> ST s (UArray Int Word32)
freezeU = freeze

freezeW8 :: STUArray s Int Word8 -> ST s (UArray Int Word8)
freezeW8 = freeze

-- | Everything one polygon scanline computes before its pixel loops.
data SpanSetup = SpanSetup
  { spRule   :: !SpanRule  -- ^ swap, edge lengths, coverage words, fill rules
  , spPieces :: !RowFill   -- ^ the X ranges the three pixel loops visit
  , spYEdge  :: !Word32    -- ^ 4 on the polygon's first line, 8 on its last
  , spInterp :: !Interp    -- ^ @Interpolator<0>(xstart, xend + 1, wl, wr)@
  , spZ      :: !(Int32, Int32)  -- ^ start- and end-edge values in drawing order
  , spR, spG, spB, spS, spT :: !(Int32, Int32)
  }

-- | The per-line part of @RenderPolygonScanline@ (and of
-- @RenderShadowMaskScanline@) for a polygon whose edges were advanced to
-- line @y@: edge W and Z, the right-edge pull-in, the swap when the edges
-- cross, the fill rules, the vertex colour and texture coordinates at both
-- edges, and the span interpolator. A wireframe polygon draws no interior
-- except on its first and last line.
spanSetup :: Word32 -> Int32 -> RPoly -> SpanSetup
spanSetup disp y rp =
  let p = rpPoly rp
      sl = rpSL rp
      sr = rpSR rp
      cl = rpCurVL rp
      nl = rpNextVL rp
      cr = rpCurVR rp
      nr = rpNextVR rp
      wl = edgeValue sl (rpW rp ! cl) (rpW rp ! nl)
      wr = edgeValue sr (rpW rp ! cr) (rpW rp ! nr)
      zl = edgeDepth sl (rpZ rp ! cl) (rpZ rp ! nl)
      zr = edgeDepth sr (rpZ rp ! cr) (rpZ rp ! nr)
      xstart = rpXL rp
      xend = rightPullIn sl sr xstart (rpXR rp)
      cfg = RasterConfig (fromIntegral disp) (fromIntegral (rpAlpha rp)) (rpWire rp) 256
      rule = spanRule cfg (y == gpYBottom p - 1) (rpX rp ! nl /= rpX rp ! nr) sl sr xstart xend
      swapped = srSwapped rule
      (sA, aC, aN, sB, bC, bN)
        | swapped = (sr, cr, nr, sl, cl, nl)
        | otherwise = (sl, cl, nl, sr, cr, nr)
      (wA, wB, zA, zB)
        | swapped = (wr, wl, zr, zl)
        | otherwise = (wl, wr, zl, zr)
      pair a = (edgeValue sA (a ! aC) (a ! aN), edgeValue sB (a ! bC) (a ! bN))
      yedge
        | y == gpYTop p = 0x4
        | y == gpYBottom p - 1 = 0x8
        | otherwise = 0x0
      (pl, pm, pr) = spanPieces cfg rule
      inner = if rpWire rp && yedge == 0 then Nothing else pm
  in SpanSetup
    { spRule = rule
    , spPieces = (pl, inner, pr)
    , spYEdge = yedge
    , spInterp = setupInterp False (srStart rule) (srEnd rule + 1) wA wB (gpWBuffer p)
    , spZ = (zA, zB)
    , spR = pair (rpR rp), spG = pair (rpG rp), spB = pair (rpB rp)
    , spS = pair (rpS rp), spT = pair (rpT rp)
    }

-- | An edge's interpolated value on the current line; a dummy edge (a
-- horizontal polygon's) has no extent and yields its vertex's value.
edgeValue, edgeDepth :: Slope -> Int32 -> Int32 -> Int32
edgeValue s a b = maybe a (interpolate a b) (slopeInterp s)
edgeDepth s a b = maybe a (interpolateZ a b) (slopeInterp s)

-- | Which of the three pixel loops a pixel belongs to.
data Piece = PLeft | PInner | PRight
  deriving (Eq, Show, Generic, NFDataX)

-- | Both layers at one X.
data Px = Px
  { pxC, pxD, pxA    :: !Word32  -- ^ top colour, depth, attribute
  , pxLC, pxLD, pxLA :: !Word32  -- ^ lower colour, depth, attribute
  } deriving (Eq, Show, Generic, NFDataX)

-- | One pixel of @RenderPolygonScanline@, given the stencil entry at X and
-- the coverage accumulator of the current edge piece:
--
-- 1. a shadow polygon draws only where the stencil is set, into the lower
--    layer when only bit 1 is, and ignores the top's edge flags when bit 1
--    is clear;
-- 2. the depth test runs against the top layer, and when it fails on an
--    edge pixel (attribute bits 0-3) against the lower layer instead;
-- 3. the pixel is shaded ('pixelWithMemory': texture, toon, highlight,
--    alpha test, translucent-ID rules);
-- 4. an opaque pixel is written with its edge flags; with anti-aliasing an
--    edge pixel also gets its coverage (bits 8-12) and, when it lands on the
--    top layer, pushes the old top pixel down;
-- 5. a translucent pixel is plotted on its layer and, when it landed on an
--    edge pixel of the top layer, on the lower layer too.
--
-- Returns the updated layers and coverage accumulator. The depth and stencil
-- part is 'pixelTarget', the write part 'pixelCommit'; the hardware shades
-- between the two.
polygonPixel :: FrameCtx -> RPoly -> SpanSetup -> Piece -> Int32 -> Word8 -> Int32 -> Px
             -> (Px, Int32)
polygonPixel ctx rp sp piece x st xcov px =
  case pixelTarget (gpShadow p) (rpMode rp) z st px of
    Nothing -> (px, xcov)
    Just t@(lower, _) ->
      pixelCommit (testBit (rrDispCnt (fcRegs ctx)) 4) edge piece (spRule sp) z t
        (plot lower px) (plot True px) xcov px
  where
    p = rpPoly rp
    i = setX x (spInterp sp)
    z = uncurry interpolateZ (spZ sp) i
    edge = spYEdge sp .|. (case piece of PLeft -> 0x1; PInner -> 0x0; PRight -> 0x2)
    at (a, b) = interpolate a b i
    c6 v = fromIntegral ((fromIntegral v :: Word32) `shiftR` 3) :: Word8
    plot lower q =
      let (dc, da) = if lower then (pxLC q, pxLA q) else (pxC q, pxA q)
          pin = PixelIn (gpTexParam p) (gpTexPalette p) (gpAttr p) (gpFacingView p)
                  (c6 (at (spR sp)), c6 (at (spG sp)), c6 (at (spB sp)))
                  (fromIntegral (at (spS sp)) :: Int16) (fromIntegral (at (spT sp)) :: Int16)
                  edge dc da z (fromIntegral x)
      in poWrite (pixelWithMemory (fcMem ctx) (fcShade ctx) (fcToon ctx) pin)

-- | Steps 1 and 2 of 'polygonPixel' for a polygon with the given shadow flag
-- and depth mode, at depth @z@ over stencil entry @st@: the layer the pixel
-- is plotted on ('True' for the lower one) and the destination attribute
-- its test read, or 'Nothing' when it draws nothing.
pixelTarget :: Bool -> DepthMode -> Int32 -> Word8 -> Px -> Maybe (Bool, Word32)
pixelTarget shadow mode z st px
  | shadow && st == 0 = Nothing
  | test (if toLower0 then pxLD px else pxD px) dstattr0 = Just (toLower0, dstattr0)
  | dstattr0 .&. 0xF == 0 || toLower0 = Nothing
  | test (pxLD px) (pxLA px) = Just (True, pxLA px)
  | otherwise = Nothing
  where
    toLower0 = shadow && not (testBit st 0)
    dstattr0
      | shadow && not (testBit st 1) = pxA px .&. complement 0xF
      | otherwise = pxA px
    test d a = depthPass mode (a .&. 0x400010 == 0x10) (fromIntegral d) z

-- | Steps 4 and 5 of 'polygonPixel', given DISP3DCNT bit 4, the pixel's edge
-- flags, its piece, the span's rule, its depth, its target, the plot on the
-- target layer and the plot on the lower layer (read only when a
-- translucent or rejected plot on the top layer lands on an edge pixel; the
-- first plot then changed only the top layer, so the lower layer it sees is
-- the pixel's own).
pixelCommit :: Bool -> Word32 -> Piece -> SpanRule -> Int32 -> (Bool, Word32)
            -> Maybe PixelWrite -> Maybe PixelWrite -> Int32 -> Px -> (Px, Int32)
pixelCommit aaOn edge piece rule z (lower, dstattr) first second xcov px =
  case first of
    Just w | not (testBit (pwAttr w) 22) -> opaque w
    _ ->
      let px1 = maybe px (\w -> put lower w px) first
          px2
            | dstattr .&. 0xF /= 0 && not lower = maybe px1 (\w -> put True w px1) second
            | otherwise = px1
      in (px2, xcov)
  where
    put low (PixelWrite c a d) q
      | low = q { pxLC = c, pxLA = a, pxLD = if d then fromIntegral z else pxLD q }
      | otherwise = q { pxC = c, pxA = a, pxD = if d then fromIntegral z else pxD q }
    aa = aaOn && edge .&. 0xF /= 0
    opaque w =
      let (cov, xcov') = case piece of
            PLeft
              | srLCov rule < 0 -> (min 31 (xcov `shiftR` 5), xcov + (srLCov rule .&. 0x3FF))
              | otherwise -> (srLCov rule, xcov)
            PRight
              | srRCov rule < 0 -> (max 0 (0x1F - (xcov `shiftR` 5)), xcov + (srRCov rule .&. 0x3FF))
              | otherwise -> (srRCov rule, xcov)
            PInner -> (0x1F, xcov)
          attr = pwAttr w .|. (if aa then fromIntegral cov `shiftL` 8 else 0)
          pushed
            | aa && not lower = px { pxLC = pxC px, pxLD = pxD px, pxLA = pxA px }
            | otherwise = px
      in (put lower (PixelWrite (pwColour w) attr True) pushed, if aa then xcov' else xcov)

-- | One pixel of @RenderShadowMaskScanline@: the stencil entry becomes 1
-- where the top layer fails the mask's depth test, and gains bit 1 where the
-- top is an edge pixel and the lower layer fails it.
maskPixel :: RPoly -> SpanSetup -> Int32 -> Px -> Word8 -> Word8
maskPixel rp sp x px st =
  maskPixelWith (rpMode rp) (uncurry interpolateZ (spZ sp) (setX x (spInterp sp))) px st

-- | 'maskPixel' at a given depth.
maskPixelWith :: DepthMode -> Int32 -> Px -> Word8 -> Word8
maskPixelWith mode z px st =
  let test d a = depthPass mode (a .&. 0x400010 == 0x10) (fromIntegral d) z
      st1 = if test (pxD px) (pxA px) then st else 1
  in if pxA px .&. 0xF /= 0 && not (test (pxLD px) (pxLA px)) then st1 .|. 2 else st1

------------------------------------------------------------------------------
-- Clear, final pass and output

-- | One line of the top layer as @ClearBuffers@ leaves it: the CLEAR_COLOR
-- colour, fog bit and depth, or with DISP3DCNT bit 14 the rear-plane image
-- from texture slots 2 (colour, bit 15 opaque) and 3 (depth, bit 15 fog),
-- scrolled by CLEAR_DEPTH bits 16-23 (X) and 24-31 (Y), wrapping at 256.
-- Both carry CLEAR_COLOR's opaque polygon ID.
clearLine :: RenderRegs -> TexMem -> Int32 -> (UArray Int Word32, UArray Int Word32, UArray Int Word32)
clearLine regs mem y
  | testBit (rrDispCnt regs) 14 =
      let px x =
            let off = clearImageOffset c2 y x
            in clearImagePixel c1 (tmTexHalf mem (0x40000 + off)) (tmTexHalf mem (0x60000 + off))
          pxs = map px [0 .. 255]
      in (line [ c | (c, _, _) <- pxs ], line [ d | (_, d, _) <- pxs ], line [ a | (_, _, a) <- pxs ])
  | otherwise =
      let (c, d, a) = clearColourPixel c1 c2
      in (line (replicate 256 c), line (replicate 256 d), line (replicate 256 a))
  where
    c1 = rrClearAttr1 regs
    c2 = rrClearAttr2 regs
    line = listArray (0, 255)

-- | The plain clear pixel (colour, depth, attribute) from CLEAR_COLOR and
-- CLEAR_DEPTH.
clearColourPixel :: Word32 -> Word32 -> (Word32, Word32, Word32)
clearColourPixel c1 c2 =
  ( packColour (expand555 (fromIntegral c1)) (fromIntegral ((c1 `shiftR` 16) .&. 0x1F))
  , ((c2 .&. 0x7FFF) * 0x200) + 0x1FF
  , (c1 .&. 0x3F000000) .|. (c1 .&. 0x8000) )

-- | The byte offset of pixel @x@ of line @y@ in rear-plane slots 2 and 3.
clearImageOffset :: Word32 -> Int32 -> Word32 -> Word32
clearImageOffset c2 y x =
  let yoff = ((c2 `shiftR` 24) + fromIntegral y) .&. 0xFF
      xoff = ((c2 `shiftR` 16) + x) .&. 0xFF
  in (yoff `shiftL` 9) + (xoff `shiftL` 1)

-- | The rear-plane clear pixel from its slot 2 and slot 3 halfwords.
clearImagePixel :: Word32 -> Word16 -> Word16 -> (Word32, Word32, Word32)
clearImagePixel c1 v2 v3 =
  ( packColour (expand555 v2) 0 .|. (if testBit v2 15 then 0x1F000000 else 0)
  , (fromIntegral v3 .&. 0x7FFF) * 0x200 + 0x1FF
  , (c1 .&. 0x3F000000) .|. (fromIntegral v3 .&. 0x8000) )

-- | A neighbour as edge marking sees it: opaque polygon ID and depth.
data Nbr = Nbr
  { nbId    :: !Word32
  , nbDepth :: !Word32
  } deriving (Eq, Show, Generic, NFDataX)

-- | @ScanlineFinalPass@ for one line, given the rendered lines above and
-- below ('Nothing' past the screen edge, where @ClearBuffers@ put a border
-- of CLEAR_COLOR's polygon ID at the clear depth; the border also flanks
-- every line left and right).
finalPass :: RenderRegs -> Maybe LineBuf -> Maybe LineBuf -> LineBuf -> LineBuf
finalPass regs above below lb =
  let border = Nbr (rrClearAttr1 regs `shiftR` 24 .&. 0x3F) (((rrClearAttr2 regs .&. 0x7FFF) * 0x200) + 0x1FF)
      nbrOf l x = Nbr (lbAttr l ! x `shiftR` 24) (lbDepth l ! x)
      vert ml x = maybe border (`nbrOf` x) ml
      horiz x
        | x < 0 || x > 255 = border
        | otherwise = nbrOf lb x
      out = [ finalPixel regs (horiz (x - 1)) (horiz (x + 1)) (vert above x) (vert below x)
                (Px (lbColour lb ! x) (lbDepth lb ! x) (lbAttr lb ! x)
                    (lbLColour lb ! x) (lbLDepth lb ! x) (lbLAttr lb ! x))
            | x <- [0 .. 255] ]
      line f = listArray (0, 255) (map f out)
  in LineBuf (line pxC) (line pxD) (line pxA) (line pxLC) (line pxLD) (line pxLA)

-- | The final pass at one pixel, given its left, right, upper and lower
-- neighbours: edge marking, then fog, then the anti-aliasing blend.
--
-- * Edge marking (DISP3DCNT bit 5) recolours a top-layer edge pixel from the
--   edge table when a neighbour has another polygon ID and a greater depth,
--   and sets its coverage to 0x10.
-- * Fog (bit 7) blends the fog colour (or with bit 6 only the fog alpha)
--   into a top pixel with the fog flag, and into the lower pixel under a
--   top edge pixel when the lower one has the flag.
-- * Anti-aliasing (bit 4) blends a top edge pixel with the lower one by its
--   coverage; coverage 0 takes the lower pixel, 31 keeps the top.
finalPixel :: RenderRegs -> Nbr -> Nbr -> Nbr -> Nbr -> Px -> Px
finalPixel regs =
  finalPixelWith (rrDispCnt regs) (rrFogColor regs)
    (\i -> rrEdgeTable regs !! fromIntegral i) (fogDensity regs)

-- | 'finalPixel' given DISP3DCNT, the fog colour, the edge table (indexed by
-- polygon ID >> 3) and the fog density function.
finalPixelWith :: Word32 -> Word32 -> (Word32 -> Word16) -> (Word32 -> Word32)
               -> Nbr -> Nbr -> Nbr -> Nbr -> Px -> Px
finalPixelWith disp fc edgeColour density l r u d px0 = antiAlias (fog (edgeMark px0))
  where
    edgeMark px
      | testBit disp 5 && pxA px .&. 0xF /= 0 && (hit l || hit r || hit u || hit d) =
          let (er, eg, eb) = expand555 (edgeColour (pid `shiftR` 3))
          in px { pxC = packColour (er, eg, eb) 0 .|. (pxC px .&. 0xFF000000)
                , pxA = (pxA px .&. 0xFFFFE0FF) .|. 0x1000 }
      | otherwise = px
      where
        pid = pxA px `shiftR` 24
        hit nb = pid /= nbId nb && pxD px < nbDepth nb
    fog px
      | testBit disp 7 =
          let top = if testBit (pxA px) 15 then fogBlend (pxD px) (pxC px) else pxC px
              low
                | pxA px .&. 0xF /= 0 && testBit (pxLA px) 15 = fogBlend (pxLD px) (pxLC px)
                | otherwise = pxLC px
          in px { pxC = top, pxLC = low }
      | otherwise = px
    fogColour = not (testBit disp 6)
    (fogR, fogG, fogB) = expand555 (fromIntegral fc)
    fogA = (fc `shiftR` 16) .&. 0x1F
    fogBlend depth c =
      let dens = density depth
          mix f s = (f * dens + s * (128 - dens)) `shiftR` 7
          ch sh = (c `shiftR` sh) .&. 0x3F
          (r', g', b')
            | fogColour = (mix (fromIntegral fogR) (ch 0), mix (fromIntegral fogG) (ch 8), mix (fromIntegral fogB) (ch 16))
            | otherwise = (ch 0, ch 8, ch 16)
          a' = mix fogA ((c `shiftR` 24) .&. 0x1F)
      in r' .|. (g' `shiftL` 8) .|. (b' `shiftL` 16) .|. (a' `shiftL` 24)
    antiAlias px
      | not (testBit disp 4) || pxA px .&. 0xF == 0 = px
      | cov == 0x1F = px
      | cov == 0 = px { pxC = pxLC px }
      | otherwise =
          let c1 = cov + 1
              ic = 32 - c1
              ch w sh = (w `shiftR` sh) .&. 0x3F
              botA = (pxLC px `shiftR` 24) .&. 0x1F
              topA = (pxC px `shiftR` 24) .&. 0x1F
              mix sh
                | botA > 0 = (ch (pxC px) sh * c1 + ch (pxLC px) sh * ic) `shiftR` 5
                | otherwise = ch (pxC px) sh
              a = (topA * c1 + botA * ic) `shiftR` 5
          in px { pxC = mix 0 .|. (mix 8 `shiftL` 8) .|. (mix 16 `shiftL` 16) .|. (a `shiftL` 24) }
      where
        cov = (pxA px `shiftR` 8) .&. 0x1F

-- | @CalculateFogDensity@: the fog table interpolated at a depth. The
-- offset depth is shifted right 2 then left by the fog shift (wrapping in
-- 32 bits), giving a 17-bit fraction and the table index; past entry 32 the
-- last entry holds. A density of 127 or more is 128.
fogDensity :: RenderRegs -> Word32 -> Word32
fogDensity regs =
  let tab = listArray (0, 33) (map fromIntegral (take 34 (rrFogDensity regs ++ repeat 0))) :: UArray Int Word32
  in fogDensityWith (rrFogOffset regs) (rrFogShift regs) (\i -> tab ! fromIntegral i)

-- | 'fogDensity' given the fog offset, the fog shift and the density table
-- (entries 0..33).
fogDensityWith :: Word32 -> Word32 -> (Word32 -> Word32) -> Word32 -> Word32
fogDensityWith off shift tab z =
  let (idx, frac)
        | z < off = (0, 0)
        | otherwise =
            let z' = ((z - off) `shiftR` 2) `shiftL` fromIntegral shift
                k = z' `shiftR` 17
            in if k >= 32 then (32, 0) else (k, z' .&. 0x1FFFF)
      density = (tab idx * (0x20000 - frac) + tab (idx + 1) * frac) `shiftR` 17
  in if density >= 127 then 128 else density

-- | @GetLine@: one line of the top colour layer, scrolled by @RenderXPos@.
-- Positions 1..255 shift the line left, filling zeros on the right; with
-- bit 8 set (256..511, a negative scroll) the line moves right by
-- @512 - xpos@, filling zeros on the left.
outputLine :: Word16 -> UArray Int Word32 -> [Word32]
outputLine xpos row = [ maybe 0 (row !) (outputSource xpos j) | j <- [0 .. 255] ]

-- | The line position output position @j@ of @GetLine@ shows, or 'Nothing'
-- for a filled zero.
outputSource :: Word16 -> Int -> Maybe Int
outputSource xpos j
  | testBit xpos 8 =
      let zs = min 256 (max 0 (512 - fromIntegral xpos))
      in if j < zs then Nothing else Just (j - zs)
  | otherwise =
      let k = max 0 (256 - fromIntegral xpos)
      in if j < k then Just (j + fromIntegral xpos) else Nothing
