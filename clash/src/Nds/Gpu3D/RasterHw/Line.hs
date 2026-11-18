{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- | The line controller: the frame sequence around the pixel engine, and
-- the per-line work that is not polygon rasterisation.
--
-- Two line slots hold both layers of a line (top and lower, 142 bits a
-- pixel). For every line @y@ the controller
--
-- 1. loads slot @y mod 2@: the top layer from @ClearBuffers@ (CLEAR_COLOR
--    or the rear-plane image, 'clearColourPixel' / 'clearImagePixel'), the
--    lower layer from external memory (production never clears it);
-- 2. lets the pixel engine render line @y@ into it;
-- 3. runs the final pass of line @y - 1@ ('finalPixelWith') in the other
--    slot, with line @y - 2@'s polygon IDs and depths from the ID buffer
--    and line @y@'s from this slot, writing the output colours (with
--    @RenderXPos@ applied, 'outputSource') to the output line buffer and
--    line @y - 1@'s IDs and depths to the ID buffer;
-- 4. writes line @y - 1@'s lower layer back to external memory (the output
--    writer streams the output line concurrently);
--
-- and line 191 gets its final pass and write-back after rendering. At the
-- end of the frame the stencil buffer and the previous-mask flag are
-- written after the lower layer (a snapshot of the state carried to the
-- next frame).
--
-- External layouts: lower layer line @y@ at @bLower + y*3072@: colour and
-- attribute of pixel @x@ ('packCA') at @+8x@, depths of pixels @2k@ (bits
-- 0-23) and @2k+1@ (bits 32-55) at @+2048+8k@; the snapshot at
-- @bLower + 0x90000@ (32 stencil words, then the flag). Output line @y@ at
-- @bOut + y*1024@, two pixels a word.
module Nds.Gpu3D.RasterHw.Line
  ( LPh (..)
  , LcSt (..)
  , lc0
  , LcIn (..)
  , LcOut (..)
  , lcStep
  , OwSt (..)
  , ow0
  , owStep
  , snapOffset
  ) where

import Prelude

import Data.Bits (shiftL, shiftR, testBit, (.&.), (.|.))
import Data.Word (Word16, Word32)
import GHC.Generics (Generic)

import Clash.Prelude (BitVector, Index, NFDataX, Unsigned, resize)
import qualified Clash.Prelude as C

import Nds.Gpu3D.Mem (MemAddr, MemReq (..))
import Nds.Gpu3D.PolyRam (FrameDesc (..))
import Nds.Gpu3D.Render
  ( Nbr (..), Px (..), clearColourPixel, clearImageOffset, clearImagePixel, finalPixelWith
  , fogDensityWith, outputSource )
import Nds.Gpu3D.RasterHw.Types

data LPh
  = LIdle
  | LToon !(Index 32)
  | LLoad
  | LRender
  | LFinal
  | LDrain
  | LSnap
  | LDone
  deriving (Eq, Generic, Show, NFDataX)

-- | Offset of the carried-state snapshot from the lower layer base.
snapOffset :: MemAddr
snapOffset = 0x90000

data LcSt = LcSt
  { lcPh    :: !LPh
  , lcRegs  :: !RegsHw
  , lcBases :: !Bases
  , lcDesc  :: !FrameDesc
  , lcY     :: !(Unsigned 8)     -- ^ line being loaded / rendered
  , lcFy    :: !(Unsigned 8)     -- ^ line in final pass / write-back
  -- loader
  , ldX     :: !(Unsigned 9)     -- ^ next pixel to write
  , ldIssK  :: !(Unsigned 8)     -- ^ lower words issued: pair
  , ldIssM  :: !(Unsigned 2)     -- ^ ... and word in the pair
  , ldOutL  :: !(Unsigned 5)
  , ldFillL :: !(Unsigned 5)
  , ldWpL   :: !(Unsigned 4)
  , ldRpL   :: !(Unsigned 4)
  , ldStage :: !(Unsigned 2)     -- ^ next lower word to pop (0 CA even, 1 CA odd, 2 depths)
  , ldCaA   :: !(BitVector 64)
  , ldCaB   :: !(BitVector 64)
  , ldOdd   :: !(Maybe (BitVector 64, BitVector 64))  -- ^ odd pixel's CA and depth word
  , ldIx    :: !(Unsigned 9)     -- ^ image issue cursor
  , ldIh    :: !Bool             -- ^ slot 3 read of the event is due
  , ldOutI  :: !(Unsigned 4)
  , ldFillI :: !(Unsigned 4)
  , ldWpI   :: !(Unsigned 3)
  , ldRpI   :: !(Unsigned 3)
  , ldCur2, ldCur3, ldNxt2, ldNxt3 :: !(BitVector 64)
  , ldNxtN  :: !(Unsigned 2)
  -- final pass
  , fnC     :: !(Unsigned 9)
  , fnL     :: !Nbr
  , fnCen   :: !(LayerPx, LayerPx, Nbr, Nbr)
  -- write-back
  , dnK     :: !(Unsigned 8)
  , dnS     :: !(Unsigned 2)     -- ^ 0 prime, 1 even CA, 2 odd CA, 3 depths
  , dnD0    :: !Word32
  , dnD1    :: !Word32
  -- snapshot
  , snK     :: !(Unsigned 6)
  , snPrime :: !Bool
  } deriving (Eq, Generic, Show, NFDataX)

lc0 :: LcSt
lc0 = LcSt
  { lcPh = LIdle, lcRegs = regsHw0, lcBases = Bases 0 0 0 0 0, lcDesc = FrameDesc 0 0
  , lcY = 0, lcFy = 0
  , ldX = 0, ldIssK = 0, ldIssM = 0, ldOutL = 0, ldFillL = 0, ldWpL = 0, ldRpL = 0, ldStage = 0
  , ldCaA = 0, ldCaB = 0, ldOdd = Nothing, ldIx = 0, ldIh = False, ldOutI = 0, ldFillI = 0
  , ldWpI = 0, ldRpI = 0, ldCur2 = 0, ldCur3 = 0, ldNxt2 = 0, ldNxt3 = 0, ldNxtN = 0
  , fnC = 0, fnL = Nbr 0 0, fnCen = (0, 0, Nbr 0 0, Nbr 0 0)
  , dnK = 0, dnS = 0, dnD0 = 0, dnD1 = 0, snK = 0, snPrime = True }
  where
    regsHw0 = RegsHw 0 0 0 0 0 0 0 (C.repeat 0) (C.repeat 0) (C.repeat 0) 0

-- Input and output records are lazy (see "Nds.Gpu3D.RasterHw.Front").
data LcIn = LcIn
  { liStart    :: Maybe (RegsHw, Bases, FrameDesc)
  , liLineDone :: Bool                    -- ^ pixel engine finished the render line
  , liSlot     :: C.Vec 2 (LayerPx, LayerPx)  -- ^ line slots at last cycle's addresses
  , liIdBuf    :: BitVector 30            -- ^ ID buffer at last cycle's address
  , liStencil  :: BitVector 32            -- ^ stencil word at last cycle's address
  , liPrevMask :: Bool
  , liLowReady :: Bool
  , liLowResp  :: Maybe (BitVector 64)
  , liLowHead  :: BitVector 64            -- ^ lower FIFO at the read pointer
  , liTexReady :: Bool
  , liTexResp  :: Maybe (BitVector 64)
  , liImgHead  :: BitVector 64            -- ^ image FIFO at the read pointer
  , liOwIdle   :: Bool                    -- ^ output writer idle
  } deriving (Generic, NFDataX)

data LcOut = LcOut
  { loRender   :: Maybe (Unsigned 8, Unsigned 1)  -- ^ render line and slot
  , loSlotRd   :: C.Vec 2 (Unsigned 8)
  , loSlotWr   :: C.Vec 2 (Maybe (Unsigned 8, (LayerPx, LayerPx)))
  , loIdRd     :: Unsigned 8
  , loIdWr     :: Maybe (Unsigned 8, BitVector 30)
  , loOutWr    :: Maybe (Unsigned 8, BitVector 23)
  , loOwStart  :: Maybe (Unsigned 8)      -- ^ start the output writer on a line
  , loStRd     :: Unsigned 5
  , loLowReq   :: Maybe MemReq
  , loLowFifoW :: Maybe (Unsigned 4, BitVector 64)
  , loLowRp    :: Unsigned 4
  , loTexReq   :: Maybe MemReq
  , loImgFifoW :: Maybe (Unsigned 3, BitVector 64)
  , loImgRp    :: Unsigned 3
  , loToon     :: Maybe (Unsigned 5, Word16)
  , loFrameStart :: Bool
  , loBusy     :: Bool
  , loDone     :: Bool
  , loRegs     :: RegsHw
  , loBases    :: Bases
  , loDesc     :: FrameDesc
  , loLoadPh   :: Bool                    -- ^ the texture port belongs to the loader
  , loSnapPh   :: Bool                    -- ^ the stencil read port belongs to the snapshot
  } deriving (Generic, NFDataX)

------------------------------------------------------------------------------

lowerLine :: Bases -> Unsigned 8 -> MemAddr
lowerLine b y = bLower b + resize y * 3072

-- | Is pixel @x@ an image fetch event (a new slot 2/3 word)?
imgEvent :: Word32 -> Unsigned 9 -> Bool
imgEvent c2 x = x == 0 || ((c2 `shiftR` 16) + fromIntegral x) .&. 3 == 0

half :: BitVector 64 -> Word32 -> Word16
half w k = fromIntegral (w `shiftR` (16 * fromIntegral (k .&. 3)))

-- | The output line position of line pixel @x@, if shown.
outPos :: Word16 -> Unsigned 9 -> Maybe (Unsigned 8)
outPos xpos x
  | testBit xpos 8 =
      let zs = min 256 (max 0 (512 - fromIntegral xpos)) :: Int
          j = fromIntegral x + zs
      in if j < 256 then Just (fromIntegral j) else Nothing
  | otherwise =
      let j = fromIntegral x - fromIntegral xpos :: Int
      in if j >= 0 then Just (fromIntegral j) else Nothing

nbrOfTop :: LayerPx -> Nbr
nbrOfTop t = let (_, d, a) = unpackLayer t in Nbr (a `shiftR` 24) d

nbrOfId :: BitVector 30 -> Nbr
nbrOfId v = Nbr (fromIntegral (v `shiftR` 24)) (fromIntegral (v .&. 0xFFFFFF))

idOfTop :: LayerPx -> BitVector 30
idOfTop t = let (_, d, a) = unpackLayer t in (fromIntegral (a `shiftR` 24) `shiftL` 24) .|. fromIntegral (d .&. 0xFFFFFF)

noOut :: LcSt -> LcOut
noOut s = LcOut
  { loRender = Nothing, loSlotRd = C.repeat 0, loSlotWr = C.repeat Nothing, loIdRd = 0, loIdWr = Nothing
  , loOutWr = Nothing, loOwStart = Nothing, loStRd = 0, loLowReq = Nothing, loLowFifoW = Nothing
  , loLowRp = ldRpL s, loTexReq = Nothing, loImgFifoW = Nothing, loImgRp = ldRpI s, loToon = Nothing
  , loFrameStart = False, loBusy = lcPh s /= LIdle && lcPh s /= LDone, loDone = False
  , loRegs = lcRegs s, loBases = lcBases s, loDesc = lcDesc s
  , loLoadPh = lcPh s == LLoad, loSnapPh = lcPh s == LSnap }

-- | Reset the loader for line @y@.
startLoad :: Unsigned 8 -> LcSt -> LcSt
startLoad y s = s
  { lcPh = LLoad, lcY = y, ldX = 0, ldIssK = 0, ldIssM = 0, ldOutL = 0, ldFillL = 0, ldWpL = 0, ldRpL = 0
  , ldStage = 0, ldOdd = Nothing, ldIx = 0, ldIh = False, ldOutI = 0, ldFillI = 0, ldWpI = 0, ldRpI = 0
  , ldNxtN = 0 }

startFinal :: Unsigned 8 -> LcSt -> LcSt
startFinal fy s = s { lcPh = LFinal, lcFy = fy, fnC = 0 }

-- | One cycle of the line controller.
lcStep :: LcSt -> LcIn -> (LcSt, LcOut)
lcStep s i = case lcPh s of
  LIdle -> case liStart i of
    Just (r, b, d) -> (s { lcPh = LToon 0, lcRegs = r, lcBases = b, lcDesc = d }, (noOut s) { loFrameStart = True })
    Nothing -> (s, noOut s)
  LToon k ->
    let o = (noOut s) { loToon = Just (fromIntegral k, rhToonTable (lcRegs s) C.!! k) }
    in (if k == 31 then startLoad 0 s else s { lcPh = LToon (k + 1) }, o)
  LLoad -> loadStep s i
  LRender ->
    -- The outputs must not depend on the line-done input (the pixel engine
    -- reads the render line from them).
    let y = lcY s
        o = (noOut s) { loRender = Just (y, resize y) }
        s'
          | not (liLineDone i) = s
          | y == 0 = startLoad 1 s
          | otherwise = startFinal (y - 1) s
    in (s', o)
  LFinal
    | fnC s == 0 && not (liOwIdle i) -> (s, noOut s)
    | otherwise -> finalStep s i
  LDrain -> drainStep s i
  LSnap -> snapStep s i
  LDone
    | liOwIdle i -> (s { lcPh = LIdle }, (noOut s) { loDone = True })
    | otherwise -> (s, noOut s)

------------------------------------------------------------------------------
-- Load

loadStep :: LcSt -> LcIn -> (LcSt, LcOut)
loadStep s i = (s4, o)
  where
    r = lcRegs s
    b = lcBases s
    y = lcY s
    slot = resize y :: Unsigned 1
    c1 = rhClear1 r
    c2 = rhClear2 r
    image = testBit (rhDispCnt r) 14
    -- lower reads
    canL = ldIssK s < 128 && ldOutL s + ldFillL s < 16
    addrL = case ldIssM s of
      0 -> lowerLine b y + (resize (ldIssK s) `shiftL` 4)
      1 -> lowerLine b y + (resize (ldIssK s) `shiftL` 4) + 8
      _ -> lowerLine b y + 2048 + (resize (ldIssK s) `shiftL` 3)
    reqL = if canL then Just (MemRead addrL) else Nothing
    issL = canL && liLowReady i
    gotL = maybe False (const True) (liLowResp i)
    -- image reads
    yoff = ((c2 `shiftR` 24) + fromIntegral y) .&. 0xFF
    widx x = (((c2 `shiftR` 16) + fromIntegral x) .&. 0xFF) `shiftR` 2
    imgAddr hi = bTex b + (if hi then 0x60000 else 0x40000) + fromIntegral (yoff `shiftL` 9)
                   + fromIntegral (widx (ldIx s) `shiftL` 3)
    ixEvent = imgEvent c2 (ldIx s)
    canI = image && ldIx s < 256 && ixEvent && ldOutI s + ldFillI s < 8
    reqI = if canI then Just (MemRead (imgAddr (ldIh s))) else Nothing
    issI = canI && liTexReady i
    gotI = maybe False (const True) (liTexResp i)
    s1 = s { ldIssK = if issL && ldIssM s == 2 then ldIssK s + 1 else ldIssK s
           , ldIssM = if issL then (if ldIssM s == 2 then 0 else ldIssM s + 1) else ldIssM s
           , ldOutL = ldOutL s + (if issL then 1 else 0) - (if gotL then 1 else 0)
           , ldWpL = if gotL then ldWpL s + 1 else ldWpL s
           , ldIx = if image && ldIx s < 256 && (not ixEvent || (issI && ldIh s)) then ldIx s + 1 else ldIx s
           , ldIh = if issI then not (ldIh s) else ldIh s
           , ldOutI = ldOutI s + (if issI then 1 else 0) - (if gotI then 1 else 0)
           , ldWpI = if gotI then ldWpI s + 1 else ldWpI s }
    -- image prefetch into nxt
    popI = image && ldNxtN s < 2 && ldFillI s > 0
    s2 = s1 { ldNxt2 = if popI && ldNxtN s == 0 then liImgHead i else ldNxt2 s
            , ldNxt3 = if popI && ldNxtN s == 1 then liImgHead i else ldNxt3 s
            , ldRpI = if popI then ldRpI s + 1 else ldRpI s
            , ldNxtN = if popI then ldNxtN s + 1 else ldNxtN s }
    -- pixel writes
    x = ldX s
    ev = image && imgEvent c2 x
    imgOk = not ev || ldNxtN s == 2
    (cur2, cur3) = if ev then (ldNxt2 s, ldNxt3 s) else (ldCur2 s, ldCur3 s)
    topOf =
      if image
        then let off = clearImageOffset c2 (fromIntegral y) (fromIntegral x)
                 k = (off `shiftR` 1) .&. 3
             in clearImagePixel c1 (half cur2 k) (half cur3 k)
        else clearColourPixel c1 c2
    pixelOf ca dw =
      let (tc, td, ta) = topOf
          (lc, la) = unpackCA ca
          ld = fromIntegral (if testBit x 0 then dw `shiftR` 32 else dw) .&. 0xFFFFFF
      in (packLayer tc td ta, packLayer lc ld la)
    headL = liLowHead i
    fillL = ldFillL s
    -- odd pixel pending: write it, and pop the next pair's first word alongside
    (wr, s3)
      | x >= 256 = (Nothing, s2)
      | Just (ca, dw) <- ldOdd s =
          if imgOk
            then let pop = fillL > 0 && x < 255
                     st = s2 { ldX = x + 1, ldOdd = Nothing
                             , ldCur2 = cur2, ldCur3 = cur3
                             , ldNxtN = if ev then (if popI then 1 else 0) else ldNxtN s2 }
                     st' = if pop then st { ldCaA = headL, ldStage = 1, ldRpL = ldRpL s + 1 } else st
                 in (Just (x, pixelOf ca dw), fixFill st' (if pop then 1 else 0))
            else (Nothing, fixFill s2 0)
      | fillL > 0 && ldStage s == 0 = (Nothing, fixFill (s2 { ldCaA = headL, ldStage = 1, ldRpL = ldRpL s + 1 }) 1)
      | fillL > 0 && ldStage s == 1 = (Nothing, fixFill (s2 { ldCaB = headL, ldStage = 2, ldRpL = ldRpL s + 1 }) 1)
      | fillL > 0 && ldStage s == 2 && imgOk =
          let st = s2 { ldX = x + 1, ldStage = 0, ldRpL = ldRpL s + 1, ldOdd = Just (ldCaB s, headL)
                      , ldCur2 = cur2, ldCur3 = cur3
                      , ldNxtN = if ev then (if popI then 1 else 0) else ldNxtN s2 }
          in (Just (x, pixelOf (ldCaA s) headL), fixFill st 1)
      | otherwise = (Nothing, fixFill s2 0)
    fixFill st popped = st { ldFillL = fillL + (if gotL then 1 else 0) - popped
                           , ldFillI = ldFillI s + (if gotI then 1 else 0) - (if popI then 1 else 0) }
    done = x >= 256
    s4 = if done then s3 { lcPh = LRender } else s3
    o = (noOut s)
      { loSlotWr = C.replace slot (fmap (\(xx, v) -> (resize xx, v)) wr) (C.repeat Nothing)
      , loLowReq = reqL
      , loLowFifoW = fmap (\w -> (ldWpL s, w)) (liLowResp i)
      , loTexReq = reqI
      , loImgFifoW = fmap (\w -> (ldWpI s, w)) (liTexResp i) }

------------------------------------------------------------------------------
-- Final pass

finalStep :: LcSt -> LcIn -> (LcSt, LcOut)
finalStep s i = (s', o)
  where
    r = lcRegs s
    fy = lcFy s
    fs = resize fy :: Unsigned 1
    fb = 1 - fs
    c = fnC s
    border = Nbr ((rhClear1 r `shiftR` 24) .&. 0x3F) (((rhClear2 r .&. 0x7FFF) * 0x200) + 0x1FF)
    cur = liSlot i C.!! fs
    below = if fy == 191 then border else nbrOfTop (fst (liSlot i C.!! fb))
    above = if fy == 0 then border else nbrOfId (liIdBuf i)
    -- data for x = c - 1 arrives when 1 <= c <= 256
    arriving = c >= 1 && c <= 256
    (curT, curL) = cur
    rightN = if arriving then nbrOfTop curT else border
    -- process x = c - 2 when 2 <= c <= 257
    proc = c >= 2
    x = c - 2
    (cT, cL, cU, cD) = fnCen s
    fogTab k = fromIntegral (rhFogTable r C.!! (fromIntegral (min 33 k) :: Int)) :: Word32
    density = fogDensityWith (rhFogOffset r) (rhFogShift r) fogTab
    edgeTab k = rhEdgeTable r C.!! (fromIntegral (k .&. 7) :: Int)
    px = pxOfLayers cT cL
    leftN = if x == 0 then border else fnL s
    px' = finalPixelWith (rhDispCnt r) (rhFogColor r) edgeTab density leftN rightN cU cD px
    (t', l') = layersOfPx px'
    wrBack = if proc then Just (resize x, (t', l')) else Nothing
    idW = if proc then Just (resize x, idOfTop cT) else Nothing
    outW = if proc then fmap (\j -> (j, packColour23 (pxC px'))) (outPos (rhXPos r) x) else Nothing
    s1 = s { fnC = c + 1
           , fnL = if proc then nbrOfTop cT else fnL s
           , fnCen = if arriving then (curT, curL, above, below) else fnCen s }
    s' = if c == 257
           then s1 { lcPh = LDrain, dnK = 0, dnS = 0 }
           else s1
    rd = resize c :: Unsigned 8
    o = (noOut s)
      { loSlotRd = C.replace fb rd (C.replace fs rd (C.repeat 0))
      , loSlotWr = C.replace fs wrBack (C.repeat Nothing)
      , loIdRd = rd
      , loIdWr = idW
      , loOutWr = outW
      , loOwStart = if c == 257 then Just fy else Nothing }

------------------------------------------------------------------------------
-- Lower layer write-back

drainStep :: LcSt -> LcIn -> (LcSt, LcOut)
drainStep s i = (s', o)
  where
    b = lcBases s
    fy = lcFy s
    fs = resize fy :: Unsigned 1
    k = dnK s
    ready = liLowReady i
    (_, lowL) = liSlot i C.!! fs
    (lc, ld, la) = unpackLayer lowL
    base = lowerLine b fy
    (req, rdX, s1) = case dnS s of
      0 -> (Nothing, resize k `shiftL` 1, s { dnS = 1 })
      1 -> let rq = MemWrite (base + (resize k `shiftL` 4)) 0xFF (packCA lc la)
           in ( Just rq
              , if ready then (resize k `shiftL` 1) + 1 else resize k `shiftL` 1
              , if ready then s { dnS = 2, dnD0 = ld } else s )
      2 -> let rq = MemWrite (base + (resize k `shiftL` 4) + 8) 0xFF (packCA lc la)
           in ( Just rq
              , if ready then (resize (k + 1) `shiftL` 1) else (resize k `shiftL` 1) + 1
              , if ready then s { dnS = 3, dnD1 = ld } else s )
      _ -> let dw = (fromIntegral (dnD1 s) `shiftL` 32) .|. fromIntegral (dnD0 s) :: BitVector 64
               rq = MemWrite (base + 2048 + (resize k `shiftL` 3)) 0xFF dw
           in ( Just rq
              , resize (k + 1) `shiftL` 1
              , if ready then s { dnS = 1, dnK = k + 1 } else s )
    lastDone = dnS s == 3 && ready && k == 127
    s' | lastDone =
           if fy == 191
             then s1 { lcPh = LSnap, snK = 0, snPrime = True }
             else if lcY s == 191 && fy == 190
               then startFinal 191 s1
               else startLoad (lcY s + 1) s1
       | otherwise = s1
    o = (noOut s)
      { loSlotRd = C.replace fs (rdX :: Unsigned 8) (C.repeat 0)
      , loLowReq = req }

------------------------------------------------------------------------------
-- Snapshot

snapStep :: LcSt -> LcIn -> (LcSt, LcOut)
snapStep s i = (s', o)
  where
    b = lcBases s
    k = snK s
    ready = liLowReady i
    addr = bLower b + snapOffset + (resize k `shiftL` 3)
    (req, s1)
      | snPrime s = (Nothing, s { snPrime = False })
      | k < 32 = (Just (MemWrite addr 0xFF (resize (liStencil i))), if ready then s { snK = k + 1 } else s)
      | otherwise = (Just (MemWrite addr 0xFF (if liPrevMask i then 1 else 0)), if ready then s { snK = k + 1 } else s)
    finished = not (snPrime s) && k == 32 && ready
    s' = if finished then s1 { lcPh = LDone } else s1
    -- read the word due next cycle
    nextK = if not (snPrime s) && ready then k + 1 else k
    o = (noOut s) { loStRd = resize nextK, loLowReq = req }

------------------------------------------------------------------------------
-- Output writer

data OwSt = OwSt
  { owRun  :: !Bool
  , owLine :: !(Unsigned 8)
  , owK    :: !(Unsigned 8)
  , owS    :: !(Unsigned 2)    -- ^ 0 prime, 1 low half, 2 high half, 3 retry
  , owLo   :: !Word32
  , owHi   :: !Word32
  } deriving (Eq, Generic, Show, NFDataX)

ow0 :: OwSt
ow0 = OwSt False 0 0 0 0 0

-- | The output writer: 128 words for a line from the output line buffer.
-- Inputs: start, XPos, output base, output buffer data (address issued last
-- cycle), port ready. Outputs: buffer read address, port request, idle.
owStep :: OwSt -> (Maybe (Unsigned 8), Word16, MemAddr, BitVector 23, Bool)
       -> (OwSt, (Unsigned 8, Maybe MemReq, Bool))
owStep s (start, xpos, base, dat, ready)
  | not (owRun s) =
      -- idle depends on the state only (the line controller waits on it)
      (maybe s (\y -> OwSt True y 0 0 0 0) start, (0, Nothing, True))
  | otherwise = case owS s of
      0 -> (s { owS = 1 }, (j0, Nothing, False))
      1 -> (s { owS = 2, owLo = colourAt j0 }, (j0 + 1, Nothing, False))
      2 -> let hi = colourAt (j0 + 1)
               rq = MemWrite addr 0xFF (word (owLo s) hi)
           in if ready
                then (nextWord, (j0 + 2, Just rq, False))
                else (s { owS = 3, owHi = hi }, (j0 + 2, Just rq, False))
      _ -> let rq = MemWrite addr 0xFF (word (owLo s) (owHi s))
           in if ready then (nextWord, (j0 + 2, Just rq, False)) else (s, (j0 + 2, Just rq, False))
  where
    j0 = resize (owK s) `shiftL` 1 :: Unsigned 8
    colourAt j = case outputSource xpos (fromIntegral j) of
      Just _ -> unpackColour23 dat
      Nothing -> 0
    addr = base + resize (owLine s) * 1024 + (resize (owK s) `shiftL` 3)
    word lo hi = (fromIntegral hi `shiftL` 32) .|. fromIntegral lo :: BitVector 64
    nextWord = if owK s == 127 then s { owRun = False } else s { owK = owK s + 1, owS = 1 }
