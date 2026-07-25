library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_bios_hotload is
end entity;

architecture sim of tb_bios_hotload is
   signal clk : std_logic := '0';

   signal a7       : unsigned(13 downto 2) := (others => '0');
   signal q7       : std_logic_vector(31 downto 0);
   signal la7      : unsigned(13 downto 2) := (others => '0');
   signal ld7      : std_logic_vector(31 downto 0) := (others => '0');
   signal be7      : std_logic_vector(3 downto 0) := (others => '0');
   signal we7      : std_logic := '0';
   signal loaded7  : std_logic := '0';

   signal a9       : unsigned(14 downto 2) := (others => '0');
   signal q9       : std_logic_vector(31 downto 0);
   signal la9      : unsigned(11 downto 2) := (others => '0');
   signal ld9      : std_logic_vector(31 downto 0) := (others => '0');
   signal be9      : std_logic_vector(3 downto 0) := (others => '0');
   signal we9      : std_logic := '0';
   signal loaded9  : std_logic := '0';
   signal q7sim, q9sim : std_logic_vector(31 downto 0);
begin
   clk <= not clk after 5 ns;

   i7 : entity work.nds_bios7
   generic map ( is_simu => '0' )
   port map
   (
      clk => clk, bios_addr => a7, bios_data => q7,
      load_addr => la7, load_data => ld7, load_be => be7,
      load_we => we7, load_done => loaded7
   );

   i9 : entity work.nds_bios9
   generic map ( is_simu => '0' )
   port map
   (
      clk => clk, brom_addr => a9, brom_data => q9,
      load_addr => la9, load_data => ld9, load_be => be9,
      load_we => we9, load_done => loaded9
   );

   -- Retail-file simulation path must have the same registered-read timing
   -- as the writable hardware RAM.  The integrated CPU trace depends on the
   -- address remaining associated with the accepted request at exceptions.
   i7sim : entity work.nds_bios7
   generic map ( is_simu => '1' )
   port map (clk => clk, bios_addr => a7, bios_data => q7sim);

   i9sim : entity work.nds_bios9
   generic map ( is_simu => '1' )
   port map (clk => clk, brom_addr => a9, brom_data => q9sim);

   process
      procedure tick is
      begin
         wait until rising_edge(clk);
         wait for 1 ns;
      end procedure;
   begin
      -- Until a complete download is committed, hardware must execute the
      -- built-in HLE vectors even if the writable RAM is being populated.
      wait for 1 ns;
      assert q7 = x"EAFFFFFE" report "BIOS7 HLE fallback missing" severity failure;
      assert q9 = x"EAFFFFFE" report "BIOS9 HLE fallback missing" severity failure;

      -- The fallback must use the registered M10K-style read timing too;
      -- an asynchronous fallback would close a combinational loop through
      -- the CPU address/data interface in hardware.
      a7 <= to_unsigned(2, a7'length);
      a9 <= to_unsigned(2, a9'length);
      tick;
      assert q7 = x"EA00000A" report "BIOS7 registered HLE read mismatch" severity failure;
      assert q9 = x"EA00000E" report "BIOS9 registered HLE read mismatch" severity failure;
      assert q7sim = x"EA000B73" report "BIOS7 retail SWI vector mismatch" severity failure;
      assert q9sim = x"EA0000A2" report "BIOS9 retail SWI vector mismatch" severity failure;
      a7 <= to_unsigned(3, a7'length);
      a9 <= to_unsigned(3, a9'length);
      wait for 1 ns;
      assert q7sim = x"EA000B73" report "BIOS7 simulation read is asynchronous" severity failure;
      assert q9sim = x"EA0000A2" report "BIOS9 simulation read is asynchronous" severity failure;
      a7 <= (others => '0');
      a9 <= (others => '0');
      tick;

      la7 <= to_unsigned(0, la7'length);
      ld7 <= x"11223344";
      be7 <= "1111";
      we7 <= '1';
      la9 <= to_unsigned(0, la9'length);
      ld9 <= x"55667788";
      be9 <= "1111";
      we9 <= '1';
      tick;
      we7 <= '0';
      we9 <= '0';
      tick;
      assert q7 = x"EAFFFFFE" report "BIOS7 switched before load_done" severity failure;
      assert q9 = x"EAFFFFFE" report "BIOS9 switched before load_done" severity failure;

      loaded7 <= '1';
      loaded9 <= '1';
      tick;
      assert q7 = x"11223344" report "BIOS7 hot-loaded word mismatch" severity failure;
      assert q9 = x"55667788" report "BIOS9 hot-loaded word mismatch" severity failure;

      -- Prove byte enables and the synchronous address path used by membus.
      la7 <= to_unsigned(1, la7'length);
      ld7 <= x"A1B2C3D4";
      be7 <= "0101";
      we7 <= '1';
      la9 <= to_unsigned(1, la9'length);
      ld9 <= x"10203040";
      be9 <= "1010";
      we9 <= '1';
      tick;
      we7 <= '0';
      we9 <= '0';
      a7 <= to_unsigned(1, a7'length);
      a9 <= to_unsigned(1, a9'length);
      tick;
      assert q7 = x"00B200D4" report "BIOS7 byte enables mismatch" severity failure;
      assert q9 = x"10003000" report "BIOS9 byte enables mismatch" severity failure;

      -- ARM9 exposes a 32 KB window, but only the low 4 KB is backed.
      a9 <= to_unsigned(1024, a9'length);
      tick;
      assert q9 = x"00000000" report "BIOS9 upper window must read zero" severity failure;

      report "tb_bios_hotload: PASS" severity note;
      std.env.stop;
      wait;
   end process;
end architecture;
