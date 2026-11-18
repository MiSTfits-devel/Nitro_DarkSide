-- | Native differential checker for textured, translucent and shadowed
-- triangle frames.
--
-- Renders a scene through the renderer model ('Nds.Gpu3D.Render') and
-- compares every one of the 256x192 pixels with the production melonDS frame
-- on all three top layers: colour (6-bit RGB and 5-bit alpha, as @GetLine@
-- returns it), depth, and the attribute word (edge flags, facing, fog flag,
-- translucent and opaque polygon IDs).
module Main (main) where

import Control.Monad (forM_, when)
import Data.Array.Unboxed (UArray, bounds, (!))
import Data.Bits (testBit)
import Data.Word (Word32)
import Numeric (showHex)
import System.Environment (getArgs)
import System.Exit (exitFailure)

import Nds.Gpu3D.Render
import Nds.Gpu3D.Types (GxPolygon (..), RenderFrame (..))

import OracleIO

-- | With @--count@ the checker only reports how many pixel layers differ and
-- exits successfully; the gate uses it for the fork's texture-cache path,
-- which is not the reference (see docs/GPU3D_CLASH.md).
main :: IO ()
main = do
  args0 <- getArgs
  let (countOnly, args) = case args0 of
        ("--count" : rest) -> (True, rest)
        _ -> (False, args0)
  case args of
    [scenePath, imgPath, colourPath, depthPath, attrPath] -> do
      text <- readFile scenePath
      sf <- either (\e -> putStrLn ("FAIL " ++ e) >> exitFailure) pure (parseScene text)
      img <- readWords imgPath
      colour <- readWords colourPath
      depth <- readWords depthPath
      attr <- readWords attrPath
      let n = 256 * 192
      when (any ((/= n) . count) [colour, depth, attr] || count img /= 0x28000) $
        putStrLn "FAIL short oracle output" >> exitFailure
      let mem = imageMemory img
          out = renderFrame mem (RenderFrame (sfRegs sf) (sfPolys sf))
          mc = roLines out
          md = lyDepth (roTop out)
          ma = lyAttr (roTop out)
          (clearC, clearD, _) = clearLine (sfRegs sf) mem 0
          diffs =
            [ (x, y, layer, want, got)
            | i <- [0 .. n - 1]
            , let (y, x) = i `divMod` 256
            , (layer, wantA, gotA) <- [("colour", colour, mc), ("depth", depth, md), ("attr", attr, ma)]
            , let want = wantA ! i
                  got = gotA ! i
            , want /= got
            ]
          written = length [ () | i <- [0 .. n - 1]
                                , colour ! i /= clearC ! 0 || depth ! i /= clearD ! 0 ]
          translucent = length [ () | i <- [0 .. n - 1], testBit (attr ! i) 22 ]
          polys = sfPolys sf
          masks = length (filter gpShadowMask polys)
          shadows = length (filter gpShadow polys)
      if countOnly
        then putStrLn ("texcache-path: " ++ show (length diffs) ++ " of " ++ show (3 * n)
               ++ " pixel layers differ from the model")
      else if null diffs
        then putStrLn ("scene-check: " ++ show (length polys) ++ " polygons ("
               ++ show masks ++ " shadow masks, " ++ show shadows ++ " shadows), "
               ++ show written ++ " written pixels, " ++ show translucent
               ++ " translucent, " ++ show n ++ " pixels x 3 layers compared, 0 failures")
        else do
          putStrLn ("FAIL " ++ show (length diffs) ++ " of " ++ show (3 * n)
                    ++ " pixel layers differ (x, y, layer, want, got):")
          forM_ (take 12 diffs) $ \(x, y, l, w, g) ->
            putStrLn ("  " ++ show (x, y) ++ " " ++ l ++ " want=0x" ++ showHex w ""
                      ++ " got=0x" ++ showHex g "")
          exitFailure
    _ -> putStrLn "usage: scene-check [--count] SCENE VRAM COLOUR DEPTH ATTR" >> exitFailure

count :: UArray Int Word32 -> Int
count a = let (lo, hi) = bounds a in hi - lo + 1
