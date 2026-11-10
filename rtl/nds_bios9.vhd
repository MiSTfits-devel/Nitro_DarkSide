-- The file probe is elaboration-time textio; in synthesis the hex is

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.textio.all;

library MEM;

entity nds_bios9 is
   generic
   (
      is_simu : std_logic := '0';
      use_cyclone5_primitive : std_logic := '0'
   );
   port
   (
      clk       : in  std_logic;
      brom_addr : in  unsigned(14 downto 2);
      brom_data : out std_logic_vector(31 downto 0);

      load_addr   : in unsigned(11 downto 2) := (others => '0');
      load_data   : in std_logic_vector(31 downto 0) := (others => '0');
      load_be     : in std_logic_vector(3 downto 0) := (others => '0');
      load_we     : in std_logic := '0';
      load_done   : in std_logic := '0'
   );
end entity;

architecture arch of nds_bios9 is

   type t_rom is array (0 to 1023) of std_logic_vector(31 downto 0);

   type t_hle is array (0 to 79) of std_logic_vector(31 downto 0);
   constant HLE : t_hle := (
      x"EAFFFFFE",
      x"EAFFFFFE",
      x"EA00000E",
      x"EAFFFFFE",
      x"EAFFFFFE",
      x"EAFFFFFE",
      x"EA000000",
      x"EAFFFFFE",
      x"E92D500F",
      x"EE19CF11",
      x"E1A0C62C",
      x"E1A0C60C",
      x"E28CC901",
      x"E51CC004",
      x"E28FE000",
      x"E12FFF1C",
      x"E8BD500F",
      x"E25EF004",
      x"E92D5800",
      x"E14FC000",
      x"E31C0020",
      x"155EB002",
      x"051EB004",
      x"01A0B82B",
      x"E20BB0FF",
      x"E35B0003",
      x"0A000008",
      x"E35B0009",
      x"0A000009",
      x"E35B000E",
      x"0A000024",
      x"E35B000F",
      x"0A000020",
      x"EAFFFFFE",
      x"E8BD5800",
      x"E1B0F00E",
      x"E2500001",
      x"CAFFFFFD",
      x"EAFFFFFA",
      x"E92D0034",
      x"E2104102",
      x"42600000",
      x"E2115102",
      x"42611000",
      x"E3A02000",
      x"E3A0C001",
      x"E1510000",
      x"91A01081",
      x"91A0C08C",
      x"9AFFFFFB",
      x"E1B0C0AC",
      x"0A000004",
      x"E1A010A1",
      x"E1500001",
      x"20400001",
      x"2082200C",
      x"EAFFFFF8",
      x"E1A03002",
      x"E1340005",
      x"42622000",
      x"E1B04004",
      x"42600000",
      x"E1A01000",
      x"E1A00002",
      x"E8BD0034",
      x"EAFFFFDF",
      x"E3A00000",
      x"EAFFFFDD",
      x"E59FC024",
      x"E2522001",
      x"BAFFFFDA",
      x"E4D1B001",
      x"E020000B",
      x"E3A0B008",
      x"E1B000A0",
      x"2020000C",
      x"E25BB001",
      x"1AFFFFFB",
      x"EAFFFFF5",
      x"0000A001"
   );

   impure function init_rom return t_rom is
      file f      : text;
      variable st : file_open_status;
      variable l  : line;
      variable w  : bit_vector(31 downto 0);
      variable m  : t_rom := (others => (others => '0'));
      variable i  : integer := 0;
   begin
      file_open(st, f, "sim/tests/bios9_retail.hex", read_mode);
      if (st = open_ok) then
         for k in t_rom'range loop
            exit when endfile(f);
            readline(f, l);
            hread(l, w);
            m(k) := to_stdlogicvector(w);
            i := i + 1;
         end loop;
         file_close(f);
         report "nds_bios9: serving RETAIL BIOS (" & integer'image(i) & " words)" severity note;
      else
         for k in t_hle'range loop
            m(k) := HLE(k);
         end loop;
         report "nds_bios9: retail hex not found, serving HLE BIOS" severity note;
      end if;
      return m;
   end function;

   signal hot_q   : std_logic_vector(31 downto 0) := (others => '0');
   signal hle_q   : std_logic_vector(31 downto 0) := HLE(0);
   signal hot_valid_q : std_logic := '1';

begin

   gsim : if is_simu = '1' generate
      constant ROM : t_rom := init_rom;
   begin
      process (clk)
      begin
         if rising_edge(clk) then
            if to_integer(brom_addr) <= t_rom'high then
               brom_data <= ROM(to_integer(brom_addr));
            else
               brom_data <= x"00000000";
            end if;
         end if;
      end process;
   end generate;

   ghot : if is_simu = '0' generate
   begin
      ihot : entity MEM.SyncRamDualByteEnable
      generic map
      (
         is_simu     => not use_cyclone5_primitive,
         is_cyclone5 => use_cyclone5_primitive,
         BYTE_WIDTH  => 8,
         ADDR_WIDTH  => 10,
         BYTES       => 4
      )
      port map
      (
         clk       => clk,
         ce_a      => '1',
         addr_a    => to_integer(brom_addr(11 downto 2)),
         datain_a0 => x"00", datain_a1 => x"00", datain_a2 => x"00", datain_a3 => x"00",
         dataout_a => hot_q,
         we_a      => '0',
         be_a      => "0000",
         ce_b      => '1',
         addr_b    => to_integer(load_addr),
         datain_b0 => load_data(7 downto 0),
         datain_b1 => load_data(15 downto 8),
         datain_b2 => load_data(23 downto 16),
         datain_b3 => load_data(31 downto 24),
         dataout_b => open,
         we_b      => load_we,
         be_b      => load_be
      );

      process (clk)
      begin
         if rising_edge(clk) then
            if to_integer(brom_addr) <= t_rom'high then
               hot_valid_q <= '1';
            else
               hot_valid_q <= '0';
            end if;
            if to_integer(brom_addr) <= t_hle'high then
               hle_q <= HLE(to_integer(brom_addr));
            else
               hle_q <= (others => '0');
            end if;
         end if;
      end process;

      brom_data <= hle_q when load_done = '0'
                   else hot_q when hot_valid_q = '1'
                   else x"00000000";
   end generate;

end architecture;
