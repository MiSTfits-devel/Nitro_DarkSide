# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# The shipping 3D island clock is 100.541946 MHz, period 9.946 ns.

create_clock -name clk -period 9.946 -waveform {0.000 4.973} [get_ports {c$arg}]
derive_clock_uncertainty
