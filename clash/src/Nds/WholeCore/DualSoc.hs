-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric #-}

-- | The first two-processor DS system: the ARM9 and the ARM7 builds of the
-- CPU slice ('arm9Arch', 'arm7Arch') sharing main RAM, each with its own
-- I/O router ('Nds.WholeCore.Arm9Io': timers and its own IME/IE/IF), joined
-- by the IPC registers ('Nds.WholeCore.Ipc'), with the NTR game card on the
-- ARM9 side as in 'Nds.WholeCore.Arm9Soc'.
--
-- Clocking. One clock at the ARM9 rate (67.03 MHz on the DS). The ARM7 core
-- steps only on @ce7@, which is high every other cycle starting with the
-- first cycle after reset: the DS's 33.51 MHz ARM7 clock as a clock enable
-- in one domain, so shared RAM, IPC and the IRQ latches need no clock-domain
-- crossing. Both routers run on every cycle (so no IF pulse is missed); both
-- CPUs' timers count on @ce7@, the 33.51 MHz system clock that melonDS also
-- counts the ARM9's timers in (NDS::RunTimers: ARM9Timestamp >>
-- ARM9ClockShift).
--
-- Main RAM. Each core's RAM window (0x02000000-0x02000FFF, 4 KiB in this
-- gate) is behind 'coreSliceExt': the core presents a read address from its
-- state, and a write ('coreExtWrite') that depends only on its state and the
-- word of its previous read. Both go to one memory port,
-- memReq{Valid,Write,Addr,Lanes,Data} / memReqReady / memResp{Valid,Data}:
-- every accepted request (writes too) gets exactly one response, in order,
-- at least one cycle later, so the memory can move off chip. Writes carry
-- byte lanes, so the two CPUs' stores to different bytes of one word do not
-- overwrite each other. A core's transactions for a step are issued in
-- order (its read, then its write), only after every transaction of its
-- previous steps was answered; the core steps once all of its transactions
-- for the step are issued and the word for its previous read is there (the
-- response may arrive in the same cycle and is used directly, as a block
-- RAM's registered output would be). The ARM7 may issue in any cycle and
-- steps on its next @ce7@.
--
-- Arbiter. One request per cycle. A request presented and not accepted
-- stays presented until accepted. Otherwise, when both cores have a request,
-- the one not granted last wins (round robin). So a core with a request
-- waits for at most one grant to the other core, plus cycles where the
-- memory does not accept. Each core has at most two transactions
-- outstanding, so a four-entry queue routes the responses.
--
-- Coherence: a core's check for stores into its own fetched code sees only
-- its own stores. Nothing here makes the ARM9 refetch code the ARM7 wrote,
-- and SWP faults on both CPUs (no atomics); guests synchronise through IPC.
-- A core's store observation ('storeData') is its own merged word, so bytes
-- the other CPU wrote in between may show stale there; memory has the
-- right word.
module Nds.WholeCore.DualSoc
  ( DualState, DualIn(..), DualOut(..), MemReq(..), ArbView(..)
  , FirmwareIo7(..), noFirmwareIo7
  , initialDual, dualStep, dualSocTopEntity
  , dualWideStep, dualWideSoc, dualWideSocTopEntity
  , dualBufferedSoc, dualBufferedSocTopEntity
  , dualFirmwareSoc, dualFirmwareSocTopEntity
  ) where

import Prelude ()
import Clash.Prelude hiding (Word)
import qualified Clash.Explicit.Prelude as E
import Data.Maybe (fromMaybe, isJust, isNothing)
import Nds.WholeCore.Arm9Slice hiding (slice)
import Nds.WholeCore.Arm9Io
import Nds.WholeCore.Card
import Nds.WholeCore.Ipc
import Nds.WholeCore.DualSocPorts (dualPorts, bufferedPorts, firmwarePorts)
import qualified Nds.WholeCore.CpuWram as W
import qualified Nds.WholeCore.FetchLine as F

type Word = BitVector 32

data DualIn = DualIn
  { boot9Word       :: Word
  , boot7Word       :: Word
  , gpuReqReady9    :: Bool    -- ^ ARM9 external link (requests no router serves)
  , gpuReplyValid9  :: Bool
  , gpuReplyData9   :: Word
  , gpuReplyFault9  :: Bool
  , irqSet9         :: Word    -- ^ external ARM9 IF sources
  , cardIn          :: CardIn
  , memReqReady     :: Bool
  , memRespValid    :: Bool
  , memRespData     :: Word
  } deriving (Generic, NFDataX)

-- | Native firmware-board responder for ARM7 MMIO not serviced by
-- timers, IE/IF/IME or IPC. It shares the existing single-beat link ABI.
data FirmwareIo7 = FirmwareIo7
  { sys7Ready :: Bool, sys7Valid :: Bool, sys7Data :: Word, sys7Fault :: Bool, sys7IrqSet :: Word }
  deriving (Generic, NFDataX)

noFirmwareIo7 :: FirmwareIo7
noFirmwareIo7 = FirmwareIo7 False False 0 False 0

data MemReq = MemReq
  { memReqValid :: Bool
  , memReqWrite :: Bool
  , memReqAddr  :: Word
  , memReqLanes :: BitVector 4
  , memReqData  :: Word
  } deriving (Eq, Show, Generic, NFDataX)

-- | Arbiter view for checkers: which core had a request this cycle, which
-- one was granted, and which cores stepped.
data ArbView = ArbView
  { want9  :: Bool
  , want7  :: Bool
  , grant  :: Maybe Bool       -- ^ Just True: the ARM7 was granted
  , step9  :: Bool
  , step7  :: Bool
  , ce7    :: Bool
  } deriving (Eq, Show, Generic, NFDataX)

data DualOut = DualOut
  { cpu9    :: SliceOut   -- ^ as the router sees it (qualified by the step); bootAddr is the ARM9 boot ROM port
  , cpu7    :: SliceOut   -- ^ bootAddr is the ARM7 boot ROM port (at 0)
  , io9     :: IoOut      -- ^ external link view: card and IPC requests removed
  , io7     :: IoOut
  , card    :: CardOut
  , memReq  :: MemReq
  , arb     :: ArbView
  } deriving (Generic, NFDataX)

-- | Per-core memory bookkeeping: transactions of earlier steps not yet
-- answered, of the current step not yet answered, which of the current
-- step's transactions are issued, the word of the previous step's read
-- (the input of the current step) and, once answered, the word of the
-- current step's own read (the input of the next step).
data Track = Track
  { prevOut   :: Index 3
  , curOut    :: Index 3
  , issuedRd  :: Bool
  , issuedWr  :: Bool
  , rdWord    :: Word
  , nextWord  :: Word
  , nextValid :: Bool
  } deriving (Generic, NFDataX)

-- | Arbiter and memory-port state; queue entries are (ARM7?, read?).
data Arb = Arb
  { trk9    :: Track
  , trk7    :: Track
  , queue   :: Vec 4 (Bool, Bool)
  , qLen    :: Index 5
  , last7   :: Bool          -- ^ the last grant went to the ARM7
  , offered :: Maybe Bool    -- ^ a request presented and not yet accepted
  , phase   :: Bool          -- ^ ce7 this cycle
  } deriving (Generic, NFDataX)

data DualState = DualState
  { core9  :: CoreExt
  , core7  :: CoreExt
  , arbSt  :: Arb
  , ioSt9  :: IoState
  , ioSt7  :: IoState
  , cardSt :: CardState
  , ipcSt  :: IpcState
  } deriving (Generic, NFDataX)

initialTrack :: Track
initialTrack = Track 0 0 False False 0 0 False

initialArb :: Arb
initialArb = Arb initialTrack initialTrack (repeat (False, False)) 0 False Nothing True

initialDual :: DualState
initialDual = DualState (initialCoreExt arm9Arch) (initialCoreExt arm7Arch) initialArb
  initialIo initialIo initialCard initialIpc

-- | The memory response this cycle, if any: (for the ARM7?, a read?).
respHead :: Arb -> Bool -> Maybe (Bool, Bool)
respHead a valid = if valid && qLen a /= 0 then Just (head (queue a)) else Nothing

-- | Each core's input word for its current step: the response arriving now
-- if it answers the previous step's read, or the latched one.
wordsNow :: Arb -> Bool -> Word -> (Word, Word)
wordsNow a valid dat = (pick False (trk9 a), pick True (trk7 a))
 where
  pick is7 t = case respHead a valid of
    Just (c, True) | c == is7 && prevOut t /= 0 -> dat
    _ -> rdWord t

-- | A core's step request: its read address and its write.
type CoreReq = (Maybe Word, Maybe (Word, BitVector 4, Word))

-- | Arbitration, step enables and bookkeeping for one cycle.
arbStep :: (Bool, Bool) -> Arb -> (Bool, Bool, Word) -> CoreReq -> CoreReq -> (Arb, (Bool, Bool, MemReq, ArbView, Bool))
arbStep (rom9, rom7) a (ready, valid, dat) (rd9, wr9) (rd7, wr7) = (a', (en9, en7, req, view, choice == Just True))
 where
  resp = respHead a valid
  -- A response answers the core's oldest open transaction: an earlier
  -- step's (its read word is this step's input) or this step's own (its
  -- read word is kept for the next step).
  answered is7 t = case resp of
    Just (c, isRead) | c == is7 ->
      if prevOut t /= 0
        then t { prevOut = prevOut t - 1, rdWord = if isRead then dat else rdWord t }
        else t { curOut = curOut t - 1, nextWord = if isRead then dat else nextWord t
               , nextValid = nextValid t || isRead }
    _ -> t
  t9 = answered False (trk9 a)
  t7 = answered True (trk7 a)
  -- The next transaction a core can issue: its read, then its write, once
  -- its earlier steps are fully answered.
  nextOf t rd wr
    | prevOut t /= 0 = Nothing
    | Just addr <- rd, not (issuedRd t) = Just (MemReq True False addr 0xf 0)
    | Just (addr, lanes, v) <- wr, not (issuedWr t) = Just (MemReq True True addr lanes v)
    | otherwise = Nothing
  popped = isJust resp
  len0 = if popped then qLen a - 1 else qLen a
  room = len0 < 4
  n9 = if room then nextOf t9 rd9 wr9 else Nothing
  n7 = if room then nextOf t7 rd7 wr7 else Nothing
  choice = case (n9, n7) of
    (Just _, Just _) -> Just (fromMaybe (not (last7 a)) (offered a))
    (Just _, Nothing) -> Just False
    (Nothing, Just _) -> Just True
    _ -> Nothing
  req = case choice of
    Just True -> fromMaybe idleReq n7
    Just False -> fromMaybe idleReq n9
    Nothing -> idleReq
  granted = if ready then choice else Nothing
  issue is7 t n = case (granted, n) of
    (Just g, Just r) | g == is7 ->
      ( t { issuedRd = issuedRd t || not (memReqWrite r), issuedWr = issuedWr t || memReqWrite r
          , curOut = curOut t + 1 }
      , Just (is7, not (memReqWrite r)) )
    _ -> (t, Nothing)
  (t9i, push9) = issue False t9 n9
  (t7i, push7) = issue True t7 n7
  allIssued t rd wr = (isNothing rd || issuedRd t) && (isNothing wr || issuedWr t)
  -- A prior store is not complete just because it has a grant, including
  -- admission to the buffered request slot. Its reply (Fabric: final
  -- sdDone; private RAM: committed write) must decrement prevOut before
  -- the next step may commit, including MCR c7,c10,4 write-buffer drain.
  en9 = rom9 && prevOut t9 == 0 && allIssued t9i rd9 wr9
  en7 = rom7 && phase a && prevOut t7 == 0 && allIssued t7i rd7 wr7
  -- On a step the current transactions become earlier ones; the next step's
  -- input word is the current read's word if it is already here.
  stepped en t
    | en = Track (prevOut t + curOut t) 0 False False (if nextValid t then nextWord t else rdWord t) 0 False
    | otherwise = t
  pushed = case push9 of
    Just e -> Just e
    Nothing -> push7
  q0 = if popped then tail (queue a) :< (False, False) else queue a
  (q', len') = case pushed of
    Just e -> (replace len0 e q0, len0 + 1)
    Nothing -> (q0, len0)
  a' = Arb
    { trk9 = stepped en9 t9i
    , trk7 = stepped en7 t7i
    , queue = q'
    , qLen = len'
    , last7 = maybe (last7 a) id granted
    , offered = if isJust granted then Nothing else choice
    , phase = not (phase a) }
  view = ArbView (isJust n9) (isJust n7) granted en9 en7 (phase a)
  idleReq = MemReq False False 0 0 0

-- | ARM9 external-side owner: card, IPC or the external link.
data Owner = OwnCard | OwnIpc | OwnLink deriving (Eq)

owner9 :: Bool -> Word -> Owner
owner9 native a
  | not native && cardOwns a = OwnCard
  | ipcOwns a = OwnIpc
  | otherwise = OwnLink

-- | The ARM9 router's inputs: card, IPC or external replies.
routerIn9 :: Bool -> SliceOut -> DualIn -> CardReply -> CardOut -> CardReply -> Word -> Bool -> IoIn
routerIn9 native c i k ko p ipcIrq tick = IoIn
  { cpuReqValid = gpuReqValid c, cpuReqWrite = gpuReqWrite c, cpuReqAddr = gpuReqAddr c
  , cpuReqWidth = gpuReqWidth c, cpuReqLanes = gpuReqLanes c, cpuReqData = gpuReqData c
  , cpuReplyReady = gpuReplyReady c
  , extReqReady = case owner9 native (gpuReqAddr c) of
      OwnCard -> cardReqReady k
      OwnIpc -> cardReqReady p
      OwnLink -> gpuReqReady9 i
  , extReplyValid = cardReplyValid k || cardReplyValid p || gpuReplyValid9 i
  , extReplyData = if cardReplyValid k then cardReplyData k else if cardReplyValid p then cardReplyData p else gpuReplyData9 i
  , extReplyFault = if cardReplyValid k then cardReplyFault k else if cardReplyValid p then cardReplyFault p else gpuReplyFault9 i
  , timerTick = tick
  , extIrqSet = irqSet9 i .|. (if cardIrq ko then bit 19 else 0) .|. ipcIrq
  , extIrqClear = 0 }

-- Legacy cores send the whole external ARM7 link to IPC (which faults
-- unsupported accesses). The native machine retains IPC ownership but
-- routes other MMIO out to its board devices, just as it does on ARM9.
routerIn7 :: Bool -> FirmwareIo7 -> SliceOut -> CardReply -> Word -> Bool -> IoIn
routerIn7 native e c p ipcIrq tick = IoIn
  { cpuReqValid = gpuReqValid c, cpuReqWrite = gpuReqWrite c, cpuReqAddr = gpuReqAddr c
  , cpuReqWidth = gpuReqWidth c, cpuReqLanes = gpuReqLanes c, cpuReqData = gpuReqData c
  , cpuReplyReady = gpuReplyReady c
  , extReqReady = if native && not (ipcOwns (gpuReqAddr c)) then sys7Ready e else cardReqReady p
  , extReplyValid = cardReplyValid p || (native && sys7Valid e)
  , extReplyData = if native && not (cardReplyValid p) then sys7Data e else cardReplyData p
  , extReplyFault = if native && not (cardReplyValid p) then sys7Fault e else cardReplyFault p
  , timerTick = tick
  , extIrqSet = ipcIrq .|. (if native then sys7IrqSet e else 0)
  , extIrqClear = 0 }

busFor :: Bool -> SliceOut -> IoOut -> CardBus
busFor sel c o = CardBus
  { busReqValid = extReqValid o && sel, busReqWrite = gpuReqWrite c
  , busReqAddr = gpuReqAddr c, busReqWidth = gpuReqWidth c, busReqData = gpuReqData c
  , busReplyReady = extReplyReady o }

linkView :: Bool -> SliceOut -> CardReply -> CardReply -> IoOut -> IoOut
linkView native c k p o = o
  { extReqValid = extReqValid o && owner9 native (gpuReqAddr c) == OwnLink
  , extReplyReady = extReplyReady o && not (cardReplyValid k) && not (cardReplyValid p) }

linkView7 :: SliceOut -> CardReply -> IoOut -> IoOut
linkView7 c p o = o { extReqValid = extReqValid o && not (ipcOwns (gpuReqAddr c))
                    , extReplyReady = extReplyReady o && not (cardReplyValid p) }

cpuIn :: Word -> IoOut -> SliceIn
cpuIn boot o = SliceIn
  { bootWord = boot, gpuReqReady = cpuReqReady o, gpuReplyValid = cpuReplyValid o
  , gpuReplyData = cpuReplyData o, gpuReplyFault = cpuReplyFault o, irqRequest = irqLine o }

-- | The devices around the cores for one cycle: both routers, the card and
-- IPC, given the cores' (qualified) outputs. Card and IPC outputs depend on
-- their state only, so feeding the routers from them and them from the
-- routers has no combinational loop (as in 'Nds.WholeCore.Arm9Soc').
devices
  :: Bool -> FirmwareIo7 -> (IoState, IoState, CardState, IpcState) -> DualIn -> Bool -> SliceOut -> SliceOut
  -> ((IoState, IoState, CardState, IpcState), (IoOut, IoOut, CardReply, CardOut, CardReply, CardReply))
devices native e (s9, s7, k, p) i tick c9 c7 = ((s9', s7', k', p'), (o9, o7, kReply, kOut, pr9, pr7))
 where
  (k', (kReply, kOut)) = cardStep k (busFor (owner9 native (gpuReqAddr c9) == OwnCard) c9 o9, cardIn i)
  (p', IpcOut pr9 pr7 pi9 pi7) = ipcStep p (busFor (owner9 native (gpuReqAddr c9) == OwnIpc) c9 o9,
                                     busFor (not native || ipcOwns (gpuReqAddr c7)) c7 o7)
  (s9', o9) = ioStep s9 (routerIn9 native c9 i kReply kOut pr9 pi9 tick)
  (s7', o7) = ioStep s7 (routerIn7 native e c7 pr7 pi7 tick)

-- | One clock of the whole system.
dualStep :: DualState -> DualIn -> (DualState, DualOut)
dualStep s i = (s', out)
 where (s', (out, _)) = dualStepWith False s i

-- | Wide main RAM / ARM7 Fabric adapter. The Bool is the memory owner
-- (True = ARM7) on the very cycle a request is presented, even if stalled.
dualWideStep :: DualState -> DualIn -> (DualState, (DualOut, Bool))
dualWideStep = dualStepWith True

dualStepWith :: Bool -> DualState -> DualIn -> (DualState, (DualOut, Bool))
dualStepWith wide s i = (s', (out, owner7))
 where
  arch9 = arm9Arch { fabricMap = wide }
  arch7 = arm7Arch { fabricMap = wide }
  a = arbSt s
  (w9, w7) = wordsNow a (memRespValid i) (memRespData i)
  req9 = (coreExtRead arch9 (core9 s), coreExtWrite arch9 (core9 s) w9)
  req7 = (coreExtRead arch7 (core7 s), coreExtWrite arch7 (core7 s) w7)
  (a', (en9, en7, mreq, view, owner7)) = arbStep (True,True) a (memReqReady i, memRespValid i, memRespData i) req9 req7
  c9 = qualifyOut en9 (coreExtObserve (core9 s))
  c7 = qualifyOut en7 (coreExtObserve (core7 s))
  ((io9', io7', k', p'), (o9, o7, kReply, kOut, pr9, _)) =
    devices False noFirmwareIo7 (ioSt9 s, ioSt7 s, cardSt s, ipcSt s) i (phase a) c9 c7
  core9' = if en9 then coreExtStep arch9 (core9 s) (cpuIn (boot9Word i) o9) w9 else core9 s
  core7' = if en7 then coreExtStep arch7 (core7 s) (cpuIn (boot7Word i) o7) w7 else core7 s
  s' = DualState core9' core7' a' io9' io7' k' p'
  out = DualOut
    { cpu9 = c9
    , cpu7 = c7
    , io9 = linkView False c9 kReply pr9 o9
    , io7 = o7
    , card = kOut
    , memReq = mreq
    , arb = view }

dualWideSoc :: KnownDomain dom => Clock dom -> Reset dom -> Enable dom -> Signal dom DualIn -> Signal dom (DualOut, Bool)
dualWideSoc clk rst en i = (\(o,_,_) -> o) <$> wideCore False clk rst en i (pure noFirmwareIo7)

-- WRAM sits after the shared CPU arbiter, before any external instruction
-- line or Fabric port. Neither an internal WRAM read nor its reply is a
-- main RAM transaction. The pure dualWideStep exposes the raw arbiter for
-- hosts modelling this same private store externally.
wideCore :: KnownDomain dom => Bool -> Clock dom -> Reset dom -> Enable dom -> Signal dom DualIn
         -> Signal dom FirmwareIo7 -> Signal dom ((DualOut, Bool), Bool, Bool)
wideCore native clk rst en i sys7 = bundle (bundle (exposed,owner),instr,invI)
 where
  cpuInput d (r,v,w,_) gpu = d { memReqReady = r, memRespValid = v, memRespData = w, gpuReplyData9 = gpu }
  (pair,instr,invI) = unbundle (dualSocWith True native clk rst en (cpuInput <$> i <*> route <*> gpuWord) sys7)
  (raw,owner) = unbundle pair
  req = memReq <$> raw
  c9 = cpu9 <$> raw
  takeGpu = (&&) <$> (extReqValid . io9 <$> raw) <*> (gpuReqReady9 <$> i)
  (mode,gpuWord) = unbundle (W.wramControl clk rst en takeGpu (gpuReqWrite <$> c9) (gpuReqAddr <$> c9)
                              (gpuReqLanes <$> c9) (gpuReqData <$> c9) (gpuReplyData9 <$> i))
  route = W.cpuWram clk rst en mode owner (memReqValid <$> req) (memReqWrite <$> req)
            (memReqAddr <$> req) (memReqLanes <$> req) (memReqData <$> req)
            (memReqReady <$> i) (memRespValid <$> i) (memRespData <$> i)
  exposed = (\o (_,_,_,v) -> o { memReq = (memReq o) { memReqValid = v } }) <$> raw <*> route

-- | Wide CPU port with a demand-only aligned 64-bit instruction buffer.
-- Downstream returns one ordered response to every accepted request; its
-- full 8-byte line accompanies each main RAM read. External masters snoop
-- every accepted main RAM write. Coordinated reset drops pending replies.
dualBufferedSoc :: KnownDomain dom => Clock dom -> Reset dom -> Enable dom -> Signal dom DualIn
                -> Signal dom (BitVector 64) -> Signal dom (Maybe Word) -> Signal dom (DualOut, Bool)
dualBufferedSoc clk rst en i line snoop = fst <$> buffered False clk rst en i (pure noFirmwareIo7) line snoop

-- | Native boot: private 4 KiB ARM9 and 16 KiB ARM7 synchronous ROMs.
-- Each ROM samples its BOOT_ADDR word index at every rising master edge.
-- Uploads finish while reset is held; no direct-boot state is injected.
dualFirmwareSoc :: KnownDomain dom => Clock dom -> Reset dom -> Enable dom -> Signal dom DualIn
                -> Signal dom FirmwareIo7 -> Signal dom (BitVector 64) -> Signal dom (Maybe Word) -> Signal dom (DualOut, Bool)
dualFirmwareSoc clk rst en i sys7 line snoop = fst <$> buffered True clk rst en i sys7 line snoop

buffered :: KnownDomain dom => Bool -> Clock dom -> Reset dom -> Enable dom -> Signal dom DualIn
         -> Signal dom FirmwareIo7 -> Signal dom (BitVector 64) -> Signal dom (Maybe Word) -> Signal dom ((DualOut, Bool), Bool)
buffered native clk rst en i sys7 line snoop = bundle (bundle (exposed,owner),instr)
 where
  -- Non-fall-through admission register cuts core request -> line lookup
  -- -> CPU enable -> device registers. Only a genuinely accepted demand
  -- enters this slot. Full address, lanes, owner and I/D remain together
  -- until the line or Fabric accepts them, even under backpressure.
  cpuInput d room o = d { memReqReady = room, memRespValid = F.responseValid o, memRespData = F.responseWord o }
  (pair,rawFetch,invI) = unbundle (wideCore native clk rst en (cpuInput <$> i <*> room <*> lo) sys7)
  (raw,rawOwner) = unbundle pair
  queued = E.register clk rst en Nothing queued'
  room = isNothing <$> queued
  incoming = (\o who f inv -> let r = memReq o in if memReqValid r
                then Just (r,who,f,f && (who || not inv)) else Nothing) <$> raw <*> rawOwner <*> rawFetch <*> invI
  advance Nothing new _ _ = new
  advance (Just (r,who,f,canFill)) _ takeLine inv
    | takeLine = Nothing
    | otherwise = Just (r,who,f,canFill && (who || not inv))
  queued' = advance <$> queued <*> incoming <*> (F.requestReady <$> lo) <*> invI
  (req,owner,instr,eligible) = unbundle (fromMaybe (MemReq False False 0 0 0,False,False,False) <$> queued)
  active = (&&) <$> fromEnable en <*> (not <$> unsafeToActiveHigh rst)
  li = F.LineIn <$> ((&&) <$> active <*> (memReqValid <$> req)) <*> (memReqWrite <$> req) <*> (memReqAddr <$> req)
                <*> owner <*> eligible <*> (memReqReady <$> i) <*> (memRespValid <$> i)
                <*> (memRespData <$> i) <*> line <*> snoop <*> invI
  lineState = E.register clk rst en F.initialLine nextLine
  (nextLine,lo) = unbundle (F.lineStep <$> lineState <*> li)
  exposed = (\o r v -> o { memReq = r { memReqValid = v } }) <$> raw <*> req <*> (F.downstreamValid <$> lo)

dualSocWith
  :: KnownDomain dom
  => Bool -> Bool -> Clock dom -> Reset dom -> Enable dom
  -> Signal dom DualIn -> Signal dom FirmwareIo7 -> Signal dom ((DualOut, Bool), Bool, Bool)
dualSocWith wide native clk rst en input sys7 = bundle (bundle (out, owner7), instr, invI)
 where
  instr = (\r f -> memReqValid r && not (memReqWrite r) && f) <$> mreq <*> mux owner7 fetch7 fetch9
  arbS = E.register clk rst en initialArb arbS'
  wNow = wordsNow <$> arbS <*> (memRespValid <$> input) <*> (memRespData <$> input)
  (o9raw, rd9, wr9, fetch9, invI) = unbundle (coreSliceExt (arm9Arch { fabricMap = wide, nativeBios = native }) clk rst en9e in9 (fst <$> wNow))
  (o7raw, rd7, wr7, fetch7, _) = unbundle (coreSliceExt (arm7Arch { fabricMap = wide, nativeBios = native }) clk rst en7e in7 (snd <$> wNow))
  -- The BIOS address is a state output, independent of the step enable.
  -- A word matches the previous edge's synchronous ROM read, including
  -- after a literal/fetch collision. Do not pause the arbiter response FIFO.
  romReady inWindow index current
    | not native = pure True
    | otherwise = (\a prev -> not (inWindow a) || prev == Just (index a)) <$> current <*>
        E.register clk rst enableGen Nothing (Just . index <$> current)
  ok9 = romReady (\a -> slice d31 d12 a == 0xffff0) (\a -> (0 :: BitVector 2) ++# slice d11 d2 a) (bootAddr <$> o9raw)
  ok7 = romReady (< 0x4000) (slice d13 d2) (bootAddr <$> o7raw)
  arbRes = arbStep <$> bundle (ok9,ok7) <*> arbS <*> ((,,) <$> (memReqReady <$> input) <*> (memRespValid <$> input) <*> (memRespData <$> input))
                   <*> ((,) <$> rd9 <*> wr9) <*> ((,) <$> rd7 <*> wr7)
  arbS' = fst <$> arbRes
  (en9, en7, mreq, view, owner7) = unbundle (snd <$> arbRes)
  en9e = toEnable ((&&) <$> fromEnable en <*> en9)
  en7e = toEnable ((&&) <$> fromEnable en <*> en7)
  -- coreSliceExt already qualifies its outputs by its enable.
  devS = E.register clk rst en (initialIo, initialIo, initialCard, initialIpc) (fst <$> devRes)
  devRes = devices native <$> sys7 <*> devS <*> input <*> (phase <$> arbS) <*> o9raw <*> o7raw
  (o9, o7, kReply, kOut, pr9, pr7) = unbundle (snd <$> devRes)
  in9 = cpuIn <$> (boot9Word <$> input) <*> o9
  in7 = cpuIn <$> (boot7Word <$> input) <*> o7
  out = DualOut <$> o9raw <*> o7raw
    <*> (linkView native <$> o9raw <*> kReply <*> pr9 <*> o9)
    <*> (if native then linkView7 <$> o7raw <*> pr7 <*> o7 else o7) <*> kOut <*> mreq <*> view

{-# ANN dualSocTopEntity (dualPorts False) #-}
dualSocTopEntity :: DualTop DualOut
dualSocTopEntity = withPorts (\clk rst en input -> (\((o,_),_,_) -> o) <$> dualSocWith False False clk rst en input (pure noFirmwareIo7))

{-# ANN dualWideSocTopEntity (dualPorts True) #-}
dualWideSocTopEntity :: DualTop ((DualOut, Bool), Bool)
dualWideSocTopEntity = withPorts (\clk rst en input -> (\(o,f,_) -> (o,f)) <$> wideCore False clk rst en input (pure noFirmwareIo7))

{-# ANN dualBufferedSocTopEntity bufferedPorts #-}
dualBufferedSocTopEntity :: Signal System (BitVector 64) -> Signal System Bool -> Signal System Word -> DualTop ((DualOut, Bool), Bool)
dualBufferedSocTopEntity line valid addr = withPorts (\clk rst en i ->
  buffered False clk rst en i (pure noFirmwareIo7) line (mux valid (Just <$> addr) (pure Nothing)))

{-# ANN dualFirmwareSocTopEntity firmwarePorts #-}
dualFirmwareSocTopEntity :: Signal System Bool -> Signal System Bool -> Signal System Word -> Signal System Bool -> Signal System Word
                         -> Signal System (BitVector 64) -> Signal System Bool -> Signal System Word -> DualTop ((DualOut, Bool), Bool)
dualFirmwareSocTopEntity ready reply dat fault irq line valid addr = withPorts (\clk rst en i ->
  buffered True clk rst en i (FirmwareIo7 <$> ready <*> reply <*> dat <*> fault <*> irq)
    line (mux valid (Just <$> addr) (pure Nothing)))

type DualTop a = Clock System -> Reset System -> Enable System
  -> Signal System Word -> Signal System Word
  -> Signal System Bool -> Signal System Bool -> Signal System Word -> Signal System Bool
  -> Signal System Word
  -> Signal System Bool -> Signal System Bool -> Signal System Word -> Signal System Word
  -> Signal System Bool -> Signal System Bool -> Signal System Word
  -> Signal System Bool -> Signal System Bool -> Signal System Word
  -> Signal System a

withPorts :: (Clock System -> Reset System -> Enable System -> Signal System DualIn -> Signal System a) -> DualTop a
withPorts soc clk rst en b9 b7 ready replyValid replyData replyFault set
    inserted direct chipId romMask romReady romValid romData memReady respValid respData =
  soc clk rst en (DualIn <$> b9 <*> b7 <*> ready <*> replyValid <*> replyData <*> replyFault <*> set
                        <*> card <*> memReady <*> respValid <*> respData)
 where
  card = CardIn <$> inserted <*> direct <*> chipId <*> romMask <*> romReady <*> romValid <*> romData
