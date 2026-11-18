{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}

-- | Shared types for the Clash 2D engine.
--
-- The field order and packing follow the production melonDS
-- @GPU2D_Soft.cpp@ renderer. A line is 256 pixels; a pixel carries its
-- 24-bit colour in the low bits exactly like the reference line word, and its
-- layer flag in bits 24..31 (BG0..3 = bits 0..3, OBJ = bit 7, 3D = bit 6).
-- Memory is an abstract byte address space so the model does not depend on a
-- concrete VRAM size; the caller supplies the mask and the backing bytes.
module Nds.Gpu2D.Types
  ( V4 (..)
  , v4Index
  , Memory (Memory)
  , memoryMask, memoryRead, memoryRead8, memoryRead16, memoryRead16Masked
  , uarrayMemory, phaseBGMemory, phaseOBJMemory, phaseOAMMemory
  , phasePaletteMemory, phaseBGExtMemory
  , BgReg (..)
  , EngineState (..)
  , Layer (..)
  , layerFlag
  , LayerPixel (..)
  , Pixel (..)
  , LineKey (..)
  , LineKeyTokens (..)
  , noLineKeyTokens
  , lineKey
  , lineKeyWith
  , lineKeyTok
  , bgPriorityMask
  , bgEnable
  , objEnable
  , dispMode
  ) where

import Data.Array.Unboxed (UArray, bounds, (!))
import qualified Data.ByteString as B
import Data.Bits ((.&.), (.|.), shiftL, shiftR, testBit)
import Data.Int (Int32, Int16)
import Data.Word (Word8, Word16, Word32)
import GHC.Generics (Generic)
import Nds.Gpu2D.Trace (Phase(..), TraceMemory, ExtendedPaletteMap(..), readRegion8, word32At)


-- | Four fixed fields, used for the four background layers.
data V4 a = V4 !a !a !a !a
  deriving (Eq, Show, Generic)

v4Index :: V4 a -> Int -> a
v4Index (V4 a _ _ _) 0 = a
v4Index (V4 _ b _ _) 1 = b
v4Index (V4 _ _ c _) 2 = c
v4Index (V4 _ _ _ d) _ = d

-- | Arbitrary callbacks remain usable by the renderer but are not cacheable.
-- Cacheable views are constructed only from immutable array/trace snapshots;
-- no caller-supplied epoch can assert equality of unrelated bytes.
data Memory = Memory !Word32 !(Word32 -> Word8)
            | ArrayMemory !(UArray Word32 Word8)
            | TraceViewMemory !TraceMemory !TraceView

data TraceView = BgView !Int !B.ByteString | ObjView !Int !B.ByteString
               | OamView !Int | PaletteView | BgExtView !Int !B.ByteString
  deriving (Eq, Show)

data MemoryKey = ArrayKey !(UArray Word32 Word8) | TraceViewKey !TraceMemory !TraceView
  deriving (Eq, Show)

memoryKey :: Memory -> Maybe MemoryKey
memoryKey (Memory _ _) = Nothing
memoryKey (ArrayMemory a) = Just (ArrayKey a)
memoryKey (TraceViewMemory m view) = Just (TraceViewKey m view)

memoryMask :: Memory -> Word32
memoryMask (Memory mask _) = mask
memoryMask (ArrayMemory a) = snd (bounds a)
memoryMask (TraceViewMemory _ view) = case view of
  BgView 0 _ -> 0x7ffff
  BgView _ _ -> 0x1ffff
  ObjView 0 _ -> 0x3ffff
  ObjView _ _ -> 0x1ffff
  OamView _ -> 0x3ff
  PaletteView -> 0x7ff
  BgExtView _ _ -> 0x7fff

memoryRead :: Memory -> Word32 -> Word8
memoryRead (Memory _ readByte) = readByte
memoryRead (ArrayMemory bytes) = (bytes !)
memoryRead (TraceViewMemory memory view) = readView memory view

readView :: TraceMemory -> TraceView -> Word32 -> Word8
readView memory view addr = case view of
  OamView n -> readRegion8 memory 1 (n*1024 + fromIntegral (addr .&. 1023))
  PaletteView -> readRegion8 memory 0 (fromIntegral (addr .&. 2047))
  BgView n mappings -> mapped mappings (if n == 0 then 32 else 8) banks addr
  ObjView n mappings -> mapped mappings (if n == 0 then 16 else 8) banks addr
  BgExtView n mappings ->
    let slot = fromIntegral ((addr `shiftR` 13) .&. 3)
        selected = word32At mappings (slot*4)
        available = if n == 0 then [(4,0x7fff),(5,0x3fff),(6,0x3fff)] else [(7,0x7fff)]
    in readBanks selected available addr
  where
    banks = zip [0..] [0x1ffff,0x1ffff,0x1ffff,0x1ffff,0xffff,0x3fff,0x3fff,0x7fff,0x3fff]
    mapped mappings slots available a =
      let selected = word32At mappings (fromIntegral ((a `shiftR` 14) .&. (slots-1))*4)
      in readBanks selected available a
    readBanks selected available a = foldl readBank 0 available
      where
        readBank result (bank,mask)
          | testBit selected bank = result .|. readRegion8 memory (bank+2) (fromIntegral (a .&. mask))
          | otherwise = result

phaseBGMemory, phaseOBJMemory, phaseOAMMemory, phaseBGExtMemory :: Phase -> Int -> Memory
phaseBGMemory p n = TraceViewMemory (phaseMemory p) (BgView n (B.take size (B.drop offset (phaseRegisters p))))
  where (offset,size) = if n == 0 then (28,128) else (220,32)
phaseOBJMemory p n = TraceViewMemory (phaseMemory p) (ObjView n (B.take size (B.drop offset (phaseRegisters p))))
  where (offset,size) = if n == 0 then (156,64) else (252,32)
phaseOAMMemory p n = TraceViewMemory (phaseMemory p) (OamView n)
phaseBGExtMemory p n = TraceViewMemory (phaseMemory p) (BgExtView n (B.take 16 (B.drop offset mappings)))
  where ExtendedPaletteMap mappings = phaseExtendedPaletteMap p
        offset = if n == 0 then 0 else 20
phasePaletteMemory :: Phase -> Memory
phasePaletteMemory p = TraceViewMemory (phaseMemory p) PaletteView

-- | Unmasked read, used exactly where the reference indexes its pointer
-- without re-masking. Tests keep addresses inside the backing store.
memoryRead8 :: Memory -> Word32 -> Word8
memoryRead8 = memoryRead

memoryRead16 :: Memory -> Word32 -> Word16
memoryRead16 m a =
  let lo = fromIntegral (memoryRead8 m a) :: Word16
      hi = fromIntegral (memoryRead8 m (a + 1)) :: Word16
  in lo .|. (hi `shiftL` 8)

memoryRead16Masked :: Memory -> Word32 -> Word16
memoryRead16Masked m a = memoryRead16 m (a .&. memoryMask m)

uarrayMemory :: UArray Word32 Word8 -> Memory
uarrayMemory = ArrayMemory

-- | One background register set: BGCNT, H/V scroll and, for BG2/BG3, the
-- affine matrix and internal reference point.
data BgReg = BgReg
  { brCnt :: !Word16
  , brX   :: !Word16
  , brY   :: !Word16
  , brPA  :: !Int16
  , brPB  :: !Int16
  , brPC  :: !Int16
  , brPD  :: !Int16
  , brRX  :: !Int32
  , brRY  :: !Int32
  } deriving (Eq, Show, Generic)

-- | The whole visible state of one engine for one frame. Epochs are the
-- model's coherency tokens: any value change bumps its epoch, so a line key
-- can tell whether a cached line is still exact.
data EngineState = EngineState
  { esNum          :: !Int
  , esDispCnt      :: !Word32
  , esBg           :: !(V4 BgReg)
  , esBlendCnt     :: !Word32
  , esEva          :: !Word32
  , esEvb          :: !Word32
  , esEvy          :: !Word32
  , esObjMosaicLine :: !Word32
  , esBgMosaicLine :: !Word32
  , esBgMosaicX    :: !Word8
  , esOam          :: !Memory
  , esVram         :: !Memory
  , esObjVram      :: !Memory
  , esPalette      :: !Memory
  , esBgExtPal     :: !Memory
  , esOamEpoch     :: !Word32
  , esVramEpoch    :: !Word32
  , esPaletteEpoch :: !Word32
  } deriving (Generic)

-- | One layer in the composition order.
data Layer = Bg !Int | LObj | L3D | LBackdrop
  deriving (Eq, Ord, Show, Generic)

-- | The reference flag byte placed in bits 24..31 of a line word.
layerFlag :: Layer -> Word32
layerFlag LObj = 0x00000080
layerFlag L3D = 0x00000040
layerFlag LBackdrop = 0x00000020
layerFlag (Bg n) = 1 `shiftL` n

-- | One layer's contribution at a pixel. @lpAlpha@ is only meaningful for
-- semi-transparent OBJ pixels; @lpPrio@ is the layer priority (0..3).
data LayerPixel = LayerPixel
  { lpRgb   :: !Word32   -- ^ 24-bit red 0..7, green 8..15, blue 16..23
  , lpPrio  :: !Word8
  , lpLayer :: !Layer
  , lpAlpha :: !Word8    -- ^ OBJ semi-transparency, 1..16, 0 otherwise
  } deriving (Eq, Show, Generic)

-- | The final composed pixel.
data Pixel = Pixel
  { pxRgb   :: !Word32
  , pxLayer :: !Layer
  } deriving (Eq, Show, Generic)

-- | Identity of a renderable line, including exact immutable memory identities.
-- Arbitrary callback memories deliberately cannot provide a cache key.
data LineKey = LineKey
  { lkLine         :: !Int
  , lkNum          :: !Int
  , lkDispCnt      :: !Word32
  , lkBg           :: !(V4 BgReg)
  , lkBlendCnt     :: !Word32
  , lkEva          :: !Word32
  , lkEvb          :: !Word32
  , lkEvy          :: !Word32
  , lkObjMosaic    :: !Word32
  , lkBgMosaic     :: !Word32
  , lkBgMosaicX    :: !Word8
  , lkOamEpoch     :: !Word32
  , lkOamMemory    :: !MemoryKey
  , lkVramMemory   :: !MemoryKey
  , lkObjMemory    :: !MemoryKey
  , lkPaletteMemory :: !MemoryKey
  , lkBgExtMemory  :: !MemoryKey
  , lkVramEpoch    :: !Word32
  , lkPaletteEpoch :: !Word32
  , lk3D           :: !(Maybe Word32)
  , lkSprite       :: !(Maybe Word32)
  , lkWindow       :: !(Maybe Word32)
  , lkCapture      :: !(Maybe Word32)
  , lkDisplay      :: !(Maybe Word32)
  } deriving (Eq, Show, Generic)

-- | Identities of inputs a composed renderer reads that are not part of
-- 'EngineState'. A renderer that reads sprite pixels, window masks or display
-- capture must supply a stable identity for each; 'Nothing' means that input
-- is genuinely absent from the render (not "unknown, reuse anything").
data LineKeyTokens = LineKeyTokens
  { lkt3D      :: !(Maybe Word32)
  , lktSprite  :: !(Maybe Word32)
  , lktWindow  :: !(Maybe Word32)
  , lktCapture :: !(Maybe Word32)
  , lktDisplay :: !(Maybe Word32)
  } deriving (Eq, Show, Generic)

noLineKeyTokens :: LineKeyTokens
noLineKeyTokens = LineKeyTokens Nothing Nothing Nothing Nothing Nothing

-- | Unknown callback memories have no safe identity; callers must render.
-- A caller composing 3D into BG0 must pass that line's independent 3D frame
-- identity here, otherwise a cached 2D line could outlive a 3D frame change.
lineKey :: EngineState -> Int -> Maybe LineKey
lineKey = lineKeyWith Nothing

lineKeyWith :: Maybe Word32 -> EngineState -> Int -> Maybe LineKey
lineKeyWith threeD = lineKeyTok (noLineKeyTokens { lkt3D = threeD })

lineKeyTok :: LineKeyTokens -> EngineState -> Int -> Maybe LineKey
lineKeyTok tokens es y = do
  oam <- memoryKey (esOam es)
  vram <- memoryKey (esVram es)
  obj <- memoryKey (esObjVram es)
  palette <- memoryKey (esPalette es)
  ext <- memoryKey (esBgExtPal es)
  pure (LineKey y (esNum es) (esDispCnt es) (esBg es) (esBlendCnt es)
    (esEva es) (esEvb es) (esEvy es) (esObjMosaicLine es)
    (esBgMosaicLine es) (esBgMosaicX es) (esOamEpoch es)
    oam vram obj palette ext (esVramEpoch es) (esPaletteEpoch es)
    (lkt3D tokens) (lktSprite tokens) (lktWindow tokens) (lktCapture tokens)
    (lktDisplay tokens))

-- | Display-control helpers. @dispMode@ is DISPCNT bits 0..2.
dispMode :: Word32 -> Int
dispMode d = fromIntegral (d .&. 0x7)

bgEnable :: Word32 -> Int -> Bool
bgEnable d n = (d .&. (1 `shiftL` (8 + n))) /= 0

objEnable :: Word32 -> Bool
objEnable d = (d .&. 0x1000) /= 0

-- | BGCnt priority bits 0..1.
bgPriorityMask :: Word16
bgPriorityMask = 0x3
