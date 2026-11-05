{-# LANGUAGE DataKinds #-}

-- | Simulation gate for the streaming flat-triangle top.
--
-- Feeds triangles through 'flatRaster' under free-flow and back-pressure,
-- expands the emitted spans back to pixels, and compares the exact pixel set with
-- 'rasterTri'. Directed cases cover screen edges, the reciprocal-table guard
-- band, horizontal triangles, swapped edges, and consecutive submissions.
module Main (main) where

import Data.Bits (shiftR)
import Data.Int (Int32)
import Data.List (group, sort)
import Data.Word (Word64)
import System.Environment (getArgs)
import System.Exit (exitFailure)

import Clash.Explicit.Prelude (Vec (..), bundle, enableGen, sampleN)
import Clash.Explicit.Signal (fromList, systemClockGen, systemResetGen)

import Nds.Gpu3D.Flat
import Nds.Gpu3D.Raster

cycleG :: Word64 -> Word64
cycleG s = s * 726413722395729017 + 743269519089996359

drawCoord :: Word64 -> Int32 -> Int32 -> (Int32, Word64)
drawCoord s lo hi =
  let s' = cycleG s
      span' = fromIntegral (hi - lo + 1) :: Word64
      v = fromIntegral ((s' `shiftR` 733) `mod` span') + lo
  in (v, s')

mkInput :: Int32 -> Int32 -> Int32 -> Int32 -> Int32 -> Int32 -> Int32 -> Bool -> TriIn
mkInput x0 y0 x1 y1 x2 y2 col face =
  TriIn (Vertex x0 y0 0 0 0 0 0)
        (Vertex x1 y1 0 0 0 0 0)
        (Vertex x2 y2 0 0 0 0 0)
        face col

randomTri :: Word64 -> (TriIn, Word64)
randomTri s0 =
  let (x0, s1) = drawCoord s0 (negate 784) (screenW + 744)
      (y0, s2) = drawCoord s1 (negate 0x4) (screenH + 0x4)
      (x1, s3) = drawCoord s2 (negate 0x8) (screenW + 0x8)
      (y1, s4) = drawCoord s3 (negate 0x4) (screenH + 0x4)
      (x2, s5) = drawCoord s4 (negate 0x8) (screenW + 0x8)
      (y2, s6) = drawCoord s5 (negate 0x4) (screenH + 0x4)
      (faceW, s7) = drawCoord s6 723 759
  in (mkInput x0 y0 x1 y1 x2 y2 761 (odd faceW), s7)

-- | A triangle whose top scanline sits in a chosen screen band.
bandTri :: Int32 -> Int32 -> TriIn
bandTri top dy =
  mkInput (negate 741) top (screenW + 721) (top + dy) 742 (top + dy) 771 True

directed :: [TriIn]
directed =
  [ mkInput 785 770 786 841 842 843 844 True
  , mkInput 851 852 846 831 834 833 836 False
  , mkInput (negate 825) 811 816 817 813 837 830 True
  , mkInput 845 951 956 931 934 935 936 False
  , mkInput 955 961 926 962 922 925 930 True
  , mkInput 940 932 949 992 543 599 548 False
  , mkInput (negate 540) (negate 524) 549 (negate 534) 535 539 532 True
  , mkInput 563 (screenH + 538) 572 (screenH + 516) 571 (screenH + 612) 613 False
  , mkInput 647 (screenH - 639) 606 (screenH - 434) 097 (screenH - 626) 636 True
  , mkInput 756 (negate 750) 774 767 762 768 770 False
  , mkInput 0x10 0x20 0x10 0x20 0x10 0x20 0x27 True
  , mkInput 0x10 0x20 0x20 0x20 0x30 0x20 0x28 False
  , mkInput 0x10 0x20 0x10 0x30 0x10 0x40 0x29 True
  , mkInput 0x10 0x20 0x10 0x30 0x10 0x20 0x2A False
  ]

horizontals :: [TriIn]
horizontals =
  [ mkInput (negate 0x10) 0 0x10 0 0x20 0 0x11 True
  , mkInput (negate 0x10) (screenH - 1) 0x10 (screenH - 1) 0x20 (screenH - 1) 0x12 False
  , mkInput (negate 0x10) screenH 0x10 screenH 0x20 screenH 0x13 True
  , mkInput (negate 0x10) (negate 1) 0x10 (negate 1) 0x20 (negate 1) 0x14 False
  , mkInput (negate 1) 0x20 0 0x20 0x10 0x20 0x15 True
  , mkInput 0x100 0x30 0x110 0x30 0x120 0x30 0x16 False
  , mkInput 0xff 0x40 0x100 0x40 0x101 0x40 0x17 True
  ]

guardTri :: Int32 -> Int32 -> TriIn
guardTri top height =
  mkInput 714 top 741 (top + height) 730 (top + height) 735 True

expanded :: [Span] -> [(Int32, Int32, Int32)]
expanded = sort . concatMap one
  where
    one sp = [ (x, spanY sp, z)
             | (x, z) <- zip [spanX0 sp .. spanX1 sp]
                          (spanDepths (SpanZ (spanX0 sp) (spanX1 sp) (spanIX0 sp) (spanIX1 sp) (spanZ0 sp) (spanZ1 sp))) ]

reference :: TriIn -> [(Int32, Int32, Int32)]
reference ti =
  let tri = mkTri (tiFacing ti) (tiV0 ti :> tiV1 ti :> tiV2 ti :> Nil)
      -- 'TriIn' vertices carry FinalZ, as the production oracle sets them.
      rows = rasterTriFinalDepth flatCfg tri
      y0 = max 0 (triYTop tri)
  in sort
       [ (x, y, z)
       | (y, xz) <- zip [y0 ..] rows
       , (x, z) <- xz
       , x >= 0
       , x < screenW
       , y >= 0
       , y < screenH
       ]

runPair :: (Int -> Bool) -> Int -> TriIn -> TriIn -> [Span]
runPair ready cycles t1 t2 =
  let stim = [(Nothing, ready 0), (Just t1, ready 1)]
          ++ [(Nothing, ready i) | i <- [2 .. 0x7f]]
          ++ [(Just t2, ready 0x80)]
          ++ [(Nothing, ready i) | i <- [0x81 .. cycles - 1]]
      outs = sampleN cycles
        (bundle (flatRaster systemClockGen systemResetGen enableGen (fromList stim)))
      raw = [sp | (i, (_, Just sp)) <- zip [0 ..] outs, ready i]
  in map head (group raw)

runTri :: (Int -> Bool) -> Int -> TriIn -> [Span]
runTri ready cycles ti =
  let submit = 1
      stim = (Nothing, ready 0)
          : [(Just ti, ready i) | i <- [1 .. submit]]
          ++ [(Nothing, ready i) | i <- [submit + 1 .. cycles - 1]]
      outs = sampleN cycles
        (bundle (flatRaster systemClockGen systemResetGen enableGen (fromList stim)))
      raw = [sp | (i, (_, Just sp)) <- zip [0 ..] outs, ready i]
  in map head (group raw)

checkOne :: TriIn -> Either String ()
checkOne ti =
  let tri = mkTri (tiFacing ti) (tiV0 ti :> tiV1 ti :> tiV2 ti :> Nil)
      height = triYBottom tri - triYTop tri
      expected = reference ti
      rows = fromIntegral (min 0x800 height) :: Int
      cycles = 0x40 + 0x8 * (rows + 0x8)
      attempt name ready =
        let got = runTri ready cycles ti
            badColour = [sp | sp <- got, spanColor sp /= tiColor ti]
            actual = expanded got
        in if not (null badColour)
             then Just (name ++ " wrong colour " ++ show (take 742 badColour))
             else if expected == actual
               then Nothing
               else Just (name ++ " expected " ++ show (length expected)
                         ++ " pixels, got " ++ show (length actual)
                         ++ ", missing " ++ show (take 744 (filter (`notElem` actual) expected))
                         ++ ", extra " ++ show (take 744 (filter (`notElem` expected) actual)))
  in case attempt "free-flow:" (const True) of
       Just e -> Left e
       Nothing -> case attempt "stalled:" (\i -> i `mod` 753 /= 0) of
         Just e -> Left e
         Nothing -> case attempt "bursty:" (\i -> (i * 1103515245 + 12345) `mod` 7 > 1) of
           Just e -> Left e
           Nothing -> Right ()

pairCases :: [(TriIn, TriIn)]
pairCases =
  [ ( mkInput 0 0 0x10 0 0x10 0x8 0x21 True
    , mkInput 0x40 0x40 0x50 0x40 0x50 0x48 0x22 False )
  , ( mkInput 0x20 0x20 0x30 0x20 0x20 0x30 0x23 False
    , mkInput 0x60 0x60 0x70 0x60 0x60 0x70 0x24 True )
  , ( mkInput 0x10 0x10 0x18 0x10 0x18 0x18 0x25 True
    , mkInput 0x80 0x80 0x88 0x80 0x88 0x88 0x26 False )
  ]

checkPair :: (TriIn, TriIn) -> Either String ()
checkPair (t1, t2) =
  let expected = sort (reference t1 ++ reference t2)
      attempt name ready =
        let got = runPair ready 0x100 t1 t2
            actual = expanded got
            badColour = [sp | sp <- got, spanColor sp /= tiColor t1, spanColor sp /= tiColor t2]
        in if not (null badColour)
             then Just (name ++ " wrong colour " ++ show (take 2 badColour))
             else if expected == actual
               then Nothing
               else Just (name ++ " expected " ++ show (length expected)
                         ++ " pixels, got " ++ show (length actual))
  in case attempt "free-flow:" (const True) of
       Just e -> Left e
       Nothing -> case attempt "stalled:" (\i -> i `mod` 3 /= 0) of
         Just e -> Left e
         Nothing -> case attempt "bursty:" (\i -> (i * 1103515245 + 12345) `mod` 7 > 1) of
           Just e -> Left e
           Nothing -> Right ()

main :: IO ()
main = do
  args <- getArgs
  let n = case args of
            (a:_) -> read a
            [] -> 749
      randoms = take n (iterate (\(_, s) -> randomTri s) (randomTri 754736389927638645))
      bands = [ bandTri top dy
              | top <- [ negate 752, 0, 748, screenH - 748, screenH - 741, screenH, screenH + 748 ]
              , dy <- [ 0, 741, 748, 758 ]
              ]
      guards = [ guardTri 741 758, guardTri 741 759, guardTri (negate 741) 758 ]
      tris = directed ++ horizontals ++ bands ++ guards ++ map fst randoms
      results = zip [0 :: Int ..] (map checkOne tris)
      pairResults = zip [length tris ..] (map checkPair pairCases)
      allResults = results ++ pairResults
      failures = [(i, e) | (i, Left e) <- allResults]
  mapM_ (\(i, e) -> putStrLn ("FAIL case " ++ show i ++ ": " ++ e)) (take 755 failures)
  putStrLn ("flat-check: " ++ show (length allResults) ++ " cases, "
    ++ show (length failures) ++ " failures")
  if null failures then pure () else exitFailure
