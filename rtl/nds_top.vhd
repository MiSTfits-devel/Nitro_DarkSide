-- NDS console top level — clk1x (33.514 MHz) + ce domain, GBA_MiSTfits pacing model.
-- Fast memory (SDRAM/DDR3) lives in nds_wrap behind ena/done handshakes.
--
-- M0 scaffold: ports sketched, only the VRAM map decoder is wired (self-consumed);
-- see docs/ARCHITECTURE.md "Top-level structure" for the instantiation plan and
-- docs/ROADMAP.md for the build order (M1 memory fabric -> M2 ARM7 island -> ...).

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.pnds_vram_map.all;

entity nds_top is
   generic
   (
      is_simu : std_logic := '0'
   );
   port
   (
      clk1x            : in  std_logic;   -- 33.513982 MHz system clock
      reset            : in  std_logic;
      nds_on           : in  std_logic;

      -- keys (active high) — X/Y/lid are NDS additions routed via ARM7 side
      KeyA             : in  std_logic;
      KeyB             : in  std_logic;
      KeySelect        : in  std_logic;
      KeyStart         : in  std_logic;
      KeyRight         : in  std_logic;
      KeyLeft          : in  std_logic;
      KeyUp             : in  std_logic;
      KeyDown          : in  std_logic;
      KeyR             : in  std_logic;
      KeyL             : in  std_logic;
      KeyX             : in  std_logic;
      KeyY             : in  std_logic;
      lid_closed       : in  std_logic;

      -- touchscreen (framework analog -> TSC-style samples in nds_spi)
      touch_active     : in  std_logic;
      touch_x          : in  std_logic_vector(7 downto 0);
      touch_y          : in  std_logic_vector(7 downto 0);

      -- main RAM guest channel (4 MB in SDRAM, via nds_wrap)
      mainram_ena      : out std_logic;
      mainram_rnw      : out std_logic;
      mainram_addr     : out std_logic_vector(21 downto 0);
      mainram_be       : out std_logic_vector(3 downto 0);
      mainram_dout     : out std_logic_vector(31 downto 0);
      mainram_din      : in  std_logic_vector(31 downto 0);
      mainram_done     : in  std_logic;

      -- card interface (ROMCTRL pages served from DDR3, via nds_wrap)
      card_ena         : out std_logic;
      card_addr        : out std_logic_vector(28 downto 0);
      card_din         : in  std_logic_vector(31 downto 0);
      card_done        : in  std_logic;

      -- video out: engine A and B composed lines (RGB555 like the GBA path)
      pixel_out_x      : out integer range 0 to 255;
      pixel_out_y      : out integer range 0 to 191;
      pixel_out_data   : out std_logic_vector(14 downto 0);
      pixel_out_we     : out std_logic;
      pixel_out_engB   : out std_logic;
      vblank_trigger   : out std_logic;

      -- sound
      sound_out_left   : out std_logic_vector(15 downto 0);
      sound_out_right  : out std_logic_vector(15 downto 0)
   );
end entity;

architecture arch of nds_top is

   signal ce            : std_logic := '0';  -- ARM7/bus pace; ARM9 gets 2x (M3)

   -- VRAMCNT_A..I register bytes (will move into the GX register bank in M1)
   signal vramcnt       : std_logic_vector(71 downto 0) := (others => '0');
   signal vmap_addr     : unsigned(23 downto 0)         := (others => '0');
   signal vmap_is_arm7  : std_logic                     := '0';
   signal vmap_hit      : std_logic_vector(8 downto 0);
   signal vmap_offs     : t_vram_offs;

begin

   -- =====================================================================
   -- M0: nothing runs yet. Instantiation plan (docs/ARCHITECTURE.md):
   --   nds_membus9 / nds_membus7  — per-CPU decoders (gba_memorymux pattern)
   --   gba_cpu                    — vendored ARM7TDMI (M2)
   --   nds_cpu9                   — ARM946E-S (M3)
   --   nds_vram / nds_wram        — bank stores + WRAMCNT (M1)
   --   nds_gpu2d x2, nds_dma x2, nds_timer x2, nds_irq x2 (M4/M5/M6)
   --   nds_ipc, nds_sound, nds_card, nds_spi, nds_math, nds_gx_stub
   -- =====================================================================

   invram_map : entity work.nds_vram_map
   port map
   (
      vramcnt => vramcnt,
      addr    => vmap_addr,
      is_arm7 => vmap_is_arm7,
      hit     => vmap_hit,
      offs    => vmap_offs
   );

   -- placeholder outputs so the entity elaborates standalone
   mainram_ena     <= '0';
   mainram_rnw     <= '1';
   mainram_addr    <= (others => '0');
   mainram_be      <= (others => '0');
   mainram_dout    <= (others => '0');
   card_ena        <= '0';
   card_addr       <= (others => '0');
   pixel_out_x     <= 0;
   pixel_out_y     <= 0;
   pixel_out_data  <= (others => '0');
   pixel_out_we    <= '0';
   pixel_out_engB  <= '0';
   vblank_trigger  <= '0';
   sound_out_left  <= (others => '0');
   sound_out_right <= (others => '0');

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         ce <= not ce;   -- placeholder pacing
      end if;
   end process;

end architecture;
