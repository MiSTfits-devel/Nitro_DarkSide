{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The external polygon and vertex RAM: the record layout the polygon
-- pipeline ("Nds.Gpu3D.PolygonHw") writes and the rasteriser reads.
--
-- The structure is melonDS's: polygon records hold absolute indices into a
-- two-bank vertex RAM (@VertexRAM[2*6144]@), so a strip continued across a
-- swap shares vertices with the other bank, and the renderer reads vertex
-- values through the indices when it runs (melonDS resolves the render list
-- at render start, scanline 215, reading polygon and vertex RAM live). The
-- sorted render list is produced at the VBlank swap.
--
-- Everything lives in one window of the 64-bit memory port, at byte offsets
-- from a window base @b@ that every address function takes:
--
-- @
--   b + 0x000000  polygon records   4096 x 128 B  (record g = bank*2048 + i)
--   b + 0x080000  vertex RAM       12288 x 16 B   (index v = bank*6144 + j)
--   b + 0x0B0000  render list      2 banks x 2048 x 8 B (sorted order)
--   b + 0x0B8000  Y-range array    2 banks x 2048 x 2 B (sorted order, 4 per word)
--   b + 0x0BA000  sort scratch     2048 x 8 B (polygon pipeline only)
--   size 0x0BE000
-- @
--
-- Polygon record @g@ (submission order within its bank) at @b + g*128@:
--
-- @
--   H0      Attr[31:0] TexParam[63:32]
--   H1      TexPalette[31:0] NumVertices[35:32] WBuffer[36] FacingView[37]
--           ShadowMask[38] Shadow[39] Degenerate[40] Translucent[41] Type[42]
--           VTop[46:43] VBottom[50:47]
--   H2      YTop[7:0] YBottom[15:8] XTop[24:16] XBottom[33:25] SortKey[50:34]
--   slot k  (0 <= k < NumVertices) at byte 24 + 8k:
--           VertexIndex[13:0] FinalW[31:16] FinalZ[55:32]
-- @
--
-- Vertex @v@ at @b + 0x080000 + v*16@ (the renderer-visible @Vertex@ fields):
--
-- @
--   V0  FinalPosition X[8:0] Y[23:16]  TexCoords S[47:32] T[63:48]
--   V1  R'[19:0] G'[39:20] B'[59:40]
-- @
--
-- where @c' = Color >> 12@ (arithmetic, 20-bit signed) and
-- @FinalColor = c' == 0 ? 0 : (c' << 4) + 0xF@ ('finalColourOf'), exact for
-- any clip factor.
--
-- Render list entry at sorted position @p@, @b + 0x0B0000 + bank*0x4000 +
-- p*8@:
--
-- @
--   PolyIndex g[11:0] YTop[19:12] YBottom[27:20] Translucent[28] Degenerate[29]
-- @
--
-- While a bank is being built its render list area holds the same words in
-- submission order (the sort's input); the VBlank sort rewrites it in
-- sorted order.
--
-- Y-range array: 16 bits per sorted position, @YTop | YBottom << 8@, lane
-- @p mod 4@ of the word at @b + 0x0B8000 + bank*0x1000 + (p div 4)*8@. A
-- degenerate polygon (which the renderer skips) is the sentinel 0xFFFF; a
-- non-degenerate one always has YTop and YBottom <= 192.
module Nds.Gpu3D.PolyRam
  ( -- * Window
    polyRamSize
  , FrameDesc (..)
    -- * Addresses
  , polyRecordAddr
  , polyHeaderAddr
  , polySlotAddr
  , vertexAddr
  , renderListAddr
  , yRangeAddr
  , yRangeLane
  , scratchAddr
    -- * Records
  , PolyHeader (..)
  , PolySlot (..)
  , VertexRec (..)
  , RenderEntry (..)
  , encodeHeader
  , decodeHeader
  , encodeSlot
  , decodeSlot
  , encodeVertexRec
  , decodeVertexRec
  , finalColourOf
  , encodeRenderEntry
  , decodeRenderEntry
  , yRangeOf
  , decodeYRange
  , yRangeWrite
    -- * Model conversion
  , headerFromGx
  , vertexRecFromGx
  , gxFromRecords
  , encodeFrame
  , decodeFrame
  , decodeYRanges
  ) where

import Prelude

import Data.Bits (shiftL, shiftR, testBit, (.&.), (.|.))
import GHC.Generics (Generic)

import Clash.Prelude
  ( Bit, BitVector, Index, KnownNat, NFDataX, Signed, Unsigned, Vec (..)
  , pack, resize, toList, unpack )

import Nds.Gpu3D.Mem (MemAddr)
import Nds.Gpu3D.Types (GxPolygon (..), GxVertex (..))

-- | Bytes the window spans.
polyRamSize :: MemAddr
polyRamSize = 0x0BE000

-- | What the polygon pipeline hands the renderer at a swap: which bank's
-- render list to read, and how many polygons it holds.
data FrameDesc = FrameDesc
  { fdBank  :: !Bit
  , fdCount :: !(Unsigned 12)  -- ^ 0 .. 2048
  } deriving (Eq, Generic, Show, NFDataX)

------------------------------------------------------------------------------
-- Addresses

-- | First byte of polygon record @g@ (@bank*2048 + i@).
polyRecordAddr :: MemAddr -> Unsigned 12 -> MemAddr
polyRecordAddr b g = b + (resize g `shiftL` 7)

-- | Header word @w@ (H0..H2) of polygon record @g@.
polyHeaderAddr :: MemAddr -> Unsigned 12 -> Index 3 -> MemAddr
polyHeaderAddr b g w = polyRecordAddr b g + (fromIntegral w `shiftL` 3)

-- | Vertex slot @k@ (0..9) of polygon record @g@.
polySlotAddr :: MemAddr -> Unsigned 12 -> Unsigned 4 -> MemAddr
polySlotAddr b g k = polyRecordAddr b g + 24 + (resize k `shiftL` 3)

-- | Word @w@ (V0, V1) of vertex @v@ (0..12287).
vertexAddr :: MemAddr -> Unsigned 14 -> Index 2 -> MemAddr
vertexAddr b v w = b + 0x080000 + (resize v `shiftL` 4) + (fromIntegral w `shiftL` 3)

-- | Render list word of sorted position @p@.
renderListAddr :: MemAddr -> Bit -> Unsigned 11 -> MemAddr
renderListAddr b bank p =
  b + 0x0B0000 + (if bank == 1 then 0x4000 else 0) + (resize p `shiftL` 3)

-- | Y-range word holding sorted position @p@ (lane 'yRangeLane').
yRangeAddr :: MemAddr -> Bit -> Unsigned 11 -> MemAddr
yRangeAddr b bank p =
  b + 0x0B8000 + (if bank == 1 then 0x1000 else 0) + (resize (p `shiftR` 2) `shiftL` 3)

yRangeLane :: Unsigned 11 -> Index 4
yRangeLane p = fromIntegral (p .&. 3)

-- | Sort scratch word @p@ (owned by the polygon pipeline).
scratchAddr :: MemAddr -> Unsigned 11 -> MemAddr
scratchAddr b p = b + 0x0BA000 + (resize p `shiftL` 3)

------------------------------------------------------------------------------
-- Records

-- | The renderer-visible per-polygon fields, at their stored widths.
data PolyHeader = PolyHeader
  { phAttr        :: !(BitVector 32)
  , phTexParam    :: !(BitVector 32)
  , phTexPalette  :: !(BitVector 32)
  , phNumVerts    :: !(Unsigned 4)
  , phWBuffer     :: !Bool
  , phFacingView  :: !Bool
  , phShadowMask  :: !Bool
  , phShadow      :: !Bool
  , phDegenerate  :: !Bool
  , phTranslucent :: !Bool
  , phType        :: !Bit       -- ^ 0 regular, 1 line
  , phVTop        :: !(Unsigned 4)
  , phVBottom     :: !(Unsigned 4)
  , phYTop        :: !(Unsigned 8)
  , phYBottom     :: !(Unsigned 8)
  , phXTop        :: !(Unsigned 9)
  , phXBottom     :: !(Unsigned 9)
  , phSortKey     :: !(BitVector 17)
  } deriving (Eq, Generic, Show, NFDataX)

-- | One vertex slot of a polygon record: the vertex RAM index and the
-- polygon's depth values for that vertex.
data PolySlot = PolySlot
  { psIndex  :: !(Unsigned 14)
  , psFinalW :: !(Unsigned 16)
  , psFinalZ :: !(Unsigned 24)
  } deriving (Eq, Generic, Show, NFDataX)

-- | One vertex RAM entry, decoded.
data VertexRec = VertexRec
  { vrX :: !(Unsigned 9)    -- ^ @FinalPosition[0]@
  , vrY :: !(Unsigned 8)    -- ^ @FinalPosition[1]@
  , vrR :: !(Signed 32)     -- ^ @FinalColor[0..2]@
  , vrG :: !(Signed 32)
  , vrB :: !(Signed 32)
  , vrS :: !(Signed 16)
  , vrT :: !(Signed 16)
  } deriving (Eq, Generic, Show, NFDataX)

-- | A render list word.
data RenderEntry = RenderEntry
  { rePoly        :: !(Unsigned 12)  -- ^ polygon record index (@bank*2048 + i@)
  , reYTop        :: !(Unsigned 8)
  , reYBottom     :: !(Unsigned 8)
  , reTranslucent :: !Bool
  , reDegenerate  :: !Bool
  } deriving (Eq, Generic, Show, NFDataX)

fld :: forall n. KnownNat n => Int -> BitVector 64 -> BitVector n
fld lo w = resize (w `shiftR` lo)

at :: forall n. KnownNat n => Int -> BitVector n -> BitVector 64
at lo x = resize x `shiftL` lo

flag :: Int -> Bool -> BitVector 64
flag i c = if c then 1 `shiftL` i else 0

encodeHeader :: PolyHeader -> Vec 3 (BitVector 64)
encodeHeader h = h0 :> h1 :> h2 :> Nil
  where
    h0 = at 0 (phAttr h) .|. at 32 (phTexParam h)
    h1 = at 0 (phTexPalette h) .|. at 32 (pack (phNumVerts h))
       .|. flag 36 (phWBuffer h) .|. flag 37 (phFacingView h)
       .|. flag 38 (phShadowMask h) .|. flag 39 (phShadow h)
       .|. flag 40 (phDegenerate h) .|. flag 41 (phTranslucent h)
       .|. at 42 (pack (phType h))
       .|. at 43 (pack (phVTop h)) .|. at 47 (pack (phVBottom h))
    h2 = at 0 (pack (phYTop h)) .|. at 8 (pack (phYBottom h))
       .|. at 16 (pack (phXTop h)) .|. at 25 (pack (phXBottom h))
       .|. at 34 (phSortKey h)

decodeHeader :: BitVector 64 -> BitVector 64 -> BitVector 64 -> PolyHeader
decodeHeader h0 h1 h2 = PolyHeader
  { phAttr = fld 0 h0
  , phTexParam = fld 32 h0
  , phTexPalette = fld 0 h1
  , phNumVerts = unpack (fld 32 h1)
  , phWBuffer = testBit h1 36
  , phFacingView = testBit h1 37
  , phShadowMask = testBit h1 38
  , phShadow = testBit h1 39
  , phDegenerate = testBit h1 40
  , phTranslucent = testBit h1 41
  , phType = unpack (fld 42 h1)
  , phVTop = unpack (fld 43 h1)
  , phVBottom = unpack (fld 47 h1)
  , phYTop = unpack (fld 0 h2)
  , phYBottom = unpack (fld 8 h2)
  , phXTop = unpack (fld 16 h2)
  , phXBottom = unpack (fld 25 h2)
  , phSortKey = fld 34 h2
  }

encodeSlot :: PolySlot -> BitVector 64
encodeSlot s = at 0 (pack (psIndex s)) .|. at 16 (pack (psFinalW s)) .|. at 32 (pack (psFinalZ s))

decodeSlot :: BitVector 64 -> PolySlot
decodeSlot w = PolySlot
  { psIndex = unpack (fld 0 w)
  , psFinalW = unpack (fld 16 w)
  , psFinalZ = unpack (fld 32 w)
  }

-- | @FinalColor@ from the stored @c' = Color >> 12@.
finalColourOf :: BitVector 20 -> Signed 32
finalColourOf c
  | c == 0 = 0
  | otherwise = (resize (unpack c :: Signed 20) `shiftL` 4) + 0xF

-- | The stored @c'@ of a @FinalColor@ (inverse of 'finalColourOf' on every
-- value @FinalColor@ can take).
colourCode :: Signed 32 -> BitVector 20
colourCode f
  | f == 0 = 0
  | otherwise = resize (pack (f `shiftR` 4))

-- | Vertex RAM words. The colours are given as @c' = Color >> 12@ (the
-- polygon pipeline stores them that way; 'vertexRecFromGx' converts from
-- @FinalColor@).
encodeVertexRec :: Unsigned 9 -> Unsigned 8 -> BitVector 20 -> BitVector 20 -> BitVector 20
                -> Signed 16 -> Signed 16 -> Vec 2 (BitVector 64)
encodeVertexRec x y r g b s t = v0 :> v1 :> Nil
  where
    v0 = at 0 (pack x) .|. at 16 (pack y) .|. at 32 (pack s) .|. at 48 (pack t)
    v1 = at 0 r .|. at 20 g .|. at 40 b

decodeVertexRec :: BitVector 64 -> BitVector 64 -> VertexRec
decodeVertexRec v0 v1 = VertexRec
  { vrX = unpack (fld 0 v0)
  , vrY = unpack (fld 16 v0)
  , vrS = unpack (fld 32 v0)
  , vrT = unpack (fld 48 v0)
  , vrR = finalColourOf (fld 0 v1)
  , vrG = finalColourOf (fld 20 v1)
  , vrB = finalColourOf (fld 40 v1)
  }

encodeRenderEntry :: RenderEntry -> BitVector 64
encodeRenderEntry e =
  at 0 (pack (rePoly e)) .|. at 12 (pack (reYTop e)) .|. at 20 (pack (reYBottom e))
  .|. flag 28 (reTranslucent e) .|. flag 29 (reDegenerate e)

decodeRenderEntry :: BitVector 64 -> RenderEntry
decodeRenderEntry w = RenderEntry
  { rePoly = unpack (fld 0 w)
  , reYTop = unpack (fld 12 w)
  , reYBottom = unpack (fld 20 w)
  , reTranslucent = testBit w 28
  , reDegenerate = testBit w 29
  }

-- | The 16-bit Y-range of a polygon (0xFFFF when degenerate).
yRangeOf :: Bool -> Unsigned 8 -> Unsigned 8 -> BitVector 16
yRangeOf degenerate ytop ybot
  | degenerate = 0xFFFF
  | otherwise = resize (pack ytop) .|. (resize (pack ybot) `shiftL` 8)

-- | @(YTop, YBottom, Degenerate)@ of a Y-range lane.
decodeYRange :: BitVector 16 -> (Unsigned 8, Unsigned 8, Bool)
decodeYRange r = (unpack (resize r), unpack (resize (r `shiftR` 8)), r == 0xFFFF)

-- | The byte-enabled write that stores one Y-range lane: word data (the lane
-- in place) and byte enables.
yRangeWrite :: Index 4 -> BitVector 16 -> (BitVector 64, BitVector 8)
yRangeWrite lane r = (resize r `shiftL` (16 * l), 3 `shiftL` (2 * l))
  where
    l = fromIntegral lane :: Int

------------------------------------------------------------------------------
-- Model conversion

-- | The stored header of a 'GxPolygon' (fields truncated to their stored
-- widths; every value the polygon pipeline produces fits).
headerFromGx :: GxPolygon -> PolyHeader
headerFromGx p = PolyHeader
  { phAttr = fromIntegral (gpAttr p)
  , phTexParam = fromIntegral (gpTexParam p)
  , phTexPalette = fromIntegral (gpTexPalette p)
  , phNumVerts = fromIntegral (length (gpVerts p))
  , phWBuffer = gpWBuffer p
  , phFacingView = gpFacingView p
  , phShadowMask = gpShadowMask p
  , phShadow = gpShadow p
  , phDegenerate = gpDegenerate p
  , phTranslucent = gpTranslucent p
  , phType = fromIntegral (gpType p)
  , phVTop = fromIntegral (gpVTop p)
  , phVBottom = fromIntegral (gpVBottom p)
  , phYTop = fromIntegral (gpYTop p)
  , phYBottom = fromIntegral (gpYBottom p)
  , phXTop = fromIntegral (gpXTop p)
  , phXBottom = fromIntegral (gpXBottom p)
  , phSortKey = fromIntegral (gpSortKey p)
  }

-- | Vertex RAM words of a 'GxVertex'.
vertexRecFromGx :: GxVertex -> Vec 2 (BitVector 64)
vertexRecFromGx v =
  encodeVertexRec (fromIntegral (gvX v)) (fromIntegral (gvY v))
    (code (gvR v)) (code (gvG v)) (code (gvB v)) (fromIntegral (gvS v)) (fromIntegral (gvT v))
  where
    code = colourCode . fromIntegral

gxFromRecords :: PolyHeader -> [(PolySlot, VertexRec)] -> GxPolygon
gxFromRecords h vs = GxPolygon
  { gpVerts = map (vert . snd) vs
  , gpFinalZ = map (fromIntegral . psFinalZ . fst) vs
  , gpFinalW = map (fromIntegral . psFinalW . fst) vs
  , gpWBuffer = phWBuffer h
  , gpAttr = fromIntegral (phAttr h)
  , gpTexParam = fromIntegral (phTexParam h)
  , gpTexPalette = fromIntegral (phTexPalette h)
  , gpDegenerate = phDegenerate h
  , gpFacingView = phFacingView h
  , gpTranslucent = phTranslucent h
  , gpShadowMask = phShadowMask h
  , gpShadow = phShadow h
  , gpType = fromIntegral (phType h)
  , gpVTop = fromIntegral (phVTop h)
  , gpVBottom = fromIntegral (phVBottom h)
  , gpYTop = fromIntegral (phYTop h)
  , gpYBottom = fromIntegral (phYBottom h)
  , gpXTop = fromIntegral (phXTop h)
  , gpXBottom = fromIntegral (phXBottom h)
  , gpSortKey = fromIntegral (phSortKey h)
  }
  where
    vert v = GxVertex
      { gvX = fromIntegral (vrX v), gvY = fromIntegral (vrY v)
      , gvR = fromIntegral (vrR v), gvG = fromIntegral (vrG v), gvB = fromIntegral (vrB v)
      , gvS = fromIntegral (vrS v), gvT = fromIntegral (vrT v)
      }

-- | A frame as memory writes, for seeding behavioural memories: polygon @k@
-- of the list in record @bank*2048 + k@, its vertices given fresh vertex RAM
-- indices from @bank*6144@ upwards (no sharing; wrapping into the other bank
-- after 6144 and failing past 12288), the render list in list order and the
-- Y-range words. With @FrameDesc bank (length polys)@ the renderer reads
-- back exactly @polys@.
encodeFrame :: MemAddr -> Bit -> [GxPolygon] -> [(MemAddr, BitVector 64)]
encodeFrame b bank polys
  | totalVerts > 12288 = error "encodeFrame: more than 12288 vertices"
  | otherwise = concat (zipWith3 record [0 ..] firsts polys) ++ yranges
  where
    vbase = if bank == 1 then 6144 else 0 :: Int
    counts = map (length . gpVerts) polys
    totalVerts = sum counts
    firsts = scanl (+) vbase counts
    gOf :: Int -> Unsigned 12
    gOf k = (if bank == 1 then 2048 else 0) + fromIntegral k
    vidx :: Int -> Unsigned 14
    vidx v = fromIntegral (v `mod` 12288)
    record k first p =
      let g = gOf k
          h = headerFromGx p
          hdr = zipWith (\w x -> (polyHeaderAddr b g w, x)) [0, 1, 2] (vec3 (encodeHeader h))
          slots = [ (polySlotAddr b g (fromIntegral i), encodeSlot (PolySlot (vidx (first + i)) (fromIntegral w) (fromIntegral z)))
                  | (i, z, w) <- zip3 [0 ..] (gpFinalZ p) (gpFinalW p) ]
          verts = concat
            [ zipWith (\w x -> (vertexAddr b (vidx (first + i)) w, x)) [0, 1] (vec2 (vertexRecFromGx v))
            | (i, v) <- zip [0 ..] (gpVerts p) ]
          entry = RenderEntry g (phYTop h) (phYBottom h) (phTranslucent h) (phDegenerate h)
      in (renderListAddr b bank (fromIntegral k), encodeRenderEntry entry) : hdr ++ slots ++ verts
    ranges = [ yRangeOf (gpDegenerate p) (fromIntegral (gpYTop p)) (fromIntegral (gpYBottom p))
             | p <- polys ]
    yranges = [ (yRangeAddr b bank (fromIntegral (4 * q)), word q)
              | q <- [0 .. (length polys + 3) `div` 4 - 1] ]
    word q = foldr (.|.) 0
      [ fst (yRangeWrite (fromIntegral l) r)
      | (l, r) <- zip [0 :: Int ..] (take 4 (drop (4 * q) ranges)) ]

vec3 :: Vec 3 a -> [a]
vec3 = toList

vec2 :: Vec 2 a -> [a]
vec2 = toList

-- | The render list a 'FrameDesc' describes, read through a memory (vertex
-- values as the memory holds them now).
decodeFrame :: (MemAddr -> BitVector 64) -> MemAddr -> FrameDesc -> [GxPolygon]
decodeFrame mem b fd = map poly [0 .. fromIntegral (fdCount fd) - 1 :: Int]
  where
    poly k =
      let e = decodeRenderEntry (mem (renderListAddr b (fdBank fd) (fromIntegral k)))
          g = rePoly e
          h = decodeHeader (mem (polyHeaderAddr b g 0)) (mem (polyHeaderAddr b g 1))
                           (mem (polyHeaderAddr b g 2))
          slot i =
            let s = decodeSlot (mem (polySlotAddr b g i))
            in (s, decodeVertexRec (mem (vertexAddr b (psIndex s) 0)) (mem (vertexAddr b (psIndex s) 1)))
      in gxFromRecords h (map slot [i | i <- [0 .. 9], i < phNumVerts h])

-- | The render list entries and Y-range lanes of a frame, in sorted order.
decodeYRanges :: (MemAddr -> BitVector 64) -> MemAddr -> FrameDesc
              -> [(RenderEntry, (Unsigned 8, Unsigned 8, Bool))]
decodeYRanges mem b fd =
  [ ( decodeRenderEntry (mem (renderListAddr b (fdBank fd) p))
    , decodeYRange (resize (mem (yRangeAddr b (fdBank fd) p) `shiftR` (16 * fromIntegral (yRangeLane p)))) )
  | k <- [0 .. fromIntegral (fdCount fd) - 1 :: Int], let p = fromIntegral k ]
