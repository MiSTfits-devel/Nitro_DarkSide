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
      TIMEOUT_MS : integer := 600;
      -- A..D renderer-feed latency in clk cycles (see prserv). 4 stands in for
      -- SDRAM; the old fixed behavioural model answered in 2.
      RSRV_LAT   : integer := 4;
      -- 1 = model the hardware channel: exactly ONE A..D read in flight, ready
      -- low from acceptance until done (NDS.sv's `~vr_busy & ~vr_fin`). The
      -- default (unlimited in flight, ready tied high) is a memory that cannot
      -- say no, which is why every bench passed while silicon white-screened.
      RSRV_ONE   : integer := 0;
      --   RSRV_OUT : max ops outstanding (0 = unlimited). NDS.sv allows 2, which
      --              is what sdram.sv's ch1 can hold: one awaiting grant plus one
      --              in service.
      --   RSRV_GAP : minimum clk cycles between accepts, i.e. the channel's
      --              THROUGHPUT rather than its latency. The ch1 slot is 8 clkMem
      --              cycles (grant, WAIT, RW1, IDLE_5..IDLE): 2.67 clk1x at 3x,
      --              2.00 at 4x. Latency alone cannot answer what a clkMem
      --              overclock buys - a channel that is throughput-bound barely
      --              moves when only RSRV_LAT drops. Mirrors tb_top_frame.
      --              NOTE 3x rounds UP to 3, so a 3-vs-2 comparison FLATTERS 4x
      --              by ~12%; the true 3x gap is 2.67.
      RSRV_OUT   : integer := 0;
      RSRV_GAP   : integer := 0;
      -- >0: fail if one line render stays busy this many clk cycles. A line is
      -- 2,130 cycles at CE_DIV=3; anything past a few thousand is a wedge, not
      -- slowness, and the probe dumps who is waiting on whom.
      STALL_CYC  : integer := 0
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
   signal rsrv_addr : unsigned(16 downto 3);
   signal rsrv_dout : std_logic_vector(63 downto 0) := (others => '0');

   -- in-order response delay line for the pipelined A..D model (see prserv)
   type t_rsrvpipe is record
      v : std_logic;
      d : std_logic_vector(63 downto 0);
   end record;
   type t_rsrvpipe_arr is array (0 to RSRV_LAT - 1) of t_rsrvpipe;
   signal rsrvpipe : t_rsrvpipe_arr := (others => ('0', (others => '0')));
   -- RSRV_ONE: hardware-shaped backpressure (one op in flight) + the valid/ready
   -- protocol checker. A request this model does not take must still be on the
   -- wire, unchanged, at the next edge; a requester that pulses and forgets
   -- fails here instead of wedging thousands of cycles later.
   signal rsrv_busy_m  : std_logic := '0';
   signal rsrv_out_m   : integer range 0 to 15 := 0;
   signal rsrv_gap_m   : integer range 0 to 15 := 0;
   signal rsrv_ready_s : std_logic;
   signal rsrv_held      : std_logic := '0';
   signal rsrv_held_bank : std_logic_vector(1 downto 0) := "00";
   signal rsrv_held_addr : unsigned(16 downto 3) := (others => '0');

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
   signal pixel_out_data : std_logic_vector(17 downto 0);
   signal pixel_out_we   : std_logic;

   type t_frame is array (0 to 49151) of std_logic_vector(17 downto 0);
   signal framebuf : t_frame := (others => (others => '0'));

   signal drops      : integer := 0;   -- drawline pulses gpu2d had to drop
   signal tests_done : boolean := false;

   -- Render-throughput measurement. The drop count alone only says "over
   -- budget", not by how much, so it cannot size a pipelining change. These
   -- are `line_busy` occupancy (the same basis as the 5,829 / 3,255
   -- cycles-per-line figures in HANDOFF.md) and are therefore comparable
   -- across configurations: cycles/line = busy_cycles / lines_rendered.
   signal rvram_busy    : std_logic;
   signal busy_cycles   : integer := 0;   -- cycles with line_busy high
   signal rvram_cycles  : integer := 0;   -- cycles nds_vram's renderer FSM was busy
   signal lines_started : integer := 0;   -- drawlines actually accepted

   -- reset-clear handshakes (see the waits in pmain)
   signal vclr_busy : std_logic;
   signal pclr_busy : std_logic;

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
      rsrv_dout => rsrv_dout, rsrv_done => rsrv_done,
      rsrv_ready => rsrv_ready_s,
      dbg_rbusy => rvram_busy
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
   -- the renderer's outstanding-request behaviour untestable. RSRV_LAT is a
   -- generic so a run can be paced at hardware-like latency, and RSRV_ONE
   -- restricts it to one op in flight the way ch1 does on silicon.
   -- three models, in precedence order: explicit depth/gap, then the legacy
   -- one-in-flight bit, then always-ready.
   rsrv_ready_s <= '1' when (RSRV_OUT /= 0 or RSRV_GAP /= 0) and
                            (RSRV_OUT = 0 or rsrv_out_m < RSRV_OUT) and
                            (rsrv_gap_m = 0)
              else '0' when (RSRV_OUT /= 0 or RSRV_GAP /= 0)
              else '1' when RSRV_ONE = 0
              else (not rsrv_busy_m);

   prserv : process (clk)
      variable accept_v : boolean;
   begin
      if rising_edge(clk) then
         for i in RSRV_LAT - 1 downto 1 loop
            rsrvpipe(i) <= rsrvpipe(i - 1);
         end loop;
         rsrvpipe(0).v <= '0';
         accept_v := (rsrv_req = '1') and (rsrv_ready_s = '1');
         if (rsrv_gap_m > 0) then rsrv_gap_m <= rsrv_gap_m - 1; end if;
         if (accept_v) then
            rsrvpipe(0).v <= '1';
            -- 64-bit line: both words of the aligned 8-byte block
            rsrvpipe(0).d <= banks(to_integer(unsigned(rsrv_bank)) * 32768 +
                                   to_integer(rsrv_addr) * 2 + 1) &
                             banks(to_integer(unsigned(rsrv_bank)) * 32768 +
                                   to_integer(rsrv_addr) * 2);
            if (RSRV_ONE /= 0) then rsrv_busy_m <= '1'; end if;
            if (RSRV_GAP > 1) then rsrv_gap_m <= RSRV_GAP - 1; end if;
         end if;
         rsrv_done <= rsrvpipe(RSRV_LAT - 1).v;
         rsrv_dout <= rsrvpipe(RSRV_LAT - 1).d;
         if (rsrvpipe(RSRV_LAT - 1).v = '1') then rsrv_busy_m <= '0'; end if;
         -- outstanding counter, handling accept and completion on the same edge
         if (accept_v and rsrvpipe(RSRV_LAT - 1).v = '0') then
            rsrv_out_m <= rsrv_out_m + 1;
         elsif (not accept_v and rsrvpipe(RSRV_LAT - 1).v = '1') then
            rsrv_out_m <= rsrv_out_m - 1;
         end if;

         -- valid/ready protocol checker (see the signal declarations)
         assert rsrv_held = '0' or
                (rsrv_req = '1' and rsrv_bank = rsrv_held_bank and
                 rsrv_addr = rsrv_held_addr)
            report "rsrv: request dropped - not held until ready (bank " &
                   to_string(rsrv_held_bank) & " addr " &
                   to_hstring(rsrv_held_addr) & ")"
            severity failure;
         rsrv_held <= '0';
         if (rsrv_req = '1' and not accept_v) then
            rsrv_held      <= '1';
            rsrv_held_bank <= rsrv_bank;
            rsrv_held_addr <= rsrv_addr;
         end if;
      end if;
   end process;

   -- ============ stall probe (STALL_CYC > 0) ============
   -- A wedge and mere slowness end the same way in the frame checker - dropped
   -- lines - so this separates them: it fires only if ONE line render stays busy
   -- for STALL_CYC cycles, and dumps the whole chain (drawer -> gpu2d arbiter ->
   -- nds_vram queue -> rsrv channel) so the party that is waiting on a word that
   -- will never arrive is named rather than guessed at.
   p_stall : process (clk)
      variable busy_run : natural := 0;
   begin
      if rising_edge(clk) then
         if (line_busy = '1') then
            busy_run := busy_run + 1;
         else
            busy_run := 0;
         end if;
         if (STALL_CYC > 0 and busy_run = STALL_CYC) then
            report "STALL after " & integer'image(busy_run) & " busy cycles on line " &
                   integer'image(linecounter) & LF &
                   "  gpu2d: cur_y=" & to_string(<< signal .tb_gpu2d_timed.igpu.cur_y : integer range 0 to 191 >>) &
                   " busy_text=" & to_string(<< signal .tb_gpu2d_timed.igpu.busy_text : std_logic_vector(0 to 3) >>) &
                   " busy_aff=" & to_string(<< signal .tb_gpu2d_timed.igpu.busy_aff : std_logic_vector(2 to 3) >>) &
                   " busy_ext=" & to_string(<< signal .tb_gpu2d_timed.igpu.busy_ext : std_logic_vector(2 to 3) >>) &
                   " obj_busy=" & to_string(<< signal .tb_gpu2d_timed.igpu.obj_busy : std_logic >>) & LF &
                   "  arb: bgv_req=" & to_string(<< signal .tb_gpu2d_timed.igpu.bgv_req : std_logic_vector(0 to 3) >>) &
                   " bgv_done=" & to_string(<< signal .tb_gpu2d_timed.igpu.bgv_done : std_logic_vector(0 to 3) >>) &
                   " pending=" & to_string(<< signal .tb_gpu2d_timed.igpu.b_arb.pending : std_logic_vector(0 to 3) >>) &
                   " unaccepted=" & to_string(<< signal .tb_gpu2d_timed.igpu.b_arb.unaccepted : std_logic >>) &
                   " os_count=" & integer'image(<< signal .tb_gpu2d_timed.igpu.b_arb.os_count : integer range 0 to 8 >>) & LF &
                   "  text0: tq=" & integer'image(<< signal .tb_gpu2d_timed.igpu.gen_text(0).itext.tq_count : integer range 0 to 4 >>) &
                   " tag=" & integer'image(<< signal .tb_gpu2d_timed.igpu.gen_text(0).itext.tag_count : integer range 0 to 8 >>) &
                   " f_tile=" & integer'image(<< signal .tb_gpu2d_timed.igpu.gen_text(0).itext.f_tile : integer range 0 to 33 >>) &
                   " unacc=" & to_string(<< signal .tb_gpu2d_timed.igpu.gen_text(0).itext.unaccepted : std_logic >>) &
                   " p_active=" & to_string(<< signal .tb_gpu2d_timed.igpu.gen_text(0).itext.p_active : std_logic >>) &
                   " p_x=" & integer'image(<< signal .tb_gpu2d_timed.igpu.gen_text(0).itext.p_x : integer range 0 to 256 >>) & LF &
                   "  text1: tq=" & integer'image(<< signal .tb_gpu2d_timed.igpu.gen_text(1).itext.tq_count : integer range 0 to 4 >>) &
                   " tag=" & integer'image(<< signal .tb_gpu2d_timed.igpu.gen_text(1).itext.tag_count : integer range 0 to 8 >>) &
                   " f_tile=" & integer'image(<< signal .tb_gpu2d_timed.igpu.gen_text(1).itext.f_tile : integer range 0 to 33 >>) &
                   " unacc=" & to_string(<< signal .tb_gpu2d_timed.igpu.gen_text(1).itext.unaccepted : std_logic >>) &
                   " p_active=" & to_string(<< signal .tb_gpu2d_timed.igpu.gen_text(1).itext.p_active : std_logic >>) &
                   " p_x=" & integer'image(<< signal .tb_gpu2d_timed.igpu.gen_text(1).itext.p_x : integer range 0 to 256 >>) & LF &
                   "  vram: rq_count=" & integer'image(<< signal .tb_gpu2d_timed.ivram.rq_count : integer range 0 to 8 >>) &
                   " adq_count=" & integer'image(<< signal .tb_gpu2d_timed.ivram.adq_count : integer range 0 to 4 >>) &
                   " rdispatch=" & to_string(<< signal .tb_gpu2d_timed.ivram.rdispatch : std_logic >>) &
                   " rpend=" & to_string(<< signal .tb_gpu2d_timed.ivram.rpend : std_logic_vector(7 downto 0) >>) &
                   " rreq_now=" & to_string(<< signal .tb_gpu2d_timed.ivram.rreq_now : std_logic_vector(7 downto 0) >>) & LF &
                   "  rsrv: req=" & to_string(rsrv_req) & " ready=" & to_string(rsrv_ready_s) &
                   " done=" & to_string(rsrv_done) & " busy_m=" & to_string(rsrv_busy_m) &
                   " bank=" & to_string(rsrv_bank) & " addr=" & to_hstring(rsrv_addr) & LF &
                   "  chan: bg(req=" & to_string(r_bg_req) & ",done=" & to_string(r_bg_done) &
                   ",acc=" & to_string(r_bg_accept) & ")" &
                   " obj(req=" & to_string(r_obj_req) & ",done=" & to_string(r_obj_done) & ")" &
                   " bgep(req=" & to_string(r_bgep_req) & ",done=" & to_string(r_bgep_done) & ")" &
                   " objep(req=" & to_string(r_objep_req) & ",done=" & to_string(r_objep_done) & ")"
               severity failure;
         end if;
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

         -- throughput: line occupancy, accepted lines, and renderer-side VRAM
         -- occupancy (dbg_rbusy, NOT srv_*_req - req is a pulse and counting it
         -- counts requests, not waiting; see nds_vram's port comment)
         if (line_busy = '1')  then busy_cycles  <= busy_cycles  + 1; end if;
         if (rvram_busy = '1') then rvram_cycles <= rvram_cycles + 1; end if;
         if (drawline = '1' and line_busy = '0') then
            lines_started <= lines_started + 1;
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
         variable exp : std_logic_vector(17 downto 0);
      begin
         for i in 0 to 49151 loop
            exp := vectors(pbase + i)(17 downto 0);
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
            write(fdl, to_hstring("00" & framebuf(i)));
            writeline(fdump, fdl);
         end loop;
         report "case " & integer'image(c) & " done, fails so far " & integer'image(nfail) &
                ", drops so far " & integer'image(drops) severity note;
         if (lines_started > 0) then
            report "THROUGHPUT case " & integer'image(c) &
                   ": lines " & integer'image(lines_started) &
                   ", cycles/line " & integer'image(busy_cycles / lines_started) &
                   ", rvram cycles/line " & integer'image(rvram_cycles / lines_started) &
                   ", budget " & integer'image(355 * 6 * CE_DIV) severity note;
         end if;
      end procedure;

      variable ncases, nregs, p : integer;
      type t_pb is array (0 to 15) of integer;
      variable pixbase : t_pb := (others => 0);
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
