-- SPDX-License-Identifier: GPL-3.0-or-later
module Main where
import Nds.WholeCore.FetchLine
import Control.Monad (unless, forM_)

main :: IO ()
main = do
  let i = LineIn True False 0x02380004 False True True False 0 0 Nothing False
      step s x = lineStep s x
      demand what o = unless (downstreamValid o && requestReady o && not (fetchHit o)) (fail what)
      hit what o = unless (requestReady o && fetchHit o && not (downstreamValid o)) (fail what)
      quiet = i { reqValid=False }
      ret = quiet { returnValid=True, returnWord=0x44556677, returnLine=0x445566778899aabb }
      (pending,miss) = step initialLine i
      (filled,returned) = step pending ret
  demand "first demand must reach SDRAM" miss
  unless (responseValid returned && responseWord returned==0x44556677) (fail "miss selected word")
  forM_ [(0x02780000,0x8899aabb),(0x02380004,0x44556677)] $ \(a,w) -> do
    let (held,h) = step filled i{reqAddr=a,downstreamReady=False}
        (_,ans) = step held quiet
    hit "mirrored half failed to hit" h
    unless (responseValid ans && responseWord ans==w) (fail "wrong half")
  forM_ [i{fetch=False},i{arm7=True},i{reqAddr=0x0238000c},i{reqAddr=0x06000004},i{reqAddr=0x04000240}] $ \x -> do
    let (_,o)=step filled x
    demand "data/other core/branch/IO must not hit" o
  forM_ [0x02780001,0x00380006] $ \wr -> do
    let (dead,_) = step filled quiet{writeSnoop=Just wr}
        (_,retry) = step dead i
    demand "external byte write must invalidate either half/mirror" retry
  let (dead,store) = step filled i{reqWrite=True,reqAddr=0x02780000,arm7=True}
      (acked,_) = step dead ret
      (_,retry) = step acked i
  demand "ARM7 store not issued" store
  demand "ARM7 write must kill ARM9 instruction line" retry
  let (killed,_) = step pending quiet{writeSnoop=Just 0x02380006}
      (killed2,out) = step killed ret
  unless (responseValid out) (fail "ordered original demand dropped")
  demand "killed outstanding fill installed" (snd (step killed2 i))
  let (killed3,_) = step pending ret{writeSnoop=Just 0x02380006}
  demand "invalidate lost on returning fill edge" (snd (step killed3 i))
  let invalidate = quiet{invalidate9=True}
      (empty9,_) = step filled invalidate
  demand "CP15 retained resident ARM9 line" (snd (step empty9 i))
  -- Independent of snooping: kill stale demand fills before, at and
  -- after their acceptance. Original requester still gets its answer.
  forM_ [(fst (step initialLine i{invalidate9=True}),ret),
         (fst (step pending invalidate),ret),(pending,ret{invalidate9=True})] $ \(s,r) -> do
    let (s',replied) = step s r
    unless (responseValid replied) (fail "invalidate dropped ordered answer")
    demand "stale ARM9 response repopulated the line" (snd (step s' i))
  let (p7,_) = step initialLine i{arm7=True}
      (f7,_) = step p7 ret{invalidate9=True}
  hit "ARM9 maintenance killed ARM7 fill" (snd (step f7 i{arm7=True}))
  let (dataMiss,_) = step initialLine i{fetch=False}
      (dataDone,_) = step dataMiss ret
      (afterReset,orphan) = step initialLine ret
  demand "data read filled I-buffer" (snd (step dataDone i))
  unless (not (responseValid orphan)) (fail "reset exposed orphan reply")
  demand "reset allowed orphan fill" (snd (step afterReset i))
  -- A stalled miss must not turn into an accepted read, a hit, or a
  -- speculative fetch at the next line address.
  let (busy,_) = step initialLine i
      (_,waiting) = step busy i{reqAddr=0x02380008}
  unless (not (requestReady waiting || downstreamValid waiting)) (fail "duplicate read")
  putStrLn "PASS: 64-bit I-line halves/mirrors, no IO/data fill, DMA/ARM7/partial writes, separate CP15 resident/outstanding/return-edge kills, coordinated reset"
