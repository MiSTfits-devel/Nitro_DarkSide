-- | Native differential checker for the depth-tested flat frame.
--
-- Reads a frame of @TRI@ / @TRIZ@ / @TRIZW@ triangles, renders them through the
-- pure model, and compares every one of the 256x192 pixels with the production
-- melonDS frame: coverage, colour, and the final depth-buffer value.
module Main (main) where

import Data.Binary.Get (getWord32le, runGet)
import Data.Bits ((.&.), shiftL, shiftR)
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int32)
import qualified Data.Map.Strict as M
import Data.Word (Word32)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import Text.Read (readMaybe)

import Nds.Gpu3D.Depth (clearDepth)
import Nds.Gpu3D.Flat
import Nds.Gpu3D.Frame
import Nds.Gpu3D.Raster

width, height :: Int
width = 256
height = 192

clearAttr :: Int32
clearAttr = 0x7FFF

-- | One pixel as both sides see it: covered colour (or none) and depth.
type Px = (Maybe Int32, Int32)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [casesPath, colourPath, depthPath] -> do
      caseText <- readFile casesPath
      colourBin <- BL.readFile colourPath
      depthBin <- BL.readFile depthPath
      let tris = [t | Just t <- map parseLine (lines caseText)]
          colours = words32 colourBin
          depths = words32 depthBin
          model = renderFrameBuffer clearAttr tris
          clear = clearDepth (fromIntegral clearAttr)
          diffs =
            [ ((x, y), want, got)
            | (i, (cw, dw)) <- zip [0 :: Int ..] (zip colours depths)
            , let (y, x) = i `divMod` width
                  key = (fromIntegral x, fromIntegral y)
                  want = (oracleColour cw, fromIntegral dw) :: Px
                  got = case M.lookup key model of
                          Just (z, c) -> (Just c, z)
                          Nothing -> (Nothing, clear)
            , want /= got
            ]
          covered = length [ () | w <- colours, w `shiftR` 24 /= 0 ]
      if length colours /= width * height || length depths /= width * height
        then putStrLn "FAIL short oracle output" >> exitFailure
        else if null diffs
          then putStrLn ("frame-check: " ++ show (length tris) ++ " triangles, "
                 ++ show covered ++ " covered pixels, "
                 ++ show (width * height) ++ " pixels compared, 0 failures")
          else do
            putStrLn ("FAIL " ++ show (length diffs) ++ " of "
              ++ show (width * height) ++ " pixels differ (want, got):")
            mapM_ (putStrLn . ("  " ++) . show) (take 12 diffs)
            exitFailure
    _ -> do
      putStrLn "usage: frame-check CASES COLOUR DEPTH"
      exitFailure

words32 :: BL.ByteString -> [Word32]
words32 bs = runGet (sequence (replicate n getWord32le)) bs
  where n = fromIntegral (BL.length bs `div` 4)

-- | The final colour word carries alpha in the top byte; zero means untouched.
oracleColour :: Word32 -> Maybe Int32
oracleColour w
  | w `shiftR` 24 == 0 = Nothing
  | otherwise = Just (fromIntegral ((w .&. 0x1F)
                       + ((w `shiftR` 8) .&. 0x1F) * 0x20
                       + ((w `shiftR` 16) .&. 0x1F) * 0x400))

parseLine :: String -> Maybe TriIn
parseLine line =
  case words line of
    ("TRIZW":rest) -> case traverse readMaybe rest of
      Just [x0, y0, z0, w0, x1, y1, z1, w1, x2, y2, z2, w2, r, g, b, face] ->
        Just (mkInput (x0, y0, z0, w0) (x1, y1, z1, w1) (x2, y2, z2, w2) r g b face)
      _ -> Nothing
    ("TRIZ":rest) -> case traverse readMaybe rest of
      Just [x0, y0, z0, x1, y1, z1, x2, y2, z2, r, g, b, face] ->
        Just (mkInput (x0, y0, z0, 0) (x1, y1, z1, 0) (x2, y2, z2, 0) r g b face)
      _ -> Nothing
    ("TRI":rest) -> case traverse readMaybe rest of
      Just [x0, y0, x1, y1, x2, y2, r, g, b, face] ->
        Just (mkInput (x0, y0, 0, 0) (x1, y1, 0, 0) (x2, y2, 0, 0) r g b face)
      _ -> Nothing
    _ -> Nothing

mkInput :: (Int32, Int32, Int32, Int32) -> (Int32, Int32, Int32, Int32)
        -> (Int32, Int32, Int32, Int32) -> Int32 -> Int32 -> Int32 -> Int32 -> TriIn
mkInput a b c r g bl face =
  TriIn (vert a) (vert b) (vert c) (face /= 0)
        ((r .&. 0x1F) + ((g .&. 0x1F) `shiftL` 5) + ((bl .&. 0x1F) `shiftL` 10))
  where
    vert (x, y, z, w) = Vertex x y z w r g bl
