-- SPDX-License-Identifier: GPL-2.0-or-later
-- NDS OBJ drawer (fork of gba_drawer_obj). One instance renders all 128
-- sprites of one line into the OBJ line buffer (color + settings planes).
-- Deltas vs the GBA donor:
--
--   * 256-pixel line, ypos 0..191, 256 KB OBJ char space (18-bit addresses)
--   * 1D tile mapping boundary: base = tileno * (32 << tile_boundary)
--     (DISPCNT 21:20); 2D unchanged (tileno*32, 1 KB row stride). NDS does
--     NOT force even tile numbers for 256-color 2D sprites (melonDS).
--   * OBJ extended palette (obj_extpal, DISPCNT.31): 256-color sprites
--     look up palno*256+color in the engine's 8 KB OBJ ext-pal slot;
--     without it the palette number is ignored (GBA behavior).
--   * bitmap sprites (OBJ mode "11"): direct-color pixels, opaque iff
--     bit15; attr2 palette field is the blend alpha - alpha=0 hides the
--     sprite. Addressing per GBATEK/melonDS:
--       1D (bitmap_1d='1'): base = tileno << (7 + bitmap_1d_boundary),
--          row stride = sprite width * 2   (bitmap_2d_wide='1' + 1D is
--          'reserved', draws nothing)
--       2D: wide: base = (tileno&1F)*16 + (tileno&3E0)*128, stride 512
--           narrow: base = (tileno&0F)*16 + (tileno&3F0)*128, stride 256
--     Affine bitmap sprites fetch base + yyy*stride + xxx*2.
--   * settings plane widened to 8 bits:
--     [1:0] priority, [2] semi-transparent (mode 01), [3] bitmap sprite,
--     [7:4] bitmap alpha (attr2 palette field)
--   * per-line budget kept but set to the full NDS line for now (melonDS
--     does not model the OBJ time limit; revisit for hardware accuracy)
--
-- OAM layout, affine pipeline, mosaic and the priority merge into the
-- double line buffer are unchanged from the donor.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nds_drawer_obj is
   port
   (
      clk                  : in  std_logic;

      drawline             : in  std_logic;
      ypos                 : in  integer range 0 to 191;
      ypos_mosaic          : in  integer range 0 to 191;

      one_dim_mapping      : in  std_logic;                    -- DISPCNT.4
      tile_boundary        : in  unsigned(1 downto 0);         -- DISPCNT.21:20
      bitmap_1d            : in  std_logic;                    -- DISPCNT.6
      bitmap_2d_wide       : in  std_logic;                    -- DISPCNT.5
      bitmap_1d_boundary   : in  std_logic;                    -- DISPCNT.22
      obj_extpal           : in  std_logic;                    -- DISPCNT.31
      Mosaic_H_Size        : in  unsigned(3 downto 0);

      hblankfree           : in  std_logic;

      pixel_we_color       : out std_logic := '0';
      pixeldata_color      : out std_logic_vector(15 downto 0) := (others => '0');
      pixel_we_settings    : out std_logic := '0';
      pixeldata_settings   : out std_logic_vector(7 downto 0) := (others => '0');
      pixel_x              : out integer range 0 to 255;
      pixel_objwnd         : out std_logic := '0';

      OAMRAM_Drawer_addr   : buffer integer range 0 to 255;
      OAMRAM_Drawer_data   : in  std_logic_vector(31 downto 0);

      PALETTE_Drawer_addr  : out integer range 0 to 127;
      PALETTE_Drawer_data  : in  std_logic_vector(31 downto 0);

      EXTPAL_Drawer_addr   : out integer range 0 to 2047;      -- 8 KB OBJ ext-pal slot
      EXTPAL_Drawer_data   : in  std_logic_vector(31 downto 0);

      VRAM_Drawer_addr     : out integer range 0 to 65535;     -- 256 KB OBJ space
      VRAM_Drawer_data     : in  std_logic_vector(31 downto 0);
      VRAM_Drawer_valid    : in  std_logic
   );
end entity;

architecture arch of nds_drawer_obj is

   -- Atr0
   constant OAM_Y_HI         : integer := 7;
   constant OAM_Y_LO         : integer := 0;
   constant OAM_AFFINE       : integer := 8;
   constant OAM_DBLSIZE      : integer := 9;
   constant OAM_OFF_HI       : integer := 9;
   constant OAM_OFF_LO       : integer := 8;
   constant OAM_MODE_HI      : integer := 11;
   constant OAM_MODE_LO      : integer := 10;
   constant OAM_MOSAIC       : integer := 12;
   constant OAM_HICOLOR      : integer := 13;
   constant OAM_OBJSHAPE_HI  : integer := 15;
   constant OAM_OBJSHAPE_LO  : integer := 14;

   -- Atr1
   constant OAM_X_HI         : integer := 8;
   constant OAM_X_LO         : integer := 0;
   constant OAM_AFF_HI       : integer := 13;
   constant OAM_AFF_LO       : integer := 9;
   constant OAM_HFLIP        : integer := 12;
   constant OAM_VFLIP        : integer := 13;
   constant OAM_OBJSIZE_HI   : integer := 15;
   constant OAM_OBJSIZE_LO   : integer := 14;

   -- Atr2
   constant OAM_TILE_HI      : integer := 9;
   constant OAM_TILE_LO      : integer := 0;
   constant OAM_PRIO_HI      : integer := 11;
   constant OAM_PRIO_LO      : integer := 10;
   constant OAM_PALETTE_HI   : integer := 15;
   constant OAM_PALETTE_LO   : integer := 12;

   type t_OAMFetch is
   (
      IDLE,
      READFIRST,
      WAITFIRST,
      READSECOND,
      WAITSECOND,
      READAFFINE0,
      WAITAFFINE0,
      READAFFINE1,
      WAITAFFINE1,
      READAFFINE2,
      WAITAFFINE2,
      READAFFINE3,
      WAITAFFINE3,
      DONE
   );
   signal OAMFetch : t_OAMFetch := IDLE;

   signal output_ok : std_logic := '0';
   signal overdraw  : std_logic := '0';

   signal OAM_currentobj : integer range 0 to 127;

   signal OAM_data0 : std_logic_vector(15 downto 0) := (others => '0');
   signal OAM_data1 : std_logic_vector(15 downto 0) := (others => '0');
   signal OAM_data2 : std_logic_vector(15 downto 0) := (others => '0');

   signal OAM_data_aff0 : std_logic_vector(15 downto 0) := (others => '0');
   signal OAM_data_aff1 : std_logic_vector(15 downto 0) := (others => '0');
   signal OAM_data_aff2 : std_logic_vector(15 downto 0) := (others => '0');
   signal OAM_data_aff3 : std_logic_vector(15 downto 0) := (others => '0');

   signal OAM_sizeX     : integer range 8 to 64;
   signal OAM_sizeY     : integer range 8 to 64;
   signal OAM_sizeX2    : integer range 8 to 128;
   signal OAM_sizeY2    : integer range 8 to 128;
   signal OAM_posy      : integer range -256 to 255;
   signal OAM_posyMos   : integer range -512 to 511;
   signal OAM_isbitmap  : std_logic;

   signal OAMfetch_sizeX         : integer range 8 to 64;
   signal OAMfetch_sizeY         : integer range 8 to 64;
   signal OAMfetch_fieldX        : integer range 8 to 128;
   signal OAMfetch_fieldY        : integer range 8 to 128;
   signal OAMfetch_ty            : integer range -256 to 255;
   signal OAMfetch_sizemult      : integer range 16 to 1024;   -- bytes per sprite tile-row / bitmap row
   signal OAMfetch_x_flip_offset : integer range 3 to 7;
   signal OAMfetch_y_flip_offset : integer range 28 to 56;
   signal OAMfetch_x_div         : integer range 1 to 2;
   signal OAMfetch_x_size        : integer range 4 to 8;
   signal OAMfetch_addrbase      : integer range 0 to 262143;

   type t_PIXELGen is
   (
      WAITOAM,
      NEXTADDR,
      PIXELISSUE
   );
   signal PIXELGen : t_PIXELGen := WAITOAM;

   signal Pixel_data0       : std_logic_vector(15 downto 0) := (others => '0');
   signal Pixel_data1       : std_logic_vector(15 downto 0) := (others => '0');
   signal Pixel_data2       : std_logic_vector(15 downto 0) := (others => '0');
   signal dx                : integer range -32768 to 32767;
   signal dy                : integer range -32768 to 32767;

   signal posx              : integer range -512 to 511;
   signal sizeX             : integer range 8 to 64;
   signal sizeY             : integer range 8 to 64;
   signal fieldX            : integer range 8 to 128;
   signal pixeladdr_base    : integer range 0 to 262143;
   signal pixeladdr         : integer range -262144 to 262143;
   signal is_bitmap         : std_logic := '0';

   signal sizemult          : integer range 16 to 1024;

   signal x_flip_offset     : integer range 3 to 7;
   signal x_div             : integer range 1 to 2;
   signal x_size            : integer range 4 to 8;

   signal x                 : integer range 0 to 255;
   signal realX             : integer range -8388608 to 8388607;
   signal realY             : integer range -8388608 to 8388607;
   signal target            : integer range 0 to 255;
   signal second_pix        : std_logic := '0';
   signal vram_reuse        : std_logic := '0';
   signal firstpix          : std_logic;
   signal skippixel         : std_logic;
   signal issue_pixel       : std_logic;
   signal pixeladdr_x       : unsigned(17 downto 0) := (others => '0');

   signal pixeladdr_x_aff0  : unsigned(17 downto 0);
   signal pixeladdr_x_aff1  : unsigned(17 downto 0);
   signal pixeladdr_x_aff2  : unsigned(17 downto 0);
   signal pixeladdr_x_aff3  : unsigned(17 downto 0);
   signal pixeladdr_x_aff4  : unsigned(17 downto 0);
   signal pixeladdr_x_aff5  : unsigned(17 downto 0);

   -- Pixel Pipeline
   signal consumeSettings  : std_logic := '0';
   signal PALETTE_byteaddr : std_logic_vector(8 downto 0);
   signal EXTPAL_byteaddr  : std_logic_vector(12 downto 0);

   type tpixel is record
      transparent : std_logic;
      prio        : std_logic_vector(1 downto 0);
      alpha       : std_logic;
      objwnd      : std_logic;
   end record;

   type t_pixelarray is array(0 to 255) of tpixel;
   signal pixelarray : t_pixelarray;

   signal Pixel_wait        : tpixel;
   signal Pixel_readback    : tpixel;
   signal Pixel_merge       : tpixel;

   signal target_eval       : integer range 0 to 255;
   signal target_wait       : integer range 0 to 255;
   signal target_merge      : integer range 0 to 255;

   signal enable_eval       : std_logic;
   signal enable_wait       : std_logic;
   signal enable_merge      : std_logic;

   signal second_pix_eval   : std_logic;

   signal vram_reuse_eval   : std_logic;
   signal VRAM_data_next    : std_logic_vector(31 downto 0) := (others => '0');

   signal readaddr_mux_eval : unsigned(1 downto 0);

   signal prio_issue        : std_logic_vector(1 downto 0);
   signal mode_issue        : std_logic_vector(1 downto 0);
   signal hicolor_issue     : std_logic;
   signal affine_issue      : std_logic;
   signal hflip_issue       : std_logic;
   signal palette_issue     : std_logic_vector(3 downto 0);
   signal mosaic_issue      : std_logic;
   signal bitmap_issue      : std_logic;

   signal prio_eval         : std_logic_vector(1 downto 0);
   signal mode_eval         : std_logic_vector(1 downto 0);
   signal hicolor_eval      : std_logic;
   signal affine_eval       : std_logic;
   signal hflip_eval        : std_logic;
   signal palette_eval      : std_logic_vector(3 downto 0);
   signal mosaic_eval       : std_logic;
   signal bitmap_eval       : std_logic;
   signal mosaic_wait       : std_logic;

   signal bitmap_wait       : std_logic;
   signal bitmap_merge      : std_logic;
   signal bmpalpha_wait     : std_logic_vector(3 downto 0);
   signal bmpalpha_merge    : std_logic_vector(3 downto 0);
   signal bmpcolor_wait     : std_logic_vector(15 downto 0);
   signal bmpcolor_merge    : std_logic_vector(15 downto 0);
   signal extpal_wait       : std_logic;
   signal extpal_merge      : std_logic;

   signal mosaik_cnt        : integer range 0 to 15 := 0;
   signal mosaik_merge      : std_logic;

   signal PALETTE_addrlow   : std_logic;
   signal EXTPAL_addrlow    : std_logic;

   signal pixeltime         : integer range 0 to 2130;
   signal maxpixeltime      : integer range 0 to 2130;

begin

   VRAM_Drawer_addr    <= to_integer(pixeladdr_x(17 downto 2));
   PALETTE_Drawer_addr <= to_integer(unsigned(PALETTE_byteaddr(8 downto 2)));
   EXTPAL_Drawer_addr  <= to_integer(unsigned(EXTPAL_byteaddr(12 downto 2)));

   OAMRAM_Drawer_addr <= (OAM_currentobj * 2) + 1                                                when (OAMFetch = READSECOND) else
                         (to_integer(unsigned(OAM_data1(OAM_AFF_HI downto OAM_AFF_LO))) * 8) + 1 when (OAMFetch = READAFFINE0) else
                         (to_integer(unsigned(OAM_data1(OAM_AFF_HI downto OAM_AFF_LO))) * 8) + 3 when (OAMFetch = READAFFINE1) else
                         (to_integer(unsigned(OAM_data1(OAM_AFF_HI downto OAM_AFF_LO))) * 8) + 5 when (OAMFetch = READAFFINE2) else
                         (to_integer(unsigned(OAM_data1(OAM_AFF_HI downto OAM_AFF_LO))) * 8) + 7 when (OAMFetch = READAFFINE3) else
                         OAM_currentobj * 2; -- READFIRST or IDLE

   OAM_sizeX <=  8 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "00") else -- square size 0
                16 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "01") else -- square size 1
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "10") else -- square size 2
                64 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "11") else -- square size 3
                16 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "00") else -- Hor size 0
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "01") else -- Hor size 1
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "10") else -- Hor size 2
                64 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "11") else -- Hor size 3
                 8 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "00") else -- Vert size 0
                 8 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "01") else -- Vert size 1
                16 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "10") else -- Vert size 2
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "11") else -- Vert size 3
                 8;

   OAM_sizeY <=  8 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "00") else -- square size 0
                16 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "01") else -- square size 1
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "10") else -- square size 2
                64 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "11") else -- square size 3
                 8 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "00") else -- Hor size 0
                 8 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "01") else -- Hor size 1
                16 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "10") else -- Hor size 2
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "11") else -- Hor size 3
                16 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "00") else -- Vert size 0
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "01") else -- Vert size 1
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "10") else -- Vert size 2
                64 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "11") else -- Vert size 3
                 8;

   OAM_sizeX2 <= 2 * OAM_sizeX when (OAMRAM_Drawer_data(OAM_AFFINE) = '1' and OAMRAM_Drawer_data(OAM_DBLSIZE) = '1') else OAM_sizeX;
   OAM_sizeY2 <= 2 * OAM_sizeY when (OAMRAM_Drawer_data(OAM_AFFINE) = '1' and OAMRAM_Drawer_data(OAM_DBLSIZE) = '1') else OAM_sizeY;

   OAM_posy <= to_integer(unsigned(OAMRAM_Drawer_data(OAM_Y_HI downto OAM_Y_LO))) - 16#100# when (to_integer(unsigned(OAMRAM_Drawer_data(OAM_Y_HI downto OAM_Y_LO))) > (16#100# - OAM_sizeY2)) else
               to_integer(unsigned(OAMRAM_Drawer_data(OAM_Y_HI downto OAM_Y_LO)));

   OAM_posyMos <= ypos_mosaic - OAM_posy when (OAMRAM_Drawer_data(OAM_MOSAIC) = '1') else ypos - OAM_posy;

   OAM_isbitmap <= '1' when (OAMRAM_Drawer_data(OAM_MODE_HI downto OAM_MODE_LO) = "11") else '0';

   -- OAM Fetch
   process (clk)
   begin
      if rising_edge(clk) then

         if (hblankfree = '1') then
            maxpixeltime <= 1664;
         else
            maxpixeltime <= 2130;
         end if;

         case (OAMFetch) is

            when IDLE =>
               OAM_currentobj     <= 0;
               if (drawline = '1') then
                  OAMFetch           <= WAITFIRST;
                  output_ok          <= '1';
                  overdraw           <= '0';
               end if;

            when READFIRST =>
               OAMFetch           <= WAITFIRST;

            when WAITFIRST =>
               OAM_data0 <= OAMRAM_Drawer_data(15 downto 0);
               OAM_data1 <= OAMRAM_Drawer_data(31 downto 16);
               OAMFetch  <= READSECOND;

               OAMfetch_sizeX    <= OAM_sizeX;
               OAMfetch_sizeY    <= OAM_sizeY;
               OAMfetch_fieldX   <= OAM_sizeX2;
               OAMfetch_fieldY   <= OAM_sizeY2;

               if (OAM_isbitmap = '1') then
                  if (bitmap_1d = '1') then
                     OAMfetch_sizemult <= OAM_sizeX * 2;          -- bytes per bitmap row
                  elsif (bitmap_2d_wide = '1') then
                     OAMfetch_sizemult <= 512;
                  else
                     OAMfetch_sizemult <= 256;
                  end if;
               elsif (OAMRAM_Drawer_data(OAM_HICOLOR) = '0') then
                  OAMfetch_sizemult <= OAM_sizeX * 4;
               else
                  OAMfetch_sizemult <= OAM_sizeX * 8;
               end if;

               if (OAMRAM_Drawer_data(OAM_HICOLOR) = '0') then
                  OAMfetch_x_flip_offset <= 3;
                  OAMfetch_y_flip_offset <= 28;
                  OAMfetch_x_div         <= 2;
                  OAMfetch_x_size        <= 4;
               else
                  OAMfetch_x_flip_offset <= 7;
                  OAMfetch_y_flip_offset <= 56;
                  OAMfetch_x_div         <= 1;
                  OAMfetch_x_size        <= 8;
               end if;

               -- skip: off-line, disabled, prohibited shape, bitmap sprites
               -- with alpha=0 or the reserved 1D+wide combination
               if (OAM_posyMos < 0 or OAM_posyMos >= OAM_sizeY2
                   or OAMRAM_Drawer_data(OAM_OFF_HI downto OAM_OFF_LO) = "10"
                   or OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "11"
                   or (OAM_isbitmap = '1' and bitmap_1d = '1' and bitmap_2d_wide = '1')) then
                  if (OAM_currentobj = 127) then
                     OAMFetch      <= IDLE;
                  else
                     OAMFetch       <= READFIRST;
                     OAM_currentobj <= OAM_currentobj + 1;
                  end if;
               else
                  OAMFetch    <= READSECOND;
                  OAMfetch_ty <= OAM_posyMos;
               end if;

            when READSECOND =>
               OAMFetch <= WAITSECOND;

            when WAITSECOND =>
               OAM_data2 <= OAMRAM_Drawer_data(15 downto 0);
               if (OAM_data0(OAM_MODE_HI downto OAM_MODE_LO) = "11"
                   and OAMRAM_Drawer_data(OAM_PALETTE_HI downto OAM_PALETTE_LO) = "0000") then
                  -- bitmap sprite with alpha=0: invisible
                  if (OAM_currentobj = 127) then
                     OAMFetch      <= IDLE;
                  else
                     OAMFetch       <= READFIRST;
                     OAM_currentobj <= OAM_currentobj + 1;
                  end if;
               elsif (OAM_data0(OAM_AFFINE) = '1') then
                  OAMFetch           <= READAFFINE0;
               else
                  OAMFetch           <= DONE;
               end if;

               -- char/bitmap base address (byte, in the 256 KB OBJ space)
               if (OAM_data0(OAM_MODE_HI downto OAM_MODE_LO) = "11") then
                  if (bitmap_1d = '1') then
                     if (bitmap_1d_boundary = '1') then
                        OAMfetch_addrbase <= 256 * to_integer(unsigned(OAMRAM_Drawer_data(OAM_TILE_HI downto OAM_TILE_LO)));
                     else
                        OAMfetch_addrbase <= 128 * to_integer(unsigned(OAMRAM_Drawer_data(OAM_TILE_HI downto OAM_TILE_LO)));
                     end if;
                  elsif (bitmap_2d_wide = '1') then
                     OAMfetch_addrbase <= 16 * to_integer(unsigned(OAMRAM_Drawer_data(OAM_TILE_LO + 4 downto OAM_TILE_LO)))
                                        + 128 * (to_integer(unsigned(OAMRAM_Drawer_data(OAM_TILE_HI downto OAM_TILE_LO + 5))) * 32);
                  else
                     OAMfetch_addrbase <= 16 * to_integer(unsigned(OAMRAM_Drawer_data(OAM_TILE_LO + 3 downto OAM_TILE_LO)))
                                        + 128 * (to_integer(unsigned(OAMRAM_Drawer_data(OAM_TILE_HI downto OAM_TILE_LO + 4))) * 16);
                  end if;
               elsif (one_dim_mapping = '1') then
                  OAMfetch_addrbase <= (32 * (2 ** to_integer(tile_boundary))) * to_integer(unsigned(OAMRAM_Drawer_data(OAM_TILE_HI downto OAM_TILE_LO)));
               else
                  OAMfetch_addrbase <= 32 * to_integer(unsigned(OAMRAM_Drawer_data(OAM_TILE_HI downto OAM_TILE_LO)));
               end if;

            when READAFFINE0 => OAMFetch <= WAITAFFINE0;
            when WAITAFFINE0 => OAMFetch <= READAFFINE1; OAM_data_aff0 <= OAMRAM_Drawer_data(31 downto 16);
            when READAFFINE1 => OAMFetch <= WAITAFFINE1;
            when WAITAFFINE1 => OAMFetch <= READAFFINE2; OAM_data_aff1 <= OAMRAM_Drawer_data(31 downto 16);
            when READAFFINE2 => OAMFetch <= WAITAFFINE2;
            when WAITAFFINE2 => OAMFetch <= READAFFINE3; OAM_data_aff2 <= OAMRAM_Drawer_data(31 downto 16);
            when READAFFINE3 => OAMFetch <= WAITAFFINE3;
            when WAITAFFINE3 => OAMFetch <= DONE;        OAM_data_aff3 <= OAMRAM_Drawer_data(31 downto 16);

            when DONE =>
               if (PIXELGen = WAITOAM or consumeSettings = '1') then
                  if (OAM_currentobj = 127) then
                     OAMFetch      <= IDLE;
                  else
                     OAMFetch           <= READFIRST;
                     OAM_currentobj     <= OAM_currentobj + 1;
                  end if;
               end if;

         end case;

         if (pixeltime >= maxpixeltime and OAMFetch /= IDLE) then
            OAMFetch <= IDLE;
            overdraw <= '1';
         end if;

      end if;
   end process;

   -- Pixelgen
   process (clk)
      variable applyNextSettings : std_logic := '0';
      variable pixeladdr_pre_a0  : integer range -8388608 to 8388607; -- 24 bit
      variable pixeladdr_pre_a1  : integer range -8388608 to 8388607;
      variable pixeladdr_pre_a2  : integer range -8388608 to 8388607;
      variable pixeladdr_pre_a3  : integer range -8388608 to 8388607;
      variable pixeladdr_pre_a4  : integer range -8388608 to 8388607;
      variable pixeladdr_pre_a5  : integer range -8388608 to 8388607;
      variable pixeladdr_pre_a6  : integer range -8388608 to 8388607;
      variable pixeladdr_pre_a7  : integer range -8388608 to 8388607;
      variable pixeladdr_pre_0   : integer range -262144 to 262143;
      variable pixeladdr_pre_1   : integer range -262144 to 262143;
      variable pixeladdr_pre_2   : integer range -262144 to 262143;
      variable pixeladdr_pre_3   : integer range -262144 to 262143;
      variable pixeladdr_pre_4   : integer range -262144 to 262143;
      variable pixeladdr_pre_5   : integer range -262144 to 262143;
      variable pixeladdr_pre_6   : integer range -262144 to 262143;
      variable pixeladdr_pre_7   : integer range -262144 to 262143;
      variable xxx               : integer range 0 to 63;
      variable yyy               : integer range 0 to 63;
      variable pixeladdr_calc    : integer;
   begin
      if rising_edge(clk) then

         consumeSettings   <= '0';
         issue_pixel       <= '0';
         applyNextSettings := '0';

         if (drawline = '1') then
            pixeltime <= 0;
         elsif (pixeltime < maxpixeltime) then
            pixeltime <= pixeltime + 1;
         end if;

         case (PIXELGen) is

            when WAITOAM =>
               if (OAMFetch = DONE) then
                  PIXELGen          <= NEXTADDR;
                  applyNextSettings := '1';
               end if;

            when NEXTADDR =>
               firstpix  <= '0';
               skippixel <= '0';
               if ((x + posX) < 256 and (x + posX) >= 0) then
                  target    <= x + posX;
               else
                  skippixel <= '1';
               end if;

               pixeladdr_calc := pixeladdr;

               vram_reuse <= '0';

               if (Pixel_data0(OAM_AFFINE) = '1') then
                  if (realX < 0 or (realX / 256) >= sizeX or realY < 0 or (realY / 256) >= sizeY) then
                     skippixel <= '1';
                  end if;

                  -- synthesis translate_off
                  if (realX >= 0 and (realX / 256) < sizeX and realY >= 0 and (realY / 256) < sizeY) then
                  -- synthesis translate_on

                     xxx := realX / 256;
                     yyy := realY / 256;
                     if (xxx mod 2 = 1) then second_pix <= '1'; else second_pix <= '0'; end if;

                     if (is_bitmap = '1') then
                        -- bitmap: base + yyy*rowstride + xxx*2
                        pixeladdr_x_aff0 <= to_unsigned(yyy * sizemult, 18);
                        pixeladdr_x_aff1 <= (others => '0');
                        pixeladdr_x_aff2 <= to_unsigned(yyy * sizemult, 18);
                        pixeladdr_x_aff3 <= (others => '0');
                        pixeladdr_x_aff4 <= to_unsigned(xxx * 2, 18);
                        pixeladdr_x_aff5 <= (others => '0');
                     else
                        pixeladdr_x_aff0 <= to_unsigned(((yyy mod 8) * x_size), 18);
                        pixeladdr_x_aff1 <= to_unsigned(((yyy / 8) * sizemult), 18);

                        pixeladdr_x_aff2 <= to_unsigned(((yyy mod 8) * x_size), 18);
                        pixeladdr_x_aff3 <= to_unsigned(((yyy / 8) * 1024), 18);

                        pixeladdr_x_aff4 <= to_unsigned(((xxx mod 8) / x_div), 18);
                        if (Pixel_data0(OAM_HICOLOR) = '0') then
                           pixeladdr_x_aff5 <= to_unsigned(((xxx / 8) * 32), 18);
                        else
                           pixeladdr_x_aff5 <= to_unsigned(((xxx / 8) * 64), 18);
                        end if;
                     end if;

                  -- synthesis translate_off
                  end if;
                  -- synthesis translate_on
               else

                  if (x mod 2 = 1) then second_pix <= '1'; else second_pix <= '0'; end if;

                  if (is_bitmap = '1') then
                     -- bitmap row base is in pixeladdr; hflip mirrors x
                     if (Pixel_data1(OAM_HFLIP) = '1') then
                        pixeladdr_calc := pixeladdr_calc + (sizeX - 1 - x) * 2;
                     else
                        pixeladdr_calc := pixeladdr_calc + x * 2;
                     end if;
                  elsif (Pixel_data1(OAM_HFLIP) = '1') then
                     pixeladdr_calc := pixeladdr_calc + (x_flip_offset - ((x mod 8) / x_div));
                     if (Pixel_data0(OAM_HICOLOR) = '0') then
                        pixeladdr_calc := pixeladdr_calc - (((x / 8) - ((sizeX / 8) - 1)) * 32);
                     else
                        pixeladdr_calc := pixeladdr_calc - (((x / 8) - ((sizeX / 8) - 1)) * 64);
                     end if;
                  else
                     pixeladdr_calc := pixeladdr_calc + ((x mod 8) / x_div);
                     if (Pixel_data0(OAM_HICOLOR) = '0') then
                        pixeladdr_calc := pixeladdr_calc + ((x / 8) * 32);
                     else
                        pixeladdr_calc := pixeladdr_calc + ((x / 8) * 64);
                     end if;
                  end if;

                  pixeladdr_x <= to_unsigned(pixeladdr_calc mod 262144, 18);

               end if;

               realX <= realX + dx;
               realY <= realY + dy;

               if (pixeltime >= maxpixeltime) then
                  PIXELGen <= WAITOAM;
               elsif (x >= fieldX) then
                  PIXELGen <= WAITOAM;
               else
                  x <= x + 1;
                  PIXELGen <= PIXELISSUE;
                  if (Pixel_data0(OAM_AFFINE) = '0') then
                     if ((pixeladdr_calc / 2 = pixeladdr_x(pixeladdr_x'left downto 1) and firstpix = '0') or VRAM_Drawer_valid = '1') then
                        if (pixeladdr_calc / 2 = pixeladdr_x(pixeladdr_x'left downto 1) and firstpix = '0') then
                           vram_reuse  <= '1';
                        end if;
                        if ((x + posX) < 256 and (x + posX) >= 0) then
                           issue_pixel <= '1';
                        end if;
                        PIXELGen    <= NEXTADDR;
                        if (x + 1 >= fieldX and OAMFetch = DONE) then
                           applyNextSettings := '1';
                        end if;
                     end if;
                  end if;
               end if;

            when PIXELISSUE =>
               if (VRAM_Drawer_valid = '1') then -- sync on vram mux
                  PIXELGen    <= NEXTADDR;

                  issue_pixel <= not skippixel;
                  if (skippixel = '0') then

                     if (Pixel_data0(OAM_AFFINE) = '1') then
                        if (is_bitmap = '1') then
                           pixeladdr_x <= to_unsigned((pixeladdr_base
                                          + to_integer(pixeladdr_x_aff0)
                                          + to_integer(pixeladdr_x_aff4)) mod 262144, 18);
                        elsif (one_dim_mapping = '1') then
                           pixeladdr_x <= to_unsigned((pixeladdr_base
                                          + to_integer(pixeladdr_x_aff0) + to_integer(pixeladdr_x_aff1)
                                          + to_integer(pixeladdr_x_aff4) + to_integer(pixeladdr_x_aff5)) mod 262144, 18);
                        else
                           pixeladdr_x <= to_unsigned((pixeladdr_base
                                          + to_integer(pixeladdr_x_aff2) + to_integer(pixeladdr_x_aff3)
                                          + to_integer(pixeladdr_x_aff4) + to_integer(pixeladdr_x_aff5)) mod 262144, 18);
                        end if;
                     end if;

                  end if;

               end if;

         end case;

         if (applyNextSettings = '1') then
            consumeSettings <= '1';

            x          <= 0;
            firstpix   <= '1';

            Pixel_data0     <= OAM_data0;
            Pixel_data1     <= OAM_data1;
            Pixel_data2     <= OAM_data2;
            dx              <= to_integer(signed(OAM_data_aff0));
            dy              <= to_integer(signed(OAM_data_aff2));

            is_bitmap       <= '1' when OAM_data0(OAM_MODE_HI downto OAM_MODE_LO) = "11" else '0';

            if (unsigned(OAM_data1(OAM_X_HI downto OAM_X_LO)) > 16#100#) then
               posx <= to_integer(unsigned(OAM_data1(OAM_X_HI downto OAM_X_LO))) - 16#200#;
            else
               posx <= to_integer(unsigned(OAM_data1(OAM_X_HI downto OAM_X_LO)));
            end if;

            sizeX  <= OAMfetch_sizeX;
            sizeY  <= OAMfetch_sizeY;
            fieldX <= OAMfetch_fieldX;

            sizemult      <= OAMfetch_sizemult;
            x_flip_offset <= OAMfetch_x_flip_offset;
            x_div         <= OAMfetch_x_div;
            x_size        <= OAMfetch_x_size;

            pixeladdr_base <= OAMfetch_addrbase;

            -- affine
            pixeladdr_pre_a0 := OAMfetch_sizeX * 128;
            pixeladdr_pre_a1 := (OAMfetch_fieldX / 2) * to_integer(signed(OAM_data_aff0));
            pixeladdr_pre_a2 := (OAMfetch_fieldY / 2) * to_integer(signed(OAM_data_aff1));
            pixeladdr_pre_a3 := OAMfetch_ty * to_integer(signed(OAM_data_aff1));
            pixeladdr_pre_a4 := OAMfetch_sizeY * 128;
            pixeladdr_pre_a5 := (OAMfetch_fieldX / 2) * to_integer(signed(OAM_data_aff2));
            pixeladdr_pre_a6 := (OAMfetch_fieldY / 2) * to_integer(signed(OAM_data_aff3));
            pixeladdr_pre_a7 := OAMfetch_ty * to_integer(signed(OAM_data_aff3));

            -- non affine, tile sprites
            pixeladdr_pre_0 := (OAMfetch_y_flip_offset - (OAMfetch_ty mod 8) * OAMfetch_x_size);
            pixeladdr_pre_1 := ((((OAMfetch_sizeY / 8) - 1) - (OAMfetch_ty / 8)) * OAMfetch_sizemult);
            pixeladdr_pre_2 := (OAMfetch_y_flip_offset - (OAMfetch_ty mod 8) * OAMfetch_x_size);
            pixeladdr_pre_3 := ((((OAMfetch_sizeY / 8) - 1) - (OAMfetch_ty / 8)) * 1024);
            pixeladdr_pre_4 := ((OAMfetch_ty mod 8) * OAMfetch_x_size);
            pixeladdr_pre_5 := ((OAMfetch_ty / 8) * OAMfetch_sizemult);
            pixeladdr_pre_6 := ((OAMfetch_ty mod 8) * OAMfetch_x_size);
            pixeladdr_pre_7 := ((OAMfetch_ty / 8) * 1024);

            -- affine
            realX <= (pixeladdr_pre_a0 - pixeladdr_pre_a1 - pixeladdr_pre_a2 + pixeladdr_pre_a3);
            realY <= (pixeladdr_pre_a4 - pixeladdr_pre_a5 - pixeladdr_pre_a6 + pixeladdr_pre_a7);

            -- non affine
            if (OAM_data0(OAM_MODE_HI downto OAM_MODE_LO) = "11") then
               -- bitmap row base (vflip mirrors the row)
               if (OAM_data1(OAM_VFLIP) = '1') then
                  pixeladdr <= OAMfetch_addrbase + (OAMfetch_sizeY - 1 - OAMfetch_ty) * OAMfetch_sizemult;
               else
                  pixeladdr <= OAMfetch_addrbase + OAMfetch_ty * OAMfetch_sizemult;
               end if;
            elsif (OAM_data1(OAM_VFLIP) = '1') then
               if (one_dim_mapping = '1') then
                  pixeladdr <= OAMfetch_addrbase + pixeladdr_pre_0 + pixeladdr_pre_1;
               else
                  pixeladdr <= OAMfetch_addrbase + pixeladdr_pre_2 + pixeladdr_pre_3;
               end if;
            else
               if (one_dim_mapping = '1') then
                  pixeladdr <= OAMfetch_addrbase + pixeladdr_pre_4 + pixeladdr_pre_5;
               else
                  pixeladdr <= OAMfetch_addrbase + pixeladdr_pre_6 + pixeladdr_pre_7;
               end if;
            end if;
         end if;

      end if;
   end process;

   -- Pixel Pipeline
   process (clk)
      variable colorbyte             : std_logic_vector(7 downto 0);
      variable colorword             : std_logic_vector(15 downto 0);
      variable colordata             : std_logic_vector(3 downto 0);
      variable VRAM_Drawer_dataMuxed : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk) then

         if (drawline = '1') then
            pixelarray <= (others => ('1', "11", '0', '0'));
         end if;

         -- must save those here, as pixeldata will be overwritten in next cycle
         prio_issue        <= Pixel_data2(OAM_PRIO_HI downto OAM_PRIO_LO);
         mode_issue        <= Pixel_data0(OAM_MODE_HI downto OAM_MODE_LO);
         hicolor_issue     <= Pixel_data0(OAM_HICOLOR);
         affine_issue      <= Pixel_data0(OAM_AFFINE);
         hflip_issue       <= Pixel_data1(OAM_HFLIP);
         palette_issue     <= Pixel_data2(OAM_PALETTE_HI downto OAM_PALETTE_LO);
         mosaic_issue      <= Pixel_data0(OAM_MOSAIC);
         bitmap_issue      <= is_bitmap;

         -- first cycle - wait for vram to deliver data
         enable_eval       <= issue_pixel;
         readaddr_mux_eval <= pixeladdr_x(1 downto 0);
         target_eval       <= target;
         second_pix_eval   <= second_pix;
         vram_reuse_eval   <= vram_reuse;

         prio_eval       <= prio_issue;
         mode_eval       <= mode_issue;
         hicolor_eval    <= hicolor_issue;
         affine_eval     <= affine_issue;
         hflip_eval      <= hflip_issue;
         palette_eval    <= palette_issue;
         mosaic_eval     <= mosaic_issue;
         bitmap_eval     <= bitmap_issue;

         -- second cycle - eval vram
         target_wait   <= target_eval;
         enable_wait   <= enable_eval;
         mosaic_wait   <= mosaic_eval;
         bitmap_wait   <= bitmap_eval;
         bmpalpha_wait <= palette_eval;
         extpal_wait   <= hicolor_eval and obj_extpal;

         Pixel_wait.prio        <= prio_eval;
         if (mode_eval = "01") then Pixel_wait.alpha  <= '1'; else Pixel_wait.alpha  <= '0'; end if;
         if (mode_eval = "10") then Pixel_wait.objwnd <= '1'; else Pixel_wait.objwnd <= '0'; end if;

         if (VRAM_Drawer_valid = '1') then
            VRAM_data_next <= VRAM_Drawer_data;
         end if;

         VRAM_Drawer_dataMuxed := VRAM_Drawer_data;
         if (vram_reuse_eval = '1') then
            VRAM_Drawer_dataMuxed := VRAM_data_next;
         end if;

         case (readaddr_mux_eval(1 downto 0)) is
            when "00" => colorbyte := VRAM_Drawer_dataMuxed(7  downto 0);
            when "01" => colorbyte := VRAM_Drawer_dataMuxed(15 downto 8);
            when "10" => colorbyte := VRAM_Drawer_dataMuxed(23 downto 16);
            when "11" => colorbyte := VRAM_Drawer_dataMuxed(31 downto 24);
            when others => null;
         end case;

         if (readaddr_mux_eval(1) = '1') then
            colorword := VRAM_Drawer_dataMuxed(31 downto 16);
         else
            colorword := VRAM_Drawer_dataMuxed(15 downto 0);
         end if;

         if (enable_eval = '1') then
            if (bitmap_eval = '1') then
               bmpcolor_wait <= colorword;
               Pixel_wait.transparent <= not colorword(15);
            elsif (hicolor_eval = '0') then
               if (affine_eval = '1') then
                  if (second_pix_eval = '1') then
                     colordata := colorbyte(7 downto 4);
                  else
                     colordata := colorbyte(3 downto 0);
                  end if;
               else
                  if ((hflip_eval = '1' and second_pix_eval = '0') or (hflip_eval = '0' and second_pix_eval = '1')) then
                     colordata := colorbyte(7 downto 4);
                  else
                     colordata := colorbyte(3 downto 0);
                  end if;
               end if;

               if (colordata = x"0") then Pixel_wait.transparent <= '1'; else Pixel_wait.transparent <= '0'; end if;

               PALETTE_byteaddr <= palette_eval & colordata & '0';

            else

               if (colorbyte = x"00") then Pixel_wait.transparent <= '1'; else Pixel_wait.transparent <= '0'; end if;

               PALETTE_byteaddr <= colorbyte & '0';
               EXTPAL_byteaddr  <= palette_eval & colorbyte & '0';

            end if;
         end if;

         -- third cycle - wait palette + mosaic
         enable_merge    <= enable_wait;
         target_merge    <= target_wait;
         Pixel_readback  <= pixelarray(target_wait);
         PALETTE_addrlow <= PALETTE_byteaddr(1);
         EXTPAL_addrlow  <= EXTPAL_byteaddr(1);
         bitmap_merge    <= bitmap_wait;
         bmpalpha_merge  <= bmpalpha_wait;
         bmpcolor_merge  <= bmpcolor_wait;
         extpal_merge    <= extpal_wait;

         if (drawline = '1' or mosaic_wait = '0') then
            mosaik_cnt <= 15;
         end if;

         mosaik_merge <= '0';
         if (enable_wait = '1') then
            if (mosaik_cnt < Mosaic_H_Size and mosaic_wait = '1') then
               mosaik_cnt   <= mosaik_cnt + 1;
               mosaik_merge <= '1';
            else
               mosaik_cnt  <= 0;
               Pixel_merge <= Pixel_wait;
            end if;
         end if;

         -- fourth cycle
         pixel_we_color    <= '0';
         pixel_we_settings <= '0';
         pixel_objwnd      <= '0';
         pixel_x           <= target_merge;

         if (enable_merge = '1' and mosaik_merge = '0') then
            if (bitmap_merge = '1') then
               pixeldata_color <= '0' & bmpcolor_merge(14 downto 0);
            elsif (extpal_merge = '1') then
               if (EXTPAL_addrlow = '1') then
                  pixeldata_color <= '0' & EXTPAL_Drawer_data(30 downto 16);
               else
                  pixeldata_color <= '0' & EXTPAL_Drawer_data(14 downto 0);
               end if;
            elsif (PALETTE_addrlow = '1') then
               pixeldata_color <= '0' & PALETTE_Drawer_data(30 downto 16);
            else
               pixeldata_color <= '0' & PALETTE_Drawer_data(14 downto 0);
            end if;
            if (bitmap_merge = '1') then
               pixeldata_settings <= bmpalpha_merge & '1' & Pixel_merge.alpha & Pixel_merge.prio;
            else
               pixeldata_settings <= "0000" & '0' & Pixel_merge.alpha & Pixel_merge.prio;
            end if;
         end if;

         if (enable_merge = '1' and output_ok = '1') then

            if (Pixel_merge.transparent = '0' and Pixel_merge.objwnd = '1') then
               pixel_objwnd <= '1';
            end if;

            if (Pixel_merge.objwnd = '0') then
               if (Pixel_readback.transparent = '1' or unsigned(Pixel_merge.prio) < unsigned(Pixel_readback.prio)) then
                  pixel_we_settings             <= '1';
                  pixelarray(target_merge).prio <= Pixel_merge.prio;
                  if (Pixel_merge.transparent = '0') then
                     pixel_we_color                       <= '1';
                     pixelarray(target_merge).transparent <= '0';
                  end if;
               end if;
            end if;

         end if;

      end if;
   end process;

end architecture;
