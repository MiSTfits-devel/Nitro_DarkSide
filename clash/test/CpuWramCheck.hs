-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, TypeApplications #-}
module Main where

import qualified Clash.Explicit.Prelude as C
import Control.Monad (forM_, unless)
import Data.Bits (xor, shiftL)
import Nds.WholeCore.CpuWram (cpuWram, wramControl)

type W = C.BitVector 32
type Inputs = (Bool,Bool,Bool,W,C.BitVector 4,W,Bool,Bool,W)
-- Response value is meaningful only on valid. Output order: ready, reply,
-- reply data, external valid. The expected responses below are calculated
-- from byte addresses, not from the RTL's index or byte-lane helpers.
type Case = (Inputs,(Bool,Maybe W,Bool))
type Entry = (W,W)
base :: W
base = 0x03800000

local :: Bool -> W -> C.BitVector 4 -> W -> Inputs
local wr a be v = (True,True,wr,a,be,v,False,False,0)
quiet :: Inputs
quiet = (False,False,False,0,0,0,True,False,0)
entries :: [Entry]
entries = [(n*4, (0x614ec517*n) `xor` 0xa50819bf) | n <- [0..16383]]

storage :: [Case]
storage = zip writes ((True,Nothing,False) : repeat (True,Just 0,False))
       ++ zip reads ((True,Just 0,False) : map (\(_,v) -> (True,Just v,False)) backwards)
       ++ [(quiet,(True,Just (snd (last backwards)),False))]
 where
  writes = [local True (base+a) 15 v | (a,v) <- entries]
  backwards = reverse entries
  reads = [local False (base + ((fromIntegral (i `mod` 128)) `shiftL` 16) + a) 15 0
          | (i,(a,_)) <- zip [0::Int ..] backwards]

lanes :: [Case]
lanes = [ (local True base 15 0x12345678, (True,Nothing,False))
        , (local True 0x03ff0000 2 0x0000ab00, (True,Just 0,False))
        , (local True 0x03810000 12 0xcdef0000, (True,Just 0,False))
        , (local False base 15 0, (True,Just 0,False))
        , (quiet, (True,Just 0xcdefab78,False)) ]

ordering :: [Case]
ordering = [ (external False 0x02000000, (True,Nothing,True))
           , (external True 0x02fffffc, (True,Nothing,True))
           , (rd, (False,Nothing,False))                  -- cannot overtake either external reply
           , (reply rd 0x3e, (False,Just 0x3e,False))
           , (reply rd 0x72, (True,Just 0x72,False))      -- final external reply + local acceptance
           , (external True 0x04000000, (True,Just 0xcdefab78,True)) -- private reply + new external offer
           , (reply quiet 0xaa, (True,Just 0xaa,False)) ]
 where
  external a7 a = (a7,True,False,a,15,0,True,False,0)
  rd = local False base 15 0
  reply (a,b,c,d,e,f,g,_,_) w = (a,b,c,d,e,f,g,True,w)

type Mode = C.BitVector 2

-- Seed both physical banks through ARM9's full window; read every word
-- through ARM7's full window in reverse across all 256 mirrors. Then
-- confirm each half-bank mapping and the unowned ARM9 write suppression.
shared :: [(Mode,Case)]
shared = zipWith cycleCase tx (Nothing : map (Just . snd) tx) ++ [(0,(quiet,(True,Just (val 1),False)))]
 where
  cycleCase ((m,i),_) prev = (m,(i,(True,prev,False)))
  io s wr a v = (s,True,wr,a,15,v,False,False,0)
  val n = 0x8af38107 * fromIntegral (n :: Int) + 0x23b3eb05
  writes = [((0,io False True (0x03000000+4*fromIntegral n) (val n)),0) | n <- [0..8191]]
  reads = [((3,io True False (0x03000000+4*fromIntegral n+0x8000*fromIntegral (n `mod` 256)) 0),val n) | n <- [8191,8190..0]]
  split = [((m,io s False 0x037fc004 0),val n) | (m,s,n) <- [(1,True,1),(1,False,4097),(2,True,4097),(2,False,1)]]
  denied = [((3,io False True 0x03ff8004 0x22334455),0),((3,io False False 0x03ff8004 0),0),
            ((3,io True False 0x037f8004 0),val 1),((0,io True True 0x037f8004 0x1e7b),0),
            ((2,io True False 0x03ff8004 0),0x1e7b),((0,io False False 0x03000004 0),val 1)]
  tx = writes ++ reads ++ split ++ denied

-- Two external transactions followed by an ARM7 status read: changing
-- WRAMCNT before the status response must not change the read snapshot.
statusOrder :: [(Mode,Case)]
statusOrder = [(0,(ext 0x02000000 False 0,(True,Nothing,True))),
               (0,(ext 0x02000004 False 0,(True,Nothing,True))),
               (1,(ext 0x04000240 False 0,(False,Nothing,False))),
               (2,(ext 0x04000240 True 0x1234,(False,Just 0x1234,False))),
               (3,(ext 0x04000240 True 0xabcd,(True,Just 0xabcd,True))),
               (0,(ext 0x02000008 False 0,(True,Nothing,True))),
               (1,((False,False,False,0,0,0,True,True,0xdeadff03),(True,Just 0xdead0303,False))),
               (2,((False,False,False,0,0,0,True,True,0x42),(True,Just 0x42,False)))]
 where ext a resp d = (True,True,False,a,15,0,True,resp,d)

control :: IO ()
control = do
  let clk=C.clockGen @C.System
      idle=(False,False,0,0,0,0)
      -- Tuple: accepted, write, address, byte lanes, right-justified data, vendor reply
      inputs=[(False,True,0x04000247,8,2,0),(True,True,0x04000247,8,0xff,0),
              (True,False,0x04000244,15,0,0),(False,False,0,0,0,0xff765432),
              (True,True,0x04000246,12,0x0281,0),(True,False,0x04000246,12,0,0),
              (False,False,0,0,0,0xff81),(True,True,0x04000244,7,0,0),
              (True,False,0x04000247,8,0,0),(False,False,0,0,0,0xff)]
      (h,w,a,l,d,e)=C.unbundle (C.fromList (idle:inputs++repeat idle))
      out=drop 1 $ C.sampleN (length inputs+1) (wramControl clk C.resetGen C.enableGen h w a l d e)
  unless (map fst out==[0,0,3,3,3,2,2,2,2,2]) (fail "WRAMCNT reset/stall/write/byte lanes")
  unless (all (\(n,x)->snd (out!!n)==x) [(3,0x03765432),(6,0x0281),(9,2)]) (fail "mixed WRAMCNT/VRAMCNT read")

-- Exercise both interfaces on the same edges. The first read below is
-- accepted alongside the mode-3 write, so it must still return private
-- RAM. The immediately following read must see shared bank A instead.
remapEdge :: IO ()
remapEdge = do
  let clk=C.clockGen @C.System
      inputs=[((False,0),(False,True,True,0x03000000,15,0xaaaa,True,False,0)),
              ((False,0),local True (base+0x8000) 15 0x7777),
              ((False,3),local False 0x037f8000 15 0),
              ((True,3),local False 0x037f8000 15 0),
              ((False,0),local False 0x037f8000 15 0),
              ((True,0),local False 0x037f8000 15 0),
              ((False,0),local False 0x037f8000 15 0),
              ((False,0),quiet)]
      (ctrl,bus)=C.unbundle (C.fromList (((False,0),quiet):inputs++repeat ((False,0),quiet)))
      (accepted,m)=C.unbundle ctrl
      mode=fst <$> wramControl clk C.resetGen C.enableGen accepted (pure True) (pure 0x04000247) (pure 8) m (pure 0)
      (s,v,w,a,be,d,r,rv,rd)=C.unbundle bus
      samples=drop 1 $ C.sampleN 9 (cpuWram clk C.resetGen C.enableGen mode s v w a be d r rv rd)
      actual=[x | (_,True,x,_) <- samples]
  unless (actual==[0,0,0x7777,0x7777,0xaaaa,0xaaaa,0x7777]) (fail ("remap ordering: "++show actual))

main :: IO ()
main = do
  control
  remapEdge
  let (modes,cases) = unzip (map ((,) 0) (storage ++ lanes ++ ordering) ++ shared ++ statusOrder)
      clk = C.clockGen @C.System
      input = C.fromList (quiet : map fst cases ++ repeat quiet)
      (a,v,w,addr,be,d,r,vr,dr) = C.unbundle input
      output = cpuWram clk C.resetGen C.enableGen (C.fromList (0:modes++repeat 0)) a v w addr be d r vr dr
      clean (ready,valid,word,external) = (ready,if valid then Just word else Nothing,external)
      got = map clean (drop 1 (C.sampleN (length cases+1) output))
  forM_ (zip3 [0::Int ..] got (map snd cases)) $ \(cycleN,actual,expected) ->
    unless (actual==expected) $ fail ("WRAM cycle "++show cycleN++": got "++show actual++", expected "++show expected)
  putStrLn "PASS: all 16384 private and 8192 shared words, aliases, lane masks, ownership, control writes, ordered status and memory replies"
