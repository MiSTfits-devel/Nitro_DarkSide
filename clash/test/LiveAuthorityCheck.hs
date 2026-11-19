{-# LANGUAGE BangPatterns #-}
-- | Execute the same small bus/latch/timing script as an independent stock
-- melonDS fixture. stdout is data only, intended for exact record comparison.
module Main (main) where
import Control.Exception (bracket)
import Control.Monad (foldM)
import Data.Array.Unboxed
import Data.Bits
import Data.IORef
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import Data.List (foldl')
import Data.Word
import Foreign.Marshal.Alloc (free)
import Foreign.Marshal.Array
import Foreign.Marshal.Utils
import Numeric
import System.Environment
import System.IO
import Nds.Gpu.Live
import Nds.Gpu.Live2D
import Nds.Gpu.LiveMemory
import Nds.Gpu2D.Trace (readRegion8)
import Nds.Gpu3D.Timed
import Nds.Gpu3D.GxFront (Size(..))

num :: String -> Word32
num text = case readHex text of [(n,"")] -> n; _ -> error ("invalid hex "++text)
hex :: Word32 -> String
hex x=showHex x ""
get :: Either String a -> IO a
get=either fail pure
applyEffects :: IORef (Word64,Word64) -> Effects -> IO ()
applyEffects ref fx = modifyIORef' ref (\(a,b) -> ((a .&. complement (irqClear9 fx)) .|. irqSet9 fx,(b .&. complement (irqClear7 fx)) .|. irqSet7 fx))
advanceTo :: IORef (Word64,Word64) -> Word64 -> Live -> IO Live
advanceTo ref now s = case deadline s of
  Just d | d<=now -> do
    (next,fx) <- advanceLive d s
    applyEffects ref fx
    advanceTo ref now next
  _ -> do
    (next,fx) <- advanceLive now s
    applyEffects ref fx
    pure next
emit :: String -> Int -> [Word32] -> IO ()
emit tag i values=putStrLn (unwords (tag:map hex (fromIntegral i:values)))
snapshot :: Engine -> [Word32]
snapshot e = [b (eEnabled e),reg32 e 0] ++ eDispLatch e ++ map fromIntegral [eLayer e,eObj e,eBlank e] ++
  [reg32 e 0x28,reg32 e 0x38,reg32 e 0x2c,reg32 e 0x3c] ++ xy (eInternal e) ++ xy (eReload e) ++
  map fromIntegral [eBgY e,eBgMax e,eObjY e] ++ [b (eBgLatch e),b (eObjLatch e),eBgLine e,eObjLine e] ++
  map fromIntegral [eWin0 e,eWin1 e,eEva e,eEvb e,eEvy e]
  where b=fromIntegral.fromEnum;xy xs=[xs!!0,xs!!2,xs!!1,xs!!3]

main :: IO ()
main=do
  [path,framePath] <- getArgs
  script <- lines <$> readFile path
  withBinaryFile framePath WriteMode $ \frames ->
    bracket (mallocArray (256*384)) free $ \pixels -> do
      fillBytes pixels 0 (256*384*4)
      initial <- newLive 0 pixels
      interrupts <- newIORef (0,0)
      _ <- foldM (step interrupts frames) (initial,0) script
      pure ()
  where
    step _ _ pair line | null line || head line=='#' = pure pair
    step interrupts frames (s,index) line = case words line of
      [op,cpu,width,address,value] | op=="W" -> do
        let c=fromIntegral (num cpu);w=fromIntegral (num width);a=num address;v=num value
        st <- advanceTo interrupts (liveTime s) s
        result <- if a==0x04000214 then do
                    modifyIORef' interrupts (\(x,y) -> if c==0 then (x .&. complement (fromIntegral v),y) else (x,y .&. complement (fromIntegral v)))
                    (next,fx) <- acknowledgeIF (liveTime st) c st
                    applyEffects interrupts fx
                    pure next
                  else if a `shiftR` 24==4 then do
                    (next,fx) <- writeIORegister (liveTime st) c w a v st
                    applyEffects interrupts fx
                    pure next
                  else do memory <- get (writeGpuMemory (liveMaps st) (livePower st) (liveMemory st) c w a v)
                          pure st { liveMemory=memory }
        pure (result,index)
      ["R",cpu,width,address] -> do
        let c=fromIntegral (num cpu);w=fromIntegral (num width);a=num address
        st <- advanceTo interrupts (liveTime s) s
        (next,value) <- if a `shiftR` 24==4 then readIORegister (liveTime st) c w a st
                        else do v <- get (readGpuMemory (liveMaps st) (livePower st) (liveMemory st) c w a)
                                pure (st,v)
        emit "R" (index+1) [value]
        pure (next,index+1)
      ["S",engine] -> do
        emit "S" (index+1) (snapshot (if engine=="0" then liveA s else liveB s))
        pure (s,index+1)
      [op,engine,y,reset] | op `elem` ["P","Q","U","F"] -> do
        let n=read engine::Int;vc=read y;rst=reset/="0"
            alter e=case op of "P"->preDraw vc rst e;"Q"->postDraw rst e;"U"->updateWindows vc e;_->finishWindows e
            st=if n==0 then s { liveA=alter (liveA s),liveVCount=vc } else s { liveB=alter (liveB s),liveVCount=vc }
        pure (st,index)
      ["T",time] -> do st <- advanceTo interrupts (fromIntegral (num time)) s;pure (st,index)
      ["Z",vp,np,pp,sc,ss] ->
        let gx=liveGX s
        in pure (s { liveGX=gx { tcVertex=fromIntegral (num vp),tcNormal=fromIntegral (num np),tcPolygon=fromIntegral (num pp),tcSlotClock=fromIntegral (num sc),tcSlots=num ss,tcDebt=0,tcBusy=True } },index)
      ["G"] -> do
        st <- advanceTo interrupts (liveTime s) s
        let gx=liveGX st
        emit "G" (index+1) [fromIntegral (liveTime st),timedRead S32 0x04000600 gx,fromIntegral (tcDebt gx),fromIntegral (tcVertex gx),fromIntegral (tcNormal gx),fromIntegral (tcPolygon gx),fromIntegral (tcSlotClock gx),tcSlots gx]
        pure (st,index+1)
      ["X"] -> do
        fillBytes (livePixels s) 0 (256*384*4)
        fresh <- newLive 0 (livePixels s)
        writeIORef interrupts (0,0)
        pure (fresh,index)
      ["B"] -> do
        (st,fx) <- startFrame (liveTime s) 0 s
        applyEffects interrupts fx
        pure (st,index)
      ["L",time] -> do st <- advanceTo interrupts (fromIntegral (num time)) s;pure (st,index)
      ["I"] -> do
        (a,b) <- readIORef interrupts
        emit "I" (index+1) [fromIntegral a,fromIntegral b]
        pure (s,index+1)
      ["K"] -> do
        pixels <- peekArray (256*384) (livePixels s)
        BL.hPut frames (BB.toLazyByteString (foldMap BB.word32LE pixels))
        emit "K" (index+1) [256*384]
        pure (s,index+1)
      _ -> fail ("unknown action "++line)
