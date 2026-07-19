-- SPDX-License-Identifier: GPL-2.0-or-later
-- NDS game-card slot (M8 part 1): AUXSPICNT/ROMCTRL register block, retail
-- read commands served from the staged card image, transfer-complete IRQ and
-- the per-word card DMA trigger. Behavior and timing follow melonDS 1.1
-- (NDSCart.cpp, the M7-established oracle); DualSOUP's measured pacing
-- refines this later if the frame diff demands it.
--
--   0x040001A0  AUXSPICNT  [15] slot enable, [14] transfer-IRQ enable,
--                          [13] SPI mode (blocks ROM transfers when set)
--   0x040001A2  AUXSPIDATA (backup SPI: 8 KB EEPROM state machine, melonDS
--               SRAMWrite_EEPROM semantics - RDSR/WRSR/READ/WRITE/WREN/WRDI,
--               9F answers FF; fresh save = FF fill; size/type per-cart and
--               save persistence come later with HPS integration)
--   0x040001A4  ROMCTRL    [12:0] gap1, [21:16] gap2, [23] word ready (RO),
--                          [26:24] block size, [27] clock divider,
--                          [30] write dir, [31] busy (write 1 starts)
--   0x040001A8+ 8 command bytes (byte-writable, big-endian order on the bus)
--   0x040001B0+ KEY2 seeds (write-only stubs)
--   0x04100010  read data port (pop: advances the transfer)
--
-- Commands implemented (direct boot leaves the cart in encrypted-data mode,
-- CmdEncMode=2, so only these are ever issued): B7 block read (contiguous
-- from the image; reads below 0x8000 redirect to 0x8000+(addr&0x1FF) like
-- real carts protect the secure area), B8 chip ID. Anything else returns FF.
-- Chip ID is Macronix NTR MROM, size byte from the image capacity would be
-- header-derived; 3FC2 covers the 64 MB retail class (melonDS formula).
--
-- Timing (33.514 MHz clk1x = melonDS system-cycle rate, applied 1:1):
-- 8-bit parallel bus, xfercycle = 8 cycles/byte (ROMCTRL[27]) or 5;
-- command = 8 bytes (+gap1, +gap2 when data follows, only while WR clear);
-- first word ready xfercycle*(cmd+4) after start, successive words
-- xfercycle*4 (+gap2 at each 512-byte boundary) after each pop.
--
-- Slot ownership: EXMEMCNT[11] (card7 input). The non-owner reads the whole
-- block as zero and its writes are dropped; the DMA trigger and IRQ pulse go
-- to the owner (ARM7 trigger port exists for the future dma7 - unconnected
-- until then, ARM9 owns the slot in everything direct-booted so far).

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity nds_card is
   port
   (
      clk          : in  std_logic;
      ce           : in  std_logic;
      reset        : in  std_logic;

      card7        : in  std_logic;    -- EXMEMCNT[11]: '1' = ARM7 owns the slot

      bus9         : in  proc_bus_gb_type;
      wired_out9   : out std_logic_vector(31 downto 0);
      wired_done9  : out std_logic;

      bus7         : in  proc_bus_gb_type;
      wired_out7   : out std_logic_vector(31 downto 0);
      wired_done7  : out std_logic;

      irq9_xfer    : out std_logic := '0';   -- IRQ bit 19, one-cycle pulses
      irq7_xfer    : out std_logic := '0';
      dma9_card    : out std_logic := '0';   -- DMA start-mode 5 word-ready pulses
      dma7_card    : out std_logic := '0';

      -- staged card image read port (shared with nds_loader, muxed in nds_top)
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

   constant CHIPID      : std_logic_vector(31 downto 0) := x"00003FC2";

   signal spicnt     : std_logic_vector(15 downto 0) := (others => '0');
   signal romctrl    : std_logic_vector(31 downto 0) := (others => '0'); -- stored bits, 23/31 live below
   signal cmdbytes   : std_logic_vector(63 downto 0) := (others => '0'); -- cmd[0] in 63:56 (bus byte order)

   signal busy       : std_logic := '0';                 -- ROMCTRL[31]
   signal word_ready : std_logic := '0';                 -- ROMCTRL[23]
   signal romdata    : std_logic_vector(31 downto 0) := (others => '0');

   type tstate is
   (
      IDLE,
      CMDDELAY,    -- command bytes + gaps on the cart bus
      FETCH,       -- image word read in flight
      DATAREADY,   -- word_ready set, waiting for the data-port pop
      WORDDELAY,   -- inter-word cart-bus pacing
      FINISH       -- clear busy, raise IRQ
   );
   signal state      : tstate := IDLE;

   signal xferlen    : unsigned(12 downto 0) := (others => '0'); -- words, max 4096
   signal xferpos    : unsigned(12 downto 0) := (others => '0');
   signal delay_cnt  : unsigned(19 downto 0) := (others => '0');
   signal cmd_b7     : std_logic := '0';
   signal cmd_b8     : std_logic := '0';
   signal b7_addr    : unsigned(31 downto 0) := (others => '0'); -- byte address of next word

   signal romctrl_rd : std_logic_vector(31 downto 0);
   signal own9, own7 : std_logic;

   -- registered request flags (bus pulses arrive with ce)
   signal pop_req    : std_logic;

   -- ================= AUXSPI backup (8 KB EEPROM, Kirby-class) =================
   -- melonDS CartRetail::SRAMWrite_EEPROM semantics; sized/typed per cart
   -- later via generics + HPS save loading. Fresh save = 0xFF fill.
   type t_sram is array (0 to 8191) of std_logic_vector(7 downto 0);
   signal sram        : t_sram := (others => (others => '1'));
   -- dedicated M10K access ports (the array must not be touched anywhere
   -- else, or Quartus falls back to registers): registered read at the
   -- current sram_addr - stable for the whole >= 64-cycle SPI busy window
   -- before any use, so sram_q always equals the old asynchronous read.
   -- Writes are staged one cycle (also invisible behind the busy window).
   signal sram_q      : std_logic_vector(7 downto 0);
   signal sram_we_r   : std_logic := '0';
   signal sram_wa_r   : integer range 0 to 8191 := 0;
   signal sram_wd_r   : std_logic_vector(7 downto 0) := (others => '0');
   signal spi_data    : std_logic_vector(7 downto 0) := (others => '0');  -- AUXSPIDATA readback
   signal spi_hold    : std_logic := '0';
   signal spi_pos     : unsigned(15 downto 0) := (others => '0');
   signal spi_busy    : unsigned(9 downto 0) := (others => '0');          -- busy countdown, bit7 readback
   signal sram_cmd    : std_logic_vector(7 downto 0) := (others => '0');
   signal sram_addr   : unsigned(15 downto 0) := (others => '0');
   signal sram_status : std_logic_vector(7 downto 0) := (others => '0');  -- bit1 = WEL
   signal auxspi_rd   : std_logic_vector(31 downto 0);
   signal spi_busy_bit : std_logic;

begin

   own9 <= not card7;
   own7 <= card7;

   -- ================= combinational read data =================
   romctrl_rd <= busy & romctrl(30 downto 24) & word_ready & romctrl(22 downto 0);

   -- AUXSPICNT with the live SPI-busy bit, AUXSPIDATA in the upper half
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

   -- ================= backup store (M10K) =================
   -- Canonical simple-dual-port template (write, then registered read) so
   -- Quartus infers block RAM; the 0xFF initial fill (fresh save) is carried
   -- by the signal initial value. Write and read never target the same
   -- address on the same edge (sram_addr has always advanced past sram_wa_r).
   process (clk)
   begin
      if rising_edge(clk) then
         if (sram_we_r = '1') then
            sram(sram_wa_r) <= sram_wd_r;
         end if;
         sram_q <= sram(to_integer(sram_addr(12 downto 0)));
      end if;
   end process;

   -- ================= state =================
   process (clk)
      variable wval      : std_logic_vector(31 downto 0);
      variable owner_bus : proc_bus_gb_type;
      variable v_start   : std_logic;
      variable v_size    : unsigned(2 downto 0);
      variable v_len     : unsigned(12 downto 0);
      variable v_cmddel  : unsigned(19 downto 0);
      variable v_xcyc    : unsigned(3 downto 0);
      variable v_eff     : unsigned(31 downto 0);
      variable v_pos     : unsigned(12 downto 0);
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

            if (card7 = '1') then
               owner_bus := bus7;
            else
               owner_bus := bus9;
            end if;

            -- -------- register writes (owner only) --------
            v_start := '0';
            if (owner_bus.ena = '1' and owner_bus.rnw = '0') then

               if (owner_bus.Adr = ADR_AUXSPI) then
                  if (owner_bus.bEna(0) = '1') then
                     spicnt(7 downto 0)  <= owner_bus.Din(7 downto 0);
                  end if;
                  if (owner_bus.bEna(1) = '1') then
                     spicnt(15 downto 8) <= owner_bus.Din(15 downto 8);
                     if (owner_bus.Din(15) = '0') then
                        spi_hold <= '0';   -- disabling the slot drops the CS hold
                     end if;
                  end if;
                  -- AUXSPIDATA byte write: one SPI transfer to the backup chip
                  if (owner_bus.bEna(2) = '1' and spicnt(15) = '1' and spicnt(13) = '1' and
                      spi_busy = 0) then
                     v_spival := owner_bus.Din(23 downto 16);
                     -- pos/last bookkeeping (melonDS WriteSPIData)
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
                     -- 8 bits at the AUXSPICNT baud rate (4 MHz >> baud)
                     spi_busy <= shift_left(to_unsigned(64, 10),
                                            to_integer(unsigned(spicnt(1 downto 0))));

                     -- EEPROM state machine (melonDS SRAMWrite_EEPROM)
                     spi_data <= (others => '0');
                     if (v_spipos = 0) then
                        if (v_spival = x"04") then
                           sram_status(1) <= '0';                -- write disable
                        elsif (v_spival = x"06") then
                           sram_status(1) <= '1';                -- write enable
                        else
                           sram_cmd  <= v_spival;
                           sram_addr <= (others => '0');
                           spi_data  <= (others => '1');
                        end if;
                     else
                        case sram_cmd is
                           when x"01" =>                          -- write status
                              if (v_spipos = 1) then
                                 sram_status <= (sram_status and x"01") or (v_spival and x"0C");
                              end if;
                           when x"05" =>                          -- read status
                              spi_data <= sram_status;
                           when x"02" =>                          -- write
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
                           when x"03" =>                          -- read
                              if (v_spipos <= 2) then
                                 sram_addr <= sram_addr(7 downto 0) & unsigned(v_spival);
                              else
                                 spi_data  <= sram_q;
                                 sram_addr <= sram_addr + 1;
                              end if;
                           when others =>                         -- incl. 9F JEDEC: EEPROM answers FF
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
                  -- start on writing 1 to bit31 while idle, slot enabled,
                  -- ROM mode (melonDS WriteROMCnt gate set)
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
               -- 0x1B0+ KEY2 seeds: accepted and dropped

            end if;

            -- data-port pop (owner read, read direction only)
            pop_req <= '0';
            if (owner_bus.ena = '1' and owner_bus.rnw = '1' and owner_bus.Adr = ADR_DATA and
                romctrl(30) = '0' and word_ready = '1') then
               pop_req <= '1';
            end if;

            -- -------- transfer start --------
            if (v_start = '1') then
               v_size := unsigned(wval(26 downto 24));
               if (v_size = 7) then
                  v_len := to_unsigned(1, 13);              -- 4 bytes
               elsif (v_size = 0) then
                  v_len := (others => '0');
               else
                  v_len := shift_left(to_unsigned(64, 13), to_integer(v_size)); -- 0x100<<n bytes = 64<<n words
               end if;
               xferlen <= v_len;
               xferpos <= (others => '0');
               busy    <= '1';
               word_ready <= '0';

               cmd_b7 <= '0';
               cmd_b8 <= '0';
               if (cmdbytes(63 downto 56) = x"B7") then
                  cmd_b7 <= '1';
               elsif (cmdbytes(63 downto 56) = x"B8") then
                  cmd_b8 <= '1';
               end if;
               b7_addr <= unsigned(cmdbytes(55 downto 24));  -- cmd[1..4] big-endian address

               -- synthesis translate_off
               report "CARD: cmd=" & to_hstring(cmdbytes(63 downto 56)) &
                      " addr=" & to_hstring(cmdbytes(55 downto 24)) &
                      " words=" & integer'image(to_integer(v_len));
               -- synthesis translate_on

               -- command time: 8 bytes, + gaps while WR clear, +4 data cycles
               -- before the first word; all times xfercycle per unit
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
               delay_cnt <= resize(v_cmddel * v_xcyc, 20);
               state     <= CMDDELAY;
            end if;

            -- -------- transfer FSM --------
            case state is

               when IDLE => null;

               when CMDDELAY =>
                  if (delay_cnt /= 0) then
                     delay_cnt <= delay_cnt - 1;
                  elsif (xferlen = 0) then
                     state <= FINISH;
                  else
                     if (cmd_b7 = '1') then
                        -- secure-area redirect, then fetch from the image
                        v_eff := b7_addr;
                        if (v_eff < 16#8000#) then
                           v_eff := to_unsigned(16#8000#, 32) + (v_eff and to_unsigned(16#1FF#, 32));
                        end if;
                        card_ena  <= '1';
                        card_addr <= std_logic_vector(v_eff(26 downto 2));
                        state     <= FETCH;
                     else
                        if (cmd_b8 = '1') then
                           romdata <= CHIPID;
                        else
                           romdata <= (others => '1');
                        end if;
                        word_ready <= '1';
                        dma9_card  <= own9;
                        dma7_card  <= own7;
                        state      <= DATAREADY;
                     end if;
                  end if;

               when FETCH =>
                  if (card_done = '1') then
                     romdata    <= card_din;
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
                     b7_addr    <= b7_addr + 4;
                     if (v_pos >= xferlen) then
                        state <= FINISH;
                     else
                        -- 4 bus cycles per word, +gap2 at 512-byte boundaries
                        if (romctrl(27) = '1') then v_xcyc := to_unsigned(8, 4); else v_xcyc := to_unsigned(5, 4); end if;
                        v_cmddel := to_unsigned(4, 20);
                        if (romctrl(30) = '0' and v_pos(6 downto 0) = 0) then
                           v_cmddel := v_cmddel + unsigned(romctrl(21 downto 16));
                        end if;
                        delay_cnt <= resize(v_cmddel * v_xcyc, 20);
                        state     <= WORDDELAY;
                     end if;
                  end if;

               when WORDDELAY =>
                  if (delay_cnt /= 0) then
                     delay_cnt <= delay_cnt - 1;
                  else
                     if (cmd_b7 = '1') then
                        v_eff := b7_addr;
                        if (v_eff < 16#8000#) then
                           v_eff := to_unsigned(16#8000#, 32) + (v_eff and to_unsigned(16#1FF#, 32));
                        end if;
                        card_ena  <= '1';
                        card_addr <= std_logic_vector(v_eff(26 downto 2));
                        state     <= FETCH;
                     else
                        if (cmd_b8 = '1') then
                           romdata <= CHIPID;
                        else
                           romdata <= (others => '1');
                        end if;
                        word_ready <= '1';
                        dma9_card  <= own9;
                        dma7_card  <= own7;
                        state      <= DATAREADY;
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

         end if;

      end if;
   end process;

end architecture;
