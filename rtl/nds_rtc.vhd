
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity nds_rtc is
   port
   (
      clk         : in  std_logic;
      ce          : in  std_logic;
      reset       : in  std_logic;

      fw_boot     : in  std_logic := '0';

      bus7        : in  proc_bus_gb_type;
      wired_out7  : out std_logic_vector(31 downto 0);
      wired_done7 : out std_logic
   );
end entity;

architecture arch of nds_rtc is

   constant ADR_RTC : std_logic_vector(27 downto 0) := x"0000138";

   constant CYCLES_PER_SEC : integer := 33513982;

   signal io_reg     : std_logic_vector(15 downto 0) := (others => '0');

   signal in_byte    : std_logic_vector(7 downto 0) := (others => '0');
   signal in_bit     : integer range 0 to 7 := 0;
   signal in_pos     : integer range 0 to 15 := 0;
   signal cur_cmd    : std_logic_vector(7 downto 0) := (others => '0');
   type t_out is array (0 to 6) of std_logic_vector(7 downto 0);
   signal out_buf    : t_out := (others => (others => '0'));
   signal out_bit    : integer range 0 to 7 := 0;
   signal out_pos    : integer range 0 to 6 := 0;

   signal status1    : std_logic_vector(7 downto 0) := x"02";
   signal status2    : std_logic_vector(7 downto 0) := x"00";
   type t_dt is array (0 to 6) of std_logic_vector(7 downto 0);
   signal datetime   : t_dt := (x"26", x"07", x"18", x"06", x"06", x"00", x"00");
   signal alarm1     : t_dt := (others => (others => '0'));
   signal alarm2     : t_dt := (others => (others => '0'));
   signal clockadj   : std_logic_vector(7 downto 0) := x"00";
   signal freereg    : std_logic_vector(7 downto 0) := x"00";

   signal sec_div    : integer range 0 to CYCLES_PER_SEC - 1 := 0;

   type t_rev is array (0 to 15) of std_logic_vector(7 downto 0);
   constant CMDREV : t_rev := (x"06", x"86", x"46", x"C6", x"26", x"A6", x"66", x"E6",
                               x"16", x"96", x"56", x"D6", x"36", x"B6", x"76", x"F6");

   function bcd_inc(v : std_logic_vector(7 downto 0)) return std_logic_vector is
      variable r : unsigned(7 downto 0) := unsigned(v);
   begin
      if (r(3 downto 0) = 9) then
         r(3 downto 0) := (others => '0');
         r(7 downto 4) := r(7 downto 4) + 1;
      else
         r(3 downto 0) := r(3 downto 0) + 1;
      end if;
      return std_logic_vector(r);
   end function;

begin

   wired_out7  <= x"0000" & io_reg when (bus7.Adr = ADR_RTC) else (others => '0');
   wired_done7 <= '1' when (bus7.Adr = ADR_RTC) else '0';

   process (clk)
      variable wval  : std_logic_vector(15 downto 0);
      variable vbyte : std_logic_vector(7 downto 0);
      variable vcmd  : std_logic_vector(7 downto 0);
      variable vio   : std_logic_vector(15 downto 0);
   begin
      if rising_edge(clk) then

         if (reset = '1') then

            io_reg  <= (others => '0');
            in_bit  <= 0; in_pos <= 0; out_bit <= 0; out_pos <= 0;
            if (fw_boot = '1') then
               status1 <= x"82";
            else
               status1 <= x"02";
            end if;
            status2 <= x"00";
            datetime <= (x"26", x"07", x"18", x"06", x"06", x"00", x"00");
            sec_div <= 0;

         elsif (ce = '1') then

            if (sec_div = CYCLES_PER_SEC - 1) then
               sec_div <= 0;
               if (datetime(6) = x"59") then
                  datetime(6) <= x"00";
                  if (datetime(5) = x"59") then
                     datetime(5) <= x"00";
                     if (datetime(4) = x"23") then
                        datetime(4) <= x"00";
                        datetime(2) <= bcd_inc(datetime(2));
                     else
                        datetime(4) <= bcd_inc(datetime(4));
                     end if;
                  else
                     datetime(5) <= bcd_inc(datetime(5));
                  end if;
               else
                  datetime(6) <= bcd_inc(datetime(6));
               end if;
            else
               sec_div <= sec_div + 1;
            end if;

            if (bus7.ena = '1' and bus7.rnw = '0' and bus7.Adr = ADR_RTC) then
               wval := io_reg;
               if (bus7.bEna(0) = '1') then wval(7 downto 0)  := bus7.Din(7 downto 0); end if;
               if (bus7.bEna(1) = '1') then wval(15 downto 8) := bus7.Din(15 downto 8); end if;

               vio := io_reg;

               if (wval(2) = '1') then
                  if (io_reg(2) = '0') then
                     in_byte <= (others => '0');
                     in_bit  <= 0;
                     in_pos  <= 0;
                     out_buf <= (others => (others => '0'));
                     out_bit <= 0;
                     out_pos <= 0;
                  elsif (wval(1) = '0') then
                     if (wval(4) = '1') then
                        vbyte := in_byte;
                        vbyte(in_bit) := wval(0);
                        in_byte <= vbyte;
                        if (in_bit = 7) then
                           in_bit  <= 0;
                           in_byte <= (others => '0');
                           if (in_pos < 15) then
                              in_pos <= in_pos + 1;
                           end if;

                           if (in_pos = 0) then
                              if (vbyte(7 downto 4) = x"6") then
                                 vcmd := CMDREV(to_integer(unsigned(vbyte(3 downto 0))));
                              else
                                 vcmd := vbyte;
                              end if;
                              cur_cmd <= vcmd;
                              if (vcmd(7) = '1') then
                                 case vcmd(6 downto 4) is
                                    when "000" =>
                                       out_buf(0) <= status1;
                                       status1(7 downto 4) <= x"0";
                                    when "100" => out_buf(0) <= status2;
                                    when "010" =>
                                       for i in 0 to 6 loop out_buf(i) <= datetime(i); end loop;
                                    when "110" =>
                                       for i in 0 to 2 loop out_buf(i) <= datetime(4 + i); end loop;
                                    when "001" =>
                                       if (status2(2) = '1') then
                                          for i in 0 to 2 loop out_buf(i) <= alarm1(i); end loop;
                                       else
                                          out_buf(0) <= alarm1(2);
                                       end if;
                                    when "101" =>
                                       for i in 0 to 2 loop out_buf(i) <= alarm2(i); end loop;
                                    when "011" => out_buf(0) <= clockadj;
                                    when others => out_buf(0) <= freereg;
                                 end case;
                              end if;
                           else
                              case cur_cmd(6 downto 4) is
                                 when "000" =>
                                    status1(3 downto 1) <= vbyte(3 downto 1);
                                 when "100" => status2 <= vbyte;
                                 when "010" =>
                                    if (in_pos <= 7) then datetime(in_pos - 1) <= vbyte; end if;
                                 when "110" =>
                                    if (in_pos <= 3) then datetime(3 + in_pos) <= vbyte; end if;
                                 when "001" =>
                                    if (in_pos <= 3) then alarm1(in_pos - 1) <= vbyte; end if;
                                 when "101" =>
                                    if (in_pos <= 3) then alarm2(in_pos - 1) <= vbyte; end if;
                                 when "011" => clockadj <= vbyte;
                                 when others => freereg <= vbyte;
                              end case;
                           end if;
                        else
                           in_bit <= in_bit + 1;
                        end if;
                     else
                        vio(0) := out_buf(out_pos)(out_bit);
                        if (out_bit = 7) then
                           out_bit <= 0;
                           if (out_pos < 6) then out_pos <= out_pos + 1; end if;
                        else
                           out_bit <= out_bit + 1;
                        end if;
                     end if;
                  end if;
               end if;

               if (wval(4) = '1') then
                  io_reg <= wval;
               else
                  io_reg <= wval(15 downto 1) & vio(0);
               end if;

            end if;

         end if;

      end if;
   end process;

end architecture;
