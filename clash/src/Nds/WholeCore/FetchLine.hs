-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric #-}
-- One aligned 64-bit instruction line per CPU. Demand-only, coherent main
-- RAM; not a model of ARM946 cache capacity or replacement. The real ARM9
-- invalidate-all operation also discards this implementation's I-line.
module Nds.WholeCore.FetchLine
  ( LineState, initialLine, LineIn(..), LineOut(..), lineStep ) where
import Prelude ()
import Clash.Prelude hiding (Word)
import qualified Clash.Prelude as C

type Word = BitVector 32
type Tag = BitVector 19  -- physical 4 MiB main RAM address [21:3]
type Burst = BitVector 64
data Cache = Cache (Maybe Tag) Burst deriving (Generic,NFDataX)
data Pending = Empty | Hit Word | Miss Bool (Maybe Tag) deriving (Generic,NFDataX)
data LineState = LineState Cache Cache Pending deriving (Generic,NFDataX)
initialLine :: LineState
initialLine = LineState (Cache Nothing 0) (Cache Nothing 0) Empty

data LineIn = LineIn
  { reqValid :: Bool, reqWrite :: Bool, reqAddr :: Word, arm7 :: Bool, fetch :: Bool
  , downstreamReady :: Bool, returnValid :: Bool, returnWord :: Word, returnLine :: Burst
  , writeSnoop :: Maybe Word  -- accepted external writer, ARM address or physical RAM offset
  , invalidate9 :: Bool       -- ARM9 committed I-cache invalidate-all, not a broadcast
  } deriving (Generic,NFDataX)
data LineOut = LineOut
  { requestReady :: Bool, responseValid :: Bool, responseWord :: Word, downstreamValid :: Bool
  , fetchHit :: Bool -- accepted internal hit; not a downstream transaction
  } deriving (Generic,NFDataX)

-- An ordered, one-request response slot, as on the real Fabric. On a
-- response edge we can also accept its successor. Unsolicited responses
-- (e.g. after coordinated reset) are never returned to a CPU.
lineStep :: LineState -> LineIn -> (LineState,LineOut)
lineStep (LineState c9 c7 pend) i = (LineState c9' c7' pend', LineOut ready valid dat want hit)
 where
  (valid,dat) = case pend of
    Empty -> (False,0)
    Hit w -> (True,w)
    Miss _ _ -> (returnValid i,returnWord i)
  room = case pend of Empty -> True; _ -> valid
  tag = C.slice d21 d3 (reqAddr i)
  mainRam = C.slice d31 d24 (reqAddr i) == 2
  eligible = mainRam && fetch i && not (reqWrite i)
  -- A simultaneous read/hit is ordered before a write from an independent
  -- master on this edge. The write wins in the stored line and fill state.
  kill who t = writeSnoopTag == Just t || ownTag == Just t || (invalidate9 i && not who)
  writeSnoopTag = C.slice d21 d3 <$> writeSnoop i
  ownTag = if accepted && reqWrite i && mainRam then Just tag else Nothing
  -- Forward a returning fill to a new demand for the other half on this
  -- same edge. Nothing about an incoming OFFER/ready gates this lookup.
  fill side = case pend of
    Miss who (Just t) | returnValid i && who == side -> Just t
    _ -> Nothing
  install side c = case fill side of Just t -> Cache (Just t) (returnLine i); Nothing -> c
  lookupLine = if arm7 i then install True c7 else install False c9
  Cache have burst = lookupLine
  found = eligible && have == Just tag
  hitWord = if testBit (reqAddr i) 2 then C.slice d63 d32 burst else C.slice d31 d0 burst
  want = room && reqValid i && not found
  ready = room && (found || downstreamReady i)
  accepted = reqValid i && ready
  hit = accepted && found
  update side c = case install side c of
    Cache (Just t) v | kill side t -> Cache Nothing v
    other -> other
  c9' = update False c9
  c7' = update True c7
  pend'
    | hit = Hit hitWord
    | accepted = Miss (arm7 i) (if eligible && not (kill (arm7 i) tag) then Just tag else Nothing)
    | room = Empty
    | Miss who (Just t) <- pend, kill who t = Miss who Nothing -- stale outstanding fill
    | otherwise = pend
