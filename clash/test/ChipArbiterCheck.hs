{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

-- | Two outstanding reads must retain their requestor tags across a pop.
module Main (main) where

import Clash.Explicit.Prelude (BitVector, Vec(..))
import qualified Clash.Explicit.Prelude as C
import Nds.Gpu3D.ChipHw
import Nds.Gpu3D.Mem
import Nds.Gpu3D.PolyRam (FrameDesc(..))
import Nds.Gpu3D.RasterHw.Types (RegsHw(..))
import Data.Maybe (isJust)
import System.Exit (exitFailure)

main :: IO ()
main = do
  let none = C.repeat Nothing :: Vec 4 (Maybe MemReq)
      both = Just (MemRead 0x10) :> Just (MemRead 0x20) :> Nothing :> Nothing :> Nil
      (s0,_) = arbStep 0 (arbInit @4) (both,True,Nothing)
      (s1,(_,f1,_)) = arbStep 0 s0 (none,True,Nothing)
      (s2,(_,f2,_)) = arbStep 0 s1 (none,True,Nothing)
      (s3,(_,_,r1)) = arbStep 0 s2 (none,True,Just (0xaa :: BitVector 64))
      (s4,(_,_,r2)) = arbStep 0 s3 (none,True,Just (0xbb :: BitVector 64))
      checks = [f1 == Just (MemRead 0x10), f2 == Just (MemRead 0x20)
               ,r1 == (Just 0xaa :> Nothing :> Nothing :> Nothing :> Nil)
               ,r2 == (Nothing :> Just 0xbb :> Nothing :> Nothing :> Nil)
               ,atCount s4 == 0]
      regs = RegsHw 0 0 0 0 0 0 0 (C.repeat 0) (C.repeat 0) (C.repeat 0) 0
      input = TIn (Just (FrameDesc 0 1)) True True True regs 0 0 0
      blocked = input { tiOk = False }
      afterBlock = iterate (fst . tblStep blocked) tInit !! 20
      states = take 170 (iterate (fst . tblStep input) afterBlock)
      starts = [i | (i,st) <- zip [0 :: Int ..] states, isJust (toStart (snd (tblStep input st)))]
      allChecks = checks ++ [starts == [148]]
  if and allChecks then putStrLn "chip arbiter response tags and render-table pulse: passed"
  else print allChecks >> exitFailure
