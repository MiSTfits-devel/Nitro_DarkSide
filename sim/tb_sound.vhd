-- SPDX-License-Identifier: GPL-2.0-or-later
-- nds_sound regression tb: drives register writes across every
-- fetch-needing format (PCM8, PCM16, ADPCM x2 - one looping, one
-- one-shot), PSG (all 8 duty settings) and noise, with several channels
-- overlapping in time so the shared fetch FSM's round-robin and the
-- mixer's 16-slot window both see real contention. This is the gate for
-- the fptr/frem BRAM conversion (M9 ALM endgame, see COORDINATION.md):
-- run it once against nds_sound.vhd BEFORE the conversion and once
-- after, then diff the two runs' "SAMPLE" report lines - they must be
-- byte-identical. There is no independent (e.g. melonDS) oracle here;
-- the two self-checks below only prove the harness itself is alive, not
-- that the decoded audio is correct - that was already validated
-- elsewhere (M8 sound part 2). Run: sim/run_sound.sh
--
-- The ARM7-membus responder serves fetches from a deterministic,
-- address-derived pattern, not real audio content - nothing here checks
-- decoded sample VALUES against a reference, only that the refactor
-- doesn't change what the RTL already produces.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.textio.all;

use work.pProc_bus_gba.all;

entity tb_sound is
   generic
   (
      TIMEOUT_MS : integer := 50
   );
end entity;

architecture sim of tb_sound is

   signal clk   : std_logic := '0';
   signal ce    : std_logic := '1';
   signal reset : std_logic := '1';

   signal bus7        : proc_bus_gb_type := (Din  => (others => '0'), Adr => (others => '0'),
                                              rnw  => '1', ena => '0', acc => "10",
                                              bEna => "0000", rst => '0');
   signal wired_out7  : std_logic_vector(31 downto 0);
   signal wired_done7 : std_logic;

   signal snd_bus_req, snd_bus_own : std_logic;
   signal snd_bus_ok  : std_logic := '1';
   signal mb_ena  : std_logic;
   signal mb_adr  : std_logic_vector(31 downto 0);
   signal mb_din  : std_logic_vector(31 downto 0) := (others => '0');
   signal mb_done : std_logic := '0';

   signal sample_l, sample_r : std_logic_vector(15 downto 0);
   signal sample_valid : std_logic;
   signal snd_enable   : std_logic;
   signal snd_active   : std_logic_vector(15 downto 0);

   signal tests_done  : boolean := false;
   signal sample_idx  : integer := 0;
   signal any_nonzero : boolean := false;

begin

   clk <= not clk after 5 ns when not tests_done else '0';

   idut : entity work.nds_sound
   generic map ( is_simu => '1' )
   port map
   (
      clk => clk, ce => ce, reset => reset,
      bus7 => bus7, wired_out7 => wired_out7, wired_done7 => wired_done7,
      snd_bus_req => snd_bus_req, snd_bus_ok => snd_bus_ok, snd_bus_own => snd_bus_own,
      mb_ena => mb_ena, mb_adr => mb_adr, mb_din => mb_din, mb_done => mb_done,
      sample_l => sample_l, sample_r => sample_r, sample_valid => sample_valid,
      snd_enable => snd_enable, snd_active => snd_active
   );

   -- behavioral ARM7-membus responder: deterministic address-derived
   -- data, fixed short latency. Bus arbitration (dma_on/cpu7_pause) lives
   -- in nds_top and is untouched by the fptr/frem conversion, so
   -- snd_bus_ok is tied high - this tb's job is the fetch FSM and the
   -- two new BRAMs, not top-level arbitration.
   p_membus : process
   begin
      wait until rising_edge(clk) and mb_ena = '1';
      mb_din <= (mb_adr(15 downto 0) & mb_adr(31 downto 16)) xor x"5A5A5A5A";
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      mb_done <= '1';
      wait until rising_edge(clk);
      mb_done <= '0';
   end process;

   -- sample collector: reports every valid sample (the actual regression
   -- gate - diffed externally against a pre-conversion run) and tracks
   -- whether anything non-silent was ever produced
   process (clk)
   begin
      if rising_edge(clk) then
         if (sample_valid = '1') then
            report "SAMPLE " & integer'image(sample_idx) &
                   " L=" & to_hstring(sample_l) & " R=" & to_hstring(sample_r) &
                   " active=" & to_hstring(snd_active) severity note;
            sample_idx <= sample_idx + 1;
            if (sample_l /= x"0000" or sample_r /= x"0000") then
               any_nonzero <= true;
            end if;
         end if;
      end if;
   end process;

   p_drive : process
      variable nfail : integer := 0;

      -- single register write pulse (byte-enabled), matching the plain
      -- inline bus-drive style used in tb_arm7_island/tb_dual_boot
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

      -- SOUNDxCNT/SAD/TMR+PNT/LEN, in that order, ending with the CNT
      -- write that sets bit31 (start) - bit positions match nds_sound's
      -- write-side decode exactly (see nds_sound.vhd's SOUNDxCNT case).
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
         -- bit31=0 with bEna(3) only hits the "elsif Din(31)='0'" stop path
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

      -- master enable, max master volume, spec-default bias (0x200)
      regw(16#500#, x"0000807F", "0011");
      regw(16#504#, x"00000200", "0011");

      -- ch0: PCM8, loop
      start_chan(0, 0, 1, 0, 100, 0, 64, 16#0000#, 16#FFF0#, 0, 4);
      -- ch1: PCM16, one-shot
      start_chan(1, 1, 0, 0, 127, 1, 100, 16#1000#, 16#FFF4#, 0, 3);

      hold(300);
      regw(16#500#, x"0000907F", "0011");  -- exclude ch1 from the mix
      hold(300);
      regw(16#500#, x"0000807F", "0011");  -- restore

      -- ch2: ADPCM, loop (short len -> wraps several times in-sim)
      start_chan(2, 2, 1, 0, 80, 2, 20, 16#2000#, 16#FFF2#, 0, 4);
      -- ch3: ADPCM, one-shot
      start_chan(3, 2, 0, 0, 80, 1, 50, 16#3000#, 16#FFF6#, 0, 3);

      hold(300);
      regw(16#500#, x"0000A07F", "0011");  -- exclude ch3 from the mix
      hold(300);
      regw(16#500#, x"0000807F", "0011");  -- restore

      -- ch8: PSG, cycle through all 8 duty settings
      for d in 0 to 7 loop
         start_chan(8, 3, 1, d, 64, 0, 64, 0, 16#FFF8#, 0, 1);
         hold(500);
         stop_chan(8);
         hold(20);
      end loop;

      -- ch14: noise, left running through to the end
      start_chan(14, 3, 1, 0, 64, 0, 64, 0, 16#FFF0#, 0, 1);

      -- run everything concurrently: several ch0/ch2 loop wraps, ch1/ch3
      -- one-shots completing and going silent, noise throughout
      hold(20000);

      -- sanity 1: the tb actually produced sound at some point
      if not any_nonzero then
         nfail := nfail + 1;
         report "tb_sound: never produced a non-silent sample - stimulus or DUT is dead" severity error;
      end if;

      -- sanity 2: disabling the master silences output. accl/accr only
      -- reset at mixcnt=1023 and finalize at mixcnt=16, so a disable
      -- mid-window still finalizes on already-accumulated energy for up
      -- to one full 1024-cycle window - wait past two full windows
      -- before expecting silence.
      regw(16#500#, x"00000000", "0011");
      hold(2100);
      if (sample_l /= x"0000" or sample_r /= x"0000") then
         nfail := nfail + 1;
         report "tb_sound: master-disable did not silence output (L=" &
                to_hstring(sample_l) & " R=" & to_hstring(sample_r) & ")" severity error;
      end if;

      if (nfail = 0) then
         report "tb_sound: PASS  " & integer'image(sample_idx) & " samples captured" severity note;
      else
         report "tb_sound: FAIL  " & integer'image(nfail) & " sanity check(s) failed" severity failure;
      end if;

      tests_done <= true;
      wait;
   end process;

   p_watchdog : process
   begin
      wait for TIMEOUT_MS * 1 ms;
      if not tests_done then
         report "tb_sound: TIMEOUT" severity failure;
      end if;
      wait;
   end process;

end architecture;
