-- | @BOX_TEST@, exactly as melonDS's @GPU3D::BoxTest@: the eight corners of
-- the box are transformed by the clip matrix and each of the six faces is
-- clipped with @ClipPolygon<false>@; the test passes when any face keeps at
-- least one vertex.
--
-- @ClipPolygon<false>@ differs from the polygon pipeline's
-- @ClipPolygon<true>@ only in not interpolating colour and texture
-- coordinates, which never affect positions or the vertex count, so the box
-- test runs the polygon block's clipper ('Nds.Gpu3D.Polygon.Clip') on
-- position-only vertices (@clipstart = 0@, the latched polygon attribute for
-- the far-plane rule).
module Nds.Gpu3D.Geometry.BoxTest
  ( boxCorners
  , boxFaces
  , boxTest
  ) where

import Data.Array (listArray, (!))
import Data.Bits (shiftR)
import Data.Int (Int16, Int32)
import qualified Data.Sequence as Seq
import Data.Word (Word32)

import Nds.Gpu3D.Geometry.Matrix (Mat, transformPoint)
import Nds.Gpu3D.Polygon.Clip (Vtx (..), clipPolygon, maxClipVertices, zeroVtx)

-- | The corner positions of a box test (before the transform): the three
-- parameter words hold @x0 y0 z0 w h d@ as signed halfwords and the far
-- corner is @(x0 + w, y0 + h, z0 + d)@ in 16-bit arithmetic. Corner order
-- is melonDS's @cube[0..7]@.
boxCorners :: Word32 -> Word32 -> Word32 -> [(Int32, Int32, Int32)]
boxCorners p0 p1 p2 =
  let lo, hi :: Word32 -> Int16
      lo = fromIntegral
      hi p = fromIntegral (p `shiftR` 16)
      x0 = lo p0; y0 = hi p0; z0 = lo p1
      x1 = hi p1 + x0; y1 = lo p2 + y0; z1 = hi p2 + z0
      c x y z = (fromIntegral x, fromIntegral y, fromIntegral z)
  in [ c x0 y0 z0, c x1 y0 z0, c x1 y1 z0, c x0 y1 z0
     , c x0 y1 z1, c x0 y0 z1, c x1 y0 z1, c x1 y1 z1 ]

-- | The faces in melonDS's test order (front, back, left, right, bottom,
-- top) as corner indices.
boxFaces :: [[Int]]
boxFaces =
  [ [0, 1, 2, 3], [4, 5, 6, 7], [0, 3, 4, 5]
  , [1, 2, 7, 6], [0, 1, 6, 5], [2, 3, 4, 7] ]

-- | The box-test result for a clip matrix, the polygon attribute latched by
-- @BEGIN_VTXS@ (bit 12 keeps far-plane-crossing faces) and the three
-- parameter words. 8 vertex transforms (96 multiply-accumulates plus 32
-- @0x1000@ terms), then up to six four-vertex face clips.
boxTest :: Mat -> Word32 -> Word32 -> Word32 -> Word32 -> Bool
boxTest clip attr p0 p1 p2 =
  let corner (x, y, z) =
        let (cx, cy, cz, cw) = transformPoint clip x y z
        in zeroVtx { vX = cx, vY = cy, vZ = cz, vW = cw }
      corners = listArray (0, 7) (map corner (boxCorners p0 p1 p2))
      face f = Seq.fromList (map (corners !) f ++ replicate (maxClipVertices - 4) zeroVtx)
      kept f = let (_, n, _) = clipPolygon attr 0 (face f) 4 in n
  in any (\f -> kept f > 0) boxFaces
