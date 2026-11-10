-- "did the renderer keep up, on hardware, in THIS scene".

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nds_perf is
   generic
   (
      ENABLE : integer := 1
   );
   port
   (
      clk          : in  std_logic;
      reset        : in  std_logic;

      vblank       : in  std_logic;
      drawline     : in  std_logic;
      drawObj      : in  std_logic;
      line_busy_a  : in  std_logic;
      line_busy_b  : in  std_logic;

      index        : in  std_logic_vector(2 downto 0);
      value        : out std_logic_vector(31 downto 0)
   );
end entity;

architecture arch of nds_perf is

   signal frames      : unsigned(31 downto 0) := (others => '0');
   signal fcyc        : unsigned(23 downto 0) := (others => '0');
   signal busy_a      : unsigned(23 downto 0) := (others => '0');
   signal busy_b      : unsigned(23 downto 0) := (others => '0');
   signal drop_a      : unsigned( 7 downto 0) := (others => '0');
   signal drop_b      : unsigned( 7 downto 0) := (others => '0');
   signal drop_a_tot  : unsigned(15 downto 0) := (others => '0');
   signal drop_b_tot  : unsigned(15 downto 0) := (others => '0');

   signal s_fcyc      : unsigned(23 downto 0) := (others => '0');
   signal s_busy_a    : unsigned(23 downto 0) := (others => '0');
   signal s_busy_b    : unsigned(23 downto 0) := (others => '0');
   signal s_drop_a    : unsigned( 7 downto 0) := (others => '0');
   signal s_drop_b    : unsigned( 7 downto 0) := (others => '0');

begin

   goff : if ENABLE = 0 generate
      value <= (others => '0');
   end generate;

   gon : if ENABLE /= 0 generate

      process (clk)
         -- on either; both map to the same "did not keep up" event.
         variable v_drop_a : boolean;
         variable v_drop_b : boolean;
      begin
         if rising_edge(clk) then

            v_drop_a := (drawline = '1' or drawObj = '1') and line_busy_a = '1';
            v_drop_b := (drawline = '1' or drawObj = '1') and line_busy_b = '1';

            if (fcyc /= x"FFFFFF") then fcyc <= fcyc + 1; end if;
            if (line_busy_a = '1' and busy_a /= x"FFFFFF") then busy_a <= busy_a + 1; end if;
            if (line_busy_b = '1' and busy_b /= x"FFFFFF") then busy_b <= busy_b + 1; end if;

            if (v_drop_a) then
               if (drop_a     /= x"FF")   then drop_a     <= drop_a + 1;         end if;
               if (drop_a_tot /= x"FFFF") then drop_a_tot <= drop_a_tot + 1;     end if;
            end if;
            if (v_drop_b) then
               if (drop_b     /= x"FF")   then drop_b     <= drop_b + 1;         end if;
               if (drop_b_tot /= x"FFFF") then drop_b_tot <= drop_b_tot + 1;     end if;
            end if;

            if (vblank = '1') then
               s_fcyc   <= fcyc;
               s_busy_a <= busy_a;
               s_busy_b <= busy_b;
               s_drop_a <= drop_a;
               s_drop_b <= drop_b;

               frames   <= frames + 1;
               fcyc     <= (others => '0');
               busy_a   <= (others => '0');
               busy_b   <= (others => '0');
               drop_a   <= (others => '0');
               drop_b   <= (others => '0');
            end if;

            if (reset = '1') then
               frames <= (others => '0');
               fcyc   <= (others => '0');
               busy_a <= (others => '0'); busy_b <= (others => '0');
               drop_a <= (others => '0'); drop_b <= (others => '0');
               drop_a_tot <= (others => '0'); drop_b_tot <= (others => '0');
               s_fcyc <= (others => '0');
               s_busy_a <= (others => '0'); s_busy_b <= (others => '0');
               s_drop_a <= (others => '0'); s_drop_b <= (others => '0');
            end if;

         end if;
      end process;

      with index select value <=
         std_logic_vector(frames)                                   when "000",
         x"00" & std_logic_vector(s_fcyc)                            when "001",
         x"00" & std_logic_vector(s_busy_a)                          when "010",
         x"00" & std_logic_vector(s_busy_b)                          when "011",
         x"000000" & std_logic_vector(s_drop_a)                      when "100",
         x"000000" & std_logic_vector(s_drop_b)                      when "101",
         x"0000" & std_logic_vector(drop_a_tot)                      when "110",
         x"0000" & std_logic_vector(drop_b_tot)                      when others;

   end generate;

end architecture;
