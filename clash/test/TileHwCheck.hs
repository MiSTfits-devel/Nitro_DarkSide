{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}

-- | Gate for "Nds.Gpu2D.TileHw" (Clash top @nds_gpu2d_tilehw@). The
-- reference for every pixel is the host model on the same register, VRAM,
-- palette and OAM state: "Nds.Gpu2D.Line".@bgLine@ for the background,
-- "Nds.Gpu2D.Sprite".@drawSprites@ (the melonDS transcription) for the
-- sprites, its OBJ-line encoding expanded through the palettes exactly as
-- "Nds.Gpu2D.TraceRender"'s @spritePixelAt@ does, and
-- "Nds.Gpu2D.Line".@composeLine@ for the composition. With OBJ off that is
-- checked to equal @renderReferenceLine@. The engine never sees any of it.
--
-- > tilehw-check check FIXTURES SEED NRANDOM [--pure]
-- > tilehw-check fault FIXTURES
-- > tilehw-check dump  FIXTURES SEED NRANDOM PREFIX
-- > tilehw-check time  FIXTURES
--
-- FIXTURES is sim/tests. Scenes: the arm9_2dk scene (engines A and B, every
-- line, BG and OBJ), its state obtained by executing the checked-in
-- arm9_2dk.bin in a small ARM interpreter below and reading back the
-- registers, palettes, OAM and VRAM it wrote; optionally the gpu2d_kirby135
-- capture (engine A, BG and OBJ, every line whose sprites the engine
-- supports), a local, untracked capture from a commercial game that is
-- never committed: it is used only when all seven gpu2d_kirby135_*.hex
-- files are in $TILEHW_KIRBY_DIR (default FIXTURES), and otherwise skipped
-- with one line saying so; and NRANDOM seeded random scenes (0-15 directed
-- backgrounds: both engines x both depths x four screen sizes, scroll at
-- the wrap points; 16-23 sprite chains that overlap by one pixel at equal
-- priority; the rest random in every field, OBJ on in about three
-- quarters).
--
-- check runs the pure step (with RAM models) and the Clash circuit under
-- one closed-loop driver: random line/palette/OAM gaps, random register
-- values on every cycle that is not a line start, random request stalls in
-- bursts and random in-order response latency (1 to 400 cycles). Every line
-- is compared pixel for pixel (colour and layer) with the reference, every
-- line must make exactly one map and one row request per BG tile slot and
-- one request per sprite tile column on the line, and the pure and Clash
-- outputs must agree on every cycle. --pure skips the Clash run (the mutant
-- runs use it).
module Main (main) where

import Clash.Explicit.Prelude (enableGen, systemClockGen, systemResetGen)
import qualified Clash.Prelude as C
import Clash.Prelude (BitVector)
import Clash.Signal.Internal (Signal (..))

import qualified Clash.Sized.Vector as V

import Control.Monad (filterM, forM, forM_, unless, when)
import Data.Array.Unboxed (UArray, listArray, (!), (//))
import Data.Bits (complement, shiftL, shiftR, testBit, xor, (.&.), (.|.))
import qualified Data.ByteString as B
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.Int (Int32)
import Data.List (foldl', transpose)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust, isNothing)
import qualified Data.Sequence as Seq
import Data.Sequence (Seq, ViewL (..), viewl, (|>))
import Data.Word (Word16, Word32, Word64, Word8)
import Numeric (readHex, showHex)
import System.Directory (doesFileExist)
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitFailure)
import System.IO (BufferMode (..), hFlush, hPutStrLn, hSetBuffering, stderr, stdout)
import Text.Printf (hPrintf, printf)

import Nds.Gpu2D.Line (bgLine, composeLine, expandColor15, renderReferenceLine)
import Nds.Gpu2D.Sprite (SpriteInput (..), SpriteLine (..), drawSprites, emptySpriteLine)
import Nds.Gpu2D.TileHw
import Nds.Gpu2D.Types

------------------------------------------------------------------------------
-- A small ARM interpreter, enough for arm9_2dk.bin

data Cpu = Cpu
  { cR    :: !(IM.IntMap Word32)
  , cN, cZ, cC, cV :: !Bool
  , cMem  :: !(M.Map Word32 Word8)   -- every byte the program stored
  , cSteps :: !Int
  }

-- | Run the image (linked at 0x02000000) until it stores 0xCAFEBABE to the
-- mailbox word 0x02FFFF04 (scene fully programmed); return every stored
-- byte and the instruction count.
runArm :: B.ByteString -> Either String (M.Map Word32 Word8, Int)
runArm img = go (Cpu (IM.fromList [(i, 0) | i <- [0 .. 14]] `IM.union` IM.singleton 15 0x02000000)
                     False False False False M.empty 0)
  where
    base = 0x02000000 :: Word32
    fetch a
      | a >= base && a + 3 < base + fromIntegral (B.length img) =
          let o = fromIntegral (a - base)
          in Right (foldr (\k acc -> (acc `shiftL` 8) .|. fromIntegral (B.index img (o + k))) 0 [0 .. 3])
      | otherwise = Left ("read outside the image at 0x" ++ showHex a "")
    go cpu
      | cSteps cpu > 5000000 = Left "no completion after 5M instructions"
      | otherwise = do
          let pc = reg cpu 15
          w <- fetch pc
          r <- exec cpu { cSteps = cSteps cpu + 1 } pc w
          case r of
            Left mem -> Right mem
            Right cpu' -> go cpu'
    reg cpu i = IM.findWithDefault 0 i (cR cpu)
    setR i v cpu = cpu { cR = IM.insert i v (cR cpu) }
    condOk cpu c = case c of
      0x0 -> cZ cpu
      0x1 -> not (cZ cpu)
      0x2 -> cC cpu
      0x3 -> not (cC cpu)
      0x4 -> cN cpu
      0x5 -> not (cN cpu)
      0xA -> cN cpu == cV cpu
      0xB -> cN cpu /= cV cpu
      0xC -> not (cZ cpu) && cN cpu == cV cpu
      0xD -> cZ cpu || cN cpu /= cV cpu
      0xE -> True
      _ -> False
    store :: Int -> Word32 -> Word32 -> Cpu -> Either (M.Map Word32 Word8, Int) Cpu
    store size a v cpu
      | size == 4 && a == 0x02FFFF04 && v == 0xCAFEBABE = Left (cMem cpu, cSteps cpu)
      -- the ARM9 cannot byte-write palette, VRAM or OAM
      | size == 1 && a >= 0x05000000 && a < 0x08000000 = Right cpu
      | otherwise = Right cpu { cMem = foldl' (\m k -> M.insert (a + fromIntegral k) (fromIntegral (v `shiftR` (8 * k))) m)
                                               (cMem cpu) [0 .. size - 1] }
    load size a cpu =
      case [M.lookup (a + fromIntegral k) (cMem cpu) | k <- [0 .. size - 1]] of
        bs | all isJust bs -> Right (foldr (\b acc -> (acc `shiftL` 8) .|. fromIntegral (fromMaybe 0 b)) 0 bs)
        _ | size == 4 -> fetch a
        _ -> Left ("load of size " ++ show size ++ " from 0x" ++ showHex a "")
    next cpu pc = Right (Right (setR 15 (pc + 4) cpu))
    exec cpu pc w
      | not (condOk cpu (w `shiftR` 28)) = next cpu pc
      | w .&. 0x0FFFFFF0 == 0x012FFF10 =
          let t = reg cpu (fromIntegral (w .&. 15))
          in if testBit t 0 then Left "BX to Thumb" else Right (Right (setR 15 t cpu))
      | w .&. 0x0FC000F0 == 0x00000090 =
          let rd = fromIntegral ((w `shiftR` 16) .&. 15)
              v = rv (w .&. 15) * rv ((w `shiftR` 8) .&. 15) + (if testBit w 21 then rv ((w `shiftR` 12) .&. 15) else 0)
              cpu1 = if testBit w 20 then cpu { cN = testBit v 31, cZ = v == 0 } else cpu
          in next (setR rd v cpu1) pc
      | w .&. 0x0E000090 == 0x00000090 && w .&. 0x60 /= 0 = halfword
      | w .&. 0x0C000000 == 0x00000000 = dataProc
      | w .&. 0x0C000000 == 0x04000000 = single
      | w .&. 0x0E000000 == 0x0A000000 =
          let off = fromIntegral ((fromIntegral (w `shiftL` 8) :: Int32) `shiftR` 6) :: Word32
              cpu1 = if testBit w 24 then setR 14 (pc + 4) cpu else cpu
          in Right (Right (setR 15 (pc + 8 + off) cpu1))
      | w .&. 0x0F000010 == 0x0E000010 = next cpu pc   -- MCR/MRC: CP15 setup, no effect here
      | otherwise = Left ("unsupported opcode 0x" ++ showHex w "" ++ " at 0x" ++ showHex pc "")
      where
        rv i = if i == 15 then pc + 8 else reg cpu (fromIntegral i)
        rn = (w `shiftR` 16) .&. 15
        rdI = fromIntegral ((w `shiftR` 12) .&. 15) :: Int
        shifted v typ amt c0 = case typ of
          0 -> if amt == 0 then (v, c0) else (v `shiftL` amt, testBit v (32 - amt))
          1 -> let a = if amt == 0 then 32 else amt
               in (if a == 32 then 0 else v `shiftR` a, testBit v (a - 1))
          2 -> let a = if amt == 0 then 32 else amt
                   s = fromIntegral (fromIntegral v :: Int32) :: Int
               in (fromIntegral (if a >= 32 then (if s < 0 then -1 else 0) else s `div` (2 ^ a)) :: Word32, testBit v (min 31 (a - 1)))
          _ -> if amt == 0 then ((v `shiftR` 1) .|. (if c0 then 0x80000000 else 0), testBit v 0)
               else (rotR v amt, testBit v (amt - 1))
        rotR v a = (v `shiftR` a) .|. (v `shiftL` (32 - a))
        op2 :: (Word32, Bool)
        op2
          | testBit w 25 =
              let imm = w .&. 0xFF
                  rot = fromIntegral (((w `shiftR` 8) .&. 15) * 2)
                  v = if rot == 0 then imm else rotR imm rot
              in (v, if rot == 0 then cC cpu else testBit v 31)
          | testBit w 4 = shifted (rv (w .&. 15)) ((w `shiftR` 5) .&. 3)
                                  (fromIntegral (rv ((w `shiftR` 8) .&. 15) .&. 31)) (cC cpu)
          | otherwise = shifted (rv (w .&. 15)) ((w `shiftR` 5) .&. 3) (fromIntegral ((w `shiftR` 7) .&. 31)) (cC cpu)
        dataProc =
          let opc = (w `shiftR` 21) .&. 15
              s = testBit w 20
              a = rv rn
              (b, sc) = op2
              cin = if cC cpu then 1 else 0
              add x y c = let r = x + y + c
                              co = (fromIntegral x + fromIntegral y + fromIntegral c :: Word64) > 0xFFFFFFFF
                              ov = testBit ((x `xor` r) .&. (y `xor` r)) 31
                          in (r, co, ov)
              arith = case opc of
                2 -> Just (add a (complement b) 1)
                3 -> Just (add b (complement a) 1)
                4 -> Just (add a b 0)
                5 -> Just (add a b cin)
                6 -> Just (add a (complement b) cin)
                7 -> Just (add b (complement a) cin)
                10 -> Just (add a (complement b) 1)
                11 -> Just (add a b 0)
                _ -> Nothing
              logic = case opc of
                0 -> a .&. b; 1 -> a `xor` b; 8 -> a .&. b; 9 -> a `xor` b
                12 -> a .|. b; 13 -> b; 14 -> a .&. complement b; _ -> complement b
              (res, c', v') = case arith of
                Just (r, co, ov) -> (r, co, ov)
                Nothing -> (logic, sc, cV cpu)
              writes = opc < 8 || opc > 11
              cpu1 = if s then cpu { cN = testBit res 31, cZ = res == 0, cC = c', cV = v' } else cpu
          in if writes && rdI == 15 then Left "data processing write to PC"
             else next (if writes then setR rdI res cpu1 else cpu1) pc
        single =
          let p = testBit w 24; u = testBit w 23; byte = testBit w 22; wb = testBit w 21; l = testBit w 20
              off = if testBit w 25 then fst (shifted (rv (w .&. 15)) ((w `shiftR` 5) .&. 3) (fromIntegral ((w `shiftR` 7) .&. 31)) (cC cpu))
                    else w .&. 0xFFF
              baseA = rv rn
              moved = if u then baseA + off else baseA - off
              addr = if p then moved else baseA
              wback c = if not p || wb then setR (fromIntegral rn) moved c else c
              size = if byte then 1 else 4
          in if l then do v <- load size addr cpu
                          next (setR rdI v (wback cpu)) pc
             else case store size addr (rv ((w `shiftR` 12) .&. 15)) cpu of
                    Left mem -> Right (Left mem)
                    Right cpu1 -> next (wback cpu1) pc
        halfword =
          let p = testBit w 24; u = testBit w 23; imm = testBit w 22; wb = testBit w 21; l = testBit w 20
              sh = (w `shiftR` 5) .&. 3
              off = if imm then ((w `shiftR` 4) .&. 0xF0) .|. (w .&. 15) else rv (w .&. 15)
              baseA = rv rn
              moved = if u then baseA + off else baseA - off
              addr = if p then moved else baseA
              wback c = if not p || wb then setR (fromIntegral rn) moved c else c
          in if sh /= 1 then Left "signed halfword/byte transfer"
             else if l then do v <- load (2 :: Int) addr cpu
                               next (setR rdI v (wback cpu)) pc
             else case store 2 addr (rv ((w `shiftR` 12) .&. 15) .&. 0xFFFF) cpu of
                    Left mem -> Right (Left mem)
                    Right cpu1 -> next (wback cpu1) pc

------------------------------------------------------------------------------
-- Scenes

data Scene = Scene
  { scName  :: String
  , scEng   :: !Int
  , scDisp  :: !Word32
  , scBgCnt :: [Word16]
  , scHofs  :: [Word16]              -- 16-bit register values; the engine port takes bits 0-8
  , scVofs  :: [Word16]
  , scBld   :: !Word16
  , scVram  :: UArray Word32 Word8   -- the engine's BG VRAM (A 512 KiB, B 128 KiB)
  , scPal   :: UArray Word32 Word8   -- the 2 KiB standard palette (both engines)
  , scBgExt :: UArray Word32 Word8   -- BG extended palette slots (never used: bit 30 clear or 4bpp)
  , scOam   :: UArray Word32 Word8   -- the engine's 1 KiB OAM
  , scObj   :: UArray Word32 Word8   -- the engine's OBJ VRAM (A 256 KiB, B 128 KiB)
  , scExt   :: UArray Word32 Word8   -- the engine's 8 KiB OBJ extended palette
  , scLines :: [Int]
  }

bytesFrom :: M.Map Word32 Word8 -> Word32 -> Int -> UArray Word32 Word8
bytesFrom mem base size = listArray (0, fromIntegral size - 1)
  [M.findWithDefault 0 (base + fromIntegral i) mem | i <- [0 .. size - 1]]

zeros :: Int -> UArray Word32 Word8
zeros n = listArray (0, fromIntegral n - 1) (replicate n 0)

io16 :: M.Map Word32 Word8 -> Word32 -> Word16
io16 mem a = fromIntegral (M.findWithDefault 0 a mem) .|. (fromIntegral (M.findWithDefault 0 (a + 1) mem) `shiftL` 8)

io32 :: M.Map Word32 Word8 -> Word32 -> Word32
io32 mem a = fromIntegral (io16 mem a) .|. (fromIntegral (io16 mem (a + 2)) `shiftL` 16)

-- | The arm9_2dk scene, both engines, from the program's own stores, and a
-- one-line summary of what the program set up.
scenes2dk :: FilePath -> IO ([Scene], String)
scenes2dk dir = do
  img <- B.readFile (dir ++ "/arm9_2dk.bin")
  (mem, steps) <- either (\e -> die' ("arm9_2dk.bin: " ++ e)) pure (runArm img)
  let vramcnt = [M.findWithDefault 0 (0x04000240 + i) mem | i <- [0 .. 5]]
  unless (vramcnt == [0x81, 0x82, 0x84, 0x84, 0x84, 0x85]) $
    die' ("arm9_2dk: unexpected VRAMCNT A-F " ++ show vramcnt ++ " (the scene mapping changed)")
  -- A -> BG-A, B -> OBJ-A, C -> BG-B, D -> OBJ-B, E -> BG ext (the trap),
  -- F -> OBJ ext palette of engine A; everything else unmapped (zero)
  let pal = bytesFrom mem 0x05000000 0x800
      bgExt = bytesFrom mem 0x06880000 0x8000
      engine e =
        let io = 0x04000000 + (if e == 1 then 0x1000 else 0)
        in Scene { scName = "2dk-" ++ (if e == 0 then "A" else "B")
                 , scEng = e
                 , scDisp = io32 mem io
                 , scBgCnt = [io16 mem (io + 8 + 2 * n) | n <- [0 .. 3]]
                 , scHofs = [io16 mem (io + 0x10 + 4 * n) | n <- [0 .. 3]]
                 , scVofs = [io16 mem (io + 0x12 + 4 * n) | n <- [0 .. 3]]
                 , scBld = io16 mem (io + 0x50)
                 , scVram = bytesFrom mem (if e == 0 then 0x06000000 else 0x06200000) (if e == 0 then 0x80000 else 0x20000)
                 , scPal = pal, scBgExt = bgExt
                 , scOam = bytesFrom mem (0x07000000 + 0x400 * fromIntegral e) 0x400
                 , scObj = bytesFrom mem (if e == 0 then 0x06400000 else 0x06600000) (if e == 0 then 0x40000 else 0x20000)
                 , scExt = if e == 0 then bytesFrom mem 0x06890000 0x2000 else zeros 0x2000
                 , scLines = [0 .. 191] }
      h16 a = showHex (io16 mem a) ""
      summary = "arm9_2dk.bin executed to its 0xCAFEBABE mailbox store: " ++ show steps ++ " instructions, "
        ++ show (M.size mem) ++ " bytes stored; DISPCNT A " ++ showHex (io32 mem 0x04000000) "" ++ " B "
        ++ showHex (io32 mem 0x04001000) "" ++ "; BG3CNT A " ++ h16 0x0400000E
        ++ " B " ++ h16 0x0400100E ++ "; BG palette A[1..3] " ++ unwords (map (\k -> h16 (0x05000000 + 2 * k)) [1 .. 3])
        ++ "; map A[0..3] " ++ unwords (map (\k -> h16 (0x06002000 + 2 * k)) [0 .. 3])
        ++ "; OAM A sprite 2 " ++ unwords (map (\k -> h16 (0x07000010 + 2 * k)) [0 .. 2])
        ++ "; OBJ ext palette A [5][1] " ++ h16 (0x06890000 + 2 * (5 * 256 + 1))
        ++ "; BG ext slot 3 entry 0 " ++ h16 0x06886000 ++ " (the trap, must stay unused)"
  pure ([engine 0, engine 1], summary)

readHexWords :: FilePath -> IO [Word32]
readHexWords p = map (fst . head . readHex) . filter (not . null) . lines . map (\ch -> if ch == '\r' then ' ' else ch)
  <$> readFile p

wordsToBytes :: [Word32] -> UArray Word32 Word8
wordsToBytes ws = listArray (0, fromIntegral (4 * length ws) - 1)
  [fromIntegral (w `shiftR` (8 * k)) | w <- ws, k <- [0 .. 3]]

-- | The seven files of the local gpu2d_kirby135 capture.
kirbyParts :: [String]
kirbyParts = ["bgvram", "pal", "bgep", "oam", "objvram", "objep", "frames"]

-- | The gpu2d_kirby135 capture, if all seven files are present in
-- @$TILEHW_KIRBY_DIR@ (default: the fixture directory), and a status line.
-- The capture is a local, untracked input (gitignored, never committed);
-- without it the gate runs every tracked scene and can pass.
loadKirby :: FilePath -> IO (Maybe Scene, String)
loadKirby dir = do
  kd <- fromMaybe dir <$> lookupEnv "TILEHW_KIRBY_DIR"
  found <- filterM doesFileExist [kd ++ "/gpu2d_kirby135_" ++ f ++ ".hex" | f <- kirbyParts]
  if length found == length kirbyParts
    then do sc <- sceneKirby kd
            pure (Just sc, "kirby135 capture: present in " ++ kd ++ ", included")
    else pure (Nothing, "kirby135 capture not present (" ++ show (length found) ++ " of 7 gpu2d_kirby135_*.hex in "
                        ++ kd ++ "), skipped")

-- | The gpu2d_kirby135 state (engine A) from the capture's seven files.
sceneKirby :: FilePath -> IO Scene
sceneKirby dir = do
  let hex f = readHexWords (dir ++ "/gpu2d_kirby135_" ++ f ++ ".hex")
  vram <- hex "bgvram"
  pal <- hex "pal"
  bgep <- hex "bgep"
  oam <- hex "oam"
  obj <- hex "objvram"
  objep <- hex "objep"
  frame <- take 33 <$> hex "frames"
  let r = drop 1 frame
      w i = r !! i
      lo, hi :: Word32 -> Word16
      lo = fromIntegral
      hi x = fromIntegral (x `shiftR` 16)
  pure Scene { scName = "kirby135", scEng = 0, scDisp = w 0
             , scBgCnt = [lo (w 2), hi (w 2), lo (w 3), hi (w 3)]
             , scHofs = [lo (w (4 + n)) | n <- [0 .. 3]]
             , scVofs = [hi (w (4 + n)) | n <- [0 .. 3]]
             , scBld = lo (w 20)
             , scVram = wordsToBytes vram
             , scPal = wordsToBytes (pal ++ replicate 256 0)
             , scBgExt = wordsToBytes bgep
             , scOam = wordsToBytes oam
             , scObj = wordsToBytes obj
             , scExt = wordsToBytes objep
             , scLines = [0 .. 191] }

-- xorshift64*
rnd :: Word64 -> (Word64, Word64)
rnd s0 = let s1 = s0 `xor` (s0 `shiftR` 12)
             s2 = s1 `xor` (s1 `shiftL` 25)
             s3 = s2 `xor` (s2 `shiftR` 27)
         in (s3, s3 * 2685821657736338717)

rnds :: Word64 -> [Word64]
rnds s = let (s', v) = rnd s in v : rnds s'

-- | Sprite sizes by size index (shape + 4 * size), as melonDS's tables.
sprW, sprH :: [Int]
sprW = [8,16,8,8,16,32,8,8,32,32,16,8,64,64,32,8]
sprH = [8,8,16,8,16,8,32,8,32,16,32,8,64,32,64,8]

-- | Seeded random scene @i@. Scenes 0-15 are directed backgrounds: engine
-- i&1, depth (i>>1)&1, screen size i>>2, scroll at the wrap points. Scenes
-- 16-23 put the sprites in chains that overlap by one pixel at equal
-- priority on the checked lines.
randomScene :: Word64 -> Int -> Scene
randomScene seed i = Scene
  { scName = "random-" ++ show i, scEng = eng, scDisp = disp, scBgCnt = cnts, scHofs = hofs, scVofs = vofs
  , scBld = bld, scVram = vram, scPal = pal, scBgExt = zeros 0x8000
  , scOam = oam, scObj = obj, scExt = ext, scLines = ys }
  where
    vs = rnds (seed * 0x9E3779B97F4A7C15 + fromIntegral i * 7919 + 1)
    v k = vs !! k
    directed = i < 16
    chains = i >= 16 && i < 24
    eng = if directed then i .&. 1 else fromIntegral (v 0 .&. 1)
    noBg = not directed && v 1 `mod` 12 == 0
    n = fromIntegral (v 2 .&. 3) :: Int
    is256 = if directed then testBit i 1 else testBit (v 3) 0
    size = if directed then fromIntegral (i `shiftR` 2) else fromIntegral (v 4 .&. 3) :: Word16
    cntSel = (fromIntegral (v 5) .&. 0x3F3F .&. complement 0x40) .|. (if is256 then 0x80 else 0) .|. (size `shiftL` 14)
             .|. (fromIntegral (v 5 `shiftR` 32) .&. 0x2000)
    cnts = [if k == n then cntSel else fromIntegral (v (6 + k)) | k <- [0 .. 3]]
    objOn = chains || v 32 .&. 3 /= 0
    -- don't-care DISPCNT bits for this engine: OBJ mapping/boundaries (4-6,
    -- 20-23) and OBJ extended palettes (31) unless OBJ is on, BG extended
    -- palettes when 4bpp (30), and on engine B bits 3, 17 and 24-29
    junk = fromIntegral (v 10) .&. (0x80F00070 .|. (if is256 then 0 else 0x40000000)
                                    .|. (if eng == 1 then 0x3F020008 else 0x3F000000)) :: Word32
    disp = junk .|. 0x10000 .|. (if noBg then 0 else 1 `shiftL` (8 + n)) .|. (if objOn then 0x1010 else 0)
    hofsSel
      | directed = [0, 7, 255, 256, 504, 511, 249, 1] !! (i `mod` 8) + fromIntegral (v 11 .&. 0xFE00)
      | otherwise = fromIntegral (v 11)
    vofsSel
      | directed = [250, 505, 0, 127, 383, 300, 506, 255] !! ((i + 3) `mod` 8) + fromIntegral (v 12 .&. 0xFE00)
      | otherwise = fromIntegral (v 12)
    hofs = [if k == n then hofsSel else fromIntegral (v (13 + k)) | k <- [0 .. 3]]
    vofs = [if k == n then vofsSel else fromIntegral (v (17 + k)) | k <- [0 .. 3]]
    -- no colour effect; second targets only where no sprite is semi-transparent
    bld2 = not objOn || v 35 `mod` 5 == 0
    bld = fromIntegral (v 21) .&. (if bld2 then 0xFF3F else 0xC03F)
    ys | directed = [0, 1, 5, 6, 7, 191] ++ [fromIntegral (v (22 + k) `mod` 192) | k <- [0 .. 3]]
       | otherwise = [fromIntegral (v (22 + k) `mod` 192) | k <- [0 .. 5]]
    vsize = if eng == 0 then 0x80000 else 0x20000 :: Int
    osize = if eng == 0 then 0x40000 else 0x20000 :: Int
    -- a quarter of the bytes zero: transparent pixels in both depths
    sparse k seedW = listArray (0, fromIntegral k - 1)
      [if b .&. 0x300 == 0 then 0 else fromIntegral (b `shiftR` 16) | b <- take k (rnds seedW)]
    vram = sparse vsize (v 30)
    obj = sparse osize (v 33)
    pal = listArray (0, 0x7FF) [fromIntegral (b `shiftR` (24 + 8 * (k .&. 1))) | (b, k) <- zip (rnds (v 31)) [0 .. 0x7FF :: Int]]
    ext = listArray (0, 0x1FFF) [fromIntegral (b `shiftR` 40) | b <- take 0x2000 (rnds (v 34))]
    sprite k rs =
      let r j = rs !! j
          kind = r 0 `mod` 100
          disabled = not chains && kind < 12
          mode0 = case r 1 `mod` 20 of
            m | m < 13 -> 0
              | m < 16 -> if bld2 && objOn && bld .&. 0x3F00 /= 0 then 0 else 1
              | m < 18 -> 2
              | otherwise -> 0 :: Word16
          mode = if chains then 0 else mode0
          s256 = testBit (r 1) 8
          shape = fromIntegral ((r 1 `shiftR` 9) .&. 3) :: Int
          sz = fromIntegral ((r 1 `shiftR` 11) .&. 3) :: Int
          h = sprH !! (shape + 4 * sz)
          line = ys !! fromIntegral ((r 2 `shiftR` 24) `mod` fromIntegral (length ys))
          y0 | chains = (ys !! ((k `div` 8) `mod` length ys) - fromIntegral ((r 2 `shiftR` 8) `mod` fromIntegral h)) `mod` 256
             | r 2 `mod` 10 < 7 = (line - fromIntegral ((r 2 `shiftR` 8) `mod` fromIntegral h)) `mod` 256
             | otherwise = fromIntegral ((r 2 `shiftR` 16) `mod` 256)
          x | chains = chainX k
            | r 3 `mod` 10 < 8 = fromIntegral ((r 3 `shiftR` 8) `mod` 320) - 64
            | otherwise = fromIntegral ((r 3 `shiftR` 8) `mod` 512) :: Int
          a0 | disabled = (fromIntegral (r 4) .&. 0xFCFF) .|. 0x0200
             | otherwise = fromIntegral y0 .|. (mode `shiftL` 10) .|. (if s256 then 0x2000 else 0)
                           .|. (fromIntegral shape `shiftL` 14)
          a1 = (fromIntegral x .&. 0x1FF) .|. (fromIntegral (r 4 `shiftR` 16) .&. 0x3E00) .|. (fromIntegral sz `shiftL` 14)
          a2 | chains = (fromIntegral (r 5) .&. 0xF3FF) .|. (fromIntegral ((k `div` 8) .&. 3) `shiftL` 10)
             | otherwise = fromIntegral (r 5)
          a3 = fromIntegral (r 5 `shiftR` 32)
      in [a0, a1, a2, a3 :: Word16]
    -- chain c (sprites 8c..8c+7): each sprite starts at the previous one's
    -- last pixel
    chainX k = let c = k `div` 8
                   start = (c * 13) `mod` 40 - 20
               in start + sum [sprW !! sizeIx j - 1 | j <- [8 * c .. k - 1]]
    sizeIx j = let r1 = sprStreams !! j !! 1
               in fromIntegral ((r1 `shiftR` 9) .&. 3) + 4 * fromIntegral ((r1 `shiftR` 11) .&. 3)
    sprStreams = [take 6 (rnds (v 36 + fromIntegral k * 0x51ED27)) | k <- [0 .. 127 :: Int]]
    oamHalves = concat [sprite k rs | (k, rs) <- zip [0 ..] sprStreams]
    oam = listArray (0, 0x3FF) (concat [[fromIntegral h, fromIntegral (h `shiftR` 8)] | h <- oamHalves])

esOf :: Scene -> EngineState
esOf sc = EngineState
  { esNum = scEng sc, esDispCnt = scDisp sc
  , esBg = V4 (bg 0) (bg 1) (bg 2) (bg 3)
  , esBlendCnt = fromIntegral (scBld sc), esEva = 0, esEvb = 0, esEvy = 0
  , esObjMosaicLine = 0, esBgMosaicLine = 0, esBgMosaicX = 0
  , esOam = uarrayMemory (scOam sc), esVram = uarrayMemory (scVram sc), esObjVram = uarrayMemory (scObj sc)
  , esPalette = uarrayMemory (scPal sc), esBgExtPal = uarrayMemory (scBgExt sc)
  , esOamEpoch = 0, esVramEpoch = 0, esPaletteEpoch = 0 }
  where
    bg k = BgReg (scBgCnt sc !! k) (scHofs sc !! k) (scVofs sc !! k) 0 0 0 0 0 0

pal16 :: UArray Word32 Word8 -> Word32 -> Word16
pal16 a i = fromIntegral (a ! i) .|. (fromIntegral (a ! (i + 1)) `shiftL` 8)

objMask :: Scene -> Word32
objMask sc = if scEng sc == 0 then 0x3FFFF else 0x1FFFF

-- | The reference sprite line: melonDS's sprite phase for this line.
spriteRef :: Scene -> Int -> SpriteLine
spriteRef sc y = drawSprites SpriteInput
  { siEnabled = True, siOBJEnabled = objEnable (scDisp sc), siDispCnt = scDisp sc
  , siMosaicLine = 0, siTargetLine = y
  , siOAMRead = \a -> scOam sc ! (a .&. 0x3FF)
  , siOBJRead = \a -> scObj sc ! a
  , siOBJMask = objMask sc } emptySpriteLine

-- | One OBJ-line word through the palettes, as TraceRender's spritePixelAt.
objPixelRef :: Scene -> Word32 -> Maybe LayerPixel
objPixelRef sc pixel
  | not (testBit pixel 18) = Nothing
  | otherwise =
      let direct = testBit pixel 15
          index = pixel .&. (if testBit pixel 12 then 0xff else 0xfff)
          color | direct = fromIntegral (pixel .&. 0x7fff)
                | testBit pixel 12 = pal16 (scPal sc) (fromIntegral (scEng sc) * 1024 + 512 + index * 2)
                | otherwise = pal16 (scExt sc) (index * 2)
          alpha | testBit pixel 30 = fromIntegral ((pixel `shiftR` 24) .&. 31)
                | testBit pixel 31 = 255
                | otherwise = 0
      in Just (LayerPixel (expandColor15 color) (fromIntegral ((pixel `shiftR` 16) .&. 3)) LObj alpha)

objRow :: Scene -> Int -> [Maybe LayerPixel]
objRow sc y = map (objPixelRef sc) (slPixels (spriteRef sc y))

-- | The reference line: the four BG layer rows and the sprite row (the
-- composition's inputs) and the composed line with the backdrop.
refParts :: Scene -> Int -> ([[Maybe LayerPixel]], [Maybe LayerPixel], [Pixel])
refParts sc y = (bgs, orow, map (fromMaybe backdrop) (composeLine es (map Bg [0 .. 3] ++ [LObj]) (bgs ++ [orow])))
  where
    es = esOf sc
    bgs = map (\k -> bgLine es (Bg k) y) [0 .. 3]
    orow = objRow sc y
    backdrop = Pixel (expandColor15 (pal16 (scPal sc) (fromIntegral (scEng sc) * 1024))) LBackdrop

layerCode :: Layer -> Int
layerCode l = case l of Bg k -> k; LObj -> 4; LBackdrop -> 5; L3D -> 6

regsOf :: Scene -> Regs
regsOf sc = Regs (fromIntegral (scDisp sc)) (v4 (map fromIntegral (scBgCnt sc)))
                 (v4 (map (fromIntegral . (.&. 0x1FF)) (scHofs sc))) (v4 (map (fromIntegral . (.&. 0x1FF)) (scVofs sc)))
                 (fromIntegral (scBld sc))

v4 :: [a] -> C.Vec 4 a
v4 [a, b, c, d] = a C.:> b C.:> c C.:> d C.:> C.Nil
v4 _ = error "v4"

junkRegs :: Word64 -> Word64 -> Regs
junkRegs a b = Regs (fromIntegral a) (v4 [fromIntegral (b `shiftR` (16 * k)) | k <- [0 .. 3]])
                    (v4 [fromIntegral (a `shiftR` (32 + 8 * k)) | k <- [0 .. 3]])
                    (v4 [fromIntegral (b `shiftR` (9 * k + 3)) | k <- [0 .. 3]]) (fromIntegral (a `shiftR` 20))

-- | BG tile slots a line needs (32, 33, none without a BG).
slotsOf :: Scene -> Int
slotsOf sc = case [k | k <- [0 .. 3], testBit (scDisp sc) (8 + k)] of
  (k : _) -> if scHofs sc !! k .&. 7 == 0 then 32 else 33
  [] -> 0

oamHalf :: Scene -> Int -> Word16
oamHalf sc k = pal16 (scOam sc) (fromIntegral (2 * k))

signExt9 :: Word16 -> Int
signExt9 v = let x = fromIntegral (v .&. 0x1FF) in if x >= 256 then x - 512 else x

-- | A sprite on the line as the harness sees it (from OAM alone, for the
-- request count, line selection and coverage; pixels are the reference's).
data SprOn = SprOn
  { soA0 :: !Word16, soA1 :: !Word16, soA2 :: !Word16
  , soW :: !Int, soH :: !Int, soX :: !Int, soY0 :: !Int, soCols :: !Int }

-- | Sprites drawn on line @y@ in OAM order, or the fault bit of the first
-- one the engine must refuse.
spritesOn :: Scene -> Int -> Either Int [SprOn]
spritesOn sc y
  | not (objEnable (scDisp sc)) = Right []
  | otherwise = go 0 []
  where
    bld2 = scBld sc .&. 0x3F00 /= 0
    go 128 acc = Right (reverse acc)
    go k acc =
      let a0 = oamHalf sc (4 * k); a1 = oamHalf sc (4 * k + 1); a2 = oamHalf sc (4 * k + 2)
          typ = (a0 `shiftR` 8) .&. 3
          mode = (a0 `shiftR` 10) .&. 3
          sz = fromIntegral ((a0 `shiftR` 14) .|. ((a1 `shiftR` 14) `shiftL` 2)) :: Int
          w = sprW !! sz; h = sprH !! sz
          dbl = if typ == 3 then 2 else 1
          y0 = fromIntegral (a0 .&. 0xFF)
          ypos = (y - y0) .&. 0xFF
          xpos = signExt9 a1
          onLine = typ /= 2 && ypos < h * dbl && xpos > negate (w * dbl)
          xoff = max 0 (negate xpos)
          xend = min w (256 - xpos)
          cols = (xend - 1) `div` 8 - xoff `div` 8 + 1
      in if not onLine || mode == 2 then go (k + 1) acc
         else if odd typ then Left faultAffine
         else if mode == 3 then Left faultBitmap
         else if testBit a0 12 then Left faultObjMosaic
         else if mode == 1 && bld2 then Left faultSemiTrans
         else go (k + 1) (SprOn a0 a1 a2 w h xpos y0 cols : acc)

-- | Requests a line must make.
requestsOf :: Scene -> Int -> Int
requestsOf sc y = 2 * slotsOf sc + either (const 0) (sum . map soCols) (spritesOn sc y)

------------------------------------------------------------------------------
-- Closed-loop driver

data Prov = PRandom | PFixed !Int | PSerial !Int
  deriving (Eq, Show)

data Act = APal !Int !Word16 | AOam !Int !Word16 | AExt !Int !Word16 | ALine !Int !JobKind | AGap !Int
  deriving (Eq, Show)

data Run = Run { rnY :: !Int, rnKind :: !JobKind, rnStart :: !Int, rnPix :: ![PixelOut], rnCount :: !Int, rnReqs :: !Int }

-- | Jobs of a kind that emits pixels end a line.
emits :: JobKind -> Bool
emits k = case k of JBoth -> True; JBg -> True; _ -> False

-- | A finished line, judged against the reference as it completes (when
-- the driver judges); its pixels are not kept.
data LineRes = LineRes { lrY :: !Int, lrCycles :: !Int, lrReqs :: !Int, lrBad :: !Int, lrMsgs :: ![String] }

data D = D
  { dCyc    :: !Int
  , dRng    :: !Word64
  , dProv   :: !Prov
  , dLoad   :: !Bool            -- load palettes and OAM at each scene start
  , dAllowF :: !Bool            -- a fault ends the run (fault cases) instead of failing it
  , dJudge  :: !Bool            -- compare finished lines with the reference
  , dSplit  :: !Int             -- 0: one JBoth job per line; 1: random job-kind patterns; 2: always JObj then JBg
  , dLineReqs :: !Int           -- requests of the line's pixel-less jobs so far
  , dLineStart :: !(Maybe Int)  -- cycle the line's first job started
  , dScenes :: ![(Int, Scene)]  -- head: current scene
  , dActs   :: ![Act]
  , dCur    :: !(Maybe Act)     -- driven this cycle
  , dRun    :: !(Maybe Run)
  , dRdy    :: !Bool            -- driven this cycle
  , dResp   :: !(Maybe Word64)  -- driven this cycle
  , dJunk   :: !Regs
  , dQ      :: !(Seq (Int, Bool, Int))
  , dLast   :: !Int
  , dRes    :: ![LineRes]       -- reverse order
  , dCov    :: !(M.Map String Int)
  , dNObj   :: !Int             -- judged pixels by layer
  , dNBack  :: !Int
  , dNPix   :: !Int
  , dCols   :: !IS.IntSet       -- distinct pixel colours
  , dErr    :: ![String]
  , dDone   :: !Bool
  , dStalls :: !Int
  , dLong   :: !Int
  , dFault  :: !(BitVector 16)  -- first fault seen
  , dFaultPix :: !Int           -- pixels of the faulting line seen
  }

-- | Palette/OAM loads, then each line as one job ('JBoth') or, when
-- splitting, as a random pattern: JBoth; JObj then JBg; or JClear, JObj,
-- JBg (a clear of the half the JObj then fills), with random gaps.
actsOf :: Bool -> Int -> Word64 -> Scene -> [Act]
actsOf loadPal split s sc =
  (if loadPal
     then [APal k (pal16 (scPal sc) (2 * fromIntegral k)) | k <- [0 .. 1023]]
          ++ [AOam (eng * 512 + k) (oamHalf sc k) | k <- [0 .. 511], k .&. 3 /= 3]
          ++ (if objEnable (scDisp sc) && testBit (scDisp sc) 31
                then [AExt (eng * 4096 + k) (pal16 (scExt sc) (2 * fromIntegral k)) | k <- [0 .. 4095]]
                else [])
     else [])
  ++ concat [ AGap (fromIntegral (g `mod` 5)) : pattern y g | (y, g) <- zip (scLines sc) (rnds s) ]
  where
    eng = scEng sc
    gap g k = AGap (fromIntegral ((g `shiftR` (8 + 3 * k)) `mod` 4))
    pattern y g
      | split == 0 = [ALine y JBoth]
      | split == 2 = [ALine y JObj, gap g 0, ALine y JBg]
      | otherwise = case (g `shiftR` 20) `mod` 4 of
          1 -> [ALine y JObj, gap g 0, ALine y JBg]
          2 -> [ALine y JClear, gap g 1, ALine y JObj, gap g 2, ALine y JBg]
          _ -> [ALine y JBoth]

newDriver :: Word64 -> Prov -> Bool -> [Scene] -> D
newDriver seed prov loadPal scs = D
  { dCyc = 0, dRng = seed * 0x2545F4914F6CDD1D + 7, dProv = prov, dLoad = loadPal, dAllowF = False, dJudge = True
  , dSplit = 1, dLineReqs = 0, dLineStart = Nothing
  , dScenes = zip [0 ..] scs
  , dActs = case scs of (sc : _) -> actsOf loadPal 1 seed sc; [] -> []
  , dCur = Nothing, dRun = Nothing, dRdy = False, dResp = Nothing, dJunk = junkRegs 1 2
  , dQ = Seq.empty, dLast = 0, dRes = [], dCov = M.empty, dNObj = 0, dNBack = 0, dNPix = 0, dCols = IS.empty
  , dErr = [], dDone = False, dStalls = 0, dLong = 0
  , dFault = 0, dFaultPix = 0 }

-- | The same driver with every line one 'JBoth' job (timing mode).
wholeLines :: D -> D
wholeLines d = withSplit 0 d

-- | The same driver with the given split mode.
withSplit :: Int -> D -> D
withSplit m d = d { dSplit = m, dActs = case dScenes d of ((_, sc) : _) -> actsOf (dLoad d) m 3 sc; [] -> [] }

curScene :: D -> Maybe Scene
curScene d = case dScenes d of ((_, sc) : _) -> Just sc; [] -> Nothing

inputsOf :: D -> TileIn
inputsOf d = TileIn
  { tiStart = case (dCur d, curScene d) of
      (Just (ALine y k), Just sc) -> Just (LineReq (fromIntegral (scEng sc)) (fromIntegral y) k)
      _ -> Nothing
  , tiRegs = case (dCur d, curScene d) of
      (Just (ALine _ _), Just sc) -> regsOf sc
      _ -> dJunk d
  , tiReqReady = dRdy d
  , tiResp = fromIntegral <$> dResp d
  , tiPalWr = case dCur d of
      Just (APal k v) -> Just (fromIntegral k, fromIntegral v)
      _ -> Nothing
  , tiOamWr = case dCur d of
      Just (AOam k v) -> Just (fromIntegral k, fromIntegral v)
      _ -> Nothing
  , tiExtWr = case dCur d of
      Just (AExt k v) -> Just (fromIntegral k, fromIntegral v)
      _ -> Nothing }

-- | The 8-byte word at word address @a@ of BG or OBJ VRAM; a request past
-- the engine's space is an error ('cycleStep') and reads zero.
wordAt :: Scene -> Bool -> Int -> Word64
wordAt sc obj a
  | inSpace sc obj a = foldr (\k acc -> (acc `shiftL` 8) .|. fromIntegral (mem ! fromIntegral (8 * a + k))) 0 [0 .. 7]
  | otherwise = 0
  where mem = if obj then scObj sc else scVram sc

inSpace :: Scene -> Bool -> Int -> Bool
inSpace sc obj a = 8 * a + 7 < (if obj then (if scEng sc == 0 then 0x40000 else 0x20000)
                                 else (if scEng sc == 0 then 0x80000 else 0x20000))

cycleStep :: D -> TileOut -> D
cycleStep d o = d3
  where
    n = dCyc d
    reqAcc = case toReq o of Just (Req obj a) | dRdy d -> Just (obj, fromIntegral a :: Int); _ -> Nothing
    q0 = if isJust (dResp d) then Seq.drop 1 (dQ d) else dQ d
    (r1, latR) = rnd (dRng d)
    lat = case dProv d of
      PRandom -> let k = latR `mod` 100
                 in 1 + fromIntegral (if k < 70 then latR `shiftR` 8 `mod` 6
                                      else if k < 95 then latR `shiftR` 8 `mod` 60
                                      else latR `shiftR` 8 `mod` 400)
      PFixed l -> l
      PSerial l -> l
    (q1, last1) = case reqAcc of
      Just (obj, a) -> let due = max (dLast d + 1) (n + lat) in (q0 |> (due, obj, a), due)
      Nothing -> (q0, dLast d)
    startAcc = case dCur d of Just (ALine _ _) -> toReady o; _ -> False
    run1 = case dRun d of
      _ | startAcc, Just (ALine y k) <- dCur d -> Just (Run y k n [] 0 0)
      Just r -> Just r { rnPix = maybe (rnPix r) (: rnPix r) (toPixel o)
                       , rnCount = rnCount r + (if isJust (toPixel o) then 1 else 0)
                       , rnReqs = rnReqs r + (if isJust reqAcc then 1 else 0) }
      Nothing -> Nothing
    faulted = toFault o /= 0
    -- unexpected events
    errs = [ "cycle " ++ show n ++ ": fault " ++ showHex (toFault o) "" | faulted, not (dAllowF d) ]
        ++ [ "cycle " ++ show n ++ ": pixel outside a line" | isJust (toPixel o), isNothing (dRun d) ]
        ++ [ "cycle " ++ show n ++ ": request outside a line" | isJust reqAcc, isNothing (dRun d), not startAcc ]
        ++ [ "cycle " ++ show n ++ ": request past the engine's " ++ (if obj then "OBJ" else "BG") ++ " VRAM, word " ++ show a
           | Just (obj, a) <- [reqAcc], Just sc <- [curScene d], not (inSpace sc obj a) ]
        ++ [ "cycle " ++ show n ++ ": line " ++ show (rnY r) ++ " running for " ++ show (n - rnStart r) ++ " cycles"
           | Just r <- [dRun d], n - rnStart r > 200000 ]
    finishedRun = case run1 of
      Just r | toReady o && not startAcc && (if emits (rnKind r) then rnCount r == 256 else n > rnStart r) -> Just r
      _ -> Nothing
    run2 = if isJust finishedRun then Nothing else run1
    lineStart = case (startAcc, dLineStart d) of
      (True, Nothing) -> Just n
      (_, s) -> s
    -- a pixel-less job adds its requests to the line; a pixel job ends it
    lineDone = case finishedRun of Just r -> emits (rnKind r); Nothing -> False
    quietErrs = [ "cycle " ++ show n ++ ": " ++ show (rnKind r) ++ " job emitted " ++ show (rnCount r) ++ " pixels"
                | Just r <- [finishedRun], not (emits (rnKind r)), rnCount r /= 0 ]
    judged = case (finishedRun, curScene d) of
      (Just r, Just sc) | emits (rnKind r) ->
        Just (judgeLine (dJudge d) sc r { rnReqs = rnReqs r + dLineReqs d } (n - fromMaybe (rnStart r) lineStart))
      _ -> Nothing
    lineReqs' = case finishedRun of
      Just r | emits (rnKind r) -> 0
             | otherwise -> dLineReqs d + rnReqs r
      Nothing -> dLineReqs d
    res2 = case judged of
      Just (lr, _) -> lr : dRes d
      Nothing -> dRes d
    curDone = case dCur d of
      Just (ALine _ _) -> startAcc
      _ -> True
    -- next action
    (cur2, acts2, scenes2) =
      if not curDone then (dCur d, dActs d, dScenes d)
      else if isJust run2 then (Nothing, dActs d, dScenes d)
      else case dActs d of
        (AGap k : rest) | k > 0 -> (Nothing, AGap (k - 1) : rest, dScenes d)
                        | otherwise -> (Nothing, rest, dScenes d)
        (a : rest) -> (Just a, rest, dScenes d)
        [] -> case dScenes d of
          (_ : more@((_, sc) : _)) | Seq.null q1 -> (Nothing, actsOf (dLoad d) (dSplit d) (r1 + fromIntegral n) sc, more)
          (_ : more) | Seq.null q1 -> (Nothing, [], more)
          sc -> (Nothing, [], sc)
    (r2, rdyR) = rnd r1
    stalled = not (dRdy d) && isJust (toReq o)
    rdy = case dProv d of
      PRandom -> if dRdy d then rdyR `mod` 100 >= 25 else rdyR `mod` 100 >= 55
      PFixed _ -> True
      PSerial _ -> Seq.null q1 && isNothing reqAcc
    resp = case viewl q1 of
      (due, obj, a) :< _ | due <= n + 1, Just sc <- curScene d { dScenes = scenes2 } -> Just (wordAt sc obj a)
      _ -> Nothing
    (r3, j1) = rnd r2
    (r4, j2) = rnd r3
    finished = null scenes2 && isNothing run2 && isNothing cur2 && Seq.null q1
    faultEnd = faulted && dAllowF d
    d3 = d { dCyc = n + 1, dRng = r4, dScenes = scenes2, dActs = acts2, dCur = cur2, dRun = run2
           , dRdy = rdy, dResp = resp, dJunk = junkRegs j1 j2, dQ = q1, dLast = last1
           , dLineReqs = lineReqs', dLineStart = if lineDone then Nothing else lineStart
           , dRes = res2, dErr = if null errs && null quietErrs then dErr d else errs ++ quietErrs ++ dErr d
           , dCov = (case dCur d of
                       Just (ALine _ k) | startAcc -> M.insertWith (+) ("jobs of kind " ++ show k) 1
                       _ -> id)
                    (maybe (dCov d) (\(_, j) -> foldl' (\m (k, v) -> M.insertWith (+) k v m) (dCov d) (jKeys j)) judged)
           , dNObj = dNObj d + maybe 0 (jObj . snd) judged
           , dNBack = dNBack d + maybe 0 (jBack . snd) judged
           , dNPix = dNPix d + maybe 0 (jPix . snd) judged
           , dCols = maybe (dCols d) (IS.union (dCols d) . jCols . snd) judged
           , dDone = finished || not (null errs) || not (null quietErrs) || faultEnd
           , dStalls = dStalls d + (if stalled then 1 else 0)
           , dLong = dLong d + (if isJust reqAcc && lat > 60 then 1 else 0)
           , dFault = if dFault d == 0 then toFault o else dFault d
           , dFaultPix = if faultEnd then maybe 0 rnCount (dRun d) else dFaultPix d }

------------------------------------------------------------------------------
-- Pure model with RAM models, and the Clash circuit

data PM = PM
  { pmSt   :: !St
  , pmMap  :: !(IM.IntMap (BitVector 16))
  , pmRow  :: !(IM.IntMap (BitVector 64))
  , pmPal  :: !(IM.IntMap (BitVector 16))
  , pmOam  :: ![IM.IntMap (BitVector 16)]
  , pmLb   :: !(IM.IntMap (BitVector 16))
  , pmDesc :: !(IM.IntMap Desc)
  , pmObj  :: !(IM.IntMap (BitVector 64))
  , pmExt  :: ![IM.IntMap (BitVector 16)]
  , pmQ    :: !RamQ
  , pmCyc  :: !Int }

descZero :: Desc
descZero = C.unpack 0

pmInit :: PM
pmInit = PM stInit IM.empty IM.empty IM.empty [IM.empty, IM.empty, IM.empty] IM.empty IM.empty IM.empty
            [IM.empty, IM.empty] (RamQ 0 0 0 (C.repeat 0) 0 descZero 0 (C.repeat 0)) 0

-- | Reset is asserted in cycle 0 only: the registers hold their reset value
-- through that cycle's edge, as Clash's simulation and the Verilog do.
pureStep :: PM -> TileIn -> (PM, TileOut)
pureStep pm inp = (pm', out)
  where
    (st', out, ops) = tileStep (pmSt pm) inp (pmQ pm)
    rd z m a = IM.findWithDefault z (fromIntegral a) m
    wr m w = case w of Just (a, v) -> IM.insert (fromIntegral a) v m; Nothing -> m
    -- every element is forced each cycle: an unread lane would otherwise
    -- keep the whole previous cycle alive (a thunk chain across the run)
    strictL xs = foldr seq () xs `seq` xs
    q' = RamQ (rd 0 (pmMap pm) (opMapRd ops)) (rd 0 (pmRow pm) (opRowRd ops)) (rd 0 (pmPal pm) (opPalRd ops))
              (V.unsafeFromList (strictL [rd 0 m (opOamRd ops) | m <- pmOam pm]))
              (rd 0 (pmLb pm) (opLbRd ops)) (rd descZero (pmDesc pm) (opDescRd ops)) (rd 0 (pmObj pm) (opObjRd ops))
              (V.unsafeFromList (strictL [rd 0 m (opExtRd ops) | m <- pmExt pm]))
    pm' = PM (if pmCyc pm == 0 then stInit else st')
             (wr (pmMap pm) (opMapWr ops)) (wr (pmRow pm) (opRowWr ops)) (wr (pmPal pm) (opPalWr ops))
             (strictL (zipWith wr (pmOam pm) (C.toList (opOamWr ops))))
             (wr (pmLb pm) (opLbWr ops)) (wr (pmDesc pm) (opDescWr ops)) (wr (pmObj pm) (opObjWr ops))
             (strictL (zipWith wr (pmExt pm) (C.toList (opExtWr ops))))
             (forceQ q') (pmCyc pm + 1)
    forceQ q = foldr seq () (C.toList (qOam q)) `seq` foldr seq () (C.toList (qExt q)) `seq` q

-- | Each cycle as (driver state with this cycle's inputs, outputs, driver
-- state after it); the run ends when the driver is done.
runPure :: D -> [(D, TileOut, D)]
runPure = go pmInit
  where
    go pm d = let (pm', o) = pureStep pm (inputsOf d)
                  d' = cycleStep d o
              in (d, o, d') : (if dDone d' then [] else d' `seq` go pm' d')

runClash :: D -> [(D, TileOut, D)]
runClash dInit = takeDone (zip3 ds (sample outs) (drop 1 ds))
  where
    -- the pure run judges the lines; the Clash run's driver only drives
    drv = driver dInit { dJudge = False } outs
    ds = sample drv
    outs = tileHw systemClockGen systemResetGen enableGen (inputsOf <$> drv)
    driver d ~(o :- os) = d :- (let d' = cycleStep d o in d' `seq` driver d' os)
    sample (x :- xs) = x : sample xs
    takeDone (x@(_, _, d') : rest) = x : (if dDone d' then [] else takeDone rest)
    takeDone [] = []

------------------------------------------------------------------------------
-- Checking

-- | What a judged line adds to the run's totals.
data Judge = Judge { jKeys :: [(String, Int)], jObj :: !Int, jBack :: !Int, jPix :: !Int, jCols :: !IS.IntSet }

-- | Judge one finished line: every pixel against the reference, the request
-- count, and with OBJ off the harness's composition against
-- renderReferenceLine; plus the line's coverage. The result is forced, so
-- neither the pixels nor the reference are retained. Without judging only
-- the cycle and request counts are kept.
judgeLine :: Bool -> Scene -> Run -> Int -> (LineRes, Judge)
judgeLine False _ r cyc = (LineRes (rnY r) cyc (rnReqs r) 0 [], Judge [] 0 0 0 IS.empty)
judgeLine True sc r cyc = msgLen `seq` keyLen `seq` (lr, j)
  where
    y = rnY r
    px = reverse (rnPix r)
    (bgs, orow, ref) = refParts sc y
    diffs = [ printf "line %d x %d: engine rgb %06x layer %d (x=%d), reference rgb %06x layer %d"
                y x (expandColor15 (fromIntegral (poColor p))) (fromIntegral (poLayer p) :: Int) (fromIntegral (poX p) :: Int)
                (pxRgb rp .&. 0xFFFFFF) (layerCode (pxLayer rp))
            | (x, p, rp) <- zip3 [0 :: Int ..] px ref
            , fromIntegral (poX p) /= x || expandColor15 (fromIntegral (poColor p)) /= pxRgb rp .&. 0xFFFFFF
              || fromIntegral (poLayer p) /= layerCode (pxLayer rp) ]
    nDiff = length diffs
    reqBad = rnReqs r /= requestsOf sc y
    glueBad = not (objEnable (scDisp sc))
              && (let rr = renderReferenceLine (esOf sc) y in map pxRgb ref /= map pxRgb rr || map pxLayer ref /= map pxLayer rr)
    msgs = take 1 diffs
        ++ [ show nDiff ++ "/256 pixels differ" | nDiff > 1 ]
        ++ [ "line " ++ show y ++ ": " ++ show (rnReqs r) ++ " memory requests, expected " ++ show (requestsOf sc y) | reqBad ]
        ++ [ "line " ++ show y ++ ": harness composition differs from renderReferenceLine with OBJ off" | glueBad ]
    bad = nDiff + fromEnum reqBad + fromEnum glueBad
    lr = LineRes y cyc (rnReqs r) bad msgs
    keys = coverageKeys sc y bgs orow ref
    j = Judge keys (length [ () | p <- px, poLayer p == layerObj ]) (length [ () | p <- px, poLayer p == layerBackdrop ])
              (length px) (IS.fromList [ fromIntegral (poColor p) | p <- px ])
    msgLen = bad `seq` sum (map length msgs)
    keyLen = jObj j `seq` jBack j `seq` IS.size (jCols j) `seq` sum [ length k + v | (k, v) <- keys ]

-- | Field coverage of one checked line, from the scene state and the
-- reference alone (not from the engine): (key, count).
coverageKeys :: Scene -> Int -> [[Maybe LayerPixel]] -> [Maybe LayerPixel] -> [Pixel] -> [(String, Int)]
coverageKeys sc y bgs orow ref = map (\k -> (k, 1)) (bgKeys ++ objKeys) ++ objCounts
  where
    disp = scDisp sc
    bgKeys = case [k | k <- [0 .. 3], testBit disp (8 + k)] of
      [] -> ["lines", "lines without a BG (backdrop only)"]
      (n : _) ->
        let cnt = scBgCnt sc !! n
            hofs = fromIntegral (scHofs sc !! n .&. 0x1FF) :: Int
            vofs = fromIntegral (scVofs sc !! n .&. 0x1FF) :: Int
            wide = testBit cnt 14; tall = testBit cnt 15
            yoff = vofs + y
            sizeK = "BG screen size " ++ show (fromEnum wide + 2 * fromEnum tall)
            engA = scEng sc == 0
            mapBase = (if engA then fromIntegral ((disp `shiftR` 27) .&. 7) * 0x10000 else 0)
                      + fromIntegral ((cnt `shiftR` 8) .&. 31) * 0x800 :: Int
            rowOff | tall = ((yoff .&. 0x1F8) `shiftL` 3) + (if wide then (yoff .&. 0x100) `shiftL` 3 else 0)
                   | otherwise = (yoff .&. 0xF8) `shiftL` 3
            mask = if engA then 0x7FFFF else 0x1FFFF
            entries = [ pal16 (scVram sc) (fromIntegral a)
                      | t <- [0 .. slotsOf sc - 1]
                      , let xt = ((hofs .&. 0x1F8) + 8 * t) .&. 0x1FF
                            a = (mapBase + rowOff + ((xt .&. 0xF8) `shiftR` 2) + (if wide then (xt .&. 0x100) `shiftL` 3 else 0)) .&. mask ]
        in [ "lines", "engine " ++ (if engA then "A" else "B"), "BG" ++ show n
           , if testBit cnt 7 then "BG 8bpp" else "BG 4bpp", sizeK, "BG priority " ++ show (cnt .&. 3) ]
           ++ [ "BG fine x scroll nonzero (33 slots)" | hofs .&. 7 /= 0 ]
           ++ [ "BG horizontal wrap inside the line" | (hofs `mod` (if wide then 512 else 256)) + 255 >= (if wide then 512 else 256) ]
           ++ [ "BG vertical wrap (VOFS + line past the map bottom)" | yoff >= (if tall then 512 else 256) ]
           ++ [ "BG DISPCNT char/screen base offset nonzero (engine A)" | engA, disp .&. 0x3F000000 /= 0 ]
           ++ [ "BGCNT char base nonzero" | cnt .&. 0x3C /= 0 ]
           ++ [ "BGCNT screen base nonzero" | cnt .&. 0x1F00 /= 0 ]
           ++ [ "BG DISPCNT bit 30 set with 4bpp" | testBit disp 30, not (testBit cnt 7) ]
           ++ [ "BG slots with h-flip" | any (`testBit` 10) entries ]
           ++ [ "BG slots with v-flip" | any (`testBit` 11) entries ]
           ++ [ "BG 4bpp slots with palette number nonzero" | not (testBit cnt 7), any (\e -> e `shiftR` 12 /= 0) entries ]
           ++ [ "BG 8bpp slots with palette number nonzero (ignored)" | testBit cnt 7, any (\e -> e `shiftR` 12 /= 0) entries ]
    objOn = objEnable disp
    sprs = if objOn then either (const []) id (spritesOn sc y) else []
    modeOf s = (soA0 s `shiftR` 10) .&. 3
    prio s = (soA2 s `shiftR` 10) .&. 3
    ext s = testBit (soA0 s) 13 && testBit disp 31
    objKeys
      | not objOn = []
      | otherwise =
          [ "OBJ lines", "OBJ tile boundary " ++ show ((disp `shiftR` 20) .&. 3) ]
          ++ [ "OBJ lines with a sprite drawn" | not (null sprs) ]
          ++ [ "OBJ lines with 8+ sprites drawn" | length sprs >= 8 ]
          ++ [ "OBJ sprite pairs overlapping in x (" ++ (if prio a == prio b then "equal" else "different") ++ " priority)"
             | (i, a) <- zip [0 :: Int ..] sprs, b <- drop (i + 1) sprs
             , max (max 0 (soX a)) (max 0 (soX b)) < min (min 256 (soX a + soW a)) (min 256 (soX b + soW b)) ]
          ++ [ "OBJ size " ++ show (soW s) ++ "x" ++ show (soH s) | s <- sprs ]
          ++ [ "OBJ sprites drawn" | _ <- sprs ]
          ++ [ "OBJ h-flip" | s <- sprs, testBit (soA1 s) 12 ]
          ++ [ "OBJ v-flip" | s <- sprs, testBit (soA1 s) 13 ]
          ++ [ "OBJ 4bpp" | s <- sprs, not (testBit (soA0 s) 13) ]
          ++ [ "OBJ 8bpp standard palette" | s <- sprs, testBit (soA0 s) 13, not (ext s) ]
          ++ [ "OBJ 8bpp extended palette" | s <- sprs, ext s ]
          ++ [ "OBJ semi-transparent (no second target)" | s <- sprs, modeOf s == 1 ]
          ++ [ "OBJ priority " ++ show (prio s) | s <- sprs ]
          ++ [ "OBJ clipped at the left edge" | s <- sprs, soX s < 0 ]
          ++ [ "OBJ clipped at the right edge" | s <- sprs, soX s + soW s > 256 ]
          ++ [ "OBJ wrapping from y > 255" | s <- sprs, y < soY0 s ]
    bgx = transpose bgs
    objCounts
      | not objOn = []
      | otherwise =
          [ ("OBJ pixels shown over BG/backdrop", length [ () | (Just _, rp) <- zip orow ref, pxLayer rp == LObj ])
          , ("OBJ pixels hidden by a BG of higher priority"
            , length [ () | (Just _, rp) <- zip orow ref, case pxLayer rp of Bg _ -> True; _ -> False ])
          , ("OBJ pixels winning a priority tie with the BG"
            , length [ () | (Just op, rp, bs) <- zip3 orow ref bgx, pxLayer rp == LObj
                          , any (\bp -> fmap lpPrio bp == Just (lpPrio op)) bs ]) ]

data Tally = Tally { tCycles :: !Int, tMism :: !Int, tFirst :: ![String], tLast :: !(Maybe D) }

-- | Fold the pure run (and the Clash run when given) cycle by cycle.
compareRuns :: [(D, TileOut, D)] -> Maybe [(D, TileOut, D)] -> Tally
compareRuns pureL clashL = case clashL of
  Nothing -> foldl' (\t (_, _, d') -> t { tCycles = tCycles t + 1, tLast = Just d' }) (Tally 0 0 [] Nothing) pureL
  Just cl -> foldl' step (Tally 0 0 [] Nothing) (zipLong pureL cl)
  where
    step t (Just (d, o, d'), Just (_, oc, _)) =
      let bad = o /= oc
      in t { tCycles = tCycles t + 1, tLast = Just d'
           , tMism = tMism t + (if bad then 1 else 0)
           , tFirst = if bad && length (tFirst t) < 5 then tFirst t ++ ["cycle " ++ show (dCyc d) ++ ": pure " ++ show o ++ " clash " ++ show oc] else tFirst t }
    step t (Just (_, _, d'), Nothing) = t { tMism = tMism t + 1, tLast = Just d', tFirst = take 5 (tFirst t ++ ["clash run ended early"]) }
    step t (Nothing, _) = t { tMism = tMism t + 1, tFirst = take 5 (tFirst t ++ ["pure run ended early"]) }
    zipLong (a : as) (b : bs) = (Just a, Just b) : zipLong as bs
    zipLong (a : as) [] = (Just a, Nothing) : zipLong as []
    zipLong [] (b : bs) = (Nothing, Just b) : zipLong [] bs
    zipLong [] [] = []

die' :: String -> IO a
die' msg = hPutStrLn stderr msg >> exitFailure

-- | Fixtures (with the lines the engine must refuse taken out and counted),
-- a summary of what was loaded, and whether the kirby135 capture is in.
loadFixtures :: FilePath -> IO ([Scene], String, Bool)
loadFixtures dir = do
  (k2, summary) <- scenes2dk dir
  (kb, kbStatus) <- loadKirby dir
  let scs = k2 ++ maybe [] pure kb
      supported sc = sc { scLines = [y | y <- scLines sc, either (const False) (const True) (spritesOn sc y)] }
      notes = [ scName sc ++ ": " ++ show (length (refused sc)) ++ " of " ++ show (length (scLines sc))
                ++ " lines have a sprite the engine refuses ("
                ++ unwords [ show (length [() | (_, f) <- refused sc, f == b]) ++ "x " ++ fromMaybe "?" (lookup b faultNames) ++ ";"
                           | b <- [faultSemiTrans, faultAffine, faultBitmap, faultObjMosaic], any ((== b) . snd) (refused sc) ]
                ++ ") and are not in the check"
              | sc <- scs, not (null (refused sc)) ]
  pure (map supported scs, unlines (summary : kbStatus : notes), isJust kb)

refused :: Scene -> [(Int, Int)]
refused sc = [ (y, f) | y <- scLines sc, Left f <- [spritesOn sc y] ]

-- | The driver seed of scene @i@ of a group: check and dump run the same
-- scenes with the same gaps, junk registers, stalls and latencies.
sceneSeed :: Word64 -> Int -> Word64
sceneSeed seed i = seed * 0x100000001B3 + fromIntegral i * 0x9E3779B1 + 1

-- | One group's (or one scene's) totals. Strict: a scene's run is dropped as
-- soon as its totals are taken.
data Acc = Acc
  { aScenes, aLines, aPix, aObj, aBack, aReqs, aStalls, aLong, aCyc, aMism, aMin, aMax, aBad :: !Int
  , aCols :: !IS.IntSet
  , aCov :: !(M.Map String Int) }

accZero :: Acc
accZero = Acc 0 0 0 0 0 0 0 0 0 0 maxBound 0 0 IS.empty M.empty

accPlus :: Acc -> Acc -> Acc
accPlus a b = Acc (aScenes a + aScenes b) (aLines a + aLines b) (aPix a + aPix b) (aObj a + aObj b) (aBack a + aBack b)
  (aReqs a + aReqs b) (aStalls a + aStalls b) (aLong a + aLong b) (aCyc a + aCyc b) (aMism a + aMism b)
  (min (aMin a) (aMin b)) (max (aMax a) (aMax b)) (aBad a + aBad b) (IS.union (aCols a) (aCols b))
  (M.unionWith (+) (aCov a) (aCov b))

-- | Run one scene through the pure step and (unless pure only) the Clash
-- circuit, judging every line as it completes; print its first problems.
checkScene :: Bool -> Word64 -> Scene -> IO Acc
checkScene pureOnly s sc = do
  let d0 = newDriver s PRandom True [sc]
      t = compareRuns (runPure d0) (if pureOnly then Nothing else Just (runClash d0))
      dEnd = fromMaybe d0 (tLast t)
      ls = dRes dEnd
      missing = [ show (length (scLines sc) - length ls) ++ " lines not completed" | length ls /= length (scLines sc) ]
      refusedR = [ show (length (refused sc)) ++ " lines with a refused sprite (generator bug)" | not (null (refused sc)) ]
      msgs = refusedR ++ dErr dEnd ++ missing ++ tFirst t ++ concatMap lrMsgs (reverse ls)
      cyc = map lrCycles ls
      a = Acc { aScenes = 1, aLines = length ls, aPix = dNPix dEnd, aObj = dNObj dEnd, aBack = dNBack dEnd
              , aReqs = sum (map lrReqs ls), aStalls = dStalls dEnd, aLong = dLong dEnd, aCyc = tCycles t, aMism = tMism t
              , aMin = if null cyc then maxBound else minimum cyc, aMax = if null cyc then 0 else maximum cyc
              , aBad = tMism t + sum (map lrBad ls) + length (dErr dEnd) + length missing + length refusedR
              , aCols = dCols dEnd, aCov = dCov dEnd }
  a `seq` mapM_ (putStrLn . ((scName sc ++ ": ") ++)) (take 6 msgs)
  pure a

report :: Bool -> String -> Acc -> IO ()
report pureOnly label a =
  printf "%s: %d scenes, %d lines, %d pixels (%d BG, %d OBJ, %d backdrop; %d distinct colours), %d memory requests (%d stalled cycles, %d responses > 60 cycles late), %d cycles; line cycles %d-%d; %s; %d failures\n"
    label (aScenes a) (aLines a) (aPix a) (aPix a - aObj a - aBack a) (aObj a) (aBack a) (IS.size (aCols a)) (aReqs a)
    (aStalls a) (aLong a) (aCyc a) (if aLines a == 0 then 0 else aMin a) (aMax a)
    (if pureOnly then "pure model only" else "pure = Clash on " ++ show (aCyc a - aMism a) ++ "/" ++ show (aCyc a) ++ " cycles")
    (aBad a)

checkMode :: FilePath -> Word64 -> Int -> Bool -> IO ()
checkMode dir seed nrand pureOnly = do
  (fixtures, summary, kbIn) <- loadFixtures dir
  putStr summary
  let group scs = foldlM' (\acc (i, sc) -> do a <- checkScene pureOnly (sceneSeed seed i) sc
                                              let acc' = accPlus acc a
                                              acc' `seq` pure acc') accZero scs
  fx <- group (zip [0 ..] fixtures)
  report pureOnly (if kbIn then "arm9_2dk (A, B) + kirby135" else "arm9_2dk (A, B)") fx
  rs <- group [ (i, randomScene seed i) | i <- [0 .. nrand - 1] ]
  report pureOnly ("random (seed " ++ show seed ++ ")") rs
  putStrLn "coverage (checked lines; pixel counts for the OBJ pixel rows):"
  forM_ (M.toList (M.unionWith (+) (aCov fx) (aCov rs))) $ \(k, v) -> printf "  %-58s %d\n" k v
  let total = aBad fx + aBad rs
  printf "tilehw check: %d failures (kirby135 capture %s)\n" total
    (if kbIn then "ran" else "not present, skipped" :: String)
  when (total /= 0) exitFailure

foldlM' :: (b -> a -> IO b) -> b -> [a] -> IO b
foldlM' f z xs = go z xs where go !acc (y : ys) = f acc y >>= \acc' -> go acc' ys; go acc [] = pure acc

------------------------------------------------------------------------------
-- Fault cases

setOam :: Int -> Word16 -> Scene -> Scene
setOam k v sc = sc { scOam = scOam sc // [(fromIntegral (2 * k), fromIntegral v), (fromIntegral (2 * k + 1), fromIntegral (v `shiftR` 8))] }

faultMode :: FilePath -> IO ()
faultMode dir = do
  ([a2dk, b2dk], _) <- scenes2dk dir
  let good = a2dk
      withDisp f sc = sc { scDisp = f (scDisp sc) }
      at ls sc = sc { scLines = ls }
      -- sprite 0 of the 2dk scene: 16x16 at (16, 24), attribute 0 0x0018
      spr0 v = setOam 0 v good
      cases =
        [ ("BG mode 1", withDisp (.|. 1) good, 0)
        , ("BG2 and BG3", withDisp (.|. 0x400) good, 1)
        , ("OBJ with 2D mapping", withDisp (.&. complement 0x10) good, 2)
        , ("window 0", withDisp (.|. 0x2000) good, 3)
        , ("OBJ window", withDisp (.|. 0x8000) good, 3)
        , ("forced blank", withDisp (.|. 0x80) good, 4)
        , ("display mode 2", withDisp (\d -> (d .&. complement 0x30000) .|. 0x20000) good, 5)
        , ("display mode 0, engine B", withDisp (.&. complement 0x10000) b2dk, 5)
        , ("BG0 3D on engine A", (withDisp (\d -> (d .&. complement 0xF00) .|. 0x108) good) { scBgCnt = [0x485, 0, 0, 0] }, 6)
        , ("BLDCNT alpha", good { scBld = 0x0848 }, 7)
        , ("BLDCNT brightness down", good { scBld = 0x00C8 }, 7)
        , ("BG3 mosaic", good { scBgCnt = [0, 0, 0, 0x4C5] }, 8)
        , ("8bpp BG with BG ext palettes", withDisp (.|. 0x40000000) good, 9)
        , ("semi-transparent sprite, BLDCNT 2nd target", (spr0 0x0418) { scBld = 0x0100 }, faultSemiTrans)
        , ("affine sprite on the line", spr0 0x0118, faultAffine)
        , ("double-size affine sprite on the line", spr0 0x0318, faultAffine)
        , ("bitmap sprite on the line", spr0 0x0C18, faultBitmap)
        , ("mosaic sprite on the line", spr0 0x1018, faultObjMosaic) ]
      accepted =
        [ ("engine B, DISPCNT bit 3 with BG0", (withDisp (\d -> (d .&. complement 0xF00) .|. 0x108) b2dk) { scBgCnt = [0x485, 0, 0, 0] })
        , ("4bpp BG with DISPCNT bit 30", (withDisp (.|. 0x40000000) good) { scBgCnt = [0, 0, 0, 0x405] })
        , ("no BG enabled", withDisp (.&. complement 0xF00) good)
        , ("affine sprite not on the line", at [0, 77, 191] (spr0 0x0118))
        , ("disabled sprite with bitmap/mosaic bits", spr0 0x1E18)
        , ("OBJ window sprite on the line", spr0 0x0818)
        , ("semi-transparent sprite, 1st target only", (spr0 0x0418) { scBld = 0x003F }) ]
  bads <- forM [ (cs, m) | cs <- cases, m <- [0, 2] ] $ \((name, sc0, b), m) -> do
    let sc = sc0 { scLines = [30] }   -- sprite 0 covers lines 24-39
        want = 2 ^ b :: BitVector 16
        d0 = withSplit m ((newDriver 9 PRandom True [sc]) { dAllowF = True })
        t = compareRuns (runPure d0) (Just (runClash d0))
        dEnd = fromMaybe d0 (tLast t)
        ok = tMism t == 0 && dFault dEnd == want && dFaultPix dEnd == 0 && null (dRes dEnd) && null (dErr dEnd)
    printf "fault %-46s bit %2d, %s: %s\n" (name :: String) b (if m == 0 then "JBoth" else "JObj+JBg" :: String)
      (if ok then "refused, halted, no pixel" else "WRONG (fault " ++ showHex (dFault dEnd) "" ++ ", "
         ++ show (dFaultPix dEnd) ++ " pixels, " ++ show (length (dRes dEnd)) ++ " lines, pure/Clash mismatches "
         ++ show (tMism t) ++ " " ++ show (take 2 (dErr dEnd)) ++ ")")
    pure (if ok then 0 else 1 :: Int)
  -- a response with nothing outstanding (after the reset sweep)
  let regs = regsOf good
      idleIn = TileIn Nothing regs True Nothing Nothing Nothing Nothing
      inputs = replicate 1100 idleIn ++ [idleIn { tiResp = Just 0x1234 }]
               ++ replicate 300 (TileIn (Just (LineReq 0 20 JBoth)) regs True (Just 0) Nothing Nothing Nothing)
      pureL = reverse (snd (foldl' (\(pm, acc) i -> let (pm', o) = pureStep pm i in (pm', o : acc)) (pmInit, []) inputs))
      clashL = sampleN' (length inputs) (tileHw systemClockGen systemResetGen enableGen (fromListS (inputs ++ repeat (last inputs))))
      protoOk = all (\o -> toFault o == 2 ^ faultProtocol) (drop 1102 pureL)
                && all (\o -> isNothing (toPixel o) && isNothing (toReq o)) pureL && pureL == clashL
  printf "fault %-46s bit %2d: %s\n" ("response with nothing outstanding" :: String) faultProtocol
    (if protoOk then "refused, halted, no pixel" else "WRONG" :: String)
  pbads <- forM accepted $ \(name, sc0) -> do
    let sc = if scLines sc0 == [0 .. 191] then sc0 { scLines = [0, 30, 77, 191] } else sc0
        d0 = newDriver 5 PRandom True [sc]
        t = compareRuns (runPure d0) (Just (runClash d0))
        dEnd = fromMaybe d0 (tLast t)
        bad = sum (map lrBad (dRes dEnd))
        ok = tMism t == 0 && bad == 0 && null (dErr dEnd) && length (dRes dEnd) == length (scLines sc)
    printf "accepted %-43s: %s\n" (name :: String)
      (if ok then show (length (scLines sc)) ++ " lines exact, no fault"
       else "WRONG " ++ show (take 2 (dErr dEnd ++ concatMap lrMsgs (dRes dEnd) ++ tFirst t)))
    pure (if ok then 0 else 1 :: Int)
  let total = sum bads + sum pbads + (if protoOk then 0 else 1)
  printf "tilehw fault: %d cases, %d wrong\n" (2 * length cases + 1 + length accepted) total
  when (total /= 0) exitFailure

fromListS :: [a] -> Signal C.System a
fromListS (x : xs) = x :- fromListS xs
fromListS [] = error "fromListS"

sampleN' :: Int -> Signal dom a -> [a]
sampleN' k (x :- xs) = if k <= 0 then [] else x : sampleN' (k - 1) xs

------------------------------------------------------------------------------
-- Cosim trace

hexN :: Int -> Integer -> String
hexN w v = let s = showHex v "" in replicate (w - length s) '0' ++ s

traceLine :: (D, TileOut, D) -> String
traceLine (d, o, _) = unwords
  [ hexN 2 (fromIntegral flags), hexN 2 (fromIntegral line), hexN 1 (fromIntegral kind), hexN 8 (fromIntegral (rDispCnt r))
  , hexN 16 (packV 16 (map fromIntegral (C.toList (rBgCnt r))))
  , hexN 9 (packV 9 (map fromIntegral (C.toList (rHofs r))))
  , hexN 9 (packV 9 (map fromIntegral (C.toList (rVofs r))))
  , hexN 4 (fromIntegral (rBldCnt r))
  , hexN 16 (fromIntegral (fromMaybe 0 (tiResp i)))
  , hexN 3 (fromIntegral (maybe 0 fst (tiPalWr i))), hexN 4 (fromIntegral (maybe 0 snd (tiPalWr i)))
  , hexN 3 (fromIntegral (maybe 0 fst (tiOamWr i))), hexN 4 (fromIntegral (maybe 0 snd (tiOamWr i)))
  , hexN 4 (fromIntegral (maybe 0 fst (tiExtWr i))), hexN 4 (fromIntegral (maybe 0 snd (tiExtWr i)))
  , hexN 1 (fromIntegral oflags), hexN 4 (fromIntegral (maybe 0 rqAddr (toReq o)))
  , hexN 2 (fromIntegral (maybe 0 poX (toPixel o))), hexN 4 (fromIntegral (maybe 0 poColor (toPixel o)))
  , hexN 1 (fromIntegral (maybe 0 poLayer (toPixel o))), hexN 4 (fromIntegral (toFault o))
  , show (dCyc d) ]
  where
    i = inputsOf d
    r = tiRegs i
    b c k = if c then 2 ^ (k :: Int) else 0 :: Int
    (eng, line, kind) = maybe (0, 0, 0)
      (\(LineReq e l k) -> (fromIntegral e :: Int, fromIntegral l :: Int, case k of JBoth -> 0; JBg -> 1; JObj -> 2; JClear -> 3 :: Int))
      (tiStart i)
    flags = b (dCyc d == 0) 0 + b (isJust (tiStart i)) 1 + b (eng == 1) 2 + b (tiReqReady i) 3
          + b (isJust (tiResp i)) 4 + b (isJust (tiPalWr i)) 5 + b (isJust (tiOamWr i)) 6 + b (isJust (tiExtWr i)) 7
    oflags = b (toReady o) 0 + b (isJust (toReq o)) 1 + b (isJust (toPixel o)) 2 + b (maybe False rqObj (toReq o)) 3
    packV w xs = sum [x `shiftL` (w * k) | (x, k) <- zip xs [0 ..]] :: Integer

-- | The pure model's run of check's scenes (same per-scene seeds, so the
-- same scenes, gaps, junk registers, stalls and latencies), one trace line
-- per cycle on stdout, scene after scene (each starts with a reset cycle):
-- GROUP is "fixtures" or "random". Nothing is kept; the Verilator harness
-- reads the stream and compares as it goes.
dumpMode :: FilePath -> Word64 -> Int -> String -> IO ()
dumpMode dir seed nrand grp = do
  hSetBuffering stdout (BlockBuffering Nothing)
  scs <- case grp of
    "fixtures" -> do (scs, _, kbIn) <- loadFixtures dir
                     hPutStrLn stderr (if kbIn then "dump fixtures: kirby135 capture included"
                                       else "dump fixtures: kirby135 capture not present, skipped")
                     pure scs
    "random" -> pure [ randomScene seed i | i <- [0 .. nrand - 1] ]
    _ -> die' "dump: group must be fixtures or random"
  let !nScenes = if grp == "fixtures" then length scs else nrand
  (cycles, pix, reqs) <- foldlM' (\acc (i, sc) ->
      foldlM' (\(!c, !p, !q) x@(d, o, _) -> do
          putStrLn (traceLine x)
          pure (c + 1, p + (if isJust (toPixel o) then 1 else 0) :: Int, q + (if isJust (toReq o) && tiReqReady (inputsOf d) then 1 else 0)))
        acc (runPure ((newDriver (sceneSeed seed i) PRandom True [sc]) { dJudge = False })))
    (0 :: Int, 0, 0 :: Int) (zip [0 ..] scs)
  hFlush stdout
  hPrintf stderr "dump %s: %d scenes, %d cycles, %d pixels, %d requests\n" grp nScenes cycles pix reqs

------------------------------------------------------------------------------
-- Timing

-- | @k@ 64x64 8bpp sprites covering lines 0-63, spread along x, on the 2dk
-- engine-A scene (which keeps its BG).
heavy :: Scene -> Int -> Scene
heavy sc k = sc { scOam = listArray (0, 0x3FF) (concat [[fromIntegral h, fromIntegral (h `shiftR` 8)] | h <- halves])
                , scDisp = scDisp sc .&. complement 0x80000000, scLines = [0, 31, 63] }
  where
    halves = concat [ if j < k then [0x2000, fromIntegral ((j * 37) `mod` 192) .|. 0xC000, fromIntegral (8 * j), 0]
                               else [0x0200, 0, 0, 0] | j <- [0 .. 127] ] :: [Word16]

timeMode :: FilePath -> IO ()
timeMode dir = do
  ([a2dk, _], _) <- scenes2dk dir
  (kbM, kbStatus) <- loadKirby dir
  putStrLn kbStatus
  let worst sc = sc { scHofs = [3, 3, 3, 3], scLines = [0, 1, 100, 191] }   -- 33 slots
      zero sc = sc { scHofs = [0, 0, 0, 0], scLines = [0, 100] }            -- 32 slots
      noObj sc = sc { scDisp = scDisp sc .&. complement 0x1000 }
      noBg = (noObj a2dk) { scDisp = scDisp a2dk .&. complement 0xF00 .&. complement 0x1000, scLines = [0, 1] }
      kbOk = fmap (\kb -> kb { scLines = [y | y <- [0 .. 191], either (const False) (const True) (spritesOn kb y)] }) kbM
      kbCol l = maybe "-" (\kb -> show (maxOf (PFixed l) [kb])) kbOk
      measure prov scs = let d0 = wholeLines ((newDriver 3 prov True scs) { dJudge = False })
                             t = compareRuns (runPure d0) Nothing
                             dEnd = fromMaybe d0 (tLast t)
                         in if null (dErr dEnd) then reverse (dRes dEnd) else error (show (dErr dEnd))
      maxOf prov scs = maximum (map lrCycles (measure prov scs))
      bgOnly33 = worst (noObj a2dk) : maybe [] (\kb -> [worst (noObj kb)]) kbM
      lats = [1, 2, 4, 8, 16, 24, 32, 64, 128, 256, 512, 768, 900, 1024]
  putStrLn "cycles per line, start accepted to engine ready again (last pixel out), pure model;"
  putStrLn "provider always ready (pipelined) or one request at a time (serial); latency = cycles from request taken to response"
  putStrLn "latency | BG 33 slots | BG 32 slots | BG 33, serial | no BG, no OBJ | 2dk A, BG+OBJ | kirby135, BG+OBJ"
  forM_ lats $ \l ->
    printf "%7d | %11d | %11d | %13d | %13d | %13d | %16s\n" l (maxOf (PFixed l) bgOnly33) (maxOf (PFixed l) [zero (noObj a2dk)])
      (maxOf (PSerial l) bgOnly33) (maxOf (PFixed l) [noBg]) (maxOf (PFixed l) [a2dk]) (kbCol l)
  let budget = 2130 :: Int
      search prov scs = let ok l = maxOf (prov l) scs <= budget
                            go lo hi = if hi - lo <= 1 then lo else let m = (lo + hi) `div` 2 in if ok m then go m hi else go lo m
                        in go 1 4096
      report name scs = do
        let lp = search PFixed scs
            ls = search PSerial scs
        printf "%s: largest latency within 2,130 cycles: pipelined %d (%d cycles), serial %d (%d cycles)\n"
          (name :: String) lp (maxOf (PFixed lp) scs) ls (maxOf (PSerial ls) scs)
  report (if isJust kbM then "BG only, 33 slots (2dk A, kirby135)" else "BG only, 33 slots (2dk A)") bgOnly33
  report "2dk engine A, BG + 6 sprites" [a2dk]
  forM_ kbOk $ \kb -> report "kirby135, BG + OBJ" [kb]
  putStrLn "64x64 8bpp sprites on the line (2dk BG, 33 slots): sprites | sprite pixels on the line | cycles at latency 1, 16, 64"
  forM_ [1, 4, 8, 16, 24, 32, 64, 128] $ \k -> do
    let sc = heavy (worst a2dk) k
        px = sum [ min 256 (soX s + soW s) - max 0 (soX s) | s <- either (const []) id (spritesOn sc 0) ]
    printf "  %3d | %5d | %5d %5d %5d\n" k px (maxOf (PFixed 1) [sc]) (maxOf (PFixed 16) [sc]) (maxOf (PFixed 64) [sc])
  let rs = measure PRandom (a2dk : maybe [] pure kbOk)
  printf "random provider (as the check), 2dk A%s: worst line %d cycles\n"
    (if isJust kbOk then " + kirby135" else "" :: String) (maximum (map lrCycles rs))

------------------------------------------------------------------------------

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["check", dir, s, n] -> checkMode dir (read s) (read n) False
    ["check", dir, s, n, "--pure"] -> checkMode dir (read s) (read n) True
    ["fault", dir] -> faultMode dir
    ["dump", dir, s, n, grp] -> dumpMode dir (read s) (read n) grp
    ["time", dir] -> timeMode dir
    _ -> do
      hPutStrLn stderr "usage: tilehw-check check DIR SEED N [--pure] | fault DIR | dump DIR SEED N fixtures|random | time DIR"
      exitFailure
