{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The scanline rasteriser: renders one latched frame (the @Render*@
-- registers and the render list in polygon RAM) into 192 output lines,
-- reproducing 'Nds.Gpu3D.Render.renderFrameFrom' exactly, including the
-- lower layer, stencil and previous-mask state carried to the next frame.
--
-- Blocks ("Nds.Gpu3D.RasterHw.*"):
--
-- * 'frontEnd' (Front): per line, the active polygons of the render list
--   in list order, read with their vertices through the polygon port;
-- * 'setupEngine' (Setup): per polygon line, the edge walk, both edges'
--   @Slope::Setup@ and values at the line, the span rules and the span
--   interpolator, as a 'SpanJob';
-- * 'pixStep' (Pixel): the pixel loops over the current line's buffers,
--   the shade back end 'shadePipe' behind the texture caches ('texCaches');
-- * 'lcStep' (Line): clear/load, final pass, lower-layer write-back, output
--   writer ('owStep') and the end-of-frame state snapshot.
--
-- Ports (all "Nds.Gpu3D.Mem" style; the board wrapper may merge them):
--
-- * polygon read: Y-ranges, render list, records, vertex RAM;
-- * texture read: texture slots at 'bTex' and palette slots at 'bPal'
--   (cache refills while rendering, rear-plane image rows while loading
--   a line; the two never overlap);
-- * lower read/write: the lower layer at 'bLower' and the snapshot;
-- * output write: 256 x 32-bit words per line at @bOut + y*1024@.
--
-- A start while busy is ignored and raises the sticky 'overrun' flag (the
-- chip keeps showing the previous frame; the DS would drop polygons).
module Nds.Gpu3D.RasterHw
  ( rasterHw
  , RasterIn (..)
  , RasterOut (..)
  , rasterTopEntity
  ) where

import Prelude

import Data.Bits (shiftR, testBit, (.&.))
import Data.Maybe (isJust)
import Data.Word (Word32)

import Clash.Annotations.TopEntity (PortName (..), TopEntity (..))
import Clash.Explicit.Prelude
  ( BitVector, Clock, Enable, KnownDomain, Reset, Signal, SNat (..), System
  , asyncRam, blockRamPow2, bundle, fromEnable, pack, register, toEnable
  , unbundle, unpack, (.&&.) )
import qualified Clash.Explicit.Prelude as C
import Clash.Explicit.Mealy (mealy)

import Nds.Gpu3D.Mem (MemReq (..))
import Nds.Gpu3D.PolyRam (FrameDesc (..))
import Nds.Gpu3D.RasterHw.Front (frontEnd)
import Nds.Gpu3D.RasterHw.Line
import Nds.Gpu3D.RasterHw.Pixel
import Nds.Gpu3D.RasterHw.Setup (setupEngine)
import Nds.Gpu3D.RasterHw.TexCache
import Nds.Gpu3D.RasterHw.Types
import Nds.Gpu3D.ShadePipe (PixelIn (..), ShadeCfg (..), shadePipe)

-- | Everything the rasteriser observes.
data RasterIn = RasterIn
  { riStart     :: Maybe (RegsHw, FrameDesc)
  , riBases     :: Bases
  , riPolyReady :: Bool
  , riPolyResp  :: Maybe (BitVector 64)
  , riTexReady  :: Bool
  , riTexResp   :: Maybe (BitVector 64)
  , riLowReady  :: Bool
  , riLowResp   :: Maybe (BitVector 64)
  , riOutReady  :: Bool
  }

-- | Everything the rasteriser drives.
data RasterOut = RasterOut
  { roPolyReq :: Maybe MemReq
  , roTexReq  :: Maybe MemReq
  , roLowReq  :: Maybe MemReq
  , roOutReq  :: Maybe MemReq
  , roBusy    :: Bool
  , roDone    :: Bool     -- ^ one cycle when the frame (and its output) is complete
  , roOverrun :: Bool     -- ^ sticky: a start arrived while busy
  }

texOnOf :: Word32 -> PixelIn -> Bool
texOnOf disp p = testBit disp 0 && (piTexParam p `shiftR` 26) .&. 0x7 /= 0

fmtOf :: PixelIn -> Word32
fmtOf p = (piTexParam p `shiftR` 26) .&. 0x7

-- | The rasteriser.
rasterHw
  :: forall dom. KnownDomain dom
  => Clock dom -> Reset dom -> Enable dom
  -> Signal dom RasterIn
  -> Signal dom RasterOut
rasterHw clk rst en inp = out
  where
    rin :: (RasterIn -> a) -> Signal dom a
    rin f = C.fmap f inp
    -- start, with the bases; the line controller only takes it when idle.
    -- (Combinational paths must not run from an output back into the same
    -- block's output constructor: every step function below builds its
    -- outputs from state and from inputs that do not depend on them.)
    startIn = (\i -> fmap (\(r, d) -> (r, riBases i, d)) (riStart i)) <$> inp
    overrun = register clk rst en False ((\o i busy -> o || (busy && isJust (riStart i))) <$> overrun <*> inp <*> lcBusy)

    ---------------------------------------------------------------- line controller
    lcO = mealy clk rst en lcStep lc0
      (LcIn <$> startIn <*> C.fmap poLineEnd pxO <*> slotData <*> idData <*> stData
            <*> C.fmap poPrevMask pxO <*> rin riLowReady <*> rin riLowResp <*> lowHead
            <*> texReadyLc <*> texRespLc <*> imgHead <*> owIdle)
    lcBusy = C.fmap loBusy lcO
    regs = C.fmap loRegs lcO
    lBases = C.fmap loBases lcO
    desc = C.fmap loDesc lcO
    disp = C.fmap rhDispCnt regs
    frameStart = C.fmap loFrameStart lcO
    render = C.fmap loRender lcO
    -- the texture port belongs to the loader in the load phase (rear-plane
    -- rows) and to the cache otherwise; neither has reads outstanding when
    -- the phase changes
    loading = C.fmap loLoadPh lcO

    ---------------------------------------------------------------- front end and setup
    (polyReq, recHead, rbWrite) = frontEnd clk rst en frameStart (C.fmap bPoly lBases)
      (C.fmap fdBank desc) (C.fmap fdCount desc) (rin riPolyReady) (rin riPolyResp) recPop
    (recPop, job) = setupEngine clk rst en frameStart disp (C.fmap rhAlphaRef regs) recHead rbWrite
                      (C.fmap poTake pxO)

    ---------------------------------------------------------------- pixel engine
    pxO = mealy clk rst en pixStep pix0
      (PixIn <$> job <*> C.fmap (fmap fst) render <*> renderData <*> stData <*> hit
             <*> pipeOut <*> sideData <*> disp)
    pipeIn = C.fmap poPipeIn pxO
    sideData = asyncRam clk clk en (SNat :: SNat 4) (C.fmap poSideRd pxO) (C.fmap poSideWr pxO)

    ---------------------------------------------------------------- shade pipe and caches
    pipeEn = toEnable (hit .&&. fromEnable en)
    cfg = (\r -> ShadeCfg (rhDispCnt r) (fromIntegral (rhAlphaRef r))) <$> regs
    (texAddr, infoAddr, palAddr, pipeOut) =
      shadePipe clk rst pipeEn cfg (C.fmap loToon lcO) pipeIn (C.fmap coTexD cache) (C.fmap coInfoD cache)
        (C.fmap coPalD cache)
    -- stage B holds a textured pixel that reads the palette
    needPalB = register clk rst pipeEn False
      ((\d mp -> case mp of
          Just p -> texOnOf d p && fmtOf p /= 7
          Nothing -> False) <$> disp <*> pipeIn)
    cacheIn = CacheIn <$> frameStart <*> hit
      <*> ((\d mp -> maybe False (texOnOf d) mp) <$> disp <*> pipeIn) <*> texAddr
      <*> ((\d mp -> maybe False (\p -> texOnOf d p && fmtOf p == 5) mp) <$> disp <*> pipeIn) <*> infoAddr
      <*> needPalB <*> palAddr
      <*> C.fmap bTex lBases <*> C.fmap bPal lBases
      <*> ((\l r -> not l && r) <$> loading <*> rin riTexReady)
      <*> ((\l r -> if l then Nothing else r) <$> loading <*> rin riTexResp)
    cache = texCaches clk rst en cacheIn
    hit = C.fmap coHit cache
    texReadyLc = (\l r -> l && r) <$> loading <*> rin riTexReady
    texRespLc = (\l r -> if l then r else Nothing) <$> loading <*> rin riTexResp
    texReq = (\o c -> case loTexReq o of
                 Just r -> Just r
                 Nothing -> coReq c) <$> lcO <*> cache

    ---------------------------------------------------------------- RAMs
    slotRam k =
      let isR = (\r -> fmap snd r == Just k) <$> render
          rd = (\r o p -> if r then poRamRd p else loSlotRd o C.!! k) <$> isR <*> lcO <*> pxO
          wr = (\r o p -> if r then poRamWr p else loSlotWr o C.!! k) <$> isR <*> lcO <*> pxO
          d = blockRamPow2 clk en (C.replicate (SNat :: SNat 256) 0) rd
                (C.fmap (fmap (\(a, (t, l)) -> (a, pack (t, l)))) wr)
      in C.fmap unpack d :: Signal dom (LayerPx, LayerPx)
    slot0 = slotRam 0
    slot1 = slotRam 1
    slotData = (\a b -> a C.:> b C.:> C.Nil) <$> slot0 <*> slot1
    renderData = (\r a b -> if fmap snd r == Just 1 then b else a) <$> render <*> slot0 <*> slot1
    idData = blockRamPow2 clk en (C.replicate (SNat :: SNat 256) 0) (C.fmap loIdRd lcO) (C.fmap loIdWr lcO)
    stRd = (\o p -> if loSnapPh o then loStRd o else poStRd p) <$> lcO <*> pxO
    stData = blockRamPow2 clk en (C.replicate (SNat :: SNat 32) 0) stRd (C.fmap poStWr pxO)
    outRamData = blockRamPow2 clk en (C.replicate (SNat :: SNat 256) 0) owRd (C.fmap loOutWr lcO)
    lowHead = asyncRam clk clk en (SNat :: SNat 16) (C.fmap loLowRp lcO) (C.fmap loLowFifoW lcO)
    imgHead = asyncRam clk clk en (SNat :: SNat 8) (C.fmap loImgRp lcO) (C.fmap loImgFifoW lcO)

    ---------------------------------------------------------------- output writer
    (owRd, outReq, owIdle) = unbundle (mealy clk rst en owStep ow0
      (bundle (C.fmap loOwStart lcO, C.fmap rhXPos regs, C.fmap bOut lBases, outRamData, rin riOutReady)))

    out = RasterOut <$> polyReq <*> texReq <*> C.fmap loLowReq lcO <*> outReq <*> lcBusy
            <*> C.fmap loDone lcO <*> overrun

-- | Concrete top entity: the rasteriser with flat ports.
{-# ANN rasterTopEntity
  (Synthesize
    { t_name = "nds_gpu3d_raster"
    , t_inputs =
        [ PortName "CLK"
        , PortName "RST"
        , PortName "EN"
        , PortName "IN"
        ]
    , t_output = PortName "OUT"
    }) #-}
rasterTopEntity
  :: Clock System -> Reset System -> Enable System
  -> Signal System RasterIn
  -> Signal System RasterOut
rasterTopEntity = rasterHw
{-# NOINLINE rasterTopEntity #-}
