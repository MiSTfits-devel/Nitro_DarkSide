-- M5 part 2: NDS OBJ drawer line tests. Instantiates nds_drawer_obj against
-- behavioral OAM (registered 1-cycle read), 256 KB OBJ VRAM, std OBJ palette
-- and the 8 KB OBJ ext-pal store; VRAM/palettes served on the GBA drawer
-- cadence (address latched while valid='0', data + valid='1' next cycle).
-- Cases come from sim/tests/gpu_obj_vectors.hex (gen_gpu_obj.py golden
-- model): 8 header words + 256 OAM words + 256 expected color words +
-- 256 expected settings words per case. The drawer has no busy output;
-- each line is bounded by the pixeltime budget, so we wait a fixed 2600
-- cycles after drawline before comparing.
-- Run: sim/run_gpu_obj.sh  (regenerate vectors first)

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.textio.all;

entity tb_gpu_obj is
   generic
   (
      VRAMFILE   : string := "sim/tests/gpu_obj_vram.hex";
      PALFILE    : string := "sim/tests/gpu_obj_pal.hex";
      EXTPALFILE : string := "sim/tests/gpu_obj_extpal.hex";
      VECFILE    : string := "sim/tests/gpu_obj_vectors.hex";
      TIMEOUT_MS : integer := 10
   );
end entity;

architecture sim of tb_gpu_obj is

   signal clk : std_logic := '0';

   type t_words is array (natural range <>) of std_logic_vector(31 downto 0);

   impure function load_hex(fname : string; size : integer) return t_words is
      file f       : text;
      variable l   : line;
      variable w   : std_logic_vector(31 downto 0);
      variable mem : t_words(0 to size - 1) := (others => (others => '0'));
      variable i   : integer := 0;
   begin
      file_open(f, fname, read_mode);
      while not endfile(f) and i < size loop
         readline(f, l);
         hread(l, w);
         mem(i) := w;
         i := i + 1;
      end loop;
      file_close(f);
      report "loaded " & integer'image(i) & " words from " & fname severity note;
      return mem;
   end function;

   constant vram    : t_words(0 to 65535) := load_hex(VRAMFILE, 65536);
   constant pal     : t_words(0 to 127)   := load_hex(PALFILE, 128);
   constant extpal  : t_words(0 to 2047)  := load_hex(EXTPALFILE, 2048);
   -- 1 count word + up to 32 cases x 776 words
   constant vectors : t_words(0 to 24832) := load_hex(VECFILE, 24833);

   -- config
   signal ypos, ypos_mosaic : integer range 0 to 191 := 0;
   signal one_dim_mapping    : std_logic := '0';
   signal tile_boundary      : unsigned(1 downto 0) := "00";
   signal bitmap_1d          : std_logic := '0';
   signal bitmap_2d_wide     : std_logic := '0';
   signal bitmap_1d_boundary : std_logic := '0';
   signal obj_extpal         : std_logic := '0';
   signal mosaic_h           : unsigned(3 downto 0) := (others => '0');

   signal drawline : std_logic := '0';

   -- OAM: 128 sprites x 8 bytes = 256 words, registered read
   type t_oam is array (0 to 255) of std_logic_vector(31 downto 0);
   signal oam      : t_oam := (others => (others => '0'));
   signal oam_addr : integer range 0 to 255;
   signal oam_data : std_logic_vector(31 downto 0) := (others => '0');

   -- drawer memory ports
   signal o_pal_addr    : integer range 0 to 127;
   signal o_extpal_addr : integer range 0 to 2047;
   signal o_vram_addr   : integer range 0 to 65535;
   signal o_pal_data, o_extpal_data, o_vram_data : std_logic_vector(31 downto 0);

   signal mem_valid : std_logic := '0';

   -- pixel outputs
   signal pixel_we_color    : std_logic;
   signal pixeldata_color   : std_logic_vector(15 downto 0);
   signal pixel_we_settings : std_logic;
   signal pixeldata_settings : std_logic_vector(7 downto 0);
   signal pixel_x           : integer range 0 to 255;
   signal pixel_objwnd      : std_logic;

   type t_line16 is array (0 to 255) of std_logic_vector(15 downto 0);
   type t_line8  is array (0 to 255) of std_logic_vector(7 downto 0);
   signal linecol  : t_line16 := (others => (others => '0'));
   signal lineset  : t_line8  := (others => (others => '0'));
   signal set_wr   : std_logic_vector(255 downto 0) := (others => '0');
   signal ownd     : std_logic_vector(255 downto 0) := (others => '0');
   signal clear_line : std_logic := '0';

   signal tests_done : boolean := false;

begin

   clk <= not clk after 5 ns when not tests_done else '0';

   idrawer_obj : entity work.nds_drawer_obj
   port map
   (
      clk                  => clk,
      drawline             => drawline,
      ypos                 => ypos,
      ypos_mosaic          => ypos_mosaic,
      one_dim_mapping      => one_dim_mapping,
      tile_boundary        => tile_boundary,
      bitmap_1d            => bitmap_1d,
      bitmap_2d_wide       => bitmap_2d_wide,
      bitmap_1d_boundary   => bitmap_1d_boundary,
      obj_extpal           => obj_extpal,
      Mosaic_H_Size        => mosaic_h,
      hblankfree           => '0',
      pixel_we_color       => pixel_we_color,
      pixeldata_color      => pixeldata_color,
      pixel_we_settings    => pixel_we_settings,
      pixeldata_settings   => pixeldata_settings,
      pixel_x              => pixel_x,
      pixel_objwnd         => pixel_objwnd,
      OAMRAM_Drawer_addr   => oam_addr,
      OAMRAM_Drawer_data   => oam_data,
      PALETTE_Drawer_addr  => o_pal_addr,
      PALETTE_Drawer_data  => o_pal_data,
      EXTPAL_Drawer_addr   => o_extpal_addr,
      EXTPAL_Drawer_data   => o_extpal_data,
      VRAM_Drawer_addr     => o_vram_addr,
      VRAM_Drawer_data     => o_vram_data,
      VRAM_Drawer_valid    => mem_valid
   );

   -- OAM: plain registered read, data one cycle after address
   p_oam : process (clk)
   begin
      if rising_edge(clk) then
         oam_data <= oam(oam_addr);
      end if;
   end process;

   -- memory service: VRAM on the valid cadence (latch on the valid='0'
   -- edge, present next cycle); the palette/ext-pal ports have no valid
   -- handshake - the pipeline expects a plain 1-cycle registered read
   p_mem : process (clk)
   begin
      if rising_edge(clk) then
         if (mem_valid = '0') then
            o_vram_data <= vram(o_vram_addr);
         end if;
         mem_valid <= not mem_valid;
         o_pal_data    <= pal(o_pal_addr);
         o_extpal_data <= extpal(o_extpal_addr);
      end if;
   end process;

   -- pixel collect
   p_collect : process (clk)
   begin
      if rising_edge(clk) then
         if (clear_line = '1') then
            linecol <= (others => x"8000");
            lineset <= (others => x"00");
            set_wr  <= (others => '0');
            ownd    <= (others => '0');
         else
            if (pixel_we_color = '1') then
               linecol(pixel_x) <= pixeldata_color;
            end if;
            if (pixel_we_settings = '1') then
               lineset(pixel_x) <= pixeldata_settings;
               set_wr(pixel_x)  <= '1';
            end if;
            if (pixel_objwnd = '1') then
               ownd(pixel_x) <= '1';
            end if;
         end if;
      end if;
   end process;

   -- case driver
   p_drive : process
      variable ncases  : integer;
      variable base    : integer;
      variable flags   : std_logic_vector(31 downto 0);
      variable exp_c   : std_logic_vector(15 downto 0);
      variable exp_s   : std_logic_vector(31 downto 0);
      variable got_s   : std_logic_vector(31 downto 0);
      variable nfail   : integer := 0;
   begin
      ncases := to_integer(unsigned(vectors(0)));
      report "running " & integer'image(ncases) & " cases" severity note;

      for c in 0 to ncases - 1 loop
         base := 1 + c * 776;

         ypos        <= to_integer(unsigned(vectors(base + 0)));
         ypos_mosaic <= to_integer(unsigned(vectors(base + 1)));
         flags       := vectors(base + 2);
         one_dim_mapping    <= flags(0);
         bitmap_1d          <= flags(1);
         bitmap_2d_wide     <= flags(2);
         bitmap_1d_boundary <= flags(3);
         obj_extpal         <= flags(4);
         tile_boundary <= unsigned(vectors(base + 3)(1 downto 0));
         mosaic_h      <= unsigned(vectors(base + 4)(3 downto 0));

         for i in 0 to 255 loop
            oam(i) <= vectors(base + 8 + i);
         end loop;

         clear_line <= '1';
         wait until rising_edge(clk);
         wait until rising_edge(clk);
         clear_line <= '0';
         for k in 1 to 4 loop wait until rising_edge(clk); end loop;

         drawline <= '1';
         wait until rising_edge(clk);
         drawline <= '0';

         -- no busy port; the line is bounded by the pixeltime budget (2130)
         for k in 1 to 2600 loop wait until rising_edge(clk); end loop;

         for x in 0 to 255 loop
            exp_c := vectors(base + 264 + x)(15 downto 0);
            if (linecol(x) /= exp_c) then
               nfail := nfail + 1;
               report "case " & integer'image(c) & " x=" & integer'image(x) &
                      " color expected=" & to_hstring(exp_c) &
                      " got=" & to_hstring(linecol(x)) severity error;
            end if;
            exp_s := vectors(base + 520 + x);
            got_s := (others => '0');
            got_s(7 downto 0) := lineset(x);
            got_s(8)          := not set_wr(x);
            got_s(12)         := ownd(x);
            if (got_s /= exp_s) then
               nfail := nfail + 1;
               report "case " & integer'image(c) & " x=" & integer'image(x) &
                      " settings expected=" & to_hstring(exp_s) &
                      " got=" & to_hstring(got_s) severity error;
            end if;
         end loop;
         report "case " & integer'image(c) & " done" severity note;
      end loop;

      if (nfail = 0) then
         report "tb_gpu_obj: PASS  " & integer'image(ncases) & " cases" severity note;
      else
         report "tb_gpu_obj: FAIL  " & integer'image(nfail) & " mismatches" severity failure;
      end if;
      tests_done <= true;
      wait;
   end process;

   p_watchdog : process
   begin
      wait for TIMEOUT_MS * 1 ms;
      if not tests_done then
         report "tb_gpu_obj: TIMEOUT" severity failure;
      end if;
      wait;
   end process;

end architecture;
