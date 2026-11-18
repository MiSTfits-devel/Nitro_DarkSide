-- | The geometry engine's matrix arithmetic, exactly as melonDS's
-- @MatrixLoad*@, @MatrixMult*@, @MatrixScale@, @MatrixTranslate@ and the
-- 4-element vertex transform (@NDS4MiSTerGXTransformVertex4@, @PosTest@ and
-- @BoxTest@ all spell the same sum).
--
-- Every product is a signed 64-bit product of signed 32-bit operands, summed
-- in 64 bits (wrapping, as the C++ does in practice), shifted right
-- arithmetically by 12 and truncated to 32 bits. Matrices are row-major
-- 4x4, element @r * 4 + c@, and every multiply computes @m = s * m@: the
-- command's matrix on the left, the current matrix on the right.
module Nds.Gpu3D.Geometry.Matrix
  ( Mat
  , mat
  , matElems
  , (!.)
  , identity
  , zeroMat
  , load4x4
  , load4x3
  , mult4x4
  , mult4x3
  , mult3x3
  , scale
  , translate
  , clipOf
  , dot64
  , transformPoint
  ) where

import Data.Array.Unboxed (UArray, elems, listArray, (!))
import Data.Bits (shiftR)
import Data.Int (Int32, Int64)
import Data.Word (Word32)

-- | A 4x4 matrix of 20.12 fixed-point entries, row-major.
type Mat = UArray Int Int32

-- | Build a matrix from its 16 elements in row-major order.
mat :: [Int32] -> Mat
mat = listArray (0, 15)

-- | The 16 elements in row-major order.
matElems :: Mat -> [Int32]
matElems = elems

-- | Element @i@ (@r * 4 + c@).
(!.) :: Mat -> Int -> Int32
(!.) = (!)
infixl 9 !.

-- | @MatrixLoadIdentity@.
identity :: Mat
identity = mat [ 0x1000, 0, 0, 0
               , 0, 0x1000, 0, 0
               , 0, 0, 0x1000, 0
               , 0, 0, 0, 0x1000 ]

-- | The power-on contents of every matrix stack slot.
zeroMat :: Mat
zeroMat = mat (replicate 16 0)

s32 :: Word32 -> Int32
s32 = fromIntegral

-- | @(sum of s64 products) >> 12@ truncated to s32: one multiply-accumulate
-- chain of the shared datapath.
dot64 :: [(Int32, Int32)] -> Int32
dot64 terms =
  fromIntegral (sum [fromIntegral a * fromIntegral b :: Int64 | (a, b) <- terms] `shiftR` 12)

-- | @MatrixLoad4x4@: the 16 parameter words as they are.
load4x4 :: [Word32] -> Mat
load4x4 ps = mat (map s32 (take 16 ps))

-- | @MatrixLoad4x3@: 12 parameter words, the fourth column completed with
-- @(0, 0, 0, 0x1000)@.
load4x3 :: [Word32] -> Mat
load4x3 ps =
  let s i = s32 (ps !! i)
  in mat [ s 0, s 1, s 2, 0
         , s 3, s 4, s 5, 0
         , s 6, s 7, s 8, 0
         , s 9, s 10, s 11, 0x1000 ]

-- | @MatrixMult4x4(m, s)@: @m = s * m@ with @s@ the 16 parameter words.
-- 64 multiply-accumulates.
mult4x4 :: [Word32] -> Mat -> Mat
mult4x4 ps m =
  let s i = s32 (ps !! i)
  in mat [ dot64 [(s (r * 4 + k), m !. (k * 4 + c)) | k <- [0 .. 3]]
         | r <- [0 .. 3], c <- [0 .. 3] ]

-- | @MatrixMult4x3(m, s)@: @s@ is 12 words, a 4x4 with fourth column
-- @(0, 0, 0, 0x1000)@. 48 multiply-accumulates plus four @0x1000 * m@
-- terms (a shift).
mult4x3 :: [Word32] -> Mat -> Mat
mult4x3 ps m =
  let s i = s32 (ps !! i)
      row r c
        | r < 3 = dot64 [(s (r * 3 + k), m !. (k * 4 + c)) | k <- [0 .. 2]]
        | otherwise = dot64 ([(s (9 + k), m !. (k * 4 + c)) | k <- [0 .. 2]]
                             ++ [(0x1000, m !. (12 + c))])
  in mat [row r c | r <- [0 .. 3], c <- [0 .. 3]]

-- | @MatrixMult3x3(m, s)@: rows 0-2 become @s * m@ over the upper 3x4 of
-- @m@; row 3 is untouched. 36 multiply-accumulates.
mult3x3 :: [Word32] -> Mat -> Mat
mult3x3 ps m =
  let s i = s32 (ps !! i)
      el r c
        | r < 3 = dot64 [(s (r * 3 + k), m !. (k * 4 + c)) | k <- [0 .. 2]]
        | otherwise = m !. (r * 4 + c)
  in mat [el r c | r <- [0 .. 3], c <- [0 .. 3]]

-- | @MatrixScale(m, s)@: row @r < 3@ times @s[r]@; row 3 untouched.
-- 12 multiplies.
scale :: [Word32] -> Mat -> Mat
scale ps m =
  let s i = s32 (ps !! i)
      el r c
        | r < 3 = dot64 [(s r, m !. (r * 4 + c))]
        | otherwise = m !. (r * 4 + c)
  in mat [el r c | r <- [0 .. 3], c <- [0 .. 3]]

-- | @MatrixTranslate(m, s)@: @m[12 + c] += (s[0] m[c] + s[1] m[4 + c] +
-- s[2] m[8 + c]) >> 12@, wrapping to 32 bits. 12 multiply-accumulates.
translate :: [Word32] -> Mat -> Mat
translate ps m =
  let s i = s32 (ps !! i)
      el r c
        | r < 3 = m !. (r * 4 + c)
        | otherwise = m !. (12 + c) + dot64 [(s k, m !. (k * 4 + c)) | k <- [0 .. 2]]
  in mat [el r c | r <- [0 .. 3], c <- [0 .. 3]]

-- | @UpdateClipMatrix@'s product: @ClipMatrix = ProjMatrix@ then
-- @MatrixMult4x4(ClipMatrix, PosMatrix)@, i.e. @Pos * Proj@.
clipOf :: Mat -> Mat -> Mat
clipOf proj pos =
  mat [ dot64 [(pos !. (r * 4 + k), proj !. (k * 4 + c)) | k <- [0 .. 3]]
      | r <- [0 .. 3], c <- [0 .. 3] ]

-- | @(x, y, z, 0x1000) * m@: the vertex transform of @SubmitVertex@, the
-- position test and the box-test corners. 12 multiply-accumulates plus four
-- @0x1000 * m@ terms.
transformPoint :: Mat -> Int32 -> Int32 -> Int32 -> (Int32, Int32, Int32, Int32)
transformPoint m x y z =
  let col c = dot64 [(x, m !. c), (y, m !. (4 + c)), (z, m !. (8 + c)), (0x1000, m !. (12 + c))]
  in (col 0, col 1, col 2, col 3)
