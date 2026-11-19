-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric, NoImplicitPrelude #-}
module Nds.WholeCore.Arm9Tcm (Config, resetConfig, Bank(..), transfer, readReg, validWrite, writeReg, target) where
import Clash.Prelude hiding (Word)
type Word = BitVector 32
data Bank = External | Itcm | Dtcm deriving (Eq,Generic,NFDataX)
-- Register masks are derived on CP15 write, not on each address comparison.
data Config = Config Word Word Word Word deriving (Generic,NFDataX)
resetConfig :: Config
resetConfig = Config 0x0c 0x0a 0xffff8000 0xffffc000
reg :: Word -> Word
reg op=op .&. 0x0fef0fff
transfer :: Word -> Bool
transfer op=reg op==0x0e090f11 || reg op==0x0e090f31 || (reg op==0x0e000f50 && testBit op 20)
readReg :: Config -> Word -> Word
readReg (Config i d _ _) op | reg op==0x0e000f50 = 0x00140180
                             | testBit op 5 = i
                             | otherwise = d
validWrite :: Word -> Word -> Bool
validWrite op v=sz>=3 && sz<=23 && (not (testBit op 5) || slice d31 d12 v==0)
 where sz=slice d5 d1 v
writeReg :: Config -> Word -> Word -> Config
writeReg (Config i d im dm) op v | testBit op 5 = Config (v .&. 0x3e) d mask dm
                                | otherwise = Config i (v .&. 0xfffff03e) im mask
 where mask=shiftL (maxBound :: Word) (9+fromIntegral (slice d5 d1 v))
-- Instruction fetches never select DTCM. ITCM wins for data, except a
-- read in load mode falls through to DTCM or the external memory system.
target :: Config -> Word -> Bool -> Bool -> Word -> Bank
target (Config _ d im dm) ctrl fetch wr a
 | testBit ctrl 18 && (wr || not (testBit ctrl 19)) && a .&. im==0 = Itcm
 | not fetch && testBit ctrl 16 && (wr || not (testBit ctrl 17)) && (xor a d .&. dm)==0 = Dtcm
 | otherwise = External
