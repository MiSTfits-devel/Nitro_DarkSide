-- keep up the channel repeats its current sample - a divergence, never a

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library MEM;

use work.pProc_bus_gba.all;

entity nds_sound is
   generic
   (
      is_simu     : std_logic := '0';
      ADPCM_TABLE_RAM : integer := 1
   );
   port
   (
      clk         : in  std_logic;
      ce          : in  std_logic;
      reset       : in  std_logic;

      bus7        : in  proc_bus_gb_type;
      wired_out7  : out std_logic_vector(31 downto 0);
      wired_done7 : out std_logic;

      snd_bus_req : out std_logic := '0';
      snd_bus_ok  : in  std_logic;
      snd_bus_own : out std_logic := '0';
      mb_ena      : out std_logic := '0';
      mb_adr      : out std_logic_vector(31 downto 0) := (others => '0');
      mb_din      : in  std_logic_vector(31 downto 0);
      mb_done     : in  std_logic;

      sample_l     : out std_logic_vector(15 downto 0) := (others => '0');
      sample_r     : out std_logic_vector(15 downto 0) := (others => '0');
      sample_valid : out std_logic := '0';

      snd_enable  : out std_logic;
      snd_active  : out std_logic_vector(15 downto 0)
   );
end entity;

architecture arch of nds_sound is

   type t_chan is record
      volmul   : std_logic_vector(6 downto 0);
      voldiv   : std_logic_vector(1 downto 0);
      hold     : std_logic;
      pan      : std_logic_vector(6 downto 0);
      duty     : std_logic_vector(2 downto 0);
      repeatm  : std_logic_vector(1 downto 0);
      format   : std_logic_vector(1 downto 0);
      busy     : std_logic;
      sad      : std_logic_vector(26 downto 0);
      tmr      : std_logic_vector(15 downto 0);
      pnt      : std_logic_vector(15 downto 0);
      len      : std_logic_vector(21 downto 0);
      timer    : unsigned(16 downto 0);
      remwords : unsigned(23 downto 0);
      subpos   : unsigned(2 downto 0);
      startdel : unsigned(1 downto 0);
      curw     : std_logic_vector(31 downto 0);
      nxtw     : std_logic_vector(31 downto 0);
      curv     : std_logic;
      nxtv     : std_logic;
      adhdr    : std_logic;
      adval    : signed(15 downto 0);
      adidx    : integer range 0 to 88;
      adval_l  : signed(15 downto 0);
      adidx_l  : integer range 0 to 88;
      noise    : unsigned(15 downto 0);
      psgpos   : unsigned(2 downto 0);
      cursmp   : signed(15 downto 0);
   end record;
   type t_chans is array (0 to 15) of t_chan;
   signal chan : t_chans;

   signal fptr_a_addr : integer range 0 to 15 := 0;
   signal fptr_a_din  : unsigned(24 downto 0) := (others => '0');
   signal fptr_a_we   : std_logic := '0';
   signal fptr_b_addr : integer range 0 to 15 := 0;
   signal fptr_b_din  : unsigned(24 downto 0) := (others => '0');
   signal fptr_b_dout : std_logic_vector(31 downto 0);
   signal fptr_b_we   : std_logic := '0';

   signal frem_a_addr : integer range 0 to 15 := 0;
   signal frem_a_din  : unsigned(23 downto 0) := (others => '0');
   signal frem_a_we   : std_logic := '0';
   signal frem_b_addr : integer range 0 to 15 := 0;
   signal frem_b_din  : unsigned(23 downto 0) := (others => '0');
   signal frem_b_dout : std_logic_vector(31 downto 0);
   signal frem_b_we   : std_logic := '0';

   signal soundcnt  : std_logic_vector(15 downto 0) := (others => '0');
   signal soundbias : std_logic_vector(9 downto 0)  := (others => '0');

   type t_cap is record
      cnt : std_logic_vector(7 downto 0);
      dad : std_logic_vector(26 downto 0);
      len : std_logic_vector(15 downto 0);
   end record;
   type t_caps is array (0 to 1) of t_cap;
   signal cap : t_caps;

   signal tick2 : std_logic := '0';

   type t_fstate is (FSCAN_ADDR, FSCAN_EVAL, FGRANT, FISSUE, FWAITDONE, FGAP);
   signal fstate : t_fstate := FSCAN_ADDR;
   signal fch    : integer range 0 to 15 := 0;
   signal fgapc  : unsigned(2 downto 0) := (others => '0');

   signal mixcnt : unsigned(9 downto 0) := (others => '0');
   signal accl   : signed(31 downto 0) := (others => '0');
   signal accr   : signed(31 downto 0) := (others => '0');

   signal master_gain_latch : std_logic_vector(6 downto 0) := (others => '0');
   signal master_bias_latch : std_logic_vector(9 downto 0) := (others => '0');
   signal master_left_latch : std_logic_vector(15 downto 0) := (others => '0');
   signal master_acc_in     : signed(31 downto 0);
   signal master_gain_in    : signed(8 downto 0);
   signal master_product    : signed(40 downto 0);

   type t_adpcm_steps is array (0 to 88) of integer range 0 to 32767;
   constant ADPCM_STEP_INIT : t_adpcm_steps := (
      16#0007#, 16#0008#, 16#0009#, 16#000A#, 16#000B#, 16#000C#, 16#000D#, 16#000E#,
      16#0010#, 16#0011#, 16#0013#, 16#0015#, 16#0017#, 16#0019#, 16#001C#, 16#001F#,
      16#0022#, 16#0025#, 16#0029#, 16#002D#, 16#0032#, 16#0037#, 16#003C#, 16#0042#,
      16#0049#, 16#0050#, 16#0058#, 16#0061#, 16#006B#, 16#0076#, 16#0082#, 16#008F#,
      16#009D#, 16#00AD#, 16#00BE#, 16#00D1#, 16#00E6#, 16#00FD#, 16#0117#, 16#0133#,
      16#0151#, 16#0173#, 16#0198#, 16#01C1#, 16#01EE#, 16#0220#, 16#0256#, 16#0292#,
      16#02D4#, 16#031C#, 16#036C#, 16#03C3#, 16#0424#, 16#048E#, 16#0502#, 16#0583#,
      16#0610#, 16#06AB#, 16#0756#, 16#0812#, 16#08E0#, 16#09C3#, 16#0ABD#, 16#0BD0#,
      16#0CFF#, 16#0E4C#, 16#0FBA#, 16#114C#, 16#1307#, 16#14EE#, 16#1706#, 16#1954#,
      16#1BDC#, 16#1EA5#, 16#21B6#, 16#2515#, 16#28CA#, 16#2CDF#, 16#315B#, 16#364B#,
      16#3BB9#, 16#41B2#, 16#4844#, 16#4F7E#, 16#5771#, 16#602F#, 16#69CE#, 16#7462#,
      16#7FFF#);

   signal adstep_init   : integer range 0 to 89 := 0;
   signal adstep_wa     : natural range 0 to 127 := 0;
   signal adstep_wd     : std_logic_vector(31 downto 0) := (others => '0');
   signal adstep_we     : std_logic := '0';
   signal adstep_ra     : natural range 0 to 127 := 0;
   signal adstep_dout_v : std_logic_vector(31 downto 0);
   type t_adstep_q is array (0 to 15) of integer range 0 to 32767;
   signal adstep_q    : t_adstep_q := (others => 0);
   signal adstep_rr   : integer range 0 to 15 := 0;
   signal adstep_rr_d : integer range 0 to 15 := 0;

   type t_adpcm_idxd is array (0 to 7) of integer range -1 to 8;
   constant ADPCM_IDXD : t_adpcm_idxd := (-1, -1, -1, -1, 2, 4, 6, 8);

   function spw_minus1(fmt : std_logic_vector(1 downto 0)) return unsigned is
   begin
      case fmt is
         when "00"   => return to_unsigned(3, 3);
         when "01"   => return to_unsigned(1, 3);
         when others => return to_unsigned(7, 3);
      end case;
   end function;

   function vol128(v : std_logic_vector(6 downto 0)) return integer is
      variable n : integer range 0 to 128;
   begin
      n := to_integer(unsigned(v));
      if (n = 127) then n := 128; end if;
      return n;
   end function;

   function volshift(d : std_logic_vector(1 downto 0)) return integer is
   begin
      case d is
         when "00"   => return 4;
         when "01"   => return 3;
         when "10"   => return 2;
         when others => return 0;
      end case;
   end function;

begin

   gadstep : if ADPCM_TABLE_RAM /= 0 generate

      adstep_ra <= chan(adstep_rr).adidx;

      iram_adstep : entity MEM.SyncRamDualByteEnable
      generic map (is_simu => is_simu, is_cyclone5 => '1', ADDR_WIDTH => 7)
      port map
      (
         clk       => clk,
         ce_a      => '1',
         addr_a    => adstep_wa,
         datain_a0 => adstep_wd(7 downto 0),
         datain_a1 => adstep_wd(15 downto 8),
         datain_a2 => adstep_wd(23 downto 16),
         datain_a3 => adstep_wd(31 downto 24),
         dataout_a => open,
         we_a      => adstep_we,
         be_a      => "1111",
         ce_b      => '1',
         addr_b    => adstep_ra,
         datain_b0 => x"00", datain_b1 => x"00",
         datain_b2 => x"00", datain_b3 => x"00",
         dataout_b => adstep_dout_v,
         we_b      => '0',
         be_b      => "0000"
      );

      p_adstep : process (clk)
      begin
         if rising_edge(clk) then
            adstep_we <= '0';
            if (adstep_init < 89) then
               adstep_wa   <= adstep_init;
               adstep_wd   <= std_logic_vector(to_unsigned(ADPCM_STEP_INIT(adstep_init), 32));
               adstep_we   <= '1';
               adstep_init <= adstep_init + 1;
            end if;

            adstep_rr_d <= adstep_rr;
            if (adstep_rr = 15) then adstep_rr <= 0; else adstep_rr <= adstep_rr + 1; end if;
            adstep_q(adstep_rr_d) <= to_integer(unsigned(adstep_dout_v(14 downto 0)));
         end if;
      end process;
   end generate;

   master_acc_in <= accl when mixcnt = to_unsigned(16, mixcnt'length) else accr;
   master_gain_in <= to_signed(vol128(soundcnt(6 downto 0)), master_gain_in'length)
                     when mixcnt = to_unsigned(16, mixcnt'length) else
                     to_signed(vol128(master_gain_latch), master_gain_in'length);
   master_product <= master_acc_in * master_gain_in;

   iram_fptr : entity MEM.SyncRamDualByteEnable
   generic map (is_simu => is_simu, is_cyclone5 => '1', ADDR_WIDTH => 4)
   port map
   (
      clk       => clk,
      ce_a      => '1',
      addr_a    => fptr_a_addr,
      datain_a0 => std_logic_vector(fptr_a_din(7 downto 0)),
      datain_a1 => std_logic_vector(fptr_a_din(15 downto 8)),
      datain_a2 => std_logic_vector(fptr_a_din(23 downto 16)),
      datain_a3 => "0000000" & fptr_a_din(24),
      dataout_a => open,
      we_a      => fptr_a_we,
      be_a      => "1111",
      ce_b      => '1',
      addr_b    => fptr_b_addr,
      datain_b0 => std_logic_vector(fptr_b_din(7 downto 0)),
      datain_b1 => std_logic_vector(fptr_b_din(15 downto 8)),
      datain_b2 => std_logic_vector(fptr_b_din(23 downto 16)),
      datain_b3 => "0000000" & fptr_b_din(24),
      dataout_b => fptr_b_dout,
      we_b      => fptr_b_we,
      be_b      => "1111"
   );

   iram_frem : entity MEM.SyncRamDualByteEnable
   generic map (is_simu => is_simu, is_cyclone5 => '1', ADDR_WIDTH => 4)
   port map
   (
      clk       => clk,
      ce_a      => '1',
      addr_a    => frem_a_addr,
      datain_a0 => std_logic_vector(frem_a_din(7 downto 0)),
      datain_a1 => std_logic_vector(frem_a_din(15 downto 8)),
      datain_a2 => std_logic_vector(frem_a_din(23 downto 16)),
      datain_a3 => x"00",
      dataout_a => open,
      we_a      => frem_a_we,
      be_a      => "1111",
      ce_b      => '1',
      addr_b    => frem_b_addr,
      datain_b0 => std_logic_vector(frem_b_din(7 downto 0)),
      datain_b1 => std_logic_vector(frem_b_din(15 downto 8)),
      datain_b2 => std_logic_vector(frem_b_din(23 downto 16)),
      datain_b3 => x"00",
      dataout_b => frem_b_dout,
      we_b      => frem_b_we,
      be_b      => "1111"
   );

   fptr_b_addr <= fch;
   frem_b_addr <= fch;

   snd_enable <= soundcnt(15);
   gact : for i in 0 to 15 generate
      snd_active(i) <= chan(i).busy;
   end generate;

   process (all)
      variable n : integer;
   begin
      wired_out7  <= (others => '0');
      wired_done7 <= '0';

      if (bus7.Adr(27 downto 9) = "0000000000000000010") then
         wired_done7 <= '1';
         if (bus7.Adr(8) = '0') then
            n := to_integer(unsigned(bus7.Adr(7 downto 4)));
            case bus7.Adr(3 downto 2) is
               when "00" =>
                  wired_out7 <= chan(n).busy & chan(n).format & chan(n).repeatm & chan(n).duty &
                                '0' & chan(n).pan & '0' & chan(n).hold & "0000" &
                                chan(n).voldiv & '0' & chan(n).volmul;
               when others =>
                  wired_out7 <= (others => '0');
            end case;
         else
            case bus7.Adr(4 downto 2) is
               when "000"  => wired_out7 <= x"0000" & soundcnt;
               when "001"  => wired_out7 <= x"00000" & "00" & soundbias;
               when "010"  => wired_out7 <= x"0000" & cap(1).cnt & cap(0).cnt;
               when "100"  => wired_out7 <= "00000" & cap(0).dad;
               when "101"  => wired_out7 <= x"0000" & cap(0).len;
               when "110"  => wired_out7 <= "00000" & cap(1).dad;
               when "111"  => wired_out7 <= x"0000" & cap(1).len;
               when others => wired_out7 <= (others => '0');
            end case;
         end if;
      end if;
   end process;

   process (clk)
      variable n      : integer;
      variable spw    : unsigned(2 downto 0);
      variable v_pos  : unsigned(2 downto 0);
      variable v_sub  : integer range 0 to 7;
      variable v_byte : unsigned(7 downto 0);
      variable v_half : unsigned(15 downto 0);
      variable v_nib  : unsigned(3 downto 0);
      variable v_step : integer range 0 to 32767;
      variable v_diff : integer range 0 to 65535;
      variable v_smp  : integer;
      variable v_i    : integer;
   begin
      if rising_edge(clk) then

         if (reset = '1') then

            soundcnt  <= (others => '0');
            soundbias <= (others => '0');
            for i in 0 to 15 loop
               chan(i).busy     <= '0';
               chan(i).volmul   <= (others => '0');
               chan(i).voldiv   <= (others => '0');
               chan(i).hold     <= '0';
               chan(i).pan      <= (others => '0');
               chan(i).duty     <= (others => '0');
               chan(i).repeatm  <= (others => '0');
               chan(i).format   <= (others => '0');
               chan(i).sad      <= (others => '0');
               chan(i).tmr      <= (others => '0');
               chan(i).pnt      <= (others => '0');
               chan(i).len      <= (others => '0');
               chan(i).timer    <= (others => '0');
               chan(i).remwords <= (others => '0');
               chan(i).subpos   <= (others => '0');
               chan(i).startdel <= (others => '0');
               chan(i).curw     <= (others => '0');
               chan(i).nxtw     <= (others => '0');
               chan(i).curv     <= '0';
               chan(i).nxtv     <= '0';
               chan(i).adhdr    <= '0';
               chan(i).adval    <= (others => '0');
               chan(i).adidx    <= 0;
               chan(i).adval_l  <= (others => '0');
               chan(i).adidx_l  <= 0;
               chan(i).noise    <= (others => '0');
               chan(i).psgpos   <= (others => '0');
               chan(i).cursmp   <= (others => '0');
            end loop;
            for i in 0 to 1 loop
               cap(i).cnt <= (others => '0');
               cap(i).dad <= (others => '0');
               cap(i).len <= (others => '0');
            end loop;
            tick2       <= '0';
            fstate      <= FSCAN_ADDR;
            fch         <= 0;
            snd_bus_req <= '0';
            snd_bus_own <= '0';
            mb_ena      <= '0';
            fptr_a_we   <= '0';
            frem_a_we   <= '0';
            fptr_b_we   <= '0';
            frem_b_we   <= '0';

         elsif (ce = '1') then

            tick2     <= not tick2;
            mb_ena    <= '0';
            fptr_a_we <= '0';
            frem_a_we <= '0';
            fptr_b_we <= '0';
            frem_b_we <= '0';

            if (bus7.ena = '1' and bus7.rnw = '0' and
                bus7.Adr(27 downto 9) = "0000000000000000010") then

               if (bus7.Adr(8) = '0') then
                  n := to_integer(unsigned(bus7.Adr(7 downto 4)));
                  case bus7.Adr(3 downto 2) is

                     when "00" =>
                        if (bus7.bEna(0) = '1') then chan(n).volmul <= bus7.Din(6 downto 0); end if;
                        if (bus7.bEna(1) = '1') then
                           chan(n).voldiv <= bus7.Din(9 downto 8);
                           chan(n).hold   <= bus7.Din(15);
                        end if;
                        if (bus7.bEna(2) = '1') then chan(n).pan <= bus7.Din(22 downto 16); end if;
                        if (bus7.bEna(3) = '1') then
                           chan(n).duty    <= bus7.Din(26 downto 24);
                           chan(n).repeatm <= bus7.Din(28 downto 27);
                           chan(n).format  <= bus7.Din(30 downto 29);
                           if (bus7.Din(31) = '1' and chan(n).busy = '0') then
                              chan(n).busy  <= '1';
                              chan(n).timer <= '0' & unsigned(chan(n).tmr);
                              chan(n).remwords <= resize(unsigned(chan(n).pnt), 24) +
                                                  resize(unsigned(chan(n).len), 24);
                              chan(n).subpos <= (others => '0');
                              chan(n).curv <= '0';
                              chan(n).nxtv <= '0';
                              fptr_a_addr <= n;
                              fptr_a_din  <= unsigned(chan(n).sad(26 downto 2));
                              fptr_a_we   <= '1';
                              frem_a_addr <= n;
                              frem_a_din  <= resize(unsigned(chan(n).pnt), 24) +
                                             resize(unsigned(chan(n).len), 24);
                              frem_a_we   <= '1';
                              if (bus7.Din(30 downto 29) = "10") then
                                 chan(n).adhdr <= '1';
                              else
                                 chan(n).adhdr <= '0';
                              end if;
                              if (bus7.Din(30 downto 29) = "11") then
                                 chan(n).startdel <= "00";
                              else
                                 chan(n).startdel <= "10";
                              end if;
                              chan(n).noise  <= x"7FFF";
                              chan(n).psgpos <= "111";
                              chan(n).cursmp <= (others => '0');
                           elsif (bus7.Din(31) = '0') then
                              chan(n).busy <= '0';
                           end if;
                        end if;

                     when "01" =>
                        chan(n).sad <= bus7.Din(26 downto 0);

                     when "10" =>
                        if (bus7.bEna(0) = '1') then chan(n).tmr(7 downto 0)  <= bus7.Din(7 downto 0); end if;
                        if (bus7.bEna(1) = '1') then chan(n).tmr(15 downto 8) <= bus7.Din(15 downto 8); end if;
                        if (bus7.bEna(2) = '1') then chan(n).pnt(7 downto 0)  <= bus7.Din(23 downto 16); end if;
                        if (bus7.bEna(3) = '1') then chan(n).pnt(15 downto 8) <= bus7.Din(31 downto 24); end if;

                     when others =>
                        chan(n).len <= bus7.Din(21 downto 0);

                  end case;
               else
                  case bus7.Adr(4 downto 2) is
                     when "000" =>
                        if (bus7.bEna(0) = '1') then soundcnt(7 downto 0)  <= bus7.Din(7 downto 0); end if;
                        if (bus7.bEna(1) = '1') then soundcnt(15 downto 8) <= bus7.Din(15 downto 8); end if;
                     when "001" =>
                        if (bus7.bEna(0) = '1') then soundbias(7 downto 0) <= bus7.Din(7 downto 0); end if;
                        if (bus7.bEna(1) = '1') then soundbias(9 downto 8) <= bus7.Din(9 downto 8); end if;
                     when "010" =>
                        if (bus7.bEna(0) = '1') then cap(0).cnt <= bus7.Din(7 downto 0); end if;
                        if (bus7.bEna(1) = '1') then cap(1).cnt <= bus7.Din(15 downto 8); end if;
                     when "100" => cap(0).dad <= bus7.Din(26 downto 0);
                     when "101" =>
                        if (bus7.bEna(0) = '1') then cap(0).len(7 downto 0)  <= bus7.Din(7 downto 0); end if;
                        if (bus7.bEna(1) = '1') then cap(0).len(15 downto 8) <= bus7.Din(15 downto 8); end if;
                     when "110" => cap(1).dad <= bus7.Din(26 downto 0);
                     when "111" =>
                        if (bus7.bEna(0) = '1') then cap(1).len(7 downto 0)  <= bus7.Din(7 downto 0); end if;
                        if (bus7.bEna(1) = '1') then cap(1).len(15 downto 8) <= bus7.Din(15 downto 8); end if;
                     when others => null;
                  end case;
               end if;
            end if;

            if (tick2 = '1' and soundcnt(15) = '1') then
               for i in 0 to 15 loop
                  if (chan(i).busy = '1') then
                     chan(i).timer <= ('0' & chan(i).timer(15 downto 0)) + 1;
                     if (chan(i).timer(15 downto 0) = x"FFFF") then
                        chan(i).timer <= '0' & unsigned(chan(i).tmr);

                        if (chan(i).startdel /= 0) then
                           chan(i).startdel <= chan(i).startdel - 1;

                        elsif (chan(i).format = "11") then
                           if (i >= 14) then
                              if (chan(i).noise(0) = '1') then
                                 chan(i).noise  <= ('0' & chan(i).noise(15 downto 1)) xor x"6000";
                                 chan(i).cursmp <= to_signed(-16#7FFF#, 16);
                              else
                                 chan(i).noise  <= '0' & chan(i).noise(15 downto 1);
                                 chan(i).cursmp <= to_signed(16#7FFF#, 16);
                              end if;
                           elsif (i >= 8) then
                              v_pos := chan(i).psgpos + 1;
                              chan(i).psgpos <= v_pos;
                              if (chan(i).duty /= "111" and
                                  to_integer(v_pos) + to_integer(unsigned(chan(i).duty)) > 6) then
                                 chan(i).cursmp <= to_signed(16#7FFF#, 16);
                              else
                                 chan(i).cursmp <= to_signed(-16#7FFF#, 16);
                              end if;
                           end if;

                        elsif (chan(i).curv = '1') then
                           v_sub := to_integer(chan(i).subpos);

                           case chan(i).format is
                              when "00" =>
                                 v_byte := resize(shift_right(unsigned(chan(i).curw), v_sub*8), 8);
                                 chan(i).cursmp <= signed(std_logic_vector(v_byte) & x"00");
                              when "01" =>
                                 v_half := resize(shift_right(unsigned(chan(i).curw), v_sub*16), 16);
                                 chan(i).cursmp <= signed(v_half);
                              when others =>
                                 if (chan(i).adhdr = '1') then
                                    if (v_sub = 0) then
                                       chan(i).adval <= signed(chan(i).curw(15 downto 0));
                                       v_i := to_integer(unsigned(chan(i).curw(22 downto 16)));
                                       if (v_i > 88) then v_i := 88; end if;
                                       chan(i).adidx   <= v_i;
                                       chan(i).adval_l <= signed(chan(i).curw(15 downto 0));
                                       chan(i).adidx_l <= v_i;
                                    end if;
                                 else
                                    v_nib  := resize(shift_right(unsigned(chan(i).curw), v_sub*4), 4);
                                    if (ADPCM_TABLE_RAM /= 0) then
                                       v_step := adstep_q(i);
                                    else
                                       v_step := ADPCM_STEP_INIT(chan(i).adidx);
                                    end if;
                                    v_diff := v_step / 8;
                                    if (v_nib(0) = '1') then v_diff := v_diff + v_step/4; end if;
                                    if (v_nib(1) = '1') then v_diff := v_diff + v_step/2; end if;
                                    if (v_nib(2) = '1') then v_diff := v_diff + v_step;   end if;
                                    v_smp := to_integer(chan(i).adval);
                                    if (v_nib(3) = '1') then
                                       v_smp := v_smp - v_diff;
                                       if (v_smp < -16#7FFF#) then v_smp := -16#7FFF#; end if;
                                    else
                                       v_smp := v_smp + v_diff;
                                       if (v_smp > 16#7FFF#) then v_smp := 16#7FFF#; end if;
                                    end if;
                                    v_i := chan(i).adidx + ADPCM_IDXD(to_integer(v_nib(2 downto 0)));
                                    if (v_i < 0) then v_i := 0; end if;
                                    if (v_i > 88) then v_i := 88; end if;
                                    chan(i).adval  <= to_signed(v_smp, 16);
                                    chan(i).adidx  <= v_i;
                                    chan(i).cursmp <= to_signed(v_smp, 16);
                                    if (v_sub = 0 and
                                        chan(i).remwords = resize(unsigned(chan(i).len), 24)) then
                                       chan(i).adval_l <= to_signed(v_smp, 16);
                                       chan(i).adidx_l <= v_i;
                                    end if;
                                 end if;
                           end case;

                           spw := spw_minus1(chan(i).format);
                           if (chan(i).subpos = spw) then
                              chan(i).subpos <= (others => '0');
                              chan(i).curv   <= '0';
                              chan(i).adhdr  <= '0';
                              if (chan(i).remwords <= 1) then
                                 if (chan(i).repeatm = "01") then
                                    chan(i).remwords <= resize(unsigned(chan(i).len), 24);
                                    if (chan(i).format = "10") then
                                       chan(i).adval    <= chan(i).adval_l;
                                       chan(i).adidx    <= chan(i).adidx_l;
                                       chan(i).cursmp   <= chan(i).adval_l;
                                       chan(i).startdel <= "01";
                                       chan(i).subpos   <= to_unsigned(1, 3);
                                    end if;
                                 else
                                    chan(i).busy   <= '0';
                                    chan(i).cursmp <= (others => '0');
                                 end if;
                              else
                                 chan(i).remwords <= chan(i).remwords - 1;
                              end if;
                           else
                              chan(i).subpos <= chan(i).subpos + 1;
                           end if;
                        end if;
                     end if;
                  end if;
               end loop;
            end if;

            for i in 0 to 15 loop
               if (chan(i).busy = '1' and chan(i).curv = '0' and chan(i).nxtv = '1') then
                  chan(i).curw <= chan(i).nxtw;
                  chan(i).curv <= '1';
                  chan(i).nxtv <= '0';
               end if;
            end loop;

            case fstate is

               when FSCAN_ADDR =>
                  fstate <= FSCAN_EVAL;

               when FSCAN_EVAL =>
                  if (chan(fch).busy = '1' and chan(fch).format /= "11" and
                      unsigned(frem_b_dout(23 downto 0)) /= 0 and chan(fch).nxtv = '0') then
                     snd_bus_req <= '1';
                     fstate      <= FGRANT;
                  elsif (fch = 15) then
                     fch    <= 0;
                     fstate <= FSCAN_ADDR;
                  else
                     fch    <= fch + 1;
                     fstate <= FSCAN_ADDR;
                  end if;

               when FGRANT =>
                  if (snd_bus_ok = '1') then
                     snd_bus_own <= '1';
                     fstate      <= FISSUE;
                  end if;

               when FISSUE =>
                  mb_ena <= '1';
                  mb_adr <= x"0" & '0' & fptr_b_dout(24 downto 0) & "00";
                  fstate <= FWAITDONE;

               when FWAITDONE =>
                  if (mb_done = '1') then
                     chan(fch).nxtw <= mb_din;
                     chan(fch).nxtv <= '1';
                     if (unsigned(frem_b_dout(23 downto 0)) = 1) then
                        if (chan(fch).repeatm = "01") then
                           fptr_b_din <= resize(unsigned(chan(fch).sad(26 downto 2)), 25) +
                                         resize(unsigned(chan(fch).pnt), 25);
                           fptr_b_we  <= '1';
                           frem_b_din <= resize(unsigned(chan(fch).len), 24);
                           frem_b_we  <= '1';
                        else
                           frem_b_din <= (others => '0');
                           frem_b_we  <= '1';
                        end if;
                     else
                        fptr_b_din <= unsigned(fptr_b_dout(24 downto 0)) + 1;
                        fptr_b_we  <= '1';
                        frem_b_din <= unsigned(frem_b_dout(23 downto 0)) - 1;
                        frem_b_we  <= '1';
                     end if;
                     snd_bus_req <= '0';
                     snd_bus_own <= '0';
                     fgapc       <= "111";
                     fstate      <= FGAP;
                  end if;

               when FGAP =>
                  if (fgapc = 0) then
                     fstate <= FSCAN_ADDR;
                  else
                     fgapc <= fgapc - 1;
                  end if;

            end case;

         end if;

      end if;
   end process;

   process (clk)
      variable v_ch  : integer range 0 to 15;
      variable v_pan : integer range 0 to 128;
      variable v_a   : signed(20 downto 0);
      variable v_b   : signed(29 downto 0);
      variable v_p   : signed(38 downto 0);
      variable v_o   : integer;
   begin
      if rising_edge(clk) then
         sample_valid <= '0';
         if (reset = '1') then
            mixcnt   <= (others => '0');
            accl     <= (others => '0');
            accr     <= (others => '0');
            master_gain_latch <= (others => '0');
            master_bias_latch <= (others => '0');
            master_left_latch <= (others => '0');
            sample_l <= (others => '0');
            sample_r <= (others => '0');
         elsif (ce = '1') then
            mixcnt <= mixcnt + 1;

            if (to_integer(mixcnt) < 16) then
               v_ch := to_integer(mixcnt(3 downto 0));
               if (soundcnt(15) = '1' and chan(v_ch).busy = '1' and not
                   ((v_ch = 1 and soundcnt(12) = '1') or
                    (v_ch = 3 and soundcnt(13) = '1'))) then
                  v_a   := shift_left(resize(chan(v_ch).cursmp, 21),
                                      volshift(chan(v_ch).voldiv));
                  v_b   := resize(v_a * to_signed(vol128(chan(v_ch).volmul), 9), 30);
                  v_pan := vol128(chan(v_ch).pan);
                  v_p   := v_b * to_signed(128 - v_pan, 9);
                  accl  <= accl + resize(shift_right(v_p, 10), 32);
                  v_p   := v_b * to_signed(v_pan, 9);
                  accr  <= accr + resize(shift_right(v_p, 10), 32);
               end if;

            elsif (to_integer(mixcnt) = 16) then
               v_o := to_integer(shift_right(master_product, 15)) +
                      to_integer(unsigned(soundbias)) * 64 - 32768;
               if (v_o < -32768) then v_o := -32768; end if;
               if (v_o >  32767) then v_o :=  32767; end if;
               master_left_latch <= std_logic_vector(to_signed(v_o, 16));
               master_gain_latch <= soundcnt(6 downto 0);
               master_bias_latch <= soundbias;

            elsif (to_integer(mixcnt) = 17) then
               v_o := to_integer(shift_right(master_product, 15)) +
                      to_integer(unsigned(master_bias_latch)) * 64 - 32768;
               if (v_o < -32768) then v_o := -32768; end if;
               if (v_o >  32767) then v_o :=  32767; end if;
               sample_l <= master_left_latch;
               sample_r <= std_logic_vector(to_signed(v_o, 16));
               sample_valid <= '1';

            elsif (mixcnt = to_unsigned(1023, 10)) then
               accl <= (others => '0');
               accr <= (others => '0');
            end if;
         end if;
      end if;
   end process;

end architecture;
