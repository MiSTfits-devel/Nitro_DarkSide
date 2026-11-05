-- | Native differential checker for 'Nds.Gpu3D.Slope'.
--
-- Reads the oracle stream produced by @test\/oracle\/slope_oracle.cpp@ and
-- compares every setup field and every stepped X against the Haskell model.
-- This is the native-silicon gate: the Clash equations are proved against the
-- production melonDS arithmetic before any synthesis run.
module Main (main) where

import Control.Monad (foldM)
import Data.Int (Int32)
import Data.Maybe (mapMaybe)
import Data.Word (Word32)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)
import Text.Read (readMaybe)

import Nds.Gpu3D.Slope

data Event
  = EvCase Case
  | EvStep Expected
  deriving (Show)

data Case = Case
  { cSide    :: Bool
  , cX0, cX1, cY0, cY1, cY :: Int32
  , cInc, cDx, cXVal :: Int32
  , cNeg, cXMajor, cXMin, cXMax, cXLen, cYLen :: Int32
  , cXRecip  :: Word32
  , cXCov    :: Int32
  , cLLen, cLCov, cRLen, cRCov :: Int32
  } deriving (Show)

data Expected = Expected
  { eDx, eXVal :: Int32
  } deriving (Show)

data Acc = Acc
  { accCases    :: !Int
  , accFailures :: !Int
  , accPending  :: Maybe (Case, Slope)
  , accReports  :: ![String]
  }

main :: IO ()
main = do
  args <- getArgs
  let limit = case args of
        (n:_) -> maybe 0x14 id (readMaybe n)
        []    -> 0x14
  input <- getContents
  let events = mapMaybe parseLine (lines input)
  final <- foldM (step limit) (Acc 0 0 Nothing []) events
  putStrLn $ "slope-check: " ++ show (accCases final) ++ " cases, "
    ++ show (accFailures final) ++ " failures"
  if accFailures final == 0
    then exitSuccess
    else do
      putStrLn "first mismatches:"
      mapM_ putStrLn (reverse (accReports final))
      exitFailure

step :: Int -> Acc -> Event -> IO Acc
step lim acc (EvCase c) =
  let (x, s) = setupSlope (cSide c) (cX0 c) (cX1 c) (cY0 c) (cY1 c)
                 0x0 0x0 (cY c) False
      bad = x /= cXVal c || not (matches c s)
      acc' = acc
        { accCases    = accCases acc + 0x1
        , accPending  = Just (c, s)
        , accFailures = accFailures acc + if bad then 0x1 else 0x0
        , accReports  = if bad && length (accReports acc) < lim
                          then reportCase c s : accReports acc
                          else accReports acc
        }
  in pure acc'
step _ acc (EvStep e) = pure $ case accPending acc of
  Nothing -> acc
  Just (c, s) ->
    let (x, s') = stepSlope s
        bad = slopeDx s' /= eDx e || x /= eXVal e
        acc' = acc
          { accPending  = Just (c, s')
          , accFailures = accFailures acc + if bad then 0x1 else 0x0
          , accReports  = if bad && length (accReports acc) < 0x14
                            then reportStep c s e : accReports acc
                            else accReports acc
          }
    in acc'

matches :: Case -> Slope -> Bool
matches c s =
     slopeInc s       == cInc c
  && slopeDx s        == cDx c
  && slopeNegative s  == (cNeg c /= 0x0)
  && slopeXMajor s    == (cXMajor c /= 0x0)
  && slopeXMin s      == cXMin c
  && slopeXMax s      == cXMax c
  && slopeXLen s      == cXLen c
  && slopeYLen s      == cYLen c
  && slopeXLenRecip s == cXRecip c
  && (not (cXMajor c /= 0x0) || slopeXCovIncr s == cXCov c)
  && llen == cLLen c && lcov == cLCov c
  && rlen == cRLen c && rcov == cRCov c
  where
    (llen, lcov) = edgeParams False s
    (rlen, rcov) = edgeParams True s

reportCase :: Case -> Slope -> String
reportCase c s = "case " ++ show c ++ " -> " ++ show s ++ " edges " ++ show (edgeParams False s, edgeParams True s)

reportStep :: Case -> Slope -> Expected -> String
reportStep c s e =
  "step " ++ show (cSide c, cX0 c, cX1 c, cY0 c, cY1 c, cY c)
    ++ " expected " ++ show e ++ " got dx=" ++ show (slopeDx s)

parseLine :: String -> Maybe Event
parseLine ln = case words ln of
  ("CASE":xs) -> EvCase <$> parseCase xs
  ("STEP":xs) -> EvStep <$> parseStep xs
  _           -> Nothing

parseCase :: [String] -> Maybe Case
parseCase ws = case traverse readI ws of
  Just [side, x0, x1, y0, y1, y, x, inc, dx, neg, xmajor,
        xmin, xmax, xlen, ylen, xrecip, xcov, llen, lcov, rlen, rcov] ->
    Just $ Case (side /= 0x0)
      (fi x0) (fi x1) (fi y0) (fi y1) (fi y) (fi inc) (fi dx) (fi x)
      (fi neg) (fi xmajor) (fi xmin) (fi xmax) (fi xlen) (fi ylen)
      (fromIntegral xrecip) (fi xcov)
      (fi llen) (fi lcov) (fi rlen) (fi rcov)
  _ -> Nothing
  where fi = fromIntegral :: Integer -> Int32

parseStep :: [String] -> Maybe Expected
parseStep ws = case traverse readI ws of
  Just [dx, x] -> Just (Expected (fi dx) (fi x))
  _            -> Nothing
  where fi = fromIntegral :: Integer -> Int32

readI :: String -> Maybe Integer
readI = readMaybe
