-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric, NoImplicitPrelude #-}
-- | A single ordered physical-fabric reader serves BG/OBJ bursts and the
-- composed pixel's OBJ extended palette. No ext-palette RAM is instantiated.
module Nds.WholeCore.TileFabric (fabricTile) where

import Clash.Explicit.Prelude
import Data.Maybe (isJust)
import Nds.Gpu2D.TileHw
import qualified Nds.Memory.Fabric as F
import Nds.WholeCore.Arm9Soc (SocOut)
import Nds.WholeCore.TileSoc

type Burst = BitVector 64
type Half = BitVector 16
-- A four-burst read-through buffer: adjacent map entries share a burst and
-- the 8-pixel row pattern may recur. Flushed by *every* VRAM/map mutation,
-- including ARM7 stores. Extended palettes always read physical E-I.
type Cache = Vec 4 (Maybe (F.VideoReq,Burst))
data Sink = Row | Colour (Index 4) deriving (Generic,NFDataX)
data ReadPort = Idle | Issue F.VideoReq Sink | Await F.VideoReq Sink | RowQ Burst | ColourQ Half
  deriving (Generic,NFDataX)

fabricTile :: Clock System -> Reset System -> Signal System Bool -> Signal System Bool -> Signal System SocOut
           -> Signal System Bool -> Signal System Bool -> Signal System F.FabricOut
           -> (Signal System LinkOut, Signal System GpuOut, Signal System (Maybe F.VideoReq), Signal System Bool)
fabricTile clk rst useBuffer ce cpu mutation invalidate fab = (link, gpu, request, takeReply)
 where
  reg :: NFDataX a => a -> Signal System a -> Signal System a
  reg = register clk rst enableGen
  st = reg Idle st'
  cache = reg (repeat Nothing :: Cache) cache'
  -- Never fill a tag from an offer that straddled a mapping/write change.
  -- Sticky until idle: unlike a wrapping epoch this survives any stall.
  poisoned = reg False ((\p inv old -> inv || (not (idle p) && old)) <$> st <*> invalidate <*> poisoned)
  (link,gpu) = displayControl True clk rst (toEnable ce) cpu visible (pure (repeat (repeat 0)))
  -- A write accepted before HBlank is logically visible at that HBlank.
  -- The jobs remain pending until its ordered fabric reply; the LCD's line
  -- counter/IRQs never stall. Writes cannot be accepted while jobs run.
  visible = (\o stop -> o { toReady = toReady o && not stop }) <$> tile <*> mutation
  tileReset = unsafeFromActiveHigh ((||) <$> unsafeToActiveHigh rst <*> (goFlush <$> gpu))
  (tile,ops) = tileHwExtPort clk tileReset (toEnable advance) input ((\q -> q :> q :> Nil) <$> previousColour)
  previousColour = register clk rst (toEnable advance) 0 (colour <$> st)
  colour (ColourQ x) = x
  colour _ = 0
  ext = opExtDemand <$> ops
  advance = (\e x p -> e && (not (isJust x) || colourReady p)) <$> ce <*> ext <*> st
  colourReady (ColourQ _) = True
  colourReady _ = False
  idle Idle = True
  idle _ = False
  input = (\g p -> (goTile g) { tiReqReady = idle p, tiResp = case p of RowQ v -> Just v; _ -> Nothing
                               , tiExtWr = Nothing }) <$> gpu <*> st
  request = (\p -> case p of Issue q _ -> Just q; _ -> Nothing) <$> st
  takeReply = (\p -> case p of Await _ _ -> True; _ -> False) <$> st
  hit q c = pick 0 (pick 1 (pick 2 (pick 3 Nothing)))
   where pick :: Index 4 -> Maybe Burst -> Maybe Burst
         pick k other = case c !! k of Just (t,w) | t==q -> Just w; _ -> other
  video eng (Req obj word) = F.VideoReq space (resize word `shiftL` 3)
   where space = case (eng,obj) of (0,False)->F.MainBG; (0,True)->F.MainOBJ; (_,False)->F.SubBG; _->F.SubOBJ
  -- Registered offers stay stable until accepted. One outstanding read;
  -- responses are held internally until the appropriate half-rate step.
  next p c t g e pal f inv cached stale = (p', if inv || not cached then repeat Nothing else c')
   where
    (p',c') = case p of
      Idle | e, Just a <- pal -> (Issue (F.VideoReq (if testBit a 12 then F.SubOBJExt else F.MainOBJExt)
                           ((resize a .&. 0xffc) `shiftL` 1)) (Colour (fromIntegral (a .&. 3))),c)
           | e, Just r <- toReq t -> let q = video (goEngine g) r in
               (maybe (Issue q Row) RowQ (if cached && not inv then hit q c else Nothing), c)
      Issue q s | F.displayReady f -> (Await q s,c)
      Await q s | Just w <- F.displayReply f -> case s of
        Row -> (RowQ w, if stale then c else Just (q,w) +>> c)
        Colour k -> (ColourQ ((reverse (unpack w :: Vec 4 Half)) !! k),c)
      RowQ _ | e -> (Idle,c)
      ColourQ _ | e -> (Idle,c)
      _ -> (p,c)
  (st',cache') = unbundle (next <$> st <*> cache <*> tile <*> gpu <*> ce <*> ext <*> fab <*> invalidate <*> useBuffer <*> poisoned)
{-# NOINLINE fabricTile #-}
