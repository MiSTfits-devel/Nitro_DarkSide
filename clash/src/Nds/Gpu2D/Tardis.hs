{-# LANGUAGE BangPatterns #-}

-- | A small TARDIS monad, after Russell O'Connor's @tardis@ package.
--
-- The state has two halves: the /past/ threads forward with @>>=@, exactly
-- like 'Control.Monad.State'; the /future/ threads backward, so a value
-- sent at the end of the computation is visible to a reader at the
-- beginning. Running ties the final future state to the initial one.
--
-- This is the mechanism the speculative frame uses: the frame-start prefetch
-- pump reads the whole-frame plan that the frame's own line loop will
-- produce, and the line loop consumes the prefetch that the pump placed in
-- the past. There is no second frame pass.
module Nds.Gpu2D.Tardis
  ( Tardis (..)
  , runTardis
  , getPast
  , sendPast
  , getFuture
  , sendFuture
  , modifyPast
  , modifyFuture
  , past
  , future
  ) where

-- | @Tardis bw fw a@ is a computation with a forward past state @bw@ and a
-- backward future state @fw@.
newtype Tardis bw fw a = Tardis { unTardis :: bw -> fw -> (a, bw, fw) }

instance Functor (Tardis bw fw) where
  fmap f (Tardis g) = Tardis $ \bw fw ->
    let (a, bw', fw') = g bw fw
    in (f a, bw', fw')

instance Applicative (Tardis bw fw) where
  pure a = Tardis $ \bw fw -> (a, bw, fw)
  Tardis mf <*> Tardis ma = Tardis $ \bw fw ->
    let (f, bw1, fwMid) = mf bw fwOut
        (a, bw2, fwOut) = ma bw1 fw
    in (f a, bw2, fwMid)

-- | The future state is threaded right to left. The left action receives the
-- future state its right neighbour produced, and the whole computation
-- receives the future state written by its last action.
instance Monad (Tardis bw fw) where
  Tardis m >>= k = Tardis $ \bw fw ->
    let (a, bw1, fwOutR) = m bw fwMid
        (b, bw2, fwMid)  = unTardis (k a) bw1 fw
    in (b, bw2, fwOutR)

-- | Run with an initial past state and the future state that the last
-- action will observe. The final future state written by the first action is
-- discarded, exactly as the package does.
runTardis :: (bw, fw) -> Tardis bw fw a -> (a, bw)
runTardis (bw, fw) (Tardis f) =
  let (a, bw', _) = f bw fw
  in (a, bw')

-- | Read the past state: everything earlier actions wrote.
getPast :: Tardis bw fw bw
getPast = Tardis $ \bw fw -> (bw, bw, fw)

-- | Write the past state seen by every later action.
sendPast :: bw -> Tardis bw fw ()
sendPast bw = Tardis $ \_ fw -> ((), bw, fw)

-- | Read the future state: everything later actions will write.
getFuture :: Tardis bw fw fw
getFuture = Tardis $ \bw fw -> (fw, bw, fw)

-- | Write the future state seen by every earlier action.
sendFuture :: fw -> Tardis bw fw ()
sendFuture fw = Tardis $ \bw _ -> ((), bw, fw)

modifyPast :: (bw -> bw) -> Tardis bw fw ()
modifyPast f = getPast >>= sendPast . f

modifyFuture :: (fw -> fw) -> Tardis bw fw ()
modifyFuture f = getFuture >>= sendFuture . f

-- | The whole past state after the computation.
past :: Tardis bw fw bw -> bw -> fw -> bw
past (Tardis f) bw fw = let (_, bw', _) = f bw fw in bw'

-- | The whole future state before the computation.
future :: Tardis bw fw fw -> bw -> fw -> fw
future (Tardis f) bw fw = let (_, _, fw') = f bw fw in fw'
