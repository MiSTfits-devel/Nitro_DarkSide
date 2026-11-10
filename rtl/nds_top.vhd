
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
      Softmap_NDS_MAINRAM_ADDR : integer   := 8388608;
      GPU_FAST                 : integer   := 0;
      CLKMEM_RATIO             : integer   := 3;
      SOUND_ENABLE             : integer   := 1;
      DEBUG_ENABLE             : integer   := 1;
      skip_copy                : std_logic := '0'
   );
   port
   (
      clk1x            : in  std_logic;
      clk2x            : in  std_logic;
      clkMem           : in  std_logic;
      clkMemIndex      : in  unsigned(1 downto 0);
      reset            : in  std_logic;
      nds_on           : in  std_logic;
      direct_boot      : in  std_logic := '0';
      fw_boot          : in  std_logic := '0';
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

      touch_active     : in  std_logic;
      touch_x          : in  std_logic_vector(7 downto 0);
      touch_y          : in  std_logic_vector(7 downto 0);

      boot_done        : out std_logic;
      boot_error       : out std_logic;

      card_ena         : out std_logic;
      card_addr        : out std_logic_vector(26 downto 2);
      card_din         : in  std_logic_vector(31 downto 0);
      card_done        : in  std_logic;

      fw_addr          : out unsigned(17 downto 2);
      fw_req           : out std_logic;
      fw_done          : in  std_logic;
      fw_data          : in  std_logic_vector(31 downto 0);

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
      sdram_Dout_hi    : in  std_logic_vector(31 downto 0) := (others => '0');
      sdram_done64     : in  std_logic := '0';

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
      vrsrv_ready      : in  std_logic := '1';

      pixel_out_x      : out integer range 0 to 255;
      pixel_out_y      : out integer range 0 to 191;
      pixel_out_data   : out std_logic_vector(17 downto 0);
      pixel_out_we     : out std_logic;
      pixelb_out_x     : out integer range 0 to 255;
      pixelb_out_y     : out integer range 0 to 191;
      pixelb_out_data  : out std_logic_vector(17 downto 0);
      pixelb_out_we    : out std_logic;
      vblank_out       : out std_logic;

      sound_out_left   : out std_logic_vector(15 downto 0);
      sound_out_right  : out std_logic_vector(15 downto 0);

      -- debug (sim monitors; unconnected in synthesis). The record-typed
      -- exports are sim-only, pragma-stripped like the CPUs' own ports
-- synthesis translate_off
      dbg_export9_done : out std_logic;
      dbg_export9      : out cpu_export_type;
      dbg_export7_done : out std_logic;
      dbg_export7      : out cpu_export_type;
-- synthesis translate_on
      dbg_line_drop    : out std_logic;
      dbg_line_drop_a  : out std_logic;
      dbg_line_drop_b  : out std_logic;
      dbg_line_busy    : out std_logic;
      dbg_cpu_err9     : out std_logic;
      dbg_cpu_err7     : out std_logic;
      dbg_pc9          : out std_logic_vector(31 downto 0);
      dbg_pc7          : out std_logic_vector(31 downto 0);
      dbg_r0_9         : out std_logic_vector(31 downto 0);
      dbg_lr9          : out std_logic_vector(31 downto 0);
      dbg_cpsr9        : out std_logic_vector(31 downto 0);
      dbg_vfy_bad      : out std_logic_vector(17 downto 0);
      dbg_vfy_addr     : out std_logic_vector(31 downto 0);
      dbg_cmd_stb      : in  std_logic := '0';
      dbg_cmd_op       : in  std_logic_vector(7 downto 0) := (others => '0');
      dbg_cmd_arg      : in  std_logic_vector(31 downto 0) := (others => '0');
      dbg_rsp_data     : out std_logic_vector(31 downto 0);
      dbg_rsp_stb      : out std_logic;
      dbg_hwstat       : out std_logic_vector(17 downto 0)
   );
end entity;

architecture arch of nds_top is

   signal resetCpu : std_logic := '1';

   type t_boot is
   (
      B_RESET,
      B_SETTLE,
      B_LDSTART, B_LDWAIT,
      B_S9RST, B_S9GAP, B_S9WR, B_S9POST,
      B_S7RST, B_S7GAP, B_S7WR, B_S7POST,
      B_RUN,
      B_ERROR
   );
   signal boot_state : t_boot := B_RESET;
   signal boot_cnt   : integer range 0 to 7 := 0;

   signal ld_start, ld_busy, ld_done, ld_error : std_logic;
   signal preset_direct : std_logic := '0';
   signal arm9_entry, arm7_entry : std_logic_vector(31 downto 0);
   signal arm9_entry_eff, arm7_entry_eff : std_logic_vector(31 downto 0);

   constant PRESET_LAST : integer := 6;
   signal   preset_idx  : integer range 0 to 7 := 0;

   function preset_adr(idx : integer) return integer is
   begin
      case idx is
         when 0      => return  0;
         when 1      => return 13;
         when 2      => return 14;
         when 3      => return 15;
         when 4      => return 24;
         when 5      => return 34;
         when others => return 37;
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

   signal ld_cartid  : std_logic_vector(31 downto 0);
   signal pc9_s, pc7_s         : std_logic_vector(31 downto 0);
   signal dbg_hold9, dbg_rel9  : std_logic;
   signal dbg_hold7, dbg_rel7  : std_logic;
   signal dbg_boot_rst         : std_logic;
   signal dbg_regsel_s         : unsigned(4 downto 0);
   signal dbg_regval9, dbg_regval7 : std_logic_vector(31 downto 0);
   signal dbg_pk_ena, dbg_pk_act, dbg_pk_sel : std_logic;
   signal dbg_card_s : std_logic_vector(31 downto 0);
   signal dbg_ipc_s  : std_logic_vector(31 downto 0);
   signal dbg_perf_s   : std_logic_vector(31 downto 0);
   signal dbg_perf_idx : std_logic_vector(2 downto 0);

   signal reset_boot : std_logic;

   signal vclr_busy   : std_logic;
   signal pclr_busy_a : std_logic;
   signal pclr_busy_b : std_logic;

   signal cdc_req_wsh, cdc_req_vram, cdc_req_mr   : std_logic := '0';
   signal cdc_req_io,  cdc_req_pal,  cdc_req_oam  : std_logic := '0';
   signal cdc_req_wsh_d, cdc_req_vram_d, cdc_req_mr_d  : std_logic := '0';
   signal cdc_req_io_d,  cdc_req_pal_d,  cdc_req_oam_d : std_logic := '0';
   signal cdc_wsh_done_d, cdc_vram_done_d         : std_logic := '0';
   signal cdc_mr_done_d                           : std_logic := '0';
   signal i9_wsh_ena, i9_vram_ena, i9_mr_ena, i9_io_ena : std_logic;
   signal i9_pal_we,  i9_oam_we                         : std_logic;
   signal i9_wsh_done, i9_vram_done, i9_mr_done, i9_io_done : std_logic;
   signal i9_io_bus : proc_bus_gb_type;
   signal io9_lat    : proc_bus_gb_type;
   signal io9_lat_1x : proc_bus_gb_type;
   signal mr9_lock  : std_logic := '0';
   signal io9_ena   : std_logic := '0';
   signal cdc_dmab_ena_d, dmab_ena_i9   : std_logic := '0';
   signal dmab_rnw_i9                    : std_logic := '1';
   signal dmab_adr_i9, dmab_dout_i9      : std_logic_vector(31 downto 0) := (others => '0');
   signal dmab_acc_i9, dmab_low_i9       : std_logic_vector(1 downto 0) := (others => '0');
   signal cdc_cpudone_tgl, cdc_cpudone_tgl_d, cpu9_done_1x : std_logic := '0';
   signal cdc_io_cpl, cdc_io_cpl_d : std_logic := '0';
   signal io9_resp_1x              : std_logic_vector(31 downto 0) := (others => '0');
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

   signal itcm_addr : unsigned(14 downto 2);
   signal itcm_we   : std_logic;
   signal itcm_be   : std_logic_vector(3 downto 0);
   signal itcm_writedata, itcm_readdata : std_logic_vector(31 downto 0);
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

   signal vr9_ena, vr9_rnw : std_logic;
   signal vr9_addr : unsigned(23 downto 2);
   signal vr9_be   : std_logic_vector(3 downto 0);
   signal vr9_din  : std_logic_vector(31 downto 0);

   signal dma_vr_ena, dma_vr_rnw : std_logic;
   signal dma_vr_addr : unsigned(23 downto 2);
   signal dma_vr_be   : std_logic_vector(3 downto 0);
   signal dma_vr_din  : std_logic_vector(31 downto 0);
   signal dma_vr_wpost : std_logic;
   signal vr9_wpost, vr9_welig, vr9_wok : std_logic;

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
   signal mr9_pair : std_logic;
   signal mr9_readdata_hi : std_logic_vector(31 downto 0);

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

   signal cpu9_bus_idle : std_logic;
   signal dma_on, dma_bus_on : std_logic;

   signal dma_io_ena  : std_logic;
   signal dma_io_rnw  : std_logic;
   signal dma_io_adr  : std_logic_vector(27 downto 0);
   signal dma_io_acc  : std_logic_vector(1 downto 0);
   signal dma_io_be   : std_logic_vector(3 downto 0);
   signal dma_io_dout : std_logic_vector(31 downto 0);
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

   signal card_wired_out9, card_wired_out7   : std_logic_vector(31 downto 0);
   signal card_wired_done9, card_wired_done7 : std_logic;

   signal rtc_wired_out7  : std_logic_vector(31 downto 0);
   signal rtc_wired_done7 : std_logic;

   signal snd_wired_out7  : std_logic_vector(31 downto 0);
   signal snd_wired_done7 : std_logic;
   signal snd_bus_req     : std_logic;
   signal snd_bus_ok      : std_logic;
   signal snd_bus_own     : std_logic;
   signal sndb7_ena       : std_logic;
   signal sndb7_adr       : std_logic_vector(31 downto 0);
   signal cpu7_pause      : std_logic;
   signal dma7_idle_ok    : std_logic;

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

   signal cpu7_adr      : std_logic_vector(31 downto 0);
   signal cpu7_rnw, cpu7_ena, cpu7_done, cpu7_lock : std_logic;
   signal cpu7_acc      : std_logic_vector(1 downto 0);
   signal cpu7_dout, cpu7_din, cpu7_lastread : std_logic_vector(31 downto 0);
   signal cpu7_lowbits  : std_logic_vector(1 downto 0);
   signal error_cpu7    : std_logic;
   signal cpu7_irq, cpu7_unhalt : std_logic;
   signal cpu7_newhalt : std_logic;

   signal bios_addr  : unsigned(13 downto 2);
   signal bios7_data : std_logic_vector(31 downto 0);

   signal w7p_addr      : unsigned(15 downto 2);
   signal w7p_we        : std_logic;
   signal w7p_be        : std_logic_vector(3 downto 0);
   signal w7p_writedata, w7p_readdata : std_logic_vector(31 downto 0);
   signal w7m_addr      : unsigned(15 downto 2);
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

   signal wramcnt : std_logic_vector(1 downto 0);
   signal vramcnt : std_logic_vector(71 downto 0);
   signal exmem_prio7 : std_logic;

   signal mem9_ena, mem9_rnw, mem9_done : std_logic;
   signal mem9_addr : std_logic_vector(21 downto 2);
   signal mem9_be   : std_logic_vector(3 downto 0);
   signal mem9_writedata, mem9_readdata : std_logic_vector(31 downto 0);
   signal mem9_pair_s : std_logic;
   signal mem9_readdata_hi_s : std_logic_vector(31 downto 0);
   signal ld_to_main, ld_to_wram7 : std_logic;

   signal keyinput : std_logic_vector(9 downto 0);
   signal extkeyin : std_logic_vector(7 downto 0);

   signal r_bg_accept, rb_bg_accept : std_logic;
   signal r_obj_accept, rb_obj_accept : std_logic;
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

   signal linecounter     : integer range 0 to 191;
   signal linecounter_obj : integer range 0 to 191;
   signal drawline, drawObj, line_trigger, hblank_trigger, gpu_vblank, refpoint_update : std_logic;
   signal line_busy, epfill_busy : std_logic;
   signal dbg_rbusy_s : std_logic;
   signal line_busy_b, epfill_busy_b : std_logic;

   signal pow_2da, pow_2db, pow_swap : std_logic;
   signal pxa_x, pxb_x       : integer range 0 to 255;
   signal pxa_y, pxb_y       : integer range 0 to 191;
   signal pxa_data, pxb_data : std_logic_vector(17 downto 0);
   signal pxa_we, pxb_we     : std_logic;
   signal pxb_data_eff       : std_logic_vector(17 downto 0);
   signal vcount_out : unsigned(8 downto 0);

begin

   p_boot : process (clk1x)
   begin
      if rising_edge(clk1x) then
         ld_start      <= '0';
         preset_direct <= '0';
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
                  ss_bus9.Din  <= preset_val(preset_idx, arm9_entry_eff, true);
                  ss_bus9.rnw  <= '0';
                  ss_bus9.bEna <= "1111";
                  ss_bus9.ena  <= '1';
                  boot_state   <= B_S9WR;

               when B_S9WR =>
                  ss_bus9.ena <= '0';
                  ss_bus9.rnw <= '1';
                  boot_cnt    <= 0;
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

   card_ena  <= ld_card_ena  when ld_busy = '1' else cardm_ena;
   card_addr <= ld_card_addr when ld_busy = '1' else cardm_addr;

   icard : entity work.nds_card
   generic map
   (
      CARDSPEED_SHIFT => 2
   )
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
      dbg_card => dbg_card_s,
      card_ena => cardm_ena, card_addr => cardm_addr,
      card_din => card_din, card_done => card_done
   );

   ld_to_main  <= '1' when (ld_busy = '1' and ld_wr_addr(31 downto 24) = x"02") else '0';
   ld_to_wram7 <= '1' when (ld_busy = '1' and ld_wr_addr(31 downto 24) = x"03") else '0';

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
   mem9_pair_s    <= mr9_pair when (ld_busy = '0' and dbg_pk_sel = '0') else '0';
   mr9_done       <= mem9_done and not ld_busy and not dbg_pk_sel;
   mr9_readdata   <= mem9_readdata;
   mr9_readdata_hi <= mem9_readdata_hi_s;
   dbg_pk_done_s  <= mem9_done and dbg_pk_sel;

   reset_boot <= reset or dbg_boot_rst;

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

   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if (i9_io_bus.ena = '1') then
            io9_lat <= i9_io_bus;
         end if;
      end if;
   end process;

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         io9_lat_1x <= io9_lat;
      end if;
   end process;

   io_bus9 <= (Din  => dma_io_dout,      Adr  => dma_io_adr,
               rnw  => dma_io_rnw,       ena  => dma_io_ena,
               acc  => dma_io_acc,       bEna => dma_io_be,
               rst  => i9_io_bus.rst)
              when dma_bus_on = '1' else
              (Din  => io9_lat_1x.Din,  Adr  => io9_lat_1x.Adr,
               rnw  => io9_lat_1x.rnw,  ena  => io9_ena,
               acc  => io9_lat_1x.acc,  bEna => io9_lat_1x.bEna,
               rst  => i9_io_bus.rst);

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

   process (clk2x)
   begin
      if rising_edge(clk2x) then
         cdc_wsh_done_d  <= wsh9_done;
         cdc_vram_done_d <= vram9_done;
         cdc_mr_done_d   <= mr9_done;
      end if;
   end process;
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if (resetCpu = '1') then
            cdc_dmab_ena_d <= '0';
            dmab_ena_i9    <= '0';
         else
            cdc_dmab_ena_d <= dmab_ena;
            dmab_ena_i9    <= '0';
            if (dmab_ena = '1' and cdc_dmab_ena_d = '0') then
               dmab_rnw_i9  <= dmab_rnw;
               dmab_adr_i9  <= dmab_adr;
               dmab_acc_i9  <= dmab_acc;
               dmab_low_i9  <= dmab_low;
               dmab_dout_i9 <= dmab_dout;
               dmab_ena_i9  <= '1';
            end if;
         end if;
      end if;
   end process;

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

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (io9_ena = '1') then
            io9_resp_1x <= io_wired_out9;
            cdc_io_cpl  <= not cdc_io_cpl;
         end if;
      end if;
   end process;

   process (clk2x)
   begin
      if rising_edge(clk2x) then
         cdc_io_cpl_d <= cdc_io_cpl;
      end if;
   end process;

   i9_io_done   <= cdc_io_cpl xor cdc_io_cpl_d;


   dbg_pc9 <= pc9_s;
   dbg_pc7 <= pc7_s;

   dbg_probe <= dma_bus_on & ld_busy & dbg_pk_sel & mem9_done &
                mem9_ena & mr9_ena & mr9_done & cpu9_ena &
                dbg_mr_s(7 downto 3) & dbg_vbl_ena9 & dbg_mr_s(1 downto 0) &
                dbg_mb9 & dbg_cache9;

   gdebug : if DEBUG_ENABLE /= 0 generate
   idebug : entity work.nds_debug
   generic map
   (
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
      cardstat => dbg_card_s,
      ipcstat  => dbg_ipc_s,
      perfstat => dbg_perf_s,
      perf_index => dbg_perf_idx,
      irq9_ime => irq9_dbg_ime, irq9_ie => irq9_dbg_ie, irq9_if => irq9_dbg_if,
      irq7_ime => irq7_dbg_ime, irq7_ie => irq7_dbg_ie, irq7_if => irq7_dbg_if,
      pk_ena   => dbg_pk_ena,
      pk_addr  => dbg_pk_addr_s,
      pk_done  => dbg_pk_done_s,
      pk_data  => mem9_readdata
   );
   end generate;

   gnodebug : if DEBUG_ENABLE = 0 generate
      dbg_rsp_data  <= (others => '0');
      dbg_rsp_stb   <= '0';
      dbg_hold9     <= '0';
      dbg_rel9      <= '0';
      dbg_hold7     <= '0';
      dbg_rel7      <= '0';
      dbg_boot_rst  <= '0';
      dbg_regsel_s  <= (others => '0');
      dbg_pk_ena    <= '0';
      dbg_pk_addr_s <= (others => '0');
      dbg_perf_idx  <= (others => '0');
   end generate;

   iperf : entity work.nds_perf
   generic map ( ENABLE => DEBUG_ENABLE )
   port map
   (
      clk         => clk1x,
      reset       => reset,
      vblank      => gpu_vblank,
      drawline    => drawline,
      drawObj     => drawObj,
      line_busy_a => line_busy,
      line_busy_b => line_busy_b,
      index       => dbg_perf_idx,
      value       => dbg_perf_s
   );

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         ld_w7_done <= ld_wr_ena and ld_to_wram7;
      end if;
   end process;
   ld_wr_done <= ld_w7_done when ld_to_wram7 = '1' else mem9_done;

   ibios9 : entity work.nds_bios9
   generic map
   (
      is_simu => is_simu,
      use_cyclone5_primitive => not is_simu
   )
   port map
   (
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
      mr_pair => mr9_pair, mr_readdata_hi => mr9_readdata_hi,
      io_ce_next => '1',
      io_bus => i9_io_bus, io_wired_out => io9_resp_1x, io_wired_done => i9_io_done,
      dbg_mb => dbg_mb9, dbg_cache => dbg_cache9
   );

   mbus_adr  <= dmab_adr_i9  when dma_bus_on = '1' else cpu9_adr;
   mbus_rnw  <= dmab_rnw_i9  when dma_bus_on = '1' else cpu9_rnw;
   mbus_ena  <= dmab_ena_i9 when dma_bus_on = '1' else cpu9_ena;
   mbus_code <= '0'       when dma_bus_on = '1' else cpu9_code;
   mbus_acc  <= dmab_acc_i9  when dma_bus_on = '1' else cpu9_acc;
   mbus_dout <= dmab_dout_i9 when dma_bus_on = '1' else cpu9_dout;
   mbus_low  <= dmab_low_i9  when dma_bus_on = '1' else cpu9_lowbits;

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
      mb_done      => cpu9_done_1x,
      io_fast_ena  => dma_io_ena,
      io_fast_rnw  => dma_io_rnw,
      io_fast_adr  => dma_io_adr,
      io_fast_acc  => dma_io_acc,
      io_fast_be   => dma_io_be,
      io_fast_dout => dma_io_dout,
      io_fast_din  => io_wired_out9,
      vram_fast_ena  => dma_vr_ena,
      vram_fast_rnw  => dma_vr_rnw,
      vram_fast_addr => dma_vr_addr,
      vram_fast_be   => dma_vr_be,
      vram_fast_din  => dma_vr_din,
      vram_fast_dout => vram9_dout,
      vram_fast_done => vram9_done,
      vram_fast_wpost => dma_vr_wpost,
      vram_fast_welig => vr9_welig,
      vram_fast_wok   => vr9_wok,
      irq_dma      => irq_dma9
   );

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
      ce_a      => '1',
      addr_a    => to_integer(dtcm_addr),
      datain_a0 => x"00", datain_a1 => x"00", datain_a2 => x"00", datain_a3 => x"00",
      dataout_a => dtcm_readdata,
      we_a      => '0',
      be_a      => "0000",
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

   w7m_we        <= (ld_wr_ena and ld_to_wram7) when ld_busy = '1' else w7p_we;
   w7m_addr      <= unsigned(ld_wr_addr(15 downto 2)) when ld_busy = '1' else w7p_addr;
   w7m_be        <= "1111"                     when ld_busy = '1' else w7p_be;
   w7m_writedata <= ld_wr_data                 when ld_busy = '1' else w7p_writedata;

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

   gsound : if SOUND_ENABLE /= 0 generate
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
   end generate;

   gnosound : if SOUND_ENABLE = 0 generate
      snd_wired_done7 <= '1' when (io_bus7.Adr(27 downto 9) = "0000000000000000010") else '0';
      snd_wired_out7  <= (others => '0');
      snd_bus_req     <= '0';
      snd_bus_own     <= '0';
      sndb7_ena       <= '0';
      sndb7_adr       <= (others => '0');
      sound_out_left  <= (others => '0');
      sound_out_right <= (others => '0');
   end generate;

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
      irq9_sync => ipc9_irq_sync, irq9_sendempty => ipc9_irq_sendempty, irq9_recv => ipc9_irq_recv,
      dbg_ipc => dbg_ipc_s
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
      sdram_Dout_hi => sdram_Dout_hi, sdram_done64 => sdram_done64,
      mem9_pair => mem9_pair_s, mem9_readdata_hi => mem9_readdata_hi_s,
      dbg_mr => dbg_mr_s
   );

   vr9_ena  <= dma_vr_ena  when dma_bus_on = '1' else vram9_ena;
   vr9_rnw  <= dma_vr_rnw  when dma_bus_on = '1' else vram9_rnw;
   vr9_addr <= dma_vr_addr when dma_bus_on = '1' else vram9_addr;
   vr9_be   <= dma_vr_be   when dma_bus_on = '1' else vram9_be;
   vr9_din  <= dma_vr_din  when dma_bus_on = '1' else vram9_din;
   vr9_wpost <= dma_vr_wpost and dma_bus_on;

   ivram : entity work.nds_vram
   generic map ( is_simu => is_simu, POSTED_WRITES => true )
   port map
   (
      clk => clk1x, reset => reset_boot, vramcnt => vramcnt,
      cpu9_ena => vr9_ena, cpu9_rnw => vr9_rnw, cpu9_addr => vr9_addr,
      cpu9_be => vr9_be, cpu9_din => vr9_din, cpu9_dout => vram9_dout, cpu9_done => vram9_done,
      cpu9_wpost => vr9_wpost, cpu9_welig => vr9_welig, cpu9_wok => vr9_wok,
      cpu7_ena => vram7_ena, cpu7_rnw => vram7_rnw, cpu7_addr => vram7_addr,
      cpu7_be => vram7_be, cpu7_din => vram7_din, cpu7_dout => vram7_dout, cpu7_done => vram7_done,
      srv_req => vsrv_req, srv_rnw => vsrv_rnw, srv_bank => vsrv_bank, srv_addr => vsrv_addr,
      srv_be => vsrv_be, srv_din => vsrv_din, srv_dout => vsrv_dout, srv_done => vsrv_done,
      rdr_bg_req => r_bg_req, rdr_bg_addr => r_bg_addr,
      rdr_bg_dout => r_bg_dout, rdr_bg_done => r_bg_done,
      rdr_bg_accept => r_bg_accept,
      rdr_obj_req => r_obj_req, rdr_obj_addr => r_obj_addr,
      rdr_obj_dout => r_obj_dout, rdr_obj_done => r_obj_done,
      rdr_obj_accept => r_obj_accept,
      rdr_bgep_req => r_bgep_req, rdr_bgep_addr => r_bgep_addr,
      rdr_bgep_dout => r_bgep_dout, rdr_bgep_done => r_bgep_done,
      rdr_objep_req => r_objep_req, rdr_objep_addr => r_objep_addr,
      rdr_objep_dout => r_objep_dout, rdr_objep_done => r_objep_done,
      rdr_bgb_req => rb_bg_req, rdr_bgb_addr => rb_bg_addr,
      rdr_bgb_dout => rb_bg_dout, rdr_bgb_done => rb_bg_done,
      rdr_bgb_accept => rb_bg_accept,
      rdr_objb_req => rb_obj_req, rdr_objb_addr => rb_obj_addr,
      rdr_objb_dout => rb_obj_dout, rdr_objb_done => rb_obj_done,
      rdr_objb_accept => rb_obj_accept,
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

   itiming : entity work.nds_gpu_timing
   port map
   (
      clk             => clk1x,
      ce              => '1',
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
   generic map ( is_simu => is_simu, GPU_FAST => GPU_FAST, CLKMEM_RATIO => CLKMEM_RATIO )
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
      srv_obj_accept => r_obj_accept,
      srv_bgep_req => r_bgep_req, srv_bgep_addr => g_bgep_addr,
      srv_bgep_data => r_bgep_dout, srv_bgep_done => r_bgep_done,
      srv_objep_req => r_objep_req, srv_objep_addr => g_objep_addr,
      srv_objep_data => r_objep_dout, srv_objep_done => r_objep_done,
      pixel_out_x => pxa_x, pixel_out_y => pxa_y,
      pixel_out_data => pxa_data, pixel_out_we => pxa_we
   );

   io_bus9b.Din  <= io_bus9.Din;
   io_bus9b.Adr  <= (io_bus9.Adr(27 downto 13) & '0' & io_bus9.Adr(11 downto 0))
                    when io_bus9.Adr(27 downto 12) = x"0001" else (others => '1');
   io_bus9b.rnw  <= io_bus9.rnw;
   io_bus9b.ena  <= io_bus9.ena;
   io_bus9b.acc  <= io_bus9.acc;
   io_bus9b.bEna <= io_bus9.bEna;
   io_bus9b.rst  <= io_bus9.rst;

   pal_we_a    <= pal_we when (pal_addr < 256 and pow_2da = '1') else '0';
   pal_we_b    <= pal_we when (pal_addr >= 256 and pow_2db = '1') else '0';
   pal_addr_lo <= pal_addr mod 256;
   oam_we_a    <= oam_we when (oam_addr < 256 and pow_2da = '1') else '0';
   oam_we_b    <= oam_we when (oam_addr >= 256 and pow_2db = '1') else '0';
   oam_addr_lo <= oam_addr mod 256;

   rb_bg_addr    <= to_unsigned(gb_bg_addr mod 32768, 15);
   rb_obj_addr   <= to_unsigned(gb_obj_addr mod 32768, 15);
   rb_bgep_addr  <= to_unsigned(gb_bgep_addr, 13);
   rb_objep_addr <= to_unsigned(gb_objep_addr, 11);

   igpu2d_b : entity work.nds_gpu2d_fast
   generic map ( is_engine_b => '1', is_simu => is_simu, GPU_FAST => GPU_FAST, CLKMEM_RATIO => CLKMEM_RATIO )
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
      srv_obj_accept => rb_obj_accept,
      srv_bgep_req => rb_bgep_req, srv_bgep_addr => gb_bgep_addr,
      srv_bgep_data => rb_bgep_dout, srv_bgep_done => rb_bgep_done,
      srv_objep_req => rb_objep_req, srv_objep_addr => gb_objep_addr,
      srv_objep_data => rb_objep_dout, srv_objep_done => rb_objep_done,
      pixel_out_x => pxb_x, pixel_out_y => pxb_y,
      pixel_out_data => pxb_data, pixel_out_we => pxb_we
   );

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
