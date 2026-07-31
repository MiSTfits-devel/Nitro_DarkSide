-- M5: full-frame tests for the engine-A orchestrator. nds_gpu2d + nds_vram
-- wired together the way nds_top will: renderer channels to the line
-- server, behavioral srv/rsrv models backing banks A..D from
-- gpu2d_banks.hex, banks E/F filled through the CPU port in LCDC mode,
-- then the fixed test VRAMCNT (A=BG 0x00000, D=BG 0x20000, B=OBJ,
-- E=BG ext pal, F=OBJ ext pal). Per case from gpu2d_vectors.hex
-- (gen_gpu2d_frame.py golden): registers via gb_bus, palette/OAM via the
-- CPU write ports, one vblank (affine ref reload + ext-pal shadow fill),
-- then 192 lines of drawObj/hblank/line_trigger/drawline/refpoint_update
-- and a pixel-exact compare of the merged 256x192 frame.
-- Run: sim/run_gpu2d_frame.sh  (regenerate vectors first)

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.textio.all;

use work.pProc_bus_gba.all;

entity tb_gpu2d_frame is
   generic
   (
      BANKFILE   : string := "sim/tests/gpu2d_banks.hex";
      VECFILE    : string := "sim/tests/gpu2d_vectors.hex";
      TIMEOUT_MS : integer := 400;
      -- A..D renderer-feed latency in clk cycles (see prserv). 4 stands in for
      -- SDRAM; the old fixed behavioural model answered in 2.
      RSRV_LAT   : integer := 4
   );
end entity;

architecture sim of tb_gpu2d_frame is

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

   -- banks A..I concatenated; A..D served behaviorally, E/F CPU-filled
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
   signal rsrv_addr : unsigned(16 downto 3);
   signal rsrv_dout : std_logic_vector(63 downto 0) := (others => '0');

   -- in-order response delay line for the pipelined A..D model (see prserv)
   type t_rsrvpipe is record
      v : std_logic;
      d : std_logic_vector(63 downto 0);
   end record;
   type t_rsrvpipe_arr is array (0 to RSRV_LAT - 1) of t_rsrvpipe;
   signal rsrvpipe : t_rsrvpipe_arr := (others => ('0', (others => '0')));

   -- renderer channels between nds_vram and nds_gpu2d
   signal r_bg_accept               : std_logic;
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

   -- gpu2d control
   signal gb_bus          : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "10", "1111", '0');
   signal linecounter     : integer range 0 to 191 := 0;
   signal linecounter_obj : integer range 0 to 191 := 0;
   signal drawline, drawObj, line_trigger, hblank_trigger, vblank_trigger, refpoint_update : std_logic := '0';
   signal line_busy, epfill_busy : std_logic;

   signal pal_we, oam_we : std_logic := '0';
   signal pal_addr, oam_addr : integer range 0 to 255 := 0;
   signal pal_din, oam_din : std_logic_vector(31 downto 0) := (others => '0');

   signal pixel_out_x    : integer range 0 to 255;
   signal pixel_out_y    : integer range 0 to 191;
   signal pixel_out_data : std_logic_vector(17 downto 0);
   signal pixel_out_we   : std_logic;

   type t_frame is array (0 to 49151) of std_logic_vector(17 downto 0);
   signal framebuf : t_frame := (others => (others => '0'));

   signal tests_done : boolean := false;

   -- reset-clear handshakes (see the waits in pmain)
   signal vclr_busy : std_logic;
   signal pclr_busy : std_logic;

begin

   clk <= not clk after 5 ns when not tests_done else '0';

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
      clr_busy => vclr_busy,
      rdr_bg_req => r_bg_req, rdr_bg_addr => r_bg_addr,
      rdr_bg_dout => r_bg_dout, rdr_bg_done => r_bg_done,
      rdr_bg_accept => r_bg_accept,
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
   generic map ( is_simu => '1' )
   port map
   (
      clk => clk, reset => reset,
      gb_bus => gb_bus, wired_out => open, wired_done => open,
      linecounter => linecounter, drawline => drawline,
      linecounter_obj => linecounter_obj, drawObj => drawObj,
      line_trigger => line_trigger, hblank_trigger => hblank_trigger,
      vblank_trigger => vblank_trigger, refpoint_update => refpoint_update,
      line_busy => line_busy, epfill_busy => epfill_busy, clr_busy => pclr_busy,
      pal_we => pal_we, pal_addr => pal_addr, pal_din => pal_din, pal_be => "1111",
      oam_we => oam_we, oam_addr => oam_addr, oam_din => oam_din, oam_be => "1111",
      srv_bg_req => r_bg_req, srv_bg_addr => g_bg_addr,
      srv_bg_data => r_bg_dout, srv_bg_done => r_bg_done,
      srv_bg_accept => r_bg_accept,
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
      -- A..D is a read-only BANKFILE model here; the only writes it ever sees
      -- are nds_vram's reset clear pass, which it acknowledges and drops (the
      -- file content stands for what the game writes after the clear)
      assert srv_rnw = '1' or vclr_busy = '1' report "unexpected A..D CPU write" severity failure;
      wait until rising_edge(clk);
      srv_dout <= banks(to_integer(unsigned(srv_bank)) * 32768 + to_integer(srv_addr));
      srv_done <= '1';
      wait until rising_edge(clk);
      srv_done <= '0';
   end process;

   -- Renderer A..D feed: a PIPELINED model, one request accepted per cycle,
   -- answered in issue order RSRV_LAT+1 cycles later. The old model was
   -- one-op-at-a-time and answered in two cycles, which both understated the
   -- cost of this channel (on hardware it is SDRAM, tens of cycles) and made
   -- the renderer's outstanding-request behaviour untestable.
   prserv : process (clk)
   begin
      if rising_edge(clk) then
         for i in RSRV_LAT - 1 downto 1 loop
            rsrvpipe(i) <= rsrvpipe(i - 1);
         end loop;
         rsrvpipe(0).v <= '0';
         if (rsrv_req = '1') then
            rsrvpipe(0).v <= '1';
            -- 64-bit line: both words of the aligned 8-byte block
            rsrvpipe(0).d <= banks(to_integer(unsigned(rsrv_bank)) * 32768 +
                                   to_integer(rsrv_addr) * 2 + 1) &
                             banks(to_integer(unsigned(rsrv_bank)) * 32768 +
                                   to_integer(rsrv_addr) * 2);
         end if;
         rsrv_done <= rsrvpipe(RSRV_LAT - 1).v;
         rsrv_dout <= rsrvpipe(RSRV_LAT - 1).d;
      end if;
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

   pmain : process
      variable nfail : integer := 0;
      file fdump     : text open write_mode is "gpu2d_frame_fb.txt";
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

      variable ncases, nregs, p : integer;
      variable exp : std_logic_vector(17 downto 0);
      variable nz  : integer := 0;   -- clear-check non-zero pixel count
   begin
      for k in 1 to 4 loop wait until rising_edge(clk); end loop;
      reset <= '0';
      -- nds_vram / nds_gpu2d zero VRAM and palette/OAM out of reset; nds_top
      -- holds the CPUs until both clr_busy drop, so do the same here
      wait until rising_edge(clk) and vclr_busy = '0' and pclr_busy = '0';
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

      ncases := to_integer(unsigned(vectors(0)));
      p := 1;
      for c in 0 to ncases - 1 loop
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

         -- vblank: affine ref reload + ext-pal shadow refill
         vblank_trigger <= '1';
         wait until rising_edge(clk);
         vblank_trigger <= '0';
         wait until rising_edge(clk);
         while epfill_busy = '1' loop
            wait until rising_edge(clk);
         end loop;

         for y in 0 to 191 loop
            -- OBJ line y into the parity buffer
            linecounter_obj <= y;
            wait until rising_edge(clk);
            drawObj <= '1';
            wait until rising_edge(clk);
            drawObj <= '0';
            -- merge config latch + affine per-line latch, then draw
            linecounter <= y;
            hblank_trigger <= '1';
            wait until rising_edge(clk);
            hblank_trigger <= '0';
            line_trigger <= '1';
            wait until rising_edge(clk);
            line_trigger <= '0';
            wait until rising_edge(clk);
            drawline <= '1';
            wait until rising_edge(clk);
            drawline <= '0';
            wait until rising_edge(clk);
            while line_busy = '1' loop
               wait until rising_edge(clk);
            end loop;
            for k in 1 to 4 loop wait until rising_edge(clk); end loop;
            refpoint_update <= '1';
            wait until rising_edge(clk);
            refpoint_update <= '0';
            wait until rising_edge(clk);
         end loop;

         -- compare frame
         for i in 0 to 49151 loop
            exp := vectors(p + i)(17 downto 0);
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
         p := p + 49152;
         -- full framebuffer dump for offline diffing
         write(fdl, "case " & integer'image(c));
         writeline(fdump, fdl);
         for i in 0 to 49151 loop
            write(fdl, to_hstring("00" & framebuf(i)));
            writeline(fdump, fdl);
         end loop;
         report "case " & integer'image(c) & " done, fails so far " & integer'image(nfail) severity note;
      end loop;

      -- ============ reset-clear check (palette / OAM / VRAM BRAM) ============
      -- The reported hardware bug is visual: load another ROM and the previous
      -- game's graphics stay on screen, because a MiSTer ROM change does not
      -- reconfigure the FPGA. So test it the way it shows up - render the SAME
      -- scene twice, once with the previous case's palette / OAM / bank data
      -- still in place and once after a reset, and require the second render to
      -- be entirely black.
      --
      -- Deliberately NOT the golden case's config: this uses a minimal one whose
      -- every other register is at its reset value (so no brightness or blend
      -- term can manufacture a non-zero pixel out of zeroed memory), and maps
      -- only the two CPU-writable BRAM banks - E as main BG, F as main OBJ - so
      -- the pixels depend on exactly the three stores under test. Banks A..D are
      -- a read-only BANKFILE model here and are covered by tb_vram_torture's
      -- direct read-back instead.
      --
      -- The first render's non-zero assertion is what stops this passing
      -- vacuously: sim memories start at zero, so a check that only looked for
      -- zeros would pass with no clear pass at all.
      vramcnt <= x"000" & x"000" & x"82" & x"81" & x"00000000";   -- E=BG, F=OBJ
      wait until rising_edge(clk);

      for pass in 0 to 1 loop
         if (pass = 1) then
            -- clear: palette/OAM zero while reset is asserted, VRAM zeroes once
            -- it releases; nds_top's boot FSM gates the CPU release on both
            -- gb_bus.rst too: the display register file resets off the proc-bus
            -- reset, not off `reset`, and in the real core nds_membus9 drives it
            -- from resetCpu. Without it MASTER_BRIGHT survives the reset here and
            -- turns cleared black into a uniform grey.
            reset      <= '1';
            gb_bus.rst <= '1';
            for k in 1 to 4 loop wait until rising_edge(clk); end loop;
            gb_bus.rst <= '0';
            reset      <= '0';
            wait until rising_edge(clk) and vclr_busy = '0' and pclr_busy = '0';
            wait until rising_edge(clk);
            vramcnt <= x"000" & x"000" & x"82" & x"81" & x"00000000";
            wait until rising_edge(clk);
         end if;

         -- display mode 1, BG mode 0, BG0 + OBJ on, no ext palettes
         regwrite(16#000#, x"00011100");
         -- BG0CNT: 256-colour text, char base 0, screen base 0
         regwrite(16#008#, x"00000080");

         vblank_trigger <= '1';
         wait until rising_edge(clk);
         vblank_trigger <= '0';
         wait until rising_edge(clk);
         while epfill_busy = '1' loop
            wait until rising_edge(clk);
         end loop;

         for y in 0 to 191 loop
            linecounter_obj <= y;
            wait until rising_edge(clk);
            drawObj <= '1';
            wait until rising_edge(clk);
            drawObj <= '0';
            linecounter <= y;
            hblank_trigger <= '1';
            wait until rising_edge(clk);
            hblank_trigger <= '0';
            line_trigger <= '1';
            wait until rising_edge(clk);
            line_trigger <= '0';
            wait until rising_edge(clk);
            drawline <= '1';
            wait until rising_edge(clk);
            drawline <= '0';
            wait until rising_edge(clk);
            while line_busy = '1' loop
               wait until rising_edge(clk);
            end loop;
            for k in 1 to 4 loop wait until rising_edge(clk); end loop;
            refpoint_update <= '1';
            wait until rising_edge(clk);
            refpoint_update <= '0';
            wait until rising_edge(clk);
         end loop;

         nz := 0;
         for i in 0 to 49151 loop
            if (framebuf(i) /= "00" & x"0000") then nz := nz + 1; end if;
         end loop;

         if (pass = 0) then
            report "clear-check: pre-dirty render has " & integer'image(nz) &
                   " non-zero pixels" severity note;
            assert nz > 0
               report "clear-check is vacuous: the pre-dirty render is already " &
                      "all black, so the post-reset check would prove nothing"
               severity failure;
         else
            report "clear-check: post-reset render has " & integer'image(nz) &
                   " non-zero pixels" severity note;
            if (nz /= 0) then
               nfail := nfail + 1;
               for i in 0 to 49151 loop
                  if (framebuf(i) /= "00" & x"0000") then
                     report "palette/OAM/VRAM not cleared on reset: y=" &
                            integer'image(i / 256) & " x=" & integer'image(i mod 256) &
                            " reads " & to_hstring(framebuf(i)) severity error;
                     exit;
                  end if;
               end loop;
               report "tb_gpu2d_frame: FAIL  reset clear pass left " &
                      integer'image(nz) & " non-black pixels" severity failure;
            end if;
         end if;
      end loop;

      if (nfail = 0) then
         report "tb_gpu2d_frame: PASS  " & integer'image(ncases) &
                " frames + reset-clear check" severity note;
      else
         report "tb_gpu2d_frame: FAIL  " & integer'image(nfail) & " pixel mismatches" severity failure;
      end if;
      tests_done <= true;
      wait;
   end process;

   p_watchdog : process
   begin
      wait for TIMEOUT_MS * 1 ms;
      if not tests_done then
         report "drawers at timeout: y=" & to_string(<< signal .tb_gpu2d_frame.igpu.cur_y : integer range 0 to 191 >>) &
                " text=" & to_string(<< signal .tb_gpu2d_frame.igpu.busy_text : std_logic_vector(0 to 3) >>) &
                " aff23=" & to_string(<< signal .tb_gpu2d_frame.igpu.busy_aff : std_logic_vector(2 to 3) >>) &
                " ext23=" & to_string(<< signal .tb_gpu2d_frame.igpu.busy_ext : std_logic_vector(2 to 3) >>) &
                " obj=" & to_string(<< signal .tb_gpu2d_frame.igpu.obj_busy : std_logic >>) &
                " arb_pending=" & to_string(<< signal .tb_gpu2d_frame.igpu.b_arb.pending : std_logic_vector(0 to 3) >>) &
                " arb_sel=" & to_string(<< signal .tb_gpu2d_frame.igpu.b_arb.arb_sel : integer range 0 to 3 >>) &
                " arb_busy=" & to_string(<< signal .tb_gpu2d_frame.igpu.b_arb.arb_busy : std_logic >>) &
                " vram_rpend=" & to_string(<< signal .tb_gpu2d_frame.ivram.rpend : std_logic_vector(3 downto 0) >>) &
                " bgv_req=" & to_string(<< signal .tb_gpu2d_frame.igpu.bgv_req : std_logic_vector(0 to 3) >>) &
                " bgv_done=" & to_string(<< signal .tb_gpu2d_frame.igpu.bgv_done : std_logic_vector(0 to 3) >>) &
                " v_req_aff=" & to_string(<< signal .tb_gpu2d_frame.igpu.v_req_aff : std_logic_vector(2 to 3) >>)
            severity note;
         report "state at timeout: epfill_busy=" & to_string(epfill_busy) &
                " line_busy=" & to_string(line_busy) &
                " bg(req=" & to_string(r_bg_req) & ",done=" & to_string(r_bg_done) &
                ") obj(req=" & to_string(r_obj_req) & ",done=" & to_string(r_obj_done) &
                ") bgep(req=" & to_string(r_bgep_req) & ",done=" & to_string(r_bgep_done) &
                ") objep(req=" & to_string(r_objep_req) & ",done=" & to_string(r_objep_done) &
                ") srv_req=" & to_string(srv_req) & " rsrv_req=" & to_string(rsrv_req)
            severity note;
         report "tb_gpu2d_frame: TIMEOUT" severity failure;
      end if;
      wait;
   end process;

end architecture;
