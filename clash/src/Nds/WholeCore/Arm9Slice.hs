-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric, FlexibleContexts #-}
{-# LANGUAGE TypeApplications #-}

-- | First ARM9/SoC slice: an ARMv5 ARM and Thumb subset with architected
-- predication, NZCV flags, data processing, branches and interworking,
-- multiplies and CLZ, User/System/SVC/IRQ modes with banked R13/R14, IRQ
-- and SWI exception entry/return, plus a boot ROM port, a 4 KiB
-- byte-enabled local RAM that code can execute from, and a blocking GPU bus
-- master.
module Nds.WholeCore.Arm9Slice
  ( SliceState, SliceIn(..), SliceOut(..)
  , initialSlice, resetSlice, sliceBootAddr, sliceStep, slice, arm9SliceTopEntity
  ) where

import Prelude ()
import Clash.Prelude hiding (Word, slice)
import qualified Clash.Prelude as C
import qualified Clash.Explicit.Prelude as E

type Word = BitVector 32
type Width = BitVector 3
type RamIndex = Index 1024

data SliceIn = SliceIn
  { bootWord      :: Word
  , gpuReqReady   :: Bool
  , gpuReplyValid :: Bool
  , gpuReplyData  :: Word
  , gpuReplyFault :: Bool
  , irqRequest    :: Bool   -- ^ ARM9 IRQ level (active high), sampled at instruction boundaries
  } deriving (Generic, NFDataX)

data SliceOut = SliceOut
  { bootAddr      :: Word
  , gpuReqValid   :: Bool
  , gpuReqWrite   :: Bool
  , gpuReqAddr    :: Word
  , gpuReqWidth   :: Width
  , gpuReqLanes   :: BitVector 4
  , gpuReqData    :: Word
  , gpuReplyReady :: Bool
  , storeValid    :: Bool
  , storeAddr     :: Word
  , storeData     :: Word
  , fault         :: BitVector 3
  , faultAddr     :: Word
  , retireValid   :: Bool
  , retirePc      :: Word
  , retireOpcode  :: Word
  } deriving (Eq, Show, Generic, NFDataX)

data Phase = Fetch | FetchRam | FetchWord | Decode | BlockCheck | BlockBeat | BootLoad
  | LocalRead | RamAccess | Offer | Await | Retire | Halted
  deriving (Eq, Generic, NFDataX)

data Access = Access
  { accessAddr   :: Word
  , accessWidth  :: Width
  , accessWrite  :: Bool
  , accessSigned :: Bool
  , accessReg    :: Index 16
  , accessData   :: Word
  } deriving (Generic, NFDataX)

data Cpu = Cpu
  { phase      :: Phase
  , pc         :: Word
  , opcode     :: Word          -- ^ ARM word, or a Thumb halfword zero-extended
  , regs       :: Vec 16 Word   -- ^ current mode's view: R13/R14 are the active bank
  , flags      :: BitVector 4
  , irqMask    :: Bool          -- ^ CPSR.I
  , fiqMask    :: Bool          -- ^ CPSR.F (stored; there is no FIQ source)
  , thumb      :: Bool          -- ^ CPSR.T
  , mode       :: BitVector 5   -- ^ CPSR mode: User 0x10, IRQ 0x12, SVC 0x13, System 0x1F
  , banks      :: Vec 3 (Word, Word)  -- ^ R13/R14 of the inactive banks (usr/sys, svc, irq)
  , spsrSvc    :: Word
  , spsrIrq    :: Word
  , pending    :: Access
  , nextPc     :: Word
  , lastStore  :: Bool
  , fullWord   :: Word
  , faultCode  :: BitVector 3
  , faultAt    :: Word
  , blockLeft  :: BitVector 16  -- ^ LDM/STM registers still to transfer, current beat included
  , blockAddr  :: Word          -- ^ address of the current LDM/STM beat
  , blockStore :: Bool
  , blockSpsr  :: Bool          -- ^ LDM {.., pc}^: copy SPSR to CPSR when PC is loaded
  , checkLeft  :: BitVector 16  -- ^ LDM/STM beats still to route-check
  , checkAddr  :: Word
  , writeBack  :: Bool          -- ^ base writeback applied when the instruction completes
  , wbReg      :: Index 16
  , wbValue    :: Word
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

-- | Reset: SVC mode, ARM state, IRQ and FIQ masked (CPSR 0x000000d3).
initialCpu :: Cpu
initialCpu = Cpu Fetch bootBase 0 (repeat 0) 0 True True False 0x13 (repeat (0, 0)) 0 0
  (Access 0 4 False False 0 0) 0 False 0 0 0 0 0 False False 0 0 False 0 0

-- The pure harness models the synchronous RAM port; the generated top uses
-- blockRam. Both call the same CPU/router transition and observer.
data SliceState = SliceState Cpu (Vec 1024 Word) Word
  deriving (Generic, NFDataX)

initialSlice :: SliceState
initialSlice = SliceState initialCpu (repeat 0) 0

-- | CPU/link reset does not clear initialized block RAM. Reset both endpoints
-- of the GPU link together; a reply from before reset must not be re-presented.
resetSlice :: SliceState -> SliceState
resetSlice (SliceState _ mem _) = SliceState initialCpu mem 0

sliceBootAddr :: SliceState -> Word
sliceBootAddr (SliceState s _ _) = romAddress s

sliceStep :: SliceState -> SliceIn -> (SliceState, SliceOut)
sliceStep (SliceState s mem readWord) i =
  (SliceState s' mem' (mem !! ramAddress s), observe s)
 where
  (s', wr) = transition s i readWord
  mem' = case wr of
    Nothing -> mem
    Just (addr, value) -> replace addr value mem

romAddress :: Cpu -> Word
romAddress s = if phase s == BootLoad then accessAddr (pending s) else pc s

ramAddress :: Cpu -> RamIndex
ramAddress = fromIntegral . C.slice d11 d2 . accessAddr . pending

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

-- | Spans the link owns: the GPU target's registers and VRAM, plus the
-- timer, IRQ and game-card registers that devices in front of the GPU
-- (Arm9Io, Card) may decode. The target behind the link must reply with an
-- error for anything here it does not implement. Each access must lie
-- wholly inside one span, so a word covering VRAMCNT_G and WRAMCNT never
-- leaves the slice.
linkOwns :: Access -> Bool
linkOwns a = C.slice d31 d24 addr == 0x06
  -- DISPCNT, DISPSTAT; VCOUNT (0x04000006) is read-only
  || within 0x04000000 (if accessWrite a then 0x04000006 else 0x04000008)
  || within 0x04000100 0x04000110  -- TM0CNT..TM3CNT
  || within 0x040001a0 0x040001a2  -- AUXSPICNT (AUXSPIDATA is not routed)
  || within 0x040001a4 0x040001b0  -- ROMCTRL, game-card command bytes
  || within 0x04000208 0x0400020c  -- IME
  || within 0x04000210 0x04000218  -- IE, IF
  || (addr == 0x04000304 && width /= 1)
  || within 0x04000240 0x04000247
  || within 0x04000248 0x0400024a
  || within 0x04100010 0x04100014  -- game-card data in
 where
  addr = accessAddr a
  width = resize (accessWidth a) :: Word
  within lo hi = addr >= lo && addr <= hi - width

observe :: Cpu -> SliceOut
observe s = SliceOut
  { bootAddr = romAddress s
  , gpuReqValid = offer
  , gpuReqWrite = offer && accessWrite a
  , gpuReqAddr = if offer then accessAddr a else 0
  , gpuReqWidth = if offer then accessWidth a else 0
  , gpuReqLanes = if offer then byteLanes a else 0
  , gpuReqData = if offer then accessData a else 0
  , gpuReplyReady = phase s == Await
  , storeValid = stored
  , storeAddr = if stored then accessAddr a .&. 0xfffffffc else 0
  , storeData = if stored then fullWord s else 0
  , fault = faultCode s
  , faultAddr = faultAt s
  , retireValid = retired
  , retirePc = if retired then pc s else 0
  , retireOpcode = if retired then opcode s else 0
  }
 where
  a = pending s
  offer = phase s == Offer
  retired = phase s == Retire
  -- A local RAM store is reported once, in the cycle after it is written:
  -- at retirement, or at the next beat of an STM.
  stored = lastStore s && (retired || phase s == BlockBeat)

stop :: BitVector 3 -> Word -> Cpu -> Cpu
stop code addr s = s { phase = Halted, faultCode = code, faultAt = addr }

-- | Instruction size in the current state.
step :: Cpu -> Word
step s = if thumb s then 2 else 4

finish :: Cpu -> Cpu
finish s = s { phase = Retire, nextPc = pc s + step s, lastStore = False }

writeReg :: Index 16 -> Word -> Cpu -> Cpu
writeReg rd value s = s { regs = replace rd value (regs s) }

-- | CPSR as MRS reads it: NZCV, I, F, T and the mode.
cpsrWord :: Cpu -> Word
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

currentSpsr :: Cpu -> Word
currentSpsr s = if mode s == 0x12 then spsrIrq s else spsrSvc s

writeSpsr :: BitVector 5 -> Word -> Cpu -> Cpu
writeSpsr m w s = if m == 0x12 then s { spsrIrq = w } else s { spsrSvc = w }

-- | Change mode, swapping R13/R14 banks when the bank changes.
setMode :: BitVector 5 -> Cpu -> Cpu
setMode m s
  | new == old = s { mode = m }
  | otherwise = s { regs = replace (13 :: Index 16) sp (replace (14 :: Index 16) lr (regs s))
                  , banks = replace old (regs s !! (13 :: Index 16), regs s !! (14 :: Index 16)) (banks s)
                  , mode = m }
 where
  new = bankOf m
  old = bankOf (mode s)
  (sp, lr) = banks s !! new

-- | Write a whole CPSR. The Q, J and reserved bits must be clear and the
-- mode in the subset; T may change only on an exception return.
setCpsr :: Bool -> Word -> Cpu -> Maybe Cpu
setCpsr allowT w s
  | C.slice d27 d8 w /= 0 || (testBit w 5 /= thumb s && not allowT) = Nothing
  | not (validMode m) = Nothing
  | otherwise = Just ((setMode m s)
      { flags = C.slice d31 d28 w, irqMask = testBit w 7, fiqMask = testBit w 6, thumb = testBit w 5 })
 where m = C.slice d4 d0 w

-- | Exception return from a retiring state: CPSR <- SPSR of the current
-- mode, PC <- target with bit 0 dropped if the new state is Thumb (an ARM
-- target must be word-aligned, or the fetch faults). An SPSR outside the
-- subset faults at the instruction.
returnTo :: Word -> Cpu -> Cpu -> Cpu
returnTo target at s = case setCpsr True (currentSpsr s) s of
  Nothing -> stop 1 (pc at) at
  Just x -> x { nextPc = target .&. (if thumb x then 0xfffffffe else 0xffffffff) }

-- | Exception entry: SPSR_<mode> <- CPSR; ARM state in the new mode with I
-- set and F kept; R14_<mode> <- lr. The caller sets the PC.
enterException :: BitVector 5 -> Word -> Cpu -> Cpu
enterException m lr s = writeReg 14 lr
  ((writeSpsr m (cpsrWord s) (setMode m s)) { irqMask = True, thumb = False })

-- | IRQ entry at an instruction boundary: R14_irq <- the next instruction's
-- address + 4 in either state, PC <- the IRQ vector. Nothing of the
-- interrupted instruction stream has started.
enterIrq :: Cpu -> Cpu
enterIrq s = (enterException 0x12 (pc s + 4) s) { pc = irqVector }

-- | SWI, ARM or Thumb: R14_svc <- the next instruction, PC <- the SWI vector
-- once the SWI retires.
enterSwi :: Cpu -> Cpu
enterSwi s = (enterException 0x13 (pc s + step s) (finish s)) { nextPc = swiVector }

-- | A value loaded into R15 outside an exception return. ARMv5 interworks
-- on bit 0; ARMv4T keeps the state and drops bit 0 in Thumb.
loadPc :: Word -> Cpu -> Cpu
loadPc v s
  | armV5 arch = s { nextPc = v .&. 0xfffffffe, thumb = testBit v 0 }
  | thumb s = s { nextPc = v .&. 0xfffffffe }
  | otherwise = s { nextPc = v }

-- | One memory beat is done. An LDM/STM continues with its next register;
-- otherwise the instruction retires and applies any base writeback.
complete :: Bool -> Cpu -> Cpu
complete ramStore s
  | rest /= 0 = s { phase = BlockBeat, blockLeft = rest, blockAddr = blockAddr s + 4
                  , lastStore = ramStore }
  | otherwise = (based (finish s)) { blockLeft = 0, lastStore = ramStore }
 where
  rest = blockLeft s .&. (blockLeft s - 1)
  based x = if writeBack s then writeReg (wbReg s) (wbValue s) x else x

-- | A load to R15 (word LDR, or the last LDM/POP beat) branches through
-- 'loadPc'; LDM {.., pc}^ instead copies the SPSR to the CPSR after its
-- writeback.
loadDone :: Cpu -> Word -> Cpu
loadDone s raw
  | accessReg a /= 15 = complete False (writeReg (accessReg a) value s)
  | blockSpsr s = returnTo value s (complete False s)
  | otherwise = loadPc value (complete False s)
 where
  a = pending s
  masked = raw .&. widthMask (accessWidth a)
  value
    | not (accessSigned a) = masked
    | accessWidth a == 1 = pack (resize (unpack (C.slice d7 d0 masked) :: Signed 8) :: Signed 32)
    | otherwise = pack (resize (unpack (C.slice d15 d0 masked) :: Signed 16) :: Signed 32)

-- | Fault code, or the phase that serves the access.
routeTo :: Access -> Either (BitVector 3) Phase
routeTo a
  | not (aligned a) = Left 2
  | inBoot addr && not (accessWrite a) = Right BootLoad
  | inRam addr = Right LocalRead
  | linkOwns a = Right Offer
  | otherwise = Left 3
 where addr = accessAddr a

route :: Cpu -> Access -> Cpu
route s a = case routeTo a of
  Left code -> stop code (accessAddr a) s
  Right p -> s { phase = p, pending = a }

-- | LDM/STM beats serve only the boot ROM and local RAM. The link stays
-- single-transfer: a block whose beat would reach it faults 3 at that beat's
-- address, like any other address with no route, before the first beat.
blockFault :: Bool -> Word -> BitVector 3
blockFault store addr = case routeTo (Access addr 4 store False 0 0) of
  Left code -> code
  Right Offer -> 3
  Right _ -> 0

lowestReg :: BitVector 16 -> Index 16
lowestReg l = maybe 0 id (findIndex id (reverse (unpack l :: Vec 16 Bool)))

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

-- | Barrel shifter for a nonzero-or-register amount: kind 0 LSL, 1 LSR,
-- 2 ASR, 3 ROR. Amount 0 passes the operand and carry through unchanged.
shiftBy :: BitVector 2 -> BitVector 8 -> Bool -> Word -> (Word, Bool)
shiftBy kind amount carry rm
  | amount == 0 = (rm, carry)
  | otherwise = case kind of
      0 -> let y = shiftL (0 ++# rm :: BitVector 33) n in (C.slice d31 d0 y, testBit y 32)
      1 -> let y = shiftR (rm ++# 0 :: BitVector 33) n in (C.slice d32 d1 y, testBit y 0)
      2 -> let y = pack (shiftR (unpack (rm ++# 0) :: Signed 33) (min n 32))
           in (C.slice d32 d1 y, testBit y 0)
      _ -> let r = rotateR rm (fromIntegral (C.slice d4 d0 amount)) in (r, testBit r 31)
 where
  n = fromIntegral amount :: Int

-- | Immediate-amount shifts: LSR/ASR #0 encode #32 and ROR #0 encodes RRX.
shiftImm :: BitVector 2 -> BitVector 5 -> Bool -> Word -> (Word, Bool)
shiftImm kind amount carry rm
  | amount /= 0 = shiftBy kind (resize amount) carry rm
  | kind == 3 = (pack carry ++# C.slice d31 d1 rm, testBit rm 0)
  | kind == 0 = (rm, carry)
  | otherwise = shiftBy kind 32 carry rm

-- | Result, carry, overflow and whether the opcode is arithmetic (writes V).
aluOp :: BitVector 4 -> Bool -> Bool -> Word -> Word -> (Word, Bool, Bool, Bool)
aluOp opc carry shifterCarry a b = case opc of
  0x0 -> logic (a .&. b)
  0x1 -> logic (xor a b)
  0x2 -> carrySum a (complement b) True
  0x3 -> carrySum b (complement a) True
  0x4 -> carrySum a b False
  0x5 -> carrySum a b carry
  0x6 -> carrySum a (complement b) carry
  0x7 -> carrySum b (complement a) carry
  0x8 -> logic (a .&. b)
  0x9 -> logic (xor a b)
  0xa -> carrySum a (complement b) True
  0xb -> carrySum a b False
  0xc -> logic (a .|. b)
  0xd -> logic b
  0xe -> logic (a .&. complement b)
  _   -> logic (complement b)
 where
  logic r = (r, shifterCarry, False, False)
  carrySum x y cin =
    let total = (0 ++# x) + (0 ++# y) + (if cin then 1 else 0) :: BitVector 33
        r = C.slice d31 d0 total
    in (r, testBit total 32, msb x == msb y && msb r /= msb x, True)

-- | What the front end decided for one instruction. Kept small so the
-- per-format choice muxes a few words, not whole CPU states.
data Front
  = Run Word Word                 -- ^ R15 read value and ARM opcode for 'execute'
  | Branch Word Bool (Maybe Word) -- ^ target, new T, R14 value
  | Skip                          -- ^ condition failed: retire with no effect
  | Undefined                     -- ^ outside the subset: fault 1

-- | Predication happens before the implemented-form check: a cond-failed
-- instruction retires with no register, flag or bus effect whatever its
-- encoding. In the cond = 1111 space only ARMv5 BLX (immediate) executes;
-- the rest faults unpredicated. ARM and Thumb share the one 'execute'
-- (one ALU, shifter, multiplier and exception path in hardware): the front
-- end hands it an ARM opcode and the value R15 reads.
decode :: Cpu -> Cpu
decode s = case front of
  Run pcRead op -> maybe bad id (execute pcRead op s)
  Branch target t lr -> (maybe id (writeReg 14) lr (finish s)) { nextPc = target, thumb = t }
  Skip -> finish s
  Undefined -> bad
 where
  bad = stop 1 (pc s) s
  armOp = opcode s
  cond = C.slice d31 d28 armOp
  front
    | thumb s = thumbOp s
    | cond == 0xf && armV5 arch && armOp .&. 0x0e000000 == 0x0a000000 =
        -- BLX <imm>: to Thumb at pc + 8 + imm24 * 4 + H * 2, R14 <- pc + 4.
        Branch (pc s + 8 + armDisplacement armOp + (if testBit armOp 24 then 2 else 0)) True
               (Just (pc s + 4))
    | cond == 0xf = Undefined
    | not (condPasses cond (flags s)) = Skip
    | otherwise = Run (pc s + 8) armOp

-- | Sign-extended B/BL/BLX word displacement in bytes.
armDisplacement :: Word -> Word
armDisplacement op = pack (resize (unpack (C.slice d23 d0 op ++# (0 :: BitVector 2)) :: Signed 26) :: Signed 32)

-- | Thumb front end. The branch formats (B<cond>, B, the BL/BLX halves)
-- are decided here. Every other ARMv5T format, SWI and BX/BLX Rm included,
-- is rewritten into the equivalent AL-condition ARM opcode for 'execute',
-- with R15 reading as pc + 4, or (pc + 4) & ~3 for the PC-relative load
-- and ADD. So Thumb shares the ARM ALU, shifter, flags, single-beat link,
-- LDM/STM precheck and fault rules. BKPT, the undefined B<cond> space and
-- ARMv6 forms are Undefined.
thumbOp :: Cpu -> Front
thumbOp s = case top5 of
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
       | otherwise -> Undefined
  0x17 | C.slice d10 d9 t == 2 ->
           arm (0xe8bd0000 .|. (if testBit t 8 then bit 15 else 0) .|. zeroExtend imm8)
       | otherwise -> Undefined
  0x18 -> arm (0xe8a00000 .|. reg16 hi8 .|. zeroExtend imm8)
  -- LDMIA with the base in the list keeps the loaded value: no writeback.
  0x19 -> arm (0xe8900000 .|. (if testBit imm8 (fromIntegral hi8) then 0 else bit 21)
                .|. reg16 hi8 .|. zeroExtend imm8)
  0x1a -> branchCond
  0x1b -> branchCond
  0x1c -> Branch (pcPlus4 + sext 12 (C.slice d10 d0 t ++# (0 :: BitVector 1))) True Nothing
  -- BLX suffix: to ARM at (R14 + offset) & ~3; bit 0 of the offset must be 0.
  0x1d | armV5 arch && not (testBit t 0) -> Branch ((lr + suffix) .&. 0xfffffffc) False (Just next)
       | otherwise -> Undefined
  -- BL/BLX prefix: R14 <- pc + 4 + (offset << 12); the next halfword follows.
  0x1e -> Branch (pc s + 2) True (Just (pcPlus4 + shiftL (sext 11 (zeroExtend (C.slice d10 d0 t))) 12))
  _ -> Branch (lr + suffix) True (Just next)
 where
  t = C.slice d15 d0 (opcode s)
  top5 = C.slice d15 d11 t
  arm x = Run pcPlus4 x
  wordPc x = Run (pcPlus4 .&. 0xfffffffc) x
  next = pc s + 2 .|. 1
  pcPlus4 = pc s + 4
  lr = regs s !! (14 :: Index 16)
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
    0 | bothLow -> Undefined
      | otherwise -> arm (dp 0x4 False False hRd hRd (zeroExtend hRm))
    1 | bothLow -> Undefined
      | otherwise -> arm (dp 0xa False True hRd 0 (zeroExtend hRm))
    2 | bothLow -> Undefined
      | otherwise -> arm (dp 0xd False False 0 hRd (zeroExtend hRm))
    _ | C.slice d2 d0 t /= 0 -> Undefined
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
    0xe -> Undefined
    0xf -> arm (0xef000000 .|. zeroExtend imm8)
    c | condPasses c (flags s) -> Branch (pcPlus4 + sext 9 (zeroExtend imm8 ++# (0 :: BitVector 1))) True Nothing
      | otherwise -> Skip

execute :: Word -> Word -> Cpu -> Maybe Cpu
execute pcRead op s
  | op .&. 0x0f000000 == 0x0f000000 = Just (enterSwi s)
  | op .&. 0x0ffffff0 == 0x012fff10 && (rm /= 15 || thumb s) = Just (exchange False)
  | op .&. 0x0ffffff0 == 0x012fff30 && rm /= 15 && armV5 arch = Just (exchange True)
  | op .&. 0x0fff0ff0 == 0x016f0f10 && armV5 arch = clz
  | op .&. 0x0fc000f0 == 0x00000090 = mulShort
  | op .&. 0x0f8000f0 == 0x00800090 = mulLong
  | op .&. 0x0fbf0fff == 0x010f0000 && rd /= 15 = statusRead
  | op .&. 0x0fb0f000 == 0x0320f000 = statusWrite immediate
  | op .&. 0x0fb0fff0 == 0x0120f000 && rm /= 15 = statusWrite rmValue
  | op .&. 0x0e000000 == 0x0a000000 =
      Just ((if testBit op 24 then link else finish s) { nextPc = pcRead + armDisplacement op })
  | op .&. 0x0e000000 == 0x08000000 = blockTransfer
  | op .&. 0x0c000000 == 0x04000000 = singleWord
  | op .&. 0x0e000090 == 0x00000090 && halfKind /= 0 = singleHalf
  | op .&. 0x0c000000 == 0 && dataForm = Just dataProcessing
  | otherwise = Nothing
 where
  rd = fromIntegral (C.slice d15 d12 op) :: Index 16
  rn = fromIntegral (C.slice d19 d16 op) :: Index 16
  rm = fromIntegral (C.slice d3 d0 op) :: Index 16
  rs = fromIntegral (C.slice d11 d8 op) :: Index 16
  reg r = if r == 15 then pcRead else regs s !! r
  base = reg rn
  rmValue = reg rm
  carry = testBit (flags s) 1
  -- CLZ Rd, Rm.
  clz | rd == 15 || rm == 15 = Nothing
      | otherwise = Just (writeReg rd (leadingZeros (regs s !! rm)) (finish s))
  -- MUL/MLA Rd, Rm, Rs[, Rn] and UMULL/UMLAL/SMULL/SMLAL RdLo, RdHi, Rm, Rs.
  -- Operands are read before either destination is written, so Rd = Rm and
  -- Rm overlapping RdLo/RdHi give the product, as the ARM946E-S does. R15
  -- operands, RdHi = RdLo and nonzero SBZ bits fault. S sets N and Z from
  -- the 32- or 64-bit result; C and V are unchanged (ARMv5). All forms
  -- share one 33x33 signed multiplier (operands sign-extended for SMULL/
  -- SMLAL, zero-extended otherwise) and one 64-bit accumulate adder.
  accumulate = testBit op 21
  longForm = testBit op 23
  operand v = unpack ((if longForm && testBit op 22 then pack (msb v) else 0) ++# v) :: Signed 33
  addend
    | not accumulate = 0
    | longForm = (regs s !! rn) ++# (regs s !! rd)
    | otherwise = zeroExtend (regs s !! rd)
  r64 = C.slice d63 d0 (pack (operand (regs s !! rm) `mul` operand (regs s !! rs))) + addend :: BitVector 64
  product32 = C.slice d31 d0 r64
  nzFlags n z = pack n ++# pack z ++# C.slice d1 d0 (flags s)
  mulShort
    | rn == 15 || rm == 15 || rs == 15 || (accumulate && rd == 15) = Nothing
    | not accumulate && rd /= 0 = Nothing
    | otherwise = Just (writeReg rn product32
        (if setFlags then (finish s) { flags = nzFlags (testBit product32 31) (product32 == 0) } else finish s))
  mulLong
    | rn == 15 || rd == 15 || rm == 15 || rs == 15 || rn == rd = Nothing
    | otherwise = Just (writeReg rn (C.slice d63 d32 r64) (writeReg rd product32
        (if setFlags then (finish s) { flags = nzFlags (testBit r64 63) (r64 == 0) } else finish s)))
  -- MRS/MSR (R = bit 22 selects SPSR). SVC and IRQ have SPSRs; SPSR access
  -- in User or System mode faults. In User mode an MSR to the CPSR writes
  -- only the flags byte; other fields are ignored (ARM ARM). An empty field
  -- mask faults, and a CPSR value outside the subset or changing T faults
  -- (see 'setCpsr'). An SPSR stores any value and is checked when an
  -- exception return copies it to the CPSR.
  spsrSelected = testBit op 22
  statusRead
    | not spsrSelected = Just (finish (writeReg rd (cpsrWord s) s))
    | hasSpsr (mode s) = Just (finish (writeReg rd (currentSpsr s) s))
    | otherwise = Nothing
  fieldMask = pack (map (\b -> if b then 0xff else 0 :: BitVector 8)
                      (unpack (C.slice d19 d16 op) :: Vec 4 Bool)) :: Word
  cpsrMask = if mode s == 0x10 then fieldMask .&. 0xff000000 else fieldMask
  merged mask old value = (old .&. complement mask) .|. (value .&. mask)
  statusWrite value
    | fieldMask == 0 = Nothing
    | not spsrSelected = setCpsr False (merged cpsrMask (cpsrWord s) value) (finish s)
    | hasSpsr (mode s) = Just (writeSpsr (mode s) (merged fieldMask (currentSpsr s) value) (finish s))
    | otherwise = Nothing
  rotation = fromIntegral (C.slice d11 d8 op ++# (0 :: BitVector 1)) :: Int
  immediate = rotateR (resize (C.slice d7 d0 op)) rotation :: Word
  -- BL/BLX link: the next instruction, with bit 0 set when it is Thumb.
  link = writeReg 14 (if thumb s then pc s + 2 .|. 1 else pc s + 4) (finish s)
  load = testBit op 20
  preIndex = testBit op 24
  baseWrite = not preIndex || testBit op 21
  -- Single transfers: P U _ W L at bits 24..20. The offset is added (U) or
  -- subtracted before (P) or after the access and written back when P=0 or
  -- W. UNPREDICTABLE operand combinations fault instead of picking one.
  transfer width signed regOffset offset
    | regOffset && rm == 15 = Nothing
    | baseWrite && (rn == 15 || rn == rd || (regOffset && rm == rn)) = Nothing
    | rd == 15 && not (load && width == 4) = Nothing
    | otherwise = Just ((route s (Access addr width (not load) signed rd payload))
        { writeBack = baseWrite, wbReg = rn, wbValue = offsetAddr, blockLeft = 0, blockSpsr = False })
   where
    offsetAddr = if testBit op 23 then base + offset else base - offset
    addr = if preIndex then offsetAddr else base
    payload = if load then 0 else (regs s !! rd) .&. widthMask width
  -- Word/byte; I (bit 25) selects an immediate-shifted Rm. P=0 with W is
  -- LDRT/STRT; I with bit 4 set is the media/undefined space.
  singleWord
    | not preIndex && testBit op 21 = Nothing
    | testBit op 25 && testBit op 4 = Nothing
    | otherwise = transfer (if testBit op 22 then 1 else 4) False (testBit op 25) wordOffset
  wordOffset
    | testBit op 25 = fst (shiftImm (C.slice d6 d5 op) (C.slice d11 d7 op) carry rmValue)
    | otherwise = resize (C.slice d11 d0 op)
  -- Halfword and signed byte/halfword (SH = bits 6..5). Bit 22 selects a
  -- split 8-bit immediate, otherwise Rm with bits 11..8 zero. Stores with
  -- SH = 1x are LDRD/STRD, outside the subset.
  halfKind = C.slice d6 d5 op
  singleHalf
    | not preIndex && testBit op 21 = Nothing
    | not (testBit op 22) && C.slice d11 d8 op /= 0 = Nothing
    | not load && halfKind /= 1 = Nothing
    | otherwise = transfer (if halfKind == 2 then 1 else 2) (halfKind /= 1)
        (not (testBit op 22)) halfOffset
  halfOffset
    | testBit op 22 = resize (C.slice d11 d8 op ++# C.slice d3 d0 op)
    | otherwise = rmValue
  -- LDM/STM: P U S W L at bits 24..20. An empty list, an R15 base, STM of
  -- R15, the UNPREDICTABLE base-in-list writebacks and the S forms other
  -- than LDM {.., pc}^ in a mode with an SPSR (user-bank transfers) fault;
  -- STM! storing its lowest-numbered base is defined.
  regList = C.slice d15 d0 op
  listBytes = sum (map (\b -> if b then 4 else 0) (unpack regList :: Vec 16 Bool)) :: Word
  restoring = testBit op 22
  blockTransfer
    | rn == 15 || regList == 0 = Nothing
    | restoring && not (load && testBit regList 15 && hasSpsr (mode s)) = Nothing
    | not load && testBit regList 15 = Nothing
    | testBit op 21 && regList ! rn == 1 && (load || lowestReg regList /= rn) = Nothing
    | otherwise = Just s { phase = BlockCheck, blockLeft = regList, blockAddr = start
                         , blockStore = not load, blockSpsr = restoring
                         , checkLeft = regList, checkAddr = start
                         , writeBack = testBit op 21, wbReg = rn, wbValue = final }
  (start, final)
    | testBit op 23 = (if preIndex then base + 4 else base, base + listBytes)
    | otherwise = (if preIndex then base - listBytes else base - listBytes + 4, base - listBytes)
  -- BX/BLX register: bit 0 selects Thumb; a misaligned ARM target faults at
  -- fetch. BX pc is defined in Thumb (to ARM at pc + 4), not in ARM.
  exchange withLink = (if withLink then link else finish s)
    { nextPc = rmValue .&. 0xfffffffe, thumb = testBit rmValue 0 }
  -- Data processing: immediate, immediate-shift and register-shift operand 2.
  -- Test opcodes require S (the S=0 space holds MRS/MSR/BX/etc.); register
  -- shifts with any R15 operand are UNPREDICTABLE. Rd=PC without S
  -- branches (bit 0 dropped in Thumb, which stays in Thumb); with S
  -- (SUBS pc, lr, #4, MOVS pc, lr) it is an exception return, available
  -- only in SVC and IRQ mode, the modes with an SPSR.
  immediateForm = testBit op 25
  registerShift = not immediateForm && testBit op 4
  opc = C.slice d24 d21 op
  setFlags = testBit op 20
  testOp = C.slice d24 d23 op == 2
  dataForm = (setFlags || not testOp)
    && not (setFlags && rd == 15 && (testOp || not (hasSpsr (mode s))))
    && not (registerShift && (testBit op 7 || rd == 15 || rn == 15 || rm == 15 || rs == 15))
  (operand2, shifterCarry)
    | immediateForm = (immediate, if rotation == 0 then carry else testBit immediate 31)
    | registerShift = shiftBy (C.slice d6 d5 op) (C.slice d7 d0 (regs s !! rs)) carry rmValue
    | otherwise = shiftImm (C.slice d6 d5 op) (C.slice d11 d7 op) carry rmValue
  (result, carryOut, overflow, arithmetic) = aluOp opc carry shifterCarry base operand2
  newFlags = pack (msb result) ++# pack (result == 0) ++# pack carryOut
    ++# pack (if arithmetic then overflow else testBit (flags s) 0)
  flagged = if setFlags then (finish s) { flags = newFlags } else finish s
  dataProcessing
    | testOp = flagged
    | rd == 15 && setFlags = returnTo result s (finish s)
    | rd == 15 = flagged { nextPc = if thumb s then result .&. 0xfffffffe else result }
    | otherwise = writeReg rd result flagged

transition :: Cpu -> SliceIn -> Word -> (Cpu, Maybe (RamIndex, Word))
transition s i readWord = case phase s of
  Fetch
    | irqRequest i && not (irqMask s) -> idle (enterIrq s)
    | pc s .&. (if thumb s then 1 else 3) /= 0 -> idle (stop 2 (pc s) s)
    | inRam (pc s) -> idle (s { phase = FetchRam, pending = Access (pc s) 4 False False 0 0 })
    | not (inBoot (pc s)) -> idle (stop 3 (pc s) s)
    | otherwise -> idle (s { phase = Decode, opcode = fetched (bootWord i) })
  -- A RAM fetch presents the address on the synchronous port for one
  -- cycle and decodes the word it returns.
  FetchRam -> idle (s { phase = FetchWord })
  FetchWord -> idle (s { phase = Decode, opcode = fetched readWord })
  Decode -> idle (decode s)
  BootLoad -> idle (loadDone s (extract a (bootWord i)))
  LocalRead -> idle (s { phase = RamAccess })
  BlockCheck -> idle (case blockFault (blockStore s) (checkAddr s) of
    0 -> let rest = checkLeft s .&. (checkLeft s - 1) in
      s { phase = if rest == 0 then BlockBeat else BlockCheck
        , checkLeft = rest, checkAddr = checkAddr s + 4 }
    code -> stop code (checkAddr s) s)
  BlockBeat -> let r = lowestReg (blockLeft s) in
    idle (route s (Access (blockAddr s) 4 (blockStore s) False r
                     (if blockStore s then regs s !! r else 0)))
  RamAccess
    | accessWrite a -> let value = mergeStore a readWord in
        ((complete True s) { fullWord = value }, Just (ramAddress s, value))
    | otherwise -> idle (loadDone s (extract a readWord))
  Offer -> idle (if gpuReqReady i then s { phase = Await } else s)
  Await
    | not (gpuReplyValid i) -> idle s
    | gpuReplyFault i -> idle (stop 4 (accessAddr a) s)
    | accessWrite a -> idle (complete False s)
    | otherwise -> idle (loadDone s (gpuReplyData i))
  Retire -> idle (s { phase = Fetch, pc = nextPc s, lastStore = False })
  Halted -> idle s
 where
  a = pending s
  idle x = (x, Nothing)
  -- Thumb fetches the halfword selected by pc[1] of the fetched word.
  fetched w
    | not (thumb s) = w
    | testBit (pc s) 1 = zeroExtend (C.slice d31 d16 w)
    | otherwise = zeroExtend (C.slice d15 d0 w)

-- | Count of leading zero bits (CLZ): 32 for zero.
leadingZeros :: Word -> Word
leadingZeros w = fromIntegral (snd (foldl count (False, 0 :: Index 33) (unpack w :: Vec 32 Bool)))
 where count (seen, n) b = if seen || b then (True, n) else (False, n + 1)

slice :: HiddenClockResetEnable dom => Signal dom SliceIn -> Signal dom SliceOut
slice = arm9Slice hasClock hasReset hasEnable

arm9Slice
  :: KnownDomain dom
  => Clock dom -> Reset dom -> Enable dom
  -> Signal dom SliceIn -> Signal dom SliceOut
arm9Slice clk rst en input = qualify <$> active <*> (observe <$> state)
 where
  active = (&&) <$> fromEnable en <*> (not <$> unsafeToActiveHigh rst)
  state = E.register clk rst en initialCpu next
  (next, wr) = unbundle (transition <$> state <*> input <*> readWord)
  readWord = E.blockRam clk (toEnable active) (repeat @1024 0) (ramAddress <$> state) wr
  qualify True out = out
  qualify False out = out { gpuReqValid = False, gpuReplyReady = False
                          , storeValid = False, retireValid = False }

{-# ANN arm9SliceTopEntity
  (Synthesize
    { t_name = "nds_arm9_slice"
    , t_inputs = [ PortName "CLK", PortName "RST", PortName "EN", PortName "BOOT_WORD"
                 , PortName "GPU_REQ_READY", PortName "GPU_REPLY_VALID"
                 , PortName "GPU_REPLY_DATA", PortName "GPU_REPLY_FAULT", PortName "IRQ" ]
    , t_output = PortProduct "" [ PortName "BOOT_ADDR", PortName "GPU_REQ_VALID"
        , PortName "GPU_REQ_WRITE", PortName "GPU_REQ_ADDR", PortName "GPU_REQ_WIDTH"
        , PortName "GPU_REQ_LANES", PortName "GPU_REQ_DATA", PortName "GPU_REPLY_READY"
        , PortName "STORE_VALID", PortName "STORE_ADDR", PortName "STORE_DATA"
        , PortName "FAULT", PortName "FAULT_ADDR", PortName "RETIRE_VALID"
        , PortName "RETIRE_PC", PortName "RETIRE_OPCODE" ]
    }) #-}
arm9SliceTopEntity
  :: Clock System -> Reset System -> Enable System
  -> Signal System Word -> Signal System Bool -> Signal System Bool
  -> Signal System Word -> Signal System Bool -> Signal System Bool -> Signal System SliceOut
arm9SliceTopEntity clk rst en rom reqReady replyValid replyData replyFault irq =
  arm9Slice clk rst en (SliceIn <$> rom <*> reqReady <*> replyValid <*> replyData <*> replyFault <*> irq)
