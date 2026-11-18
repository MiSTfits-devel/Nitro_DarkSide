{-# LANGUAGE BangPatterns #-}

-- | Gate for "Nds.Gpu3D.Polygon" against the production melonDS polygon
-- pipeline. Each argument is a stream written by @nds_gx3d_polygon_oracle@
-- (format in @tools/gx3d_oracle/polygon_oracle.cpp@): the 'GeoEvent's the
-- oracle fed melonDS, interleaved with what melonDS produced. The model runs
-- the same events and every observation is compared:
--
-- * after every vertex: @RAM_COUNT@, and when the vertex completed a polygon,
--   the @PolygonPipeline@ / @VertexSlotsFree@ that 'submitTiming' predicts;
-- * at every dump: the counters, overflow flag, bank and swap request, every
--   polygon of the current bank (all fields, vertex indices included) and
--   every vertex of the current bank plus any other-bank vertex a polygon
--   points at (all fields, @Clipped@ included);
-- * at every VBlank: whether a swap happened and the sorted render list, both
--   as polygon RAM indices and as 'GxPolygon' values.
module Main (main) where

import Control.Monad (forM, unless, when)
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.List (foldl')
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Map.Strict as M
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hFlush, stdout)

import Nds.Gpu3D.Polygon
import Nds.Gpu3D.Types

data Check = Check
  { ckState    :: !PolyPipeState
  , ckLine     :: !Int
  , ckFails    :: !Int
  , ckMsgs     :: ![String]           -- first failures, newest first
  , ckDumpNext :: !Int                -- next expected P index in a dump
  , ckPending  :: ![(Int, GxPolygon)] -- render list still to compare
  , ckStats    :: !(M.Map String Int)
  }

maxMsgs :: Int
maxMsgs = 12

fails :: String -> Check -> Check
fails msg ck = ck
  { ckFails = ckFails ck + 1
  , ckMsgs = if length (ckMsgs ck) < maxMsgs
               then ("line " ++ show (ckLine ck) ++ ": " ++ msg) : ckMsgs ck
               else ckMsgs ck
  }

expect :: (Eq a, Show a) => String -> a -> a -> Check -> Check
expect what oracle model ck
  | oracle == model = ck
  | otherwise = fails (what ++ "\n    melonDS: " ++ show oracle ++ "\n    model:   " ++ show model) ck

bump :: String -> Int -> Check -> Check
bump k n ck = ck { ckStats = M.insertWith (+) k n (ckStats ck) }

-- | A statistic kept as a maximum (key starts with "max").
bumpMax :: String -> Int -> Check -> Check
bumpMax k n ck = ck { ckStats = M.insertWith max k n (ckStats ck) }

mergeStats :: M.Map String Int -> M.Map String Int -> M.Map String Int
mergeStats = M.unionWithKey (\k a c -> if take 3 k == "max" then max a c else a + c)

ints :: BL.ByteString -> [Int]
ints s = case BL.readInt (BL.dropWhile (== ' ') s) of
  Just (n, rest) -> n : ints rest
  Nothing -> []

b :: Int -> Bool
b = (/= 0)

splitTail :: Int -> [Int] -> ([Int], [Int], [Int])
splitTail n xs = let (zs, r1) = splitAt n xs
                     (ws, r2) = splitAt n r1
                 in (zs, ws, r2)

polyFrom :: [Int] -> [Int] -> [Int] -> [Int] -> Maybe Poly
polyFrom refs zs ws rest = case rest of
  [wbuf, attr, tp, tpal, degen, facing, transl, smask, shadow, typ, vtop, vbot, ytop, ybot, xtop, xbot, key] ->
    Just Poly
      { plVerts = refs
      , plFinalZ = map fromIntegral zs
      , plFinalW = map fromIntegral ws
      , plWBuffer = b wbuf
      , plAttr = fromIntegral attr
      , plTexParam = fromIntegral tp
      , plTexPalette = fromIntegral tpal
      , plDegenerate = b degen
      , plFacingView = b facing
      , plTranslucent = b transl
      , plShadowMask = b smask
      , plShadow = b shadow
      , plType = typ
      , plVTop = vtop
      , plVBottom = vbot
      , plYTop = fromIntegral ytop
      , plYBottom = fromIntegral ybot
      , plXTop = fromIntegral xtop
      , plXBottom = fromIntegral xbot
      , plSortKey = fromIntegral key
      }
  _ -> Nothing

gxFrom :: [GxVertex] -> Poly -> GxPolygon
gxFrom vs p = GxPolygon
  { gpVerts = vs, gpFinalZ = plFinalZ p, gpFinalW = plFinalW p
  , gpWBuffer = plWBuffer p, gpAttr = plAttr p, gpTexParam = plTexParam p
  , gpTexPalette = plTexPalette p, gpDegenerate = plDegenerate p
  , gpFacingView = plFacingView p, gpTranslucent = plTranslucent p
  , gpShadowMask = plShadowMask p, gpShadow = plShadow p, gpType = plType p
  , gpVTop = plVTop p, gpVBottom = plVBottom p, gpYTop = plYTop p
  , gpYBottom = plYBottom p, gpXTop = plXTop p, gpXBottom = plXBottom p
  , gpSortKey = plSortKey p
  }

gxVerts :: [Int] -> [GxVertex]
gxVerts (fx : fy : fr : fg : fb : s : t : rest) =
  GxVertex (fromIntegral fx) (fromIntegral fy) (fromIntegral fr) (fromIntegral fg)
           (fromIntegral fb) (fromIntegral s) (fromIntegral t) : gxVerts rest
gxVerts _ = []

-- | Statistics of one SubmitPolygon.
submitStats :: PolyPipeState -> SubmitResult -> Check -> Check
submitStats st r ck0 = case r of
  Culled -> bump "rejected: culled" 1 ck
  ClippedAway cs -> clipStats cs (bump "rejected: clipped away" 1 ck)
  Overflow cs -> clipStats cs (bump "rejected: RAM full" 1 ck)
  ZeroDot cs -> clipStats cs (bump "rejected: 1-dot" 1 ck)
  Built n reused cs ->
    let p = readPoly st (polyRamBank (ppBank st) + ppNumPolys st - 1)
        flag k c = if c then bump k 1 else id
    in clipStats cs
       . flag "built: clipped" (csSegments cs > 0)
       . flag "built: strip vertices reused" reused
       . flag "built: 4 vertices" (n == 4)
       . flag "built: 5+ vertices" (n >= 5)
       . flag "built: 2 vertices" (n == 2)
       . flag "built: line" (plType p == 1)
       . flag "built: degenerate" (plDegenerate p)
       . flag "built: translucent" (plTranslucent p)
       . flag "built: shadow mask" (plShadowMask p)
       . flag "built: shadow" (plShadow p)
       . flag "built: W-buffer" (plWBuffer p)
       . flag "built: back-facing" (not (plFacingView p))
       . bumpMax "max vertices of a built polygon" n
       $ bump "built" 1 ck
  where
    ck = bump "polygons submitted" 1 ck0
    clipStats cs = bump "clip intersections" (csSegments cs)
                 . bumpMax "max clip intersections in one polygon" (csSegments cs)
                 . bump "clip intersections, 64-bit factors" (csWide cs)
                 . bump "clip vertices dropped at 10" (csDropped cs)
                 . (if csFarReject cs then bump "far-plane rejections" 1 else id)

line :: Check -> BL.ByteString -> Check
line ck0 raw = case BL.words (BL.take 2 raw) of
  [] -> ck
  [tag] | tag == BL.pack "VB" -> vblankLine ck (ints (BL.drop 2 raw))
  _ -> case BL.head raw of
    'V' -> vertexLine ck (ints (BL.drop 1 raw))
    'B' -> stepEv (GeBegin (fromIntegral (head (ints (BL.drop 1 raw)))))
    'E' -> stepEv GeEnd
    'S' -> stepEv (GeSwap (fromIntegral (head (ints (BL.drop 1 raw)))))
    'A' -> ck { ckState = clearOverflow (ckState ck) }
    'D' -> ck { ckDumpNext = polyRamBank (ppBank (ckState ck)) }
    'C' -> countsLine ck (ints (BL.drop 1 raw))
    'P' -> polyLine ck (ints (BL.drop 1 raw))
    'X' -> vertLine ck (ints (BL.drop 1 raw))
    'L' -> renderLine ck (ints (BL.drop 1 raw))
    _ -> fails ("unparsed: " ++ BL.unpack raw) ck
  where
    ck = ck0 { ckLine = ckLine ck0 + 1 }
    stepEv ev = ck { ckState = step (ckState ck) ev }

vertexLine :: Check -> [Int] -> Check
vertexLine ck xs = case xs of
  [x, y, z, w, r, g, bl, s, t, attr, tp, tpal, v0, v1, v2, v3, v4, v5, zdw, np, nv, pp, vsc, vsf] ->
    let cv = ClipVertex (fi x) (fi y) (fi z) (fi w) (fi r) (fi g) (fi bl) (fi s) (fi t)
        ps = PolyState (fi attr) (fi tp) (fi tpal) (fi v0, fi v1, fi v2, fi v3, fi v4, fi v5) (fi zdw)
        st' = step (ckState ck) (GeVertex cv ps)
        ck1 = expect "RAM_COUNT after vertex" (PipeStatus (fi np) (fi nv)) (pipeStatus st')
                (bump "vertices" 1 ck { ckState = st' })
    in case ppLastSubmit st' of
         Nothing -> ck1
         Just res ->
           let (p, f) = submitTiming (ppMode st') res
           in submitStats st' res
                (expect "PolygonPipeline/VertexSlotCounter/VertexSlotsFree after SubmitPolygon"
                   (pp, vsc, vsf) (fromIntegral p - 3, 4, fromIntegral f) ck1)
  _ -> fails "malformed V line" ck
  where
    fi :: (Integral a, Num c) => a -> c
    fi = fromIntegral

countsLine :: Check -> [Int] -> Check
countsLine ck xs =
  let st = ckState ck
      model = [ ppNumPolys st, ppNumVerts st, fromEnum (ppOverflow st), ppBank st
              , fromEnum (ppFlushReq st), fromIntegral (ppFlushAttr st) ]
  in expect "counts (polygons vertices overflow bank flushreq flushattr)" xs model ck

polyLine :: Check -> [Int] -> Check
polyLine ck (gidx : n : rest) =
  let (refs, r1) = splitAt n rest
      (zs, ws, r2) = splitTail n r1
      st = ckState ck
      ck1 = expect "dump polygon order" (ckDumpNext ck) gidx ck { ckDumpNext = ckDumpNext ck + 1 }
  in case polyFrom refs zs ws r2 of
       Just p -> bump "polygons compared" 1
                   (expect ("polygon RAM[" ++ show gidx ++ "]") p (readPoly st gidx) ck1)
       Nothing -> fails "malformed P line" ck1
polyLine ck _ = fails "malformed P line" ck

vertLine :: Check -> [Int] -> Check
vertLine ck xs = case xs of
  [gidx, x, y, z, w, r, g, bl, s, t, clipped, fx, fy, fr, fg, fb] ->
    let v = Vtx (fi x) (fi y) (fi z) (fi w) (fi r) (fi g) (fi bl) (fi s) (fi t)
                (b clipped) (fi fx) (fi fy) (fi fr) (fi fg) (fi fb)
    in bump "vertices compared" 1
         (expect ("vertex RAM[" ++ show gidx ++ "]") v (readVert (ckState ck) gidx) ck)
  _ -> fails "malformed X line" ck
  where
    fi :: (Integral a, Num c) => a -> c
    fi = fromIntegral

vblankLine :: Check -> [Int] -> Check
vblankLine ck xs = case xs of
  [swapped, n] ->
    let st = ckState ck
        order = if ppFlushReq st then renderOrder st else []
        (st', ml) = vblank st
        ck1 = ck { ckState = st', ckPending = zip order (fromMaybe [] ml) }
        ck2 = expect "VBlank swapped" (b swapped) (isJust ml) ck1
        ck3 = expect "render list length" n (length (fromMaybe [] ml)) ck2
    in if isJust ml then bump "swaps" 1 ck3 else bump "VBlanks without swap" 1 ck3
  _ -> fails "malformed VB line" ck

renderLine :: Check -> [Int] -> Check
renderLine ck (gidx : n : rest) =
  let (vs, r1) = splitAt (7 * n) rest
      (zs, ws, r2) = splitTail n r1
  in case (ckPending ck, polyFrom [] zs ws r2) of
       ((mi, mp) : more, Just p) ->
         bump "render polygons compared" 1
           (expect "render list entry (GxPolygon)" (gxFrom (gxVerts vs) p) mp
              (expect "render list entry (polygon RAM index)" gidx mi ck { ckPending = more }))
       ([], _) -> fails "render list longer than the model's" ck
       (_, Nothing) -> fails "malformed L line" ck
renderLine ck _ = fails "malformed L line" ck

checkFile :: FilePath -> IO (Int, M.Map String Int)
checkFile path = do
  s <- BL.readFile path
  let ck = foldl' line (Check initPolyPipe 0 0 [] 0 [] M.empty) (BL.lines s)
  putStrLn (path ++ ": " ++ show (ckLine ck) ++ " records, "
            ++ show (M.findWithDefault 0 "built" (ckStats ck)) ++ " polygons built, "
            ++ show (ckFails ck) ++ " failures")
  mapM_ (putStrLn . ("  " ++)) (reverse (ckMsgs ck))
  hFlush stdout
  return (ckFails ck, ckStats ck)

main :: IO ()
main = do
  files <- getArgs
  when (null files) $ fail "usage: polygon-check STREAM..."
  results <- forM files checkFile
  let failures = sum (map fst results)
      stats = foldr mergeStats M.empty (map snd results)
  putStrLn "totals:"
  mapM_ (\(k, v) -> putStrLn ("  " ++ k ++ ": " ++ show v)) (M.toList stats)
  putStrLn ("polygon-check: " ++ show (length files) ++ " streams, "
            ++ show (M.findWithDefault 0 "polygons submitted" stats) ++ " polygons submitted, "
            ++ show (M.findWithDefault 0 "built" stats) ++ " built, "
            ++ show failures ++ " failures")
  unless (failures == 0) exitFailure
