{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ForeignFunctionInterface #-}
-- | Versioned synchronous service described by sim/melonds_tracer/HsGpuAbi.h.
-- No oracle, trace file or melonDS GPU pointer is accepted by this ABI.
module GpuService where

import Control.Exception
import Control.Monad (when)
import Data.Bits
import Data.IORef
import Data.Word
import Foreign.C.String
import Foreign.C.Types
import Foreign.Marshal.Alloc
import Foreign.Marshal.Array
import Foreign.Marshal.Utils
import Foreign.Ptr
import Foreign.StablePtr
import Foreign.Storable
import Nds.Gpu.Live
import Nds.Gpu.LiveMemory
import Nds.Gpu3D.Chip (chipStalled,chipDmaRequest)
import Nds.Gpu3D.Timed (tcChip)

-- Scope/time of the ordinary command write that actually asserted the stall.
data Instance = Instance !Live !(Maybe String) !CString !(Maybe (Word64,Word64))

foreign export ccall nds_hs_gpu_create :: IO (Ptr ())
foreign export ccall nds_hs_gpu_call :: Ptr () -> Ptr Word64 -> Ptr Word64 -> IO CInt
foreign export ccall nds_hs_gpu_destroy :: Ptr () -> IO ()

nds_hs_gpu_create :: IO (Ptr ())
nds_hs_gpu_create = handle (\(_ :: SomeException) -> pure nullPtr) $ do
  little <- alloca $ \p -> do
    poke (p :: Ptr Word64) 1
    (==1) <$> peek (castPtr p :: Ptr Word8)
  when (sizeOf (nullPtr :: Ptr ()) /= 8 || not little) (fail "GPU service requires a little-endian 64-bit host")
  bracketOnError (mallocArray (256*384)) free $ \pixels -> do
    fillBytes pixels 0 (256*384*4)
    device <- newLive 0 pixels
    ref <- newIORef (Instance device Nothing nullPtr Nothing)
    castStablePtrToPtr <$> newStablePtr ref

nds_hs_gpu_destroy :: Ptr () -> IO ()
nds_hs_gpu_destroy pointer = when (pointer/=nullPtr) $ do
  let stable=castPtrToStablePtr pointer
  ref <- deRefStablePtr stable
  Instance device _ text _ <- readIORef ref
  free (livePixels device)
  when (text/=nullPtr) (free text)
  freeStablePtr stable

nds_hs_gpu_call :: Ptr () -> Ptr Word64 -> Ptr Word64 -> IO CInt
nds_hs_gpu_call pointer request reply
  | pointer==nullPtr || request==nullPtr || reply==nullPtr = pure 1
  | otherwise = do
      ref <- deRefStablePtr (castPtrToStablePtr pointer)
      Instance device terminal previous origin <- readIORef ref
      when (previous/=nullPtr) (free previous)
      -- Pointer validity is the C caller's ABI obligation. All Haskell/model
      -- exceptions are caught, make the device terminal, and never unwind C++.
      result <- try $ do
        version <- peekElemOff request 0
        op <- peekElemOff request 1
        now <- peekElemOff request 2
        cpu <- peekElemOff request 3
        address <- peekElemOff request 4
        width <- peekElemOff request 5
        value <- peekElemOff request 6
        scope <- peekElemOff request 7
        when (version/=2) (fail "GPU service ABI version mismatch")
        when (sizeOf (nullPtr :: Ptr ()) /= 8) (fail "GPU service requires a 64-bit host")
        case terminal of Just message | op/=5 -> fail message; _ -> pure ()
        when (op `elem` [1,2,3,4,9] && (cpu>1 || width `notElem` [1,2,4] || address>0xffffffff || value>0xffffffff)) (fail "invalid GPU bus request")
        when (op `elem` [1,2,3,4,9] && address .&. (width-1)/=0) (fail "unaligned GPU bus request")
        let commandWrite=cpu==0 && width==4 && address>=0x04000400 && address<0x040005cc
            stalledBefore=chipStalled (tcChip (liveGX device))
        when (scope/=0 && not (op==9 || op==2 && commandWrite)) (fail "invalid GPU instruction scope")
        when (op==9 && (cpu/=0 || width/=4 || scope==0 || not stalledBefore || origin/=Just (scope,now)))
          (fail "GX continuation has no matching instruction stall origin")
        let c=fromIntegral cpu; w=fromIntegral width; a=fromIntegral address; v=fromIntegral value
            syncMemory = do
              when (maybe False (<=now) (deadline device)) (fail "GPU memory request before due deadline")
              (st,fx) <- advanceLive now device
              when (fx/=noEffects) (fail "GPU memory synchronization produced an unserviced effect")
              pure st
        (st,fx,out) <- case op of
          0 -> do (st,fx) <- advanceLive now device; pure (st,fx,0)
          1 -> do (st,out) <- readIORegister now c w a device; pure (st,noEffects,fromIntegral out)
          2 -> do (st,fx) <- writeIORegister now c w a v device; pure (st,fx,0)
          3 -> do st <- syncMemory
                  out <- either fail pure (readGpuMemory (liveMaps st) (livePower st) (liveMemory st) c w a)
                  pure (st,noEffects,fromIntegral out)
          4 -> do st <- syncMemory
                  memory <- either fail pure (writeGpuMemory (liveMaps st) (livePower st) (liveMemory st) c w a v)
                  pure (st { liveMemory=memory },noEffects,0)
          5 -> do fillBytes (livePixels device) 0 (256*384*4)
                  st <- newLive now (livePixels device)
                  pure (st,noEffects,0)
          6 -> do when (cpu>1) (fail "invalid IF acknowledge CPU")
                  (st,fx) <- acknowledgeIF now c device
                  pure (st,fx,0)
          7 -> do when (now/=liveTime device) (fail "FRAME query must use current GPU time")
                  pure (device,noEffects,0)
          8 -> do (st,fx) <- startFrame now value device; pure (st,fx,0)
          9 -> do (st,fx) <- writeIOContinuation now a v device; pure (st,fx,0)
          _ -> fail "unsupported GPU service operation"
        -- Force every ABI-visible scalar (including lazy MMIO/memory reads)
        -- inside the exception boundary before committing the new state.
        putReply reply st fx out 0 nullPtr
        let nextOrigin
              | not (chipStalled (tcChip (liveGX st))) = Nothing
              | op==2 && commandWrite && scope/=0 && not stalledBefore = Just (scope,now)
              | maybe False ((==now) . snd) origin = origin
              | otherwise = Nothing
        pure (st,nextOrigin)
      case result of
        Left (exception :: SomeException) -> do
          let message=displayException exception
          text <- newCString message
          writeIORef ref (Instance device (Just message) text Nothing)
          putReply reply device noEffects 0 1 text
          pure 1
        Right (st,nextOrigin) -> do
          -- Commit before the host applies IRQ/DMA effects (which can perform
          -- another synchronous bus call at this same timestamp).
          writeIORef ref (Instance st Nothing nullPtr nextOrigin)
          pure 0

putReply :: Ptr Word64 -> Live -> Effects -> Word64 -> Word64 -> CString -> IO ()
putReply out st effects value status text = do
  let chip=tcChip (liveGX st)
      flags=(if chipStalled chip then bit 0 else 0) .|.
            (if chipDmaRequest chip then bit 1 else 0) .|.
            (if frameCompleted effects then bit 2 else 0) .|.
            (if livePixelsValid st then bit 3 else 0)
  pokeElemOff out 0 2
  pokeElemOff out 1 status
  pokeElemOff out 2 value
  pokeElemOff out 3 (maybe maxBound id (deadline st))
  pokeElemOff out 4 (irqSet9 effects)
  pokeElemOff out 5 (irqClear9 effects)
  pokeElemOff out 6 (irqSet7 effects)
  pokeElemOff out 7 (irqClear7 effects)
  pokeElemOff out 8 (dma9 effects)
  pokeElemOff out 9 (dma7 effects)
  pokeElemOff out 10 flags
  pokeElemOff out 11 (liveFrame st)
  pokeElemOff out 12 (if livePixelsValid st then fromIntegral (ptrToWordPtr (livePixels st)) else 0)
  pokeElemOff out 13 (if livePixelsValid st then 256*384*4 else 0)
  pokeElemOff out 14 (fromIntegral (ptrToWordPtr text))
  pokeElemOff out 15 0
