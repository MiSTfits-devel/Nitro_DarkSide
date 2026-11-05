{-# LANGUAGE DataKinds #-}

-- | Functional gate for the streaming depth engine.
--
-- Runs the same 'depthStep' used by the Clash top against a behavioural depth
-- memory with variable read latency and output stalls, then compares the surviving
-- pixels with 'Nds.Gpu3D.Frame.renderFrame'. Also runs the flat rasteriser in
-- front of the depth engine so span facing and span depth are checked together.
module Main (main) where

import Data.Bits (shiftR, (.|.))
import Data.Int (Int32)
import Data.List (sort)
import Data.Word (Word64)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import System.Environment (getArgs)
import System.Exit (exitFailure)

import Nds.Gpu3D.Depth (DepthMode (..), clearDepth, depthPass)
import Nds.Gpu3D.DepthPipe
import Nds.Gpu3D.Flat
import Nds.Gpu3D.Frame (renderFrame)
import Nds.Gpu3D.Raster (SpanZ (..), Vertex (..), spanDepths)

-- Behavioural depth memory ---------------------------------------------------

data Mem = Mem
  { memCells :: M.Map Int32 Int32
  , memQueue :: [(Int, Int32)]
  , memCycle :: Int
  }

-- | Power-on contents. Zero passes no depth test, so a missed clear write
-- shows up as a missing pixel.
garbage :: Int32
garbage = 0

memEmpty :: Mem
memEmpty = Mem M.empty [] 0

memStep :: Int -> Mem -> MemOp -> (Mem, Maybe Int32)
memStep lat (Mem cells queue n) op =
  let resp = case lookup n queue of
        Just a -> Just (M.findWithDefault garbage a cells)
        Nothing -> Nothing
      cells' = case op of
        MemWrite a d -> M.insert a d cells
        _ -> cells
      queue' = case op of
        MemRead a -> filter ((> n) . fst) (queue ++ [(n + lat, a)])
        _ -> filter ((> n) . fst) queue
  in (Mem cells' queue' (n + 1), resp)

-- Reference -----------------------------------------------------------------

-- | Final buffer after every span, keyed @(y, x)@: depth, back-facing, colour.
depthReferenceBuf :: Int32 -> [Span] -> M.Map (Int32, Int32) (Int32, Bool, Int32)
depthReferenceBuf clear spans = foldl span1 M.empty spans
  where
    span1 m sp = foldl (pixel sp) m
      (zip [spanX0 sp .. spanX1 sp]
           (spanDepths (SpanZ (spanX0 sp) (spanX1 sp) (spanIX0 sp) (spanIX1 sp) (spanZ0 sp) (spanZ1 sp))))
    pixel sp m (x, z) =
      let key = (spanY sp, x)
          (dst, dstBack) = maybe (clear, False) (\(d, b, _) -> (d, b)) (M.lookup key m)
          front = spanFront sp
          mode = if front then DepthLessFront else DepthLess
      in if depthPass mode dstBack dst z
           then M.insert key (z, not front, spanColor sp) m
           else m

depthReference :: Int32 -> [Span] -> [(Int32, Int32, Int32)]
depthReference clear spans =
  [ (x, y, c) | ((y, x), (_, _, c)) <- M.toList (depthReferenceBuf clear spans) ]

-- | Every depth-buffer word the engine should leave behind: the clear value
-- where nothing was written, otherwise FinalZ with bit 24 for back faces.
expectedMemory :: Int32 -> [Span] -> [Int32]
expectedMemory clear spans =
  [ maybe clear (\(z, back, _) -> if back then z .|. 0x1000000 else z)
      (M.lookup (y, x) buf)
  | y <- [0 .. screenH - 1], x <- [0 .. screenW - 1] ]
  where buf = depthReferenceBuf clear spans

-- Runner --------------------------------------------------------------------

-- | Surviving framebuffer and the final contents of all 49,152 depth words.
runDepth :: Int -> Int32 -> [Span] -> ([(Int32, Int32, Int32)], [Int32])
runDepth lat clear spans = go fuel DIdle memEmpty MemNone spans True True []
  where
    pixels = sum [ spanX1 sp - spanX0 sp + 1 | sp <- spans ]
    fuel = 16 * (fromIntegral pixels + 49152 + 64) :: Int
    go 0 _ _ _ _ _ _ _ = error "depth gate: engine did not drain"
    go f st mem prevOp pending outReady clearing acc
      | not clearing && st == DIdle && null pending && prevOp == MemNone =
          ( framebuffer (reverse acc)
          , [ M.findWithDefault garbage a (memCells mem) | a <- [0 .. screenW * screenH - 1] ] )
      | otherwise =
          let (mem', resp) = memStep (1 + (f `mod` 3)) mem prevOp
              accept = st == DIdle && not clearing
              (inp, rest)
                | accept && not (null pending) = (Just (head pending), tail pending)
                | otherwise = (Nothing, pending)
              outReady' = f `mod` 5 /= 0
              din = DepthIn inp clearing clear True resp outReady'
              (st', out) = depthStep st din
              -- A pixel is consumed only on a cycle where the sink is ready.
              acc' = case doPixel out of
                       Just p | outReady' -> (poX p, poY p, poColor p) : acc
                       _ -> acc
          in go (f - 1) st' mem' (doMem out) rest outReady' False acc'

-- | Later accepted pixels overwrite earlier ones, as in the real colour buffer.
framebuffer :: [(Int32, Int32, Int32)] -> [(Int32, Int32, Int32)]
framebuffer ps =
  [ (x, y, c) | ((y, x), c) <- M.toList (M.fromList [ ((y, x), c) | (x, y, c) <- ps ]) ]

-- End-to-end ----------------------------------------------------------------

runTriangles :: Int -> [TriIn] -> ([(Int32, Int32, Int32)], [Int32])
runTriangles lat tris = runDepth lat (clearDepth 0x7FFF) (flatSpans tris)

referenceTriangles :: [TriIn] -> [(Int32, Int32, Int32)]
referenceTriangles = framebuffer . renderFrame

-- Generator ------------------------------------------------------------------

cycleG :: Word64 -> Word64
cycleG s = s * 726413722395729017 + 743269519089996359

drawCoord :: Word64 -> Int32 -> Int32 -> (Int32, Word64)
drawCoord s lo hi =
  let s' = cycleG s
      span' = fromIntegral (hi - lo + 1) :: Word64
      v = fromIntegral ((s' `shiftR` 23) `mod` span') + lo
  in (v, s')

mkInput :: Int32 -> Int32 -> Int32 -> Int32 -> Int32 -> Int32 -> Int32 -> Int32 -> Int32 -> Bool -> Int32 -> TriIn
mkInput x0 y0 z0 x1 y1 z1 x2 y2 z2 face col =
  TriIn (Vertex x0 y0 z0 0x4000 0 0 0)
        (Vertex x1 y1 z1 0x4000 0 0 0)
        (Vertex x2 y2 z2 0x4000 0 0 0)
        face col

randomTri :: Word64 -> (TriIn, Word64)
randomTri s0 =
  -- Post-clip viewport: the geometry engine clips before rasterising.
  let (x0, s1) = drawCoord s0 0 screenW
      (y0, s2) = drawCoord s1 0 screenH
      (z0, s3) = drawCoord s2 20 0xFFFFFF
      (x1, s4) = drawCoord s3 0 screenW
      (y1, s5) = drawCoord s4 0 screenH
      (z1, s6) = drawCoord s5 50 0xFFFFFF
      (x2, s7) = drawCoord s6 0 screenW
      (y2, s8) = drawCoord s7 0 screenH
      (z2, s9) = drawCoord s8 60 0xFFFFFF
      (faceW, s10) = drawCoord s9 83 99
      (col, s11) = drawCoord s10 1 0x7FFF
      -- One triangle in four is flat at a shared depth so Z ties actually occur
      -- and the front/back comparators are distinguished.
      (tie, s12) = drawCoord s11 0 3
      flatZ = if tie == 0 then 0x400000 else z0
      (z1', z2') = if tie == 0 then (flatZ, flatZ) else (z1, z2)
  in (mkInput x0 y0 flatZ x1 y1 z1' x2 y2 z2' (odd faceW) col, s12)

directed :: [TriIn]
directed =
  [ mkInput 11 12 13 22 42 53 52 62 73 True 1
  , mkInput 41 82 93 72 92 91 51 81 70 False 2
  , mkInput 15 35 45 65 69 79 49 59 39 True 3
  , mkInput 29 90 37 58 86 47 76 56 87 False 4
  -- A right edge that starts on X 256: raw span end 257, the table's last entry.
  , mkInput 200 100 0x100000 256 110 0xE00000 256 135 0x500000 True 5
  , mkInput 150 60 0x100000 256 80 0xE00000 150 100 0x500000 False 6
  , mkInput 0 140 0x100000 256 150 0xE00000 0 190 0x500000 True 7
  ]

-- | Overlapping constant-depth pairs: front-facing keeps the first writer
-- (strict less), back-facing lets the second through (less-or-equal).
-- | Row 182 of this triangle has raw interpolator interval [0, 257), the
-- reciprocal table's last entry.
border :: [TriIn]
border = [ mkInput 0 183 0x200000 256 192 0xC00000 256 0 0x600000 False 8 ]

equalZ :: [TriIn]
equalZ =
  [ mkInput 10 10 z 60 10 z 35 60 z True 0x11
  , mkInput 10 10 z 60 10 z 35 60 z True 0x12
  , mkInput 100 10 z 150 10 z 125 60 z False 0x21
  , mkInput 100 10 z 150 10 z 125 60 z False 0x22
  , mkInput 190 10 z 240 10 z 215 60 z False 0x31
  , mkInput 190 10 z 240 10 z 215 60 z True 0x32
  ]
  where z = 0x400000

-- Checks --------------------------------------------------------------------

check :: String -> [(Int32, Int32, Int32)] -> [(Int32, Int32, Int32)] -> Either String ()
check name expected actual
  | expected == actual = Right ()
  | otherwise = Left (name ++ ": expected " ++ show (length expected)
      ++ ", got " ++ show (length actual)
      ++ ", missing " ++ show (take 8 (S.toList (S.difference e a)))
      ++ ", extra " ++ show (take 8 (S.toList (S.difference a e))))
  where
    e = S.fromList expected
    a = S.fromList actual

-- | The engine's reciprocal table covers span lengths 1..257; every span the
-- gate feeds must be inside that domain, or the comparison proves nothing.
checkDomain :: [Span] -> Either String ()
checkDomain spans =
  case [ sp | sp <- spans, let d = spanIX1 sp - spanIX0 sp, d < 1 || d > 257 ] of
    [] -> Right ()
    bad -> Left ("span length outside 1..257: " ++ show (take 3 bad))

-- | Compare the 49,152 final depth words, reporting the first few differences.
checkMemory :: String -> [Int32] -> [Int32] -> Either String ()
checkMemory name expected actual =
  case [ (a `divMod` screenW, e, g) | (a, e, g) <- zip3 [0 :: Int32 ..] expected actual, e /= g ] of
    [] -> Right ()
    bad -> Left (name ++ ": " ++ show (length bad) ++ " depth words differ ((y, x), want, got): "
                 ++ show (take 6 bad))

checkSpans :: Int -> Int32 -> [Span] -> Either String ()
checkSpans lat clearAttr spans =
  let clear = clearDepth (fromIntegral clearAttr)
      name = "spans/" ++ show (length spans)
      (fb, mem) = runDepth lat clear spans
  in checkDomain spans
       >> check name (depthReference clear spans) fb
       >> checkMemory name (expectedMemory clear spans) mem

checkTris :: Int -> [TriIn] -> Either String ()
checkTris lat tris =
  let spans = flatSpans tris
      clear = clearDepth 0x7FFF
      name = "tris/" ++ show (length tris)
      (fb, mem) = runTriangles lat tris
  in checkDomain spans
       >> check name (referenceTriangles tris) fb
       >> checkMemory name (expectedMemory clear spans) mem

main :: IO ()
main = do
  args <- getArgs
  let cases = case args of
        (n:_) -> read n
        _ -> 400
      gen0 = 67319
      build 0 s acc = (s, acc)
      build k s acc = let (t, s') = randomTri s in build (k - 1) s' (t : acc)
      (_, trisRev) = build cases gen0 []
      tris = reverse trisRev
      failures = concat
        [ [e | Left e <- [checkTris 2 tris, checkTris 4 tris]]
        , [e | Left e <- map (checkSpans 2 0x7FFF) [flatSpans tris]]
        , [e | Left e <- map (checkSpans 3 0x7FFF) [flatSpans tris]]
        , [e | Left e <- map (checkSpans 4 0x7FFF) [flatSpans tris]]
        , [e | Left e <- map (checkSpans 5 0x7FFF) [flatSpans tris]]
        , [e | Left e <- [checkSpans 2 0x7FFF (flatSpans directed)]]
        , [e | Left e <- [checkSpans 3 0x7FFF (flatSpans equalZ)]]
        , [e | Left e <- [checkTris 2 equalZ, checkTris 3 directed, checkTris 2 border]]
        , [e | Left e <- [checkSpans 3 0x7FFF (flatSpans border)]]
        ]
  if null failures
    then putStrLn ("depth-pipe-check: " ++ show cases ++ " triangles, "
      ++ show (length (fst (runTriangles 2 tris))) ++ " pixels and 49152 depth words, 0 failures")
    else mapM_ putStrLn failures >> exitFailure
