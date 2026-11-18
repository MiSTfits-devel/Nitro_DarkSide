{-# LANGUAGE DataKinds #-}

-- | Clash-simulation gate for the pipelined pixel back end.
--
-- Runs the real 'shadePipe' machine against a behavioural texture/palette
-- memory with registered (one-cycle) read ports, and compares every pixel it
-- writes, in order, with 'pixelWithMemory' (which the frame gate ties to
-- melonDS). Each run first writes the toon table through its port, then
-- streams random pixels over every texture format, blend mode, polygon alpha,
-- ID and attribute bit, with bubbles. The second run stalls the whole
-- pipeline, memories included, one cycle in four.
module Main (main) where

import Control.Monad (when)
import Data.Array.Unboxed (UArray, listArray, (!))
import Data.Bits (shiftL, shiftR, xor, (.&.), (.|.))
import Data.Int (Int16, Int32)
import Data.List (unfoldr)
import Data.Word (Word16, Word32, Word64)
import System.Environment (getArgs)
import System.Exit (exitFailure)

import Clash.Explicit.Prelude (Unsigned, bundle, register, sampleN)
import Clash.Explicit.Signal (fromList, systemClockGen, systemResetGen, toEnable)

import Nds.Gpu3D.ShadePipe
import Nds.Gpu3D.Texture (TexMem (..))

main :: IO ()
main = do
  args <- getArgs
  let pixels = case args of
        [n] -> read n
        _ -> 20000
  (n1, w1) <- run 1 pixels False
  (n2, w2) <- run 2 pixels True
  putStrLn ("shade-pipe-check: 2 runs, " ++ show (n1 + n2) ++ " pixels compared ("
            ++ show (w1 + w2) ++ " writes), 0 failures")

-- | xorshift64 stream.
rng :: Word64 -> [Word32]
rng = unfoldr (\x0 -> let x1 = x0 `xor` (x0 `shiftL` 13)
                          x2 = x1 `xor` (x1 `shiftR` 7)
                          x3 = x2 `xor` (x2 `shiftL` 17)
                      in Just (fromIntegral (x3 `shiftR` 16), x3))

run :: Word64 -> Int -> Bool -> IO (Int, Int)
run seed pixels stall = do
  let rs0 = rng (0x9E3779B97F4A7C15 * seed)
      (memWords, rs1) = splitAt (0x28000 :: Int) rs0
      img = listArray (0, 0x27FFF) memWords :: UArray Int Word32
      mem = TexMem
        (\a -> let w = img ! fromIntegral ((a .&. 0x7FFFC) `div` 4)
               in fromIntegral (if a .&. 2 /= 0 then w `shiftR` 16 else w))
        (\a -> img ! fromIntegral (0x20000 + (a .&. 0x1FFFC) `div` 4))
      cfg = ShadeCfg ((rs1 !! 0) .&. 0xB) ((rs1 !! 1) `mod` 32)
      (toonWords, rs3) = splitAt 32 (drop 2 rs1)
      toonTab = listArray (0, 31) (map (fromIntegral . (.&. 0x7FFF)) toonWords) :: UArray Int Word16
      ins = take pixels (pixelStream rs3)
      expected = map (pixelWithMemory mem cfg (\i -> toonTab ! fromIntegral i)) ins
      -- Cycle 0 is reset; then 32 toon writes; then the stream.
      enables = True : replicate 32 True
                ++ (if stall then cycle [True, True, False, True] else repeat True)
      toonWrites = Nothing : [Just (fromIntegral i, toonTab ! i) | i <- [0 .. 31]] ++ repeat Nothing
      bubbled = concat [ Just p : [Nothing | k `mod` 13 == 12] | (k, p) <- zip [0 :: Int ..] ins ]
      stream = Nothing : replicate 32 Nothing ++ present bubbled (drop 33 enables)
      cycles = 40 + 2 * length stream
      clk = systemClockGen
      rst = systemResetGen
      en = toEnable (fromList (enables ++ repeat True))
      (texA, infoA, palA, out) =
        shadePipe clk rst en (pure cfg) (fromList toonWrites)
          (fromList (stream ++ repeat Nothing)) texD infoD palD
      texD = register clk rst en 0 (tmTexHalf mem <$> texA)
      infoD = register clk rst en 0 (tmTexHalf mem <$> infoA)
      palD = register clk rst en 0 (tmPalWord mem <$> palA)
      outs = sampleN cycles (bundle (out, fromList (enables ++ repeat True)))
      got = [o | (Just o, True) <- outs]
  when (length got /= length expected) $ do
    putStrLn ("FAIL run " ++ show seed ++ ": " ++ show (length got) ++ " outputs, expected "
              ++ show (length expected))
    exitFailure
  let bad = [(i, e, g) | (i, e, g) <- zip3 [0 :: Int ..] expected got, e /= g]
  case bad of
    [] -> pure (length got, length [() | o <- got, poWrite o /= Nothing])
    ((i, e, g) : _) -> do
      putStrLn ("FAIL run " ++ show seed ++ " pixel " ++ show i ++ ": input "
                ++ show (ins !! i) ++ "\n  want " ++ show e ++ "\n  got  " ++ show g)
      exitFailure

-- | Present each item, a pixel or a bubble, until an enabled cycle takes it.
present :: [Maybe PixelIn] -> [Bool] -> [Maybe PixelIn]
present [] _ = []
present ps [] = ps
present (p : ps) (e : es)
  | e = p : present ps es
  | otherwise = p : present (p : ps) es

pixelStream :: [Word32] -> [PixelIn]
pixelStream (a : b : c : d : e : f : g : h : i : j : rest) =
  let fmt = a `mod` 8
      texparam = (b .&. 0x3FFFFFF) .|. (fmt `shiftL` 26) .|. ((c .&. 0x7) `shiftL` 29)
      alpha = case d `mod` 8 of
        0 -> 0
        1 -> 31
        2 -> 31
        _ -> (d `shiftR` 3) `mod` 32
      ids = [0, 1, 7, 63]
      pid = ids !! fromIntegral ((d `shiftR` 8) `mod` 4)
      attr = (alpha `shiftL` 16) .|. (pid `shiftL` 24) .|. (((d `shiftR` 10) .&. 3) `shiftL` 4)
               .|. (d .&. 0x0000C800)
      v k = fromIntegral ((e `shiftR` k) .&. 0x3F)
      dstA = (f .&. 0x3F7F9F1F)
      dstC = (g .&. 0x1F3F3F3F)
      px = PixelIn texparam (h .&. 0x1FFF) attr (odd (c `shiftR` 3)) (v 0, v 8, v 16)
             (fromIntegral (i .&. 0xFFFF) :: Int16) (fromIntegral (i `shiftR` 16) :: Int16)
             ((j `shiftR` 4) .&. 0xF) dstC dstA (fromIntegral (j .&. 0xFFFFFF) :: Int32)
             (fromIntegral (j `shiftR` 24) :: Unsigned 8)
  in px : pixelStream rest
pixelStream _ = []
