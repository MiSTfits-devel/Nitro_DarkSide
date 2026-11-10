-- SPDX-License-Identifier: GPL-2.0-or-later

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nds_loader is
   generic
   (
      is_simu     : std_logic := '0';
      skip_copy   : std_logic := '0'
   );
   port
   (
      clk         : in  std_logic;
      reset       : in  std_logic;
      start       : in  std_logic;
      direct      : in  std_logic := '0';
      fw_boot     : in  std_logic := '0';
      busy        : out std_logic := '0';
      done        : out std_logic := '0';
      load_error  : out std_logic := '0';

      arm9_entry  : out std_logic_vector(31 downto 0) := (others => '0');
      arm7_entry  : out std_logic_vector(31 downto 0) := (others => '0');
      cart_id     : out std_logic_vector(31 downto 0) := (others => '0');

      card_ena    : out std_logic := '0';
      card_addr   : out std_logic_vector(26 downto 2) := (others => '0');
      card_done   : in  std_logic;
      card_rdata  : in  std_logic_vector(31 downto 0);

      wr_ena      : out std_logic := '0';
      wr_rnw      : out std_logic := '0';
      wr_addr     : out std_logic_vector(31 downto 0) := (others => '0');
      wr_data     : out std_logic_vector(31 downto 0) := (others => '0');
      wr_done     : in  std_logic;
      rd_data     : in  std_logic_vector(31 downto 0) := (others => '0');

      vfy_bad     : out std_logic_vector(17 downto 0) := (others => '0');
      vfy_addr    : out std_logic_vector(31 downto 0) := (others => '0')
   );
end entity;

architecture arch of nds_loader is

   type t_state is
   (
      IDLE,
      CLR_WR, CLR_WR_WAIT,
      HDR_REQ, HDR_WAIT,
      CP_RD, CP_RD_WAIT,
      CP_WR, CP_WR_WAIT,
      NEXT_CPU,
      CARTID_CALC,
      ENV_SET, ENV_WR, ENV_WR_WAIT,
      VF_RD, VF_RD_WAIT,
      VF_MEM, VF_MEM_WAIT,
      FINISHED
   );
   signal state : t_state := IDLE;

   type t_hdr is array (0 to 7) of std_logic_vector(31 downto 0);
   signal hdr     : t_hdr := (others => (others => '0'));
   signal hdr_i   : integer range 0 to 8 := 0;

   signal clr_i   : unsigned(19 downto 0) := (others => '0');
   signal clr_w7  : std_logic := '0';

   signal cpu_sel : integer range 0 to 2 := 0;
   signal src     : unsigned(26 downto 2) := (others => '0');
   signal dst     : unsigned(31 downto 0) := (others => '0');
   signal words   : unsigned(21 downto 0) := (others => '0');

   signal env_size   : unsigned(31 downto 0) := (others => '0');
   signal env_hdrcrc : std_logic_vector(15 downto 0) := (others => '0');
   signal env_seccrc : std_logic_vector(15 downto 0) := (others => '0');
   signal cart_p     : unsigned(31 downto 0) := to_unsigned(512, 32);
   signal cart_iter  : integer range 9 to 28 := 9;
   signal cartid     : std_logic_vector(31 downto 0) := (others => '0');
   signal crcword    : std_logic_vector(31 downto 0) := (others => '0');
   signal env_i      : integer range 0 to 41 := 0;

   signal verifying  : std_logic := '0';
   signal vfy_exp    : std_logic_vector(31 downto 0) := (others => '0');
   signal vfy_cnt    : unsigned(17 downto 0) := (others => '0');
   signal vfy_seen   : std_logic := '0';
   signal vfy_at     : std_logic_vector(31 downto 0) := (others => '0');

   function env_addr(i : integer) return unsigned is
   begin
      case i is
         when  0 => return x"02FFF800";
         when  1 => return x"02FFF804";
         when  2 => return x"02FFF808";
         when  3 => return x"02FFF850";
         when  4 => return x"02FFFC00";
         when  5 => return x"02FFFC04";
         when  6 => return x"02FFFC08";
         when  7 => return x"02FFFC10";
         when  8 => return x"02FFFC30";
         when  9 => return x"02FFFC40";
         when 10 => return x"02FFF864";
         when 11 => return x"02FFF868";
         when 12 => return x"02FFF874";
         when others => return to_unsigned(16#02FFFC80# + (i - 13) * 4, 32);
      end case;
   end function;

begin

   cart_id  <= cartid;
   vfy_bad  <= std_logic_vector(vfy_cnt);
   vfy_addr <= vfy_at;

   process (clk)
      variable romoff, loadaddr, size : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk) then

         card_ena <= '0';
         wr_ena   <= '0';

         if (reset = '1') then
            state      <= IDLE;
            busy       <= '0';
            done       <= '0';
            load_error <= '0';
            verifying  <= '0';
            vfy_cnt    <= (others => '0');
            vfy_seen   <= '0';
            wr_rnw     <= '0';
         else
            case state is

               when IDLE =>
                  if (start = '1') then
                     busy  <= '1';
                     done  <= '0';
                     hdr_i <= 0;
                     clr_i  <= (others => '0');
                     clr_w7 <= '0';
                     if (is_simu = '1') then
                        state <= HDR_REQ;
                     else
                        state <= CLR_WR;
                     end if;
                  end if;

               when CLR_WR =>
                  wr_ena  <= '1';
                  wr_rnw  <= '0';
                  if (clr_w7 = '0') then
                     wr_addr <= x"02" & "00" & std_logic_vector(clr_i) & "00";
                  else
                     wr_addr <= x"038" & x"0" & std_logic_vector(clr_i(13 downto 0)) & "00";
                  end if;
                  wr_data <= (others => '0');
                  state   <= CLR_WR_WAIT;

               when CLR_WR_WAIT =>
                  if (wr_done = '1') then
                     if (clr_w7 = '0') then
                        if (clr_i = to_unsigned(1048575, clr_i'length)) then
                           clr_i  <= (others => '0');
                           clr_w7 <= '1';
                           state  <= CLR_WR;
                        else
                           clr_i <= clr_i + 1;
                           state <= CLR_WR;
                        end if;
                     else
                        if (clr_i = to_unsigned(16383, clr_i'length)) then
                           state <= HDR_REQ;
                        else
                           clr_i <= clr_i + 1;
                           state <= CLR_WR;
                        end if;
                     end if;
                  end if;

               when HDR_REQ =>
                  card_ena <= '1';
                  if (hdr_i = 8) then
                     card_addr <= std_logic_vector(to_unsigned(16#20#, 25));
                  else
                     card_addr <= std_logic_vector(to_unsigned(8 + hdr_i, 25));
                  end if;
                  state <= HDR_WAIT;

               when HDR_WAIT =>
                  if (card_done = '1') then
                     if (hdr_i = 8) then
                        env_size <= unsigned(card_rdata);
                        cpu_sel  <= 0;
                        if (fw_boot = '1') then
                           cart_p    <= to_unsigned(512, cart_p'length);
                           cart_iter <= 9;
                           state     <= CARTID_CALC;
                        else
                           state <= NEXT_CPU;
                        end if;
                     else
                        hdr(hdr_i) <= card_rdata;
                        hdr_i      <= hdr_i + 1;
                        state      <= HDR_REQ;
                     end if;
                  end if;

               when NEXT_CPU =>
                  romoff   := hdr(cpu_sel*4 + 0);
                  loadaddr := hdr(cpu_sel*4 + 2);
                  size     := hdr(cpu_sel*4 + 3);
                  arm9_entry <= hdr(1) and x"FFFFFFFE";
                  arm7_entry <= hdr(5) and x"FFFFFFFE";
                  if (loadaddr(31 downto 24) /= x"02" and loadaddr(31 downto 20) /= x"037") then
                     load_error <= '1';
                     busy       <= '0';
                     state      <= FINISHED;
                  else
                     src <= unsigned(romoff(26 downto 2));
                     dst <= unsigned(loadaddr);
                     if (skip_copy = '1' and loadaddr(31 downto 24) = x"02") then
                        words <= (others => '0');
                     elsif (size(1 downto 0) = "00") then
                        words <= unsigned(size(23 downto 2));
                     else
                        words <= unsigned(size(23 downto 2)) + 1;
                     end if;
                     if (verifying = '1') then
                        state <= VF_RD;
                     else
                        state <= CP_RD;
                     end if;
                  end if;

               when CP_RD =>
                  if (words = 0) then
                     if (cpu_sel = 0) then
                        cpu_sel <= 1;
                        state   <= NEXT_CPU;
                     elsif (cpu_sel = 1 and direct = '1') then
                        cpu_sel <= 2;
                        src     <= (others => '0');
                        dst     <= x"02FFFE00";
                        words   <= to_unsigned(16#5C#, words'length);
                        state   <= CP_RD;
                     else
                        cart_p    <= to_unsigned(512, cart_p'length);
                        cart_iter <= 9;
                        crcword <= env_seccrc & env_hdrcrc;
                        env_i   <= 0;
                        state   <= CARTID_CALC;
                     end if;
                  else
                     card_ena  <= '1';
                     card_addr <= std_logic_vector(src);
                     state     <= CP_RD_WAIT;
                  end if;

               when CP_RD_WAIT =>
                  if (card_done = '1') then
                     wr_data <= card_rdata;
                     state   <= CP_WR;
                     if (cpu_sel = 2) then
                        if (src = 16#1B#) then
                           env_seccrc <= card_rdata(15 downto 0);
                        elsif (src = 16#57#) then
                           env_hdrcrc <= card_rdata(31 downto 16);
                        end if;
                     end if;
                  end if;

               when CP_WR =>
                  wr_ena  <= '1';
                  wr_addr <= std_logic_vector(dst);
                  state   <= CP_WR_WAIT;

               when CP_WR_WAIT =>
                  if (wr_done = '1') then
                     src   <= src + 1;
                     dst   <= dst + 4;
                     words <= words - 1;
                     state <= CP_RD;
                  end if;

               when CARTID_CALC =>
                  if (cart_iter <= 27) then
                     if (cart_p < env_size) then
                        cart_p <= shift_left(cart_p, 1);
                     end if;
                     cart_iter <= cart_iter + 1;
                  else
                     if (cart_p >= x"00100000") then
                        cartid <= std_logic_vector(
                           x"000000C2" or
                           shift_left(resize(shift_right(cart_p, 20) - 1, 32), 8));
                     else
                        cartid <= x"000100C2";
                     end if;
                     if (fw_boot = '1') then
                        busy  <= '0';
                        done  <= '1';
                        state <= FINISHED;
                     elsif (direct = '1') then
                        state <= ENV_SET;
                     else
                        verifying <= '1';
                        cpu_sel   <= 0;
                        state     <= NEXT_CPU;
                     end if;
                  end if;

               when ENV_SET =>
                  if (env_i = 41) then
                     verifying <= '1';
                     cpu_sel   <= 0;
                     state     <= NEXT_CPU;
                  else
                     dst <= env_addr(env_i);
                     case env_i is
                        when 0 | 1 | 4 | 5 => wr_data <= cartid;
                        when 2 | 6         => wr_data <= crcword;
                        when 3 | 7         => wr_data <= x"00005835";
                        when 8             => wr_data <= x"0000FFFF";
                        when 9             => wr_data <= x"00000001";
                        when 10            => wr_data <= x"00000000";
                        when 11            => wr_data <= x"0007FE00";
                        when 12            => wr_data <= x"0000FFFF";
                        when 13            => wr_data <= x"01000005";
                        when 14            => wr_data <= x"00000001";
                        when 38            => wr_data <= x"00000031";
                        when others        => wr_data <= x"00000000";
                     end case;
                     state <= ENV_WR;
                  end if;

               when ENV_WR =>
                  wr_ena  <= '1';
                  wr_addr <= std_logic_vector(dst);
                  state   <= ENV_WR_WAIT;

               when ENV_WR_WAIT =>
                  if (wr_done = '1') then
                     env_i <= env_i + 1;
                     state <= ENV_SET;
                  end if;

               when VF_RD =>
                  if (words = 0) then
                     if (cpu_sel = 0) then
                        cpu_sel <= 1;
                        state   <= NEXT_CPU;
                     else
                        busy  <= '0';
                        done  <= '1';
                        state <= FINISHED;
                     end if;
                  elsif (dst(31 downto 24) /= x"02") then
                     src   <= src + 1;
                     dst   <= dst + 4;
                     words <= words - 1;
                  else
                     card_ena  <= '1';
                     card_addr <= std_logic_vector(src);
                     state     <= VF_RD_WAIT;
                  end if;

               when VF_RD_WAIT =>
                  if (card_done = '1') then
                     vfy_exp <= card_rdata;
                     state   <= VF_MEM;
                  end if;

               when VF_MEM =>
                  wr_ena  <= '1';
                  wr_rnw  <= '1';
                  wr_addr <= std_logic_vector(dst);
                  state   <= VF_MEM_WAIT;

               when VF_MEM_WAIT =>
                  if (wr_done = '1') then
                     wr_rnw <= '0';
                     if (rd_data /= vfy_exp) then
                        if (vfy_cnt /= 2#111111111111111111#) then
                           vfy_cnt <= vfy_cnt + 1;
                        end if;
                        if (vfy_seen = '0') then
                           vfy_seen <= '1';
                           vfy_at   <= std_logic_vector(dst);
                        end if;
                     end if;
                     src   <= src + 1;
                     dst   <= dst + 4;
                     words <= words - 1;
                     state <= VF_RD;
                  end if;

               when FINISHED =>
                  null;

            end case;
         end if;
      end if;
   end process;

end architecture;
