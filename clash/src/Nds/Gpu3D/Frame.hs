{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- | Pure depth-tested frame model for the flat opaque path.
--
-- Triangles are submitted in order, rasterised with 'rasterTriFinalDepth', and
-- tested against a 256x192 depth buffer. 'renderFrameBuffer' returns the
-- written pixels with their final depth and colour; untouched pixels keep the
-- clear depth and no colour.
module Nds.Gpu3D.Frame
  ( renderFrame
  , renderFrameWith
  , renderFrameBuffer
  ) where

import Data.Int (Int32)
import Data.List (foldl')

import qualified Data.Map.Strict as M

import Clash.Prelude (Vec (..))

import Nds.Gpu3D.Depth (DepthMode (..), clearDepth, depthPass)
import Nds.Gpu3D.Flat (TriIn (..), flatCfg)
import Nds.Gpu3D.Raster (Tri, mkTri, rasterTriFinalDepth, triYTop)

-- | Render a list of triangles and return the surviving colour pixels.
renderFrame :: [TriIn] -> [(Int32, Int32, Int32)]
renderFrame = renderFrameWith 0x7FFF

-- | Render with an explicit @RenderClearAttr2@ value.
renderFrameWith :: Int32 -> [TriIn] -> [(Int32, Int32, Int32)]
renderFrameWith clearAttr tris =
  [ (x, y, col) | ((x, y), (_, col)) <- M.toList (renderFrameBuffer clearAttr tris) ]

-- | Written pixels keyed by @(x, y)@, holding @(depth, colour)@.
renderFrameBuffer :: Int32 -> [TriIn] -> M.Map (Int32, Int32) (Int32, Int32)
renderFrameBuffer clearAttr tris =
  M.map (\(z, _, c) -> (z, c)) (foldl' draw M.empty tris)
  where
    -- Cleared pixels carry no back-facing attribute.
    clear = (clearDepth (fromIntegral clearAttr), False)
    draw buf ti =
      let tri = mkTriFor ti
          rows = rasterTriFinalDepth flatCfg tri
          y0 = max 0 (triYTop tri)
          front = tiFacing ti
          mode = if front then DepthLessFront else DepthLess
          step b (y, row) = foldl' (pixel y) b row
          pixel y b (x, z) =
            let key = (x, y)
                (dst, dstBack) = maybe clear (\(d, bk, _) -> (d, bk)) (M.lookup key b)
            in if depthPass mode dstBack dst z
                 then M.insert key (z, not front, tiColor ti) b
                 else b
      in foldl' step buf (zip [y0 ..] rows)

mkTriFor :: TriIn -> Tri
mkTriFor ti = mkTri (tiFacing ti) (tiV0 ti :> tiV1 ti :> tiV2 ti :> Nil)
