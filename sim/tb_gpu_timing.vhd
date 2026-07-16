-- SPDX-License-Identifier: GPL-2.0-or-later
-- nds_gpu_timing checks: an independent arithmetic model (edge counter ->
-- line/cycle, event-based VCount/flag model per the melonDS GPU.cpp spec)
-- asserts every DUT output on every clock edge, plus per-frame pulse
-- counts. The driver scripts both CPU buses: IRQ enables, 9-bit V-match
-- (incl. unreachable values 300/511), a delayed VCOUNT write mid-frame,
-- and DISPSTAT write-mask readbacks.
--
-- Model/DUT alignment: reset ends mid "line 0" (cycle counter frozen at
-- 0), so line 0 of frame 0 never runs its scanline-start work - the
-- V-match flag first evaluates at the line 1 boundary, as in the DUT and
-- the GBA donor. All scripted writes/reads happen mid-line so register
-- updates never race a boundary evaluation.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity tb_gpu_timing is
   generic
   (
      TIMEOUT_MS : integer := 200
   );
end entity;

architecture arch of tb_gpu_timing is

   constant LINE_CYCLES  : integer := 355 * 6;
   constant RENDER_START : integer := 48 + 256 * 6;
   constant NFRAMES      : integer := 4;

   signal clk   : std_logic := '0';
   signal reset : std_logic := '1';

   signal gb_bus9      : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "10", "1111", '0');
   signal gb_bus7      : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "10", "1111", '0');
   signal wired_out9   : std_logic_vector(31 downto 0);
   signal wired_done9  : std_logic;
   signal wired_out7   : std_logic_vector(31 downto 0);
   signal wired_done7  : std_logic;

   signal irq9_vblank, irq9_hblank, irq9_vcount : std_logic;
   signal irq7_vblank, irq7_hblank, irq7_vcount : std_logic;

   signal linecounter     : integer range 0 to 191;
   signal drawline        : std_logic;
   signal linecounter_obj : integer range 0 to 191;
   signal drawObj         : std_logic;
   signal line_trigger    : std_logic;
   signal hblank_trigger  : std_logic;
   signal vblank_trigger  : std_logic;
   signal refpoint_update : std_logic;
   signal vcount_out      : unsigned(8 downto 0);

   -- driver -> monitor mirrors (what the DUT registers should now hold)
   signal tb_vmatch9   : integer range 0 to 511 := 0;
   signal tb_vmatch7   : integer range 0 to 511 := 0;
   signal tb_ena9_vbl  : std_logic := '0';
   signal tb_ena9_hbl  : std_logic := '0';
   signal tb_ena9_vcnt : std_logic := '0';
   signal tb_ena7_vbl  : std_logic := '0';
   signal tb_ena7_hbl  : std_logic := '0';
   signal tb_ena7_vcnt : std_logic := '0';
   signal tb_vcwr_seq  : integer := 0;             -- increments per VCOUNT write
   signal tb_vcwr_val  : integer range 0 to 511 := 0;

   -- monitor -> driver live position
   signal tb_lin : integer range 0 to 262 := 0;
   signal tb_cyc : integer range 0 to LINE_CYCLES - 1 := 0;

   signal tests_done : boolean := false;

begin

   clk <= not clk after 5 ns when not tests_done else '0';

   idut : entity work.nds_gpu_timing
   port map
   (
      clk             => clk,
      ce              => '1',
      reset           => reset,
      gb_bus9         => gb_bus9,
      wired_out9      => wired_out9,
      wired_done9     => wired_done9,
      gb_bus7         => gb_bus7,
      wired_out7      => wired_out7,
      wired_done7     => wired_done7,
      irq9_vblank     => irq9_vblank,
      irq9_hblank     => irq9_hblank,
      irq9_vcount     => irq9_vcount,
      irq7_vblank     => irq7_vblank,
      irq7_hblank     => irq7_hblank,
      irq7_vcount     => irq7_vcount,
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

   -- ================= monitor =================
   p_mon : process
      variable v            : integer := 0;   -- post-state index of the edge whose outputs are visible now
      variable cyc_v, lin_v : integer;
      variable exp_vcnt     : integer := 0;
      variable exp_vbl      : std_logic := '0';
      variable exp_hbl      : std_logic := '0';
      variable exp_vmf9     : std_logic := '0';
      variable exp_vmf7     : std_logic := '0';
      variable consumed_seq : integer := 0;
      variable exp_pulse    : boolean;
      variable frames       : integer := 0;
      variable cnt_drawline, cnt_drawobj, cnt_ltrig, cnt_htrig, cnt_vtrig, cnt_ref : integer := 0;
      variable cnt_i9v, cnt_i9h, cnt_i9c, cnt_i7v, cnt_i7h, cnt_i7c : integer := 0;

      procedure chk(cond : boolean; msg : string) is
      begin
         if (not cond) then
            report "tb_gpu_timing: v=" & integer'image(v) &
                   " line=" & integer'image(lin_v) & " cyc=" & integer'image(cyc_v) &
                   " " & msg severity failure;
         end if;
      end procedure;
   begin
      wait until rising_edge(clk) and reset = '0';
      while not tests_done loop

         cyc_v := v mod LINE_CYCLES;
         lin_v := (v / LINE_CYCLES) mod 263;

         -- event model: scanline start / hblank point
         if (v > 0 and cyc_v = 0) then
            if (lin_v = 0) then
               exp_vcnt     := 0;
               consumed_seq := tb_vcwr_seq;   -- pending write discarded at frame wrap
               frames       := frames + 1;
            elsif (consumed_seq /= tb_vcwr_seq) then
               exp_vcnt     := tb_vcwr_val;
               consumed_seq := tb_vcwr_seq;
            else
               exp_vcnt := (exp_vcnt + 1) mod 512;
            end if;
            exp_hbl := '0';
            if (exp_vcnt = tb_vmatch9) then exp_vmf9 := '1'; else exp_vmf9 := '0'; end if;
            if (exp_vcnt = tb_vmatch7) then exp_vmf7 := '1'; else exp_vmf7 := '0'; end if;
            if    (exp_vcnt = 192) then exp_vbl := '1';
            elsif (exp_vcnt = 262) then exp_vbl := '0'; end if;
         elsif (cyc_v = RENDER_START) then
            exp_hbl := '1';
         end if;

         -- frame-boundary pulse-count checks (skip the partial reset frame)
         if (v > 0 and cyc_v = 0 and lin_v = 0) then
            if (frames > 1) then
               chk(cnt_drawline = 192, "drawline count " & integer'image(cnt_drawline));
               chk(cnt_drawobj  = 192, "drawObj count "  & integer'image(cnt_drawobj));
               chk(cnt_ltrig    = 192, "line_trigger count " & integer'image(cnt_ltrig));
               chk(cnt_htrig    = 192, "hblank_trigger count " & integer'image(cnt_htrig));
               chk(cnt_vtrig    = 1,   "vblank_trigger count " & integer'image(cnt_vtrig));
               chk(cnt_ref      = 191, "refpoint count " & integer'image(cnt_ref));
               if (tb_ena9_hbl = '1') then chk(cnt_i9h = 263, "irq9_hblank count " & integer'image(cnt_i9h));
               else                        chk(cnt_i9h = 0,   "irq9_hblank count " & integer'image(cnt_i9h)); end if;
               if (tb_ena9_vbl = '1') then chk(cnt_i9v = 1, "irq9_vblank count " & integer'image(cnt_i9v));
               else                        chk(cnt_i9v = 0, "irq9_vblank count " & integer'image(cnt_i9v)); end if;
               if (tb_ena7_hbl = '0') then chk(cnt_i7h = 0, "irq7_hblank count " & integer'image(cnt_i7h)); end if;
               if (tb_ena7_vbl = '0') then chk(cnt_i7v = 0, "irq7_vblank count " & integer'image(cnt_i7v)); end if;
               report "tb_gpu_timing: frame " & integer'image(frames - 1) &
                      " counts ok (irq9_vcount " & integer'image(cnt_i9c) &
                      ", irq7_vcount " & integer'image(cnt_i7c) & ")" severity note;
            end if;
            cnt_drawline := 0; cnt_drawobj := 0; cnt_ltrig := 0; cnt_htrig := 0;
            cnt_vtrig := 0; cnt_ref := 0;
            cnt_i9v := 0; cnt_i9h := 0; cnt_i9c := 0;
            cnt_i7v := 0; cnt_i7h := 0; cnt_i7c := 0;
         end if;

         -- flags
         chk((vcount_out = to_unsigned(exp_vcnt, 9)), "vcount_out " & integer'image(to_integer(vcount_out)) & " expected " & integer'image(exp_vcnt));

         -- pulses: expected exactly at their cadence points
         exp_pulse := (cyc_v = RENDER_START and lin_v < 192);
         chk((hblank_trigger = '1') = exp_pulse, "hblank_trigger " & std_logic'image(hblank_trigger));
         exp_pulse := (cyc_v = RENDER_START + 1 and lin_v < 192);
         chk((line_trigger = '1') = exp_pulse, "line_trigger " & std_logic'image(line_trigger));
         exp_pulse := (cyc_v = RENDER_START + 2 and lin_v < 192);
         chk((drawline = '1') = exp_pulse, "drawline " & std_logic'image(drawline));
         if (drawline = '1') then
            chk(linecounter = lin_v, "linecounter " & integer'image(linecounter));
         end if;
         exp_pulse := (cyc_v = RENDER_START + 2 and (lin_v < 191 or lin_v = 262));
         chk((drawObj = '1') = exp_pulse, "drawObj " & std_logic'image(drawObj));
         if (drawObj = '1') then
            chk(linecounter_obj = (lin_v + 1) mod 263, "linecounter_obj " & integer'image(linecounter_obj));
         end if;
         exp_pulse := (v > 0 and cyc_v = 0 and lin_v >= 1 and lin_v <= 191);
         chk((refpoint_update = '1') = exp_pulse, "refpoint_update " & std_logic'image(refpoint_update));
         exp_pulse := (v > 0 and cyc_v = 0 and exp_vcnt = 192);
         chk((vblank_trigger = '1') = exp_pulse, "vblank_trigger " & std_logic'image(vblank_trigger));

         -- IRQ pulses
         exp_pulse := (v > 0 and cyc_v = 0 and exp_vcnt = 192);
         chk((irq9_vblank = '1') = (exp_pulse and tb_ena9_vbl = '1'), "irq9_vblank");
         chk((irq7_vblank = '1') = (exp_pulse and tb_ena7_vbl = '1'), "irq7_vblank");
         exp_pulse := (cyc_v = RENDER_START);
         chk((irq9_hblank = '1') = (exp_pulse and tb_ena9_hbl = '1'), "irq9_hblank");
         chk((irq7_hblank = '1') = (exp_pulse and tb_ena7_hbl = '1'), "irq7_hblank");
         exp_pulse := (v > 0 and cyc_v = 0 and exp_vcnt = tb_vmatch9);
         chk((irq9_vcount = '1') = (exp_pulse and tb_ena9_vcnt = '1'), "irq9_vcount");
         exp_pulse := (v > 0 and cyc_v = 0 and exp_vcnt = tb_vmatch7);
         chk((irq7_vcount = '1') = (exp_pulse and tb_ena7_vcnt = '1'), "irq7_vcount");

         -- DISPSTAT read paths, checked continuously via the wired-or bus
         -- (the driver parks the address between accesses; only assert when
         -- the address currently selects DISPSTAT)
         if (gb_bus9.Adr = std_logic_vector(to_unsigned(16#004#, 28))) then
            chk(wired_out9(0) = exp_vbl,  "DISPSTAT9 vblank flag read " & std_logic'image(wired_out9(0)));
            chk(wired_out9(1) = exp_hbl,  "DISPSTAT9 hblank flag read " & std_logic'image(wired_out9(1)));
            chk(wired_out9(2) = exp_vmf9, "DISPSTAT9 vmatch flag read " & std_logic'image(wired_out9(2)));
            chk(wired_out9(6) = '0',      "DISPSTAT9 bit6 read");
            chk(to_integer(unsigned(wired_out9(24 downto 16))) = exp_vcnt, "VCOUNT9 read");
            chk(wired_out9(31 downto 25) = "0000000", "VCOUNT9 high bits read");
         end if;
         if (gb_bus7.Adr = std_logic_vector(to_unsigned(16#004#, 28))) then
            chk(wired_out7(0) = exp_vbl,  "DISPSTAT7 vblank flag read " & std_logic'image(wired_out7(0)));
            chk(wired_out7(1) = exp_hbl,  "DISPSTAT7 hblank flag read " & std_logic'image(wired_out7(1)));
            chk(wired_out7(2) = exp_vmf7, "DISPSTAT7 vmatch flag read " & std_logic'image(wired_out7(2)));
            chk(to_integer(unsigned(wired_out7(24 downto 16))) = exp_vcnt, "VCOUNT7 read");
         end if;

         -- counts
         if (drawline = '1')        then cnt_drawline := cnt_drawline + 1; end if;
         if (drawObj = '1')         then cnt_drawobj  := cnt_drawobj + 1;  end if;
         if (line_trigger = '1')    then cnt_ltrig    := cnt_ltrig + 1;    end if;
         if (hblank_trigger = '1')  then cnt_htrig    := cnt_htrig + 1;    end if;
         if (vblank_trigger = '1')  then cnt_vtrig    := cnt_vtrig + 1;    end if;
         if (refpoint_update = '1') then cnt_ref      := cnt_ref + 1;      end if;
         if (irq9_vblank = '1')     then cnt_i9v      := cnt_i9v + 1;      end if;
         if (irq9_hblank = '1')     then cnt_i9h      := cnt_i9h + 1;      end if;
         if (irq9_vcount = '1')     then cnt_i9c      := cnt_i9c + 1;      end if;
         if (irq7_vblank = '1')     then cnt_i7v      := cnt_i7v + 1;      end if;
         if (irq7_hblank = '1')     then cnt_i7h      := cnt_i7h + 1;      end if;
         if (irq7_vcount = '1')     then cnt_i7c      := cnt_i7c + 1;      end if;

         tb_lin <= lin_v;
         tb_cyc <= cyc_v;

         v := v + 1;
         wait until rising_edge(clk);
      end loop;
      wait;
   end process;

   -- ================= driver =================
   p_drive : process
      variable rd : std_logic_vector(31 downto 0);

      procedure wr9(bena : std_logic_vector(3 downto 0); data : std_logic_vector(31 downto 0)) is
      begin
         gb_bus9.Adr  <= std_logic_vector(to_unsigned(16#004#, 28));
         gb_bus9.Din  <= data;
         gb_bus9.rnw  <= '0';
         gb_bus9.bEna <= bena;
         gb_bus9.ena  <= '1';
         wait until rising_edge(clk);
         gb_bus9.ena  <= '0';
         gb_bus9.rnw  <= '1';
         gb_bus9.Adr  <= (others => '1');   -- park off-decode
         wait until rising_edge(clk);
      end procedure;

      procedure wr7(bena : std_logic_vector(3 downto 0); data : std_logic_vector(31 downto 0)) is
      begin
         gb_bus7.Adr  <= std_logic_vector(to_unsigned(16#004#, 28));
         gb_bus7.Din  <= data;
         gb_bus7.rnw  <= '0';
         gb_bus7.bEna <= bena;
         gb_bus7.ena  <= '1';
         wait until rising_edge(clk);
         gb_bus7.ena  <= '0';
         gb_bus7.rnw  <= '1';
         gb_bus7.Adr  <= (others => '1');
         wait until rising_edge(clk);
      end procedure;

      -- select DISPSTAT on a bus for a few cycles: the monitor then checks
      -- the combinational read value against its model continuously
      procedure rd9_window is
      begin
         gb_bus9.Adr <= std_logic_vector(to_unsigned(16#004#, 28));
         for k in 1 to 4 loop wait until rising_edge(clk); end loop;
         rd := wired_out9;
         gb_bus9.Adr <= (others => '1');
         wait until rising_edge(clk);
      end procedure;

      procedure rd7_window is
      begin
         gb_bus7.Adr <= std_logic_vector(to_unsigned(16#004#, 28));
         for k in 1 to 4 loop wait until rising_edge(clk); end loop;
         rd := wired_out7;
         gb_bus7.Adr <= (others => '1');
         wait until rising_edge(clk);
      end procedure;

      procedure at_point(l : integer; c : integer) is
      begin
         wait until rising_edge(clk) and tb_lin = l and tb_cyc = c;
      end procedure;
   begin
      gb_bus9.Adr <= (others => '1');
      gb_bus7.Adr <= (others => '1');
      for k in 1 to 4 loop wait until rising_edge(clk); end loop;
      reset <= '0';
      wait until rising_edge(clk);
      wait until rising_edge(clk);

      -- frame 0, line 0, early (before the first hblank point):
      -- ARM9: all three IRQs enabled, vmatch 200
      wr9("0011", x"0000" & x"C838");
      tb_vmatch9 <= 200; tb_ena9_vbl <= '1'; tb_ena9_hbl <= '1'; tb_ena9_vcnt <= '1';
      -- ARM7: only the V-count IRQ, vmatch 100
      wr7("0011", x"0000" & x"6420");
      tb_vmatch7 <= 100; tb_ena7_vcnt <= '1';

      -- flag-window spot reads (mid-line, away from boundaries)
      at_point(50, 800);   rd9_window;   -- visible, pre-hblank
      at_point(50, 1900);  rd9_window;   -- visible, in hblank
      at_point(80, 300);   rd7_window;

      -- delayed VCOUNT write: lands at the line 101 boundary as 150
      at_point(100, 500);
      wr9("1100", std_logic_vector(to_unsigned(150, 16)) & x"0000");
      tb_vcwr_val <= 150;
      tb_vcwr_seq <= tb_vcwr_seq + 1;

      -- vblank now starts when VCount hits 192: internal line 143
      at_point(143, 700);  rd9_window;
      at_point(200, 300);  rd9_window;   -- deep in (shifted) vblank
      at_point(262, 900);  rd7_window;   -- vblank flag already clear on the last line? (VCount 311 here: flag cleared at 262)

      -- frame 1: no writes, plain cadence
      at_point(0, 400);
      report "tb_gpu_timing: frame 1 running clean" severity note;
      at_point(100, 900);  rd7_window;   -- ARM7 vmatch flag on its match line
      at_point(200, 900);  rd9_window;   -- ARM9 vmatch flag on its match line

      -- frame 2, line 0 early: ARM7 vmatch -> 300 (unreachable: 263-line
      -- frame), ARM9 -> everything-written pattern (vmatch 511, unreachable)
      at_point(0, 200);
      wr7("0011", x"0000" & x"2CA0");
      tb_vmatch7 <= 300;
      wr9("0011", x"0000" & x"FFFF");
      tb_vmatch9 <= 511;
      -- write mask readback: flags live (none set at line 0 pre-hblank),
      -- bit 6 zero, enables + match as written
      rd9_window;
      if (rd(15 downto 0) /= x"FFB8") then
         report "tb_gpu_timing: DISPSTAT9 mask readback " & to_hstring(rd(15 downto 0)) severity failure;
      end if;
      rd7_window;
      if (rd(15 downto 0) /= x"2CA0") then
         report "tb_gpu_timing: DISPSTAT7 mask readback " & to_hstring(rd(15 downto 0)) severity failure;
      end if;

      -- frame 3: quiet full frame under the unreachable-match settings
      -- (counts checked at the frame 3/4 boundaries)
      at_point(262, 600);   -- end of frame 2
      report "tb_gpu_timing: frame 3 running clean" severity note;
      at_point(262, 600);   -- all the way through frame 3
      at_point(0, 600);     -- into frame 4: frame-3 counts checked at the boundary

      report "tb_gpu_timing: PASS  " & integer'image(NFRAMES) & " frames" severity note;
      tests_done <= true;
      wait;
   end process;

   p_watchdog : process
   begin
      wait for TIMEOUT_MS * 1 ms;
      if not tests_done then
         report "tb_gpu_timing: TIMEOUT" severity failure;
      end if;
      wait;
   end process;

end architecture;
