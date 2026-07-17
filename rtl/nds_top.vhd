-- NDS console top level — clk1x (33.514 MHz) + ce domain, GBA_MiSTfits pacing model.
-- Fast memory (SDRAM/DDR3) lives in nds_wrap behind ena/done handshakes.
--
-- M5 integration: the M4 dual-CPU fabric (nds_cpu9 + gba_cpu, membuses, shared
-- WRAM, main RAM, IPC, IRQ, timers, syscnt) plus the engine-A render path
-- (nds_vram + nds_gpu_timing + nds_gpu2d). Boot is the card-header HLE loader:
-- an FSM starts nds_loader once reset drops with nds_on high, presets both
-- boot PCs through the savestate buses, then releases the CPUs — the flow
-- tb_dual_boot proved, made synthesizable.
--
-- Current scope/simplifications (see docs/ROADMAP.md):
--   * both CPUs run at the full clk1x rate (ce='1'); the ARM9 2x / ARM7 1x
--     pacing model is the M9 hardware milestone
--   * the GPU dot cadence is ce-paced at 1-of-GPU_CE_DIV so the render
--     fabric has GPU_CE_DIV clocks per dot — the planned MiSTer topology
--     (fabric 100.5 MHz, dots 33.5) with clk1x standing in for the fabric
--     clock. At 1 the v1 line server blows the line budget (~110 dropped
--     lines/frame on an affine scene); tb_gpu2d_timed proves 3 is enough.
--     Consequence: relative to the CPUs the frame is GPU_CE_DIV x longer
--     than hardware — fine for static scenes, revisited with M9 pacing.
--   * TCMs, ARM7-private WRAM: behavioral arrays (BRAM entities land in M9)
--   * no DMA / sound / SPI / RTC / card yet; KEYINPUT/EXTKEYIN are wired
--     directly so samples polling keys see released state
--   * engine B absent: pixel_out_engB is tied low (M6)

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity nds_top is
   generic
   (
      is_simu                  : std_logic := '0';
      Softmap_NDS_MAINRAM_ADDR : integer   := 8388608; -- byte offset of the 4 MB window in SDRAM
      GPU_CE_DIV               : integer   := 3        -- render-fabric clocks per dot
   );
   port
   (
      clk1x            : in  std_logic;   -- 33.513982 MHz system clock
      clkMem           : in  std_logic;   -- 100.542 MHz (3x clk1x, phase-locked)
      clkMemIndex      : in  unsigned(1 downto 0);  -- clkMem phase, 0 on clk1x rising edge
      reset            : in  std_logic;
      nds_on           : in  std_logic;

      -- keys (active high) — X/Y/lid are NDS additions routed via ARM7 side
      KeyA             : in  std_logic;
      KeyB             : in  std_logic;
      KeySelect        : in  std_logic;
      KeyStart         : in  std_logic;
      KeyRight         : in  std_logic;
      KeyLeft          : in  std_logic;
      KeyUp            : in  std_logic;
      KeyDown          : in  std_logic;
      KeyR             : in  std_logic;
      KeyL             : in  std_logic;
      KeyX             : in  std_logic;
      KeyY             : in  std_logic;
      lid_closed       : in  std_logic;

      -- touchscreen (framework analog -> TSC-style samples in nds_spi later;
      -- for now only EXTKEYIN pen-down uses it)
      touch_active     : in  std_logic;
      touch_x          : in  std_logic_vector(7 downto 0);
      touch_y          : in  std_logic_vector(7 downto 0);

      -- boot status (HLE loader)
      boot_done        : out std_logic;
      boot_error       : out std_logic;

      -- card image read port (word addressed into the staged .nds, via nds_wrap)
      card_ena         : out std_logic;
      card_addr        : out std_logic_vector(26 downto 2);
      card_din         : in  std_logic_vector(31 downto 0);
      card_done        : in  std_logic;

      -- main RAM: nds_mainram SDRAM request port + scheduler handshake
      mainram_allow    : in  std_logic;
      mainram_active   : out std_logic;
      mainram_busy     : out std_logic;
      sdram_ena        : out std_logic;
      sdram_rnw        : out std_logic;
      sdram_Adr        : out std_logic_vector(26 downto 0);
      sdram_Din        : out std_logic_vector(31 downto 0);
      sdram_be         : out std_logic_vector(3 downto 0);
      sdram_Dout       : in  std_logic_vector(31 downto 0);
      sdram_done32     : in  std_logic;

      -- VRAM banks A..D backing store (CPU r/w + renderer read channels;
      -- SDRAM guest clients in nds_wrap, behavioral models in sim)
      vsrv_req         : out std_logic;
      vsrv_rnw         : out std_logic;
      vsrv_bank        : out std_logic_vector(1 downto 0);
      vsrv_addr        : out unsigned(16 downto 2);
      vsrv_be          : out std_logic_vector(3 downto 0);
      vsrv_din         : out std_logic_vector(31 downto 0);
      vsrv_dout        : in  std_logic_vector(31 downto 0);
      vsrv_done        : in  std_logic;
      vrsrv_req        : out std_logic;
      vrsrv_bank       : out std_logic_vector(1 downto 0);
      vrsrv_addr       : out unsigned(16 downto 2);
      vrsrv_dout       : in  std_logic_vector(31 downto 0);
      vrsrv_done       : in  std_logic;

      -- video out: engine A composed lines (RGB555 like the GBA path)
      pixel_out_x      : out integer range 0 to 255;
      pixel_out_y      : out integer range 0 to 191;
      pixel_out_data   : out std_logic_vector(14 downto 0);
      pixel_out_we     : out std_logic;
      pixel_out_engB   : out std_logic;
      vblank_out       : out std_logic;

      -- sound
      sound_out_left   : out std_logic_vector(15 downto 0);
      sound_out_right  : out std_logic_vector(15 downto 0);

      -- debug (sim monitors; unconnected in synthesis)
      dbg_line_drop    : out std_logic;   -- drawline landed while gpu2d was still busy
      dbg_line_busy    : out std_logic;
      dbg_cpu_err9     : out std_logic;
      dbg_cpu_err7     : out std_logic
   );
end entity;

architecture arch of nds_top is

   signal resetCpu : std_logic := '1';   -- both CPUs, held until the loader finished

   -- ================= boot FSM + loader =================
   type t_boot is
   (
      B_RESET,             -- fabric in reset / waiting for nds_on
      B_SETTLE,            -- fabric out of reset, let it settle
      B_LDSTART, B_LDWAIT, -- run nds_loader
      B_S9RST, B_S9GAP, B_S9WR, B_S9POST,   -- preset ARM9 PC via savestate bus
      B_S7RST, B_S7GAP, B_S7WR, B_S7POST,   -- preset ARM7 PC
      B_RUN,
      B_ERROR
   );
   signal boot_state : t_boot := B_RESET;
   signal boot_cnt   : integer range 0 to 7 := 0;

   signal ld_start, ld_busy, ld_done, ld_error : std_logic;
   signal arm9_entry, arm7_entry : std_logic_vector(31 downto 0);
   signal ld_wr_ena  : std_logic;
   signal ld_wr_addr, ld_wr_data : std_logic_vector(31 downto 0);
   signal ld_wr_done : std_logic;
   signal ld_w7_done : std_logic := '0';

   signal ss_bus9 : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');
   signal ss_bus7 : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');

   -- ================= ARM9 side =================
   signal cpu9_adr      : std_logic_vector(31 downto 0);
   signal cpu9_rnw, cpu9_ena, cpu9_code, cpu9_done : std_logic;
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

   -- TCM stores (behavioral arrays until the M9 BRAM pass)
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

   signal vram9_ena, vram9_rnw, vram9_done : std_logic;
   signal vram9_addr : unsigned(23 downto 2);
   signal vram9_be   : std_logic_vector(3 downto 0);
   signal vram9_din, vram9_dout : std_logic_vector(31 downto 0);

   signal pal_we, oam_we : std_logic;
   signal pal_addr, oam_addr : integer range 0 to 255;
   signal pal_din, oam_din : std_logic_vector(31 downto 0);
   signal pal_be, oam_be : std_logic_vector(3 downto 0);

   signal mr9_ena, mr9_rnw, mr9_done : std_logic;
   signal mr9_addr : std_logic_vector(21 downto 2);
   signal mr9_be   : std_logic_vector(3 downto 0);
   signal mr9_writedata, mr9_readdata : std_logic_vector(31 downto 0);

   signal io_bus9 : proc_bus_gb_type;
   signal io_wired_out9, irq_wired_out9, timer_wired_out9 : std_logic_vector(31 downto 0);
   signal io_wired_done9, irq_wired_done9, timer_wired_done9 : std_logic;
   signal ipc_wired_out9, sys_wired_out9 : std_logic_vector(31 downto 0);
   signal ipc_wired_done9, sys_wired_done9 : std_logic;
   signal tim_wired_out9, g2d_wired_out : std_logic_vector(31 downto 0);
   signal tim_wired_done9, g2d_wired_done : std_logic;
   signal key_wired_out9 : std_logic_vector(31 downto 0);
   signal key_wired_done9 : std_logic;
   signal irq_in9    : std_logic_vector(31 downto 0);
   signal irp_timer9 : std_logic_vector(3 downto 0);
   signal ipc9_irq_sync, ipc9_irq_sendempty, ipc9_irq_recv : std_logic;
   signal irq9_vblank, irq9_hblank, irq9_vcount : std_logic;

   -- ================= ARM7 side =================
   signal cpu7_adr      : std_logic_vector(31 downto 0);
   signal cpu7_rnw, cpu7_ena, cpu7_done : std_logic;
   signal cpu7_acc      : std_logic_vector(1 downto 0);
   signal cpu7_dout, cpu7_din, cpu7_lastread : std_logic_vector(31 downto 0);
   signal cpu7_lowbits  : std_logic_vector(1 downto 0);
   signal error_cpu7    : std_logic;
   signal cpu7_irq, cpu7_unhalt : std_logic;

   signal bios_addr : unsigned(13 downto 2);

   -- ARM7-private WRAM (64 KB, behavioral array until M9)
   type t_wram7 is array (0 to 16383) of std_logic_vector(31 downto 0);
   signal wram7 : t_wram7 := (others => (others => '0'));
   signal w7p_addr      : unsigned(15 downto 2);
   signal w7p_we        : std_logic;
   signal w7p_be        : std_logic_vector(3 downto 0);
   signal w7p_writedata, w7p_readdata : std_logic_vector(31 downto 0);
   signal w7m_addr      : unsigned(15 downto 2);   -- membus/loader mux
   signal w7m_we        : std_logic;
   signal w7m_be        : std_logic_vector(3 downto 0);
   signal w7m_writedata : std_logic_vector(31 downto 0);

   signal wsh7_ena, wsh7_rnw, wsh7_done, wsh7_mapped : std_logic;
   signal wsh7_addr : unsigned(14 downto 2);
   signal wsh7_be   : std_logic_vector(3 downto 0);
   signal wsh7_din, wsh7_dout : std_logic_vector(31 downto 0);

   signal vram7_ena, vram7_rnw, vram7_done : std_logic;
   signal vram7_addr : unsigned(23 downto 2);
   signal vram7_be   : std_logic_vector(3 downto 0);
   signal vram7_din, vram7_dout : std_logic_vector(31 downto 0);

   signal mr7_ena, mr7_rnw, mr7_done : std_logic;
   signal mr7_addr : std_logic_vector(21 downto 2);
   signal mr7_be   : std_logic_vector(3 downto 0);
   signal mr7_writedata, mr7_readdata : std_logic_vector(31 downto 0);

   signal io_bus7 : proc_bus_gb_type;
   signal io_wired_out7, irq_wired_out7, timer_wired_out7 : std_logic_vector(31 downto 0);
   signal io_wired_done7, irq_wired_done7, timer_wired_done7 : std_logic;
   signal ipc_wired_out7, sys_wired_out7 : std_logic_vector(31 downto 0);
   signal ipc_wired_done7, sys_wired_done7 : std_logic;
   signal tim_wired_out7 : std_logic_vector(31 downto 0);
   signal tim_wired_done7 : std_logic;
   signal key_wired_out7 : std_logic_vector(31 downto 0);
   signal key_wired_done7 : std_logic;
   signal irq_in7    : std_logic_vector(31 downto 0);
   signal irp_timer7 : std_logic_vector(3 downto 0);
   signal ipc7_irq_sync, ipc7_irq_sendempty, ipc7_irq_recv : std_logic;
   signal irq7_vblank, irq7_hblank, irq7_vcount : std_logic;

   -- ================= shared fabric =================
   signal wramcnt : std_logic_vector(1 downto 0);
   signal vramcnt : std_logic_vector(71 downto 0);
   signal exmem_prio7 : std_logic;

   -- main RAM port 9 = loader (while busy) / membus9 mux
   signal mem9_ena, mem9_rnw, mem9_done : std_logic;
   signal mem9_addr : std_logic_vector(21 downto 2);
   signal mem9_be   : std_logic_vector(3 downto 0);
   signal mem9_writedata, mem9_readdata : std_logic_vector(31 downto 0);
   signal ld_to_main, ld_to_wram7 : std_logic;

   -- ================= GPU =================
   signal keyinput : std_logic_vector(9 downto 0);
   signal extkeyin : std_logic_vector(7 downto 0);

   -- renderer channels between nds_vram and nds_gpu2d
   signal r_bg_req, r_bg_done       : std_logic;
   signal r_bg_addr                 : unsigned(18 downto 2);
   signal r_bg_dout                 : std_logic_vector(31 downto 0);
   signal r_obj_req, r_obj_done     : std_logic;
   signal r_obj_addr                : unsigned(17 downto 2);
   signal r_obj_dout                : std_logic_vector(31 downto 0);
   signal r_bgep_req, r_bgep_done   : std_logic;
   signal r_bgep_addr               : unsigned(14 downto 2);
   signal r_bgep_dout               : std_logic_vector(31 downto 0);
   signal r_objep_req, r_objep_done : std_logic;
   signal r_objep_addr              : unsigned(12 downto 2);
   signal r_objep_dout              : std_logic_vector(31 downto 0);

   signal g_bg_addr    : integer range 0 to 131071;
   signal g_obj_addr   : integer range 0 to 65535;
   signal g_bgep_addr  : integer range 0 to 8191;
   signal g_objep_addr : integer range 0 to 2047;

   -- timing -> gpu2d line control
   signal gpu_ce          : std_logic := '0';
   signal linecounter     : integer range 0 to 191;
   signal linecounter_obj : integer range 0 to 191;
   signal drawline, drawObj, line_trigger, hblank_trigger, gpu_vblank, refpoint_update : std_logic;
   signal line_busy, epfill_busy : std_logic;
   signal vcount_out : unsigned(8 downto 0);

begin

   -- =====================================================================
   -- boot: fabric out of reset -> loader copies both sections -> preset
   -- both boot PCs through the savestate buses -> release the CPUs
   -- =====================================================================
   p_boot : process (clk1x)
   begin
      if rising_edge(clk1x) then
         ld_start <= '0';
         if (reset = '1') then
            boot_state <= B_RESET;
            boot_cnt   <= 0;
            resetCpu   <= '1';
            ss_bus9    <= ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');
            ss_bus7    <= ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');
         else
            case boot_state is

               when B_RESET =>
                  resetCpu <= '1';
                  boot_cnt <= 0;
                  if (nds_on = '1') then
                     boot_state <= B_SETTLE;
                  end if;

               when B_SETTLE =>
                  if (boot_cnt = 7) then
                     boot_state <= B_LDSTART;
                  else
                     boot_cnt <= boot_cnt + 1;
                  end if;

               when B_LDSTART =>
                  ld_start   <= '1';
                  boot_state <= B_LDWAIT;

               when B_LDWAIT =>
                  if (ld_error = '1') then
                     boot_state <= B_ERROR;
                  elsif (ld_done = '1' and ld_busy = '0') then
                     boot_state  <= B_S9RST;
                     boot_cnt    <= 0;
                     ss_bus9.rst <= '1';
                  end if;

               when B_S9RST =>
                  if (boot_cnt = 2) then
                     ss_bus9.rst <= '0';
                     boot_cnt    <= 0;
                     boot_state  <= B_S9GAP;
                  else
                     boot_cnt <= boot_cnt + 1;
                  end if;

               when B_S9GAP =>
                  ss_bus9.Adr  <= (others => '0');   -- REG_SAVESTATE_PC
                  ss_bus9.Din  <= arm9_entry;
                  ss_bus9.rnw  <= '0';
                  ss_bus9.bEna <= "1111";
                  ss_bus9.ena  <= '1';
                  boot_state   <= B_S9WR;

               when B_S9WR =>
                  ss_bus9.ena <= '0';
                  ss_bus9.rnw <= '1';
                  boot_cnt    <= 0;
                  boot_state  <= B_S9POST;

               when B_S9POST =>
                  if (boot_cnt = 2) then
                     boot_cnt    <= 0;
                     ss_bus7.rst <= '1';
                     boot_state  <= B_S7RST;
                  else
                     boot_cnt <= boot_cnt + 1;
                  end if;

               when B_S7RST =>
                  if (boot_cnt = 2) then
                     ss_bus7.rst <= '0';
                     boot_cnt    <= 0;
                     boot_state  <= B_S7GAP;
                  else
                     boot_cnt <= boot_cnt + 1;
                  end if;

               when B_S7GAP =>
                  ss_bus7.Adr  <= (others => '0');
                  ss_bus7.Din  <= arm7_entry;
                  ss_bus7.rnw  <= '0';
                  ss_bus7.bEna <= "1111";
                  ss_bus7.ena  <= '1';
                  boot_state   <= B_S7WR;

               when B_S7WR =>
                  ss_bus7.ena <= '0';
                  ss_bus7.rnw <= '1';
                  boot_cnt    <= 0;
                  boot_state  <= B_S7POST;

               when B_S7POST =>
                  if (boot_cnt = 2) then
                     boot_state <= B_RUN;
                  else
                     boot_cnt <= boot_cnt + 1;
                  end if;

               when B_RUN =>
                  resetCpu <= '0';

               when B_ERROR =>
                  null;

            end case;
         end if;
      end if;
   end process;

   boot_done  <= '1' when boot_state = B_RUN else '0';
   boot_error <= '1' when boot_state = B_ERROR else '0';

   iloader : entity work.nds_loader
   port map
   (
      clk => clk1x, reset => reset,
      start => ld_start, busy => ld_busy, done => ld_done, load_error => ld_error,
      arm9_entry => arm9_entry, arm7_entry => arm7_entry,
      card_ena => card_ena, card_addr => card_addr,
      card_done => card_done, card_rdata => card_din,
      wr_ena => ld_wr_ena, wr_addr => ld_wr_addr, wr_data => ld_wr_data,
      wr_done => ld_wr_done
   );

   -- loader writes route by target: main RAM (0x02xxxxxx) via main-RAM port 9,
   -- ARM7-private WRAM (0x037xxxxx) straight into the store (CPUs are in reset)
   ld_to_main  <= '1' when (ld_busy = '1' and ld_wr_addr(31 downto 24) = x"02") else '0';
   ld_to_wram7 <= '1' when (ld_busy = '1' and ld_wr_addr(31 downto 24) = x"03") else '0';

   mem9_ena       <= (ld_wr_ena and ld_to_main) when ld_busy = '1' else mr9_ena;
   mem9_rnw       <= '0'                        when ld_busy = '1' else mr9_rnw;
   mem9_addr      <= ld_wr_addr(21 downto 2)    when ld_busy = '1' else mr9_addr;
   mem9_be        <= "1111"                     when ld_busy = '1' else mr9_be;
   mem9_writedata <= ld_wr_data                 when ld_busy = '1' else mr9_writedata;
   mr9_done       <= mem9_done and not ld_busy;
   mr9_readdata   <= mem9_readdata;

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         ld_w7_done <= ld_wr_ena and ld_to_wram7;
      end if;
   end process;
   ld_wr_done <= ld_w7_done when ld_to_wram7 = '1' else mem9_done;

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
      vram_din => vram9_din, vram_dout => vram9_dout, vram_done => vram9_done,
      pal_we => pal_we, pal_addr => pal_addr, pal_din => pal_din, pal_be => pal_be,
      oam_we => oam_we, oam_addr => oam_addr, oam_din => oam_din, oam_be => oam_be,
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
      end if;
   end process;
   itcm_readdata <= itcm(to_integer(itcm_addr));
   dtcm_readdata <= dtcm(to_integer(dtcm_addr));

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
      vram_din => vram7_din, vram_dout => vram7_dout, vram_done => vram7_done,
      mr_ena => mr7_ena, mr_rnw => mr7_rnw, mr_addr => mr7_addr, mr_be => mr7_be,
      mr_writedata => mr7_writedata, mr_done => mr7_done, mr_readdata => mr7_readdata,
      io_ce_next => '1',
      io_bus => io_bus7, io_wired_out => io_wired_out7, io_wired_done => io_wired_done7
   );

   -- ARM7-private WRAM store (loader can preload it; CPUs are in reset then)
   w7m_we        <= (ld_wr_ena and ld_to_wram7) when ld_busy = '1' else w7p_we;
   w7m_addr      <= unsigned(ld_wr_addr(15 downto 2)) when ld_busy = '1' else w7p_addr;
   w7m_be        <= "1111"                     when ld_busy = '1' else w7p_be;
   w7m_writedata <= ld_wr_data                 when ld_busy = '1' else w7p_writedata;

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (w7m_we = '1') then
            for i in 0 to 3 loop
               if (w7m_be(i) = '1') then
                  wram7(to_integer(w7m_addr))(i*8 + 7 downto i*8) <= w7m_writedata(i*8 + 7 downto i*8);
               end if;
            end loop;
         end if;
      end if;
   end process;
   w7p_readdata <= wram7(to_integer(w7p_addr));

   -- ================= IO register banks =================
   io_wired_out9  <= irq_wired_out9 or timer_wired_out9 or ipc_wired_out9 or sys_wired_out9 or
                     tim_wired_out9 or g2d_wired_out or key_wired_out9;
   io_wired_done9 <= irq_wired_done9 or timer_wired_done9 or ipc_wired_done9 or sys_wired_done9 or
                     tim_wired_done9 or g2d_wired_done or key_wired_done9;
   io_wired_out7  <= irq_wired_out7 or timer_wired_out7 or ipc_wired_out7 or sys_wired_out7 or
                     tim_wired_out7 or key_wired_out7;
   io_wired_done7 <= irq_wired_done7 or timer_wired_done7 or ipc_wired_done7 or sys_wired_done7 or
                     tim_wired_done7 or key_wired_done7;

   irq_in9 <= (0 => irq9_vblank, 1 => irq9_hblank, 2 => irq9_vcount,
               3 => irp_timer9(0), 4 => irp_timer9(1), 5 => irp_timer9(2), 6 => irp_timer9(3),
               16 => ipc9_irq_sync, 17 => ipc9_irq_sendempty, 18 => ipc9_irq_recv,
               others => '0');
   irq_in7 <= (0 => irq7_vblank, 1 => irq7_hblank, 2 => irq7_vcount,
               3 => irp_timer7(0), 4 => irp_timer7(1), 5 => irp_timer7(2), 6 => irp_timer7(3),
               16 => ipc7_irq_sync, 17 => ipc7_irq_sendempty, 18 => ipc7_irq_recv,
               others => '0');

   -- KEYINPUT (0x130, both CPUs) + EXTKEYIN (0x136, ARM7): wired directly
   -- until a keypad module (KEYCNT/key IRQ) exists; active low, released = 1
   keyinput <= not (KeyL & KeyR & KeyDown & KeyUp & KeyLeft & KeyRight &
                    KeyStart & KeySelect & KeyB & KeyA);
   extkeyin <= lid_closed & (not touch_active) & "11" & "11" & (not KeyY) & (not KeyX);

   key_wired_out9  <= x"0000" & "000000" & keyinput when (io_bus9.Adr = x"0000130") else (others => '0');
   key_wired_done9 <= '1' when (io_bus9.Adr = x"0000130") else '0';
   key_wired_out7  <= x"0000" & "000000" & keyinput when (io_bus7.Adr = x"0000130") else
                      x"00" & extkeyin & x"0000"    when (io_bus7.Adr = x"0000134") else
                      (others => '0');
   key_wired_done7 <= '1' when (io_bus7.Adr = x"0000130" or io_bus7.Adr = x"0000134") else '0';

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
      wramcnt => wramcnt, vramcnt => vramcnt,
      exmem_gba7 => open, exmem_card7 => open, exmem_prio7 => exmem_prio7
   );

   -- ================= shared memory fabric =================
   iwram : entity work.nds_wram
   generic map ( is_simu => is_simu )
   port map
   (
      clk => clk1x, wramcnt => wramcnt,
      arm9_ena => wsh9_ena, arm9_rnw => wsh9_rnw, arm9_addr => wsh9_addr, arm9_be => wsh9_be,
      arm9_din => wsh9_din, arm9_dout => wsh9_dout, arm9_done => wsh9_done, arm9_mapped => wsh9_mapped,
      arm7_ena => wsh7_ena, arm7_rnw => wsh7_rnw, arm7_addr => wsh7_addr, arm7_be => wsh7_be,
      arm7_din => wsh7_din, arm7_dout => wsh7_dout, arm7_done => wsh7_done, arm7_mapped => wsh7_mapped
   );

   imainram : entity work.nds_mainram
   generic map ( Softmap_NDS_MAINRAM_ADDR => Softmap_NDS_MAINRAM_ADDR )
   port map
   (
      clk1x => clk1x, clkMem => clkMem, clkMemIndex => clkMemIndex, reset => reset,
      arm7_priority => exmem_prio7,
      mem9_ena => mem9_ena, mem9_rnw => mem9_rnw, mem9_addr => mem9_addr, mem9_be => mem9_be,
      mem9_writedata => mem9_writedata, mem9_done => mem9_done, mem9_readdata => mem9_readdata,
      mem7_ena => mr7_ena, mem7_rnw => mr7_rnw, mem7_addr => mr7_addr, mem7_be => mr7_be,
      mem7_writedata => mr7_writedata, mem7_done => mr7_done, mem7_readdata => mr7_readdata,
      mainram_allow => mainram_allow, mainram_active => mainram_active, mainram_busy => mainram_busy,
      mr_sdram_ena => sdram_ena, mr_sdram_rnw => sdram_rnw, mr_sdram_Adr => sdram_Adr,
      mr_sdram_Din => sdram_Din, mr_sdram_be => sdram_be,
      sdram_Dout => sdram_Dout, sdram_done32 => sdram_done32
   );

   -- ================= VRAM + engine A render path =================
   ivram : entity work.nds_vram
   generic map ( is_simu => is_simu )
   port map
   (
      clk => clk1x, reset => reset, vramcnt => vramcnt,
      cpu9_ena => vram9_ena, cpu9_rnw => vram9_rnw, cpu9_addr => vram9_addr,
      cpu9_be => vram9_be, cpu9_din => vram9_din, cpu9_dout => vram9_dout, cpu9_done => vram9_done,
      cpu7_ena => vram7_ena, cpu7_rnw => vram7_rnw, cpu7_addr => vram7_addr,
      cpu7_be => vram7_be, cpu7_din => vram7_din, cpu7_dout => vram7_dout, cpu7_done => vram7_done,
      srv_req => vsrv_req, srv_rnw => vsrv_rnw, srv_bank => vsrv_bank, srv_addr => vsrv_addr,
      srv_be => vsrv_be, srv_din => vsrv_din, srv_dout => vsrv_dout, srv_done => vsrv_done,
      rdr_bg_req => r_bg_req, rdr_bg_addr => r_bg_addr,
      rdr_bg_dout => r_bg_dout, rdr_bg_done => r_bg_done,
      rdr_obj_req => r_obj_req, rdr_obj_addr => r_obj_addr,
      rdr_obj_dout => r_obj_dout, rdr_obj_done => r_obj_done,
      rdr_bgep_req => r_bgep_req, rdr_bgep_addr => r_bgep_addr,
      rdr_bgep_dout => r_bgep_dout, rdr_bgep_done => r_bgep_done,
      rdr_objep_req => r_objep_req, rdr_objep_addr => r_objep_addr,
      rdr_objep_dout => r_objep_dout, rdr_objep_done => r_objep_done,
      rsrv_req => vrsrv_req, rsrv_bank => vrsrv_bank, rsrv_addr => vrsrv_addr,
      rsrv_dout => vrsrv_dout, rsrv_done => vrsrv_done
   );

   -- dot pace: 1 of GPU_CE_DIV clocks (see header)
   p_gpu_ce : process (clk1x)
      variable div : integer range 0 to GPU_CE_DIV - 1 := 0;
   begin
      if rising_edge(clk1x) then
         if (div = GPU_CE_DIV - 1) then
            div    := 0;
            gpu_ce <= '1';
         else
            div    := div + 1;
            gpu_ce <= '0';
         end if;
      end if;
   end process;

   itiming : entity work.nds_gpu_timing
   port map
   (
      clk             => clk1x,
      ce              => gpu_ce,
      reset           => resetCpu,
      gb_bus9         => io_bus9,
      wired_out9      => tim_wired_out9,
      wired_done9     => tim_wired_done9,
      gb_bus7         => io_bus7,
      wired_out7      => tim_wired_out7,
      wired_done7     => tim_wired_done7,
      irq9_vblank     => irq9_vblank,
      irq9_hblank     => irq9_hblank,
      irq9_vcount     => irq9_vcount,
      irq7_vblank     => irq7_vblank,
      irq7_hblank     => irq7_hblank,
      irq7_vcount     => irq7_vcount,
      linecounter     => linecounter,
      drawline        => drawline,
      linecounter_obj => linecounter_obj,
      drawObj         => drawObj,
      line_trigger    => line_trigger,
      hblank_trigger  => hblank_trigger,
      vblank_trigger  => gpu_vblank,
      refpoint_update => refpoint_update,
      vcount_out      => vcount_out
   );

   r_bg_addr    <= to_unsigned(g_bg_addr, 17);
   r_obj_addr   <= to_unsigned(g_obj_addr, 16);
   r_bgep_addr  <= to_unsigned(g_bgep_addr, 13);
   r_objep_addr <= to_unsigned(g_objep_addr, 11);

   igpu2d_a : entity work.nds_gpu2d
   port map
   (
      clk => clk1x, reset => resetCpu,
      gb_bus => io_bus9, wired_out => g2d_wired_out, wired_done => g2d_wired_done,
      linecounter => linecounter, drawline => drawline,
      linecounter_obj => linecounter_obj, drawObj => drawObj,
      line_trigger => line_trigger, hblank_trigger => hblank_trigger,
      vblank_trigger => gpu_vblank, refpoint_update => refpoint_update,
      line_busy => line_busy, epfill_busy => epfill_busy,
      pal_we => pal_we, pal_addr => pal_addr, pal_din => pal_din, pal_be => pal_be,
      oam_we => oam_we, oam_addr => oam_addr, oam_din => oam_din, oam_be => oam_be,
      srv_bg_req => r_bg_req, srv_bg_addr => g_bg_addr,
      srv_bg_data => r_bg_dout, srv_bg_done => r_bg_done,
      srv_obj_req => r_obj_req, srv_obj_addr => g_obj_addr,
      srv_obj_data => r_obj_dout, srv_obj_done => r_obj_done,
      srv_bgep_req => r_bgep_req, srv_bgep_addr => g_bgep_addr,
      srv_bgep_data => r_bgep_dout, srv_bgep_done => r_bgep_done,
      srv_objep_req => r_objep_req, srv_objep_addr => g_objep_addr,
      srv_objep_data => r_objep_dout, srv_objep_done => r_objep_done,
      pixel_out_x => pixel_out_x, pixel_out_y => pixel_out_y,
      pixel_out_data => pixel_out_data, pixel_out_we => pixel_out_we
   );

   pixel_out_engB <= '0';   -- engine B lands in M6
   vblank_out     <= gpu_vblank;

   dbg_line_drop <= drawline and line_busy;
   dbg_line_busy <= line_busy;
   dbg_cpu_err9  <= error_cpu9;
   dbg_cpu_err7  <= error_cpu7;

   sound_out_left  <= (others => '0');
   sound_out_right <= (others => '0');

end architecture;
