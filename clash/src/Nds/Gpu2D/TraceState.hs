-- | Decode the existing scanline fields and the banked VRAM view from a
-- trace phase.  Reads remain backed by that immutable phase's memory pages.
-- Sprite rendering must use the SpritePhase snapshot, not the ScanlinePhase.
module Nds.Gpu2D.TraceState
  ( phaseEngine, phaseBGRead, phaseOBJRead, phaseOAMRead, phaseOBJExtRead, phaseWindowMasks ) where

import Data.Bits ((.&.), (.|.), complement, shiftL, testBit, clearBit, setBit)
import Data.List (mapAccumL)
import Data.Word (Word8, Word32)
import Nds.Gpu2D.Trace
import Nds.Gpu2D.Types

phaseBGRead :: Phase -> Int -> Word32 -> Word8
phaseBGRead p n = memoryRead (phaseBGMemory p n)

phaseOBJRead :: Phase -> Int -> Word32 -> Word8
phaseOBJRead p n = memoryRead (phaseOBJMemory p n)

phaseOAMRead :: Phase -> Int -> Word32 -> Word8
phaseOAMRead p n = memoryRead (phaseOAMMemory p n)

-- Map bits are physical bank indices (A=0); trace regions 0/1 are palette/OAM.
phaseOBJExtRead :: Phase -> Int -> Word32 -> Word8
phaseOBJExtRead p n addr =
  let ExtendedPaletteMap mappings = phaseExtendedPaletteMap p
      mapping = word32At mappings (if n == 0 then 16 else 36)
      bank b = if testBit mapping b then readRegion8 (phaseMemory p) (b+2) (fromIntegral (addr .&. 0x1fff)) else 0
  in if n == 0 then bank 5 .|. bank 6 else bank 8

-- | Resolve the latched vertical/horizontal window state in the same order as
-- CalculateWindowMask. OBJ window is produced at the prior sprite phase.
phaseWindowMasks :: Phase -> Int -> [Bool] -> [Word8]
phaseWindowMasks p n obj
  | length obj /= 256 = error "phaseWindowMasks: OBJ window must have 256 pixels"
  | control .&. 0xe000 == 0 = replicate 256 0xff
  | otherwise = snd (mapAccumL pixel (word8At r (e+76), word8At r (e+77)) (zip [0..255] obj))
  where
    r = phaseRegisters p
    e = 292 + 90*n
    control = word32At r e
    update active x begin end
      | x == fromIntegral end = clearBit active 1
      | x == fromIntegral begin = setBit active 1
      | otherwise = active
    pixel (a0,a1) (x, objHit) =
      let b0 = if testBit control 13 then update a0 x (word8At r (e+64)) (word8At r (e+65)) else a0
          b1 = if testBit control 14 then update a1 x (word8At r (e+68)) (word8At r (e+69)) else a1
          mask | testBit control 13 && b0 == 3 = word8At r (e+72)
               | testBit control 14 && b1 == 3 = word8At r (e+73)
               | testBit control 15 && objHit = word8At r (e+75)
               | otherwise = word8At r (e+74)
      in ((b0,b1),mask)

-- | Convert the fields used by the current line model. Cache epochs are not
-- derived here: trace snapshots are content snapshots, not caller-supplied
-- revision tokens, and must not be fed to the old TARDIS cache.
phaseEngine :: Phase -> Int -> EngineState
phaseEngine p n
  | n /= 0 && n /= 1 = error "phaseEngine: invalid engine"
  | otherwise = EngineState
      { esNum = n, esDispCnt = disp, esBg = V4 (bg 0) (bg 1) (bg 2) (bg 3)
      , esBlendCnt = fromIntegral (word16At r (e+82))
      , esEva = fromIntegral (word8At r (e+86)), esEvb = fromIntegral (word8At r (e+87))
      , esEvy = fromIntegral (word8At r (e+88))
      , esBgMosaicX = word8At r (e+78)
      , esObjMosaicLine = latchOBJMosaicLine l, esBgMosaicLine = latchBGMosaicLine l
      , esOam = phaseOAMMemory p n
      , esVram = phaseBGMemory p n
      , esObjVram = phaseOBJMemory p n
      , esBgExtPal = phaseBGExtMemory p n
      , esPalette = phasePaletteMemory p
      , esOamEpoch = 0, esVramEpoch = 0, esPaletteEpoch = 0
      }
  where
    r = phaseRegisters p
    e = 292 + 90*n
    Latch a b = phaseLatch p
    l = if n == 0 then a else b
    -- LayerEnable is the delayed renderer latch, not the raw DISPCNT bits.
    disp = (word32At r e .&. complement 0x1f00) .|. (fromIntegral (word8At r (e+4) .&. 31) `shiftL` 8)
    bg i = BgReg (word16At r (e+8+2*i)) (word16At r (e+16+2*i)) (word16At r (e+24+2*i))
      (rot 48 i) (rot 52 i) (rot 56 i) (rot 60 i)
      (if i == 2 then fromIntegral (latchX2 l) else if i == 3 then fromIntegral (latchX3 l) else 0)
      (if i == 2 then fromIntegral (latchY2 l) else if i == 3 then fromIntegral (latchY3 l) else 0)
    rot off i = if i < 2 then 0 else fromIntegral (word16At r (e+off+2*(i-2)))
