-- nds_gpu2d frame tests: the full engine A - registers written over the
-- proc bus, palettes/OAM through the CPU write ports, VRAM served on the
-- four line-server channels (behavioral arrays, randomized latency) - runs
-- whole frames against the gen_gpu2d.py golden compositor.
--
-- Frame sequence per frame: program registers, vblank_trigger (affine
-- reload + ext-pal shadow fill), pre-render OBJ line 0, then per line:
-- line_trigger, drawline(N) + drawObj(N+1), wait line_busy, hblank +
-- refpoint_update. Pixels land in a 256x192 framebuffer, compared at
-- frame end. Run: sim/run_gpu2d.sh  (regenerate vectors first)

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.textio.all;

use work.pProc_bus_gba.all;

entity tb_gpu2d is
   generic
   (
      BGVRAMFILE  : string := "sim/tests/gpu2d_bgvram.hex";
      OBJVRAMFILE : string := "sim/tests/gpu2d_objvram.hex";
      BGEPFILE    : string := "sim/tests/gpu2d_bgep.hex";
      OBJEPFILE   : string := "sim/tests/gpu2d_objep.hex";
      PALFILE     : string := "sim/tests/gpu2d_pal.hex";
      OAMFILE     : string := "sim/tests/gpu2d_oam.hex";
      FRAMEFILE   : string := "sim/tests/gpu2d_frames.hex";
      TIMEOUT_MS  : integer := 200;
      DBGLINE     : integer := -1   -- >=0: dump merge input stream for that line of frame 0, then stop
   );
end entity;

architecture sim of tb_gpu2d is

   signal clk   : std_logic := '0';
   signal reset : std_logic := '1';

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

   constant bgvram  : t_words(0 to 131071) := load_hex(BGVRAMFILE, 131072);
   constant objvram : t_words(0 to 65535)  := load_hex(OBJVRAMFILE, 65536);
   constant bgep    : t_words(0 to 8191)   := load_hex(BGEPFILE, 8192);
   constant objep   : t_words(0 to 2047)   := load_hex(OBJEPFILE, 2048);
   constant palinit : t_words(0 to 255)    := load_hex(PALFILE, 256);
   constant oaminit : t_words(0 to 255)    := load_hex(OAMFILE, 256);

   signal gb_bus : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "10", "0000", '0');

   signal linecounter, linecounter_obj : integer range 0 to 191 := 0;
   signal drawline, drawObj, line_trigger, hblank_trigger, vblank_trigger, refpoint_update : std_logic := '0';
   signal line_busy : std_logic;
   signal clr_busy  : std_logic;   -- palette/OAM reset-clear handshake

   signal pal_we, oam_we : std_logic := '0';
   signal pal_addr, oam_addr : integer range 0 to 255 := 0;
   signal pal_din, oam_din : std_logic_vector(31 downto 0) := (others => '0');

   signal srv_bg_accept             : std_logic := '0';
   signal srv_bg_req, srv_bg_done   : std_logic := '0';
   -- in-order response delay line for the pipelined BG model (see p_srv_bg)
   constant BGSRV_LAT : integer := 3;
   type t_bgpipe is record
      v : std_logic;
      d : std_logic_vector(31 downto 0);
   end record;
   type t_bgpipe_arr is array (0 to BGSRV_LAT - 1) of t_bgpipe;
   signal bgpipe : t_bgpipe_arr := (others => ('0', (others => '0')));
   signal srv_bg_addr   : integer range 0 to 131071;
   signal srv_bg_data   : std_logic_vector(31 downto 0);
   signal srv_obj_req, srv_obj_done : std_logic := '0';
   signal srv_obj_accept            : std_logic := '0';
   signal srv_obj_addr  : integer range 0 to 65535;
   signal srv_obj_data  : std_logic_vector(31 downto 0);
   constant OBJSRV_LAT : integer := 3;
   type t_objpipe_arr is array (0 to OBJSRV_LAT - 1) of t_bgpipe;
   signal objpipe : t_objpipe_arr := (others => ('0', (others => '0')));
   signal srv_bgep_req, srv_bgep_done : std_logic := '0';
   signal srv_bgep_addr : integer range 0 to 8191;
   signal srv_bgep_data : std_logic_vector(31 downto 0);
   signal srv_objep_req, srv_objep_done : std_logic := '0';
   signal srv_objep_addr : integer range 0 to 2047;
   signal srv_objep_data : std_logic_vector(31 downto 0);

   signal px_x : integer range 0 to 255;
   signal px_y : integer range 0 to 191;
   signal px_d : std_logic_vector(17 downto 0);
   signal px_we : std_logic;

   type t_fb is array (0 to 49151) of std_logic_vector(17 downto 0);
   signal fb : t_fb := (others => (others => '1'));

   signal tests_done : boolean := false;

begin

   clk <= not clk after 5 ns when not tests_done else '0';

   igpu : entity work.nds_gpu2d
   generic map ( is_simu => '1' )
   port map
   (
      clk             => clk,
      reset           => reset,
      gb_bus          => gb_bus,
      wired_out       => open,
      wired_done      => open,
      linecounter     => linecounter,
      drawline        => drawline,
      linecounter_obj => linecounter_obj,
      drawObj         => drawObj,
      line_trigger    => line_trigger,
      hblank_trigger  => hblank_trigger,
      vblank_trigger  => vblank_trigger,
      refpoint_update => refpoint_update,
      line_busy       => line_busy,
      clr_busy        => clr_busy,
      pal_we          => pal_we,
      pal_addr        => pal_addr,
      pal_din         => pal_din,
      pal_be          => "1111",
      oam_we          => oam_we,
      oam_addr        => oam_addr,
      oam_din         => oam_din,
      oam_be          => "1111",
      srv_bg_req      => srv_bg_req,
      srv_bg_addr     => srv_bg_addr,
      srv_bg_data     => srv_bg_data,
      srv_bg_done     => srv_bg_done,
      srv_bg_accept   => srv_bg_accept,
      srv_obj_req     => srv_obj_req,
      srv_obj_addr    => srv_obj_addr,
      srv_obj_data    => srv_obj_data,
      srv_obj_done    => srv_obj_done,
      srv_obj_accept  => srv_obj_accept,
      srv_bgep_req    => srv_bgep_req,
      srv_bgep_addr   => srv_bgep_addr,
      srv_bgep_data   => srv_bgep_data,
      srv_bgep_done   => srv_bgep_done,
      srv_objep_req   => srv_objep_req,
      srv_objep_addr  => srv_objep_addr,
      srv_objep_data  => srv_objep_data,
      srv_objep_done  => srv_objep_done,
      pixel_out_x     => px_x,
      pixel_out_y     => px_y,
      pixel_out_data  => px_d,
      pixel_out_we    => px_we
   );

   -- ================= channel servers =================
   -- BG: pipelined, one request accepted per cycle, answered in issue order
   -- BGSRV_LAT+1 cycles later. gpu2d's arbiter may keep several BG fetches in
   -- flight (that is what lets the drawers prefetch), so a blocking
   -- one-at-a-time model would silently drop requests here.
   srv_bg_accept <= srv_bg_req;

   p_srv_bg : process (clk)
   begin
      if rising_edge(clk) then
         for k in BGSRV_LAT - 1 downto 1 loop
            bgpipe(k) <= bgpipe(k - 1);
         end loop;
         bgpipe(0).v <= '0';
         if (srv_bg_req = '1') then
            bgpipe(0).v <= '1';
            bgpipe(0).d <= bgvram(srv_bg_addr);
         end if;
         srv_bg_done <= bgpipe(BGSRV_LAT - 1).v;
         srv_bg_data <= bgpipe(BGSRV_LAT - 1).d;
      end if;
   end process;

   -- OBJ, same shape as p_srv_bg above and for the same reason: the drawer
   -- now keeps several requests in flight, and the one-at-a-time process this
   -- replaces would have silently dropped every request that arrived while it
   -- was sleeping - and answered from whatever address the drawer had moved
   -- on to by the time it woke.
   srv_obj_accept <= srv_obj_req;

   p_srv_obj : process (clk)
   begin
      if rising_edge(clk) then
         for k in OBJSRV_LAT - 1 downto 1 loop
            objpipe(k) <= objpipe(k - 1);
         end loop;
         objpipe(0).v <= '0';
         if (srv_obj_req = '1') then
            objpipe(0).v <= '1';
            objpipe(0).d <= objvram(srv_obj_addr);
         end if;
         srv_obj_done <= objpipe(OBJSRV_LAT - 1).v;
         srv_obj_data <= objpipe(OBJSRV_LAT - 1).d;
      end if;
   end process;

   p_srv_bgep : process
   begin
      wait until rising_edge(clk) and srv_bgep_req = '1';
      srv_bgep_data <= bgep(srv_bgep_addr);
      srv_bgep_done <= '1';
      wait until rising_edge(clk);
      srv_bgep_done <= '0';
   end process;

   p_srv_objep : process
   begin
      wait until rising_edge(clk) and srv_objep_req = '1';
      srv_objep_data <= objep(srv_objep_addr);
      srv_objep_done <= '1';
      wait until rising_edge(clk);
      srv_objep_done <= '0';
   end process;

   -- ================= framebuffer =================
   p_fb : process (clk)
   begin
      if rising_edge(clk) then
         if (px_we = '1') then
            fb(px_y * 256 + px_x) <= px_d;
         end if;
      end if;
   end process;

   -- ================= driver =================
   p_drive : process
      file ff          : text;
      variable fl      : line;
      variable fw      : std_logic_vector(31 downto 0);
      variable nframes : integer;
      variable exp     : std_logic_vector(17 downto 0);
      variable nfail   : integer := 0;
      variable regw    : t_words(0 to 31);

      impure function next_word return std_logic_vector is
         variable l : line;
         variable w : std_logic_vector(31 downto 0);
      begin
         readline(ff, l);
         hread(l, w);
         return w;
      end function;

      procedure regwrite(a : integer; d : std_logic_vector(31 downto 0)) is
      begin
         gb_bus.Adr  <= std_logic_vector(to_unsigned(a, 28));
         gb_bus.Din  <= d;
         gb_bus.rnw  <= '0';
         gb_bus.bEna <= "1111";
         gb_bus.ena  <= '1';
         wait until rising_edge(clk);
         gb_bus.ena  <= '0';
         gb_bus.rnw  <= '1';
         wait until rising_edge(clk);
      end procedure;
   begin
      file_open(ff, FRAMEFILE, read_mode);
      nframes := to_integer(unsigned(next_word));
      report "running " & integer'image(nframes) & " frames" severity note;

      for k in 1 to 8 loop wait until rising_edge(clk); end loop;
      -- nds_gpu2d zeroes palette/OAM out of reset (it runs the pass WHILE reset
      -- is asserted, since reset here is nds_top's resetCpu); nds_top holds the
      -- CPUs until clr_busy drops, so wait for it before writing anything
      wait until rising_edge(clk) and clr_busy = '0';
      reset <= '0';
      wait until rising_edge(clk);

      -- palettes + OAM
      for i in 0 to 255 loop
         pal_we   <= '1';
         pal_addr <= i;
         pal_din  <= palinit(i);
         oam_we   <= '1';
         oam_addr <= i;
         oam_din  <= oaminit(i);
         wait until rising_edge(clk);
      end loop;
      pal_we <= '0';
      oam_we <= '0';

      for f in 0 to nframes - 1 loop
         for w in 0 to 31 loop
            regw(w) := next_word;
         end loop;

         -- program registers (word addresses 0x000..0x054)
         for w in 0 to 21 loop
            regwrite(w * 4, regw(w));
         end loop;

         -- vblank: affine reload + ext-pal shadow fill (10240 reads)
         vblank_trigger <= '1';
         wait until rising_edge(clk);
         vblank_trigger <= '0';
         for k in 1 to 34000 loop wait until rising_edge(clk); end loop;

         -- pre-render OBJ line 0
         linecounter_obj <= 0;
         drawObj <= '1';
         wait until rising_edge(clk);
         drawObj <= '0';
         for k in 1 to 12000 loop wait until rising_edge(clk); end loop;

         -- latch merge config before the first line
         hblank_trigger <= '1';
         wait until rising_edge(clk);
         hblank_trigger <= '0';
         wait until rising_edge(clk);

         for y in 0 to 191 loop
            linecounter <= y;
            line_trigger <= '1';
            wait until rising_edge(clk);
            line_trigger <= '0';
            wait until rising_edge(clk);

            drawline <= '1';
            if (y < 191) then
               linecounter_obj <= y + 1;
               drawObj <= '1';
            end if;
            wait until rising_edge(clk);
            drawline <= '0';
            drawObj  <= '0';

            wait until rising_edge(clk) and line_busy = '0';
            for k in 1 to 8 loop wait until rising_edge(clk); end loop;

            refpoint_update <= '1';
            wait until rising_edge(clk);
            refpoint_update <= '0';
            hblank_trigger  <= '1';
            wait until rising_edge(clk);
            hblank_trigger  <= '0';
            wait until rising_edge(clk);
         end loop;

         -- compare the frame
         for y in 0 to 191 loop
            for x in 0 to 255 loop
               fw  := next_word;
               exp := fw(17 downto 0);
               if (fb(y * 256 + x) /= exp) then
                  nfail := nfail + 1;
                  if (nfail <= 100) then
                     report "frame " & integer'image(f) & " y=" & integer'image(y) &
                            " x=" & integer'image(x) & " expected=" & to_hstring(exp) &
                            " got=" & to_hstring(fb(y * 256 + x)) severity error;
                  end if;
               end if;
            end loop;
         end loop;
         report "frame " & integer'image(f) & " done" severity note;
      end loop;

      if (nfail = 0) then
         report "tb_gpu2d: PASS  " & integer'image(nframes) & " frames" severity note;
      else
         report "tb_gpu2d: FAIL  " & integer'image(nfail) & " pixel mismatches" severity failure;
      end if;
      tests_done <= true;
      wait;
   end process;

   -- debug: mirror the merge input stream (as the merge samples it) for one line
   g_dbg : if DBGLINE >= 0 generate
      p_dbg : process (clk)
         file df       : text open write_mode is "gpu2d_dbg_line.txt";
         variable dl   : line;
         variable seen : integer := 0;
         alias a_ena  is << signal .tb_gpu2d.igpu.merge_ena  : std_logic >>;
         alias a_xpos is << signal .tb_gpu2d.igpu.merge_xpos : integer range 0 to 255 >>;
         alias a_cury is << signal .tb_gpu2d.igpu.cur_y      : integer range 0 to 191 >>;
         alias a_bg0  is << signal .tb_gpu2d.igpu.mrg_bg0    : std_logic_vector(15 downto 0) >>;
         alias a_bg1  is << signal .tb_gpu2d.igpu.mrg_bg1    : std_logic_vector(15 downto 0) >>;
         alias a_bg2  is << signal .tb_gpu2d.igpu.mrg_bg2    : std_logic_vector(15 downto 0) >>;
         alias a_bg3  is << signal .tb_gpu2d.igpu.mrg_bg3    : std_logic_vector(15 downto 0) >>;
         alias a_obj  is << signal .tb_gpu2d.igpu.mrg_obj    : std_logic_vector(23 downto 0) >>;
      begin
         if rising_edge(clk) then
            if (a_ena = '1' and a_cury = DBGLINE) then
               write(dl, integer'image(a_xpos) & " " & to_hstring(a_bg0) & " " &
                     to_hstring(a_bg1) & " " & to_hstring(a_bg2) & " " &
                     to_hstring(a_bg3) & " " & to_hstring(a_obj));
               writeline(df, dl);
               seen := seen + 1;
               if (seen = 256) then
                  file_close(df);
                  report "tb_gpu2d: DBGLINE dump complete" severity failure;
               end if;
            end if;
         end if;
      end process;
   end generate;

   p_watchdog : process
   begin
      wait for TIMEOUT_MS * 1 ms;
      if not tests_done then
         report "tb_gpu2d: TIMEOUT" severity failure;
      end if;
      wait;
   end process;

end architecture;
