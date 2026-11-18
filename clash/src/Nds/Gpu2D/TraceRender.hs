-- | Trace-driven 2D/3D diagnostic. Sprite preparation and scanout are
-- separate phases; oracle records are never used as rendering inputs.
module Nds.Gpu2D.TraceRender
  ( TraceRenderState, initialTraceRenderState, advanceTraceSprites
  , renderTraceDisplays, traceComposeInputs, handleTraceCapture
  , traceCaptureStateMatches ) where

import Data.Bits ((.&.), (.|.), shiftL, shiftR, testBit, xor)
import Data.Word (Word8, Word16, Word32)
import Nds.Gpu.Unified
import Nds.Gpu2D.Line
import qualified Nds.Gpu2D.Capture as Cap
import Nds.Gpu2D.Sprite
import Nds.Gpu2D.Trace
import Nds.Gpu2D.TraceState
import Nds.Gpu2D.Types

data TraceRenderState = TraceRenderState !SpriteLine !SpriteLine !Cap.CaptureState !(Maybe CaptureSources)
data CaptureSources = CaptureSources !Word32 !Word16 ![Word32] !(Maybe [Word32]) ![Word16]

initialTraceRenderState :: TraceRenderState
initialTraceRenderState = TraceRenderState emptySpriteLine emptySpriteLine Cap.emptyCaptureState Nothing

-- | Called on every SpritePhase, including VCount 262's preparation of line 0.
advanceTraceSprites :: TraceRenderState -> Phase -> Either String TraceRenderState
advanceTraceSprites (TraceRenderState a b capture sources) p = do
  d <- maybe (Left "sprite phase lacks v10 display state") Right (phaseDisplayState p)
  pure (TraceRenderState (draw d 0 a) (draw d 1 b) capture sources)
  where
    r = phaseRegisters p
    Latch la lb = phaseLatch p
    draw d n previous =
      let e = 292+90*n
          obj = phaseOBJMemory p n
          inp = SpriteInput
            { siEnabled = if n == 0 then displayEngineAEnabled d else displayEngineBEnabled d
            , siOBJEnabled = word8At r (e+5) /= 0
            , siDispCnt = word32At r e
            , siMosaicLine = latchOBJMosaicLine (if n == 0 then la else lb)
            , siTargetLine = fromIntegral (word16At r 4)
            , siOAMRead = memoryRead (phaseOAMMemory p n)
            , siOBJRead = memoryRead obj
            , siOBJMask = memoryMask obj
            }
      in drawSprites inp previous

-- | Render one physical top/bottom line in melonDS BGRA8888 order. The 3D
-- source is supplied explicitly; this renderer never reads the trace's
-- recorded 3D oracle. A supplied line must retain all 256 pixel positions.
renderTraceDisplays :: Maybe [Word32] -> TraceRenderState -> Phase -> Either String (TraceRenderState, ([Word32], [Word32]))
renderTraceDisplays source3d (TraceRenderState oldA oldB capture _) p = do
  case source3d of
    Just line | length line /= 256 -> Left "3D input must have 256 pixels"
    _ -> Right ()
  d <- maybe (Left "display state absent (v10 trace required)") Right (phaseDisplayState p)
  let prep n old =
        let enabled = if n == 0 then displayEngineAEnabled d else displayEngineBEnabled d
            e = 292+90*n
        in if enabled && word8At r (e+6) == 0 then applySpriteMosaic (word8At r (e+80)) old else old
      aSprites = prep 0 oldA
      bSprites = prep 1 oldB
  rawA <- rawEngine d 0 aSprites
  rawB <- rawEngine d 1 bSprites
  let fifo = [word16At (displayFIFOBuffer d) (x*2) | x <- [0..255]]
      sources = CaptureSources (word32At r 0) (word16At r 4) rawA source3d fifo
      next = TraceRenderState aSprites bSprites capture (Just sources)
  if word8At r 8 == 0 then pure (next, (replicate 256 0xff000000, replicate 256 0xff000000))
  else do
    a <- output d 0 rawA
    b <- output d 1 rawB
    pure (next, if word8At r 9 /= 0 then (a,b) else (b,a))
  where
    r = phaseRegisters p
    y = fromIntegral (word16At r 4) :: Int
    rawEngine d n sprites =
      let base = 292+90*n
          enabled = if n == 0 then displayEngineAEnabled d else displayEngineBEnabled d
          dispcnt = word32At r base
      in if dispcnt .&. 7 == 7 then Left "unsupported video mode 7"
         else if not enabled then Right (replicate 256 (if n == 0 then 0xff000000 else 0xff3f3f3f))
         else if word8At r (base+6) /= 0 then Right (replicate 256 0xff3f3f3f)
         else map (.|. 0xff000000) <$> engineLine n base dispcnt sprites
    output d n raw = do
      let base = 292 + 90*n
          dispcnt = word32At r base
          mode = fromIntegral ((dispcnt `shiftR` 16) .&. if n == 0 then 3 else 1) :: Int
          enabled = if n == 0 then displayEngineAEnabled d else displayEngineBEnabled d
          forcedBlank = word8At r (base+6) /= 0
          brightness = word16At r (12 + 2*n)
      colors <- case mode of
        0 -> pure (replicate 256 0x3f3f3f)
        1 -> pure raw
        2 -> let bank = fromIntegral ((dispcnt `shiftR` 18) .&. 3)
                 pixels = if testBit (displayLCDCMap d) bank
                   then [pixel15 (read16Region (phaseMemory p) (bank+2) (y*512+x*2)) | x <- [0..255]]
                   else replicate 256 0
             in pure pixels
        _ -> pure [pixel15 (word16At (displayFIFOBuffer d) (x*2)) | x <- [0..255]]
      pure (map (expand . if mode == 0 then id else master brightness) colors)
    engineLine n base dispcnt sprites = do
      let enabledLayers = word8At r (base+4)
          active i = testBit enabledLayers i
          uses3d = n == 0 && active 0 && testBit dispcnt 3
      pixels <- if uses3d then case source3d of
        Nothing -> Left "3D input absent"
        Just pixels3d -> Right [(x,y,c) | (x,c) <- zip [0..255] pixels3d]
        else Right []
      let objPixels = if active 4 then map (spritePixelAt p n) (slPixels sprites) else emptyLine
          line = unifiedLineWindowed (UnifiedInput (phaseEngine p n) pixels) y
                   (phaseWindowMasks p n (slWindow sprites)) objPixels
      traverse (maybe (Left "missing backdrop") (Right . pxRgb)) line

spritePixelAt :: Phase -> Int -> Word32 -> Maybe LayerPixel
spritePixelAt p n pixel
  | not (testBit pixel 18) = Nothing
  | otherwise =
      let direct = testBit pixel 15
          index = pixel .&. if testBit pixel 12 then 0xff else 0xfff
          readExt a = fromIntegral (phaseOBJExtRead p n a) .|.
                      (fromIntegral (phaseOBJExtRead p n (a+1)) `shiftL` 8)
          color | direct = fromIntegral (pixel .&. 0x7fff)
                | testBit pixel 12 = read16Region (phaseMemory p) 0 (n*1024+512+fromIntegral index*2)
                | otherwise = readExt (index*2)
          alpha | testBit pixel 30 = fromIntegral ((pixel `shiftR` 24) .&. 31)
                | testBit pixel 31 = 255
                | otherwise = 0
      in Just (LayerPixel (expandColor15 color) (fromIntegral ((pixel `shiftR` 16) .&. 3)) LObj alpha)

-- | Everything a composed engine-A/B line depends on outside 'EngineState':
-- window mask, palette-expanded OBJ layer, and cache tokens identifying the
-- sprite buffer, mask, capture state and 3D line (the caller decides whether
-- 3D is displayed). 'Nothing' tokens mean the input is genuinely absent.
traceComposeInputs
  :: TraceRenderState -> Phase -> Int
  -> ([Word8], [Maybe LayerPixel], LineKeyTokens)
traceComposeInputs (TraceRenderState spritesA spritesB capture sources) p n =
  let sprites = if n == 0 then spritesA else spritesB
      masks = phaseWindowMasks p n (slWindow sprites)
      objRaw = slPixels sprites
      active = word8At r (292 + 90*n + 4) .&. 0x10 /= 0
      obj = if active then map (spritePixelAt p n) objRaw else emptyLine
      three = case phase3D p of
        Just bytes -> Just (hash32 (map (word32At bytes . (*4)) [0..255]))
        Nothing -> Nothing
      capTok = case sources of
        Just _ -> Just (hash32 (fromIntegral (fromEnum (Cap.csActive capture)) :
                     map fromIntegral (Cap.csFlags capture)))
        Nothing -> Just 0
      displayTok = case phaseDisplayState p of
        Nothing -> Nothing
        Just d -> Just (hash32
          ([ fromIntegral (fromEnum (displayEngineAEnabled d))
          , fromIntegral (fromEnum (displayEngineBEnabled d))
          , displayCaptureCnt d
          , displayLCDCMap d
          , fromIntegral (word8At r 8)            -- screens enabled
          , fromIntegral (word8At r 9)            -- screen swap
          , fromIntegral (word16At r 12)          -- master brightness A
          , fromIntegral (word16At r 14)          -- master brightness B
          ] ++ [ fromIntegral (word16At (displayFIFOBuffer d) (x*2)) | x <- [0..255] ]))
      tokens = LineKeyTokens
        { lkt3D = three
        , lktSprite = Just (hash32 objRaw)
        , lktWindow = Just (hash32 (map fromIntegral masks))
        , lktCapture = capTok
        , lktDisplay = displayTok
        }
  in (masks, obj, tokens)
  where
    r = phaseRegisters p

hash32 :: [Word32] -> Word32
hash32 = foldl (\h w -> (h `xor` w) * 16777619) 2166136261

-- | Run capture against the decoder's independent renderer-memory snapshot.
-- Expected capture records are never passed here.
handleTraceCapture :: TraceRenderState -> CaptureEvent -> Either String (TraceRenderState, [CaptureWrite])
handleTraceCapture (TraceRenderState a b state sources) event = case event of
  CaptureLifecycleStart _ _ cnt lcdc -> Right (TraceRenderState a b (Cap.captureStart state cnt lcdc) sources, [])
  CaptureLifecycleEnd _ _ cnt _ -> Right (TraceRenderState a b (Cap.captureEnd state cnt) sources, [])
  CaptureBegin frame line cnt disp lcdc memory -> case sources of
    Just (CaptureSources f y src2d src3d fifo) | f == frame && y == line ->
      if testBit cnt 24 && ((cnt `shiftR` 29) .&. 3) /= 1 && src3d == Nothing
      then Left "capture requires missing 3D source"
      else
        let readBank bank index = read16Region memory (bank+2) (fromIntegral index*2)
            input = Cap.CaptureInput state cnt (fromIntegral line) lcdc disp src2d
                      (maybe [] id src3d) fifo readBank
            result = Cap.captureLine input
        in Right (TraceRenderState a b (Cap.coState result) sources, Cap.coWrites result)
    _ -> Left "capture does not match the preceding scanline"

traceCaptureStateMatches :: TraceRenderState -> [Word16] -> Bool -> Bool
traceCaptureStateMatches (TraceRenderState _ _ state _) flags active =
  Cap.csFlags state == flags && Cap.csActive state == active

read16Region :: TraceMemory -> Int -> Int -> Word16
read16Region m region addr = fromIntegral (readRegion8 m region addr) .|.
  (fromIntegral (readRegion8 m region (addr+1)) `shiftL` 8)

pixel15 :: Word16 -> Word32
pixel15 c = fromIntegral ((c .&. 31) `shiftL` 1) .|.
  (fromIntegral ((c `shiftR` 5) .&. 31) `shiftL` 9) .|.
  (fromIntegral ((c `shiftR` 10) .&. 31) `shiftL` 17)

master :: Word16 -> Word32 -> Word32
master reg pixel = case reg `shiftR` 14 of
  1 -> colorBrightnessUp pixel factor 0
  2 -> colorBrightnessDown pixel factor 15
  _ -> pixel
  where factor = min 16 (fromIntegral (reg .&. 31))

expand :: Word32 -> Word32
expand c = 0xff000000 .|. (channel 0 `shiftL` 16) .|. (channel 8 `shiftL` 8) .|. channel 16
  where channel n = let x = (c `shiftR` n) .&. 63 in (x `shiftL` 2) .|. (x `shiftR` 4)
