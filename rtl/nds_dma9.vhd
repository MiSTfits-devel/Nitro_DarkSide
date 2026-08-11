-- SPDX-License-Identifier: GPL-2.0-or-later
-- NDS ARM9 DMA (M6): 4 channels, registers 0x040000B0-0x040000EF incl. the
-- FILL words. Semantics per DualSOUP dma.c (Jaklyy's hardware research) and
-- GBATEK:
--
--   * CNT: [20:0] word count (0 -> 0x200000), [22:21] dst ctrl (0 inc,
--     1 dec, 2 fixed, 3 inc-reload), [24:23] src ctrl (3 behaves as inc +
--     reload, DualSOUP), [25] repeat, [26] 32-bit, [29:27] start timing,
--     [30] IRQ, [31] enable. SAD/DAD/CNT all read back (NDS, unlike GBA).
--   * enable rising edge latches src/dst; the word count is latched lazily
--     when the remaining count is 0 (so repeat reloads it per trigger, and
--     ctrl-3 re-latches the address then too) - DualSOUP DMA_Run.
--   * start timings implemented: 0 immediate, 1 vblank, 2 hblank (visible
--     lines only - the gpu2d cadence pulses), 5 card (one pulse per ready
--     data word from nds_card; games arm count=1 + repeat). GX FIFO (7)
--     comes with the 3D subsystem; 3/4/6 are exotic (DualSOUP stubs them).
--   * repeat re-arms every trigger for non-immediate modes; immediate
--     transfers clear enable regardless. IRQ per completed transfer.
--   * transfers go through the ARM9 membus with the CPU paused (dma_on +
--     CPU_bus_idle grant) and the TCM windows bypassed (DMA cannot see
--     ITCM/DTCM). Addresses are masked to 0x0FFFFFFF and hold the size
--     alignment; 16-bit reads take the rotated lane, writes replicate.
--
-- Timing is functional-only for now: one read + one write handshake per
-- unit, no cycle accuracy. The M9 pacing target is the DualSOUP dma.txt
-- measurement: NR+NW first pair, then SR/SW pairs, a 1-cycle stall after
-- a fast first read, and main-RAM read prefetch making later SRs
-- single-cycle. The FSM shape below (first-pair / steady-pair) is chosen
-- so those timings can be dialed in without restructuring.

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

      -- trigger pulses (gpu2d cadence: vblank start / visible-line hblank;
      -- card: one pulse per ready data word from nds_card)
      trig_vblank  : in  std_logic;
      trig_hblank  : in  std_logic;
      trig_card    : in  std_logic;

      -- membus grant: dma_on pauses the CPU, the bus is ours once idle
      cpu_bus_idle : in  std_logic;
      dma_on       : out std_logic := '0';
      dma_bus_on   : out std_logic := '0';

      -- ARM9 membus access port (muxed onto the CPU port in nds_top)
      mb_ena       : out std_logic := '0';
      mb_rnw       : out std_logic := '1';
      mb_adr       : out std_logic_vector(31 downto 0) := (others => '0');
      mb_acc       : out std_logic_vector(1 downto 0) := ACCESS_32BIT;
      mb_lowbits   : out std_logic_vector(1 downto 0) := "00";
      mb_dout      : out std_logic_vector(31 downto 0) := (others => '0');
      mb_din       : in  std_logic_vector(31 downto 0);
      mb_done      : in  std_logic;

      -- clk1x fast lane straight into the IO fabric.
      --
      -- The island bridge costs 5 clk1x cycles on every IO access - request CDC
      -- out (clk1x -> clk2x), the clk1x IO fabric, then the completion CDC back
      -- through cdc_io_cpl and cpu9_done_1x - and nds_dma9 is already a clk1x
      -- unit, so it can address the peripherals directly and skip all of it.
      -- Measured 5 -> 1 cycle per IO access, and IO is where a DMA reads its
      -- source whenever software points SAD at a register (the NITRO Tester's
      -- [04-02] uses TM3CNT_L; sound and card streaming do the same).
      --
      -- Needs no arbitration with the island: dma_on pauses the CPU, the grant
      -- waits for cpu_bus_idle - which only returns to '1' on gb_bus_done, so the
      -- CPU's last access has completed - and nds_top hands the fabric over for
      -- exactly as long as dma_bus_on is held.
      io_fast_ena  : out std_logic := '0';
      io_fast_rnw  : out std_logic := '1';
      io_fast_adr  : out std_logic_vector(27 downto 0) := (others => '0');
      io_fast_acc  : out std_logic_vector(1 downto 0) := ACCESS_32BIT;
      io_fast_be   : out std_logic_vector(3 downto 0) := "1111";
      io_fast_dout : out std_logic_vector(31 downto 0) := (others => '0');
      io_fast_din  : in  std_logic_vector(31 downto 0);

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
      -- latched transfer state
      cur_src  : unsigned(27 downto 0);
      cur_dst  : unsigned(27 downto 0);
      remain   : unsigned(21 downto 0);   -- 0x200000 max
      pend     : std_logic;
   end record;
   constant CHAN_INIT : t_chan := ((others => '0'), (others => '0'), (others => '0'),
                                   "00", "00", '0', '0', "000", '0', '0',
                                   (others => '0'), (others => '0'), (others => '0'), '0');
   type t_chans is array (0 to 3) of t_chan;
   signal ch : t_chans := (others => CHAN_INIT);

   type t_fill is array (0 to 3) of std_logic_vector(31 downto 0);
   signal fill : t_fill := (others => (others => '0'));

   -- RD_IOW / WR_IOW are the fast-lane counterparts of RD_WAIT / WR_WAIT: the
   -- peripherals see io_fast_ena during that single cycle and answer
   -- combinationally, so there is nothing to wait for beyond it.
   type t_state is (IDLE, GRANT, LATCH, RD, RD_WAIT, RD_IOW, WR, WR_WAIT, WR_IOW, COMPLETE);
   signal state  : t_state := IDLE;
   signal active : integer range 0 to 3 := 0;

   signal rdval  : std_logic_vector(31 downto 0) := (others => '0');

   -- one cycle per retired unit, for the census below
   signal unit_ret : std_logic := '0';

   -- register write/read decode
   signal regsel_ch  : integer range 0 to 3;
   signal regsel_reg : integer range 0 to 2;
   signal reg_hit    : std_logic;
   signal fill_hit   : std_logic;

   -- NDS IO is 0x04000000-0x04FFFFFF, and DMA addresses are already masked to 28
   -- bits, so the region is exactly the top nibble.
   function is_io(a : unsigned(27 downto 0)) return boolean is
   begin
      return a(27 downto 24) = 4;
   end function;

   -- byte enables for an access of this size at this address, matching the
   -- decode nds_membus9 applies on the slow path
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
         when others => return step;      -- 0 and 3: increment
      end case;
   end function;

begin

   -- ================= per-access cost census (sim only) =================
   -- [04-02] DMA PRIORITY requires a 16-bit unit to cost 2 clk1x cycles and this
   -- FSM costs 20 (11 even into palette, the lowest-latency target in the core).
   -- Splitting that between the two waits and the FSM's own states is what says
   -- whether the read path or the write path is the thing to restructure. Prints
   -- once per completed transfer, so it is quiet on ordinary DMA.
   -- synthesis translate_off
   p_census : process (clk)
      variable rw, ww, un, cy : integer := 0;
   begin
      if rising_edge(clk) then
         if (state /= IDLE)     then cy := cy + 1; end if;
         if (state = RD_WAIT or state = RD_IOW) then rw := rw + 1; end if;
         if (state = WR_WAIT or state = WR_IOW) then ww := ww + 1; end if;
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

   -- ================= register decode =================
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
            -- Four channels, three words each. An arithmetic /3 and mod 3
            -- here makes Quartus build two full combinational dividers for a
            -- twelve-value MMIO decode; spell out the exact fixed mapping.
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

   -- ================= main FSM + register writes =================
   process (clk)
      variable v_ena   : std_logic;
      variable v_pick  : integer range 0 to 3;
      variable v_got   : std_logic;
      variable v_inc   : integer;
      variable lane16  : std_logic_vector(15 downto 0);

      -- End of a unit: step both pointers, drop the count and either start the
      -- next read or finish. This used to be its own NEXTUNIT state, which cost a
      -- whole cycle per unit for work that fits in the cycle the write retires.
      procedure retire_unit is
         variable inc : integer;
      begin
         unit_ret <= '1';
         inc := inc_of(ch(active).srcctl, ch(active).word32);
         ch(active).cur_src <= ch(active).cur_src + inc;  -- wraps mod 2^28 (address mask)
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
         mb_ena      <= '0';
         io_fast_ena <= '0';
         unit_ret    <= '0';

         if (reset = '1') then
            ch     <= (others => CHAN_INIT);
            state  <= IDLE;
            dma_on <= '0';
            dma_bus_on <= '0';
         else

            -- -------- CPU register writes --------
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
                           -- enable rising edge: latch addresses, arm
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

            -- -------- triggers --------
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

            -- -------- transfer FSM --------
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
                  -- lazy count latch (DualSOUP): remaining 0 means reload;
                  -- ctrl 3 re-latches its address too
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
                     io_fast_ena <= '1';
                     io_fast_rnw <= '1';
                     -- the IO fabric decodes with the region nibble stripped
                     -- (nds_membus9 drives x"0" & adr(23:2) & "00", and this
                     -- module's own ADR_BASE is x"00000B0", not x"40000B0")
                     io_fast_adr <= x"0" & std_logic_vector(ch(active).cur_src(23 downto 2)) & "00";
                     io_fast_be  <= be_of(ch(active).cur_src, ch(active).word32);
                     if (ch(active).word32 = '1') then
                        io_fast_acc <= ACCESS_32BIT;
                     else
                        io_fast_acc <= ACCESS_16BIT;
                     end if;
                     state <= RD_IOW;
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
                     rdval <= mb_din;   -- membus rotates: low half = the halfword
                     state <= WR;
                  end if;

               when RD_IOW =>
                  -- io_fast_ena is high across this cycle and the peripherals'
                  -- wired_out is combinational from the address, so the word is
                  -- valid now. Rotate it here, since the slow path's rotation
                  -- lives in nds_membus9 and this one bypasses it: the rest of the
                  -- FSM expects the halfword in the low half.
                  if (ch(active).word32 = '1') then
                     rdval <= io_fast_din;
                  elsif (ch(active).cur_src(1) = '1') then
                     rdval <= x"0000" & io_fast_din(31 downto 16);
                  else
                     rdval <= x"0000" & io_fast_din(15 downto 0);
                  end if;
                  state <= WR;

               when WR =>
                  if (is_io(ch(active).cur_dst)) then
                     io_fast_ena <= '1';
                     io_fast_rnw <= '0';
                     io_fast_adr <= x"0" & std_logic_vector(ch(active).cur_dst(23 downto 2)) & "00";
                     io_fast_be  <= be_of(ch(active).cur_dst, ch(active).word32);
                     if (ch(active).word32 = '1') then
                        io_fast_acc  <= ACCESS_32BIT;
                        io_fast_dout <= rdval;
                     else
                        io_fast_acc  <= ACCESS_16BIT;
                        lane16       := rdval(15 downto 0);
                        io_fast_dout <= lane16 & lane16;   -- bEna picks the lane
                     end if;
                     state <= WR_IOW;
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

               when WR_IOW =>
                  -- the peripheral latched the write on this cycle's edge
                  retire_unit;

               when COMPLETE =>
                  -- repeat keeps the channel armed for the next trigger;
                  -- immediate transfers always disable (DualSOUP)
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
