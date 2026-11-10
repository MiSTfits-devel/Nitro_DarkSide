
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library MEM;

use work.pProc_bus_gba.all;
use work.pRegmap_gba.all;
use work.pReg_nds_display.all;

entity nds_gpu2d is
   generic
   (
      is_engine_b : std_logic := '0';
      is_simu     : std_logic := '0'
   );
   port
   (
      clk               : in  std_logic;
      reset             : in  std_logic;

      gb_bus            : in  proc_bus_gb_type;
      wired_out         : out std_logic_vector(31 downto 0) := (others => '0');
      wired_done        : out std_logic;

      linecounter       : in  integer range 0 to 191;
      drawline          : in  std_logic;
      linecounter_obj   : in  integer range 0 to 191;
      drawObj           : in  std_logic;
      line_trigger      : in  std_logic;
      hblank_trigger    : in  std_logic;
      vblank_trigger    : in  std_logic;
      refpoint_update   : in  std_logic;

      line_busy         : out std_logic;
      epfill_busy       : out std_logic;
      clr_busy          : out std_logic := '1';

      pal_we            : in  std_logic;
      pal_addr          : in  integer range 0 to 255;
      pal_din           : in  std_logic_vector(31 downto 0);
      pal_be            : in  std_logic_vector(3 downto 0);
      oam_we            : in  std_logic;
      oam_addr          : in  integer range 0 to 255;
      oam_din           : in  std_logic_vector(31 downto 0);
      oam_be            : in  std_logic_vector(3 downto 0);

      srv_bg_req        : out std_logic := '0';
      srv_bg_addr       : out integer range 0 to 131071;
      srv_bg_data       : in  std_logic_vector(31 downto 0);
      srv_bg_done       : in  std_logic;
      srv_bg_accept     : in  std_logic := '1';
      srv_obj_req       : out std_logic := '0';
      srv_obj_addr      : out integer range 0 to 65535;
      srv_obj_data      : in  std_logic_vector(31 downto 0);
      srv_obj_done      : in  std_logic;
      srv_obj_accept    : in  std_logic := '1';
      srv_bgep_req      : out std_logic := '0';
      srv_bgep_addr     : out integer range 0 to 8191;
      srv_bgep_data     : in  std_logic_vector(31 downto 0);
      srv_bgep_done     : in  std_logic;
      srv_objep_req     : out std_logic := '0';
      srv_objep_addr    : out integer range 0 to 2047;
      srv_objep_data    : in  std_logic_vector(31 downto 0);
      srv_objep_done    : in  std_logic;

      pixel_out_x       : out integer range 0 to 255;
      pixel_out_y       : out integer range 0 to 191;
      pixel_out_data    : out std_logic_vector(17 downto 0);
      pixel_out_we      : out std_logic;

      dbg_bg_busy       : out std_logic;
      dbg_obj_busy      : out std_logic;
      dbg_bgmode        : out std_logic_vector(2 downto 0);
      dbg_fblank        : out std_logic
   );
end entity;

architecture arch of nds_gpu2d is

   constant REGCOUNT : integer := 72;
   type t_reg_wired_or is array (0 to REGCOUNT-1) of std_logic_vector(31 downto 0);
   signal reg_wired_or   : t_reg_wired_or := (others => (others => '0'));
   signal reg_wired_done : std_logic_vector(0 to REGCOUNT-1) := (others => '0');

   signal R_bgmode       : std_logic_vector(2 downto 0);
   signal R_bg0_3d       : std_logic_vector(3 downto 3);
   signal R_obj1d        : std_logic_vector(4 downto 4);
   signal R_bmp2dwide    : std_logic_vector(5 downto 5);
   signal R_bmp1d        : std_logic_vector(6 downto 6);
   signal R_forced_blank : std_logic_vector(7 downto 7);
   signal R_ena_bg0      : std_logic_vector(8 downto 8);
   signal R_ena_bg1      : std_logic_vector(9 downto 9);
   signal R_ena_bg2      : std_logic_vector(10 downto 10);
   signal R_ena_bg3      : std_logic_vector(11 downto 11);
   signal R_ena_obj      : std_logic_vector(12 downto 12);
   signal R_win0_on      : std_logic_vector(13 downto 13);
   signal R_win1_on      : std_logic_vector(14 downto 14);
   signal R_winobj_on    : std_logic_vector(15 downto 15);
   signal R_dispmode     : std_logic_vector(17 downto 16);
   signal R_vramblock    : std_logic_vector(19 downto 18);
   signal R_objbound     : std_logic_vector(21 downto 20);
   signal R_bmpbound     : std_logic_vector(22 downto 22);
   signal R_objhbl       : std_logic_vector(23 downto 23);
   signal R_charbase     : std_logic_vector(26 downto 24);
   signal eff_screenbase : std_logic_vector(2 downto 0);
   signal eff_charbase   : std_logic_vector(2 downto 0);
   signal eff_bmpbound   : std_logic;
   signal R_mbright_f    : std_logic_vector(4 downto 0);
   signal R_mbright_m    : std_logic_vector(15 downto 14);
   signal raw666         : std_logic_vector(17 downto 0);
   signal dispmode_eff   : std_logic_vector(1 downto 0);
   signal R_screenbase   : std_logic_vector(29 downto 27);
   signal R_bgextpal     : std_logic_vector(30 downto 30);
   signal R_objextpal    : std_logic_vector(31 downto 31);

   type t_bgcnt is record
      prio       : std_logic_vector(1 downto 0);
      charbase   : std_logic_vector(3 downto 0);
      mosaic     : std_logic_vector(0 downto 0);
      hicolor    : std_logic_vector(0 downto 0);
      screenbase : std_logic_vector(4 downto 0);
      slotwrap   : std_logic_vector(0 downto 0);
      size       : std_logic_vector(1 downto 0);
   end record;
   type t_bgcnt_arr is array (0 to 3) of t_bgcnt;
   signal R_bgcnt : t_bgcnt_arr;

   type t_scroll_arr is array (0 to 3) of std_logic_vector(8 downto 0);
   signal R_hofs, R_vofs : t_scroll_arr;

   signal R_bg2dx, R_bg2dmx, R_bg2dy, R_bg2dmy : std_logic_vector(15 downto 0);
   signal R_bg3dx, R_bg3dmx, R_bg3dy, R_bg3dmy : std_logic_vector(15 downto 0);
   signal R_bg2refx, R_bg2refy, R_bg3refx, R_bg3refy : std_logic_vector(27 downto 0);
   signal ref2x_written, ref2y_written, ref3x_written, ref3y_written : std_logic;

   signal R_win0h, R_win1h, R_win0v, R_win1v : std_logic_vector(15 downto 0);
   signal R_winin0, R_winin1, R_winout, R_winobj : std_logic_vector(5 downto 0);
   signal R_mos_bgh, R_mos_bgv, R_mos_objh, R_mos_objv : std_logic_vector(3 downto 0);
   signal R_bld1st : std_logic_vector(5 downto 0);
   signal R_bldeff : std_logic_vector(1 downto 0);
   signal R_bld2nd : std_logic_vector(5 downto 0);
   signal R_eva, R_evb : std_logic_vector(4 downto 0);
   signal R_bldy   : std_logic_vector(4 downto 0);

   signal ref2x_int, ref2y_int, ref3x_int, ref3y_int : signed(27 downto 0) := (others => '0');
   type t_ref_pair is array (2 to 3) of signed(27 downto 0);
   signal refx_arr, refy_arr : t_ref_pair;
   type t_d_pair is array (2 to 3) of signed(15 downto 0);
   signal dx_arr, dy_arr : t_d_pair;

   type t_base_arr is array (0 to 3) of unsigned(18 downto 0);
   signal cfg_mapbase, cfg_tilebase, cfg_bmpbase : t_base_arr;
   type t_slot_arr is array (0 to 3) of unsigned(1 downto 0);
   signal cfg_extslot : t_slot_arr;
   type t_var_arr is array (2 to 3) of unsigned(1 downto 0);
   signal cfg_variant : t_var_arr;
   signal cfg_extbase : t_base_arr;
   signal cfg_isaff   : std_logic_vector(2 to 3);
   signal cfg_aebase  : t_base_arr;

   type t_bgtype_arr is array (0 to 3) of integer range 0 to 3;
   signal bgtype : t_bgtype_arr;

   signal drawline_text : std_logic_vector(0 to 3);
   signal drawline_ae   : std_logic_vector(2 to 3);
   signal drawline_acc  : std_logic;
   signal drawobj_acc   : std_logic;

   signal busy_text : std_logic_vector(0 to 3);
   signal busy_ae   : std_logic_vector(2 to 3);

   type t_pix_arr  is array (0 to 3) of std_logic_vector(15 downto 0);
   type t_x_arr    is array (0 to 3) of integer range 0 to 255;
   signal pix_we_text : std_logic_vector(0 to 3);
   signal pix_text    : t_pix_arr;
   signal pixx_text   : t_x_arr;
   signal pix_we_ae   : std_logic_vector(2 to 3);
   signal pix_ae      : t_pix_arr;
   signal pixx_ae     : t_x_arr;

   type t_vaddr_arr is array (0 to 3) of integer range 0 to 131071;
   signal bgv_req   : std_logic_vector(0 to 3);
   signal bgv_addr  : t_vaddr_arr;
   signal bgv_done  : std_logic_vector(0 to 3);
   signal bgv_data  : std_logic_vector(31 downto 0);
   signal bgv_accept : std_logic_vector(0 to 3);
   type t_vaddrt_arr is array (0 to 3) of integer range 0 to 131071;
   signal v_req_text : std_logic_vector(0 to 3);
   signal v_addr_text : t_vaddrt_arr;
   signal v_req_ae   : std_logic_vector(2 to 3);
   signal v_addr_ae  : t_vaddrt_arr;

   type t_paddr_arr is array (0 to 3) of integer range 0 to 127;
   signal p_addr_text, p_addr_ae : t_paddr_arr;
   signal bgp_addr  : t_paddr_arr;
   type t_pdata_arr is array (0 to 3) of std_logic_vector(31 downto 0);
   signal bgp_data  : t_pdata_arr;
   signal bgp_valid : std_logic_vector(0 to 3) := (others => '1');

   type t_epaddr_arr is array (0 to 3) of integer range 0 to 8191;
   signal ep_addr_text, ep_addr_ae : t_epaddr_arr;
   signal bgep_addr  : t_epaddr_arr;
   signal bgep_data  : t_pdata_arr;
   signal bgep_valid : std_logic_vector(0 to 3) := (others => '1');

   signal obj_pal_addr    : integer range 0 to 127;
   signal obj_pal_data    : std_logic_vector(31 downto 0);
   signal obj_ep_addr     : integer range 0 to 2047;
   signal obj_ep_data     : std_logic_vector(31 downto 0);
   signal obj_oam_addr    : integer range 0 to 127;
   signal obj_oam_data    : std_logic_vector(63 downto 0);
   signal obj_oamaff_addr : integer range 0 to 31;
   signal obj_oamaff_data : std_logic_vector(63 downto 0);
   signal obj_we_color    : std_logic;
   signal obj_color       : std_logic_vector(15 downto 0);
   signal obj_we_settings : std_logic;
   signal obj_settings    : std_logic_vector(7 downto 0);
   signal obj_x           : integer range 0 to 255;
   signal obj_objwnd      : std_logic;
   signal obj_busy        : std_logic;


   signal pal_we_i, oam_we_i     : std_logic;
   signal pal_addr_i, oam_addr_i : integer range 0 to 255;
   signal pal_din_i, oam_din_i   : std_logic_vector(31 downto 0);
   signal pal_be_i, oam_be_i     : std_logic_vector(3 downto 0);
   signal clr_run  : std_logic := '1';
   signal clr_addr : unsigned(7 downto 0) := (others => '0');
   signal reset_d  : std_logic := '1';

   constant EPSLOT_WORDS : integer := 2048;
   type t_epslot_data is array (0 to 3) of std_logic_vector(31 downto 0);
   signal epslot_qa, epslot_qb : t_epslot_data;
   type t_epslot_addr is array (0 to 3) of integer range 0 to EPSLOT_WORDS - 1;
   signal epslot_addr_a : t_epslot_addr;
   signal epslot_addr_b : t_epslot_addr;
   signal epslot_pa     : t_epslot_addr;
   signal epslot_we     : std_logic_vector(0 to 3);
   type t_slot_d is array (0 to 3) of unsigned(1 downto 0);
   signal extslot_d : t_slot_d := (others => "00");

   type t_objep is array (0 to 2047) of std_logic_vector(31 downto 0);
   signal objep_shadow : t_objep := (others => (others => '0'));

   type t_epfill is (EPIDLE, EPBG_REQ, EPBG_WAIT, EPOBJ_REQ, EPOBJ_WAIT);
   signal epfill       : t_epfill := EPIDLE;
   signal epfill_addr  : integer range 0 to 8191 := 0;

   signal lb_bg    : t_pix_arr;
   type t_q32_arr is array (0 to 3) of std_logic_vector(31 downto 0);
   signal lb_bg_q32 : t_q32_arr;
   signal obj_q32   : std_logic_vector(31 downto 0);
   signal lb_we    : std_logic_vector(0 to 3);
   signal lb_wa    : t_x_arr;
   signal lb_wd    : t_pix_arr;
   signal lb_clrwe : std_logic_vector(0 to 3);
   signal lb_baddr : integer range 0 to 255;

   signal objcol_q    : std_logic_vector(15 downto 0);
   signal objset_q    : std_logic_vector(7 downto 0);
   signal objcol_we   : std_logic;
   signal objset_we   : std_logic;
   signal objb_wa_col : integer range 0 to 511;
   signal objb_wa_set : integer range 0 to 511;
   signal objcol_wd   : std_logic_vector(15 downto 0);
   signal objset_wd   : std_logic_vector(7 downto 0);
   signal objb_ra     : integer range 0 to 511;
   signal mrg_objcol_eff : std_logic_vector(15 downto 0);
   signal mrg_objset_eff : std_logic_vector(7 downto 0);
   signal mrg_objcolv    : std_logic;
   signal mrg_objsetv    : std_logic;
   type t_objwnd_arr is array (0 to 1) of std_logic_vector(0 to 255);
   signal linebuf_objwnd  : t_objwnd_arr := (others => (others => '0'));
   signal linebuf_objcolv : t_objwnd_arr := (others => (others => '0'));
   signal linebuf_objsetv : t_objwnd_arr := (others => (others => '0'));

   type t_linestate is (LIDLE, LDRAW, LMERGE, LFLUSH);
   signal linestate  : t_linestate := LIDLE;
   signal clear_addr : integer range 0 to 256 := 256;
   signal merge_x    : integer range 0 to 256 := 0;
   signal flush_cnt  : integer range 0 to 7 := 0;
   signal merge_ena  : std_logic := '0';
   signal merge_xpos : integer range 0 to 255 := 0;
   signal cur_y      : integer range 0 to 191 := 0;

   signal any_bg_busy : std_logic;

   signal mrg_bg0, mrg_bg1, mrg_bg2, mrg_bg3 : std_logic_vector(15 downto 0);
   signal mrg_obj : std_logic_vector(23 downto 0);
   signal mrg_objwnd : std_logic;
   signal backdrop : std_logic_vector(15 downto 0) := (others => '0');

   signal ypos_mosaic_bg  : integer range 0 to 191;
   signal ypos_mosaic_obj : integer range 0 to 191;
   signal mos_bgy     : integer range 0 to 15  := 0;
   signal mos_bgy_max : integer range 0 to 15  := 0;
   signal mos_bgbase  : integer range 0 to 191 := 0;
   signal mos_objcnt  : integer range 0 to 15  := 0;
   signal mos_objbase : integer range 0 to 191 := 0;

   signal merge_out666    : std_logic_vector(17 downto 0);

begin

   iDISPCNT_BG_Mode    : entity work.eProcReg_gba generic map (DISPCNT_BG_Mode)            port map (clk, gb_bus, reg_wired_or(0),  reg_wired_done(0),  R_bgmode, R_bgmode);
   iDISPCNT_BG0_3D     : entity work.eProcReg_gba generic map (DISPCNT_BG0_3D)             port map (clk, gb_bus, reg_wired_or(1),  reg_wired_done(1),  R_bg0_3d, R_bg0_3d);
   iDISPCNT_OBJ1D      : entity work.eProcReg_gba generic map (DISPCNT_Tile_OBJ_1D)        port map (clk, gb_bus, reg_wired_or(2),  reg_wired_done(2),  R_obj1d, R_obj1d);
   iDISPCNT_BMP2DW     : entity work.eProcReg_gba generic map (DISPCNT_Bitmap_OBJ_2D_Wide) port map (clk, gb_bus, reg_wired_or(3),  reg_wired_done(3),  R_bmp2dwide, R_bmp2dwide);
   iDISPCNT_BMP1D      : entity work.eProcReg_gba generic map (DISPCNT_Bitmap_OBJ_1D)      port map (clk, gb_bus, reg_wired_or(4),  reg_wired_done(4),  R_bmp1d, R_bmp1d);
   iDISPCNT_FBLANK     : entity work.eProcReg_gba generic map (DISPCNT_Forced_Blank)       port map (clk, gb_bus, reg_wired_or(5),  reg_wired_done(5),  R_forced_blank, R_forced_blank);
   iDISPCNT_ENA_BG0    : entity work.eProcReg_gba generic map (DISPCNT_Screen_Display_BG0) port map (clk, gb_bus, reg_wired_or(6),  reg_wired_done(6),  R_ena_bg0, R_ena_bg0);
   iDISPCNT_ENA_BG1    : entity work.eProcReg_gba generic map (DISPCNT_Screen_Display_BG1) port map (clk, gb_bus, reg_wired_or(7),  reg_wired_done(7),  R_ena_bg1, R_ena_bg1);
   iDISPCNT_ENA_BG2    : entity work.eProcReg_gba generic map (DISPCNT_Screen_Display_BG2) port map (clk, gb_bus, reg_wired_or(8),  reg_wired_done(8),  R_ena_bg2, R_ena_bg2);
   iDISPCNT_ENA_BG3    : entity work.eProcReg_gba generic map (DISPCNT_Screen_Display_BG3) port map (clk, gb_bus, reg_wired_or(9),  reg_wired_done(9),  R_ena_bg3, R_ena_bg3);
   iDISPCNT_ENA_OBJ    : entity work.eProcReg_gba generic map (DISPCNT_Screen_Display_OBJ) port map (clk, gb_bus, reg_wired_or(10), reg_wired_done(10), R_ena_obj, R_ena_obj);
   iDISPCNT_WIN0       : entity work.eProcReg_gba generic map (DISPCNT_Window_0_Display)   port map (clk, gb_bus, reg_wired_or(11), reg_wired_done(11), R_win0_on, R_win0_on);
   iDISPCNT_WIN1       : entity work.eProcReg_gba generic map (DISPCNT_Window_1_Display)   port map (clk, gb_bus, reg_wired_or(12), reg_wired_done(12), R_win1_on, R_win1_on);
   iDISPCNT_WINOBJ     : entity work.eProcReg_gba generic map (DISPCNT_OBJ_Wnd_Display)    port map (clk, gb_bus, reg_wired_or(13), reg_wired_done(13), R_winobj_on, R_winobj_on);
   iDISPCNT_DISPMODE   : entity work.eProcReg_gba generic map (DISPCNT_Display_Mode)       port map (clk, gb_bus, reg_wired_or(14), reg_wired_done(14), R_dispmode, R_dispmode);
   iDISPCNT_VRAMBLK    : entity work.eProcReg_gba generic map (DISPCNT_VRAM_Block)         port map (clk, gb_bus, reg_wired_or(15), reg_wired_done(15), R_vramblock, R_vramblock);
   iDISPCNT_OBJBOUND   : entity work.eProcReg_gba generic map (DISPCNT_Tile_OBJ_Boundary)  port map (clk, gb_bus, reg_wired_or(16), reg_wired_done(16), R_objbound, R_objbound);
   iDISPCNT_BMPBOUND   : entity work.eProcReg_gba generic map (DISPCNT_Bitmap_OBJ_Boundary)port map (clk, gb_bus, reg_wired_or(17), reg_wired_done(17), R_bmpbound, R_bmpbound);
   iDISPCNT_OBJHBL     : entity work.eProcReg_gba generic map (DISPCNT_OBJ_HBlank_Proc)    port map (clk, gb_bus, reg_wired_or(18), reg_wired_done(18), R_objhbl, R_objhbl);
   iDISPCNT_CHARBASE   : entity work.eProcReg_gba generic map (DISPCNT_Char_Base)          port map (clk, gb_bus, reg_wired_or(19), reg_wired_done(19), R_charbase, R_charbase);
   iDISPCNT_SCREENBASE : entity work.eProcReg_gba generic map (DISPCNT_Screen_Base)        port map (clk, gb_bus, reg_wired_or(20), reg_wired_done(20), R_screenbase, R_screenbase);
   iDISPCNT_BGEXTPAL   : entity work.eProcReg_gba generic map (DISPCNT_BG_ExtPal)          port map (clk, gb_bus, reg_wired_or(21), reg_wired_done(21), R_bgextpal, R_bgextpal);
   iDISPCNT_OBJEXTPAL  : entity work.eProcReg_gba generic map (DISPCNT_OBJ_ExtPal)         port map (clk, gb_bus, reg_wired_or(22), reg_wired_done(22), R_objextpal, R_objextpal);

   iBG0CNT_PRIO  : entity work.eProcReg_gba generic map (BG0CNT_Priority)    port map (clk, gb_bus, reg_wired_or(23), reg_wired_done(23), R_bgcnt(0).prio,       R_bgcnt(0).prio);
   iBG0CNT_CHAR  : entity work.eProcReg_gba generic map (BG0CNT_Char_Base)   port map (clk, gb_bus, reg_wired_or(24), reg_wired_done(24), R_bgcnt(0).charbase,   R_bgcnt(0).charbase);
   iBG0CNT_MOS   : entity work.eProcReg_gba generic map (BG0CNT_Mosaic)      port map (clk, gb_bus, reg_wired_or(25), reg_wired_done(25), R_bgcnt(0).mosaic,     R_bgcnt(0).mosaic);
   iBG0CNT_HICOL : entity work.eProcReg_gba generic map (BG0CNT_HiColor)     port map (clk, gb_bus, reg_wired_or(26), reg_wired_done(26), R_bgcnt(0).hicolor,    R_bgcnt(0).hicolor);
   iBG0CNT_SCR   : entity work.eProcReg_gba generic map (BG0CNT_Screen_Base) port map (clk, gb_bus, reg_wired_or(27), reg_wired_done(27), R_bgcnt(0).screenbase, R_bgcnt(0).screenbase);
   iBG0CNT_SLOT  : entity work.eProcReg_gba generic map (BG0CNT_ExtPal_Slot) port map (clk, gb_bus, reg_wired_or(28), reg_wired_done(28), R_bgcnt(0).slotwrap,   R_bgcnt(0).slotwrap);
   iBG0CNT_SIZE  : entity work.eProcReg_gba generic map (BG0CNT_Screen_Size) port map (clk, gb_bus, reg_wired_or(29), reg_wired_done(29), R_bgcnt(0).size,       R_bgcnt(0).size);

   iBG1CNT_PRIO  : entity work.eProcReg_gba generic map (BG1CNT_Priority)    port map (clk, gb_bus, reg_wired_or(30), reg_wired_done(30), R_bgcnt(1).prio,       R_bgcnt(1).prio);
   iBG1CNT_CHAR  : entity work.eProcReg_gba generic map (BG1CNT_Char_Base)   port map (clk, gb_bus, reg_wired_or(31), reg_wired_done(31), R_bgcnt(1).charbase,   R_bgcnt(1).charbase);
   iBG1CNT_MOS   : entity work.eProcReg_gba generic map (BG1CNT_Mosaic)      port map (clk, gb_bus, reg_wired_or(32), reg_wired_done(32), R_bgcnt(1).mosaic,     R_bgcnt(1).mosaic);
   iBG1CNT_HICOL : entity work.eProcReg_gba generic map (BG1CNT_HiColor)     port map (clk, gb_bus, reg_wired_or(33), reg_wired_done(33), R_bgcnt(1).hicolor,    R_bgcnt(1).hicolor);
   iBG1CNT_SCR   : entity work.eProcReg_gba generic map (BG1CNT_Screen_Base) port map (clk, gb_bus, reg_wired_or(34), reg_wired_done(34), R_bgcnt(1).screenbase, R_bgcnt(1).screenbase);
   iBG1CNT_SLOT  : entity work.eProcReg_gba generic map (BG1CNT_ExtPal_Slot) port map (clk, gb_bus, reg_wired_or(35), reg_wired_done(35), R_bgcnt(1).slotwrap,   R_bgcnt(1).slotwrap);
   iBG1CNT_SIZE  : entity work.eProcReg_gba generic map (BG1CNT_Screen_Size) port map (clk, gb_bus, reg_wired_or(36), reg_wired_done(36), R_bgcnt(1).size,       R_bgcnt(1).size);

   iBG2CNT_PRIO  : entity work.eProcReg_gba generic map (BG2CNT_Priority)    port map (clk, gb_bus, reg_wired_or(37), reg_wired_done(37), R_bgcnt(2).prio,       R_bgcnt(2).prio);
   iBG2CNT_CHAR  : entity work.eProcReg_gba generic map (BG2CNT_Char_Base)   port map (clk, gb_bus, reg_wired_or(38), reg_wired_done(38), R_bgcnt(2).charbase,   R_bgcnt(2).charbase);
   iBG2CNT_MOS   : entity work.eProcReg_gba generic map (BG2CNT_Mosaic)      port map (clk, gb_bus, reg_wired_or(39), reg_wired_done(39), R_bgcnt(2).mosaic,     R_bgcnt(2).mosaic);
   iBG2CNT_HICOL : entity work.eProcReg_gba generic map (BG2CNT_HiColor)     port map (clk, gb_bus, reg_wired_or(40), reg_wired_done(40), R_bgcnt(2).hicolor,    R_bgcnt(2).hicolor);
   iBG2CNT_SCR   : entity work.eProcReg_gba generic map (BG2CNT_Screen_Base) port map (clk, gb_bus, reg_wired_or(41), reg_wired_done(41), R_bgcnt(2).screenbase, R_bgcnt(2).screenbase);
   iBG2CNT_WRAP  : entity work.eProcReg_gba generic map (BG2CNT_Wrap)        port map (clk, gb_bus, reg_wired_or(42), reg_wired_done(42), R_bgcnt(2).slotwrap,   R_bgcnt(2).slotwrap);
   iBG2CNT_SIZE  : entity work.eProcReg_gba generic map (BG2CNT_Screen_Size) port map (clk, gb_bus, reg_wired_or(43), reg_wired_done(43), R_bgcnt(2).size,       R_bgcnt(2).size);

   iBG3CNT_PRIO  : entity work.eProcReg_gba generic map (BG3CNT_Priority)    port map (clk, gb_bus, reg_wired_or(44), reg_wired_done(44), R_bgcnt(3).prio,       R_bgcnt(3).prio);
   iBG3CNT_CHAR  : entity work.eProcReg_gba generic map (BG3CNT_Char_Base)   port map (clk, gb_bus, reg_wired_or(45), reg_wired_done(45), R_bgcnt(3).charbase,   R_bgcnt(3).charbase);
   iBG3CNT_MOS   : entity work.eProcReg_gba generic map (BG3CNT_Mosaic)      port map (clk, gb_bus, reg_wired_or(46), reg_wired_done(46), R_bgcnt(3).mosaic,     R_bgcnt(3).mosaic);
   iBG3CNT_HICOL : entity work.eProcReg_gba generic map (BG3CNT_HiColor)     port map (clk, gb_bus, reg_wired_or(47), reg_wired_done(47), R_bgcnt(3).hicolor,    R_bgcnt(3).hicolor);
   iBG3CNT_SCR   : entity work.eProcReg_gba generic map (BG3CNT_Screen_Base) port map (clk, gb_bus, reg_wired_or(48), reg_wired_done(48), R_bgcnt(3).screenbase, R_bgcnt(3).screenbase);
   iBG3CNT_WRAP  : entity work.eProcReg_gba generic map (BG3CNT_Wrap)        port map (clk, gb_bus, reg_wired_or(49), reg_wired_done(49), R_bgcnt(3).slotwrap,   R_bgcnt(3).slotwrap);
   iBG3CNT_SIZE  : entity work.eProcReg_gba generic map (BG3CNT_Screen_Size) port map (clk, gb_bus, reg_wired_or(50), reg_wired_done(50), R_bgcnt(3).size,       R_bgcnt(3).size);

   iBG0HOFS : entity work.eProcReg_gba generic map (BG0HOFS) port map (clk, gb_bus, reg_wired_or(51), reg_wired_done(51), R_hofs(0), R_hofs(0));
   iBG1HOFS : entity work.eProcReg_gba generic map (BG1HOFS) port map (clk, gb_bus, reg_wired_or(52), reg_wired_done(52), R_hofs(1), R_hofs(1));
   iBG2HOFS : entity work.eProcReg_gba generic map (BG2HOFS) port map (clk, gb_bus, reg_wired_or(53), reg_wired_done(53), R_hofs(2), R_hofs(2));
   iBG3HOFS : entity work.eProcReg_gba generic map (BG3HOFS) port map (clk, gb_bus, reg_wired_or(54), reg_wired_done(54), R_hofs(3), R_hofs(3));
   iBG0VOFS : entity work.eProcReg_gba generic map (BG0VOFS) port map (clk, gb_bus, reg_wired_or(55), reg_wired_done(55), R_vofs(0), R_vofs(0));
   iBG1VOFS : entity work.eProcReg_gba generic map (BG1VOFS) port map (clk, gb_bus, reg_wired_or(56), reg_wired_done(56), R_vofs(1), R_vofs(1));
   iBG2VOFS : entity work.eProcReg_gba generic map (BG2VOFS) port map (clk, gb_bus, reg_wired_or(57), reg_wired_done(57), R_vofs(2), R_vofs(2));
   iBG3VOFS : entity work.eProcReg_gba generic map (BG3VOFS) port map (clk, gb_bus, reg_wired_or(58), reg_wired_done(58), R_vofs(3), R_vofs(3));

   iBG2DX  : entity work.eProcReg_gba generic map (BG2RotScaleParDX)  port map (clk, gb_bus, open, open, R_bg2dx, R_bg2dx);
   iBG2DMX : entity work.eProcReg_gba generic map (BG2RotScaleParDMX) port map (clk, gb_bus, open, open, R_bg2dmx, R_bg2dmx);
   iBG2DY  : entity work.eProcReg_gba generic map (BG2RotScaleParDY)  port map (clk, gb_bus, open, open, R_bg2dy, R_bg2dy);
   iBG2DMY : entity work.eProcReg_gba generic map (BG2RotScaleParDMY) port map (clk, gb_bus, open, open, R_bg2dmy, R_bg2dmy);
   iBG2RX  : entity work.eProcReg_gba generic map (BG2RefX)           port map (clk, gb_bus, open, open, R_bg2refx, R_bg2refx, ref2x_written);
   iBG2RY  : entity work.eProcReg_gba generic map (BG2RefY)           port map (clk, gb_bus, open, open, R_bg2refy, R_bg2refy, ref2y_written);
   iBG3DX  : entity work.eProcReg_gba generic map (BG3RotScaleParDX)  port map (clk, gb_bus, open, open, R_bg3dx, R_bg3dx);
   iBG3DMX : entity work.eProcReg_gba generic map (BG3RotScaleParDMX) port map (clk, gb_bus, open, open, R_bg3dmx, R_bg3dmx);
   iBG3DY  : entity work.eProcReg_gba generic map (BG3RotScaleParDY)  port map (clk, gb_bus, open, open, R_bg3dy, R_bg3dy);
   iBG3DMY : entity work.eProcReg_gba generic map (BG3RotScaleParDMY) port map (clk, gb_bus, open, open, R_bg3dmy, R_bg3dmy);
   iBG3RX  : entity work.eProcReg_gba generic map (BG3RefX)           port map (clk, gb_bus, open, open, R_bg3refx, R_bg3refx, ref3x_written);
   iBG3RY  : entity work.eProcReg_gba generic map (BG3RefY)           port map (clk, gb_bus, open, open, R_bg3refy, R_bg3refy, ref3y_written);

   iWIN0H  : entity work.eProcReg_gba generic map ((16#040#, 15, 0, 1, 0, writeonly))  port map (clk, gb_bus, open, open, R_win0h, R_win0h);
   iWIN1H  : entity work.eProcReg_gba generic map ((16#040#, 31, 16, 1, 0, writeonly)) port map (clk, gb_bus, open, open, R_win1h, R_win1h);
   iWIN0V  : entity work.eProcReg_gba generic map ((16#044#, 15, 0, 1, 0, writeonly))  port map (clk, gb_bus, open, open, R_win0v, R_win0v);
   iWIN1V  : entity work.eProcReg_gba generic map ((16#044#, 31, 16, 1, 0, writeonly)) port map (clk, gb_bus, open, open, R_win1v, R_win1v);
   iWININ0 : entity work.eProcReg_gba generic map (WININ_Win0_Enables)    port map (clk, gb_bus, reg_wired_or(59), reg_wired_done(59), R_winin0, R_winin0);
   iWININ1 : entity work.eProcReg_gba generic map (WININ_Win1_Enables)    port map (clk, gb_bus, reg_wired_or(60), reg_wired_done(60), R_winin1, R_winin1);
   iWINOUT : entity work.eProcReg_gba generic map (WINOUT_Enables)        port map (clk, gb_bus, reg_wired_or(61), reg_wired_done(61), R_winout, R_winout);
   iWINOBJ : entity work.eProcReg_gba generic map (WINOUT_Objwnd_Enables) port map (clk, gb_bus, reg_wired_or(62), reg_wired_done(62), R_winobj, R_winobj);

   iMOSBGH  : entity work.eProcReg_gba generic map (MOSAIC_BG_H)  port map (clk, gb_bus, open, open, R_mos_bgh, R_mos_bgh);
   iMOSBGV  : entity work.eProcReg_gba generic map (MOSAIC_BG_V)  port map (clk, gb_bus, open, open, R_mos_bgv, R_mos_bgv);
   iMOSOBJH : entity work.eProcReg_gba generic map (MOSAIC_OBJ_H) port map (clk, gb_bus, open, open, R_mos_objh, R_mos_objh);
   iMOSOBJV : entity work.eProcReg_gba generic map (MOSAIC_OBJ_V) port map (clk, gb_bus, open, open, R_mos_objv, R_mos_objv);

   iBLD1ST : entity work.eProcReg_gba generic map (BLDCNT_1st_Target) port map (clk, gb_bus, reg_wired_or(63), reg_wired_done(63), R_bld1st, R_bld1st);
   iBLDEFF : entity work.eProcReg_gba generic map (BLDCNT_Effect)     port map (clk, gb_bus, reg_wired_or(64), reg_wired_done(64), R_bldeff, R_bldeff);
   iBLD2ND : entity work.eProcReg_gba generic map (BLDCNT_2nd_Target) port map (clk, gb_bus, reg_wired_or(65), reg_wired_done(65), R_bld2nd, R_bld2nd);
   iEVA    : entity work.eProcReg_gba generic map (BLDALPHA_EVA)      port map (clk, gb_bus, reg_wired_or(66), reg_wired_done(66), R_eva, R_eva);
   iEVB    : entity work.eProcReg_gba generic map (BLDALPHA_EVB)      port map (clk, gb_bus, reg_wired_or(67), reg_wired_done(67), R_evb, R_evb);
   iBLDY   : entity work.eProcReg_gba generic map (BLDY)              port map (clk, gb_bus, reg_wired_or(68), reg_wired_done(68), R_bldy, R_bldy);
   iMBRF   : entity work.eProcReg_gba generic map (MASTER_BRIGHT_Factor) port map (clk, gb_bus, reg_wired_or(69), reg_wired_done(69), R_mbright_f, R_mbright_f);
   iMBRM   : entity work.eProcReg_gba generic map (MASTER_BRIGHT_Mode)   port map (clk, gb_bus, reg_wired_or(70), reg_wired_done(70), R_mbright_m, R_mbright_m);

   process (all)
      variable wired_or : std_logic_vector(31 downto 0);
      variable wired_dn : std_logic;
   begin
      wired_or := (others => '0');
      wired_dn := '0';
      for i in 0 to REGCOUNT-1 loop
         wired_or := wired_or or reg_wired_or(i);
         wired_dn := wired_dn or reg_wired_done(i);
      end loop;
      wired_out  <= wired_or;
      wired_done <= wired_dn;
   end process;

   eff_screenbase <= R_screenbase when is_engine_b = '0' else "000";
   eff_charbase   <= R_charbase   when is_engine_b = '0' else "000";
   eff_bmpbound   <= R_bmpbound(22) when is_engine_b = '0' else '0';

   gen_cfg : for i in 0 to 3 generate
      cfg_mapbase(i)  <= to_unsigned((to_integer(unsigned(eff_screenbase)) * 65536
                                    + to_integer(unsigned(R_bgcnt(i).screenbase)) * 2048) mod 524288, 19);
      cfg_tilebase(i) <= to_unsigned((to_integer(unsigned(eff_charbase)) * 65536
                                    + to_integer(unsigned(R_bgcnt(i).charbase)) * 16384) mod 524288, 19);
      cfg_bmpbase(i)  <= to_unsigned((to_integer(unsigned(R_bgcnt(i).screenbase)) * 16384) mod 524288, 19);
   end generate;

   cfg_extslot(0) <= "10" when R_bgcnt(0).slotwrap = "1" else "00";
   cfg_extslot(1) <= "11" when R_bgcnt(1).slotwrap = "1" else "01";
   cfg_extslot(2) <= "10";
   cfg_extslot(3) <= "11";

   gen_var : for i in 2 to 3 generate
      cfg_variant(i) <= "00" when R_bgcnt(i).hicolor = "0" else
                        "01" when R_bgcnt(i).charbase(0) = '0' else
                        "10";
      cfg_extbase(i) <= cfg_mapbase(i) when R_bgcnt(i).hicolor = "0" else cfg_bmpbase(i);
      cfg_isaff(i)   <= '1' when bgtype(i) = 2 else '0';
      cfg_aebase(i)  <= cfg_mapbase(i) when bgtype(i) = 2 else cfg_extbase(i);
   end generate;

   refx_arr(2) <= ref2x_int;  refy_arr(2) <= ref2y_int;
   refx_arr(3) <= ref3x_int;  refy_arr(3) <= ref3y_int;
   dx_arr(2)   <= signed(R_bg2dx);  dy_arr(2) <= signed(R_bg2dy);
   dx_arr(3)   <= signed(R_bg3dx);  dy_arr(3) <= signed(R_bg3dy);

   process (all)
   begin
      bgtype <= (0, 0, 0, 0);
      case to_integer(unsigned(R_bgmode)) is
         when 0 => bgtype <= (1, 1, 1, 1);
         when 1 => bgtype <= (1, 1, 1, 2);
         when 2 => bgtype <= (1, 1, 2, 2);
         when 3 => bgtype <= (1, 1, 1, 3);
         when 4 => bgtype <= (1, 1, 2, 3);
         when 5 => bgtype <= (1, 1, 3, 3);
         when others => bgtype <= (0, 0, 0, 0);
      end case;
      if (R_bg0_3d = "1" and is_engine_b = '0') then
         bgtype(0) <= 0;
      end if;
   end process;

   process (clk)
   begin
      if rising_edge(clk) then
         if (reset = '1' or vblank_trigger = '1') then
            mos_bgy     <= 0;
            mos_bgy_max <= to_integer(unsigned(R_mos_bgv));
            mos_bgbase  <= 0;
         elsif (refpoint_update = '1') then
            if (mos_bgy >= mos_bgy_max) then
               mos_bgy     <= 0;
               mos_bgy_max <= to_integer(unsigned(R_mos_bgv));
               if (linecounter < 191) then
                  mos_bgbase <= linecounter + 1;
               else
                  mos_bgbase <= 191;
               end if;
            else
               mos_bgy <= mos_bgy + 1;
            end if;
         end if;
      end if;
   end process;

   ypos_mosaic_bg <= mos_bgbase;

   process (clk)
   begin
      if rising_edge(clk) then
         if (reset = '1' or vblank_trigger = '1') then
            mos_objcnt <= to_integer(unsigned(R_mos_objv));
         elsif (drawObj = '1') then
            if (mos_objcnt >= to_integer(unsigned(R_mos_objv))) then
               mos_objcnt  <= 0;
               mos_objbase <= linecounter_obj;
            else
               mos_objcnt <= mos_objcnt + 1;
            end if;
         end if;
      end if;
   end process;

   ypos_mosaic_obj <= mos_objbase;

   process (clk)
   begin
      if rising_edge(clk) then
         if (reset = '1' or vblank_trigger = '1') then
            ref2x_int <= signed(R_bg2refx);
            ref2y_int <= signed(R_bg2refy);
            ref3x_int <= signed(R_bg3refx);
            ref3y_int <= signed(R_bg3refy);
         else
            if (ref2x_written = '1') then ref2x_int <= signed(R_bg2refx);
            elsif (refpoint_update = '1') then ref2x_int <= ref2x_int + resize(signed(R_bg2dmx), 28); end if;
            if (ref2y_written = '1') then ref2y_int <= signed(R_bg2refy);
            elsif (refpoint_update = '1') then ref2y_int <= ref2y_int + resize(signed(R_bg2dmy), 28); end if;
            if (ref3x_written = '1') then ref3x_int <= signed(R_bg3refx);
            elsif (refpoint_update = '1') then ref3x_int <= ref3x_int + resize(signed(R_bg3dmx), 28); end if;
            if (ref3y_written = '1') then ref3y_int <= signed(R_bg3refy);
            elsif (refpoint_update = '1') then ref3y_int <= ref3y_int + resize(signed(R_bg3dmy), 28); end if;
         end if;
      end if;
   end process;

   drawline_acc <= drawline when linestate = LIDLE else '0';
   drawobj_acc  <= drawObj  when obj_busy = '0' else '0';

   gen_dl_text : for i in 0 to 3 generate
      drawline_text(i) <= drawline_acc when (bgtype(i) = 1) else '0';
   end generate;
   gen_dl_a : for i in 2 to 3 generate
      drawline_ae(i) <= drawline_acc when (bgtype(i) = 2 or bgtype(i) = 3) else '0';
   end generate;

   any_bg_busy <= busy_text(0) or busy_text(1) or busy_text(2) or busy_text(3)
                  or busy_ae(2) or busy_ae(3);

   gen_text : for i in 0 to 3 generate
      itext : entity work.nds_drawer_text
      port map
      (
         clk                  => clk,
         drawline             => drawline_text(i),
         busy                 => busy_text(i),
         ypos                 => linecounter,
         ypos_mosaic          => ypos_mosaic_bg,
         mapbase              => cfg_mapbase(i),
         tilebase             => cfg_tilebase(i),
         hicolor              => R_bgcnt(i).hicolor(0),
         extpalette           => R_bgextpal(30),
         extpal_slot          => cfg_extslot(i),
         mosaic               => R_bgcnt(i).mosaic(0),
         Mosaic_H_Size        => unsigned(R_mos_bgh),
         screensize           => unsigned(R_bgcnt(i).size),
         scrollX              => unsigned(R_hofs(i)),
         scrollY              => unsigned(R_vofs(i)),
         pixel_we             => pix_we_text(i),
         pixeldata            => pix_text(i),
         pixel_x              => pixx_text(i),
         PALETTE_Drawer_addr  => p_addr_text(i),
         PALETTE_Drawer_data  => bgp_data(i),
         PALETTE_Drawer_valid => bgp_valid(i),
         EXTPAL_Drawer_addr   => ep_addr_text(i),
         EXTPAL_Drawer_data   => bgep_data(i),
         EXTPAL_Drawer_valid  => bgep_valid(i),
         VRAM_Drawer_req      => v_req_text(i),
         VRAM_Drawer_addr     => v_addr_text(i),
         VRAM_Drawer_data     => bgv_data,
         VRAM_Drawer_done     => bgv_done(i),
         VRAM_Drawer_accept   => bgv_accept(i)
      );
   end generate;

   gen_affext : for i in 2 to 3 generate
      iae : entity work.nds_drawer_affext
      port map
      (
         clk                  => clk,
         line_trigger         => line_trigger,
         drawline             => drawline_ae(i),
         busy                 => busy_ae(i),
         is_affine            => cfg_isaff(i),
         variant              => cfg_variant(i),
         mapbase              => cfg_aebase(i),
         tilebase             => cfg_tilebase(i),
         extpalette           => R_bgextpal(30),
         extpal_slot          => cfg_extslot(i),
         screensize           => unsigned(R_bgcnt(i).size),
         wrapping             => R_bgcnt(i).slotwrap(0),
         mosaic               => R_bgcnt(i).mosaic(0),
         Mosaic_H_Size        => unsigned(R_mos_bgh),
         refX                 => refx_arr(i),
         refY                 => refy_arr(i),
         refX_mosaic          => refx_arr(i),
         refY_mosaic          => refy_arr(i),
         dx                   => dx_arr(i),
         dy                   => dy_arr(i),
         pixel_we             => pix_we_ae(i),
         pixeldata            => pix_ae(i),
         pixel_x              => pixx_ae(i),
         PALETTE_Drawer_addr  => p_addr_ae(i),
         PALETTE_Drawer_data  => bgp_data(i),
         PALETTE_Drawer_valid => bgp_valid(i),
         EXTPAL_Drawer_addr   => ep_addr_ae(i),
         EXTPAL_Drawer_data   => bgep_data(i),
         EXTPAL_Drawer_valid  => bgep_valid(i),
         VRAM_Drawer_req      => v_req_ae(i),
         VRAM_Drawer_addr     => v_addr_ae(i),
         VRAM_Drawer_data     => bgv_data,
         VRAM_Drawer_done     => bgv_done(i),
         VRAM_Drawer_accept   => bgv_accept(i)
      );
   end generate;

   iobj : entity work.nds_drawer_obj
   port map
   (
      clk                  => clk,
      drawline             => drawobj_acc,
      busy                 => obj_busy,
      ypos                 => linecounter_obj,
      ypos_mosaic          => ypos_mosaic_obj,
      one_dim_mapping      => R_obj1d(4),
      tile_boundary        => unsigned(R_objbound),
      bitmap_1d            => R_bmp1d(6),
      bitmap_2d_wide       => R_bmp2dwide(5),
      bitmap_1d_boundary   => eff_bmpbound,
      obj_extpal           => R_objextpal(31),
      Mosaic_H_Size        => unsigned(R_mos_objh),
      hblankfree           => not R_objhbl(23),
      pixel_we_color       => obj_we_color,
      pixeldata_color      => obj_color,
      pixel_we_settings    => obj_we_settings,
      pixeldata_settings   => obj_settings,
      pixel_x              => obj_x,
      pixel_objwnd         => obj_objwnd,
      OAMRAM_Drawer_addr   => obj_oam_addr,
      OAMRAM_Drawer_data   => obj_oam_data,
      OAMAFF_Drawer_addr   => obj_oamaff_addr,
      OAMAFF_Drawer_data   => obj_oamaff_data,
      PALETTE_Drawer_addr  => obj_pal_addr,
      PALETTE_Drawer_data  => obj_pal_data,
      EXTPAL_Drawer_addr   => obj_ep_addr,
      EXTPAL_Drawer_data   => obj_ep_data,
      VRAM_Drawer_req      => srv_obj_req,
      VRAM_Drawer_addr     => srv_obj_addr,
      VRAM_Drawer_data     => srv_obj_data,
      VRAM_Drawer_done     => srv_obj_done,
      VRAM_Drawer_accept   => srv_obj_accept
   );

   -- M10K stores; the drawer-side reads keep their 1-cycle registered-read
   -- these three M10Ks keep the previous game's palette and sprite table and
   p_clear : process (clk)
   begin
      if rising_edge(clk) then
         reset_d <= reset;
         if (reset = '1' and reset_d = '0') then
            clr_addr <= (others => '0');
            clr_run  <= '1';
         elsif (clr_run = '1') then
            if (clr_addr = 255) then
               clr_run <= '0';
            else
               clr_addr <= clr_addr + 1;
            end if;
         end if;
      end if;
   end process;

   clr_busy <= clr_run;

   pal_we_i   <= '1'          when clr_run = '1' else pal_we;
   pal_addr_i <= to_integer(clr_addr) when clr_run = '1' else pal_addr;
   pal_din_i  <= (others => '0') when clr_run = '1' else pal_din;
   pal_be_i   <= "1111"       when clr_run = '1' else pal_be;
   oam_we_i   <= '1'          when clr_run = '1' else oam_we;
   oam_addr_i <= to_integer(clr_addr) when clr_run = '1' else oam_addr;
   oam_din_i  <= (others => '0') when clr_run = '1' else oam_din;
   oam_be_i   <= "1111"       when clr_run = '1' else oam_be;

   ipal_obj : entity MEM.SyncRamDualByteEnable
   generic map ( is_simu => is_simu, is_cyclone5 => '1',
                 BYTE_WIDTH => 8, ADDR_WIDTH => 8, BYTES => 4 )
   port map
   (
      clk       => clk,
      ce_a      => '1',
      addr_a    => pal_addr_i,
      datain_a0 => pal_din_i( 7 downto  0),
      datain_a1 => pal_din_i(15 downto  8),
      datain_a2 => pal_din_i(23 downto 16),
      datain_a3 => pal_din_i(31 downto 24),
      dataout_a => open,
      we_a      => pal_we_i,
      be_a      => pal_be_i,
      ce_b      => '1',
      addr_b    => 128 + obj_pal_addr,
      datain_b0 => x"00", datain_b1 => x"00", datain_b2 => x"00", datain_b3 => x"00",
      dataout_b => obj_pal_data,
      we_b      => '0',
      be_b      => "0000"
   );

   gpal_bg : for i in 0 to 3 generate
      ipal_bg : entity MEM.SyncRamDualByteEnable
      generic map ( is_simu => is_simu, is_cyclone5 => '1',
                    BYTE_WIDTH => 8, ADDR_WIDTH => 8, BYTES => 4 )
      port map
      (
         clk       => clk,
         ce_a      => '1',
         addr_a    => pal_addr_i,
         datain_a0 => pal_din_i( 7 downto  0),
         datain_a1 => pal_din_i(15 downto  8),
         datain_a2 => pal_din_i(23 downto 16),
         datain_a3 => pal_din_i(31 downto 24),
         dataout_a => open,
         we_a      => pal_we_i,
         be_a      => pal_be_i,
         ce_b      => '1',
         addr_b    => bgp_addr(i),
         datain_b0 => x"00", datain_b1 => x"00", datain_b2 => x"00", datain_b3 => x"00",
         dataout_b => bgp_data(i),
         we_b      => '0',
         be_b      => "0000"
      );
   end generate;

   goam : for i in 0 to 1 generate
      ioam : entity MEM.SyncRamDualByteEnable
      generic map ( is_simu => is_simu, is_cyclone5 => '1',
                    BYTE_WIDTH => 8, ADDR_WIDTH => 8, BYTES => 4 )
      port map
      (
         clk       => clk,
         ce_a      => '1',
         addr_a    => oam_addr_i,
         datain_a0 => oam_din_i( 7 downto  0),
         datain_a1 => oam_din_i(15 downto  8),
         datain_a2 => oam_din_i(23 downto 16),
         datain_a3 => oam_din_i(31 downto 24),
         dataout_a => open,
         we_a      => oam_we_i,
         be_a      => oam_be_i,
         ce_b      => '1',
         addr_b    => obj_oam_addr * 2 + i,
         datain_b0 => x"00", datain_b1 => x"00", datain_b2 => x"00", datain_b3 => x"00",
         dataout_b => obj_oam_data(32*i + 31 downto 32*i),
         we_b      => '0',
         be_b      => "0000"
      );
   end generate;

   gaff : for i in 0 to 1 generate
      signal aff_we   : std_logic;
      signal aff_half : std_logic;
      signal aff_be   : std_logic_vector(3 downto 0);
   begin
      aff_we   <= oam_we_i when (oam_addr_i mod 2 = 1 and ((oam_addr_i / 4) mod 2) = i) else '0';
      aff_half <= '1'      when ((oam_addr_i / 2) mod 2) = 1 else '0';
      aff_be   <= (oam_be_i(3 downto 2) & "00") when aff_half = '1' else ("00" & oam_be_i(3 downto 2));

      iaff : entity MEM.SyncRamDualByteEnable
      generic map ( is_simu => is_simu, is_cyclone5 => '1',
                    BYTE_WIDTH => 8, ADDR_WIDTH => 5, BYTES => 4 )
      port map
      (
         clk       => clk,
         ce_a      => '1',
         addr_a    => oam_addr_i / 8,
         datain_a0 => oam_din_i(23 downto 16),
         datain_a1 => oam_din_i(31 downto 24),
         datain_a2 => oam_din_i(23 downto 16),
         datain_a3 => oam_din_i(31 downto 24),
         dataout_a => open,
         we_a      => aff_we,
         be_a      => aff_be,
         ce_b      => '1',
         addr_b    => obj_oamaff_addr,
         datain_b0 => x"00", datain_b1 => x"00", datain_b2 => x"00", datain_b3 => x"00",
         dataout_b => obj_oamaff_data(32*i + 31 downto 32*i),
         we_b      => '0',
         be_b      => "0000"
      );
   end generate;

   process (clk)
   begin
      if rising_edge(clk) then
         if (pal_we_i = '1' and pal_addr_i = 0) then
            if (pal_be_i(0) = '1') then backdrop( 7 downto 0) <= pal_din_i( 7 downto 0); end if;
            if (pal_be_i(1) = '1') then backdrop(14 downto 8) <= pal_din_i(14 downto 8); end if;
         end if;
         obj_ep_data <= objep_shadow(obj_ep_addr);
      end if;
   end process;

   gen_pmux : for i in 0 to 3 generate
      bgp_addr(i)  <= p_addr_text(i)  when bgtype(i) = 1 else
                      p_addr_ae(i)    when (i >= 2 and (bgtype(i) = 2 or bgtype(i) = 3)) else 0;
      bgep_addr(i) <= ep_addr_text(i) when bgtype(i) = 1 else
                      ep_addr_ae(i)   when (i >= 2 and bgtype(i) = 3) else 0;
   end generate;

   bgp_valid  <= (others => '1');
   bgep_valid <= (others => '1');

   gep_addr : for s in 0 to 3 generate
      epslot_addr_a(s) <= (bgep_addr(0) mod EPSLOT_WORDS) when (s = 0 or s = 2) else
                          (bgep_addr(1) mod EPSLOT_WORDS);
      epslot_addr_b(s) <= (bgep_addr(2) mod EPSLOT_WORDS) when (s = 2) else
                          (bgep_addr(3) mod EPSLOT_WORDS) when (s = 3) else 0;
      epslot_we(s)     <= '1' when (epfill = EPBG_WAIT and srv_bgep_done = '1' and
                                    epfill_addr / EPSLOT_WORDS = s) else '0';
      epslot_pa(s)     <= (epfill_addr mod EPSLOT_WORDS) when epslot_we(s) = '1'
                          else epslot_addr_a(s);
   end generate;

   gepslot : for s in 0 to 3 generate
      iep : entity MEM.SyncRamDualByteEnable
      generic map ( is_simu => is_simu, is_cyclone5 => '1',
                    BYTE_WIDTH => 8, ADDR_WIDTH => 11, BYTES => 4 )
      port map
      (
         clk       => clk,
         ce_a      => '1',
         addr_a    => epslot_pa(s),
         datain_a0 => srv_bgep_data( 7 downto  0),
         datain_a1 => srv_bgep_data(15 downto  8),
         datain_a2 => srv_bgep_data(23 downto 16),
         datain_a3 => srv_bgep_data(31 downto 24),
         dataout_a => epslot_qa(s),
         we_a      => epslot_we(s),
         be_a      => "1111",
         ce_b      => '1',
         addr_b    => epslot_addr_b(s),
         datain_b0 => x"00", datain_b1 => x"00", datain_b2 => x"00", datain_b3 => x"00",
         dataout_b => epslot_qb(s),
         we_b      => '0',
         be_b      => "0000"
      );
   end generate;

   process (clk)
   begin
      if rising_edge(clk) then
         for i in 0 to 3 loop
            extslot_d(i) <= cfg_extslot(i);
         end loop;
      end if;
   end process;

   bgep_data(0) <= epslot_qa(0) when extslot_d(0) = "00" else epslot_qa(2);
   bgep_data(1) <= epslot_qa(1) when extslot_d(1) = "01" else epslot_qa(3);
   bgep_data(2) <= epslot_qb(2);
   bgep_data(3) <= epslot_qb(3);

   gen_vmux01 : for i in 0 to 1 generate
      bgv_req(i)  <= v_req_text(i)  when bgtype(i) = 1 else '0';
      bgv_addr(i) <= v_addr_text(i) when bgtype(i) = 1 else 0;
   end generate;
   gen_vmux23 : for i in 2 to 3 generate
      bgv_req(i)  <= v_req_text(i) when bgtype(i) = 1 else
                     v_req_ae(i)   when (bgtype(i) = 2 or bgtype(i) = 3) else '0';
      bgv_addr(i) <= v_addr_text(i) when bgtype(i) = 1 else
                     v_addr_ae(i)   when (bgtype(i) = 2 or bgtype(i) = 3) else 0;
   end generate;

   b_arb : block
      constant OS_DEPTH : integer := 8;
      type t_owner is array (0 to OS_DEPTH-1) of integer range 0 to 3;
      signal owner    : t_owner := (others => 0);
      signal os_head  : integer range 0 to OS_DEPTH-1 := 0;
      signal os_tail  : integer range 0 to OS_DEPTH-1 := 0;
      signal os_count : integer range 0 to OS_DEPTH := 0;
      signal arb_rr   : integer range 0 to 3 := 0;
      signal arb_busy : std_logic;
      signal pending  : std_logic_vector(0 to 3) := (others => '0');
      signal unaccepted : std_logic := '0';
      signal bg_data_r  : std_logic_vector(31 downto 0) := (others => '0');
   begin
      arb_busy <= '0' when os_count = 0 else '1';

      bgv_data <= bg_data_r;

      process (clk)
         variable pend_v : std_logic_vector(0 to 3);
         variable sel    : integer range 0 to 3;
         variable found  : boolean;
         variable v_cnt  : integer range 0 to OS_DEPTH;
         variable v_head : integer range 0 to OS_DEPTH-1;
         variable v_tail : integer range 0 to OS_DEPTH-1;
      begin
         if rising_edge(clk) then
            srv_bg_req <= '0';
            bgv_done   <= (others => '0');
            bgv_accept <= (others => '0');

            pend_v := pending;
            for i in 0 to 3 loop
               if (bgv_req(i) = '1') then
                  pend_v(i) := '1';
               end if;
            end loop;

            if (srv_bg_accept = '1') then
               unaccepted <= '0';
            end if;

            if (reset = '1') then
               pending    <= (others => '0');
               os_head    <= 0;
               os_tail    <= 0;
               os_count   <= 0;
               unaccepted <= '0';
            else
               v_cnt  := os_count;
               v_head := os_head;
               v_tail := os_tail;

               if (srv_bg_done = '1' and v_cnt > 0) then
                  bgv_done(owner(v_head)) <= '1';
                  bg_data_r               <= srv_bg_data;
                  v_head := (v_head + 1) mod OS_DEPTH;
                  v_cnt  := v_cnt - 1;
               end if;

               found := false;
               sel   := 0;
               for k in 0 to 3 loop
                  if (not found and pend_v((arb_rr + k) mod 4) = '1') then
                     sel   := (arb_rr + k) mod 4;
                     found := true;
                  end if;
               end loop;
               if (found and v_cnt < OS_DEPTH and
                   (unaccepted = '0' or srv_bg_accept = '1')) then
                  arb_rr      <= (sel + 1) mod 4;
                  srv_bg_addr <= bgv_addr(sel);
                  srv_bg_req  <= '1';
                  unaccepted  <= '1';
                  bgv_accept(sel) <= '1';
                  pend_v(sel) := '0';
                  owner(v_tail) <= sel;
                  v_tail := (v_tail + 1) mod OS_DEPTH;
                  v_cnt  := v_cnt + 1;
               end if;

               os_head  <= v_head;
               os_tail  <= v_tail;
               os_count <= v_cnt;
            end if;

            pending <= pend_v;
         end if;
      end process;
   end block;

   process (clk)
   begin
      if rising_edge(clk) then
         srv_bgep_req  <= '0';
         srv_objep_req <= '0';
         if (reset = '1') then
            epfill <= EPIDLE;
         else
            case epfill is
               when EPIDLE =>
                  if (vblank_trigger = '1') then
                     epfill_addr <= 0;
                     epfill      <= EPBG_REQ;
                  end if;
               when EPBG_REQ =>
                  srv_bgep_addr <= epfill_addr;
                  srv_bgep_req  <= '1';
                  epfill        <= EPBG_WAIT;
               when EPBG_WAIT =>
                  if (srv_bgep_done = '1') then
                     if (epfill_addr = 8191) then
                        epfill_addr <= 0;
                        epfill      <= EPOBJ_REQ;
                     else
                        epfill_addr <= epfill_addr + 1;
                        epfill      <= EPBG_REQ;
                     end if;
                  end if;
               when EPOBJ_REQ =>
                  srv_objep_addr <= epfill_addr mod 2048;
                  srv_objep_req  <= '1';
                  epfill         <= EPOBJ_WAIT;
               when EPOBJ_WAIT =>
                  if (srv_objep_done = '1') then
                     objep_shadow(epfill_addr mod 2048) <= srv_objep_data;
                     if (epfill_addr = 2047) then
                        epfill <= EPIDLE;
                     else
                        epfill_addr <= epfill_addr + 1;
                        epfill      <= EPOBJ_REQ;
                     end if;
                  end if;
            end case;
         end if;
      end if;
   end process;

   process (all)
      variable we : std_logic;
      variable wa : integer range 0 to 255;
      variable wd : std_logic_vector(15 downto 0);
   begin
      for i in 0 to 3 loop
         we := '0';
         wa := 0;
         wd := (others => '0');
         if (i < 2 or bgtype(i) = 1) then
            we := pix_we_text(i);
            wa := pixx_text(i);
            wd := pix_text(i);
         elsif (bgtype(i) = 2 or bgtype(i) = 3) then
            we := pix_we_ae(i);
            wa := pixx_ae(i);
            wd := pix_ae(i);
         end if;
         lb_we(i) <= we;
         lb_wa(i) <= wa;
         lb_wd(i) <= wd;
         if (clear_addr < 256 and not (we = '1' and wa = clear_addr)) then
            lb_clrwe(i) <= '1';
         else
            lb_clrwe(i) <= '0';
         end if;
      end loop;
   end process;

   lb_baddr <= clear_addr when clear_addr < 256 else merge_x mod 256;

   gen_lb : for i in 0 to 3 generate
   begin
      ilb : entity MEM.SyncRamDualByteEnable
      generic map ( is_simu => is_simu, is_cyclone5 => '1',
                    BYTE_WIDTH => 8, ADDR_WIDTH => 8, BYTES => 4 )
      port map
      (
         clk       => clk,
         ce_a      => '1',
         addr_a    => lb_wa(i),
         datain_a0 => lb_wd(i)(7 downto 0),
         datain_a1 => lb_wd(i)(15 downto 8),
         datain_a2 => x"00", datain_a3 => x"00",
         dataout_a => open,
         we_a      => lb_we(i),
         be_a      => "0011",
         ce_b      => '1',
         addr_b    => lb_baddr,
         datain_b0 => x"00",
         datain_b1 => x"80",
         datain_b2 => x"00", datain_b3 => x"00",
         dataout_b => lb_bg_q32(i),
         we_b      => lb_clrwe(i),
         be_b      => "0011"
      );
      lb_bg(i) <= lb_bg_q32(i)(15 downto 0);
   end generate;

   objcol_we   <= obj_we_color;
   objset_we   <= obj_we_settings;
   objb_wa_col <= (linecounter_obj mod 2) * 256 + obj_x;
   objb_wa_set <= (linecounter_obj mod 2) * 256 + obj_x;
   objcol_wd   <= obj_color;
   objset_wd   <= obj_settings;

   objb_ra <= (cur_y mod 2) * 256 + (merge_x mod 256);

   iobjbuf : entity MEM.SyncRamDualByteEnable
   generic map ( is_simu => is_simu, is_cyclone5 => '1',
                 BYTE_WIDTH => 8, ADDR_WIDTH => 9, BYTES => 4 )
   port map
   (
      clk       => clk,
      ce_a      => '1',
      addr_a    => objb_wa_col,
      datain_a0 => objcol_wd(7 downto 0),
      datain_a1 => objcol_wd(15 downto 8),
      datain_a2 => objset_wd,
      datain_a3 => x"00",
      dataout_a => open,
      we_a      => objcol_we or objset_we,
      be_a      => '0' & objset_we & objcol_we & objcol_we,
      ce_b      => '1',
      addr_b    => objb_ra,
      datain_b0 => x"00", datain_b1 => x"00",
      datain_b2 => x"00", datain_b3 => x"00",
      dataout_b => obj_q32,
      we_b      => '0',
      be_b      => "0000"
   );
   objcol_q <= obj_q32(15 downto 0);
   objset_q <= obj_q32(23 downto 16);

   mrg_objcol_eff <= objcol_q when mrg_objcolv = '1' else x"8000";
   mrg_objset_eff <= objset_q when mrg_objsetv = '1' else x"00";
   mrg_obj        <= mrg_objset_eff & mrg_objcol_eff;

   process (clk)
   begin
      if rising_edge(clk) then
         if (drawobj_acc = '1') then
            for i in 0 to 255 loop
               linebuf_objwnd(linecounter_obj mod 2)(i)  <= '0';
               linebuf_objcolv(linecounter_obj mod 2)(i) <= '0';
               linebuf_objsetv(linecounter_obj mod 2)(i) <= '0';
            end loop;
         else
            if (obj_objwnd = '1') then
               linebuf_objwnd(linecounter_obj mod 2)(obj_x) <= '1';
            end if;
            if (obj_we_color = '1') then
               linebuf_objcolv(linecounter_obj mod 2)(obj_x) <= '1';
            end if;
            if (obj_we_settings = '1') then
               linebuf_objsetv(linecounter_obj mod 2)(obj_x) <= '1';
            end if;
         end if;
         mrg_objwnd  <= linebuf_objwnd(cur_y mod 2)(merge_x mod 256);
         mrg_objcolv <= linebuf_objcolv(cur_y mod 2)(merge_x mod 256);
         mrg_objsetv <= linebuf_objsetv(cur_y mod 2)(merge_x mod 256);
      end if;
   end process;

   mrg_bg0 <= lb_bg(0);
   mrg_bg1 <= lb_bg(1);
   mrg_bg2 <= lb_bg(2);
   mrg_bg3 <= lb_bg(3);

   process (clk)
   begin
      if rising_edge(clk) then
         merge_ena <= '0';
         if (reset = '1') then
            linestate  <= LIDLE;
            clear_addr <= 256;
         else
            if (clear_addr < 256) then
               clear_addr <= clear_addr + 1;
            end if;

            case linestate is
               when LIDLE =>
                  if (drawline = '1') then
                     linestate  <= LDRAW;
                     clear_addr <= 0;
                     cur_y      <= linecounter;
                  end if;
               when LDRAW =>
                  if (any_bg_busy = '0' and obj_busy = '0' and clear_addr = 256) then
                     linestate <= LMERGE;
                     merge_x   <= 0;
                  end if;
               when LMERGE =>
                  if (merge_x < 256) then
                     merge_x    <= merge_x + 1;
                     merge_ena  <= '1';
                     merge_xpos <= merge_x;
                  else
                     linestate <= LFLUSH;
                     flush_cnt <= 0;
                  end if;
               when LFLUSH =>
                  if (flush_cnt = 7) then
                     linestate <= LIDLE;
                  else
                     flush_cnt <= flush_cnt + 1;
                  end if;
            end case;
         end if;
      end if;
   end process;

   line_busy   <= '0' when linestate = LIDLE else '1';
   epfill_busy <= '0' when epfill = EPIDLE else '1';

   dbg_bg_busy  <= any_bg_busy;
   dbg_obj_busy <= obj_busy;
   dbg_bgmode   <= R_bgmode;
   dbg_fblank   <= R_forced_blank(7);

   imerge : entity work.nds_drawer_merge
   port map
   (
      clk                  => clk,
      enable               => merge_ena,
      hblank               => hblank_trigger,
      xpos                 => merge_xpos,
      ypos                 => cur_y,
      in_WND0_on           => R_win0_on(13),
      in_WND1_on           => R_win1_on(14),
      in_WNDOBJ_on         => R_winobj_on(15),
      in_WND0_X1           => unsigned(R_win0h(15 downto 8)),
      in_WND0_X2           => unsigned(R_win0h(7 downto 0)),
      in_WND0_Y1           => unsigned(R_win0v(15 downto 8)),
      in_WND0_Y2           => unsigned(R_win0v(7 downto 0)),
      in_WND1_X1           => unsigned(R_win1h(15 downto 8)),
      in_WND1_X2           => unsigned(R_win1h(7 downto 0)),
      in_WND1_Y1           => unsigned(R_win1v(15 downto 8)),
      in_WND1_Y2           => unsigned(R_win1v(7 downto 0)),
      in_enables_wnd0      => R_winin0,
      in_enables_wnd1      => R_winin1,
      in_enables_wndobj    => R_winobj,
      in_enables_wndout    => R_winout,
      in_special_effect_in => unsigned(R_bldeff),
      in_effect_1st_bg0    => R_bld1st(0),
      in_effect_1st_bg1    => R_bld1st(1),
      in_effect_1st_bg2    => R_bld1st(2),
      in_effect_1st_bg3    => R_bld1st(3),
      in_effect_1st_obj    => R_bld1st(4),
      in_effect_1st_BD     => R_bld1st(5),
      in_effect_2nd_bg0    => R_bld2nd(0),
      in_effect_2nd_bg1    => R_bld2nd(1),
      in_effect_2nd_bg2    => R_bld2nd(2),
      in_effect_2nd_bg3    => R_bld2nd(3),
      in_effect_2nd_obj    => R_bld2nd(4),
      in_effect_2nd_BD     => R_bld2nd(5),
      in_Prio_BG0          => unsigned(R_bgcnt(0).prio),
      in_Prio_BG1          => unsigned(R_bgcnt(1).prio),
      in_Prio_BG2          => unsigned(R_bgcnt(2).prio),
      in_Prio_BG3          => unsigned(R_bgcnt(3).prio),
      in_EVA               => unsigned(R_eva),
      in_EVB               => unsigned(R_evb),
      in_BLDY              => unsigned(R_bldy),
      in_ena_bg0           => R_ena_bg0(8),
      in_ena_bg1           => R_ena_bg1(9),
      in_ena_bg2           => R_ena_bg2(10),
      in_ena_bg3           => R_ena_bg3(11),
      in_ena_obj           => R_ena_obj(12),
      pixeldata_bg0        => mrg_bg0,
      pixeldata_bg1        => mrg_bg1,
      pixeldata_bg2        => mrg_bg2,
      pixeldata_bg3        => mrg_bg3,
      pixeldata_obj        => mrg_obj,
      pixeldata_back       => backdrop,
      objwindow_in         => mrg_objwnd,
      pixeldata_out        => merge_out666,
      pixel_x              => pixel_out_x,
      pixel_y              => pixel_out_y,
      pixel_we             => pixel_out_we
   );

   raw666 <= (others => '1') when R_forced_blank = "1" else merge_out666;

   dispmode_eff <= R_dispmode(17 downto 16) when is_engine_b = '0' else '0' & R_dispmode(16);

   p_mbright : process (all)
      variable f    : integer range 0 to 31;
      variable c    : integer range 0 to 63;
      variable r    : integer range 0 to 127;
      variable outv : std_logic_vector(17 downto 0);
   begin
      f := to_integer(unsigned(R_mbright_f));
      if (f > 16) then
         f := 16;
      end if;
      outv := raw666;
      if (R_mbright_m = "01") then
         for k in 0 to 2 loop
            c := to_integer(unsigned(raw666(k*6 + 5 downto k*6)));
            r := c + (((63 - c) * f) / 16);
            outv(k*6 + 5 downto k*6) := std_logic_vector(to_unsigned(r, 6));
         end loop;
      elsif (R_mbright_m = "10") then
         for k in 0 to 2 loop
            c := to_integer(unsigned(raw666(k*6 + 5 downto k*6)));
            r := c - ((c * f + 15) / 16);
            outv(k*6 + 5 downto k*6) := std_logic_vector(to_unsigned(r, 6));
         end loop;
      end if;
      if (dispmode_eff = "00") then
         outv := (others => '1');
      end if;
      pixel_out_data <= outv;
   end process;

end architecture;
