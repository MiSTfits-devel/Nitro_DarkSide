-- SPDX-License-Identifier: GPL-2.0-or-later
-- NDS affine (rot/scale) BG drawer (fork of gba_drawer_mode2). One instance
-- renders one BG line. Deltas vs the GBA donor:
--
--   * 256-pixel line
--   * 512 KB BG address space: mapbase/tilebase as full byte addresses
--     (orchestrator sums DISPCNT offsets with BGxCNT blocks)
--
-- The map stays 8-bit tile entries (16x16..128x128 of 8bpp tiles), std
-- palette only - extended palettes apply to text and extended-mode BGs,
-- not plain affine (GBATEK). Wrapping, mosaic, transparent-on-0 unchanged.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nds_drawer_affine_ref is
   generic
   (
      DXYBITS      : integer := 16;
      ACCURACYBITS : integer := 28
   );
   port
   (
      clk                  : in  std_logic;

      line_trigger         : in  std_logic;
      drawline             : in  std_logic;
      busy                 : out std_logic := '0';

      mapbase              : in  unsigned(18 downto 0);   -- byte address, 2 KB aligned
      tilebase             : in  unsigned(18 downto 0);   -- byte address, 16 KB aligned
      screensize           : in  unsigned(1 downto 0);
      wrapping             : in  std_logic;
      mosaic               : in  std_logic;
      Mosaic_H_Size        : in  unsigned(3 downto 0);
      refX                 : in  signed;
      refY                 : in  signed;
      refX_mosaic          : in  signed(27 downto 0);
      refY_mosaic          : in  signed(27 downto 0);
      dx                   : in  signed(DXYBITS - 1 downto 0);
      dy                   : in  signed(DXYBITS - 1 downto 0);

      pixel_we             : out std_logic := '0';
      pixeldata            : buffer std_logic_vector(15 downto 0) := (others => '0');
      pixel_x              : out integer range 0 to 255;

      PALETTE_Drawer_addr  : out integer range 0 to 127;
      PALETTE_Drawer_data  : in  std_logic_vector(31 downto 0);
      PALETTE_Drawer_valid : in  std_logic;

      -- one request in flight; req one-cycle pulse, addr held until the
      -- done pulse (data valid that cycle)
      VRAM_Drawer_req      : out std_logic := '0';
      VRAM_Drawer_addr     : out integer range 0 to 131071;
      VRAM_Drawer_data     : in  std_logic_vector(31 downto 0);
      VRAM_Drawer_done     : in  std_logic
   );
end entity;

architecture arch of nds_drawer_affine_ref is

   type tVRAMState is
   (
      IDLE,
      CALCADDR,
      WAITREAD_TILE,
      EVALTILE,
      WAITREAD_COLOR,
      HANDOFF
   );
   signal vramfetch    : tVRAMState := IDLE;

   type tPALETTEState is
   (
      IDLE,
      STARTREAD,
      WAITREAD
   );
   signal palettefetch : tPALETTEState := IDLE;

   signal VRAM_byteaddr        : unsigned(18 downto 0) := (others => '0');
   signal VRAM_byteaddr_low    : unsigned(1 downto 0) := (others => '0');
   signal VRAM_addr_r          : unsigned(18 downto 2) := (others => '0');

   signal PALETTE_byteaddr     : std_logic_vector(8 downto 0) := (others => '0');
   signal palette_readwait     : integer range 0 to 1;

   signal realX                : signed(ACCURACYBITS - 1 downto 0);
   signal realY                : signed(ACCURACYBITS - 1 downto 0);
   signal xxx                  : signed(19 downto 0);
   signal yyy                  : signed(19 downto 0);
   signal xxx_pre              : signed(19 downto 0);
   signal yyy_pre              : signed(19 downto 0);

   signal tileindex            : integer range -524288 to 524287;

   signal x_cnt                : integer range 0 to 255;
   signal scroll_mod           : integer range 128 to 1024;
   signal tileinfo             : std_logic_vector(7 downto 0) := (others => '0');

   signal colordata            : std_logic_vector(7 downto 0) := (others => '0');
   signal colordata_r          : std_logic_vector(7 downto 0) := (others => '0');
   signal palette_newPixel     : std_logic := '0';
   signal palette_x_cnt        : integer range 0 to 255;

   -- last-word caches on the map and char fetch streams: neighboring
   -- pixels usually sample the same 32-bit word (a map word covers 4
   -- tiles = 32 screen pixels, a char word 4 texels), so most of the two
   -- per-pixel round-trips through the line server collapse to hits.
   -- Invalidated at drawline (per line - VRAM writes land between lines).
   signal cache_map_addr       : unsigned(18 downto 2) := (others => '0');
   signal cache_map_data       : std_logic_vector(31 downto 0) := (others => '0');
   signal cache_map_valid      : std_logic := '0';
   signal cache_chr_addr       : unsigned(18 downto 2) := (others => '0');
   signal cache_chr_data       : std_logic_vector(31 downto 0) := (others => '0');
   signal cache_chr_valid      : std_logic := '0';

   signal mosaik_cnt           : integer range 0 to 15 := 0;

begin

   -- request address is registered when req issues - VRAM_byteaddr is a
   -- combinational mux on the FSM state and would drift mid-request
   VRAM_Drawer_addr    <= to_integer(VRAM_addr_r);
   PALETTE_Drawer_addr <= to_integer(unsigned(PALETTE_byteaddr(8 downto 2)));

   xxx_pre <= realX(realX'left downto realX'left  - 19);
   yyy_pre <= realY(realY'left downto realY'left  - 19);

   xxx     <= xxx_pre          when (wrapping = '0') else
              xxx_pre mod 128  when (screensize = "00") else
              xxx_pre mod 256  when (screensize = "01") else
              xxx_pre mod 512  when (screensize = "10") else
              xxx_pre mod 1024;

   yyy     <= yyy_pre          when (wrapping = '0') else
              yyy_pre mod 128  when (screensize = "00") else
              yyy_pre mod 256  when (screensize = "01") else
              yyy_pre mod 512  when (screensize = "10") else
              yyy_pre mod 1024;

   tileindex <= to_integer((xxx / 8) + shift_left(shift_right(yyy, 3), 4)) when (screensize = "00") else
                to_integer((xxx / 8) + shift_left(shift_right(yyy, 3), 5)) when (screensize = "01") else
                to_integer((xxx / 8) + shift_left(shift_right(yyy, 3), 6)) when (screensize = "10") else
                to_integer((xxx / 8) + shift_left(shift_right(yyy, 3), 7));

   -- mod keeps the address in the 512 KB window (hardware wrap) and
   -- non-negative while xxx/yyy are still out of range pre-skip
   VRAM_byteaddr <= to_unsigned((to_integer(mapbase) + tileindex) mod 524288, VRAM_byteaddr'length) when (vramfetch = CALCADDR) else
                    to_unsigned((to_integer(tilebase) + to_integer(unsigned(tileinfo)) * 64
                                + to_integer(unsigned(yyy(2 downto 0))) * 8
                                + to_integer(unsigned(xxx(2 downto 0)))) mod 524288, VRAM_byteaddr'length);

   -- vramfetch
   process (clk)
   begin
      if rising_edge(clk) then

         palette_newPixel <= '0';
         VRAM_Drawer_req  <= '0';

         case (vramfetch) is

            when IDLE =>
               if (line_trigger = '1') then
                  realX <= (others => '0');
                  realY <= (others => '0');
                  if (mosaic = '1' and unsigned(Mosaic_H_Size) > 0) then
                     realX(realX'left downto realX'left - refX_mosaic'length + 1) <= refX_mosaic;
                     realY(realY'left downto realY'left - refY_mosaic'length + 1) <= refY_mosaic;
                  else
                     realX(realX'left downto realX'left - refX'length + 1) <= refX;
                     realY(realY'left downto realY'left - refY'length + 1) <= refY;
                  end if;
               elsif (drawline = '1') then
                  busy         <= '1';
                  vramfetch    <= CALCADDR;
                  case (to_integer(screensize)) is
                     when 0 => scroll_mod <= 128;
                     when 1 => scroll_mod <= 256;
                     when 2 => scroll_mod <= 512;
                     when 3 => scroll_mod <= 1024;
                     when others => null;
                  end case;
                  x_cnt           <= 0;
                  cache_map_valid <= '0';
                  cache_chr_valid <= '0';
               elsif (palettefetch = IDLE and palette_newPixel = '0') then
                  busy         <= '0';   -- the last pixel may still be in the palette pipe
               end if;

            when CALCADDR =>
               if (wrapping = '0' and (xxx_pre < 0 or yyy_pre < 0 or xxx_pre >= scroll_mod or yyy_pre >= scroll_mod)) then
                  realX <= realX + dx;
                  realY <= realy + dy;
                  if (x_cnt < 255) then
                     vramfetch <= CALCADDR;
                     x_cnt     <= x_cnt + 1;
                  else
                     vramfetch <= IDLE;
                  end if;
               elsif (cache_map_valid = '1' and cache_map_addr = VRAM_byteaddr(18 downto 2)) then
                  case (to_integer(VRAM_byteaddr(1 downto 0))) is
                     when 0 => tileinfo <= cache_map_data( 7 downto  0);
                     when 1 => tileinfo <= cache_map_data(15 downto  8);
                     when 2 => tileinfo <= cache_map_data(23 downto 16);
                     when 3 => tileinfo <= cache_map_data(31 downto 24);
                     when others => null;
                  end case;
                  vramfetch <= EVALTILE;
               else
                  VRAM_byteaddr_low <= VRAM_byteaddr(1 downto 0);
                  VRAM_addr_r       <= VRAM_byteaddr(18 downto 2);
                  VRAM_Drawer_req   <= '1';
                  vramfetch         <= WAITREAD_TILE;
               end if;

            when WAITREAD_TILE =>
               if (VRAM_Drawer_done = '1') then
                  case (to_integer(VRAM_byteaddr_low(1 downto 0))) is
                     when 0 => tileinfo <= VRAM_Drawer_data( 7 downto  0);
                     when 1 => tileinfo <= VRAM_Drawer_data(15 downto  8);
                     when 2 => tileinfo <= VRAM_Drawer_data(23 downto 16);
                     when 3 => tileinfo <= VRAM_Drawer_data(31 downto 24);
                     when others => null;
                  end case;
                  cache_map_addr  <= VRAM_addr_r;
                  cache_map_data  <= VRAM_Drawer_data;
                  cache_map_valid <= '1';
                  vramfetch  <= EVALTILE;
               end if;

            when EVALTILE =>
               if (cache_chr_valid = '1' and cache_chr_addr = VRAM_byteaddr(18 downto 2)) then
                  case (to_integer(VRAM_byteaddr(1 downto 0))) is
                     when 0 => colordata_r <= cache_chr_data( 7 downto  0);
                     when 1 => colordata_r <= cache_chr_data(15 downto  8);
                     when 2 => colordata_r <= cache_chr_data(23 downto 16);
                     when 3 => colordata_r <= cache_chr_data(31 downto 24);
                     when others => null;
                  end case;
                  vramfetch <= HANDOFF;
               else
                  VRAM_byteaddr_low <= VRAM_byteaddr(1 downto 0);
                  VRAM_addr_r       <= VRAM_byteaddr(18 downto 2);
                  VRAM_Drawer_req   <= '1';
                  vramfetch         <= WAITREAD_COLOR;
               end if;

            -- capture the color byte on the done cycle, then hold the pixel
            -- until the palette FSM is free (the donor advanced immediately
            -- and relied on the GBA 4-phase service cadence)
            when WAITREAD_COLOR =>
               if (VRAM_Drawer_done = '1') then
                  colordata_r     <= colordata;
                  cache_chr_addr  <= VRAM_addr_r;
                  cache_chr_data  <= VRAM_Drawer_data;
                  cache_chr_valid <= '1';
                  vramfetch   <= HANDOFF;
               end if;

            when HANDOFF =>
               if (palettefetch = IDLE and palette_newPixel = '0') then
                  palette_newPixel <= '1';
                  palette_x_cnt    <= x_cnt;
                  realX <= realX + dx;
                  realY <= realy + dy;
                  if (x_cnt < 255) then
                     vramfetch <= CALCADDR;
                     x_cnt     <= x_cnt + 1;
                  else
                     vramfetch <= IDLE;
                  end if;
               end if;

         end case;

      end if;
   end process;

   colordata <= VRAM_Drawer_data(7  downto 0)  when (VRAM_byteaddr_low = "00") else
                VRAM_Drawer_data(15 downto 8)  when (VRAM_byteaddr_low = "01") else
                VRAM_Drawer_data(23 downto 16) when (VRAM_byteaddr_low = "10") else
                VRAM_Drawer_data(31 downto 24);

   process (clk)
   begin
      if rising_edge(clk) then

         pixel_we      <= '0';

         if (drawline = '1') then
            mosaik_cnt    <= 15; -- first pixel must fetch new data
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
                     mosaik_cnt       <= 0;

                     palettefetch     <= STARTREAD;
                     PALETTE_byteaddr <= colordata_r & '0';
                     if (colordata_r = x"00") then -- transparent
                        palettefetch  <= IDLE;
                        pixeldata(15) <= '1';
                     end if;
                  end if;
               end if;

            when STARTREAD =>
               palettefetch     <= WAITREAD;
               -- The palette answers ONE cycle after the address, and the
               -- address became present on entering STARTREAD - so the first
               -- WAITREAD cycle already has the word. This budgeted a second
               -- cycle, which only ever mattered when the shared palette port
               -- was round-robin served and the wait was hidden anyway; with a
               -- private read port per BG (nds_gpu2d gpal_bg) it is one wasted
               -- cycle on every single pixel.
               palette_readwait <= 0;

            when WAITREAD =>
               if (palette_readwait > 0) then
                  palette_readwait <= palette_readwait - 1;
               elsif (PALETTE_Drawer_valid = '1') then
                  palettefetch  <= IDLE;
                  pixel_we      <= '1';
                  if (PALETTE_byteaddr(1) = '1') then
                     pixeldata <= '0' & PALETTE_Drawer_data(30 downto 16);
                  else
                     pixeldata <= '0' & PALETTE_Drawer_data(14 downto 0);
                  end if;
               end if;

         end case;

      end if;
   end process;

end architecture;
