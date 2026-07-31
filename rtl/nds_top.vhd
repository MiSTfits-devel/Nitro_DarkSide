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
--   * TCMs, ARM7-private WRAM: SyncRamDualByteEnable (M10K; the membus
--     presents addresses combinationally in the accept cycle, the BRAM's
--     internal address register replaces the old registered-address idiom)
--   * ARM9 DMA (nds_dma9): immediate/vblank/hblank, functional timing;
--     card/RTC/sound-regs/ARM7-DMA exist (sound mixer DSP pending); KEYINPUT/EXTKEYIN are
--     wired directly so samples polling keys see released state
--   * ARM7 SPI bus (nds_spi): PMIC + firmware flash + TSC; the flash serves
--     the fw_* image port (melonDS default firmware in sim; touch/mic not
--     wired into the TSC yet)
--   * ARM7 HLE BIOS (nds_bios7, generated from sim/tests/hle_bios7):
--     GBATEK IRQ dispatch via [0x0380FFFC] + the SWIs calico/libnds use;
--     svcHalt goes through HALTCNT in nds_syscnt. The ARM9 needs no BIOS
--     (calico ds9 installs its own vectors)
--   * both 2D engines render (engine B via the 0x1000 register window,
--     palette/OAM upper halves and the C/D/H/I VRAM roles); POWCNT routes
--     the screens (swap bit; B-off shows white, palette/OAM writes gated
--     by engine power) and MASTER_BRIGHT applies per engine in nds_gpu2d.
--     Still open: LCDC/FIFO display modes, the DDR3 compose stage

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library MEM;

use work.pProc_bus_gba.all;
use work.pexport.all;

entity nds_top is
   generic
   (
      is_simu                  : std_logic := '0';
      Softmap_NDS_MAINRAM_ADDR : integer   := 8388608; -- byte offset of the 4 MB window in SDRAM
      GPU_CE_DIV               : integer   := 3;       -- render-fabric clocks per dot
      -- 1 = run both 2D engines on clkMem (3x clk1x) instead of clk1x, giving
      -- the renderer 6390 cycles per scanline instead of 2130. A rendered line
      -- measures 5829 cycles, so it only fits the former. See nds_gpu2d_fast.
      GPU_FAST                 : integer   := 0;
      -- simulation only: the testbench has staged the ARM9/ARM7 main-RAM sections
      -- itself, so nds_loader may skip copying them (see nds_loader.skip_copy)
      skip_copy                : std_logic := '0'
   );
   port
   (
      clk1x            : in  std_logic;   -- 33.513982 MHz system clock
      -- The ARM9 island clock, PLL outclk_3, 50.270973 MHz = VCO/16 = 1.5x clk1x
      -- from the same VCO at 0 ps. Clocks only the ARM9 island (icpu9 + imembus9
      -- + cache9 + ITCM/DTCM).
      --
      -- Historically this was outclk_1 at 67.027964 MHz, "EXACTLY 2x clk1x", and
      -- the comment here said having both on clk1x "breaks the NitroSDK IPCSYNC
      -- boot handshake". Both parts of that are now known to be wrong:
      --   * 67.028 MHz was the VIDEO pixel clock, which the island merely shared.
      --     It was never an ARM9 requirement.
      --   * The handshake imposes no speed ratio at all. Both sides are unbounded
      --     waits (ARM7 spins at 0x0238FEA8/0x0238FEC8 with no timeout; the ARM9's
      --     1000-poll budget at 0x0214FF50 restores its counter and retries on
      --     expiry), so either CPU may be arbitrarily slower than the other.
      -- The bridge handshakes below are ratio-independent by construction - the
      -- request path is a toggle held until the transaction completes, and the
      -- done paths are edge detectors - so a non-integer 1.5x is fine.
      --
      -- ISLAND=0 (tie to clk1x) still does NOT work, but for an unrelated reason:
      -- a bridge completion is lost at 1:1 and the ARM9 parks after ~90 accepts
      -- with main RAM IDLE. That is a bug to fix, not a ratio requirement.
      clk2x            : in  std_logic;
      clkMem           : in  std_logic;   -- 100.542 MHz (3x clk1x, phase-locked)
      clkMemIndex      : in  unsigned(1 downto 0);  -- clkMem phase, 0 on clk1x rising edge
      reset            : in  std_logic;
      nds_on           : in  std_logic;
      direct_boot      : in  std_logic := '0';  -- synthesize the firmware boot env (stock ROMs)
      -- '1' = FIRMWARE BOOT. The loader clears memory and derives the cartridge
      -- chip ID, then stops: no image staging, no direct-boot env block. The boot
      -- FSM then releases both CPUs WITHOUT presetting their PCs, so they start at
      -- their architectural reset vectors and the retail BIOSes run - the ARM7 BIOS
      -- pulls the firmware over SPI and the firmware reads the cartridge itself,
      -- as real hardware does.
      --
      -- This exists because every "leftover memory" bug in this core has been the
      -- same shape: direct boot skips the firmware, so something is uninitialised.
      -- Main RAM (SWP cart-lock wedge), VRAM/palette/OAM (stale screen) and ARM7
      -- WRAM were each fixed by hand-reimplementing one thing the firmware does.
      -- Booting the firmware addresses the cause rather than the symptoms.
      fw_boot          : in  std_logic := '0';
      -- '1' = dot cadence 1-of-1 (real frame rate); '0' = 1-of-GPU_CE_DIV
      gpu_full_pace    : in  std_logic := '0';

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

      -- SPI firmware flash image read port (256 KB, word addressed; req/done
      -- handshake — hex array in sim answers next cycle, the DDR3 pager on
      -- hardware answers in tens of cycles, both inside the SPI byte window)
      fw_addr          : out unsigned(17 downto 2);
      fw_req           : out std_logic;
      fw_done          : in  std_logic;
      fw_data          : in  std_logic_vector(31 downto 0);

      -- Runtime-loadable retail CPU BIOS images. Hardware writes these
      -- while reset is asserted, then switches atomically on *_load_done.
      bios7_load_addr  : in unsigned(13 downto 2) := (others => '0');
      bios7_load_data  : in std_logic_vector(31 downto 0) := (others => '0');
      bios7_load_be    : in std_logic_vector(3 downto 0) := (others => '0');
      bios7_load_we    : in std_logic := '0';
      bios7_load_done  : in std_logic := '0';
      bios9_load_addr  : in unsigned(11 downto 2) := (others => '0');
      bios9_load_data  : in std_logic_vector(31 downto 0) := (others => '0');
      bios9_load_be    : in std_logic_vector(3 downto 0) := (others => '0');
      bios9_load_we    : in std_logic := '0';
      bios9_load_done  : in std_logic := '0';

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
      vrsrv_addr       : out unsigned(16 downto 3);
      vrsrv_dout       : in  std_logic_vector(63 downto 0);
      vrsrv_done       : in  std_logic;
      -- back-pressure for the renderer VRAM feed. nds_vram's renderer server
      -- now issues A..D reads PIPELINED, so the channel has to say when it can
      -- take one; without this a platform that serves one op at a time drops
      -- every request that arrives while it is busy. Defaults high for models
      -- that are always ready.
      vrsrv_ready      : in  std_logic := '1';

      -- video out: TOP and BOTTOM screen lines after POWCNT routing,
      -- BGR666 (the NDS 18-bit LCD format; B in [17:12])
      pixel_out_x      : out integer range 0 to 255;
      pixel_out_y      : out integer range 0 to 191;
      pixel_out_data   : out std_logic_vector(17 downto 0);
      pixel_out_we     : out std_logic;
      pixelb_out_x     : out integer range 0 to 255;
      pixelb_out_y     : out integer range 0 to 191;
      pixelb_out_data  : out std_logic_vector(17 downto 0);
      pixelb_out_we    : out std_logic;
      vblank_out       : out std_logic;

      -- sound
      sound_out_left   : out std_logic_vector(15 downto 0);
      sound_out_right  : out std_logic_vector(15 downto 0);

      -- debug (sim monitors; unconnected in synthesis). The record-typed
      -- exports are sim-only, pragma-stripped like the CPUs' own ports
      -- (donor gba_cpu idiom); keep plain ports after them so stripping
      -- never leaves a dangling ';' before the closing paren.
-- synthesis translate_off
      dbg_export9_done : out std_logic;   -- ARM9 retired-instruction export (is_simu only)
      dbg_export9      : out cpu_export_type;
      dbg_export7_done : out std_logic;   -- ARM7 retired-instruction export (is_simu only)
      dbg_export7      : out cpu_export_type;
-- synthesis translate_on
      dbg_line_drop    : out std_logic;   -- drawline landed while gpu2d was still busy
      dbg_line_drop_a  : out std_logic;   -- ... engine A specifically
      dbg_line_drop_b  : out std_logic;   -- ... engine B specifically
      dbg_line_busy    : out std_logic;
      dbg_cpu_err9     : out std_logic;
      dbg_cpu_err7     : out std_logic;
      dbg_pc9          : out std_logic_vector(31 downto 0);
      dbg_pc7          : out std_logic_vector(31 downto 0);
      dbg_r0_9         : out std_logic_vector(31 downto 0);
      dbg_lr9          : out std_logic_vector(31 downto 0);
      dbg_cpsr9        : out std_logic_vector(31 downto 0);
      -- main-RAM verify results from nds_loader (see its port comment)
      dbg_vfy_bad      : out std_logic_vector(17 downto 0);
      dbg_vfy_addr     : out std_logic_vector(31 downto 0);
      -- nds_debug mailbox, driven by the ddram ch4 pager in NDS.sv
      dbg_cmd_stb      : in  std_logic := '0';
      dbg_cmd_op       : in  std_logic_vector(7 downto 0) := (others => '0');
      dbg_cmd_arg      : in  std_logic_vector(31 downto 0) := (others => '0');
      dbg_rsp_data     : out std_logic_vector(31 downto 0);
      dbg_rsp_stb      : out std_logic;
      dbg_hwstat       : out std_logic_vector(17 downto 0)
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
   signal preset_direct : std_logic := '0';
   signal arm9_entry, arm7_entry : std_logic_vector(31 downto 0);
   -- Effective boot PCs. Firmware boot enters each BIOS at its reset vector
   -- instead of the cart's entry point: the ARM9 at 0xFFFF0000 (the NDS ties
   -- VINITHI high, so exception vectors are high from reset) and the ARM7 at
   -- 0x00000000. This core does not model the ARM reset exception at all -
   -- both CPUs take their initial fetch_PC from the savestate write in
   -- B_S9GAP/B_S7GAP - so simply releasing reset without presetting a PC
   -- starts the ARM9 at 0x00000000 and retires nothing at all.
   signal arm9_entry_eff, arm7_entry_eff : std_logic_vector(31 downto 0);

   -- ---- direct-boot register preset ------------------------------------
   -- Presetting only the PC is not enough. The loader's env block was specced
   -- against calico homebrew, whose bootstubs set up their own CP15 and stacks;
   -- a NitroSDK-built cart never sets its own SP, it inherits one from the boot
   -- ROM. With SP=0 its first function prologue pushes into ITCM at address 0
   -- and the cart is dead long before it touches a display register - see
   -- docs/NTR_EVA_TESTER.md, where that is the whole of the failure.
   --
   -- Values are the GBATEK default stack pointers. melonDS banks with std::swap
   -- while this core saves/restores per mode (the CPUMODE_* case in
   -- gba_cpu.vhd), so its R[13]/R_SVC[0] pair does NOT copy across literally.
   --
   -- Translating melonDS's swap model into this one is not a field-by-field
   -- copy, and getting it wrong costs a whole sim cycle to notice:
   --
   --   melonDS R[13]     -> the ACTIVE bank. Boot CPSR reads supervisor but the
   --                        value there is the USER stack (0x03002F7C).
   --   melonDS R_SVC[0]  -> the USER/SYSTEM bank. Under swap, while supervisor
   --                        is active R_SVC holds the stack that swaps in when
   --                        LEAVING supervisor - so despite the name it is the
   --                        outer stack, not the supervisor one.
   --   melonDS R_IRQ[0]  -> the IRQ bank directly (IRQ is not the active mode,
   --                        so it really is holding IRQ's own stack).
   --
   -- Reading R_SVC[0] as "the supervisor bank" diverges at the ROM's first
   -- MSR CPSR out of supervisor - instruction 69 of this cart, with every other
   -- column still matching. Matching the oracle exactly is the point:
   -- sim/tests/compare_trace.py had to document "--ignore cpsr,r13,r14 against
   -- a melonDS trace" only because this preset was missing, and those ignores
   -- mask real divergences.
   --
   -- Savestate addresses come from rtl/reg_savestates.vhd: REG_SAVESTATE_PC is
   -- 0, and REG_SAVESTATE_REGS is a size-18 block based at 1, so rN is at 1+N.
   -- REGS_0_13 = 24 (user/system bank), REGS_2_13 = 34 (IRQ), REGS_3_13 = 37
   -- (supervisor). Both CPUs come out of reset in supervisor mode
   -- (SAVESTATE_cpu_mode defaults to CPUMODE_SUPERVISOR), so the plain REGS r13
   -- at address 14 IS the supervisor stack.
   constant PRESET_LAST : integer := 6;
   signal   preset_idx  : integer range 0 to 7 := 0;

   function preset_adr(idx : integer) return integer is
   begin
      case idx is
         when 0      => return  0;   -- fetch PC
         when 1      => return 13;   -- r12
         when 2      => return 14;   -- r13, active (supervisor) bank
         when 3      => return 15;   -- r14
         when 4      => return 24;   -- r13 user/system bank
         when 5      => return 34;   -- r13 IRQ bank
         when others => return 37;   -- r13 supervisor bank
      end case;
   end function;

   function preset_val(idx : integer; entry_pc : std_logic_vector(31 downto 0);
                       is_arm9 : boolean) return std_logic_vector is
   begin
      case idx is
         when 0 | 1 | 3 => return entry_pc;
         when 2         => if is_arm9 then return x"03002F7C"; else return x"0380FD80"; end if;
         when 5         => if is_arm9 then return x"03003F80"; else return x"0380FF80"; end if;
         when others    => if is_arm9 then return x"03003FC0"; else return x"0380FFC0"; end if;
      end case;
   end function;

   signal ld_cartid  : std_logic_vector(31 downto 0);  -- header-size chip ID -> nds_card B8
   -- on-FPGA debug unit (nds_debug): CPU hold/release, register read-back and
   -- a main-RAM peek muxed onto the ARM9 channel the same way the loader is
   signal pc9_s, pc7_s         : std_logic_vector(31 downto 0);
   signal dbg_hold9, dbg_rel9  : std_logic;
   signal dbg_hold7, dbg_rel7  : std_logic;
   signal dbg_boot_rst         : std_logic;   -- debugger-requested boot restart
   signal dbg_regsel_s         : unsigned(4 downto 0);
   signal dbg_regval9, dbg_regval7 : std_logic_vector(31 downto 0);
   signal dbg_pk_ena, dbg_pk_act, dbg_pk_sel : std_logic;

   -- Everything the CPUs' resetCpu does not cover, but which a from-reset probe
   -- must still start clean. nds_mainram in particular latches req9/req7_pending
   -- and lock_pair: a SOFTRESET landing mid-op leaves the arbiter waiting on a
   -- request no one will re-issue, which kills the ARM9's main-RAM channel from
   -- t=0 while the ARM7 keeps running out of its private WRAM. These three
   -- cannot take resetCpu instead - the loader stages main RAM through them
   -- while resetCpu is still asserted.
   signal reset_boot : std_logic;

   -- Reset clear passes: VRAM (nds_vram) and palette/OAM (both gpu2d engines)
   -- zero themselves out of reset, the way nds_loader's CLR_WR zeroes main RAM
   -- - a MiSTer ROM change does not reconfigure the FPGA, so without this the
   -- new game renders the previous game's leftovers. The CPU release waits on
   -- all three so no game write can race a clear (VRAM's pass runs concurrently
   -- with the loader and is by far the longest, ~660 KB; measured ordering is in
   -- the bench, not assumed).
   signal vclr_busy   : std_logic;
   signal pclr_busy_a : std_logic;
   signal pclr_busy_b : std_logic;

   -- ARM9 clk2x island <-> clk1x world bridge (see the process block below)
   signal cdc_req_wsh, cdc_req_vram, cdc_req_mr   : std_logic := '0';
   signal cdc_req_io,  cdc_req_pal,  cdc_req_oam  : std_logic := '0';
   signal cdc_req_wsh_d, cdc_req_vram_d, cdc_req_mr_d  : std_logic := '0';
   signal cdc_req_io_d,  cdc_req_pal_d,  cdc_req_oam_d : std_logic := '0';
   signal cdc_wsh_done_d, cdc_vram_done_d         : std_logic := '0';
   signal cdc_mr_done_d                           : std_logic := '0';
   -- island side (clk2x): membus9's raw request pulses / narrowed dones
   signal i9_wsh_ena, i9_vram_ena, i9_mr_ena, i9_io_ena : std_logic;
   signal i9_pal_we,  i9_oam_we                         : std_logic;
   signal i9_wsh_done, i9_vram_done, i9_mr_done, i9_io_done : std_logic;
   -- island-side copy of the IO bus record: nds_top rebuilds io_bus9 from it with
   -- the stretched enable substituted, since only .ena needs to cross
   signal i9_io_bus : proc_bus_gb_type;
   -- island-side capture of the IO request payload, held across the bridge,
   -- and its clk1x re-registration (see io_bus9 below)
   signal io9_lat    : proc_bus_gb_type;
   signal io9_lat_1x : proc_bus_gb_type;
   -- island-side capture of the main-RAM request's SWP lock bit (see mr9_lock)
   signal mr9_lock  : std_logic := '0';
   signal io9_ena   : std_logic := '0';   -- stretched io_bus9.ena, clk1x domain
   signal cdc_dmab_ena_d, dmab_ena_i9   : std_logic := '0';
   signal cdc_cpudone_tgl, cdc_cpudone_tgl_d, cpu9_done_1x : std_logic := '0';
   -- per-transaction IO completion, clk1x -> island (see i9_io_done below)
   signal cdc_io_cpl, cdc_io_cpl_d : std_logic := '0';
   signal dbg_mb9, dbg_cache9, dbg_mr_s      : std_logic_vector(7 downto 0);
   signal dbg_probe                          : std_logic_vector(31 downto 0);
   signal dbg_pk_addr_s        : std_logic_vector(31 downto 0);
   signal dbg_pk_done_s        : std_logic;

   signal ld_wr_ena  : std_logic;
   signal ld_wr_rnw  : std_logic;
   signal ld_wr_addr, ld_wr_data : std_logic_vector(31 downto 0);
   signal ld_wr_done : std_logic;
   signal ld_w7_done : std_logic := '0';

   signal ss_bus9 : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');
   signal ss_bus7 : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');

   -- ================= ARM9 side =================
   signal cpu9_adr      : std_logic_vector(31 downto 0);
   signal cpu9_rnw, cpu9_ena, cpu9_code, cpu9_done, cpu9_lock : std_logic;
   signal cpu9_acc      : std_logic_vector(1 downto 0);
   signal cpu9_dout, cpu9_din, cpu9_lastread : std_logic_vector(31 downto 0);
   signal cpu9_lowbits  : std_logic_vector(1 downto 0);
   signal error_cpu9    : std_logic;
   signal cpu9_irq, cpu9_unhalt, cpu9_halt : std_logic;
   signal cpu9_dbg_r0, cpu9_dbg_lr, cpu9_dbg_cpsr : std_logic_vector(31 downto 0);

   signal cp15_itcm_ena, cp15_itcm_load : std_logic;
   signal cp15_dtcm_ena, cp15_dtcm_load : std_logic;
   signal cp15_dtcm_base : std_logic_vector(31 downto 12);
   signal cp15_dtcm_size, cp15_itcm_size : std_logic_vector(4 downto 0);
   signal bus_cacheable_i, bus_cacheable_d : std_logic;
   signal cache_op_ena, cache_op_busy : std_logic;
   signal cache_op      : std_logic_vector(3 downto 0);
   signal cache_op_addr : std_logic_vector(31 downto 0);

   -- TCM stores (M10K, see iitcm/idtcm instances)
   signal itcm_addr : unsigned(14 downto 2);
   signal itcm_we   : std_logic;
   signal itcm_be   : std_logic_vector(3 downto 0);
   signal itcm_writedata, itcm_readdata : std_logic_vector(31 downto 0);
   -- DTCM port A is the read port; the store is deferred onto port B (dtcm_*_b)
   signal dtcm_addr : unsigned(13 downto 2);
   signal dtcm_readdata : std_logic_vector(31 downto 0);
   signal dtcm_addr_b : unsigned(13 downto 2);
   signal dtcm_we_b   : std_logic;
   signal dtcm_be_b   : std_logic_vector(3 downto 0);
   signal dtcm_writedata_b : std_logic_vector(31 downto 0);

   signal brom_addr : unsigned(14 downto 2);
   signal brom_data : std_logic_vector(31 downto 0);

   signal wsh9_ena, wsh9_rnw, wsh9_done, wsh9_mapped : std_logic;
   signal wsh9_addr : unsigned(14 downto 2);
   signal wsh9_be   : std_logic_vector(3 downto 0);
   signal wsh9_din, wsh9_dout : std_logic_vector(31 downto 0);

   signal vram9_ena, vram9_rnw, vram9_done : std_logic;
   signal vram9_addr : unsigned(23 downto 2);
   signal vram9_be   : std_logic_vector(3 downto 0);
   signal vram9_din, vram9_dout : std_logic_vector(31 downto 0);

   signal pal_we, oam_we : std_logic;
   signal pal_addr, oam_addr : integer range 0 to 511;
   signal pal_din, oam_din : std_logic_vector(31 downto 0);
   signal pal_be, oam_be : std_logic_vector(3 downto 0);
   signal pal_we_a, pal_we_b, oam_we_a, oam_we_b : std_logic;
   signal pal_addr_lo, oam_addr_lo : integer range 0 to 255;

   signal mr9_ena, mr9_rnw, mr9_done : std_logic;
   signal mr9_addr : std_logic_vector(21 downto 2);
   signal mr9_be   : std_logic_vector(3 downto 0);
   signal mr9_writedata, mr9_readdata : std_logic_vector(31 downto 0);

   signal io_bus9 : proc_bus_gb_type;
   signal io_wired_out9, irq_wired_out9, timer_wired_out9 : std_logic_vector(31 downto 0);
   signal io_wired_done9, irq_wired_done9, timer_wired_done9 : std_logic;
   signal ipc_wired_out9, sys_wired_out9 : std_logic_vector(31 downto 0);
   signal ipc_wired_done9, sys_wired_done9 : std_logic;
   signal tim_wired_out9, g2d_wired_out, g2db_wired_out : std_logic_vector(31 downto 0);
   signal tim_wired_done9, g2d_wired_done, g2db_wired_done : std_logic;
   signal dma_wired_out : std_logic_vector(31 downto 0);
   signal dma_wired_done : std_logic;
   signal io_bus9b : proc_bus_gb_type;

   -- ARM9 DMA bus mastering
   signal cpu9_bus_idle : std_logic;
   signal dma_on, dma_bus_on : std_logic;
   signal dmab_ena, dmab_rnw : std_logic;
   signal dmab_adr  : std_logic_vector(31 downto 0);
   signal dmab_acc  : std_logic_vector(1 downto 0);
   signal dmab_low  : std_logic_vector(1 downto 0);
   signal dmab_dout : std_logic_vector(31 downto 0);
   signal irq_dma9  : std_logic_vector(3 downto 0);
   signal mbus_adr, mbus_dout : std_logic_vector(31 downto 0);
   signal mbus_rnw, mbus_ena, mbus_code : std_logic;
   signal mbus_acc, mbus_low : std_logic_vector(1 downto 0);
   signal key_wired_out9 : std_logic_vector(31 downto 0);
   signal key_wired_done9 : std_logic;
   signal irq_in9    : std_logic_vector(31 downto 0);
   signal irq9_dbg_ime, irq9_dbg_ie, irq9_dbg_if : std_logic_vector(31 downto 0);
   signal irq7_dbg_ime, irq7_dbg_ie, irq7_dbg_if : std_logic_vector(31 downto 0);
   signal irq9_any : std_logic;
   signal irp_timer9 : std_logic_vector(3 downto 0);
   signal ipc9_irq_sync, ipc9_irq_sendempty, ipc9_irq_recv : std_logic;

   -- game-card slot
   signal card_wired_out9, card_wired_out7   : std_logic_vector(31 downto 0);
   signal card_wired_done9, card_wired_done7 : std_logic;

   -- RTC
   signal rtc_wired_out7  : std_logic_vector(31 downto 0);
   signal rtc_wired_done7 : std_logic;

   -- sound
   signal snd_wired_out7  : std_logic_vector(31 downto 0);
   signal snd_wired_done7 : std_logic;
   signal snd_bus_req     : std_logic;
   signal snd_bus_ok      : std_logic;
   signal snd_bus_own     : std_logic;
   signal sndb7_ena       : std_logic;
   signal sndb7_adr       : std_logic_vector(31 downto 0);
   signal cpu7_pause      : std_logic;
   signal dma7_idle_ok    : std_logic;

   -- ARM7 DMA (mux onto the membus7 CPU port, ARM9 dmab idiom)
   signal cpu7_bus_idle   : std_logic;
   signal dma7_on, dma7_bus_on : std_logic;
   signal dmab7_ena, dmab7_rnw : std_logic;
   signal dmab7_adr       : std_logic_vector(31 downto 0);
   signal dmab7_acc       : std_logic_vector(1 downto 0);
   signal dmab7_low       : std_logic_vector(1 downto 0);
   signal dmab7_dout      : std_logic_vector(31 downto 0);
   signal mbus7_adr, mbus7_dout : std_logic_vector(31 downto 0);
   signal mbus7_rnw, mbus7_ena  : std_logic;
   signal mbus7_acc       : std_logic_vector(1 downto 0);
   signal mbus7_low       : std_logic_vector(1 downto 0);
   signal dma7_wired_out  : std_logic_vector(31 downto 0);
   signal dma7_wired_done : std_logic;
   signal irq_dma7        : std_logic_vector(3 downto 0);
   signal irq9_card, irq7_card               : std_logic;
   signal dma9_card_trig, dma7_card_trig     : std_logic;
   signal exmem_card7_s                      : std_logic;
   signal cardm_ena                          : std_logic;
   signal cardm_addr                         : std_logic_vector(26 downto 2);
   signal ld_card_ena                        : std_logic;
   signal ld_card_addr                       : std_logic_vector(26 downto 2);
   signal irq9_vblank, irq9_hblank, irq9_vcount : std_logic;
   signal dbg_vbl_ena9 : std_logic;

   -- ================= ARM7 side =================
   signal cpu7_adr      : std_logic_vector(31 downto 0);
   signal cpu7_rnw, cpu7_ena, cpu7_done, cpu7_lock : std_logic;
   -- MEASURED 2026-07-25: the DS clocks the ARM9 at 67.028 MHz and the ARM7 at
   -- 33.514 - a 2:1 ratio. Both cores here run on clk1x with ce='1', so the ARM9
   -- is at HALF its correct relative speed. That skew breaks the NitroSDK
   -- IPCSYNC boot handshake: the ARM7 writes its nibble, delays 593
   -- instructions, and reads back before the ARM9 reaches its echo loop, so the
   -- countdown runs one step offset forever. Proven by slowing the ARM7: the
   -- ARM9's echo-loop poll count went 8 -> 237 (melonDS oracle: 158).
   -- Do NOT "fix" this by gating cpu7's ce alone: membus7 has no ce port and its
   -- cpu_done is a state level, so the core misses done and dies after 2
   -- instructions (measured). Gating the whole ARM7 subsystem would also
   -- desynchronise it from its own timers, and nds_ipc/nds_wram are shared with
   -- the ARM9. The correct fix is to clock the ARM9 domain at 2x; clk_sys Fmax
   -- is currently 37.68 MHz, so that needs timing work in this domain first.
   signal cpu7_acc      : std_logic_vector(1 downto 0);
   signal cpu7_dout, cpu7_din, cpu7_lastread : std_logic_vector(31 downto 0);
   signal cpu7_lowbits  : std_logic_vector(1 downto 0);
   signal error_cpu7    : std_logic;
   signal cpu7_irq, cpu7_unhalt : std_logic;
   signal cpu7_newhalt : std_logic;

   signal bios_addr  : unsigned(13 downto 2);
   signal bios7_data : std_logic_vector(31 downto 0);

   -- ARM7-private WRAM (64 KB, M10K - see iwram7 instance)
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
   signal spi_wired_out7 : std_logic_vector(31 downto 0);
   signal spi_wired_done7 : std_logic;
   signal irq7_spi : std_logic;
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

   -- renderer channels between nds_vram and nds_gpu2d. *_accept pulses when
   -- the line server takes a request; the BG channels use it so a drawer may
   -- keep several fetches in flight (see nds_vram's pipeline comment).
   signal r_bg_accept, rb_bg_accept : std_logic;
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

   signal rb_bg_req, rb_bg_done       : std_logic;
   signal rb_bg_addr                  : unsigned(16 downto 2);
   signal rb_bg_dout                  : std_logic_vector(31 downto 0);
   signal rb_obj_req, rb_obj_done     : std_logic;
   signal rb_obj_addr                 : unsigned(16 downto 2);
   signal rb_obj_dout                 : std_logic_vector(31 downto 0);
   signal rb_bgep_req, rb_bgep_done   : std_logic;
   signal rb_bgep_addr                : unsigned(14 downto 2);
   signal rb_bgep_dout                : std_logic_vector(31 downto 0);
   signal rb_objep_req, rb_objep_done : std_logic;
   signal rb_objep_addr               : unsigned(12 downto 2);
   signal rb_objep_dout               : std_logic_vector(31 downto 0);

   signal gb_bg_addr    : integer range 0 to 131071;
   signal gb_obj_addr   : integer range 0 to 65535;
   signal gb_bgep_addr  : integer range 0 to 8191;
   signal gb_objep_addr : integer range 0 to 2047;

   -- timing -> gpu2d line control
   signal gpu_ce          : std_logic := '0';
   signal linecounter     : integer range 0 to 191;
   signal linecounter_obj : integer range 0 to 191;
   signal drawline, drawObj, line_trigger, hblank_trigger, gpu_vblank, refpoint_update : std_logic;
   signal line_busy, epfill_busy : std_logic;
   signal dbg_rbusy_s : std_logic;
   signal line_busy_b, epfill_busy_b : std_logic;

   -- engine streams pre-routing
   signal pow_2da, pow_2db, pow_swap : std_logic;
   signal pxa_x, pxb_x       : integer range 0 to 255;
   signal pxa_y, pxb_y       : integer range 0 to 191;
   signal pxa_data, pxb_data : std_logic_vector(17 downto 0);
   signal pxa_we, pxb_we     : std_logic;
   signal pxb_data_eff       : std_logic_vector(17 downto 0);
   signal vcount_out : unsigned(8 downto 0);

begin

   -- =====================================================================
   -- boot: fabric out of reset -> loader copies both sections -> preset
   -- both boot PCs through the savestate buses -> release the CPUs
   -- =====================================================================
   p_boot : process (clk1x)
   begin
      if rising_edge(clk1x) then
         ld_start      <= '0';
         preset_direct <= '0';
         -- dbg_boot_rst is the debugger's SOFTRESET: it re-enters the same
         -- sequence as a real reset (loader, PC presets, CPU release) while the
         -- cart image stays staged in DDR3, so a from-reset differential can be
         -- repeated without reloading the core or the ROM.
         if (reset = '1' or dbg_boot_rst = '1') then
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
                  elsif (ld_done = '1' and ld_busy = '0' and
                         vclr_busy = '0' and pclr_busy_a = '0' and pclr_busy_b = '0') then
                     boot_state  <= B_S9RST;
                     boot_cnt    <= 0;
                     ss_bus9.rst <= '1';
                  end if;

               when B_S9RST =>
                  if (boot_cnt = 2) then
                     ss_bus9.rst <= '0';
                     boot_cnt    <= 0;
                     preset_idx  <= 0;
                     boot_state  <= B_S9GAP;
                  else
                     boot_cnt <= boot_cnt + 1;
                  end if;

               when B_S9GAP =>
                  ss_bus9.Adr  <= std_logic_vector(to_unsigned(preset_adr(preset_idx), ss_bus9.Adr'length));
                  -- Firmware boot enters the ARM9 BIOS at its reset vector instead
                  -- of the cart's entry point. This core does not model the ARM
                  -- reset exception at all - both CPUs start from whatever this
                  -- savestate write puts in fetch_PC - so "just release reset and
                  -- let it vector" boots from 0x00000000 and retires nothing.
                  ss_bus9.Din  <= preset_val(preset_idx, arm9_entry_eff, true);
                  ss_bus9.rnw  <= '0';
                  ss_bus9.bEna <= "1111";
                  ss_bus9.ena  <= '1';
                  boot_state   <= B_S9WR;

               when B_S9WR =>
                  ss_bus9.ena <= '0';
                  ss_bus9.rnw <= '1';
                  boot_cnt    <= 0;
                  -- Firmware boot gets the PC and nothing else: the ARM9 BIOS
                  -- sets up its own stacks, and presetting them here would mask
                  -- a BIOS that never reached that point.
                  if (preset_idx < PRESET_LAST and fw_boot = '0') then
                     preset_idx <= preset_idx + 1;
                     boot_state <= B_S9GAP;
                  else
                     boot_state <= B_S9POST;
                  end if;

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
                     preset_idx  <= 0;
                     boot_state  <= B_S7GAP;
                  else
                     boot_cnt <= boot_cnt + 1;
                  end if;

               when B_S7GAP =>
                  ss_bus7.Adr  <= std_logic_vector(to_unsigned(preset_adr(preset_idx), ss_bus7.Adr'length));
                  ss_bus7.Din  <= preset_val(preset_idx, arm7_entry_eff, false);
                  ss_bus7.rnw  <= '0';
                  ss_bus7.bEna <= "1111";
                  ss_bus7.ena  <= '1';
                  boot_state   <= B_S7WR;

               when B_S7WR =>
                  ss_bus7.ena <= '0';
                  ss_bus7.rnw <= '1';
                  boot_cnt    <= 0;
                  if (preset_idx < PRESET_LAST and fw_boot = '0') then
                     preset_idx <= preset_idx + 1;
                     boot_state <= B_S7GAP;
                  else
                     boot_state <= B_S7POST;
                  end if;

               when B_S7POST =>
                  if (boot_cnt = 2) then
                     boot_cnt   <= 0;
                     boot_state <= B_RUN;
                  else
                     boot_cnt <= boot_cnt + 1;
                  end if;

               when B_RUN =>
                  resetCpu <= '0';
                  -- firmware-left registers: pulsed WITH the reset release, not at
                  -- ld_done - nds_syscnt resets on resetCpu, which swallows any
                  -- earlier preset (WRAMCNT=0 then let the calico crt0 section copy
                  -- to 0x037F8000 mirror into WRAM7 over the ARM7 stack)
                  if (boot_cnt = 0) then
                     boot_cnt      <= 1;
                     preset_direct <= direct_boot;
                  end if;

               when B_ERROR =>
                  null;

            end case;
         end if;
      end if;
   end process;

   boot_done  <= '1' when boot_state = B_RUN else '0';
   boot_error <= '1' when boot_state = B_ERROR else '0';

   iloader : entity work.nds_loader
   generic map ( is_simu => is_simu, skip_copy => skip_copy )
   port map
   (
      clk => clk1x, reset => reset_boot,
      start => ld_start, direct => direct_boot, fw_boot => fw_boot,
      busy => ld_busy, done => ld_done, load_error => ld_error,
      arm9_entry => arm9_entry, arm7_entry => arm7_entry, cart_id => ld_cartid,
      card_ena => ld_card_ena, card_addr => ld_card_addr,
      card_done => card_done, card_rdata => card_din,
      wr_ena => ld_wr_ena, wr_rnw => ld_wr_rnw,
      wr_addr => ld_wr_addr, wr_data => ld_wr_data,
      wr_done => ld_wr_done, rd_data => mem9_readdata,
      vfy_bad => dbg_vfy_bad, vfy_addr => dbg_vfy_addr
   );

   arm9_entry_eff <= x"FFFF0000" when (fw_boot = '1') else arm9_entry;
   arm7_entry_eff <= x"00000000" when (fw_boot = '1') else arm7_entry;

   -- card image port: the loader owns it during boot, the slot module after
   -- (the CPUs are in reset while ld_busy, so no ROMCTRL transfer can overlap)
   card_ena  <= ld_card_ena  when ld_busy = '1' else cardm_ena;
   card_addr <= ld_card_addr when ld_busy = '1' else cardm_addr;

   icard : entity work.nds_card
   port map
   (
      clk => clk1x, ce => '1', reset => resetCpu,
      card7 => exmem_card7_s,
      fw_boot => fw_boot,
      chipid => ld_cartid,
      bus9 => io_bus9, wired_out9 => card_wired_out9, wired_done9 => card_wired_done9,
      bus7 => io_bus7, wired_out7 => card_wired_out7, wired_done7 => card_wired_done7,
      irq9_xfer => irq9_card, irq7_xfer => irq7_card,
      dma9_card => dma9_card_trig, dma7_card => dma7_card_trig,
      card_ena => cardm_ena, card_addr => cardm_addr,
      card_din => card_din, card_done => card_done
   );

   -- loader writes route by target: main RAM (0x02xxxxxx) via main-RAM port 9,
   -- ARM7-private WRAM (0x037xxxxx) straight into the store (CPUs are in reset)
   ld_to_main  <= '1' when (ld_busy = '1' and ld_wr_addr(31 downto 24) = x"02") else '0';
   ld_to_wram7 <= '1' when (ld_busy = '1' and ld_wr_addr(31 downto 24) = x"03") else '0';

   -- ARM9 main-RAM channel has three possible owners, in priority order: the
   -- loader (boot copy + its verify pass), the debug unit's peek, then the CPU.
   -- dbg_pk_sel stays asserted for the whole peek so address/rnw hold until the
   -- op completes; the CPU's own done is suppressed for both borrowed cases.
   idbgpk : process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (reset = '1') then
            dbg_pk_act <= '0';
         elsif (dbg_pk_ena = '1') then
            dbg_pk_act <= '1';
         elsif (mem9_done = '1') then
            dbg_pk_act <= '0';
         end if;
      end if;
   end process;
   dbg_pk_sel <= dbg_pk_ena or dbg_pk_act;

   mem9_ena       <= (ld_wr_ena and ld_to_main) when ld_busy = '1' else
                     dbg_pk_ena                 when dbg_pk_sel = '1' else mr9_ena;
   mem9_rnw       <= ld_wr_rnw                  when ld_busy = '1' else
                     '1'                        when dbg_pk_sel = '1' else mr9_rnw;
   mem9_addr      <= ld_wr_addr(21 downto 2)    when ld_busy = '1' else
                     dbg_pk_addr_s(21 downto 2) when dbg_pk_sel = '1' else mr9_addr;
   mem9_be        <= "1111"                     when ld_busy = '1' else
                     "1111"                     when dbg_pk_sel = '1' else mr9_be;
   mem9_writedata <= ld_wr_data                 when ld_busy = '1' else mr9_writedata;
   mr9_done       <= mem9_done and not ld_busy and not dbg_pk_sel;
   mr9_readdata   <= mem9_readdata;
   dbg_pk_done_s  <= mem9_done and dbg_pk_sel;

   reset_boot <= reset or dbg_boot_rst;

   -- ================= ARM9 67 MHz island: clk1x <-> clk2x bridge =================
   -- clk2x is exactly 2x clk1x from one VCO at 0 ps, so this is a *related*-clock
   -- crossing, not an asynchronous one - no metastability, but the pulse widths
   -- still have to be reconciled: a 1-clk2x pulse is half a clk1x period and
   -- clk1x would miss it, and a 1-clk1x pulse is two clk2x cycles and the island
   -- would count it twice.
   --
   -- Only the pulses cross. membus9 holds address/data/byte-enables stable for the
   -- whole transaction (nds_cache9's own comment relies on this: "the membus holds
   -- them until resp_done"), and it has at most ONE external access in flight, so
   -- the level signals are wired straight through.
   --
   -- Request handshake, clk2x -> clk1x, TOGGLE based. A sticky-bit stretch is
   -- phase-dependent and silently drops half the requests: ph1x is high on the
   -- island cycle right after a clk1x edge, so a sticky set in the *second* half
   -- of a clk1x period is cleared before clk1x ever samples it. A toggle has no
   -- such window - the island flips it once per request and it then sits stable
   -- until the transaction completes (membus9 issues at most one external access
   -- at a time and waits), so the clk1x edge-detector fires exactly once.
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if (resetCpu = '1') then
            cdc_req_wsh  <= '0'; cdc_req_vram <= '0'; cdc_req_mr <= '0';
            cdc_req_io   <= '0'; cdc_req_pal  <= '0'; cdc_req_oam <= '0';
         else
            if (i9_wsh_ena  = '1') then cdc_req_wsh  <= not cdc_req_wsh;  end if;
            if (i9_vram_ena = '1') then cdc_req_vram <= not cdc_req_vram; end if;
            if (i9_mr_ena   = '1') then cdc_req_mr   <= not cdc_req_mr;   end if;
            -- membus9's IO request is a record field, not the (never-driven)
            -- standalone signal this used to test - which silently killed every
            -- ARM9 IO access across the bridge, IPCSYNC included.
            if (i9_io_bus.ena = '1') then cdc_req_io <= not cdc_req_io; end if;
            if (i9_pal_we   = '1') then cdc_req_pal  <= not cdc_req_pal;  end if;
            if (i9_oam_we   = '1') then cdc_req_oam  <= not cdc_req_oam;  end if;
         end if;
      end if;
   end process;

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         cdc_req_wsh_d  <= cdc_req_wsh;
         cdc_req_vram_d <= cdc_req_vram;
         cdc_req_mr_d   <= cdc_req_mr;
         cdc_req_io_d   <= cdc_req_io;
         cdc_req_pal_d  <= cdc_req_pal;
         cdc_req_oam_d  <= cdc_req_oam;
         wsh9_ena  <= cdc_req_wsh  xor cdc_req_wsh_d;
         vram9_ena <= cdc_req_vram xor cdc_req_vram_d;
         mr9_ena   <= cdc_req_mr   xor cdc_req_mr_d;
         io9_ena   <= cdc_req_io   xor cdc_req_io_d;
         pal_we    <= cdc_req_pal  xor cdc_req_pal_d;
         oam_we    <= cdc_req_oam  xor cdc_req_oam_d;
      end if;
   end process;

   -- everything except .ena is a stable level for the whole transaction
   -- IO payload latch, island -> clk1x. Only `ena` was synchronised across the
   -- bridge; Adr/Din/bEna/rnw were taken live from the island signal. membus9
   -- asserts io_bus.ena for ONE island cycle and then enters FINISH, where
   -- accept_now is already true - so it can accept the next request and overwrite
   -- the payload on the following island cycle, a full clk1x edge before the IO
   -- fabric samples it. The write then landed with whatever had replaced it.
   --
   -- This is why the screen was white. The ARM9 wrote IPCSYNC 59 times and
   -- nds_ipc applied every one of them with a data nibble of 0, so sync9_out never
   -- left 0, the ARM7 read 0x0800 instead of 0x0808 and the boot handshake never
   -- completed; DISPCNT was programmed with garbage for the same reason. None of it
   -- was visible in the ARM9's instruction trace, which stayed byte-identical to
   -- melonDS for 1.29M instructions - a store that goes astray does not touch the
   -- CPU's registers.
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if (i9_io_bus.ena = '1') then
            io9_lat <= i9_io_bus;
         end if;
      end if;
   end process;

   -- ...and then re-registered onto clk1x before it reaches the peripherals.
   -- io9_lat is a clk2x flop, so driving the IO fabric straight from it left
   -- every peripheral's address decode inside a clk2x -> clk1x crossing with
   -- only 14.915 ns. That was the whole remaining clk1x failing family once
   -- mem9_lock was fixed - `io9_lat.Adr[5] -> nds_card|delay_cnt[*]` at
   -- -1.959 ns, the card's cycle-count decode hanging off the bridge.
   --
   -- Unconditional, and it costs no latency. io9_lat is written on the island
   -- edge that toggles cdc_req_io, and io9_ena cannot rise before the clk1x
   -- edge that first sees that toggle - the same edge this captures on - so the
   -- payload is already valid in the cycle the enable is asserted. It also
   -- cannot move underneath the access: membus9 has one IO transaction in
   -- flight at a time and waits in W_IO_RESP for cdc_io_cpl, which is not
   -- toggled until the end of the enable cycle.
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         io9_lat_1x <= io9_lat;
      end if;
   end process;

   io_bus9 <= (Din  => io9_lat_1x.Din,  Adr  => io9_lat_1x.Adr,
               rnw  => io9_lat_1x.rnw,  ena  => io9_ena,
               acc  => io9_lat_1x.acc,  bEna => io9_lat_1x.bEna,
               rst  => i9_io_bus.rst);

   -- Main-RAM SWP lock, island -> clk1x. Same payload-latch reasoning as io9_lat
   -- above, but this one was a *timing* bug rather than a functional one, and it
   -- was the whole worst-path family: `cpu9_lock and not bus_cacheable_d` was
   -- wired live into nds_mainram's mem9_lock, so nds_mainram's clk1x req9_lock
   -- flop closed a combinational path that started at the ARM9's register file
   -- and ran through the shifter, the ALU, the writeback mux, the address mux
   -- and the CP15 PU region compare - 18.48 ns into a 14.915 ns clk2x->clk1x
   -- relationship. All 50 paths in the global -npaths 50 report ended here.
   --
   -- Nothing about that was necessary. req9_lock only samples mem9_lock in the
   -- clk1x cycle where mem9_ena is high, and mem9_ena is mr9_ena - the toggle
   -- edge-detect above, which cannot fire until at least one clk1x edge AFTER
   -- the island raised i9_mr_ena. Latching the term in the island at the instant
   -- the request is launched therefore delivers the identical value with a full
   -- clk1x period of settling, and turns the crossing into flop -> flop.
   --
   -- dma_bus_on / ld_busy stay live at the port: both are clk1x registers that
   -- hold for the whole burst, so they cost one LUT and no cross-domain cone.
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if (resetCpu = '1') then
            mr9_lock <= '0';
         elsif (i9_mr_ena = '1') then
            mr9_lock <= cpu9_lock and not bus_cacheable_d;
         end if;
      end if;
   end process;

   -- Done narrow, clk1x -> clk2x. A 1-clk1x done is high for two clk2x cycles;
   -- edge-detect so the island's FSM sees exactly one.
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         cdc_wsh_done_d  <= wsh9_done;
         cdc_vram_done_d <= vram9_done;
         cdc_mr_done_d   <= mr9_done;
      end if;
   end process;
   -- DMA9 masters the ARM9 membus while dma_bus_on, but nds_dma9 is a clk1x unit
   -- talking to a clk2x membus, so its request pulse is two island cycles wide
   -- (membus9 would accept it twice) and membus9's one-island-cycle done is only
   -- half a clk1x period (nds_dma9 would miss it). Narrow one, stretch the other.
   -- The CPU's own path needs neither: cpu9 is inside the island.
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         cdc_dmab_ena_d <= dmab_ena;
      end if;
   end process;
   dmab_ena_i9 <= dmab_ena and not cdc_dmab_ena_d;

   -- membus9's cpu_done is one ISLAND cycle - half a clk1x period - so a clk1x
   -- process sampling it directly would miss it half the time (the same defect
   -- the request path had). Toggle in the island, edge-detect in clk1x.
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if (cpu9_done = '1') then cdc_cpudone_tgl <= not cdc_cpudone_tgl; end if;
      end if;
   end process;

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         cdc_cpudone_tgl_d <= cdc_cpudone_tgl;
         cpu9_done_1x      <= cdc_cpudone_tgl xor cdc_cpudone_tgl_d;
      end if;
   end process;

   i9_wsh_done  <= wsh9_done       and not cdc_wsh_done_d;
   i9_vram_done <= vram9_done      and not cdc_vram_done_d;
   i9_mr_done   <= mr9_done        and not cdc_mr_done_d;

   -- IO completion, clk1x -> island. io_wired_done9 is a pure address decode
   -- ("some peripheral claims this address"), not a per-transaction event, so
   -- edge-detecting it fires once and then never again across back-to-back IO
   -- accesses to claimed addresses. Generate an explicit completion one clk1x
   -- after the access was presented: by then the peripheral has seen io_bus9.ena
   -- and its wired_out is stable (the payload latch holds Adr), so the island can
   -- sample the read data in the cycle it retires the access.
   --
   -- Unconditional on purpose - it must fire for UNCLAIMED addresses too, or
   -- membus9 would hang in W_IO_RESP on any unmapped IO read. That is still
   -- correct data: io_wired_out9 is a wired-OR tree and reads 0 when nothing
   -- claims the address, which is what an NDS9 unclaimed IO read returns.
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (io9_ena = '1') then cdc_io_cpl <= not cdc_io_cpl; end if;
      end if;
   end process;

   process (clk2x)
   begin
      if rising_edge(clk2x) then
         cdc_io_cpl_d <= cdc_io_cpl;
      end if;
   end process;

   i9_io_done   <= cdc_io_cpl xor cdc_io_cpl_d;


   -- out ports are write-only in VHDL-93; nds_debug reads the internals
   dbg_pc9 <= pc9_s;
   dbg_pc7 <= pc7_s;

   -- PROBE word (mailbox op 0x0A). Byte 3 is the top-level mux state, which is
   -- what decides whether a cache request ever reaches nds_mainram at all.
   -- Bit 18 is nds_mainram's spare '0' in dbg_mr_s(2); it now carries the ARM9's
   -- persistent DISPSTAT bit 3 (VBlank IRQ enable). Diagnostic only.
   --
   -- WHY: Kirby freezes on hardware with the ARM9 asleep in the NitroSDK idle
   -- thread's WFI at 0x0214FC08, IE9 VBlank enabled, and IF9 bit 0 NEVER latching
   -- - while the ARM7 does receive VBlank. reach9 proves Kirby's DISPSTAT-writing
   -- code IS executed (0x02143A4C, 0x02143AF0), and the sim sees the write land on
   -- the bus as `VIDREG A +004 = 0000000B bEna=3`, bit 3 set. So the open question
   -- is exactly whether R_vbl_irq_ena(0) holds that bit, and nothing readable
   -- answered it: the earlier dbg_vbl_ena9 probe was never exported, and the DDR3
   -- telemetry lane is clobbered by the framebuffer on a white screen. The mailbox
   -- probe is the one channel that returns clean data.
   dbg_probe <= dma_bus_on & ld_busy & dbg_pk_sel & mem9_done &
                mem9_ena & mr9_ena & mr9_done & cpu9_ena &
                dbg_mr_s(7 downto 3) & dbg_vbl_ena9 & dbg_mr_s(1 downto 0) &
                dbg_mb9 & dbg_cache9;

   idebug : entity work.nds_debug
   generic map
   (
      -- '0' = play image: the cores boot on their own. Set to `not is_simu` for a
      -- diagnostic image, which leaves both cores held out of reset so a
      -- debugger can arm breakpoints before the first instruction retires
      -- (without it the boot FSM's B_RUN drops resetCpu and the game is millions
      -- of instructions in before a host can attach). Simulation must never
      -- hold: it is the golden reference for that differential, and holding
      -- there yields a boot_done with zero retired instructions and an empty
      -- trace. The mailbox itself stays usable either way.
      BOOT_HOLD => '0'
   )
   port map
   (
      clk      => clk1x,
      reset    => reset,
      cmd_stb  => dbg_cmd_stb,
      cmd_op   => dbg_cmd_op,
      cmd_arg  => dbg_cmd_arg,
      rsp_data => dbg_rsp_data,
      rsp_stb  => dbg_rsp_stb,
      hold9    => dbg_hold9,
      rel9     => dbg_rel9,
      hold7    => dbg_hold7,
      rel7     => dbg_rel7,
      boot_rst => dbg_boot_rst,
      regsel   => dbg_regsel_s,
      regval9  => dbg_regval9,
      regval7  => dbg_regval7,
      pc9      => pc9_s,
      pc7      => pc7_s,
      probe    => dbg_probe,
      irq9_ime => irq9_dbg_ime, irq9_ie => irq9_dbg_ie, irq9_if => irq9_dbg_if,
      irq7_ime => irq7_dbg_ime, irq7_ie => irq7_dbg_ie, irq7_if => irq7_dbg_if,
      pk_ena   => dbg_pk_ena,
      pk_addr  => dbg_pk_addr_s,
      pk_done  => dbg_pk_done_s,
      pk_data  => mem9_readdata
   );

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         ld_w7_done <= ld_wr_ena and ld_to_wram7;
      end if;
   end process;
   ld_wr_done <= ld_w7_done when ld_to_wram7 = '1' else mem9_done;

   -- ================= ARM9 CPU + membus =================
   ibios9 : entity work.nds_bios9
   generic map
   (
      is_simu => is_simu,
      use_cyclone5_primitive => not is_simu
   )
   port map
   (
      -- clk2x, NOT clk1x. This is a synchronous RAM whose read address comes
      -- combinationally from the island's cpu_adr (nds_membus9.vhd:191) and
      -- whose data is consumed combinationally in the island's FINISH state
      -- (nds_membus9.vhd:508) - there is no done handshake on T_BROM at all.
      -- On clk1x the ROM only sampled the address on every OTHER island cycle,
      -- so every second BIOS9 fetch returned the previous word, and the first
      -- fetch after reset returned whatever was latched (word 0).
      --
      -- That is what put Kirby's ARM9 into ITCM garbage. The Thumb `swi 0x0B`
      -- at 0x020002BE vectored correctly to 0xFFFF0008, but the fetch there
      -- delivered word 0 (the reset vector, EA000042) instead of the SWI vector
      -- (EA0000A2), so it branched to 0xFFFF0120 - the middle of the CRC16
      -- helper - and executed the BIOS from there with every other word stale
      -- until `ldr pc,[r0,#-4]` at 0xFFFF0294 threw it into ITCM at 0x00000008.
      -- The ARM7 is the control: its BIOS shares clk1x with its CPU, and all
      -- 488 of its SWI entries fetch the right vector and land in the right
      -- handler.
      --
      -- Safe for the hot-load write port too: it is fed from the ioctl download
      -- (NDS.sv:421), which finishes long before the CPUs are released, and
      -- clocking it at 2x only oversamples the same load_we pulse - worst case
      -- the same word is written twice to the same address, which is idempotent.
      clk       => clk2x,
      brom_addr => brom_addr,
      brom_data => brom_data,
      load_addr => bios9_load_addr,
      load_data => bios9_load_data,
      load_be   => bios9_load_be,
      load_we   => bios9_load_we,
      load_done => bios9_load_done
   );

   icpu9 : entity work.nds_cpu9
   generic map ( is_simu => is_simu )
   port map
   (
      clk             => clk2x,
      ce              => '1',
      reset           => resetCpu,
-- synthesis translate_off
      cpu_export_done => dbg_export9_done,
      cpu_export      => dbg_export9,
-- synthesis translate_on
      error_cpu       => error_cpu9,
      dbg_pc          => pc9_s,
      dbg_r0          => cpu9_dbg_r0,
      dbg_lr          => cpu9_dbg_lr,
      dbg_cpsr        => cpu9_dbg_cpsr,
      dbg_regsel      => dbg_regsel_s,
      dbg_regval      => dbg_regval9,
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
      dma_on          => dma_on,
      done            => open,
      CPU_bus_idle    => cpu9_bus_idle,
      PC_in_BIOS      => open,
      cpu_halt        => cpu9_halt,
      lastread        => cpu9_lastread,
      jump_out        => open,
      IRQ_in          => cpu9_irq,
      unhalt          => cpu9_unhalt or dbg_rel9,
      new_halt        => dbg_hold9,
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
   generic map ( is_simu => is_simu )
   port map
   (
      clk => clk2x, reset => resetCpu,
      bus_cacheable_i => bus_cacheable_i, bus_cacheable_d => bus_cacheable_d,
      cache_op_ena => cache_op_ena, cache_op => cache_op,
      cache_op_addr => cache_op_addr, cache_op_busy => cache_op_busy,
      itcm_ena => cp15_itcm_ena, itcm_load => cp15_itcm_load, itcm_size => cp15_itcm_size,
      dtcm_ena => cp15_dtcm_ena, dtcm_load => cp15_dtcm_load,
      dtcm_base => cp15_dtcm_base, dtcm_size => cp15_dtcm_size,
      dma_bus => dma_bus_on,
      cpu_adr => mbus_adr, cpu_rnw => mbus_rnw, cpu_ena => mbus_ena, cpu_code => mbus_code,
      cpu_acc => mbus_acc, cpu_dout => mbus_dout, cpu_lowbits => mbus_low,
      -- cpu_done stays island-native: membus9 and icpu9 are both on clk2x, so the
      -- CPU's own handshake needs no crossing. The clk1x stretch below is only for
      -- nds_dma9, which lives outside the island.
      cpu_lastread => cpu9_lastread, cpu_din => cpu9_din, cpu_done => cpu9_done,
      itcm_addr => itcm_addr, itcm_we => itcm_we, itcm_be => itcm_be,
      itcm_writedata => itcm_writedata, itcm_readdata => itcm_readdata,
      dtcm_addr => dtcm_addr, dtcm_readdata => dtcm_readdata,
      dtcm_addr_b => dtcm_addr_b, dtcm_we_b => dtcm_we_b,
      dtcm_be_b => dtcm_be_b, dtcm_writedata_b => dtcm_writedata_b,
      brom_addr => brom_addr, brom_data => brom_data,
      wsh_ena => i9_wsh_ena, wsh_rnw => wsh9_rnw, wsh_addr => wsh9_addr, wsh_be => wsh9_be,
      wsh_din => wsh9_din, wsh_dout => wsh9_dout, wsh_done => i9_wsh_done, wsh_mapped => wsh9_mapped,
      vram_ena => i9_vram_ena, vram_rnw => vram9_rnw, vram_addr => vram9_addr, vram_be => vram9_be,
      vram_din => vram9_din, vram_dout => vram9_dout, vram_done => i9_vram_done,
      pal_we => i9_pal_we, pal_addr => pal_addr, pal_din => pal_din, pal_be => pal_be,
      oam_we => i9_oam_we, oam_addr => oam_addr, oam_din => oam_din, oam_be => oam_be,
      mr_ena => i9_mr_ena, mr_rnw => mr9_rnw, mr_addr => mr9_addr, mr_be => mr9_be,
      mr_writedata => mr9_writedata, mr_done => i9_mr_done, mr_readdata => mr9_readdata,
      io_ce_next => '1',
      io_bus => i9_io_bus, io_wired_out => io_wired_out9, io_wired_done => i9_io_done,
      dbg_mb => dbg_mb9, dbg_cache => dbg_cache9
   );

   -- ARM9 bus mux: the DMA owns the membus while dma_bus_on (CPU paused
   -- via dma_on and drained via CPU_bus_idle before the grant)
   mbus_adr  <= dmab_adr  when dma_bus_on = '1' else cpu9_adr;
   mbus_rnw  <= dmab_rnw  when dma_bus_on = '1' else cpu9_rnw;
   mbus_ena  <= dmab_ena_i9 when dma_bus_on = '1' else cpu9_ena;
   mbus_code <= '0'       when dma_bus_on = '1' else cpu9_code;
   mbus_acc  <= dmab_acc  when dma_bus_on = '1' else cpu9_acc;
   mbus_dout <= dmab_dout when dma_bus_on = '1' else cpu9_dout;
   mbus_low  <= dmab_low  when dma_bus_on = '1' else cpu9_lowbits;

   idma9 : entity work.nds_dma9
   port map
   (
      clk          => clk1x,
      reset        => resetCpu,
      gb_bus       => io_bus9,
      wired_out    => dma_wired_out,
      wired_done   => dma_wired_done,
      trig_vblank  => gpu_vblank,
      trig_hblank  => hblank_trigger,
      trig_card    => dma9_card_trig,
      cpu_bus_idle => cpu9_bus_idle,
      dma_on       => dma_on,
      dma_bus_on   => dma_bus_on,
      mb_ena       => dmab_ena,
      mb_rnw       => dmab_rnw,
      mb_adr       => dmab_adr,
      mb_acc       => dmab_acc,
      mb_lowbits   => dmab_low,
      mb_dout      => dmab_dout,
      mb_din       => cpu9_din,
      -- nds_dma9 is outside the island (clk1x), so it needs the stretched form of
      -- membus9's one-island-cycle done, not the raw signal.
      mb_done      => cpu9_done_1x,
      irq_dma      => irq_dma9
   );

   -- TCM stores: M10K. The membus presents address/write combinationally in
   -- the accept cycle; the BRAM registers the address, so read data is valid
   -- in the FINISH cycle - same bus timing as the old asynchronous arrays.
   iitcm : entity MEM.SyncRamDualByteEnable
   generic map
   (
      is_simu     => is_simu,
      is_cyclone5 => '1',
      BYTE_WIDTH  => 8,
      ADDR_WIDTH  => 13,
      BYTES       => 4
   )
   port map
   (
      clk       => clk2x,
      ce_a      => '1',
      addr_a    => to_integer(itcm_addr),
      datain_a0 => itcm_writedata( 7 downto  0),
      datain_a1 => itcm_writedata(15 downto  8),
      datain_a2 => itcm_writedata(23 downto 16),
      datain_a3 => itcm_writedata(31 downto 24),
      dataout_a => itcm_readdata,
      we_a      => itcm_we,
      be_a      => itcm_be,
      ce_b      => '0',
      addr_b    => 0,
      datain_b0 => x"00", datain_b1 => x"00", datain_b2 => x"00", datain_b3 => x"00",
      dataout_b => open,
      we_b      => '0',
      be_b      => "0000"
   );

   idtcm : entity MEM.SyncRamDualByteEnable
   generic map
   (
      is_simu     => is_simu,
      is_cyclone5 => '1',
      BYTE_WIDTH  => 8,
      ADDR_WIDTH  => 12,
      BYTES       => 4
   )
   port map
   (
      clk       => clk2x,
      -- Port A: READ ONLY. The write moved to port B so its enable comes off a
      -- flop instead of off the CPU's address - see the "DTCM deferred store"
      -- comment in nds_membus9. Tying the port-A write inputs off (rather than
      -- leaving them driven with we_a = '0') is what lets Quartus prune the
      -- shifter -> datain_a cone, which is half the point of the change.
      ce_a      => '1',
      addr_a    => to_integer(dtcm_addr),
      datain_a0 => x"00", datain_a1 => x"00", datain_a2 => x"00", datain_a3 => x"00",
      dataout_a => dtcm_readdata,
      we_a      => '0',
      be_a      => "0000",
      -- Port B: the deferred store, one cycle behind the accept.
      ce_b      => '1',
      addr_b    => to_integer(dtcm_addr_b),
      datain_b0 => dtcm_writedata_b( 7 downto  0),
      datain_b1 => dtcm_writedata_b(15 downto  8),
      datain_b2 => dtcm_writedata_b(23 downto 16),
      datain_b3 => dtcm_writedata_b(31 downto 24),
      dataout_b => open,
      we_b      => dtcm_we_b,
      be_b      => dtcm_be_b
   );

   -- ================= ARM7 CPU + membus =================
   icpu7 : entity work.gba_cpu
   generic map ( is_simu => is_simu )
   port map
   (
      clk             => clk1x,
      ce              => '1',
      reset           => resetCpu,
-- synthesis translate_off
      cpu_export_done => dbg_export7_done,
      cpu_export      => dbg_export7,
-- synthesis translate_on
      error_cpu       => error_cpu7,
      dbg_pc          => pc7_s,
      dbg_regsel      => dbg_regsel_s,
      dbg_regval      => dbg_regval7,
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
      dma_on          => cpu7_pause,
      done            => open,
      CPU_bus_idle    => cpu7_bus_idle,
      PC_in_BIOS      => open,
      cpu_halt        => open,
      lastread        => cpu7_lastread,
      jump_out        => open,
      IRQ_in          => cpu7_irq,
      unhalt          => cpu7_unhalt or dbg_rel7,
      new_halt        => cpu7_newhalt or dbg_hold7
   );

   ibios7 : entity work.nds_bios7
   generic map
   (
      is_simu => is_simu,
      use_cyclone5_primitive => not is_simu
   )
   port map
   (
      clk       => clk1x,
      bios_addr => bios_addr,
      bios_data => bios7_data,
      load_addr => bios7_load_addr,
      load_data => bios7_load_data,
      load_be   => bios7_load_be,
      load_we   => bios7_load_we,
      load_done => bios7_load_done
   );

   -- ARM7 bus mux: the DMA owns the membus while dma7_bus_on (CPU paused
   -- via cpu7_pause and drained via cpu7_bus_idle before the grant); the
   -- sound fetch unit is a second, lower-priority guest - it pauses the
   -- CPU the same way (snd_bus_req -> cpu7_pause) but only gets the bus
   -- when DMA7 neither holds nor wants it, and DMA7's grant is held off
   -- while a sound word is in flight (dma7_idle_ok)
   cpu7_pause   <= dma7_on or snd_bus_req;
   dma7_idle_ok <= cpu7_bus_idle and not snd_bus_own;
   snd_bus_ok   <= cpu7_bus_idle and not dma7_on and not dma7_bus_on;

   mbus7_adr  <= dmab7_adr  when dma7_bus_on = '1' else
                 sndb7_adr  when snd_bus_own = '1' else cpu7_adr;
   mbus7_rnw  <= dmab7_rnw  when dma7_bus_on = '1' else
                 '1'        when snd_bus_own = '1' else cpu7_rnw;
   mbus7_ena  <= dmab7_ena  when dma7_bus_on = '1' else
                 sndb7_ena  when snd_bus_own = '1' else cpu7_ena;
   mbus7_acc  <= dmab7_acc  when dma7_bus_on = '1' else
                 ACCESS_32BIT when snd_bus_own = '1' else cpu7_acc;
   mbus7_dout <= dmab7_dout when dma7_bus_on = '1' else
                 (others => '0') when snd_bus_own = '1' else cpu7_dout;
   mbus7_low  <= dmab7_low  when dma7_bus_on = '1' else
                 "00"       when snd_bus_own = '1' else cpu7_lowbits;

   idma7 : entity work.nds_dma7
   port map
   (
      clk          => clk1x,
      reset        => resetCpu,
      gb_bus       => io_bus7,
      wired_out    => dma7_wired_out,
      wired_done   => dma7_wired_done,
      trig_vblank  => gpu_vblank,
      trig_card    => dma7_card_trig,
      cpu_bus_idle => dma7_idle_ok,
      dma_on       => dma7_on,
      dma_bus_on   => dma7_bus_on,
      mb_ena       => dmab7_ena,
      mb_rnw       => dmab7_rnw,
      mb_adr       => dmab7_adr,
      mb_acc       => dmab7_acc,
      mb_lowbits   => dmab7_low,
      mb_dout      => dmab7_dout,
      mb_din       => cpu7_din,
      mb_done      => cpu7_done,
      irq_dma      => irq_dma7
   );

   imembus7 : entity work.nds_membus7
   port map
   (
      clk => clk1x, reset => resetCpu,
      cpu_adr => mbus7_adr, cpu_rnw => mbus7_rnw, cpu_ena => mbus7_ena, cpu_acc => mbus7_acc,
      cpu_dout => mbus7_dout, cpu_lowbits => mbus7_low, cpu_lastread => cpu7_lastread,
      cpu_din => cpu7_din, cpu_done => cpu7_done,
      bios_addr => bios_addr, bios_data => bios7_data,
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

   -- M10K store: write capture at the w7m_we edge is identical to the old
   -- clocked array write; the read side registers the (combinational) membus
   -- address, so read data lands in the FINISH cycle as before.
   iwram7 : entity MEM.SyncRamDualByteEnable
   generic map
   (
      is_simu     => is_simu,
      is_cyclone5 => '1',
      BYTE_WIDTH  => 8,
      ADDR_WIDTH  => 14,
      BYTES       => 4
   )
   port map
   (
      clk       => clk1x,
      ce_a      => '1',
      addr_a    => to_integer(w7m_addr),
      datain_a0 => w7m_writedata( 7 downto  0),
      datain_a1 => w7m_writedata(15 downto  8),
      datain_a2 => w7m_writedata(23 downto 16),
      datain_a3 => w7m_writedata(31 downto 24),
      dataout_a => w7p_readdata,
      we_a      => w7m_we,
      be_a      => w7m_be,
      ce_b      => '0',
      addr_b    => 0,
      datain_b0 => x"00", datain_b1 => x"00", datain_b2 => x"00", datain_b3 => x"00",
      dataout_b => open,
      we_b      => '0',
      be_b      => "0000"
   );

   -- ================= IO register banks =================
   io_wired_out9  <= irq_wired_out9 or timer_wired_out9 or ipc_wired_out9 or sys_wired_out9 or
                     tim_wired_out9 or g2d_wired_out or g2db_wired_out or dma_wired_out or
                     key_wired_out9 or card_wired_out9;
   io_wired_done9 <= irq_wired_done9 or timer_wired_done9 or ipc_wired_done9 or sys_wired_done9 or
                     tim_wired_done9 or g2d_wired_done or g2db_wired_done or dma_wired_done or
                     key_wired_done9 or card_wired_done9;
   io_wired_out7  <= irq_wired_out7 or timer_wired_out7 or ipc_wired_out7 or sys_wired_out7 or
                     tim_wired_out7 or key_wired_out7 or spi_wired_out7 or card_wired_out7 or
                     rtc_wired_out7 or snd_wired_out7 or dma7_wired_out;
   io_wired_done7 <= irq_wired_done7 or timer_wired_done7 or ipc_wired_done7 or sys_wired_done7 or
                     tim_wired_done7 or key_wired_done7 or spi_wired_done7 or card_wired_done7 or
                     rtc_wired_done7 or snd_wired_done7 or dma7_wired_done;

   irq_in9 <= (0 => irq9_vblank, 1 => irq9_hblank, 2 => irq9_vcount,
               3 => irp_timer9(0), 4 => irp_timer9(1), 5 => irp_timer9(2), 6 => irp_timer9(3),
               8 => irq_dma9(0), 9 => irq_dma9(1), 10 => irq_dma9(2), 11 => irq_dma9(3),
               16 => ipc9_irq_sync, 17 => ipc9_irq_sendempty, 18 => ipc9_irq_recv,
               19 => irq9_card,
               others => '0');
   irq_in7 <= (0 => irq7_vblank, 1 => irq7_hblank, 2 => irq7_vcount,
               3 => irp_timer7(0), 4 => irp_timer7(1), 5 => irp_timer7(2), 6 => irp_timer7(3),
               8 => irq_dma7(0), 9 => irq_dma7(1), 10 => irq_dma7(2), 11 => irq_dma7(3),
               16 => ipc7_irq_sync, 17 => ipc7_irq_sendempty, 18 => ipc7_irq_recv,
               19 => irq7_card, 23 => irq7_spi,
               others => '0');

   irq9_any <= '1' when irq_in9 /= x"00000000" else '0';
   dbg_r0_9   <= cpu9_dbg_r0;
   dbg_lr9    <= cpu9_dbg_lr;
   dbg_cpsr9  <= cpu9_dbg_cpsr;

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
      irq_in => irq_in9, cpu_irq => cpu9_irq, cpu_unhalt => cpu9_unhalt,
      dbg_ime => irq9_dbg_ime, dbg_ie => irq9_dbg_ie, dbg_if => irq9_dbg_if
   );

   iirq7 : entity work.nds_irq
   port map
   (
      clk => clk1x, ce => '1', reset => resetCpu,
      gb_bus => io_bus7, wired_out => irq_wired_out7, wired_done => irq_wired_done7,
      irq_in => irq_in7, cpu_irq => cpu7_irq, cpu_unhalt => cpu7_unhalt,
      dbg_ime => irq7_dbg_ime, dbg_ie => irq7_dbg_ie, dbg_if => irq7_dbg_if
   );

   irtc : entity work.nds_rtc
   port map
   (
      clk => clk1x, ce => '1', reset => resetCpu, fw_boot => fw_boot,
      bus7 => io_bus7, wired_out7 => rtc_wired_out7, wired_done7 => rtc_wired_done7
   );

   isound : entity work.nds_sound
   generic map ( is_simu => is_simu )
   port map
   (
      clk => clk1x, ce => '1', reset => resetCpu,
      bus7 => io_bus7, wired_out7 => snd_wired_out7, wired_done7 => snd_wired_done7,
      snd_bus_req => snd_bus_req,
      snd_bus_ok  => snd_bus_ok,
      snd_bus_own => snd_bus_own,
      mb_ena      => sndb7_ena,
      mb_adr      => sndb7_adr,
      mb_din      => cpu7_din,
      mb_done     => cpu7_done,
      sample_l     => sound_out_left,
      sample_r     => sound_out_right,
      sample_valid => open,
      snd_enable => open, snd_active => open
   );

   ispi : entity work.nds_spi
   port map
   (
      clk => clk1x, reset => resetCpu,
      bus7 => io_bus7, wired_out7 => spi_wired_out7, wired_done7 => spi_wired_done7,
      irq_spi => irq7_spi,
      fw_addr => fw_addr, fw_req => fw_req, fw_done => fw_done, fw_data => fw_data
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
      preset_direct => preset_direct,
      wramcnt => wramcnt, vramcnt => vramcnt,
      pow_2da => pow_2da, pow_2db => pow_2db, pow_swap => pow_swap,
      exmem_gba7 => open, exmem_card7 => exmem_card7_s, exmem_prio7 => exmem_prio7,
      halt7 => cpu7_newhalt
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
      clk1x => clk1x, clkMem => clkMem, clkMemIndex => clkMemIndex, reset => reset_boot,
      arm7_priority => exmem_prio7,
      mem9_ena => mem9_ena,
      mem9_lock => mr9_lock and not dma_bus_on and not ld_busy,
      mem9_rnw => mem9_rnw, mem9_addr => mem9_addr, mem9_be => mem9_be,
      mem9_writedata => mem9_writedata, mem9_done => mem9_done, mem9_readdata => mem9_readdata,
      mem7_ena => mr7_ena,
      mem7_lock => cpu7_lock and not dma7_bus_on and not snd_bus_own,
      mem7_rnw => mr7_rnw, mem7_addr => mr7_addr, mem7_be => mr7_be,
      mem7_writedata => mr7_writedata, mem7_done => mr7_done, mem7_readdata => mr7_readdata,
      mainram_allow => mainram_allow, mainram_active => mainram_active, mainram_busy => mainram_busy,
      mr_sdram_ena => sdram_ena, mr_sdram_rnw => sdram_rnw, mr_sdram_Adr => sdram_Adr,
      mr_sdram_Din => sdram_Din, mr_sdram_be => sdram_be,
      sdram_Dout => sdram_Dout, sdram_done32 => sdram_done32,
      dbg_mr => dbg_mr_s
   );

   -- ================= VRAM + engine A render path =================
   ivram : entity work.nds_vram
   generic map ( is_simu => is_simu )
   port map
   (
      clk => clk1x, reset => reset_boot, vramcnt => vramcnt,
      cpu9_ena => vram9_ena, cpu9_rnw => vram9_rnw, cpu9_addr => vram9_addr,
      cpu9_be => vram9_be, cpu9_din => vram9_din, cpu9_dout => vram9_dout, cpu9_done => vram9_done,
      cpu7_ena => vram7_ena, cpu7_rnw => vram7_rnw, cpu7_addr => vram7_addr,
      cpu7_be => vram7_be, cpu7_din => vram7_din, cpu7_dout => vram7_dout, cpu7_done => vram7_done,
      srv_req => vsrv_req, srv_rnw => vsrv_rnw, srv_bank => vsrv_bank, srv_addr => vsrv_addr,
      srv_be => vsrv_be, srv_din => vsrv_din, srv_dout => vsrv_dout, srv_done => vsrv_done,
      rdr_bg_req => r_bg_req, rdr_bg_addr => r_bg_addr,
      rdr_bg_dout => r_bg_dout, rdr_bg_done => r_bg_done,
      rdr_bg_accept => r_bg_accept,
      rdr_obj_req => r_obj_req, rdr_obj_addr => r_obj_addr,
      rdr_obj_dout => r_obj_dout, rdr_obj_done => r_obj_done,
      rdr_bgep_req => r_bgep_req, rdr_bgep_addr => r_bgep_addr,
      rdr_bgep_dout => r_bgep_dout, rdr_bgep_done => r_bgep_done,
      rdr_objep_req => r_objep_req, rdr_objep_addr => r_objep_addr,
      rdr_objep_dout => r_objep_dout, rdr_objep_done => r_objep_done,
      rdr_bgb_req => rb_bg_req, rdr_bgb_addr => rb_bg_addr,
      rdr_bgb_dout => rb_bg_dout, rdr_bgb_done => rb_bg_done,
      rdr_bgb_accept => rb_bg_accept,
      rdr_objb_req => rb_obj_req, rdr_objb_addr => rb_obj_addr,
      rdr_objb_dout => rb_obj_dout, rdr_objb_done => rb_obj_done,
      rdr_bgepb_req => rb_bgep_req, rdr_bgepb_addr => rb_bgep_addr,
      rdr_bgepb_dout => rb_bgep_dout, rdr_bgepb_done => rb_bgep_done,
      rdr_objepb_req => rb_objep_req, rdr_objepb_addr => rb_objep_addr,
      rdr_objepb_dout => rb_objep_dout, rdr_objepb_done => rb_objep_done,
      clr_busy => vclr_busy,
      rsrv_req => vrsrv_req, rsrv_bank => vrsrv_bank, rsrv_addr => vrsrv_addr,
      rsrv_dout => vrsrv_dout, rsrv_done => vrsrv_done,
      rsrv_ready => vrsrv_ready
      ,
      dbg_rbusy => dbg_rbusy_s
   );

   -- dot pace: 1 of GPU_CE_DIV clocks (see header)
   -- gpu_full_pace = '1' runs the dot cadence at 1-of-1 instead of
   -- 1-of-GPU_CE_DIV, i.e. real frame rate instead of GPU_CE_DIV x too slow.
   -- Runtime-selectable rather than a generic so the two can be compared on
   -- hardware from the OSD without a 25-minute rebuild each way. The trade is
   -- real and visible: at 1-of-1 a line has 2,130 clk1x cycles and the renderer
   -- needs ~3,996 even with GPU_FAST, so roughly half the scanlines are dropped
   -- per frame; at 1-of-3 every line renders but frames are 3x long. Changing it
   -- mid-frame just perturbs one frame's pacing, so it needs no reset.
   p_gpu_ce : process (clk1x)
      variable div : integer range 0 to GPU_CE_DIV - 1 := 0;
   begin
      if rising_edge(clk1x) then
         if (gpu_full_pace = '1') then
            div    := 0;
            gpu_ce <= '1';
         elsif (div = GPU_CE_DIV - 1) then
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
      vcount_out      => vcount_out,
      dbg_vbl_ena9    => dbg_vbl_ena9
   );

   r_bg_addr    <= to_unsigned(g_bg_addr, 17);
   r_obj_addr   <= to_unsigned(g_obj_addr, 16);
   r_bgep_addr  <= to_unsigned(g_bgep_addr, 13);
   r_objep_addr <= to_unsigned(g_objep_addr, 11);

   igpu2d_a : entity work.nds_gpu2d_fast
   generic map ( is_simu => is_simu, GPU_FAST => GPU_FAST )
   port map
   (
      clk1x => clk1x, clkMem => clkMem, clkMemIndex => clkMemIndex, reset => resetCpu,
      gb_bus => io_bus9, wired_out => g2d_wired_out, wired_done => g2d_wired_done,
      linecounter => linecounter, drawline => drawline,
      linecounter_obj => linecounter_obj, drawObj => drawObj,
      line_trigger => line_trigger, hblank_trigger => hblank_trigger,
      vblank_trigger => gpu_vblank, refpoint_update => refpoint_update,
      line_busy => line_busy, epfill_busy => epfill_busy, clr_busy => pclr_busy_a,
      pal_we => pal_we_a, pal_addr => pal_addr_lo, pal_din => pal_din, pal_be => pal_be,
      oam_we => oam_we_a, oam_addr => oam_addr_lo, oam_din => oam_din, oam_be => oam_be,
      srv_bg_req => r_bg_req, srv_bg_addr => g_bg_addr,
      srv_bg_data => r_bg_dout, srv_bg_done => r_bg_done,
      srv_bg_accept => r_bg_accept,
      srv_obj_req => r_obj_req, srv_obj_addr => g_obj_addr,
      srv_obj_data => r_obj_dout, srv_obj_done => r_obj_done,
      srv_bgep_req => r_bgep_req, srv_bgep_addr => g_bgep_addr,
      srv_bgep_data => r_bgep_dout, srv_bgep_done => r_bgep_done,
      srv_objep_req => r_objep_req, srv_objep_addr => g_objep_addr,
      srv_objep_data => r_objep_dout, srv_objep_done => r_objep_done,
      pixel_out_x => pxa_x, pixel_out_y => pxa_y,
      pixel_out_data => pxa_data, pixel_out_we => pxa_we
   );

   -- ================= engine B =================
   -- register window 0x1000-0x106C: engine B sees the bus with bit 12
   -- stripped so the shared register map decodes; outside the window the
   -- address is forced unmatchable so its wired-or stays silent
   io_bus9b.Din  <= io_bus9.Din;
   io_bus9b.Adr  <= (io_bus9.Adr(27 downto 13) & '0' & io_bus9.Adr(11 downto 0))
                    when io_bus9.Adr(27 downto 12) = x"0001" else (others => '1');
   io_bus9b.rnw  <= io_bus9.rnw;
   io_bus9b.ena  <= io_bus9.ena;
   io_bus9b.acc  <= io_bus9.acc;
   io_bus9b.bEna <= io_bus9.bEna;
   io_bus9b.rst  <= io_bus9.rst;

   -- palette/OAM 2 KB mirrors: low half engine A, high half engine B;
   -- writes are dropped while the owning engine is powered off (melonDS)
   pal_we_a    <= pal_we when (pal_addr < 256 and pow_2da = '1') else '0';
   pal_we_b    <= pal_we when (pal_addr >= 256 and pow_2db = '1') else '0';
   pal_addr_lo <= pal_addr mod 256;
   oam_we_a    <= oam_we when (oam_addr < 256 and pow_2da = '1') else '0';
   oam_we_b    <= oam_we when (oam_addr >= 256 and pow_2db = '1') else '0';
   oam_addr_lo <= oam_addr mod 256;

   -- engine B flat spaces are 128 KB: wrap the drawer addresses
   rb_bg_addr    <= to_unsigned(gb_bg_addr mod 32768, 15);
   rb_obj_addr   <= to_unsigned(gb_obj_addr mod 32768, 15);
   rb_bgep_addr  <= to_unsigned(gb_bgep_addr, 13);
   rb_objep_addr <= to_unsigned(gb_objep_addr, 11);

   igpu2d_b : entity work.nds_gpu2d_fast
   generic map ( is_engine_b => '1', is_simu => is_simu, GPU_FAST => GPU_FAST )
   port map
   (
      clk1x => clk1x, clkMem => clkMem, clkMemIndex => clkMemIndex, reset => resetCpu,
      gb_bus => io_bus9b, wired_out => g2db_wired_out, wired_done => g2db_wired_done,
      linecounter => linecounter, drawline => drawline,
      linecounter_obj => linecounter_obj, drawObj => drawObj,
      line_trigger => line_trigger, hblank_trigger => hblank_trigger,
      vblank_trigger => gpu_vblank, refpoint_update => refpoint_update,
      line_busy => line_busy_b, epfill_busy => epfill_busy_b, clr_busy => pclr_busy_b,
      pal_we => pal_we_b, pal_addr => pal_addr_lo, pal_din => pal_din, pal_be => pal_be,
      oam_we => oam_we_b, oam_addr => oam_addr_lo, oam_din => oam_din, oam_be => oam_be,
      srv_bg_req => rb_bg_req, srv_bg_addr => gb_bg_addr,
      srv_bg_data => rb_bg_dout, srv_bg_done => rb_bg_done,
      srv_bg_accept => rb_bg_accept,
      srv_obj_req => rb_obj_req, srv_obj_addr => gb_obj_addr,
      srv_obj_data => rb_obj_dout, srv_obj_done => rb_obj_done,
      srv_bgep_req => rb_bgep_req, srv_bgep_addr => gb_bgep_addr,
      srv_bgep_data => rb_bgep_dout, srv_bgep_done => rb_bgep_done,
      srv_objep_req => rb_objep_req, srv_objep_addr => gb_objep_addr,
      srv_objep_data => rb_objep_dout, srv_objep_done => rb_objep_done,
      pixel_out_x => pxb_x, pixel_out_y => pxb_y,
      pixel_out_data => pxb_data, pixel_out_we => pxb_we
   );

   -- POWCNT display routing: engine B disabled shows raw white (melonDS-
   -- documented hardware quirk: engine A keeps rendering with its bit off);
   -- swap ('1') puts engine A on the top screen
   pxb_data_eff <= pxb_data when pow_2db = '1' else (others => '1');

   pixel_out_x     <= pxa_x        when pow_swap = '1' else pxb_x;
   pixel_out_y     <= pxa_y        when pow_swap = '1' else pxb_y;
   pixel_out_data  <= pxa_data     when pow_swap = '1' else pxb_data_eff;
   pixel_out_we    <= pxa_we       when pow_swap = '1' else pxb_we;
   pixelb_out_x    <= pxb_x        when pow_swap = '1' else pxa_x;
   pixelb_out_y    <= pxb_y        when pow_swap = '1' else pxa_y;
   pixelb_out_data <= pxb_data_eff when pow_swap = '1' else pxa_data;
   pixelb_out_we   <= pxb_we       when pow_swap = '1' else pxa_we;

   vblank_out <= gpu_vblank;

   -- Per-engine drop exports. The combined `drawline and (busy_a or busy_b)`
   -- below is kept because callers use it as "a line was dropped at all", but on
   -- its own it cannot say WHICH engine was behind - and engine B runs the
   -- simpler configuration in Kirby's mode (no ext palettes), so attributing a
   -- combined +7 drops/frame to the wrong engine sizes the renderer work wrong.
   -- Debug-only signals: behaviourally inert.
   dbg_line_drop_a <= drawline and line_busy;
   dbg_line_drop_b <= drawline and line_busy_b;
   dbg_line_drop <= drawline and (line_busy or line_busy_b);
   dbg_line_busy <= line_busy or line_busy_b;
   dbg_cpu_err9  <= error_cpu9;
   dbg_cpu_err7  <= error_cpu7;
   dbg_hwstat    <= std_logic_vector(to_unsigned(t_boot'pos(boot_state), 4)) &
                    resetCpu & ld_busy & ld_done & ld_error &
                    error_cpu9 & error_cpu7 &
                    cpu9_ena & cpu9_done & cpu7_ena & cpu7_done &
                    gpu_vblank & line_busy & line_busy_b & preset_direct;


end architecture;
