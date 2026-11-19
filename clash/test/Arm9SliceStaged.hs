-- SPDX-License-Identifier: GPL-3.0-or-later
-- | Frozen copy of the non-overlapped staged ARM9 slice step (commit
-- fbb32bd, Nds.WholeCore.Arm9Slice at that revision), kept as the oracle
-- for the pipelined slice's randomized differential test
-- (test/Arm9PipeDiff.hs). Only the module header, the shared SliceIn/SliceOut
-- types, the synthesis tops and the link spans ('linkOwns', kept equal to
-- the product slice's) differ from that revision. Change nothing else.
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric, FlexibleContexts #-}
{-# LANGUAGE TypeApplications #-}

-- | First ARM9/SoC slice: an ARMv5 ARM and Thumb subset with architected
-- predication, NZCV flags, data processing, branches and interworking,
-- multiplies and CLZ, User/System/SVC/IRQ modes with banked R13/R14, IRQ
-- and SWI exception entry/return, plus a boot ROM port, a 4 KiB
-- byte-enabled local RAM that code can execute from, and a blocking GPU bus
-- master.
--
-- Microarchitecture. The general registers, the banked R13/R14 and the two
-- SPSRs live in a 32-row register file held in two block RAMs (one write
-- port, two synchronous read ports); the PC and CPSR fields are registers.
-- An instruction is a token that moves through stages, each a function
-- from its own input record to its own output record with a valid bit:
--
--   fetch -> [expand, Thumb only] -> decode -> shift -> alu -> [mem] -> retire
--
-- Decode classifies the (Thumb-expanded) ARM opcode and presents register
-- reads; shift runs the one barrel shifter on operand 2; alu runs the one
-- adder/logic unit, the condition check, flags and the register write, and
-- starts the memory, multiply-accumulate, writeback or exception-link work
-- that the mem stage sequences. This revision runs exactly one token at a
-- time (fetch waits for the pipe to drain), so there is no forwarding or
-- hazard logic; no stage reads another stage's pipeline register.
module Arm9SliceStaged
  ( SliceState, initialSlice, sliceBootAddr, sliceStep
  ) where

import Nds.WholeCore.Arm9Slice (SliceIn(..), SliceOut(..))

import Prelude ()
import Clash.Prelude hiding (Word, slice)
import qualified Clash.Prelude as C
import qualified Clash.Explicit.Prelude as E
import Data.Maybe (fromMaybe, isJust)

type Word = BitVector 32
type Width = BitVector 3
type RamIndex = Index 1024

-- | Register-file row: R0-R12 at 0-12; R13/R14 at 13/14 (User/System),
-- 17/18 (SVC), 21/22 (IRQ); SPSR_svc at 25, SPSR_irq at 26. R15 is never
-- stored: a read of R15 takes the stage's PC value.
type Row = Index 32

data Access = Access
  { accessAddr   :: Word
  , accessWidth  :: Width
  , accessWrite  :: Bool
  , accessSigned :: Bool
  , accessReg    :: Index 16
  , accessData   :: Word
  } deriving (Generic, NFDataX)

-- | The one architecture switch. This slice is built as the DS ARM9
-- (ARM946E-S: ARMv5TE, exception vectors and boot at 0xFFFF0000). Every
-- ARMv5-only behaviour tests 'armV5' — BLX (register, immediate, Thumb
-- suffix), CLZ, and interworking on loads to PC (LDR pc, LDM/POP {pc}) —
-- and every vector address derives from 'vectorBase', so an ARMv4T
-- (ARM7TDMI, vectors at 0) configuration would change only this record.
-- That configuration is not built or tested.
data Arch = Arch
  { armV5      :: Bool
  , vectorBase :: Word
  }

arch :: Arch
arch = Arch { armV5 = True, vectorBase = 0xffff0000 }

bootBase, ramBase, irqVector, swiVector :: Word
bootBase = vectorBase arch    -- reset vector: the boot ROM window starts here
ramBase = 0x02000000
irqVector = vectorBase arch + 0x18
swiVector = vectorBase arch + 0x08

-- * State

-- | Architectural registers kept in flip-flops: PC (the next instruction to
-- fetch) and the CPSR fields.
data Psr = Psr
  { pc      :: Word
  , flags   :: BitVector 4    -- ^ NZCV
  , irqMask :: Bool           -- ^ CPSR.I
  , fiqMask :: Bool           -- ^ CPSR.F (stored; there is no FIQ source)
  , thumb   :: Bool           -- ^ CPSR.T
  , mode    :: BitVector 5    -- ^ User 0x10, IRQ 0x12, SVC 0x13, System 0x1F
  } deriving (Generic, NFDataX)

-- | Identity of an instruction, carried by its token to retirement.
data Tag = Tag
  { tagPc    :: Word
  , tagOp    :: Word          -- ^ ARM word, or the Thumb halfword zero-extended
  , tagThumb :: Bool
  } deriving (Generic, NFDataX)

-- | Thumb forms that are not rewritten into an ARM opcode, plus the
-- PC-relative forms whose R15 reads word-aligned.
data Aux = AuxArm | AuxWordPc | AuxBranch | AuxBlPrefix | AuxBlSuffix | AuxBlxSuffix | AuxUndef
  deriving (Eq, Generic, NFDataX)

-- | Fetch/expand -> decode token.
data IrTok = IrTok
  { irTag  :: Tag
  , irOp   :: Word            -- ^ ARM opcode (Thumb: the equivalent ARM opcode)
  , irAux  :: Aux
  , irCond :: BitVector 4
  , irImm  :: Word            -- ^ Thumb branch offset
  } deriving (Generic, NFDataX)

data Cls = CDp | CMrs | CMsr | CClz | CMul | CMulLong | CBranch | CBx | CLinkOnly
  | CSingle | CBlock | CSwi | CUndef
  deriving (Eq, Generic, NFDataX)

-- | Decode -> shift token.
data DecTok = DecTok
  { dTag    :: Tag
  , dOp     :: Word
  , dCls    :: Cls
  , dCond   :: BitVector 4
  , dPcRead :: Word           -- ^ value of R15 as an operand
  , dImm    :: Word           -- ^ immediate operand 2 (before shifting)
  , dBImm   :: Bool           -- ^ operand 2 is 'dImm'
  , dA15    :: Bool           -- ^ operand 1 is 'dPcRead'
  , dB15    :: Bool           -- ^ operand 2 register is R15
  , dLink   :: Bool           -- ^ branch writes R14
  , dSetT   :: Maybe Bool     -- ^ branch sets T (Nothing: keeps it)
  , dAlign4 :: Bool           -- ^ branch target rounded to a word (Thumb BLX suffix)
  } deriving (Generic, NFDataX)

-- | Shift -> ALU token.
data ShTok = ShTok
  { sDec   :: DecTok
  , sA     :: Word
  , sB     :: Word
  , sCarry :: Bool            -- ^ shifter carry-out
  } deriving (Generic, NFDataX)

data MPhase = MRoute | MBoot | MLocal | MRam | MOffer | MAwait | MCheck | MBeat
  | MWriteBack | MRestore | MMulAcc | MMulHi | MSwiLink
  deriving (Eq, Generic, NFDataX)

-- | Mem stage: everything after the ALU that takes more than one cycle.
data MemSt = MemSt
  { mPhase     :: MPhase
  , mTag       :: Tag
  , mNext      :: Word          -- ^ next PC (a load to R15 replaces it)
  , pending    :: Access
  , blockLeft  :: BitVector 16  -- ^ LDM/STM registers still to transfer, current beat included
  , blockAddr  :: Word
  , blockStore :: Bool
  , checkLeft  :: BitVector 16  -- ^ LDM/STM beats still to route-check
  , checkAddr  :: Word
  , writeBack  :: Bool          -- ^ base writeback when the transfer completes
  , wbReg      :: Index 16
  , wbValue    :: Word          -- ^ also the high word of a long multiply
  , blockSpsr  :: Bool          -- ^ LDM {.., pc}^
  , restore    :: Bool          -- ^ CPSR <- SPSR once PC is loaded
  , mulOp      :: Word          -- ^ multiply opcode (destinations, S, long)
  , mulProd    :: BitVector 64
  } deriving (Generic, NFDataX)

data RetTok = RetTok { rTag :: Tag, rNext :: Word }
  deriving (Generic, NFDataX)

data FPhase = FIdle | FRam | FWord | FIrqLink
  deriving (Eq, Generic, NFDataX)

data Cpu = Cpu
  { psr       :: Psr
  , fphase    :: FPhase
  , xq        :: Maybe Tag                 -- ^ Thumb halfword awaiting expansion
  , iq        :: Maybe IrTok               -- ^ awaiting decode
  , dq        :: Maybe DecTok              -- ^ awaiting shift
  , shLatch   :: Maybe (Word, BitVector 8) -- ^ register shift: Rn and Rs read in the first shift cycle
  , sq        :: Maybe ShTok               -- ^ awaiting ALU
  , mq        :: Maybe MemSt
  , rq        :: Maybe RetTok
  , storeObs  :: Maybe (Word, Word)        -- ^ local RAM store written last cycle
  , faultCode :: BitVector 3
  , faultAt   :: Word
  } deriving (Generic, NFDataX)

-- | Reset: SVC mode, ARM state, IRQ and FIQ masked (CPSR 0x000000d3).
initialCpu :: Cpu
initialCpu = Cpu (Psr bootBase 0 True True False 0x13) FIdle Nothing Nothing Nothing Nothing
  Nothing Nothing Nothing Nothing 0 0

-- | One cycle's effects besides the next CPU state. Each RAM has one write
-- port; the register file has two read ports.
data Step = Step
  { stepCpu   :: Cpu
  , ramWrite  :: Maybe (RamIndex, Word)
  , regWrite  :: Maybe (Row, Word)
  , readA     :: Maybe Row
  , readB     :: Maybe Row
  } deriving (Generic, NFDataX)

-- | The pure harness models both synchronous RAMs (local RAM and its read
-- register; register file and its two read registers); the generated top
-- uses block RAMs. Both call the same transition and observer. Both
-- register-file copies power up zero.
data SliceState = SliceState Cpu (Vec 1024 Word) Word (Vec 32 Word) Word Word
  deriving (Generic, NFDataX)

initialSlice :: SliceState
initialSlice = SliceState initialCpu (repeat 0) 0 (repeat 0) 0 0

-- | CPU/link reset does not clear block RAM (local RAM or register file).
-- Reset both endpoints of the GPU link together; a reply from before reset
-- must not be re-presented.
resetSlice :: SliceState -> SliceState
resetSlice (SliceState _ mem _ rf _ _) = SliceState initialCpu mem 0 rf 0 0

sliceBootAddr :: SliceState -> Word
sliceBootAddr (SliceState s _ _ _ _ _) = romAddress s

-- | One clock. The output depends only on the current state, so a host may
-- feed it back combinationally into this cycle's input (Arm9Soc does). The
-- next state is strict: matching it (the following call) checks that the
-- register file was not read and written at the same row in this cycle
-- (the block RAM's read-during-write result is then irrelevant; a
-- violation is a model error and fails every pure gate) and forces the CPU
-- record, the written RAM words and the read registers, so a long pure run
-- holds one state, not a chain of unevaluated 'replace's.
sliceStep :: SliceState -> SliceIn -> (SliceState, SliceOut)
sliceStep (SliceState s mem readWord rf ra rb) i = (next, observe s)
 where
  next
    | clash readA || clash readB = error "Arm9Slice: register file row read and written in one cycle"
    | otherwise = rnfX cpu' `seq` written mem' (ramWrite st) `seq` written rf' (regWrite st)
        `seq` word' `seq` ra' `seq` rb' `seq` SliceState cpu' mem' word' rf' ra' rb'
  st = transition s i readWord ra rb
  cpu' = stepCpu st
  mem' = maybe mem (\(addr, value) -> replace addr value mem) (ramWrite st)
  rf' = maybe rf (\(row, value) -> replace row value rf) (regWrite st)
  word' = mem !! ramAddress s
  ra' = rf !! port readA
  rb' = rf !! port readB
  written :: (KnownNat n, Enum k) => Vec n Word -> Maybe (k, Word) -> ()
  written v = maybe () (\(k, _) -> (v !! k) `seq` ())
  port f = fromMaybe 0 (f st)
  clash f = case (f st, regWrite st) of
    (Just r, Just (w, _)) -> r == w
    _ -> False

romAddress :: Cpu -> Word
romAddress s = case mq s of
  Just m | mPhase m == MBoot -> accessAddr (pending m)
  _ -> pc (psr s)

-- | The local RAM port serves a RAM fetch and the mem stage.
ramAddress :: Cpu -> RamIndex
ramAddress s = fromIntegral (C.slice d11 d2 addr)
 where
  addr = case (fphase s, mq s) of
    (FRam, _) -> pc (psr s)
    (_, Just m) -> accessAddr (pending m)
    _ -> pc (psr s)

-- * Memory helpers

-- 4 KiB boot ROM window; 4 KiB local RAM, which instructions may also be
-- fetched from.
inBoot, inRam :: Word -> Bool
inBoot addr = addr .&. 0xfffff000 == bootBase
inRam addr = addr .&. 0xfffff000 == ramBase

laneShift :: Word -> Int
laneShift addr = fromIntegral (C.slice d1 d0 addr ++# (0 :: BitVector 3))

widthMask :: Width -> Word
widthMask width = case width of
  1 -> 0xff
  2 -> 0xffff
  _ -> 0xffffffff

byteLanes :: Access -> BitVector 4
byteLanes a = shiftL low (fromIntegral (C.slice d1 d0 (accessAddr a)))
 where
  low = case accessWidth a of
    1 -> 0x1
    2 -> 0x3
    _ -> 0xf

extract :: Access -> Word -> Word
extract a value = shiftR value (laneShift (accessAddr a)) .&. widthMask (accessWidth a)

mergeStore :: Access -> Word -> Word
mergeStore a old = (old .&. complement laneMask) .|. shiftL (accessData a) offset
 where
  offset = laneShift (accessAddr a)
  laneMask = shiftL (widthMask (accessWidth a)) offset

aligned :: Access -> Bool
aligned a = case accessWidth a of
  1 -> True
  2 -> not (testBit (accessAddr a) 0)
  _ -> accessAddr a .&. 3 == 0

-- | Spans the link owns: the GPU target's registers, palettes, VRAM and
-- OAM, plus the timer, IRQ and game-card registers that devices in front of
-- the GPU (Arm9Io, Card) may decode. The target behind the link must reply
-- with an error for anything here it does not implement. Each access must
-- lie wholly inside one span, so a word covering VRAMCNT_G and WRAMCNT never
-- leaves the slice.
linkOwns :: Access -> Bool
linkOwns a = C.slice d31 d24 addr == 0x06
  -- DISPCNT, DISPSTAT; VCOUNT (0x04000006) is read-only
  || within 0x04000000 (if accessWrite a then 0x04000006 else 0x04000008)
  || within 0x04000008 0x04000070  -- engine A BGCNT, scroll, window, blend
  || within 0x04000100 0x04000110  -- TM0CNT..TM3CNT
  || within 0x040001a0 0x040001a2  -- AUXSPICNT (AUXSPIDATA is not routed)
  || within 0x040001a4 0x040001b0  -- ROMCTRL, game-card command bytes
  || within 0x04000208 0x0400020c  -- IME
  || within 0x04000210 0x04000218  -- IE, IF
  || (addr == 0x04000304 && width /= 1)
  || within 0x04000240 0x04000247
  || within 0x04000248 0x0400024a
  || within 0x04001000 0x04001070  -- engine B display registers
  || within 0x04100010 0x04100014  -- game-card data in
  || within 0x05000000 0x05000800  -- palettes
  || within 0x07000000 0x07000800  -- OAM
 where
  addr = accessAddr a
  width = resize (accessWidth a) :: Word
  within lo hi = addr >= lo && addr <= hi - width

-- | Fault code, or the mem phase that serves the access.
routeTo :: Access -> Either (BitVector 3) MPhase
routeTo a
  | not (aligned a) = Left 2
  | inBoot addr && not (accessWrite a) = Right MBoot
  | inRam addr = Right MLocal
  | linkOwns a = Right MOffer
  | otherwise = Left 3
 where addr = accessAddr a

-- | LDM/STM beats serve only the boot ROM and local RAM. The link stays
-- single-transfer: a block whose beat would reach it faults 3 at that beat's
-- address, like any other address with no route, before the first beat.
blockFault :: Bool -> Word -> BitVector 3
blockFault store addr = case routeTo (Access addr 4 store False 0 0) of
  Left code -> code
  Right MOffer -> 3
  Right _ -> 0

lowestReg :: BitVector 16 -> Index 16
lowestReg l = maybe 0 id (findIndex id (reverse (unpack l :: Vec 16 Bool)))

observe :: Cpu -> SliceOut
observe s = SliceOut
  { bootAddr = romAddress s
  , gpuReqValid = offer
  , gpuReqWrite = offer && accessWrite a
  , gpuReqAddr = if offer then accessAddr a else 0
  , gpuReqWidth = if offer then accessWidth a else 0
  , gpuReqLanes = if offer then byteLanes a else 0
  , gpuReqData = if offer then accessData a else 0
  , gpuReplyReady = phaseIs MAwait
  , storeValid = isJust (storeObs s)
  , storeAddr = maybe 0 fst (storeObs s)
  , storeData = maybe 0 snd (storeObs s)
  , fault = faultCode s
  , faultAddr = faultAt s
  , retireValid = isJust (rq s)
  , retirePc = maybe 0 (tagPc . rTag) (rq s)
  , retireOpcode = maybe 0 (tagOp . rTag) (rq s)
  }
 where
  phaseIs p = maybe False ((== p) . mPhase) (mq s)
  offer = phaseIs MOffer
  a = maybe (Access 0 4 False False 0 0) pending (mq s)

-- * Modes and the register file

-- | Instruction size in a state.
stepOf :: Bool -> Word
stepOf t = if t then 2 else 4

-- | CPSR as MRS reads it: NZCV, I, F, T and the mode.
cpsrWord :: Psr -> Word
cpsrWord s = flags s ++# (0 :: BitVector 20) ++# pack (irqMask s) ++# pack (fiqMask s)
  ++# pack (thumb s) ++# mode s

-- | Modes in the subset: User, IRQ, SVC and System. FIQ, abort and
-- undefined are not, so a CPSR naming them is refused.
validMode, hasSpsr :: BitVector 5 -> Bool
validMode m = m == 0x10 || m == 0x12 || m == 0x13 || m == 0x1f
hasSpsr m = m == 0x12 || m == 0x13

-- | R13/R14 bank: User and System share one.
bankOf :: BitVector 5 -> Index 3
bankOf m = case m of
  0x13 -> 1
  0x12 -> 2
  _ -> 0

regRow :: BitVector 5 -> Index 16 -> Row
regRow m r
  | r < 13 = fromIntegral r
  | otherwise = fromIntegral r + 4 * fromIntegral (bankOf m)

spsrRow :: BitVector 5 -> Row
spsrRow m = if m == 0x12 then 26 else 25

-- | Write a whole CPSR. The Q, J and reserved bits must be clear and the
-- mode in the subset; T may change only on an exception return. The banks
-- follow the mode through 'regRow'.
setCpsr :: Bool -> Word -> Psr -> Maybe Psr
setCpsr allowT w s
  | C.slice d27 d8 w /= 0 || (testBit w 5 /= thumb s && not allowT) = Nothing
  | not (validMode m) = Nothing
  | otherwise = Just s { flags = C.slice d31 d28 w, irqMask = testBit w 7, fiqMask = testBit w 6
                       , thumb = testBit w 5, mode = m }
 where m = C.slice d4 d0 w

-- | Exception entry: ARM state in the new mode with I set and F kept.
-- SPSR_<mode> <- the old CPSR and R14_<mode> are separate register-file
-- writes made by the caller.
enterMode :: BitVector 5 -> Psr -> Psr
enterMode m s = s { mode = m, irqMask = True, thumb = False }

-- | ARM condition field against NZCV (bit 3 = N ... bit 0 = V).
condPasses :: BitVector 4 -> BitVector 4 -> Bool
condPasses cond nzcv = case cond of
  0x0 -> z
  0x1 -> not z
  0x2 -> c
  0x3 -> not c
  0x4 -> n
  0x5 -> not n
  0x6 -> v
  0x7 -> not v
  0x8 -> c && not z
  0x9 -> not c || z
  0xa -> n == v
  0xb -> n /= v
  0xc -> not z && n == v
  0xd -> z || n /= v
  _   -> True
 where
  n = testBit nzcv 3
  z = testBit nzcv 2
  c = testBit nzcv 1
  v = testBit nzcv 0

-- * Datapath units (one instance each)

-- | The barrel shifter: kind 0 LSL, 1 LSR, 2 ASR, 3 ROR by an 8-bit amount
-- (register shifts and rotated immediates), or with immediate-shift
-- encoding when 'immForm' (LSR/ASR #0 mean #32, ROR #0 is RRX). Amount 0
-- passes the operand and carry through unchanged.
barrel :: BitVector 2 -> BitVector 8 -> Bool -> Bool -> Word -> (Word, Bool)
barrel kind amount0 immForm carry rm
  | rrx = (pack carry ++# C.slice d31 d1 rm, testBit rm 0)
  | amount == 0 = (rm, carry)
  | otherwise = case kind of
      0 -> let y = shiftL (0 ++# rm :: BitVector 33) n in (C.slice d31 d0 y, testBit y 32)
      1 -> let y = shiftR (rm ++# 0 :: BitVector 33) n in (C.slice d32 d1 y, testBit y 0)
      2 -> let y = pack (shiftR (unpack (rm ++# 0) :: Signed 33) (min n 32))
           in (C.slice d32 d1 y, testBit y 0)
      _ -> let r = rotateR rm (fromIntegral (C.slice d4 d0 amount)) in (r, testBit r 31)
 where
  zeroImm = immForm && amount0 == 0
  rrx = zeroImm && kind == 3
  amount = if zeroImm && (kind == 1 || kind == 2) then 32 else amount0
  n = fromIntegral amount :: Int

-- | Result, carry, overflow and whether the opcode is arithmetic (writes V).
aluOp :: BitVector 4 -> Bool -> Bool -> Word -> Word -> (Word, Bool, Bool, Bool)
aluOp opc carry shifterCarry a b = case opc of
  0x0 -> logic (a .&. b)
  0x1 -> logic (xor a b)
  0x8 -> logic (a .&. b)
  0x9 -> logic (xor a b)
  0xc -> logic (a .|. b)
  0xd -> logic b
  0xe -> logic (a .&. complement b)
  0xf -> logic (complement b)
  _   -> (r, testBit total 32, msb x == msb y && msb r /= msb x, True)
 where
  logic v = (v, shifterCarry, False, False)
  -- One adder: SUB/CMP a-b, RSB b-a, ADD/CMN a+b, ADC, SBC, RSC.
  (x, y, cin) = case opc of
    0x2 -> (a, complement b, True)
    0x3 -> (b, complement a, True)
    0x5 -> (a, b, carry)
    0x6 -> (a, complement b, carry)
    0x7 -> (b, complement a, carry)
    0xa -> (a, complement b, True)
    _   -> (a, b, False)
  total = (0 ++# x) + (0 ++# y) + (if cin then 1 else 0) :: BitVector 33
  r = C.slice d31 d0 total

-- | Count of leading zero bits (CLZ): 32 for zero. Five mux levels.
leadingZeros :: Word -> Word
leadingZeros w
  | w == 0 = 32
  | otherwise = zeroExtend (pack (z16, z8, z4, z2, z1))
 where
  z16 = C.slice d31 d16 w == 0
  w1 = if z16 then shiftL w 16 else w
  z8 = C.slice d31 d24 w1 == 0
  w2 = if z8 then shiftL w1 8 else w1
  z4 = C.slice d31 d28 w2 == 0
  w3 = if z4 then shiftL w2 4 else w2
  z2 = C.slice d31 d30 w3 == 0
  w4 = if z2 then shiftL w3 2 else w3
  z1 = not (testBit w4 31)

-- | Sign-extended B/BL/BLX word displacement in bytes.
armDisplacement :: Word -> Word
armDisplacement op = pack (resize (unpack (C.slice d23 d0 op ++# (0 :: BitVector 2)) :: Signed 26) :: Signed 32)

-- * Stages

-- | Thumb expand stage. Every ARMv5T format except the branches is
-- rewritten into the equivalent AL-condition ARM opcode, so Thumb shares
-- the ARM decode, shifter, ALU, flags, link, LDM/STM precheck and fault
-- rules. B<cond>, B and the BL/BLX halves carry their offset; BKPT, the
-- undefined B<cond> space and ARMv6 forms are 'AuxUndef'.
expandStage :: Tag -> IrTok
expandStage tag = case top5 of
  0x00 -> arm (shiftImm' 0)
  0x01 -> arm (shiftImm' 1)
  0x02 -> arm (shiftImm' 2)
  0x03 -> arm (dp (if testBit t 9 then 2 else 4) (testBit t 10) True lo3 lo0 (zeroExtend lo6))
  0x04 -> arm (dp 0xd True True 0 hi8 imm12)
  0x05 -> arm (dp 0xa True True hi8 0 imm12)
  0x06 -> arm (dp 0x4 True True hi8 hi8 imm12)
  0x07 -> arm (dp 0x2 True True hi8 hi8 imm12)
  0x08 | not (testBit t 10) -> arm alu
       | otherwise -> hiOps
  0x09 -> wordPc (0xe59f0000 .|. reg12 hi8 .|. shiftL (zeroExtend imm8) 2)
  0x0a -> arm (regTransfer False)
  0x0b -> arm (regTransfer True)
  0x0c -> arm (0xe5800000 .|. base3 .|. reg12 lo0 .|. shiftL (zeroExtend imm5) 2)
  0x0d -> arm (0xe5900000 .|. base3 .|. reg12 lo0 .|. shiftL (zeroExtend imm5) 2)
  0x0e -> arm (0xe5c00000 .|. base3 .|. reg12 lo0 .|. zeroExtend imm5)
  0x0f -> arm (0xe5d00000 .|. base3 .|. reg12 lo0 .|. zeroExtend imm5)
  0x10 -> arm (halfImm False)
  0x11 -> arm (halfImm True)
  0x12 -> arm (0xe58d0000 .|. reg12 hi8 .|. shiftL (zeroExtend imm8) 2)
  0x13 -> arm (0xe59d0000 .|. reg12 hi8 .|. shiftL (zeroExtend imm8) 2)
  0x14 -> wordPc (dp 0x4 True False 15 hi8 (0xf00 .|. imm12))
  0x15 -> arm (dp 0x4 True False 13 hi8 (0xf00 .|. imm12))
  0x16 | C.slice d10 d8 t == 0 ->
           arm (dp (if testBit t 7 then 2 else 4) True False 13 13 (0xf00 .|. zeroExtend (C.slice d6 d0 t)))
       | C.slice d10 d9 t == 2 ->
           arm (0xe92d0000 .|. (if testBit t 8 then bit 14 else 0) .|. zeroExtend imm8)
       | otherwise -> undef
  0x17 | C.slice d10 d9 t == 2 ->
           arm (0xe8bd0000 .|. (if testBit t 8 then bit 15 else 0) .|. zeroExtend imm8)
       | otherwise -> undef
  0x18 -> arm (0xe8a00000 .|. reg16 hi8 .|. zeroExtend imm8)
  -- LDMIA with the base in the list keeps the loaded value: no writeback.
  0x19 -> arm (0xe8900000 .|. (if testBit imm8 (fromIntegral hi8) then 0 else bit 21)
                .|. reg16 hi8 .|. zeroExtend imm8)
  0x1a -> branchCond
  0x1b -> branchCond
  0x1c -> special AuxBranch 0xe (sext 12 (C.slice d10 d0 t ++# (0 :: BitVector 1)))
  -- BLX suffix: to ARM at (R14 + offset) & ~3; bit 0 of the offset must be 0.
  0x1d | armV5 arch && not (testBit t 0) -> special AuxBlxSuffix 0xe suffix
       | otherwise -> undef
  -- BL/BLX prefix: R14 <- pc + 4 + (offset << 12).
  0x1e -> special AuxBlPrefix 0xe (shiftL (sext 11 (zeroExtend (C.slice d10 d0 t))) 12)
  _ -> special AuxBlSuffix 0xe suffix
 where
  t = C.slice d15 d0 (tagOp tag)
  top5 = C.slice d15 d11 t
  arm x = IrTok tag x AuxArm 0xe 0
  wordPc x = IrTok tag x AuxWordPc 0xe 0
  special aux cond imm = IrTok tag 0 aux cond imm
  undef = IrTok tag 0 AuxUndef 0xe 0
  suffix = shiftL (zeroExtend (C.slice d10 d0 t)) 1 :: Word
  sext :: Int -> BitVector 12 -> Word
  sext n v = let w = zeroExtend v :: Word in if testBit w (n - 1) then w .|. shiftL 0xffffffff n else w
  lo0 = zeroExtend (C.slice d2 d0 t) :: BitVector 4
  lo3 = zeroExtend (C.slice d5 d3 t) :: BitVector 4
  lo6 = C.slice d8 d6 t
  hi8 = zeroExtend (C.slice d10 d8 t) :: BitVector 4
  imm8 = C.slice d7 d0 t
  imm12 = zeroExtend imm8 :: BitVector 12
  imm5 = C.slice d10 d6 t
  reg12 r = shiftL (zeroExtend r :: Word) 12
  reg16 r = shiftL (zeroExtend r :: Word) 16
  base3 = reg16 lo3
  dp :: BitVector 4 -> Bool -> Bool -> BitVector 4 -> BitVector 4 -> BitVector 12 -> Word
  dp opc imm sflag rn rd op2 = 0xe0000000 .|. (if imm then bit 25 else 0)
    .|. shiftL (zeroExtend opc) 21 .|. (if sflag then bit 20 else 0)
    .|. reg16 rn .|. reg12 rd .|. zeroExtend op2
  -- LSL/LSR/ASR Rd, Rm, #imm5: MOVS Rd, Rm, <shift> #imm5.
  shiftImm' sh = dp 0xd False True 0 lo0 (imm5 ++# (sh :: BitVector 2) ++# (0 :: BitVector 1) ++# C.slice d3 d0 lo3)
  -- The 16 ALU operations on Rd, Rm; shifts by register and MUL included.
  aluSel = C.slice d9 d6 t
  rmLow = C.slice d3 d0 lo3
  byReg sh = dp 0xd False True 0 lo0 (C.slice d3 d0 lo3 ++# (0 :: BitVector 1) ++# (sh :: BitVector 2) ++# (1 :: BitVector 1) ++# lo0)
  alu = case aluSel of
    0x2 -> byReg 0
    0x3 -> byReg 1
    0x4 -> byReg 2
    0x7 -> byReg 3
    0x8 -> dp 0x8 False True lo0 0 (zeroExtend rmLow)
    0x9 -> dp 0x3 True True lo3 lo0 0                       -- NEG: RSBS Rd, Rm, #0
    0xa -> dp 0xa False True lo0 0 (zeroExtend rmLow)
    0xb -> dp 0xb False True lo0 0 (zeroExtend rmLow)
    0xd -> 0xe0100090 .|. reg16 lo0 .|. shiftL (zeroExtend lo0) 8 .|. zeroExtend lo3  -- MULS Rd, Rm, Rd
    0xf -> dp 0xf False True 0 lo0 (zeroExtend rmLow)
    op4 -> dp op4 False True lo0 lo0 (zeroExtend rmLow)   -- AND EOR ADC SBC ORR BIC
  -- Hi-register ADD/CMP/MOV (both registers low is UNPREDICTABLE on v5) and
  -- BX/BLX Rm (SBZ bits must be zero). ADD/MOV to PC branch with bit 0
  -- cleared, staying in Thumb.
  hRd = pack (testBit t 7) ++# C.slice d2 d0 t
  hRm = pack (testBit t 6) ++# C.slice d5 d3 t
  bothLow = not (testBit t 7) && not (testBit t 6)
  hiOps = case C.slice d9 d8 t of
    0 | bothLow -> undef
      | otherwise -> arm (dp 0x4 False False hRd hRd (zeroExtend hRm))
    1 | bothLow -> undef
      | otherwise -> arm (dp 0xa False True hRd 0 (zeroExtend hRm))
    2 | bothLow -> undef
      | otherwise -> arm (dp 0xd False False 0 hRd (zeroExtend hRm))
    _ | C.slice d2 d0 t /= 0 -> undef
      | otherwise -> arm ((if testBit t 7 then 0xe12fff30 else 0xe12fff10) .|. zeroExtend hRm)
  -- Register-offset transfers, L = bit 11: STR STRH STRB LDRSB / LDR LDRH
  -- LDRB LDRSH.
  regTransfer loadSide = operands .|. case (loadSide, testBit t 10, testBit t 9) of
    (False, b, False) -> 0xe7800000 .|. (if b then bit 22 else 0)
    (False, False, True) -> 0xe18000b0                  -- STRH
    (False, True, True) -> 0xe19000d0                   -- LDRSB
    (True, b, False) -> 0xe7900000 .|. (if b then bit 22 else 0)
    (True, False, True) -> 0xe19000b0                   -- LDRH
    (True, True, True) -> 0xe19000f0                    -- LDRSH
   where operands = base3 .|. reg12 lo0 .|. zeroExtend lo6
  -- STRH/LDRH Rd, [Rb, #imm5 * 2].
  halfImm loadSide = 0xe1c000b0 .|. (if loadSide then bit 20 else 0) .|. base3 .|. reg12 lo0
    .|. shiftL (zeroExtend (C.slice d4 d3 imm5)) 8 .|. shiftL (zeroExtend (C.slice d2 d0 imm5)) 1
  -- B<cond>; cond 1110 is undefined and 1111 is SWI.
  branchCond = case C.slice d11 d8 t of
    0xe -> undef
    0xf -> arm (0xef000000 .|. zeroExtend imm8)
    c -> special AuxBranch c (sext 9 (zeroExtend imm8 ++# (0 :: BitVector 1)))

-- | ARM token for a fetched ARM word.
armToken :: Tag -> IrTok
armToken tag = IrTok tag (tagOp tag) AuxArm (C.slice d31 d28 (tagOp tag)) 0

-- | Implemented-form check and class of an ARM opcode (Thumb: the
-- rewritten one), in the guard order that also resolves overlapping
-- encodings. Every UNPREDICTABLE or unimplemented combination is 'CUndef'
-- and faults 1 if its condition passes.
classify :: Bool -> BitVector 5 -> Word -> Cls
classify th m op
  | op .&. 0x0f000000 == 0x0f000000 = CSwi
  | op .&. 0x0ffffff0 == 0x012fff10 && (rm /= 15 || th) = CBx
  | op .&. 0x0ffffff0 == 0x012fff30 && rm /= 15 && armV5 arch = CBx
  | op .&. 0x0fff0ff0 == 0x016f0f10 && armV5 arch = valid (rd /= 15 && rm /= 15) CClz
  -- MUL/MLA: R15 operands and MUL with nonzero SBZ (Rn) fault; Rd = Rm is
  -- defined (operands are read before the result is written).
  | op .&. 0x0fc000f0 == 0x00000090 =
      valid (not (rn == 15 || rm == 15 || rs == 15 || (accumulate && rd == 15) || (not accumulate && rd /= 0))) CMul
  -- UMULL/UMLAL/SMULL/SMLAL: R15 operands and RdHi = RdLo fault.
  | op .&. 0x0f8000f0 == 0x00800090 =
      valid (not (rn == 15 || rd == 15 || rm == 15 || rs == 15 || rn == rd)) CMulLong
  | op .&. 0x0fbf0fff == 0x010f0000 && rd /= 15 = valid (not spsrSelected || hasSpsr m) CMrs
  | op .&. 0x0fb0f000 == 0x0320f000 = msr
  | op .&. 0x0fb0fff0 == 0x0120f000 && rm /= 15 = msr
  | op .&. 0x0e000000 == 0x0a000000 = CBranch
  | op .&. 0x0e000000 == 0x08000000 = block
  | op .&. 0x0c000000 == 0x04000000 = singleWord
  | op .&. 0x0e000090 == 0x00000090 && halfKind /= 0 = singleHalf
  | op .&. 0x0c000000 == 0 && dataForm = CDp
  | otherwise = CUndef
 where
  rd = fromIntegral (C.slice d15 d12 op) :: Index 16
  rn = fromIntegral (C.slice d19 d16 op) :: Index 16
  rm = fromIntegral (C.slice d3 d0 op) :: Index 16
  rs = fromIntegral (C.slice d11 d8 op) :: Index 16
  valid ok c = if ok then c else CUndef
  accumulate = testBit op 21
  -- MRS/MSR (R = bit 22 selects SPSR): SVC and IRQ have SPSRs; SPSR access
  -- in User or System mode faults; an empty MSR field mask faults. A CPSR
  -- value outside the subset faults in the ALU (see 'setCpsr').
  spsrSelected = testBit op 22
  msr = valid (C.slice d19 d16 op /= 0 && (not spsrSelected || hasSpsr m)) CMsr
  load = testBit op 20
  preIndex = testBit op 24
  baseWrite = not preIndex || testBit op 21
  -- Single transfers: P U _ W L at bits 24..20. UNPREDICTABLE operand
  -- combinations fault instead of picking one.
  transferOk width regOffset =
    not (regOffset && rm == 15)
    && not (baseWrite && (rn == 15 || rn == rd || (regOffset && rm == rn)))
    && not (rd == 15 && not (load && width == (4 :: Int)))
  -- Word/byte; I (bit 25) selects an immediate-shifted Rm. P=0 with W is
  -- LDRT/STRT; I with bit 4 set is the media/undefined space.
  singleWord = valid (not (not preIndex && testBit op 21) && not (testBit op 25 && testBit op 4)
                      && transferOk (if testBit op 22 then 1 else 4) (testBit op 25)) CSingle
  -- Halfword and signed byte/halfword (SH = bits 6..5). Bit 22 selects a
  -- split 8-bit immediate, otherwise Rm with bits 11..8 zero. Stores with
  -- SH = 1x are LDRD/STRD, outside the subset.
  halfKind = C.slice d6 d5 op
  singleHalf = valid (not (not preIndex && testBit op 21)
                      && not (not (testBit op 22) && C.slice d11 d8 op /= 0)
                      && not (not load && halfKind /= 1)
                      && transferOk (if halfKind == 2 then 1 else 2) (not (testBit op 22))) CSingle
  -- LDM/STM: an empty list, an R15 base, STM of R15, the UNPREDICTABLE
  -- base-in-list writebacks and the S forms other than LDM {.., pc}^ in a
  -- mode with an SPSR (user-bank transfers) fault; STM! storing its
  -- lowest-numbered base is defined.
  regList = C.slice d15 d0 op
  restoring = testBit op 22
  block = valid (not (rn == 15 || regList == 0)
                 && not (restoring && not (load && testBit regList 15 && hasSpsr m))
                 && not (not load && testBit regList 15)
                 && not (testBit op 21 && regList ! rn == 1 && (load || lowestReg regList /= rn))) CBlock
  -- Data processing: test opcodes require S (the S=0 space holds
  -- MRS/MSR/BX/etc.); register shifts with any R15 operand are
  -- UNPREDICTABLE; S with Rd = PC is an exception return, only in a mode
  -- with an SPSR.
  registerShift = not (testBit op 25) && testBit op 4
  setFlags = testBit op 20
  testOp = C.slice d24 d23 op == 2
  dataForm = (setFlags || not testOp)
    && not (setFlags && rd == 15 && (testOp || not (hasSpsr m)))
    && not (registerShift && (testBit op 7 || rd == 15 || rn == 15 || rm == 15 || rs == 15))

-- | Decode stage: class, condition, the value R15 reads, operand selection
-- and the register reads the shift stage consumes.
decodeStage :: BitVector 5 -> IrTok -> (DecTok, Maybe Row, Maybe Row)
decodeStage m (IrTok tag op aux cond imm) = (tok, readRow aRow, readRow bRow)
 where
  th = tagThumb tag
  pcRead
    | not th = tagPc tag + 8
    | aux == AuxWordPc = (tagPc tag + 4) .&. complement 3
    | otherwise = tagPc tag + 4
  armBlx = not th && cond == 0xf && armV5 arch && op .&. 0x0e000000 == 0x0a000000
  cls = case aux of
    AuxBranch -> CBranch
    AuxBlSuffix -> CBranch
    AuxBlxSuffix -> CBranch
    AuxBlPrefix -> CLinkOnly
    AuxUndef -> CUndef
    _ | armBlx -> CBranch
      | not th && cond == 0xf -> CUndef
      | otherwise -> classify th m op
  -- The cond = 1111 space is not predicated: BLX <imm> always executes,
  -- the rest faults.
  cond' = if not th && cond == 0xf then 0xe else cond
  rn = fromIntegral (C.slice d19 d16 op) :: Index 16
  rm = fromIntegral (C.slice d3 d0 op) :: Index 16
  rs = fromIntegral (C.slice d11 d8 op) :: Index 16
  regList = C.slice d15 d0 op
  listBytes = sum (map (\b -> if b then 4 else 0) (unpack regList :: Vec 16 Bool)) :: Word
  registerShift = not (testBit op 25) && testBit op 4
  thumbBranch = aux == AuxBranch || aux == AuxBlSuffix || aux == AuxBlxSuffix || aux == AuxBlPrefix
  -- Operand 2 immediate (rotated or shifted later by the shift stage).
  immValue
    | thumbBranch = imm
    | armBlx = armDisplacement op .|. (if testBit op 24 then 2 else 0)
    | cls == CBranch = armDisplacement op
    | cls == CBlock = listBytes
    | cls == CSingle && op .&. 0x0c000000 == 0x04000000 = zeroExtend (C.slice d11 d0 op)
    | cls == CSingle = zeroExtend (C.slice d11 d8 op ++# C.slice d3 d0 op)
    | otherwise = zeroExtend (C.slice d7 d0 op)
  bImm = case cls of
    CBranch -> True
    CLinkOnly -> True
    CBlock -> True
    CDp -> testBit op 25
    CMsr -> testBit op 25
    CSingle | op .&. 0x0c000000 == 0x04000000 -> not (testBit op 25)
            | otherwise -> testBit op 22
    _ -> False
  -- Operand 1: R15 reads pcRead; branches add to pcRead, except the Thumb
  -- BL/BLX suffix, which adds to R14.
  suffix = aux == AuxBlSuffix || aux == AuxBlxSuffix
  aReg = case cls of
    CBranch | suffix -> Just 14
            | otherwise -> Nothing
    CLinkOnly -> Nothing
    CDp -> Just rn
    CSingle -> Just rn
    CBlock -> Just rn
    CMul -> Just rm
    CMulLong -> Just rm
    _ -> Nothing
  -- Operand 2 register; a register shift reads Rs first (then Rm).
  bReg = case cls of
    CDp | bImm -> Nothing
        | registerShift -> Just rs
        | otherwise -> Just rm
    CMsr | bImm -> Nothing
         | otherwise -> Just rm
    CSingle | bImm -> Nothing
            | otherwise -> Just rm
    CClz -> Just rm
    CBx -> Just rm
    CMul -> Just rs
    CMulLong -> Just rs
    _ -> Nothing
  readRow r = case r of
    Just x | x /= 15 -> Just (regRow m x)
    _ -> Nothing
  aRow = aReg
  bRow = bReg
  tok = DecTok
    { dTag = tag, dOp = op, dCls = cls, dCond = cond', dPcRead = pcRead, dImm = immValue
    , dBImm = bImm
    , dA15 = maybe True (== 15) aReg
    , dB15 = bReg == Just 15
    , dLink = case aux of
        AuxBlSuffix -> True
        AuxBlxSuffix -> True
        AuxArm | armBlx -> True
               | cls == CBranch -> testBit op 24
               | cls == CBx -> testBit op 5
        _ -> False
    , dSetT = case aux of
        AuxBlxSuffix -> Just False
        _ | armBlx -> Just True
          | otherwise -> Nothing
    , dAlign4 = aux == AuxBlxSuffix
    }

-- | Shift stage: operand 1 and the shifted operand 2. A register shift
-- takes two cycles: Rn and Rs first, then Rm. Presents the reads the ALU
-- consumes: the current SPSR (MRS/MSR/exception return) on port A, the
-- store data register on port B.
shiftStage :: BitVector 5 -> Bool -> DecTok -> Maybe (Word, BitVector 8) -> Word -> Word
  -> (Either (Word, BitVector 8) ShTok, Maybe Row, Maybe Row)
shiftStage m carry d latch portA portB
  | regShift, Nothing <- latch = (Left (portA, C.slice d7 d0 portB), Nothing, Just (regRow m rm))
  | otherwise = (Right (ShTok d aVal b c), presentA, presentB)
 where
  op = dOp d
  cls = dCls d
  rm = fromIntegral (C.slice d3 d0 op) :: Index 16
  rd = fromIntegral (C.slice d15 d12 op) :: Index 16
  regShift = cls == CDp && not (testBit op 25) && testBit op 4
  aVal
    | dA15 d = dPcRead d
    | Just (rn, _) <- latch = rn
    | otherwise = portA
  bIn
    | dBImm d = dImm d
    | dB15 d = dPcRead d
    | otherwise = portB
  rsAmount = maybe 0 snd latch
  (kind, amount, immForm) = case cls of
    CDp | testBit op 25 -> rotateImm
        | regShift -> (C.slice d6 d5 op, rsAmount, False)
        | otherwise -> immShift
    CMsr | testBit op 25 -> rotateImm
    CSingle | op .&. 0x0c000000 == 0x04000000 && testBit op 25 -> immShift
    _ -> (0, 0, False)
  rotateImm = (3, zeroExtend (C.slice d11 d8 op ++# (0 :: BitVector 1)), False)
  immShift = (C.slice d6 d5 op, zeroExtend (C.slice d11 d7 op), True)
  (b, c) = barrel kind amount immForm carry bIn
  presentA = if cls == CDp || cls == CMrs || cls == CMsr then Just (spsrRow m) else Nothing
  presentB = if cls == CSingle && not (testBit op 20) then Just (regRow m rd) else Nothing

-- | What the ALU stage hands on.
data AluNext = ToRetire Word | ToMem MemSt | ToFault (BitVector 3) Word
  deriving (Generic, NFDataX)

-- | ALU stage: condition check, the one adder/logic unit, flags, register
-- write, branches, PSR transfers, and the start of memory, multiply and
-- SWI work. portA/portB carry what the shift stage presented (SPSR, store
-- data).
aluStage :: Psr -> ShTok -> Word -> Word -> (Psr, Maybe (Row, Word), Maybe Row, Maybe Row, AluNext)
aluStage s (ShTok d a b sc) portA portB
  | not (condPasses (dCond d) (flags s)) = (s, Nothing, Nothing, Nothing, ToRetire next)
  | otherwise = case dCls d of
      CUndef -> faultHere
      CDp
        | testOp -> (flagged, Nothing, Nothing, Nothing, ToRetire next)
        | rd == 15 && setFlags -> case setCpsr True portA s of
            Nothing -> faultHere
            Just s' -> (s', Nothing, Nothing, Nothing, ToRetire (result .&. pcMask (thumb s')))
        | rd == 15 -> (flagged, Nothing, Nothing, Nothing, ToRetire (result .&. pcMask th))
        | otherwise -> (flagged, write rd result, Nothing, Nothing, ToRetire next)
      CMrs -> (s, write rd (if spsrSelected then portA else cpsrWord s), Nothing, Nothing, ToRetire next)
      CMsr
        | not spsrSelected -> case setCpsr False (merged cpsrMask (cpsrWord s) b) s of
            Nothing -> faultHere
            Just s' -> (s', Nothing, Nothing, Nothing, ToRetire next)
        | otherwise -> (s, Just (spsrRow (mode s), merged fieldMask portA b), Nothing, Nothing, ToRetire next)
      CClz -> (s, write rd (leadingZeros b), Nothing, Nothing, ToRetire next)
      CBranch -> branchTo (if dAlign4 d then result .&. complement 3 else result)
      CBx -> branchTo b
      CLinkOnly -> (s, write 14 result, Nothing, Nothing, ToRetire next)
      CSwi -> (s, Just (spsrRow 0x13, cpsrWord s), Nothing, Nothing, ToMem (mem MSwiLink))
      CSingle -> (s, Nothing, Nothing, Nothing, ToMem (mem MRoute)
        { pending = Access (if preIndex then result else a) width (not load) signed rd
                      (if load then 0 else portB .&. widthMask width)
        , writeBack = baseWrite, wbReg = rn, wbValue = result })
      CBlock -> (s, Nothing, Nothing, Nothing, ToMem (mem MCheck)
        { blockLeft = regList, blockAddr = start, blockStore = not load
        , checkLeft = regList, checkAddr = start, blockSpsr = testBit op 22
        , writeBack = testBit op 21, wbReg = rn, wbValue = result })
      -- Present the accumulator: RdLo/Rn (bits 15..12) on A, RdHi on B.
      CMul -> mulStart
      CMulLong -> mulStart
 where
  op = dOp d
  tag = dTag d
  th = tagThumb tag
  next = tagPc tag + stepOf th
  rd = fromIntegral (C.slice d15 d12 op) :: Index 16
  rn = fromIntegral (C.slice d19 d16 op) :: Index 16
  write r v = Just (regRow (mode s) r, v)
  faultHere = (s, Nothing, Nothing, Nothing, ToFault 1 (tagPc tag))
  pcMask t = if t then 0xfffffffe else 0xffffffff
  load = testBit op 20
  up = testBit op 23
  preIndex = testBit op 24
  baseWrite = not preIndex || testBit op 21
  setFlags = testBit op 20
  testOp = C.slice d24 d23 op == 2
  carry = testBit (flags s) 1
  wordForm = op .&. 0x0c000000 == 0x04000000
  halfKind = C.slice d6 d5 op
  width = if wordForm then (if testBit op 22 then 1 else 4) else (if halfKind == 2 then 1 else 2)
  signed = not wordForm && halfKind /= 1
  regList = C.slice d15 d0 op
  opc = case dCls d of
    CDp -> C.slice d24 d21 op
    CSingle -> if up then 0x4 else 0x2
    CBlock -> if up then 0x4 else 0x2
    CBranch -> 0x4
    CLinkOnly -> 0x4
    _ -> 0xd
  (result, carryOut, overflow, arithmetic) = aluOp opc carry sc a b
  newFlags = pack (msb result) ++# pack (result == 0) ++# pack carryOut
    ++# pack (if arithmetic then overflow else testBit (flags s) 0)
  flagged = if setFlags then s { flags = newFlags } else s
  -- LDM/STM first beat: IA base, IB base + 4, DA final + 4, DB final.
  start = a + (if up then (if preIndex then 4 else 0) else (if preIndex then 0 else 4) - b)
  -- MSR field mask; in User mode an MSR to the CPSR writes only NZCV.
  spsrSelected = testBit op 22
  fieldMask = pack (map (\x -> if x then 0xff else 0 :: BitVector 8)
                      (unpack (C.slice d19 d16 op) :: Vec 4 Bool)) :: Word
  cpsrMask = if mode s == 0x10 then fieldMask .&. 0xff000000 else fieldMask
  merged mask old value = (old .&. complement mask) .|. (value .&. mask)
  -- BL/BLX link: the next instruction, with bit 0 set when it is Thumb.
  link = if th then (tagPc tag + 2) .|. 1 else tagPc tag + 4
  branchTo target =
    let t' = case dSetT d of
          Just t -> t
          Nothing -> if dCls d == CBx then testBit target 0 else th
        target' = if dCls d == CBx then target .&. complement 1 else target
    in (s { thumb = t' }, if dLink d then write 14 link else Nothing, Nothing, Nothing, ToRetire target')
  mem p = MemSt p tag next (Access 0 4 False False 0 0) 0 0 False 0 0 False 0 0 False False op 0
  -- One 33x33 multiplier: operands sign-extended for SMULL/SMLAL.
  longForm = testBit op 23
  operand v = unpack ((if longForm && testBit op 22 then pack (msb v) else 0) ++# v) :: Signed 33
  product64 = C.slice d63 d0 (pack (operand a `mul` operand b))
  mulStart = (s, Nothing, Just (regRow (mode s) rd), Just (regRow (mode s) rn), ToMem (mem MMulAcc) { mulProd = product64 })

-- | Mem stage: memory routes and beats, base writeback, LDM^ CPSR restore,
-- multiply-accumulate, and the second half of SWI entry.
data MemOut = MemOut
  { moPsr    :: Psr
  , moMem    :: Maybe MemSt
  , moRetire :: Maybe RetTok
  , moFault  :: Maybe (BitVector 3, Word)
  , moReg    :: Maybe (Row, Word)
  , moRam    :: Bool                   -- ^ write the merged store word to local RAM
  , moStore  :: Maybe (Word, Word)
  , moReadA  :: Maybe Row
  , moReadB  :: Maybe Row
  } deriving (Generic, NFDataX)

memStage :: SliceIn -> Word -> Word -> Word -> Psr -> MemSt -> MemOut
memStage i ramWord portA portB s m = case mPhase m of
  MRoute -> case routeTo acc of
    Left code -> faulted code (accessAddr acc)
    Right p -> stay m { mPhase = p }
  MBoot -> loaded
  MLocal -> stay m { mPhase = MRam }
  MRam
    | accessWrite acc -> (complete m) { moRam = True, moStore = Just (accessAddr acc .&. 0xfffffffc, stored) }
    | otherwise -> loaded
  MOffer -> stay (if gpuReqReady i then m { mPhase = MAwait } else m)
  MAwait
    | not (gpuReplyValid i) -> stay m
    | gpuReplyFault i -> faulted 4 (accessAddr acc)
    | accessWrite acc -> complete m
    | otherwise -> loaded
  MCheck -> case blockFault (blockStore m) (checkAddr m) of
    0 -> let rest = checkLeft m .&. (checkLeft m - 1) in
      if rest == 0
        then (stay m { mPhase = MBeat, checkLeft = 0 }) { moReadB = beatRead (blockLeft m) }
        else stay m { checkLeft = rest, checkAddr = checkAddr m + 4 }
    code -> faulted code (checkAddr m)
  MBeat ->
    let r = lowestReg (blockLeft m)
        beat = Access (blockAddr m) 4 (blockStore m) False r (if blockStore m then portB else 0)
    in case routeTo beat of
         Left code -> faulted code (blockAddr m)
         Right p -> stay m { mPhase = p, pending = beat }
  MWriteBack -> (finish m { writeBack = False }) { moReg = Just (regRow (mode s) (wbReg m), wbValue m) }
  MRestore -> case setCpsr True portA s of
    Nothing -> faulted 1 (tagPc (mTag m))
    Just s' -> (out s') { moRetire = Just (RetTok (mTag m) (mNext m .&. (if thumb s' then 0xfffffffe else 0xffffffff))) }
  MMulAcc ->
    let mo = mulOp m
        long = testBit mo 23
        acc64 | not (testBit mo 21) = 0
              | long = portB ++# portA
              | otherwise = zeroExtend portA
        r64 = mulProd m + acc64
        lo = C.slice d31 d0 r64
        n = if long then testBit r64 63 else testBit lo 31
        z = if long then r64 == 0 else lo == 0
        s' = if testBit mo 20 then s { flags = pack n ++# pack z ++# C.slice d1 d0 (flags s) } else s
        dst = fromIntegral (if long then C.slice d15 d12 mo else C.slice d19 d16 mo) :: Index 16
        o = (out s') { moReg = Just (regRow (mode s) dst, lo) }
    in if long then o { moMem = Just m { mPhase = MMulHi, wbValue = C.slice d63 d32 r64 } }
       else o { moRetire = Just (RetTok (mTag m) (mNext m)) }
  MMulHi -> (retireWith s) { moReg = Just (regRow (mode s) (fromIntegral (C.slice d19 d16 (mulOp m))), wbValue m) }
  MSwiLink -> (out (enterMode 0x13 s))
    { moReg = Just (regRow 0x13 14, tagPc (mTag m) + stepOf (tagThumb (mTag m)))
    , moRetire = Just (RetTok (mTag m) swiVector) }
 where
  acc = pending m
  stored = mergeStore acc ramWord
  out s' = MemOut s' Nothing Nothing Nothing Nothing False Nothing Nothing Nothing
  stay m' = (out s) { moMem = Just m' }
  faulted code addr = (out s) { moFault = Just (code, addr) }
  retireWith s' = (out s') { moRetire = Just (RetTok (mTag m) (mNext m)) }
  beatRead l = if blockStore m then Just (regRow (mode s) (lowestReg l)) else Nothing
  -- The loaded value: boot ROM, local RAM or link reply.
  raw = case mPhase m of
    MBoot -> extract acc (bootWord i)
    MRam -> extract acc ramWord
    _ -> gpuReplyData i
  masked = raw .&. widthMask (accessWidth acc)
  value
    | not (accessSigned acc) = masked
    | accessWidth acc == 1 = pack (resize (unpack (C.slice d7 d0 masked) :: Signed 8) :: Signed 32)
    | otherwise = pack (resize (unpack (C.slice d15 d0 masked) :: Signed 16) :: Signed 32)
  -- A load to R15 (word LDR, or the last LDM/POP beat) branches: LDM
  -- {.., pc}^ restores the CPSR from the SPSR at the end; otherwise ARMv5
  -- interworks on bit 0 (ARMv4T keeps the state, dropping bit 0 in Thumb).
  loaded
    | accessReg acc /= 15 = (complete m) { moReg = Just (regRow (mode s) (accessReg acc), value) }
    | blockSpsr m = complete m { mNext = value, restore = True }
    | armV5 arch = (complete m { mNext = value .&. 0xfffffffe }) { moPsr = s { thumb = testBit value 0 } }
    | thumb s = complete m { mNext = value .&. 0xfffffffe }
    | otherwise = complete m { mNext = value }
  -- One beat is done: the next LDM/STM register, or the end of the transfer.
  complete m'
    | rest /= 0 = (stay m' { mPhase = MBeat, blockLeft = rest, blockAddr = blockAddr m' + 4 })
                    { moReadB = beatRead rest }
    | otherwise = finish m' { blockLeft = 0 }
   where rest = blockLeft m' .&. (blockLeft m' - 1)
  finish m'
    | writeBack m' = stay m' { mPhase = MWriteBack }
    | restore m' = (stay m' { mPhase = MRestore }) { moReadA = Just (spsrRow (mode s)) }
    | otherwise = (out s) { moRetire = Just (RetTok (mTag m') (mNext m')) }

-- | One clock of the whole CPU: the stage holding the token runs (fetch
-- when the pipe is empty).
transition :: Cpu -> SliceIn -> Word -> Word -> Word -> Step
transition s1 i ramWord portA portB
  | faultCode s /= 0 = plain s
  | Just r <- rq s = plain s { psr = p { pc = rNext r }, rq = Nothing }
  | Just m <- mq s =
      let o = memStage i ramWord portA portB p m
          s' = s { psr = moPsr o, mq = moMem o, rq = moRetire o, storeObs = moStore o }
      in Step (faultWith (moFault o) s') (if moRam o then Just (ramAddress s, mergeStore (pending m) ramWord) else Nothing)
              (moReg o) (moReadA o) (moReadB o)
  | Just t <- sq s =
      let (p', w, ra, rb, nxt) = aluStage p t portA portB
          s0 = s { psr = p', sq = Nothing }
          s' = case nxt of
            ToRetire target -> s0 { rq = Just (RetTok (dTag (sDec t)) target) }
            ToMem m -> s0 { mq = Just m }
            ToFault c addr -> faultWith (Just (c, addr)) s0
      in Step s' Nothing w ra rb
  | Just d <- dq s = case shiftStage (mode p) (testBit (flags p) 1) d (shLatch s) portA portB of
      (Left l, ra, rb) -> Step s { shLatch = Just l } Nothing Nothing ra rb
      (Right t, ra, rb) -> Step s { dq = Nothing, shLatch = Nothing, sq = Just t } Nothing Nothing ra rb
  | Just t <- iq s = let (d, ra, rb) = decodeStage (mode p) t in Step s { iq = Nothing, dq = Just d } Nothing Nothing ra rb
  | Just t <- xq s = plain s { xq = Nothing, iq = Just (expandStage t) }
  | otherwise = case fphase s of
      FIdle
        -- IRQ entry at an instruction boundary: SPSR_irq <- CPSR now,
        -- R14_irq <- next instruction + 4 in either state next cycle.
        | irqRequest i && not (irqMask p) ->
            Step s { fphase = FIrqLink } Nothing (Just (spsrRow 0x12, cpsrWord p)) Nothing Nothing
        | pc p .&. (if thumb p then 1 else 3) /= 0 -> plain (faultWith (Just (2, pc p)) s)
        | inRam (pc p) -> plain s { fphase = FRam }
        | not (inBoot (pc p)) -> plain (faultWith (Just (3, pc p)) s)
        | otherwise -> plain (issue (bootWord i))
      -- A RAM fetch presents the address on the synchronous port for one
      -- cycle and decodes the word it returns.
      FRam -> plain s { fphase = FWord }
      FWord -> plain (issue ramWord) { fphase = FIdle }
      FIrqLink -> Step s { fphase = FIdle, psr = (enterMode 0x12 p) { pc = irqVector } } Nothing
                    (Just (regRow 0x12 14, pc p + 4)) Nothing Nothing
 where
  -- A store is observed for exactly the one cycle after its RAM write.
  s = s1 { storeObs = Nothing }
  p = psr s
  plain x = Step x Nothing Nothing Nothing Nothing
  faultWith f x = case f of
    Just (c, addr) -> x { faultCode = c, faultAt = addr }
    Nothing -> x
  -- Thumb fetches the halfword selected by pc[1] of the fetched word.
  issue w
    | thumb p = s { xq = Just (Tag (pc p) (zeroExtend half) True) }
    | otherwise = s { iq = Just (armToken (Tag (pc p) w False)) }
   where half = if testBit (pc p) 1 then C.slice d31 d16 w else C.slice d15 d0 w

