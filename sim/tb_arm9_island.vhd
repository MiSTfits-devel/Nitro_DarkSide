-- ARM9 island (roadmap M3): nds_cpu9 (ARM946E-S fork of gba_cpu) wired through
-- nds_membus9 to the boot ROM (sim/tests/arm9_island.hex at 0xFFFF0000), the
-- TCMs, main RAM (nds_mainram + behavioral SDRAM controller), shared WRAM,
-- timers and IRQ. The testbench presets the boot PC to 0xFFFF0000 through the
-- savestate bus — the same way the card loader will set the ARM9 entry point.
-- The test program exercises the v5TE additions, CP15, both TCMs, high
-- vectors and wait-for-interrupt; progress is snooped from the mailbox at
-- 0x02FFFF00 (bitmask +0x00, magic +0x04).
-- Run: sim/run_arm9_island.sh

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.textio.all;

use work.pProc_bus_gba.all;

entity tb_arm9_island is
   generic
   (
      HEXFILE    : string  := "sim/tests/arm9_island.hex";
      TIMEOUT_MS : integer := 10
   );
end entity;

architecture sim of tb_arm9_island is

   constant MAINRAM_BASE : integer := 8388608;

   signal clk1x       : std_logic := '0';
   signal clkMem      : std_logic := '0';
   signal clkMemIndex : unsigned(1 downto 0) := "10";
   signal reset       : std_logic := '1';

   -- CPU <-> membus
   signal cpu_adr      : std_logic_vector(31 downto 0);
   signal cpu_rnw      : std_logic;
   signal cpu_ena      : std_logic;
   signal cpu_code     : std_logic;
   signal cpu_acc      : std_logic_vector(1 downto 0);
   signal cpu_dout     : std_logic_vector(31 downto 0);
   signal cpu_din      : std_logic_vector(31 downto 0);
   signal cpu_done     : std_logic;
   signal cpu_lowbits  : std_logic_vector(1 downto 0);
   signal cpu_lastread : std_logic_vector(31 downto 0);
   signal error_cpu    : std_logic;

   signal cpu_irq, cpu_unhalt : std_logic;

   -- CP15 config
   signal cp15_itcm_ena, cp15_itcm_load : std_logic;
   signal cp15_dtcm_ena, cp15_dtcm_load : std_logic;
   signal cp15_dtcm_base : std_logic_vector(31 downto 12);
   signal cp15_dtcm_size, cp15_itcm_size : std_logic_vector(4 downto 0);

   signal ss_bus : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');

   -- boot ROM (32 KB, linked at 0xFFFF0000)
   type t_brom is array (0 to 8191) of std_logic_vector(31 downto 0);
   impure function load_hex(fname : string) return t_brom is
      file f       : text;
      variable l   : line;
      variable w   : std_logic_vector(31 downto 0);
      variable mem : t_brom := (others => (others => '0'));
      variable i   : integer := 0;
   begin
      file_open(f, fname, read_mode);
      while not endfile(f) loop
         readline(f, l);
         hread(l, w);
         mem(i) := w;
         i := i + 1;
      end loop;
      file_close(f);
      report "loaded " & integer'image(i) & " boot ROM words from " & fname severity note;
      return mem;
   end function;
   constant brom : t_brom := load_hex(HEXFILE);
   signal brom_addr : unsigned(14 downto 2);
   signal brom_data : std_logic_vector(31 downto 0);

   -- TCM stores
   type t_itcm is array (0 to 8191) of std_logic_vector(31 downto 0);
   type t_dtcm is array (0 to 4095) of std_logic_vector(31 downto 0);
   signal itcm : t_itcm := (others => (others => '0'));
   signal dtcm : t_dtcm := (others => (others => '0'));
   signal itcm_addr : unsigned(14 downto 2);
   signal itcm_we   : std_logic;
   signal itcm_be   : std_logic_vector(3 downto 0);
   signal itcm_writedata, itcm_readdata : std_logic_vector(31 downto 0);
   signal dtcm_addr : unsigned(13 downto 2);
   signal dtcm_we   : std_logic;
   signal dtcm_be   : std_logic_vector(3 downto 0);
   signal dtcm_writedata, dtcm_readdata : std_logic_vector(31 downto 0);

   -- shared WRAM
   signal wsh_ena, wsh_rnw, wsh_done, wsh_mapped : std_logic;
   signal wsh_addr : unsigned(14 downto 2);
   signal wsh_be   : std_logic_vector(3 downto 0);
   signal wsh_din, wsh_dout : std_logic_vector(31 downto 0);

   -- VRAM tied off (unused by the ARM9 island test)
   signal vram_ena, vram_rnw : std_logic;
   signal vram_addr : unsigned(23 downto 2);
   signal vram_be   : std_logic_vector(3 downto 0);
   signal vram_din  : std_logic_vector(31 downto 0);

   -- main RAM
   signal mr9_ena, mr9_rnw, mr9_done : std_logic;
   signal mr9_addr : std_logic_vector(21 downto 2);
   signal mr9_be   : std_logic_vector(3 downto 0);
   signal mr9_writedata, mr9_readdata : std_logic_vector(31 downto 0);
   signal mainram_active, mainram_busy : std_logic;
   signal model_allow : std_logic := '1';
   signal sdram_ena, sdram_rnw : std_logic := '0';
   signal sdram_Adr : std_logic_vector(26 downto 0);
   signal sdram_Din : std_logic_vector(31 downto 0);
   signal sdram_be  : std_logic_vector(3 downto 0);
   signal sdram_Dout : std_logic_vector(31 downto 0) := (others => '0');
   signal sdram_done32 : std_logic := '0';

   -- IO register bus
   signal io_bus : proc_bus_gb_type;
   signal io_wired_out : std_logic_vector(31 downto 0);
   signal io_wired_done : std_logic;
   signal irq_wired_out, timer_wired_out : std_logic_vector(31 downto 0);
   signal irq_wired_done, timer_wired_done : std_logic;

   signal irq_in    : std_logic_vector(31 downto 0);
   signal irp_timer : std_logic_vector(3 downto 0);

   signal mailbox_bits : std_logic_vector(31 downto 0) := (others => '0');
   signal tests_done   : boolean := false;

begin

   -- ================= clocks =================
   clkMem <= not clkMem after 5 ns when not tests_done else '0';

   process (clkMem)
   begin
      if rising_edge(clkMem) then
         if (clkMemIndex = 2) then
            clkMemIndex <= "00";
            clk1x       <= '1';
         else
            clkMemIndex <= clkMemIndex + 1;
         end if;
         if (clkMemIndex = 0) then
            clk1x <= '0';
         end if;
      end if;
   end process;

   -- boot: shadow-reg reset pulse, then preset the boot PC to 0xFFFF0000
   -- through the savestate bus, then release reset
   p_boot : process
   begin
      ss_bus.rst <= '1';
      for k in 1 to 3 loop wait until rising_edge(clk1x); end loop;
      ss_bus.rst <= '0';
      wait until rising_edge(clk1x);
      ss_bus.Adr  <= (others => '0'); -- REG_SAVESTATE_PC
      ss_bus.Din  <= x"FFFF0000";
      ss_bus.rnw  <= '0';
      ss_bus.bEna <= "1111";
      ss_bus.ena  <= '1';
      wait until rising_edge(clk1x);
      ss_bus.ena  <= '0';
      ss_bus.rnw  <= '1';
      for k in 1 to 3 loop wait until rising_edge(clk1x); end loop;
      reset <= '0';
      wait;
   end process;

   -- ================= CPU =================
   icpu : entity work.nds_cpu9
   generic map ( is_simu => '0' )
   port map
   (
      clk             => clk1x,
      ce              => '1',
      reset           => reset,
      cpu_export_done => open,
      cpu_export      => open,
      error_cpu       => error_cpu,
      savestate_bus   => ss_bus,
      ss_wired_out    => open,
      ss_wired_done   => open,
      gb_bus_Adr      => cpu_adr,
      gb_bus_rnw      => cpu_rnw,
      gb_bus_ena      => cpu_ena,
      gb_bus_seq      => open,
      gb_bus_code     => cpu_code,
      gb_bus_acc      => cpu_acc,
      gb_bus_dout     => cpu_dout,
      gb_bus_din      => cpu_din,
      gb_bus_done     => cpu_done,
      bus_lowbits     => cpu_lowbits,
      dma_on          => '0',
      done            => open,
      CPU_bus_idle    => open,
      PC_in_BIOS      => open,
      cpu_halt        => open,
      lastread        => cpu_lastread,
      jump_out        => open,
      IRQ_in          => cpu_irq,
      unhalt          => cpu_unhalt,
      new_halt        => '0',
      cp15_vector_hi  => open,
      cp15_pu_enable  => open,
      cp15_icache_ena => open,
      cp15_dcache_ena => open,
      cp15_itcm_ena   => cp15_itcm_ena,
      cp15_itcm_load  => cp15_itcm_load,
      cp15_dtcm_ena   => cp15_dtcm_ena,
      cp15_dtcm_load  => cp15_dtcm_load,
      cp15_dtcm_base  => cp15_dtcm_base,
      cp15_dtcm_size  => cp15_dtcm_size,
      cp15_itcm_size  => cp15_itcm_size
   );

   -- ================= bus decoder =================
   imembus : entity work.nds_membus9
   port map
   (
      clk => clk1x, reset => reset,
      itcm_ena => cp15_itcm_ena, itcm_load => cp15_itcm_load, itcm_size => cp15_itcm_size,
      dtcm_ena => cp15_dtcm_ena, dtcm_load => cp15_dtcm_load,
      dtcm_base => cp15_dtcm_base, dtcm_size => cp15_dtcm_size,
      cpu_adr => cpu_adr, cpu_rnw => cpu_rnw, cpu_ena => cpu_ena, cpu_code => cpu_code,
      cpu_acc => cpu_acc, cpu_dout => cpu_dout, cpu_lowbits => cpu_lowbits,
      cpu_lastread => cpu_lastread, cpu_din => cpu_din, cpu_done => cpu_done,
      itcm_addr => itcm_addr, itcm_we => itcm_we, itcm_be => itcm_be,
      itcm_writedata => itcm_writedata, itcm_readdata => itcm_readdata,
      dtcm_addr => dtcm_addr, dtcm_we => dtcm_we, dtcm_be => dtcm_be,
      dtcm_writedata => dtcm_writedata, dtcm_readdata => dtcm_readdata,
      brom_addr => brom_addr, brom_data => brom_data,
      wsh_ena => wsh_ena, wsh_rnw => wsh_rnw, wsh_addr => wsh_addr, wsh_be => wsh_be,
      wsh_din => wsh_din, wsh_dout => wsh_dout, wsh_done => wsh_done, wsh_mapped => wsh_mapped,
      vram_ena => vram_ena, vram_rnw => vram_rnw, vram_addr => vram_addr, vram_be => vram_be,
      vram_din => vram_din, vram_dout => (others => '0'), vram_done => '0',
      mr_ena => mr9_ena, mr_rnw => mr9_rnw, mr_addr => mr9_addr, mr_be => mr9_be,
      mr_writedata => mr9_writedata, mr_done => mr9_done, mr_readdata => mr9_readdata,
      io_bus => io_bus, io_wired_out => io_wired_out, io_wired_done => io_wired_done
   );

   -- ================= boot ROM + TCM stores =================
   brom_data <= brom(to_integer(brom_addr));

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (itcm_we = '1') then
            for i in 0 to 3 loop
               if (itcm_be(i) = '1') then
                  itcm(to_integer(itcm_addr))(i*8 + 7 downto i*8) <= itcm_writedata(i*8 + 7 downto i*8);
               end if;
            end loop;
         end if;
         if (dtcm_we = '1') then
            for i in 0 to 3 loop
               if (dtcm_be(i) = '1') then
                  dtcm(to_integer(dtcm_addr))(i*8 + 7 downto i*8) <= dtcm_writedata(i*8 + 7 downto i*8);
               end if;
            end loop;
         end if;
      end if;
   end process;
   itcm_readdata <= itcm(to_integer(itcm_addr));
   dtcm_readdata <= dtcm(to_integer(dtcm_addr));

   -- ================= IO register banks =================
   io_wired_out  <= irq_wired_out or timer_wired_out;
   io_wired_done <= irq_wired_done or timer_wired_done;

   irq_in <= (3 => irp_timer(0), 4 => irp_timer(1), 5 => irp_timer(2), 6 => irp_timer(3),
              others => '0');

   iirq : entity work.nds_irq
   port map
   (
      clk => clk1x, ce => '1', reset => reset,
      gb_bus => io_bus, wired_out => irq_wired_out, wired_done => irq_wired_done,
      irq_in => irq_in, cpu_irq => cpu_irq, cpu_unhalt => cpu_unhalt
   );

   itimer : entity work.gba_timer
   generic map ( is_simu => '0' )
   port map
   (
      clk => clk1x, ce => '1', reset => reset,
      savestate_bus => ss_bus, ss_wired_out => open, ss_wired_done => open,
      loading_savestate => '0',
      gb_bus => io_bus, wired_out => timer_wired_out, wired_done => timer_wired_done,
      IRP_Timer => irp_timer,
      timer0_tick => open, timer1_tick => open,
      debugout0 => open, debugout1 => open, debugout2 => open, debugout3 => open
   );

   -- ================= memory fabric =================
   iwram : entity work.nds_wram
   generic map ( is_simu => '1' )
   port map
   (
      clk => clk1x, wramcnt => "00", -- all 32K to the ARM9
      arm9_ena => wsh_ena, arm9_rnw => wsh_rnw, arm9_addr => wsh_addr, arm9_be => wsh_be,
      arm9_din => wsh_din, arm9_dout => wsh_dout, arm9_done => wsh_done, arm9_mapped => wsh_mapped,
      arm7_ena => '0', arm7_rnw => '1', arm7_addr => (others => '0'), arm7_be => "0000",
      arm7_din => (others => '0'), arm7_dout => open, arm7_done => open, arm7_mapped => open
   );

   imainram : entity work.nds_mainram
   generic map ( Softmap_NDS_MAINRAM_ADDR => MAINRAM_BASE )
   port map
   (
      clk1x => clk1x, clkMem => clkMem, clkMemIndex => clkMemIndex, reset => reset,
      arm7_priority => '0',
      mem9_ena => mr9_ena, mem9_rnw => mr9_rnw, mem9_addr => mr9_addr, mem9_be => mr9_be,
      mem9_writedata => mr9_writedata, mem9_done => mr9_done, mem9_readdata => mr9_readdata,
      mem7_ena => '0', mem7_rnw => '1', mem7_addr => (others => '0'), mem7_be => "0000",
      mem7_writedata => (others => '0'), mem7_done => open, mem7_readdata => open,
      mainram_allow => model_allow, mainram_active => mainram_active, mainram_busy => mainram_busy,
      mr_sdram_ena => sdram_ena, mr_sdram_rnw => sdram_rnw, mr_sdram_Adr => sdram_Adr,
      mr_sdram_Din => sdram_Din, mr_sdram_be => sdram_be,
      sdram_Dout => sdram_Dout, sdram_done32 => sdram_done32
   );

   -- ================= behavioral SDRAM controller (from tb_mainram) =================
   psdram : process
      type t_mem is array (0 to 1048575) of std_logic_vector(31 downto 0);
      variable mem : t_mem := (others => (others => '0'));
      variable a   : integer;
      variable w   : integer;
      variable refresh_cnt : integer := 0;
      variable v_rnw : std_logic;
      variable v_din : std_logic_vector(31 downto 0);
      variable v_be  : std_logic_vector(3 downto 0);
   begin
      wait until rising_edge(clkMem);
      refresh_cnt := refresh_cnt + 1;

      if (refresh_cnt = 740) then
         model_allow <= '0';
      end if;

      if (sdram_ena = '1') then
         a     := to_integer(unsigned(sdram_Adr));
         v_rnw := sdram_rnw;
         v_din := sdram_Din;
         v_be  := sdram_be;
         assert (a >= MAINRAM_BASE and a < MAINRAM_BASE + 4194304)
            report "sdram op outside main-RAM window: " & integer'image(a) severity failure;
         w := (a - MAINRAM_BASE) / 4;

         if (v_rnw = '1') then
            for k in 1 to 6 loop wait until rising_edge(clkMem); end loop;
            sdram_Dout   <= mem(w);
            sdram_done32 <= '1';
            wait until rising_edge(clkMem);
            sdram_done32 <= '0';
            for k in 1 to 3 loop wait until rising_edge(clkMem); end loop;
         else
            for k in 1 to 3 loop wait until rising_edge(clkMem); end loop;
            for j in 0 to 3 loop
               if (v_be(j) = '1') then
                  mem(w)(j*8 + 7 downto j*8) := v_din(j*8 + 7 downto j*8);
               end if;
            end loop;
            sdram_done32 <= '1';
            wait until rising_edge(clkMem);
            sdram_done32 <= '0';
            for k in 1 to 4 loop wait until rising_edge(clkMem); end loop;
         end if;
      elsif (refresh_cnt > 750) then
         for k in 1 to 6 loop
            wait until rising_edge(clkMem);
            assert sdram_ena = '0' report "sdram request during refresh slot" severity failure;
         end loop;
         refresh_cnt := 0;
         model_allow <= '1';
      end if;
   end process;

   -- ================= mailbox snoop + verdict =================
   p_snoop : process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (mr9_ena = '1' and mr9_rnw = '0') then
            if (mr9_addr = std_logic_vector(to_unsigned(16#FFFC0#, 20))) then
               mailbox_bits <= mr9_writedata;
               report "island progress: bitmask=" & to_hstring(mr9_writedata) severity note;
            elsif (mr9_addr = std_logic_vector(to_unsigned(16#FFFC1#, 20))) then
               if (mr9_writedata = x"CAFEBABE") then
                  report "tb_arm9_island: PASS  bitmask=" & to_hstring(mailbox_bits) severity note;
                  tests_done <= true;
               else
                  report "tb_arm9_island: FAIL magic=" & to_hstring(mr9_writedata) &
                         " bitmask=" & to_hstring(mailbox_bits) severity failure;
               end if;
            end if;
         end if;
         assert error_cpu /= '1' report "nds_cpu9 error_cpu pulse (unsupported opcode?)" severity failure;
      end if;
   end process;

   -- first CPU bus transactions, for bring-up debugging (silent after 64 ops)
   p_debug : process (clk1x)
      variable n : integer := 0;
   begin
      if rising_edge(clk1x) then
         if (cpu_ena = '1' and n < 64) then
            report "cpu op " & integer'image(n) & ": adr=" & to_hstring(cpu_adr) &
                   " rnw=" & to_string(cpu_rnw) & " acc=" & to_string(cpu_acc) &
                   " dout=" & to_hstring(cpu_dout) severity note;
            n := n + 1;
         end if;
         if (cpu_done = '1' and n <= 64 and n > 0) then
            report "   done: din=" & to_hstring(cpu_din) severity note;
         end if;
      end if;
   end process;

   p_watchdog : process
   begin
      wait for TIMEOUT_MS * 1 ms;
      if not tests_done then
         report "tb_arm9_island: TIMEOUT  bitmask=" & to_hstring(mailbox_bits) severity failure;
      end if;
      wait;
   end process;

end architecture;
