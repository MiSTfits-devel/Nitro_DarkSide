-- Self-checking unit test for nds_vram_map.
-- Vectors transcribed from NitroSDK libraries/gx/src/gx_vramcnt.c (MST truth table)
-- and GBATEK "DS Video Memory Control". Run: sim/run_vram_map_tb.sh

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.pnds_vram_map.all;

entity tb_vram_map is
end entity;

architecture sim of tb_vram_map is

   signal vramcnt : std_logic_vector(71 downto 0) := (others => '0');
   signal addr    : unsigned(23 downto 0)         := (others => '0');
   signal is_arm7 : std_logic                     := '0';
   signal hit     : std_logic_vector(8 downto 0);
   signal offs    : t_vram_offs;

   function cntbyte(mst : integer; ofs : integer; ena : std_logic := '1') return std_logic_vector is
      variable r : std_logic_vector(7 downto 0);
   begin
      r := ena & "00" & std_logic_vector(to_unsigned(ofs, 2)) & std_logic_vector(to_unsigned(mst, 3));
      return r;
   end function;

   function make_cnt(bank : integer; mst : integer; ofs : integer; ena : std_logic := '1') return std_logic_vector is
      variable r : std_logic_vector(71 downto 0) := (others => '0');
   begin
      r(bank*8 + 7 downto bank*8) := cntbyte(mst, ofs, ena);
      return r;
   end function;

   type t_vec is record
      bank : integer;             -- BANK_A..BANK_I
      mst  : integer;
      ofs  : integer;
      arm7 : std_logic;           -- query CPU
      base : integer;             -- expected mapped base (bits 23:0 of 0x06xxxxxx)
      size : integer;             -- bank size in bytes
   end record;
   type t_vec_arr is array (natural range <>) of t_vec;

   constant vecs : t_vec_arr := (
      -- ============ bank A ============
      (BANK_A, 0, 0, '0', 16#800000#, 16#20000#),   -- LCDC
      (BANK_A, 1, 0, '0', 16#000000#, 16#20000#),   -- main BG, all four OFS
      (BANK_A, 1, 1, '0', 16#020000#, 16#20000#),
      (BANK_A, 1, 2, '0', 16#040000#, 16#20000#),
      (BANK_A, 1, 3, '0', 16#060000#, 16#20000#),
      (BANK_A, 2, 0, '0', 16#400000#, 16#20000#),   -- main OBJ
      (BANK_A, 2, 1, '0', 16#420000#, 16#20000#),
      -- ============ bank B ============
      (BANK_B, 0, 0, '0', 16#820000#, 16#20000#),
      (BANK_B, 1, 2, '0', 16#040000#, 16#20000#),
      (BANK_B, 2, 1, '0', 16#420000#, 16#20000#),
      -- ============ bank C ============
      (BANK_C, 0, 0, '0', 16#840000#, 16#20000#),
      (BANK_C, 1, 1, '0', 16#020000#, 16#20000#),
      (BANK_C, 2, 0, '1', 16#000000#, 16#20000#),   -- ARM7 WRAM slot 0
      (BANK_C, 2, 1, '1', 16#020000#, 16#20000#),   -- ARM7 WRAM slot 1
      (BANK_C, 4, 0, '0', 16#200000#, 16#20000#),   -- sub BG
      -- ============ bank D ============
      (BANK_D, 0, 0, '0', 16#860000#, 16#20000#),
      (BANK_D, 1, 3, '0', 16#060000#, 16#20000#),
      (BANK_D, 2, 1, '1', 16#020000#, 16#20000#),   -- ARM7 WRAM slot 1
      (BANK_D, 4, 0, '0', 16#600000#, 16#20000#),   -- sub OBJ
      -- ============ bank E ============
      (BANK_E, 0, 0, '0', 16#880000#, 16#10000#),
      (BANK_E, 1, 0, '0', 16#000000#, 16#10000#),
      (BANK_E, 2, 0, '0', 16#400000#, 16#10000#),
      -- ============ bank F ============
      (BANK_F, 0, 0, '0', 16#890000#, 16#04000#),
      (BANK_F, 1, 0, '0', 16#000000#, 16#04000#),   -- OFS -> 0 / 0x4000 / 0x10000 / 0x14000
      (BANK_F, 1, 1, '0', 16#004000#, 16#04000#),
      (BANK_F, 1, 2, '0', 16#010000#, 16#04000#),
      (BANK_F, 1, 3, '0', 16#014000#, 16#04000#),
      (BANK_F, 2, 2, '0', 16#410000#, 16#04000#),
      -- ============ bank G ============
      (BANK_G, 0, 0, '0', 16#894000#, 16#04000#),
      (BANK_G, 1, 1, '0', 16#004000#, 16#04000#),
      (BANK_G, 2, 3, '0', 16#414000#, 16#04000#),
      -- ============ bank H ============
      (BANK_H, 0, 0, '0', 16#898000#, 16#08000#),
      (BANK_H, 1, 0, '0', 16#200000#, 16#08000#),   -- sub BG
      -- ============ bank I ============
      (BANK_I, 0, 0, '0', 16#8A0000#, 16#04000#),
      (BANK_I, 1, 0, '0', 16#208000#, 16#04000#),   -- sub BG second slot
      (BANK_I, 2, 0, '0', 16#600000#, 16#04000#)    -- sub OBJ
   );

   -- probes that must produce NO hit anywhere
   type t_neg is record
      bank : integer;
      mst  : integer;
      ofs  : integer;
      ena  : std_logic;
      arm7 : std_logic;
      a    : integer;
   end record;
   type t_neg_arr is array (natural range <>) of t_neg;

   constant negs : t_neg_arr := (
      (BANK_A, 3, 0, '1', '0', 16#000000#),  -- texture mode: no CPU mapping (BG addr)
      (BANK_A, 3, 0, '1', '0', 16#800000#),  -- texture mode: not at LCDC either
      (BANK_A, 1, 0, '0', '0', 16#000000#),  -- disabled bank
      (BANK_A, 1, 0, '1', '1', 16#000000#),  -- ARM7 cannot see main BG mapping
      (BANK_C, 2, 0, '1', '0', 16#000000#),  -- ARM9 cannot see the ARM7 slot
      (BANK_E, 4, 0, '1', '0', 16#880000#),  -- BG ext palette: no CPU mapping
      (BANK_F, 5, 0, '1', '0', 16#890000#),  -- OBJ ext palette: no CPU mapping
      (BANK_H, 2, 0, '1', '0', 16#898000#),  -- sub BG ext palette: no CPU mapping
      (BANK_A, 0, 0, '1', '0', 16#820000#),  -- A in LCDC must not answer at B's slot
      (BANK_A, 1, 1, '1', '0', 16#000000#),  -- OFS=1 must not answer at slot 0
      (BANK_I, 1, 0, '1', '0', 16#200000#)   -- I sub BG sits at +0x8000, not 0
   );

   signal tests_done : boolean := false;

begin

   uut : entity work.nds_vram_map
   port map
   (
      vramcnt => vramcnt,
      addr    => addr,
      is_arm7 => is_arm7,
      hit     => hit,
      offs    => offs
   );

   process
      variable v        : t_vec;
      variable n        : t_neg;
      variable exp_hit  : std_logic_vector(8 downto 0);
      variable passcnt  : integer := 0;
   begin

      -- ================= positive vectors: base and last byte =================
      for k in vecs'range loop
         v := vecs(k);
         exp_hit := (others => '0');
         exp_hit(v.bank) := '1';

         vramcnt <= make_cnt(v.bank, v.mst, v.ofs);
         is_arm7 <= v.arm7;
         addr    <= to_unsigned(v.base, 24);
         wait for 1 ns;
         assert hit = exp_hit
            report "vec " & integer'image(k) & ": base hit mismatch, bank " & integer'image(v.bank) &
                   " mst " & integer'image(v.mst) & " ofs " & integer'image(v.ofs)
            severity failure;
         assert to_integer(offs(v.bank)) = 0
            report "vec " & integer'image(k) & ": base offset /= 0"
            severity failure;

         addr <= to_unsigned(v.base + v.size - 1, 24);
         wait for 1 ns;
         assert hit = exp_hit
            report "vec " & integer'image(k) & ": last-byte hit mismatch"
            severity failure;
         assert to_integer(offs(v.bank)) = v.size - 1
            report "vec " & integer'image(k) & ": last-byte offset mismatch, got " &
                   integer'image(to_integer(offs(v.bank)))
            severity failure;

         passcnt := passcnt + 2;
      end loop;

      -- ================= negative vectors =================
      for k in negs'range loop
         n := negs(k);
         vramcnt <= make_cnt(n.bank, n.mst, n.ofs, n.ena);
         is_arm7 <= n.arm7;
         addr    <= to_unsigned(n.a, 24);
         wait for 1 ns;
         assert hit = "000000000"
            report "neg " & integer'image(k) & ": unexpected hit " & to_string(hit)
            severity failure;
         passcnt := passcnt + 1;
      end loop;

      -- ================= overlap: A and B both main BG slot 0 =================
      vramcnt <= make_cnt(BANK_A, 1, 0) or make_cnt(BANK_B, 1, 0);
      is_arm7 <= '0';
      addr    <= to_unsigned(16#010000#, 24);
      wait for 1 ns;
      assert hit(BANK_A) = '1' and hit(BANK_B) = '1'
         report "overlap: A+B should both hit" severity failure;
      assert to_integer(offs(BANK_A)) = 16#10000# and to_integer(offs(BANK_B)) = 16#10000#
         report "overlap: offsets wrong" severity failure;
      passcnt := passcnt + 1;

      report "tb_vram_map: PASS, " & integer'image(passcnt) & " checks" severity note;
      tests_done <= true;
      wait;
   end process;

end architecture;
