-- | Native differential checker for the geometry engine model.
--
-- Reads the output of @tools/gx3d_oracle/geometry_oracle.cpp@ (production
-- melonDS @GPU3D::ExecuteCommand@ on directed or seeded random streams),
-- replays every input through 'Nds.Gpu3D.Geometry.step' and compares, input
-- by input: the full geometry state (matrices, clip-matrix cache, stacks via
-- a hash of every slot, pointers, error and box-test flags, vertex/normal/
-- colour/texture-coordinate registers, lights, material, shininess table,
-- polygon state, viewport, 1-dot depth, test results), the production
-- @GXSTAT@ read against 'geoStatus', the @Read32@/@Read16@ result registers
-- against 'geoRead32'/'geoRead16' and the packed 'geoReadResult', and the
-- event stream: each vertex @SubmitVertex@ stored with its polygon state,
-- @BEGIN_VTXS@ against the polygon mode it set, @SWAP_BUFFERS@ against the
-- flush request and attributes, @END_VTXS@.
module Main (main) where

import Control.Monad (forM_, unless, when)
import Data.Array (elems)
import qualified Data.Array.Unboxed as U
import Data.Bits (shiftL, shiftR, xor, (.&.), (.|.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Unsafe as BU
import Data.Int (Int16, Int32)
import Data.List (foldl')
import Data.Word (Word32, Word64, Word8)
import Numeric (showHex)
import System.Environment (getArgs)
import System.Exit (exitFailure)

import Nds.Gpu3D.Geometry
import Nds.Gpu3D.Geometry.Lighting (Light (..), Material (..))
import Nds.Gpu3D.Geometry.Matrix (Mat, matElems)
import Nds.Gpu3D.Types

main :: IO ()
main = do
  args <- getArgs
  case args of
    [path] -> do
      bytes <- BL.readFile path
      let r = checkAll (wordsOf bytes)
      forM_ (reverse (aMsgs r)) putStrLn
      putStrLn ("geometry-check: " ++ show (aStreams r) ++ " streams, "
        ++ show (aRecords r) ++ " inputs (" ++ show (aCommands r) ++ " commands), "
        ++ show (aVerts r) ++ " vertices, box tests " ++ show (aBoxT r) ++ " hit / "
        ++ show (aBoxF r) ++ " miss, " ++ show (aErrSets r) ++ " stack-error sets, "
        ++ show (aFails r) ++ " failures")
      unless (aComplete r) (putStrLn "geometry-check: truncated oracle output")
      when (aFails r /= 0 || aRecords r == 0 || not (aComplete r)) exitFailure
    _ -> putStrLn "usage: geometry-check FILE" >> exitFailure

-- | Little-endian words of a lazy byte string, across chunk boundaries.
wordsOf :: BL.ByteString -> [Word32]
wordsOf = go BS.empty . BL.toChunks
  where
    go acc [] = strict acc
    go acc (c : cs) =
      let joined = acc <> c
          n = (BS.length joined `div` 4) * 4
      in strict (BS.take n joined) ++ go (BS.drop n joined) cs
    strict bs = [word bs (4 * i) | i <- [0 .. BS.length bs `div` 4 - 1]]
    word bs o = byte bs o .|. (byte bs (o + 1) `shiftL` 8)
                  .|. (byte bs (o + 2) `shiftL` 16) .|. (byte bs (o + 3) `shiftL` 24)
    byte bs o = fromIntegral (BU.unsafeIndex bs o) :: Word32

tagStream, tagRecord, tagStreamEnd, tagFileEnd :: Word32
tagStream = 0x5354524D
tagRecord = 0x52454331
tagStreamEnd = 0x454E4453
tagFileEnd = 0x454E4446

data Acc = Acc
  { aStreams  :: !Int
  , aRecords  :: !Int
  , aCommands :: !Int
  , aVerts    :: !Int
  , aBoxT     :: !Int
  , aBoxF     :: !Int
  , aErrSets  :: !Int
  , aFails    :: !Int
  , aComplete :: !Bool
  , aMsgs     :: [String]
  }

maxMsgs :: Int
maxMsgs = 12

failWith :: [String] -> Acc -> Acc
failWith ms a = a { aFails = aFails a + 1
                  , aMsgs = if length (aMsgs a) < maxMsgs then reverse ms ++ aMsgs a else aMsgs a }

checkAll :: [Word32] -> Acc
checkAll = top (Acc 0 0 0 0 0 0 0 0 False [])
  where
    top a ws = case ws of
      (t : sid : rest) | t == tagStream ->
        stream a { aStreams = aStreams a + 1 } sid 0 initGeoState rest
      [t, total] | t == tagFileEnd ->
        if fromIntegral total == aRecords a then a { aComplete = True }
        else failWith ["record count mismatch: oracle " ++ show total] a
      _ -> failWith ["malformed oracle output at stream level"] a
    stream a sid k s ws = case ws of
      (t : rest) | t == tagStreamEnd -> top a rest
      (t : kind : op : n : rest) | t == tagRecord ->
        let (params, rest1) = splitAt (fromIntegral n) rest
            (stw, rest2) = splitAt nStateWords rest1
        in case rest2 of
             (nv : rest3) ->
               let (vw, rest4) = splitAt (if nv == 1 then 19 else 0) rest3
               in case rest4 of
                    (pm : fr : fa : rest5) ->
                      let (a', s') = record a sid k s kind op params stw nv vw pm fr fa
                      in a' `seq` s' `seq` stream a' sid (k + 1) s' rest5
                    _ -> failWith ["truncated record"] a
             _ -> failWith ["truncated record"] a
      _ -> failWith ["malformed oracle output in stream " ++ show sid] a

-- | Check one input. Returns the updated counters and the model state.
record :: Acc -> Word32 -> Int -> GeoState -> Word32 -> Word32 -> [Word32] -> [Word32]
       -> Word32 -> [Word32] -> Word32 -> Word32 -> Word32 -> (Acc, GeoState)
record a sid k s kind op params stw nv vw pm fr fa =
  let inp = case kind of
        0 -> GeoCmd (fromIntegral op) params
        1 -> SetZeroDotW (head params)
        _ -> AckStackError
      (s', evs) = step s inp
      opc = fromIntegral op :: Word8
      isCmd = kind == 0
      where_ = "stream " ++ show sid ++ " input " ++ show k ++ " " ++ show inp
      -- state
      mws = modelWords s'
      stateDiffs = [ n ++ ": oracle=0x" ++ showHex o "" ++ " model=0x" ++ showHex m ""
                   | (n, o, m) <- zip3 stateNames stw mws, o /= m ]
      -- packed result words against the production reads
      r32, r16 :: Word32 -> Word32
      r32 a' = stw !! (resultBase + fromIntegral ((a' - 0x04000620) `div` 4))
      r16 a' = stw !! (read16Base + fromIntegral ((a' - 0x04000620) `div` 2))
      packedWant a'
        | a' == 0x04000630 = r16 0x04000630 .|. (r16 0x04000632 `shiftL` 16)
        | a' == 0x04000634 = r16 0x04000634 .|. (r16 0x04000636 `shiftL` 16)
        | otherwise = r32 a'
      packedDiffs = [ "geoReadResult 0x" ++ showHex (a' + d) "" ++ ": want=0x" ++ showHex w ""
                      ++ " model=0x" ++ showHex g ""
                    | a' <- [0x04000620, 0x04000624 .. 0x040006A0], d <- [0 .. 3]
                    , let w = packedWant a'; g = geoReadResult s' (a' + d), w /= g ]
      -- events
      verts = [(cv, ps) | GeVertex cv ps <- evs]
      vertDiffs = case (nv, verts) of
        (0, []) -> []
        (1, [(cv, ps)]) ->
          [ n ++ ": oracle=0x" ++ showHex o "" ++ " model=0x" ++ showHex m ""
          | (n, o, m) <- zip3 vertexNames vw (vertexWords cv ps), o /= m ]
        _ -> ["vertex count: oracle " ++ show nv ++ " model " ++ show (length verts)]
      begins = [p | GeBegin p <- evs]
      swaps = [p | GeSwap p <- evs]
      ends = length [() | GeEnd <- evs]
      eventDiffs = concat
        [ [ "more than one event: " ++ show evs | length evs > 1 ]
        , [ "BEGIN_VTXS event " ++ show begins | begins /= [head params | isCmd && opc == 0x40] ]
        , [ "BEGIN_VTXS mode: oracle " ++ show pm | [p] <- [begins], p .&. 3 /= pm ]
        , [ "SWAP_BUFFERS event " ++ show swaps ++ " oracle flush " ++ show fr
          | (fr == 1) /= not (null swaps) || swaps /= [head params | isCmd && opc == 0x50] ]
        , [ "SWAP_BUFFERS attributes: oracle " ++ show fa | [p] <- [swaps], p .&. 3 /= fa ]
        , [ "END_VTXS event" | (ends == 1) /= (isCmd && opc == 0x41) || ends > 1 ]
        , [ "parameter count " ++ show (length params) ++ " for command 0x" ++ showHex op ""
          | isCmd && length params /= max 1 (cmdNumParams opc) ]
        ]
      diffs = stateDiffs ++ packedDiffs ++ vertDiffs ++ eventDiffs
      boxed = isCmd && opc == 0x70
      a1 = a { aRecords = aRecords a + 1
             , aCommands = aCommands a + (if isCmd then 1 else 0)
             , aVerts = aVerts a + length verts
             , aBoxT = aBoxT a + (if boxed && gBoxResult s' then 1 else 0)
             , aBoxF = aBoxF a + (if boxed && not (gBoxResult s') then 1 else 0)
             , aErrSets = aErrSets a + (if gStackError s' && not (gStackError s) then 1 else 0) }
      a2 = if null diffs then a1
           else failWith (("FAIL " ++ where_) : map ("  " ++) (take 8 diffs)) a1
  in (a2, s')

-- | The state words in @dumpState@ order.
modelWords :: GeoState -> [Word32]
modelWords s = concat
  [ [w8 (gMtxMode s)]
  , mw (gProj s), mw (gPos s), mw (gVec s), mw (gTex s), mw (gClip s)
  , [b (gClipDirty s), w8 (gProjSP s), w8 (gPosSP s), w8 (gTexSP s)]
  , [fromIntegral h, fromIntegral (h `shiftR` 32)]
  , [(if gStackError s then 0x8000 else 0) .|. (if gBoxResult s then 2 else 0)]
  , [statusWord (geoStatus s)]
  , v3 (gCurVertex s), c3 (gVertexColor s), v2 (gTexCoords s), v2 (gRawTexCoords s)
  , v3 (gNormal s)
  , concat [v3 (lDir l) ++ [i32 (lSpecRecip l)] ++ c3 (lColor l) | l <- elems (gLights s)]
  , c3 (mDiffuse m), c3 (mAmbient m), c3 (mSpecular m), c3 (mEmission m)
  , [b (mUseShininess m)]
  , [ foldr (\j acc -> (acc `shiftL` 8) .|. fromIntegral (mShininess m U.! (4 * i + j))) 0 [0 .. 3]
    | i <- [0 .. 31] ]
  , [gPolyAttr s, gCurPolyAttr s, gTexParam s, gTexPalette s]
  , vp (gViewport s), [gZeroDotW s]
  , let (r0, r1, r2, r3) = gPosTest s in map i32 [r0, r1, r2, r3]
  , v3 (gVecTest s)
  , [geoRead32 s a | a <- [0x04000620, 0x04000624 .. 0x040006A0]]
  , [geoRead32 s a | a <- unalignedReads]
  , [geoRead16 s a | a <- [0x04000620, 0x04000622 .. 0x040006A2]]
  ]
  where
    m = gMaterial s
    h = stackHash s

unalignedReads :: [Word32]
unalignedReads = [0x04000621, 0x04000642, 0x04000643, 0x0400067D, 0x04000682]

stateNames :: [String]
stateNames = concat
  [ ["mtxmode"], mn "proj", mn "pos", mn "vec", mn "tex", mn "clip"
  , ["clipdirty", "projsp", "possp", "texsp", "stackhash.lo", "stackhash.hi", "gxstat&8002"
    , "read32(0x600)&BF02 vs geoStatus"]
  , ix "curvertex" 3, ix "vertexcolor" 3, ix "texcoords" 2, ix "rawtexcoords" 2, ix "normal" 3
  , concat [ ix ("light" ++ show l ++ ".dir") 3 ++ ["light" ++ show l ++ ".specrecip"]
             ++ ix ("light" ++ show l ++ ".color") 3 | l <- [0 .. 3 :: Int] ]
  , ix "matdiffuse" 3, ix "matambient" 3, ix "matspecular" 3, ix "matemission" 3
  , ["useshininess"], ix "shininess.word" 32
  , ["polyattr", "curpolyattr", "texparam", "texpalette"], ix "viewport" 6, ["zerodotw"]
  , ix "postest" 4, ix "vectest" 3
  , ["read32(0x" ++ showHex a ")" | a <- [0x04000620 :: Word32, 0x04000624 .. 0x040006A0]]
  , ["read32(0x" ++ showHex a ")" | a <- unalignedReads]
  , ["read16(0x" ++ showHex a ")" | a <- [0x04000620 :: Word32, 0x04000622 .. 0x040006A2]]
  ]
  where
    mn p = ix p 16
    ix p n = [p ++ "[" ++ show i ++ "]" | i <- [0 .. n - 1 :: Int]]

nStateWords, resultBase, read16Base :: Int
nStateWords = length stateNames
resultBase = nStateWords - 66 - 5 - 33
read16Base = nStateWords - 66

vertexWords :: ClipVertex -> PolyState -> [Word32]
vertexWords cv ps =
  map i32 [cvX cv, cvY cv, cvZ cv, cvW cv, cvR cv, cvG cv, cvB cv]
  ++ map (i32 . (fromIntegral :: Int16 -> Int32)) [cvS cv, cvT cv]
  ++ [psAttr ps, psTexParam ps, psTexPalette ps] ++ vp (psViewport ps) ++ [psZeroDotW ps]

vertexNames :: [String]
vertexNames = ["x", "y", "z", "w", "r", "g", "b", "s", "t", "attr", "texparam", "texpalette"]
  ++ ["viewport[" ++ show i ++ "]" | i <- [0 .. 5 :: Int]] ++ ["zerodotw"]

statusWord :: GeoStatus -> Word32
statusWord g =
  bit0 (gsTestBusy g) 0 .|. bit0 (gsBoxResult g) 1 .|. (fromIntegral (gsPosStack g) `shiftL` 8)
    .|. bit0 (gsProjStack g) 13 .|. bit0 (gsStackBusy g) 14 .|. bit0 (gsStackError g) 15
    .|. bit0 (gsBusy g) 27
  where
    bit0 c n = if c then 1 `shiftL` n else 0

-- | FNV-1a over the stack words, in the oracle's order.
stackHash :: GeoState -> Word64
stackHash s = foldl' mixMat 0xCBF29CE484222325
  ([gProjStack s, gTexStack s] ++ elems (gPosStack s) ++ elems (gVecStack s))
  where
    mixMat h m = foldl' (\h' w -> (h' `xor` fromIntegral (fromIntegral w :: Word32)) * 0x100000001B3)
                   h (matElems m)

mw :: Mat -> [Word32]
mw = map fromIntegral . matElems

w8 :: Word8 -> Word32
w8 = fromIntegral

b :: Bool -> Word32
b x = if x then 1 else 0

i32 :: Int32 -> Word32
i32 = fromIntegral

v3 :: (Int16, Int16, Int16) -> [Word32]
v3 (x, y, z) = map (i32 . fromIntegral) [x, y, z]

v2 :: (Int16, Int16) -> [Word32]
v2 (x, y) = map (i32 . fromIntegral) [x, y]

c3 :: (Word8, Word8, Word8) -> [Word32]
c3 (x, y, z) = map w8 [x, y, z]

vp :: (Word32, Word32, Word32, Word32, Word32, Word32) -> [Word32]
vp (a0, a1, a2, a3, a4, a5) = [a0, a1, a2, a3, a4, a5]
