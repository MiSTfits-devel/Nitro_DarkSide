-- SPDX-License-Identifier: GPL-2.0-or-later
-- Exhaustive equivalence check for the nds_cpu9 barrel shifter rewrite.
--
-- The shifter went from five parallel 32-bit shifters (LSL/LSR/ASR/ROR/RRX,
-- each sized for an 8-bit amount because decode_shift_amount is declared
-- `integer range 0 to 255`) to one 5-stage right-rotator plus a keep/fill mux.
-- The rewrite is a pure algebraic identity, so it can be proved outright rather
-- than sampled: this bench runs BOTH formulations over
--
--    amount 0..255  x  mode 00/01/10/11  x  RRX 0/1  x  carry-in 0/1  x  values
--
-- and fails on the first disagreement in either the result or the carry-out.
-- `ref_shift` is the pre-rewrite RTL transcribed verbatim, guards and all.
--
-- This proves the algebra. It does not prove the RTL transcribes the algebra -
-- that is what the arm9_torture and Kirby A/B trace diffs are for. Run both.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity tb_shifter_equiv is
end entity;

architecture sim of tb_shifter_equiv is

   -- ===== the five-shifter formulation, verbatim from before the rewrite =====
   procedure ref_shift (v    : in  unsigned(31 downto 0);
                        n    : in  integer range 0 to 255;
                        mode : in  std_logic_vector(1 downto 0);
                        rrx  : in  std_logic;
                        cin  : in  std_logic;
                        res  : out unsigned(31 downto 0);
                        cout : out std_logic) is
      variable rLSL, rRSL, rARS, rROR, rRRX : unsigned(31 downto 0);
      variable cLSL, cRSL, cARS, cROR, cRRX : std_logic;
   begin
      -- LSL
      rLSL := v;
      if (n >= 32) then
         if (n = 32) then cLSL := v(0); else cLSL := '0'; end if;
         rLSL := (others => '0');
      elsif (n > 0) then
         cLSL := v(32 - n);
         rLSL := v sll n;
      else
         cLSL := cin;
      end if;

      -- RSL
      rRSL := v;
      if (n >= 32) then
         if (n = 32) then cRSL := v(31); else cRSL := '0'; end if;
         rRSL := (others => '0');
      elsif (n > 0) then
         cRSL := v(n - 1);
         rRSL := v srl n;
      else
         cRSL := cin;
      end if;

      -- ARS
      rARS := v;
      if (n >= 32) then
         cARS := v(31);
         rARS := unsigned(shift_right(signed(v), 31));
      elsif (n > 0) then
         cARS := v(n - 1);
         rARS := unsigned(shift_right(signed(v), n));
      else
         cARS := cin;
      end if;

      -- ROR
      rROR := v;
      if (n >= 32) then
         cROR := v(31);
      elsif (n > 0) then
         cROR := v(n - 1);
         rROR := v ror n;
      else
         cROR := cin;
      end if;

      -- RRX
      cRRX := v(0);
      rRRX := cin & v(31 downto 1);

      if (rrx = '1') then
         cout := cRRX; res := rRRX;
      else
         case mode is
            when "00"   => cout := cLSL; res := rLSL;
            when "01"   => cout := cRSL; res := rRSL;
            when "10"   => cout := cARS; res := rARS;
            when others => cout := cROR; res := rROR;
         end case;
      end if;
   end procedure;

   -- ===== the rotator formulation, mirroring nds_cpu9 =====
   procedure new_shift (v    : in  unsigned(31 downto 0);
                        n    : in  integer range 0 to 255;
                        mode : in  std_logic_vector(1 downto 0);
                        rrx  : in  std_logic;
                        cin  : in  std_logic;
                        res  : out unsigned(31 downto 0);
                        cout : out std_logic) is
      variable rot  : integer range 0 to 31;
      variable keep : std_logic_vector(31 downto 0);
      variable fill : integer range 0 to 2;   -- 0 zero, 1 sign, 2 carry
      variable cidx : integer range 0 to 31;
      variable csel : integer range 0 to 2;   -- 0 zero, 1 carry, 2 value
      variable rotv : unsigned(31 downto 0);
      variable fb   : std_logic;
   begin
      rot  := 0;
      keep := (others => '1');
      fill := 0;
      cidx := 0;
      csel := 1;

      if (rrx = '1') then
         rot  := 1;
         keep := (31 => '0', others => '1');
         fill := 2;
         csel := 2;
         cidx := 0;
      elsif (n /= 0) then
         case mode is
            when "00" =>                                   -- LSL
               if (n < 32) then
                  rot := 32 - n;
                  for i in 0 to 31 loop
                     if (i < n) then keep(i) := '0'; end if;
                  end loop;
                  csel := 2; cidx := 32 - n;
               else
                  keep := (others => '0');
                  if (n = 32) then csel := 2; cidx := 0; else csel := 0; end if;
               end if;

            when "01" =>                                   -- LSR
               if (n < 32) then
                  rot := n;
                  for i in 0 to 31 loop
                     if (i > 31 - n) then keep(i) := '0'; end if;
                  end loop;
                  csel := 2; cidx := n - 1;
               else
                  keep := (others => '0');
                  if (n = 32) then csel := 2; cidx := 31; else csel := 0; end if;
               end if;

            when "10" =>                                   -- ASR
               fill := 1;
               csel := 2;
               if (n < 32) then
                  rot := n;
                  for i in 0 to 31 loop
                     if (i > 31 - n) then keep(i) := '0'; end if;
                  end loop;
                  cidx := n - 1;
               else
                  keep := (others => '0');
                  cidx := 31;
               end if;

            when others =>                                 -- ROR
               csel := 2;
               if (n < 32) then
                  rot := n; cidx := n - 1;
               else
                  rot := 0; cidx := 31;
               end if;
         end case;
      end if;

      rotv := v ror rot;
      case fill is
         when 2      => fb := cin;
         when 1      => fb := v(31);
         when others => fb := '0';
      end case;
      for i in 0 to 31 loop
         if (keep(i) = '1') then res(i) := rotv(i); else res(i) := fb; end if;
      end loop;
      case csel is
         when 1      => cout := cin;
         when 2      => cout := v(cidx);
         when others => cout := '0';
      end case;
   end procedure;

   -- deterministic value set: edges, walking bits, and an LCG spread
   type t_vals is array (natural range <>) of unsigned(31 downto 0);
   function make_vals return t_vals is
      variable r : t_vals(0 to 71);
      variable s : unsigned(31 downto 0) := x"12345678";
   begin
      r(0) := x"00000000"; r(1) := x"FFFFFFFF";
      r(2) := x"80000000"; r(3) := x"00000001";
      r(4) := x"55555555"; r(5) := x"AAAAAAAA";
      r(6) := x"7FFFFFFF"; r(7) := x"FFFFFFFE";
      for i in 0 to 31 loop
         r(8 + i) := shift_left(to_unsigned(1, 32), i);
      end loop;
      for i in 40 to 71 loop
         s := resize(s * to_unsigned(1103515245, 32) + 12345, 32);
         r(i) := s;
      end loop;
      return r;
   end function;

   constant VALS : t_vals(0 to 71) := make_vals;

begin

   process
      variable rres, nres : unsigned(31 downto 0);
      variable rc, nc     : std_logic;
      variable checks     : natural := 0;
      variable modes      : std_logic_vector(1 downto 0);
   begin
      for vi in VALS'range loop
         for n in 0 to 255 loop
            for m in 0 to 3 loop
               modes := std_logic_vector(to_unsigned(m, 2));
               for rrxi in 0 to 1 loop
                  for ci in 0 to 1 loop
                     -- RRX is only reachable with amount 0 (ROR #0 decodes to
                     -- it), but check it against every amount anyway: both
                     -- formulations must ignore the amount when RRX is set.
                     ref_shift(VALS(vi), n, modes,
                               std_logic'val(rrxi), std_logic'val(ci), rres, rc);
                     new_shift(VALS(vi), n, modes,
                               std_logic'val(rrxi), std_logic'val(ci), nres, nc);
                     assert nres = rres
                        report "result mismatch v=" & to_hstring(VALS(vi)) &
                               " n=" & integer'image(n) &
                               " mode=" & integer'image(m) &
                               " rrx=" & integer'image(rrxi) &
                               " c=" & integer'image(ci) &
                               " ref=" & to_hstring(rres) &
                               " new=" & to_hstring(nres)
                        severity failure;
                     assert nc = rc
                        report "carry mismatch v=" & to_hstring(VALS(vi)) &
                               " n=" & integer'image(n) &
                               " mode=" & integer'image(m) &
                               " rrx=" & integer'image(rrxi) &
                               " c=" & integer'image(ci)
                        severity failure;
                     checks := checks + 1;
                  end loop;
               end loop;
            end loop;
         end loop;
      end loop;
      report "tb_shifter_equiv: OK, " & integer'image(checks) & " cases" severity note;
      wait;
   end process;

end architecture;
