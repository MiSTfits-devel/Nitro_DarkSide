{-# LANGUAGE BangPatterns #-}
-- | Live 2D register file and scanline latches. These are CPU-owned inputs
-- and GPU-owned delayed state, not snapshots supplied by another renderer.
module Nds.Gpu.Live2D
  ( Engine(..), initialEngine, engineRead, engineWrite, preDraw, postDraw
  , updateWindows, finishWindows, enginePacket, engineLatch, reg8, reg16, reg32
  ) where

import Data.Array.Unboxed
import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import Data.Int
import Data.Word
import Nds.Gpu2D.Trace (EngineLatch(..))

data Engine = Engine
  { eEnabled :: !Bool, eRegisters :: !(UArray Int Word8), eDispLatch :: ![Word32]
  , eLayer :: !Word8, eObj :: !Word8, eBlank :: !Word8
  , eInternal :: ![Word32], eReload :: ![Word32]
  , eBgY :: !Word8, eBgMax :: !Word8, eObjY :: !Word8
  , eBgLatch :: !Bool, eObjLatch :: !Bool, eBgLine :: !Word32, eObjLine :: !Word32
  , eWin0 :: !Word8, eWin1 :: !Word8
  , eEva :: !Word8, eEvb :: !Word8, eEvy :: !Word8
  } deriving (Eq,Show)

initialEngine :: Engine
initialEngine = Engine False (listArray (0,95) (replicate 96 0)) [0,0,0] 0 0 0
  [0,0,0,0] [0,0,0,0] 0 0 0 True True 0 0 0 0 16 0 0
reg8 :: Engine -> Int -> Word8
reg8 e a = eRegisters e ! a
reg16 :: Engine -> Int -> Word16
reg16 e a = fromIntegral (reg8 e a) .|. (fromIntegral (reg8 e (a+1)) `shiftL` 8)
reg32 :: Engine -> Int -> Word32
reg32 e a = fromIntegral (reg16 e a) .|. (fromIntegral (reg16 e (a+2)) `shiftL` 16)
putReg :: Int -> Int -> Word32 -> Engine -> Engine
putReg a width value e = e { eRegisters = eRegisters e // [(a+i,fromIntegral (value `shiftR` (8*i))) | i <- [0..width-1]] }

engineRead :: Int -> Int -> Engine -> Word32
engineRead width a e
  | width == 4 = engineRead 2 a e .|. (engineRead 2 (a+2) e `shiftL` 16)
  | otherwise = foldr (.|.) 0 [fromIntegral (readByte (a+i)) `shiftL` (8*i) | i <- [0..width-1]]
  where readByte x | x < 4 || (x >= 8 && x < 16) || (x >= 0x48 && x <= 0x4b) || (x >= 0x50 && x <= 0x53) = reg8 e x
                   | otherwise = 0

engineWrite :: Int -> Int -> Int -> Word32 -> Engine -> Engine
engineWrite number width a value e
  | a < 4 = let new = putReg a width value e
            in if number == 1 then putReg 0 4 (reg32 new 0 .&. 0xc0b1fff7) new else new
  | not (eEnabled e) = e
  | width == 4 && a `elem` refs = putReference a 4 (sign28 value) e
  | width == 4 = engineWrite number 2 (a+2) (value `shiftR` 16) (engineWrite number 2 a (value .&. 0xffff) e)
  | width == 2 && a `elem` concat [[r,r+2] | r <- refs] =
      let v = if a .&. 2 /= 0 && testBit value 11 then value .|. 0xf000 else value
      in putReference a 2 v e
  | width == 2 && a >= 0x20 && a < 0x40 = putReg a 2 value e
  | width == 2 && a == 0x50 = putReg a 2 (value .&. 0x3fff) e
  | width == 2 = engineWrite number 1 (a+1) (value `shiftR` 8) (engineWrite number 1 a (value .&. 255) e)
  | (a >= 8 && a < 0x20) || (a >= 0x40 && a <= 0x4d) = putReg a 1 value e
  | a == 0x50 = putReg a 1 value e
  | a == 0x51 = putReg a 1 value e
  | a == 0x52 = (putReg a 1 (value .&. 31) e) { eEva = min 16 (fromIntegral (value .&. 31)) }
  | a == 0x53 = (putReg a 1 (value .&. 31) e) { eEvb = min 16 (fromIntegral (value .&. 31)) }
  | a == 0x54 = (putReg a 1 (value .&. 31) e) { eEvy = min 16 (fromIntegral (value .&. 31)) }
  | otherwise = e
  where
    refs = [0x28,0x2c,0x38,0x3c]
    sign28 v = if testBit v 27 then v .|. 0xf0000000 else v
    putReference at n v old = let updated = putReg at n v old
                            in updated { eReload = [if r == at .&. complement 3 then reg32 updated r else oldValue | (r,oldValue) <- zip refs (eReload old)] }

preDraw :: Word16 -> Bool -> Engine -> Engine
preDraw vcount reset e
  | not (eEnabled e) = e
  | otherwise = e { eDispLatch = latches
                  , eLayer = fromIntegral (((latches !! 2 .&. disp) `shiftR` 8) .&. 31)
                  , eObj = fromIntegral (((latches !! 1 .&. disp) `shiftR` 12) .&. 1)
                  , eBlank = fromIntegral (((latches !! 2 .|. disp) `shiftR` 7) .&. 1)
                  , eInternal = concat [if not (testBit (reg16 e (12+2*i)) 6) || eBgLatch e then [reg32 e (0x28+i*16),reg32 e (0x2c+i*16)] else take 2 (drop (i*2) (eInternal e)) | i <- [0,1]]
                  , eBgLine = if eBgLatch e then fromIntegral vcount else eBgLine e
                  , eObjY = objY, eObjLatch = objLatch
                  , eObjLine = if objLatch then if reset then 0 else fromIntegral vcount+1 else eObjLine e }
  where
    disp = reg32 e 0
    latches = disp : take 2 (eDispLatch e)
    enabled = testBit disp 12
    objLatch = if enabled then reset || eObjY e == reg8 e 0x4d `shiftR` 4 else eObjLatch e
    objY = if not enabled then eObjY e else if objLatch then 0 else (eObjY e+1) .&. 15

postDraw :: Bool -> Engine -> Engine
postDraw reset e
  | not (eEnabled e) = e
  | otherwise = updated { eBgY = y, eBgMax = maximumY, eBgLatch = latch }
  where
    latch = reset || eBgY e == eBgMax e
    y = if latch then 0 else (eBgY e+1) .&. 15
    maximumY = if latch then reg8 e 0x4c `shiftR` 4 else eBgMax e
    updated = foldl update e [0,1]
    update old i
      | not (testBit (eLayer e) (2+i)) = old
      | reset = putReg (0x2c+i*16) 4 (eReload e !! (i*2+1)) (putReg (0x28+i*16) 4 (eReload e !! (i*2)) old)
      | otherwise = let dx = fromIntegral (fromIntegral (reg16 e (0x22+i*16)) :: Int16)
                        dy = fromIntegral (fromIntegral (reg16 e (0x26+i*16)) :: Int16)
                    in putReg (0x2c+i*16) 4 (reg32 e (0x2c+i*16)+dy) (putReg (0x28+i*16) 4 (reg32 e (0x28+i*16)+dx) old)

updateWindows :: Word16 -> Engine -> Engine
updateWindows y e
  | not (eEnabled e) = e
  | otherwise = e { eWin0 = one (eWin0 e) 0x44, eWin1 = one (eWin1 e) 0x46 }
  where
    one active a | fromIntegral (y .&. 255) == reg8 e a = clearBit active 0
                 | fromIntegral (y .&. 255) == reg8 e (a+1) = setBit active 0
                 | otherwise = active

finishWindows :: Engine -> Engine
finishWindows e = e { eWin0 = one 13 0x40 (eWin0 e), eWin1 = one 14 0x42 (eWin1 e) }
  where one enable a active | not (testBit (reg32 e 0) enable) = active
                             | reg8 e (a+1) > reg8 e a = setBit active 1
                             | otherwise = clearBit active 1

engineLatch :: Engine -> EngineLatch
engineLatch e = EngineLatch (internal 0) (internal 2) (internal 1) (internal 3)
  (eBgY e) (eBgMax e) (eObjY e) (fromIntegral (fromEnum (eBgLatch e)) .|. (fromIntegral (fromEnum (eObjLatch e)) `shiftL` 1)) (eBgLine e) (eObjLine e)
  where internal i = eInternal e !! i

enginePacket :: Engine -> B.ByteString
enginePacket e = BL.toStrict . BB.toLazyByteString $
  BB.word32LE (reg32 e 0) <> foldMap BB.word8 [eLayer e,eObj e,eBlank e,0] <>
  half [8,10,12,14] <> half [16,20,24,28] <> half [18,22,26,30] <>
  word [0x28,0x38] <> word [0x2c,0x3c] <>
  half [0x20,0x30] <> half [0x22,0x32] <> half [0x24,0x34] <> half [0x26,0x36] <>
  bytes [0x41,0x40,0x45,0x44,0x43,0x42,0x47,0x46,0x48,0x49,0x4a,0x4b] <>
  foldMap BB.word8 [eWin0 e,eWin1 e,reg8 e 0x4c .&. 15,reg8 e 0x4c `shiftR` 4,reg8 e 0x4d .&. 15,reg8 e 0x4d `shiftR` 4] <>
  BB.word16LE (reg16 e 0x50) <> BB.word16LE (reg16 e 0x52) <>
  foldMap BB.word8 [eEva e,eEvb e,eEvy e,0]
  where half = foldMap (BB.word16LE . reg16 e)
        word = foldMap (BB.word32LE . reg32 e)
        bytes = foldMap (BB.word8 . reg8 e)
