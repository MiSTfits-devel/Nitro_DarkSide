-- Card B7 block-read cost: how long a 512-word transfer actually takes, and
-- how much of that is the cart bus versus our own image-fetch latency.
--
-- melonDS charges NOTHING for the fetch - the ROM is a memcpy from a buffer, so
-- the only time in a transfer is the ROMCTRL pacing (xfercycle*(8+gaps+4) to the
-- first word, xfercycle*4 per word after). On silicon every word comes out of
-- DDR3, and while the fetch was issued after the pacing delay expired that
-- round trip was charged on top of every single word.
--
-- The image model here is ddram.sv ch2 as it behaves for the card: one request
-- in flight, LAT cycles when the request crosses into a new 64-bit beat, one
-- cycle when it is inside the beat ch2 already holds (the same-beat cache hit,
-- which is every other word of a sequential read), and every 64th request eats
-- an extra FBSTALL cycles for a framebuffer burst holding the port - ch5/ch6 run
-- 128-beat bursts and the grant chain cannot preempt one.
--
-- So MEASURED-EXPECTED is the time this core adds over melonDS, which charges
-- nothing at all for the read. It must not scale with LAT or FBSTALL: that is what
-- the prefetch queue is for.
--
--   sim/run_card_read.sh              DDR3-ish latency, one burst collision/64
--   sim/run_card_read.sh 0 0 0        pacing floor, zero-latency memory
--   sim/run_card_read.sh 60 2 130     as shipped (CARDSPEED_SHIFT=2)

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity tb_card_read is
   generic
   (
      LAT   : integer := 60;   -- DDR3 round trip on a new 64-bit beat
      SHIFT : integer := 0;    -- nds_card CARDSPEED_SHIFT
      FBSTALL : integer := 130;  -- extra cycles when an fb burst owns the port
      PF      : integer := 4     -- nds_card CARDPREFETCH
   );
end entity;

architecture sim of tb_card_read is

   constant WORDS    : integer := 512;              -- ROMCTRL block size 3
   constant BASE     : integer := 16#8000#;         -- B7 address, above the redirect

   signal clk        : std_logic := '0';
   signal reset      : std_logic := '1';
   signal tests_done : boolean := false;

   signal cardm_ena  : std_logic;
   signal cardm_addr : std_logic_vector(26 downto 2);
   signal card_din   : std_logic_vector(31 downto 0) := (others => '0');
   signal card_done  : std_logic := '0';

   constant BUS_IDLE : proc_bus_gb_type :=
      ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');
   signal bus9       : proc_bus_gb_type := BUS_IDLE;
   signal card_out9  : std_logic_vector(31 downto 0);

   constant ADR_AUXSPI  : std_logic_vector(27 downto 0) := x"00001A0";
   constant ADR_ROMCTRL : std_logic_vector(27 downto 0) := x"00001A4";
   constant ADR_CMD0    : std_logic_vector(27 downto 0) := x"00001A8";
   constant ADR_CMD4    : std_logic_vector(27 downto 0) := x"00001AC";
   constant ADR_DATA    : std_logic_vector(27 downto 0) := x"0100010";

   signal cyc     : integer := 0;   -- free-running clock counter
   signal fetches : integer := 0;   -- image fetches issued

begin

   clk <= not clk after 5 ns when not tests_done else '0';

   p_cyc : process (clk)
   begin
      if rising_edge(clk) then
         cyc <= cyc + 1;
      end if;
   end process;

   -- ================= image model: LAT cycles, one request in flight =========
   -- Each word answers with its own byte address, so an out-of-order or skipped
   -- fetch shows up as a data mismatch rather than as a plausible-looking word.
   p_mem : process (clk)
      variable cnt   : integer := -1;
      variable adr   : unsigned(24 downto 0) := (others => '0');
      variable beat  : unsigned(24 downto 0) := (others => '1');   -- cached beat
      variable nreq  : integer := 0;
   begin
      if rising_edge(clk) then
         card_done <= '0';
         if (cardm_ena = '1') then
            assert cnt < 0
               report "nds_card issued an image fetch with one still in flight"
               severity failure;
            adr     := unsigned(cardm_addr);
            fetches <= fetches + 1;
            nreq    := nreq + 1;
            if (adr(24 downto 1) = beat(24 downto 1)) then
               cnt := 1;                        -- ch2 already holds this beat
            else
               cnt  := LAT;
               beat := adr;
            end if;
            if (nreq mod 64 = 0) then
               cnt := cnt + FBSTALL;              -- fb burst owns the port
            end if;
         end if;
         if (cnt = 0) then
            card_din  <= std_logic_vector(resize(adr & "00", 32));
            card_done <= '1';
         end if;
         if (cnt >= 0) then
            cnt := cnt - 1;
         end if;
      end if;
   end process;

   icard : entity work.nds_card
   generic map (CARDSPEED_SHIFT => SHIFT, CARDPREFETCH => PF)
   port map
   (
      clk => clk, ce => '1', reset => reset,
      card7 => '0',                                 -- ARM9 owns the slot
      chipid => x"00003FC2",
      bus9 => bus9, wired_out9 => card_out9, wired_done9 => open,
      bus7 => BUS_IDLE, wired_out7 => open, wired_done7 => open,
      irq9_xfer => open, irq7_xfer => open,
      dma9_card => open, dma7_card => open,
      card_ena => cardm_ena, card_addr => cardm_addr,
      card_din => card_din, card_done => card_done
   );

   -- ================= driver =================
   p_test : process
      variable dat      : std_logic_vector(31 downto 0);
      variable t_start  : integer;
      variable measured : integer;
      variable expected : integer;
      variable pacing   : integer;
      variable memory   : integer;
      variable xcyc     : integer := 5;   -- ROMCTRL[27] clear

      procedure bus_write(adr : std_logic_vector(27 downto 0);
                          dt  : std_logic_vector(31 downto 0)) is
      begin
         bus9.Adr  <= adr;
         bus9.Din  <= dt;
         bus9.bEna <= "1111";
         bus9.acc  <= ACCESS_32BIT;
         bus9.rnw  <= '0';
         bus9.ena  <= '1';
         wait until rising_edge(clk);
         bus9 <= BUS_IDLE;
         wait until rising_edge(clk);
      end procedure;

      procedure bus_pop(variable dt : out std_logic_vector(31 downto 0)) is
      begin
         bus9.Adr <= ADR_DATA;
         bus9.acc <= ACCESS_32BIT;
         bus9.rnw <= '1';
         bus9.ena <= '1';
         wait until rising_edge(clk);
         dt := card_out9;
         bus9 <= BUS_IDLE;
         wait until rising_edge(clk);
      end procedure;

      -- ROMCTRL poll, exactly what a game's drain loop does
      procedure wait_word_ready is
         variable guard : integer := 0;
      begin
         bus9.Adr <= ADR_ROMCTRL;
         bus9.rnw <= '1';
         loop
            wait until rising_edge(clk);
            exit when card_out9(23) = '1';
            guard := guard + 1;
            assert guard < 10000
               report "ROMCTRL word-ready never came" severity failure;
         end loop;
         bus9 <= BUS_IDLE;
      end procedure;

      procedure wait_not_busy is
         variable guard : integer := 0;
      begin
         bus9.Adr <= ADR_ROMCTRL;
         bus9.rnw <= '1';
         loop
            wait until rising_edge(clk);
            exit when card_out9(31) = '0';
            guard := guard + 1;
            assert guard < 10000
               report "ROMCTRL busy never cleared" severity failure;
         end loop;
         bus9 <= BUS_IDLE;
      end procedure;
   begin
      for k in 1 to 4 loop wait until rising_edge(clk); end loop;
      reset <= '0';
      wait until rising_edge(clk);

      bus_write(ADR_AUXSPI, x"00008000");         -- slot enabled, ROM mode
      bus_write(ADR_CMD0,   x"800000B7");         -- B7, address 0x00008000
      bus_write(ADR_CMD4,   x"00000000");

      t_start := cyc;
      bus_write(ADR_ROMCTRL, x"83000000");        -- start, block size 3, no gaps

      for i in 0 to WORDS-1 loop
         wait_word_ready;
         bus_pop(dat);
         assert dat = std_logic_vector(to_unsigned(BASE + i*4, 32))
            report "word " & integer'image(i) & " = " & to_hstring(dat) &
                   ", expected " & to_hstring(to_unsigned(BASE + i*4, 32))
            severity failure;
      end loop;

      wait_not_busy;
      measured := cyc - t_start;

      -- Two floors, and which one binds is the whole diagnostic:
      --   pacing - the melonDS schedule, all a transfer should ever cost
      --   memory - what the DDR3 port can deliver, one request in flight, two
      --            words per beat. Above the pacing floor this is a BANDWIDTH
      --            limit that no amount of prefetch depth can hide; the fix for
      --            it is a burst fetch (ddram ch6 shape), not more queueing.
      pacing := ((8 + 4) * xcyc + (WORDS - 1) * 4 * xcyc) / (2 ** SHIFT);
      memory := ((WORDS + 1) / 2) * LAT + (WORDS / 2) + (WORDS / 64) * FBSTALL;
      if (pacing > memory) then
         expected := pacing;
      else
         expected := memory;
      end if;

      report "card read: " & integer'image(WORDS) & " words, LAT=" &
             integer'image(LAT) & " shift=" & integer'image(SHIFT) &
             " fbstall=" & integer'image(FBSTALL) & " pf=" & integer'image(PF) &
             " -> " & integer'image(measured) & " cycles (pacing floor " &
             integer'image(pacing) & ", memory floor " & integer'image(memory) &
             ", " & integer'image(fetches) & " fetches)";

      -- The tb's own poll/pop loop costs a few cycles per word (a real ARM9
      -- drain loop costs more), so allow a small per-word margin over whichever
      -- floor binds. What must NOT appear is the two floors added together,
      -- which is what charging the fetch serially after the pacing delay did.
      assert measured < expected + 6 * WORDS
         report "transfer cost " & integer'image(measured) & " cycles against a " &
                "binding floor of " & integer'image(expected) &
                ": the image fetch is not overlapped with the cart pacing"
         severity failure;

      assert fetches = WORDS
         report "expected " & integer'image(WORDS) & " image fetches, got " &
                integer'image(fetches)
         severity failure;

      -- B8 straight after, because the chip-ID answer is served from the same
      -- state as the prefetched image words and must not touch the queue at all:
      -- NitroSDK compares it against the boot-time copy and reads a mismatch as
      -- "cartridge pulled out". (sim/tb_card_chipid.vhd is the test for what the
      -- ID should BE; it currently times out in its loader pass, on HEAD too.)
      bus_write(ADR_CMD0, x"000000B8");
      bus_write(ADR_CMD4, x"00000000");
      bus_write(ADR_ROMCTRL, x"87000000");         -- start, block size 7 = 1 word
      wait_word_ready;
      bus_pop(dat);
      assert dat = x"00003FC2"
         report "B8 answered " & to_hstring(dat) & ", expected 00003FC2"
         severity failure;
      wait_not_busy;

      assert fetches = WORDS
         report "B8 issued an image fetch"
         severity failure;

      report "tb_card_read: PASS";
      tests_done <= true;
      wait;
   end process;

   p_watchdog : process
   begin
      wait for 5 ms;
      assert tests_done report "tb_card_read: TIMEOUT" severity failure;
      wait;
   end process;

end architecture;
