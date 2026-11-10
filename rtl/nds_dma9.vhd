-- SPDX-License-Identifier: GPL-2.0-or-later

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity nds_dma9 is
   port
   (
      clk          : in  std_logic;
      reset        : in  std_logic;

      gb_bus       : in  proc_bus_gb_type;
      wired_out    : out std_logic_vector(31 downto 0) := (others => '0');
      wired_done   : out std_logic;

      trig_vblank  : in  std_logic;
      trig_hblank  : in  std_logic;
      trig_card    : in  std_logic;

      cpu_bus_idle : in  std_logic;
      dma_on       : out std_logic := '0';
      dma_bus_on   : out std_logic := '0';

      mb_ena       : out std_logic := '0';
      mb_rnw       : out std_logic := '1';
      mb_adr       : out std_logic_vector(31 downto 0) := (others => '0');
      mb_acc       : out std_logic_vector(1 downto 0) := ACCESS_32BIT;
      mb_lowbits   : out std_logic_vector(1 downto 0) := "00";
      mb_dout      : out std_logic_vector(31 downto 0) := (others => '0');
      mb_din       : in  std_logic_vector(31 downto 0);
      mb_done      : in  std_logic;

      io_fast_ena  : out std_logic := '0';
      io_fast_rnw  : out std_logic := '1';
      io_fast_adr  : out std_logic_vector(27 downto 0) := (others => '0');
      io_fast_acc  : out std_logic_vector(1 downto 0) := ACCESS_32BIT;
      io_fast_be   : out std_logic_vector(3 downto 0) := "1111";
      io_fast_dout : out std_logic_vector(31 downto 0) := (others => '0');
      io_fast_din  : in  std_logic_vector(31 downto 0);

      vram_fast_ena  : out std_logic := '0';
      vram_fast_rnw  : out std_logic := '1';
      vram_fast_addr : out unsigned(23 downto 2) := (others => '0');
      vram_fast_be   : out std_logic_vector(3 downto 0) := "1111";
      vram_fast_din  : out std_logic_vector(31 downto 0) := (others => '0');
      vram_fast_dout : in  std_logic_vector(31 downto 0);
      vram_fast_done : in  std_logic;
      vram_fast_wpost : out std_logic := '1';
      vram_fast_welig : in  std_logic;
      vram_fast_wok   : in  std_logic;

      irq_dma      : out std_logic_vector(3 downto 0) := (others => '0')
   );
end entity;

architecture arch of nds_dma9 is

   constant ADR_BASE : unsigned(27 downto 0) := x"00000B0";

   type t_chan is record
      sad      : std_logic_vector(27 downto 0);
      dad      : std_logic_vector(27 downto 0);
      count    : std_logic_vector(20 downto 0);
      dstctl   : std_logic_vector(1 downto 0);
      srcctl   : std_logic_vector(1 downto 0);
      repeat   : std_logic;
      word32   : std_logic;
      timing   : std_logic_vector(2 downto 0);
      irqena   : std_logic;
      enable   : std_logic;
      cur_src  : unsigned(27 downto 0);
      cur_dst  : unsigned(27 downto 0);
      remain   : unsigned(21 downto 0);
      pend     : std_logic;
   end record;
   constant CHAN_INIT : t_chan := ((others => '0'), (others => '0'), (others => '0'),
                                   "00", "00", '0', '0', "000", '0', '0',
                                   (others => '0'), (others => '0'), (others => '0'), '0');
   type t_chans is array (0 to 3) of t_chan;
   signal ch : t_chans := (others => CHAN_INIT);

   type t_fill is array (0 to 3) of std_logic_vector(31 downto 0);
   signal fill : t_fill := (others => (others => '0'));

   type t_state is (IDLE, GRANT, LATCH, RD, RD_WAIT, RD_VRW,
                    WR, WR_WAIT, WR_VRW, COMPLETE);
   signal state  : t_state := IDLE;
   signal active : integer range 0 to 3 := 0;

   signal rdval  : std_logic_vector(31 downto 0) := (others => '0');

   signal unit_ret : std_logic := '0';

   signal regsel_ch  : integer range 0 to 3;
   signal regsel_reg : integer range 0 to 2;
   signal reg_hit    : std_logic;
   signal fill_hit   : std_logic;

   function is_io(a : unsigned(27 downto 0)) return boolean is
   begin
      return a(27 downto 24) = 4;
   end function;

   function is_vram(a : unsigned(27 downto 0)) return boolean is
   begin
      return a(27 downto 24) = 6;
   end function;

   function be_of(a : unsigned(27 downto 0); w32 : std_logic) return std_logic_vector is
   begin
      if (w32 = '1') then
         return "1111";
      elsif (a(1) = '1') then
         return "1100";
      else
         return "0011";
      end if;
   end function;

   function inc_of(ctl : std_logic_vector(1 downto 0); w32 : std_logic) return integer is
      variable step : integer;
   begin
      if (w32 = '1') then step := 4; else step := 2; end if;
      case ctl is
         when "01"   => return -step;
         when "10"   => return 0;
         when others => return step;
      end case;
   end function;

begin

   -- synthesis translate_off
   p_census : process (clk)
      variable rw, ww, un, cy : integer := 0;
   begin
      if rising_edge(clk) then
         if (state /= IDLE)     then cy := cy + 1; end if;
         if (state = RD_WAIT or state = RD_VRW) then rw := rw + 1; end if;
         if (state = WR_WAIT or state = WR_VRW) then ww := ww + 1; end if;
         if (unit_ret = '1')    then un := un + 1; end if;
         if (state = COMPLETE and un > 0) then
            report "dma9 census ch" & integer'image(active) & ": " &
                   integer'image(un) & " units, " & integer'image(cy) &
                   " cycles = " & integer'image(cy / un) & "/unit  (rd_wait " &
                   integer'image(rw / un) & ", wr_wait " & integer'image(ww / un) &
                   ", fsm " & integer'image((cy - rw - ww) / un) & ")";
            rw := 0; ww := 0; un := 0; cy := 0;
         end if;
      end if;
   end process;
   -- synthesis translate_on

   io_fast_ena <= '1' when (state = RD and is_io(ch(active).cur_src)) or
                           (state = WR and is_io(ch(active).cur_dst)) else '0';
   io_fast_rnw <= '1' when state = RD else '0';
   io_fast_adr <= x"0" & std_logic_vector(ch(active).cur_src(23 downto 2)) & "00"
                     when state = RD else
                  x"0" & std_logic_vector(ch(active).cur_dst(23 downto 2)) & "00";
   io_fast_be  <= be_of(ch(active).cur_src, ch(active).word32) when state = RD else
                  be_of(ch(active).cur_dst, ch(active).word32);
   io_fast_acc <= ACCESS_32BIT when ch(active).word32 = '1' else ACCESS_16BIT;
   io_fast_dout <= rdval when ch(active).word32 = '1' else
                   rdval(15 downto 0) & rdval(15 downto 0);

   vram_fast_ena  <= '1' when (state = RD and is_vram(ch(active).cur_src)) or
                              (state = WR and is_vram(ch(active).cur_dst) and
                               (vram_fast_welig = '0' or vram_fast_wok = '1')) else '0';
   vram_fast_rnw  <= '1' when state = RD else '0';
   vram_fast_addr <= ch(active).cur_src(23 downto 2) when state = RD else
                     ch(active).cur_dst(23 downto 2);
   vram_fast_be   <= be_of(ch(active).cur_src, ch(active).word32) when state = RD else
                     be_of(ch(active).cur_dst, ch(active).word32);
   vram_fast_din  <= rdval when ch(active).word32 = '1' else
                     rdval(15 downto 0) & rdval(15 downto 0);

   process (all)
      variable off : integer;
   begin
      reg_hit    <= '0';
      fill_hit   <= '0';
      regsel_ch  <= 0;
      regsel_reg <= 0;
      if (unsigned(gb_bus.Adr) >= ADR_BASE and unsigned(gb_bus.Adr) < ADR_BASE + 16#40#) then
         off := to_integer(unsigned(gb_bus.Adr) - ADR_BASE) / 4;
         if (off < 12) then
            reg_hit    <= '1';
            case off is
               when 0  => regsel_ch <= 0; regsel_reg <= 0;
               when 1  => regsel_ch <= 0; regsel_reg <= 1;
               when 2  => regsel_ch <= 0; regsel_reg <= 2;
               when 3  => regsel_ch <= 1; regsel_reg <= 0;
               when 4  => regsel_ch <= 1; regsel_reg <= 1;
               when 5  => regsel_ch <= 1; regsel_reg <= 2;
               when 6  => regsel_ch <= 2; regsel_reg <= 0;
               when 7  => regsel_ch <= 2; regsel_reg <= 1;
               when 8  => regsel_ch <= 2; regsel_reg <= 2;
               when 9  => regsel_ch <= 3; regsel_reg <= 0;
               when 10 => regsel_ch <= 3; regsel_reg <= 1;
               when 11 => regsel_ch <= 3; regsel_reg <= 2;
               when others => null;
            end case;
         else
            fill_hit  <= '1';
            regsel_ch <= off mod 4;
         end if;
      end if;
   end process;

   wired_done <= reg_hit or fill_hit;
   wired_out  <= fill(regsel_ch) when fill_hit = '1' else
                 x"0" & ch(regsel_ch).sad when (reg_hit = '1' and regsel_reg = 0) else
                 x"0" & ch(regsel_ch).dad when (reg_hit = '1' and regsel_reg = 1) else
                 ch(regsel_ch).enable & ch(regsel_ch).irqena & ch(regsel_ch).timing &
                 ch(regsel_ch).word32 & ch(regsel_ch).repeat & ch(regsel_ch).srcctl &
                 ch(regsel_ch).dstctl & ch(regsel_ch).count
                 when reg_hit = '1' else (others => '0');

   process (clk)
      variable v_ena   : std_logic;
      variable v_pick  : integer range 0 to 3;
      variable v_got   : std_logic;
      variable v_inc   : integer;
      variable lane16  : std_logic_vector(15 downto 0);

      procedure retire_unit is
         variable inc : integer;
      begin
         unit_ret <= '1';
         inc := inc_of(ch(active).srcctl, ch(active).word32);
         ch(active).cur_src <= ch(active).cur_src + inc;
         inc := inc_of(ch(active).dstctl, ch(active).word32);
         ch(active).cur_dst <= ch(active).cur_dst + inc;
         ch(active).remain  <= ch(active).remain - 1;
         if (ch(active).remain = 1 or ch(active).enable = '0') then
            state <= COMPLETE;
         else
            state <= RD;
         end if;
      end procedure;
   begin
      if rising_edge(clk) then

         irq_dma     <= (others => '0');
         mb_ena        <= '0';
         unit_ret      <= '0';

         if (reset = '1') then
            ch     <= (others => CHAN_INIT);
            state  <= IDLE;
            dma_on <= '0';
            dma_bus_on <= '0';
         else

            if (gb_bus.ena = '1' and gb_bus.rnw = '0') then
               if (fill_hit = '1') then
                  for i in 0 to 3 loop
                     if (gb_bus.bEna(i) = '1') then
                        fill(regsel_ch)(i*8 + 7 downto i*8) <= gb_bus.Din(i*8 + 7 downto i*8);
                     end if;
                  end loop;
               elsif (reg_hit = '1') then
                  case regsel_reg is
                     when 0 =>
                        for i in 0 to 3 loop
                           if (gb_bus.bEna(i) = '1' and i < 4) then
                              if (i = 3) then
                                 ch(regsel_ch).sad(27 downto 24) <= gb_bus.Din(27 downto 24);
                              else
                                 ch(regsel_ch).sad(i*8 + 7 downto i*8) <= gb_bus.Din(i*8 + 7 downto i*8);
                              end if;
                           end if;
                        end loop;
                     when 1 =>
                        for i in 0 to 3 loop
                           if (gb_bus.bEna(i) = '1') then
                              if (i = 3) then
                                 ch(regsel_ch).dad(27 downto 24) <= gb_bus.Din(27 downto 24);
                              else
                                 ch(regsel_ch).dad(i*8 + 7 downto i*8) <= gb_bus.Din(i*8 + 7 downto i*8);
                              end if;
                           end if;
                        end loop;
                     when others =>
                        v_ena := ch(regsel_ch).enable;
                        if (gb_bus.bEna(0) = '1') then ch(regsel_ch).count(7 downto 0)   <= gb_bus.Din(7 downto 0);   end if;
                        if (gb_bus.bEna(1) = '1') then ch(regsel_ch).count(15 downto 8)  <= gb_bus.Din(15 downto 8);  end if;
                        if (gb_bus.bEna(2) = '1') then
                           ch(regsel_ch).count(20 downto 16) <= gb_bus.Din(20 downto 16);
                           ch(regsel_ch).dstctl <= gb_bus.Din(22 downto 21);
                           ch(regsel_ch).srcctl(0) <= gb_bus.Din(23);
                        end if;
                        if (gb_bus.bEna(3) = '1') then
                           ch(regsel_ch).srcctl(1) <= gb_bus.Din(24);
                           ch(regsel_ch).repeat <= gb_bus.Din(25);
                           ch(regsel_ch).word32 <= gb_bus.Din(26);
                           ch(regsel_ch).timing <= gb_bus.Din(29 downto 27);
                           ch(regsel_ch).irqena <= gb_bus.Din(30);
                           ch(regsel_ch).enable <= gb_bus.Din(31);
                           if (gb_bus.Din(31) = '1' and v_ena = '0') then
                              ch(regsel_ch).cur_src <= unsigned(ch(regsel_ch).sad);
                              ch(regsel_ch).cur_dst <= unsigned(ch(regsel_ch).dad);
                              ch(regsel_ch).remain  <= (others => '0');
                              if (gb_bus.Din(29 downto 27) = "000") then
                                 ch(regsel_ch).pend <= '1';
                              end if;
                           end if;
                        end if;
                  end case;
               end if;
            end if;

            for i in 0 to 3 loop
               if (ch(i).enable = '1') then
                  if (trig_vblank = '1' and ch(i).timing = "001") then
                     ch(i).pend <= '1';
                  end if;
                  if (trig_hblank = '1' and ch(i).timing = "010") then
                     ch(i).pend <= '1';
                  end if;
                  if (trig_card = '1' and ch(i).timing = "101") then
                     ch(i).pend <= '1';
                  end if;
               end if;
            end loop;

            case state is

               when IDLE =>
                  dma_bus_on <= '0';
                  v_got  := '0';
                  v_pick := 0;
                  for i in 3 downto 0 loop
                     if (ch(i).pend = '1' and ch(i).enable = '1') then
                        v_pick := i;
                        v_got  := '1';
                     end if;
                  end loop;
                  if (v_got = '1') then
                     active <= v_pick;
                     dma_on <= '1';
                     state  <= GRANT;
                  else
                     dma_on <= '0';
                  end if;

               when GRANT =>
                  if (cpu_bus_idle = '1') then
                     dma_bus_on <= '1';
                     state      <= LATCH;
                  end if;

               when LATCH =>
                  ch(active).pend <= '0';
                  if (ch(active).remain = 0) then
                     if (unsigned(ch(active).count) = 0) then
                        ch(active).remain <= to_unsigned(16#200000#, 22);
                     else
                        ch(active).remain <= unsigned('0' & ch(active).count);
                     end if;
                     if (ch(active).srcctl = "11") then
                        ch(active).cur_src <= unsigned(ch(active).sad);
                     end if;
                     if (ch(active).dstctl = "11") then
                        ch(active).cur_dst <= unsigned(ch(active).dad);
                     end if;
                  end if;
                  state <= RD;

               when RD =>
                  if (is_io(ch(active).cur_src)) then
                     if (ch(active).word32 = '1') then
                        rdval <= io_fast_din;
                     elsif (ch(active).cur_src(1) = '1') then
                        rdval <= x"0000" & io_fast_din(31 downto 16);
                     else
                        rdval <= x"0000" & io_fast_din(15 downto 0);
                     end if;
                     state <= WR;
                  elsif (is_vram(ch(active).cur_src)) then
                     state <= RD_VRW;
                  else
                     mb_ena     <= '1';
                     mb_rnw     <= '1';
                     if (ch(active).word32 = '1') then
                        mb_adr     <= x"0" & std_logic_vector(ch(active).cur_src(27 downto 2)) & "00";
                        mb_acc     <= ACCESS_32BIT;
                        mb_lowbits <= "00";
                     else
                        mb_adr     <= x"0" & std_logic_vector(ch(active).cur_src(27 downto 1)) & '0';
                        mb_acc     <= ACCESS_16BIT;
                        mb_lowbits <= std_logic_vector(ch(active).cur_src(1 downto 1)) & '0';
                     end if;
                     state <= RD_WAIT;
                  end if;

               when RD_WAIT =>
                  if (mb_done = '1') then
                     rdval <= mb_din;
                     state <= WR;
                  end if;

               when RD_VRW =>
                  if (vram_fast_done = '1') then
                     if (ch(active).word32 = '1') then
                        rdval <= vram_fast_dout;
                     elsif (ch(active).cur_src(1) = '1') then
                        rdval <= x"0000" & vram_fast_dout(31 downto 16);
                     else
                        rdval <= x"0000" & vram_fast_dout(15 downto 0);
                     end if;
                     state <= WR;
                  end if;

               when WR =>
                  if (is_io(ch(active).cur_dst)) then
                     retire_unit;
                  elsif (is_vram(ch(active).cur_dst)) then
                     if (vram_fast_welig = '1') then
                        if (vram_fast_wok = '1') then
                           retire_unit;
                        end if;
                     else
                        state <= WR_VRW;
                     end if;
                  else
                     mb_ena <= '1';
                     mb_rnw <= '0';
                     if (ch(active).word32 = '1') then
                        mb_adr  <= x"0" & std_logic_vector(ch(active).cur_dst(27 downto 2)) & "00";
                        mb_acc  <= ACCESS_32BIT;
                        mb_dout <= rdval;
                     else
                        mb_adr  <= x"0" & std_logic_vector(ch(active).cur_dst(27 downto 1)) & '0';
                        mb_acc  <= ACCESS_16BIT;
                        lane16  := rdval(15 downto 0);
                        mb_dout <= lane16 & lane16;
                     end if;
                     mb_lowbits <= "00";
                     state <= WR_WAIT;
                  end if;

               when WR_WAIT =>
                  if (mb_done = '1') then
                     retire_unit;
                  end if;

               when WR_VRW =>
                  if (vram_fast_done = '1') then
                     retire_unit;
                  end if;

               when COMPLETE =>
                  if (ch(active).repeat = '0' or ch(active).timing = "000") then
                     ch(active).enable <= '0';
                  end if;
                  if (ch(active).irqena = '1') then
                     irq_dma(active) <= '1';
                  end if;
                  dma_bus_on <= '0';
                  state      <= IDLE;

            end case;

         end if;
      end if;
   end process;

end architecture;
