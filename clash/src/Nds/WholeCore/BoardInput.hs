-- SPDX-License-Identifier: GPL-3.0-or-later
{-# LANGUAGE DataKinds, NoImplicitPrelude #-}
-- The release shell has already arbitrated mouse vs right stick. Do not
-- apply a second display rotation or alter HPS joystick numbering here.
module Nds.WholeCore.BoardInput (boardInputTopEntity) where
import Clash.Prelude

{-# ANN boardInputTopEntity (Synthesize { t_name="nds_board_input",
  t_inputs=[PortName "JOY", PortName "ANALOG"],
  t_output=PortProduct "" [PortName "KEYS",PortName "PEN",PortName "X",PortName "Y",PortName "LID",PortName "BLOW"] }) #-}
boardInputTopEntity :: BitVector 32 -> BitVector 16 -> (BitVector 12,Bool,BitVector 8,BitVector 8,Bool,Bool)
boardInputTopEntity j axes = (keys,testBit j 12,x,y,testBit j 13,testBit j 14)
 where
  -- Y X L R Down Up Left Right Start Select B A, as KEYINPUT/EXTKEYIN.
  keys = slice d7 d6 j ++# slice d8 d8 j ++# slice d9 d9 j ++# slice d2 d2 j ++# slice d3 d3 j ++#
         slice d1 d0 j ++# slice d11 d10 j ++# slice d5 d4 j
  ux = slice d7 d0 axes `xor` 0x80
  uy = zeroExtend (slice d15 d8 axes `xor` 0x80) :: BitVector 10
  -- Preserve the shipping low-X dead pixel and 0..191 vertical range.
  x = if ux == 1 then 0 else ux
  y = slice d9 d2 (uy + shiftL uy 1)
