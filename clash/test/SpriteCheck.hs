-- | Independent gate for Nds.Gpu2D.Sprite: every expected OBJLine and
-- OBJWindow word comes from melonDS's production DrawSprites through
-- tools/gx2d_sprite_oracle.cpp. The oracle also applies ApplySpriteMosaicX;
-- the checker compares drawSprites and applySpriteMosaic separately.
module Main (main) where

import Control.Monad (unless, when)
import qualified Data.Array.Unboxed as A
import qualified Data.Binary.Get as G
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Word (Word32, Word8)
import System.Environment (getArgs)
import System.Exit (exitFailure)

import Nds.Gpu2D.Sprite

data Case = Case
  { cEnabled, cObjEnabled :: Bool
  , cMosaic :: Word8
  , cDispCnt, cMosaicLine, cLine :: Word32
  , cOam, cObj :: B.ByteString
  , cPre :: [Word32]
  , cWindow :: [Bool]
  , cPost :: [Word32]
  }

parseFile :: FilePath -> IO [Case]
parseFile path = do
  raw <- BL.readFile path
  let cases = G.runGet (do
                 magic <- G.getByteString 4
                 unless (magic == B.pack [83,80,82,50]) (fail "bad SPR2 magic")
                 count <- G.getWord32le
                 mapM (const parseCase) [1 .. count]) raw
  pure cases

parseCase :: G.Get Case
parseCase = do
  en <- (/= 0) <$> G.getWord8
  oe <- (/= 0) <$> G.getWord8
  mo <- G.getWord8
  dc <- G.getWord32le
  ml <- G.getWord32le
  ln <- G.getWord32le
  oamLen <- G.getWord32le
  oam <- G.getByteString (fromIntegral oamLen)
  objLen <- G.getWord32le
  obj <- G.getByteString (fromIntegral objLen)
  pre <- mapM (const G.getWord32le) [1 .. 256]
  win <- mapM (const ((/= 0) <$> G.getWord8)) [1 .. 256]
  post <- mapM (const G.getWord32le) [1 .. 256]
  pure (Case en oe mo dc ml ln oam obj pre win post)

inputFor :: Case -> SpriteInput
inputFor c = SpriteInput
  { siEnabled = cEnabled c
  , siOBJEnabled = cObjEnabled c
  , siDispCnt = cDispCnt c
  , siMosaicLine = cMosaicLine c
  , siTargetLine = fromIntegral (cLine c)
  , siOAMRead = \a -> oamArr A.! fromIntegral a
  , siOBJRead = \a -> objArr A.! fromIntegral a
  , siOBJMask = fromIntegral (B.length (cObj c) - 1)
  }
  where
    oamArr = A.listArray (0, B.length (cOam c) - 1) (B.unpack (cOam c)) :: A.UArray Int Word8
    objArr = A.listArray (0, B.length (cObj c) - 1) (B.unpack (cObj c)) :: A.UArray Int Word8

checkCase :: Int -> SpriteLine -> Case -> ([String], SpriteLine)
checkCase i prior c =
  let inp = inputFor c
      got = drawSprites inp prior
      gotMos = applySpriteMosaic (cMosaic c) got
      pixErr = firstDiff (slPixels got) (cPre c)
      winErr = firstDiff (map (fromIntegral . fromEnum) (slWindow got))
                         (map (fromIntegral . fromEnum) (cWindow c))
      mosErr = firstDiff (slPixels gotMos) (cPost c)
      errs = [ "case " ++ show i ++ ": " ++ what ++ " at x=" ++ show x
               ++ " got=" ++ show g ++ " want=" ++ show w
             | (what, Just (x, g, w)) <- [("OBJLine", pixErr), ("OBJWindow", winErr), ("mosaic", mosErr)] ]
  in (errs, gotMos)

firstDiff :: Eq a => [a] -> [a] -> Maybe (Int, a, a)
firstDiff xs ys = go 0 xs ys
  where
    go _ [] [] = Nothing
    go n (a:as) (b:bs) | a == b = go (n + 1) as bs
                       | otherwise = Just (n, a, b)
    go n xs' ys' = Just (n, head xs', head ys')

main :: IO ()
main = do
  args <- getArgs
  path <- case args of
    [p] -> pure p
    _ -> do putStrLn "usage: sprite-check <oracle.bin>"; exitFailure
  cases <- parseFile path
  let (failures, _) = foldl step ([], emptySpriteLine)
        (zip [0 :: Int ..] cases)
      step (errs, prior) (i, c) =
        let (e, next) = checkCase i prior c in (errs ++ e, next)
  mapM_ putStrLn failures
  putStrLn ("sprite-check: " ++ show (length cases) ++ " cases, "
            ++ show (length failures) ++ " mismatches")
  when (not (null failures)) exitFailure
