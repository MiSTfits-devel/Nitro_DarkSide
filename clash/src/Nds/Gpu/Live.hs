{-# LANGUAGE BangPatterns #-}
-- | Authoritative live GPU device. The CPU host submits ordered bus accesses
-- and services returned deadlines; it supplies no GPU registers, pixels,
-- capture bytes, status or IRQ/DMA decisions. LCD and geometry schedules share
-- one system-clock time domain. All effects are returned after state commits.
module Nds.Gpu.Live
  ( Live(..), Effects(..), noEffects, newLive, deadline, advanceLive
  , startFrame, readIORegister, writeIORegister, writeIOContinuation, acknowledgeIF, makePhase
  ) where

import Control.Exception (evaluate)
import Control.Monad (when)
import Data.Array.Unboxed
import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import Data.List (foldl')
import Data.Maybe (catMaybes)
import Data.Word
import Foreign.Marshal.Array (pokeArray)
import Foreign.Ptr
import Nds.Gpu.Live2D
import Nds.Gpu.LiveMemory
import Nds.Gpu2D.Trace
import Nds.Gpu2D.TraceRender
import Nds.Gpu3D.Chip
import qualified Nds.Gpu3D.GxFront as F
import Nds.Gpu3D.Timed
import Nds.Gpu3D.TraceReplay (trace3DTexMem)

data LCD = Scanline !Word32 | HBlank !Word32 | EndFrame deriving (Eq,Show)
data Effects = Effects
  { irqSet9 :: !Word64, irqClear9 :: !Word64, irqSet7 :: !Word64, irqClear7 :: !Word64
  , dma9 :: !Word64, dma7 :: !Word64, frameCompleted :: !Bool } deriving (Eq,Show)
noEffects :: Effects
noEffects = Effects 0 0 0 0 0 0 False

data Live = Live
  { liveTime :: !Word64, liveGX :: !TimedChip, liveMemory :: !TraceMemory, liveMaps :: !VramMaps
  , liveA :: !Engine, liveB :: !Engine, livePower :: !Word16
  , liveVCount :: !Word16, liveNextVCount :: !Word16, liveOverride :: !Bool
  , liveStat9 :: !Word16, liveStat7 :: !Word16
  , liveCapture :: !Word32, liveCaptureEnabled :: !Bool
  , liveBrightnessA :: !Word16, liveBrightnessB :: !Word16
  , liveFIFO :: !(UArray Int Word16), liveFIFORead :: !Int, liveFIFOWrite :: !Int
  , liveFIFOBuffer :: !(UArray Int Word16), liveRunFIFO :: !Bool
  , liveFIFOEvent :: !(Maybe (Word64,Int)), liveLCD :: !(Maybe (Word64,LCD))
  , liveScreens :: !Bool, liveFrame :: !Word64, liveRenderer :: !TraceRenderState
  , livePixels :: !(Ptr Word32), livePixelsValid :: !Bool }

newLive :: Word64 -> Ptr Word32 -> IO Live
newLive now pixels = do
  memory <- newTraceMemory
  pure Live { liveTime=now,liveGX=initTimedChip now,liveMemory=memory,liveMaps=emptyMaps
            , liveA=initialEngine,liveB=initialEngine,livePower=0
            , liveVCount=0,liveNextVCount=0,liveOverride=False,liveStat9=0,liveStat7=0
            , liveCapture=0,liveCaptureEnabled=False,liveBrightnessA=0,liveBrightnessB=0
            , liveFIFO=listArray (0,15) (replicate 16 0),liveFIFORead=0,liveFIFOWrite=0
            , liveFIFOBuffer=listArray (0,255) (replicate 256 0),liveRunFIFO=False
            , liveFIFOEvent=Nothing,liveLCD=Nothing,liveScreens=False,liveFrame=0
            , liveRenderer=initialTraceRenderState
            , livePixels=pixels,livePixelsValid=False }

deadline :: Live -> Maybe Word64
deadline s = case catMaybes [timedDeadline (liveGX s),fst <$> liveLCD s,fst <$> liveFIFOEvent s] of
  [] -> Nothing
  ds -> Just (minimum ds)

orFail :: Either String a -> IO a
orFail = either fail pure
-- A bus cannot silently absorb multiple earlier pulses. The coordinator must
-- service every returned deadline, including equal-timestamp follow-on work.
synchronize :: Word64 -> Live -> IO Live
synchronize now s = do
  when (now < liveTime s) (fail "GPU timestamp moved backwards")
  when (maybe False (<=now) (deadline s)) (fail "GPU bus access before servicing due deadline")
  (gx,fx) <- orFail (timedAdvance now (liveGX s))
  when (not (null fx)) (fail "unscheduled geometry effect during bus synchronization")
  pure s { liveTime=now,liveGX=gx }

fromGX :: [TimedEffect] -> Effects
fromGX = foldl' one noEffects
  where one e GxDma = e { dma9=setBit (dma9 e) 7 }
        one e (GxIrq True) = e { irqSet9=bit 21,irqClear9=0 }
        one e (GxIrq False) = e { irqClear9=bit 21,irqSet9=0 }

advanceLive :: Word64 -> Live -> IO (Live,Effects)
advanceLive now s = do
  when (now < liveTime s) (fail "GPU timestamp moved backwards")
  when (maybe False (<now) (deadline s)) (fail "GPU deadline skipped")
  if timedDeadline (liveGX s) == Just now then do
    (gx,fx) <- orFail (timedAdvance now (liveGX s))
    pure (s { liveTime=now,liveGX=gx },fromGX fx)
  else do
    (gx,fx) <- orFail (timedAdvance now (liveGX s))
    when (not (null fx)) (fail "geometry event without its deadline")
    let s0=s { liveTime=now,liveGX=gx }
    case liveLCD s of
      Just (t,event) | t==now -> lcd event s0
      _ -> case liveFIFOEvent s of
        Just (t,x) | t==now -> pure (sampleFIFO x s0,if x<256 then noEffects { dma9=bit 4 } else noEffects)
        _ -> pure (s0,noEffects)

startFrame :: Word64 -> Word64 -> Live -> IO (Live,Effects)
startFrame now armed s = do
  s0 <- synchronize now s
  when (liveLCD s0 /= Nothing) (fail "FRAME_START while LCD frame is active")
  let usesFIFO = (reg32 (liveA s0) 0 `shiftR` 16) .&. 3 == 3 ||
                 (testBit (liveCapture s0) 25 && (liveCapture s0 `shiftR` 29) .&. 3 /= 0)
  lcd (Scanline 0) s0 { liveScreens=testBit (livePower s0) 0
                      , liveRunFIFO=usesFIFO || testBit armed 4 }

sampleFIFO :: Int -> Live -> Live
sampleFIFO x s = sampled { liveFIFOEvent=if x<256 then Just (liveTime s+48,x+8) else Nothing }
  where
    (offset,count) | x==0=(0,0) | x==8=(0,5) | x==256=(245,11) | otherwise=(x-11,8)
    -- At x256 the regular 8 samples are followed by the final 3.
    sampled=s { liveFIFORead=(liveFIFORead s+count) .&. 15
              , liveFIFOBuffer=liveFIFOBuffer s // [(offset+i,liveFIFO s ! ((liveFIFORead s+i) .&. 15)) | i <- [0..count-1]] }

setStatusIRQ :: Int -> Int -> Live -> (Live,Effects) -> (Live,Effects)
setStatusIRQ cpu flag source (s,e)
  | testBit old flag = (s,e)
  | otherwise = (if cpu==0 then s { liveStat9=setBit old flag } else s { liveStat7=setBit old flag },e')
  where old=if cpu==0 then liveStat9 source else liveStat7 source
        e' | not (testBit old (flag+3)) = e
           | cpu==0 = e { irqSet9=setBit (irqSet9 e) flag }
           | otherwise = e { irqSet7=setBit (irqSet7 e) flag }

lcd :: LCD -> Live -> IO (Live,Effects)
lcd (Scanline physical) s = do
  let vc=if physical==0 then 0 else (liveVCount s+1) .&. 511
      s0=s { liveVCount=vc,liveStat9=clearBit (liveStat9 s) 1,liveStat7=clearBit (liveStat7 s) 1
           , liveA=updateWindows vc (liveA s),liveB=updateWindows vc (liveB s)
           , liveFIFOEvent=if vc<192 && liveRunFIFO s then Just (liveTime s+32,0) else liveFIFOEvent s }
      e0=noEffects { dma9=if vc>=2 && vc<194 then bit 3 else if vc==194 then bit 35 else 0 }
  (s1,e1) <- if vc==0 && testBit (liveCapture s0) 31 then do
      (renderer,_) <- orFail (handleTraceCapture (liveRenderer s0) (CaptureLifecycleStart (fromIntegral (liveFrame s0)) vc (liveCapture s0) (lcdcMap (liveMaps s0))))
      pure (s0 { liveCaptureEnabled=True,liveRenderer=renderer },e0)
    else if vc==192 then do
      (renderer,_) <- if liveCaptureEnabled s0 then orFail (handleTraceCapture (liveRenderer s0) (CaptureLifecycleEnd (fromIntegral (liveFrame s0)) vc (liveCapture s0) (lcdcMap (liveMaps s0)))) else pure (liveRenderer s0,[])
      let sV=s0 { liveRenderer=renderer,liveCapture=if liveCaptureEnabled s0 then clearBit (liveCapture s0) 31 else liveCapture s0,liveCaptureEnabled=False
                , liveFIFORead=0,liveFIFOWrite=0,liveGX=timedVBlank (liveGX s0) }
          (sI,eI)=setStatusIRQ 1 0 sV (setStatusIRQ 0 0 sV (sV,e0))
      pure (sI,eI { dma9=dma9 eI .|. bit 36 .|. bit 1,dma7=bit 17 })
    else pure (if vc==262 then s0 { liveStat9=clearBit (liveStat9 s0) 0,liveStat7=clearBit (liveStat7 s0) 0 } else s0,e0)
  let current=if liveOverride s1 then liveNextVCount s1 else liveVCount s1
      s2=s1 { liveVCount=current,liveOverride=False }
      match stat=(stat `shiftR` 8) .|. ((stat .&. 128) `shiftL` 1)
      matchOne cpu (st,ef)=let status=if cpu==0 then liveStat9 st else liveStat7 st
                           in if current==match status then setStatusIRQ cpu 2 st (st,ef)
                              else (if cpu==0 then st { liveStat9=clearBit status 2 } else st { liveStat7=clearBit status 2 },ef)
      (s3,e3)=matchOne 1 (matchOne 0 (s2,e1))
  pure (s3 { liveLCD=Just (liveTime s+1584,HBlank physical) },e3)
lcd (HBlank physical) s = do
  let vc=liveVCount s; reset=vc==262
      pre=s { liveA=preDraw vc reset (liveA s),liveB=preDraw vc reset (liveB s)
            , liveStat9=setBit (liveStat9 s) 1,liveStat7=setBit (liveStat7 s) 1 }
  drawn <- if vc<192 && physical<192 then drawLine physical pre else pure pre
  sprites <- if vc<192 && physical<191 then prepareSprites (fromIntegral physical+1) drawn
             else if vc==262 then prepareSprites 0 drawn else pure drawn
  rendered <- if vc==215 then do
      let memory=trace3DTexMem (liveMemory sprites) (textureMaps (liveMaps sprites)) (texturePaletteMaps (liveMaps sprites))
          gx=liveGX sprites
          chip=chipRenderStart memory (tcChip gx)
      _ <- evaluate (chColour chip ! (256*192-1))
      pure sprites { liveGX=gx { tcChip=chip } }
    else pure sprites
  let result=rendered { liveA=postDraw reset (liveA rendered),liveB=postDraw reset (liveB rendered)
                      , liveLCD=Just (liveTime s+546,if vc==262 || vc==511 then EndFrame else Scanline (physical+1)) }
      effects=noEffects { irqSet9=if testBit (liveStat9 s) 4 then bit 1 else 0
                        , irqSet7=if testBit (liveStat7 s) 4 then bit 1 else 0
                        , dma9=if vc<192 then bit 2 else 0 }
  pure (result,effects)
lcd EndFrame s = pure (s { liveLCD=Nothing,liveFrame=liveFrame s+1,livePixelsValid=True
                         , liveGX=(liveGX s) { tcChip=chipFrameEnd (tcChip (liveGX s)) } },noEffects { frameCompleted=True })

makePhase :: PhaseKind -> Word16 -> Live -> Phase
makePhase kind y s = Phase kind registers (Latch (engineLatch (liveA s)) (engineLatch (liveB s)))
  (ExtendedPaletteMap (extendedMapBytes (liveMaps s))) (Just display) (liveMemory s) Nothing
  where
    display=DisplayState (eEnabled (liveA s)) (eEnabled (liveB s)) (liveCapture s) (lcdcMap (liveMaps s))
      (packed16 (elems (liveFIFO s))) (fromIntegral (liveFIFORead s)) (fromIntegral (liveFIFOWrite s)) (packed16 (elems (liveFIFOBuffer s)))
    registers=BL.toStrict . BB.toLazyByteString $
      BB.word32LE (fromIntegral (liveFrame s)) <> BB.word16LE y <> BB.word16LE (liveVCount s) <>
      foldMap BB.word8 [bool (liveScreens s),bool (testBit (livePower s) 15),bool (liveCaptureEnabled s),0] <>
      BB.word16LE (liveBrightnessA s) <> BB.word16LE (liveBrightnessB s) <>
      foldMap (BB.word8 . bankControl (liveMaps s)) [0..8] <> BB.word8 0 <> BB.word16LE 0 <>
      BB.byteString (phaseMapBytes (liveMaps s)) <> BB.word64LE 0 <>
      BB.byteString (enginePacket (liveA s)) <> BB.byteString (enginePacket (liveB s))
    bool=fromIntegral . fromEnum
    packed16=BL.toStrict . BB.toLazyByteString . foldMap BB.word16LE

prepareSprites :: Word16 -> Live -> IO Live
prepareSprites y s = do
  renderer <- orFail (advanceTraceSprites (liveRenderer s) (makePhase SpritePhase y s))
  pure s { liveRenderer=renderer }

drawLine :: Word32 -> Live -> IO Live
drawLine physical s = do
  let y=liveVCount s
      source=chipGetLine (fromIntegral y) (tcChip (liveGX s))
      phase=makePhase ScanlinePhase y s
  (renderer,(top,bottom)) <- orFail (renderTraceDisplays (Just source) (liveRenderer s) phase)
  pokeArray (livePixels s `plusPtr` (fromIntegral physical*256*4)) top
  pokeArray (livePixels s `plusPtr` ((256*192+fromIntegral physical*256)*4)) bottom
  (captured,writes) <- if liveCaptureEnabled s then orFail (handleTraceCapture renderer (CaptureBegin (fromIntegral (liveFrame s)) y (liveCapture s) (reg32 (liveA s) 0) (lcdcMap (liveMaps s)) (liveMemory s))) else pure (renderer,[])
  memory <- applyCaptureWrites (liveMemory s) writes
  let windows e=if eEnabled e && eBlank e==0 then finishWindows e else e
  pure s { liveRenderer=captured,liveMemory=memory,liveA=windows (liveA s),liveB=windows (liveB s) }

sizeOf :: Int -> F.Size
sizeOf 1=F.S8
sizeOf 2=F.S16
sizeOf _=F.S32

readIORegister :: Word64 -> Int -> Int -> Word32 -> Live -> IO (Live,Word32)
readIORegister now cpu width address s = do
  st <- synchronize now s
  pure (st,readReg st)
  where
    readReg st
      | cpu==1 && address==0x04000240 = vramStat (liveMaps st)
      | address>=0x04000004 && address<0x04000008 = lane width (address-0x04000004) (fromIntegral status .|. (fromIntegral (liveVCount st) `shiftL` 16))
      | cpu/=0 = 0
      | isGX address = timedRead (sizeOf width) address (liveGX st)
      | address>=0x04000000 && address<0x04000060 = engineRead width (fromIntegral (address .&. 0xfff)) (liveA st)
      | address>=0x04001000 && address<0x04001060 = engineRead width (fromIntegral (address .&. 0xfff)) (liveB st)
      | address>=0x04000240 && address<=0x04000249 = foldl' (.|.) 0 [fromIntegral (cnt (address+fromIntegral i)) `shiftL` (8*i) | i<-[0..width-1]]
      | address==0x04000304 && width/=1 = fromIntegral (livePower st)
      | address>=0x04000064 && address<0x04000068 = lane width (address-0x04000064) (liveCapture st)
      | address==0x0400006c || address==0x0400006d = lane width (address-0x0400006c) (fromIntegral (liveBrightnessA st))
      | address==0x0400106c || address==0x0400106d = lane width (address-0x0400106c) (fromIntegral (liveBrightnessB st))
      | otherwise = 0
      where status=if cpu==0 then liveStat9 st else liveStat7 st
            cnt a | a>=0x04000240 && a<=0x04000246 = bankControl (liveMaps st) (fromIntegral (a-0x04000240))
                  | a==0x04000248 || a==0x04000249 = bankControl (liveMaps st) (fromIntegral (a-0x04000241))
                  | otherwise=0

isGX :: Word32 -> Bool
isGX a = (a>=0x04000060 && a<0x04000064) || (a>=0x04000320 && a<0x040006a4)
lane :: Int -> Word32 -> Word32 -> Word32
lane width offset value=(value `shiftR` (8*fromIntegral offset)) .&. if width==4 then 0xffffffff else (1 `shiftL` (width*8))-1

writeIORegister :: Word64 -> Int -> Int -> Word32 -> Word32 -> Live -> IO (Live,Effects)
writeIORegister now cpu width address value s = do
  st <- synchronize now s
  if address>=0x04000004 && address<0x04000008 then pure (writeStatus cpu width address value st,noEffects)
  else if cpu/=0 then pure (st,noEffects)
  else if isGX address then do
    (gx,effects) <- orFail (timedWrite (sizeOf width) address value (liveGX st))
    pure (st { liveGX=gx },fromGX effects)
  else if address>=0x04000000 && address<0x04000060 then
    let a=fromIntegral (address .&. 0xfff)
        gx=liveGX st
        xpos=if a==0x10 || a==0x11 then chipXPos (fromIntegral (value `shiftL` (8*(a .&. 1)))) (if width==1 then if odd a then 0xff00 else 0xff else 0xffff) (tcChip gx) else tcChip gx
    in pure (st { liveA=engineWrite 0 width a value (liveA st),liveGX=gx { tcChip=xpos } },noEffects)
  else if address>=0x04001000 && address<0x04001060 then pure (st { liveB=engineWrite 1 width (fromIntegral (address .&. 0xfff)) value (liveB st) },noEffects)
  -- Stock CPU routing defines POWCNT1 only for halfword/word accesses;
  -- byte reads are zero and byte writes do not change either lane.
  else if address==0x04000304 && width/=1 then
    let power=fromIntegral value .&. 0x820f
    in pure (st { livePower=power,liveA=(liveA st) { eEnabled=testBit power 1 },liveB=(liveB st) { eEnabled=testBit power 9 },liveGX=timedPower (testBit power 3) (testBit power 2) (liveGX st) },noEffects)
  else if address>=0x04000240 && address<=0x04000249 then do
    maps <- foldl' (\acc i -> acc >>= \m -> let a=address+fromIntegral i in
                     if a>=0x04000240 && a<=0x04000246 then orFail (mapBank (fromIntegral (a-0x04000240)) (fromIntegral (value `shiftR` (8*i))) m)
                     else if a==0x04000248 || a==0x04000249 then orFail (mapBank (fromIntegral (a-0x04000241)) (fromIntegral (value `shiftR` (8*i))) m)
                     else fail "WRAMCNT/non-GPU byte in GPU-owned VRAMCNT request") (pure (liveMaps st)) [0..width-1]
    pure (st { liveMaps=maps },noEffects)
  else pure (writeDisplay width address value st,noEffects)

-- | The FFI service has authenticated this exact ARM9 instruction's stall
-- origin. Non-command GX registers still use their normal write decoder.
writeIOContinuation :: Word64 -> Word32 -> Word32 -> Live -> IO (Live,Effects)
writeIOContinuation now address value s = do
  when (not (isGX address) || address .&. 3/=0) (fail "GX continuation requires word GX MMIO")
  st <- synchronize now s
  (gx,effects) <- orFail (timedWriteContinuation address value (liveGX st))
  pure (st { liveGX=gx },fromGX effects)

writeStatus :: Int -> Int -> Word32 -> Word32 -> Live -> Live
writeStatus cpu width address value s = foldl' one s [0..width-1]
  where
    one st i
      | a<0x04000006 =
          let sh=fromIntegral (a-0x04000004)*8
              mask=(0xff `shiftL` sh) .&. complement 0x47
              old=if cpu==0 then liveStat9 st else liveStat7 st
              new=(old .&. complement mask) .|. ((fromIntegral byte `shiftL` sh) .&. mask)
          in if cpu==0 then st { liveStat9=new } else st { liveStat7=new }
      | a<0x04000008 =
          let sh=fromIntegral (a-0x04000006)*8
              mask=0xff `shiftL` sh
              new=(liveNextVCount st .&. complement mask) .|. ((fromIntegral byte `shiftL` sh) .&. mask .&. 511)
              gx=liveGX st
          in st { liveNextVCount=new,liveOverride=True,liveGX=gx { tcChip=if new/=liveNextVCount st then chipAbortFrame (tcChip gx) else tcChip gx } }
      | otherwise=st
      where a=address+fromIntegral i; byte=fromIntegral (value `shiftR` (8*i)) :: Word8

writeDisplay :: Int -> Word32 -> Word32 -> Live -> Live
writeDisplay width address value s
  | address>=0x04000068 && address<0x0400006c = fifoWrite
  | otherwise=foldl' one s [0..width-1]
  where
    fifoWrite
      | width==4 = s { liveFIFO=liveFIFO s // [(liveFIFOWrite s,fromIntegral value),(liveFIFOWrite s+1,fromIntegral (value `shiftR` 16))],liveFIFOWrite=(liveFIFOWrite s+2) .&. 15 }
      | width==2 = s { liveFIFO=liveFIFO s // [(liveFIFOWrite s+fromIntegral ((address `shiftR` 1) .&. 1),fromIntegral value)],liveFIFOWrite=if testBit address 1 then (liveFIFOWrite s+2) .&. 15 else liveFIFOWrite s }
      | address .&. 3==0 || address .&. 3==2 = s { liveFIFO=liveFIFO s // [(liveFIFOWrite s+fromIntegral ((address `shiftR` 1) .&. 1),fromIntegral value*0x101)] }
      | address .&. 3==3 = s { liveFIFOWrite=(liveFIFOWrite s+2) .&. 15 }
      | otherwise=s
    one st i
      | a>=0x04000064 && a<0x04000068 =
          let sh=fromIntegral (a-0x04000064)*8
              mask=(0xff `shiftL` sh) .&. 0xef3f1f1f
          in st { liveCapture=(liveCapture st .&. complement (0xff `shiftL` sh)) .|. ((byte `shiftL` sh) .&. mask) }
      | a==0x0400006c || a==0x0400006d = st { liveBrightnessA=brightness (liveBrightnessA st) a byte }
      | a==0x0400106c || a==0x0400106d = st { liveBrightnessB=brightness (liveBrightnessB st) a byte }
      | otherwise=st
      where a=address+fromIntegral i; byte=(value `shiftR` (8*i)) .&. 255
    brightness old a byte=let sh=fromIntegral (a .&. 1)*8; mask=(0xff `shiftL` sh) .&. 0xc01f
                          in (old .&. complement (0xff `shiftL` sh)) .|. ((fromIntegral byte `shiftL` sh) .&. mask)

acknowledgeIF :: Word64 -> Int -> Live -> IO (Live,Effects)
acknowledgeIF now cpu s = do
  st <- synchronize now s
  if cpu/=0 then pure (st,noEffects) else do
    let gx=liveGX st; chip=chipIrqCheck (tcChip gx)
    pure (st { liveGX=gx { tcChip=chip } },fromGX [GxIrq (chipIrq chip)])
