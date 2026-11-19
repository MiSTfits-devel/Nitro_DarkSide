-- SPDX-License-Identifier: GPL-3.0-or-later
-- Independent oracle for the Clash ARM7 (ARMv4T) fixtures: the product ARM7
-- core (gba_cpu, the ARM7TDMI the console uses) and its product memory bus
-- (nds_membus7) run the same image with only the BIOS window (the image, at
-- 0x00000000) and main RAM attached. Any other access fails. RAM is the
-- slice's 64 words at 0x02000000: word k < SCRATCH is mailbox slot k and must
-- be stored whole, in slot order, equal to EXPECT_FILE (first hex token per
-- line, '#' comments); words SCRATCH..63 are byte-enabled scratch. No store
-- may follow the last checked mailbox word (MAILBOX_WORDS, or the whole file
-- when 0). With IRQ_IO the product timers (gba_timer) and IME/IE/IF
-- (nds_irq) sit on the I/O bus, paced at half the CPU clock, and drive the
-- CPU's IRQ input.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use std.textio.all;
use work.pProc_bus_gba.all;

entity tb_arm7_isa_oracle is
   generic (ROM_FILE : string; EXPECT_FILE : string; SCRATCH : natural := 64;
            MAILBOX_WORDS : natural := 0; IRQ_IO : boolean := false);
end entity;

architecture sim of tb_arm7_isa_oracle is
   subtype word is std_logic_vector(31 downto 0);
   type words is array (natural range <>) of word;
   type table is record
      data  : words(0 to 1023);
      count : natural;
   end record;

   impure function load(path : string; fill : word) return table is
      file image : text open read_mode is path;
      variable line_in : line;
      variable result : table := ((others => fill), 0);
   begin
      while not endfile(image) loop
         readline(image, line_in);
         if line_in'length > 0 and line_in(line_in'low) /= '#' then
            hread(line_in, result.data(result.count));
            result.count := result.count + 1;
         end if;
      end loop;
      return result;
   end function;

   constant rom : table := load(ROM_FILE, x"E7F000F0"); -- UDF past the image
   constant expected : table := load(EXPECT_FILE, x"00000000");
   impure function checked_words return natural is
   begin
      if MAILBOX_WORDS = 0 then return expected.count; end if;
      assert MAILBOX_WORDS <= expected.count report "MAILBOX_WORDS exceeds EXPECT_FILE" severity failure;
      return MAILBOX_WORDS;
   end function;
   constant checked : natural := checked_words;
   signal stores : natural := 0;
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   constant ss : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "10", "1111", '1');

   signal cpu_adr, cpu_dout, cpu_din, cpu_lastread, pc : word;
   signal cpu_rnw, cpu_ena, cpu_done, cpu_error : std_logic;
   signal cpu_acc, cpu_low : std_logic_vector(1 downto 0);
   signal bios_addr : unsigned(13 downto 2);
   signal bios_data : word;
   signal w7p_addr : unsigned(15 downto 2);
   signal w7p_we : std_logic;
   signal io_bus : proc_bus_gb_type;
   signal wsh_ena, vram_ena : std_logic;
   signal mr_ena, mr_rnw : std_logic;
   signal mr_done : std_logic := '0';
   signal mr_addr : std_logic_vector(21 downto 2);
   signal mr_be : std_logic_vector(3 downto 0);
   signal mr_data : word;
   signal mr_rdata : word := (others => '0');
   signal ram : words(0 to 63) := (others => (others => '0'));
   signal io_wired_out, irq_wired_out, timer_wired_out : word := (others => '0');
   signal io_wired_done, irq_wired_done, timer_wired_done : std_logic := '0';
   signal cpu_irq, io_ce : std_logic := '0';
   signal io_ce_next : std_logic := '1';   -- full-rate I/O unless IRQ_IO at half rate
   signal irp_timer : std_logic_vector(3 downto 0);
   signal irq_sources : word;
begin
   clk <= not clk after 5 ns;

   cpu : entity work.gba_cpu
   generic map (is_simu => '0')
   port map (
      clk => clk, ce => '1', reset => reset,
      error_cpu => cpu_error, dbg_pc => pc,
      savestate_bus => ss, ss_wired_out => open, ss_wired_done => open,
      gb_bus_Adr => cpu_adr, gb_bus_rnw => cpu_rnw, gb_bus_ena => cpu_ena,
      gb_bus_seq => open, gb_bus_code => open, gb_bus_acc => cpu_acc,
      gb_bus_dout => cpu_dout, gb_bus_din => cpu_din, gb_bus_done => cpu_done,
      gb_bus_lock => open, bus_lowbits => cpu_low,
      dma_on => '0', CPU_bus_idle => open, PC_in_BIOS => open, cpu_halt => open,
      lastread => cpu_lastread, jump_out => open,
      IRQ_in => cpu_irq, unhalt => '0', new_halt => '0'
   );

   membus : entity work.nds_membus7
   port map (
      clk => clk, reset => reset,
      cpu_adr => cpu_adr, cpu_rnw => cpu_rnw, cpu_ena => cpu_ena, cpu_acc => cpu_acc,
      cpu_dout => cpu_dout, cpu_lowbits => cpu_low, cpu_lastread => cpu_lastread,
      cpu_din => cpu_din, cpu_done => cpu_done,
      bios_addr => bios_addr, bios_data => bios_data,
      w7p_addr => w7p_addr, w7p_we => w7p_we, w7p_be => open, w7p_writedata => open,
      w7p_readdata => (others => 'X'),
      wsh_ena => wsh_ena, wsh_rnw => open, wsh_addr => open, wsh_be => open, wsh_din => open,
      wsh_dout => (others => 'X'), wsh_done => '0', wsh_mapped => '0',
      vram_ena => vram_ena, vram_rnw => open, vram_addr => open, vram_be => open, vram_din => open,
      vram_dout => (others => 'X'), vram_done => '0',
      mr_ena => mr_ena, mr_rnw => mr_rnw, mr_addr => mr_addr, mr_be => mr_be,
      mr_writedata => mr_data, mr_done => mr_done, mr_readdata => mr_rdata,
      io_ce_next => io_ce_next,
      io_bus => io_bus, io_wired_out => io_wired_out, io_wired_done => io_wired_done
   );

   process (clk)
      variable word_index : natural;
   begin
      if rising_edge(clk) then
         word_index := to_integer(bios_addr);
         if word_index < rom.data'length then
            bios_data <= rom.data(word_index);
         else
            bios_data <= x"E7F000F0";
         end if;
         mr_done <= '0';
         if reset = '0' then
            assert cpu_error = '0' report "ARM7 instruction error at PC " & to_hstring(pc) severity failure;
            assert vram_ena = '0' and wsh_ena = '0' report "ARM7 fixture reached VRAM or shared WRAM" severity failure;
            assert io_bus.ena = '0' or (IRQ_IO and
                   ((unsigned(io_bus.Adr(23 downto 0)) >= 16#100# and unsigned(io_bus.Adr(23 downto 0)) < 16#110#) or
                    (unsigned(io_bus.Adr(23 downto 0)) >= 16#208# and unsigned(io_bus.Adr(23 downto 0)) < 16#218#)))
               report "ARM7 fixture reached unwired I/O at 04" & to_hstring(io_bus.Adr(23 downto 0)) severity failure;
            if cpu_ena = '1' then
               assert (unsigned(cpu_adr) < 16#1000# and cpu_rnw = '1') or
                      cpu_adr(31 downto 24) = x"02" or
                      (IRQ_IO and cpu_adr(31 downto 24) = x"04")
                  report "ARM7 fixture access outside BIOS/main RAM/I/O: " & to_hstring(cpu_adr) severity failure;
            end if;
            if mr_ena = '1' then
               word_index := to_integer(unsigned(mr_addr));
               assert word_index < 64
                  report "ARM7 main RAM access outside the 256-byte fixture RAM at 02" &
                         to_hstring(mr_addr & "00") severity failure;
               if mr_rnw = '1' then
                  mr_rdata <= ram(word_index);
               else
                  assert stores < checked
                     report "unexpected ARM7 main RAM store at 02" & to_hstring(mr_addr & "00") severity failure;
                  if word_index >= SCRATCH then
                     for lane in 0 to 3 loop
                        if mr_be(lane) = '1' then
                           ram(word_index)(lane*8+7 downto lane*8) <= mr_data(lane*8+7 downto lane*8);
                        end if;
                     end loop;
                  else
                     assert mr_be = "1111" and word_index = stores
                        report "unexpected ARM7 mailbox store at 02" & to_hstring(mr_addr & "00") severity failure;
                     report "ARM7 RAM[" & integer'image(word_index*4) & "]=" & to_hstring(mr_data);
                     assert mr_data = expected.data(word_index)
                        report "slot " & integer'image(word_index) & " expected " &
                               to_hstring(expected.data(word_index)) severity failure;
                     ram(word_index) <= mr_data;
                     stores <= stores + 1;
                  end if;
               end if;
               mr_done <= '1';
            end if;
         end if;
      end if;
   end process;

   process
   begin
      for i in 1 to 6 loop wait until falling_edge(clk); end loop;
      reset <= '0';
      wait until stores = checked for 400 us;
      assert stores = checked report "ARM7 fixture did not finish; PC=" & to_hstring(pc) severity failure;
      -- The image then spins: no further stores may appear.
      wait for 2 us;
      assert stores = checked report "ARM7 fixture stored past its mailbox" severity failure;
      report "PASS: product ARM7 matches " & integer'image(checked) & " fixture mailbox words";
      stop;
      wait;
   end process;

   io_wired_out  <= irq_wired_out or timer_wired_out;
   io_wired_done <= irq_wired_done or timer_wired_done;

   io : if IRQ_IO generate
      irq_sources <= (3 => irp_timer(0), 4 => irp_timer(1), 5 => irp_timer(2),
                      6 => irp_timer(3), others => '0');
      io_ce_next <= not io_ce;
      process (clk)
      begin
         if rising_edge(clk) then
            io_ce <= not io_ce;
         end if;
      end process;

      iirq : entity work.nds_irq
      port map (
         clk => clk, ce => io_ce, reset => reset,
         gb_bus => io_bus, wired_out => irq_wired_out, wired_done => irq_wired_done,
         irq_in => irq_sources, cpu_irq => cpu_irq, cpu_unhalt => open
      );

      itimer : entity work.gba_timer
      generic map (is_simu => '0')
      port map (
         clk => clk, ce => io_ce, reset => reset,
         savestate_bus => ss, ss_wired_out => open, ss_wired_done => open,
         loading_savestate => '0',
         gb_bus => io_bus, wired_out => timer_wired_out, wired_done => timer_wired_done,
         IRP_Timer => irp_timer, timer0_tick => open, timer1_tick => open,
         debugout0 => open, debugout1 => open, debugout2 => open, debugout3 => open
      );
   end generate;
end architecture;
