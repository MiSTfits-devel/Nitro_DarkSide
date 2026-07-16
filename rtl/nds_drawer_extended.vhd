-- SPDX-License-Identifier: GPL-2.0-or-later
-- NDS extended-mode BG drawer (BG2/BG3 with BGxCNT.7 semantics), built on
-- the nds_drawer_affine skeleton. All three variants are rot/scale
-- (ref/dx/dy) with the wrapping bit; VARIANT selects the pixel source:
--
--   0: 8bpp tiles with 16-bit map entries (tile# 9:0, hflip 10, vflip 11,
--      palno 15:12), sizes 128..1024 like plain affine; ext palettes
--      supported (slot = BG index from the orchestrator)
--   1: 256-color bitmap, std BG palette, sizes 128x128/256x256/512x256/
--      512x512, mapbase = bitmap base (16 KB units upstream)
--   2: direct-color bitmap, same sizes; bit15 of the pixel = alpha
--      (0 -> transparent), no palette lookup
--
-- Register semantics per GBATEK / melonDS GPU2D. Same request/valid memory
-- cadence and pixel handoff as the other NDS drawers.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nds_drawer_extended is
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

      variant              : in  unsigned(1 downto 0);
      mapbase              : in  unsigned(18 downto 0);   -- map / bitmap byte base
      tilebase             : in  unsigned(18 downto 0);   -- tile byte base (variant 0)
      extpalette           : in  std_logic;
      extpal_slot          : in  unsigned(1 downto 0);
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

      EXTPAL_Drawer_addr   : out integer range 0 to 8191;
      EXTPAL_Drawer_data   : in  std_logic_vector(31 downto 0);
      EXTPAL_Drawer_valid  : in  std_logic;

      VRAM_Drawer_addr     : out integer range 0 to 131071;
      VRAM_Drawer_data     : in  std_logic_vector(31 downto 0);
      VRAM_Drawer_valid    : in  std_logic
   );
end entity;

architecture arch of nds_drawer_extended is

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

   -- latched by the palette FSM at trigger time - colordata_r/palno_r move
   -- on with the next pixel while a lookup is still in flight
   signal PALETTE_byteaddr     : std_logic_vector(8 downto 0) := (others => '0');
   signal EXTPAL_byteaddr      : std_logic_vector(14 downto 0) := (others => '0');
   signal palette_readwait     : integer range 0 to 1;

   signal realX                : signed(ACCURACYBITS - 1 downto 0);
   signal realY                : signed(ACCURACYBITS - 1 downto 0);
   signal xxx                  : signed(19 downto 0);
   signal yyy                  : signed(19 downto 0);
   signal xxx_pre              : signed(19 downto 0);
   signal yyy_pre              : signed(19 downto 0);
   signal xxx_flip             : unsigned(2 downto 0);
   signal yyy_flip             : unsigned(2 downto 0);

   signal xlim                 : integer range 128 to 1024;
   signal ylim                 : integer range 128 to 1024;

   signal palno                : std_logic_vector(3 downto 0) := (others => '0');

   signal x_cnt                : integer range 0 to 255;
   signal tileentry            : std_logic_vector(15 downto 0) := (others => '0');

   signal colordata16          : std_logic_vector(15 downto 0) := (others => '0');
   signal colordata_r          : std_logic_vector(15 downto 0) := (others => '0');
   signal palno_r              : std_logic_vector(3 downto 0) := (others => '0');
   signal palette_newPixel     : std_logic := '0';
   signal palette_x_cnt        : integer range 0 to 255;

   signal mosaik_cnt           : integer range 0 to 15 := 0;

   -- address plumbing
   signal map_entryaddr        : integer;
   signal pixeladdr            : integer;

begin

   VRAM_Drawer_addr    <= to_integer(VRAM_byteaddr(18 downto 2));
   PALETTE_Drawer_addr <= to_integer(unsigned(PALETTE_byteaddr(8 downto 2)));
   EXTPAL_Drawer_addr  <= to_integer(unsigned(EXTPAL_byteaddr(14 downto 2)));

   xxx_pre <= realX(realX'left downto realX'left - 19);
   yyy_pre <= realY(realY'left downto realY'left - 19);

   xxx     <= xxx_pre           when (wrapping = '0') else
              xxx_pre mod xlim;
   yyy     <= yyy_pre           when (wrapping = '0') else
              yyy_pre mod ylim;

   -- variant 0: 16-bit map entry address (map is (xlim/8) entries wide);
   -- variants 1/2: bitmap pixel address
   map_entryaddr <=
      to_integer((xxx / 8) + shift_left(shift_right(yyy, 3), 4 + to_integer(screensize))) * 2;

   -- tile pixel address is combinational from tileentry (valid during
   -- EVALTILE, the RAM latch slot); bitmap addresses from the live xxx/yyy
   -- (realX/realY only advance at HANDOFF)
   xxx_flip <= unsigned(xxx(2 downto 0)) when tileentry(10) = '0' else (7 - unsigned(xxx(2 downto 0)));
   yyy_flip <= unsigned(yyy(2 downto 0)) when tileentry(11) = '0' else (7 - unsigned(yyy(2 downto 0)));

   pixeladdr <=
      to_integer(tilebase) + to_integer(unsigned(tileentry(9 downto 0))) * 64
         + to_integer(yyy_flip) * 8 + to_integer(xxx_flip)               when (variant = "00") else
      to_integer(mapbase) + to_integer(yyy) * xlim + to_integer(xxx)     when (variant = "01") else
      to_integer(mapbase) + (to_integer(yyy) * xlim + to_integer(xxx)) * 2;

   VRAM_byteaddr <=
      to_unsigned((to_integer(mapbase) + map_entryaddr) mod 524288, VRAM_byteaddr'length)
         when (vramfetch = CALCADDR and variant = "00") else
      to_unsigned(pixeladdr mod 524288, VRAM_byteaddr'length);

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
                  if (variant = "00") then
                     xlim <= 128 * (2 ** to_integer(screensize));
                     ylim <= 128 * (2 ** to_integer(screensize));
                  else
                     case (to_integer(screensize)) is
                        when 0      => xlim <= 128; ylim <= 128;
                        when 1      => xlim <= 256; ylim <= 256;
                        when 2      => xlim <= 512; ylim <= 256;
                        when others => xlim <= 512; ylim <= 512;
                     end case;
                  end if;
                  x_cnt     <= 0;
               elsif (palettefetch = IDLE and palette_newPixel = '0') then
                  busy         <= '0';
               end if;

            when CALCADDR =>
               if (VRAM_Drawer_valid = '0') then
                  VRAM_byteaddr_low <= VRAM_byteaddr(1 downto 0);
                  if (variant = "00") then
                     vramfetch <= WAITREAD_TILE;
                  else
                     vramfetch <= WAITREAD_COLOR;
                  end if;

                  if (wrapping = '0') then
                     if (xxx_pre < 0 or yyy_pre < 0 or xxx_pre >= xlim or yyy_pre >= ylim) then
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
                  when 0 | 1  => tileentry <= VRAM_Drawer_data(15 downto  0);
                  when others => tileentry <= VRAM_Drawer_data(31 downto 16);
               end case;
               vramfetch  <= EVALTILE;

            when EVALTILE =>
               -- EVALTILE is the RAM latch slot for the tile pixel address
               -- (combinational from tileentry); WAITREAD_TILE was the
               -- data-valid cycle that loaded tileentry
               palno <= tileentry(15 downto 12);
               VRAM_byteaddr_low <= VRAM_byteaddr(1 downto 0);
               vramfetch <= WAITREAD_COLOR;

            when WAITREAD_COLOR =>
               colordata_r <= colordata16;
               palno_r     <= palno;
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

   -- color extraction on the data-valid cycle
   colordata16 <=
      -- variant 0 / 1: one byte
      x"00" & VRAM_Drawer_data( 7 downto  0) when (variant /= "10" and VRAM_byteaddr_low = "00") else
      x"00" & VRAM_Drawer_data(15 downto  8) when (variant /= "10" and VRAM_byteaddr_low = "01") else
      x"00" & VRAM_Drawer_data(23 downto 16) when (variant /= "10" and VRAM_byteaddr_low = "10") else
      x"00" & VRAM_Drawer_data(31 downto 24) when (variant /= "10") else
      -- variant 2: 16-bit direct color
      VRAM_Drawer_data(15 downto  0)         when (VRAM_byteaddr_low(1) = '0') else
      VRAM_Drawer_data(31 downto 16);

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

                     PALETTE_byteaddr <= colordata_r(7 downto 0) & '0';
                     EXTPAL_byteaddr  <= std_logic_vector(extpal_slot) & palno_r & colordata_r(7 downto 0) & '0';

                     if (variant = "10") then
                        -- direct color: alpha bit set -> opaque, no lookup
                        if (colordata_r(15) = '1') then
                           pixel_we  <= '1';
                           pixeldata <= '0' & colordata_r(14 downto 0);
                        else
                           pixeldata(15) <= '1';
                        end if;
                     elsif (colordata_r(7 downto 0) = x"00") then -- transparent
                        pixeldata(15) <= '1';
                     else
                        palettefetch  <= STARTREAD;
                     end if;
                  end if;
               end if;

            when STARTREAD =>
               palettefetch     <= WAITREAD;
               palette_readwait <= 1;

            when WAITREAD =>
               if (palette_readwait > 0) then
                  palette_readwait <= palette_readwait - 1;
               elsif (variant = "00" and extpalette = '1') then
                  if (EXTPAL_Drawer_valid = '1') then
                     palettefetch  <= IDLE;
                     pixel_we      <= '1';
                     if (EXTPAL_byteaddr(1) = '1') then
                        pixeldata <= '0' & EXTPAL_Drawer_data(30 downto 16);
                     else
                        pixeldata <= '0' & EXTPAL_Drawer_data(14 downto 0);
                     end if;
                  end if;
               else
                  if (PALETTE_Drawer_valid = '1') then
                     palettefetch  <= IDLE;
                     pixel_we      <= '1';
                     if (PALETTE_byteaddr(1) = '1') then
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
