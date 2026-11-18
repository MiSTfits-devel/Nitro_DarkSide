-- | Gate for the GX front-end model ('Nds.Gpu3D.GxFront') against the
-- production melonDS GPU3D register block and command FIFO
-- (@tools/gx3d_oracle/gxfront_oracle.cpp@).
--
-- Every case is a script of ops (ARM9 reads and writes at all widths,
-- geometry pops, VBlanks, render X position writes, POWCNT1 writes, and the
-- neighbour inputs: geometry status, RAM_COUNT, result registers, DISP3DCNT
-- status bits). The same script runs through the model and the oracle; after
-- every op both print the read value or popped entry, the whole front-end
-- state (FIFO level and end entries, PIPE, stall queue, GXSTAT, IRQ, DMA
-- check, counters, packer, registers), the live tables after table writes and
-- the latched render registers after frame events, and the gate compares the
-- text op by op. Writes are never issued while the model says the bus is
-- stalled: pops are inserted first, as the held ARM9 would wait (if the model
-- were wrong about the stall, the oracle's stall queue would show it).
--
-- Usage: gxfront-check ORACLE [SEED [RANDOM_CASES [OPS_PER_CASE]]]
module Main (main) where

import Control.Monad (forM_, unless, when)
import Data.Bits (shiftL, shiftR, testBit, xor, (.&.), (.|.))
import Data.Foldable (toList)
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import qualified Data.Sequence as Seq
import Data.Word (Word16, Word32, Word64, Word8)
import Numeric (showHex)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

import Nds.Gpu3D.GxFront
import Nds.Gpu3D.Types

------------------------------------------------------------------------------
-- Ops

data Geo = Geo
  { gTb, gBr :: !Bool
  , gPs      :: !Word8
  , gPj      :: !Bool
  , gSb, gSe, gBz :: !Bool
  } deriving (Eq, Show)

data Op
  = OCase String
  | OW Size Word32 Word32
  | OR Size Word32
  | OP
  | OV
  | OX Word16 Word16
  | OE Bool Bool
  | OG Geo
  | OF Bool Bool
  | OQ Word16 Word16
  | OZ Word32 Word32
  deriving (Eq, Show)

hex :: (Integral a, Show a) => a -> String
hex v = showHex v ""

b01 :: Bool -> String
b01 b = if b then "1" else "0"

sizeBits :: Size -> String
sizeBits S8 = "8"
sizeBits S16 = "16"
sizeBits S32 = "32"

render :: Op -> String
render op = case op of
  OCase n -> "C " ++ n
  OW s a v -> unwords ["W", sizeBits s, hex a, hex v]
  OR s a -> unwords ["R", sizeBits s, hex a]
  OP -> "P"
  OV -> "V"
  OX x m -> unwords ["X", hex x, hex m]
  OE g r -> unwords ["E", b01 g, b01 r]
  OG g -> unwords ["G", b01 (gTb g), b01 (gBr g), hex (gPs g), b01 (gPj g), b01 (gSb g), b01 (gSe g), b01 (gBz g)]
  OF u o -> unwords ["F", b01 u, b01 o]
  OQ p v -> unwords ["Q", hex p, hex v]
  OZ a v -> unwords ["Z", hex a, hex v]

------------------------------------------------------------------------------
-- The model side: the front end plus stubs for its neighbours.

data H = H
  { hSt   :: !GxFront
  , hGeo  :: !Geo
  , hPipe :: !PipeStatus
  , hRes  :: !(M.Map Word32 Word32)
  }

geo0 :: Geo
geo0 = Geo False False 0 False False False False

h0 :: H
h0 = H initGxFront geo0 (PipeStatus 0 0) resetResults

-- | The result registers after @GPU3D::Reset@: identity clip and vector
-- matrices, zero test results.
resetResults :: M.Map Word32 Word32
resetResults = M.fromList [(a, 0x1000) | a <- [0x04000640, 0x04000654, 0x04000668, 0x0400067C, 0x04000680, 0x04000690, 0x040006A0]]

geoStatus :: Geo -> GeoStatus
geoStatus g = GeoStatus
  { gsTestBusy = gTb g, gsBoxResult = gBr g, gsPosStack = gPs g, gsProjStack = gPj g
  , gsStackBusy = gSb g, gsStackError = gSe g, gsBusy = gBz g }

frontIn :: H -> FrontIn
frontIn h = FrontIn (geoStatus (hGeo h)) (hPipe h) (\a -> M.findWithDefault 0 a (hRes h))

tableAddr :: Word32 -> Bool
tableAddr a = a >= 0x04000330 && a < 0x040003C0

-- | One op through the model: the next harness state and the lines the
-- oracle prints for it.
step :: H -> Op -> (H, [String])
step h op = case op of
  OCase _ -> let h' = h0 in (h', [stateLine h' 0, tablesLine h', renderLine h'])
  OW s a v ->
    let (st, fx) = mmioWrite s a v (hSt h)
        g = hGeo h
        g' = if wfAck fx then g { gSe = False, gPj = False } else g
        h' = h { hSt = st, hGeo = g' }
    in (h', stateLine h' 0 : [tablesLine h' | tableAddr a])
  OR s a -> (h, ["R " ++ hex (mmioRead (frontIn h) s a (hSt h)), stateLine h 0])
  OP -> case popEntry (hSt h) of
    Nothing -> (h, ["P empty", stateLine h 0])
    Just (e, st, fx) ->
      let h' = h { hSt = st }
      in (h', [unwords ["P", hex (ceCmd e), hex (ceParam e)], stateLine h' (if pfDma fx then 1 else 0)])
  OV -> frame (vblank (hSt h))
  OX x m -> frame (setRenderXPos x m (hSt h))
  OE g r -> frame (setPower g r (hSt h))
  OG g -> let h' = h { hGeo = g } in (h', [stateLine h' 0])
  OF u o -> let h' = h { hSt = setDispCntFlags u o (hSt h) } in (h', [stateLine h' 0])
  OQ p v -> let h' = h { hPipe = PipeStatus p v } in (h', [stateLine h' 0])
  OZ a v ->
    let v' = if a == 0x04000634 then v .&. 0xFFFF else v
        h' = h { hRes = M.insert a v' (hRes h) }
    in (h', [stateLine h' 0])
  where
    frame st = let h' = h { hSt = st } in (h', [stateLine h' 0, renderLine h'])

entryStr :: CmdEntry -> String
entryStr e = hex (ceCmd e) ++ ":" ++ hex (ceParam e)

stateLine :: H -> Int -> String
stateLine h dma = unwords $
  [ "S f=" ++ hex (Seq.length fifo) ]
  ++ (if Seq.null fifo then [] else [entryStr (Seq.index fifo 0), entryStr (Seq.index fifo (Seq.length fifo - 1))])
  ++ [ "p=" ++ hex (Seq.length (gfPipe st)) ] ++ map entryStr (toList (gfPipe st))
  ++ [ "q=" ++ hex (Seq.length (gfStallQ st)) ] ++ map entryStr (toList (gfStallQ st))
  ++ [ "gx=" ++ hex (gxStat (geoStatus g) st)
     , "irq=" ++ b01 (irqLine st)
     , "dma=" ++ show dma
     , "pp=" ++ hex (gfNumPushPop st)
     , "tst=" ++ hex (gfNumTest st)
     , "epc=" ++ hex (gfExecParamCount st)
     , "pk=" ++ intercalate "," [hex (pkNumCommands pk), hex (pkCurCommand pk), hex (pkParamCount pk), hex (pkTotalParams pk)]
     , "dc=" ++ hex (gfDispCnt st)
     , "ar=" ++ hex (gfAlphaRefVal st) ++ "," ++ hex (gfAlphaRef st)
     , "ca=" ++ hex (gfClearAttr1 st) ++ "," ++ hex (gfClearAttr2 st)
     , "fc=" ++ hex (gfFogColor st)
     , "fo=" ++ hex (gfFogOffset st)
     , "zd=" ++ hex (zeroDotW st)
     , "en=" ++ b01 (gfGeomEn st) ++ b01 (gfRendEn st)
     , "xp=" ++ hex (rrXPos (renderRegs st))
     , "se=" ++ b01 (gSe g) ++ "," ++ b01 (gPj g)
     ]
  where
    st = hSt h
    g = hGeo h
    fifo = gfFifo st
    pk = gfPack st

list :: (Integral a, Show a) => String -> [a] -> String
list tag xs = tag ++ "=" ++ intercalate "," (map hex xs)

tablesLine :: H -> String
tablesLine h = unwords
  [ "T", list "fd" (toList (gfFogDensity st)), list "ed" (toList (gfEdge st)), list "tn" (toList (gfToon st)) ]
  where st = hSt h

renderLine :: H -> String
renderLine h = unwords
  [ "RR dc=" ++ hex (rrDispCnt r), "ar=" ++ hex (rrAlphaRef r)
  , "ca=" ++ hex (rrClearAttr1 r) ++ "," ++ hex (rrClearAttr2 r)
  , "fc=" ++ hex (rrFogColor r), "fo=" ++ hex (rrFogOffset r), "fs=" ++ hex (rrFogShift r)
  , list "fd" (rrFogDensity r), list "ed" (rrEdgeTable r), list "tn" (rrToonTable r)
  , "xp=" ++ hex (rrXPos r) ]
  where r = renderRegs (hSt h)

-- | The script as issued: a pop goes in before every ARM9 access while the
-- model holds the bus. Returns the ops and the expected lines per op.
issue :: [Op] -> [(Op, [String], H)]
issue = go h0
  where
    go _ [] = []
    go h (op : ops)
      | busOp op && stalled (hSt h) && headEntry (hSt h) /= Nothing = go h (OP : op : ops)
      | otherwise = let (h', ls) = step h op in (op, ls, h') : go h' ops
    busOp (OW _ _ _) = True
    busOp (OR _ _) = True
    busOp _ = False

------------------------------------------------------------------------------
-- Directed cases

on :: [Op]
on = [OE True True]

w32, w16, w8 :: Word32 -> Word32 -> Op
w32 = OW S32
w16 = OW S16
w8 = OW S8

gx :: Word32 -> Op
gx = w32 0x04000400

readAll :: [Op]
readAll =
     [OR S8 a | a <- [0x04000060 .. 0x04000063] ++ [0x04000320 .. 0x040006A3]]
  ++ [OR S16 a | a <- [0x04000060, 0x04000062] ++ [0x04000320, 0x04000322 .. 0x040006A2]]
  ++ [OR S32 a | a <- 0x04000060 : [0x04000320, 0x04000324 .. 0x040006A0]]

readGx :: [Op]
readGx = [OR S8 a | a <- [0x04000600 .. 0x04000603]] ++ [OR S16 0x04000600, OR S16 0x04000602, OR S32 0x04000600]

resultWords :: [Word32]
resultWords = [0x04000620, 0x04000624 .. 0x04000634] ++ [0x04000640, 0x04000644 .. 0x040006A0]

directed :: [(String, [Op])]
directed =
  [ ("reset-reads", readAll)
  , ("reads", on
      ++ [OZ a (0x80000001 * (a .&. 0xFFF) `xor` 0xA5A5F00F) | a <- resultWords]
      ++ [OQ 0x123 0x1789, OG (Geo False True 0x2A True False True False), gx 0x15]
      ++ readAll
      ++ [OG (Geo True True 0x3F True True True True)] ++ readGx
      ++ [OG (Geo False False 31 False False False True)] ++ readGx
      ++ [OP] ++ readGx)
  , ("dispcnt", on ++
      [ w16 0x04000060 0xFFFF, OR S16 0x04000060, OF True True, OR S32 0x04000060
      , w16 0x04000060 0x1004, OR S32 0x04000060, w16 0x04000060 0x2004, OR S16 0x04000060
      , OF False True, w32 0x04000060 0xFFFFDFFF, OR S32 0x04000060
      , OF True False, w32 0x04000060 0xFFFFFFFF, OR S32 0x04000060
      , w8 0x04000060 0x55, w8 0x04000061 0x55, w16 0x04000062 0xFFFF, OR S16 0x04000062, OR S8 0x04000060
      , w32 0x04000060 0x0000F0F0, OV, w32 0x04000060 0x00000F0F, OF True True, OV ])
  , ("alpharef", on ++
      [ w8 0x04000340 0xFF, OV, w32 0x04000060 4, OV, w8 0x04000341 0x1F, w16 0x04000340 0x1234, OV
      , w16 0x04000342 0x1F, w32 0x04000340 0xFFFFFFE5, OV, w32 0x04000060 0, OV
      , w16 0x04000340 0x11, w16 0x04000060 4, OV ])
  , ("clear-fog", on ++
      [ w16 0x04000350 0x1234, w16 0x04000352 0x5678, w16 0x04000354 0x9ABC, w16 0x04000356 0xDEF0, OV
      , w32 0x04000350 0x11223344, w32 0x04000354 0x55667788, OV
      , w32 0x04000352 0xFFFFFFFF, w32 0x04000356 0xFFFFFFFF, w8 0x04000350 0xEE, w8 0x04000357 0xEE, OV
      , w16 0x04000358 0xAAAA, w16 0x0400035A 0xBBBB, w16 0x0400035C 0xFFFF, OV
      , w32 0x04000358 0xCAFEBABE, w32 0x0400035C 0xFFFFFFFF, w16 0x0400035E 0x1234, OV
      , w8 0x04000358 1, w8 0x0400035C 2, w32 0x0400035A 3, w32 0x04000060 0x0A00, OV ])
  , ("tables", on
      ++ [w8 a (fromIntegral ((a * 37) .&. 0xFF)) | a <- [0x04000330 .. 0x0400033F]]
      ++ [w8 a (fromIntegral ((a * 41) .&. 0xFF)) | a <- [0x04000360 .. 0x0400037F]]
      ++ [w8 a (fromIntegral ((a * 43) .&. 0xFF)) | a <- [0x04000380 .. 0x040003BF]]
      ++ [OV]
      ++ [w16 a ((a * 0x9E37) .&. 0xFFFF) | a <- [0x04000330, 0x04000332 .. 0x0400033E]]
      ++ [w16 a ((a * 0x7F4B) .&. 0xFFFF) | a <- [0x04000360, 0x04000362 .. 0x0400037E]]
      ++ [w16 a ((a * 0x1D35) .&. 0xFFFF) | a <- [0x04000380, 0x04000382 .. 0x040003BE]]
      ++ [OV]
      ++ [w32 a (a * 0x9E3779B9) | a <- [0x04000330, 0x04000334 .. 0x0400033C]]
      ++ [w32 a (a * 0x85EBCA6B) | a <- [0x04000360, 0x04000364 .. 0x0400037C]]
      ++ [w32 a (a * 0xC2B2AE35) | a <- [0x04000380, 0x04000384 .. 0x040003BC]]
      ++ [OV]
      ++ [w32 a 0xFFFFFFFF | a <- [0x04000320, 0x04000324 .. 0x0400032C] ++ [0x04000344, 0x04000348, 0x0400034C]
                                ++ [0x040003C0, 0x040003C4 .. 0x040003FC]]
      ++ [w16 a 0xFFFF | a <- [0x04000320, 0x04000344, 0x040003C0, 0x040003FE]]
      ++ [w8 a 0xFF | a <- [0x04000321, 0x04000345, 0x040003C1, 0x040003FF]]
      ++ [OV])
  , ("zerodot", on ++
      [ w16 0x04000610 0xFFFF, w32 0x04000610 0x12345678, w8 0x04000610 0x12, w16 0x04000612 0x3456
      , w32 0x04000612 0x3456, w16 0x04000610 0, w32 0x04000614 0x77 ])
  , ("gxstat-writes", on ++
      [ OG (Geo False False 5 True False True False), w8 0x04000601 0x7F, w8 0x04000601 0x80
      , OG (Geo False False 5 True False True False), w16 0x04000600 0x7FFF, w16 0x04000600 0x8000
      , OG (Geo False False 5 True False True False), w32 0x04000600 0x80004000
      , w8 0x04000603 0xFF, w16 0x04000602 0x4000, w32 0x04000600 0x00000000, w8 0x04000603 0x80
      , w8 0x04000600 0xFF, w8 0x04000602 0xFF, w16 0x04000602 0xFFFF, w32 0x04000600 0xFFFFFFFF
      , w32 0x04000604 0xFFFFFFFF, w16 0x04000606 0xFFFF, w32 0x04000608 1 ] ++ readGx)
  , ("power", [ w32 0x04000060 0x1F, w8 0x04000340 3, w32 0x04000330 0x11112222, gx 0x15, w32 0x04000444 0
              , w32 0x04000610 0x55, w32 0x04000600 0x40000000, OV, OX 0x1FF 0xFFFF ]
      ++ [OE True False, w32 0x04000330 0x33334444, w32 0x04000350 1, gx 0x15, OV, OX 0x1FF 0xFFFF]
      ++ [OE False True, w32 0x04000330 0x55556666, w32 0x04000340 7, gx 0x15, w32 0x0400045C 9
         , w32 0x04000610 0x66, w32 0x04000600 0x80000000, OV, OX 0x0AB 0x00FF]
      ++ on ++ [OV, OX 0x1FF 0xFFFF, OX 0xAB00 0xFF00, OX 0x00CD 0x00FF, OX 0xFFFF 0xFFFF, OE True False, OX 0 0xFFFF]
      ++ on ++ [OV, OE False False, OV, OE True True, gx 0x15, OV])
  , ("packing", on ++
      [ gx 0, gx 0x15151515, gx 0x00000015, gx 0x00001500, gx 0x00150000, gx 0x15000000
      , gx 0x00002010, gx 0xAAAA0001, gx 0xBBBB0002
      , gx 0x00000016 ] ++ map gx [1 .. 16] ++
      [ gx 0x34 ] ++ map gx [0x100 .. 0x11F] ++
      [ gx 0x00727170 ] ++ map gx [0x200 .. 0x205] ++
      [ gx 0x000000FF, gx 0x00FF0010, gx 0x1234, gx 0x11121115, gx 0x99
      , gx 0x10, w32 0x04000444 0xDEAD, w16 0x04000400 0x10, w8 0x04000400 0x10, gx 0x77
      , gx 0x41504060, gx 1, gx 2, gx 3, gx 0, gx 0x00000000, gx 0x00001000, gx 0x5555
      , gx 0x00100000, gx 0x6666, gx 0x10000000, gx 0x7777, gx 0x21202322, gx 0xA, gx 0xB, gx 0xC, gx 0xD, gx 0xE
      , gx 0x30313233, gx 1, gx 2, gx 3, gx 4, gx 0x1B1C1A19 ]
      ++ map gx [0x300 .. 0x300 + 3 + 3 + 9 + 12 - 1]
      ++ replicate 20 OP ++ readGx ++ replicate 300 OP ++ readGx)
  , ("direct-ports", on ++ concat
      [ [w32 a (a * 0x01000193), OP] | a <- [0x04000440, 0x04000444 .. 0x040005FC] ]
      ++ [w16 0x04000444 1, w8 0x04000444 1, w16 0x04000500 1] ++ replicate 300 OP)
  , ("malformed-retire", on ++
      [ w32 0x04000458 1, w32 0x04000458 2, w32 0x040005C0 3, OP, OP, OP, OP ] ++ readGx ++
      [ w32 0x040005C0 4, w32 0x040005C4 5, OP, OP ] ++ readGx ++
      [ w32 0x040005C8 6, w32 0x04000448 7, w32 0x04000444 8 ] ++ readGx ++ replicate 6 OP ++ readGx)
  , ("fifo-full", on ++
      [ w32 0x04000600 0x40000000 ] ++ replicate 261 (w32 0x04000454 0) ++ readGx
      ++ concat (replicate 140 (OP : readGx))
      ++ [ w32 0x04000600 0x80000000 ] ++ replicate 130 OP ++ readGx
      ++ [ w32 0x04000600 0xC0000000 ] ++ replicate 4 OP ++ readGx
      ++ [ w32 0x04000600 0x00000000, w8 0x04000603 0x40 ] ++ readGx)
  , ("stall-packed", on ++
      [ w32 0x04000600 0x80000000 ] ++ replicate 258 (w32 0x04000454 0)
      ++ [ gx 0x15151515, gx 0x00001110 ] ++ readGx ++ [gx 0x1234, gx 0x34] ++ map gx [1 .. 32]
      ++ replicate 300 OP ++ readGx)
  , ("stall-counted", on ++
      [ w32 0x04000600 0x40000000 ] ++ replicate 260 (w32 0x04000444 0)
      ++ [ w32 0x04000448 0, w32 0x040005C8 0, gx 0x00721211, gx 1, gx 2 ] ++ readGx
      ++ replicate 270 OP ++ readGx)
  , ("vblank", on ++
      [ w32 a (a * 0x2545F491) | a <- [0x04000360, 0x04000364 .. 0x0400037C] ] ++
      [ w32 0x04000060 0x4F55, w8 0x04000340 0x1A, w32 0x04000350 0x12345678, w32 0x04000354 0x9ABCDEF0
      , w32 0x04000358 0x0F0F0F0F, w32 0x0400035C 0x7FFF, OF False True, OV, OX 0x155 0xFFFF
      , OE True False, OV, OE True True, OV, OE False True, w32 0x04000360 0, OV, OE True True, OV ])
  , ("geo-status", on ++ concat
      [ [OG (Geo (testBit i 0) (testBit i 1) (fromIntegral (i * 7)) (testBit i 2) (testBit i 3) (testBit i 4) (testBit i 5))]
        ++ readGx | i <- [0 .. 63 :: Int] ]
      ++ [w32 0x04000444 0, w32 0x040005C8 0] ++ readGx ++ [OP] ++ readGx ++ [OP] ++ readGx)
  -- CheckFIFOIRQ exactly at the thresholds: IRQ-mode writes with the FIFO
  -- at 127, 128 and 129 entries, and PIPE refills that leave 128 / 126
  -- (mode 1) or 1 / 0 (mode 2) entries.
  , ("irq-threshold", on ++
      replicate (4 + 127) (w32 0x04000454 0) ++
      [ w32 0x04000600 0x40000000 ] ++ readGx ++
      [ w32 0x04000454 0, w32 0x04000600 0x40000000 ] ++ readGx ++
      [ w8 0x04000603 0x40 ] ++ readGx ++ [ w16 0x04000602 0x4000 ] ++ readGx ++
      [ w32 0x04000454 0, w32 0x04000600 0x40000000 ] ++ readGx ++
      [ w32 0x04000454 0, OP, OP ] ++ readGx ++
      [ OP, OP ] ++ readGx ++
      [ w32 0x04000600 0x00000000, w32 0x04000454 0, w32 0x04000454 0, w32 0x04000600 0x40000000, OP, OP ] ++ readGx)
  , ("irq-mode2", on ++
      replicate (4 + 3) (w32 0x04000454 0) ++
      [ w32 0x04000600 0x80000000 ] ++ readGx ++
      [ OP, OP ] ++ readGx ++ [ OP, OP ] ++ readGx ++ [ OP ] ++ readGx ++
      [ w32 0x04000600 0xC0000000 ] ++ readGx ++ [ w32 0x04000454 0, w32 0x04000600 0x80000000 ] ++ readGx ++
      replicate 4 OP ++ readGx)
  ]

------------------------------------------------------------------------------
-- Random cases

newtype Rng = Rng Word64

next :: Rng -> (Word64, Rng)
next (Rng s) =
  let s' = s + 0x9E3779B97F4A7C15
      z1 = (s' `xor` (s' `shiftR` 30)) * 0xBF58476D1CE4E5B9
      z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94D049BB133111EB
  in (z2 `xor` (z2 `shiftR` 31), Rng s')

below :: Int -> Rng -> (Int, Rng)
below n r = let (x, r') = next r in (fromIntegral (x `mod` fromIntegral n), r')

word :: Rng -> (Word32, Rng)
word r = let (x, r') = next r in (fromIntegral (x `shiftR` 16), r')

pick :: [a] -> Rng -> (a, Rng)
pick xs r = let (i, r') = below (length xs) r in (xs !! i, r')

validCmds :: [Word8]
validCmds = [0x10 .. 0x1C] ++ [0x20 .. 0x2B] ++ [0x30 .. 0x34] ++ [0x40, 0x41, 0x50, 0x60, 0x70, 0x71, 0x72]

-- | A packed command word and the parameters its commands take (sometimes
-- one too few or too many, to desynchronise the packer).
packed :: Rng -> ([Word32], Rng)
packed r0 =
  let (n, r1) = below 5 r0
      (cmds, r2) = cmdBytes n r1
      (lead, r3) = below 6 r2
      bytes = (if lead == 0 && n < 4 then (0 :) else id) cmds
      bytes4 = take 4 (bytes ++ repeat 0)
      wordV = foldr (\b acc -> (acc `shiftL` 8) .|. fromIntegral b) 0 bytes4
      nparams = sum [cmdNumParams b | b <- bytes4]
      (skew, r4) = below 16 r3
      np' = max 0 (nparams + (if skew == 0 then -1 else if skew == 1 then 1 else 0))
      (params, r5) = paramWords np' r4
  in (wordV : params, r5)
  where
    cmdBytes 0 r = ([], r)
    cmdBytes k r =
      let (kind, r1) = below 20 r
          (b, r2) = if kind == 0 then (\(w, r') -> (fromIntegral w, r')) (word r1)
                    else if kind == 1 then (0, r1) else pick validCmds r1
          (bs, r3) = cmdBytes (k - 1 :: Int) r2
      in (b : bs, r3)
    paramWords 0 r = ([], r)
    paramWords k r = let (w, r1) = paramWord r; (ws, r2) = paramWords (k - 1 :: Int) r1 in (w : ws, r2)
    paramWord r = let (k, r1) = below 8 r in if k == 0 then (0, r1) else word r1

regAddrs :: [Word32]
regAddrs =
  [0x04000060, 0x04000062, 0x04000340, 0x04000342, 0x04000350, 0x04000352, 0x04000354, 0x04000356
  , 0x04000358, 0x0400035A, 0x0400035C, 0x0400035E, 0x04000600, 0x04000602, 0x04000610, 0x04000612
  , 0x04000320, 0x04000604, 0x04000630, 0x04000640]

-- | One random case of @n@ op proposals. @flavour@ 0 favours the FIFO (fill
-- and drain bursts), 1 the registers, 2 mixes everything.
randomCase :: Int -> Int -> Rng -> [Op]
randomCase flavour n r0 = OE True True : go n (0 :: Int) r0
  where
    go k phase r
      | k <= 0 = []
      | otherwise =
          let (x, r1) = below 1000 r
              (ops, r2) = proposal phase x r1
              (flip', r3) = below 200 r2
              phase' = if flip' == 0 then 1 - phase else phase
          in ops ++ go (k - length ops) phase' r3
    fifoWeight = case flavour of 0 -> 700; 1 -> 150; _ -> 400
    proposal phase x r
      | x < fifoWeight =
          let (y, r1) = below 100 r
              popP = if phase == 0 then 25 else 85
          in if y < popP then ([OP], r1) else fifoWrite r1
      | x < fifoWeight + 60 = let (s, r1) = pick [S8, S16, S32] r
                                  (a, r2) = readAddr r1
                              in ([OR s (align s a)], r2)
      | x < fifoWeight + 230 = regWrite r
      | x < fifoWeight + 245 = ([OV], r)
      | x < fifoWeight + 252 = let (v, r1) = word r; (m, r2) = pick [0x00FF, 0xFF00, 0xFFFF] r1
                               in ([OX (fromIntegral v) m], r2)
      | x < fifoWeight + 256 = let (p, r1) = below 16 r in ([OE (p /= 0) (p /= 1)], r1)
      | x < fifoWeight + 268 = let (v, r1) = word r
                                   g = Geo (testBit v 0) (testBit v 1) (fromIntegral (v `shiftR` 2) .&. 0x3F)
                                           (testBit v 8) (testBit v 9) (testBit v 10) (testBit v 11)
                               in ([OG g], r1)
      | x < fifoWeight + 272 = let (v, r1) = below 4 r in ([OF (testBit v 0) (testBit v 1)], r1)
      | x < fifoWeight + 276 = let (v, r1) = word r in ([OQ (fromIntegral v .&. 0x7FF) (fromIntegral (v `shiftR` 16) .&. 0x1FFF)], r1)
      | x < fifoWeight + 290 = let (a, r1) = pick resultWords r; (v, r2) = word r1 in ([OZ a v], r2)
      | otherwise = let (s, r1) = pick [S8, S16, S32] r
                        (a, r2) = readAddr r1
                    in ([OR s (align s a)], r2)
    fifoWrite r =
      let (k, r1) = below 10 r
      in if k < 5 then let (ws, r2) = packed r1 in (map gx ws, r2)
         else if k < 9 then let (a, r2) = below 0x6C r1; (v, r3) = word r2
                            in ([w32 (0x04000440 + fromIntegral a * 4) v], r3)
         else let (s, r2) = pick [S8, S16] r1; (a, r3) = below 0x200 r2; (v, r4) = word r3
              in ([OW s (align s (0x04000400 + fromIntegral a)) v], r4)
    readAddr r =
      let (k, r1) = below 4 r
      in if k == 0 then pick (0x04000600 : 0x04000602 : regAddrs) r1
         else if k == 1 then (\(a, r') -> (0x04000060 + fromIntegral a, r')) (below 4 r1)
         else (\(a, r') -> (0x04000320 + fromIntegral a, r')) (below 0x384 r1)
    regWrite r =
      let (k, r1) = below 6 r
          (s, r2) = pick [S8, S16, S32] r1
          (v, r3) = word r2
          (a, r4) = case k of
            0 -> pick regAddrs r3
            1 -> (\(i, r') -> (0x04000330 + fromIntegral i, r')) (below 0x90 r3)
            2 -> pick [0x04000600, 0x04000601, 0x04000602, 0x04000603] r3
            3 -> (\(i, r') -> (0x04000320 + fromIntegral i, r')) (below 0x384 r3)
            4 -> (\(i, r') -> (0x04000060 + fromIntegral i, r')) (below 4 r3)
            _ -> pick [0x04000340, 0x04000610, 0x0400035C, 0x04000060] r3
          (mask, r5) = below 4 r4
          v' = if k == 2 && mask /= 0 then v .&. 0xC0FFC0FF .|. (fromIntegral mask `shiftL` 30) else v
      in ([OW s (align s a) v'], r5)
    align S8 a = a
    align S16 a = a .&. complement' 1
    align S32 a = a .&. complement' 3
    complement' m = 0xFFFFFFFF `xor` m

------------------------------------------------------------------------------

main :: IO ()
main = do
  args <- getArgs
  (oracle, seed, ncases, nops) <- case args of
    [o] -> pure (o, 1, 12, 4000)
    [o, s] -> pure (o, read s, 12, 4000)
    [o, s, c] -> pure (o, read s, read c, 4000)
    [o, s, c, n] -> pure (o, read s, read c, read n)
    _ -> hPutStrLn stderr "usage: gxfront-check ORACLE [SEED [CASES [OPS]]]" >> exitFailure
  let randoms =
        [ ("random-" ++ show i, randomCase (i `mod` 3) nops (Rng (seed * 0x100000001B3 + fromIntegral i)))
        | i <- [0 .. ncases - 1] ]
      cases = [(n, ops) | (n, ops) <- directed] ++ randoms
      -- drain at the end of every case so every queued entry is compared
      script = concat [OCase n : ops ++ replicate 300 OP | (n, ops) <- cases]
      issued = issue script
      text = unlines (map (\(op, _, _) -> render op) issued)
  (code, out, _oracleLog) <- readProcessWithExitCode oracle [] text
  when (code /= ExitSuccess) $ hPutStrLn stderr ("gxfront-check: oracle exited with " ++ show code)
  let got = lines out
      expectedCount = sum (map (\(_, ls, _) -> length ls) issued)
  when (length got /= expectedCount) $
    hPutStrLn stderr ("gxfront-check: oracle printed " ++ show (length got)
                      ++ " lines, model " ++ show expectedCount)
  let compareOps _ _ [] = []
      compareOps idx gs ((op, ls, _) : rest) =
        let (mine, gs') = splitAt (length ls) gs
        in (if mine == ls then [] else [(idx, op, ls, mine)]) ++ compareOps (idx + 1 :: Int) gs' rest
      bad = compareOps 0 got issued
      isRandom (OCase n, _, _) = take 7 n == "random-"
      isRandom _ = False
      nDirectedOps = length (takeWhile (not . isRandom) issued)
  forM_ (take 5 bad) $ \(idx, op, ls, mine) -> do
    hPutStrLn stderr ("mismatch at op " ++ show idx ++ ": " ++ render op)
    forM_ (zip ls (mine ++ repeat "<missing>")) $ \(e, g) ->
      unless (e == g) $ do
        hPutStrLn stderr ("  model:  " ++ e)
        hPutStrLn stderr ("  oracle: " ++ g)
  putStrLn ("gxfront-model: " ++ show (length cases) ++ " cases (" ++ show (length directed)
            ++ " directed, " ++ show ncases ++ " random x " ++ show nops ++ " proposals, seed "
            ++ show seed ++ "), " ++ show (length issued) ++ " ops (" ++ show nDirectedOps
            ++ " directed), " ++ show expectedCount ++ " lines compared, "
            ++ show (length bad) ++ " failures")
  putStrLn ("gxfront-model coverage: " ++ coverage issued)
  unless (null bad && length got == expectedCount) exitFailure

-- | How often the interesting states occur after an op, over the whole run.
coverage :: [(Op, [String], H)] -> String
coverage issued = intercalate ", " [name ++ " " ++ show (count p) | (name, p) <- probes]
  where
    count p = length [() | (op, _, h) <- issued, p op (hSt h)]
    isPop OP = True
    isPop _ = False
    probes =
      [ ("stalled", \_ st -> stalled st)
      , ("stall-q>=2", \_ st -> Seq.length (gfStallQ st) >= 2)
      , ("fifo-full", \_ st -> fifoLevel st == fifoDepth)
      , ("fifo-half", \_ st -> fifoLevel st == 128)
      , ("fifo-empty+pipe-full", \_ st -> fifoLevel st == 0 && Seq.length (gfPipe st) == pipeDepth)
      , ("irq", \_ st -> irqLine st)
      , ("irq-mode1", \_ st -> gfIrqMode st `shiftR` 30 == 1)
      , ("irq-mode2", \_ st -> gfIrqMode st `shiftR` 30 == 2)
      , ("pack-mid-word", \_ st -> pkNumCommands (gfPack st) /= 0)
      , ("test-wrapped", \_ st -> gfNumTest st >= 0x80000000)
      , ("pushpop-wrapped", \_ st -> gfNumPushPop st >= 0x80000000)
      , ("test-bit", \_ st -> gfTestBit st)
      , ("pushpop-bit", \_ st -> gfPushPopBit st)
      , ("pops", \op _ -> isPop op)
      , ("geometry-off", \_ st -> not (gfGeomEn st))
      , ("rendering-off", \_ st -> not (gfRendEn st))
      ]
