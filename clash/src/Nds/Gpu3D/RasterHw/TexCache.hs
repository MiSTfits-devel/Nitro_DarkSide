{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The texture caches in front of the texture/palette read port, shaped for
-- 'Nds.Gpu3D.ShadePipe': three direct-mapped read-only caches with 32-byte
-- lines and 64-bit data RAMs,
--
-- * texel halfwords (stage A address): 4 KiB, 128 lines;
-- * 4x4 palette-index halfwords (stage A): 512 B, 16 lines;
-- * palette words (stage B address): 2 KiB, 64 lines.
--
-- The hit test is combinational on the address the pipe drives this cycle;
-- the data RAM read is registered, so the pipe sees the halfword or word one
-- cycle later, as 'shadePipe' expects. A needed access that misses lowers
-- the pipeline enable; the refill engine then reads the line (four words,
-- pipelined) through the texture port, writes it and its tag, and the access
-- hits on a later cycle. Data a stalled stage already received is held in a
-- register, so a refill cannot change it. 'restart' invalidates every line
-- (texture memory may change between frames).
module Nds.Gpu3D.RasterHw.TexCache
  ( texCaches
  , CacheIn (..)
  , CacheOut (..)
  ) where

import Prelude

import Data.Bits (setBit, shiftL, shiftR, testBit, (.&.))
import Data.Word (Word16, Word32)
import GHC.Generics (Generic)

import Clash.Explicit.Prelude
  ( BitVector, Clock, Enable, Index, KnownDomain, NFDataX, Reset, Signal, Unsigned
  , asyncRam, blockRamPow2, bundle, register, resize, unbundle )
import qualified Clash.Explicit.Prelude as C
import Clash.Explicit.Mealy (mealy)

import Nds.Gpu3D.Mem (MemAddr, MemReq (..))

-- Input and output records are lazy: the enable fed back in is the hit
-- signal this block drives.
data CacheIn = CacheIn
  { ciRestart  :: Bool
  , ciEn       :: Bool                 -- ^ pipeline enable this cycle
  , ciNeedTex  :: Bool
  , ciTexAddr  :: Word32
  , ciNeedInfo :: Bool
  , ciInfoAddr :: Word32
  , ciNeedPal  :: Bool
  , ciPalAddr  :: Word32
  , ciTexBase  :: MemAddr
  , ciPalBase  :: MemAddr
  , ciAccept   :: Bool                 -- ^ the port arbiter accepted the refill request
  , ciResp     :: Maybe (BitVector 64) -- ^ refill response
  } deriving (Generic, NFDataX)

data CacheOut = CacheOut
  { coHit   :: Bool       -- ^ every needed access hits
  , coTexD  :: Word16
  , coInfoD :: Word16
  , coPalD  :: Word32
  , coReq   :: Maybe MemReq
  , coMisses :: Unsigned 32  -- ^ refills so far (statistics)
  } deriving (Generic, NFDataX)

data Sel = STex | SInfo | SPal
  deriving (Eq, Generic, Show, NFDataX)

data Fill = Fill
  { flBusy :: !Bool
  , flSel  :: !Sel
  , flLine :: !Word32        -- ^ byte address of the line (in texture or palette space)
  , flIss  :: !(Index 5)
  , flRcv  :: !(Index 5)
  , flValidT :: !(BitVector 128)
  , flValidI :: !(BitVector 16)
  , flValidP :: !(BitVector 64)
  , flCount :: !(Unsigned 32)
  } deriving (Eq, Generic, Show, NFDataX)

fill0 :: Fill
fill0 = Fill False STex 0 0 0 0 0 0 0

-- Line index and tag of each cache.
texIdx, infoIdx, palIdx :: Word32 -> Unsigned 7
texIdx a = fromIntegral ((a `shiftR` 5) .&. 127)
infoIdx a = fromIntegral ((a `shiftR` 5) .&. 15)
palIdx a = fromIntegral ((a `shiftR` 5) .&. 63)

texTag, infoTag, palTag :: Word32 -> Unsigned 10
texTag a = fromIntegral ((a .&. 0x7FFFF) `shiftR` 12)
infoTag a = fromIntegral ((a .&. 0x7FFFF) `shiftR` 9)
palTag a = fromIntegral ((a .&. 0x1FFFF) `shiftR` 11)

-- | Refill engine and valid bits. Inputs: the hit flags of the three tag
-- lookups, the request; outputs the refill request, the data RAM write
-- (cache, word address, data) and the tag write.
fillStep :: Fill -> (CacheIn, Bool, Bool, Bool)
         -> (Fill, (Maybe MemReq, Maybe (Sel, Unsigned 9, BitVector 64), Maybe (Sel, Unsigned 7, Unsigned 10), Fill))
fillStep f (i, hT, hI, hP) =
  -- the restart (frame start) invalidates every line; it resets the state
  -- only, never the outputs
  let (f', o) = fillRun f (i, hT, hI, hP) in (if ciRestart i then fill0 else f', o)

fillRun :: Fill -> (CacheIn, Bool, Bool, Bool)
        -> (Fill, (Maybe MemReq, Maybe (Sel, Unsigned 9, BitVector 64), Maybe (Sel, Unsigned 7, Unsigned 10), Fill))
fillRun f (i, hT, hI, hP)
  | not (flBusy f) =
      let start sel a = f { flBusy = True, flSel = sel, flLine = a .&. complement31, flIss = 0, flRcv = 0
                          , flCount = flCount f + 1 }
          f'
            | ciNeedTex i && not hT = start STex (ciTexAddr i .&. 0x7FFFF)
            | ciNeedInfo i && not hI = start SInfo (ciInfoAddr i .&. 0x7FFFF)
            | ciNeedPal i && not hP = start SPal (ciPalAddr i .&. 0x1FFFF)
            | otherwise = f
      in (f', (Nothing, Nothing, Nothing, f))
  | otherwise =
      let base = if flSel f == SPal then ciPalBase i else ciTexBase i
          req = if flIss f < 4
                  then Just (MemRead (base + fromIntegral (flLine f) + (fromIntegral (flIss f) `shiftL` 3)))
                  else Nothing
          f1 = if ciAccept i && flIss f < 4 then f { flIss = flIss f + 1 } else f
          wordAddr = (fromIntegral (flLine f `shiftR` 3) .&. 0x1FC) + fromIntegral (flRcv f) :: Unsigned 9
          (wr, f2) = case ciResp i of
            Just w -> (Just (flSel f, wordAddr, w), f1 { flRcv = flRcv f1 + 1 })
            Nothing -> (Nothing, f1)
          done = flRcv f2 == 4
          a = flLine f
          (tagW, f3)
            | not done = (Nothing, f2)
            | otherwise = case flSel f of
                STex -> (Just (STex, texIdx a, texTag a), f2 { flBusy = False, flValidT = setB (texIdx a) (flValidT f2) })
                SInfo -> (Just (SInfo, infoIdx a, infoTag a), f2 { flBusy = False, flValidI = setB (infoIdx a) (flValidI f2) })
                SPal -> (Just (SPal, palIdx a, palTag a), f2 { flBusy = False, flValidP = setB (palIdx a) (flValidP f2) })
      in (f3, (req, wr, tagW, f))
  where
    complement31 = 0xFFFFFFE0
    setB :: C.KnownNat n => Unsigned 7 -> BitVector n -> BitVector n
    setB k v = setBit v (fromIntegral k)

-- | The three caches and their refill engine.
texCaches
  :: forall dom. KnownDomain dom
  => Clock dom -> Reset dom -> Enable dom
  -> Signal dom CacheIn
  -> Signal dom CacheOut
texCaches clk rst en inp = out
  where
    (fReq, fWr, fTag, fSt) = unbundle (mealy clk rst en fillStep fill0 (bundle (inp, hitT, hitI, hitP)))

    tagWr sel = C.fmap (\m -> case m of
                           Just (s, k, t) | s == sel -> Just (k, t)
                           _ -> Nothing) fTag
    tagT = asyncRam clk clk en (C.SNat :: C.SNat 128) (C.fmap (texIdx . ciTexAddr) inp) (tagWr STex)
    tagI = asyncRam clk clk en (C.SNat :: C.SNat 16) (C.fmap (resize . infoIdx . ciInfoAddr) inp :: Signal dom (Unsigned 4)) (C.fmap (C.fmap (\(k, t) -> (resize k, t))) (tagWr SInfo))
    tagP = asyncRam clk clk en (C.SNat :: C.SNat 64) (C.fmap (resize . palIdx . ciPalAddr) inp :: Signal dom (Unsigned 6)) (C.fmap (C.fmap (\(k, t) -> (resize k, t))) (tagWr SPal))

    hitT = (\f i t -> testBit (flValidT f) (fromIntegral (texIdx (ciTexAddr i))) && t == texTag (ciTexAddr i)) <$> fSt <*> inp <*> tagT
    hitI = (\f i t -> testBit (flValidI f) (fromIntegral (infoIdx (ciInfoAddr i))) && t == infoTag (ciInfoAddr i)) <$> fSt <*> inp <*> tagI
    hitP = (\f i t -> testBit (flValidP f) (fromIntegral (palIdx (ciPalAddr i))) && t == palTag (ciPalAddr i)) <$> fSt <*> inp <*> tagP

    dataWr sel = C.fmap (\m -> case m of
                            Just (s, k, w) | s == sel -> Just (k, w)
                            _ -> Nothing) fWr
    ramT = blockRamPow2 clk en (C.replicate (C.SNat :: C.SNat 512) 0)
             (C.fmap (\i -> fromIntegral ((ciTexAddr i `shiftR` 3) .&. 511) :: Unsigned 9) inp) (dataWr STex)
    ramI = blockRamPow2 clk en (C.replicate (C.SNat :: C.SNat 64) 0)
             (C.fmap (\i -> fromIntegral ((ciInfoAddr i `shiftR` 3) .&. 63) :: Unsigned 6) inp)
             (C.fmap (C.fmap (\(k, w) -> (resize k, w))) (dataWr SInfo))
    ramP = blockRamPow2 clk en (C.replicate (C.SNat :: C.SNat 256) 0)
             (C.fmap (\i -> fromIntegral ((ciPalAddr i `shiftR` 3) .&. 255) :: Unsigned 8) inp)
             (C.fmap (C.fmap (\(k, w) -> (resize k, w))) (dataWr SPal))

    -- Lane selects of last cycle's reads, and the hold registers.
    selT = register clk rst en 0 (C.fmap (\i -> fromIntegral ((ciTexAddr i `shiftR` 1) .&. 3) :: Unsigned 2) inp)
    selI = register clk rst en 0 (C.fmap (\i -> fromIntegral ((ciInfoAddr i `shiftR` 1) .&. 3) :: Unsigned 2) inp)
    selP = register clk rst en False (C.fmap (\i -> testBit (ciPalAddr i) 2) inp)
    enPrev = register clk rst en True (C.fmap ciEn inp)
    half w k = fromIntegral (w `shiftR` (16 * fromIntegral k)) :: Word16
    texNow = half <$> ramT <*> selT
    infoNow = half <$> ramI <*> selI
    palNow = (\w hi -> fromIntegral (if hi then w `shiftR` 32 else w) :: Word32) <$> ramP <*> selP
    hold :: (NFDataX a, Num a) => Signal dom a -> Signal dom a
    hold now = let v = C.mux enPrev now held
                   held = register clk rst en 0 v
               in v
    texD = hold texNow
    infoD = hold infoNow
    palD = hold palNow

    hitAll = (\i t a p -> (not (ciNeedTex i) || t) && (not (ciNeedInfo i) || a) && (not (ciNeedPal i) || p))
               <$> inp <*> hitT <*> hitI <*> hitP
    out = CacheOut <$> hitAll <*> texD <*> infoD <*> palD <*> fReq <*> C.fmap flCount fSt
