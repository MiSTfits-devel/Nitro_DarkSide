{-# LANGUAGE BangPatterns, DataKinds, MultiWayIf #-}
-- SPDX-License-Identifier: GPL-3.0-or-later
-- | Randomized differential test of the pipelined ARM9 slice
-- ("Nds.WholeCore.Arm9Slice") against the frozen non-overlapped staged step
-- ("Arm9SliceStaged", commit fbb32bd) as the oracle.
--
-- Each seed generates a boot-ROM program: data processing with every shift
-- form, conditions and flag writes; multiplies, CLZ, MRS/MSR (flags, and
-- System/SVC switches); loads and stores to local RAM (immediate offsets,
-- post- and pre-indexed writeback, signed and halfword); LDM/STM; link loads
-- and stores; forward B/BL over blocks; BX/BLX into inline Thumb blocks and
-- back; LDR pc and LDM {pc}; SWI from ARM and Thumb; jumps through ARM and
-- Thumb trampolines in the last ROM word, whose sequential prefetch runs off
-- the ROM (wrong-path fetch faults that must not fault); local-RAM code
-- blocks that store over their own next instructions (STR, STM beats, and
-- Thumb STRH, one to three instructions ahead); and in some seeds a final
-- real-path fault (misaligned or unrouted branch target, undefined
-- instruction, link reply error).
--
-- Both cores run with independent random link stalls. The pipelined core's
-- IRQ line rises at random cycles and drops when the handler's acknowledge
-- store is seen. Each entry must be legal: the line high and CPSR.I clear in
-- the cycle it was taken (never with the line low), and no more than
-- 'irqBound' cycles after the line was first high with I clear. The oracle
-- is then given each IRQ at the instruction boundary the pipelined core
-- chose (its line is high exactly while it has retired that many
-- instructions). Retire, store and link streams, IRQ boundaries and the
-- fault must be identical.
--
--   arm9-pipe-diff [FIRST_SEED [COUNT]]
--
-- Prints one line per failing seed and a summary; exit status 1 on failure.
module Main (main) where

import Clash.Prelude (BitVector)
import Control.Monad (foldM, forM, when)
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import Data.Bits
import qualified Data.IntMap.Strict as IM
import Data.List (foldl', sort)
import Data.Word (Word16, Word32, Word64)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import Text.Printf (printf)
import qualified Arm9SliceStaged as Old
import Nds.WholeCore.Arm9Slice

type W = Word32

-- * Random numbers (SplitMix64) and a small generator monad

newtype Rng = Rng Word64

next64 :: Rng -> (Word64, Rng)
next64 (Rng s) = (z3, Rng s')
 where
  s' = s + 0x9e3779b97f4a7c15
  z1 = (s' `xor` (s' `shiftR` 30)) * 0xbf58476d1ce4e5b9
  z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94d049bb133111eb
  z3 = z2 `xor` (z2 `shiftR` 31)

below :: Int -> Rng -> (Int, Rng)
below n g = let (x, g') = next64 g in (fromIntegral (x `mod` fromIntegral (max 1 n)), g')

newtype Gen a = Gen { runGen :: Rng -> (a, Rng) }

instance Functor Gen where
  fmap f (Gen m) = Gen (\g -> let (a, g') = m g in (f a, g'))
instance Applicative Gen where
  pure a = Gen (\g -> (a, g))
  Gen mf <*> Gen ma = Gen (\g -> let (f, g1) = mf g; (a, g2) = ma g1 in (f a, g2))
instance Monad Gen where
  Gen m >>= k = Gen (\g -> let (a, g') = m g in runGen (k a) g')

int :: Int -> Gen Int
int n = Gen (below n)

num :: Num a => Int -> Gen a
num n = fromIntegral <$> int n

pick :: [a] -> Gen a
pick xs = (xs !!) <$> int (length xs)

chance :: Int -> Gen Bool
chance pct = (< pct) <$> int 100

word :: Gen W
word = Gen (\g -> let (x, g') = next64 g in (fromIntegral x, g'))

-- * ARM and Thumb encodings

al :: W
al = 0xe

fl :: Bool -> Int -> W
fl c n = if c then bit n else 0

dpR :: W -> W -> Bool -> W -> W -> W -> W
dpR c opc s rn rd op2 = shiftL c 28 .|. shiftL opc 21 .|. fl s 20 .|. shiftL rn 16 .|. shiftL rd 12 .|. op2

-- | Data processing with a rotated immediate: value = imm ROR (2 * rot).
dpI :: W -> W -> Bool -> W -> W -> W -> W -> W
dpI c opc s rn rd rot imm = dpR c opc s rn rd (bit 25 .|. shiftL rot 8 .|. imm)

-- | MOV rd, #c for a constant that fits one rotated byte.
movByte :: W -> W -> W -> W
movByte rd rot imm = dpI al 0xd False 0 rd rot imm

-- | Load any 32-bit constant: MOV of the low byte and ORRs of the others.
loadConst :: W -> W -> [W]
loadConst rd v = movByte rd 0 (v .&. 0xff)
  : [ dpI al 0xc False rd rd (fromIntegral ((16 - 4 * k) `mod` 16)) ((v `shiftR` (8 * k)) .&. 0xff)
    | k <- [1, 2, 3 :: Int], (v `shiftR` (8 * k)) .&. 0xff /= 0 ]

-- | rd = rn + v for v < 0x10000.
addLarge :: W -> W -> W -> [W]
addLarge rd rn v
  | v < 0x100 = [dpI al 0x4 False rn rd 0 v]
  | v .&. 0xff == 0 = [dpI al 0x4 False rn rd 12 (v `shiftR` 8)]
  | otherwise = [dpI al 0x4 False rn rd 12 (v `shiftR` 8), dpI al 0x4 False rd rd 0 (v .&. 0xff)]

ldstI :: W -> Bool -> Bool -> Bool -> Bool -> Bool -> W -> W -> W -> W
ldstI c p u b w l rn rd off = shiftL c 28 .|. 0x04000000 .|. fl p 24 .|. fl u 23 .|. fl b 22
  .|. fl w 21 .|. fl l 20 .|. shiftL rn 16 .|. shiftL rd 12 .|. (off .&. 0xfff)

-- | LDRH/STRH/LDRSB/LDRSH, immediate offset, pre-indexed, added.
ldstH :: W -> Bool -> W -> W -> W -> W -> W
ldstH c l sh rn rd off = shiftL c 28 .|. bit 24 .|. bit 23 .|. bit 22 .|. fl l 20 .|. shiftL rn 16
  .|. shiftL rd 12 .|. shiftL ((off `shiftR` 4) .&. 0xf) 8 .|. 0x90 .|. shiftL sh 5 .|. (off .&. 0xf)

blockT :: W -> Bool -> Bool -> Bool -> Bool -> W -> W -> W
blockT c p u w l rn list = shiftL c 28 .|. 0x08000000 .|. fl p 24 .|. fl u 23 .|. fl w 21 .|. fl l 20
  .|. shiftL rn 16 .|. list

-- | B/BL to the instruction 'ahead' words after this one.
branch :: W -> Bool -> Int -> W
branch c link ahead = shiftL c 28 .|. 0x0a000000 .|. fl link 24 .|. (fromIntegral (ahead - 2) .&. 0xffffff)

bx, blx :: W -> W
bx rm = 0xe12fff10 .|. rm
blx rm = 0xe12fff30 .|. rm

movLrPc, haltW, nopA :: W
movLrPc = dpR al 0xd False 0 14 15
haltW = 0xeafffffe
nopA = 0xe1a00000

pack16 :: [Word16] -> [W]
pack16 (a : b : r) = (fromIntegral a .|. shiftL (fromIntegral b) 16) : pack16 r
pack16 [a] = [fromIntegral a .|. 0x46c00000]
pack16 [] = []

-- * Program generator

ramBase, linkBase, ackAddr, linkFaultAddr, ramTramp :: W
ramBase = 0x02000000
linkBase = 0x06000000
ackAddr = ramBase + 0xfe0
linkFaultAddr = linkBase + 0x3fc
-- | RAM offset of the local-RAM trampolines: Thumb BX lr at 0xffa, ARM BX lr
-- at 0xffc. Their sequential prefetch runs off the end of local RAM.
ramTramp = 0xff8

-- | Registers the random code may write (never R11 = RAM base, R12 = link
-- base, R13 = stack).
dataRegs :: [W]
dataRegs = [0 .. 10] ++ [14]

reg :: Gen W
reg = pick dataRegs

cond :: Gen W
cond = do
  c <- chance 70
  if c then pure al else pick [0 .. 13]

dataProc :: [W] -> Gen W
dataProc dests = do
  opc <- num 16
  c <- cond
  let testOp = opc >= 8 && opc <= 11
  s <- if testOp then pure True else chance 40
  rd <- if testOp then pure 0 else pick dests
  rn <- pick (dataRegs ++ [11, 12, 13, 15])
  form <- int 4
  op2 <- case form of
    0 -> (\rot imm -> bit 25 .|. shiftL rot 8 .|. imm) <$> num 16 <*> num 256
    1 -> (\sh amt rm -> shiftL amt 7 .|. shiftL sh 5 .|. rm) <$> num 4 <*> num 32 <*> pick (dataRegs ++ [11, 15])
    2 -> (\sh rs rm -> shiftL rs 8 .|. shiftL sh 5 .|. 0x10 .|. rm) <$> num 4 <*> reg <*> reg
    _ -> (\sh rm -> shiftL sh 5 .|. rm) <$> pick [1, 2, 3] <*> reg     -- LSR/ASR #32, RRX
  -- register shifts may not name R15
  let rn' = if form == 2 && rn == 15 then 0 else rn
  pure (dpR c opc s rn' rd op2)

multiply :: Gen W
multiply = do
  c <- cond
  long <- chance 50
  s <- chance 40
  a <- chance 50
  rm <- reg
  rs <- reg
  if long
    then do
      lo <- reg
      hi <- pick (filter (/= lo) dataRegs)
      u <- chance 50
      pure (shiftL c 28 .|. 0x00800090 .|. fl u 22 .|. fl a 21 .|. fl s 20 .|. shiftL hi 16 .|. shiftL lo 12
            .|. shiftL rs 8 .|. rm)
    else do
      rd <- reg
      rn <- if a then reg else pure 0
      pure (shiftL c 28 .|. 0x90 .|. fl a 21 .|. fl s 20 .|. shiftL rd 16 .|. shiftL rn 12 .|. shiftL rs 8 .|. rm)

memItem :: Gen [W]
memItem = do
  kind <- int 5
  c <- cond
  rd <- reg
  case kind of
    0 -> do -- word or byte, [r11, #off]
      b <- chance 30
      l <- chance 50
      off <- if b then num 0x400 else (* 4) <$> num 0x100
      pure [ldstI c True True b False l 11 rd off]
    1 -> do -- halfword and signed loads, [r11, #off]
      sh <- pick [1, 2, 3]
      l <- if sh == 1 then chance 50 else pure True
      off <- if sh == 2 then num 0x100 else (* 2) <$> num 0x80
      pure [ldstH c l sh 11 rd off]
    2 -> do -- r9 pointer, post-indexed or pre-indexed with writeback
      base <- (* 4) <$> num 0xd0
      l <- chance 50
      pre <- chance 50
      rd' <- pick (filter (/= 9) dataRegs)
      pure (addLarge 9 11 base ++ [ldstI c pre True False pre l 9 rd' 4])
    3 -> do -- link
      w <- pick [1, 2, 4 :: Int]
      l <- chance 50
      off <- (* fromIntegral w) <$> num (0x100 `div` w)
      pure [ if w == 2 then ldstH c l 1 12 rd off else ldstI c True True (w == 1) False l 12 rd off ]
    _ -> do -- LDM/STM in all four modes through r9
      base <- (* 4) <$> num 0xc0
      list <- (.&. 0x45ff) . (.|. 1) <$> num 0x10000
      l <- chance 50
      wb <- chance 50
      dirn <- int 4
      let (p, u) = [(False, True), (True, True), (False, False), (True, False)] !! dirn
          base' = if u then base else base + 0x80
      pure (addLarge 9 11 base' ++ [blockT c p u wb l 9 list])

-- | One body item; 'depth' bounds nesting of branch blocks.
armItem :: Int -> Gen [W]
armItem depth = do
  k <- int 100
  if | k < 38 -> (: []) <$> dataProc dataRegs
     | k < 44 -> (: []) <$> multiply
     | k < 46 -> (\c rd rm -> [shiftL c 28 .|. 0x016f0f10 .|. shiftL rd 12 .|. rm]) <$> cond <*> reg <*> reg
     | k < 48 -> (\rd -> [0xe10f0000 .|. shiftL rd 12]) <$> reg
     | k < 50 -> (\f -> [0xe328f200 .|. f]) <$> num 16                  -- MSR cpsr_f
     | k < 52 -> (\m -> [0xe321f000 .|. m]) <$> pick [0x1f, 0x13]        -- System / SVC, I clear
     | k < 54 -> spsrItem
     | k < 64 -> memItem
     | k < 68 && depth < 2 -> do
         n <- int 4
         body <- concat <$> mapM (const (armItem (depth + 1))) [0 .. n]
         c <- cond
         l <- chance 30
         pure (branch c l (length body + 1) : body)
     | k < 73 && depth < 2 -> thumbBlock
     | k < 75 -> (\imm -> [0xef000000 .|. imm]) <$> num 0x1000
     | k < 77 -> pcLoad
     | k < 80 -> do
         inRam <- chance 50
         if inRam then ramTrampoline else trampoline
     | k < 84 && depth == 0 -> ramBlock
     | otherwise -> (: []) <$> dataProc dataRegs

-- | In SVC mode, write SPSR_svc (MSR spsr_fc) and read it back zero to two
-- instructions later. Mode SVC or System, T clear: nothing returns through
-- it (SWI entry overwrites it first).
spsrItem :: Gen [W]
spsrItem = do
  v <- (\f i m -> shiftL f 28 .|. shiftL i 6 .|. m) <$> num 16 <*> num 4 <*> pick [0x13, 0x1f]
  gap <- int 3
  between <- mapM (const (dataProc dataRegs)) [1 .. gap]
  rd <- reg
  pure ([0xe321f013] ++ loadConst 10 v ++ [0xe169f00a] ++ between ++ [0xe14f0000 .|. shiftL rd 12])

-- | LDR pc or LDM {pc} to the ARM instruction two words on (the junk word
-- between must never execute).
pcLoad :: Gen [W]
pcLoad = do
  viaLdm <- chance 50
  junk <- dataProc dataRegs
  off <- (* 4) <$> num 0x40
  let setTarget = dpI al 0x4 False 15 10 0 8                     -- r10 = pc + 8 + 8
  pure $ if viaLdm
    then [setTarget, blockT al True False True False 13 (bit 10), blockT al False True True True 13 (bit 15), junk]
    else [ setTarget, ldstI al True True False False False 11 10 (0x300 + off)
         , ldstI al True True False False True 11 15 (0x300 + off), junk ]

-- | BX to the last ROM word (ARM BX r7) or the Thumb BX r7 before it.
trampoline :: Gen [W]
trampoline = do
  thumbSide <- chance 50
  pure [ dpI al 0xf False 0 10 12 0xf0                       -- r10 = 0xffff0fff
       , dpI al 0x2 False 10 10 0 (if thumbSide then 6 else 3)
       , dpI al 0x4 False 15 7 0 0                           -- r7 = the instruction after BX
       , bx 10 ]

-- | Call the local-RAM trampoline (ARM BX lr at the last RAM word, or the
-- Thumb BX lr before it); its prefetch of 0x02001000 has no route.
ramTrampoline :: Gen [W]
ramTrampoline = do
  thumbSide <- chance 50
  pure (addLarge 10 11 (if thumbSide then ramTramp + 3 else ramTramp + 4) ++ [movLrPc, bx 10])

thumbItem :: Int -> Gen [Word16]
thumbItem depth = do
  k <- int 100
  lo <- num 8
  lo2 <- num 8
  lo3 <- num 8
  let rd = if lo == 6 then 5 else lo :: Word16           -- r6 holds the RAM base
  if | k < 14 -> (\op imm -> [shiftL op 11 .|. shiftL imm 6 .|. shiftL lo2 3 .|. rd]) <$> num 3 <*> num 32
     | k < 24 -> (\i op x -> [0x1800 .|. shiftL i 10 .|. shiftL op 9 .|. shiftL x 6 .|. shiftL lo2 3 .|. rd])
                   <$> num 2 <*> num 2 <*> num 8
     | k < 38 -> (\op imm -> [0x2000 .|. shiftL op 11 .|. shiftL rd 8 .|. imm]) <$> num 4 <*> num 256
     | k < 58 -> (\op -> [0x4000 .|. shiftL op 6 .|. shiftL lo2 3 .|. rd]) <$> num 16
     | k < 62 -> (\op -> [0x4400 .|. shiftL op 8 .|. 0x40 .|. shiftL lo3 3 .|. rd]) <$> pick [0, 2]  -- ADD/MOV low, high
     | k < 64 -> (\op -> [0x4400 .|. shiftL op 8 .|. 0x80 .|. shiftL lo2 3 .|. (lo3 `mod` 3)]) <$> pick [0, 2]  -- to r8-r10
     | k < 74 -> (\l imm -> [0x6000 .|. (if l then 0x800 else 0) .|. shiftL imm 6 .|. shiftL 6 3 .|. rd]) <$> chance 50 <*> num 32
     | k < 80 -> (\l imm -> [0x8000 .|. (if l then 0x800 else 0) .|. shiftL imm 6 .|. shiftL 6 3 .|. rd]) <$> chance 50 <*> num 32
     | k < 84 -> pure [0xb40f, 0xbc0f]                                  -- push/pop {r0-r3}
     | k < 90 -> (\toArm -> [blSentinel, if toArm then 0xe800 else 0xf800]) <$> chance 40  -- BL / BLX pair
     | k < 95 && depth < 1 -> do
         n <- int 3
         body <- concat <$> mapM (const (thumbItem (depth + 1))) [0 .. n]
         c <- num 14
         pure ((0xd000 .|. shiftL c 8 .|. (fromIntegral (length body - 1) .&. 0xff)) : body)
     | k < 97 -> pure [0xdf00 .|. lo]                                    -- SWI
     | otherwise -> pure [0x4040 .|. shiftL lo2 3 .|. rd]

-- | Placeholder BL/BLX prefix, resolved by 'resolveCalls' once the pair's
-- position in its Thumb block is known (no other generated Thumb
-- instruction has this encoding).
blSentinel :: Word16
blSentinel = 0xf000

-- | Enter an inline Thumb block with BX or BLX; it returns with BX pc. The
-- block starts word-aligned with a branch over two subroutines that its
-- BL (Thumb) and BLX (ARM) pairs call:
--   +0 mov r6, r11; +2 b +16; +4 adds r0, #1; +6 bx lr;
--   +8 add r1, r1, #1 (ARM); +12 bx lr (ARM); +16 body.
thumbBlock :: Gen [W]
thumbBlock = do
  link <- chance 30
  n <- int 8
  body <- concat <$> mapM (const (thumbItem 0)) [0 .. n]
  let prologue = [0x465e, 0xe005, 0x3001, 0x4770, 0x1001, 0xe281, 0xff1e, 0xe12f]
      hs0 = resolveCalls (prologue ++ body)
      hs1 = if even (length hs0) then hs0 else hs0 ++ [0x46c0]
  pure ([dpI al 0x4 False 15 10 0 1, if link then blx 10 else bx 10] ++ pack16 (hs1 ++ [0x4778, 0x46c0]))

-- | Encode each BL/BLX placeholder pair for its halfword index: BL to the
-- Thumb subroutine at block offset 4, BLX to the ARM one at offset 8.
resolveCalls :: [Word16] -> [Word16]
resolveCalls = go 0
 where
  go :: Int -> [Word16] -> [Word16]
  go i (p : s : rest)
    | p == blSentinel && (s == 0xf800 || s == 0xe800) =
        let base = 2 * i + 4
            off = if s == 0xf800 then 4 - base else 8 - (base .&. complement 3)
        in (0xf000 .|. fromIntegral ((off `shiftR` 12) .&. 0x7ff)) : (s .|. fromIntegral ((off `shiftR` 1) .&. 0x7ff))
             : go (i + 2) rest
  go i (h : rest) = h : go (i + 1) rest
  go _ [] = []

-- | Local-RAM code that rewrites instructions one to three ahead of the
-- store before executing them.
ramBlock :: Gen [W]
ramBlock = do
  thumbSide <- chance 35
  slot <- num 8
  let at = 0x800 + slot * 0x40
  if thumbSide then thumbRam at else armRam at

writeWords :: W -> [W] -> [W]
writeWords at ws = concat [loadConst 10 w ++ [ldstI al True True False False False 11 10 (at + 4 * k)] | (k, w) <- zip [0 ..] ws]

armRam :: W -> Gen [W]
armRam at = do
  useStm <- chance 40
  let lowDp = dataProc [0 .. 7]
  pre <- mapM (const lowDp) [0 .. 1 :: Int]
  newA <- lowDp
  newB <- lowDp
  oldA <- lowDp
  oldB <- lowDp
  post <- mapM (const lowDp) [0 .. 1 :: Int]
  ahead <- int 3
  let tIdx = fromIntegral (length pre + 1 + ahead)
      target = at + 4 * tIdx
      store = if useStm then blockT al False True False False 9 (bit 8 .|. bit 10)   -- stmia r9, {r8, r10}
                        else ldstI al True True False False False 11 8 target
      code = pre ++ [store] ++ replicate ahead nopA ++ [oldA, oldB] ++ post ++ [bx 14]
  pure $ writeWords at code ++ loadConst 8 newA ++ loadConst 10 newB ++ loadConst 9 (ramBase + target)
    ++ addLarge 7 11 at ++ [movLrPc, bx 7]

thumbRam :: W -> Gen [W]
thumbRam at = do
  let lowItem = (\op a b -> 0x4000 .|. shiftL op 6 .|. shiftL a 3 .|. b :: Word16) <$> num 16 <*> num 4 <*> num 4
  pre <- mapM (const lowItem) [0 .. 1 :: Int]
  ahead <- int 3
  oldT <- mapM (const lowItem) [0 .. 2 :: Int]
  newT <- lowItem
  post <- mapM (const lowItem) [0 .. 1 :: Int]
  let tIdx = length pre + 1 + ahead
      hs0 = pre ++ [0x8000 .|. shiftL 4 3 .|. 5] ++ replicate ahead 0x46c0 ++ oldT ++ post ++ [0x4770]  -- strh r5,[r4] .. bx lr
      hs = if even (length hs0) then hs0 else hs0 ++ [0x46c0]
  pure $ writeWords at (pack16 hs) ++ loadConst 5 (fromIntegral newT) ++ loadConst 4 (ramBase + at + 2 * fromIntegral tIdx)
    ++ addLarge 7 11 (at + 1) ++ [movLrPc, bx 7]

-- | Vectors, reset, body, epilogue or final fault; handlers at 0xf00/0xf40;
-- ROM Thumb trampoline at 0xff8 and ARM trampoline at 0xffc; reset also
-- writes the local-RAM trampolines at 'ramTramp'.
program :: Gen [W]
program = do
  inits <- forM dataRegs (\r -> loadConst r <$> word)
  body <- fillBody []
  ending <- int 100
  ldmReturns <- chance 50
  let epilogue
        | ending < 85 = addLarge 9 11 0x400 ++ [blockT al False True False False 9 0x47ff, 0xe10f0000
                                              , ldstI al True True False False False 11 0 0x430, haltW]
        | ending < 89 = [dpI al 0x4 False 15 10 0 2, bx 10, haltW]                    -- misaligned ARM target
        | ending < 93 = [movByte 10 4 8, dpR al 0xd False 0 15 10, haltW]            -- unrouted 0x08000000
        | ending < 96 = [0xe7f000f0, haltW]                                           -- undefined
        | otherwise = [ldstI al True True False False True 12 0 0x3fc, haltW]        -- link reply error
      reset = [ movByte 11 4 2, movByte 12 4 6
              , 0xe321f0d2, dpI al 0x4 False 11 13 14 0xf8            -- IRQ mode: sp = r11 + 0xf80
              , 0xe321f0df, dpI al 0x4 False 11 13 14 0xe0            -- System: sp = r11 + 0xe00
              , 0xe321f0d3, dpI al 0x4 False 11 13 14 0xf0            -- SVC: sp = r11 + 0xf00
              ] ++ writeWords ramTramp [0x477046c0, bx 14]           -- nop; bx lr (Thumb) / bx lr (ARM)
              ++ concat inits ++ [0xe321f013]                         -- SVC, I clear
      mainCode = reset ++ body ++ epilogue
      vectors = [branch al False 8, haltW, branch al False (0x3d0 - 2), haltW, haltW, haltW, branch al False (0x3c0 - 6), haltW]
      image = IM.fromList (zip [0 ..] (replicate 0x400 0)) `IM.union` IM.empty
      placed = foldl' (\m (k, w) -> IM.insert k w m) image
                 (zip [0 ..] vectors ++ zip [8 ..] mainCode ++ zip [0x3c0 ..] (irqHandler ldmReturns)
                  ++ zip [0x3d0 ..] (swiHandler ldmReturns)
                  ++ [(0x3fe, 0x4738 .|. shiftL 0x46c0 16), (0x3ff, bx 7)])
  pure (IM.elems placed)
 where
  fillBody acc = do
    stop <- chance 1
    it <- armItem 0
    let used = sum (map length acc)
    if stop || used + length it > 0x330 then pure (concat (reverse acc)) else fillBody (it : acc)

-- | IRQ handler: log SPSR and R14_irq, acknowledge, return with
-- SUBS pc, lr, #4 or (LDM form) LDMIA sp!, {.., pc}^.
irqHandler :: Bool -> [W]
irqHandler ldmForm
  | ldmForm =
      [ dpI al 0x2 False 14 14 0 4                                 -- sub lr, lr, #4
      , blockT al True False True False 13 0x4003                  -- stmdb sp!, {r0, r1, lr}
      , 0xe14f0000                                                 -- mrs r0, spsr
      , ldstI al True True False False False 11 0 0xfe4
      , ldstI al True True False False False 11 14 0xfe8
      , ldstI al True True False False False 11 0 0xfe0           -- acknowledge ('ackAddr')
      , blockT al False True True True 13 0x8003 .|. bit 22 ]      -- ldmia sp!, {r0, r1, pc}^
  | otherwise =
      [ blockT al True False True False 13 0x3                     -- stmdb sp!, {r0, r1}
      , 0xe14f0000
      , ldstI al True True False False False 11 0 0xfe4
      , ldstI al True True False False False 11 14 0xfe8
      , ldstI al True True False False False 11 0 0xfe0
      , blockT al False True True True 13 0x3                       -- ldmia sp!, {r0, r1}
      , dpI al 0x2 True 14 15 0 4 ]                                 -- subs pc, lr, #4

-- | SWI handler: log R14_svc and SPSR, return with MOVS pc, lr or (LDM
-- form) LDMIA sp!, {r0, pc}^.
swiHandler :: Bool -> [W]
swiHandler ldmForm
  | ldmForm =
      [ ldstI al True True False False False 11 14 0xfd8
      , blockT al True False True False 13 0x4001                  -- stmdb sp!, {r0, lr}
      , 0xe14f0000
      , ldstI al True True False False False 11 0 0xfdc
      , blockT al False True True True 13 0x8001 .|. bit 22 ]      -- ldmia sp!, {r0, pc}^
  | otherwise =
      [ ldstI al True True False False False 11 14 0xfd8
      , blockT al True False True False 13 0x1
      , 0xe14f0000
      , ldstI al True True False False False 11 0 0xfdc
      , blockT al False True True True 13 0x1
      , dpR al 0xd True 0 15 14 ]                                   -- movs pc, lr

-- | The epilogue's final 'b .' (the last halt word before the handlers).
haltAddress :: [W] -> W
haltAddress rom = case [k | (k, w) <- zip [0 :: Int ..] (take 0x3c0 rom), w == haltW, k >= 8] of
  [] -> 0
  ks -> 0xffff0000 + 4 * fromIntegral (last ks)

-- * Running a core

data Model s = Model
  { mInit     :: s
  , mStep     :: s -> SliceIn -> (s, SliceOut)
  , mBoot     :: s -> BitVector 32
  , mEntering :: s -> Bool
  , mMasked   :: s -> Bool
  }

newModel :: Model SliceState
newModel = Model initialSlice sliceStep sliceBootAddr sliceIrqEntering sliceIrqMasked

oldModel :: Model Old.SliceState
oldModel = Model Old.initialSlice Old.sliceStep Old.sliceBootAddr (const False) (const False)

data LinkEv = LinkEv Bool Int W W deriving (Eq, Show)

data Link = LIdle | LWait Int | LReply Int W Bool

-- | IRQ line policy: rises at these cycles and, when the flag is set, in
-- every cycle a Thumb BL/BLX prefix is reported retired (so the IRQ falls
-- between the halves); dropped by the acknowledge store. Or high exactly
-- while the retire count equals the next boundary (the oracle replay).
data Drive = RiseAt [Int] Bool | AtBoundaries [Int]

-- | A Thumb BL/BLX first half (retire opcodes of Thumb instructions are the
-- halfword zero-extended).
isBlPrefix :: W -> Bool
isBlPrefix op = op .&. 0xfffff800 == 0xf000

data Result = Result
  { rRetire  :: [(W, W)]
  , rStores  :: [(W, W)]
  , rLink    :: [LinkEv]
  , rFault   :: Maybe (Int, W)
  , rCycles  :: Int
  , rEntries :: [Int]
  , rErr     :: Maybe String
  , rMaxLat  :: Int
  , rDone    :: Bool
  }

irqBound :: Int
irqBound = 200

cycleCap :: Int
cycleCap = 300000

data Run s = Run
  { tick :: !Int, cpu :: !s, rng :: !Rng, link :: !Link, mem :: !(IM.IntMap W)
  , line :: !Bool, drive :: !Drive, since :: !(Maybe Int), retired :: !Int, halts :: !Int
  , rets :: ![(W, W)], sts :: ![(W, W)], lnk :: ![LinkEv], ents :: ![Int]
  , err :: !(Maybe String), maxLat :: !Int }

runModel :: Model s -> [W] -> Drive -> Rng -> Result
runModel md rom drv0 g0 = loop (Run 0 (mInit md) g0 LIdle IM.empty False drv0 Nothing 0 0 [] [] [] [] Nothing 0)
 where
  romArr = IM.fromList (zip [0 ..] rom)
  haltPc = haltAddress rom
  fetchW :: W -> W
  fetchW a
    | a .&. 0xfffff000 == 0xffff0000 = IM.findWithDefault 0 (fromIntegral ((a - 0xffff0000) `shiftR` 2)) romArr
    | otherwise = 0
  isRise r = case drive r of RiseAt _ _ -> True; _ -> False
  loop r
    | tick r >= cycleCap = result r Nothing False
    | otherwise =
        let t = tick r
            st = cpu r
            boot = fromIntegral (fetchW (fromIntegral (mBoot md st)))
            out0 = snd (mStep md st (SliceIn boot False False 0 False False))
            -- IRQ line this cycle.
            (lineNow, drv1) = case drive r of
              RiseAt rises onBl ->
                let (due, later) = span (<= t) rises
                    blHit = onBl && retireValid out0 && isBlPrefix (fromIntegral (retireOpcode out0))
                in (line r || not (null due) || blHit, RiseAt later onBl)
              AtBoundaries bs@(b : _) -> (retired r == b, AtBoundaries bs)
              AtBoundaries [] -> (False, drive r)
            -- Link target.
            a = fromIntegral (gpuReqAddr out0) :: W
            width = fromIntegral (gpuReqWidth out0) :: Int
            (dAccept, g1) = below 7 (rng r)
            (dReply, g2) = below 7 g1
            (ready, link1, mem1, lnk1, gNext) = case link r of
              LIdle | gpuReqValid out0 && dAccept == 0 -> accept g2
                    | gpuReqValid out0 -> (False, LWait (t + dAccept), mem r, lnk r, g1)
              LWait at | gpuReqValid out0 && t >= at -> accept g1
              l -> (False, l, mem r, lnk r, rng r)
             where
              accept g =
                let wordIx = fromIntegral (a .&. complement 3)
                    old = IM.findWithDefault (linkInit a) wordIx (mem r)
                    m' = if gpuReqWrite out0 then IM.insert wordIx (merge a width (fromIntegral (gpuReqData out0)) old) (mem r) else mem r
                    ev = LinkEv (gpuReqWrite out0) width a (fromIntegral (gpuReqData out0))
                in (True, LReply (t + 1 + dReply) (extract a width old) (a == linkFaultAddr), m', ev : lnk r, g)
            (replyValid, replyData, replyFault) = case link r of
              LReply at v f | t >= at -> (True, v, f)
              _ -> (False, 0, False)
            input = SliceIn boot ready replyValid (fromIntegral replyData) replyFault lineNow
            (st', out) = mStep md st input
            link2 = case link r of
              LReply _ _ _ | replyValid && gpuReplyReady out0 -> LIdle
              _ -> link1
            -- Observed outputs.
            stored = storeValid out
            sAddr = fromIntegral (storeAddr out) :: W
            sts' = if stored then (sAddr, fromIntegral (storeData out)) : sts r else sts r
            retPc = fromIntegral (retirePc out) :: W
            isRet = retireValid out
            rets' = if isRet then (retPc, fromIntegral (retireOpcode out)) : rets r else rets r
            isVector = isRet && retPc == 0xffff0018
            ents' = if isVector then retired r : ents r else ents r
            retired' = if isRet then retired r + 1 else retired r
            halts' = if isRet && retPc == haltPc then halts r + 1 else halts r
            -- IRQ legality (pipelined core, driven by random rises).
            entering = mEntering md st'
            masked = mMasked md st
            since0 = if lineNow && not masked then Just (maybe t id (since r)) else Nothing
            bad msg = Just (printf "%s (cycle %d)" (msg :: String) t)
            err' = err r `orElse`
              (if isRise r && entering && not lineNow then bad "IRQ taken with the line low" else Nothing) `orElse`
              (if isRise r && entering && masked then bad "IRQ taken with CPSR.I set" else Nothing) `orElse`
              (case since0 of
                 Just s0 | isRise r && not entering && t - s0 > irqBound ->
                   Just (printf "IRQ starved: line high with CPSR.I clear since cycle %d, no entry by %d" s0 t)
                 _ -> Nothing)
            maxLat' = case (since0, entering) of
              (Just s0, True) -> max (maxLat r) (t - s0)
              _ -> maxLat r
            line' = lineNow && not (stored && sAddr == ackAddr)
            drv2 = case drv1 of
              AtBoundaries (b : bs) | isVector && retired r == b -> AtBoundaries bs
              _ -> drv1
            r' = r { tick = t + 1, cpu = st', rng = gNext, link = link2, mem = mem1, line = line', drive = drv2
                   , since = if entering then Nothing else since0, retired = retired', halts = halts'
                   , rets = rets', sts = sts', lnk = lnk1, ents = ents', err = err', maxLat = maxLat' }
        in if fault out /= 0 then result r' (Just (fromIntegral (fault out), fromIntegral (faultAddr out))) True
           else if halts' >= 2 then result r' Nothing True
           else loop r'
  result r f ok = Result (reverse (rets r)) (reverse (sts r)) (reverse (lnk r)) f (tick r) (reverse (ents r)) (err r) (maxLat r) ok
  orElse x y = maybe y Just x
  linkInit a = fromIntegral ((a .&. complement 3) * 0x9e3779b1 + 0x7f4a7c15)
  extract a w v = (v `shiftR` (8 * fromIntegral (a .&. 3))) .&. maskW w
  merge a w d old = let sh = 8 * fromIntegral (a .&. 3) in (old .&. complement (shiftL (maskW w) sh)) .|. shiftL (d .&. maskW w) sh
  maskW w = if w >= 4 then 0xffffffff else shiftL 1 (8 * w) - 1 :: W

-- | One seed: generate, run the pipelined core with random IRQ rises (and,
-- in half the seeds, an IRQ at every Thumb BL/BLX prefix), then the oracle
-- with the same IRQ boundaries; compare.
checkSeed :: Int -> (Maybe String, Result, Result, [W])
checkSeed seed = (verdict, new, old, rom)
 where
  g0 = Rng (fromIntegral seed * 0x2545f4914f6cdd1d + 0x1234567)
  (rom, g1) = runGen program g0
  (nRises, g2) = below 9 g1
  ((rises, onBl), g3) = runGen ((,) <$> mapM (const (int 2500)) [1 .. nRises] <*> chance 50) g2
  new = runModel newModel rom (RiseAt (sort rises) onBl) g3
  old = runModel oldModel rom (AtBoundaries (rEntries new)) (snd (next64 (snd (next64 g3))))
  verdict
    | Just e <- rErr new = Just e
    | not (rDone new) = Just "pipelined core neither halted nor faulted"
    | not (rDone old) = Just "oracle neither halted nor faulted"
    | rFault new /= rFault old = Just (printf "fault: pipelined %s, oracle %s" (show (rFault new)) (show (rFault old)))
    | rRetire new /= rRetire old = Just ("retire stream differs at " ++ firstDiff (rRetire new) (rRetire old))
    | rStores new /= rStores old = Just ("store stream differs at " ++ firstDiff (rStores new) (rStores old))
    | rLink new /= rLink old = Just ("link stream differs at " ++ firstDiff (rLink new) (rLink old))
    | rEntries new /= rEntries old = Just (printf "IRQ boundaries: pipelined %s, oracle %s" (show (rEntries new)) (show (rEntries old)))
    | otherwise = Nothing

firstDiff :: Show a => [a] -> [a] -> String
firstDiff xs ys = go (0 :: Int) xs ys
 where
  go k (x : xt) (y : yt) | show x == show y = go (k + 1) xt yt
                         | otherwise = printf "%d: pipelined %s, oracle %s" k (show x) (show y)
  go k (x : _) [] = printf "%d: pipelined %s, oracle ended" k (show x)
  go k [] (y : _) = printf "%d: pipelined ended, oracle %s" k (show y)
  go _ [] [] = "?"

-- | Failure detail for one seed: the ROM image (for objdump), both faults
-- and IRQ boundaries, and the retire streams around the first difference.
showSeed :: Int -> FilePath -> IO ()
showSeed seed romOut = do
  let (verdict, new, old, rom) = checkSeed seed
  BL.writeFile romOut (BB.toLazyByteString (foldMap BB.word32LE rom))
  printf "verdict: %s\n" (maybe "pass" id verdict)
  printf "pipelined: %d cycles, fault %s, IRQs at %s\n" (rCycles new) (show (rFault new)) (show (rEntries new))
  printf "oracle:    %d cycles, fault %s, IRQs at %s\n" (rCycles old) (show (rFault old)) (show (rEntries old))
  let n = length (takeWhile id (zipWith (==) (rRetire new) (rRetire old)))
      window xs = take 24 (drop (n - 12) (zip [0 :: Int ..] xs))
      line (k, (pc, op)) = printf "  %5d %08x %08x\n" k pc op :: IO ()
  printf "retire streams from %d (first difference at %d):\npipelined\n" (max 0 (n - 12)) n
  mapM_ line (window (rRetire new))
  putStrLn "oracle"
  mapM_ line (window (rRetire old))
  printf "stores: pipelined %d, oracle %d; last pipelined %s\n" (length (rStores new)) (length (rStores old))
    (show (take 4 (reverse (rStores new))))

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--show", s, romOut] -> showSeed (read s) romOut
    _ -> batch args

data Stats = Stats
  { sFails, sRetired, sCycles, sIrqs, sSplits, sBlPairs, sRamRetired, sFaults, sLat :: !Int }

batch :: [String] -> IO ()
batch args = do
  let (first, count) = case args of
        [a, b] -> (read a, read b)
        [a] -> (read a, 200)
        _ -> (1, 200 :: Int)
      step s seed = do
        let (verdict, res, _, _) = checkSeed seed
            retires = rRetire res
            ops = IM.fromList (zip [0 ..] (map snd retires))
            splits = length [() | i <- rEntries res, i > 0, maybe False isBlPrefix (IM.lookup (i - 1) ops)]
        case verdict of
          Just e -> printf "FAIL seed %d: %s\n" seed e
          Nothing -> pure ()
        let !s' = Stats
              { sFails = sFails s + maybe 0 (const 1) verdict, sRetired = sRetired s + length retires
              , sCycles = sCycles s + rCycles res, sIrqs = sIrqs s + length (rEntries res)
              , sSplits = sSplits s + splits, sBlPairs = sBlPairs s + length (filter (isBlPrefix . snd) retires)
              , sRamRetired = sRamRetired s + length (filter ((== ramBase) . (.&. 0xfffff000) . fst) retires)
              , sFaults = sFaults s + maybe 0 (const 1) (rFault res), sLat = max (sLat s) (rMaxLat res) }
        pure s'
  s <- foldM step (Stats 0 0 0 0 0 0 0 0 0) [first .. first + count - 1]
  printf "%d seeds, %d failed; %d instructions retired in %d pipelined cycles (%d from local RAM, %d Thumb BL/BLX pairs); %d IRQs taken (%d between BL/BLX halves), worst latency %d cycles (bound %d); %d seeds end in a fault\n"
    count (sFails s) (sRetired s) (sCycles s) (sRamRetired s) (sBlPairs s) (sIrqs s) (sSplits s) (sLat s) irqBound (sFaults s)
  -- A full batch must actually exercise the cases it exists for.
  let uncovered = [what | (what, n) <- [("IRQ between BL/BLX halves", sSplits s), ("code in local RAM", sRamRetired s)], n == 0]
  when (count >= 100 && not (null uncovered)) $ printf "FAIL coverage: no %s\n" (unwords uncovered)
  when (sFails s > 0 || (count >= 100 && not (null uncovered))) exitFailure
