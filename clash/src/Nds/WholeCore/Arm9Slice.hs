-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric, FlexibleContexts #-}
{-# LANGUAGE TypeApplications #-}

-- | The DS CPU slice: an ARMv5 (ARM9) or ARMv4T (ARM7, see 'Arch') ARM and
-- Thumb subset with architected predication, NZCV flags, data processing,
-- branches and interworking, multiplies (and CLZ on ARMv5), User/System/
-- SVC/IRQ modes with banked R13/R14, IRQ and SWI exception entry/return,
-- plus a boot ROM port, a 4 KiB byte-enabled local RAM that code can
-- execute from, and a blocking GPU bus master.
--
-- Microarchitecture. The general registers, the banked R13/R14 and the two
-- SPSRs live in a 32-row register file held in two block RAMs (one write
-- port, two synchronous read ports); the CPSR fields are registers.
-- Instructions are tokens in an in-order pipeline; each stage is a function
-- from its own input record to its own output record with a valid bit:
--
--   fetch -> [expand, Thumb only] -> decode -> E1 -> E2 -> [mem] -> retire
--
-- Fetch prefetches sequentially from the boot ROM (one per cycle) and the
-- local RAM (pipelined on the synchronous port); a misaligned or unrouted
-- fetch PC yields a fault token that faults only if it reaches commit.
-- Decode classifies the (Thumb-expanded) ARM opcode and presents the first
-- two operand reads. E1 gathers the remaining operands (each latch snoops
-- the register-file write bus) and runs the one barrel shifter. E2 is the
-- commit point: condition, the one adder/logic unit, flags, the register
-- write, branch resolution, and the start of memory, multiply or SWI work,
-- which the mem stage sequences while the pipe behind it waits. E2 commits
-- only with the mem stage empty, so architectural effects stay in program
-- order; an IRQ is taken instead of the commit, at that instruction's
-- boundary. Taken branches, PC loads, MSR, exception entry and return, and
-- stores into already-fetched local-RAM code flush the younger tokens.
module Nds.WholeCore.Arm9Slice
  ( SliceState, SliceIn(..), SliceOut(..)
  , initialSlice, resetSlice, sliceBootAddr, sliceStep, slice, arm9SliceTopEntity
  , sliceIrqMasked, sliceIrqEntering
  , Arch(..), IoMap(..), arm9Arch, arm7Arch
  , initialCore, resetCore, coreStep, coreSlice
  , CoreExt, initialCoreExt, coreExtObserve, coreExtBootAddr, coreExtIrqMasked
  , coreExtRead, coreExtWrite, coreExtStep, qualifyOut, coreSliceExt
  ) where

import Prelude ()
import Clash.Prelude hiding (Word, slice)
import qualified Clash.Prelude as C
import qualified Clash.Explicit.Prelude as E
import Data.Maybe (fromMaybe, isJust, isNothing)
import qualified Nds.WholeCore.Arm9Mpu as M

type Word = BitVector 32
type Width = BitVector 3
type RamIndex = Index 1024

-- | Register-file row: R0-R12 at 0-12; R13/R14 at 13/14 (User/System),
-- 17/18 (SVC), 21/22 (IRQ), 27/28 (ABT); SPSR_svc/irq/abt at 25/26/29.
-- R15 is never stored: a read of R15 takes the stage's PC value.
type Row = Index 32

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

data Access = Access
  { accessAddr   :: Word
  , accessWidth  :: Width
  , accessWrite  :: Bool
  , accessSigned :: Bool
  , accessReg    :: Index 16
  , accessData   :: Word
  } deriving (Generic, NFDataX)

-- | The architecture switch. One source builds the DS ARM9 ('arm9Arch':
-- ARM946E-S, ARMv5TE, exception vectors and boot at 0xFFFF0000) and the DS
-- ARM7 ('arm7Arch': ARM7TDMI, ARMv4T, vectors and boot at 0). Every
-- ARMv5-only behaviour tests 'armV5' — BLX (register, immediate, Thumb
-- suffix), CLZ, and interworking on loads to PC (LDR pc, LDM/POP {pc}) —
-- every vector address derives from 'vectorBase', and 'ioMap' selects which
-- I/O spans go out on the link. A top passes its record as a constant, so
-- each build keeps only its own logic.
data Arch = Arch
  { armV5      :: Bool
  , vectorBase :: Word
  , ioMap      :: IoMap
  , fabricMap  :: Bool   -- ^ full external main RAM aperture; ARM7 may also access Fabric VRAM
  , nativeBios :: Bool   -- ^ full private BIOS apertures, BIOS protection and native system IO
  }

-- | The I/O spans one CPU's link owns (see 'linkOwns').
data IoMap = Arm9Map | Arm7Map
  deriving (Eq)

arm9Arch, arm7Arch :: Arch
arm9Arch = Arch { armV5 = True, vectorBase = 0xffff0000, ioMap = Arm9Map, fabricMap = False, nativeBios = False }
arm7Arch = Arch { armV5 = False, vectorBase = 0x00000000, ioMap = Arm7Map, fabricMap = False, nativeBios = False }

ramBase :: Word
ramBase = 0x02000000

-- | Reset vector (the boot ROM window starts here), IRQ and SWI vectors.
bootBase :: Arch -> Word
bootBase = vectorBase

exceptionBase :: Arch -> Psr -> Word
exceptionBase a s | fabricMap a && armV5 a = if testBit (control s) 13 then 0xffff0000 else 0
                  | otherwise = vectorBase a

-- * State

-- | Committed CPSR fields, kept in flip-flops. (The fetch PC lives in
-- 'Fetch'; an instruction's own PC travels in its token.)
data Psr = Psr
  { flags   :: BitVector 4    -- ^ NZCV
  , irqMask :: Bool           -- ^ CPSR.I
  , fiqMask :: Bool           -- ^ CPSR.F (stored; there is no FIQ source)
  , thumb   :: Bool           -- ^ CPSR.T
  , mode    :: BitVector 5    -- ^ User 0x10, IRQ 0x12, SVC 0x13, System 0x1F
  , control :: Word           -- ^ ARM946 CP15 c1, *not* part of CPSR/SPSR; reset 0x2078
  } deriving (Eq, Generic, NFDataX)

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

-- | Fetch/expand -> decode token. A fetch fault travels as a token with a
-- nonzero 'irFault' and faults only if it reaches commit.
data IrTok = IrTok
  { irTag   :: Tag
  , irOp    :: Word            -- ^ ARM opcode (Thumb: the equivalent ARM opcode)
  , irAux   :: Aux
  , irCond  :: BitVector 4
  , irImm   :: Word            -- ^ Thumb branch offset
  , irFault :: BitVector 3     -- ^ fetch fault code (0: none)
  } deriving (Generic, NFDataX)

data Cls = CDp | CMrs | CMsr | CClz | CMul | CMulLong | CBranch | CBx | CLinkOnly
  | CSingle | CBlock | CSwi | CControl | CCacheOp | CUndef
  deriving (Eq, Generic, NFDataX)

-- | Decoded instruction, carried through E1 and E2.
data DecTok = DecTok
  { dTag    :: Tag
  , dOp     :: Word
  , dCls    :: Cls
  , dCond   :: BitVector 4
  , dPcRead :: Word           -- ^ value of R15 as an operand
  , dImm    :: Word           -- ^ immediate operand 2 (before shifting)
  , dBImm   :: Bool           -- ^ operand 2 is 'dImm'
  , dB15    :: Bool           -- ^ operand 2 register is R15
  , dLink   :: Bool           -- ^ branch writes R14
  , dSetT   :: Maybe Bool     -- ^ branch sets T (Nothing: keeps it)
  , dAlign4 :: Bool           -- ^ branch target rounded to a word (Thumb BLX suffix)
  , dFault  :: BitVector 3    -- ^ fetch fault code (0: none)
  } deriving (Generic, NFDataX)

-- | How far an E1 operand is: not read yet, read presented last cycle on
-- port A or B (the value is on that port now), or held.
data OpState = OEmpty | OPendA | OPendB | OValid Word
  deriving (Generic, NFDataX)

-- | An E1 operand: its register-file row (Nothing: not needed, or R15),
-- the architectural register for hazard checks (Nothing: an SPSR row) and
-- its state. A held value snoops every register-file write to its row.
data Opnd = Opnd
  { oRow   :: Maybe Row
  , oReg   :: Maybe (Index 16)
  , oState :: OpState
  } deriving (Generic, NFDataX)

-- | Decode -> E1 token. Operand slots: A (Rn, R14 for the Thumb BL/BLX
-- suffix, Rm for multiplies, the SPSR for MRS/MSR SPSR), B (the shifter
-- operand), S (the shift amount Rs) and D (store data, or the SPSR an
-- exception return copies).
data E1Tok = E1Tok
  { eDec :: DecTok
  , eOps :: Vec 4 Opnd
  } deriving (Generic, NFDataX)

-- | E1 -> E2 token.
data ShTok = ShTok
  { sDec   :: DecTok
  , sA     :: Word
  , sB     :: Word            -- ^ shifted operand 2
  , sCarry :: Bool            -- ^ shifter carry-out
  , sPass  :: Bool            -- ^ shifter passed the carry through: E2 uses CPSR.C
  , sD     :: Word            -- ^ store data or the SPSR of an exception return
  } deriving (Generic, NFDataX)

data MPhase = MRoute | MBoot | MBiosProt | MPostFlag | MLocal | MRam | MOffer | MAwait | MCheck | MBeat
  | MWriteBack | MRestore | MMulAcc | MMulHi | MSwiLink
  deriving (Eq, Generic, NFDataX)

-- | Mem stage: everything after the ALU that takes more than one cycle.
data MemSt = MemSt
  { mPhase     :: MPhase
  , mTag       :: Tag
  , mNext      :: Word          -- ^ next PC (a load to R15 replaces it)
  , pending    :: Access
  , loadLane   :: BitVector 2   -- ^ native ARM946 single word load, original byte offset
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

-- Architectural R15 of the actual load/store instruction, not the fetch
-- address or last retired PC. A held token retains its origin across stalls.
memoryR15 :: MemSt -> Word
memoryR15 m = tagPc (mTag m) + if tagThumb (mTag m) then 4 else 8

data RetTok = RetTok { rTag :: Tag, rNext :: Word }
  deriving (Generic, NFDataX)

-- | Fetch unit: the next address to fetch and its state, the local-RAM read
-- presented last cycle (its word is on the RAM port now), and whether
-- fetch has stopped after issuing a fault token or for IRQ entry.
data Fetch = Fetch
  { fpc    :: Word
  , fthumb :: Bool
  , fram   :: Maybe Word
  , fidle  :: Bool
  } deriving (Generic, NFDataX)

data Entry = EnterIrq Word | EnterAbort Bool Word -- data abort?; architectural LR
  deriving (Generic,NFDataX)

data Cpu = Cpu
  { psr       :: Psr
  , fetch     :: Fetch
  , xq        :: Maybe (Tag, BitVector 3)  -- ^ Thumb halfword (or fetch fault) awaiting expansion
  , iq        :: Maybe IrTok               -- ^ awaiting decode
  , e1        :: Maybe E1Tok
  , e2        :: Maybe ShTok
  , mq        :: Maybe MemSt
  , rq        :: Maybe RetTok
  , entry     :: Maybe Entry
  , storeObs  :: Maybe (Word, Word)        -- ^ local RAM store written last cycle
  , faultCode :: BitVector 3
  , faultAt   :: Word
  , mpu       :: M.Mpu
  , execPage  :: Maybe (BitVector 20, Bool, Bool) -- virtual page, user, executable
  , bios7Prot :: BitVector 16 -- ARM7 BIOSPROT: first nonzero write locks it until reset
  , postFlag :: BitVector 2 -- native per-CPU latch; a guest branch/SWI does not reset it
  } deriving (Generic, NFDataX)

-- | Reset: SVC mode, ARM state, IRQ and FIQ masked (CPSR 0x000000d3).
initialCpu :: Arch -> Cpu
initialCpu a = Cpu (Psr 0 True True False 0x13 0x2078) (Fetch (bootBase a) False Nothing False) Nothing Nothing
  Nothing Nothing Nothing Nothing Nothing Nothing 0 0 M.resetMpu Nothing 0 0

-- | One cycle's effects besides the next CPU state. Each RAM has one write
-- port; the register file has two read ports.
data Step = Step
  { stepCpu   :: Cpu
  , ramWrite  :: Maybe (Word, Word)    -- ^ aligned ARM byte address; narrow only at a local block RAM
  , regWrite  :: Maybe (Row, Word)
  , readA     :: Maybe Row
  , readB     :: Maybe Row
  , invalidateI :: Bool                -- ^ committed ARM9 MCR p15,0,Rd,c7,c5,0
  } deriving (Generic, NFDataX)

-- | The pure harness models both synchronous RAMs (local RAM and its read
-- register; register file and its two read registers); the generated top
-- uses block RAMs. Both call the same transition and observer. Both
-- register-file copies power up zero.
data SliceState = SliceState Cpu (Vec 1024 Word) Word (Vec 32 Word) Word Word
  deriving (Generic, NFDataX)

initialSlice :: SliceState
initialSlice = initialCore arm9Arch

initialCore :: Arch -> SliceState
initialCore a = SliceState (initialCpu a) (repeat 0) 0 (repeat 0) 0 0

-- | CPU/link reset does not clear block RAM (local RAM or register file).
-- Reset both endpoints of the GPU link together; a reply from before reset
-- must not be re-presented.
resetSlice :: SliceState -> SliceState
resetSlice = resetCore arm9Arch

resetCore :: Arch -> SliceState -> SliceState
resetCore a (SliceState _ mem _ rf _ _) = SliceState (initialCpu a) mem 0 rf 0 0

sliceBootAddr :: SliceState -> Word
sliceBootAddr (SliceState s _ _ _ _ _) = romAddress s

-- | Test observers: CPSR.I, and whether an IRQ was taken in the previous
-- cycle (its R14_irq is written this cycle).
sliceIrqMasked, sliceIrqEntering :: SliceState -> Bool
sliceIrqMasked (SliceState s _ _ _ _ _) = irqMask (psr s)
sliceIrqEntering (SliceState s _ _ _ _ _) = case entry s of Just (EnterIrq _) -> True; _ -> False

-- | One clock. The output depends only on the current state, so a host may
-- feed it back combinationally into this cycle's input (Arm9Soc does). The
-- next state is strict: matching it (the following call) checks that the
-- register file was not read and written at the same row in this cycle
-- (the block RAM's read-during-write result is then irrelevant; a
-- violation is a model error and fails every pure gate) and forces the CPU
-- record, the written RAM words and the read registers, so a long pure run
-- holds one state, not a chain of unevaluated 'replace's.
sliceStep :: SliceState -> SliceIn -> (SliceState, SliceOut)
sliceStep = coreStep arm9Arch

coreStep :: Arch -> SliceState -> SliceIn -> (SliceState, SliceOut)
coreStep a (SliceState s mem readWord rf ra rb) i = (next, observe s)
 where
  next
    | clash readA || clash readB = error "Arm9Slice: register file row read and written in one cycle"
    | otherwise = rnfX cpu' `seq` written mem' localWrite `seq` written rf' (regWrite st)
        `seq` word' `seq` ra' `seq` rb' `seq` SliceState cpu' mem' word' rf' ra' rb'
  st = transition a s i readWord ra rb
  cpu' = stepCpu st
  localWrite = localRamWrite st
  mem' = maybe mem (\(addr, value) -> replace addr value mem) localWrite
  rf' = maybe rf (\(row, value) -> replace row value rf) (regWrite st)
  word' = mem !! localRamIndex (ramAddress s)
  ra' = rf !! port readA
  rb' = rf !! port readB
  written :: (KnownNat n, Enum k) => Vec n Word -> Maybe (k, Word) -> ()
  written v = maybe () (\(k, _) -> (v !! k) `seq` ())
  port f = fromMaybe 0 (f st)
  clash f = case (f st, regWrite st) of
    (Just r, Just (w, _)) -> r == w
    _ -> False

-- | The core with its RAM window (0x02000000, 4 KiB) behind a port instead
-- of the local block RAM: the CPU state, the register file and its two read
-- registers. A host steps it only when the RAM word it needs is there and
-- its own RAM transactions for the step are issued (see 'coreExtRead' and
-- 'coreExtStep'); between steps the state, and so every output, holds.
data CoreExt = CoreExt Cpu (Vec 32 Word) Word Word
  deriving (Generic, NFDataX)

initialCoreExt :: Arch -> CoreExt
initialCoreExt a = CoreExt (initialCpu a) (repeat 0) 0 0

coreExtObserve :: CoreExt -> SliceOut
coreExtObserve (CoreExt s _ _ _) = observe s

coreExtBootAddr :: CoreExt -> Word
coreExtBootAddr (CoreExt s _ _ _) = romAddress s

coreExtIrqMasked :: CoreExt -> Bool
coreExtIrqMasked (CoreExt s _ _ _) = irqMask (psr s)

-- | The RAM read this step presents (aligned byte address), decided from
-- the state alone: a RAM fetch or a mem-stage RAM access. Its word is the
-- 'coreExtStep' input of the following step.
coreExtRead :: Arch -> CoreExt -> Maybe Word
coreExtRead a (CoreExt s _ _ _) = externalRead a s

-- | The RAM write the next step makes (aligned byte address, byte lanes, the
-- word with the stored bytes in their lanes), given the RAM word for the
-- previous step's read. It depends only on the state and that word, never
-- on the 'SliceIn' inputs, so a host issues it before the step; it is
-- computed with quiet inputs, as 'coreSliceExt' does.
coreExtWrite :: Arch -> CoreExt -> Word -> Maybe (Word, BitVector 4, Word)
coreExtWrite a (CoreExt s _ ra rb) readWord =
  externalWrite s (transition a s quietIn readWord ra rb)

-- | One step, given the RAM word for the previous step's read. The write
-- the step actually makes must be the one 'coreExtWrite' announced; a
-- difference is a model error.
coreExtStep :: Arch -> CoreExt -> SliceIn -> Word -> CoreExt
coreExtStep a c@(CoreExt s rf ra rb) i readWord = next
 where
  next
    | clash readA || clash readB = error "Arm9Slice: register file row read and written in one cycle"
    | write /= coreExtWrite a c readWord = error "Arm9Slice: the RAM write depends on the inputs"
    | otherwise = rnfX cpu' `seq` written (regWrite st) `seq` ra' `seq` rb' `seq` CoreExt cpu' rf' ra' rb'
  st = transition a s i readWord ra rb
  cpu' = stepCpu st
  rf' = maybe rf (\(row, value) -> replace row value rf) (regWrite st)
  ra' = rf !! port readA
  rb' = rf !! port readB
  written = maybe () (\(k, _) -> (rf' !! k) `seq` ())
  port f = fromMaybe 0 (f st)
  clash f = case (f st, regWrite st) of
    (Just r, Just (w, _)) -> r == w
    _ -> False
  write = externalWrite s st

externalRead :: Arch -> Cpu -> Maybe Word
externalRead a s
  | memReadsRam s || fetchReadsRam a s = Just (ramAddress s)
  | otherwise = Nothing

externalWrite :: Cpu -> Step -> Maybe (Word, BitVector 4, Word)
externalWrite s st = fmap (\(addr, v) -> (addr, ramLanes s, v)) (ramWrite st)

localRamIndex :: Word -> RamIndex
localRamIndex = fromIntegral . C.slice d11 d2

localRamWrite :: Step -> Maybe (RamIndex, Word)
localRamWrite = fmap (\(addr, v) -> (localRamIndex addr, v)) . ramWrite

-- | Byte lanes of the mem stage's RAM store (the only RAM writer).
ramLanes :: Cpu -> BitVector 4
ramLanes s = maybe 0xf (byteLanes . pending) (mq s)

-- | The boot ROM port serves instruction fetch, except while the mem stage
-- reads a ROM literal.
romAddress :: Cpu -> Word
romAddress s = case mq s of
  Just m | mPhase m == MBoot -> accessAddr (pending m)
  _ -> fpc (fetch s)

-- | The local RAM read port serves the mem stage while it presents an
-- access (phase MLocal) and instruction fetch otherwise.
ramAddress :: Cpu -> Word
ramAddress s = (if memReadsRam s then accessAddr (maybe accessNone pending (mq s))
                                else fpc (fetch s)) .&. complement 3

memReadsRam :: Cpu -> Bool
memReadsRam s = maybe False ((== MLocal) . mPhase) (mq s)

accessNone :: Access
accessNone = Access 0 4 False False 0 0

-- | Fetch presents a local-RAM read this cycle (decided from the state
-- alone, as the RAM address is).
fetchReadsRam :: Arch -> Cpu -> Bool
fetchReadsRam a s = not (memReadsRam s) && not (fidle f) && isNothing (entry s) && faultCode s == 0
  && inRam a (fpc f) && fetchAligned f && fetchPermission a s == Just True
 where f = fetch s

-- Register execute permission for the current virtual page. The eight
-- region comparisons are not on the RAM-grant path. Configuration writes
-- invalidate the grant and privilege forms part of its key.
mpuEnabled :: Arch -> Psr -> Bool
mpuEnabled a p = fabricMap a && armV5 a && testBit (control p) 0

fetchPermission :: Arch -> Cpu -> Maybe Bool
fetchPermission a s
  | not (mpuEnabled a (psr s)) = Just True
  | Just (pg,u,ok) <- execPage s, pg == C.slice d31 d12 (fpc (fetch s)), u == (mode (psr s) == 0x10) = Just ok
  | otherwise = Nothing

fetchAligned :: Fetch -> Bool
fetchAligned f = fpc f .&. (if fthumb f then 1 else 3) == 0

-- * Memory helpers

-- Legacy boot fixtures occupy 4 KiB. Only the real ARM7 BIOS spans 16 KiB.
inBoot :: Arch -> Word -> Bool
inBoot a addr
  | nativeBios a && not (armV5 a) = addr < 0x4000
  | otherwise = addr .&. 0xfffff000 == bootBase a

-- The Fabric, not the CPU, maps physical banks and mirrors. Keep all ARM
-- address bits on the external port, including on instruction fetches.
inRam :: Arch -> Word -> Bool
inRam a addr
  | fabricMap a = region == 0x02 || region == 0x03 || (ioMap a == Arm7Map && region == 0x06)
  | otherwise = addr .&. 0xfffff000 == ramBase
 where region = C.slice d31 d24 addr


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

-- | Spans the link owns. ARM9: the GPU target's registers, palettes, VRAM
-- and OAM, plus the timer, IRQ, IPC and game-card registers that devices in
-- front of the GPU (Arm9Io, Ipc, Card) may decode. ARM7: its timers, IRQ
-- and IPC registers. The target behind the link must reply with an error
-- for anything here it does not implement. The legacy ARM9 target excludes
-- WRAMCNT; only the wide board glue merges WRAMCNT and VRAMCNT lanes.
linkOwns :: Arch -> Access -> Bool
linkOwns arch a = ipc || nativeIo || case ioMap arch of
  Arm9Map -> C.slice d31 d24 addr == 0x06
    -- DISPCNT, DISPSTAT; VCOUNT (0x04000006) is read-only
    || within 0x04000000 (if accessWrite a then 0x04000006 else 0x04000008)
    || within 0x04000008 0x04000070  -- engine A BGCNT, scroll, window, blend
    || within 0x04000100 0x04000110  -- TM0CNT..TM3CNT
    || within 0x040001a0 0x040001a2  -- AUXSPICNT (AUXSPIDATA is not routed)
    || within 0x040001a4 0x040001b0  -- ROMCTRL, game-card command bytes
    || within 0x04000208 0x0400020c  -- IME
    || within 0x04000210 0x04000218  -- IE, IF
    || (addr == 0x04000304 && width /= 1)
    || within 0x04000240 (if fabricMap arch then 0x0400024a else 0x04000247)
    || (not (fabricMap arch) && within 0x04000248 0x0400024a)
    || within 0x04001000 0x04001070  -- engine B display registers
    || within 0x04100010 0x04100014  -- game-card data in
    || within 0x05000000 0x05000800  -- palettes
    || within 0x07000000 0x07000800  -- OAM
  Arm7Map -> within 0x04000100 0x04000110  -- TM0CNT..TM3CNT
    || within 0x04000208 0x0400020c  -- IME
    || within 0x04000210 0x04000218  -- IE, IF
 where
  -- The native board's responders, not the CPU, implement system IO and
  -- report unsupported registers. Instruction fetch never uses this link.
  nativeIo = nativeBios arch && (within 0x04000000 0x04010000 || within 0x04100000 0x04100014)
  -- IPCSYNC, IPCFIFOCNT, IPCFIFOSEND; IPCFIFORECV
  ipc = within 0x04000180 0x0400018c || within 0x04100000 0x04100004
  addr = accessAddr a
  width = resize (accessWidth a) :: Word
  within lo hi = addr >= lo && addr <= hi - width

-- | Fault code, or the mem phase that serves the access.
routeTo :: Arch -> Access -> Either (BitVector 3) MPhase
routeTo arch a
  | not (aligned a) = Left 2
  | inBoot arch addr && not (accessWrite a) = Right MBoot
  | nativeBios arch && not (armV5 arch) && addr == 0x04000308 && accessWidth a /= 1 = Right MBiosProt
  | nativeBios arch && addr == 0x04000300 =
      case accessWidth a of
        1 -> Right MPostFlag
        2 | armV5 arch || not (accessWrite a) || accessData a .&. 0xc000 == 0 -> Right MPostFlag
        4 | armV5 arch && not (accessWrite a) -> Right MPostFlag
        _ -> Left 3 -- not a POST access: e.g. combined ARM7 HALTCNT command
  | inRam arch addr = Right MLocal
  | fabricMap arch && ioMap arch == Arm7Map && (addr == 0x04000240 || addr == 0x04000241) &&
      accessWidth a == 1 && not (accessWrite a) = Right MLocal -- VRAMSTAT/WRAMSTAT byte reads
  | linkOwns arch a = Right MOffer
  | otherwise = Left 3
 where addr = accessAddr a

-- | LDM/STM beats serve only the boot ROM and local RAM. The link stays
-- single-transfer: a block whose beat would reach it faults 3 at that beat's
-- address, like any other address with no route, before the first beat.
blockFault :: Arch -> Bool -> Word -> BitVector 3
blockFault arch store addr = case routeTo arch (Access addr 4 store False 0 0) of
  Left code -> code
  Right MOffer -> 3
  Right MBiosProt -> 3
  Right MPostFlag -> 3
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

-- Abort mode is reachable only on the MPU-capable ARM9.
validMode :: Arch -> BitVector 5 -> Bool
validMode a m = m == 0x10 || m == 0x12 || m == 0x13 || m == 0x1f || (fabricMap a && armV5 a && m == 0x17)
hasSpsr :: BitVector 5 -> Bool
hasSpsr m = m == 0x12 || m == 0x13 || m == 0x17

-- | R13/R14 bank: User and System share one.
bankOf :: BitVector 5 -> Index 3
bankOf m = case m of
  0x13 -> 1
  0x12 -> 2
  _ -> 0

regRow :: BitVector 5 -> Index 16 -> Row
regRow m r
  | r < 13 = fromIntegral r
  | m == 0x17 = if r == 13 then 27 else 28
  | otherwise = fromIntegral r + 4 * fromIntegral (bankOf m)

spsrRow :: BitVector 5 -> Row
spsrRow m = if m == 0x17 then 29 else if m == 0x12 then 26 else 25

-- | Write a whole CPSR. The Q, J and reserved bits must be clear and the
-- mode in the subset; T may change only on an exception return. The banks
-- follow the mode through 'regRow'.
setCpsr :: Arch -> Bool -> Word -> Psr -> Maybe Psr
setCpsr arch allowT w s
  | C.slice d27 d8 w /= 0 || (testBit w 5 /= thumb s && not allowT) = Nothing
  | not (validMode arch m) = Nothing
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
-- passes the operand and carry through unchanged, and says so: the carry
-- is then CPSR.C at commit, not this cycle's.
barrel :: BitVector 2 -> BitVector 8 -> Bool -> Bool -> Word -> (Word, Bool, Bool)
barrel kind amount0 immForm carry rm
  | rrx = (pack carry ++# C.slice d31 d1 rm, testBit rm 0, False)
  | amount == 0 = (rm, carry, True)
  | otherwise = case kind of
      0 -> let y = shiftL (0 ++# rm :: BitVector 33) n in (C.slice d31 d0 y, testBit y 32, False)
      1 -> let y = shiftR (rm ++# 0 :: BitVector 33) n in (C.slice d32 d1 y, testBit y 0, False)
      2 -> let y = pack (shiftR (unpack (rm ++# 0) :: Signed 33) (min n 32))
           in (C.slice d32 d1 y, testBit y 0, False)
      _ -> let r = rotateR rm (fromIntegral (C.slice d4 d0 amount)) in (r, testBit r 31, False)
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
expandStage :: Arch -> Tag -> IrTok
expandStage arch tag = case top5 of
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
  arm x = IrTok tag x AuxArm 0xe 0 0
  wordPc x = IrTok tag x AuxWordPc 0xe 0 0
  special aux cond imm = IrTok tag 0 aux cond imm 0
  undef = IrTok tag 0 AuxUndef 0xe 0 0
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
armToken tag = IrTok tag (tagOp tag) AuxArm (C.slice d31 d28 (tagOp tag)) 0 0

-- | A fetch fault as a token: unpredicated, faulting at commit.
faultToken :: Tag -> BitVector 3 -> IrTok
faultToken tag code = IrTok tag 0 AuxUndef 0xe 0 code

-- | Implemented-form check and class of an ARM opcode (Thumb: the
-- rewritten one), in the guard order that also resolves overlapping
-- encodings. Every UNPREDICTABLE or unimplemented combination is 'CUndef'
-- and faults 1 if its condition passes.
classify :: Arch -> Bool -> BitVector 5 -> Word -> Cls
classify arch th m op
  | op .&. 0x0f000000 == 0x0f000000 = CSwi
  | op .&. 0x0ffffff0 == 0x012fff10 && (rm /= 15 || th) = CBx
  | op .&. 0x0ffffff0 == 0x012fff30 && rm /= 15 && armV5 arch = CBx
  | op .&. 0x0fff0ff0 == 0x016f0f10 && armV5 arch = valid (rd /= 15 && rm /= 15) CClz
  | not th && fabricMap arch && armV5 arch && (op .&. 0x0fef0fff == 0x0e010f10 || M.isMpuTransfer op) =
      valid (m /= 0x10 && (load || rd /= 15)) CControl
  | not th && fabricMap arch && armV5 arch &&
      (cpOp == 0x0e070f15 || cpOp == 0x0e070f16 || cpOp == 0x0e070f9a) =
      valid (m /= 0x10 && rd /= 15) CCacheOp
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
  cpOp = op .&. 0x0fff0fff
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

-- | Decode stage: class, condition, the value R15 reads, the immediate and
-- the operand slots (register-file rows in the current mode; a mode change
-- flushes every younger token, so the rows stay right).
decodeStage :: Arch -> BitVector 5 -> IrTok -> E1Tok
decodeStage arch m (IrTok tag op aux cond imm fault)
  | fault /= 0 = E1Tok (DecTok tag 0 CUndef 0xe pcRead 0 False False False Nothing False fault) (repeat noOpnd)
  | otherwise = E1Tok tok (if cls == CUndef then repeat noOpnd else slotA :> slotB :> slotS :> slotD :> Nil)
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
      | otherwise -> classify arch th m op
  -- The cond = 1111 space is not predicated: BLX <imm> always executes,
  -- the rest faults.
  cond' = if not th && cond == 0xf then 0xe else cond
  rd = fromIntegral (C.slice d15 d12 op) :: Index 16
  rn = fromIntegral (C.slice d19 d16 op) :: Index 16
  rm = fromIntegral (C.slice d3 d0 op) :: Index 16
  rs = fromIntegral (C.slice d11 d8 op) :: Index 16
  regList = C.slice d15 d0 op
  listBytes = sum (map (\b -> if b then 4 else 0) (unpack regList :: Vec 16 Bool)) :: Word
  registerShift = not (testBit op 25) && testBit op 4
  setFlags = testBit op 20
  testOp = C.slice d24 d23 op == 2
  spsrSelected = testBit op 22
  thumbBranch = aux == AuxBranch || aux == AuxBlSuffix || aux == AuxBlxSuffix || aux == AuxBlPrefix
  -- Operand 2 immediate (rotated or shifted later by E1).
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
  -- Slot A: R15 or no register reads pcRead; branches add to pcRead,
  -- except the Thumb BL/BLX suffix, which adds to R14.
  suffix = aux == AuxBlSuffix || aux == AuxBlxSuffix
  regSlot r = if r == 15 then noOpnd else Opnd (Just (regRow m r)) (Just r) OEmpty
  spsrSlot = Opnd (Just (spsrRow m)) Nothing OEmpty
  slotA = case cls of
    CBranch | suffix -> regSlot 14
    CDp -> regSlot rn
    CSingle -> regSlot rn
    CBlock -> regSlot rn
    CMul -> regSlot rm
    CMulLong -> regSlot rm
    CMrs | spsrSelected -> spsrSlot
    CMsr | spsrSelected -> spsrSlot
    CControl | not (testBit op 20) -> regSlot rd
    _ -> noOpnd
  -- Slot B: the shifter operand register.
  bReg = case cls of
    CDp | bImm -> Nothing
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
  slotB = maybe noOpnd regSlot bReg
  slotS = if cls == CDp && registerShift then regSlot rs else noOpnd
  slotD
    | cls == CSingle && not (testBit op 20) = regSlot rd
    | cls == CDp && setFlags && rd == 15 && not testOp = spsrSlot
    | otherwise = noOpnd
  tok = DecTok
    { dTag = tag, dOp = op, dCls = cls, dCond = cond', dPcRead = pcRead, dImm = immValue
    , dBImm = bImm
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
    , dFault = 0
    }

noOpnd :: Opnd
noOpnd = Opnd Nothing Nothing OEmpty

-- | The value an operand has this cycle, if it has one.
opValue :: Word -> Word -> Opnd -> Maybe Word
opValue portA portB o = case oState o of
  OValid v -> Just v
  OPendA -> Just portA
  OPendB -> Just portB
  OEmpty -> Nothing

-- | The value that was on an operand's port this cycle is latched.
opLatch :: Word -> Word -> Opnd -> Opnd
opLatch portA portB o = case oState o of
  OPendA -> o { oState = OValid portA }
  OPendB -> o { oState = OValid portB }
  _ -> o

-- | A register-file write to an operand's row replaces whatever it held or
-- was about to read.
opSnoop :: Maybe (Row, Word) -> Opnd -> Opnd
opSnoop w o = case (oRow o, w) of
  (Just r, Just (wr, v)) | r == wr -> o { oState = OValid v }
  _ -> o

-- | A write to an operand's row in this cycle, else the given value.
snoop :: Maybe (Row, Word) -> Opnd -> Word -> Word
snoop w o v = case (oRow o, w) of
  (Just r, Just (wr, x)) | r == wr -> x
  _ -> v

-- | Present reads for up to two operands still to be read, on the ports
-- left free by older stages. A read of the row written this cycle is not
-- presented: the operand takes the written value instead ('opSnoop').
presentOps :: Maybe Row -> Maybe Row -> Maybe (Row, Word) -> Vec 4 Opnd -> (Vec 4 Opnd, Maybe Row, Maybe Row)
presentOps usedA usedB w ops = (ops', keep ra, keep rb)
 where
  ((_, _, ra, rb), ops') = mapAccumL go (isNothing usedA, isNothing usedB, Nothing, Nothing) ops
  go st@(af, bf, ra0, rb0) o = case (oRow o, oState o) of
    (Just r, OEmpty) | af -> ((False, bf, Just r, rb0), o { oState = OPendA })
                     | bf -> ((af, False, ra0, Just r), o { oState = OPendB })
    _ -> (st, o)
  keep r = case (r, w) of
    (Just x, Just (wr, _)) | x == wr -> Nothing
    _ -> r

-- | Shifter set-up: kind, immediate amount, amount from Rs, immediate-shift
-- encoding.
shiftPlan :: DecTok -> (BitVector 2, BitVector 8, Bool, Bool)
shiftPlan d = case dCls d of
  CDp | testBit op 25 -> rotateImm
      | not (testBit op 25) && testBit op 4 -> (C.slice d6 d5 op, 0, True, False)
      | otherwise -> immShift
  CMsr | testBit op 25 -> rotateImm
  CSingle | op .&. 0x0c000000 == 0x04000000 && testBit op 25 -> immShift
  _ -> (0, 0, False, False)
 where
  op = dOp d
  rotateImm = (3, zeroExtend (C.slice d11 d8 op ++# (0 :: BitVector 1)), False, False)
  immShift = (C.slice d6 d5 op, zeroExtend (C.slice d11 d7 op), False, True)

-- | The shift needs CPSR.C for its value (RRX), not just its carry-out.
usesCarryIn :: DecTok -> Bool
usesCarryIn d = let (kind, amount, _, immForm) = shiftPlan d in immForm && kind == 3 && amount == 0

-- | E1 operand values this cycle (Nothing: some operand not here yet).
e1Values :: Word -> Word -> E1Tok -> Maybe (Word, Word, Word, Word)
e1Values portA portB (E1Tok d ops) = (,,,) <$> slot 0 (dPcRead d) <*> slot 1 0 <*> slot 2 0 <*> slot 3 0
 where
  slot k dflt = let o = ops !! (k :: Index 4) in maybe (Just dflt) (const (opValue portA portB o)) (oRow o)

-- | E1: the shifted operand 2. A and the store data/SPSR take a write to
-- their row made in this very cycle (the instruction ahead committing).
e1Shift :: Bool -> Maybe (Row, Word) -> E1Tok -> (Word, Word, Word, Word) -> ShTok
e1Shift carry w (E1Tok d ops) (a, bv, sv, dv) =
  ShTok d (snoop w (ops !! (0 :: Index 4)) a) b c pass (snoop w (ops !! (3 :: Index 4)) dv)
 where
  (kind, immAmount, regAmount, immForm) = shiftPlan d
  amount = if regAmount then C.slice d7 d0 sv else immAmount
  bIn
    | dBImm d = dImm d
    | dB15 d = dPcRead d
    | otherwise = bv
  (b, c, pass) = barrel kind amount immForm carry bIn

bitReg :: Index 16 -> BitVector 16
bitReg r = shiftL 1 (fromIntegral r)

-- | Registers an E2 token writes when it commits (ALU results).
immDests :: DecTok -> BitVector 16
immDests d = case dCls d of
  CDp | C.slice d24 d23 op /= 2 && rd /= 15 -> bitReg rd
  CMrs -> bitReg rd
  CControl | testBit op 20 && rd /= 15 -> bitReg rd
  CClz -> bitReg rd
  CLinkOnly -> bitReg 14
  CBranch | dLink d -> bitReg 14
  CBx | dLink d -> bitReg 14
  _ -> 0
 where
  op = dOp d
  rd = fromIntegral (C.slice d15 d12 op) :: Index 16

-- | Registers an E2 token writes later, from the mem stage.
deferredDests :: DecTok -> BitVector 16
deferredDests d = case dCls d of
  CSingle -> (if testBit op 20 && rd /= 15 then bitReg rd else 0)
    .|. (if not (testBit op 24) || testBit op 21 then bitReg rn else 0)
  CBlock -> (if testBit op 20 then C.slice d15 d0 op .&. 0x7fff else 0) .|. (if testBit op 21 then bitReg rn else 0)
  CMul -> bitReg rn
  CMulLong -> bitReg rn .|. bitReg rd
  CSwi -> bitReg 14
  _ -> 0
 where
  op = dOp d
  rd = fromIntegral (C.slice d15 d12 op) :: Index 16
  rn = fromIntegral (C.slice d19 d16 op) :: Index 16

-- | Registers the mem stage still writes (this cycle or later).
memDests :: MemSt -> BitVector 16
memDests m = case mPhase m of
  MMulAcc -> bitReg (fld (C.slice d19 d16 mo)) .|. (if testBit mo 23 then bitReg (fld (C.slice d15 d12 mo)) else 0)
  MMulHi -> bitReg (fld (C.slice d19 d16 mo))
  MSwiLink -> bitReg 14
  MRestore -> 0
  MWriteBack -> bitReg (wbReg m)
  _ -> loads .|. (if writeBack m then bitReg (wbReg m) else 0)
 where
  mo = mulOp m
  fld :: BitVector 4 -> Index 16
  fld = fromIntegral
  acc = pending m
  loads
    | blockLeft m /= 0 = if blockStore m then 0 else blockLeft m .&. 0x7fff
    | not (accessWrite acc) && accessReg acc /= 15 = bitReg (accessReg acc)
    | otherwise = 0

-- | Instructions that may write NZCV.
flagWriter :: DecTok -> Bool
flagWriter d = case dCls d of
  CDp -> testBit (dOp d) 20
  CMsr -> not (testBit (dOp d) 22)
  CControl -> testBit (dOp d) 20 && C.slice d15 d12 (dOp d) == 15
  CMul -> testBit (dOp d) 20
  CMulLong -> testBit (dOp d) 20
  _ -> False

memFlagWriter :: MemSt -> Bool
memFlagWriter m = (mPhase m == MMulAcc && testBit (mulOp m) 20) || blockSpsr m || restore m

-- | E2 instructions that redirect fetch when their condition passes: B/BL
-- and the Thumb branch forms, BX/BLX, data processing to R15 (exception
-- returns included) and every MSR (a mode change moves the register rows;
-- SPSR writes flush by specification).
redirectsFetch :: DecTok -> Bool
redirectsFetch d = case dCls d of
  CBranch -> True
  CBx -> True
  CMsr -> True
  CCacheOp -> C.slice d3 d0 (dOp d) == 5 -- only I invalidate discards younger words
  CDp -> C.slice d15 d12 (dOp d) == 15 && C.slice d24 d23 (dOp d) /= 2
  _ -> False

-- | Mem-stage retirements that branch: a load to R15 (LDR pc, or the last
-- LDM/POP beat, also when base writeback follows), the LDM^ CPSR restore
-- and SWI entry.
memJumps :: MemSt -> Bool
memJumps m = case mPhase m of
  MSwiLink -> True
  MRestore -> True
  _ -> accessReg (pending m) == 15 && not (accessWrite (pending m))

-- | What the ALU stage hands on.
data AluNext = ToRetire Word | ToMem MemSt | ToFault (BitVector 3) Word
  deriving (Generic, NFDataX)

-- | E2, the commit point: fetch-fault tokens, the condition check, the one
-- adder/logic unit, flags, the register write, branches, PSR transfers,
-- and the start of memory, multiply and SWI work. For MRS/MSR SPSR the
-- SPSR is operand A; an exception return's SPSR and a store's data come in
-- 'sD'. A multiply presents its accumulator rows for the mem stage.
aluStage :: Arch -> M.Mpu -> Psr -> ShTok -> (Psr, Maybe (Row, Word), Maybe Row, Maybe Row, AluNext)
aluStage arch protection s (ShTok d a b sc pass dv)
  | dFault d /= 0 = (s, Nothing, Nothing, Nothing, ToFault (dFault d) (tagPc tag))
  | not (condPasses (dCond d) (flags s)) = (s, Nothing, Nothing, Nothing, ToRetire next)
  | otherwise = case dCls d of
      CUndef -> faultHere
      CDp
        | testOp -> (flagged, Nothing, Nothing, Nothing, ToRetire next)
        | rd == 15 && setFlags -> case setCpsr arch True dv s of
            Nothing -> faultHere
            Just s' -> (s', Nothing, Nothing, Nothing, ToRetire (result .&. pcMask (thumb s')))
        | rd == 15 -> (flagged, Nothing, Nothing, Nothing, ToRetire (result .&. pcMask th))
        | otherwise -> (flagged, write rd result, Nothing, Nothing, ToRetire next)
      CMrs -> (s, write rd (if spsrSelected then a else cpsrWord s), Nothing, Nothing, ToRetire next)
      CCacheOp
        -- All data bypasses and no data lines exist. Never acknowledge
        -- invalidate-all in an enabled or dirty D-cache configuration.
        | C.slice d3 d0 op == 6 && testBit (control s) 2 -> faultHere
        -- Drain c7,c10,4: the mem stage must be empty to reach E2; external
        -- steps cannot advance beyond the previous step until every earlier
        -- store response arrived (DualSoc.arbStep, prevOut). No posted
        -- write buffer exists. I invalidation also emits the commit pulse.
        | otherwise -> (s, Nothing, Nothing, Nothing, ToRetire next)
      CControl
        | load && rd == 15 -> (s { flags = C.slice d31 d28 cpValue }, Nothing, Nothing, Nothing, ToRetire next)
        | load -> (s, write rd cpValue, Nothing, Nothing, ToRetire next)
        | C.slice d19 d16 op /= 1 -> if M.validMpuWrite op a then (s, Nothing, Nothing, Nothing, ToRetire next) else faultHere
        -- No architectural I/D caches, big-endian bus or TCM load modes.
        | a .&. 0x000a1084 /= 0 -> faultHere
        | otherwise -> (s { control = (a .&. 0x000ff085) .|. 0x78 }, Nothing, Nothing, Nothing, ToRetire next)
      CMsr
        | not spsrSelected -> case setCpsr arch False (merged cpsrMask (cpsrWord s) b) s of
            Nothing -> faultHere
            Just s' -> (s', Nothing, Nothing, Nothing, ToRetire next)
        | otherwise -> (s, Just (spsrRow (mode s), merged fieldMask a b), Nothing, Nothing, ToRetire next)
      CClz -> (s, write rd (leadingZeros b), Nothing, Nothing, ToRetire next)
      CBranch -> branchTo (if dAlign4 d then result .&. complement 3 else result)
      CBx -> branchTo b
      CLinkOnly -> (s, write 14 result, Nothing, Nothing, ToRetire next)
      CSwi -> (s, Just (spsrRow 0x13, cpsrWord s), Nothing, Nothing, ToMem (mem MSwiLink))
      CSingle -> (s, Nothing, Nothing, Nothing, ToMem (mem MRoute)
        { pending = Access busAddr width (not load) signed rd (if load then 0 else dv .&. widthMask width)
        , loadLane = if nativeSingle && load && width == 4 then C.slice d1 d0 effective else 0
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
  cpValue = if C.slice d19 d16 op == 1 then control s else M.readMpu protection op
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
  -- ARM946E-S c1[1] is reserved SBZ (DDI0201D table 2-9). Bus address
  -- alignment never rounds the base/writeback value or rotates store data.
  nativeSingle = nativeBios arch && armV5 arch
  effective = if preIndex then result else a
  busAddr | not nativeSingle = effective
          | width == 4 = effective .&. 0xfffffffc
          | width == 2 = effective .&. 0xfffffffe
          | otherwise = effective
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
  (result, carryOut, overflow, arithmetic) = aluOp opc carry (if pass then carry else sc) a b
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
  mem p = MemSt p tag next (Access 0 4 False False 0 0) 0 0 0 False 0 0 False 0 0 False False op 0
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
  , moStore  :: Maybe (Word, Word)
  , moReadA  :: Maybe Row
  , moReadB  :: Maybe Row
  } deriving (Generic, NFDataX)

memStage :: Arch -> M.Mpu -> BitVector 16 -> BitVector 2 -> SliceIn -> Word -> Word -> Word -> Psr -> MemSt -> MemOut
memStage arch prot biosProt post i ramWord portA portB s m = case mPhase m of
  MRoute -> case protectedRoute acc of
    Left code -> faulted code (accessAddr acc)
    Right p -> stay m { mPhase = p }
  MBoot -> loaded
  MBiosProt -> if accessWrite acc then complete m else loaded
  MPostFlag -> if accessWrite acc then complete m else loaded
  MLocal -> stay m { mPhase = MRam }
  MRam
    | accessWrite acc -> (complete m) { moStore = Just (accessAddr acc .&. 0xfffffffc, stored) }
    | otherwise -> loaded
  MOffer -> stay (if gpuReqReady i then m { mPhase = MAwait } else m)
  MAwait
    | not (gpuReplyValid i) -> stay m
    | gpuReplyFault i -> faulted 4 (accessAddr acc)
    | accessWrite acc -> complete m
    | otherwise -> loaded
  MCheck | mpuEnabled arch s -> (stay m {mPhase=MBeat}) {moReadB=beatRead (blockLeft m)}
  MCheck -> case blockFault arch (blockStore m) (checkAddr m) of
    0 -> let rest = checkLeft m .&. (checkLeft m - 1) in
      if rest == 0
        then (stay m { mPhase = MBeat, checkLeft = 0 }) { moReadB = beatRead (blockLeft m) }
        else stay m { checkLeft = rest, checkAddr = checkAddr m + 4 }
    code -> faulted code (checkAddr m)
  MBeat ->
    let r = lowestReg (blockLeft m)
        beat = Access (blockAddr m) 4 (blockStore m) False r (if blockStore m then portB else 0)
    in case protectedRoute beat of
         Left code -> faulted code (blockAddr m)
         Right MOffer -> faulted 3 (blockAddr m) -- no block transfer to IO in this core
         Right MPostFlag -> faulted 3 (blockAddr m)
         Right p -> stay m { mPhase = p, pending = beat }
  MWriteBack -> (finish m { writeBack = False }) { moReg = Just (regRow (mode s) (wbReg m), wbValue m) }
  MRestore -> case setCpsr arch True portA s of
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
    , moRetire = Just (RetTok (mTag m) (exceptionBase arch s + 8)) }
 where
  acc = pending m
  protectedRoute x
    | mpuEnabled arch s && not (M.allowed prot (mode s == 0x10) False (accessWrite x) (accessAddr x)) = Left 6
    | otherwise = routeTo arch x
  stored = mergeStore acc ramWord
  out s' = MemOut s' Nothing Nothing Nothing Nothing Nothing Nothing Nothing
  stay m' = (out s) { moMem = Just m' }
  faulted code addr = (out s) { moFault = Just (code, addr) }
  retireWith s' = (out s') { moRetire = Just (RetTok (mTag m) (mNext m)) }
  beatRead l = if blockStore m then Just (regRow (mode s) (lowestReg l)) else Nothing
  -- The loaded value: boot ROM, local RAM or link reply.
  raw = case mPhase m of
    MBoot -> extract acc (if blockedBios then maxBound else bootWord i)
    MBiosProt -> zeroExtend biosProt
    MPostFlag -> zeroExtend post
    MRam -> extract acc ramWord
    _ -> gpuReplyData i
  -- The data access belongs to the executing instruction, not the
  -- speculative fetch PC (which may already have left the BIOS).
  instructionPc = memoryR15 m
  blockedBios = nativeBios arch && not (armV5 arch) &&
    (instructionPc >= 0x4000 || (accessAddr acc < zeroExtend biosProt && instructionPc >= zeroExtend biosProt))
  masked = raw .&. widthMask (accessWidth acc)
  value
    | nativeBios arch && armV5 arch && accessWidth acc == 4 =
        rotateR raw (fromIntegral (loadLane m ++# (0 :: BitVector 3)))
    | not (accessSigned acc) = masked
    | accessWidth acc == 1 = pack (resize (unpack (C.slice d7 d0 masked) :: Signed 8) :: Signed 32)
    | otherwise = pack (resize (unpack (C.slice d15 d0 masked) :: Signed 16) :: Signed 32)
  -- A load to R15 (word LDR, or the last LDM/POP beat) branches: LDM
  -- {.., pc}^ restores the CPSR from the SPSR at the end; otherwise ARMv5
  -- interworks on bit 0, while ARMv4T keeps the state and drops bit 0 (as
  -- melonDS's ARM7 does; bit 1 set in ARM state still faults at fetch).
  loaded
    | accessReg acc /= 15 = (complete m) { moReg = Just (regRow (mode s) (accessReg acc), value) }
    | blockSpsr m = complete m { mNext = value, restore = True }
    | armV5 arch && not (fabricMap arch && testBit (control s) 15) =
        (complete m { mNext = value .&. 0xfffffffe }) { moPsr = s { thumb = testBit value 0 } }
    | otherwise = complete m { mNext = value .&. 0xfffffffe }
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

-- | One clock of the whole CPU. Every stage works on its own token; a
-- stage advances when the next one is free or advancing. Port priority on
-- the register file: mem stage, E2 (multiply accumulators), E1, decode.
transition :: Arch -> Cpu -> SliceIn -> Word -> Word -> Word -> Step
transition arch s1 i ramWord portA portB
  | faultCode s /= 0 = Step s Nothing Nothing Nothing Nothing False
  | Just ex <- entry s =
      let (m,lr,off) = case ex of
            EnterIrq l -> (0x12,l,0x18)
            EnterAbort dat l -> (0x17,l,if dat then 0x10 else 0x0c)
      in Step s { psr = enterMode m p, entry = Nothing, fetch = Fetch (exceptionBase arch p + off) False Nothing False }
           Nothing (Just (regRow m 14, lr)) Nothing Nothing False
  -- A denied fetch takes its exception only if its token reaches commit.
  -- A denied data beat never reached RAM/IO. Preserve completed older
  -- beats; no final base writeback or retirement of the faulting operation.
  | fabricMap arch && armV5 arch, Just (c,_) <- faulted, c == 5 || c == 6 =
      let dat = c == 6
          pc = if dat then maybe 0 (tagPc . mTag) (mq s) else tagPc e2Tag
      in Step s { xq=Nothing, iq=Nothing, e1=Nothing, e2=Nothing, mq=Nothing, rq=Nothing
                , fetch=f { fram=Nothing, fidle=True }, entry=Just (EnterAbort dat (pc + if dat then 8 else 4)) }
           Nothing (Just (spsrRow 0x17,cpsrWord p)) Nothing Nothing False
  | Just (c, addr) <- faulted =
      Step s { faultCode = c, faultAt = addr, storeObs = mStore, rq = Nothing } Nothing Nothing Nothing Nothing False
  | otherwise = Step s' mStore regW readA' readB' invI
 where
  -- A store is observed for exactly the one cycle after its RAM write.
  s = s1 { storeObs = Nothing }
  p = psr s
  f = fetch s
  seqNext tag = tagPc tag + stepOf (tagThumb tag)

  -- Mem stage: the oldest instruction in flight, if any.
  mOut = fmap (memStage arch (mpu s) (bios7Prot s) (postFlag s) i ramWord portA portB p) (mq s)
  pM = maybe p moPsr mOut
  mRet = mOut >>= moRetire
  mStore = mOut >>= moStore
  -- A store into local RAM over an instruction already fetched (or being
  -- fetched) refetches everything younger after it.
  smcHit = case mStore of
    Just (addr, _) -> any (== Just (codeWord addr)) (map (fmap codeWord) fetchedPcs)
    Nothing -> False
  -- An ARM9/ARM7 may store through a different main RAM mirror of its
  -- own fetched instruction. VRAM bank aliases are Fabric-owned.
  codeWord addr | fabricMap arch && C.slice d31 d24 addr == 0x02 = addr .&. 0xff3ffffc
                -- A smaller comparison may conservatively refetch, but
                -- never misses an alias in a 16/32/64 KiB WRAM mapping.
                | fabricMap arch && C.slice d31 d24 addr == 0x03 = 0x03000000 .|. (addr .&. 0x3ffc)
                | otherwise = addr .&. complement 3
  fetchedPcs = fmap (tagPc . fst) (xq s) :> fmap (tagPc . irTag) (iq s)
    :> fmap (tagPc . dTag . eDec) (e1 s) :> fmap (tagPc . dTag . sDec) (e2 s)
    :> fram f :> (if fetchReadsRam arch s then Just (fpc f) else Nothing) :> Nil
  mRedirect = case (mq s, mRet) of
    (Just m, Just (RetTok _ next)) | memJumps m -> Just (next, thumb pM)
    (Just m, _) | smcHit -> Just (seqNext (mTag m), tagThumb (mTag m))
    _ -> Nothing

  -- E2: commits only with the mem stage empty; an IRQ is taken instead.
  e2Ready = isJust (e2 s) && isNothing (mq s)
  irqTake = e2Ready && irqRequest i && not (irqMask p)
  e2Res = if e2Ready && not irqTake then fmap (aluStage arch (mpu s) p) (e2 s) else Nothing
  e2Fire = isJust e2Res
  e2Tag = maybe (Tag 0 0 False) (dTag . sDec) (e2 s)
  (p2, e2Write, e2ReadA, e2ReadB, e2Next) = fromMaybe (p, Nothing, Nothing, Nothing, ToRetire 0) e2Res
  -- A passed branch, PC write or MSR redirects fetch and flushes everything
  -- younger. This is decided from the class and condition alone, not by
  -- comparing the target with the next PC, so the ALU result feeds only the
  -- fetch PC (a fault outranks it).
  e2Redirect = case e2 s of
    Just t | e2Fire && condPasses (dCond (sDec t)) (flags p) && (redirectsFetch (sDec t) || syncMpu) -> Just (e2Target, thumb p2)
    _ -> Nothing
  invI = isJust e2Redirect && maybe False ((== CCacheOp) . dCls . sDec) (e2 s)
  cpWrite = case (e2 s,e2Next) of
    (Just t,ToRetire _) | e2Fire && dCls (sDec t) == CControl && not (testBit (dOp (sDec t)) 20)
                           && condPasses (dCond (sDec t)) (flags p) -> Just (dOp (sDec t), sA t)
    _ -> Nothing
  syncMpu = isJust cpWrite && (mpuEnabled arch p || mpuEnabled arch p2)
  e2Target = case e2Next of
    ToRetire target -> target
    _ -> 0
  faulted = case (mOut >>= moFault, e2Next) of
    (Just x, _) -> Just x
    (_, ToFault c addr) | e2Fire -> Just (c, addr)
    _ -> Nothing

  -- The one register-file write this cycle.
  regW = case (e2Write, mOut >>= moReg) of
    (Just w, _) -> Just w
    (_, Just w) -> Just w
    _ | irqTake -> Just (spsrRow 0x12, cpsrWord p)
      | otherwise -> Nothing
  usedA = (mOut >>= moReadA) `orElse` e2ReadA
  usedB = (mOut >>= moReadB) `orElse` e2ReadB
  orElse a b = maybe b Just a

  -- Flushes: everything younger than the mem stage (PC load, LDM^, SWI,
  -- store into fetched code, IRQ), or younger than E2 (taken branch, PC
  -- write, MSR, exception return).
  flushFromM = isJust mRedirect || irqTake
  flushYoung = flushFromM || isJust e2Redirect
  redirect = mRedirect `orElse` e2Redirect

  -- E1: advances when E2 frees, its operands are here and no older
  -- instruction still owes a write to them (or, for RRX, to the flags).
  e2Frees = isNothing (e2 s) || e2Fire
  e2Imm = maybe 0 (immDests . sDec) (e2 s)
  e2Def = maybe 0 (deferredDests . sDec) (e2 s)
  mPend = maybe 0 memDests (mq s)
  flagsBusy = maybe False (flagWriter . sDec) (e2 s) || maybe False memFlagWriter (mq s)
  hazard t = or (zipWith owed (0 :> 1 :> 2 :> 3 :> Nil) (eOps t))
    || (usesCarryIn (eDec t) && flagsBusy)
   where
    owed :: Index 4 -> Opnd -> Bool
    owed k o = case oReg o of
      Just r -> (mPend .|. e2Def .|. (if k == 1 || k == 2 then e2Imm else 0)) ! r == 1
      Nothing -> False
  e1Vals = e1 s >>= e1Values portA portB
  e1Adv = case (e1 s, e1Vals) of
    (Just t, Just _) -> e2Frees && not flushYoung && not (hazard t)
    _ -> False
  e1Out = case (e1 s, e1Vals) of
    (Just t, Just v) | e1Adv -> Just (e1Shift (testBit (flags p) 1) regW t v)
    _ -> Nothing
  -- A waiting E1 token latches what arrived and asks for what is missing.
  (e1Held, e1RA, e1RB) = case e1 s of
    Just t | not e1Adv && not flushYoung ->
      let (ops, ra, rb) = presentOps usedA usedB regW (map (opLatch portA portB) (eOps t))
      in (Just t { eOps = map (opSnoop regW) ops }, ra, rb)
    _ -> (Nothing, Nothing, Nothing)

  -- Decode: hands its token to E1 with the first operand reads.
  dAdv = isJust (iq s) && (isNothing (e1 s) || e1Adv) && not flushYoung
  (dTok, dRA, dRB) = case iq s of
    Just t | dAdv ->
      let E1Tok d ops0 = decodeStage arch (mode p) t
          (ops, ra, rb) = presentOps usedA usedB regW ops0
      in (Just (E1Tok d (map (opSnoop regW) ops)), ra, rb)
    _ -> (Nothing, Nothing, Nothing)
  readA' = usedA `orElse` e1RA `orElse` dRA
  readB' = usedB `orElse` e1RB `orElse` dRB

  -- Thumb expansion.
  xAdv = isJust (xq s) && (isNothing (iq s) || dAdv) && not flushYoung
  xTok = case xq s of
    Just (t, code) | xAdv -> Just (if code /= 0 then faultToken t code else expandStage arch t)
    _ -> Nothing

  -- Fetch.
  accept = if fthumb f then isNothing (xq s) || xAdv else isNothing (iq s) || dAdv
  presented = fetchReadsRam arch s
  romFree = not (maybe False ((== MBoot) . mPhase) (mq s))
  step = stepOf (fthumb f)
  deposit a w = if fthumb f
    then (Just (Tag a (zeroExtend (if testBit a 1 then C.slice d31 d16 w else C.slice d15 d0 w)) True, 0), Nothing)
    else (Nothing, Just (armToken (Tag a w False)))
  depositFault code = if fthumb f
    then (Just (Tag (fpc f) 0 True, code), Nothing)
    else (Nothing, Just (faultToken (Tag (fpc f) 0 False) code))
  none = (Nothing, Nothing)
  ((fx, fi), f')
    | Just (target, t) <- redirect = (none, Fetch target t Nothing False)
    | irqTake = (none, f { fram = Nothing, fidle = True })
    | Just a <- fram f = if accept
        then (deposit a ramWord, f { fram = if presented then Just (fpc f) else Nothing
                                   , fpc = if presented then fpc f + step else fpc f })
        else (none, f { fram = Nothing, fpc = a })
    | presented = (none, f { fram = Just (fpc f), fpc = fpc f + step })
    | fidle f = (none, f)
    | not (fetchAligned f) = if accept then (depositFault 2, f { fidle = True }) else (none, f)
    | Nothing <- fetchPermission arch s = (none,f)
    | Just False <- fetchPermission arch s = if accept then (depositFault 5, f { fidle=True }) else (none,f)
    | inRam arch (fpc f) = (none, f)
    | not (inBoot arch (fpc f)) = if accept then (depositFault 3, f { fidle = True }) else (none, f)
    | romFree && accept = (deposit (fpc f) (bootWord i), f { fpc = fpc f + step })
    | otherwise = (none, f)

  -- Next state.
  keepIf c x = if c then Nothing else x
  s' = s
    { psr = if e2Fire then p2 else pM
    , fetch = f'
    , xq = if flushYoung then Nothing else fx `orElse` (if xAdv then Nothing else xq s)
    , iq = if flushYoung then Nothing else fi `orElse` xTok `orElse` (if dAdv then Nothing else iq s)
    , e1 = if flushYoung then Nothing else dTok `orElse` e1Held
    , e2 = keepIf flushFromM (e1Out `orElse` (if e2Fire then Nothing else e2 s))
    , mq = case (mq s, e2Next) of
        (Just _, _) -> mOut >>= moMem
        (Nothing, ToMem m) | e2Fire -> Just m
        _ -> Nothing
    , rq = case e2Next of
        ToRetire target | e2Fire -> Just (RetTok e2Tag target)
        _ -> mRet
    , entry = if irqTake then Just (EnterIrq (tagPc e2Tag + 4)) else Nothing
    , mpu = case cpWrite of
        Just (op,v) | fabricMap arch && armV5 arch && C.slice d19 d16 op /= 1 -> M.writeMpu (mpu s) op v
        _ -> mpu s
    , execPage = if syncMpu then Nothing else if mpuEnabled arch p && isNothing (fetchPermission arch s)
        then let u=mode p==0x10; addr=fpc f
             in Just (C.slice d31 d12 addr,u,M.allowed (mpu s) u True False addr)
        else execPage s
    , bios7Prot = case mq s of
        Just m | nativeBios arch && not (armV5 arch) && mPhase m == MBiosProt && accessWrite (pending m) && bios7Prot s == 0 ->
          C.slice d15 d0 (accessData (pending m)) .&. 0xfffe
        _ -> bios7Prot s
    , postFlag = case mq s of
        Just m | nativeBios arch && mPhase m == MPostFlag && accessWrite (pending m) &&
                 (armV5 arch || memoryR15 m < 0x4000) ->
          let v=accessData (pending m)
          in pack (armV5 arch && testBit v 1) ++# pack (testBit (postFlag s) 0 || testBit v 0)
        _ -> postFlag s
    , storeObs = mStore
    }

slice :: HiddenClockResetEnable dom => Signal dom SliceIn -> Signal dom SliceOut
slice = arm9Slice hasClock hasReset hasEnable

arm9Slice
  :: KnownDomain dom
  => Clock dom -> Reset dom -> Enable dom
  -> Signal dom SliceIn -> Signal dom SliceOut
arm9Slice = coreSlice arm9Arch

-- | The core with its local RAM and register file in block RAMs, for one
-- architecture.
coreSlice
  :: KnownDomain dom
  => Arch -> Clock dom -> Reset dom -> Enable dom
  -> Signal dom SliceIn -> Signal dom SliceOut
coreSlice arch clk rst en input = qualify <$> active <*> (observe <$> state)
 where
  active = (&&) <$> fromEnable en <*> (not <$> unsafeToActiveHigh rst)
  ramEn = toEnable active
  state = E.register clk rst en (initialCpu arch) (stepCpu <$> next)
  next = transition arch <$> state <*> input <*> readWord <*> regA <*> regB
  readWord = E.blockRam clk ramEn (repeat @1024 0) (localRamIndex . ramAddress <$> state) (localRamWrite <$> next)
  regA = E.blockRam clk ramEn (repeat @32 0) (fromMaybe 0 . readA <$> next) (regWrite <$> next)
  regB = E.blockRam clk ramEn (repeat @32 0) (fromMaybe 0 . readB <$> next) (regWrite <$> next)
  qualify True out = out
  qualify False out = out { gpuReqValid = False, gpuReplyReady = False
                          , storeValid = False, retireValid = False }

-- | Outputs as a host sees them while the core does not step: no request,
-- no reply taken, no store or retire pulse.
qualifyOut :: Bool -> SliceOut -> SliceOut
qualifyOut en out = out
  { gpuReqValid = en && gpuReqValid out, gpuReplyReady = en && gpuReplyReady out
  , storeValid = en && storeValid out, retireValid = en && retireValid out }

-- | 'coreSlice' with the RAM window behind a port (the pure 'CoreExt'
-- model): the register file stays in block RAM; the core steps in cycles
-- where @en@ is high, given the word for its previous step's RAM read.
-- Besides the outputs it presents, from its state, this step's RAM read
-- address and RAM write ('coreExtRead', 'coreExtStep').
coreSliceExt
  :: KnownDomain dom
  => Arch -> Clock dom -> Reset dom -> Enable dom
  -> Signal dom SliceIn -> Signal dom Word
  -> Signal dom (SliceOut, Maybe Word, Maybe (Word, BitVector 4, Word), Bool, Bool)
coreSliceExt arch clk rst en input readWord = bundle (out, rd, wr, not . memReadsRam <$> state, (&&) <$> active <*> (invalidateI <$> next))
 where
  active = (&&) <$> fromEnable en <*> (not <$> unsafeToActiveHigh rst)
  ramEn = toEnable active
  state = E.register clk rst en (initialCpu arch) (stepCpu <$> next)
  next = transition arch <$> state <*> input <*> readWord <*> regA <*> regB
  regA = E.blockRam clk ramEn (repeat @32 0) (fromMaybe 0 . readA <$> next) (regWrite <$> next)
  regB = E.blockRam clk ramEn (repeat @32 0) (fromMaybe 0 . readB <$> next) (regWrite <$> next)
  out = qualifyOut <$> active <*> (observe <$> state)
  rd = externalRead arch <$> state
  -- The step's RAM write does not depend on the inputs (see 'coreExtStep'),
  -- so it is computed with quiet inputs: the host can issue it before the
  -- step without a combinational path from its own outputs back to it.
  wr = externalWrite <$> state <*> (transition arch <$> state <*> pure quietIn <*> readWord <*> regA <*> regB)

-- | Inputs with no request answered, no reply and no IRQ.
quietIn :: SliceIn
quietIn = SliceIn 0 False False 0 False False

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
arm9SliceTopEntity clk rst en boot reqReady replyValid replyData replyFault irq =
  arm9Slice clk rst en (SliceIn <$> boot <*> reqReady <*> replyValid <*> replyData <*> replyFault <*> irq)
