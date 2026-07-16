-- SPDX-License-Identifier: GPL-2.0-or-later
-- M5: timed full-frame tests — nds_gpu_timing paces nds_gpu2d + nds_vram
-- with the real dot cadence and the frames must stay pixel-exact against
-- the same gen_gpu2d_frame.py golden as tb_gpu2d_frame. The GPU logic
-- runs every clk while the timing module is ce-paced at 1-of-CE_DIV,
-- modeling the planned MiSTer topology (GPU fabric at 100.5 MHz, dot
-- clock at 33.5 MHz, CE_DIV=3). A drawline that lands while the previous
-- line is still rendering is dropped by nds_gpu2d - the drop monitor
-- counts those (budget overruns) and any drop fails the run, so this TB
-- is also the line-budget measurement for the affine/extended fetch path.
--
-- Per case: configuration is written during vblank (after the last
-- visible line finished - the drawers read some registers live), the
-- ext-pal shadow refill runs off the timing module's own vblank_trigger,
-- OBJ line 0 pre-renders at line 262 with the new OAM, and the following
-- frame is collected and compared.
-- Run: sim/run_gpu2d_timed.sh  (regenerate vectors first)

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.textio.all;

use work.pProc_bus_gba.all;

entity tb_gpu2d_timed is
   generic
   (
      BANKFILE   : string := "sim/tests/gpu2d_banks.hex";
      VECFILE    : string := "sim/tests/gpu2d_vectors.hex";
      CE_DIV     : integer := 3;
      TIMEOUT_MS : integer := 600
   );
end entity;

architecture sim of tb_gpu2d_timed is

   signal clk    : std_logic := '0';
   signal reset  : std_logic := '1';
   signal treset : std_logic := '1';   -- timing module held while banks fill
   signal ce     : std_logic := '0';

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

   constant banks   : t_words(0 to 167935) := load_hex(BANKFILE, 167936);
   constant vectors : t_words(0 to 200703) := load_hex(VECFILE, 200704);

   constant CNT_FILL : std_logic_vector(71 downto 0) := x"00" & x"00008080" & x"00000000";
   constant CNT_TEST : std_logic_vector(71 downto 0) := x"00" & x"00008584" & x"89008281";

   signal vramcnt : std_logic_vector(71 downto 0) := CNT_FILL;

   -- nds_vram CPU port
   signal cpu9_ena, cpu9_rnw, cpu9_done : std_logic := '0';
   signal cpu9_addr : unsigned(23 downto 2) := (others => '0');
   signal cpu9_be   : std_logic_vector(3 downto 0) := (others => '0');
   signal cpu9_din, cpu9_dout : std_logic_vector(31 downto 0) := (others => '0');

   -- A..D backing channels
   signal srv_req, srv_rnw, srv_done : std_logic := '0';
   signal srv_bank : std_logic_vector(1 downto 0);
   signal srv_addr : unsigned(16 downto 2);
   signal srv_be   : std_logic_vector(3 downto 0);
   signal srv_din, srv_dout : std_logic_vector(31 downto 0) := (others => '0');
   signal rsrv_req, rsrv_done : std_logic := '0';
   signal rsrv_bank : std_logic_vector(1 downto 0);
   signal rsrv_addr : unsigned(16 downto 2);
   signal rsrv_dout : std_logic_vector(31 downto 0) := (others => '0');

   -- renderer channels between nds_vram and nds_gpu2d
   signal r_bg_req, r_bg_done       : std_logic;
   signal r_bg_addr                 : unsigned(18 downto 2);
   signal r_bg_dout                 : std_logic_vector(31 downto 0);
   signal r_obj_req, r_obj_done     : std_logic;
   signal r_obj_addr                : unsigned(17 downto 2);
   signal r_obj_dout                : std_logic_vector(31 downto 0);
   signal r_bgep_req, r_bgep_done   : std_logic;
   signal r_bgep_addr               : unsigned(14 downto 2);
   signal r_bgep_dout               : std_logic_vector(31 downto 0);
   signal r_objep_req, r_objep_done : std_logic;
   signal r_objep_addr              : unsigned(12 downto 2);
   signal r_objep_dout              : std_logic_vector(31 downto 0);

   signal g_bg_addr    : integer range 0 to 131071;
   signal g_obj_addr   : integer range 0 to 65535;
   signal g_bgep_addr  : integer range 0 to 8191;
   signal g_objep_addr : integer range 0 to 2047;

   -- shared register bus (gpu2d regs 0x000..0x05F + timing DISPSTAT 0x004)
   signal gb_bus  : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "10", "1111", '0');
   signal gb_bus7 : proc_bus_gb_type := ((others => '0'), (others => '1'), '1', '0', "10", "0000", '0');

   -- timing -> gpu2d line control
   signal linecounter     : integer range 0 to 191;
   signal linecounter_obj : integer range 0 to 191;
   signal drawline, drawObj, line_trigger, hblank_trigger, vblank_trigger, refpoint_update : std_logic;
   signal line_busy, epfill_busy : std_logic;
   signal vcount_out : unsigned(8 downto 0);

   signal pal_we, oam_we : std_logic := '0';
   signal pal_addr, oam_addr : integer range 0 to 255 := 0;
   signal pal_din, oam_din : std_logic_vector(31 downto 0) := (others => '0');

   signal pixel_out_x    : integer range 0 to 255;
   signal pixel_out_y    : integer range 0 to 191;
   signal pixel_out_data : std_logic_vector(14 downto 0);
   signal pixel_out_we   : std_logic;

   type t_frame is array (0 to 49151) of std_logic_vector(14 downto 0);
   signal framebuf : t_frame := (others => (others => '0'));

   signal drops      : integer := 0;   -- drawline pulses gpu2d had to drop
   signal tests_done : boolean := false;

begin

   clk <= not clk after 5 ns when not tests_done else '0';

   -- dot-clock pace for the timing module: 1 of CE_DIV clk ticks
   p_ce : process (clk)
      variable div : integer range 0 to CE_DIV - 1 := 0;
   begin
      if rising_edge(clk) then
         if (div = CE_DIV - 1) then
            div := 0;
            ce  <= '1';
         else
            div := div + 1;
            ce  <= '0';
         end if;
      end if;
   end process;

   itiming : entity work.nds_gpu_timing
   port map
   (
      clk             => clk,
      ce              => ce,
      reset           => treset,
      gb_bus9         => gb_bus,
      wired_out9      => open,
      wired_done9     => open,
      gb_bus7         => gb_bus7,
      wired_out7      => open,
      wired_done7     => open,
      irq9_vblank     => open,
      irq9_hblank     => open,
      irq9_vcount     => open,
      irq7_vblank     => open,
      irq7_hblank     => open,
      irq7_vcount     => open,
      linecounter     => linecounter,
      drawline        => drawline,
      linecounter_obj => linecounter_obj,
      drawObj         => drawObj,
      line_trigger    => line_trigger,
      hblank_trigger  => hblank_trigger,
      vblank_trigger  => vblank_trigger,
      refpoint_update => refpoint_update,
      vcount_out      => vcount_out
   );

   ivram : entity work.nds_vram
   generic map ( is_simu => '1' )
   port map
   (
      clk => clk, reset => reset, vramcnt => vramcnt,
      cpu9_ena => cpu9_ena, cpu9_rnw => cpu9_rnw, cpu9_addr => cpu9_addr,
      cpu9_be => cpu9_be, cpu9_din => cpu9_din, cpu9_dout => cpu9_dout, cpu9_done => cpu9_done,
      cpu7_ena => '0', cpu7_rnw => '1', cpu7_addr => (others => '0'),
      cpu7_be => (others => '0'), cpu7_din => (others => '0'),
      cpu7_dout => open, cpu7_done => open,
      srv_req => srv_req, srv_rnw => srv_rnw, srv_bank => srv_bank, srv_addr => srv_addr,
      srv_be => srv_be, srv_din => srv_din, srv_dout => srv_dout, srv_done => srv_done,
      rdr_bg_req => r_bg_req, rdr_bg_addr => r_bg_addr,
      rdr_bg_dout => r_bg_dout, rdr_bg_done => r_bg_done,
      rdr_obj_req => r_obj_req, rdr_obj_addr => r_obj_addr,
      rdr_obj_dout => r_obj_dout, rdr_obj_done => r_obj_done,
      rdr_bgep_req => r_bgep_req, rdr_bgep_addr => r_bgep_addr,
      rdr_bgep_dout => r_bgep_dout, rdr_bgep_done => r_bgep_done,
      rdr_objep_req => r_objep_req, rdr_objep_addr => r_objep_addr,
      rdr_objep_dout => r_objep_dout, rdr_objep_done => r_objep_done,
      rsrv_req => rsrv_req, rsrv_bank => rsrv_bank, rsrv_addr => rsrv_addr,
      rsrv_dout => rsrv_dout, rsrv_done => rsrv_done
   );

   r_bg_addr    <= to_unsigned(g_bg_addr, 17);
   r_obj_addr   <= to_unsigned(g_obj_addr, 16);
   r_bgep_addr  <= to_unsigned(g_bgep_addr, 13);
   r_objep_addr <= to_unsigned(g_objep_addr, 11);

   igpu : entity work.nds_gpu2d
   port map
   (
      clk => clk, reset => reset,
      gb_bus => gb_bus, wired_out => open, wired_done => open,
      linecounter => linecounter, drawline => drawline,
      linecounter_obj => linecounter_obj, drawObj => drawObj,
      line_trigger => line_trigger, hblank_trigger => hblank_trigger,
      vblank_trigger => vblank_trigger, refpoint_update => refpoint_update,
      line_busy => line_busy, epfill_busy => epfill_busy,
      pal_we => pal_we, pal_addr => pal_addr, pal_din => pal_din, pal_be => "1111",
      oam_we => oam_we, oam_addr => oam_addr, oam_din => oam_din, oam_be => "1111",
      srv_bg_req => r_bg_req, srv_bg_addr => g_bg_addr,
      srv_bg_data => r_bg_dout, srv_bg_done => r_bg_done,
      srv_obj_req => r_obj_req, srv_obj_addr => g_obj_addr,
      srv_obj_data => r_obj_dout, srv_obj_done => r_obj_done,
      srv_bgep_req => r_bgep_req, srv_bgep_addr => g_bgep_addr,
      srv_bgep_data => r_bgep_dout, srv_bgep_done => r_bgep_done,
      srv_objep_req => r_objep_req, srv_objep_addr => g_objep_addr,
      srv_objep_data => r_objep_dout, srv_objep_done => r_objep_done,
      pixel_out_x => pixel_out_x, pixel_out_y => pixel_out_y,
      pixel_out_data => pixel_out_data, pixel_out_we => pixel_out_we
   );

   -- behavioral A..D stores (read-only in this TB; content from BANKFILE)
   pserv : process
   begin
      wait until rising_edge(clk) and srv_req = '1';
      assert srv_rnw = '1' report "unexpected A..D CPU write" severity failure;
      wait until rising_edge(clk);
      srv_dout <= banks(to_integer(unsigned(srv_bank)) * 32768 + to_integer(srv_addr));
      srv_done <= '1';
      wait until rising_edge(clk);
      srv_done <= '0';
   end process;

   prserv : process
   begin
      wait until rising_edge(clk) and rsrv_req = '1';
      wait until rising_edge(clk);
      rsrv_dout <= banks(to_integer(unsigned(rsrv_bank)) * 32768 + to_integer(rsrv_addr));
      rsrv_done <= '1';
      wait until rising_edge(clk);
      rsrv_done <= '0';
   end process;

   -- pixel collect
   p_collect : process (clk)
   begin
      if rising_edge(clk) then
         if (pixel_out_we = '1') then
            framebuf(pixel_out_y * 256 + pixel_out_x) <= pixel_out_data;
         end if;
      end if;
   end process;

   -- budget monitor: a drawline arriving while the previous line is still
   -- rendering is silently dropped by nds_gpu2d - count and flag them
   p_drops : process (clk)
   begin
      if rising_edge(clk) then
         if (drawline = '1' and line_busy = '1') then
            drops <= drops + 1;
            report "tb_gpu2d_timed: line " & integer'image(linecounter) &
                   " drawline dropped (previous line still busy)" severity warning;
         end if;
      end if;
   end process;

   pmain : process
      variable nfail : integer := 0;
      file fdump     : text open write_mode is "gpu2d_timed_fb.txt";
      variable fdl   : line;

      procedure cpu9write(byteaddr : integer; data : std_logic_vector(31 downto 0)) is
      begin
         cpu9_addr <= to_unsigned(byteaddr, 24)(23 downto 2);
         cpu9_rnw  <= '0';
         cpu9_be   <= "1111";
         cpu9_din  <= data;
         cpu9_ena  <= '1';
         wait until rising_edge(clk);
         cpu9_ena  <= '0';
         wait until rising_edge(clk) and cpu9_done = '1';
      end procedure;

      procedure regwrite(offset : integer; data : std_logic_vector(31 downto 0)) is
      begin
         gb_bus.Adr  <= std_logic_vector(to_unsigned(offset, 28));
         gb_bus.Din  <= data;
         gb_bus.rnw  <= '0';
         gb_bus.ena  <= '1';
         wait until rising_edge(clk);
         gb_bus.ena  <= '0';
         gb_bus.rnw  <= '1';
         wait until rising_edge(clk);
      end procedure;

      procedure compare_frame(c : integer; pbase : integer) is
         variable exp : std_logic_vector(14 downto 0);
      begin
         for i in 0 to 49151 loop
            exp := vectors(pbase + i)(14 downto 0);
            if (framebuf(i) /= exp) then
               nfail := nfail + 1;
               if (nfail <= 32) then
                  report "case " & integer'image(c) & " y=" & integer'image(i / 256) &
                         " x=" & integer'image(i mod 256) &
                         " expected=" & to_hstring(exp) &
                         " got=" & to_hstring(framebuf(i)) severity error;
               end if;
            end if;
         end loop;
         write(fdl, "case " & integer'image(c));
         writeline(fdump, fdl);
         for i in 0 to 49151 loop
            write(fdl, to_hstring(framebuf(i)));
            writeline(fdump, fdl);
         end loop;
         report "case " & integer'image(c) & " done, fails so far " & integer'image(nfail) &
                ", drops so far " & integer'image(drops) severity note;
      end procedure;

      variable ncases, nregs, p : integer;
      type t_pb is array (0 to 15) of integer;
      variable pixbase : t_pb := (others => 0);
   begin
      for k in 1 to 4 loop wait until rising_edge(clk); end loop;
      reset <= '0';
      wait until rising_edge(clk);

      -- fill E (64 KB) and F (16 KB) via LCDC
      for w in 0 to 16383 loop
         cpu9write(16#880000# + w * 4, banks(131072 + w));
      end loop;
      for w in 0 to 4095 loop
         cpu9write(16#890000# + w * 4, banks(147456 + w));
      end loop;
      vramcnt <= CNT_TEST;
      wait until rising_edge(clk);
      report "bank fill done" severity note;

      -- release the timing module: the cadence free-runs from here
      treset <= '0';

      ncases := to_integer(unsigned(vectors(0)));
      p := 1;
      for c in 0 to ncases - 1 loop
         -- wait for vblank, then for the last visible line to finish
         -- (drawers read some registers live - no config writes mid-line)
         wait until rising_edge(clk) and vblank_trigger = '1';
         while line_busy = '1' loop
            wait until rising_edge(clk);
         end loop;

         -- previous case's frame is complete now
         if (c > 0) then
            compare_frame(c - 1, pixbase(c - 1));
         end if;

         -- program case c during vblank (ext-pal shadow refill runs
         -- concurrently off the same vblank_trigger; OBJ line 0
         -- pre-renders at line 262 with this OAM)
         nregs := to_integer(unsigned(vectors(p)));
         p := p + 1;
         for r in 0 to nregs - 1 loop
            regwrite(to_integer(unsigned(vectors(p))), vectors(p + 1));
            p := p + 2;
         end loop;
         for i in 0 to 255 loop
            pal_addr <= i;
            pal_din  <= vectors(p + i);
            pal_we   <= '1';
            wait until rising_edge(clk);
         end loop;
         pal_we <= '0';
         p := p + 256;
         for i in 0 to 255 loop
            oam_addr <= i;
            oam_din  <= vectors(p + i);
            oam_we   <= '1';
            wait until rising_edge(clk);
         end loop;
         oam_we <= '0';
         p := p + 256;
         pixbase(c) := p;
         p := p + 49152;
      end loop;

      -- last case's frame
      wait until rising_edge(clk) and vblank_trigger = '1';
      while line_busy = '1' loop
         wait until rising_edge(clk);
      end loop;
      compare_frame(ncases - 1, pixbase(ncases - 1));

      if (drops > 0) then
         report "tb_gpu2d_timed: " & integer'image(drops) &
                " dropped lines (render budget overrun at CE_DIV=" &
                integer'image(CE_DIV) & ")" severity error;
         nfail := nfail + drops;
      end if;

      if (nfail = 0) then
         report "tb_gpu2d_timed: PASS  " & integer'image(ncases) &
                " frames, 0 dropped lines (CE_DIV=" & integer'image(CE_DIV) & ")" severity note;
      else
         report "tb_gpu2d_timed: FAIL  " & integer'image(nfail) & " mismatches" severity failure;
      end if;
      tests_done <= true;
      wait;
   end process;

   p_watchdog : process
   begin
      wait for TIMEOUT_MS * 1 ms;
      if not tests_done then
         report "tb_gpu2d_timed: TIMEOUT" severity failure;
      end if;
      wait;
   end process;

end architecture;
