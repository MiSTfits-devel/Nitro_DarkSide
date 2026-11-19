{-# LANGUAGE BangPatterns #-}
-- | GPU-owned physical memory and CPU/renderer VRAM views. No melonDS memory
-- pointers or oracle data enter these snapshots. Overlapping banks OR on read
-- and broadcast on write, including the documented CPU aliases and gaps.
module Nds.Gpu.LiveMemory
  ( VramMaps, View(..), emptyMaps, mapBank, bankControl, banksAt
  , lcdcMap, vramStat, textureMaps, texturePaletteMaps, phaseMapBytes, extendedMapBytes
  , readGpuMemory, writeGpuMemory, bankMasks
  ) where

import Data.Array.Unboxed
import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import Data.List (foldl')
import Data.Word
import Nds.Gpu2D.Trace

data View = ABG | AOBJ | BBG | BOBJ | ABGExt | AOBJExt | BBGExt | BOBJExt | Texture | TexPalette | Arm7
  deriving (Eq,Ord,Enum,Bounded,Show)
data VramMaps = VramMaps !(UArray Int Word8) !(UArray (Int,Int) Word32) !Word32
bankMasks :: [Word32]
bankMasks = [0x1ffff,0x1ffff,0x1ffff,0x1ffff,0xffff,0x3fff,0x3fff,0x7fff,0x3fff]
emptyMaps :: VramMaps
emptyMaps = rebuild (listArray (0,8) (replicate 9 0))
bankControl :: VramMaps -> Int -> Word8
bankControl (VramMaps cnt _ _) = (cnt !)

mapBank :: Int -> Word8 -> VramMaps -> Either String VramMaps
mapBank bank value (VramMaps cnt _ _)
  | bank < 0 || bank > 8 = Left "VRAM bank outside A..I"
  | otherwise = Right (rebuild (cnt // [(bank,value .&. masks !! bank)]))
  where masks = [0x9b,0x9b,0x9f,0x9f,0x87,0x9f,0x9f,0x83,0x83]

rebuild :: UArray Int Word8 -> VramMaps
rebuild cnt = VramMaps cnt cells lcdc
  where
    lcdc = foldl' (.|.) 0 [bit b | b <- [0..8], testBit (cnt ! b) 7, cnt ! b .&. 7 == 0]
    cells = accumArray (.|.) 0 ((0,0),(fromEnum (maxBound :: View),31))
      [((fromEnum view,slot),bit b) | b <- [0..8], (view,slot) <- mapping b (cnt ! b)]
    mapping b value
      | not (testBit value 7) = []
      | otherwise = let mode = value .&. 7
                        ofs = fromIntegral ((value `shiftR` 3) .&. 3)
                        range view start n = [(view,i) | i <- [start..start+n-1]]
                        fg = (ofs .&. 1) + ((ofs .&. 2) `shiftL` 1)
                    in case (b,mode) of
                      (_,0) -> []
                      (0,1) -> range ABG (ofs*8) 8
                      (1,1) -> range ABG (ofs*8) 8
                      (0,2) -> range AOBJ ((ofs .&. 1)*8) 8
                      (1,2) -> range AOBJ ((ofs .&. 1)*8) 8
                      (0,3) -> [(Texture,ofs)]
                      (1,3) -> [(Texture,ofs)]
                      (2,1) -> range ABG (ofs*8) 8
                      (3,1) -> range ABG (ofs*8) 8
                      (2,2) -> [(Arm7,ofs .&. 1)]
                      (3,2) -> [(Arm7,ofs .&. 1)]
                      (2,3) -> [(Texture,ofs)]
                      (3,3) -> [(Texture,ofs)]
                      (2,4) -> range BBG 0 8
                      (3,4) -> range BOBJ 0 8
                      (4,1) -> range ABG 0 4
                      (4,2) -> range AOBJ 0 4
                      (4,3) -> range TexPalette 0 4
                      (4,4) -> range ABGExt 0 4
                      (5,1) -> [(ABG,fg),(ABG,fg+2)]
                      (6,1) -> [(ABG,fg),(ABG,fg+2)]
                      (5,2) -> [(AOBJ,fg),(AOBJ,fg+2)]
                      (6,2) -> [(AOBJ,fg),(AOBJ,fg+2)]
                      (5,3) -> [(TexPalette,fg)]
                      (6,3) -> [(TexPalette,fg)]
                      (5,4) -> range ABGExt ((ofs .&. 1)*2) 2
                      (6,4) -> range ABGExt ((ofs .&. 1)*2) 2
                      (5,5) -> [(AOBJExt,0)]
                      (6,5) -> [(AOBJExt,0)]
                      (7,1) -> [(BBG,i) | i <- [0,1,4,5]]
                      (7,2) -> range BBGExt 0 4
                      (8,1) -> [(BBG,i) | i <- [2,3,6,7]]
                      (8,2) -> range BOBJ 0 8
                      (8,3) -> [(BOBJExt,0)]
                      _ -> []

banksAt :: VramMaps -> View -> Int -> Word32
banksAt (VramMaps _ cells _) view slot = cells ! (fromEnum view,slot)
lcdcMap :: VramMaps -> Word32
lcdcMap (VramMaps _ _ m) = m
vramStat :: VramMaps -> Word32
vramStat m = foldl' (.|.) 0 [bit (b-2) | b <- [2,3], bankControl m b .&. 0x87 == 0x82]
textureMaps, texturePaletteMaps :: VramMaps -> [Word32]
textureMaps m = [banksAt m Texture i | i <- [0..3]]
texturePaletteMaps m = [banksAt m TexPalette i | i <- [0..7]]
phaseMapBytes, extendedMapBytes :: VramMaps -> B.ByteString
phaseMapBytes m = packed (concat [[banksAt m v i | i <- [0..n-1]] | (v,n) <- [(ABG,32),(AOBJ,16),(BBG,8),(BOBJ,8)]])
extendedMapBytes m = packed ([banksAt m ABGExt i | i <- [0..3]] ++ [banksAt m AOBJExt 0] ++ [banksAt m BBGExt i | i <- [0..3]] ++ [banksAt m BOBJExt 0])
packed :: [Word32] -> B.ByteString
packed = BL.toStrict . BB.toLazyByteString . foldMap BB.word32LE

-- Selected physical bytes. ARM9 byte writes to all GPU memories are ignored;
-- ARM7's assigned VRAM byte writes are supported. Palette/OAM power gating is
-- architectural, not a renderer-side blanking approximation.
location :: VramMaps -> Word16 -> Int -> Word32 -> Either String [(Int,Int)]
location m power cpu a
  | cpu == 1 = if a `shiftR` 24 == 6 then Right (vram (banksAt m Arm7 (fromIntegral ((a `shiftR` 17) .&. 1)))) else Left "ARM7 access outside GPU-owned VRAM"
  | cpu /= 0 = Left "GPU memory CPU must be ARM9 or ARM7"
  | a `shiftR` 24 == 5 = Right (if enabled then [(0,fromIntegral (a .&. 2047))] else [])
  | a `shiftR` 24 == 7 = Right (if enabled then [(1,fromIntegral (a .&. 2047))] else [])
  | a `shiftR` 24 /= 6 = Left "access outside GPU-owned memory"
  | otherwise = Right $ case a .&. 0x00e00000 of
      0 -> vram (banksAt m ABG (fromIntegral ((a `shiftR` 14) .&. 31)))
      0x200000 -> vram (banksAt m BBG (fromIntegral ((a `shiftR` 14) .&. 7)))
      0x400000 -> vram (banksAt m AOBJ (fromIntegral ((a `shiftR` 14) .&. 15)))
      0x600000 -> vram (banksAt m BOBJ (fromIntegral ((a `shiftR` 14) .&. 7)))
      _ -> case lcdcBank (a .&. 0xfffff) of
        Just b | testBit (lcdcMap m) b -> [(b+2,fromIntegral (a .&. (bankMasks !! b)))]
        _ -> []
  where
    enabled = testBit power (if testBit a 10 then 9 else 1)
    vram mask = [(b+2,fromIntegral (a .&. bm)) | (b,bm) <- zip [0..] bankMasks, testBit mask b]
    lcdcBank x
      | x < 0x80000 = Just (fromIntegral (x `shiftR` 17))
      | x < 0x90000 = Just 4
      | x < 0x94000 = Just 5
      | x < 0x98000 = Just 6
      | x < 0xa0000 = Just 7
      | x < 0xa4000 = Just 8
      | otherwise = Nothing

readGpuMemory :: VramMaps -> Word16 -> TraceMemory -> Int -> Int -> Word32 -> Either String Word32
readGpuMemory maps power memory cpu width address = do
  loc <- location maps power cpu address
  pure (foldl' (.|.) 0 [readRegion8 memory region (offset+i) `asWord` (8*i) | (region,offset) <- loc, i <- [0..width-1]])
  where asWord byte sh = (fromIntegral byte :: Word32) `shiftL` sh

writeGpuMemory :: VramMaps -> Word16 -> TraceMemory -> Int -> Int -> Word32 -> Word32 -> Either String TraceMemory
writeGpuMemory maps power memory cpu width address value
  | cpu == 0 && width == 1 = Right memory
  | otherwise = do
      loc <- location maps power cpu address
      let bytes = B.pack [fromIntegral (value `shiftR` (8*i)) | i <- [0..width-1]]
      foldl' (\acc (region,offset) -> acc >>= \m -> applyDelta m region offset bytes) (Right memory) loc
