library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity nds_spi is
   port
   (
      clk         : in  std_logic;
      reset       : in  std_logic;

      bus7        : in  proc_bus_gb_type;
      wired_out7  : out std_logic_vector(31 downto 0);
      wired_done7 : out std_logic;

      irq_spi     : out std_logic := '0';

      fw_addr     : out unsigned(17 downto 2) := (others => '0');
      fw_req      : out std_logic := '0';
      fw_done     : in  std_logic;
      fw_data     : in  std_logic_vector(31 downto 0)
   );
end entity;

architecture arch of nds_spi is

   constant ADR_SPI : std_logic_vector(27 downto 0) := x"00001C0";

   signal cnt        : std_logic_vector(15 downto 0) := (others => '0');
   signal delay_cnt  : unsigned(9 downto 0) := (others => '0');
   signal cnt_rd     : std_logic_vector(31 downto 0);
   signal rdata      : std_logic_vector(7 downto 0);

   type t_pmregs is array (0 to 7) of std_logic_vector(7 downto 0);
   signal pm_regs    : t_pmregs := (others => (others => '0'));
   signal pm_hold    : std_logic := '0';
   signal pm_index   : std_logic_vector(7 downto 0) := (others => '0');
   signal pm_data    : std_logic_vector(7 downto 0) := (others => '0');
   signal pm_datapos : unsigned(1 downto 0) := (others => '0');

   function pm_mask(i : integer) return std_logic_vector is
   begin
      case i is
         when 0 => return x"7F";
         when 2 => return x"01";
         when 3 => return x"03";
         when 4 => return x"0F";
         when others => return x"00";
      end case;
   end function;

   signal fw_hold    : std_logic := '0';
   signal fw_cmd     : std_logic_vector(7 downto 0) := (others => '0');
   signal fw_datapos : unsigned(2 downto 0) := (others => '0');
   signal fw_a       : unsigned(23 downto 0) := (others => '0');
   signal fw_out     : std_logic_vector(7 downto 0) := (others => '0');
   signal fw_status  : std_logic_vector(7 downto 0) := (others => '0');
   signal fw_pend    : std_logic := '0';
   signal fw_lane    : unsigned(1 downto 0) := (others => '0');

   signal tsc_ctrl    : std_logic_vector(7 downto 0) := (others => '0');
   signal tsc_data    : std_logic_vector(7 downto 0) := (others => '0');
   signal tsc_datapos : unsigned(1 downto 0) := (others => '0');
   signal tsc_conv    : unsigned(11 downto 0) := (others => '0');

begin

   rdata <= x"00"   when (cnt(15) = '0' or cnt(7) = '1') else
            pm_data when (cnt(9 downto 8) = "00") else
            fw_out  when (cnt(9 downto 8) = "01") else
            tsc_data;

   cnt_rd <= x"00" & rdata & cnt;

   wired_out7  <= cnt_rd when (bus7.Adr = ADR_SPI) else (others => '0');
   wired_done7 <= '1' when (bus7.Adr = ADR_SPI) else '0';

   process (clk)
      variable wval     : std_logic_vector(7 downto 0);
      variable dev      : std_logic_vector(1 downto 0);
      variable conv     : unsigned(11 downto 0);
      variable v_release : std_logic;
   begin
      if rising_edge(clk) then

         irq_spi <= '0';

         if (reset = '1') then
            cnt        <= (others => '0');
            delay_cnt  <= (others => '0');
            pm_regs    <= (others => (others => '0'));
            pm_regs(4) <= x"40";
            pm_hold    <= '0';
            pm_data    <= (others => '0');
            fw_hold    <= '0';
            fw_status  <= (others => '0');
            fw_out     <= (others => '0');
            fw_pend    <= '0';
            fw_req     <= '0';
            tsc_ctrl   <= (others => '0');
            tsc_data   <= (others => '0');
            tsc_conv   <= (others => '0');
         else

            fw_req <= '0';
            if (fw_pend = '1' and fw_done = '1') then
               fw_pend <= '0';
               case fw_lane is
                  when "00" => fw_out <= fw_data( 7 downto  0);
                  when "01" => fw_out <= fw_data(15 downto  8);
                  when "10" => fw_out <= fw_data(23 downto 16);
                  when others => fw_out <= fw_data(31 downto 24);
               end case;
            end if;

            if (cnt(7) = '1') then
               if (delay_cnt = 0 and fw_pend = '0') then
                  cnt(7) <= '0';
                  if (cnt(14) = '1') then
                     irq_spi <= '1';
                  end if;
               else
                  delay_cnt <= delay_cnt - 1;
               end if;
            end if;

            if (bus7.ena = '1' and bus7.rnw = '0' and bus7.Adr = ADR_SPI) then

               if (bus7.bEna(0) = '1') then
                  cnt(6 downto 2) <= (others => '0');
                  cnt(1 downto 0) <= bus7.Din(1 downto 0);
               end if;
               if (bus7.bEna(1) = '1') then
                  if (cnt(15) = '1' and bus7.Din(15) = '0') then
                     case cnt(9 downto 8) is
                        when "00" => pm_hold <= '0';
                        when "01" => fw_hold <= '0';
                        when others => null;
                     end case;
                  end if;
                  cnt(15 downto 14) <= bus7.Din(15 downto 14);
                  cnt(11)           <= bus7.Din(11);
                  cnt(9 downto 8)   <= bus7.Din(9 downto 8);
                  cnt(13 downto 12) <= "00";
                  cnt(10)           <= '0';
               end if;

               if (bus7.bEna(2) = '1' and cnt(15) = '1' and cnt(7) = '0') then
                  wval := bus7.Din(23 downto 16);
                  dev  := cnt(9 downto 8);
                  cnt(7)    <= '1';
                  delay_cnt <= shift_left(to_unsigned(8, 10), 3 + to_integer(unsigned(cnt(1 downto 0)))) - 1;
                  v_release := not cnt(11);

                  case dev is

                     when "00" =>
                        if (pm_hold = '0') then
                           pm_index   <= wval;
                           pm_hold    <= '1';
                           pm_data    <= (others => '0');
                           pm_datapos <= "01";
                        else
                           if (pm_datapos = 1) then
                              if (pm_index(7) = '1') then
                                 pm_data <= pm_regs(to_integer(unsigned(pm_index(2 downto 0))));
                              else
                                 pm_regs(to_integer(unsigned(pm_index(2 downto 0)))) <=
                                    (pm_regs(to_integer(unsigned(pm_index(2 downto 0)))) and not pm_mask(to_integer(unsigned(pm_index(2 downto 0)))))
                                    or (wval and pm_mask(to_integer(unsigned(pm_index(2 downto 0)))));
                                 pm_data <= (others => '0');
                              end if;
                           else
                              pm_data <= (others => '0');
                           end if;
                           if (pm_datapos /= 3) then
                              pm_datapos <= pm_datapos + 1;
                           end if;
                        end if;
                        if (v_release = '1') then pm_hold <= '0'; end if;

                     when "01" =>
                        if (fw_hold = '0') then
                           fw_cmd     <= wval;
                           fw_hold    <= '1';
                           fw_out     <= (others => '0');
                           fw_datapos <= "001";
                           fw_a       <= (others => '0');
                           case wval is
                              when x"04" => fw_status(1) <= '0';
                              when x"06" => fw_status(1) <= '1';
                              when others => null;
                           end case;
                        else
                           case fw_cmd is
                              when x"03" =>
                                 if (fw_datapos < 4) then
                                    fw_a   <= fw_a(15 downto 0) & unsigned(wval);
                                    fw_out <= (others => '0');
                                 else
                                    fw_addr  <= fw_a(17 downto 2);
                                    fw_lane  <= fw_a(1 downto 0);
                                    fw_req   <= '1';
                                    fw_pend  <= '1';
                                    fw_a     <= fw_a + 1;
                                 end if;
                                 if (fw_datapos /= 7) then
                                    fw_datapos <= fw_datapos + 1;
                                 end if;
                              when x"05" =>
                                 fw_out <= fw_status;
                              when x"0A" =>
                                 if (fw_datapos < 4) then
                                    fw_a   <= fw_a(15 downto 0) & unsigned(wval);
                                    fw_out <= (others => '0');
                                 else
                                    fw_out <= wval;
                                    fw_a   <= fw_a + 1;
                                 end if;
                                 if (fw_datapos /= 7) then
                                    fw_datapos <= fw_datapos + 1;
                                 end if;
                              when others =>
                                 fw_out <= (others => '0');
                           end case;
                        end if;
                        if (v_release = '1') then fw_hold <= '0'; end if;

                     when others =>
                        if (tsc_datapos = 1) then
                           tsc_data <= '0' & std_logic_vector(tsc_conv(11 downto 5));
                        elsif (tsc_datapos = 2) then
                           tsc_data <= std_logic_vector(tsc_conv(4 downto 0)) & "000";
                        else
                           tsc_data <= (others => '0');
                        end if;
                        if (wval(7) = '1') then
                           tsc_ctrl    <= wval;
                           tsc_datapos <= "01";
                           case wval(6 downto 4) is
                              when "001" => conv := (others => '0');
                              when "101" => conv := (others => '0');
                              when "110" => conv := x"80" & x"0";
                              when others => conv := x"FF" & x"F";
                           end case;
                           if (wval(3) = '1') then
                              conv := conv and x"FF0";
                           end if;
                           tsc_conv <= conv;
                        else
                           if (tsc_datapos /= 3) then
                              tsc_datapos <= tsc_datapos + 1;
                           end if;
                        end if;

                  end case;
               end if;
            end if;

         end if;
      end if;
   end process;

end architecture;
