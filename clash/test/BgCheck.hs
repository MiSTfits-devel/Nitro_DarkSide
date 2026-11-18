-- | Independent BG gate: production SoftRenderer2D::DrawScanline_BGOBJ is the
-- expected line. Only one BG is enabled, with effects and OBJ off, so the
-- comparison isolates the background path that Nds.Gpu2D.Line models.
-- Covers engine A and engine B, BG extended palettes (DISPCNT bit 30), all
-- background modes, map/tileset base blocks and mosaic.
module Main (main) where

import Control.Monad (unless, when)
import Data.Array.Unboxed (listArray)
import Data.Binary.Get as G
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Bits (shiftL, shiftR, testBit, xor, (.&.), (.|.))
import Data.Int (Int16, Int32)
import Data.Word (Word8, Word16, Word32)
import System.Environment (getArgs)
import System.Exit (exitFailure)

import Nds.Gpu2D.Line
import Nds.Gpu2D.Types

data Case = Case
  { cDispCnt, cLine, cSeed, cKind, cEngine, cBgNum, cPattern, cMosaic :: Word32
  , cBgCnt, cX, cY :: Word16
  , cPA, cPB, cPC, cPD :: Int16
  , cRX, cRY :: Int32
  , cWords :: [Word32]
  }

parseFile :: FilePath -> IO [Case]
parseFile path = do
  raw <- BL.readFile path
  pure $ G.runGet (do
    magic <- G.getByteString 4
    unless (magic == B.pack [66,71,67,50]) (fail "bad BGC2 magic")
    n <- G.getWord32le
    mapM (const parseCase) [1 .. n]) raw

parseCase :: G.Get Case
parseCase = do
  dc <- G.getWord32le; ln <- G.getWord32le; sd <- G.getWord32le
  kd <- G.getWord32le; en <- G.getWord32le; bn <- G.getWord32le
  pt <- G.getWord32le; mo <- G.getWord32le
  bc <- G.getWord16le; x <- G.getWord16le; y <- G.getWord16le
  pa <- G.getInt16le; pb <- G.getInt16le; pc <- G.getInt16le; pd <- G.getInt16le
  rx <- G.getInt32le; ry <- G.getInt32le
  ws <- mapM (const G.getWord32le) [1 .. 256]
  pure (Case dc ln sd kd en bn pt mo bc x y pa pb pc pd rx ry ws)

-- Fixture patterns, byte-for-byte identical to tools/gx2d_bg_oracle.cpp.
vramByte :: Word32 -> Word32 -> Word8
vramByte seed i = fromIntegral ((seed * 37 + i * 13 + (i `div` 512)) .&. 0xFF)

hashByte :: Word32 -> Word32 -> Word8
hashByte seed i =
  let h0 = seed * 2654435761 + i * 0x9E3779B1
      h1 = h0 `xor` (h0 `shiftR` 15)
      h2 = h1 * 2246822519
      h3 = h2 `xor` (h2 `shiftR` 13)
  in fromIntegral (h3 `shiftR` 24)

structuredWord :: Word32 -> Word32 -> Word16
structuredWord seed k =
  let tile = fromIntegral ((k * 7 + seed) .&. 0x3FF) :: Word16
      attr = fromIntegral ((((k `shiftR` 2) .&. 0xF) `shiftL` 12)
                           .|. (((k `shiftR` 3) .&. 1) `shiftL` 11)
                           .|. (((k `shiftR` 4) .&. 1) `shiftL` 10)) :: Word16
  in tile .|. attr

fixtureByte :: Word32 -> Word32 -> Word32 -> Word8
fixtureByte pat seed i = case pat of
  1 -> hashByte seed i
  2 -> let w = structuredWord seed (i `shiftR` 1)
       in fromIntegral (if odd i then w `shiftR` 8 else w .&. 0xFF)
  _ -> vramByte seed i

palWord :: Word32 -> Word32 -> Word16
palWord seed i = fromIntegral ((seed * 17 + i * 5 + 1) .&. 0x7FFF)

mkMem :: Word32 -> Word32 -> Memory
mkMem seed size = uarrayMemory (listArray (0, fromIntegral size - 1)
  [vramByte seed i | i <- [0 .. size - 1]])

mkVram :: Word32 -> Word32 -> Word32 -> Memory
mkVram pat seed size = uarrayMemory (listArray (0, fromIntegral size - 1)
  [fixtureByte pat seed i | i <- [0 .. size - 1]])

mkPal :: Word32 -> Memory
mkPal seed = uarrayMemory (listArray (0, 0xFFF)
  [ byteAt i | i <- [0 .. 0xFFF] ])
  where
    byteAt i = let w = palWord seed (i `div` 2)
               in if even i then fromIntegral (w .&. 0xFF)
                            else fromIntegral (w `shiftR` 8)

checkCase :: Int -> Case -> [String]
checkCase i c =
  let n = fromIntegral (cBgNum c)
      engine = fromIntegral (cEngine c) :: Int
      rot = if n > 1 then n - 2 else 0
      zero = BgReg 0 0 0 0 0 0 0 0 0
      bgAt k | k == n = BgReg { brCnt = cBgCnt c, brX = cX c, brY = cY c
                             , brPA = cPA c, brPB = cPB c, brPC = cPC c, brPD = cPD c
                             , brRX = cRX c, brRY = cRY c }
             | otherwise = zero
      es = EngineState
        { esNum = engine
        , esDispCnt = cDispCnt c
        , esBg = V4 (bgAt 0) (bgAt 1) (bgAt 2) (bgAt 3)
        , esBlendCnt = 0, esEva = 0, esEvb = 0, esEvy = 0
        , esObjMosaicLine = 0
        , esBgMosaicLine = cLine c
        , esBgMosaicX = fromIntegral (cMosaic c)
        , esOam = mkMem 0 0x400
        , esVram = mkVram (cPattern c) (cSeed c + (if engine == 1 then 0x4000 else 0))
                          (if engine == 0 then 0x80000 else 0x20000)
        , esObjVram = mkMem 0 0x40000
        , esPalette = mkPal (cSeed c)
        , esBgExtPal = mkMem (cSeed c + 3 + (if engine == 1 then 0x40 else 0)) 0x8000
        , esOamEpoch = 0, esVramEpoch = 0, esPaletteEpoch = 0
        }
      got = renderReferenceLine es (fromIntegral (cLine c))
      conv p = pxRgb p .&. 0xFFFFFF
      want = [ w .&. 0xFFFFFF | w <- cWords c]
      diffs = [ (x, conv g, w) | (x, g, w) <- zip3 [0..] got want, conv g /= w ]
  in if null diffs then []
       else [ "case " ++ show i ++ " kind=" ++ show (cKind c)
              ++ " engine=" ++ show (['A','B'] !! max 0 (min 1 engine))
              ++ " bg=" ++ show n
              ++ " extpal=" ++ show (testBit (cDispCnt c) 30)
              ++ " pattern=" ++ show (cPattern c)
              ++ " mosaic=" ++ show (cMosaic c)
              ++ " line=" ++ show (cLine c)
              ++ " dispcnt=" ++ show (cDispCnt c)
              ++ " bgcnt=" ++ show (cBgCnt c) ++ " x=" ++ show (cX c)
              ++ " y=" ++ show (cY c) ++ " seed=" ++ show (cSeed c)
              ++ " rot=" ++ show (cPA c,cPB c,cPC c,cPD c,cRX c,cRY c)
              ++ ": first mismatch " ++ show (head diffs)
              ++ " (" ++ show (length diffs) ++ "/256 pixels)" ]

main :: IO ()
main = do
  args <- getArgs
  path <- case args of [p] -> pure p; _ -> putStrLn "usage: bg-check <oracle.bin>" >> exitFailure
  cases <- parseFile path
  let results = [ (c, checkCase i c) | (i, c) <- zip [0 :: Int ..] cases ]
      failures = concatMap snd results
      engineOf c = if cEngine c == 0 then "A" else "B"
      tally e = ( length [ () | (c, f) <- results, engineOf c == e, not (null f) ]
                , length [ () | (c, _) <- results, engineOf c == e ] )
      (fa, ta) = tally "A"
      (fb, tb) = tally "B"
  mapM_ putStrLn failures
  putStrLn ("bg-check: " ++ show (length cases) ++ " cases, "
            ++ show (length failures) ++ " mismatches"
            ++ " (engine A " ++ show fa ++ "/" ++ show ta
            ++ ", engine B " ++ show fb ++ "/" ++ show tb ++ ")")
  when (not (null failures)) exitFailure
