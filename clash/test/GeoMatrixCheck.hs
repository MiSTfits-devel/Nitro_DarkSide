{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}

-- | Gate and measurements for the compact geometry experiment
-- ('Nds.Gpu3D.GeoMatrix': the whole geometry engine on one row RAM and four
-- multipliers) against the authoritative model ('Nds.Gpu3D.Geometry' after
-- @Chip.gatherEntry@), melonDS's recorded state and vertices, and the existing
-- hardware ('Nds.Gpu3D.GeometryHw').
--
-- Inputs are real command streams, whole: the geometry gate's melonDS oracle
-- files (@geometry_oracle directed@ / @random@, each record carrying the
-- state melonDS's GPU3D reached and the vertex it stored), and the GX
-- command stream of a captured cartridge run ('extract': the v12 NSD2
-- trace's raw GX bus writes replayed through the authoritative chip front
-- end, 'Nds.Gpu3D.Chip', recording every geometry-engine input in order).
-- Nothing is dropped.
--
-- @check@ runs each stream twice through the same closed-loop driver
-- (random entry gaps, a random event ready, a random polygon stall, random
-- and post-swap VBlank pulses, acknowledges and @DISP_1DOT_DEPTH@ writes
-- when idle, full 33-word result sweeps): on the pure step with a block-RAM
-- model, where the whole RAM and every register is compared with the model
-- and with melonDS's recorded state after every input, and on the Clash
-- circuit ('geoMatrix', real 'blockRam'), and requires both runs to produce
-- the same outputs every cycle. Every transferred event is compared, in
-- order, with the model's ('toHwEvent') and its vertex words with melonDS's;
-- the status with the model's after every input; every result word with the
-- model's and melonDS's; the swap wait against its VBlank. With @--mutate@
-- one multi-word command in four has a non-final entry retagged with another
-- multi-word command (interleaved @ExecParams@ gathering, model only).
--
-- @time@ feeds the streams back to back (entry always valid, event always
-- ready, no stall, VBlank as soon as a swap waits) to both this engine and
-- 'Nds.Gpu3D.GeometryHw', prints cycles per command class against
-- melonDS's charge at one, two and three engine cycles per melonDS cycle,
-- and requires both engines to transfer the same events and to show the
-- same architectural @GXSTAT@ bits after every command. @dump@ writes the
-- cycle trace tests/geomtx_cosim.cpp replays on the generated Verilog.
-- @div@ checks 'Nds.Gpu3D.GeoDiv' against 'Nds.Gpu3D.GeometryHw''s divider
-- source and against the reference arithmetic.
--
-- Usage:
--   geomatrix-check extract TRACE.nsd2 OUT.gxs
--   geomatrix-check check FILE [SEED] [--mutate] [--limit N]
--   geomatrix-check time FILE [--limit N]
--   geomatrix-check dump FILE SEED OUT [STREAMS]
--   geomatrix-check div SRCDIR [N]
-- FILE is an oracle file (.bin) or an extracted stream (.gxs).
module Main (main) where

import Control.Concurrent (forkIO, getNumCapabilities)
import Control.Concurrent.MVar
import Control.Exception (evaluate)
import Control.Monad (forM_, replicateM_, unless, when)
import qualified Data.Array as A
import qualified Data.Array.Unboxed as U
import Data.Bits (complement, shiftL, shiftR, testBit, xor, (.&.), (.|.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Unsafe as BU
import Data.Char (isSpace)
import Data.Int (Int16, Int32)
import qualified Data.IntMap.Strict as IM
import Data.IORef
import Data.List (foldl', isPrefixOf, isSuffixOf, sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Word (Word32, Word64, Word8)
import Numeric (showFFloat, showHex)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (BufferMode (..), Handle, IOMode (..), hClose, hPutStrLn, hSetBuffering, openFile, stderr, stdout)

import Clash.Explicit.Prelude (Signed, Unsigned, Vec, enableGen, pack, toList)
import qualified Clash.Explicit.Prelude as C
import Clash.Explicit.Signal (systemClockGen, systemResetGen)
import Clash.Signal.Internal (Signal (..))

import Nds.Gpu2D.Trace (GeometryEvent (..), replayTraceGeometry)
import Nds.Gpu3D.Chip
import Nds.Gpu3D.GeoDiv
import Nds.Gpu3D.GeoMatrix
import Nds.Gpu3D.Geometry
import Nds.Gpu3D.Geometry.Lighting (Light (..), Material (..))
import Nds.Gpu3D.Geometry.Matrix (matElems)
import qualified Nds.Gpu3D.GeometryHw as Base
import Nds.Gpu3D.GeometryHw.Event (HwGeoEvent (..), fromHwEvent, toHwEvent)
import Nds.Gpu3D.GxFront (GxFront (..), Size (..), WriteAct (..), WriteFx (..), mmioWrite, popEntry, writeAction)
import Nds.Gpu3D.GxFrontHw (HwEntry (..))
import Nds.Gpu3D.Polygon (PolyPipeState (..))
import Nds.Gpu3D.Polygon.Clip (clipFactors, interpolate32)
import Nds.Gpu3D.Types

------------------------------------------------------------------------------
-- Streams

-- | A record's words, unboxed (a melonDS state record is 297 words: 1.2 kB
-- here, against about 16 kB as a boxed list).
type Words = U.UArray Int Word32

-- | One input and, for oracle files, melonDS's state and stored vertex after
-- it.
data Rec = Rec { rIn :: !GeoIn, rMel :: !(Maybe Words), rVert :: !(Maybe Words) }

-- | One stream, fully parsed.
type Stream = [Rec]

tagStream, tagRecord, tagStreamEnd, tagFileEnd :: Word32
tagStream = 0x5354524D
tagRecord = 0x52454331
tagStreamEnd = 0x454E4453
tagFileEnd = 0x454E4446

-- | Words of melonDS state after each oracle record (GeometryCheck's
-- @stateNames@), and of a stored vertex (its @vertexNames@).
nStateWords, nVertexWords :: Int
nStateWords = 297
nVertexWords = 19

-- | @k@ little-endian words from the front of the bytes, evaluated, and the
-- rest of the bytes; Nothing when fewer remain.
takeWords :: Int -> BL.ByteString -> Maybe ([Word32], BL.ByteString)
takeWords k bs =
  let (a, b) = BL.splitAt (4 * fromIntegral k) bs
      s = BL.toStrict a
      ws = [wordAt s (4 * i) | i <- [0 .. k - 1]]
  in if BS.length s /= 4 * k then Nothing else foldl' (flip seq) () ws `seq` Just (ws, b)

-- | 'takeWords' into an unboxed array.
takeArr :: Int -> BL.ByteString -> Maybe (Words, BL.ByteString)
takeArr k bs = do
  (ws, b) <- takeWords k bs
  let !arr = U.listArray (0, k - 1) ws
  pure (arr, b)

wordAt :: BS.ByteString -> Int -> Word32
wordAt s o = byte o .|. (byte (o + 1) `shiftL` 8) .|. (byte (o + 2) `shiftL` 16) .|. (byte (o + 3) `shiftL` 24)
  where byte i = fromIntegral (BU.unsafeIndex s i) :: Word32

inOf :: Word32 -> Word32 -> [Word32] -> GeoIn
inOf kind op params = case kind of
  0 -> GeoCmd (fromIntegral op) params
  1 -> SetZeroDotW (head params)
  _ -> AckStackError

-- | The streams of a file, read from disk one stream at a time: an element
-- is a whole stream parsed strictly, the rest of the file is read only when
-- the next element is demanded, and nothing keeps a stream once its
-- consumer drops it. A malformed file ends the list with a 'Left'. @limit@
-- keeps the first records of each stream.
fileStreams :: FilePath -> Maybe Int -> IO [Either String Stream]
fileStreams path limit = do
  bytes <- BL.readFile path
  let cut = maybe id take limit
  pure (if ".gxs" `isSuffixOf` path then gxsStreams cut bytes else oracleStreams cut bytes)

-- | A geometry_oracle file: per stream a tag and id, records, an end tag;
-- then the file-end tag and record count.
oracleStreams :: (Stream -> Stream) -> BL.ByteString -> [Either String Stream]
oracleStreams cut = top
  where
    top bs = case takeWords 2 bs of
      Just ([t, _], rest)
        | t == tagStream -> case records [] rest of
            Left e -> [Left e]
            Right (s, rest') -> let !s' = cut s in Right s' : top rest'
        | t == tagFileEnd -> []
      _ -> [Left "malformed oracle output at stream level"]
    records !acc bs = case takeWords 1 bs of
      Just ([t], rest) | t == tagStreamEnd -> Right (reverse acc, rest)
      _ -> case takeWords 4 bs of
        Just ([t, kind, op, n], rest) | t == tagRecord ->
          case takeWords (fromIntegral n) rest of
            Nothing -> truncated
            Just (params, r1) -> case takeArr nStateWords r1 of
              Nothing -> truncated
              Just (st, r2) -> case takeWords 1 r2 of
                Just ([nv], r3) ->
                  let vert = if nv == 1 then fmap (\(v, r) -> (Just v, r)) (takeArr nVertexWords r3)
                             else Just (Nothing, r3)
                  in case vert of
                       Just (vw, r4) -> case takeWords 3 r4 of
                         Just (_, r5) -> let !r = Rec (inOf kind op params) (Just st) vw in records (r : acc) r5
                         Nothing -> truncated
                       Nothing -> truncated
                _ -> truncated
        _ -> Left "malformed oracle output in a stream"
    truncated = Left "truncated record"

-- | An extracted stream (.gxs): per input kind, opcode, parameter count and
-- parameters, little-endian words, then 0xFFFFFFFF.
gxsStreams :: (Stream -> Stream) -> BL.ByteString -> [Either String Stream]
gxsStreams cut bytes = [fmap cut (go [] bytes)]
  where
    go !acc bs = case takeWords 1 bs of
      Just ([0xFFFFFFFF], rest) -> if BL.null rest then Right (reverse acc) else bad
      _ -> case takeWords 3 bs of
        Just ([k, op, n], rest) -> case takeWords (fromIntegral n) rest of
          Just (ps, rest') -> let !r = Rec (inOf k op ps) Nothing Nothing in go (r : acc) rest'
          Nothing -> bad
        _ -> bad
    bad = Left "malformed .gxs stream"

-- | Run @f@ on every stream with a fixed pool of at most four workers (the
-- capabilities, if fewer). Each worker takes the next stream from the file
-- when it has finished the last, and its result (a strict summary, so
-- evaluating it lets the stream go) is folded into the accumulator at once:
-- at most four streams are in memory, whatever the core count. A malformed
-- file stops the run with its error.
foldStreams :: [Either String Stream] -> (Int -> Stream -> r) -> (acc -> Int -> r -> acc) -> acc -> IO (Either String acc)
foldStreams streams f combine acc0 = do
  caps <- min 4 <$> getNumCapabilities
  src <- newMVar (zip [0 :: Int ..] streams)
  accV <- newMVar acc0
  failV <- newMVar Nothing
  done <- newEmptyMVar
  let worker = do
        job <- modifyMVar src (\l -> case l of
                 [] -> pure ([], Nothing)
                 (j : js) -> pure (js, Just j))
        case job of
          Nothing -> putMVar done ()
          Just (_, Left e) -> modifyMVar_ failV (const (pure (Just e))) >> modifyMVar_ src (const (pure [])) >> worker
          Just (k, Right s) -> do
            r <- evaluate (f k s)
            modifyMVar_ accV (\a -> evaluate (combine a k r))
            worker
  replicateM_ caps (forkIO worker)
  replicateM_ caps (takeMVar done)
  e <- readMVar failV
  case e of
    Just msg -> pure (Left msg)
    Nothing -> Right <$> readMVar accV

------------------------------------------------------------------------------
-- The architectural state, from the model and from the engine

data View = View
  { vMode :: Word8, vProj, vPos, vVec, vTex, vClip :: [Int32]
  , vProjS, vTexS :: [Int32], vPosS, vVecS :: [[Int32]]
  , vProjSP, vPosSP, vTexSP :: Word8, vErr :: Bool
  , vVtx :: VtxView
  , vLights :: [[Int32]]                 -- ^ per light: direction x, y, z, specular reciprocal
  , vLCol :: [(Word8, Word8, Word8)]
  , vMat :: [(Word8, Word8, Word8)]      -- ^ diffuse, ambient, specular, emission
  , vUseSh :: Bool
  , vShine :: [Word32]                   -- ^ the 128-byte table as 32 little-endian words
  , vBox :: Bool
  , vPosT :: [Int32]
  , vVecT :: [Int32] }
  deriving (Eq, Show)

-- | The vertex-side state: current vertex, colour, texture coordinates, raw
-- texture coordinates, polygon attribute, latched attribute, texture
-- parameter, palette, viewport, @ZeroDotWLimit@.
data VtxView = VtxView
  { xCur :: (Int16, Int16, Int16), xCol :: (Word8, Word8, Word8), xTex, xRaw :: (Int16, Int16)
  , xAttr, xCurAttr, xTexP, xPal :: Word32, xVp :: (Word32, Word32, Word32, Word32, Word32, Word32)
  , xZero :: Word32 }
  deriving (Eq, Show)

viewOf :: GeoState -> View
viewOf s = View
  { vMode = gMtxMode s, vProj = matElems (gProj s), vPos = matElems (gPos s)
  , vVec = matElems (gVec s), vTex = matElems (gTex s), vClip = matElems (currentClip s)
  , vProjS = matElems (gProjStack s), vTexS = matElems (gTexStack s)
  , vPosS = map matElems (A.elems (gPosStack s)), vVecS = map matElems (A.elems (gVecStack s))
  , vProjSP = gProjSP s, vPosSP = gPosSP s, vTexSP = gTexSP s, vErr = gStackError s
  , vVtx = vtxOf s
  , vLights = [ [fromIntegral x, fromIntegral y, fromIntegral z, lSpecRecip l]
              | l <- A.elems (gLights s), let (x, y, z) = lDir l ]
  , vLCol = map lColor (A.elems (gLights s))
  , vMat = [mDiffuse m, mAmbient m, mSpecular m, mEmission m]
  , vUseSh = mUseShininess m
  , vShine = [ foldr (\j acc -> (acc `shiftL` 8) .|. fromIntegral (mShininess m U.! (4 * i + j))) 0 [0 .. 3]
             | i <- [0 .. 31] ]
  , vBox = gBoxResult s
  , vPosT = let (a, b, c, d) = gPosTest s in [a, b, c, d]
  , vVecT = let (a, b, c) = gVecTest s in map fromIntegral [a, b, c] }
  where
    m = gMaterial s

vtxOf :: GeoState -> VtxView
vtxOf s = VtxView
  { xCur = gCurVertex s, xCol = gVertexColor s, xTex = gTexCoords s, xRaw = gRawTexCoords s
  , xAttr = gPolyAttr s, xCurAttr = gCurPolyAttr s, xTexP = gTexParam s, xPal = gTexPalette s
  , xVp = gViewport s, xZero = gZeroDotW s }

type Row = Vec 4 (Signed 32)

-- | The engine's state from its registers and RAM (@ZeroDotWLimit@ is the
-- front end's, passed in).
engView :: Gm -> IM.IntMap Row -> Word32 -> View
engView g mem zero = View
  { vMode = fromIntegral (gmMode g), vProj = matAt rowProj, vPos = matAt rowPos, vVec = matAt rowVec
  , vTex = matAt rowTex, vClip = matAt rowClip, vProjS = matAt rowProjStack, vTexS = matAt rowTexStack
  , vPosS = [matAt (rowPosStack (fromIntegral i)) | i <- [0 .. 31 :: Int]]
  , vVecS = [matAt (rowVecStack (fromIntegral i)) | i <- [0 .. 31 :: Int]]
  , vProjSP = sp0, vPosSP = sp1, vTexSP = sp2, vErr = e0
  , vVtx = VtxView cur col tex raw attr curA texP pal vp zero
  , vLights = [rowAt (rowLight (fromIntegral l)) | l <- [0 .. 3 :: Int]]
  , vLCol = lcol
  , vMat = [dif, amb, spe, emi]
  , vUseSh = useSh
  , vShine = [ fromIntegral (rowAt (rowShine + fromIntegral (i `div` 4)) !! (i `mod` 4)) | i <- [0 .. 31 :: Int] ]
  , vBox = box
  , vPosT = rowAt rowPosRes
  , vVecT = take 3 (rowAt rowVecRes) }
  where
    rowAt :: RowAddr -> [Int32]
    rowAt a = map fromIntegral (toList (IM.findWithDefault (C.repeat 0) (fromIntegral a) mem))
    matAt base = concatMap (\r -> rowAt (base + r)) [0 .. 3]
    (cur, col, tex, raw, attr, curA, texP, pal, vp) = gmVertexRegs g
    (lcol, dif, amb, spe, emi, useSh, box, _) = gmLightRegs g
    (sp0, sp1, sp2, e0) = gmPointers g

fieldDiffs :: View -> View -> [(String, Bool)]
fieldDiffs a b =
  [ ("mode", vMode a /= vMode b), ("projection", vProj a /= vProj b), ("position", vPos a /= vPos b)
  , ("vector", vVec a /= vVec b), ("texture", vTex a /= vTex b), ("clip", vClip a /= vClip b)
  , ("projection stack", vProjS a /= vProjS b), ("texture stack", vTexS a /= vTexS b)
  , ("position stack", vPosS a /= vPosS b), ("vector stack", vVecS a /= vVecS b)
  , ("pointers/error", (vProjSP a, vPosSP a, vTexSP a, vErr a) /= (vProjSP b, vPosSP b, vTexSP b, vErr b))
  , ("vertex state", vVtx a /= vVtx b)
  , ("light directions/reciprocals", vLights a /= vLights b), ("light colours", vLCol a /= vLCol b)
  , ("material", (vMat a, vUseSh a) /= (vMat b, vUseSh b)), ("shininess table", vShine a /= vShine b)
  , ("box-test result", vBox a /= vBox b), ("position-test result", vPosT a /= vPosT b)
  , ("vector-test result", vVecT a /= vVecT b) ]

-- | melonDS's FNV-1a stack hash (geometry_oracle.cpp @stackHash@).
stackHashOf :: View -> Word64
stackHashOf v = foldl' mix 0xCBF29CE484222325 (vProjS v ++ vTexS v ++ concat (vPosS v) ++ concat (vVecS v))
  where mix h x = (h `xor` fromIntegral (fromIntegral x :: Word32)) * 0x100000001B3

-- | melonDS state word offsets (GeometryCheck's @stateNames@).
melMode, melProj, melPos, melVec, melTex, melProjSP, melPosSP, melTexSP, melHashLo, melHashHi, melGxStat :: Int
melMode = 0
melProj = 1
melPos = 17
melVec = 33
melTex = 49
melProjSP = 82
melPosSP = 83
melTexSP = 84
melHashLo = 85
melHashHi = 86
melGxStat = 87
melCur, melCol, melTexC, melRaw, melLights, melMat, melUseSh, melShine, melAttr, melPosT, melVecT :: Int
melCur = 89
melCol = 92
melTexC = 95
melRaw = 97
melLights = 102
melMat = 130
melUseSh = 142
melShine = 143
melAttr = 175
melPosT = 186
melVecT = 190
melRead, melRead16 :: Int
melRead = nStateWords - 66 - 5 - 33
melRead16 = nStateWords - 66

-- | The engine's state against melonDS's record (everything melonDS dumps
-- except @Normal@, which the engine does not keep: nothing reads it after its
-- command, and @ZeroDotWLimit@, which is the front end's).
melDiffs :: View -> Words -> [String]
melDiffs eng st = [ "differs from melonDS in " ++ n | (n, False) <- checks ]
  where
    w i = st U.! i
    ints base = [fromIntegral (w (base + i)) | i <- [0 .. 15]] :: [Int32]
    i16 i = fromIntegral (w i) :: Int16
    u32 :: Int32 -> Word32
    u32 = fromIntegral
    c3 (a, b, c) = map fromIntegral [a, b, c] :: [Word32]
    hash = fromIntegral (w melHashLo) .|. (fromIntegral (w melHashHi) `shiftL` 32) :: Word64
    x = vVtx eng
    (vp0, vp1, vp2, vp3, vp4, vp5) = xVp x
    (c0, c1, c2) = xCur x
    checks =
      [ ("matrix mode", fromIntegral (w melMode) == vMode eng)
      , ("projection matrix", ints melProj == vProj eng)
      , ("position matrix", ints melPos == vPos eng)
      , ("vector matrix", ints melVec == vVec eng)
      , ("texture matrix", ints melTex == vTex eng)
      , ("projection stack pointer", fromIntegral (w melProjSP) == vProjSP eng)
      , ("position stack pointer", fromIntegral (w melPosSP) == vPosSP eng)
      , ("texture stack pointer", fromIntegral (w melTexSP) == vTexSP eng)
      , ("stack hash", hash == stackHashOf eng)
      , ("GXSTAT bits 1 and 15", w melGxStat == ((if vErr eng then 0x8000 else 0) .|. (if vBox eng then 2 else 0)))
      , ("current vertex", [i16 melCur, i16 (melCur + 1), i16 (melCur + 2)] == [c0, c1, c2])
      , ("vertex colour", [w melCol, w (melCol + 1), w (melCol + 2)] == c3 (xCol x))
      , ("texture coordinates", (i16 melTexC, i16 (melTexC + 1)) == xTex x)
      , ("raw texture coordinates", (i16 melRaw, i16 (melRaw + 1)) == xRaw x)
      , ("light directions/reciprocals", [ [w (melLights + 7 * l + i) | i <- [0 .. 3]] | l <- [0 .. 3] ]
                                          == map (map u32) (vLights eng))
      , ("light colours", [ [w (melLights + 7 * l + 4 + i) | i <- [0 .. 2]] | l <- [0 .. 3] ] == map c3 (vLCol eng))
      , ("material colours", [w (melMat + i) | i <- [0 .. 11]] == concatMap c3 (vMat eng))
      , ("shininess-table enable", (w melUseSh /= 0) == vUseSh eng)
      , ("shininess table", [w (melShine + i) | i <- [0 .. 31]] == vShine eng)
      , ("polygon attributes", [w melAttr, w (melAttr + 1), w (melAttr + 2), w (melAttr + 3)]
                                 == [xAttr x, xCurAttr x, xTexP x, xPal x])
      , ("viewport", [w (melAttr + 4 + i) | i <- [0 .. 5]] == [vp0, vp1, vp2, vp3, vp4, vp5])
      , ("position-test result", [w (melPosT + i) | i <- [0 .. 3]] == map u32 (vPosT eng))
      , ("vector-test result", [w (melVecT + i) | i <- [0 .. 2]] == map u32 (vVecT eng)) ]

-- | melonDS's word at a result address (@0x04000630@ / @0x04000634@ as the
-- two halfwords @VEC_RESULT@ reads as, the rest as its 32-bit reads).
melResult :: Words -> Word32 -> Word32
melResult st al
  | al == 0x04000630 = r16 0x04000630 .|. (r16 0x04000632 `shiftL` 16)
  | al == 0x04000634 = r16 0x04000634 .|. (r16 0x04000636 `shiftL` 16)
  | otherwise = st U.! (melRead + fromIntegral ((al - 0x04000620) `div` 4))
  where
    r16 :: Word32 -> Word32
    r16 a = st U.! (melRead16 + fromIntegral ((a - 0x04000620) `div` 2))

------------------------------------------------------------------------------
-- Random numbers (GeometryHwCheck's)

newtype Rng = Rng Word64

next :: Rng -> (Word64, Rng)
next (Rng s) =
  let s' = s + 0x9E3779B97F4A7C15
      z1 = (s' `xor` (s' `shiftR` 30)) * 0xBF58476D1CE4E5B9
      z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94D049BB133111EB
  in (z2 `xor` (z2 `shiftR` 31), Rng s')

below :: Int -> Rng -> (Int, Rng)
below n r = let (x, r') = next r in (fromIntegral (x `mod` fromIntegral n), r')

chance :: Int -> Rng -> (Bool, Rng)
chance pct r = let (x, r') = below 100 r in (x < pct, r')

------------------------------------------------------------------------------
-- Stimulus

data Item = IEntry !HwEntry | IAck | IZero !Word32
  deriving (Show)

multiWord :: [Word8]
multiWord = [0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x23, 0x34, 0x70, 0x71]

-- | Entries in FIFO order; @mutate@ retags one non-final entry of a
-- multi-word command in four with another multi-word command.
itemsOf :: Bool -> Rng -> [GeoIn] -> [Item]
itemsOf mutate = go
  where
    go _ [] = []
    go r (i : is) = case i of
      SetZeroDotW z -> IZero z : go r is
      AckStackError -> IAck : go r is
      GeoCmd op ps
        | cmdNumParams op <= 1 -> IEntry (HwEntry op (headOr ps)) : go r is
        | otherwise ->
            let n = cmdNumParams op
                ws = take n (ps ++ repeat 0)
                (hit, r1) = if mutate then chance 25 r else (False, r)
                (k, r2) = below (n - 1) r1
                (m, r3) = below (length multiWord) r2
                tagOf j = if hit && j == k then multiWord !! m else op
            in [IEntry (HwEntry (tagOf j) w) | (j, w) <- zip [0 ..] ws] ++ go r3 is
    headOr ps = case ps of
      (p : _) -> p
      [] -> 0

gather :: HwEntry -> [Word32] -> (Maybe GeoIn, [Word32])
gather (HwEntry c p) = gatherEntry (CmdEntry c p)

------------------------------------------------------------------------------
-- Command classes and melonDS's charges

-- | Timing classes, as GeometryHwCheck names them (without its stale-clip
-- split: both engines keep the clip matrix current).
cmdClass :: GeoState -> Word8 -> String
cmdClass s op = case op of
  0x10 -> "MTX_MODE"
  0x11 -> "PUSH " ++ grp
  0x12 -> "POP " ++ grp
  0x13 -> "STORE " ++ grp
  0x14 -> "RESTORE " ++ grp
  0x15 -> "IDENTITY " ++ md
  0x16 -> "LOAD_4x4 " ++ md
  0x17 -> "LOAD_4x3 " ++ md
  0x18 -> "MULT_4x4 " ++ md
  0x19 -> "MULT_4x3 " ++ md
  0x1A -> "MULT_3x3 " ++ md
  0x1B -> "SCALE " ++ md
  0x1C -> "TRANS " ++ md
  0x20 -> "COLOR"
  0x21 -> "NORMAL " ++ show nl ++ " light" ++ (if nl == 1 then "" else "s") ++ (if tmode == 2 then ", texcoord mode 2" else "")
  0x22 -> if tmode == 1 then "TEXCOORD mode 1" else "TEXCOORD"
  _ | op >= 0x23 && op <= 0x28 ->
        (if op == 0x23 then "VTX_16" else "VTX_10/XY/XZ/YZ/DIFF") ++ (if tmode == 3 then ", texcoord mode 3" else "")
  0x29 -> "POLYGON_ATTR"
  0x2A -> "TEXIMAGE_PARAM"
  0x2B -> "PLTT_BASE"
  0x30 -> "DIF_AMB"
  0x31 -> "SPE_EMI"
  0x32 -> "LIGHT_VECTOR"
  0x33 -> "LIGHT_COLOR"
  0x34 -> "SHININESS"
  0x40 -> "BEGIN_VTXS"
  0x41 -> "END_VTXS"
  0x50 -> "SWAP_BUFFERS"
  0x60 -> "VIEWPORT"
  0x70 -> "BOX_TEST"
  0x71 -> "POS_TEST"
  0x72 -> "VEC_TEST"
  _ -> "other"
  where
    m = gMtxMode s
    grp | m == 0 = "proj" | m == 3 = "tex" | otherwise = "pos/vec"
    md = "mode " ++ show m
    tmode = gTexParam s `shiftR` 30
    nl = length [() | i <- [0 .. 3 :: Int], testBit (gCurPolyAttr s) i]

-- | Cycles the vendored melonDS charges a command run in isolation
-- (GeometryHwCheck's table: one per entry plus the command's own
-- @AddCycles@; the 7-cycle vertex and normal pipelines later commands may
-- wait on are left out).
melonCycles :: String -> Maybe Int
melonCycles cls = lookup cls table
  where
    table =
      [ ("MTX_MODE", 1), ("PUSH proj", 17), ("PUSH pos/vec", 17), ("PUSH tex", 17)
      , ("POP proj", 36), ("POP pos/vec", 36), ("POP tex", 18)
      , ("STORE proj", 17), ("STORE pos/vec", 17), ("STORE tex", 17)
      , ("RESTORE proj", 36), ("RESTORE pos/vec", 36), ("RESTORE tex", 18)
      ] ++ concat
      [ [ ("IDENTITY mode " ++ show m, if m == 3 then 1 else 19)
        , ("LOAD_4x4 mode " ++ show m, if m == 3 then 26 else 34)
        , ("LOAD_4x3 mode " ++ show m, if m == 3 then 19 else 30)
        , ("MULT_4x4 mode " ++ show m, mult m)
        , ("MULT_4x3 mode " ++ show m, mult m)
        , ("MULT_3x3 mode " ++ show m, mult m)
        , ("SCALE mode " ++ show m, if m == 3 then 33 else 35)
        , ("TRANS mode " ++ show m, mult m) ]
      | m <- [0 .. 3 :: Int] ] ++
      [ ("COLOR", 1), ("TEXCOORD", 1), ("TEXCOORD mode 1", 1)
      , ("POLYGON_ATTR", 1), ("TEXIMAGE_PARAM", 1), ("PLTT_BASE", 1)
      , ("DIF_AMB", 4), ("SPE_EMI", 4), ("LIGHT_VECTOR", 6), ("LIGHT_COLOR", 2), ("SHININESS", 32)
      , ("BEGIN_VTXS", 1), ("END_VTXS", 1), ("SWAP_BUFFERS", 1), ("VIEWPORT", 1)
      , ("POS_TEST", 7), ("VEC_TEST", 5), ("BOX_TEST", 257), ("other", 1)
      ] ++
      [ ("NORMAL " ++ show n ++ " light" ++ (if n == 1 then "" else "s") ++ t, 1 + max 1 n)
      | n <- [0 .. 4 :: Int], t <- ["", ", texcoord mode 2"] ] ++
      [ (v ++ t, c) | (v, c) <- [("VTX_16", 5), ("VTX_10/XY/XZ/YZ/DIFF", 4)], t <- ["", ", texcoord mode 3"] ]
    mult m = if m == 3 then 33 else if m == 2 then 65 else 35

-- | melonDS's stored-vertex words for an event (GeometryCheck's
-- @vertexWords@).
vertexWordsOf :: HwGeoEvent -> Maybe [Word32]
vertexWordsOf ev = case fromHwEvent ev of
  GeVertex cv ps -> Just $
    map i32 [cvX cv, cvY cv, cvZ cv, cvW cv, cvR cv, cvG cv, cvB cv]
    ++ map (i32 . (fromIntegral :: Int16 -> Int32)) [cvS cv, cvT cv]
    ++ [psAttr ps, psTexParam ps, psTexPalette ps] ++ vp (psViewport ps) ++ [psZeroDotW ps]
  _ -> Nothing
  where
    i32 :: Int32 -> Word32
    i32 = fromIntegral
    vp (a, b, c, d, e, f) = [a, b, c, d, e, f]

-- | The architectural @GXSTAT@ bits (box result, stack levels, stack error),
-- as the melonDS state word @read32(0x600) & 0xBF02@.
archMask :: Word32
archMask = 0xBF02

------------------------------------------------------------------------------
-- Driver

-- | Feeding entries; waiting @n@ settle cycles, then for the engine to go
-- idle with no event outstanding; sweeping the 33 result words.
data Phase = PFeed | PWait !Int | PSweep !Int
  deriving (Eq, Show)

data Timing = Timing { tmCount :: !Int, tmSum :: !Int, tmMin :: !Int, tmMax :: !Int }

mergeT :: Timing -> Timing -> Timing
mergeT (Timing c1 s1 a1 b1) (Timing c2 s2 a2 b2) = Timing (c1 + c2) (s1 + s2) (min a1 a2) (max b1 b2)

data D = D
  { dItems    :: [Item]
  , dMel      :: [(Maybe Words, Maybe Words)]        -- ^ melonDS state and vertex per remaining input
  , dCurMel   :: !(Maybe Words)
  , dModel    :: !GeoState
  , dGather   :: [Word32]
  , dExpect   :: [(HwGeoEvent, Maybe Words)]         -- ^ model events, with melonDS's vertex words
  , dPhase    :: !Phase
  , dEntry    :: !(Maybe HwEntry)     -- ^ driven this cycle
  , dAck      :: !Bool
  , dEvReady  :: !Bool
  , dStall    :: !Bool
  , dVbl      :: !Bool
  , dVblPrev  :: !Bool                -- ^ VBlank driven in the previous cycle
  , dSwapPrevO :: !Bool               -- ^ the swap waited in the previous cycle
  , dSwapExp  :: !(Maybe Int)         -- ^ cycle a swap event was transferred; the engine must wait
  , dZero     :: !Word32
  , dRead     :: !(Maybe Word32)      -- ^ read address driven this cycle
  , dPend     :: !(Maybe Word32)      -- ^ read taken last cycle
  , dRng      :: !Rng
  , dTime     :: !Bool
  , dCycle    :: !Int
  , dIdle     :: !Int
  , dFull     :: !Bool                -- ^ the pure runner compares the RAM this cycle
  , dErrs     :: ![String]           -- ^ the first 12 mismatches (forced: a mutant makes millions)
  , dNErr     :: !Int
  , dDone     :: !Bool
  , dInputs, dEntries, dEvents, dVerts, dMelVerts, dSwaps, dEvWaits, dStallC, dSwapC :: !Int
  , dReads, dMelReads, dStatus, dGaps, dMelCyc :: !Int
  , dStart    :: !(Maybe Int)
  , dPending  :: !(Maybe (Int, String))
  , dTimes    :: !(M.Map String Timing)
  , dPostStat :: !Int                 -- ^ post-command GXSTAT checks (time mode)
  }

d0 :: Bool -> [Item] -> [(Maybe Words, Maybe Words)] -> Word64 -> D
d0 tm items mel seed = D
  { dItems = items, dMel = mel, dCurMel = Nothing, dModel = initGeoState, dGather = [], dExpect = []
  , dPhase = PFeed, dEntry = Nothing, dAck = False, dEvReady = True, dStall = False
  , dVbl = False, dVblPrev = False, dSwapPrevO = False, dSwapExp = Nothing
  , dZero = gZeroDotW initGeoState, dRead = Nothing, dPend = Nothing
  , dRng = Rng seed, dTime = tm, dCycle = 0, dIdle = 0, dFull = False, dErrs = [], dNErr = 0
  , dDone = False, dInputs = 0, dEntries = 0, dEvents = 0, dVerts = 0, dMelVerts = 0, dSwaps = 0, dEvWaits = 0
  , dStallC = 0, dSwapC = 0, dReads = 0, dMelReads = 0, dStatus = 0, dGaps = 0, dMelCyc = 0
  , dStart = Nothing, dPending = Nothing, dTimes = M.empty, dPostStat = 0 }

err :: String -> D -> D
err m d = let !c = dCycle d; es = dErrs d
          in d { dErrs = if length es < 12 then es ++ ["cycle " ++ show c ++ ": " ++ m] else es
               , dNErr = dNErr d + 1 }

hexs :: Word32 -> String
hexs w = "0x" ++ showHex w ""

statusWord :: GeoStatus -> Word32
statusWord = fromIntegral . gmStatusBits

-- | One clock: what the engine drove for the inputs @d@ drove.
cycleStep :: D -> GmOut -> D
cycleStep d o = finish (phases afterEntry)
  where
    -- events transferred this cycle
    afterEv = case goEvent o of
      Just ev | dEvReady d -> case dExpect d of
        ((e, mv) : es)
          | e /= ev -> err ("event mismatch: engine " ++ show ev ++ " model " ++ show e) d { dExpect = es }
          | otherwise ->
              let dA = d { dExpect = es, dEvents = dEvents d + 1
                         , dVerts = dVerts d + (case ev of HeVertex _ _ -> 1; _ -> 0)
                         , dSwaps = dSwaps d + (case ev of HeSwap _ -> 1; _ -> 0) }
              in case (mv, vertexWordsOf ev) of
                   (Just want, Just got)
                     | U.elems want == got -> dA { dMelVerts = dMelVerts dA + 1 }
                     | otherwise -> err ("vertex differs from melonDS: engine " ++ show got ++ " melonDS " ++ show want) dA
                   _ -> dA
        [] -> err ("unexpected event " ++ show ev) d
      Just _ -> d { dEvWaits = dEvWaits d + 1 }
      Nothing -> d
    -- the swap wait: from the cycle the swap event is taken until a VBlank
    -- driven in a later cycle
    released = case dSwapExp d of
      Just t -> dVblPrev d && dCycle d - 1 >= t + 1
      Nothing -> False
    swapExp' = case (goEvent o, dEvReady d) of
      (Just (HeSwap _), True) -> Just (dCycle d)
      _ | released -> Nothing
        | otherwise -> dSwapExp d
    afterSwap = foldl' (flip err) afterEv { dSwapExp = swapExp', dSwapC = dSwapC afterEv + fromEnum (goSwapWait o) }
      ( [ "entry ready while the swap waits for VBlank" | goReady o && goSwapWait o ]
        ++ [ "swap released without a VBlank" | dSwapPrevO d && not (goSwapWait o) && not (dVblPrev d) ]
        ++ [ "swap wait " ++ show (goSwapWait o) ++ ", expected " ++ show (not released)
           | isJust (dSwapExp d) && goSwapWait o /= not released ] )
    -- read data
    afterRead = case dPend afterSwap of
      Just a ->
        let want = geoReadResult (dModel afterSwap) a
            got = fmap (\v -> fromIntegral (pack v)) (goRdData o) :: Maybe Word32
            dA = afterSwap { dReads = dReads afterSwap + 1 }
            dB = if got == Just want then dA
                 else err ("result " ++ hexs a ++ ": engine " ++ maybe "none" hexs got ++ " model " ++ hexs want) dA
            al = a .&. complement 3
        in case dCurMel dB of
             Just st ->
               let mw = melResult st al
                   dC = dB { dMelReads = dMelReads dB + 1 }
               in if got == Just mw then dC
                  else err ("result " ++ hexs a ++ ": engine " ++ maybe "none" hexs got ++ " melonDS " ++ hexs mw) dC
             _ -> dB
      Nothing -> if isJust (goRdData o) then err "read data without a read" afterSwap else afterSwap
    -- timing, and the architectural status after each command against the
    -- model's (time mode)
    afterTime = case dPending afterRead of
      Just (t0, cls) | goReady o ->
        let n = dCycle afterRead - t0
            got = statusWord (goStatus o) .&. archMask
            want = statusWord (geoStatus (dModel afterRead)) .&. archMask
            dA = afterRead { dPending = Nothing, dTimes = M.insertWith mergeT cls (Timing 1 n n n) (dTimes afterRead)
                           , dPostStat = dPostStat afterRead + 1 }
        in if got == want then dA else err ("GXSTAT after " ++ cls ++ ": engine " ++ hexs got ++ " model " ++ hexs want) dA
      _ -> afterRead
    popMel dd = case dMel dd of
      (m : ms) -> (m, ms)
      [] -> ((Nothing, Nothing), [])
    -- side inputs (acknowledge, DISP_1DOT_DEPTH) driven this cycle
    sideIn dd gi =
      let (s', _) = step (dModel dd) gi
          ((m, _), ms) = popMel dd
      in dd { dModel = s', dInputs = dInputs dd + 1, dPhase = if dTime dd then PFeed else PWait 1
            , dCurMel = m, dMel = ms }
    afterAck = if dAck afterTime then sideIn afterTime AckStackError else afterTime
    -- entry transfer
    afterEntry = case dEntry afterAck of
      Just e | goReady o ->
        let dA = afterAck { dItems = drop 1 (dItems afterAck), dEntries = dEntries afterAck + 1
                          , dStart = Just (fromMaybe (dCycle afterAck) (dStart afterAck)) }
            (mgi, g') = gather e (dGather dA)
        in case mgi of
             Nothing -> dA { dGather = g' }
             Just gi@(GeoCmd op _) ->
               let (s', evs) = step (dModel dA) gi
                   ((m, mv), ms) = popMel dA
                   exp' = [ (toHwEvent ev, case ev of GeVertex _ _ -> mv; _ -> Nothing) | ev <- evs ]
                   cls = cmdClass (dModel dA) op
               in dA { dGather = g', dModel = s', dInputs = dInputs dA + 1, dCurMel = m, dMel = ms
                     , dExpect = dExpect dA ++ exp'
                     , dPhase = if dTime dA then PFeed else PWait 1
                     , dPending = if dTime dA then Just (fromMaybe (dCycle dA) (dStart dA), cls) else Nothing
                     , dMelCyc = dMelCyc dA + fromMaybe 1 (melonCycles cls)
                     , dStart = Nothing }
             Just _ -> dA
      _ -> afterAck
    idleNow = goReady o && isNothing (goEvent o)
    phases dd = case dPhase dd of
      PWait n | n > 0 -> dd { dPhase = PWait (n - 1) }
      PWait _
        | not idleNow || not (null (dExpect dd)) -> dd { dIdle = dIdle dd + 1 }
        | otherwise ->
            let want = geoStatus (dModel dd)
                st = goStatus o
                dA = dd { dStatus = dStatus dd + 1, dIdle = 0, dFull = True
                        , dPhase = if dTime dd then PFeed else PSweep 0 }
                dB = if st == want then dA else err ("status: engine " ++ show st ++ " model " ++ show want) dA
                dC = case dCurMel dB of
                  Just mst ->
                    let bad = [ "melonDS stack levels " ++ show (mst U.! melPosSP, mst U.! melProjSP)
                                ++ " engine " ++ show (gsPosStack st, gsProjStack st)
                              | fromIntegral (mst U.! melPosSP .&. 0x1F) /= gsPosStack st
                                || (mst U.! melProjSP == 1) /= gsProjStack st ]
                    in foldl' (flip err) dB bad
                  Nothing -> dB
            in dC
      _ -> dd
    finish dd =
      let r0 = dRng dd
          (gapRoll, r1) = chance 70 r0
          (lowBits, r2) = below 4 r1
          (rdyRoll, r3) = chance 65 r2
          (stallFlip, r4) = chance 12 r3
          (vblRoll, r5) = chance 6 r4
          (spurious, r6) = below 400 r5
          tm = dTime dd
          feeding = dPhase dd == PFeed
          quiet = feeding && idleNow && isNothing (dPending dd) && null (dExpect dd) && not (dAck dd)
          (entry, ack, zero) = case dItems dd of
            (IEntry e : _) | feeding && (tm || gapRoll) -> (Just e, False, Nothing)
            (IAck : _) | quiet -> (Nothing, True, Nothing)
            (IZero z : _) | quiet -> (Nothing, False, Just z)
            _ -> (Nothing, False, Nothing)
          ddZ = case zero of
            Just z -> (sideIn dd (SetZeroDotW z)) { dItems = drop 1 (dItems dd) }
            Nothing -> dd
          zeroW = gZeroDotW (dModel ddZ)
          dropAck = if ack then drop 1 (dItems ddZ) else dItems ddZ
          -- a read is checked the cycle after the engine took it
          tookRead = isJust (dRead d) && goRdReady o
          pend' = if tookRead then dRead d else Nothing
          sweepK = case dPhase ddZ of
            PSweep k -> Just (if tookRead then k + 1 else k)
            _ -> Nothing
          phaseN = case sweepK of
            Just k | k > 32 -> PFeed
                   | otherwise -> PSweep k
            Nothing -> dPhase ddZ
          readA = case phaseN of
            PSweep k -> Just (0x04000620 + 4 * fromIntegral k + fromIntegral lowBits)
            _ -> Nothing
          swapWaiting = goSwapWait o && isNothing (goEvent o)
          hung = dIdle ddZ > 100000
          done = null dropAck && feeding && not ack && isNothing zero && isNothing (dPending dd) && idleNow
                 && null (dExpect dd) && isNothing (dEntry dd) && isNothing pend' && isNothing (dPend dd)
      in (if hung then err "hang: the engine never went idle" else id) ddZ
           { dItems = dropAck, dEntry = entry, dAck = ack, dRead = readA, dPend = pend'
           , dPhase = phaseN, dZero = zeroW
           , dEvReady = tm || rdyRoll
           , dStall = not tm && (if stallFlip then not (dStall dd) else dStall dd)
           , dVbl = (swapWaiting && (tm || vblRoll)) || (not tm && spurious == 0)
           , dVblPrev = dVbl d
           , dSwapPrevO = goSwapWait o
           , dStallC = dStallC dd + fromEnum (dStall d)
           , dRng = r6, dCycle = dCycle dd + 1, dDone = done || hung
           , dGaps = dGaps dd + (case (dItems dd, entry) of (IEntry _ : _, Nothing) | feeding -> 1; _ -> 0) }

inputsOf :: D -> GmIn
inputsOf d = GmIn (dEntry d) (dEvReady d) (dStall d) (dVbl d) (dAck d) (fromIntegral (dZero d)) (fmap fromIntegral (dRead d))

------------------------------------------------------------------------------
-- Runners

-- | One stream through the pure step (with block-RAM models, read before
-- write) and the Clash circuit in lock step: each cycle the circuit's
-- outputs must equal the pure step's, and after every input the whole RAM
-- and every register are compared with the model and melonDS. Nothing of a
-- past cycle is kept. Cycle 0 is the reset cycle of 'systemResetGen': the
-- registers keep their reset value across it (the RAM write it drives still
-- happens, as in the circuit).
data Run = Run { ruD :: !D, ruFull :: !Int, ruMelFull :: !Int, ruNFullErr :: !Int, ruFullErr :: ![String]
               , ruDiff :: !(Maybe Int) }

runStream :: D -> Run
runStream dInit = go gmInit dInit (RamQ (C.repeat 0) 0) IM.empty IM.empty (clashTrace dInit) 0 0 [] 0 Nothing
  where
    go !g !d !q !mem !prm cl !nf !nm errs !ne !diff =
      let (g'0, o, ops) = gmStep g (inputsOf d) q
          g' = if dCycle d == 0 then gmInit else g'0
          d' = cycleStep d o
          rowAt a = IM.findWithDefault (C.repeat 0) a mem
          q' = RamQ (rowAt (fromIntegral (opRowRdOf ops))) (IM.findWithDefault 0 (fromIntegral (opPrmRdOf ops)) prm)
          mem' = case opRowWrOf ops of
            Just (a, v) -> IM.insert (fromIntegral a) v mem
            Nothing -> mem
          prm' = case opPrmWrOf ops of
            Just (a, v) -> IM.insert (fromIntegral a) v prm
            Nothing -> prm
          -- the circuit's outputs this cycle; after the first difference the
          -- circuit is no longer followed
          (diff', cl') = case cl of
            ((_, oc) : rest) | isNothing diff -> if oc == o then (Nothing, rest) else (Just (dCycle d), [])
            _ -> (if isNothing diff then Just (dCycle d) else diff, [])
          (nf', nm', errs', ne') =
            if dFull d'
              then let s = dModel d'
                       eng = engView g mem (gZeroDotW s)
                       bad = [ "RAM/registers differ from the model in " ++ f | (f, True) <- fieldDiffs (viewOf s) eng ]
                             ++ maybe [] (melDiffs eng) (dCurMel d')
                       e2 = if null bad || length errs >= 12 then errs
                            else take 12 (errs ++ map (("cycle " ++ show (dCycle d) ++ ": ") ++) bad)
                   in length e2 `seq` (nf + 1, nm + fromEnum (isJust (dCurMel d')), e2, ne + length bad)
              else (nf, nm, errs, ne)
          d'' = d' { dFull = False }
      in if dDone d'
           then Run d' nf' nm' ne' errs' (if isNothing diff' && not (null cl') then Just (dCycle d + 1) else diff')
           else go g' d'' q' mem' prm' cl' nf' nm' errs' ne' diff'

opRowRdOf :: RamOps -> RowAddr
opRowRdOf (RamOps a _ _ _) = a
opRowWrOf :: RamOps -> Maybe (RowAddr, Row)
opRowWrOf (RamOps _ w _ _) = w
opPrmRdOf :: RamOps -> Unsigned 5
opPrmRdOf (RamOps _ _ a _) = a
opPrmWrOf :: RamOps -> Maybe (Unsigned 5, Signed 32)
opPrmWrOf (RamOps _ _ _ w) = w

-- | The Clash circuit closed loop with the driver, produced lazily: the
-- driver's state each cycle (its inputs) and the circuit's outputs, until
-- the driver is done. A consumer that walks it keeps nothing behind it.
clashTrace :: D -> [(D, GmOut)]
clashTrace dInit = takeDone (zip (sample drv) (sample outs))
  where
    drv = driver dInit outs
    outs = geoMatrix systemClockGen systemResetGen enableGen (inputsOf <$> drv)
    driver d ~(o :- os) = d :- (let d' = (cycleStep d o) { dFull = False } in d' `seq` driver d' os)
    sample (x :- xs) = x : sample xs
    -- the next driver state is the next element's
    takeDone (x : rest) = x : (case rest of
                                 ((dn, _) : _) | dDone dn -> []
                                 _ -> takeDone rest)
    takeDone [] = []

------------------------------------------------------------------------------
-- The existing engine, same entries back to back

-- | The existing engine's driver. Its events and its architectural @GXSTAT@
-- bits after every command are compared with the model's as they happen
-- (the compact engine's are compared with the same model), so the two
-- engines are compared without keeping either's trace.
data BD = BD { bItems :: [Item], bModel :: !GeoState, bGather :: [Word32], bCycle :: !Int
             , bStart :: !(Maybe Int), bPending :: !(Maybe (Int, String)), bTimes :: !(M.Map String Timing)
             , bEntry :: !(Maybe HwEntry), bAck :: !Bool, bVbl :: !Bool, bDone :: !Bool, bIdle :: !Int
             , bZero :: !Word32, bExpect :: ![HwGeoEvent], bEvents :: !Int, bStat :: !Int
             , bNErr :: !Int, bErrs :: ![String] }

berr :: String -> BD -> BD
berr m b = let !c = bCycle b; es = bErrs b
           in b { bErrs = if length es < 12 then es ++ ["existing engine, cycle " ++ show c ++ ": " ++ m] else es
                , bNErr = bNErr b + 1 }

baseStep :: BD -> Base.GeoHwOut -> BD
baseStep b o = finish afterEntry
  where
    ready = Base.goCmdReady o
    quietNow = ready && isNothing (Base.goEvent o)
    -- event ready is always high: an event shown is transferred
    afterEv = case Base.goEvent o of
      Just ev -> case bExpect b of
        (e : es) | e == ev -> b { bExpect = es, bEvents = bEvents b + 1 }
        es -> berr ("event " ++ show ev ++ ", model " ++ show (take 1 es)) b { bExpect = drop 1 es }
      Nothing -> b
    afterTime = case bPending afterEv of
      Just (t0, cls) | ready ->
        let n = bCycle afterEv - t0
            got = fromIntegral (Base.statusBits (Base.goStatus o)) .&. archMask
            want = statusWord (geoStatus (bModel afterEv)) .&. archMask
            bA = afterEv { bPending = Nothing, bTimes = M.insertWith mergeT cls (Timing 1 n n n) (bTimes afterEv)
                         , bStat = bStat afterEv + 1 }
        in if got == want then bA else berr ("GXSTAT after " ++ cls ++ ": " ++ hexs got ++ ", model " ++ hexs want) bA
      _ -> afterEv
    afterAck = if bAck afterTime then afterTime { bModel = fst (step (bModel afterTime) AckStackError) } else afterTime
    afterEntry = case bEntry afterAck of
      Just e | ready ->
        let bA = afterAck { bItems = drop 1 (bItems afterAck), bStart = Just (fromMaybe (bCycle afterAck) (bStart afterAck)) }
            (mgi, g') = gather e (bGather bA)
        in case mgi of
             Just gi@(GeoCmd op _) ->
               let (s', evs) = step (bModel bA) gi
               in bA { bGather = g', bModel = s', bStart = Nothing, bExpect = bExpect bA ++ map toHwEvent evs
                     , bPending = Just (fromMaybe (bCycle bA) (bStart bA), cmdClass (bModel bA) op) }
             _ -> bA { bGather = g' }
      _ -> afterAck
    finish bb =
      let idleNow = quietNow && isNothing (bPending bb)
          (entry, ack, zero, rest) = case bItems bb of
            (IEntry e : _) -> (Just e, False, Nothing, bItems bb)
            (IAck : r) | idleNow && not (bAck bb) -> (Nothing, True, Nothing, r)
            (IZero z : r) | idleNow && not (bAck bb) -> (Nothing, False, Just z, r)
            is -> (Nothing, False, Nothing, is)
          model' = maybe (bModel bb) (\z -> fst (step (bModel bb) (SetZeroDotW z))) zero
          hung = bIdle bb > 100000
          done = null rest && not ack && isNothing zero && isNothing (bPending bb) && quietNow
      in (if hung then berr "hang: the engine never went idle" else id)
         . (if done && not (null (bExpect bb)) then berr ("model events never transferred: " ++ show (take 1 (bExpect bb))) else id)
         $ bb { bItems = rest, bEntry = entry, bAck = ack, bCycle = bCycle bb + 1, bModel = model'
            , bZero = gZeroDotW model'
            , bVbl = Base.goSwapWait o && isNothing (Base.goEvent o)
            , bIdle = if ready then 0 else bIdle bb + 1
            , bDone = done || hung }

runBase :: [Item] -> BD
runBase items = finalOf drv
  where
    drv = driver (BD items initGeoState [] 0 Nothing Nothing M.empty Nothing False False False 0 0xFFFFFF [] 0 0 0 []) outs
    inp = (\b -> Base.GeoHwIn (bEntry b) True False (bVbl b) (bAck b) (bZero b)) <$> drv
    (outs, _) = Base.geometryHw systemClockGen systemResetGen enableGen inp (pure 0x04000620)
    driver b ~(o :- os) = b :- (let b' = baseStep b o in b' `seq` driver b' os)
    finalOf (b :- bs) = if bDone b then b else finalOf bs

------------------------------------------------------------------------------
-- Trace extraction (v12 NSD2 raw GX writes through the authoritative chip)

alignOf :: Size -> Word32 -> Word32
alignOf sz a = case sz of
  S16 -> a .&. complement 0x1
  S32 -> a .&. complement 0x3
  S8 -> a

sizeOf :: Word8 -> Size
sizeOf w = case w of
  1 -> S8
  2 -> S16
  _ -> S32

-- | One iteration of @GPU3D::Run@ (Chip.chipRunOne), recording the
-- geometry input it makes.
runOneCap :: Chip -> Maybe (Chip, Maybe GeoIn)
runOneCap ch
  | not (gfGeomEn (chFront ch)) = Nothing
  | ppFlushReq (chPoly ch) = Nothing
  | otherwise = do
      (e, gf', _) <- popEntry (chFront ch)
      let (cmd, ps) = gatherEntry e (chParams ch)
          ch1 = ch { chFront = gf', chParams = ps }
      pure (maybe ch1 (`execGeo` ch1) cmd, cmd)

settleCap :: Chip -> (Chip, [GeoIn])
settleCap = go []
  where
    go acc ch = case runOneCap ch of
      Nothing -> (ch, reverse acc)
      Just (ch', m) -> go (maybe acc (: acc) m) ch'

-- | A bus write with the geometry inputs it makes (Chip.writeRegister).
writeCap :: Size -> Word32 -> Word32 -> Chip -> (Chip, [GeoIn])
writeCap sz a0 v ch =
  let a = alignOf sz a0
      gf = chFront ch
      act = writeAction (gfGeomEn gf) (gfRendEn gf) sz a (truncateWrite sz v)
      (_, fx) = mmioWrite sz a v gf
      ins = [AckStackError | wfAck fx] ++ [SetZeroDotW z | WaZeroDot z <- [act]]
  in (chipWrite sz a0 v ch, ins)

extract :: FilePath -> FilePath -> IO ()
extract trace outPath = do
  chRef <- newIORef initChip
  rawRef <- newIORef False
  insRef <- newIORef ([] :: [GeoIn])
  writes <- newIORef (0 :: Int)
  let emit is = modifyIORef' insRef (reverse is ++)
      settle = do
        ch <- readIORef chRef
        let (ch', is) = settleCap ch
        writeIORef chRef ch'
        emit is
      drain = do
        ch <- readIORef chRef
        when (chipStalled ch) $ do
          settle
          ch' <- readIORef chRef
          when (chipStalled ch') (fail "GX FIFO stays stalled with nothing to run")
      write sz a v = do
        drain
        ch <- readIORef chRef
        let (ch', is) = writeCap sz a v ch
        writeIORef chRef ch'
        emit is
        modifyIORef' writes (+ 1)
        settle
      onGeometry _ ev _ = do
        raw <- readIORef rawRef
        case ev of
          GeometryGxWrite _ addr val width -> writeIORef rawRef True >> write (sizeOf width) addr val
          GeometryCommand _ cmd param | not raw -> write S32 (0x04000400 + ((fromIntegral cmd .&. 0x7F) `shiftL` 2)) param
          GeometryRegister _ addr val width | not raw -> write (sizeOf width) addr val
          GeometryPower _ geom rend _ -> modifyIORef' chRef (chipPower geom rend)
          GeometryRenderStart _ _ _ geom rend _ _ _ _ -> modifyIORef' chRef (chipPower geom rend)
          GeometryVBlank _ _ -> settle >> modifyIORef' chRef chipVBlank
          _ -> pure ()
  replayTraceGeometry trace onGeometry (const (pure ())) (const (pure [])) (const (pure ()))
  settle
  ins <- reverse <$> readIORef insRef
  nw <- readIORef writes
  let enc i = case i of
        GeoCmd op ps -> [0, fromIntegral op, fromIntegral (length ps)] ++ ps
        SetZeroDotW z -> [1, 0, 1, z]
        AckStackError -> [2, 0, 0]
  BL.writeFile outPath (BB.toLazyByteString (foldMap BB.word32LE (concatMap enc ins ++ [0xFFFFFFFF])))
  let cmds = [op | GeoCmd op _ <- ins]
      count p = length [() | op <- cmds, p op]
  putStrLn ("geomatrix-check extract: " ++ show nw ++ " GX bus writes -> " ++ show (length ins) ++ " geometry inputs ("
            ++ show (length cmds) ++ " commands: " ++ show (count (\op -> op >= 0x23 && op <= 0x28)) ++ " vertices, "
            ++ show (count (== 0x21)) ++ " NORMAL, " ++ show (count (\op -> op >= 0x30 && op <= 0x34)) ++ " lighting setup, "
            ++ show (count (\op -> op >= 0x70 && op <= 0x72)) ++ " tests, " ++ show (count (== 0x50)) ++ " swaps; "
            ++ show (length [() | AckStackError <- ins]) ++ " acknowledges)")

------------------------------------------------------------------------------
-- Cosim trace

-- | One stream's cycle trace for tests/geomtx_cosim.cpp, written line by
-- line as the circuit runs (nothing is kept); returns the line count. A
-- line: input flags (reset, command valid, event ready, stall, acknowledge,
-- read valid, VBlank), command, parameter, @ZeroDotWLimit@, read address,
-- expected flags (ready, event valid, swap wait, read ready, read data
-- valid), status, read data, the event (83 hex digits), cycle.
dumpStream :: Handle -> D -> IO Int
dumpStream h dInit = go 0 (clashTrace dInit)
  where
    go !n [] = pure n
    go !n ((d, o) : rest) = hPutStrLn h (line n d o) >> go (n + 1) rest
    flag c n = if c then (1 `shiftL` n) else 0 :: Int
    line cyc d o = unwords
      [ hx 2 (flag (cyc == 0) 0 .|. flag (isJust (dEntry d)) 1 .|. flag (dEvReady d) 2 .|. flag (dStall d) 3
              .|. flag (dAck d) 4 .|. flag (isJust (dRead d)) 5 .|. flag (dVbl d) 6)
      , hx 2 (maybe 0 heCmd (dEntry d)), hx 8 (maybe 0 heParam (dEntry d)), hx 6 (dZero d)
      , hx 8 (fromMaybe 0 (dRead d))
      , hx 2 (flag (goReady o) 0 .|. flag (isJust (goEvent o)) 1 .|. flag (goSwapWait o) 2
              .|. flag (goRdReady o) 3 .|. flag (isJust (goRdData o)) 4)
      , hx 8 (statusWord (goStatus o))
      , hx 8 (maybe 0 (\v -> fromIntegral (pack v)) (goRdData o) :: Word32)
      , hx 83 (toInteger (gmEventBits (goEvent o)))
      , show cyc ]

hx :: (Integral a) => Int -> a -> String
hx n v = let s = showHex (toInteger v) "" in replicate (n - length s) '0' ++ s

------------------------------------------------------------------------------
-- The divider

-- | 'Nds.Gpu3D.GeoDiv' against 'Nds.Gpu3D.GeometryHw''s divider, which that
-- module does not export: the definitions of the state, 'divStart',
-- 'divDone' and 'divStep' must be the same text (whitespace aside); then
-- the reference arithmetic on random and edge operands: 64 / 32-bit
-- quotients, every @LIGHT_VECTOR@ denominator (0 included), and box-test
-- interpolations through the whole operand path ('clipQ', the four partial
-- products, 'segDiv', 'segResult') against
-- 'Nds.Gpu3D.Polygon.Clip.interpolate32' on both planes, both signs, and the
-- fork's wide denominator.
divCheck :: FilePath -> Int -> IO Int
divCheck srcDir n = do
  base <- readFile (srcDir ++ "/Nds/Gpu3D/GeometryHw.hs")
  own <- readFile (srcDir ++ "/Nds/Gpu3D/GeoDiv.hs")
  let defn start s = case dropWhile (not . (start `isPrefixOf`)) (lines s) of
        [] -> Nothing
        (l : ls) -> Just (words (unwords (l : takeWhile (\x -> not (all isSpace x) && not ("--" `isPrefixOf` x)) ls)))
      srcChecks = [ (nm, isJust (defn nm base) && defn nm base == defn nm own)
                  | nm <- ["data DivSt = DivSt", "divStart ::", "divDone ::", "divStep ::"] ]
      run :: DivSt -> (Int, DivSt)
      run = go 0
        where go !k dv = if dvBusy dv then go (k + 1) (divStep dv) else (k, dv)
      -- quotients
      rnd = take n (iterateRng (Rng 0x5EED))
      iterateRng r = let (x, r') = next r in x : iterateRng r'
      pairs = [ (a, fromIntegral b :: Word32) | (a, b) <- zip rnd (drop n rnd ++ rnd) ]
      edges = [ (a, b) | a <- [0, 1, 0xFFFFFFFF, 0x100000000, maxBound, maxBound - 1, 1 `shiftL` 63, 0x123456789ABCDEF0]
                       , b <- [1, 2, 3, 0xFFFF, 0x10000, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFE, 0xFFFFFFFF] ]
      quoBad = [ (a, b, dvQuo dv, want)
               | (a, b0) <- edges ++ pairs ++ [ (a `shiftR` s, b0 `shiftR` t) | (a, b0) <- take (n `div` 4) pairs
                                               , (s, t) <- [(17, 0), (31, 3), (40, 20), (5, 28)] ]
               , let b = if b0 == 0 then 1 else b0
               , let (_, dv) = run (divStart (fromIntegral a) 32 (fromIntegral b) False)
               , let want = fromIntegral (a `quot` fromIntegral b) :: Unsigned 32
               , not (dvValid dv) || dvQuo dv /= want ]
      -- LIGHT_VECTOR reciprocals
      recips = [ (den, got, want)
               | den <- [minBound .. maxBound :: Signed 12]
               , let (_, dv) = run (divRecip den)
               , let got = divSigned dv
               , let di = fromIntegral den :: Int32
               , let want = if di == 0 then 0 else (1 `shiftL` 18) `quot` di
               , not (dvValid dv) || got /= fromIntegral want ]
      recipCyc = maximum [ fst (run (divRecip den)) | den <- [minBound .. maxBound :: Signed 12] ]
      -- box-test interpolations
      i32s = map (fromIntegral :: Word64 -> Int32) rnd
      small = map (`shiftR` 12) i32s
      extremes = [minBound, minBound + 1, -1, 0, 1, maxBound - 1, maxBound]
      cands = [ (pos, vc, vw, oc, ow, a, b)
              | (k, vc0, vw0, oc0, ow0, a, b) <- zip7 [0 .. n - 1] (cycle (extremes ++ i32s)) (drop 3 (cycle (small ++ i32s)))
                                                     (drop 5 (cycle i32s)) (drop 7 (cycle (small ++ extremes ++ i32s)))
                                                     (drop 11 (cycle i32s)) (drop 13 (cycle (extremes ++ i32s)))
              , let pos = even k
              , let (vc, vw) = (vc0, vw0)
              , let (oc, ow) = (oc0, ow0)
              , outside pos vc vw, inside pos oc ow ]
      wides = [ (pos, vc, vw, oc, fromIntegral ow', a, b)
              | (k, vc, vw, ow0, a, b) <- zip6 [0 .. n - 1] (cycle (extremes ++ i32s)) (drop 3 (cycle (i32s ++ extremes)))
                                                (drop 5 (cycle i32s)) (drop 7 (cycle i32s)) (drop 9 (cycle (extremes ++ i32s)))
              , let pos = even k
              , outside pos vc vw
              , let ow' = ow0
              , let dIn = (if pos then toInteger vw - toInteger vc else toInteger vw + toInteger vc) + 2 ^ (32 :: Int)
              , let ocI = if pos then toInteger ow' - dIn else dIn - toInteger ow'
              , ocI >= toInteger (minBound :: Int32) && ocI <= toInteger (maxBound :: Int32)
              , let oc = fromInteger ocI
              , inside pos oc ow' ]
      interp (pos, vc, vw, oc, ow, a, b) =
        let q = clipQ pos (fromIntegral vc) (fromIntegral vw) (fromIntegral oc) (fromIntegral ow)
            as = segOpA q
            bs = segOpB (fromIntegral a) (fromIntegral b)
            ps = C.zipWith (\x y -> C.truncateB (x `C.mul` y)) as bs :: Vec 4 (Signed 44)
            (k, dv) = run (segDiv q (segProduct ps))
            got = segResult (fromIntegral a) (segQNeg q (fromIntegral a) (fromIntegral b)) (dvQuo dv)
            want = interpolate32 (clipFactors (if pos then 1 else -1) vc vw oc ow) a b
        in (cqWide q, k, dvValid dv && fromIntegral got == want, (pos, vc, vw, oc, ow, a, b, got, want))
      results = map interp (cands ++ wides)
      segBad = [ x | (_, _, ok, x) <- results, not ok ]
      nWide = length [ () | (True, _, _, _) <- results ]
      segCyc = maximum (0 : [ k | (_, k, _, _) <- results ])
      outside pos c w = if pos then c > w else c < negate w
      inside pos c w = if pos then c <= w else c >= negate w
  forM_ [ nm | (nm, False) <- srcChecks ] $ \nm -> putStrLn ("divider source differs from GeometryHw's: " ++ nm)
  forM_ (take 5 quoBad) $ \x -> putStrLn ("quotient wrong: " ++ show x)
  forM_ (take 5 recips) $ \x -> putStrLn ("LIGHT_VECTOR reciprocal wrong: " ++ show x)
  forM_ (take 5 segBad) $ \x -> putStrLn ("box-test interpolation wrong: " ++ show x)
  let bad = length [ () | (_, False) <- srcChecks ] + length quoBad + length recips + length segBad
  putStrLn ("geomatrix-check div: source of " ++ show (length srcChecks) ++ " definitions as GeometryHw's; "
            ++ show (length edges + length pairs + n) ++ " quotients, 4096 LIGHT_VECTOR denominators (max "
            ++ show recipCyc ++ " cycles), " ++ show (length results) ++ " box-test interpolations ("
            ++ show nWide ++ " wide denominators, max " ++ show segCyc ++ " divider cycles); " ++ show bad ++ " wrong")
  pure bad
  where
    zip6 (a : as) (b : bs) (c : cs) (d : ds) (e : es) (f : fs) = (a, b, c, d, e, f) : zip6 as bs cs ds es fs
    zip6 _ _ _ _ _ _ = []
    zip7 (a : as) (b : bs) (c : cs) (d : ds) (e : es) (f : fs) (g : gs) = (a, b, c, d, e, f, g) : zip7 as bs cs ds es fs gs
    zip7 _ _ _ _ _ _ _ = []

------------------------------------------------------------------------------
-- Main

-- | Counts, the first messages of each stream, and timings, folded strictly
-- over the streams as they finish.
data Tot = Tot { tN :: !(M.Map String Int), tMsgs :: !(M.Map Int [String])
               , tTimes :: !(M.Map String Timing), tBTimes :: !(M.Map String Timing) }

noTot :: Tot
noTot = Tot M.empty M.empty M.empty M.empty

addTot :: Tot -> Int -> Tot -> Tot
addTot a _ b = Tot (M.unionWith (+) (tN a) (tN b)) (M.union (tMsgs a) (tMsgs b))
                   (M.unionWith mergeT (tTimes a) (tTimes b)) (M.unionWith mergeT (tBTimes a) (tBTimes b))

-- | One stream's summary: its counts, and its messages (evaluated, so that
-- nothing of the run is kept).
totOf :: Int -> [(String, Int)] -> [String] -> M.Map String Timing -> M.Map String Timing -> Tot
totOf k counts msgs tm btm =
  let ms = foldl' (\acc m -> length m `seq` acc) () msgs `seq` msgs
  in Tot (M.fromList counts) (if null ms then M.empty else M.singleton k ms) tm btm

cnt :: Tot -> String -> Int
cnt t key = M.findWithDefault 0 key (tN t)

-- | Print each stream's messages and fail on a malformed file.
report :: Either String Tot -> IO Tot
report r = case r of
  Left e -> hPutStrLn stderr ("geomatrix-check: " ++ e) >> exitFailure
  Right t -> do
    forM_ (M.toList (tMsgs t)) $ \(k, ms) -> forM_ ms $ \m -> putStrLn ("stream " ++ show k ++ ": " ++ m)
    pure t

option :: String -> [String] -> Maybe String
option name args = case dropWhile (/= name) args of
  (_ : v : _) -> Just v
  _ -> Nothing

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["extract", trace, out] -> extract trace out
    ("div" : srcDir : rest) -> do
      bad <- divCheck srcDir (case rest of { (k : _) -> read k; _ -> 200000 })
      unless (bad == 0) exitFailure
    ("check" : path : rest) -> check path rest
    ("time" : path : rest) -> timing path rest
    ("dump" : path : sd : out : rest) -> dump path (read sd) out (case rest of { [k] -> read k; _ -> 2 })
    _ -> putStrLn "usage: geomatrix-check extract TRACE OUT | check FILE [SEED] [--mutate] [--limit N] | time FILE [--limit N] | dump FILE SEED OUT|- [STREAMS] | div SRCDIR [N]" >> exitFailure

-- | The cosim trace of the first @n@ streams, to a file or standard output
-- (- : the gate pipes it into the Verilator bench, so no trace file is
-- written), one stream at a time, ending with a line count the bench
-- checks.
dump :: FilePath -> Word64 -> FilePath -> Int -> IO ()
dump path sd out n = do
  streams <- fileStreams path Nothing
  h <- if out == "-" then pure stdout else openFile out WriteMode
  hSetBuffering h (BlockBuffering Nothing)
  let go !total k ss
        | k >= n = pure total
        | otherwise = case ss of
            [] -> pure total
            (Left e : _) -> hPutStrLn stderr ("geomatrix-check: " ++ e) >> exitFailure
            (Right s : rest) -> do
              lns <- dumpStream h (d0 False (itemsOf False (Rng (sd * 7919 + fromIntegral k)) (map rIn s)) []
                                      (sd * 1000003 + fromIntegral k))
              go (total + lns) (k + 1) rest
  total <- go (0 :: Int) (0 :: Int) streams
  hPutStrLn h ("# end " ++ show total)
  hClose h
  when (total == 0) exitFailure

check :: FilePath -> [String] -> IO ()
check path rest = do
  let seed = case rest of
        (s : _) | all (`elem` ['0' .. '9']) s -> read s
        _ -> 1 :: Word64
      mutate = "--mutate" `elem` rest
      limit = read <$> option "--limit" rest
      one k s =
        let !nIn = length s
            !nMel = if mutate then 0 else length [() | Rec _ (Just _) _ <- s]
            items = itemsOf mutate (Rng (seed * 7919 + fromIntegral k)) (map rIn s)
            mels = if mutate then [] else [(rMel r, rVert r) | r <- s]
            ru = runStream (d0 False items mels (seed * 1000003 + fromIntegral k))
            d = ruD ru
            nDiff = maybe 0 (const 1) (ruDiff ru)
        in totOf k
             [ ("streams", 1), ("in", nIn), ("mel", nMel), ("inputs", dInputs d), ("entries", dEntries d)
             , ("events", dEvents d), ("verts", dVerts d), ("melVerts", dMelVerts d), ("swaps", dSwaps d)
             , ("status", dStatus d), ("full", ruFull ru), ("melFull", ruMelFull ru), ("reads", dReads d)
             , ("melReads", dMelReads d), ("cycles", dCycle d), ("gaps", dGaps d), ("evWaits", dEvWaits d)
             , ("stall", dStallC d), ("swapC", dSwapC d), ("diffs", nDiff)
             , ("err", dNErr d + ruNFullErr ru + nDiff) ]
             (dErrs d ++ ruFullErr ru
              ++ [ "pure step and Clash circuit outputs differ at cycle " ++ show c | Just c <- [ruDiff ru] ])
             M.empty M.empty
  streams <- fileStreams path limit
  t <- report =<< foldStreams streams one addTot noTot
  let c = cnt t
      nf = c "err"
  putStrLn ("geomatrix-check: " ++ show (c "streams") ++ " streams, " ++ show (c "in") ++ " inputs ("
            ++ (if mutate then "melonDS not compared" else show (c "mel") ++ " with melonDS records")
            ++ "), " ++ show (c "inputs") ++ " inputs run (" ++ show (c "entries") ++ " entries), "
            ++ show (c "events") ++ " events (" ++ show (c "verts") ++ " vertices, " ++ show (c "melVerts")
            ++ " against melonDS, " ++ show (c "swaps") ++ " swaps), " ++ show (c "status") ++ " status checks, "
            ++ show (c "full") ++ " whole-state checks (" ++ show (c "melFull") ++ " against melonDS), "
            ++ show (c "reads") ++ " result reads (" ++ show (c "melReads") ++ " against melonDS), "
            ++ show (c "cycles") ++ " cycles (" ++ show (c "gaps") ++ " entry gaps, " ++ show (c "evWaits")
            ++ " event waits, " ++ show (c "stall") ++ " stall cycles, " ++ show (c "swapC") ++ " swap-wait cycles), pure/Clash outputs "
            ++ (if c "diffs" == 0 then "identical" else "DIFFERENT")
            ++ ", " ++ show nf ++ " mismatches" ++ (if mutate then " (interleaved gathering, model only)" else ""))
  when (nf /= 0 || c "inputs" == 0 || c "events" == 0) exitFailure

-- | The compact engine's final driver state for a closed-loop run.
finalD :: D -> D
finalD dInit = go (clashTrace dInit)
  where
    go [(d, o)] = cycleStep d o
    go (_ : rest) = go rest
    go [] = dInit

timing :: FilePath -> [String] -> IO ()
timing path rest = do
  let one k s =
        let items = itemsOf False (Rng 1) (map rIn s)
            d = finalD (d0 True items [] 1)
            b = runBase items
            -- both engines matched the model event by event and command by
            -- command; equal counts make the two sequences the same
            same = [ "the engines transferred " ++ show (dEvents d) ++ " and " ++ show (bEvents b) ++ " events"
                   | dEvents d /= bEvents b ]
                   ++ [ "the engines finished " ++ show (dPostStat d) ++ " and " ++ show (bStat b) ++ " commands"
                      | dPostStat d /= bStat b ]
        in totOf k
             [ ("streams", 1), ("inputs", dInputs d), ("events", dEvents d), ("postStat", dPostStat d)
             , ("cycles", dCycle d), ("bCycles", bCycle b), ("melCycles", dMelCyc d)
             , ("err", dNErr d + bNErr b + length same) ]
             (dErrs d ++ bErrs b ++ same) (dTimes d) (bTimes b)
  streams <- fileStreams path (read <$> option "--limit" rest)
  t <- report =<< foldStreams streams one addTot noTot
  let c = cnt t
      ct = tTimes t
      bt = tBTimes t
      mean (Timing n s _ _) = fromIntegral s / fromIntegral n :: Double
      f1 x = showFFloat (Just 1) x ""
      f2 x = showFFloat (Just 2) x ""
      budget mx mel k = if mx <= k * mel then "ok" else "MISS"
  putStrLn "class | n | compact min | compact mean | compact max | existing mean | existing max | melonDS | compact max/melonDS | 1x | 2x | 3x"
  forM_ (sortOn fst (M.toList ct)) $ \(cls, tm) -> do
    let b = M.lookup cls bt
        mel = melonCycles cls
    putStrLn (cls ++ " | " ++ show (tmCount tm) ++ " | " ++ show (tmMin tm) ++ " | " ++ f1 (mean tm) ++ " | " ++ show (tmMax tm) ++ " | "
              ++ maybe "-" (f1 . mean) b ++ " | " ++ maybe "-" (show . tmMax) b ++ " | " ++ maybe "-" show mel ++ " | "
              ++ maybe "-" (\m -> f2 (fromIntegral (tmMax tm) / fromIntegral m :: Double)) mel ++ " | "
              ++ concatMap (\k -> maybe "-" (\m -> budget (tmMax tm) m k) mel ++ (if k < 3 then " | " else "")) [1, 2, 3])
  putStrLn ("geomatrix-check time: " ++ show (c "streams") ++ " streams, " ++ show (c "inputs") ++ " inputs, "
            ++ show (c "events") ++ " events and " ++ show (c "postStat")
            ++ " post-command GXSTAT values the same in both engines; whole streams: compact "
            ++ show (c "cycles") ++ " cycles, existing " ++ show (c "bCycles") ++ " cycles, melonDS " ++ show (c "melCycles")
            ++ " (compact/melonDS " ++ f2 (fromIntegral (c "cycles") / fromIntegral (max 1 (c "melCycles")) :: Double) ++ "); "
            ++ show (c "err") ++ " mismatches")
  when (c "err" /= 0 || c "streams" == 0) exitFailure
