{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- | The external-memory port every 3D hardware block uses.
--
-- One port is a request stream and a response stream:
--
-- * the block drives @Signal dom (Maybe MemReq)@ and holds a request
--   unchanged until a cycle in which the memory's @Signal dom Bool@ ready is
--   high (that cycle is the transfer);
-- * the memory answers every 'MemRead' with exactly one
--   @Just (BitVector 64)@ on the response signal, in request order, after
--   any latency of at least one cycle. Writes get no response.
--
-- Addresses are byte addresses of 8-byte-aligned words (bits 2:0 ignored).
-- The board wrapper maps each port to SDRAM, DDR3 or M10K and arbitrates.
module Nds.Gpu3D.Mem
  ( MemAddr
  , MemReq (..)
  , memAddr
  , isRead
  ) where

import Clash.Prelude

-- | A 28-bit byte address (256 MiB, the DDR3 window the FPGA owns).
type MemAddr = Unsigned 28

data MemReq
  = MemRead !MemAddr
  | MemWrite !MemAddr !(BitVector 8) !(BitVector 64)
    -- ^ address, byte enables (bit i enables byte i, little-endian), data
  deriving (Eq, Generic, Show, NFDataX)

memAddr :: MemReq -> MemAddr
memAddr (MemRead a) = a
memAddr (MemWrite a _ _) = a

isRead :: MemReq -> Bool
isRead (MemRead _) = True
isRead _ = False
