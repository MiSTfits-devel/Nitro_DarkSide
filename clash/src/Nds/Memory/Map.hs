-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, NoImplicitPrelude, DeriveAnyClass, DeriveGeneric #-}
module Nds.Memory.Map
  ( Space(..), VideoReq(..), Controls, controlMask, bankHits, cpuVideo ) where

import Clash.Explicit.Prelude

data Space = MainBG | SubBG | MainOBJ | SubOBJ | LCDC | Texture | TexPalette
           | MainBGExt | SubBGExt | MainOBJExt | SubOBJExt | Arm7VRAM
  deriving (Eq, Show, Generic, NFDataX)
data VideoReq = VideoReq { videoSpace :: Space, videoOffset :: Unsigned 20 }
  deriving (Eq, Show, Generic, NFDataX)
type Controls = Vec 9 (BitVector 8)

controlMask :: Controls
controlMask = 0x9b :> 0x9b :> 0x9f :> 0x9f :> 0x87 :> 0x9f :> 0x9f :> 0x83 :> 0x83 :> Nil

-- ARM9 regions are 2 MiB apertures; from 06800000 up the LCDC layout
-- repeats every MiB, including the unpopulated pages after I. ARM7 decodes
-- only bit 17 across the entire 06 window and only exposes C/D in MST 2.
cpuVideo :: Bool -> BitVector 32 -> VideoReq
cpuVideo arm7 a = VideoReq space (unpack (slice d19 d0 a))
 where
  space | arm7 = Arm7VRAM
        | otherwise = case slice d23 d21 a of
            0 -> MainBG; 1 -> SubBG; 2 -> MainOBJ; 3 -> SubOBJ; _ -> LCDC

-- Decode into a *set*, never a preferred bank. Offsets within physical
-- banks are simply the low address wires (after folding palette apertures).
-- Nintendo's NITRO manual 2.2.1 specifies supported MST/OFS combinations;
-- mirror aliases and prohibited OFS high bits follow melonDS GPU::MapVRAM_*.
bankHits :: Controls -> VideoReq -> BitVector 9
bankHits cnt (VideoReq space off) = pack (reverse (imap hit cnt))
 where
  p = pack off
  lcdBases = 0 :> 8 :> 16 :> 24 :> 32 :> 36 :> 37 :> 38 :> 40 :> Nil :: Vec 9 (BitVector 6)
  lcdMasks = 56 :> 56 :> 56 :> 56 :> 60 :> 63 :> 63 :> 62 :> 63 :> Nil :: Vec 9 (BitVector 6)
  hit i c = testBit c 7 && case space of
    LCDC -> mst == 0 && slice d19 d14 p .&. (lcdMasks !! i) == lcdBases !! i
    MainBG -> mst == 1 && (if big then slice d18 d17 p == ofs else
              if i == 4 then slice d18 d16 p == 0 else fg && fgHit && not (testBit p 18))
    MainOBJ -> mst == 2 && (if i <= 1 then b17 else
               if i == 4 then slice d17 d16 p == 0 else fg && fgHit)
    SubBG -> (i == 2 && mst == 4) || (mst == 1 &&
             ((i == 7 && not (testBit p 15)) || (i == 8 && testBit p 15)))
    SubOBJ -> (i == 3 && mst == 4) || (i == 8 && mst == 2)
    Arm7VRAM -> (i == 2 || i == 3) && mst == 2 && b17
    Texture -> big && mst == 3 && slice d18 d17 p == ofs
    TexPalette -> mst == 3 && ((i == 4 && not (testBit p 16)) ||
                  (fg && slice d16 d14 p == (slice d1 d1 ofs ++# (0 :: BitVector 1) ++# slice d0 d0 ofs)))
    MainBGExt -> mst == 4 && (i == 4 || (fg && testBit p 14 == testBit ofs 0))
    MainOBJExt -> fg && mst == 5
    SubBGExt -> i == 7 && mst == 2
    SubOBJExt -> i == 8 && mst == 3
   where
    big = i < 4
    fg = i == 5 || i == 6
    mst = slice d2 d0 c
    ofs = slice d4 d3 c
    b17 = testBit p 17 == testBit ofs 0
    -- F/G also respond one 32 KiB page up: address bit 15 isn't decoded.
    fgHit = not (testBit p 17) && testBit p 16 == testBit ofs 1 && testBit p 14 == testBit ofs 0
