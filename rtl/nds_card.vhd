-- SPDX-License-Identifier: GPL-2.0-or-later

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity nds_card is
   generic
   (
      CARDSPEED_SHIFT : integer := 0;
      CARDPREFETCH    : integer := 4
   );
   port
   (
      clk          : in  std_logic;
      ce           : in  std_logic;
      reset        : in  std_logic;

      card7        : in  std_logic;

      fw_boot      : in  std_logic := '0';

      chipid       : in  std_logic_vector(31 downto 0);

      bus9         : in  proc_bus_gb_type;
      wired_out9   : out std_logic_vector(31 downto 0);
      wired_done9  : out std_logic;

      bus7         : in  proc_bus_gb_type;
      wired_out7   : out std_logic_vector(31 downto 0);
      wired_done7  : out std_logic;

      irq9_xfer    : out std_logic := '0';
      irq7_xfer    : out std_logic := '0';

      dbg_card     : out std_logic_vector(31 downto 0) := (others => '0');
      dma9_card    : out std_logic := '0';
      dma7_card    : out std_logic := '0';

      card_ena     : out std_logic := '0';
      card_addr    : out std_logic_vector(26 downto 2) := (others => '0');
      card_din     : in  std_logic_vector(31 downto 0);
      card_done    : in  std_logic
   );
end entity;

architecture arch of nds_card is

   constant ADR_AUXSPI  : std_logic_vector(27 downto 0) := x"00001A0";
   constant ADR_ROMCTRL : std_logic_vector(27 downto 0) := x"00001A4";
   constant ADR_CMD0    : std_logic_vector(27 downto 0) := x"00001A8";
   constant ADR_CMD4    : std_logic_vector(27 downto 0) := x"00001AC";
   constant ADR_DATA    : std_logic_vector(27 downto 0) := x"0100010";

   signal spicnt     : std_logic_vector(15 downto 0) := (others => '0');
   signal romctrl    : std_logic_vector(31 downto 0) := (others => '0');
   signal cmdbytes   : std_logic_vector(63 downto 0) := (others => '0');

   signal busy       : std_logic := '0';
   signal word_ready : std_logic := '0';
   signal romdata    : std_logic_vector(31 downto 0) := (others => '0');

   type tstate is
   (
      IDLE,
      CMDDELAY,
      FETCH,
      DATAREADY,
      WORDDELAY,
      FINISH
   );
   signal state      : tstate := IDLE;

   signal xferlen    : unsigned(12 downto 0) := (others => '0');
   signal xferpos    : unsigned(12 downto 0) := (others => '0');
   signal delay_cnt  : unsigned(19 downto 0) := (others => '0');
   signal cmd_b7     : std_logic := '0';
   signal cmd_b8     : std_logic := '0';
   signal cmd_redir  : std_logic := '0';
   signal b7_addr    : unsigned(31 downto 0) := (others => '0');

   type t_pf is array (0 to CARDPREFETCH-1) of std_logic_vector(31 downto 0);
   signal pf         : t_pf := (others => (others => '0'));
   signal pf_wr      : integer range 0 to CARDPREFETCH-1 := 0;
   signal pf_rd      : integer range 0 to CARDPREFETCH-1 := 0;
   signal pf_cnt     : integer range 0 to CARDPREFETCH := 0;
   signal pf_inflt   : std_logic := '0';
   signal pf_asked   : unsigned(12 downto 0) := (others => '0');

   function eff_addr(addr : unsigned(31 downto 0); redir : std_logic) return unsigned is
   begin
      if (redir = '1' and addr < 16#8000#) then
         return to_unsigned(16#8000#, 32) + (addr and to_unsigned(16#1FF#, 32));
      end if;
      return addr;
   end function;

   signal cmd_mode   : unsigned(1 downto 0) := "10";
   signal sec_cnt    : unsigned(2 downto 0) := (others => '0');
   signal key1_seen4 : std_logic := '0';

   signal romctrl_rd : std_logic_vector(31 downto 0);
   signal own9, own7 : std_logic;

   signal pop_req    : std_logic;

   type t_sram is array (0 to 8191) of std_logic_vector(7 downto 0);
   signal sram        : t_sram := (others => (others => '1'));
   signal sram_q      : std_logic_vector(7 downto 0);
   signal sram_we_r   : std_logic := '0';
   signal sram_wa_r   : integer range 0 to 8191 := 0;
   signal sram_wd_r   : std_logic_vector(7 downto 0) := (others => '0');
   signal spi_data    : std_logic_vector(7 downto 0) := (others => '0');
   signal spi_hold    : std_logic := '0';
   signal spi_pos     : unsigned(15 downto 0) := (others => '0');
   signal spi_busy    : unsigned(9 downto 0) := (others => '0');
   signal sram_cmd    : std_logic_vector(7 downto 0) := (others => '0');
   signal sram_addr   : unsigned(15 downto 0) := (others => '0');
   signal sram_status : std_logic_vector(7 downto 0) := (others => '0');
   signal auxspi_rd   : std_logic_vector(31 downto 0);
   signal spi_busy_bit : std_logic;

begin

   own9 <= not card7;
   own7 <= card7;

   romctrl_rd <= busy & romctrl(30 downto 24) & word_ready & romctrl(22 downto 0);

   dbg_card <= std_logic_vector(to_unsigned(tstate'pos(state), 3))
               & busy & word_ready & own9 & own7 & spicnt(14) & pop_req
               & std_logic_vector(xferlen(6 downto 0))
               & std_logic_vector(to_unsigned(pf_cnt, 3))
               & std_logic_vector(xferpos);

   spi_busy_bit <= '1' when (spi_busy /= 0) else '0';
   auxspi_rd  <= x"00" & spi_data & spicnt(15 downto 8) &
                 spi_busy_bit & spicnt(6 downto 0);

   wired_out9 <= auxspi_rd                         when (own9 = '1' and bus9.Adr = ADR_AUXSPI)  else
                 romctrl_rd                        when (own9 = '1' and bus9.Adr = ADR_ROMCTRL) else
                 cmdbytes(39 downto 32) & cmdbytes(47 downto 40) & cmdbytes(55 downto 48) & cmdbytes(63 downto 56)
                                                   when (own9 = '1' and bus9.Adr = ADR_CMD0)    else
                 cmdbytes(7 downto 0) & cmdbytes(15 downto 8) & cmdbytes(23 downto 16) & cmdbytes(31 downto 24)
                                                   when (own9 = '1' and bus9.Adr = ADR_CMD4)    else
                 romdata                           when (own9 = '1' and bus9.Adr = ADR_DATA)    else
                 (others => '0');
   wired_done9 <= '1' when (bus9.Adr = ADR_AUXSPI or bus9.Adr = ADR_ROMCTRL or
                            bus9.Adr = ADR_CMD0 or bus9.Adr = ADR_CMD4 or
                            bus9.Adr(27 downto 4) = x"00001B" or bus9.Adr = ADR_DATA) else '0';

   wired_out7 <= auxspi_rd                         when (own7 = '1' and bus7.Adr = ADR_AUXSPI)  else
                 romctrl_rd                        when (own7 = '1' and bus7.Adr = ADR_ROMCTRL) else
                 romdata                           when (own7 = '1' and bus7.Adr = ADR_DATA)    else
                 (others => '0');
   wired_done7 <= '1' when (bus7.Adr = ADR_AUXSPI or bus7.Adr = ADR_ROMCTRL or
                            bus7.Adr = ADR_CMD0 or bus7.Adr = ADR_CMD4 or
                            bus7.Adr(27 downto 4) = x"00001B" or bus7.Adr = ADR_DATA) else '0';

   process (clk)
   begin
      if rising_edge(clk) then
         if (sram_we_r = '1') then
            sram(sram_wa_r) <= sram_wd_r;
         end if;
         sram_q <= sram(to_integer(sram_addr(12 downto 0)));
      end if;
   end process;

   process (clk)
      variable wval      : std_logic_vector(31 downto 0);
      variable owner_bus : proc_bus_gb_type;
      variable v_start   : std_logic;
      variable v_size    : unsigned(2 downto 0);
      variable v_len     : unsigned(12 downto 0);
      variable v_cmddel  : unsigned(19 downto 0);
      variable v_xcyc    : unsigned(3 downto 0);
      variable v_pos     : unsigned(12 downto 0);
      variable v_b7      : std_logic;
      variable v_b8      : std_logic;
      variable v_redir   : std_logic;
      variable v_addr    : unsigned(31 downto 0);
      variable v_pfcnt   : integer range 0 to CARDPREFETCH;
      variable v_inflt   : std_logic;
      variable v_spival  : std_logic_vector(7 downto 0);
      variable v_spipos  : unsigned(15 downto 0);
      variable v_spilast : std_logic;
   begin
      if rising_edge(clk) then

         irq9_xfer <= '0';
         irq7_xfer <= '0';
         dma9_card <= '0';
         dma7_card <= '0';
         card_ena  <= '0';
         sram_we_r <= '0';

         if (reset = '1') then

            spicnt     <= (others => '0');
            romctrl    <= (others => '0');
            cmdbytes   <= (others => '0');
            busy       <= '0';
            word_ready <= '0';
            pop_req    <= '0';
            state      <= IDLE;
            if (fw_boot = '1') then
               cmd_mode <= "00";
            else
               cmd_mode <= "10";
            end if;
            sec_cnt     <= (others => '0');
            key1_seen4  <= '0';
            pf_wr       <= 0;
            pf_rd       <= 0;
            pf_cnt      <= 0;
            pf_inflt    <= '0';
            pf_asked    <= (others => '0');
            spi_data    <= (others => '0');
            spi_hold    <= '0';
            spi_pos     <= (others => '0');
            spi_busy    <= (others => '0');
            sram_cmd    <= (others => '0');
            sram_status <= (others => '0');

         elsif (ce = '1') then

            if (spi_busy /= 0) then
               spi_busy <= spi_busy - 1;
            end if;

            v_pfcnt := pf_cnt;
            v_inflt := pf_inflt;
            if (card_done = '1' and pf_inflt = '1') then
               pf(pf_wr) <= card_din;
               if (pf_wr = CARDPREFETCH-1) then pf_wr <= 0; else pf_wr <= pf_wr + 1; end if;
               v_pfcnt := v_pfcnt + 1;
               v_inflt := '0';
            end if;

            if (card7 = '1') then
               owner_bus := bus7;
            else
               owner_bus := bus9;
            end if;

            v_start := '0';
            if (owner_bus.ena = '1' and owner_bus.rnw = '0') then

               if (owner_bus.Adr = ADR_AUXSPI) then
                  if (owner_bus.bEna(0) = '1') then
                     spicnt(7 downto 0)  <= owner_bus.Din(7 downto 0);
                  end if;
                  if (owner_bus.bEna(1) = '1') then
                     spicnt(15 downto 8) <= owner_bus.Din(15 downto 8);
                     if (owner_bus.Din(15) = '0') then
                        spi_hold <= '0';
                     end if;
                  end if;
                  if (owner_bus.bEna(2) = '1' and spicnt(15) = '1' and spicnt(13) = '1' and
                      spi_busy = 0) then
                     v_spival := owner_bus.Din(23 downto 16);
                     if (spicnt(6) = '0') then
                        if (spi_hold = '1') then
                           v_spipos := spi_pos + 1;
                        else
                           v_spipos := (others => '0');
                        end if;
                        v_spilast := '1';
                        spi_hold <= '0';
                     elsif (spi_hold = '0') then
                        spi_hold <= '1';
                        v_spipos := (others => '0');
                        v_spilast := '0';
                     else
                        v_spipos := spi_pos + 1;
                        v_spilast := '0';
                     end if;
                     spi_pos <= v_spipos;
                     spi_busy <= shift_left(to_unsigned(64, 10),
                                            to_integer(unsigned(spicnt(1 downto 0))));

                     spi_data <= (others => '0');
                     if (v_spipos = 0) then
                        if (v_spival = x"04") then
                           sram_status(1) <= '0';
                        elsif (v_spival = x"06") then
                           sram_status(1) <= '1';
                        else
                           sram_cmd  <= v_spival;
                           sram_addr <= (others => '0');
                           spi_data  <= (others => '1');
                        end if;
                     else
                        case sram_cmd is
                           when x"01" =>
                              if (v_spipos = 1) then
                                 sram_status <= (sram_status and x"01") or (v_spival and x"0C");
                              end if;
                           when x"05" =>
                              spi_data <= sram_status;
                           when x"02" =>
                              if (v_spipos <= 2) then
                                 sram_addr <= sram_addr(7 downto 0) & unsigned(v_spival);
                              else
                                 if (sram_status(1) = '1') then
                                    sram_we_r <= '1';
                                    sram_wa_r <= to_integer(sram_addr(12 downto 0));
                                    sram_wd_r <= v_spival;
                                 end if;
                                 sram_addr <= sram_addr + 1;
                              end if;
                              if (v_spilast = '1') then
                                 sram_status(1) <= '0';
                              end if;
                           when x"03" =>
                              if (v_spipos <= 2) then
                                 sram_addr <= sram_addr(7 downto 0) & unsigned(v_spival);
                              else
                                 spi_data  <= sram_q;
                                 sram_addr <= sram_addr + 1;
                              end if;
                           when others =>
                              spi_data <= (others => '1');
                        end case;
                     end if;
                  end if;

               elsif (owner_bus.Adr = ADR_ROMCTRL) then
                  wval := romctrl;
                  for i in 0 to 3 loop
                     if (owner_bus.bEna(i) = '1') then
                        wval(i*8 + 7 downto i*8) := owner_bus.Din(i*8 + 7 downto i*8);
                     end if;
                  end loop;
                  romctrl <= wval;
                  if (wval(31) = '1' and busy = '0' and owner_bus.bEna(3) = '1' and
                      spicnt(15) = '1' and spicnt(13) = '0') then
                     v_start := '1';
                  end if;

               elsif (owner_bus.Adr = ADR_CMD0) then
                  if (owner_bus.bEna(0) = '1') then cmdbytes(63 downto 56) <= owner_bus.Din(7 downto 0); end if;
                  if (owner_bus.bEna(1) = '1') then cmdbytes(55 downto 48) <= owner_bus.Din(15 downto 8); end if;
                  if (owner_bus.bEna(2) = '1') then cmdbytes(47 downto 40) <= owner_bus.Din(23 downto 16); end if;
                  if (owner_bus.bEna(3) = '1') then cmdbytes(39 downto 32) <= owner_bus.Din(31 downto 24); end if;

               elsif (owner_bus.Adr = ADR_CMD4) then
                  if (owner_bus.bEna(0) = '1') then cmdbytes(31 downto 24) <= owner_bus.Din(7 downto 0); end if;
                  if (owner_bus.bEna(1) = '1') then cmdbytes(23 downto 16) <= owner_bus.Din(15 downto 8); end if;
                  if (owner_bus.bEna(2) = '1') then cmdbytes(15 downto 8)  <= owner_bus.Din(23 downto 16); end if;
                  if (owner_bus.bEna(3) = '1') then cmdbytes(7 downto 0)   <= owner_bus.Din(31 downto 24); end if;

               end if;

            end if;

            pop_req <= '0';
            if (owner_bus.ena = '1' and owner_bus.rnw = '1' and owner_bus.Adr = ADR_DATA and
                romctrl(30) = '0' and word_ready = '1') then
               pop_req <= '1';
            end if;

            if (v_start = '1') then
               v_size := unsigned(wval(26 downto 24));
               if (v_size = 7) then
                  v_len := to_unsigned(1, 13);
               elsif (v_size = 0) then
                  v_len := (others => '0');
               else
                  v_len := shift_left(to_unsigned(64, 13), to_integer(v_size));
               end if;
               xferlen <= v_len;
               xferpos <= (others => '0');
               busy    <= '1';
               word_ready <= '0';

               v_b7    := '0';
               v_b8    := '0';
               v_redir := '0';
               v_addr  := unsigned(cmdbytes(55 downto 24));

               case to_integer(cmd_mode) is

                  when 0 =>
                     case cmdbytes(63 downto 56) is
                        when x"9F" =>
                           null;
                        when x"00" =>
                           v_b7   := '1';
                           v_addr := (others => '0');
                        when x"90" =>
                           v_b8 := '1';
                        when x"3C" =>
                           cmd_mode   <= "01";
                           sec_cnt    <= (others => '0');
                           key1_seen4 <= '0';
                        when others =>
                           null;
                     end case;

                  when 1 =>
                     if (v_len = 0) then
                        if (key1_seen4 = '0') then
                           key1_seen4 <= '1';
                        else
                           cmd_mode <= "10";
                        end if;
                     elsif (v_len = 1) then
                        v_b8 := '1';
                     else
                        v_b7 := '1';
                        case to_integer(sec_cnt) is
                           when 0      => v_addr := x"00006000";
                           when 1      => v_addr := x"00007000";
                           when 2      => v_addr := x"00005000";
                           when others => v_addr := x"00004000";
                        end case;
                        if (sec_cnt /= 7) then
                           sec_cnt <= sec_cnt + 1;
                        end if;
                     end if;

                  when others =>
                     if (cmdbytes(63 downto 56) = x"B7") then
                        v_b7    := '1';
                        v_redir := '1';
                     elsif (cmdbytes(63 downto 56) = x"B8") then
                        v_b8 := '1';
                     end if;

               end case;

               cmd_b7    <= v_b7;
               cmd_b8    <= v_b8;
               cmd_redir <= v_redir;
               b7_addr   <= v_addr;

               v_pfcnt  := 0;
               pf_wr    <= 0;
               pf_rd    <= 0;
               pf_asked <= (others => '0');

               -- synthesis translate_off
               report "CARD: mode=" & integer'image(to_integer(cmd_mode)) &
                      " cmd=" & to_hstring(cmdbytes(63 downto 56)) &
                      " addr=" & to_hstring(cmdbytes(55 downto 24)) &
                      " words=" & integer'image(to_integer(v_len));
               -- synthesis translate_on

               if (wval(27) = '1') then v_xcyc := to_unsigned(8, 4); else v_xcyc := to_unsigned(5, 4); end if;
               v_cmddel := to_unsigned(8, 20);
               if (wval(30) = '0') then
                  v_cmddel := v_cmddel + unsigned(wval(12 downto 0));
                  if (v_len /= 0) then
                     v_cmddel := v_cmddel + unsigned(wval(21 downto 16));
                  end if;
               end if;
               if (v_len /= 0) then
                  v_cmddel := v_cmddel + 4;
               end if;
               delay_cnt <= shift_right(resize(v_cmddel * v_xcyc, 20), CARDSPEED_SHIFT);
               state     <= CMDDELAY;
            end if;

            case state is

               when IDLE => null;

               when CMDDELAY =>
                  if (delay_cnt /= 0) then
                     delay_cnt <= delay_cnt - 1;
                  elsif (xferlen = 0) then
                     state <= FINISH;
                  else
                     state <= FETCH;
                  end if;

               when WORDDELAY =>
                  if (delay_cnt /= 0) then
                     delay_cnt <= delay_cnt - 1;
                  else
                     state <= FETCH;
                  end if;

               when FETCH =>
                  if (cmd_b7 = '0') then
                     if (cmd_b8 = '1') then
                        romdata <= chipid;
                     else
                        romdata <= (others => '1');
                     end if;
                     word_ready <= '1';
                     dma9_card  <= own9;
                     dma7_card  <= own7;
                     state      <= DATAREADY;
                  elsif (v_pfcnt /= 0) then
                     if (pf_cnt = 0) then
                        romdata <= card_din;
                     else
                        romdata <= pf(pf_rd);
                     end if;
                     if (pf_rd = CARDPREFETCH-1) then pf_rd <= 0; else pf_rd <= pf_rd + 1; end if;
                     v_pfcnt    := v_pfcnt - 1;
                     word_ready <= '1';
                     dma9_card  <= own9;
                     dma7_card  <= own7;
                     state      <= DATAREADY;
                  end if;

               when DATAREADY =>
                  if (pop_req = '1') then
                     word_ready <= '0';
                     v_pos      := xferpos + 1;
                     xferpos    <= v_pos;
                     if (v_pos >= xferlen) then
                        state <= FINISH;
                     else
                        if (romctrl(27) = '1') then v_xcyc := to_unsigned(8, 4); else v_xcyc := to_unsigned(5, 4); end if;
                        v_cmddel := to_unsigned(4, 20);
                        if (romctrl(30) = '0' and v_pos(6 downto 0) = 0) then
                           v_cmddel := v_cmddel + unsigned(romctrl(21 downto 16));
                        end if;
                        delay_cnt <= shift_right(resize(v_cmddel * v_xcyc, 20), CARDSPEED_SHIFT);
                        state     <= WORDDELAY;
                     end if;
                  end if;

               when FINISH =>
                  busy       <= '0';
                  word_ready <= '0';
                  if (spicnt(14) = '1') then
                     irq9_xfer <= own9;
                     irq7_xfer <= own7;
                  end if;
                  state <= IDLE;

            end case;

            if (busy = '1' and cmd_b7 = '1' and v_inflt = '0' and
                v_pfcnt < CARDPREFETCH and pf_asked < xferlen) then
               card_ena  <= '1';
               card_addr <= std_logic_vector(eff_addr(b7_addr, cmd_redir)(26 downto 2));
               b7_addr   <= b7_addr + 4;
               pf_asked  <= pf_asked + 1;
               v_inflt   := '1';
            end if;

            pf_cnt   <= v_pfcnt;
            pf_inflt <= v_inflt;

         end if;

      end if;
   end process;

end architecture;
