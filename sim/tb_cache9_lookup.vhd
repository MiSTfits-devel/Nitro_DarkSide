-- SPDX-License-Identifier: GPL-2.0-or-later
-- Focused regression for nds_cache9's synchronous per-way tag lookup.
-- Exercises maintenance arriving (1) in the request lookup cycle and
-- (2) while a miss fill is active, then proves the queued invalidate forces
-- a fresh eight-beat fill rather than hitting a stale or wrong-set tag.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

entity tb_cache9_lookup is
end entity;

architecture sim of tb_cache9_lookup is
   constant CLK_PERIOD : time := 10 ns;
   constant A : std_logic_vector(31 downto 0) := x"02210104";

   signal clk   : std_logic := '0';
   signal reset : std_logic := '1';

   signal req_ena       : std_logic := '0';
   signal req_rnw       : std_logic := '1';
   signal req_code      : std_logic := '0';
   signal req_cacheable : std_logic := '1';
   signal req_addr      : std_logic_vector(31 downto 0) := (others => '0');
   signal req_be        : std_logic_vector(3 downto 0) := "1111";
   signal req_wdata     : std_logic_vector(31 downto 0) := (others => '0');
   signal resp_done     : std_logic;
   signal resp_rdata    : std_logic_vector(31 downto 0);

   signal mem_ena   : std_logic;
   signal mem_rnw   : std_logic;
   signal mem_addr  : std_logic_vector(21 downto 2);
   signal mem_be    : std_logic_vector(3 downto 0);
   signal mem_wdata : std_logic_vector(31 downto 0);
   signal mem_done  : std_logic := '0';
   signal mem_rdata : std_logic_vector(31 downto 0) := (others => '0');

   signal op_ena  : std_logic := '0';
   signal op      : std_logic_vector(3 downto 0) := (others => '0');
   signal op_addr : std_logic_vector(31 downto 0) := (others => '0');
   signal op_busy : std_logic;

   signal mem_epoch : natural range 0 to 15 := 1;
   signal read_beats : natural := 0;

   function backing_word(
      a : std_logic_vector(21 downto 2);
      e : natural
   ) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned(e, 4)) & a(21 downto 2) & x"5A";
   end function;
begin
   clk <= not clk after CLK_PERIOD / 2;

   dut : entity work.nds_cache9
      generic map (is_simu => '1')
      port map
      (
         clk => clk, reset => reset,
         req_ena => req_ena, req_rnw => req_rnw, req_code => req_code,
         req_cacheable => req_cacheable, req_addr => req_addr,
         req_be => req_be, req_wdata => req_wdata,
         resp_done => resp_done, resp_rdata => resp_rdata,
         mem_ena => mem_ena, mem_rnw => mem_rnw, mem_addr => mem_addr,
         mem_be => mem_be, mem_wdata => mem_wdata,
         mem_done => mem_done, mem_rdata => mem_rdata,
         op_ena => op_ena, op => op, op_addr => op_addr, op_busy => op_busy
      );

   -- One-cycle memory response. This test performs reads only; writes are a
   -- failure because all exercised lines remain clean.
   p_memory : process (clk)
   begin
      if rising_edge(clk) then
         mem_done <= mem_ena;
         if (mem_ena = '1') then
            assert mem_rnw = '1'
               report "unexpected writeback in clean-line lookup test"
               severity failure;
            mem_rdata <= backing_word(mem_addr, mem_epoch);
            read_beats <= read_beats + 1;
         end if;
      end if;
   end process;

   p_stim : process
      procedure pulse_invalidate_d(constant addr : std_logic_vector(31 downto 0)) is
      begin
         op      <= "0011"; -- invalidate D line by MVA, without clean
         op_addr <= addr;
         op_ena  <= '1';
         wait until rising_edge(clk);
         op_ena  <= '0';
      end procedure;

      procedure start_read(constant addr : std_logic_vector(31 downto 0)) is
      begin
         req_addr <= addr;
         req_rnw  <= '1';
         req_code <= '0';
         req_ena  <= '1';
         wait until rising_edge(clk);
         req_ena  <= '0';
      end procedure;

      procedure await_read(constant expected : std_logic_vector(31 downto 0)) is
      begin
         while resp_done /= '1' loop
            wait until rising_edge(clk);
         end loop;
         assert resp_rdata = expected
            report "cache response mismatch: got " & to_hstring(resp_rdata) &
                   " expected " & to_hstring(expected)
            severity failure;
         wait until rising_edge(clk);
      end procedure;

      variable before : natural;
   begin
      wait for 4 * CLK_PERIOD;
      wait until rising_edge(clk);
      reset <= '0';
      wait until rising_edge(clk);

      -- Cold miss: establish a resident clean D line.
      before := read_beats;
      start_read(A);
      await_read(backing_word(A(21 downto 2), 1));
      assert read_beats = before + 8 report "cold fill was not eight beats" severity failure;

      -- A maintenance pulse arrives in the newly-added REQ_LOOKUP cycle.
      -- The hit must still retire correctly; the op then invalidates the line.
      before := read_beats;
      start_read(A);
      pulse_invalidate_d(A);
      await_read(backing_word(A(21 downto 2), 1));
      while op_busy = '1' loop
         wait until rising_edge(clk);
      end loop;
      assert read_beats = before report "lookup-cycle hit unexpectedly refilled" severity failure;

      mem_epoch <= 2;
      wait until rising_edge(clk);
      before := read_beats;
      start_read(A);
      await_read(backing_word(A(21 downto 2), 2));
      assert read_beats = before + 8
         report "lookup-cycle invalidate did not remove the resident line"
         severity failure;

      -- Queue invalidate while the next refill is in flight. It must execute
      -- after fill completion and invalidate the newly-installed tag.
      pulse_invalidate_d(A);
      while op_busy = '1' loop
         wait until rising_edge(clk);
      end loop;
      mem_epoch <= 3;
      wait until rising_edge(clk);
      before := read_beats;
      start_read(A);
      while read_beats = before loop
         wait until rising_edge(clk);
      end loop;
      pulse_invalidate_d(A);
      await_read(backing_word(A(21 downto 2), 3));
      while op_busy = '1' loop
         wait until rising_edge(clk);
      end loop;
      assert read_beats = before + 8 report "fill-race request did not fill once" severity failure;

      mem_epoch <= 4;
      wait until rising_edge(clk);
      before := read_beats;
      start_read(A);
      await_read(backing_word(A(21 downto 2), 4));
      assert read_beats = before + 8
         report "fill-window invalidate raced and left the new tag valid"
         severity failure;

      report "tb_cache9_lookup: PASS" severity note;
      stop;
      wait;
   end process;

   p_timeout : process
   begin
      wait for 20 us;
      assert false report "tb_cache9_lookup timeout" severity failure;
   end process;
end architecture;
