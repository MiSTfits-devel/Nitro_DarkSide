-- M4 exit test: dual-CPU boot through the card-header HLE loader.
--
-- nds_loader parses sim/tests/nds_dual.hex (a minimal .nds image, see
-- build_nds_dual.sh) from a behavioral card store and copies both sections
-- into main RAM while the CPUs are held in reset; the testbench then presets
-- each boot PC from the reported entry points through the savestate buses and
-- releases them. Both CPUs run against the shared fabric: nds_mainram (one
-- port each), nds_wram steered by syscnt's WRAMCNT, nds_ipc (SYNC + FIFO),
-- nds_syscnt (EXMEMCNT/WRAMCNT), per-CPU timers and IRQ.
--
-- Both CPUs run at the full clk1x rate (ce='1', io_ce_next='1'): gba_cpu only
-- samples gb_bus_done on ce cycles, so half-rate ARM7 pacing against the
-- full-rate membus needs the done-alignment that nds_top will own (M9); this
-- test is about functional dual-boot, not pacing.
--
-- Verdict comes from the mailbox both programs keep in the uncached main-RAM
-- mirror: ARM9 bitmask/magic at 0x02FFFF00/04, ARM7 bitmask/done at
-- 0x02FFFF10/14. PASS = ARM9 writes 0xCAFEBABE (it waits for the ARM7's
-- 0xBEEF7777 first). Run: sim/run_dual_boot.sh

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.textio.all;

use work.pProc_bus_gba.all;

entity tb_dual_boot is
   generic
   (
      HEXFILE    : string  := "sim/tests/nds_dual.hex";
      TIMEOUT_MS : integer := 10
   );
end entity;

architecture sim of tb_dual_boot is

   constant MAINRAM_BASE : integer := 8388608;

   signal clk1x       : std_logic := '0';
   signal clkMem      : std_logic := '0';
   signal clkMemIndex : unsigned(1 downto 0) := "10";
   signal reset       : std_logic := '1';   -- fabric + loader
   signal resetCpu    : std_logic := '1';   -- both CPUs, held until loaded

   -- ================= card store + loader =================
   type t_card is array (0 to 16383) of std_logic_vector(31 downto 0);
   impure function load_hex(fname : string) return t_card is
      file f       : text;
      variable l   : line;
      variable w   : std_logic_vector(31 downto 0);
      variable mem : t_card := (others => (others => '0'));
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
      report "loaded " & integer'image(i) & " card words from " & fname severity note;
      return mem;
   end function;
   constant card : t_card := load_hex(HEXFILE);

   signal ld_start, ld_busy, ld_done, ld_error : std_logic;
   signal arm9_entry, arm7_entry, ld_cartid : std_logic_vector(31 downto 0);
   signal card_ena, card_done : std_logic := '0';
   signal card_addr  : std_logic_vector(26 downto 2);
   signal card_rdata : std_logic_vector(31 downto 0) := (others => '0');
   signal ld_wr_ena  : std_logic;
   signal ld_wr_rnw  : std_logic;
   signal ld_vfy_bad : std_logic_vector(17 downto 0);
   signal ld_vfy_addr : std_logic_vector(31 downto 0);
   signal ld_wr_addr, ld_wr_data : std_logic_vector(31 downto 0);

   -- ================= ARM9 side =================
   signal cpu9_adr      : std_logic_vector(31 downto 0);
   signal cpu9_rnw, cpu9_ena, cpu9_code, cpu9_done, cpu9_lock : std_logic;
   signal cpu9_acc      : std_logic_vector(1 downto 0);
   signal cpu9_dout, cpu9_din, cpu9_lastread : std_logic_vector(31 downto 0);
   signal cpu9_lowbits  : std_logic_vector(1 downto 0);
   signal error_cpu9    : std_logic;
   signal cpu9_irq, cpu9_unhalt : std_logic;

   signal cp15_itcm_ena, cp15_itcm_load : std_logic;
   signal cp15_dtcm_ena, cp15_dtcm_load : std_logic;
   signal cp15_dtcm_base : std_logic_vector(31 downto 12);
   signal cp15_dtcm_size, cp15_itcm_size : std_logic_vector(4 downto 0);
   signal bus_cacheable_i, bus_cacheable_d : std_logic;
   signal cache_op_ena, cache_op_busy : std_logic;
   signal cache_op      : std_logic_vector(3 downto 0);
   signal cache_op_addr : std_logic_vector(31 downto 0);

   signal ss_bus9 : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');
   signal ss_bus7 : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');

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

   signal brom_addr : unsigned(14 downto 2);

   signal wsh9_ena, wsh9_rnw, wsh9_done, wsh9_mapped : std_logic;
   signal wsh9_addr : unsigned(14 downto 2);
   signal wsh9_be   : std_logic_vector(3 downto 0);
   signal wsh9_din, wsh9_dout : std_logic_vector(31 downto 0);

   signal vram9_ena, vram9_rnw : std_logic;
   signal vram9_addr : unsigned(23 downto 2);
   signal vram9_be   : std_logic_vector(3 downto 0);
   signal vram9_din  : std_logic_vector(31 downto 0);

   signal mr9_ena, mr9_rnw, mr9_done : std_logic;
   signal mr9_addr : std_logic_vector(21 downto 2);
   signal mr9_be   : std_logic_vector(3 downto 0);
   signal mr9_writedata, mr9_readdata : std_logic_vector(31 downto 0);

   signal io_bus9 : proc_bus_gb_type;
   signal io_wired_out9, irq_wired_out9, timer_wired_out9 : std_logic_vector(31 downto 0);
   signal io_wired_done9, irq_wired_done9, timer_wired_done9 : std_logic;
   signal ipc_wired_out9, sys_wired_out9 : std_logic_vector(31 downto 0);
   signal ipc_wired_done9, sys_wired_done9 : std_logic;
   signal irq_in9    : std_logic_vector(31 downto 0);
   signal irp_timer9 : std_logic_vector(3 downto 0);
   signal ipc9_irq_sync, ipc9_irq_sendempty, ipc9_irq_recv : std_logic;

   -- ================= ARM7 side =================
   signal cpu7_adr      : std_logic_vector(31 downto 0);
   signal cpu7_rnw, cpu7_ena, cpu7_done, cpu7_lock : std_logic;
   signal cpu7_acc      : std_logic_vector(1 downto 0);
   signal cpu7_dout, cpu7_din, cpu7_lastread : std_logic_vector(31 downto 0);
   signal cpu7_lowbits  : std_logic_vector(1 downto 0);
   signal error_cpu7    : std_logic;
   signal cpu7_irq, cpu7_unhalt : std_logic;

   signal bios_addr : unsigned(13 downto 2);

   type t_wram7 is array (0 to 16383) of std_logic_vector(31 downto 0);
   signal wram7 : t_wram7 := (others => (others => '0'));
   signal w7p_addr      : unsigned(15 downto 2);
   signal w7p_we        : std_logic;
   signal w7p_be        : std_logic_vector(3 downto 0);
   signal w7p_writedata, w7p_readdata : std_logic_vector(31 downto 0);

   signal wsh7_ena, wsh7_rnw, wsh7_done, wsh7_mapped : std_logic;
   signal wsh7_addr : unsigned(14 downto 2);
   signal wsh7_be   : std_logic_vector(3 downto 0);
   signal wsh7_din, wsh7_dout : std_logic_vector(31 downto 0);

   signal vram7_ena, vram7_rnw : std_logic;
   signal vram7_addr : unsigned(23 downto 2);
   signal vram7_be   : std_logic_vector(3 downto 0);
   signal vram7_din  : std_logic_vector(31 downto 0);

   signal mr7_ena, mr7_rnw, mr7_done : std_logic;
   signal mr7_addr : std_logic_vector(21 downto 2);
   signal mr7_be   : std_logic_vector(3 downto 0);
   signal mr7_writedata, mr7_readdata : std_logic_vector(31 downto 0);

   signal io_bus7 : proc_bus_gb_type;
   signal io_wired_out7, irq_wired_out7, timer_wired_out7 : std_logic_vector(31 downto 0);
   signal io_wired_done7, irq_wired_done7, timer_wired_done7 : std_logic;
   signal ipc_wired_out7, sys_wired_out7 : std_logic_vector(31 downto 0);
   signal ipc_wired_done7, sys_wired_done7 : std_logic;
   signal irq_in7    : std_logic_vector(31 downto 0);
   signal irp_timer7 : std_logic_vector(3 downto 0);
   signal ipc7_irq_sync, ipc7_irq_sendempty, ipc7_irq_recv : std_logic;

   -- ================= shared fabric =================
   signal wramcnt : std_logic_vector(1 downto 0);
   signal exmem_prio7 : std_logic;

   -- main RAM port 9 = loader (while busy) / membus9 mux
   signal mem9_ena, mem9_rnw, mem9_done : std_logic;
   signal mem9_addr : std_logic_vector(21 downto 2);
   signal mem9_be   : std_logic_vector(3 downto 0);
   signal mem9_writedata, mem9_readdata : std_logic_vector(31 downto 0);

   signal mainram_active, mainram_busy : std_logic;
   signal model_allow : std_logic := '1';
   signal sdram_ena, sdram_rnw : std_logic := '0';
   signal sdram_Adr : std_logic_vector(26 downto 0);
   signal sdram_Din : std_logic_vector(31 downto 0);
   signal sdram_be  : std_logic_vector(3 downto 0);
   signal sdram_Dout : std_logic_vector(31 downto 0) := (others => '0');
   signal sdram_done32 : std_logic := '0';

   signal mailbox9, mailbox7 : std_logic_vector(31 downto 0) := (others => '0');
   signal tests_done : boolean := false;

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

   -- ================= boot sequencing =================
   -- fabric out of reset -> loader runs -> preset both boot PCs -> CPUs go
   p_boot : process
      procedure preset_pc(signal bus_ss : inout proc_bus_gb_type;
                          entry         : in std_logic_vector(31 downto 0)) is
      begin
         bus_ss.rst <= '1';
         for k in 1 to 3 loop wait until rising_edge(clk1x); end loop;
         bus_ss.rst <= '0';
         wait until rising_edge(clk1x);
         bus_ss.Adr  <= (others => '0'); -- REG_SAVESTATE_PC
         bus_ss.Din  <= entry;
         bus_ss.rnw  <= '0';
         bus_ss.bEna <= "1111";
         bus_ss.ena  <= '1';
         wait until rising_edge(clk1x);
         bus_ss.ena  <= '0';
         bus_ss.rnw  <= '1';
         for k in 1 to 3 loop wait until rising_edge(clk1x); end loop;
      end procedure;
   begin
      ld_start <= '0';
      for k in 1 to 8 loop wait until rising_edge(clk1x); end loop;
      reset <= '0';
      wait until rising_edge(clk1x);
      ld_start <= '1';
      wait until rising_edge(clk1x);
      ld_start <= '0';
      wait until rising_edge(clk1x) and ld_busy = '0';
      assert ld_error = '0' report "nds_loader flagged load_error" severity failure;
      assert ld_done  = '1' report "nds_loader neither done nor error" severity failure;
      -- The behavioural SDRAM here is perfect, so the loader's post-copy verify
      -- must come back clean. A non-zero count in simulation means the verify
      -- logic itself is wrong (addressing, rd_data timing), which would make it
      -- useless as a hardware measurement - so gate on it here.
      assert unsigned(ld_vfy_bad) = 0
         report "loader main-RAM verify reported " & to_hstring(ld_vfy_bad) &
                " mismatches, first at " & to_hstring(ld_vfy_addr) &
                " - the verify pass itself is suspect" severity failure;
      report "loader done: arm9_entry=" & to_hstring(arm9_entry) &
             " arm7_entry=" & to_hstring(arm7_entry) &
             " verify clean" severity note;
      preset_pc(ss_bus9, arm9_entry);
      preset_pc(ss_bus7, arm7_entry);
      resetCpu <= '0';
      wait;
   end process;

   -- ================= loader + card store =================
   iloader : entity work.nds_loader
   port map
   (
      clk => clk1x, reset => reset,
      start => ld_start, busy => ld_busy, done => ld_done, load_error => ld_error,
      direct => '1',
      arm9_entry => arm9_entry, arm7_entry => arm7_entry, cart_id => ld_cartid,
      card_ena => card_ena, card_addr => card_addr,
      card_done => card_done, card_rdata => card_rdata,
      wr_ena => ld_wr_ena, wr_rnw => ld_wr_rnw,
      wr_addr => ld_wr_addr, wr_data => ld_wr_data,
      wr_done => mem9_done, rd_data => mem9_readdata,
      vfy_bad => ld_vfy_bad, vfy_addr => ld_vfy_addr
   );

   p_card : process (clk1x)
   begin
      if rising_edge(clk1x) then
         card_done <= '0';
         if (card_ena = '1') then
            -- Exercise the direct-boot chip-ID calculation with Kirby's
            -- actual used-ROM-size header word (0x03159E2C -> 64 MiB
            -- power-of-two envelope -> chip ID 0x00003FC2).
            if (unsigned(card_addr) = 16#20#) then
               card_rdata <= x"03159E2C";
            else
               card_rdata <= card(to_integer(unsigned(card_addr(15 downto 2))));
            end if;
            card_done  <= '1';
         end if;
      end if;
   end process;

   -- loader owns the main-RAM port 9 while busy; both targets (ARM9 at
   -- 0x02000000, ARM7 at 0x02380000) live in main RAM for this image
   mem9_ena       <= ld_wr_ena when ld_busy = '1' else mr9_ena;
   -- mirrors nds_top: the loader's verify pass drives wr_rnw='1' to read main
   -- RAM back, so this must follow it rather than forcing a write
   mem9_rnw       <= ld_wr_rnw when ld_busy = '1' else mr9_rnw;
   mem9_addr      <= ld_wr_addr(21 downto 2) when ld_busy = '1' else mr9_addr;
   mem9_be        <= "1111"    when ld_busy = '1' else mr9_be;
   mem9_writedata <= ld_wr_data when ld_busy = '1' else mr9_writedata;
   mr9_done       <= mem9_done and not ld_busy;
   mr9_readdata   <= mem9_readdata;

   p_ldcheck : process (clk1x)
   begin
      if rising_edge(clk1x) then
         -- only real writes are checked; the verify pass reuses this port with
         -- wr_rnw='1' for read-back and leaves wr_data holding a stale word
         assert not (ld_wr_ena = '1' and ld_wr_rnw = '0' and ld_wr_addr(31 downto 24) /= x"02")
            report "loader write outside main RAM: " & to_hstring(ld_wr_addr) severity failure;
         if (ld_wr_ena = '1' and ld_wr_rnw = '0' and ld_wr_addr = x"02FFF800") then
            assert ld_wr_data = x"00003FC2"
               report "loader direct-boot cartridge ID mismatch: " &
                      to_hstring(ld_wr_data) severity failure;
            -- the exported cart_id feeds nds_card's B8 answer in nds_top, so
            -- it has to be the same word that lands in the env block
            assert ld_wr_data = ld_cartid
               report "cart_id " & to_hstring(ld_cartid) & " disagrees with the " &
                      "env-block chip ID " & to_hstring(ld_wr_data) severity failure;
         end if;
      end if;
   end process;

   -- ================= ARM9 CPU + membus =================
   icpu9 : entity work.nds_cpu9
   generic map ( is_simu => '0' )
   port map
   (
      clk             => clk1x,
      ce              => '1',
      reset           => resetCpu,
      cpu_export_done => open,
      cpu_export      => open,
      error_cpu       => error_cpu9,
      dbg_pc          => open,
      dbg_r0          => open,
      dbg_lr          => open,
      dbg_cpsr        => open,
      savestate_bus   => ss_bus9,
      ss_wired_out    => open,
      ss_wired_done   => open,
      gb_bus_Adr      => cpu9_adr,
      gb_bus_rnw      => cpu9_rnw,
      gb_bus_ena      => cpu9_ena,
      gb_bus_seq      => open,
      gb_bus_code     => cpu9_code,
      gb_bus_acc      => cpu9_acc,
      gb_bus_dout     => cpu9_dout,
      gb_bus_din      => cpu9_din,
      gb_bus_done     => cpu9_done,
      gb_bus_lock     => cpu9_lock,
      bus_lowbits     => cpu9_lowbits,
      dma_on          => '0',
      done            => open,
      CPU_bus_idle    => open,
      PC_in_BIOS      => open,
      cpu_halt        => open,
      lastread        => cpu9_lastread,
      jump_out        => open,
      IRQ_in          => cpu9_irq,
      unhalt          => cpu9_unhalt,
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

   imembus9 : entity work.nds_membus9
   generic map ( is_simu => '1' )
   port map
   (
      clk => clk1x, reset => resetCpu,
      bus_cacheable_i => bus_cacheable_i, bus_cacheable_d => bus_cacheable_d,
      cache_op_ena => cache_op_ena, cache_op => cache_op,
      cache_op_addr => cache_op_addr, cache_op_busy => cache_op_busy,
      itcm_ena => cp15_itcm_ena, itcm_load => cp15_itcm_load, itcm_size => cp15_itcm_size,
      dtcm_ena => cp15_dtcm_ena, dtcm_load => cp15_dtcm_load,
      dtcm_base => cp15_dtcm_base, dtcm_size => cp15_dtcm_size,
      cpu_adr => cpu9_adr, cpu_rnw => cpu9_rnw, cpu_ena => cpu9_ena, cpu_code => cpu9_code,
      cpu_acc => cpu9_acc, cpu_dout => cpu9_dout, cpu_lowbits => cpu9_lowbits,
      cpu_lastread => cpu9_lastread, cpu_din => cpu9_din, cpu_done => cpu9_done,
      itcm_addr => itcm_addr, itcm_we => itcm_we, itcm_be => itcm_be,
      itcm_writedata => itcm_writedata, itcm_readdata => itcm_readdata,
      dtcm_addr => dtcm_addr, dtcm_we => dtcm_we, dtcm_be => dtcm_be,
      dtcm_writedata => dtcm_writedata, dtcm_readdata => dtcm_readdata,
      brom_addr => brom_addr, brom_data => x"00000000",
      wsh_ena => wsh9_ena, wsh_rnw => wsh9_rnw, wsh_addr => wsh9_addr, wsh_be => wsh9_be,
      wsh_din => wsh9_din, wsh_dout => wsh9_dout, wsh_done => wsh9_done, wsh_mapped => wsh9_mapped,
      vram_ena => vram9_ena, vram_rnw => vram9_rnw, vram_addr => vram9_addr, vram_be => vram9_be,
      vram_din => vram9_din, vram_dout => (others => '0'), vram_done => '0',
      mr_ena => mr9_ena, mr_rnw => mr9_rnw, mr_addr => mr9_addr, mr_be => mr9_be,
      mr_writedata => mr9_writedata, mr_done => mr9_done, mr_readdata => mr9_readdata,
      io_ce_next => '1',
      io_bus => io_bus9, io_wired_out => io_wired_out9, io_wired_done => io_wired_done9
   );

   -- TCM stores
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
         -- sync-read store model (matches the M10K in nds_top; the membus
         -- presents the address combinationally in the accept cycle)
         itcm_readdata <= itcm(to_integer(itcm_addr));
         dtcm_readdata <= dtcm(to_integer(dtcm_addr));
      end if;
   end process;

   -- ================= ARM7 CPU + membus =================
   icpu7 : entity work.gba_cpu
   generic map ( is_simu => '0' )
   port map
   (
      clk             => clk1x,
      ce              => '1',
      reset           => resetCpu,
      cpu_export_done => open,
      cpu_export      => open,
      error_cpu       => error_cpu7,
      dbg_pc          => open,
      savestate_bus   => ss_bus7,
      ss_wired_out    => open,
      ss_wired_done   => open,
      gb_bus_Adr      => cpu7_adr,
      gb_bus_rnw      => cpu7_rnw,
      gb_bus_ena      => cpu7_ena,
      gb_bus_seq      => open,
      gb_bus_code     => open,
      gb_bus_acc      => cpu7_acc,
      gb_bus_dout     => cpu7_dout,
      gb_bus_din      => cpu7_din,
      gb_bus_done     => cpu7_done,
      gb_bus_lock     => cpu7_lock,
      bus_lowbits     => cpu7_lowbits,
      dma_on          => '0',
      done            => open,
      CPU_bus_idle    => open,
      PC_in_BIOS      => open,
      cpu_halt        => open,
      lastread        => cpu7_lastread,
      jump_out        => open,
      IRQ_in          => cpu7_irq,
      unhalt          => cpu7_unhalt,
      new_halt        => '0'
   );

   imembus7 : entity work.nds_membus7
   port map
   (
      clk => clk1x, reset => resetCpu,
      cpu_adr => cpu7_adr, cpu_rnw => cpu7_rnw, cpu_ena => cpu7_ena, cpu_acc => cpu7_acc,
      cpu_dout => cpu7_dout, cpu_lowbits => cpu7_lowbits, cpu_lastread => cpu7_lastread,
      cpu_din => cpu7_din, cpu_done => cpu7_done,
      bios_addr => bios_addr, bios_data => x"00000000",
      w7p_addr => w7p_addr, w7p_we => w7p_we, w7p_be => w7p_be,
      w7p_writedata => w7p_writedata, w7p_readdata => w7p_readdata,
      wsh_ena => wsh7_ena, wsh_rnw => wsh7_rnw, wsh_addr => wsh7_addr, wsh_be => wsh7_be,
      wsh_din => wsh7_din, wsh_dout => wsh7_dout, wsh_done => wsh7_done, wsh_mapped => wsh7_mapped,
      vram_ena => vram7_ena, vram_rnw => vram7_rnw, vram_addr => vram7_addr, vram_be => vram7_be,
      vram_din => vram7_din, vram_dout => (others => '0'), vram_done => '0',
      mr_ena => mr7_ena, mr_rnw => mr7_rnw, mr_addr => mr7_addr, mr_be => mr7_be,
      mr_writedata => mr7_writedata, mr_done => mr7_done, mr_readdata => mr7_readdata,
      io_ce_next => '1',
      io_bus => io_bus7, io_wired_out => io_wired_out7, io_wired_done => io_wired_done7
   );

   -- ARM7-private WRAM store (sync-read model, matches the M10K in nds_top)
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (w7p_we = '1') then
            for i in 0 to 3 loop
               if (w7p_be(i) = '1') then
                  wram7(to_integer(w7p_addr))(i*8 + 7 downto i*8) <= w7p_writedata(i*8 + 7 downto i*8);
               end if;
            end loop;
         end if;
         w7p_readdata <= wram7(to_integer(w7p_addr));
      end if;
   end process;

   -- ================= IO register banks =================
   io_wired_out9  <= irq_wired_out9 or timer_wired_out9 or ipc_wired_out9 or sys_wired_out9;
   io_wired_done9 <= irq_wired_done9 or timer_wired_done9 or ipc_wired_done9 or sys_wired_done9;
   io_wired_out7  <= irq_wired_out7 or timer_wired_out7 or ipc_wired_out7 or sys_wired_out7;
   io_wired_done7 <= irq_wired_done7 or timer_wired_done7 or ipc_wired_done7 or sys_wired_done7;

   irq_in9 <= (3 => irp_timer9(0), 4 => irp_timer9(1), 5 => irp_timer9(2), 6 => irp_timer9(3),
               16 => ipc9_irq_sync, 17 => ipc9_irq_sendempty, 18 => ipc9_irq_recv,
               others => '0');
   irq_in7 <= (3 => irp_timer7(0), 4 => irp_timer7(1), 5 => irp_timer7(2), 6 => irp_timer7(3),
               16 => ipc7_irq_sync, 17 => ipc7_irq_sendempty, 18 => ipc7_irq_recv,
               others => '0');

   iirq9 : entity work.nds_irq
   port map
   (
      clk => clk1x, ce => '1', reset => resetCpu,
      gb_bus => io_bus9, wired_out => irq_wired_out9, wired_done => irq_wired_done9,
      irq_in => irq_in9, cpu_irq => cpu9_irq, cpu_unhalt => cpu9_unhalt
   );

   iirq7 : entity work.nds_irq
   port map
   (
      clk => clk1x, ce => '1', reset => resetCpu,
      gb_bus => io_bus7, wired_out => irq_wired_out7, wired_done => irq_wired_done7,
      irq_in => irq_in7, cpu_irq => cpu7_irq, cpu_unhalt => cpu7_unhalt
   );

   itimer9 : entity work.gba_timer
   generic map ( is_simu => '0' )
   port map
   (
      clk => clk1x, ce => '1', reset => resetCpu,
      savestate_bus => ss_bus9, ss_wired_out => open, ss_wired_done => open,
      loading_savestate => '0',
      gb_bus => io_bus9, wired_out => timer_wired_out9, wired_done => timer_wired_done9,
      IRP_Timer => irp_timer9,
      timer0_tick => open, timer1_tick => open,
      debugout0 => open, debugout1 => open, debugout2 => open, debugout3 => open
   );

   itimer7 : entity work.gba_timer
   generic map ( is_simu => '0' )
   port map
   (
      clk => clk1x, ce => '1', reset => resetCpu,
      savestate_bus => ss_bus7, ss_wired_out => open, ss_wired_done => open,
      loading_savestate => '0',
      gb_bus => io_bus7, wired_out => timer_wired_out7, wired_done => timer_wired_done7,
      IRP_Timer => irp_timer7,
      timer0_tick => open, timer1_tick => open,
      debugout0 => open, debugout1 => open, debugout2 => open, debugout3 => open
   );

   iipc : entity work.nds_ipc
   port map
   (
      clk => clk1x, reset => resetCpu,
      bus7 => io_bus7, wired_out7 => ipc_wired_out7, wired_done7 => ipc_wired_done7,
      irq7_sync => ipc7_irq_sync, irq7_sendempty => ipc7_irq_sendempty, irq7_recv => ipc7_irq_recv,
      bus9 => io_bus9, wired_out9 => ipc_wired_out9, wired_done9 => ipc_wired_done9,
      irq9_sync => ipc9_irq_sync, irq9_sendempty => ipc9_irq_sendempty, irq9_recv => ipc9_irq_recv
   );

   isyscnt : entity work.nds_syscnt
   port map
   (
      clk => clk1x, reset => resetCpu,
      bus9 => io_bus9, wired_out9 => sys_wired_out9, wired_done9 => sys_wired_done9,
      bus7 => io_bus7, wired_out7 => sys_wired_out7, wired_done7 => sys_wired_done7,
      wramcnt => wramcnt,
      exmem_gba7 => open, exmem_card7 => open, exmem_prio7 => exmem_prio7
   );

   -- ================= shared memory fabric =================
   iwram : entity work.nds_wram
   generic map ( is_simu => '1' )
   port map
   (
      clk => clk1x, wramcnt => wramcnt,
      arm9_ena => wsh9_ena, arm9_rnw => wsh9_rnw, arm9_addr => wsh9_addr, arm9_be => wsh9_be,
      arm9_din => wsh9_din, arm9_dout => wsh9_dout, arm9_done => wsh9_done, arm9_mapped => wsh9_mapped,
      arm7_ena => wsh7_ena, arm7_rnw => wsh7_rnw, arm7_addr => wsh7_addr, arm7_be => wsh7_be,
      arm7_din => wsh7_din, arm7_dout => wsh7_dout, arm7_done => wsh7_done, arm7_mapped => wsh7_mapped
   );

   imainram : entity work.nds_mainram
   generic map ( Softmap_NDS_MAINRAM_ADDR => MAINRAM_BASE )
   port map
   (
      clk1x => clk1x, clkMem => clkMem, clkMemIndex => clkMemIndex, reset => reset,
      arm7_priority => exmem_prio7,
      mem9_ena => mem9_ena,
      mem9_lock => cpu9_lock and not bus_cacheable_d and not ld_busy,
      mem9_rnw => mem9_rnw, mem9_addr => mem9_addr, mem9_be => mem9_be,
      mem9_writedata => mem9_writedata, mem9_done => mem9_done, mem9_readdata => mem9_readdata,
      mem7_ena => mr7_ena, mem7_lock => cpu7_lock,
      mem7_rnw => mr7_rnw, mem7_addr => mr7_addr, mem7_be => mr7_be,
      mem7_writedata => mr7_writedata, mem7_done => mr7_done, mem7_readdata => mr7_readdata,
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

   -- ================= mailbox snoops + verdict =================
   -- ARM9 mailbox 0x02FFFF00/04 -> main-RAM words 0xFFFC0/0xFFFC1 (port 9);
   -- ARM7 mailbox 0x02FFFF10/14 -> words 0xFFFC4/0xFFFC5 (port 7)
   p_snoop9 : process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (ld_busy = '0' and mr9_ena = '1' and mr9_rnw = '0') then
            if (mr9_addr = std_logic_vector(to_unsigned(16#FFFC0#, 20))) then
               mailbox9 <= mr9_writedata;
               report "arm9 progress: bitmask=" & to_hstring(mr9_writedata) severity note;
            elsif (mr9_addr = std_logic_vector(to_unsigned(16#FFFC1#, 20))) then
               if (mr9_writedata = x"CAFEBABE") then
                  report "tb_dual_boot: PASS  arm9=" & to_hstring(mailbox9) &
                         " arm7=" & to_hstring(mailbox7) severity note;
                  tests_done <= true;
               else
                  report "tb_dual_boot: ARM9 FAIL magic=" & to_hstring(mr9_writedata) &
                         " bitmask=" & to_hstring(mailbox9) severity failure;
               end if;
            end if;
         end if;
         assert error_cpu9 /= '1' report "nds_cpu9 error_cpu pulse" severity failure;
      end if;
   end process;

   p_snoop7 : process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (mr7_ena = '1' and mr7_rnw = '0') then
            if (mr7_addr = std_logic_vector(to_unsigned(16#FFFC4#, 20))) then
               mailbox7 <= mr7_writedata;
               report "arm7 progress: bitmask=" & to_hstring(mr7_writedata) severity note;
            elsif (mr7_addr = std_logic_vector(to_unsigned(16#FFFC5#, 20))) then
               if (mr7_writedata = x"BEEF7777") then
                  report "arm7 done word posted" severity note;
               else
                  report "tb_dual_boot: ARM7 FAIL word=" & to_hstring(mr7_writedata) &
                         " bitmask=" & to_hstring(mailbox7) severity failure;
               end if;
            end if;
         end if;
         assert error_cpu7 /= '1' report "gba_cpu error_cpu pulse" severity failure;
      end if;
   end process;

   -- first bus transactions per CPU, for bring-up debugging
   p_debug : process (clk1x)
      variable n9, n7 : integer := 0;
   begin
      if rising_edge(clk1x) then
         if (cpu9_ena = '1' and n9 < 32) then
            report "cpu9 op " & integer'image(n9) & ": adr=" & to_hstring(cpu9_adr) &
                   " rnw=" & to_string(cpu9_rnw) severity note;
            n9 := n9 + 1;
         end if;
         if (cpu7_ena = '1' and n7 < 32) then
            report "cpu7 op " & integer'image(n7) & ": adr=" & to_hstring(cpu7_adr) &
                   " rnw=" & to_string(cpu7_rnw) severity note;
            n7 := n7 + 1;
         end if;
      end if;
   end process;

   p_watchdog : process
   begin
      wait for TIMEOUT_MS * 1 ms;
      if not tests_done then
         report "tb_dual_boot: TIMEOUT  arm9=" & to_hstring(mailbox9) &
                " arm7=" & to_hstring(mailbox7) severity failure;
      end if;
      wait;
   end process;

end architecture;
