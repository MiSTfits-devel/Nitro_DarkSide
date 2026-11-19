-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric #-}
-- | ARM946E-S unified protection regions. ARM DDI 0201D §§2.3.6–9, 4.2–3.
-- The caller owns C1.M, instruction privilege, exception entry and bus gating.
module Nds.WholeCore.Arm9Mpu
  ( Mpu, resetMpu, isMpuTransfer, validMpuWrite, readMpu, writeMpu, allowed ) where

import Prelude ()
import Clash.Prelude hiding (Word)
import qualified Clash.Prelude as C
import Data.Maybe (isJust)

type W = BitVector 32
type Page = BitVector 20
type AP = BitVector 4

-- Store the mask when CP15 is written, not in the fetch or LSU critical path.
-- An enabled base has already been checked for region-size alignment.
data Region = Region Page (BitVector 5) Bool Page deriving (Eq,Show,Generic,NFDataX)
data Mpu = Mpu { regions :: Vec 8 Region, dataAP :: Vec 8 AP, codeAP :: Vec 8 AP
               , dataCacheable :: BitVector 8, codeCacheable :: BitVector 8, bufferable :: BitVector 8
               } deriving (Eq,Show,Generic,NFDataX)

resetMpu :: Mpu
resetMpu = Mpu (repeat (Region 0 0 False 0)) (repeat 0) (repeat 0) 0 0 0

data Target = Cache Bool | Buffer | Permissions Bool Bool | Descriptor (Index 8)

-- MRC/MCR p15,0,Rd,CRn,CRm,opcode2. ARM condition/Rd/privilege checks
-- belong to the core. The backward-compatible c6 opcode2=1 is MRC only.
target :: W -> Maybe Target
target op
  | op .&. 0x0fe00f10 /= 0x0e000f10 = Nothing
  | cn == 6 && cm < 8 && (sub == 0 || (sub == 1 && testBit op 20)) =
      Just (Descriptor (fromIntegral cm))
  | cm /= 0 = Nothing
  | cn == 5 && sub < 4 = Just (Permissions (testBit sub 0) (testBit sub 1))
  | cn == 2 && sub < 2 = Just (Cache (testBit sub 0))
  | cn == 3 && sub == 0 = Just Buffer
  | otherwise = Nothing
 where
  cn = C.slice d19 d16 op
  cm = C.slice d3 d0 op
  sub = C.slice d7 d5 op

isMpuTransfer :: W -> Bool
isMpuTransfer = isJust . target

regionFields :: W -> Region
regionFields v = Region (C.slice d31 d12 v) size (testBit v 0) mask
 where
  size = C.slice d5 d1 v
  -- 4 KiB => all page bits compared, 4 GiB => none. A disabled
  -- descriptor's size is immaterial; an invalid enabled write is rejected.
  mask = shiftL maxBound (fromIntegral (size - 11))

-- Enabled sizes below 4 KiB and non-size-aligned bases are UNPREDICTABLE:
-- reject them at MCR commit, rather than granting a rounded/aliased region.
validMpuWrite :: W -> W -> Bool
validMpuWrite op v = not (testBit op 20) && case target op of
  Nothing -> False
  Just (Descriptor _) -> case regionFields v of
    Region base size on mask -> not on || (size >= 11 && base .&. complement mask == 0)
  Just _ -> True

readMpu :: Mpu -> W -> W
readMpu m op = case target op of
  Just (Descriptor i) -> case regions m !! i of
    Region base size on _ -> base ++# (0 :: BitVector 6) ++# size ++# pack on
  Just (Permissions code ext) ->
    let ps = reverse (if code then codeAP m else dataAP m)
    in if ext then pack ps else zeroExtend (pack (map (C.slice d1 d0) ps))
  Just (Cache code) -> zeroExtend (if code then codeCacheable m else dataCacheable m)
  Just Buffer -> zeroExtend (bufferable m)
  Nothing -> errorX "readMpu: unqualified CP15 transfer"

-- Call only after isMpuTransfer and validMpuWrite. Invalid/unrecognized
-- transfers must fault in the CPU, not appear to succeed as hint writes.
writeMpu :: Mpu -> W -> W -> Mpu
writeMpu m op v = case target op of
  Just (Descriptor i) -> m { regions = replace i (regionFields v) (regions m) }
  Just (Permissions code ext) ->
    let ps = if ext then reverse (unpack v)
             else map zeroExtend (reverse (unpack (C.slice d15 d0 v) :: Vec 8 (BitVector 2)))
    in if code then m { codeAP = ps } else m { dataAP = ps }
  Just (Cache False) -> m { dataCacheable = resize v }
  Just (Cache True) -> m { codeCacheable = resize v }
  Just Buffer -> m { bufferable = resize v }
  Nothing -> errorX "writeMpu: unqualified CP15 transfer"

-- | Enabled MPU permission for an aligned instruction/data beat, before
-- physical translation/mirroring. No matching region means no access in
-- ANY mode. Highest matching number wins even when that region denies.
-- Unpredictable reserved AP encodings deny; no lower region may override.
allowed :: Mpu -> Bool -> Bool -> Bool -> W -> Bool
allowed m user instruction wr addr = snd (fold higher candidates)
 where
  page = C.slice d31 d12 addr
  candidates = zipWith check (regions m) (if instruction then codeAP m else dataAP m)
  check (Region base _ on mask) ap = (hit, hit && permitted ap)
   where hit = on && (page .&. mask) == base
  higher (lh,la) (hh,ha) = (lh || hh, ha || (not hh && la))
  permitted ap = not (instruction && wr) && case ap of
    1 -> not user
    2 -> not user || not wr
    3 -> True
    5 -> not user && not wr
    6 -> not wr
    _ -> False
