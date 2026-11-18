-- | Shared input parsing for the melonDS frame gates: little-endian word
-- files written by the oracles, the VRAM image, the triangle-scene text
-- format of @tools/gx3d_oracle/scene_oracle.cpp@ and the full frame format of
-- @tools/gx3d_oracle/render_oracle.cpp@. Both formats become the renderer's
-- boundary types ('RenderFrame').
module OracleIO
  ( readWords
  , imageMemory
  , SceneFile (..)
  , parseScene
  , parseRenderCase
  ) where

import Data.Array.Unboxed (UArray, listArray, (!))
import Data.Bits (shiftL, (.&.), (.|.))
import qualified Data.ByteString as BS
import Data.Int (Int32)
import Data.Word (Word16, Word32)
import Text.Read (readMaybe)

import Nds.Gpu3D.Texture (TexMem (..))
import Nds.Gpu3D.Types (GxPolygon (..), GxVertex (..), RenderFrame (..), RenderRegs (..))

-- | A file of little-endian 32-bit words.
readWords :: FilePath -> IO (UArray Int Word32)
readWords path = do
  bs <- BS.readFile path
  let n = BS.length bs `div` 4
      byte i = fromIntegral (BS.index bs i) :: Word32
      word i = byte (4 * i) .|. (byte (4 * i + 1) `shiftL` 8)
                 .|. (byte (4 * i + 2) `shiftL` 16) .|. (byte (4 * i + 3) `shiftL` 24)
  pure (listArray (0, n - 1) (map word [0 .. n - 1]))

-- | The texture memories from a VRAM image: 512 KiB of texture slots followed
-- by 128 KiB of palette slots, read as words.
imageMemory :: UArray Int Word32 -> TexMem
imageMemory img = TexMem tex pal
  where
    tex a =
      let w = img ! fromIntegral ((a .&. 0x7FFFC) `div` 4)
      in fromIntegral (if a .&. 0x2 /= 0 then w `div` 0x10000 else w) :: Word16
    pal a = img ! fromIntegral (0x20000 + (a .&. 0x1FFFC) `div` 4)

-- | A triangle scene: the frame it describes, as @scene_oracle@ builds it.
data SceneFile = SceneFile
  { sfRegs  :: RenderRegs
  , sfPolys :: [GxPolygon]
  }

-- | Parse the scene text (@CFG@, @TOON@ and three-vertex @POLY@ lines).
-- Each triangle becomes the polygon @scene_oracle@ builds: bounds as
-- @SubmitPolygon@ computes them, shadow flags from the attribute, the
-- frame's W-buffer flag. Unknown or malformed lines are an error.
parseScene :: String -> Either String SceneFile
parseScene text = go (regs0, False, []) (lines text)
  where
    regs0 = RenderRegs 0 0 0 0x7FFF 0 0 0 (replicate 34 0) (replicate 8 0) (replicate 32 0) 0
    go (r, wb, ps) [] = Right (SceneFile r (reverse [ p { gpWBuffer = wb } | p <- ps ]))
    go st@(r, wb, ps) (l : ls) = case words l of
      [] -> go st ls
      ("CFG" : rest) -> case traverse readMaybe rest of
        Just [d, a, c1, c2, w] ->
          go (r { rrDispCnt = fromInteger d, rrAlphaRef = fromInteger a
                , rrClearAttr1 = fromInteger c1, rrClearAttr2 = fromInteger c2 }
             , w /= (0 :: Integer), ps) ls
        _ -> Left ("bad CFG: " ++ l)
      ("TOON" : rest) -> case traverse readMaybe rest of
        Just ts | length ts == 32 ->
          go (r { rrToonTable = map (\t -> fromInteger (t .&. 0x7FFF)) ts }, wb, ps) ls
        _ -> Left ("bad TOON: " ++ l)
      ("POLY" : rest) -> case traverse readMaybe rest of
        Just (attr : tp : pal : face : vs) | length vs == 27 ->
          let chunk xs = [take 9 xs, take 9 (drop 9 xs), drop 18 xs]
              vert [x, y, _, _, cr, cg, cb, s, t] =
                GxVertex (i32 x) (i32 y) (i32 cr) (i32 cg) (i32 cb) (fromInteger s) (fromInteger t)
              vert _ = error "unreachable"
              cs = chunk vs
              p = scenePolygon (fromInteger attr) (fromInteger tp) (fromInteger pal) (face /= 0)
                    (map vert cs) [ i32 z | (_ : _ : z : _) <- cs ] [ i32 w | (_ : _ : _ : w : _) <- cs ]
          in go (r, wb, p : ps) ls
        _ -> Left ("bad POLY: " ++ l)
      _ -> Left ("unknown line: " ++ l)
    i32 = fromInteger :: Integer -> Int32

scenePolygon :: Word32 -> Word32 -> Word32 -> Bool -> [GxVertex] -> [Int32] -> [Int32] -> GxPolygon
scenePolygon attr tp pal facing vs zs ws =
  let (vtop, vbot, ytop, ybot, xtop, xbot) = submitBounds vs
      fmt = (tp `div` 0x4000000) .&. 7
      alpha = (attr `div` 0x10000) .&. 0x1F
      mask = attr .&. 0x3F000030 == 0x30
  in GxPolygon
    { gpVerts = vs, gpFinalZ = zs, gpFinalW = ws, gpWBuffer = False
    , gpAttr = attr, gpTexParam = tp, gpTexPalette = pal
    , gpDegenerate = False, gpFacingView = facing
    , gpTranslucent = fmt == 1 || fmt == 6 || (alpha > 0 && alpha < 31)
    , gpShadowMask = mask
    , gpShadow = attr .&. 0x30 == 0x30 && not mask
    , gpType = 0
    , gpVTop = vtop, gpVBottom = vbot, gpYTop = ytop, gpYBottom = ybot
    , gpXTop = xtop, gpXBottom = xbot, gpSortKey = 0
    }

-- | @SubmitPolygon@'s bounds: the first vertex with the least Y is the top;
-- the bottom is the greatest Y, the greater X winning a tie.
submitBounds :: [GxVertex] -> (Int, Int, Int32, Int32, Int32, Int32)
submitBounds vs = foldl step (0, 0, 192, 0, 256, 0) (zip [0 ..] vs)
  where
    step (vt, vb, yt, yb, xt, xb) (i, v) =
      let (vt', yt', xt') = if gvY v < yt then (i, gvY v, gvX v) else (vt, yt, xt)
          (vb', yb', xb')
            | gvY v > yb || (gvY v == yb && gvX v > xb) = (i, gvY v, gvX v)
            | otherwise = (vb, yb, xb)
      in (vt', vb', yt', yb', xt', xb')

-- | Parse a @render_oracle@ case: one or more frames, each a @FRAME@ line
-- followed by @REGS@, @FOG@, @EDGE@, @TOON@ and @POLY@ lines.
parseRenderCase :: String -> Either String [RenderFrame]
parseRenderCase text = finish =<< foldl step (Right []) (lines text)
  where
    regs0 = RenderRegs 0 0 0 0 0 0 0 (replicate 34 0) (replicate 8 0) (replicate 32 0) 0
    finish fs = if null fs then Left "no FRAME" else Right (reverse [ f { rfPolys = reverse (rfPolys f) } | f <- fs ])
    step acc l = acc >>= \fs -> case (words l, fs) of
      ([], _) -> Right fs
      (["FRAME"], _) -> Right (RenderFrame regs0 [] : fs)
      (_, []) -> Left ("line before FRAME: " ++ l)
      (k : rest, f : more) -> do
        nums <- maybe (Left ("bad numbers: " ++ l)) Right (traverse readMaybe rest :: Maybe [Integer])
        let r = rfRegs f
        f' <- case (k, nums) of
          ("REGS", [d, a, c1, c2, fc, fo, fs', xp]) -> Right f { rfRegs = r
            { rrDispCnt = fromInteger d, rrAlphaRef = fromInteger a
            , rrClearAttr1 = fromInteger c1, rrClearAttr2 = fromInteger c2
            , rrFogColor = fromInteger fc, rrFogOffset = fromInteger fo
            , rrFogShift = fromInteger fs', rrXPos = fromInteger xp } }
          ("FOG", ds) | length ds == 34 -> Right f { rfRegs = r { rrFogDensity = map fromInteger ds } }
          ("EDGE", es) | length es == 8 -> Right f { rfRegs = r { rrEdgeTable = map fromInteger es } }
          ("TOON", ts) | length ts == 32 -> Right f { rfRegs = r { rrToonTable = map fromInteger ts } }
          ("POLY", n : attr : tp : pal : dg : fc : tr : sm : sh : ty : wb : vt : vb : yt : yb : xt : xb : sk : vs)
            | n >= 3 && n <= 10 && length vs == 9 * fromInteger n ->
                let chunk [] = []
                    chunk xs = take 9 xs : chunk (drop 9 xs)
                    cs = chunk vs
                    vert [x, y, cr, cg, cb, s, t, _, _] =
                      GxVertex (fromInteger x) (fromInteger y) (fromInteger cr) (fromInteger cg)
                               (fromInteger cb) (fromInteger s) (fromInteger t)
                    vert _ = error "unreachable"
                    p = GxPolygon
                      { gpVerts = map vert cs
                      , gpFinalZ = [ fromInteger (c !! 7) | c <- cs ]
                      , gpFinalW = [ fromInteger (c !! 8) | c <- cs ]
                      , gpWBuffer = wb /= 0
                      , gpAttr = fromInteger attr, gpTexParam = fromInteger tp
                      , gpTexPalette = fromInteger pal
                      , gpDegenerate = dg /= 0, gpFacingView = fc /= 0
                      , gpTranslucent = tr /= 0, gpShadowMask = sm /= 0, gpShadow = sh /= 0
                      , gpType = fromInteger ty
                      , gpVTop = fromInteger vt, gpVBottom = fromInteger vb
                      , gpYTop = fromInteger yt, gpYBottom = fromInteger yb
                      , gpXTop = fromInteger xt, gpXBottom = fromInteger xb
                      , gpSortKey = fromInteger sk
                      }
                in Right f { rfPolys = p : rfPolys f }
          _ -> Left ("bad line: " ++ l)
        Right (f' : more)
