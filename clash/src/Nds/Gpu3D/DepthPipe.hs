{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}

-- | Streaming depth test with an external depth buffer.
--
-- Consumes one clipped span at a time, expands its endpoint depth values with the
-- production interpolator, and performs one read and (on a pass) one write per
-- visible pixel. The memory port is deliberately abstract: the board wrapper owns
-- the SDRAM arbitration and supplies the read response.
module Nds.Gpu3D.DepthPipe
  ( MemOp (..)
  , PixelOut (..)
  , DepthIn (..)
  , DepthOut (..)
  , DState (..)
  , depthStep
  , depthPipe
  , depthTopEntity
  ) where

import Prelude hiding ((&&), (||), (!!), map)

import Data.Int (Int32)

import Clash.Prelude
import qualified Clash.Explicit.Mealy as EM

import Nds.Gpu3D.Depth
import Nds.Gpu3D.Flat (Span (..), screenH, screenW)

-- | One external depth-buffer transaction.
data MemOp
  = MemNone
  | MemRead !Int32
  | MemWrite !Int32 !Int32
  deriving (Eq, Generic, Show, NFDataX)

-- | A surviving pixel.
data PixelOut = PixelOut
  { poX     :: !Int32
  , poY     :: !Int32
  , poColor :: !Int32
  } deriving (Eq, Generic, Show, NFDataX)

-- | Everything the engine observes in one cycle.
data DepthIn = DepthIn
  { diSpan       :: !(Maybe Span)
  , diClear      :: !Bool
  , diClearDepth :: !Int32
  , diMemReady   :: !Bool
  , diMemResp    :: !(Maybe Int32)
  , diOutReady   :: !Bool
  } deriving (Eq, Generic, Show, NFDataX)

-- | Everything the engine drives in one cycle.
data DepthOut = DepthOut
  { doSpanReady :: !Bool
  , doMem       :: !MemOp
  , doPixel     :: !(Maybe PixelOut)
  , doBusy      :: !Bool
  } deriving (Eq, Generic, Show, NFDataX)

-- | Engine state. The span and interpolator are carried while a pixel walks
-- through read, compare, write, and emit.
data DState
  = DIdle
  | DClear !Int32 !Int32
  | DRead !Span !Interp !Int32
  | DWait !Span !Interp !Int32
  | DWrite !Span !Interp !Int32 !Int32 !PixelOut
  | DEmit !Span !Interp !Int32 !PixelOut
  deriving (Eq, Generic, Show, NFDataX)

addrOf :: Span -> Int32 -> Int32
addrOf sp x = spanY sp * screenW + x

modeOf :: Span -> DepthMode
modeOf sp = if spanFront sp then DepthLessFront else DepthLess

-- | Depth-buffer word: FinalZ in bits 0-23, and bit 24 set when an opaque
-- back-facing polygon wrote the pixel (production's @dstattr & 0x400010 ==
-- 0x10@, the only attribute the opaque depth test reads).
-- | @0x400000 / xdiff@ for every reachable span length. Post-clip spans run over
-- @[xstart, xend + 1)@; a border-biased sweep of 200,000 triangles measured
-- @xdiff@ from 1 to 257, and the depth-pipe gate asserts that domain on every
-- span it feeds.
spanRecipTable :: Vec 258 Int32
spanRecipTable = map (\d -> if d == 0 then 0 else 0x400000 `quot` d) (iterateI (+ 1) 0)

spanRecip :: Int32 -> Int32
spanRecip d
  | d <= 0 = 0
  | d > 257 = spanRecipTable !! (257 :: Int)
  | otherwise = spanRecipTable !! d

backBit :: Int32
backBit = 0x1000000

packDepth :: Span -> Int32 -> Int32
packDepth sp z = if spanFront sp then z else z .|. backBit

-- | One cycle of the depth engine. The memory model guarantees that a write
-- accepted on this port is visible to a later read on the same port.
depthStep :: DState -> DepthIn -> (DState, DepthOut)
depthStep st i = case st of
  DIdle
    | diClear i ->
        (DClear (screenW * screenH - 1) (diClearDepth i)
        , DepthOut False MemNone Nothing False)
    | Just sp <- diSpan i ->
        -- Z-buffer mode reads only the raw endpoints (see
        -- 'Nds.Gpu3D.Raster.spanDepths'); the reciprocal comes from a table.
        let interp = setupInterpWith spanRecip False (spanIX0 sp) (spanIX1 sp) 0 0 False
        in (DRead sp interp (spanX0 sp)
           , DepthOut False MemNone Nothing True)
    | otherwise ->
        (DIdle, DepthOut True MemNone Nothing False)

  DClear a cv
    | diMemReady i ->
        if a <= 0
          then (DIdle, DepthOut False (MemWrite a cv) Nothing False)
          else (DClear (a - 1) cv, DepthOut False (MemWrite a cv) Nothing True)
    | otherwise ->
        (st, DepthOut False MemNone Nothing True)

  DRead sp interp x
    | diMemReady i ->
        (DWait sp interp x
        , DepthOut False (MemRead (addrOf sp x)) Nothing True)
    | otherwise ->
        (st, DepthOut False MemNone Nothing True)

  DWait sp interp x ->
    case diMemResp i of
      Just dst ->
        let z = interpolateZ (spanZ0 sp) (spanZ1 sp) (setXLinear x interp)
            pix = PixelOut x (spanY sp) (spanColor sp)
            dstz = dst .&. 0xFFFFFF
            dstBack = dst .&. backBit /= 0
        in if depthPass (modeOf sp) dstBack dstz z
             then (DWrite sp interp x (packDepth sp z) pix
                  , DepthOut False MemNone Nothing True)
             else nextPixel sp interp x
      Nothing ->
        (st, DepthOut False MemNone Nothing True)

  DWrite sp interp x z pix
    | diMemReady i ->
        (DEmit sp interp x pix
        , DepthOut False (MemWrite (addrOf sp x) z) Nothing True)
    | otherwise ->
        (st, DepthOut False MemNone Nothing True)

  DEmit sp interp x pix
    | diOutReady i ->
        let (st', out) = nextPixel sp interp x
        in (st', out { doPixel = Just pix })
    | otherwise ->
        (st, DepthOut False MemNone (Just pix) True)

nextPixel :: Span -> Interp -> Int32 -> (DState, DepthOut)
nextPixel sp interp x
  | x < spanX1 sp = (DRead sp interp (x + 1), DepthOut False MemNone Nothing True)
  | otherwise = (DIdle, DepthOut False MemNone Nothing False)

-- | Streaming depth test. The first output accepts a span, the second drives the
-- depth memory, the third carries surviving pixels, and the fourth is busy.
depthPipe
  :: forall dom. KnownDomain dom
  => Clock dom -> Reset dom -> Enable dom
  -> Signal dom DepthIn
  -> ( Signal dom Bool
     , Signal dom MemOp
     , Signal dom (Maybe PixelOut)
     , Signal dom Bool
     )
depthPipe clk rst en inp =
  let out = EM.mealy clk rst en depthStep DIdle inp
  in ( fmap doSpanReady out
     , fmap doMem out
     , fmap doPixel out
     , fmap doBusy out
     )

-- | Concrete top entity for resource estimation.
{-# ANN depthTopEntity
  (Synthesize
    { t_name = "nds_gpu3d_depth"
    , t_inputs =
        [ PortName "CLK"
        , PortName "RST"
        , PortName "EN"
        , PortName "IN"
        ]
    , t_output = PortProduct ""
        [ PortName "SPAN_READY", PortName "MEM", PortName "PIXEL", PortName "BUSY" ]
    }) #-}
depthTopEntity
  :: Clock System -> Reset System -> Enable System
  -> Signal System DepthIn
  -> ( Signal System Bool
     , Signal System MemOp
     , Signal System (Maybe PixelOut)
     , Signal System Bool
     )
depthTopEntity = depthPipe
{-# NOINLINE depthTopEntity #-}
