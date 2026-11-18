-- | Ordered v11 GX replay bridge for the M4 3D line.
--
-- The trace decoder (owned elsewhere) must hand these events to us in the
-- order the type-5/6/7 records appeared. We feed them through the whole
-- Nds.Gpu3D.Chip model (GX front end -> geometry -> polygon RAM -> Render)
-- and expose the resulting 256-pixel line in the renderer's internal
-- RGBA6/A5 word format, which is exactly what @Nds.Gpu3D.Render.GetLine@
-- returns.
--
-- Required Trace.hs hook: a Phase must carry the ordered geometry records
-- observed since the previous Phase, with distinct constructors matching
-- Trace3DEvent. Records must not be sorted or dropped. Type 6 is emitted at
-- VBlank (frame summary); type 5 is one normalized GX command entry
-- (@entry.Command@, @entry.Param@); type 7 is a GX register write.
module Nds.Gpu3D.TraceReplay
  ( Trace3DEvent (..)
  , Trace3DState (..)
  , initialTrace3DState
  , applyTrace3DEvent
  , trace3DRenderStart
  , trace3DLine
  , trace3DPower
  , trace3DXPos
  , trace3DAbortFrame
  , trace3DFrameEnd
  , trace3DVBlank
  , trace3DTexMem
  ) where

import Data.Bits ((.&.), (.|.), shiftL, shiftR, testBit)
import Data.List (foldl')
import Data.Word (Word16, Word32, Word64, Word8)

import Nds.Gpu2D.Trace (TraceMemory, readRegion8)
import Nds.Gpu3D.Chip
import Nds.Gpu3D.GxFront (Size (..))
import Nds.Gpu3D.Texture (TexMem (..))

-- | One ordered type-5/6/7 event. Timestamps are not needed by the model, but
-- are carried so a decoder can preserve ordering/diagnostics.
data Trace3DEvent
  = Trace3DCommand !Word32 !Word64 !Word32 !Word32
    -- ^ frame, timestamp, command byte, parameter (type 5)
  | Trace3DRegister !Word32 !Word64 !Word32 !Word32 !Word8
    -- ^ frame, timestamp, address, value, width (type 7; width 1/2/4)
  | Trace3DFrame !Word32 !Word64 !Word32 !Word32 !Word32
    -- ^ frame, timestamp, vertices, polygons, flush attributes (type 6)
  | Trace3DVBlank !Word32 !Word64
    -- ^ explicit VBlank event; use one of this and type 6, not both
  | Trace3DRenderStart
    -- ^ explicit scanline-215 marker; no visible Phase exists there
  | Trace3DGxWrite !Word32 !Word64 !Word32 !Word32 !Word8
    -- ^ raw accepted GPU3D bus write (v12 type 26): frame, timestamp,
    -- address, value, width. Exact FIFO packing/command-port + SWAP timing.
  deriving (Eq, Show)

newtype Trace3DState = Trace3DState { trChip :: Chip }

initialTrace3DState :: Trace3DState
initialTrace3DState = Trace3DState initChip

-- | Apply one record. If the GX FIFO holds the ARM9 bus, the geometry engine
-- is drained first, exactly as GPU3D::Run would before accepting the write.
applyTrace3DEvent :: TexMem -> Trace3DEvent -> Trace3DState -> Either String Trace3DState
applyTrace3DEvent mem ev (Trace3DState ch) = case ev of
  Trace3DCommand _ _ cmd param ->
    let a = 0x04000400 + ((cmd .&. 0x7F) `shiftL` 2)
    in Right (Trace3DState (settle (write S32 a param (drain ch))))
  Trace3DRegister _ _ addr val width ->
    let sz = case width of
               1 -> S8
               2 -> S16
               4 -> S32
               _ -> S32
    in Right (Trace3DState (settle (write sz addr val (drain ch))))
  Trace3DFrame _ _ _ _ _ -> Right (Trace3DState (chipVBlank (settle ch)))
  Trace3DVBlank _ _ -> Right (Trace3DState (chipVBlank (settle ch)))
  Trace3DRenderStart -> Right (Trace3DState (chipRenderStart mem (settle ch)))
  Trace3DGxWrite _ _ addr val width ->
    let sz = case width of
               1 -> S8
               2 -> S16
               4 -> S32
               _ -> S32
    in Right (Trace3DState (settle (chipWrite sz addr val (drain ch))))
  where
    -- The production geometry engine runs continuously: a command is
    -- executed as soon as the pipeline reaches it, not only when the FIFO
    -- fills. Replaying must settle after every input for the same reason.
    settle c = let (c', _) = chipRun c in c'
    write sz a v c = chipWrite sz a v c
    drain c
      | chipStalled c = settle (drain c)
      | otherwise = c

-- | Scanline 215: build the render list and render the latched frame. The
-- texture memory is the same abstraction the Chip model already consumes.
trace3DRenderStart :: TexMem -> Trace3DState -> Trace3DState
trace3DRenderStart mem (Trace3DState ch) = Trace3DState (chipRenderStart mem ch)

-- | GetLine(y): exact 256 renderer words (6-bit R, G, B in bytes 0-2 and a
-- 5-bit alpha in byte 3), already X-scrolled by RenderXPos.
trace3DLine :: Int -> Trace3DState -> Either String [Word32]
trace3DLine y (Trace3DState ch)
  | y < 0 || y > 191 = Left "trace3DLine: y outside 0..191"
  | otherwise = Right (chipGetLine y ch)

trace3DPower :: Bool -> Bool -> Trace3DState -> Trace3DState
trace3DPower geom rend (Trace3DState ch) = Trace3DState (chipPower geom rend ch)

trace3DXPos :: Word16 -> Word16 -> Trace3DState -> Trace3DState
trace3DXPos x m (Trace3DState ch) = Trace3DState (chipXPos x m ch)

trace3DAbortFrame :: Trace3DState -> Trace3DState
trace3DAbortFrame (Trace3DState ch) = Trace3DState (chipAbortFrame ch)

trace3DFrameEnd :: Trace3DState -> Trace3DState
trace3DFrameEnd (Trace3DState ch) = Trace3DState (chipFrameEnd ch)

-- | Explicit VBlank advance (type 6 may also carry this; integration chooses
-- one source per VBlank to avoid applying it twice).
trace3DVBlank :: Trace3DState -> Trace3DState
trace3DVBlank (Trace3DState ch) = Trace3DState (chipVBlank ch)

-- | Texture and texture-palette views of a render-start memory snapshot.
-- The maps are the render-start VRAMMap_Texture[4] / VRAMMap_TexPal[8] bank
-- bitmasks (bit n = VRAM bank A+n, trace region n+2); mapped banks are ORed
-- exactly as melonDS's texture-slot reads do.
trace3DTexMem :: TraceMemory -> [Word32] -> [Word32] -> TexMem
trace3DTexMem mem texMaps palMaps = TexMem half word
  where
    masks = [0x1FFFF, 0x1FFFF, 0x1FFFF, 0x1FFFF, 0xFFFF, 0x3FFF, 0x3FFF, 0x7FFF, 0x3FFF] :: [Word32]
    byteAt sel a = foldl' (\acc (bank, mask) ->
        if testBit sel bank
          then acc .|. fromIntegral (readRegion8 mem (bank + 2) (fromIntegral (a .&. mask)))
          else acc) (0 :: Word32) (zip [0 ..] masks)
    half addr =
      let a = addr .&. 0x7FFFE
          sel = texMaps !! fromIntegral ((a `shiftR` 17) .&. 3)
      in fromIntegral (byteAt sel a) .|. (fromIntegral (byteAt sel (a + 1)) `shiftL` 8 :: Word16)
    word addr =
      let a = addr .&. 0x1FFFC
          sel = palMaps !! fromIntegral ((a `shiftR` 14) .&. 7)
      in byteAt sel a .|. (byteAt sel (a + 1) `shiftL` 8)
         .|. (byteAt sel (a + 2) `shiftL` 16) .|. (byteAt sel (a + 3) `shiftL` 24)
