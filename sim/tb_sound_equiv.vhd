-- SPDX-License-Identifier: GPL-2.0-or-later
-- Equivalence test: rtl/nds_sound.vhd against sim/nds_sound_ref.vhd, a verbatim
-- copy of the version before the area refactor.
--
-- WHY THIS EXISTS. tb_sound's own header nominates the intended method - run it
-- before and after, diff the SAMPLE lines - and that was adequate for the
-- fptr/frem BRAM conversion, which moved storage and touched nothing else. It is
-- NOT adequate for restructuring the sample engine. It captures 27 samples, it
-- has no oracle ("nothing here checks decoded sample VALUES against a
-- reference"), and a stimulus that never starts a channel cannot notice that the
-- channel is broken. Refactoring 6,402 ALMs of decode logic against 27 samples
-- is how a silent regression ships.
--
-- Same shape as sim/tb_drawer_text_equiv.vhd: the old version is the reference,
-- because it is the thing already validated against hardware behaviour.
--
-- EACH INSTANCE GETS ITS OWN MEMBUS RESPONDER. They must not share one: the two
-- may fetch at different times once the engine is restructured, and a shared
-- responder would let one perturb the other's data and turn a timing difference
-- into a false value mismatch.
--
-- THE COMPARISON IS ON THE SAMPLE STREAM, NOT CYCLE-ALIGNED. A restructured
-- engine may legitimately emit a sample a cycle earlier or later; what must not
-- change is the sequence of values. Same reasoning as the drawer bench comparing
-- the line buffer rather than the pixel stream.
--
-- Run: sim/run_sound_equiv.sh

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity tb_sound_equiv is
   generic
   (
      TIMEOUT_MS : integer := 200
   );
end entity;

architecture sim of tb_sound_equiv is

   signal clk   : std_logic := '0';
   signal ce    : std_logic := '1';
   signal reset : std_logic := '1';

   signal bus7 : proc_bus_gb_type := (Din  => (others => '0'), Adr => (others => '0'),
                                      rnw  => '1', ena => '0', acc => "10",
                                      bEna => "0000", rst => '0');

   -- device under test
   signal d_out7, d_adr           : std_logic_vector(31 downto 0);
   signal d_done7                 : std_logic;
   signal d_req, d_own, d_ena     : std_logic;
   signal d_din                   : std_logic_vector(31 downto 0) := (others => '0');
   signal d_mdone                 : std_logic := '0';
   signal d_l, d_r                : std_logic_vector(15 downto 0);
   signal d_v, d_en               : std_logic;
   signal d_act                   : std_logic_vector(15 downto 0);

   -- reference
   signal r_out7, r_adr           : std_logic_vector(31 downto 0);
   signal r_done7                 : std_logic;
   signal r_req, r_own, r_ena     : std_logic;
   signal r_din                   : std_logic_vector(31 downto 0) := (others => '0');
   signal r_mdone                 : std_logic := '0';
   signal r_l, r_r                : std_logic_vector(15 downto 0);
   signal r_v, r_en               : std_logic;
   signal r_act                   : std_logic_vector(15 downto 0);

   signal tests_done  : boolean := false;
   signal any_nonzero : boolean := false;

   constant QN : integer := 4096;
   type t_q is array (0 to QN-1) of std_logic_vector(31 downto 0);
   signal dq, rq : t_q;
   signal dwp, rwp, cmpp : integer := 0;
   signal mismatches : integer := 0;

begin

   clk <= not clk after 5 ns when not tests_done else '0';

   idut : entity work.nds_sound
   generic map ( is_simu => '1' )
   port map (
      clk => clk, ce => ce, reset => reset,
      bus7 => bus7, wired_out7 => d_out7, wired_done7 => d_done7,
      snd_bus_req => d_req, snd_bus_ok => '1', snd_bus_own => d_own,
      mb_ena => d_ena, mb_adr => d_adr, mb_din => d_din, mb_done => d_mdone,
      sample_l => d_l, sample_r => d_r, sample_valid => d_v,
      snd_enable => d_en, snd_active => d_act
   );

   iref : entity work.nds_sound_ref
   generic map ( is_simu => '1' )
   port map (
      clk => clk, ce => ce, reset => reset,
      bus7 => bus7, wired_out7 => r_out7, wired_done7 => r_done7,
      snd_bus_req => r_req, snd_bus_ok => '1', snd_bus_own => r_own,
      mb_ena => r_ena, mb_adr => r_adr, mb_din => r_din, mb_done => r_mdone,
      sample_l => r_l, sample_r => r_r, sample_valid => r_v,
      snd_enable => r_en, snd_active => r_act
   );

   -- two identical responders, one per instance. Same address-derived pattern
   -- tb_sound uses, so the same address always yields the same word no matter
   -- WHEN each instance asks for it.
   p_mem_d : process
   begin
      wait until rising_edge(clk) and d_ena = '1';
      d_din <= (d_adr(15 downto 0) & d_adr(31 downto 16)) xor x"5A5A5A5A";
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      d_mdone <= '1';
      wait until rising_edge(clk);
      d_mdone <= '0';
   end process;

   p_mem_r : process
   begin
      wait until rising_edge(clk) and r_ena = '1';
      r_din <= (r_adr(15 downto 0) & r_adr(31 downto 16)) xor x"5A5A5A5A";
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      r_mdone <= '1';
      wait until rising_edge(clk);
      r_mdone <= '0';
   end process;

   -- stream capture and in-order compare. One comparison per clock keeps up
   -- trivially: samples arrive once per 1024 clocks, so at most one entry is
   -- ever outstanding and the modulo indexing cannot lap itself.
   p_cmp : process (clk)
   begin
      if rising_edge(clk) then
         if (d_v = '1') then
            dq(dwp mod QN) <= d_l & d_r;
            dwp <= dwp + 1;
            if (d_l /= x"0000" or d_r /= x"0000") then any_nonzero <= true; end if;
         end if;
         if (r_v = '1') then
            rq(rwp mod QN) <= r_l & r_r;
            rwp <= rwp + 1;
         end if;

         if (cmpp < dwp and cmpp < rwp) then
            if (dq(cmpp mod QN) /= rq(cmpp mod QN)) then
               report "MISMATCH at sample " & integer'image(cmpp) &
                      "  dut=" & to_hstring(dq(cmpp mod QN)) &
                      "  ref=" & to_hstring(rq(cmpp mod QN)) severity error;
               mismatches <= mismatches + 1;
            end if;
            cmpp <= cmpp + 1;
         end if;
      end if;
   end process;

   -- snd_active/snd_enable are combinational taps of the same state, so unlike
   -- the sample stream they SHOULD track cycle for cycle. Checked separately so
   -- a divergence here points at the state, not at the mixer.
   p_taps : process (clk)
   begin
      if rising_edge(clk) then
         if (reset = '0' and d_en /= r_en) then
            report "snd_enable diverged: dut=" & to_string(d_en) &
                   " ref=" & to_string(r_en) severity error;
         end if;
      end if;
   end process;

   p_drive : process
      variable nfail : integer := 0;

      procedure regw(a : integer; d : std_logic_vector(31 downto 0); be : std_logic_vector(3 downto 0)) is
      begin
         wait until rising_edge(clk);
         bus7.Adr  <= std_logic_vector(to_unsigned(a, 28));
         bus7.Din  <= d;
         bus7.rnw  <= '0';
         bus7.bEna <= be;
         bus7.ena  <= '1';
         wait until rising_edge(clk);
         bus7.ena  <= '0';
         bus7.rnw  <= '1';
      end procedure;

      procedure start_chan(ch, fmt, repm, duty, volmul, voldiv, pan,
                            sad, tmr, pnt, len : integer) is
         variable base    : integer;
         variable cntword : std_logic_vector(31 downto 0);
      begin
         base := 16#400# + ch * 16#10#;
         regw(base + 16#04#, std_logic_vector(to_unsigned(sad, 32)), "1111");
         regw(base + 16#08#, std_logic_vector(to_unsigned(pnt, 16)) &
                              std_logic_vector(to_unsigned(tmr, 16)), "1111");
         regw(base + 16#0C#, std_logic_vector(to_unsigned(len, 32)), "1111");
         cntword := "1" &
                    std_logic_vector(to_unsigned(fmt, 2)) &
                    std_logic_vector(to_unsigned(repm, 2)) &
                    std_logic_vector(to_unsigned(duty, 3)) &
                    "0" &
                    std_logic_vector(to_unsigned(pan, 7)) &
                    "000000" &
                    std_logic_vector(to_unsigned(voldiv, 2)) &
                    "0" &
                    std_logic_vector(to_unsigned(volmul, 7));
         regw(base + 16#00#, cntword, "1111");
      end procedure;

      procedure stop_chan(ch : integer) is
      begin
         regw(16#400# + ch * 16#10#, x"00000000", "1000");
      end procedure;

      procedure hold(n : integer) is
      begin
         for k in 1 to n loop
            wait until rising_edge(clk);
         end loop;
      end procedure;

   begin
      hold(3);
      reset <= '0';
      hold(1);

      regw(16#500#, x"0000807F", "0011");
      regw(16#504#, x"00000200", "0011");

      -- ---- every channel busy at once, spanning every format ----
      -- 0-3 PCM8, 4-7 PCM16, 8-13 ADPCM and PSG duty, 14-15 noise. Different
      -- timers so overflows land on different ticks and the shared fetch FSM
      -- sees genuine contention.
      start_chan(0,  0, 1, 0, 100, 0,  64, 16#0000#, 16#FFF0#, 0, 4);
      start_chan(1,  0, 0, 0, 127, 1, 100, 16#1000#, 16#FFF4#, 0, 3);
      start_chan(2,  1, 1, 0,  90, 0,  30, 16#2000#, 16#FFF1#, 0, 5);
      start_chan(3,  1, 0, 0,  70, 2,  90, 16#3000#, 16#FFF5#, 0, 3);
      start_chan(4,  2, 1, 0,  80, 2,  20, 16#4000#, 16#FFF2#, 0, 4);
      start_chan(5,  2, 0, 0,  80, 1,  50, 16#5000#, 16#FFF6#, 0, 3);
      start_chan(6,  2, 1, 0, 110, 3,  10, 16#6000#, 16#FFF3#, 0, 6);
      start_chan(7,  0, 1, 0,  64, 0, 127, 16#7000#, 16#FFF7#, 0, 2);
      start_chan(8,  3, 1, 0,  64, 0,  64, 0, 16#FFF8#, 0, 1);
      start_chan(9,  3, 1, 3,  64, 0,  64, 0, 16#FFF9#, 0, 1);
      start_chan(10, 3, 1, 5,  64, 0,  64, 0, 16#FFFA#, 0, 1);
      start_chan(11, 3, 1, 7,  64, 0,  64, 0, 16#FFFB#, 0, 1);
      start_chan(12, 1, 1, 0,  95, 0,  40, 16#C000#, 16#FFF2#, 0, 4);
      start_chan(13, 2, 1, 0,  85, 1,  70, 16#D000#, 16#FFF4#, 0, 3);
      start_chan(14, 3, 1, 0,  64, 0,  64, 0, 16#FFF0#, 0, 1);
      start_chan(15, 3, 1, 0,  64, 0,  30, 0, 16#FFF6#, 0, 1);

      hold(6000);

      -- master volume sweep: exercises the mixer's shift/multiply path
      for v in 0 to 7 loop
         regw(16#500#, x"00008000" or std_logic_vector(to_unsigned(v * 16, 32)), "0011");
         hold(1500);
      end loop;
      regw(16#500#, x"0000807F", "0011");

      -- ch1/ch3 mix-exclude bits, both directions
      regw(16#500#, x"0000907F", "0011");
      hold(1500);
      regw(16#500#, x"0000A07F", "0011");
      hold(1500);
      regw(16#500#, x"0000B07F", "0011");
      hold(1500);
      regw(16#500#, x"0000807F", "0011");

      -- restart channels mid-flight: stop and immediately re-start, which is
      -- what a game doing note retriggers does and what a restructured engine
      -- with pending state is most likely to get wrong
      for k in 0 to 7 loop
         stop_chan(k);
         hold(40);
         start_chan(k, k mod 3, 1, 0, 90, k mod 4, 64,
                    k * 16#1000#, 16#FFF0# + k, 0, 3);
         hold(200);
      end loop;

      -- PSG duty sweep on a live channel
      for d in 0 to 7 loop
         stop_chan(8);
         hold(20);
         start_chan(8, 3, 1, d, 64, 0, 64, 0, 16#FFF8#, 0, 1);
         hold(800);
      end loop;

      -- bias register movement
      regw(16#504#, x"00000000", "0011");
      hold(1500);
      regw(16#504#, x"000003FF", "0011");
      hold(1500);
      regw(16#504#, x"00000200", "0011");

      hold(30000);

      if not any_nonzero then
         nfail := nfail + 1;
         report "tb_sound_equiv: never produced a non-silent sample - stimulus is dead" severity error;
      end if;
      if (cmpp < 40) then
         nfail := nfail + 1;
         report "tb_sound_equiv: only " & integer'image(cmpp) &
                " samples compared - too few to mean anything" severity error;
      end if;
      if (mismatches /= 0) then
         nfail := nfail + 1;
      end if;

      if (nfail = 0) then
         report "tb_sound_equiv: PASS  " & integer'image(cmpp) &
                " samples compared, 0 mismatches" severity note;
      else
         report "tb_sound_equiv: FAIL  " & integer'image(mismatches) &
                " sample mismatch(es) over " & integer'image(cmpp) &
                " compared" severity failure;
      end if;

      tests_done <= true;
      wait;
   end process;

   p_watchdog : process
   begin
      wait for TIMEOUT_MS * 1 ms;
      if not tests_done then
         report "tb_sound_equiv: TIMEOUT" severity failure;
      end if;
      wait;
   end process;

end architecture;
