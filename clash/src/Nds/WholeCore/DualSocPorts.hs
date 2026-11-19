-- SPDX-License-Identifier: GPL-3.0-or-later
{-# OPTIONS_GHC -dynamic-too #-}
-- Both board-facing ABIs have the same names. Only the wide variant
-- exports the presented (not necessarily accepted) memory request's owner.
module Nds.WholeCore.DualSocPorts (dualPorts, bufferedPorts, firmwarePorts) where

import Prelude
import Clash.Annotations.TopEntity (TopEntity(..), PortName(..))

dualPorts :: Bool -> TopEntity
dualPorts wide = Synthesize
  { t_name = if wide then "nds_dual_soc_wide" else "nds_dual_soc"
  , t_inputs = map PortName
      [ "CLK", "RST", "EN", "BOOT9_WORD", "BOOT7_WORD", "GPU_REQ_READY", "GPU_REPLY_VALID"
      , "GPU_REPLY_DATA", "GPU_REPLY_FAULT", "EXT_IRQ_SET", "CARD_INSERTED", "CARD_DIRECT_BOOT"
      , "CARD_CHIP_ID", "CARD_ROM_MASK", "CARD_ROM_READY", "CARD_ROM_REPLY_VALID", "CARD_ROM_DATA"
      , "MEM_REQ_READY", "MEM_RESP_VALID", "MEM_RESP_DATA" ]
  , t_output = if wide then PortProduct "" [PortProduct "" [outputs, PortName "MEM_ARM7"], PortName "MEM_FETCH"] else outputs }
 where
  group name fields = PortProduct name (map PortName fields)
  cpu name = group name ["BOOT_ADDR", "REQ_VALID", "REQ_WRITE", "REQ_ADDR", "REQ_WIDTH", "REQ_LANES", "REQ_DATA",
                          "REPLY_READY", "STORE_VALID", "STORE_ADDR", "STORE_DATA", "FAULT", "FAULT_ADDR",
                          "RETIRE_VALID", "RETIRE_PC", "RETIRE_OPCODE"]
  io name = group name ["CPU_REQ_READY", "CPU_REPLY_VALID", "CPU_REPLY_DATA", "CPU_REPLY_FAULT",
                         "GPU_REQ_VALID", "GPU_REPLY_READY", "IRQ", "IF_ACK", "IE", "IF", "IME"]
  outputs = PortProduct "" [cpu "CPU9", cpu "CPU7", io "IO9", io "IO7", group "CARD" ["ROM_REQ_VALID", "ROM_ADDR", "IRQ", "BUSY"],
                            group "MEM" ["REQ_VALID", "REQ_WRITE", "REQ_ADDR", "REQ_LANES", "REQ_DATA"],
                            group "ARB" ["WANT9", "WANT7", "GRANT", "STEP9", "STEP7", "CE7"]]

bufferedPorts :: TopEntity
bufferedPorts = base { t_name = "nds_dual_soc_buffered", t_inputs = extra ++ t_inputs base }
 where
  base = dualPorts True
  extra = map PortName ["MEM_RESP_LINE", "SNOOP_WRITE", "SNOOP_ADDR"]

firmwarePorts :: TopEntity
firmwarePorts = bufferedPorts { t_name = "nds_dual_soc_firmware", t_inputs = extra ++ t_inputs bufferedPorts }
 where
  extra = map PortName ["SYS7_READY", "SYS7_REPLY_VALID", "SYS7_REPLY_DATA", "SYS7_REPLY_FAULT", "SYS7_IRQ_SET"]
