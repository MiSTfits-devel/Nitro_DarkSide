-- NDS merge-stage line tests. Streams per-pixel layer data from
-- sim/tests/gpu_merge_vectors.hex (gen_gpu_merge.py golden model) through
-- nds_drawer_merge - config latched via a hblank pulse, then 256 pixels
-- with enable='1' - and compares the written output line pixel-exact
-- (15-bit color). Run: sim/run_gpu_merge.sh  (regenerate vectors first)

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.textio.all;

entity tb_gpu_merge is
   generic
   (
      VECFILE    : string := "sim/tests/gpu_merge_vectors.hex";
      TIMEOUT_MS : integer := 10
   );
end entity;

architecture sim of tb_gpu_merge is

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

   -- 1 count word + up to 16 cases x (16 + 7*256) words
   constant vectors : t_words(0 to 28944) := load_hex(VECFILE, 28945);

   signal ypos       : integer range 0 to 191 := 0;
   signal xpos       : integer range 0 to 255 := 0;
   signal enable     : std_logic := '0';
   signal hblank     : std_logic := '0';

   signal win0_on, win1_on, winobj_on : std_logic := '0';
   signal w0x1, w0x2, w0y1, w0y2 : unsigned(7 downto 0) := (others => '0');
   signal w1x1, w1x2, w1y1, w1y2 : unsigned(7 downto 0) := (others => '0');
   signal en_win0, en_win1, en_winobj, en_winout : std_logic_vector(5 downto 0) := (others => '0');
   signal effect     : unsigned(1 downto 0) := (others => '0');
   signal first_tgt  : std_logic_vector(5 downto 0) := (others => '0');
   signal second_tgt : std_logic_vector(5 downto 0) := (others => '0');
   signal prio_bg0, prio_bg1, prio_bg2, prio_bg3 : unsigned(1 downto 0) := (others => '0');
   signal eva, evb, bldy : unsigned(4 downto 0) := (others => '0');
   signal lena       : std_logic_vector(4 downto 0) := (others => '0');
   signal backdrop   : std_logic_vector(15 downto 0) := (others => '0');

   signal px_bg0, px_bg1, px_bg2, px_bg3 : std_logic_vector(15 downto 0) := (others => '0');
   signal px_obj     : std_logic_vector(23 downto 0) := (others => '0');
   signal objwnd     : std_logic := '0';

   signal out_data   : std_logic_vector(15 downto 0);
   signal out_x      : integer range 0 to 255;
   signal out_we     : std_logic;

   type t_line is array (0 to 255) of std_logic_vector(14 downto 0);
   signal linebuf    : t_line := (others => (others => '0'));

   signal tests_done : boolean := false;

begin

   clk <= not clk after 5 ns when not tests_done else '0';

   imerge : entity work.nds_drawer_merge
   port map
   (
      clk                  => clk,
      enable               => enable,
      hblank               => hblank,
      xpos                 => xpos,
      ypos                 => ypos,
      in_WND0_on           => win0_on,
      in_WND1_on           => win1_on,
      in_WNDOBJ_on         => winobj_on,
      in_WND0_X1           => w0x1,
      in_WND0_X2           => w0x2,
      in_WND0_Y1           => w0y1,
      in_WND0_Y2           => w0y2,
      in_WND1_X1           => w1x1,
      in_WND1_X2           => w1x2,
      in_WND1_Y1           => w1y1,
      in_WND1_Y2           => w1y2,
      in_enables_wnd0      => en_win0,
      in_enables_wnd1      => en_win1,
      in_enables_wndobj    => en_winobj,
      in_enables_wndout    => en_winout,
      in_special_effect_in => effect,
      in_effect_1st_bg0    => first_tgt(0),
      in_effect_1st_bg1    => first_tgt(1),
      in_effect_1st_bg2    => first_tgt(2),
      in_effect_1st_bg3    => first_tgt(3),
      in_effect_1st_obj    => first_tgt(4),
      in_effect_1st_BD     => first_tgt(5),
      in_effect_2nd_bg0    => second_tgt(0),
      in_effect_2nd_bg1    => second_tgt(1),
      in_effect_2nd_bg2    => second_tgt(2),
      in_effect_2nd_bg3    => second_tgt(3),
      in_effect_2nd_obj    => second_tgt(4),
      in_effect_2nd_BD     => second_tgt(5),
      in_Prio_BG0          => prio_bg0,
      in_Prio_BG1          => prio_bg1,
      in_Prio_BG2          => prio_bg2,
      in_Prio_BG3          => prio_bg3,
      in_EVA               => eva,
      in_EVB               => evb,
      in_BLDY              => bldy,
      in_ena_bg0           => lena(0),
      in_ena_bg1           => lena(1),
      in_ena_bg2           => lena(2),
      in_ena_bg3           => lena(3),
      in_ena_obj           => lena(4),
      pixeldata_bg0        => px_bg0,
      pixeldata_bg1        => px_bg1,
      pixeldata_bg2        => px_bg2,
      pixeldata_bg3        => px_bg3,
      pixeldata_obj        => px_obj,
      pixeldata_back       => backdrop,
      objwindow_in         => objwnd,
      pixeldata_out        => out_data,
      pixel_x              => out_x,
      pixel_y              => open,
      pixel_we             => out_we
   );

   p_collect : process (clk)
   begin
      if rising_edge(clk) then
         if (out_we = '1') then
            linebuf(out_x) <= out_data(14 downto 0);
         end if;
      end if;
   end process;

   p_drive : process
      variable ncases : integer;
      variable base   : integer;
      variable w      : std_logic_vector(31 downto 0);
      variable exp    : std_logic_vector(14 downto 0);
      variable nfail  : integer := 0;
   begin
      ncases := to_integer(unsigned(vectors(0)));
      report "running " & integer'image(ncases) & " cases" severity note;

      for c in 0 to ncases - 1 loop
         base := 1 + c * (16 + 7 * 256);

         ypos      <= to_integer(unsigned(vectors(base + 0)(7 downto 0)));
         w         := vectors(base + 1);
         win0_on   <= w(0);
         win1_on   <= w(1);
         winobj_on <= w(2);
         w         := vectors(base + 2);
         w0x1 <= unsigned(w(7 downto 0));  w0x2 <= unsigned(w(15 downto 8));
         w0y1 <= unsigned(w(23 downto 16)); w0y2 <= unsigned(w(31 downto 24));
         w         := vectors(base + 3);
         w1x1 <= unsigned(w(7 downto 0));  w1x2 <= unsigned(w(15 downto 8));
         w1y1 <= unsigned(w(23 downto 16)); w1y2 <= unsigned(w(31 downto 24));
         w         := vectors(base + 4);
         en_win0   <= w(5 downto 0);
         en_win1   <= w(11 downto 6);
         en_winobj <= w(17 downto 12);
         en_winout <= w(23 downto 18);
         w         := vectors(base + 5);
         effect     <= unsigned(w(1 downto 0));
         first_tgt  <= w(7 downto 2);
         second_tgt <= w(13 downto 8);
         w         := vectors(base + 6);
         prio_bg0 <= unsigned(w(1 downto 0));
         prio_bg1 <= unsigned(w(3 downto 2));
         prio_bg2 <= unsigned(w(5 downto 4));
         prio_bg3 <= unsigned(w(7 downto 6));
         w         := vectors(base + 7);
         eva  <= unsigned(w(4 downto 0));
         evb  <= unsigned(w(9 downto 5));
         bldy <= unsigned(w(14 downto 10));
         lena      <= vectors(base + 8)(4 downto 0);
         backdrop  <= '0' & vectors(base + 9)(14 downto 0);

         -- latch config (hblank) and let the y/EV prep settle
         wait until rising_edge(clk);
         hblank <= '1';
         wait until rising_edge(clk);
         hblank <= '0';
         for k in 1 to 4 loop wait until rising_edge(clk); end loop;

         -- stream the line
         for x in 0 to 255 loop
            xpos   <= x;
            px_bg0 <= vectors(base + 16 + 0 * 256 + x)(15 downto 0);
            px_bg1 <= vectors(base + 16 + 1 * 256 + x)(15 downto 0);
            px_bg2 <= vectors(base + 16 + 2 * 256 + x)(15 downto 0);
            px_bg3 <= vectors(base + 16 + 3 * 256 + x)(15 downto 0);
            px_obj <= vectors(base + 16 + 4 * 256 + x)(23 downto 0);
            objwnd <= vectors(base + 16 + 5 * 256 + x)(0);
            enable <= '1';
            wait until rising_edge(clk);
         end loop;
         enable <= '0';
         for k in 1 to 8 loop wait until rising_edge(clk); end loop;

         -- compare
         for x in 0 to 255 loop
            exp := vectors(base + 16 + 6 * 256 + x)(14 downto 0);
            if (linebuf(x) /= exp) then
               nfail := nfail + 1;
               report "case " & integer'image(c) & " x=" & integer'image(x) &
                      " expected=" & to_hstring(exp) & " got=" & to_hstring(linebuf(x))
                      severity error;
            end if;
         end loop;
         report "case " & integer'image(c) & " done" severity note;
      end loop;

      if (nfail = 0) then
         report "tb_gpu_merge: PASS  " & integer'image(ncases) & " cases" severity note;
      else
         report "tb_gpu_merge: FAIL  " & integer'image(nfail) & " pixel mismatches" severity failure;
      end if;
      tests_done <= true;
      wait;
   end process;

   p_watchdog : process
   begin
      wait for TIMEOUT_MS * 1 ms;
      if not tests_done then
         report "tb_gpu_merge: TIMEOUT" severity failure;
      end if;
      wait;
   end process;

end architecture;
