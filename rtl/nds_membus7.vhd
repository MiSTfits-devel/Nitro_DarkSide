
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity nds_membus7 is
   port
   (
      clk            : in  std_logic;
      reset          : in  std_logic;

      cpu_adr        : in  std_logic_vector(31 downto 0);
      cpu_rnw        : in  std_logic;
      cpu_ena        : in  std_logic;
      cpu_acc        : in  std_logic_vector(1 downto 0);
      cpu_dout       : in  std_logic_vector(31 downto 0);
      cpu_lowbits    : in  std_logic_vector(1 downto 0);
      cpu_lastread   : in  std_logic_vector(31 downto 0);
      cpu_din        : out std_logic_vector(31 downto 0);
      cpu_done       : out std_logic;

      bios_addr      : out unsigned(13 downto 2) := (others => '0');
      bios_data      : in  std_logic_vector(31 downto 0);

      w7p_addr       : out unsigned(15 downto 2);
      w7p_we         : out std_logic;
      w7p_be         : out std_logic_vector(3 downto 0);
      w7p_writedata  : out std_logic_vector(31 downto 0);
      w7p_readdata   : in  std_logic_vector(31 downto 0);

      wsh_ena        : out std_logic := '0';
      wsh_rnw        : out std_logic := '1';
      wsh_addr       : out unsigned(14 downto 2) := (others => '0');
      wsh_be         : out std_logic_vector(3 downto 0) := (others => '0');
      wsh_din        : out std_logic_vector(31 downto 0) := (others => '0');
      wsh_dout       : in  std_logic_vector(31 downto 0);
      wsh_done       : in  std_logic;
      wsh_mapped     : in  std_logic;

      vram_ena       : out std_logic := '0';
      vram_rnw       : out std_logic := '1';
      vram_addr      : out unsigned(23 downto 2) := (others => '0');
      vram_be        : out std_logic_vector(3 downto 0) := (others => '0');
      vram_din       : out std_logic_vector(31 downto 0) := (others => '0');
      vram_dout      : in  std_logic_vector(31 downto 0);
      vram_done      : in  std_logic;

      mr_ena         : out std_logic := '0';
      mr_rnw         : out std_logic := '1';
      mr_addr        : out std_logic_vector(21 downto 2) := (others => '0');
      mr_be          : out std_logic_vector(3 downto 0) := (others => '0');
      mr_writedata   : out std_logic_vector(31 downto 0) := (others => '0');
      mr_done        : in  std_logic;
      mr_readdata    : in  std_logic_vector(31 downto 0);

      io_ce_next     : in  std_logic := '1';
      io_bus         : out proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');
      io_wired_out   : in  std_logic_vector(31 downto 0);
      io_wired_done  : in  std_logic
   );
end entity;

architecture arch of nds_membus7 is

   type t_target is (T_BIOS, T_MAIN, T_WRAMSH, T_WRAM7, T_IO, T_VRAM, T_OPEN);
   type t_state  is (IDLE, FINISH, W_WRAMSH, W_VRAM, W_MAIN, W_IO_ALIGN);

   signal state    : t_state  := IDLE;
   signal target   : t_target := T_OPEN;
   signal r_acc    : std_logic_vector(1 downto 0) := "10";
   signal r_low    : std_logic_vector(1 downto 0) := "00";

   signal dec_target : t_target;
   signal wdata      : std_logic_vector(31 downto 0);
   signal be         : std_logic_vector(3 downto 0);

   signal accept_now : std_logic;
   signal w7p_sel    : std_logic;

   signal din_unrot  : std_logic_vector(31 downto 0);

begin

   bios_addr <= unsigned(cpu_adr(13 downto 2));

   accept_now <= '1' when reset = '0' and
                          (state = IDLE or state = FINISH or
                           (state = W_WRAMSH and wsh_done  = '1') or
                           (state = W_VRAM   and vram_done = '1') or
                           (state = W_MAIN   and mr_done   = '1')) else '0';

   w7p_sel       <= '1' when (accept_now = '1' and cpu_ena = '1' and dec_target = T_WRAM7) else '0';
   w7p_addr      <= unsigned(cpu_adr(15 downto 2));
   w7p_we        <= w7p_sel and not cpu_rnw;
   w7p_be        <= be;
   w7p_writedata <= wdata;

   process (all)
   begin
      dec_target <= T_OPEN;
      if (cpu_adr(31 downto 28) = x"0") then
         case cpu_adr(27 downto 24) is
            when x"0" =>
               if (unsigned(cpu_adr(23 downto 14)) = 0) then
                  dec_target <= T_BIOS;
               end if;
            when x"2" => dec_target <= T_MAIN;
            when x"3" =>
               if (cpu_adr(23) = '1' or wsh_mapped = '0') then
                  dec_target <= T_WRAM7;
               else
                  dec_target <= T_WRAMSH;
               end if;
            when x"4" =>
               if (cpu_adr(23) = '0') then
                  dec_target <= T_IO;
               end if;
            when x"6" => dec_target <= T_VRAM;
            when others => null;
         end case;
      end if;
   end process;

   process (all)
   begin
      wdata <= cpu_dout;
      if (cpu_acc = ACCESS_8BIT) then
         case (cpu_adr(1 downto 0)) is
            when "00" => wdata( 7 downto  0) <= cpu_dout(7 downto 0);
            when "01" => wdata(15 downto  8) <= cpu_dout(7 downto 0);
            when "10" => wdata(23 downto 16) <= cpu_dout(7 downto 0);
            when "11" => wdata(31 downto 24) <= cpu_dout(7 downto 0);
            when others => null;
         end case;
      elsif (cpu_acc = ACCESS_16BIT and cpu_adr(1) = '1') then
         wdata(31 downto 16) <= cpu_dout(15 downto 0);
      end if;

      be <= "1111";
      case (cpu_acc) is
         when ACCESS_8BIT =>
            case (cpu_adr(1 downto 0)) is
               when "00" => be <= "0001";
               when "01" => be <= "0010";
               when "10" => be <= "0100";
               when "11" => be <= "1000";
               when others => null;
            end case;
         when ACCESS_16BIT =>
            if (cpu_adr(1) = '1') then be <= "1100"; else be <= "0011"; end if;
         when others => null;
      end case;
   end process;

   process (clk)
      variable can_accept : boolean;
   begin
      if rising_edge(clk) then

         wsh_ena  <= '0';
         vram_ena <= '0';
         mr_ena   <= '0';
         io_bus.ena <= '0';
         io_bus.rst <= reset;

         if (reset = '1') then
            state <= IDLE;
         else
            can_accept := (accept_now = '1');

            if (state = W_IO_ALIGN) then
               if (io_ce_next = '1') then
                  io_bus.ena <= '1';
                  state      <= FINISH;
               end if;
            elsif can_accept then
               state <= IDLE;
               if (cpu_ena = '1') then
                  target <= dec_target;
                  r_acc  <= cpu_acc;
                  r_low  <= cpu_adr(1 downto 0);

                  case dec_target is

                     when T_BIOS =>
                        state     <= FINISH;

                     when T_WRAM7 =>
                        state <= FINISH;

                     when T_WRAMSH =>
                        wsh_ena  <= '1';
                        wsh_rnw  <= cpu_rnw;
                        wsh_addr <= unsigned(cpu_adr(14 downto 2));
                        wsh_be   <= be;
                        wsh_din  <= wdata;
                        state    <= W_WRAMSH;

                     when T_VRAM =>
                        vram_ena  <= '1';
                        vram_rnw  <= cpu_rnw;
                        vram_addr <= unsigned(cpu_adr(23 downto 2));
                        vram_be   <= be;
                        vram_din  <= wdata;
                        state     <= W_VRAM;

                     when T_MAIN =>
                        mr_ena       <= '1';
                        mr_rnw       <= cpu_rnw;
                        mr_addr      <= cpu_adr(21 downto 2);
                        mr_be        <= be;
                        mr_writedata <= wdata;
                        state        <= W_MAIN;

                     when T_IO =>
                        io_bus.rnw  <= cpu_rnw;
                        io_bus.Adr  <= x"0" & cpu_adr(23 downto 2) & "00";
                        io_bus.acc  <= cpu_acc;
                        io_bus.Din  <= wdata;
                        io_bus.bEna <= be;
                        if (io_ce_next = '1') then
                           io_bus.ena <= '1';
                           state      <= FINISH;
                        else
                           state <= W_IO_ALIGN;
                        end if;

                     when T_OPEN =>
                        state <= FINISH;

                  end case;
               end if;
            end if;
         end if;
      end if;
   end process;

   cpu_done <= '1'       when state = FINISH  else
               wsh_done  when state = W_WRAMSH else
               vram_done when state = W_VRAM   else
               mr_done   when state = W_MAIN   else '0';

   din_unrot <= bios_data     when target = T_BIOS   else
                w7p_readdata  when target = T_WRAM7  else
                wsh_dout      when target = T_WRAMSH else
                vram_dout     when target = T_VRAM   else
                mr_readdata   when target = T_MAIN   else
                io_wired_out  when (target = T_IO and io_wired_done = '1') else
                x"00000000"   when target = T_IO else
                cpu_lastread;

   process (all)
   begin
      cpu_din <= (others => '0');
      if (r_acc = ACCESS_8BIT) then
         case (r_low) is
            when "00" => cpu_din <= x"000000" & din_unrot(7 downto 0);
            when "01" => cpu_din <= x"000000" & din_unrot(15 downto 8);
            when "10" => cpu_din <= x"000000" & din_unrot(23 downto 16);
            when "11" => cpu_din <= x"000000" & din_unrot(31 downto 24);
            when others => null;
         end case;
      elsif (r_acc = ACCESS_16BIT) then
         case (r_low) is
            when "00" => cpu_din <= x"0000" & din_unrot(15 downto 0);
            when "01" => cpu_din <= din_unrot(7 downto 0) & x"0000" & din_unrot(15 downto 8);
            when "10" => cpu_din <= x"0000" & din_unrot(31 downto 16);
            when "11" => cpu_din <= din_unrot(23 downto 16) & x"0000" & din_unrot(31 downto 24);
            when others => null;
         end case;
      else
         case (r_low) is
            when "00" => cpu_din <= din_unrot;
            when "01" => cpu_din <= din_unrot(7 downto 0) & din_unrot(31 downto 8);
            when "10" => cpu_din <= din_unrot(15 downto 0) & din_unrot(31 downto 16);
            when "11" => cpu_din <= din_unrot(23 downto 0) & din_unrot(31 downto 24);
            when others => null;
         end case;
      end if;
   end process;

end architecture;
