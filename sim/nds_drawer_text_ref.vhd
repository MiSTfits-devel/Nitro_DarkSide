-- SPDX-License-Identifier: GPL-2.0-or-later
-- NDS text-mode BG drawer (fork of gba_drawer_mode0). One instance renders
-- one BG line into the per-BG line buffer. Deltas vs the GBA donor:
--
--   * 256-pixel line (0..255), ypos 0..191
--   * 512 KB BG address space: mapbase/tilebase arrive as full byte
--     addresses (the orchestrator sums DISPCNT char/screen base offsets
--     with BGxCNT blocks), VRAM_Drawer_addr is a 17-bit word address
--   * extended palettes: in 256-color mode with extpalette='1' the color
--     is looked up in the 32 KB ext-pal space (slot from the orchestrator:
--     BG0/1 -> slot 0/1 or 2/3 per BGxCNT.13, BG2/3 -> slot 2/3) as
--     slot*8K + palno*512 + color*2, palno = tileinfo(15:12). Without
--     extpalette, 256-color tiles use the std palette and ignore palno
--     (GBA behavior). 16-color tiles always use the std palette.
--
-- Map layout, flips, mosaic, and the transparent-on-index-0 rule are
-- unchanged from the GBA. Register semantics per GBATEK / melonDS GPU2D.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nds_drawer_text_ref is
   port
   (
      clk                  : in  std_logic;

      drawline             : in  std_logic;
      busy                 : out std_logic := '0';

      ypos                 : in  integer range 0 to 191;
      ypos_mosaic          : in  integer range 0 to 191;
      mapbase              : in  unsigned(18 downto 0);   -- byte address, 2 KB aligned
      tilebase             : in  unsigned(18 downto 0);   -- byte address, 16 KB aligned
      hicolor              : in  std_logic;
      extpalette           : in  std_logic;
      extpal_slot          : in  unsigned(1 downto 0);
      mosaic               : in  std_logic;
      Mosaic_H_Size        : in  unsigned(3 downto 0);
      screensize           : in  unsigned(1 downto 0);
      scrollX              : in  unsigned(8 downto 0);
      scrollY              : in  unsigned(8 downto 0);

      pixel_we             : out std_logic := '0';
      pixeldata            : buffer std_logic_vector(15 downto 0) := (others => '0');
      pixel_x              : out integer range 0 to 255;

      PALETTE_Drawer_addr  : out integer range 0 to 127;
      PALETTE_Drawer_data  : in  std_logic_vector(31 downto 0);
      PALETTE_Drawer_valid : in  std_logic;

      EXTPAL_Drawer_addr   : out integer range 0 to 8191;  -- word into 32 KB ext-pal space
      EXTPAL_Drawer_data   : in  std_logic_vector(31 downto 0);
      EXTPAL_Drawer_valid  : in  std_logic;

      -- VRAM char/map fetch: one request in flight; req is a one-cycle
      -- pulse, addr held until the done pulse (data valid that cycle) -
      -- latency-tolerant for the VRAM line server
      VRAM_Drawer_req      : out std_logic := '0';
      VRAM_Drawer_addr     : out integer range 0 to 131071; -- word into 512 KB BG space
      VRAM_Drawer_data     : in  std_logic_vector(31 downto 0);
      VRAM_Drawer_done     : in  std_logic
   );
end entity;

architecture arch of nds_drawer_text_ref is

   type tVRAMState is
   (
      IDLE,
      CALCBASE,
      CALCADDR,
      WAITREAD_TILE,
      CALCCOLORADDR,
      WAITREAD_COLOR
   );
   signal vramfetch    : tVRAMState := IDLE;

   type tPALETTEState is
   (
      IDLE,
      WAITREAD
   );
   signal palettefetch : tPALETTEState := IDLE;

   signal VRAM_byteaddr        : unsigned(18 downto 0) := (others => '0');

   signal PALETTE_byteaddr     : std_logic_vector(8 downto 0) := (others => '0');
   signal PALETTE_byteaddr_1   : std_logic_vector(8 downto 0) := (others => '0');
   signal EXTPAL_byteaddr      : std_logic_vector(14 downto 0) := (others => '0');
   signal EXTPAL_byteaddr_1    : std_logic_vector(14 downto 0) := (others => '0');
   signal use_extpal           : std_logic;

   signal x_cnt                : integer range 0 to 255;
   signal y_scrolled           : integer range 0 to 1023;
   signal y_scrolled_mod       : integer range 0 to 511;
   signal offset_y             : integer range 0 to 1023;
   -- Text BG dimensions are powers of two. Keep the captured 256/512 choice
   -- explicit so Quartus sees literal-constant wrapping instead of inferring
   -- a runtime divider for `mod scroll_[xy]_mod` in every drawer instance.
   signal scroll_x_512         : std_logic := '0';
   signal scroll_y_512         : std_logic := '0';

   signal x_scrolled           : unsigned(8 downto 0) := (others => '0');

   signal tileinfo             : std_logic_vector(15 downto 0) := (others => '0');
   signal pixeladdr_base       : integer range 0 to 1048575;

   signal colordata            : std_logic_vector(7 downto 0) := (others => '0');
   signal VRAM_lastcolor_addr  : unsigned(16 downto 0) := (others => '0');
   signal VRAM_lastcolor_data  : std_logic_vector(31 downto 0) := (others => '0');
   signal VRAM_lastcolor_valid : std_logic := '0';

   signal palette_newPixel     : std_logic := '0';
   signal palette_x_cnt        : integer range 0 to 255;
   signal palette_selecthigh   : std_logic := '0';
   signal mosaik_cnt           : integer range 0 to 15 := 0;

begin

   x_scrolled <= to_unsigned((x_cnt + to_integer(scrollX)) mod 512, 9) when (scroll_x_512 = '1') else
                 to_unsigned((x_cnt + to_integer(scrollX)) mod 256, 9);

   VRAM_Drawer_addr    <= to_integer(VRAM_byteaddr(18 downto 2));
   PALETTE_Drawer_addr <= to_integer(unsigned(PALETTE_byteaddr(8 downto 2)));
   EXTPAL_Drawer_addr  <= to_integer(unsigned(EXTPAL_byteaddr(14 downto 2)));

   -- 256-color + ext palette enable -> the ext-pal lookup path
   use_extpal <= hicolor and extpalette;

   y_scrolled <= ypos_mosaic + to_integer(scrollY) when (mosaic = '1') else
                 ypos + to_integer(scrollY);

   y_scrolled_mod <= y_scrolled mod 512 when (scroll_y_512 = '1') else
                     y_scrolled mod 256;

   offset_y   <= ((y_scrolled mod 256) / 8) * 32;

   -- vramfetch
   process (clk)
    variable tileindex_var   : integer range 0 to 4095;
    variable tileaddr_var    : integer range 0 to 4095;
    variable pixeladdr       : integer range 0 to 1048575;
    variable pixel_x_in_tile : integer range 0 to 7;
    variable done_var        : std_logic;
   begin
      if rising_edge(clk) then

         palette_newPixel <= '0';
         VRAM_Drawer_req  <= '0';

         case (vramfetch) is

            when IDLE =>
               if (drawline = '1') then
                  busy            <= '1';
                  vramfetch       <= CALCBASE;
                  scroll_x_512 <= '0';
                  scroll_y_512 <= '0';
                  case (to_integer(screensize)) is
                     when 1 => scroll_x_512 <= '1';
                     when 2 => scroll_y_512 <= '1';
                     when 3 => scroll_x_512 <= '1'; scroll_y_512 <= '1';
                     when others => null;
                  end case;
                  x_cnt     <= 0;
                  VRAM_lastcolor_valid <= '0'; -- invalidate fetch cache
               elsif (palettefetch = IDLE and palette_newPixel = '0') then
                  busy         <= '0';   -- the last pixel may still be in the palette pipe
               end if;

            when CALCBASE =>
               vramfetch  <= CALCADDR;

            when CALCADDR =>
               tileindex_var  := 0;
               if (x_scrolled >= 256 or (y_scrolled_mod >= 256 and to_integer(screensize) = 2)) then
                  tileindex_var  := tileindex_var + 1024;
               end if;
               if (y_scrolled_mod >= 256 and to_integer(screensize) = 3) then
                  tileindex_var := tileindex_var + 2048;
               end if;
               tileaddr_var  := tileindex_var + offset_y + to_integer(x_scrolled(7 downto 3));
               VRAM_byteaddr   <= to_unsigned((to_integer(mapbase) + (tileaddr_var * 2)) mod 524288, VRAM_byteaddr'length);
               VRAM_Drawer_req <= '1';
               vramfetch       <= WAITREAD_TILE;

            when WAITREAD_TILE =>
               if (VRAM_Drawer_done = '1') then
                  if (VRAM_byteaddr(1) = '1') then
                     tileinfo <= VRAM_Drawer_data(31 downto 16);
                     if (hicolor = '0') then
                        pixeladdr_base <= to_integer(tilebase) + to_integer(unsigned(VRAM_Drawer_data(25 downto 16))) * 32;
                     else
                        pixeladdr_base <= to_integer(tilebase) + to_integer(unsigned(VRAM_Drawer_data(25 downto 16))) * 64;
                     end if;
                  else
                     tileinfo <= VRAM_Drawer_data(15 downto 0);
                     if (hicolor = '0') then
                        pixeladdr_base <= to_integer(tilebase) + to_integer(unsigned(VRAM_Drawer_data(9 downto 0))) * 32;
                     else
                        pixeladdr_base <= to_integer(tilebase) + to_integer(unsigned(VRAM_Drawer_data(9 downto 0))) * 64;
                     end if;
                  end if;
                  vramfetch  <= CALCCOLORADDR;
               end if;

            when CALCCOLORADDR =>
               vramfetch  <= WAITREAD_COLOR;
               if (hicolor = '0') then
                  pixel_x_in_tile := to_integer(x_scrolled(2 downto 1));
               else
                  pixel_x_in_tile := to_integer(x_scrolled(2 downto 0));
               end if;
               if (tileinfo(10) = '1') then -- hoz flip
                  if (hicolor = '0') then
                     pixeladdr := pixeladdr_base + (3 - pixel_x_in_tile);
                  else
                     pixeladdr := pixeladdr_base + (7 - pixel_x_in_tile);
                  end if;
               else
                  pixeladdr := pixeladdr_base + pixel_x_in_tile;
               end if;
               if (tileinfo(11) = '1') then -- vert flip
                  if (hicolor = '0') then
                     pixeladdr := pixeladdr + ((7 - (y_scrolled_mod mod 8)) * 4);
                  else
                     pixeladdr := pixeladdr + ((7 - (y_scrolled_mod mod 8)) * 8);
                  end if;
               else
                  if (hicolor = '0') then
                     pixeladdr := pixeladdr + (y_scrolled_mod mod 8 * 4);
                  else
                     pixeladdr := pixeladdr + (y_scrolled_mod mod 8 * 8);
                  end if;
               end if;
               VRAM_byteaddr <= to_unsigned(pixeladdr mod 524288, VRAM_byteaddr'length);
               -- only issue a request when the word cache misses - a stale
               -- in-flight response would otherwise be misassociated
               if (VRAM_lastcolor_valid = '0' or
                   VRAM_lastcolor_addr /= to_unsigned(pixeladdr mod 524288, 19)(18 downto 2)) then
                  VRAM_Drawer_req <= '1';
               end if;
               vramfetch     <= WAITREAD_COLOR;

            when WAITREAD_COLOR =>
               -- live cache check: also covers the palette-stall cycles
               -- after a fresh word landed (done registers it below)
               done_var := '0';
               if (VRAM_lastcolor_valid = '1' and VRAM_lastcolor_addr = VRAM_byteaddr(VRAM_byteaddr'left downto 2)) then
                  done_var := '1';
                  case (VRAM_byteaddr(1 downto 0)) is
                     when "00" => colordata <= VRAM_lastcolor_data(7  downto 0);
                     when "01" => colordata <= VRAM_lastcolor_data(15 downto 8);
                     when "10" => colordata <= VRAM_lastcolor_data(23 downto 16);
                     when "11" => colordata <= VRAM_lastcolor_data(31 downto 24);
                     when others => null;
                  end case;
               elsif (VRAM_Drawer_done = '1') then
                  done_var := '1';
                  VRAM_lastcolor_addr  <= VRAM_byteaddr(VRAM_byteaddr'left downto 2);
                  VRAM_lastcolor_data  <= VRAM_Drawer_data;
                  VRAM_lastcolor_valid <= '1';
                  case (VRAM_byteaddr(1 downto 0)) is
                     when "00" => colordata <= VRAM_Drawer_data(7  downto 0);
                     when "01" => colordata <= VRAM_Drawer_data(15 downto 8);
                     when "10" => colordata <= VRAM_Drawer_data(23 downto 16);
                     when "11" => colordata <= VRAM_Drawer_data(31 downto 24);
                     when others => null;
                  end case;
               end if;

               if (done_var = '1') then
                  palette_x_cnt      <= x_cnt;
                  palette_selecthigh <= '0';
                  if ((tileinfo(10) = '1' and (x_scrolled mod 2) = 0) or (tileinfo(10) = '0' and (x_scrolled mod 2) = 1)) then
                     palette_selecthigh <= '1';
                  end if;
                  if (palettefetch = IDLE) then
                     palette_newPixel   <= '1';
                     if (x_cnt < 255) then
                        x_cnt     <= x_cnt + 1;
                        if (x_scrolled(2 downto 0) = "111") then
                           vramfetch <= CALCADDR;
                        else
                           vramfetch <= CALCCOLORADDR;
                        end if;
                     else
                        vramfetch <= IDLE;
                     end if;
                  end if;
               end if;

         end case;

      end if;
   end process;

   -- palette addressing: std palette (16-color, or 256-color without ext
   -- palettes) vs ext-pal space (256-color with ext palettes)
   PALETTE_byteaddr <= PALETTE_byteaddr_1                                   when (palettefetch = WAITREAD) else
                       colordata & '0'                                      when (hicolor = '1') else
                       tileinfo(15 downto 12) & colordata(7 downto 4) & '0' when (palette_selecthigh = '1') else
                       tileinfo(15 downto 12) & colordata(3 downto 0) & '0';

   EXTPAL_byteaddr <= EXTPAL_byteaddr_1 when (palettefetch = WAITREAD) else
                      std_logic_vector(extpal_slot) & tileinfo(15 downto 12) & colordata & '0';

   process (clk)
   begin
      if rising_edge(clk) then

         pixel_we      <= '0';

         if (drawline = '1') then
            mosaik_cnt    <= 15;  -- first pixel must fetch new data
            pixeldata(15) <= '1';
         end if;

         case (palettefetch) is

            when IDLE =>
               if (palette_newPixel = '1') then

                  pixel_x          <= palette_x_cnt;

                  if (mosaik_cnt < Mosaic_H_Size and mosaic = '1') then
                     mosaik_cnt <= mosaik_cnt + 1;
                     pixel_we   <= not pixeldata(15);
                  else
                     mosaik_cnt         <= 0;

                     palettefetch       <= WAITREAD;
                     PALETTE_byteaddr_1 <= PALETTE_byteaddr;
                     EXTPAL_byteaddr_1  <= EXTPAL_byteaddr;

                     if (hicolor = '0') then
                        if (palette_selecthigh = '1') then
                           if (colordata(7 downto 4) = x"0") then -- transparent
                              palettefetch  <= IDLE;
                              pixeldata(15) <= '1';
                           end if;
                        else
                           if (colordata(3 downto 0) = x"0") then -- transparent
                              palettefetch  <= IDLE;
                              pixeldata(15) <= '1';
                           end if;
                        end if;
                     else
                        if (colordata = x"00") then -- transparent
                           palettefetch  <= IDLE;
                           pixeldata(15) <= '1';
                        end if;
                     end if;
                  end if;
               end if;

            when WAITREAD =>
               if (use_extpal = '1') then
                  if (EXTPAL_Drawer_valid = '1') then
                     palettefetch  <= IDLE;
                     pixel_we      <= '1';
                     if (EXTPAL_byteaddr_1(1) = '1') then
                        pixeldata <= '0' & EXTPAL_Drawer_data(30 downto 16);
                     else
                        pixeldata <= '0' & EXTPAL_Drawer_data(14 downto 0);
                     end if;
                  end if;
               else
                  if (PALETTE_Drawer_valid = '1') then
                     palettefetch  <= IDLE;
                     pixel_we      <= '1';
                     if (PALETTE_byteaddr_1(1) = '1') then
                        pixeldata <= '0' & PALETTE_Drawer_data(30 downto 16);
                     else
                        pixeldata <= '0' & PALETTE_Drawer_data(14 downto 0);
                     end if;
                  end if;
               end if;

         end case;

      end if;
   end process;

end architecture;
