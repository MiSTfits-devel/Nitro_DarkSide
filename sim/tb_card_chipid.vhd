-- Cartridge chip-ID agreement test: nds_loader's direct-boot env block and
-- nds_card's B8 command have to answer the same word, for any ROM size.
--
-- nds_card used to hardcode 0x00003FC2 (melonDS's formula evaluated for a
-- 64 MB cart, right for Kirby and wrong for everything else) while the loader
-- derived it from the header's used-ROM-size word at +0x80. NitroSDK re-reads
-- the chip ID from CARDi_CheckPulledOut and compares it against the boot-time
-- copy at 0x02FFF800, so a disagreement reads as "cartridge pulled out".
--
-- Per case: a stub card image reports the size under test at header +0x80, the
-- loader runs (nothing to copy - both section sizes are 0), the env write at
-- 0x02FFF800 is snooped, then a B8 transfer is driven through the ARM9 half of
-- nds_card's register block and the popped data word compared. Both are also
-- checked against a hand-computed expectation so the test is not just the
-- design agreeing with itself.  Run: sim/run_card_chipid.sh

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity tb_card_chipid is
end entity;

architecture sim of tb_card_chipid is

   signal clk       : std_logic := '0';
   signal reset     : std_logic := '1';   -- loader
   signal resetCard : std_logic := '1';   -- nds_card (nds_top holds it in resetCpu)
   signal tests_done : boolean := false;

   -- ================= cases =================
   -- used ROM size at header +0x80 -> power-of-two envelope -> melonDS chip ID
   constant NCASES : integer := 5;
   type t_words is array (0 to NCASES-1) of std_logic_vector(31 downto 0);
   constant SIZES : t_words := (x"03159E2C",    -- Kirby: 51.3 MB -> 64 MB
                                x"00200000",    -- exactly 2 MB
                                x"00200001",    -- 2 MB + 1 byte -> 4 MB
                                x"08000000",    -- exactly 128 MB
                                x"00080000");   -- 512 KB, below the 1 MB floor
   constant IDS   : t_words := (x"00003FC2",    -- (64  - 1) << 8 | C2
                                x"000001C2",    -- (2   - 1) << 8 | C2
                                x"000003C2",    -- (4   - 1) << 8 | C2
                                x"00007FC2",    -- (128 - 1) << 8 | C2
                                x"000100C2");   -- melonDS small-ROM encoding

   signal test_size : std_logic_vector(31 downto 0) := SIZES(0);

   -- ================= stub card image =================
   -- only the words the loader reads matter; both section sizes are 0 so the
   -- copy loops fall straight through to the chip-ID calculation
   type t_card is array (0 to 255) of std_logic_vector(31 downto 0);
   constant CARDIMG : t_card :=
   (
       8      => x"00000000",   -- +0x20 ARM9 rom offset
       9      => x"02000000",   -- +0x24 ARM9 entry
      10      => x"02000000",   -- +0x28 ARM9 load addr
      11      => x"00000000",   -- +0x2C ARM9 size
      12      => x"00000000",   -- +0x30 ARM7 rom offset
      13      => x"02380000",   -- +0x34 ARM7 entry
      14      => x"02380000",   -- +0x38 ARM7 load addr
      15      => x"00000000",   -- +0x3C ARM7 size
      16#1B#  => x"0000BEEF",   -- +0x6C secure-area CRC16
      16#57#  => x"CAFE0000",   -- +0x15C header CRC16 in [31:16]
      others  => x"00000000"
   );

   -- ================= loader =================
   signal ld_start, ld_busy, ld_done, ld_error : std_logic;
   signal ld_cartid  : std_logic_vector(31 downto 0);
   signal ld_wr_ena  : std_logic;
   signal ld_wr_addr, ld_wr_data : std_logic_vector(31 downto 0);
   signal ld_card_ena  : std_logic;
   signal ld_card_addr : std_logic_vector(26 downto 2);

   signal env_chipid : std_logic_vector(31 downto 0) := (others => '0');
   signal env_seen   : std_logic := '0';

   -- ================= card =================
   signal cardm_ena  : std_logic;
   signal cardm_addr : std_logic_vector(26 downto 2);
   signal card_ena   : std_logic;
   signal card_addr  : std_logic_vector(26 downto 2);
   signal card_din   : std_logic_vector(31 downto 0) := (others => '0');
   signal card_done  : std_logic := '0';

   constant BUS_IDLE : proc_bus_gb_type :=
      ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');
   signal bus9 : proc_bus_gb_type := BUS_IDLE;
   signal card_out9 : std_logic_vector(31 downto 0);

   constant ADR_AUXSPI  : std_logic_vector(27 downto 0) := x"00001A0";
   constant ADR_ROMCTRL : std_logic_vector(27 downto 0) := x"00001A4";
   constant ADR_CMD0    : std_logic_vector(27 downto 0) := x"00001A8";
   constant ADR_DATA    : std_logic_vector(27 downto 0) := x"0100010";

begin

   clk <= not clk after 5 ns when not tests_done else '0';

   -- ================= behavioral card store =================
   -- shared port, muxed exactly like nds_top: the loader owns it while busy
   card_ena  <= ld_card_ena  when ld_busy = '1' else cardm_ena;
   card_addr <= ld_card_addr when ld_busy = '1' else cardm_addr;

   p_card : process (clk)
   begin
      if rising_edge(clk) then
         card_done <= '0';
         if (card_ena = '1') then
            if (unsigned(card_addr) = 16#20#) then      -- +0x80: size under test
               card_din <= test_size;
            elsif (unsigned(card_addr) < 256) then
               card_din <= CARDIMG(to_integer(unsigned(card_addr)));
            else
               card_din <= (others => '0');
            end if;
            card_done <= '1';
         end if;
      end if;
   end process;

   iloader : entity work.nds_loader
   port map
   (
      clk => clk, reset => reset,
      start => ld_start, direct => '1',
      busy => ld_busy, done => ld_done, load_error => ld_error,
      arm9_entry => open, arm7_entry => open, cart_id => ld_cartid,
      card_ena => ld_card_ena, card_addr => ld_card_addr,
      card_done => card_done, card_rdata => card_din,
      wr_ena => ld_wr_ena, wr_addr => ld_wr_addr, wr_data => ld_wr_data,
      wr_done => '1'                                -- accept every write at once
   );

   icard : entity work.nds_card
   port map
   (
      clk => clk, ce => '1', reset => resetCard,
      card7 => '0',                                 -- ARM9 owns the slot
      chipid => ld_cartid,
      bus9 => bus9, wired_out9 => card_out9, wired_done9 => open,
      bus7 => BUS_IDLE, wired_out7 => open, wired_done7 => open,
      irq9_xfer => open, irq7_xfer => open,
      dma9_card => open, dma7_card => open,
      card_ena => cardm_ena, card_addr => cardm_addr,
      card_din => card_din, card_done => card_done
   );

   -- snoop the direct-boot env block's first chip-ID word
   p_snoop : process (clk)
   begin
      if rising_edge(clk) then
         if (reset = '1') then                       -- asserted between cases
            env_seen <= '0';
         elsif (ld_wr_ena = '1' and ld_wr_addr = x"02FFF800") then
            env_chipid <= ld_wr_data;
            env_seen   <= '1';
         end if;
      end if;
   end process;

   -- ================= driver =================
   p_test : process
      variable b8_id : std_logic_vector(31 downto 0);

      procedure bus_write(adr : std_logic_vector(27 downto 0);
                          dat : std_logic_vector(31 downto 0)) is
      begin
         bus9.Adr  <= adr;
         bus9.Din  <= dat;
         bus9.bEna <= "1111";
         bus9.acc  <= ACCESS_32BIT;
         bus9.rnw  <= '0';
         bus9.ena  <= '1';
         wait until rising_edge(clk);
         bus9 <= BUS_IDLE;
         wait until rising_edge(clk);
      end procedure;

      -- read + pop of the data port (romdata is registered and does not move
      -- on the popping edge, so sampling right after it is the transfer value)
      procedure bus_pop(variable dat : out std_logic_vector(31 downto 0)) is
      begin
         bus9.Adr  <= ADR_DATA;
         bus9.acc  <= ACCESS_32BIT;
         bus9.rnw  <= '1';
         bus9.ena  <= '1';
         wait until rising_edge(clk);
         dat := card_out9;
         bus9 <= BUS_IDLE;
         wait until rising_edge(clk);
      end procedure;

      -- ROMCTRL[23] word-ready poll (pure combinational readback, no pop)
      procedure wait_word_ready is
         variable guard : integer := 0;
      begin
         bus9.Adr <= ADR_ROMCTRL;
         bus9.rnw <= '1';
         loop
            wait until rising_edge(clk);
            exit when card_out9(23) = '1';
            guard := guard + 1;
            assert guard < 1000
               report "nds_card never raised ROMCTRL word-ready for B8" severity failure;
         end loop;
         bus9 <= BUS_IDLE;
      end procedure;
   begin
      for c in 0 to NCASES-1 loop

         reset     <= '1';
         resetCard <= '1';
         ld_start  <= '0';
         test_size <= SIZES(c);
         for k in 1 to 4 loop wait until rising_edge(clk); end loop;

         -- ---- loader pass ----
         reset <= '0';
         wait until rising_edge(clk);
         ld_start <= '1';
         wait until rising_edge(clk);
         ld_start <= '0';
         wait until rising_edge(clk) and ld_busy = '0';
         assert ld_error = '0'
            report "loader flagged load_error for size " & to_hstring(SIZES(c))
            severity failure;
         assert ld_done = '1'
            report "loader neither done nor error for size " & to_hstring(SIZES(c))
            severity failure;

         assert env_seen = '1'
            report "loader wrote no chip ID to 0x02FFF800 for size " &
                   to_hstring(SIZES(c)) severity failure;
         assert env_chipid = IDS(c)
            report "size " & to_hstring(SIZES(c)) & ": env-block chip ID " &
                   to_hstring(env_chipid) & ", expected " & to_hstring(IDS(c))
            severity failure;
         assert ld_cartid = IDS(c)
            report "size " & to_hstring(SIZES(c)) & ": cart_id " &
                   to_hstring(ld_cartid) & ", expected " & to_hstring(IDS(c))
            severity failure;

         -- ---- card B8 pass ----
         resetCard <= '0';
         for k in 1 to 4 loop wait until rising_edge(clk); end loop;
         bus_write(ADR_AUXSPI,  x"00008000");   -- slot enabled, ROM mode
         bus_write(ADR_CMD0,    x"000000B8");   -- cmd[0] = B8, rest zero
         bus_write(ADR_ROMCTRL, x"87000000");   -- start, read dir, block size 7 = 1 word
         wait_word_ready;
         bus_pop(b8_id);

         assert b8_id = IDS(c)
            report "size " & to_hstring(SIZES(c)) & ": B8 answered " &
                   to_hstring(b8_id) & ", expected " & to_hstring(IDS(c))
            severity failure;
         assert b8_id = env_chipid
            report "size " & to_hstring(SIZES(c)) & ": B8 answered " &
                   to_hstring(b8_id) & " but the env block says " &
                   to_hstring(env_chipid) severity failure;

         report "size " & to_hstring(SIZES(c)) & ": env block and B8 both " &
                to_hstring(b8_id) severity note;

         -- let the transfer retire before the next case resets the block
         for k in 1 to 8 loop wait until rising_edge(clk); end loop;
      end loop;

      report "tb_card_chipid: PASS  " & integer'image(NCASES) &
             " ROM sizes, env block and B8 agree" severity note;
      tests_done <= true;
      wait;
   end process;

   p_watchdog : process
   begin
      wait for 2 ms;
      if not tests_done then
         report "tb_card_chipid: TIMEOUT" severity failure;
      end if;
      wait;
   end process;

end architecture;
