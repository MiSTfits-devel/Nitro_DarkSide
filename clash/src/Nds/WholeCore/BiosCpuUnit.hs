-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds #-}
-- Preserve the real dual CPU as an independently compiled unit. Clash
-- derives the packed port widths at both ends from the SAME Haskell type.
-- Its simulation is the actual circuit, not a default-valued black box.
module Nds.WholeCore.BiosCpuUnit (biosCpuTopEntity) where
import Prelude ()
import Clash.Explicit.Prelude
import qualified Nds.WholeCore.DualSoc as D

type Unit=Clock System -> Reset System -> Signal System D.DualIn -> Signal System D.FirmwareIo7
       -> Signal System (BitVector 64) -> Signal System (Maybe (BitVector 32)) -> Signal System (D.DualOut,Bool)
{-# ANN biosCpuTopEntity (Synthesize {t_name="nds_bios_cpu",t_inputs=[PortName "CLK",PortName "RST",PortName "DIN",PortName "IO7",PortName "LINE",PortName "SNOOP"],t_output=PortName "DOUT"}) #-}
biosCpuTopEntity :: Unit
biosCpuTopEntity clk rst = D.dualFirmwareSoc clk rst enableGen
