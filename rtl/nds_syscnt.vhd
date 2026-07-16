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
      exmem_gba7   : out std_logic;   -- GBA slot belongs to ARM7
      exmem_card7  : out std_logic;   -- NDS card belongs to ARM7
      exmem_prio7  : out std_logic    -- main-memory priority to ARM7
   );
end entity;

architecture arch of nds_syscnt is

   constant ADR_EXMEM : std_logic_vector(27 downto 0) := x"0000204";
   constant ADR_WRAM  : std_logic_vector(27 downto 0) := x"0000240"; -- 0x241/0x247 word base is 0x240/0x244
   constant ADR_WRAM9 : std_logic_vector(27 downto 0) := x"0000244";

   signal exmem9    : std_logic_vector(15 downto 0) := x"6580"; -- post-BIOS-ish default
   signal exmem7lo  : std_logic_vector(6 downto 0)  := (others => '0');
   signal r_wramcnt : std_logic_vector(1 downto 0)  := "00";

   signal exmem9_rd, exmem7_rd : std_logic_vector(15 downto 0);

begin

   exmem9_rd <= exmem9(15 downto 14) & '1' & exmem9(12 downto 0);
   exmem7_rd <= exmem9(15 downto 14) & '1' & exmem9(12 downto 7) & exmem7lo;

   wired_out9 <= x"0000" & exmem9_rd when (bus9.Adr = ADR_EXMEM) else
                 "000000" & r_wramcnt & x"000000" when (bus9.Adr = ADR_WRAM9) else -- 0x247 = byte 3
                 (others => '0');
   wired_done9 <= '1' when (bus9.Adr = ADR_EXMEM or bus9.Adr = ADR_WRAM9 or bus9.Adr = ADR_WRAM) else '0';

   wired_out7 <= x"0000" & exmem7_rd when (bus7.Adr = ADR_EXMEM) else
                 x"0000" & "000000" & r_wramcnt & x"00" when (bus7.Adr = ADR_WRAM) else
                 (others => '0');
   wired_done7 <= '1' when (bus7.Adr = ADR_EXMEM or bus7.Adr = ADR_WRAM) else '0';

   wramcnt     <= r_wramcnt;
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
         else
            if (bus9.ena = '1' and bus9.rnw = '0') then
               if (bus9.Adr = ADR_EXMEM) then
                  if (bus9.bEna(0) = '1') then exmem9(7 downto 0)  <= bus9.Din(7 downto 0);  end if;
                  if (bus9.bEna(1) = '1') then exmem9(15 downto 8) <= bus9.Din(15 downto 8); end if;
               elsif (bus9.Adr = ADR_WRAM9 and bus9.bEna(3) = '1') then
                  r_wramcnt <= bus9.Din(25 downto 24);           -- byte 0x247
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
