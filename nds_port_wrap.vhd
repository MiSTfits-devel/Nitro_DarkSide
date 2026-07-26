-- nds_port_wrap — mixed-language shim between NDS.sv (SystemVerilog) and
-- nds_top (VHDL). Quartus can't carry VHDL record ports (dbg_export9/7,
-- cpu_export_type) or ranged-integer ports (pixel_out_x/y) across the
-- language boundary, so this wrapper terminates the debug records (is_simu
-- only anyway), converts the pixel coordinates to plain vectors, and exposes
-- everything else 1:1 as std_logic/std_logic_vector.
--
-- No logic lives here. All generics keep their nds_top defaults
-- (is_simu='0', main RAM at SDRAM byte offset 8 MB, GPU_CE_DIV=3).

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nds_port_wrap is
   port
   (
      clk1x            : in  std_logic;   -- 33.513982 MHz system clock
      clk2x            : in  std_logic;   -- 67.027964 MHz (2x clk1x, same VCO): ARM9 island
      clkMem           : in  std_logic;   -- 100.541946 MHz (3x clk1x, phase-locked)
      clkMemIndex      : in  std_logic_vector(1 downto 0);  -- clkMem phase, 0 on clk1x rising edge
      reset            : in  std_logic;
      nds_on           : in  std_logic;
      direct_boot      : in  std_logic;

      -- keys (active high)
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

      -- touchscreen
      touch_active     : in  std_logic;
      touch_x          : in  std_logic_vector(7 downto 0);
      touch_y          : in  std_logic_vector(7 downto 0);

      -- boot status (HLE loader)
      boot_done        : out std_logic;
      boot_error       : out std_logic;

      -- card image read port (word addressed into the staged .nds)
      card_ena         : out std_logic;
      card_addr        : out std_logic_vector(24 downto 0);  -- word address (byte addr 26:2)
      card_din         : in  std_logic_vector(31 downto 0);
      card_done        : in  std_logic;

      -- SPI firmware flash image read port (128 KB, word addressed)
      fw_addr          : out std_logic_vector(15 downto 0);  -- word address (byte addr 17:2)
      fw_req           : out std_logic;
      fw_done          : in  std_logic;
      fw_data          : in  std_logic_vector(31 downto 0);

      -- hot-loadable ARM7/ARM9 BIOS RAM write ports
      bios7_load_addr  : in std_logic_vector(13 downto 2);
      bios7_load_data  : in std_logic_vector(31 downto 0);
      bios7_load_be    : in std_logic_vector(3 downto 0);
      bios7_load_we    : in std_logic;
      bios7_load_done  : in std_logic;
      bios9_load_addr  : in std_logic_vector(11 downto 2);
      bios9_load_data  : in std_logic_vector(31 downto 0);
      bios9_load_be    : in std_logic_vector(3 downto 0);
      bios9_load_we    : in std_logic;
      bios9_load_done  : in std_logic;

      -- main RAM SDRAM request port + scheduler handshake
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

      -- VRAM banks A..D backing store
      vsrv_req         : out std_logic;
      vsrv_rnw         : out std_logic;
      vsrv_bank        : out std_logic_vector(1 downto 0);
      vsrv_addr        : out std_logic_vector(14 downto 0);  -- word address (byte addr 16:2)
      vsrv_be          : out std_logic_vector(3 downto 0);
      vsrv_din         : out std_logic_vector(31 downto 0);
      vsrv_dout        : in  std_logic_vector(31 downto 0);
      vsrv_done        : in  std_logic;
      vrsrv_req        : out std_logic;
      vrsrv_bank       : out std_logic_vector(1 downto 0);
      vrsrv_addr       : out std_logic_vector(14 downto 0);
      vrsrv_dout       : in  std_logic_vector(31 downto 0);
      vrsrv_done       : in  std_logic;

      -- video out, per-screen pixel writes, BGR666 (B in [17:12])
      pixel_out_x      : out std_logic_vector(7 downto 0);
      pixel_out_y      : out std_logic_vector(7 downto 0);
      pixel_out_data   : out std_logic_vector(17 downto 0);
      pixel_out_we     : out std_logic;
      pixelb_out_x     : out std_logic_vector(7 downto 0);
      pixelb_out_y     : out std_logic_vector(7 downto 0);
      pixelb_out_data  : out std_logic_vector(17 downto 0);
      pixelb_out_we    : out std_logic;
      vblank_out       : out std_logic;

      -- sound
      sound_out_left   : out std_logic_vector(15 downto 0);
      sound_out_right  : out std_logic_vector(15 downto 0);

      -- Temporary live-hardware telemetry, flattened for SystemVerilog.
      dbg_pc9           : out std_logic_vector(31 downto 0);
      dbg_pc7           : out std_logic_vector(31 downto 0);
      dbg_r0_9          : out std_logic_vector(31 downto 0);
      dbg_lr9           : out std_logic_vector(31 downto 0);
      dbg_cpsr9         : out std_logic_vector(31 downto 0);
      dbg_vfy_bad       : out std_logic_vector(17 downto 0);
      dbg_vfy_addr      : out std_logic_vector(31 downto 0);

      -- IS-NITRO-style debug mailbox (ddram ch4 pager lives in NDS.sv)
      dbg_cmd_stb       : in  std_logic := '0';
      dbg_cmd_op        : in  std_logic_vector(7 downto 0) := (others => '0');
      dbg_cmd_arg       : in  std_logic_vector(31 downto 0) := (others => '0');
      dbg_rsp_data      : out std_logic_vector(31 downto 0);
      dbg_rsp_stb       : out std_logic;

      dbg_hwstat        : out std_logic_vector(17 downto 0)
   );
end entity;

architecture arch of nds_port_wrap is

   signal pix_x_i, pix_y_i   : integer range 0 to 255;
   signal pixb_x_i, pixb_y_i : integer range 0 to 255;
   signal fw_addr_u          : unsigned(17 downto 2);
   signal vsrv_addr_u        : unsigned(16 downto 2);
   signal vrsrv_addr_u       : unsigned(16 downto 2);

begin

   pixel_out_x  <= std_logic_vector(to_unsigned(pix_x_i, 8));
   pixel_out_y  <= std_logic_vector(to_unsigned(pix_y_i, 8));
   pixelb_out_x <= std_logic_vector(to_unsigned(pixb_x_i, 8));
   pixelb_out_y <= std_logic_vector(to_unsigned(pixb_y_i, 8));
   fw_addr      <= std_logic_vector(fw_addr_u);
   vsrv_addr    <= std_logic_vector(vsrv_addr_u);
   vrsrv_addr   <= std_logic_vector(vrsrv_addr_u);

   inds : entity work.nds_top
   port map
   (
      clk1x            => clk1x,
      clk2x            => clk2x,
      clkMem           => clkMem,
      clkMemIndex      => unsigned(clkMemIndex),
      reset            => reset,
      nds_on           => nds_on,
      direct_boot      => direct_boot,

      KeyA             => KeyA,
      KeyB             => KeyB,
      KeySelect        => KeySelect,
      KeyStart         => KeyStart,
      KeyRight         => KeyRight,
      KeyLeft          => KeyLeft,
      KeyUp            => KeyUp,
      KeyDown          => KeyDown,
      KeyR             => KeyR,
      KeyL             => KeyL,
      KeyX             => KeyX,
      KeyY             => KeyY,
      lid_closed       => lid_closed,

      touch_active     => touch_active,
      touch_x          => touch_x,
      touch_y          => touch_y,

      boot_done        => boot_done,
      boot_error       => boot_error,

      card_ena         => card_ena,
      card_addr        => card_addr,
      card_din         => card_din,
      card_done        => card_done,

      fw_addr          => fw_addr_u,
      fw_req           => fw_req,
      fw_done          => fw_done,
      fw_data          => fw_data,

      bios7_load_addr  => unsigned(bios7_load_addr),
      bios7_load_data  => bios7_load_data,
      bios7_load_be    => bios7_load_be,
      bios7_load_we    => bios7_load_we,
      bios7_load_done  => bios7_load_done,
      bios9_load_addr  => unsigned(bios9_load_addr),
      bios9_load_data  => bios9_load_data,
      bios9_load_be    => bios9_load_be,
      bios9_load_we    => bios9_load_we,
      bios9_load_done  => bios9_load_done,

      mainram_allow    => mainram_allow,
      mainram_active   => mainram_active,
      mainram_busy     => mainram_busy,
      sdram_ena        => sdram_ena,
      sdram_rnw        => sdram_rnw,
      sdram_Adr        => sdram_Adr,
      sdram_Din        => sdram_Din,
      sdram_be         => sdram_be,
      sdram_Dout       => sdram_Dout,
      sdram_done32     => sdram_done32,

      vsrv_req         => vsrv_req,
      vsrv_rnw         => vsrv_rnw,
      vsrv_bank        => vsrv_bank,
      vsrv_addr        => vsrv_addr_u,
      vsrv_be          => vsrv_be,
      vsrv_din         => vsrv_din,
      vsrv_dout        => vsrv_dout,
      vsrv_done        => vsrv_done,
      vrsrv_req        => vrsrv_req,
      vrsrv_bank       => vrsrv_bank,
      vrsrv_addr       => vrsrv_addr_u,
      vrsrv_dout       => vrsrv_dout,
      vrsrv_done       => vrsrv_done,

      pixel_out_x      => pix_x_i,
      pixel_out_y      => pix_y_i,
      pixel_out_data   => pixel_out_data,
      pixel_out_we     => pixel_out_we,
      pixelb_out_x     => pixb_x_i,
      pixelb_out_y     => pixb_y_i,
      pixelb_out_data  => pixelb_out_data,
      pixelb_out_we    => pixelb_out_we,
      vblank_out       => vblank_out,

      sound_out_left   => sound_out_left,
      sound_out_right  => sound_out_right,

      -- the record-typed exports only exist in simulation (pragma-stripped
      -- in nds_top, donor gba_cpu idiom); plain debug taps stay last so the
      -- stripped list keeps valid comma placement
-- synthesis translate_off
      dbg_export9_done => open,
      dbg_export9      => open,
      dbg_export7_done => open,
      dbg_export7      => open,
-- synthesis translate_on
      dbg_line_drop    => open,
      dbg_line_busy    => open,
      dbg_cpu_err9     => open,
      dbg_cpu_err7     => open,
      dbg_pc9          => dbg_pc9,
      dbg_pc7          => dbg_pc7,
      dbg_r0_9         => dbg_r0_9,
      dbg_lr9          => dbg_lr9,
      dbg_cpsr9        => dbg_cpsr9,
      dbg_vfy_bad      => dbg_vfy_bad,
      dbg_vfy_addr     => dbg_vfy_addr,
      dbg_cmd_stb      => dbg_cmd_stb,
      dbg_cmd_op       => dbg_cmd_op,
      dbg_cmd_arg      => dbg_cmd_arg,
      dbg_rsp_data     => dbg_rsp_data,
      dbg_rsp_stb      => dbg_rsp_stb,
      dbg_hwstat       => dbg_hwstat
   );

end architecture;
