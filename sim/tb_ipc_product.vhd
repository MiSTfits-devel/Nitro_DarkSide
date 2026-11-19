-- SPDX-License-Identifier: GPL-3.0-or-later
-- Product IPC (nds_ipc) driven by an operation list (sim/tests/hs_ipc_ops.py)
-- for comparison with Nds.WholeCore.Ipc (clash/test/IpcOpsCheck.hs). Each
-- operation takes four cycles: the access is on the CPU's proc bus for one
-- cycle, then the bus idles with the address held. Read data is sampled as
-- the product's consumers do: the ARM7 path in the access cycle, the ARM9
-- path in the access cycle for IPCSYNC/IPCFIFOCNT and one cycle later for
-- IPCFIFORECV (nds_ipc presents last9 after the pop edge). IRQ pulses seen
-- during the four cycles are reported with the operation. Output, one line
-- per operation: index, read data (hex, 0 for writes), the ARM9 IRQ bits
-- and the ARM7 IRQ bits raised (bit 16 sync, 17 send empty, 18 receive).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use std.textio.all;
use work.pProc_bus_gba.all;

entity tb_ipc_product is
   generic (OPS_FILE : string; LOG_FILE : string);
end entity;

architecture sim of tb_ipc_product is
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   constant idle : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "10", "0000", '0');
   signal bus7, bus9 : proc_bus_gb_type := idle;
   signal out7, out9 : std_logic_vector(31 downto 0);
   signal done7, done9 : std_logic;
   signal i9s, i9e, i9r, i7s, i7e, i7r : std_logic;
begin
   clk <= not clk after 5 ns;

   dut : entity work.nds_ipc
   port map (
      clk => clk, reset => reset,
      bus7 => bus7, wired_out7 => out7, wired_done7 => done7,
      irq7_sync => i7s, irq7_sendempty => i7e, irq7_recv => i7r,
      bus9 => bus9, wired_out9 => out9, wired_done9 => done9,
      irq9_sync => i9s, irq9_sendempty => i9e,
      dbg_ipc => open, irq9_recv => i9r
   );

   process
      file ops : text open read_mode is OPS_FILE;
      file log : text open write_mode is LOG_FILE;
      variable l, o : line;
      variable cpu : integer;
      variable kind : string(1 to 2);
      variable sp : character;
      variable addr, data, rd : std_logic_vector(31 downto 0);
      variable b : proc_bus_gb_type;
      variable irq9, irq7 : std_logic_vector(31 downto 0);
      variable n : natural := 0;
      variable is_recv : boolean;
   begin
      for i in 1 to 3 loop wait until falling_edge(clk); end loop;
      reset <= '0';
      wait until falling_edge(clk);
      while not endfile(ops) loop
         readline(ops, l);
         read(l, cpu);
         read(l, sp);
         read(l, kind);
         hread(l, addr);
         hread(l, data);
         b := idle;
         b.Adr := "00" & addr(25 downto 0);   -- offset from 0x04000000
         b.rnw := '1' when kind(1) = 'R' else '0';
         b.ena := '1';
         b.acc := "10" when kind(2) = '4' else "01";
         if kind(2) = '4' then
            b.bEna := "1111";
            b.Din := data;
         elsif addr(1) = '1' then
            b.bEna := "1100";
            b.Din := data(15 downto 0) & x"0000";
         else
            b.bEna := "0011";
            b.Din := x"0000" & data(15 downto 0);
         end if;
         is_recv := addr = x"04100000";
         irq9 := (others => '0');
         irq7 := (others => '0');
         if cpu = 9 then bus9 <= b; else bus7 <= b; end if;
         wait for 1 ns;
         rd := (others => '0');
         if b.rnw = '1' and not (cpu = 9 and is_recv) then
            rd := out9 when cpu = 9 else out7;
         end if;
         for k in 1 to 4 loop
            wait until rising_edge(clk);
            wait for 1 ns;
            if k = 1 then
               b.ena := '0';
               if cpu = 9 then bus9 <= b; else bus7 <= b; end if;
               wait for 1 ns;
               if b.rnw = '1' and cpu = 9 and is_recv then rd := out9; end if;
            end if;
            if i9s = '1' then irq9(16) := '1'; end if;
            if i9e = '1' then irq9(17) := '1'; end if;
            if i9r = '1' then irq9(18) := '1'; end if;
            if i7s = '1' then irq7(16) := '1'; end if;
            if i7e = '1' then irq7(17) := '1'; end if;
            if i7r = '1' then irq7(18) := '1'; end if;
         end loop;
         bus9 <= idle;
         bus7 <= idle;
         if kind(1) = 'R' and kind(2) = '2' then
            rd := (x"0000" & rd(31 downto 16)) when addr(1) = '1' else (x"0000" & rd(15 downto 0));
         end if;
         write(o, integer'image(n) & " ");
         hwrite(o, rd);
         write(o, string'(" "));
         hwrite(o, irq9);
         write(o, string'(" "));
         hwrite(o, irq7);
         writeline(log, o);
         n := n + 1;
         wait until falling_edge(clk);
      end loop;
      report "ops: " & integer'image(n);
      stop;
      wait;
   end process;
end architecture;
