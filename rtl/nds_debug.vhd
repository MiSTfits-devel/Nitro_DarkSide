-- escape (nds_cpu9.vhd:921, gba_cpu.vhd equivalents). Peripherals keep running

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nds_debug is
   generic
   (
      BOOT_HOLD : std_logic := '0'
   );
   port
   (
      clk       : in  std_logic;
      reset     : in  std_logic;

      cmd_stb   : in  std_logic;
      cmd_op    : in  std_logic_vector(7 downto 0);
      cmd_arg   : in  std_logic_vector(31 downto 0);
      rsp_data  : out std_logic_vector(31 downto 0) := (others => '0');
      rsp_stb   : out std_logic := '0';

      hold9     : out std_logic := '0';
      rel9      : out std_logic := '0';
      hold7     : out std_logic := '0';
      rel7      : out std_logic := '0';

      boot_rst  : out std_logic := '0';

      regsel    : out unsigned(4 downto 0) := (others => '0');
      regval9   : in  std_logic_vector(31 downto 0);
      regval7   : in  std_logic_vector(31 downto 0);

      pc9       : in  std_logic_vector(31 downto 0);
      pc7       : in  std_logic_vector(31 downto 0);

      probe     : in  std_logic_vector(31 downto 0) := (others => '0');
      cardstat  : in  std_logic_vector(31 downto 0) := (others => '0');
      ipcstat   : in  std_logic_vector(31 downto 0) := (others => '0');

      perfstat  : in  std_logic_vector(31 downto 0) := (others => '0');
      perf_index : out std_logic_vector(2 downto 0) := (others => '0');

      irq9_ime  : in  std_logic_vector(31 downto 0) := (others => '0');
      irq9_ie   : in  std_logic_vector(31 downto 0) := (others => '0');
      irq9_if   : in  std_logic_vector(31 downto 0) := (others => '0');
      irq7_ime  : in  std_logic_vector(31 downto 0) := (others => '0');
      irq7_ie   : in  std_logic_vector(31 downto 0) := (others => '0');
      irq7_if   : in  std_logic_vector(31 downto 0) := (others => '0');

      pk_ena    : out std_logic := '0';
      pk_addr   : out std_logic_vector(31 downto 0) := (others => '0');
      pk_done   : in  std_logic;
      pk_data   : in  std_logic_vector(31 downto 0)
   );
end entity;

architecture arch of nds_debug is

   type t_state is (IDLE, REG_WAIT, PEEK_REQ, PEEK_WAIT, RESPOND);
   signal state : t_state := IDLE;

   signal held9, held7   : std_logic := BOOT_HOLD;
   signal bp9_en, bp7_en : std_logic := '0';
   signal bp9, bp7       : std_logic_vector(31 downto 0) := (others => '0');
   signal hit9, hit7     : std_logic := '0';

   signal run9_cnt, run7_cnt : unsigned(23 downto 0) := (others => '0');
   signal run9_act, run7_act : std_logic := '0';

   signal sel_cpu : std_logic := '0';
   signal answer  : std_logic_vector(31 downto 0) := (others => '0');

   signal pk_timer : unsigned(15 downto 0) := (others => '0');

begin

   hold9 <= held9;
   hold7 <= held7;

   perf_index <= cmd_arg(2 downto 0);

   process (clk)
      variable op : std_logic_vector(6 downto 0);
   begin
      if rising_edge(clk) then

         rsp_stb  <= '0';
         rel9     <= '0';
         rel7     <= '0';
         pk_ena   <= '0';
         boot_rst <= '0';

         if (reset = '1') then
            state    <= IDLE;
            held9    <= BOOT_HOLD;
            held7    <= BOOT_HOLD;
            bp9_en   <= '0';
            bp7_en   <= '0';
            hit9     <= '0';
            hit7     <= '0';
            run9_act <= '0';
            run7_act <= '0';
         else

            if (bp9_en = '1' and held9 = '0' and pc9 = bp9) then
               held9    <= '1';
               hit9     <= '1';
               run9_act <= '0';
            end if;
            if (bp7_en = '1' and held7 = '0' and pc7 = bp7) then
               held7    <= '1';
               hit7     <= '1';
               run7_act <= '0';
            end if;

            if (run9_act = '1') then
               if (run9_cnt = 0) then
                  run9_act <= '0';
                  held9    <= '1';
               else
                  run9_cnt <= run9_cnt - 1;
               end if;
            end if;
            if (run7_act = '1') then
               if (run7_cnt = 0) then
                  run7_act <= '0';
                  held7    <= '1';
               else
                  run7_cnt <= run7_cnt - 1;
               end if;
            end if;

            case state is

               when IDLE =>
                  if (cmd_stb = '1') then
                     op      := cmd_op(6 downto 0);
                     sel_cpu <= cmd_op(7);
                     answer  <= (others => '0');

                     case op is
                        when "0000001" =>
                           if (cmd_op(7) = '0') then
                              held9 <= '1'; run9_act <= '0';
                           else
                              held7 <= '1'; run7_act <= '0';
                           end if;
                           state <= RESPOND;

                        when "0000010" =>
                           if (cmd_op(7) = '0') then
                              held9 <= '0'; hit9 <= '0'; rel9 <= '1';
                           else
                              held7 <= '0'; hit7 <= '0'; rel7 <= '1';
                           end if;
                           state <= RESPOND;

                        when "0000011" =>
                           if (cmd_op(7) = '0') then
                              held9    <= '0';
                              hit9     <= '0';
                              rel9     <= '1';
                              run9_cnt <= unsigned(cmd_arg(23 downto 0));
                              run9_act <= '1';
                           else
                              held7    <= '0';
                              hit7     <= '0';
                              rel7     <= '1';
                              run7_cnt <= unsigned(cmd_arg(23 downto 0));
                              run7_act <= '1';
                           end if;
                           state <= RESPOND;

                        when "0000100" =>
                           if (cmd_op(7) = '0') then
                              bp9 <= cmd_arg; bp9_en <= '1'; hit9 <= '0';
                           else
                              bp7 <= cmd_arg; bp7_en <= '1'; hit7 <= '0';
                           end if;
                           state <= RESPOND;

                        when "0000101" =>
                           if (cmd_op(7) = '0') then bp9_en <= '0';
                           else                      bp7_en <= '0'; end if;
                           state <= RESPOND;

                        when "0000110" =>
                           regsel <= unsigned(cmd_arg(4 downto 0));
                           state  <= REG_WAIT;

                        when "0000111" =>
                           pk_addr <= cmd_arg;
                           state   <= PEEK_REQ;

                        when "0001001" =>
                           boot_rst <= '1';
                           held9    <= '1'; held7    <= '1';
                           hit9     <= '0'; hit7     <= '0';
                           run9_act <= '0'; run7_act <= '0';
                           state    <= RESPOND;

                        when "0001010" =>
                           answer <= probe;
                           state  <= RESPOND;

                        when "0001101" =>
                           answer <= cardstat;
                           state  <= RESPOND;

                        when "0001110" =>
                           answer <= ipcstat;
                           state  <= RESPOND;

                        when "0001111" =>
                           answer <= perfstat;
                           state  <= RESPOND;

                        when "0001100" =>
                           case cmd_arg(2 downto 0) is
                              when "000"  => answer <= irq9_ime;
                              when "001"  => answer <= irq9_ie;
                              when "010"  => answer <= irq9_if;
                              when "011"  => answer <= irq7_ime;
                              when "100"  => answer <= irq7_ie;
                              when others => answer <= irq7_if;
                           end case;
                           state <= RESPOND;

                        when others =>
                           answer <= x"0000000" &
                                     hit7 & hit9 & held7 & held9;
                           state  <= RESPOND;
                     end case;
                  end if;

               when REG_WAIT =>
                  if (sel_cpu = '0') then answer <= regval9;
                  else                    answer <= regval7; end if;
                  state <= RESPOND;

               when PEEK_REQ =>
                  pk_ena   <= '1';
                  pk_timer <= (others => '0');
                  state    <= PEEK_WAIT;

               when PEEK_WAIT =>
                  pk_timer <= pk_timer + 1;
                  if (pk_done = '1') then
                     answer <= pk_data;
                     state  <= RESPOND;
                  elsif (pk_timer = x"FFFF") then
                     answer <= x"BADACCE5";
                     state  <= RESPOND;
                  end if;

               when RESPOND =>
                  rsp_data <= answer;
                  rsp_stb  <= '1';
                  state    <= IDLE;

            end case;
         end if;
      end if;
   end process;

end architecture;
