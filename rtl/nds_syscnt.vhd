-- SPDX-License-Identifier: GPL-2.0-or-later
-- NDS system-control registers shared between the two CPUs (M4):
--
--   EXMEMCNT  0x04000204 (ARM9, r/w 16 bit): GBA-slot timings [6:0], GBA-slot
--             rights [7], NDS-card rights [11], main-memory mode [14],
--             main-memory priority [15]. Bit 13 reads as 1.
--   EXMEMSTAT 0x04000204 (ARM7): [6:0] are the ARM7's own private timing
--             copy (r/w); [15:7] mirror the ARM9 register read-only.
--   WRAMCNT   0x04000247 (ARM9, r/w 8 bit, [1:0] used) - shared-WRAM mapping,
--             wired straight to nds_wram.
--   WRAMSTAT  0x04000241 (ARM7, read-only view of WRAMCNT).
--   VRAMCNT_A..I 0x240..0x246 / 0x248..0x249 (ARM9, write-only bytes) -
--             bank mapping, wired straight to nds_vram/nds_vram_map
--             (vramcnt(8k+7 downto 8k) = bank k, A = 0). Reads return 0.
--   VRAMSTAT  0x04000240 (ARM7, read-only): bit0/1 = bank C/D mapped as
--             ARM7 WRAM (MST=2).
--
-- Register semantics per GBATEK / melonDS.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity nds_syscnt is
   port
   (
      clk          : in  std_logic;
      reset        : in  std_logic;

      bus9         : in  proc_bus_gb_type;
      wired_out9   : out std_logic_vector(31 downto 0);
      wired_done9  : out std_logic;

      bus7         : in  proc_bus_gb_type;
      wired_out7   : out std_logic_vector(31 downto 0);
      wired_done7  : out std_logic;

      wramcnt      : out std_logic_vector(1 downto 0);
      vramcnt      : out std_logic_vector(71 downto 0);
      exmem_gba7   : out std_logic;   -- GBA slot belongs to ARM7
      exmem_card7  : out std_logic;   -- NDS card belongs to ARM7
      exmem_prio7  : out std_logic    -- main-memory priority to ARM7
   );
end entity;

architecture arch of nds_syscnt is

   constant ADR_EXMEM : std_logic_vector(27 downto 0) := x"0000204";
   constant ADR_WRAM  : std_logic_vector(27 downto 0) := x"0000240"; -- 0x241/0x247 word base is 0x240/0x244
   constant ADR_WRAM9 : std_logic_vector(27 downto 0) := x"0000244";
   constant ADR_VRAMHI : std_logic_vector(27 downto 0) := x"0000248";

   signal exmem9    : std_logic_vector(15 downto 0) := x"6580"; -- post-BIOS-ish default
   signal exmem7lo  : std_logic_vector(6 downto 0)  := (others => '0');
   signal r_wramcnt : std_logic_vector(1 downto 0)  := "00";
   signal r_vramcnt : std_logic_vector(71 downto 0) := (others => '0');

   signal exmem9_rd, exmem7_rd : std_logic_vector(15 downto 0);
   signal vramstat  : std_logic_vector(1 downto 0);

begin

   exmem9_rd <= exmem9(15 downto 14) & '1' & exmem9(12 downto 0);
   exmem7_rd <= exmem9(15 downto 14) & '1' & exmem9(12 downto 7) & exmem7lo;

   wired_out9 <= x"0000" & exmem9_rd when (bus9.Adr = ADR_EXMEM) else
                 "000000" & r_wramcnt & x"000000" when (bus9.Adr = ADR_WRAM9) else -- 0x247 = byte 3
                 (others => '0');
   wired_done9 <= '1' when (bus9.Adr = ADR_EXMEM or bus9.Adr = ADR_WRAM9 or
                            bus9.Adr = ADR_WRAM or bus9.Adr = ADR_VRAMHI) else '0';

   -- VRAMSTAT: bank C/D mapped as ARM7 WRAM (enabled, MST=2)
   vramstat(0) <= '1' when (r_vramcnt(23 downto 16) and x"87") = x"82" else '0';
   vramstat(1) <= '1' when (r_vramcnt(31 downto 24) and x"87") = x"82" else '0';

   wired_out7 <= x"0000" & exmem7_rd when (bus7.Adr = ADR_EXMEM) else
                 x"0000" & "000000" & r_wramcnt & "000000" & vramstat when (bus7.Adr = ADR_WRAM) else
                 (others => '0');
   wired_done7 <= '1' when (bus7.Adr = ADR_EXMEM or bus7.Adr = ADR_WRAM) else '0';

   wramcnt     <= r_wramcnt;
   vramcnt     <= r_vramcnt;
   exmem_gba7  <= exmem9(7);
   exmem_card7 <= exmem9(11);
   exmem_prio7 <= exmem9(15);

   process (clk)
   begin
      if rising_edge(clk) then
         if (reset = '1') then
            exmem9    <= x"6580";
            exmem7lo  <= (others => '0');
            r_wramcnt <= "00";
            r_vramcnt <= (others => '0');
         else
            if (bus9.ena = '1' and bus9.rnw = '0') then
               if (bus9.Adr = ADR_EXMEM) then
                  if (bus9.bEna(0) = '1') then exmem9(7 downto 0)  <= bus9.Din(7 downto 0);  end if;
                  if (bus9.bEna(1) = '1') then exmem9(15 downto 8) <= bus9.Din(15 downto 8); end if;
               elsif (bus9.Adr = ADR_WRAM) then
                  -- VRAMCNT_A..D, bytes 0x240..0x243
                  for i in 0 to 3 loop
                     if (bus9.bEna(i) = '1') then
                        r_vramcnt(i*8 + 7 downto i*8) <= bus9.Din(i*8 + 7 downto i*8);
                     end if;
                  end loop;
               elsif (bus9.Adr = ADR_WRAM9) then
                  -- VRAMCNT_E..G, bytes 0x244..0x246; WRAMCNT byte 0x247
                  for i in 0 to 2 loop
                     if (bus9.bEna(i) = '1') then
                        r_vramcnt(32 + i*8 + 7 downto 32 + i*8) <= bus9.Din(i*8 + 7 downto i*8);
                     end if;
                  end loop;
                  if (bus9.bEna(3) = '1') then
                     r_wramcnt <= bus9.Din(25 downto 24);        -- byte 0x247
                  end if;
               elsif (bus9.Adr = ADR_VRAMHI) then
                  -- VRAMCNT_H..I, bytes 0x248..0x249
                  for i in 0 to 1 loop
                     if (bus9.bEna(i) = '1') then
                        r_vramcnt(56 + i*8 + 7 downto 56 + i*8) <= bus9.Din(i*8 + 7 downto i*8);
                     end if;
                  end loop;
               end if;
            end if;
            if (bus7.ena = '1' and bus7.rnw = '0' and bus7.Adr = ADR_EXMEM) then
               if (bus7.bEna(0) = '1') then
                  exmem7lo <= bus7.Din(6 downto 0);
               end if;
            end if;
         end if;
      end if;
   end process;

end architecture;
