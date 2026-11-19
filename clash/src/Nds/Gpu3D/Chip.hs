-- | The whole 3D chip as one pure model: the GX front end
-- ("Nds.Gpu3D.GxFront"), the geometry engine ("Nds.Gpu3D.Geometry"), the
-- polygon pipeline ("Nds.Gpu3D.Polygon") and the renderer
-- ("Nds.Gpu3D.Render") composed the way melonDS composes them inside
-- @GPU3D@ and @SoftRenderer3D@. It is the reference the chip hardware top
-- is gated against.
--
-- The chip's input alphabet is 'ChipIn'; 'chipStep' applies one event and
-- each event also has its own function:
--
-- * 'chipWrite' / 'chipRead': one ARM9 bus access to 0x04000060-0x04000063
--   (DISP3DCNT) or 0x04000320-0x040006A3 (@GPU3D::Write*@ / @Read*@ behind
--   @NDS::ARM9IOWrite*@ / @ARM9IORead*@). A write also reaches the geometry
--   engine where melonDS's register write does: the GXSTAT bit-15
--   acknowledge (stack error and projection/texture stack pointers) and
--   @DISP_1DOT_DEPTH@.
-- * 'chipRun': the geometry engine catches up (@GPU3D::Run@ with an
--   unbounded cycle budget): it takes entries while geometry is enabled, no
--   @SWAP_BUFFERS@ is pending and the PIPE is not empty. 'chipRunOne' takes
--   exactly one entry. Each entry is gathered into @ExecParams@
--   ('gatherEntry'); a complete command runs through the geometry engine and
--   its events through the polygon pipeline ('execGeo'), whose RAM-overflow
--   flag sets DISP3DCNT bit 13.
-- * 'chipVBlank': scanline 192, @GPU3D::VBlank@: with geometry enabled, the
--   render list is built from the finished bank (rendering enabled and a
--   swap pending), the @Render*@ registers latch (rendering enabled), then
--   the polygon banks swap (swap pending).
-- * 'chipRenderStart': scanline 215, @SoftRenderer3D::RenderFrame@ on the
--   latched registers and the render list, carrying the renderer state from
--   the previous frame, with polygon/vertex RAM and the texture memories as
--   they are at that moment.
-- * 'chipGetLine': @SoftRenderer3D::GetLine@, the last rendered frame's line
--   scrolled by the live @RenderXPos@, or zeros while the frame is aborted.
-- * 'chipPower' (POWCNT1 bits 3/2, @GPU3D::SetEnabled@), 'chipXPos' (engine A
--   BG0HOFS writes, @SetRenderXPos@), 'chipAbortFrame' (a VCOUNT write that
--   changed the next line counter, @GPU::SetVCount@), 'chipFrameEnd'
--   (@GPU::FinishFrame@ clears the abort), 'chipIrqCheck' (an ARM9 IF write,
--   which re-runs @CheckFIFOIRQ@).
--
-- Outputs: 'chipRead' values, 'chipGetLine' lines, the 'Drain' report of a
-- run (entries taken, GXFIFO DMA triggers), 'chipIrq' (IF bit 21),
-- 'chipDmaRequest' (the GXFIFO DMA level), 'chipStalled' (ordinary ARM9 bus
-- accesses are held until it clears; authenticated atomic-handler writes use
-- the separate 'chipWriteContinuation' entry point).
--
-- GXSTAT is composed at the chip level: the geometry engine is reported busy
-- (bit 27) while a @SWAP_BUFFERS@ waits for VBlank, as melonDS's @GXStat@
-- bit 27 stays set from the swap entry until @FinishWork@ after the VBlank.
-- DISP3DCNT bit 13 lives in the front end's DISP3DCNT register: the polygon
-- pipeline's overflow flag is passed on as a set pulse ('execGeo'), so
-- 'Types.PipeStatus' needs no field for it.
module Nds.Gpu3D.Chip
  ( -- * State
    Chip (..)
  , initChip
    -- * Events
  , ChipIn (..)
  , ChipOut (..)
  , Drain (..)
  , chipStep
  , chipWrite
  , chipWriteContinuation
  , chipRead
  , chipRun
  , chipRunOne
  , chipVBlank
  , chipRenderStart
  , chipGetLine
  , chipPower
  , chipXPos
  , chipAbortFrame
  , chipFrameEnd
  , chipIrqCheck
    -- * Outputs
  , chipStalled
  , chipIrq
  , chipDmaRequest
  , chipGeoStatus
  , chipFrontIn
  , chipRenderFrame
    -- * Composition steps
  , gatherEntry
  , execGeo
  , truncateWrite
  ) where

import Data.Array.Unboxed (UArray, listArray, (!))
import Data.Bits ((.&.), complement)
import Data.List (foldl')
import Data.Word (Word16, Word32)

import qualified Nds.Gpu3D.Geometry as Geo
import Nds.Gpu3D.GxFront
  ( FrontIn (..), GxFront (..), PopFx (..), Size (..), WriteAct (..), WriteFx (..)
  , dmaRequest, fifoIrqCond, fifoLevel, initGxFront, irqLine, mmioRead
  , mmioWrite, popEntry, renderRegs, setDispCntFlags, setPower
  , setRenderXPos, stalled, writeAction )
import qualified Nds.Gpu3D.GxFront as Front
import Nds.Gpu3D.Polygon (PolyPipeState (..))
import qualified Nds.Gpu3D.Polygon as Poly
import Nds.Gpu3D.Render (Carry, Layer (..), RenderOut (..), outputLine, renderFrameFrom, resetCarry)
import Nds.Gpu3D.Texture (TexMem)
import Nds.Gpu3D.Types

-- | The chip's state: each block's state, the geometry engine's gathered
-- parameter words, the render list, the renderer's carried state and the
-- last rendered colour layer, and the display-timing abort flag.
data Chip = Chip
  { chFront      :: !GxFront
  , chGeo        :: !Geo.GeoState
  , chPoly       :: !PolyPipeState
  , chParams     :: ![Word32]
    -- ^ @ExecParams[0 .. ExecParamCount-1]@, oldest first
  , chRenderList :: ![Int]
    -- ^ @RenderPolygonRAM[0 .. RenderNumPolygons-1]@ as polygon RAM indices.
    -- The polygons are read through them at render start, as production
    -- dereferences its pointers then.
  , chCarry      :: !Carry
    -- ^ the renderer state one frame leaves to the next
  , chColour     :: !(UArray Int Word32)
    -- ^ @ColorBuffer@'s top layer after the last frame (256x192, @y*256+x@)
  , chAbort      :: !Bool
    -- ^ @GPU3D::AbortFrame@
  }

-- | Power-on: @GPU3D::Reset@ in every block, a reset renderer (zero
-- buffers) and no frame aborted. Geometry and rendering start disabled
-- (POWCNT1 bits 3 and 2 clear).
initChip :: Chip
initChip = Chip
  { chFront = initGxFront
  , chGeo = Geo.initGeoState
  , chPoly = Poly.initPolyPipe
  , chParams = []
  , chRenderList = []
  , chCarry = resetCarry
  , chColour = listArray (0, 256 * 192 - 1) (replicate (256 * 192) 0)
  , chAbort = False
  }

------------------------------------------------------------------------------
-- Event alphabet

-- | One input event.
data ChipIn
  = CiWrite !Size !Word32 !Word32
    -- ^ ARM9 write: width, address, value (precondition: not 'chipStalled')
  | CiRead !Size !Word32
    -- ^ ARM9 read (precondition: not 'chipStalled')
  | CiRun
    -- ^ the geometry engine catches up ('chipRun')
  | CiVBlank
    -- ^ scanline 192
  | CiRenderStart
    -- ^ scanline 215
  | CiGetLine !Int
    -- ^ the 2D engine fetches 3D line @y@ (0..191)
  | CiPower !Bool !Bool
    -- ^ POWCNT1 write: geometry (bit 3), rendering (bit 2)
  | CiXPos !Word16 !Word16
    -- ^ engine A BG0HOFS write: value and lane mask (0x00FF, 0xFF00, 0xFFFF)
  | CiAbortFrame
    -- ^ a VCOUNT write changed the next line counter
  | CiFrameEnd
    -- ^ end of the frame (@GPU::FinishFrame@)
  | CiIrqCheck
    -- ^ an ARM9 IF write (@CheckFIFOIRQ@ runs after the acknowledge)
  deriving (Eq, Show)

-- | What one event returns.
data ChipOut
  = CoNone
  | CoRead !Word32
  | CoLine ![Word32]
  | CoRun !Drain
  deriving (Eq, Show)

-- | What a run did: GX entries the geometry engine took, and how many of
-- those takes refilled the PIPE with fewer than 128 FIFO entries left
-- (@CheckFIFODMA@ starting the ARM9 DMA channels in GXFIFO mode).
data Drain = Drain
  { drEntries :: !Int
  , drDma     :: !Int
  } deriving (Eq, Show)

-- | Apply one event. The texture memories are an input: the renderer reads
-- them at render start.
chipStep :: TexMem -> Chip -> ChipIn -> (Chip, ChipOut)
chipStep mem ch ev = case ev of
  CiWrite sz a v -> (chipWrite sz a v ch, CoNone)
  CiRead sz a -> (ch, CoRead (chipRead sz a ch))
  CiRun -> let (ch', d) = chipRun ch in (ch', CoRun d)
  CiVBlank -> (chipVBlank ch, CoNone)
  CiRenderStart -> (chipRenderStart mem ch, CoNone)
  CiGetLine y -> (ch, CoLine (chipGetLine y ch))
  CiPower g r -> (chipPower g r ch, CoNone)
  CiXPos x m -> (chipXPos x m ch, CoNone)
  CiAbortFrame -> (chipAbortFrame ch, CoNone)
  CiFrameEnd -> (chipFrameEnd ch, CoNone)
  CiIrqCheck -> (chipIrqCheck ch, CoNone)

------------------------------------------------------------------------------
-- ARM9 bus

-- | The value an access of this width carries.
truncateWrite :: Size -> Word32 -> Word32
truncateWrite sz v = case sz of
  S8 -> v .&. 0xFF
  S16 -> v .&. 0xFFFF
  S32 -> v

-- | melonDS's ARM9Read16/Write16 mask the address with @~1@ and
-- ARM9Read32/Write32 with @~3@; unaligned accesses therefore hit the aligned
-- register, not an unknown one. The bus lane is still what the caller passed.
alignAddr :: Size -> Word32 -> Word32
alignAddr sz a = case sz of
  S16 -> a .&. complement 0x1
  S32 -> a .&. complement 0x3
  S8 -> a

-- | One ARM9 write. The front end performs it; the geometry engine sees the
-- GXSTAT stack-error acknowledge and @DISP_1DOT_DEPTH@, which melonDS's
-- register write applies to geometry state directly.
chipWrite :: Size -> Word32 -> Word32 -> Chip -> Chip
chipWrite sz a0 v ch
  | stalled (chFront ch) = error "Nds.Gpu3D.Chip.chipWrite: the ARM9 bus is held by a GX FIFO stall"
  | otherwise = writeRegister sz a0 v ch

-- | Authenticated remaining word write of the same atomic ARM9 handler.
-- Admission belongs to the live service; preserve the existing register
-- decoder, geometry effects and front-end pending FIFO.
chipWriteContinuation :: Word32 -> Word32 -> Chip -> Chip
chipWriteContinuation a v ch
  | not (stalled (chFront ch)) = error "Nds.Gpu3D.Chip.chipWriteContinuation: no active GX FIFO stall"
  | otherwise = writeRegister S32 a v ch

writeRegister :: Size -> Word32 -> Word32 -> Chip -> Chip
writeRegister sz a0 v ch =
  let a = alignAddr sz a0
      act = writeAction (gfGeomEn gf) (gfRendEn gf) sz a (truncateWrite sz v)
      (gf', fx) = mmioWrite sz a v gf
      geo1 = if wfAck fx then fst (Geo.step (chGeo ch) Geo.AckStackError) else chGeo ch
      geo2 = case act of
        WaZeroDot z -> fst (Geo.step geo1 (Geo.SetZeroDotW z))
        _ -> geo1
  in ch { chFront = gf', chGeo = geo2 }
  where
    gf = chFront ch

-- | One ARM9 read. Pure: the front end composes it from its own state, the
-- chip-level geometry status, RAM_COUNT and the geometry result registers.
chipRead :: Size -> Word32 -> Chip -> Word32
chipRead sz a0 ch
  | stalled (chFront ch) = error "Nds.Gpu3D.Chip.chipRead: the ARM9 bus is held by a GX FIFO stall"
  | otherwise = mmioRead (chipFrontIn ch) sz (alignAddr sz a0) (chFront ch)

-- | What the front end reads from its neighbours.
chipFrontIn :: Chip -> FrontIn
chipFrontIn ch = FrontIn
  { fiGeo = chipGeoStatus ch
  , fiPipe = Poly.pipeStatus (chPoly ch)
  , fiResult = Geo.geoReadResult (chGeo ch)
  }

-- | The geometry part of GXSTAT at chip level: the geometry engine's own
-- bits, and busy (bit 27) while a swap is pending.
chipGeoStatus :: Chip -> GeoStatus
chipGeoStatus ch = (Geo.geoStatus (chGeo ch)) { gsBusy = ppFlushReq (chPoly ch) }

------------------------------------------------------------------------------
-- Geometry engine

-- | The geometry engine takes entries until it cannot ('chipRunOne').
chipRun :: Chip -> (Chip, Drain)
chipRun = go (Drain 0 0)
  where
    go d@(Drain n k) ch = case chipRunOne ch of
      Nothing -> (ch, d)
      Just (ch', fx) -> go (Drain (n + 1) (k + fromEnum (pfDma fx))) ch'

-- | The geometry engine takes one entry, as one iteration of @GPU3D::Run@'s
-- loop: nothing while geometry is disabled, while a @SWAP_BUFFERS@ waits for
-- VBlank, or when the PIPE is empty. Also returns the front end's side
-- effects of the take (the PIPE refill and its DMA trigger).
chipRunOne :: Chip -> Maybe (Chip, PopFx)
chipRunOne ch
  | not (gfGeomEn (chFront ch)) = Nothing
  | ppFlushReq (chPoly ch) = Nothing
  | otherwise = do
      (e, gf', fx) <- popEntry (chFront ch)
      let (cmd, ps) = gatherEntry e (chParams ch)
          ch1 = ch { chFront = gf', chParams = ps }
      pure (maybe ch1 (`execGeo` ch1) cmd, fx)

-- | @ExecuteCommand@'s parameter gathering: a command of at most one
-- parameter runs at once with its entry's parameter, without touching the
-- gathered words; any other entry is appended to @ExecParams@, and the
-- command runs, with every gathered word, when the count reaches the
-- parameter count of the entry that completes it.
gatherEntry :: CmdEntry -> [Word32] -> (Maybe Geo.GeoIn, [Word32])
gatherEntry (CmdEntry c p) ps
  | n <= 1 = (Just (Geo.GeoCmd c [p]), ps)
  | length ps' >= n = (Just (Geo.GeoCmd c ps'), [])
  | otherwise = (Nothing, ps')
  where
    n = cmdNumParams c
    ps' = ps ++ [p]

-- | One geometry-engine input and the polygon pipeline behind it. A polygon
-- rejected for lack of RAM sets DISP3DCNT bit 13 in the front end (the
-- polygon block's flag is a set pulse; the front end owns the register and
-- its write-1-to-clear).
execGeo :: Geo.GeoIn -> Chip -> Chip
execGeo gi ch =
  let (geo', evs) = Geo.step (chGeo ch) gi
      feed (p, f) ev =
        let p1 = Poly.step p ev
        in if Poly.pipeOverflow p1
             then (Poly.clearOverflow p1, setDispCntFlags False True f)
             else (p1, f)
      (poly', gf') = foldl' feed (chPoly ch, chFront ch) evs
  in ch { chGeo = geo', chPoly = poly', chFront = gf' }

------------------------------------------------------------------------------
-- Frame events

-- | @GPU3D::VBlank@. With geometry enabled: when rendering is enabled too,
-- a pending swap builds the render list from the finished bank and the
-- @Render*@ registers latch; then a pending swap flips the polygon banks.
-- With geometry disabled nothing happens (the swap stays pending).
chipVBlank :: Chip -> Chip
chipVBlank ch
  | not (gfGeomEn gf) = ch
  | otherwise =
      let poly = chPoly ch
          list
            | gfRendEn gf && ppFlushReq poly = Poly.renderOrder poly
            | otherwise = chRenderList ch
          (poly', _) = Poly.vblank poly
      in ch { chFront = Front.vblank gf, chPoly = poly', chRenderList = list }
  where
    gf = chFront ch

-- | What the renderer consumes now: the latched registers and the render
-- list, each polygon read from polygon and vertex RAM as they are now.
chipRenderFrame :: Chip -> RenderFrame
chipRenderFrame ch =
  let p = chPoly ch
  in RenderFrame (renderRegs (chFront ch)) (map (Poly.toGxPolygon p . Poly.readPoly p) (chRenderList ch))

-- | @SoftRenderer3D::RenderFrame@, every frame (the hardware has no
-- identical-frame skip), from the state the previous frame left.
chipRenderStart :: TexMem -> Chip -> Chip
chipRenderStart mem ch =
  let (out, carry') = renderFrameFrom (chCarry ch) mem (chipRenderFrame ch)
  in ch { chCarry = carry', chColour = lyColour (roTop out) }

-- | @GetLine(y)@: line @y@ of the last frame, scrolled by @RenderXPos@ as
-- it is now; all zero while the frame is aborted.
chipGetLine :: Int -> Chip -> [Word32]
chipGetLine y ch
  | chAbort ch = replicate 256 0
  | otherwise =
      let row = listArray (0, 255) [ chColour ch ! (y * 256 + x) | x <- [0 .. 255] ] :: UArray Int Word32
      in outputLine (rrXPos (renderRegs (chFront ch))) row

-- | @SetEnabled(geometry, rendering)@. Disabling rendering resets the
-- latched rendering state, which empties the render list
-- (@RenderNumPolygons = 0@).
chipPower :: Bool -> Bool -> Chip -> Chip
chipPower geom rend ch = ch
  { chFront = setPower geom rend (chFront ch)
  , chRenderList = if rend then chRenderList ch else []
  }

-- | @SetRenderXPos@.
chipXPos :: Word16 -> Word16 -> Chip -> Chip
chipXPos x m ch = ch { chFront = setRenderXPos x m (chFront ch) }

-- | @AbortFrame |= true@.
chipAbortFrame :: Chip -> Chip
chipAbortFrame ch = ch { chAbort = True }

-- | @GPU::FinishFrame@: the aborted frame is restarted; @AbortFrame@ clears.
chipFrameEnd :: Chip -> Chip
chipFrameEnd ch = ch { chAbort = False }

-- | @CheckFIFOIRQ@ after an IF write: the GXFIFO request is re-evaluated
-- from the IRQ mode and the FIFO level.
chipIrqCheck :: Chip -> Chip
chipIrqCheck ch =
  let gf = chFront ch
  in ch { chFront = gf { gfIrq = fifoIrqCond (gfIrqMode gf) (fromIntegral (fifoLevel gf)) } }

------------------------------------------------------------------------------
-- Outputs

-- | The ARM9 bus is held until the geometry engine makes room.
chipStalled :: Chip -> Bool
chipStalled = stalled . chFront

-- | IF bit 21 (GXFIFO).
chipIrq :: Chip -> Bool
chipIrq = irqLine . chFront

-- | GXFIFO DMA request level (fewer than 128 FIFO entries).
chipDmaRequest :: Chip -> Bool
chipDmaRequest = dmaRequest . chFront
