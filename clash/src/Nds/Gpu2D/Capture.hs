{-# LANGUAGE RecordWildCards #-}

-- | Standalone display-capture unit, transcribed from melonDS
-- @SoftRenderer::DoCapture@ (GPU_Soft.cpp) and the capture block lifecycle
-- in @GPU::CheckCaptureStart@ / @CheckCaptureEnd@ (GPU.cpp).
--
-- Inputs are explicit immutable views: a VRAM read function (bank A-D, word
-- index), both source-A lines, the display FIFO and the register words. The
-- unit returns every VRAM write in issue order plus capture flags. It never
-- reads an oracle framebuffer. Writes are overlaid on the read view before a
-- later source-B read, so a capture whose destination overlaps source B sees
-- the earlier writes in pixel order.
module Nds.Gpu2D.Capture
  ( CaptureState (..)
  , emptyCaptureState
  , CaptureInput (..)
  , CaptureOutput (..)
  , captureStart
  , captureEnd
  , captureLine
  ) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import qualified Data.IntMap.Strict as IM
import Data.Word (Word16, Word32)

data CaptureState = CaptureState
  { csActive :: !Bool
  , csFlags  :: ![Word16] -- 16 entries, bank-major, block-minor
  } deriving (Eq, Show)

emptyCaptureState :: CaptureState
emptyCaptureState = CaptureState False (replicate 16 0)

data CaptureInput = CaptureInput
  { ciState       :: !CaptureState
  , ciCaptureCnt  :: !Word32
  , ciLine        :: !Word32
  , ciVramMapLCDC :: !Word32
  , ciDispCntA    :: !Word32
  , ciSrc2D       :: ![Word32]   -- Output2D[0], 256 pixels
  , ciSrc3D       :: ![Word32]   -- Output3D, 256 pixels
  , ciSrcBFifo    :: ![Word16]   -- GPU.DispFIFOBuffer, 256
  , ciVramRead    :: Int -> Word32 -> Word16
  }

data CaptureOutput = CaptureOutput
  { coWrites      :: ![(Int, Word32, Word16)] -- bank, word index, value
  , coDirtyBlocks :: ![(Int, Word32)]
  , coState       :: !CaptureState
  , coActive      :: !Bool
  , coWidth       :: !Word32
  , coHeight      :: !Word32
  , coValid       :: !Bool
  } deriving (Eq, Show)

isCapture, complete :: Word16
isCapture = 1 `shiftL` 15
complete = 1 `shiftL` 14

emptyOut :: CaptureState -> CaptureOutput
emptyOut s = CaptureOutput [] [] s (csActive s) 0 0 False

replaceAt :: Int -> a -> [a] -> [a]
replaceAt i v xs = take i xs ++ [v] ++ drop (i + 1) xs

captureStart :: CaptureState -> Word32 -> Word32 -> CaptureState
captureStart s captureCnt lcdcMap
  | lcdcMap .&. (1 `shiftL` fromIntegral dstbank) == 0 = s
  | otherwise = s { csActive = True, csFlags = setBlocks cleared dstoff len newval }
  where
    dstbank = (captureCnt `shiftR` 16) .&. 0x3
    dstoff = (captureCnt `shiftR` 18) .&. 0x3
    size = (captureCnt `shiftR` 20) .&. 0x3
    len = if size == 0 then 1 else size
    base = fromIntegral dstbank * 4
    at b = base + fromIntegral ((dstoff + b) .&. 0x3)
    cleared = foldl clearOne (csFlags s) [0 .. len - 1]
    clearOne fs b =
      let i = at b
          fl = fs !! i
      in if fl .&. isCapture == 0
           then fs
           else
             let oldstart = fl .&. 0x3
                 oldsize = (fl `shiftR` 6) .&. 0x3
             in if fromIntegral oldstart == dstoff && fromIntegral oldsize == size
                  then fs
                  else setBlocks fs oldstart (if oldsize == 0 then 1 else oldsize) 0
    newval = isCapture .|. fromIntegral dstoff .|. (fromIntegral dstbank `shiftL` 2)
             .|. (fromIntegral len `shiftL` 4) .|. (fromIntegral size `shiftL` 6)
    setBlocks fs start n v =
      foldl (\a b -> replaceAt (base + fromIntegral ((start + b) .&. 0x3)) v a)
            fs [0 .. n - 1]

captureEnd :: CaptureState -> Word32 -> CaptureState
captureEnd s captureCnt =
  let dstbank = (captureCnt `shiftR` 16) .&. 0x3
      dstoff = (captureCnt `shiftR` 18) .&. 0x3
      size = (captureCnt `shiftR` 20) .&. 0x3
      i = fromIntegral dstbank * 4 + fromIntegral dstoff
      fl = csFlags s !! i
      oldstart = fl .&. 0x3
      oldsize = (fl `shiftR` 6) .&. 0x3
  in if fl .&. isCapture == 0 || fromIntegral oldstart /= dstoff
                              || fromIntegral oldsize /= size
       then s { csActive = False }
       else s { csActive = False
              , csFlags = completeBlocks (csFlags s) (fromIntegral dstbank * 4) dstoff
                           (fromIntegral ((fl `shiftR` 4) .&. 0x3)) }
  where
    completeBlocks fs base start len =
      foldl (\a i -> let j = base + fromIntegral ((start + i) .&. 0x3)
                     in replaceAt j (a !! j .|. complete) a)
            fs [0 .. len - 1]

captureLine :: CaptureInput -> CaptureOutput
captureLine ci@CaptureInput{..} =
  let captureCnt = ciCaptureCnt
      sz = (captureCnt `shiftR` 20) .&. 0x3
      width :: Int
      width = if sz == 0 then 128 else 256
      height :: Int
      height = if sz == 0 then 128 else fromIntegral (64 * sz)
  in if ciLine >= fromIntegral height
       then emptyOut ciState
       else
         let dstbank = fromIntegral ((captureCnt `shiftR` 16) .&. 0x3) :: Int
             mapped = ciVramMapLCDC .&. (1 `shiftL` fromIntegral dstbank) /= 0
             dstaddr0 = ((((captureCnt `shiftR` 18) .&. 0x3) `shiftL` 14)
                         + ciLine * fromIntegral width) .&. 0xFFFF
             srcB
               | captureCnt .&. (1 `shiftL` 25) /= 0 = Left (take 256 (ciSrcBFifo ++ repeat 0))
               | otherwise =
                   let srcvram = (ciDispCntA `shiftR` 18) .&. 0x3
                   in if ciVramMapLCDC .&. (1 `shiftL` fromIntegral srcvram) == 0
                        then Right Nothing
                        else
                          let offset = ciLine * 256
                                       + if ((ciDispCntA `shiftR` 16) .&. 0x3) /= 2
                                           then ((captureCnt `shiftR` 26) .&. 0x3) `shiftL` 14
                                           else 0
                          in Right (Just (fromIntegral srcvram, offset .&. 0xFFFF))
             mode = (captureCnt `shiftR` 29) .&. 0x3
             eva = min 16 (captureCnt .&. 0x1F)
             evb = min 16 ((captureCnt `shiftR` 8) .&. 0x1F)
             srcA = if captureCnt .&. (1 `shiftL` 24) /= 0 then ciSrc3D else ciSrc2D
             -- Overlay of writes issued earlier in this line, per bank.
             step (ov, ws) i =
               let addr = (dstaddr0 + fromIntegral i) .&. 0xFFFF
                   readBank b idx =
                     IM.findWithDefault (ciVramRead b idx) (fromIntegral idx)
                       (IM.findWithDefault IM.empty b ov)
                   va = fromIntegral (indexDef srcA i 0)
                   vb :: Word32
                   vb = case srcB of
                          Left fifo -> fromIntegral (indexDef fifo i 0)
                          Right Nothing -> 0
                          Right (Just (b, off)) -> fromIntegral (readBank b ((off + fromIntegral i) .&. 0xFFFF))
                   hasB = case srcB of Left _ -> True; Right (Just _) -> True; Right Nothing -> False
                   val = case mode of
                     0 -> packA va
                     1 -> fromIntegral vb
                     _ -> if hasB then blend va vb eva evb else packAWithEvA va eva
                   ov'
                     | mapped = IM.insert dstbank
                         (IM.insert (fromIntegral addr) val (IM.findWithDefault IM.empty dstbank ov)) ov
                     | otherwise = ov
                   ws' = if mapped then (dstbank, fromIntegral addr, val) : ws else ws
               in (ov', ws')
             (_, revWrites) = foldl step (IM.empty, []) [0 .. width - 1]
             dirty = if mapped
                       then [(dstbank, fromIntegral (((dstaddr0 * 2) `div` 512) .&. 3))]
                       else []
         in CaptureOutput (reverse revWrites) dirty ciState True
              (fromIntegral width) (fromIntegral height) mapped
  where
    packA :: Word32 -> Word16
    packA v =
      let r=(v `shiftR` 1) .&. 0x1F; g=(v `shiftR` 9) .&. 0x1F
          b=(v `shiftR` 17) .&. 0x1F; a=if (v `shiftR` 24) /= 0 then 0x8000 else 0
      in fromIntegral (r .|. (g `shiftL` 5) .|. (b `shiftL` 10) .|. a)
    packAWithEvA :: Word32 -> Word32 -> Word16
    packAWithEvA v eva =
      let r=(v `shiftR` 1) .&. 0x1F; g=(v `shiftR` 9) .&. 0x1F; b=(v `shiftR` 17) .&. 0x1F
          a=if (v `shiftR` 24) /= 0 then 1 else 0
          rD=min 0x1F (((r*a*eva)+8) `shiftR` 4)
          gD=min 0x1F (((g*a*eva)+8) `shiftR` 4)
          bD=min 0x1F (((b*a*eva)+8) `shiftR` 4)
          aD=if eva>0 then a else 0
      in fromIntegral (rD .|. (gD `shiftL` 5) .|. (bD `shiftL` 10) .|. (aD `shiftL` 15))
    blend :: Word32 -> Word32 -> Word32 -> Word32 -> Word16
    blend va vb eva evb =
      let rA=(va `shiftR` 1) .&. 0x1F; gA=(va `shiftR` 9) .&. 0x1F; bA=(va `shiftR` 17) .&. 0x1F
          aA=if (va `shiftR` 24) /= 0 then 1 else 0
          rB=vb .&. 0x1F; gB=(vb `shiftR` 5) .&. 0x1F; bB=(vb `shiftR` 10) .&. 0x1F; aB=vb `shiftR` 15
          rD=min 0x1F (((rA*aA*eva)+(rB*aB*evb)+8) `shiftR` 4)
          gD=min 0x1F (((gA*aA*eva)+(gB*aB*evb)+8) `shiftR` 4)
          bD=min 0x1F (((bA*aA*eva)+(bB*aB*evb)+8) `shiftR` 4)
          aD=(if eva>0 then aA else 0) .|. (if evb>0 then aB else 0)
      in fromIntegral (rD .|. (gD `shiftL` 5) .|. (bD `shiftL` 10) .|. (aD `shiftL` 15))
    indexDef xs i d = if i < length xs then xs !! i else d
