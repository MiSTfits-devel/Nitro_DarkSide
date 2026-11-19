-- SPDX-License-Identifier: GPL-3.0-or-later
-- Drives the shipping rtl/gba_timer.vhd through three schedules and logs per
-- cycle for TimersCheck --vhdl. Write schedules must match TimersCheck.hs
-- (scenarioA, scenarioB, and the C reload-on-overflow case).
--   A t d0 d1 d2 d3 irp   cascade chain, F/1 source
--   B t irp               prescaled timers, periods only
--   C t d0 irp            reload written on the overflow clock
-- dN is debugoutN: the counter readback two clocks late. irp is IRP_Timer.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.pProc_bus_gba.all;

entity tb_gba_timer_witness is
end entity;

architecture sim of tb_gba_timer_witness is
   signal clk   : std_logic := '0';
   signal reset : std_logic := '1';
   signal bus_i : proc_bus_gb_type := (Din => (others => '0'), Adr => (others => '0'), rnw => '1',
                                       ena => '0', acc => ACCESS_32BIT, bEna => "1111", rst => '1');
   signal irp   : std_logic_vector(3 downto 0);
   signal d0, d1, d2, d3 : unsigned(15 downto 0);
   signal ss_bus : proc_bus_gb_type := (Din => (others => '0'), Adr => (others => '0'), rnw => '1',
                                        ena => '0', acc => ACCESS_32BIT, bEna => "0000", rst => '0');
begin
   dut : entity work.gba_timer
      generic map (is_simu => '1')
      port map (clk => clk, ce => '1', reset => reset,
                savestate_bus => ss_bus, ss_wired_out => open, ss_wired_done => open,
                loading_savestate => '0',
                gb_bus => bus_i, wired_out => open, wired_done => open,
                IRP_Timer => irp, timer0_tick => open, timer1_tick => open,
                debugout0 => d0, debugout1 => d1, debugout2 => d2, debugout3 => d3);

   process
      variable l : line;

      procedure edge is
      begin
         wait for 5 ns; clk <= '1'; wait for 5 ns; clk <= '0';
      end procedure;

      procedure do_reset is
      begin
         bus_i.ena <= '0'; bus_i.rst <= '1'; reset <= '1';
         edge; edge;
         bus_i.rst <= '0'; reset <= '0';
      end procedure;

      -- Present one write for the current cycle (it lands on the next edge).
      procedure put(n : natural; lanes : std_logic_vector(3 downto 0); d : std_logic_vector(31 downto 0)) is
      begin
         bus_i.Adr <= std_logic_vector(to_unsigned(16#100# + 4 * n, proc_busadr));
         bus_i.Din <= d; bus_i.bEna <= lanes; bus_i.rnw <= '0'; bus_i.ena <= '1';
      end procedure;

      procedure none is
      begin
         bus_i.ena <= '0'; bus_i.rnw <= '1';
      end procedure;

      procedure hex(v : unsigned) is
      begin
         write(l, string'(" ")); hwrite(l, std_logic_vector(v));
      end procedure;
   begin
      do_reset;
      for t in 0 to 19999 loop
         case t is
            when 0 => put(3, "1111", x"00C4FFFE");
            when 1 => put(2, "1111", x"00C4FFFC");
            when 2 => put(1, "1111", x"00C4FFF8");
            when 3 => put(0, "1111", x"00C0FFF0");
            when others => none;
         end case;
         wait for 1 ns;
         write(l, string'("A ")); write(l, t);
         hex(d0); hex(d1); hex(d2); hex(d3); hex(unsigned(irp));
         writeline(output, l);
         wait for 3 ns; clk <= '1'; wait for 5 ns; clk <= '0'; wait for 1 ns;
      end loop;

      do_reset;
      for t in 0 to 99999 loop
         case t is
            when 0 => put(0, "1111", x"00C1FFF0");
            when 1 => put(1, "1111", x"00C2FFFC");
            when 2 => put(2, "1111", x"00C3FFFE");
            when 3 => put(3, "1111", x"00C08000");
            when others => none;
         end case;
         wait for 1 ns;
         write(l, string'("B ")); write(l, t); hex(unsigned(irp));
         writeline(output, l);
         wait for 3 ns; clk <= '1'; wait for 5 ns; clk <= '0'; wait for 1 ns;
      end loop;

      do_reset;
      for t in 0 to 59 loop
         case t is
            when 0 => put(0, "1111", x"00C0FFF0");
            when 17 => put(0, "0011", x"00001234");
            when others => none;
         end case;
         wait for 1 ns;
         write(l, string'("C ")); write(l, t); hex(d0); hex(unsigned(irp));
         writeline(output, l);
         wait for 3 ns; clk <= '1'; wait for 5 ns; clk <= '0'; wait for 1 ns;
      end loop;

      std.env.finish;
   end process;
end architecture;
