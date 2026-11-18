-- | Native differential checker for the full renderer model.
--
-- @render-check CASE VRAM ORACLE_OUT@ renders every frame of a
-- @render_oracle@ case through 'Nds.Gpu3D.Render' (back to back, carrying
-- the renderer state between frames as production does) and compares, per
-- frame, all 192 @GetLine@ lines and every pixel of the top and lower
-- colour, depth and attribute layers with the production output.
--
-- @render-check --stats CASE...@ prints the per-scanline work the model
-- does on the cases (active polygons, edge setups, visited pixels,
-- divisions), the numbers the hardware wave sizes its line-buffer rasteriser
-- by.
module Main (main) where

import Control.Monad (forM_, when)
import Data.Array.Unboxed (UArray, bounds, (!))
import Data.Bits (testBit, (.&.))
import Data.Int (Int32)
import Data.List (foldl', mapAccumL, sort)
import Data.Word (Word32)
import Numeric (showHex)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import Text.Printf (printf)

import Nds.Gpu3D.Depth (Interp (..))
import Nds.Gpu3D.Render
import Nds.Gpu3D.Slope (Slope (..))
import Nds.Gpu3D.Types (GxPolygon (..), RenderFrame (..), RenderRegs (..))

import OracleIO

main :: IO ()
main = do
  args <- getArgs
  case args of
    ("--stats" : paths@(_ : _)) -> do
      frames <- concat <$> mapM parseOrDie paths
      statsReport (concatMap frameWork frames)
    [casePath, imgPath, outPath] -> check casePath imgPath outPath
    _ -> putStrLn "usage: render-check CASE VRAM ORACLE_OUT | render-check --stats CASE..." >> exitFailure

parseOrDie :: FilePath -> IO [RenderFrame]
parseOrDie path = do
  text <- readFile path
  either (\e -> putStrLn ("FAIL " ++ path ++ ": " ++ e) >> exitFailure) pure (parseRenderCase text)

check :: FilePath -> FilePath -> FilePath -> IO ()
check casePath imgPath outPath = do
  frames <- parseOrDie casePath
  img <- readWords imgPath
  oracle <- readWords outPath
  let n = 256 * 192
      perFrame = 7 * n
  when (count img /= 0x28000 || count oracle /= perFrame * length frames) $
    putStrLn "FAIL short oracle output" >> exitFailure
  let mem = imageMemory img
      (_, outs) = mapAccumL (\c f -> let (o, c') = renderFrameFrom c mem f in (c', o)) resetCarry frames
      layersOf o = [ ("line", roLines o)
                   , ("top-colour", lyColour (roTop o)), ("top-depth", lyDepth (roTop o))
                   , ("top-attr", lyAttr (roTop o))
                   , ("lower-colour", lyColour (roLower o)), ("lower-depth", lyDepth (roLower o))
                   , ("lower-attr", lyAttr (roLower o)) ]
      diffs =
        [ (fi, name, x, y, want, got)
        | (fi, o) <- zip [0 :: Int ..] outs
        , (li, (name, arr)) <- zip [0 ..] (layersOf o)
        , i <- [0 .. n - 1]
        , let want = oracle ! (fi * perFrame + li * n + i)
              got = arr ! i
        , want /= got
        , let (y, x) = i `divMod` 256
        ]
  case diffs of
    [] -> do
      let polys = concatMap rfPolys frames
          live = filter (not . gpDegenerate) polys
          nv k = length (filter ((== k) . length . gpVerts) live)
          pixels f = sum [ length (filter id [ f o i | i <- [0 .. n - 1] ]) | o <- outs ]
          topA o i = lyAttr (roTop o) ! i
          edgePx = pixels (\o i -> topA o i .&. 0xF /= 0)
          transPx = pixels (\o i -> testBit (topA o i) 22)
          partial = sum [ length [ () | i <- [0 .. n - 1], topA o i .&. 0xF /= 0
                                     , (topA o i `div` 0x100) .&. 0x1F /= 0x1F ]
                        | (o, f) <- zip outs frames, testBit (rrDispCnt (rfRegs f)) 4 ]
          lowerPx = pixels (\o i -> lyAttr (roLower o) ! i /= 0 || lyDepth (roLower o) ! i /= 0)
      putStrLn ("render-check: " ++ show (length frames) ++ " frames, " ++ show (length polys)
        ++ " polygons (" ++ show (length polys - length live) ++ " degenerate; n-gons "
        ++ unwords [ show k ++ ":" ++ show (nv k) | k <- [1 .. 10 :: Int], nv k > 0 ]
        ++ "; " ++ show (length (filter gpShadowMask live)) ++ " masks, "
        ++ show (length (filter gpShadow live)) ++ " shadows), "
        ++ show edgePx ++ " edge px (" ++ show partial ++ " partial AA), "
        ++ show transPx ++ " translucent px, " ++ show lowerPx ++ " lower-layer px, "
        ++ show (length frames * perFrame) ++ " words compared, 0 failures")
    _ -> do
      putStrLn ("FAIL " ++ show (length diffs) ++ " of " ++ show (length frames * perFrame)
                ++ " words differ; per frame and layer: "
                ++ unwords [ show fi ++ "/" ++ l ++ "=" ++ show k
                           | (fi, l, k) <- tally [ (fi, l) | (fi, l, _, _, _, _) <- diffs ] ])
      putStrLn "  first differences (frame, layer, x, y, want, got):"
      forM_ (take 16 diffs) $ \(fi, l, x, y, w, g) ->
        putStrLn ("  " ++ show fi ++ " " ++ l ++ " " ++ show (x, y) ++ " want=0x" ++ showHex w ""
                  ++ " got=0x" ++ showHex g "")
      exitFailure
  where
    tally [] = []
    tally ((f, l) : rest) =
      let (same, other) = span (== (f, l)) rest in (f, l, 1 + length same) : tally other

count :: UArray Int Word32 -> Int
count a = let (lo, hi) = bounds a in hi - lo + 1

------------------------------------------------------------------------------
-- Per-scanline work, for sizing the line-buffer rasteriser.

data LineWork = LineWork
  { lwPolys      :: !Int  -- ^ active polygons = span setups (one 2^22/xdiff reciprocal each)
  , lwEdgeSetups :: !Int  -- ^ Slope::Setup calls (2^18/ylen, 2^22/ydiff, X-major: 2^32/xlen
                          --   and the coverage step)
  , lwXMajor     :: !Int  -- ^ X-major edges (one coverage DivideByXLen each per line)
  , lwPixels     :: !Int  -- ^ pixels the three loops visit
  , lwSpanDivs   :: !Int  -- ^ span perspective-factor divisions (one per visited pixel of a
                          --   perspective or W-buffered span)
  , lwSpanLin    :: !Int  -- ^ span linear attribute divisions (five per visited pixel of a
                          --   linear span: R, G, B, S, T by xdiff)
  , lwEdgeDivs   :: !Int  -- ^ edge perspective-factor divisions (Interp.SetX at setup and step)
  , lwLinDivs    :: !Int  -- ^ edge linear value divisions (W, R, G, B, S, T by the edge's ydiff)
  }

frameWork :: RenderFrame -> [LineWork]
frameWork rf = go 0 [ setupPolygon p | p <- rfPolys rf, not (gpDegenerate p) ] []
  where
    regs = rfRegs rf
    go y ps acc
      | y > 191 = reverse acc
      | otherwise =
          let rs = map (lineStep regs y) ps
          in go (y + 1) (map fst rs) (foldl' addWork emptyWork (map snd rs) : acc)

emptyWork :: LineWork
emptyWork = LineWork 0 0 0 0 0 0 0 0

addWork :: LineWork -> LineWork -> LineWork
addWork (LineWork a b c d e f g h) (LineWork a' b' c' d' e' f' g' h') =
  LineWork (a + a') (b + b') (c + c') (d + d') (e + e') (f + f') (g + g') (h + h')

lineStep :: RenderRegs -> Int32 -> RPoly -> (RPoly, LineWork)
lineStep regs y rp
  | not (polygonActive y rp) = (rp, emptyWork)
  | otherwise =
      let p = rpPoly rp
          walks = gpYTop p /= gpYBottom p
          vbot = gpVBottom p
          setL = walks && y >= rpY rp ! rpNextVL rp && rpCurVL rp /= vbot
          setR = walks && y >= rpY rp ! rpNextVR rp && rpCurVR rp /= vbot
          rp1 = advanceEdges y rp
          sp = spanSetup (rrDispCnt regs) y rp1
          (pl, pm, pr) = spPieces sp
          len = maybe 0 (\(a, b) -> fromIntegral (b - a + 1))
          pixels = len pl + len pm + len pr
          persp ip = interpXDiff ip /= 0 && (not (interpLinear ip) || interpWBuf ip)
          lin ip = interpXDiff ip /= 0 && interpLinear ip
          count1 b = if b then 1 else 0
          edgeDiv s = maybe 0 (count1 . persp) (slopeInterp s)
          linDiv s = maybe 0 (\ip -> 6 * count1 (lin ip)) (slopeInterp s)
          rp2 = stepEdges rp1
          xmaj = count1 (slopeXMajor (rpSL rp1)) + count1 (slopeXMajor (rpSR rp1))
          si = spInterp sp
      in ( rp2
         , LineWork 1 (count1 setL + count1 setR) xmaj pixels
             (if persp si then pixels else 0)
             (if lin si then 5 * pixels else 0)
             ((if setL then edgeDiv (rpSL rp1) else 0) + (if setR then edgeDiv (rpSR rp1) else 0)
               + edgeDiv (rpSL rp2) + edgeDiv (rpSR rp2))
             (linDiv (rpSL rp1) + linDiv (rpSR rp1)) )

statsReport :: [LineWork] -> IO ()
statsReport ws = do
  let lines' = length ws
      mx f = maximum (0 : map f ws)
      avg f = fromIntegral (sum (map f ws)) / fromIntegral (max 1 lines') :: Double
      pct q f = let xs = sort (map f ws) in if null xs then 0 else xs !! min (length xs - 1) (q * length xs `div` 100)
  printf "%d lines\n%-34s %6s %8s %6s\n" lines' ("per line" :: String) ("max" :: String) ("mean" :: String) ("p99" :: String)
  forM_ [ ("active polygons (span setups)", lwPolys), ("edge setups", lwEdgeSetups)
        , ("x-major edges (coverage divides)", lwXMajor), ("visited pixels", lwPixels)
        , ("span factor divisions", lwSpanDivs), ("span linear divisions", lwSpanLin)
        , ("edge factor divisions", lwEdgeDivs), ("edge linear divisions", lwLinDivs) ] $ \(name, f) ->
    printf "%-34s %6d %8.1f %6d\n" (name :: String) (mx f) (avg f) (pct 99 f)
