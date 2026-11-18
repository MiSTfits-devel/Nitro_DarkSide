{-# LANGUAGE BangPatterns #-}

-- | Bounded per-line speculation. The cache only admits immutable memories
-- with exact identities; arbitrary callbacks are rendered on demand.
--
-- 'onePassFrame' / 'referenceFrame' use the pure 2D line renderer. A caller
-- that composes an independent 3D layer into BG0 must use the @*With@ forms:
-- the renderer is supplied explicitly and a per-line 3D identity participates
-- in the cache key, so a cached line cannot outlive a 3D frame change.
module Nds.Gpu2D.Speculate
  ( FrameInput(..), FrameOutput(..), Stats(..), emptyStats, totalRenders
  , LinePlan(..), planFrame, planFrameWith, planFrameTokens, Cache, emptyCache, cacheCapacity
  , prefetchFrame, prefetchFrameWith, prefetchFrameWithTokens
  , referenceFrame, referenceFrameWith, onePassFrame, onePassFrameWith
  , onePassFrameWithTokens
  ) where

import Data.List (foldl', minimumBy)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Ord (comparing)
import Data.Word (Word32)

import Nds.Gpu2D.Line (renderReferenceLine)
import Nds.Gpu2D.Tardis
import Nds.Gpu2D.Types

data LinePlan = LinePlan
  { lpLine :: !Int
  , lpKey :: !(Maybe LineKey)
  } deriving (Show)

-- | Counts actual fully evaluated line renders, not an estimate of time.
data Stats = Stats
  { stHits :: !Int
  , stMisses :: !Int
  , stFixups :: !Int
  , stPrefetchRenders :: !Int
  , stDemandRenders :: !Int
  , stInvalidated :: !Int
  } deriving (Eq, Show)

emptyStats :: Stats
emptyStats = Stats 0 0 0 0 0 0

totalRenders :: Stats -> Int
totalRenders s = stPrefetchRenders s + stDemandRenders s

-- Timestamped LRU replacement. A slot is indexed by scanline, while its
-- complete identity includes engine, registers, 3D identity and all renderer
-- memories.
data Cache = Cache !(Map Int (LineKey, [Pixel], Integer)) !Integer
  deriving (Eq, Show)

emptyCache :: Cache
emptyCache = Cache M.empty 0

cacheCapacity :: Int
cacheCapacity = 192

cacheLookup :: Cache -> Int -> LineKey -> Maybe ([Pixel], Cache)
cacheLookup (Cache m clock) y k = case M.lookup y m of
  Just (old, px, _) | old == k ->
    let next = clock + 1 in Just (px, Cache (M.insert y (old,px,next) m) next)
  _ -> Nothing

cacheInsert :: Cache -> Int -> LineKey -> [Pixel] -> (Cache, Int)
cacheInsert (Cache m clock) y k px =
  let next = clock + 1
      occupied = M.member y m
      (trimmed, dropped)
        | occupied = (M.delete y m, 1)
        | M.size m >= cacheCapacity =
            let (victim,_) = minimumBy (comparing (\(_,(_,_,stamp)) -> stamp)) (M.toList m)
            in (M.delete victim m, 1)
        | otherwise = (m, 0)
  in (Cache (M.insert y (k,px,next) trimmed) next, dropped)

planFrame :: [EngineState] -> [LinePlan]
planFrame = planFrameWith (const Nothing)

-- | @planFrameWith line3D@ keys each line with its state and the independent
-- 3D identity that line displays (if any).
planFrameWith :: (Int -> Maybe Word32) -> [EngineState] -> [LinePlan]
planFrameWith line3D = planFrameTokens (\y -> noLineKeyTokens { lkt3D = line3D y })

-- | Full-token plan for a composed renderer that reads 3D, sprites, windows
-- or capture state in addition to 'EngineState'.
planFrameTokens :: (Int -> LineKeyTokens) -> [EngineState] -> [LinePlan]
planFrameTokens tokens states =
  zipWith (\y es -> LinePlan y (lineKeyTok (tokens y) es y)) [0..] states

-- A line is evaluated before it is counted or inserted: lazy thunks must not
-- make prefetch work disappear from timing or total-render statistics.
forceLine :: [Pixel] -> [Pixel]
forceLine pixels =
  foldl' (\() p -> pxRgb p `seq` pxLayer p `seq` ()) () pixels `seq` pixels

-- | Prefetch by exact key using each line's own state. Stale slots alone are
-- replaced; callback-backed memories cannot be prefetched or reused.
prefetchFrame :: Cache -> [EngineState] -> [LinePlan] -> (Cache, Stats)
prefetchFrame = prefetchFrameWith (\y es -> renderReferenceLine es y)

prefetchFrameWith
  :: (Int -> EngineState -> [Pixel])
  -> Cache -> [EngineState] -> [LinePlan] -> (Cache, Stats)
prefetchFrameWith = prefetchFrameWithTokens

prefetchFrameWithTokens
  :: (Int -> EngineState -> [Pixel])
  -> Cache -> [EngineState] -> [LinePlan] -> (Cache, Stats)
prefetchFrameWithTokens render seeded states plans =
  foldl' step (seeded, emptyStats) (zip [0..] (zip states plans))
  where
    step (cache,stats) (y,(es,plan)) = case lpKey plan of
      Nothing -> (cache,stats)
      Just key
        | lineKeyTok (tokensOfKey key) es y /= Just key -> (cache,stats)
        | otherwise -> case cacheLookup cache y key of
            Just (_, hitCache) -> (hitCache,stats)
            Nothing ->
              let !pixels = forceLine (render y es)
                  (next,dropped) = cacheInsert cache y key pixels
              in (next,stats { stPrefetchRenders = stPrefetchRenders stats + 1
                             , stInvalidated = stInvalidated stats + dropped })

data FrameInput = FrameInput
  { fiCache :: !Cache
  , fiStates :: ![EngineState]
  } deriving ()

data FrameOutput = FrameOutput
  { foLines :: ![[Pixel]]
  , foCache :: !Cache
  , foStats :: !Stats
  } deriving (Show)

referenceFrame :: FrameInput -> FrameOutput
referenceFrame = referenceFrameWith (\y es -> renderReferenceLine es y)

referenceFrameWith :: (Int -> EngineState -> [Pixel]) -> FrameInput -> FrameOutput
referenceFrameWith render fi =
  let states = fiStates fi
      lines' = zipWith render [0..] states
      !_ = foldl' (\() line -> forceLine line `seq` ()) () lines'
  in FrameOutput lines' emptyCache emptyStats { stDemandRenders = length states }

-- The later sendFuture supplies every per-line plan to the earlier prefetch.
-- No claim of real parallel execution or wall-clock acceleration is implied.
onePassFrame :: FrameInput -> FrameOutput
onePassFrame = onePassFrameWith (\y es -> renderReferenceLine es y) (const Nothing)

onePassFrameWith
  :: (Int -> EngineState -> [Pixel])
  -> (Int -> Maybe Word32)
  -> FrameInput -> FrameOutput
onePassFrameWith render line3D =
  onePassFrameWithTokens render (\y -> noLineKeyTokens { lkt3D = line3D y })

onePassFrameWithTokens
  :: (Int -> EngineState -> [Pixel])
  -> (Int -> LineKeyTokens)
  -> FrameInput -> FrameOutput
onePassFrameWithTokens render tokens fi =
  let (out, _) = runTardis (emptyStats, []) pass
      pass = do
        plans <- getFuture
        let (seeded, prefetchStats) = prefetchFrameWithTokens render (fiCache fi) (fiStates fi) plans
            (lines, stats, cache') = walk render seeded plans (fiStates fi) 0 [] prefetchStats
        sendFuture (planFrameTokens tokens (fiStates fi))
        pure (FrameOutput (reverse lines) cache' stats)
  in out

walk :: (Int -> EngineState -> [Pixel]) -> Cache -> [LinePlan]
     -> [EngineState] -> Int -> [[Pixel]] -> Stats
     -> ([[Pixel]], Stats, Cache)
walk render cache plans states y acc st = case (plans,states) of
  (plan:rest, es:remaining) ->
    let (line,next,stats) = demandLine render cache plan es y st
    in walk render next rest remaining (y+1) (line:acc) stats
  _ -> (acc,st,cache)

demandLine :: (Int -> EngineState -> [Pixel]) -> Cache -> LinePlan
           -> EngineState -> Int -> Stats -> ([Pixel], Cache, Stats)
demandLine render cache plan es y st =
  let live = lineKeyTok (tokensOfPlan plan) es y
      changed = live /= lpKey plan
  in case live >>= cacheLookup cache y of
       Just (pixels,next) ->
         (pixels,next,st { stHits = stHits st + 1 })
       Nothing ->
         let !pixels = forceLine (render y es)
             (next,dropped) = case live of
               Just key -> cacheInsert cache y key pixels
               Nothing -> (cache,0)
         in (pixels,next,st { stMisses = stMisses st + 1
                            , stFixups = stFixups st + if changed then 1 else 0
                            , stDemandRenders = stDemandRenders st + 1
                            , stInvalidated = stInvalidated st + dropped })
tokensOfPlan :: LinePlan -> LineKeyTokens
tokensOfPlan p = case lpKey p of
  Just k -> tokensOfKey k
  Nothing -> noLineKeyTokens

tokensOfKey :: LineKey -> LineKeyTokens
tokensOfKey k = LineKeyTokens (lk3D k) (lkSprite k) (lkWindow k) (lkCapture k) (lkDisplay k)
