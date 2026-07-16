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

entity nds_drawer_affine is
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

      VRAM_Drawer_addr     : out integer range 0 to 131071;
      VRAM_Drawer_data     : in  std_logic_vector(31 downto 0);
      VRAM_Drawer_valid    : in  std_logic
   );
end entity;

architecture arch of nds_drawer_affine is

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

   signal mosaik_cnt           : integer range 0 to 15 := 0;

begin

   VRAM_Drawer_addr    <= to_integer(VRAM_byteaddr(18 downto 2));
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
                  x_cnt     <= 0;
               elsif (palettefetch = IDLE and palette_newPixel = '0') then
                  busy         <= '0';   -- the last pixel may still be in the palette pipe
               end if;

            when CALCADDR =>
               if (VRAM_Drawer_valid = '0') then
                  VRAM_byteaddr_low <= VRAM_byteaddr(1 downto 0);
                  vramfetch     <= WAITREAD_TILE;

                  if (wrapping = '0') then
                     if (xxx_pre < 0 or yyy_pre < 0 or xxx_pre >= scroll_mod or yyy_pre >= scroll_mod) then
                        realX <= realX + dx;
                        realY <= realy + dy;
                        if (x_cnt < 255) then
                           vramfetch <= CALCADDR;
                           x_cnt     <= x_cnt + 1;
                        else
                           vramfetch <= IDLE;
                        end if;
                     end if;
                  end if;
               end if;

            when WAITREAD_TILE =>
               case (to_integer(VRAM_byteaddr_low(1 downto 0))) is
                  when 0 => tileinfo <= VRAM_Drawer_data( 7 downto  0);
                  when 1 => tileinfo <= VRAM_Drawer_data(15 downto  8);
                  when 2 => tileinfo <= VRAM_Drawer_data(23 downto 16);
                  when 3 => tileinfo <= VRAM_Drawer_data(31 downto 24);
                  when others => null;
               end case;
               vramfetch  <= EVALTILE;

            when EVALTILE =>
               VRAM_byteaddr_low <= VRAM_byteaddr(1 downto 0);
               vramfetch     <= WAITREAD_COLOR;

            -- capture the color byte while the data bus is valid, then hold
            -- the pixel until the palette FSM is free - the donor advanced
            -- immediately and relied on the GBA 4-phase service cadence to
            -- never overrun the palette pipeline; with other cadences that
            -- silently dropped pixels
            when WAITREAD_COLOR =>
               colordata_r <= colordata;
               vramfetch   <= HANDOFF;

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
               palette_readwait <= 1;

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
