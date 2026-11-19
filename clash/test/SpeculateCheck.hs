-- | Cache identity, replacement and total-render accounting checks.
module Main (main) where

import Data.Array.Unboxed (UArray, listArray)
import qualified Data.ByteString as B
import Data.Word (Word8, Word32)
import System.Exit (exitFailure)
import Nds.Gpu2D.Speculate
import Nds.Gpu2D.Types
import Nds.Gpu2D.Trace

main :: IO ()
main = do
  parent <- newTraceMemory
  branchA <- either fail pure (applyDelta parent 0 0 (B.pack [0x1f,0]))
  branchB <- either fail pure (applyDelta parent 0 0 (B.pack [0,0x7c]))
  let base = state
      frame = FrameInput emptyCache (replicate 192 base)
      cold = onePassFrame frame
      warm = onePassFrame frame { fiCache = foCache cold }
      changed = base { esPalette = mem 7 }
      oneChanged = frame { fiCache = foCache cold
                         , fiStates = take 37 (fiStates frame) ++ [changed] ++ drop 38 (fiStates frame) }
      fixed = onePassFrame oneChanged
      callback = base { esObjVram = Memory 2047 (\_ -> 0) }
      untrusted = onePassFrame (FrameInput (foCache cold) (replicate 192 callback))
      originalKey = lineKey base 37
      mutants =
        [ base { esOam = mem 1 }, base { esVram = mem 2 }
        , base { esObjVram = mem 3 }, base { esPalette = mem 4 }
        , base { esBgExtPal = mem 5 }, base { esNum = 1 }
        , base { esBgMosaicX = 1 }, base { esBgMosaicLine = 1 }
        , base { esObjMosaicLine = 1 }, base { esBlendCnt = 1 }
        , base { esEva = 1 }, base { esEvb = 1 }, base { esEvy = 1 }
        , base { esDispCnt = 1 }
        ] ++ [base { esBgMosaicLine = n } | n <- [2..33]]
      zeroLatch = EngineLatch 0 0 0 0 0 0 0 0 0 0
      paletteView memory = phasePaletteMemory (Phase ScanlinePhase B.empty
        (Latch zeroLatch zeroLatch) (ExtendedPaletteMap B.empty) Nothing memory Nothing)
      forkStateA = state { esPalette = paletteView branchA }
      forkStateB = state { esPalette = paletteView branchB }
      forkA = onePassFrame (FrameInput emptyCache (replicate 192 forkStateA))
      forkFrameB = FrameInput (foCache forkA) (replicate 192 forkStateB)
      forkB = onePassFrame forkFrameB
      forkExpected = referenceFrame forkFrameB
      checks =
        [ ("cold total renders", totalRenders (foStats cold) == 192)
        , ("cold output", foLines cold == foLines (referenceFrame frame))
        , ("warm output", foLines warm == foLines cold)
        , ("warm hits", stHits (foStats warm) == 192 && totalRenders (foStats warm) == 0)
        , ("selective replacement", stInvalidated (foStats fixed) == 1 && stPrefetchRenders (foStats fixed) == 1)
        , ("changed output", foLines fixed == foLines (referenceFrame oneChanged))
        , ("every memory/register mutation changes key", all ((/= originalKey) . (`lineKey` 37)) mutants)
        , ("line belongs to key", lineKey base 38 /= originalKey)
        , ("opaque callbacks cannot be cached", lineKey callback 37 == Nothing && stDemandRenders (foStats untrusted) == 192)
        , ("opaque callbacks render correctly", foLines untrusted == foLines (referenceFrame (FrameInput emptyCache (replicate 192 callback))))
        , ("same-parent palette fork changes cached consumer pixels",
           foLines forkB == foLines forkExpected && foLines forkA /= foLines forkExpected)
        ]
      failures = [name | (name,ok) <- checks, not ok]
  mapM_ (putStrLn . ("FAIL " ++)) failures
  putStrLn ("speculate-check: " ++ show (length checks) ++ " cases, " ++ show (length failures) ++ " failures")
  if null failures then pure () else exitFailure

mem :: Word8 -> Memory
mem first = uarrayMemory (listArray (0,2047) (first : replicate 2047 0) :: UArray Word32 Word8)

state :: EngineState
state = EngineState
  { esNum = 0, esDispCnt = 0
  , esBg = V4 reg reg reg reg
  , esBlendCnt = 0, esEva = 0, esEvb = 0, esEvy = 0
  , esObjMosaicLine = 0, esBgMosaicLine = 0, esBgMosaicX = 0
  , esOam = mem 0, esVram = mem 0, esObjVram = mem 0
  , esPalette = mem 0, esBgExtPal = mem 0
  , esOamEpoch = 0, esVramEpoch = 0, esPaletteEpoch = 0
  }
  where reg = BgReg 0 0 0 0 0 0 0 0 0
