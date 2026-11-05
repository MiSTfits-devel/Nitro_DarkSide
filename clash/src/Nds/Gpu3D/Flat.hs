{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Streaming flat-opaque triangle feeder.
--
-- Consumes one triangle at a time and emits the covered screen spans, one span per
-- cycle, in ascending scanline order. The arithmetic is the validated
-- 'Nds.Gpu3D.Raster' model; this module only adds the handshake and the
-- per-row sequencer.
module Nds.Gpu3D.Flat
  ( TriIn (..)
  , Span (..)
  , flatCfg
  , screenW
  , screenH
  , flatRaster
  , flatSpans
  , topEntity
  ) where

import Data.Int (Int32)
import Prelude hiding ((&&), (||))

import Clash.Prelude hiding (head, tail, not, reverse, iterate, length, null, map, zip, concat, concatMap, filter, foldl, foldr, sum, and, or, any, all, elem, lookup, take, drop, splitAt, replicate, cycle, repeat, (!!))
import qualified Clash.Explicit.Mealy as EM

import Nds.Gpu3D.Raster

screenW, screenH :: Int32
screenW = 256
screenH = 192

-- | A triangle submission: three vertices, winding, and a constant colour.
data TriIn = TriIn
  { tiV0     :: !Vertex
  , tiV1     :: !Vertex
  , tiV2     :: !Vertex
  , tiFacing :: !Bool
  , tiColor  :: !Int32
  } deriving (Eq, Generic, Show, NFDataX)

-- | One inclusive horizontal span on one scanline.
data Span = Span
  { spanY     :: !Int32
  , spanX0    :: !Int32
  , spanX1    :: !Int32
  , spanIX0   :: !Int32  -- ^ depth interpolator start (raw edge X)
  , spanIX1   :: !Int32  -- ^ depth interpolator end (raw edge X + 1)
  , spanZ0    :: !Int32
  , spanZ1    :: !Int32
  , spanColor :: !Int32
  , spanFront :: !Bool
  } deriving (Eq, Generic, Show, NFDataX)

-- | Flat opaque configuration: force-opaque display bit, no antialiasing,
-- no wireframe.
flatCfg :: RasterConfig
flatCfg = RasterConfig 32 31 False 256

data RState
  = RIdle
  | RFetch Raster Int32 Int32 Int32
  | RRow Raster Int32 Int32 Int32 (Maybe Span)
  deriving (Eq, Generic, Show, NFDataX)

clipSpan :: Int32 -> Bool -> Int32 -> Int32 -> Int32 -> Int32 -> Int32 -> Int32 -> Int32 -> Maybe Span
clipSpan y front a b ix0 ix1 z0 z1 col
  | y < 0 = Nothing
  | y > screenH - 1 = Nothing
  | b < 0 = Nothing
  | a > screenW - 1 = Nothing
  | a > b = Nothing
  | otherwise = Just (Span y (max 0 a) (min (screenW - 1) b) ix0 ix1 z0 z1 col front)

horizontalSpan :: TriIn -> Tri -> Maybe Span
horizontalSpan ti tri =
  case horizontalSpanZ vertexZ tri of
    Nothing -> Nothing
    Just s -> clipSpan (triYTop tri) (tiFacing ti) (szX0 s) (szX1 s)
                (szIX0 s) (szIX1 s) (szZ0 s) (szZ1 s) (tiColor ti)

-- | One forced-fill span for a row. The configuration forces every polygon
-- opaque, so the reference's left/interior/right pieces are contiguous and the
-- union is exactly @max x0 0 .. min 255 b0@.
rowSpanWithDepth :: Bool -> Int32 -> Int32 -> Raster -> (Maybe Span, Raster)
rowSpanWithDepth front y col r0 =
  let (sp, r') = rowSpanDepthWith (\_ v -> vertexZ v) False y r0
  in case sp of
       Nothing -> (Nothing, r')
       Just s -> (clipSpan y front (szX0 s) (szX1 s) (szIX0 s) (szIX1 s)
                            (szZ0 s) (szZ1 s) col, r')

advanceRow :: Raster -> Int32 -> Int32 -> Int32 -> RState
advanceRow r y yb col
  | y >= yb = RIdle
  | otherwise = RFetch r y yb col

step :: RState -> (Maybe TriIn, Bool) -> (RState, (Bool, Maybe Span))
step st (inp, outReady) = case st of
  RIdle -> case inp of
    Nothing -> (RIdle, (True, Nothing))
    Just ti ->
      let tri = mkTri (tiFacing ti)
                  (tiV0 ti :> tiV1 ti :> tiV2 ti :> Nil)
          y = triYTop tri
          yb = triYBottom tri
          startY = max 0 y
          endY = min screenH yb
          r = setupRasterFrom tri startY
          col = tiColor ti
      in if y == yb
             then (RRow r y yb col (horizontalSpan ti tri), (False, Nothing))
             else if startY >= endY
               then (RIdle, (True, Nothing))
               else (RFetch r startY endY col, (False, Nothing))
  RFetch r y yb col ->
    let (sp, r') = rowSpanWithDepth (triFacing (rasTri r)) y col r
    in (RRow r' y yb col sp, (False, Nothing))
  RRow r y yb col sp ->
    case sp of
      Nothing -> (advanceRow r (y + 1) yb col, (False, Nothing))
      Just s ->
        if outReady
          then (advanceRow r (y + 1) yb col, (False, Just s))
          else (st, (False, Just s))

-- | Collect the spans for a list of triangles with no output back-pressure.
-- The cycle bound covers the longest admissible triangle plus drain.
flatSpans :: [TriIn] -> [Span]
flatSpans ts = reverse (forth ((iterate go start) !! bound))
  where
    bound = 8712 + 8632 * length ts
    start = (RIdle, ts, True, [])
    go (st, pending, ready, acc) =
      let (inp, rest)
            | ready && not (null pending) = (Just (head pending), tail pending)
            | otherwise = (Nothing, pending)
          (st', (inReady, msp)) = step st (inp, True)
          acc' = maybe acc (: acc) msp
      in (st', rest, inReady, acc')
    forth (_, _, _, acc) = acc

-- | Sequential flat rasteriser. The first output is @inReady@, high only in the
-- idle state. The second output carries a span; @Just@ is valid and the state
-- holds it until @outReady@.
flatRaster
  :: forall dom. KnownDomain dom
  => Clock dom -> Reset dom -> Enable dom
  -> Signal dom (Maybe TriIn, Bool)
  -> (Signal dom Bool, Signal dom (Maybe Span))
flatRaster clk rst en inp =
  let out = EM.mealy clk rst en step RIdle inp
  in (fmap fst out, fmap snd out)

-- | Concrete top entity for resource estimation and the eventual board wrapper.
topEntity
  :: Clock System -> Reset System -> Enable System
  -> Signal System (Maybe TriIn, Bool)
  -> (Signal System Bool, Signal System (Maybe Span))
topEntity = flatRaster
{-# NOINLINE topEntity #-}
