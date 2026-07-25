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

      -- one request in flight; req one-cycle pulse, addr held until the
      -- done pulse (data valid that cycle)
      VRAM_Drawer_req      : out std_logic := '0';
      VRAM_Drawer_addr     : out integer range 0 to 131071;
      VRAM_Drawer_data     : in  std_logic_vector(31 downto 0);
      VRAM_Drawer_done     : in  std_logic
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
   signal VRAM_addr_r          : unsigned(18 downto 2) := (others => '0');

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
   -- xlim/ylim only ever hold 128/256/512/1024, but as plain runtime
   -- integers Quartus can't see that, so `mod xlim` / `* xlim` below
   -- synthesize as full dividers/multipliers. xlim_sel/ylim_sel carry the
   -- same value as a 2-bit index so those ops become literal-constant
   -- case/when expressions (mask/shift), same pattern as nds_drawer_affine.
   signal xlim_sel             : unsigned(1 downto 0) := (others => '0');
   signal ylim_sel             : unsigned(1 downto 0) := (others => '0');
   signal yyy_x_xlim           : integer := 0;

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

   -- last-word caches on the map and pixel fetch streams: a map word
   -- covers 2 tiles = 16 screen pixels, a char/bitmap word 4 (8bpp) or 2
   -- (16bpp) pixels, so most per-pixel round-trips through the line
   -- server collapse to hits. Invalidated at drawline (per line - VRAM
   -- writes land between lines).
   signal cache_map_addr       : unsigned(18 downto 2) := (others => '0');
   signal cache_map_data       : std_logic_vector(31 downto 0) := (others => '0');
   signal cache_map_valid      : std_logic := '0';
   signal cache_pix_addr       : unsigned(18 downto 2) := (others => '0');
   signal cache_pix_data       : std_logic_vector(31 downto 0) := (others => '0');
   signal cache_pix_valid      : std_logic := '0';
   signal cache_pix_color16    : std_logic_vector(15 downto 0);

begin

   -- request address is registered when req issues - VRAM_byteaddr is a
   -- combinational mux on the FSM state and would drift mid-request
   VRAM_Drawer_addr    <= to_integer(VRAM_addr_r);
   PALETTE_Drawer_addr <= to_integer(unsigned(PALETTE_byteaddr(8 downto 2)));
   EXTPAL_Drawer_addr  <= to_integer(unsigned(EXTPAL_byteaddr(14 downto 2)));

   xxx_pre <= realX(realX'left downto realX'left - 19);
   yyy_pre <= realY(realY'left downto realY'left - 19);

   xxx     <= xxx_pre           when (wrapping = '0') else
              xxx_pre mod 128   when (xlim_sel = "00") else
              xxx_pre mod 256   when (xlim_sel = "01") else
              xxx_pre mod 512   when (xlim_sel = "10") else
              xxx_pre mod 1024;
   yyy     <= yyy_pre           when (wrapping = '0') else
              yyy_pre mod 128   when (ylim_sel = "00") else
              yyy_pre mod 256   when (ylim_sel = "01") else
              yyy_pre mod 512   when (ylim_sel = "10") else
              yyy_pre mod 1024;

   -- variant 0: 16-bit map entry address (map is (xlim/8) entries wide);
   -- variants 1/2: bitmap pixel address
   map_entryaddr <=
      to_integer((xxx / 8) + shift_left(shift_right(yyy, 3), 4 + to_integer(screensize))) * 2;

   -- to_integer(yyy) * xlim, as a mux of literal-constant multiplies (see
   -- xlim_sel comment above) instead of one runtime-variable multiply.
   yyy_x_xlim <=
      to_integer(yyy) * 128    when (xlim_sel = "00") else
      to_integer(yyy) * 256    when (xlim_sel = "01") else
      to_integer(yyy) * 512    when (xlim_sel = "10") else
      to_integer(yyy) * 1024;

   -- tile pixel address is combinational from tileentry (valid during
   -- EVALTILE, the RAM latch slot); bitmap addresses from the live xxx/yyy
   -- (realX/realY only advance at HANDOFF)
   xxx_flip <= unsigned(xxx(2 downto 0)) when tileentry(10) = '0' else (7 - unsigned(xxx(2 downto 0)));
   yyy_flip <= unsigned(yyy(2 downto 0)) when tileentry(11) = '0' else (7 - unsigned(yyy(2 downto 0)));

   pixeladdr <=
      to_integer(tilebase) + to_integer(unsigned(tileentry(9 downto 0))) * 64
         + to_integer(yyy_flip) * 8 + to_integer(xxx_flip)               when (variant = "00") else
      to_integer(mapbase) + yyy_x_xlim + to_integer(xxx)                 when (variant = "01") else
      to_integer(mapbase) + (yyy_x_xlim + to_integer(xxx)) * 2;

   VRAM_byteaddr <=
      to_unsigned((to_integer(mapbase) + map_entryaddr) mod 524288, VRAM_byteaddr'length)
         when (vramfetch = CALCADDR and variant = "00") else
      to_unsigned(pixeladdr mod 524288, VRAM_byteaddr'length);

   -- colordata16 extraction from the cached pixel word (hit path: the
   -- live VRAM_byteaddr low bits select the lane, same shape as the
   -- data-valid-cycle extraction below)
   cache_pix_color16 <=
      x"00" & cache_pix_data( 7 downto  0) when (variant /= "10" and VRAM_byteaddr(1 downto 0) = "00") else
      x"00" & cache_pix_data(15 downto  8) when (variant /= "10" and VRAM_byteaddr(1 downto 0) = "01") else
      x"00" & cache_pix_data(23 downto 16) when (variant /= "10" and VRAM_byteaddr(1 downto 0) = "10") else
      x"00" & cache_pix_data(31 downto 24) when (variant /= "10") else
      cache_pix_data(15 downto  0)         when (VRAM_byteaddr(1) = '0') else
      cache_pix_data(31 downto 16);

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
                  if (variant = "00") then
                     xlim     <= 128 * (2 ** to_integer(screensize));
                     ylim     <= 128 * (2 ** to_integer(screensize));
                     xlim_sel <= screensize;
                     ylim_sel <= screensize;
                  else
                     case (to_integer(screensize)) is
                        when 0      => xlim <= 128; ylim <= 128; xlim_sel <= "00"; ylim_sel <= "00";
                        when 1      => xlim <= 256; ylim <= 256; xlim_sel <= "01"; ylim_sel <= "01";
                        when 2      => xlim <= 512; ylim <= 256; xlim_sel <= "10"; ylim_sel <= "01";
                        when others => xlim <= 512; ylim <= 512; xlim_sel <= "10"; ylim_sel <= "10";
                     end case;
                  end if;
                  x_cnt           <= 0;
                  cache_map_valid <= '0';
                  cache_pix_valid <= '0';
               elsif (palettefetch = IDLE and palette_newPixel = '0') then
                  busy         <= '0';
               end if;

            when CALCADDR =>
               if (wrapping = '0' and (xxx_pre < 0 or yyy_pre < 0 or xxx_pre >= xlim or yyy_pre >= ylim)) then
                  realX <= realX + dx;
                  realY <= realy + dy;
                  if (x_cnt < 255) then
                     vramfetch <= CALCADDR;
                     x_cnt     <= x_cnt + 1;
                  else
                     vramfetch <= IDLE;
                  end if;
               elsif (variant = "00" and cache_map_valid = '1' and cache_map_addr = VRAM_byteaddr(18 downto 2)) then
                  if (VRAM_byteaddr(1) = '0') then
                     tileentry <= cache_map_data(15 downto  0);
                  else
                     tileentry <= cache_map_data(31 downto 16);
                  end if;
                  vramfetch <= EVALTILE;
               elsif (variant /= "00" and cache_pix_valid = '1' and cache_pix_addr = VRAM_byteaddr(18 downto 2)) then
                  colordata_r <= cache_pix_color16;
                  palno_r     <= palno;
                  vramfetch   <= HANDOFF;
               else
                  VRAM_byteaddr_low <= VRAM_byteaddr(1 downto 0);
                  VRAM_addr_r       <= VRAM_byteaddr(18 downto 2);
                  VRAM_Drawer_req   <= '1';
                  if (variant = "00") then
                     vramfetch <= WAITREAD_TILE;
                  else
                     vramfetch <= WAITREAD_COLOR;
                  end if;
               end if;

            when WAITREAD_TILE =>
               if (VRAM_Drawer_done = '1') then
                  case (to_integer(VRAM_byteaddr_low(1 downto 0))) is
                     when 0 | 1  => tileentry <= VRAM_Drawer_data(15 downto  0);
                     when others => tileentry <= VRAM_Drawer_data(31 downto 16);
                  end case;
                  cache_map_addr  <= VRAM_addr_r;
                  cache_map_data  <= VRAM_Drawer_data;
                  cache_map_valid <= '1';
                  vramfetch  <= EVALTILE;
               end if;

            when EVALTILE =>
               -- tile pixel address is combinational from tileentry, which
               -- WAITREAD_TILE just loaded
               palno <= tileentry(15 downto 12);
               if (cache_pix_valid = '1' and cache_pix_addr = VRAM_byteaddr(18 downto 2)) then
                  colordata_r <= cache_pix_color16;
                  palno_r     <= tileentry(15 downto 12);
                  vramfetch   <= HANDOFF;
               else
                  VRAM_byteaddr_low <= VRAM_byteaddr(1 downto 0);
                  VRAM_addr_r       <= VRAM_byteaddr(18 downto 2);
                  VRAM_Drawer_req   <= '1';
                  vramfetch <= WAITREAD_COLOR;
               end if;

            when WAITREAD_COLOR =>
               if (VRAM_Drawer_done = '1') then
                  colordata_r     <= colordata16;
                  palno_r         <= palno;
                  cache_pix_addr  <= VRAM_addr_r;
                  cache_pix_data  <= VRAM_Drawer_data;
                  cache_pix_valid <= '1';
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
