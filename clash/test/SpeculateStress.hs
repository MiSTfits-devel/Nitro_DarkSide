-- | Independent M5 cache-semantics stress: bounded 192-entry LRU, exact-key
-- reuse, stale-plan rejection, memory/register/latch/engine/line identity, and
-- no stale output against the exact renderer. Uses only the public
-- Nds.Gpu2D.Speculate API; it does not inspect or modify cache internals.
module Main (main) where

import Control.Monad (unless)
import Data.Array.Unboxed (UArray, listArray)
import Data.Bits ((.&.), (.|.), shiftL, shiftR, testBit, xor)
import Data.List (foldl')
import Data.Word (Word16, Word32, Word64, Word8)
import System.Exit (exitFailure)

import Nds.Gpu2D.Speculate
import Nds.Gpu2D.Types

xs :: Word64 -> Word64
xs s0 =
  let s1 = s0 `xor` (s0 `shiftR` 12)
      s2 = s1 `xor` (s1 `shiftR` 25)
      s3 = s2 `xor` (s2 `shiftR` 27)
  in s3 * 2685821657736338717

stream :: Word64 -> [Word64]
stream = iterate xs

memBytes :: Int -> Word64 -> Memory
memBytes n seed =
  uarrayMemory (listArray (0, fromIntegral n - 1)
    [ fromIntegral ((s `shiftR` 17) .&. 0xFF)
    | s <- take n (tail (stream seed)) ])

vramMem :: Word64 -> Memory
vramMem seed =
  uarrayMemory (listArray (0, 0x0FFF)
    [ if odd i then 0
      else fromIntegral ((s `shiftR` 7) .&. 0x3F)
    | (i, s) <- zip [0 :: Int ..] (tail (stream seed)) ])

oamMem :: Word64 -> Memory
oamMem seed = uarrayMemory (listArray (0, 1023) bytes)
  where
    ws = stream seed
    w n i = ws !! (n * 8 + i)
    attr n =
      let a0 = fromIntegral (w n 0 .&. 0xFF) :: Word16
          typ = if n < 4 then 0 else 2
          a0' = a0 .|. (fromIntegral typ `shiftL` 8)
          a1 = (fromIntegral (w n 1 .&. 0x1FF) :: Word16)
               .|. (if testBit (w n 1) 12 then 1 `shiftL` 12 else 0)
               .|. (if testBit (w n 1) 13 then 1 `shiftL` 13 else 0)
               .|. (fromIntegral (w n 1 .&. 0x3) `shiftL` 14)
          a2 = (fromIntegral (w n 2 .&. 0x3F) :: Word16)
               .|. (fromIntegral ((w n 2 `shiftR` 2) .&. 0x3) `shiftL` 10)
               .|. (fromIntegral ((w n 2 `shiftR` 4) .&. 0xF) `shiftL` 12)
               .|. (if testBit (w n 2) 8 then 1 `shiftL` 13 else 0)
      in [ lo a0', hi a0', lo a1, hi a1, lo a2, hi a2, 0, 0 ]
    lo x = fromIntegral (x .&. 0xFF)
    hi x = fromIntegral (x `shiftR` 8)
    bytes = concat [ attr n | n <- [0 .. 127] ]

randState :: Word64 -> EngineState
randState seed =
  let w i = stream seed !! i
      byte i = fromIntegral ((w i `shiftR` 9) .&. 0xFF) :: Word8
      vram = vramMem (seed + 1)
      oam = oamMem (seed + 2)
      objs = memBytes 0x1100 (seed + 3)
      pal = memBytes 0x800 (seed + 4)
      ext = memBytes 0x400 (seed + 5)
      reg y = BgReg
        { brCnt = fromIntegral (w (10 + y) .&. 0x0003)
        , brX = fromIntegral (w (20 + y) .&. 0xFF)
        , brY = fromIntegral (w (30 + y) .&. 0xFF)
        , brPA = 0, brPB = 0, brPC = 0, brPD = 0, brRX = 0, brRY = 0 }
      d = w 1
      dispcnt = 1
        .|. (if testBit d 0 then 1 `shiftL` 8 else 0)
        .|. (if testBit d 1 then 1 `shiftL` 12 else 0)
        .|. (if testBit d 2 then 1 `shiftL` 30 else 0)
        .|. (if testBit d 3 then 1 `shiftL` 6 else 0)
  in EngineState
      { esNum = 0
      , esDispCnt = dispcnt
      , esBg = V4 (reg 0) (reg 1) (reg 2) (reg 3)
      , esBlendCnt = 0
      , esEva = 0, esEvb = 0, esEvy = 0
      , esObjMosaicLine = fromIntegral (w 4 .&. 0xFF)
      , esBgMosaicLine = fromIntegral (w 3 .&. 0xFF)
      , esBgMosaicX = fromIntegral (w 2 .&. 0x3)
      , esOam = oam
      , esVram = vram
      , esObjVram = objs
      , esPalette = pal
      , esBgExtPal = ext
      , esOamEpoch = 0, esVramEpoch = 0, esPaletteEpoch = 0
      }
  where
    byte2 = 0

frameStates :: Word64 -> [EngineState]
frameStates seed =
  [ randState (seed + fromIntegral y * 0x9E3779B97F4A7C15)
  | y <- [0 .. 191 :: Int] ]

forceLines :: [[Pixel]] -> [[Pixel]]
forceLines ls =
  foldl' (\() line -> foldl' (\() p -> pxRgb p `seq` pxLayer p `seq` ()) () line) () ls
  `seq` ls

mutate :: Int -> EngineState -> EngineState
mutate i s = case i `mod` 16 of
  0 -> s { esOam = oamMem 11 }
  1 -> s { esVram = vramMem 12 }
  2 -> s { esObjVram = memBytes 0x1100 13 }
  3 -> s { esPalette = memBytes 0x800 14 }
  4 -> s { esBgExtPal = memBytes 0x400 15 }
  5 -> s { esOamEpoch = esOamEpoch s + 1 }
  6 -> s { esVramEpoch = esVramEpoch s + 1 }
  7 -> s { esPaletteEpoch = esPaletteEpoch s + 1 }
  8 -> s { esNum = 1, esObjVram = memBytes 0x22000 31 }
  9 -> s { esDispCnt = esDispCnt s `xor` 0x40 }
  10 -> s { esBg = V4 (b0 { brCnt = brCnt b0 `xor` 0x8000 })
                       (v4Index (esBg s) 1) (v4Index (esBg s) 2) (v4Index (esBg s) 3) }
  11 -> s { esBg = V4 (b0 { brX = brX b0 `xor` 1 })
                       (v4Index (esBg s) 1) (v4Index (esBg s) 2) (v4Index (esBg s) 3) }
  12 -> s { esBgMosaicLine = esBgMosaicLine s `xor` 1 }
  13 -> s { esObjMosaicLine = esObjMosaicLine s `xor` 1 }
  14 -> s { esBgMosaicX = if esBgMosaicX s == 3 then 0 else esBgMosaicX s + 1 }
  _ -> s { esDispCnt = esDispCnt s `xor` 0x1000 }
  where b0 = v4Index (esBg s) 0

main :: IO ()
main = do
  let f0 = frameStates 0xABCDEF
      cold = onePassFrame (FrameInput emptyCache f0)
      warm = onePassFrame (FrameInput (foCache cold) f0)
      ref0 = referenceFrame (FrameInput emptyCache f0)
      checks0 =
        [ ("cold exact output", foLines cold == foLines ref0)
        , ("cold renders=192", totalRenders (foStats cold) == 192 && stPrefetchRenders (foStats cold) == 192 && stDemandRenders (foStats cold) == 0)
        , ("warm exact output", foLines warm == foLines ref0)
        , ("warm zero renders", totalRenders (foStats warm) == 0)
        , ("warm hits=192", stHits (foStats warm) == 192)
        ]

      -- Incoherent plans must never be trusted.
      plan0 = planFrame f0
      wrongState = (head f0) { esVram = vramMem 99 }
      wrongPlan = [ LinePlan y (lineKey wrongState y) | LinePlan y _ <- plan0 ]
      (wrongCache, wrongStats) = prefetchFrame emptyCache f0 wrongPlan
      (_, rightStats) = prefetchFrame wrongCache f0 plan0
      checks1 =
        [ ("mismatched plan is not prefetched",
           stPrefetchRenders wrongStats == 0 && stInvalidated wrongStats == 0)
        , ("nothing incorrectly cached", stPrefetchRenders rightStats == 192)
        ]

      -- Random single-line mutations: exact output, key changes, no stale line.
      seeds = [0x1111, 0x2222, 0x3333, 0x4444, 0x5555]
      mutChecks = concat
        [ let baseFrame = frameStates seed
              coldF = onePassFrame (FrameInput emptyCache baseFrame)
              y = fromIntegral (seed `mod` 192)
              base = baseFrame !! y
              mutated = [ if i == y then mutate (fromIntegral (seed `shiftR` 8)) base else st
                        | (i, st) <- zip [0 ..] baseFrame ]
              refM = referenceFrame (FrameInput emptyCache mutated)
              gotM = onePassFrame (FrameInput (foCache coldF) mutated)
              keyChanged = lineKey base y /= lineKey (mutated !! y) y
          in [ ("mutation exact output seed " ++ show seed, foLines gotM == foLines refM)
             , ("mutation changes key seed " ++ show seed, keyChanged)
             , ("mutation not served stale seed " ++ show seed,
                foLines gotM !! y == foLines refM !! y) ]
        | seed <- seeds ]

      -- Every field family changes the key and its line is re-rendered.
      famFrame = frameStates 0xCAFE
      famCold = onePassFrame (FrameInput emptyCache famFrame)
      y0 = 37
      base = famFrame !! y0
      k0 = lineKey base y0
      famMut mi = [ if i == y0 then mutate mi base else st | (i, st) <- zip [0..] famFrame ]
      famChecks = concat
        [ let mutated = famMut mi
              refM = referenceFrame (FrameInput emptyCache mutated)
              gotM = onePassFrame (FrameInput (foCache famCold) mutated)
          in [ ("mutation " ++ show mi ++ " changes key", lineKey (mutated !! y0) y0 /= k0)
             , ("mutation " ++ show mi ++ " exact output", foLines gotM == foLines refM)
             , ("mutation " ++ show mi ++ " not stale", foLines gotM !! y0 == foLines refM !! y0)
             ]
        | mi <- [0 .. 15] ]
      checks2 =
        [ ("line index is part of key", lineKey base (y0 + 1) /= k0)
        ] ++ famChecks

      -- 192-entry LRU: 300 sequential inserts evict the first 108.
      big = [ randState (0xF00D + fromIntegral i * 0x9E37) | i <- [0 .. 299 :: Int] ]
      bigPlans = [ LinePlan i (lineKey (big !! i) i) | i <- [0 .. 299] ]
      (bigCache, bigStats) = prefetchFrame emptyCache big bigPlans
      selected ys = [ if i `elem` ys then LinePlan i (lineKey (big !! i) i) else LinePlan i Nothing
                    | i <- [0 .. length big - 1] ]
      (_, evicted0) = prefetchFrame bigCache big (selected [0])
      (_, kept108) = prefetchFrame bigCache big (selected [108])
      (_, kept299) = prefetchFrame bigCache big (selected [299])
      (_, kept107) = prefetchFrame bigCache big (selected [107])
      (_, retainedAll) = prefetchFrame bigCache big (selected [108 .. 299])
      checks3 =
        [ ("300 inserts render 300", stPrefetchRenders bigStats == 300)
        , ("300 inserts drop 108", stInvalidated bigStats == 300 - cacheCapacity)
        , ("evicted line 0 refetches", stPrefetchRenders evicted0 == 1)
        , ("evicted line 107 refetches", stPrefetchRenders kept107 == 1)
        , ("retained line 108 hits", stPrefetchRenders kept108 == 0)
        , ("retained line 299 hits", stPrefetchRenders kept299 == 0)
        , ("all 192 retained lines hit", stPrefetchRenders retainedAll == 0)
        ]

      -- Touch updates LRU: line 0 touched, next insert evicts line 1.
      small = [ randState (0xBEEF + fromIntegral i * 0x85EB) | i <- [0 .. 192 :: Int] ]
      smallPlans = [ LinePlan i (lineKey (small !! i) i) | i <- [0 .. 191] ]
      (lruCache, lruStats) = prefetchFrame emptyCache small smallPlans
      sselected ys = [ if i `elem` ys then LinePlan i (lineKey (small !! i) i) else LinePlan i Nothing
                     | i <- [0 .. length small - 1] ]
      (lruCacheTouched, touch0) = prefetchFrame lruCache small (sselected [0])
      (lruCache2, ins192) = prefetchFrame lruCacheTouched small (sselected [192])
      (_, after0) = prefetchFrame lruCache2 small (sselected [0])
      (_, after1) = prefetchFrame lruCache2 small (sselected [1])
      checks4 =
        [ ("192 inserts fit", stPrefetchRenders lruStats == 192 && stInvalidated lruStats == 0)
        , ("touched line hits", stPrefetchRenders touch0 == 0)
        , ("new line evicts one", stPrefetchRenders ins192 == 1 && stInvalidated ins192 == 1)
        , ("touched line survives", stPrefetchRenders after0 == 0)
        , ("least-recent line 1 evicted", stPrefetchRenders after1 == 1)
        ]

      -- Provider-aware cache: 3D token identity invalidates only changed lines.
      fakeA y _ = replicate 256 (Pixel (fromIntegral (y * 3)) LBackdrop)
      fakeB y es = if y >= 10 && y <= 20
                     then replicate 256 (Pixel 0xABCD LBackdrop)
                     else fakeA y es
      tokA _ = Just 0
      tokB y = Just (if y >= 10 && y <= 20 then 1 else 0)
      provFrame = FrameInput emptyCache f0
      provCold = onePassFrameWith fakeA tokA provFrame
      provWarm = onePassFrameWith fakeA tokA provFrame { fiCache = foCache provCold }
      provB = onePassFrameWith fakeB tokB provFrame { fiCache = foCache provWarm }
      provRefA = referenceFrameWith fakeA provFrame
      provRefB = referenceFrameWith fakeB provFrame
      checks5 =
        [ ("provider cold exact", foLines provCold == foLines provRefA)
        , ("provider cold renders 192",
           stPrefetchRenders (foStats provCold) == 192 && stDemandRenders (foStats provCold) == 0)
        , ("provider warm exact", foLines provWarm == foLines provRefA)
        , ("provider warm zero renders", totalRenders (foStats provWarm) == 0)
        , ("provider token change exact", foLines provB == foLines provRefB)
        , ("provider token change only re-renders changed lines",
           totalRenders (foStats provB) == 11)
        , ("3D token is part of key", lineKeyWith (tokA 10) base 10 /= lineKeyWith (tokB 10) base 10)
        , ("unchanged token keeps key", lineKeyWith (tokA 0) base 0 == lineKeyWith (tokB 0) base 0)
        ]

      -- Full token identity: sprite/window/capture tokens participate in the
      -- key exactly like the 3D token and invalidate only their own lines.
      tokNone = noLineKeyTokens
      tok3 = tokNone { lkt3D = Just 7 }
      tokS = tokNone { lktSprite = Just 7 }
      tokW = tokNone { lktWindow = Just 7 }
      tokC = tokNone { lktCapture = Just 7 }
      tokD = tokNone { lktDisplay = Just 7 }
      tokAll = LineKeyTokens (Just 1) (Just 2) (Just 3) (Just 4) (Just 5)
      checks6 =
        [ ("3D token changes key", lineKeyTok tok3 base 10 /= lineKeyTok tokNone base 10)
        , ("sprite token changes key", lineKeyTok tokS base 10 /= lineKeyTok tokNone base 10)
        , ("window token changes key", lineKeyTok tokW base 10 /= lineKeyTok tokNone base 10)
        , ("capture token changes key", lineKeyTok tokC base 10 /= lineKeyTok tokNone base 10)
        , ("display token changes key", lineKeyTok tokD base 10 /= lineKeyTok tokNone base 10)
        , ("token fields are distinct",
           let ks = map (\t -> lineKeyTok t base 10) [tok3, tokS, tokW, tokC, tokD, tokAll]
           in length ks == length (foldr (\k acc -> if k `elem` acc then acc else k : acc) [] ks))
        ]
      tokFrame = FrameInput emptyCache f0
      tokSA _ = noLineKeyTokens { lktSprite = Just 0, lktWindow = Just 0, lktCapture = Just 0 }
      tokSB y = let t = tokSA y
                in if y >= 5 && y <= 9 then t { lktWindow = Just 1 } else t
      renderTokA y es = replicate 256 (Pixel (fromIntegral y) LBackdrop)
      renderTokB y es = if y >= 5 && y <= 9
                          then replicate 256 (Pixel 0xBEEF LBackdrop)
                          else renderTokA y es
      tokCold = onePassFrameWithTokens renderTokA tokSA tokFrame
      tokRefA = referenceFrameWith renderTokA tokFrame
      tokWarm = onePassFrameWithTokens renderTokA tokSA tokFrame { fiCache = foCache tokCold }
      tokChanged = onePassFrameWithTokens renderTokB tokSB tokFrame { fiCache = foCache tokWarm }
      tokRefB = referenceFrameWith renderTokB tokFrame
      checks7 =
        [ ("token cold exact", foLines tokCold == foLines tokRefA)
        , ("token warm zero renders", totalRenders (foStats tokWarm) == 0)
        , ("token change exact", foLines tokChanged == foLines tokRefB)
        , ("token change re-renders only changed lines", totalRenders (foStats tokChanged) == 5)
        ]

      allChecks = checks0 ++ checks1 ++ mutChecks ++ checks2 ++ checks3 ++ checks4 ++ checks5 ++ checks6 ++ checks7
      failures = [ name | (name, ok) <- allChecks, not ok ]
  mapM_ (putStrLn . ("FAIL " ++)) failures
  putStrLn ("speculate-stress: " ++ show (length allChecks) ++ " checks, "
            ++ show (length failures) ++ " failures")
  unless (null failures) exitFailure
