-- ARM9 differential-trace harness (roadmap M3 exit test). Same island as
-- tb_arm9_island but with the CPU's simulation export enabled: every retired
-- instruction appends one line to TRACEFILE:
--
--   <pc> <opcode> <cpsr> <r0> .. <r14>     (lowercase hex, space-separated)
--
-- pc is the pipeline PC (instruction address + 8 in ARM, + 4 in Thumb) —
-- the melonDS tracer patch (docs/TRACE_DIFF.md) emits the same tuple, and
-- sim/tests/compare_trace.py reports the first divergence.
-- Run: sim/run_arm9_trace.sh [MAXINSTR=n] [HEXFILE=...]

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.textio.all;

use work.pProc_bus_gba.all;
use work.pexport.all;

entity tb_arm9_trace is
   generic
   (
      HEXFILE    : string  := "sim/tests/arm9_island.hex";
      TRACEFILE  : string  := "arm9_trace.log";
      MAXINSTR   : integer := 1000000;
      TIMEOUT_MS : integer := 100;
      -- 0: HEXFILE is the boot ROM at 0xFFFF0000 (island style). Otherwise:
      -- load HEXFILE into main RAM at this address and boot from it
      -- (0x02000000 for the melonDS differential workloads).
      LOADADDR   : integer := 0;
      DBG_T0     : integer := 0;         -- TEMP DEBUG window start/end in ns (0 = off)
      DBG_T1     : integer := 0
   );
end entity;

architecture sim of tb_arm9_trace is

   constant MAINRAM_BASE : integer := 8388608;

   signal clk1x       : std_logic := '0';
   signal clkMem      : std_logic := '0';
   signal clkMemIndex : unsigned(1 downto 0) := "10";
   signal reset       : std_logic := '1';

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

   signal cpu_export_done : std_logic;
   signal cpu_export      : cpu_export_type;

   signal cp15_itcm_ena, cp15_itcm_load : std_logic;
   signal cp15_dtcm_ena, cp15_dtcm_load : std_logic;
   signal cp15_dtcm_base : std_logic_vector(31 downto 12);
   signal cp15_dtcm_size, cp15_itcm_size : std_logic_vector(4 downto 0);

   signal bus_cacheable_i, bus_cacheable_d : std_logic;
   signal cache_op_ena, cache_op_busy : std_logic;
   signal cache_op      : std_logic_vector(3 downto 0);
   signal cache_op_addr : std_logic_vector(31 downto 0);

   signal ss_bus : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');

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
      return mem;
   end function;
   impure function init_brom return t_brom is
      variable z : t_brom := (others => (others => '0'));
   begin
      if (LOADADDR = 0) then
         return load_hex(HEXFILE);
      end if;
      return z;
   end function;
   constant brom : t_brom := init_brom;

   function boot_pc return std_logic_vector is
   begin
      if (LOADADDR = 0) then
         return x"FFFF0000";
      end if;
      return std_logic_vector(to_unsigned(LOADADDR, 32));
   end function;
   signal brom_addr : unsigned(14 downto 2);
   signal brom_data : std_logic_vector(31 downto 0);

   type t_itcm is array (0 to 8191) of std_logic_vector(31 downto 0);
   type t_dtcm is array (0 to 4095) of std_logic_vector(31 downto 0);
   signal itcm : t_itcm := (others => (others => '0'));
   signal dtcm : t_dtcm := (others => (others => '0'));
   signal itcm_addr : unsigned(14 downto 2);
   signal itcm_we   : std_logic;
   signal itcm_be   : std_logic_vector(3 downto 0);
   signal itcm_writedata, itcm_readdata : std_logic_vector(31 downto 0);
   -- DTCM port A is the read port; the store is deferred onto port B
   signal dtcm_addr : unsigned(13 downto 2);
   signal dtcm_readdata : std_logic_vector(31 downto 0);
   signal dtcm_addr_b : unsigned(13 downto 2);
   signal dtcm_we_b   : std_logic;
   signal dtcm_be_b   : std_logic_vector(3 downto 0);
   signal dtcm_writedata_b : std_logic_vector(31 downto 0);

   signal wsh_ena, wsh_rnw, wsh_done, wsh_mapped : std_logic;
   signal wsh_addr : unsigned(14 downto 2);
   signal wsh_be   : std_logic_vector(3 downto 0);
   signal wsh_din, wsh_dout : std_logic_vector(31 downto 0);

   signal vram_ena, vram_rnw : std_logic;
   signal vram_addr : unsigned(23 downto 2);
   signal vram_be   : std_logic_vector(3 downto 0);
   signal vram_din  : std_logic_vector(31 downto 0);

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

   signal io_bus : proc_bus_gb_type;
   signal io_wired_out : std_logic_vector(31 downto 0);
   signal io_wired_done : std_logic;
   signal irq_wired_out, timer_wired_out : std_logic_vector(31 downto 0);
   signal irq_wired_done, timer_wired_done : std_logic;

   signal irq_in    : std_logic_vector(31 downto 0);
   signal irp_timer : std_logic_vector(3 downto 0);

   signal trace_done : boolean := false;
   signal time_up    : boolean := false;
   signal tests_done : boolean := false;

begin

   tests_done <= trace_done or time_up;

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

   p_boot : process
   begin
      ss_bus.rst <= '1';
      for k in 1 to 3 loop wait until rising_edge(clk1x); end loop;
      ss_bus.rst <= '0';
      wait until rising_edge(clk1x);
      ss_bus.Adr  <= (others => '0');
      ss_bus.Din  <= boot_pc;
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

   icpu : entity work.nds_cpu9
   generic map ( is_simu => '1' )
   port map
   (
      clk             => clk1x,
      ce              => '1',
      reset           => reset,
      cpu_export_done => cpu_export_done,
      cpu_export      => cpu_export,
      error_cpu       => error_cpu,
      dbg_pc          => open,
      dbg_r0          => open,
      dbg_lr          => open,
      dbg_cpsr        => open,
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
      cp15_itcm_size  => cp15_itcm_size,
      bus_cacheable_i => bus_cacheable_i,
      bus_cacheable_d => bus_cacheable_d,
      cache_op_ena    => cache_op_ena,
      cache_op        => cache_op,
      cache_op_addr   => cache_op_addr,
      cache_op_busy   => cache_op_busy
   );

   imembus : entity work.nds_membus9
   generic map ( is_simu => '1' )
   port map
   (
      clk => clk1x, reset => reset,
      bus_cacheable_i => bus_cacheable_i, bus_cacheable_d => bus_cacheable_d,
      cache_op_ena => cache_op_ena, cache_op => cache_op,
      cache_op_addr => cache_op_addr, cache_op_busy => cache_op_busy,
      itcm_ena => cp15_itcm_ena, itcm_load => cp15_itcm_load, itcm_size => cp15_itcm_size,
      dtcm_ena => cp15_dtcm_ena, dtcm_load => cp15_dtcm_load,
      dtcm_base => cp15_dtcm_base, dtcm_size => cp15_dtcm_size,
      cpu_adr => cpu_adr, cpu_rnw => cpu_rnw, cpu_ena => cpu_ena, cpu_code => cpu_code,
      cpu_acc => cpu_acc, cpu_dout => cpu_dout, cpu_lowbits => cpu_lowbits,
      cpu_lastread => cpu_lastread, cpu_din => cpu_din, cpu_done => cpu_done,
      itcm_addr => itcm_addr, itcm_we => itcm_we, itcm_be => itcm_be,
      itcm_writedata => itcm_writedata, itcm_readdata => itcm_readdata,
      dtcm_addr => dtcm_addr, dtcm_readdata => dtcm_readdata,
      dtcm_addr_b => dtcm_addr_b, dtcm_we_b => dtcm_we_b,
      dtcm_be_b => dtcm_be_b, dtcm_writedata_b => dtcm_writedata_b,
      brom_addr => brom_addr, brom_data => brom_data,
      wsh_ena => wsh_ena, wsh_rnw => wsh_rnw, wsh_addr => wsh_addr, wsh_be => wsh_be,
      wsh_din => wsh_din, wsh_dout => wsh_dout, wsh_done => wsh_done, wsh_mapped => wsh_mapped,
      vram_ena => vram_ena, vram_rnw => vram_rnw, vram_addr => vram_addr, vram_be => vram_be,
      vram_din => vram_din, vram_dout => (others => '0'), vram_done => '0',
      mr_ena => mr9_ena, mr_rnw => mr9_rnw, mr_addr => mr9_addr, mr_be => mr9_be,
      mr_writedata => mr9_writedata, mr_done => mr9_done, mr_readdata => mr9_readdata,
      io_bus => io_bus, io_wired_out => io_wired_out, io_wired_done => io_wired_done
   );

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
         if (dtcm_we_b = '1') then
            for i in 0 to 3 loop
               if (dtcm_be_b(i) = '1') then
                  dtcm(to_integer(dtcm_addr_b))(i*8 + 7 downto i*8) <= dtcm_writedata_b(i*8 + 7 downto i*8);
               end if;
            end loop;
         end if;
         -- sync-read store model (matches the M10K in nds_top; the membus
         -- presents the address combinationally in the accept cycle)
         itcm_readdata <= itcm(to_integer(itcm_addr));
         dtcm_readdata <= dtcm(to_integer(dtcm_addr));
      end if;
   end process;

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

   iwram : entity work.nds_wram
   generic map ( is_simu => '1' )
   port map
   (
      clk => clk1x, wramcnt => "00",
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

   psdram : process
      type t_mem is array (0 to 1048575) of std_logic_vector(31 downto 0);
      impure function init_mem return t_mem is
         file f       : text;
         variable l   : line;
         variable w   : std_logic_vector(31 downto 0);
         variable m   : t_mem := (others => (others => '0'));
         variable i   : integer;
      begin
         if (LOADADDR /= 0) then
            i := (LOADADDR mod 4194304) / 4;
            file_open(f, HEXFILE, read_mode);
            while not endfile(f) loop
               readline(f, l);
               hread(l, w);
               m(i) := w;
               i := i + 1;
            end loop;
            file_close(f);
         end if;
         return m;
      end function;
      variable mem : t_mem := init_mem;
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
         for k in 1 to 6 loop wait until rising_edge(clkMem); end loop;
         refresh_cnt := 0;
         model_allow <= '1';
      end if;
   end process;

   -- ================= trace writer =================
   p_trace : process
      file tf     : text;
      variable l  : line;
      variable n  : integer := 0;
   begin
      file_open(tf, TRACEFILE, write_mode);
      loop
         wait until rising_edge(clk1x);
         if (cpu_export_done = '1') then
            write(l, to_hstring(cpu_export.pc));
            write(l, ' ');
            write(l, to_hstring(cpu_export.opcode));
            write(l, ' ');
            write(l, to_hstring(cpu_export.CPSR));
            for i in 0 to 14 loop
               write(l, ' ');
               write(l, to_hstring(cpu_export.regs(i)));
            end loop;
            writeline(tf, l);
            n := n + 1;
            if (n mod 100000 = 0) then
               report "traced " & integer'image(n) & " instructions" severity note;
            end if;
            if (n >= MAXINSTR) then
               report "tb_arm9_trace: DONE  instructions=" & integer'image(n) severity note;
               file_close(tf);
               trace_done <= true;
               wait;
            end if;
         end if;
      end loop;
   end process;

   p_watchdog : process
   begin
      wait for TIMEOUT_MS * 1 ms;
      if not trace_done then
         report "tb_arm9_trace: sim time limit reached (trace is still valid)" severity note;
      end if;
      time_up <= true;
      wait;
   end process;

   -- Pipeline debug: per-cycle dump of the CPU's fetch/decode/execute
   -- handshake between DBG_T0 and DBG_T1 (ns) into pipe_debug.log, via
   -- external names. Off by default (DBG_T1=0); this is how the ldm^
   -- bank-swap bug (sim/tests/ldm_bx_irq) was localized.
   gdbg : if DBG_T1 > 0 generate
      pdbg : process (clk1x)
         file df : text open write_mode is "pipe_debug.log";
         variable l : line;
         alias a_fetch_PC     is << signal .tb_arm9_trace.icpu.fetch_PC       : unsigned(31 downto 0) >>;
         alias a_fetch_ready  is << signal .tb_arm9_trace.icpu.fetch_ready    : std_logic >>;
         alias a_fetch_done   is << signal .tb_arm9_trace.icpu.fetch_done     : std_logic >>;
         alias a_dec_ready    is << signal .tb_arm9_trace.icpu.decode_ready   : std_logic >>;
         alias a_dec_PC       is << signal .tb_arm9_trace.icpu.decode_PC      : unsigned(31 downto 0) >>;
         alias a_ex_branch    is << signal .tb_arm9_trace.icpu.execute_branch : std_logic >>;
         alias a_ex_done      is << signal .tb_arm9_trace.icpu.execute_done   : std_logic >>;
         alias a_ex_stall     is << signal .tb_arm9_trace.icpu.execute_stall  : std_logic >>;
         alias a_ex_now       is << signal .tb_arm9_trace.icpu.execute_now    : std_logic >>;
         alias a_bus_ena      is << signal .tb_arm9_trace.icpu.gb_bus_ena     : std_logic >>;
         alias a_bus_done     is << signal .tb_arm9_trace.icpu.gb_bus_done    : std_logic >>;
         alias a_bus_adr      is << signal .tb_arm9_trace.icpu.gb_bus_Adr     : std_logic_vector(31 downto 0) >>;
         alias a_branchPC     is << signal .tb_arm9_trace.icpu.execute_branchPC_masked : unsigned(31 downto 0) >>;
         alias a_fdata        is << signal .tb_arm9_trace.icpu.fetch_data     : std_logic_vector(31 downto 0) >>;
         alias a_mode         is << signal .tb_arm9_trace.icpu.cpu_mode       : std_logic_vector(3 downto 0) >>;
         alias a_msr_ena      is << signal .tb_arm9_trace.icpu.execute_msr_setvalue_ena : std_logic >>;
         alias a_msr_val      is << signal .tb_arm9_trace.icpu.execute_msr_setvalue : unsigned(31 downto 0) >>;
         alias a_sw_now       is << signal .tb_arm9_trace.icpu.execute_switchmode_now : std_logic >>;
         alias a_sw_new       is << signal .tb_arm9_trace.icpu.execute_switchmode_new : std_logic_vector(3 downto 0) >>;
      begin
         if rising_edge(clk1x) then
            if now >= DBG_T0 * 1 ns and now <= DBG_T1 * 1 ns then
               write(l, to_hstring(a_dec_PC) & " fPC=" & to_hstring(a_fetch_PC) &
                        " fdat=" & to_hstring(a_fdata) &
                        " fr=" & std_logic'image(a_fetch_ready)(2) &
                        " fd=" & std_logic'image(a_fetch_done)(2) &
                        " dr=" & std_logic'image(a_dec_ready)(2) &
                        " en=" & std_logic'image(a_ex_now)(2) &
                        " br=" & std_logic'image(a_ex_branch)(2) &
                        " ed=" & std_logic'image(a_ex_done)(2) &
                        " st=" & std_logic'image(a_ex_stall)(2) &
                        " be=" & std_logic'image(a_bus_ena)(2) &
                        " bd=" & std_logic'image(a_bus_done)(2) &
                        " ba=" & to_hstring(a_bus_adr) &
                        " tgt=" & to_hstring(a_branchPC) &
                        " md=" & to_hstring(a_mode) &
                        " me=" & std_logic'image(a_msr_ena)(2) &
                        " mv=" & to_hstring(a_msr_val) &
                        " sn=" & std_logic'image(a_sw_now)(2) &
                        " nw=" & to_hstring(a_sw_new));
               writeline(df, l);
            end if;
         end if;
      end process;
   end generate;

end architecture;
