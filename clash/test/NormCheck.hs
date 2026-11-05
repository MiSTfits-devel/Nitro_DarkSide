-- | Native differential checker for W normalization and the depth transform.
module Main (main) where

import Control.Monad (forM_)
import Data.Int (Int32)
import Data.Word (Word32)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import Text.Read (readMaybe)

import Nds.Gpu3D.Depth

data Case = Case Word32 Int32 Word32 Int32 Int32

main :: IO ()
main = do
  args <- getArgs
  case args of
    [path] -> do
      text <- readFile path
      let cases = [c | Just c <- map parseLine (lines text)]
          failures = [(i, e) | (i, Just e) <- zip [0 :: Int ..] (map check cases)]
      forM_ (take 8 failures) $ \(i, e) ->
        putStrLn ("FAIL norm case " ++ show i ++ ": " ++ e)
      putStrLn ("norm-check: " ++ show (length cases) ++ " cases, "
        ++ show (length failures) ++ " failures")
      if null failures then pure () else exitFailure
    _ -> do
      putStrLn "usage: norm-check FILE"
      exitFailure

parseLine :: String -> Maybe Case
parseLine line =
  case words line of
    ("NORM":rest) ->
      case traverse readI rest of
        Just [w, z, wsize, wnorm, zz] ->
          Just (Case (fromIntegral (w :: Int32)) z
                     (fromIntegral (wsize :: Int32)) wnorm zz)
        _ -> Nothing
    _ -> Nothing
  where
    readI s = readMaybe s

check :: Case -> Maybe String
check (Case w z wsize wnorm zz) =
  let gotSize = normalizedWSize w
      gotW = normalizeW w
      gotZ = divideZ z w
  in if (gotSize, gotW, gotZ) == (wsize, wnorm, zz)
       then Nothing
       else Just ("w=" ++ show w ++ " z=" ++ show z
                ++ " want=" ++ show (wsize, wnorm, zz)
                ++ " got=" ++ show (gotSize, gotW, gotZ))
