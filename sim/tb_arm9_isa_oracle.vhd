-- SPDX-License-Identifier: GPL-3.0-or-later
-- Independent oracle for the Clash ARM9 ISA fixtures: the product ARM9 and
-- memory bus run the same image with only boot ROM and main RAM attached.
-- Any I/O or VRAM access fails. RAM is the slice's 64 words at 0x02000000:
-- word k < SCRATCH is mailbox slot k and must be stored whole, in slot
-- order, equal to EXPECT_FILE (first hex token per line, '#' comments);
-- words SCRATCH..63 are byte-enabled scratch. No store may follow the
-- last checked mailbox word (MAILBOX_WORDS, or the whole file when 0).
-- With IRQ_IO the product timers (gba_timer) and IME/IE/IF (nds_irq) sit on
-- the I/O bus as in the console island, paced at half the CPU clock (or at
-- the full clock with IO_FULL_RATE, as nds_nitro_console_top runs nds_irq),
-- and drive the CPU's IRQ input. With CARD_IO the product game-card slot
-- (nds_card, full rate as in nds_nitro_console_top) is on the same bus,
-- reading CARD_FILE (one little-endian word per line) through its image
-- port with CARD_LAT cycles per word, and its transfer IRQ is IF bit 19.
-- I/O outside those registers still fails.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use std.textio.all;
use work.pProc_bus_gba.all;

entity tb_arm9_isa_oracle is
   generic (ROM_FILE : string; EXPECT_FILE : string; SCRATCH : natural := 64;
            MAILBOX_WORDS : natural := 0; IRQ_IO : boolean := false;
            IO_FULL_RATE : boolean := false;
            CARD_IO : boolean := false; CARD_FILE : string := "";
            CARD_FW_BOOT : std_logic := '0'; CARD_CHIPID : natural := 0;
            CARD_MASK : natural := 16#FFFF#; CARD_LAT : positive := 3);
end entity;

architecture sim of tb_arm9_isa_oracle is
   subtype word is std_logic_vector(31 downto 0);
   type words is array (natural range <>) of word;
   type table is record
      data  : words(0 to 1023);
      count : natural;
   end record;

   impure function load(path : string; fill : word) return table is
      file image : text open read_mode is path;
      variable line_in : line;
      variable result : table := ((others => fill), 0);
   begin
      while not endfile(image) loop
         readline(image, line_in);
         if line_in'length > 0 and line_in(line_in'low) /= '#' then
            hread(line_in, result.data(result.count));
            result.count := result.count + 1;
         end if;
      end loop;
      return result;
   end function;

   constant rom : table := load(ROM_FILE, x"E7F000F0"); -- UDF past the image
   constant expected : table := load(EXPECT_FILE, x"00000000");
   impure function checked_words return natural is
   begin
      if MAILBOX_WORDS = 0 then return expected.count; end if;
      assert MAILBOX_WORDS <= expected.count report "MAILBOX_WORDS exceeds EXPECT_FILE" severity failure;
      return MAILBOX_WORDS;
   end function;
   constant checked : natural := checked_words;
   signal stores : natural := 0;
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal ss : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "10", "1111", '1');

   signal cpu_adr, cpu_dout, cpu_din, cpu_lastread, pc : word;
   signal cpu_rnw, cpu_ena, cpu_code, cpu_lock, cpu_done, cpu_error : std_logic;
   signal cpu_acc, cpu_low : std_logic_vector(1 downto 0);
   signal itcm_ena, itcm_load, dtcm_ena, dtcm_load : std_logic;
   signal itcm_size, dtcm_size : std_logic_vector(4 downto 0);
   signal dtcm_base : std_logic_vector(31 downto 12);
   signal cache_i, cache_d, buffer_d, deny_d, cache_ena, cache_busy : std_logic;
   signal cache_op : std_logic_vector(3 downto 0);
   signal cache_addr : word;
   signal brom_addr : unsigned(14 downto 2);
   signal brom_data : word;

   signal io_bus : proc_bus_gb_type;
   signal vram_ena, vram_rnw : std_logic;
   signal vram_addr : unsigned(23 downto 2);
   signal vram_be : std_logic_vector(3 downto 0);
   signal vram_data : word;
   signal mr_ena, mr_rnw, mr_pair : std_logic;
   signal mr_done : std_logic := '0';
   signal mr_addr : std_logic_vector(21 downto 2);
   signal mr_be : std_logic_vector(3 downto 0);
   signal mr_data : word;
   signal mr_rdata, mr_rdata_hi : word := (others => '0');
   signal ram : words(0 to 1023) := (others => (others => '0'));
   signal io_wired_out, irq_wired_out, timer_wired_out, card_wired_out : word := (others => '0');
   signal io_wired_done, irq_wired_done, timer_wired_done, card_wired_done : std_logic := '0';
   signal cpu_irq, io_ce : std_logic := '0';
   signal io_ce_next : std_logic := '1';   -- full-rate I/O unless IRQ_IO at half rate
   signal irp_timer : std_logic_vector(3 downto 0);
   signal irq_sources : word;
   signal irq9_card : std_logic := '0';
   signal card_ena, card_done : std_logic := '0';
   signal card_addr : std_logic_vector(28 downto 2);
   signal card_din : word := (others => '0');
begin
   clk <= not clk after 5 ns;

   cpu : entity work.nds_cpu9
   generic map (is_simu => '0')
   port map (
      clk => clk, ce => '1', reset => reset, cold_boot => '1',
      savestate_bus => ss, error_cpu => cpu_error, dbg_pc => pc,
      gb_bus_adr => cpu_adr, gb_bus_rnw => cpu_rnw, gb_bus_ena => cpu_ena,
      gb_bus_code => cpu_code, gb_bus_acc => cpu_acc, gb_bus_lock => cpu_lock,
      gb_bus_dout => cpu_dout, gb_bus_din => cpu_din, gb_bus_done => cpu_done,
      bus_lowbits => cpu_low, lastread => cpu_lastread,
      dma_on => '0', IRQ_in => cpu_irq, unhalt => '0', new_halt => '0',
      cp15_itcm_ena => itcm_ena, cp15_itcm_load => itcm_load, cp15_itcm_size => itcm_size,
      cp15_dtcm_ena => dtcm_ena, cp15_dtcm_load => dtcm_load, cp15_dtcm_size => dtcm_size,
      cp15_dtcm_base => dtcm_base, bus_cacheable_i => cache_i, bus_cacheable_d => cache_d,
      bus_bufferable_d => buffer_d, bus_wdenied_d => deny_d, cache_op_ena => cache_ena,
      cache_op => cache_op, cache_op_addr => cache_addr, cache_op_busy => cache_busy
   );

   membus : entity work.nds_membus9
   generic map (is_simu => '1')
   port map (
      clk => clk, reset => reset, native_mode => '1',
      itcm_ena => itcm_ena, itcm_load => itcm_load, itcm_size => itcm_size,
      dtcm_ena => dtcm_ena, dtcm_load => dtcm_load, dtcm_size => dtcm_size,
      dtcm_base => dtcm_base, bus_cacheable_i => cache_i, bus_cacheable_d => cache_d,
      bus_bufferable_d => buffer_d, bus_wdenied_d => deny_d, cache_op_ena => cache_ena,
      cache_op => cache_op, cache_op_addr => cache_addr, cache_op_busy => cache_busy,
      cpu_adr => cpu_adr, cpu_rnw => cpu_rnw, cpu_ena => cpu_ena, cpu_code => cpu_code,
      cpu_acc => cpu_acc, cpu_lock => cpu_lock, cpu_dout => cpu_dout, cpu_lowbits => cpu_low,
      cpu_lastread => cpu_lastread, cpu_din => cpu_din, cpu_done => cpu_done,
      brom_addr => brom_addr, brom_data => brom_data,
      itcm_readdata => (others => 'X'), dtcm_readdata => (others => 'X'),
      wsh_dout => (others => 'X'), wsh_done => '0', wsh_mapped => '0',
      pal_readdata => (others => 'X'), oam_readdata => (others => 'X'),
      vram_ena => vram_ena, vram_rnw => vram_rnw, vram_addr => vram_addr,
      vram_be => vram_be, vram_din => vram_data, vram_dout => (others => 'X'), vram_done => '0',
      io_ce_next => io_ce_next,
      io_bus => io_bus, io_wired_out => io_wired_out, io_wired_done => io_wired_done,
      mr_ena => mr_ena, mr_rnw => mr_rnw, mr_addr => mr_addr, mr_be => mr_be,
      mr_writedata => mr_data, mr_pair => mr_pair, mr_done => mr_done,
      mr_readdata => mr_rdata, mr_readdata_hi => mr_rdata_hi
   );

   process (clk)
      variable word_index : natural;
   begin
      if rising_edge(clk) then
         word_index := to_integer(brom_addr);
         if word_index < rom.data'length then
            brom_data <= rom.data(word_index);
         else
            brom_data <= x"E7F000F0";
         end if;
         mr_done <= '0';
         if reset = '0' then
            assert cpu_error = '0' report "ARM9 instruction error at PC " & to_hstring(pc) severity failure;
            assert vram_ena = '0' report "ARM9 fixture reached VRAM" severity failure;
            assert io_bus.ena = '0' or (IRQ_IO and
                   ((unsigned(io_bus.Adr(23 downto 0)) >= 16#100# and unsigned(io_bus.Adr(23 downto 0)) < 16#110#) or
                    (unsigned(io_bus.Adr(23 downto 0)) >= 16#208# and unsigned(io_bus.Adr(23 downto 0)) < 16#218#))) or
                   (CARD_IO and
                   ((unsigned(io_bus.Adr(23 downto 0)) >= 16#1A0# and unsigned(io_bus.Adr(23 downto 0)) < 16#1B0#) or
                    unsigned(io_bus.Adr(23 downto 0)) = 16#100010#))
               report "ARM9 fixture reached unwired I/O at 04" & to_hstring(io_bus.Adr(23 downto 0)) severity failure;
            if cpu_ena = '1' then
               assert (cpu_adr(31 downto 15) = "11111111111111110" and cpu_rnw = '1') or
                      cpu_adr(31 downto 24) = x"02" or
                      ((IRQ_IO or CARD_IO) and cpu_adr(31 downto 24) = x"04")
                  report "ARM9 fixture access outside ROM/main RAM/I/O: " & to_hstring(cpu_adr) severity failure;
            end if;
            if mr_ena = '1' then
               word_index := to_integer(unsigned(mr_addr));
               assert word_index < 64 and (mr_pair = '0' or word_index < 63)
                  report "ARM9 main RAM access outside the 256-byte fixture RAM at 02" &
                         to_hstring(mr_addr & "00") severity failure;
               if mr_rnw = '1' then
                  mr_rdata <= ram(word_index);
                  if mr_pair = '1' then
                     mr_rdata_hi <= ram(word_index + 1);
                  end if;
               else
                  assert mr_pair = '0' and stores < checked
                     report "unexpected ARM9 main RAM store at 02" & to_hstring(mr_addr & "00") severity failure;
                  if word_index >= SCRATCH then
                     for lane in 0 to 3 loop
                        if mr_be(lane) = '1' then
                           ram(word_index)(lane*8+7 downto lane*8) <= mr_data(lane*8+7 downto lane*8);
                        end if;
                     end loop;
                  else
                     assert mr_be = "1111" and word_index = stores
                        report "unexpected ARM9 mailbox store at 02" & to_hstring(mr_addr & "00") severity failure;
                     report "ARM9 RAM[" & integer'image(word_index*4) & "]=" & to_hstring(mr_data);
                     assert mr_data = expected.data(word_index)
                        report "slot " & integer'image(word_index) & " expected " &
                               to_hstring(expected.data(word_index)) severity failure;
                     ram(word_index) <= mr_data;
                     stores <= stores + 1;
                  end if;
               end if;
               mr_done <= '1';
            end if;
         end if;
      end if;
   end process;

   process
   begin
      -- Hold reset and seed the boot PC through the real processor preset bus.
      for i in 1 to 3 loop wait until falling_edge(clk); end loop;
      ss.rst <= '0';
      ss.Din <= x"FFFF0000";
      ss.rnw <= '0';
      ss.ena <= '1';
      wait until falling_edge(clk);
      ss.ena <= '0';
      for i in 1 to 3 loop wait until falling_edge(clk); end loop;
      reset <= '0';

      wait until stores = checked for 400 us;
      assert stores = checked report "ARM9 fixture did not finish; PC=" & to_hstring(pc) severity failure;
      -- The image then spins: no further stores may appear.
      wait for 2 us;
      assert stores = checked report "ARM9 fixture stored past its mailbox" severity failure;
      report "PASS: product ARM9 matches " & integer'image(checked) & " fixture mailbox words";
      stop;
      wait;
   end process;

   io_wired_out  <= irq_wired_out or timer_wired_out or card_wired_out;
   io_wired_done <= irq_wired_done or timer_wired_done or card_wired_done;

   io : if IRQ_IO generate
      irq_sources   <= (3 => irp_timer(0), 4 => irp_timer(1), 5 => irp_timer(2),
                        6 => irp_timer(3), 19 => irq9_card, others => '0');

      full : if IO_FULL_RATE generate
         io_ce <= '1';
      end generate;
      half : if not IO_FULL_RATE generate
         io_ce_next <= not io_ce;
         process (clk)
         begin
            if rising_edge(clk) then
               io_ce <= not io_ce;
            end if;
         end process;
      end generate;

      iirq : entity work.nds_irq
      port map (
         clk => clk, ce => io_ce, reset => reset,
         gb_bus => io_bus, wired_out => irq_wired_out, wired_done => irq_wired_done,
         irq_in => irq_sources, cpu_irq => cpu_irq, cpu_unhalt => open
      );

      itimer : entity work.gba_timer
      generic map (is_simu => '0')
      port map (
         clk => clk, ce => io_ce, reset => reset,
         savestate_bus => ss, ss_wired_out => open, ss_wired_done => open,
         loading_savestate => '0',
         gb_bus => io_bus, wired_out => timer_wired_out, wired_done => timer_wired_done,
         IRP_Timer => irp_timer, timer0_tick => open, timer1_tick => open,
         debugout0 => open, debugout1 => open, debugout2 => open, debugout3 => open
      );
   end generate;

   card : if CARD_IO generate
      type image_t is array (natural range <>) of word;
      impure function load_image return image_t is
         file image : text open read_mode is CARD_FILE;
         variable line_in : line;
         variable result : image_t(0 to CARD_MASK / 4) := (others => (others => '1'));
         variable index : natural := 0;
      begin
         while not endfile(image) loop
            readline(image, line_in);
            hread(line_in, result(index));
            index := index + 1;
         end loop;
         assert index = result'length report "CARD_FILE size differs from CARD_MASK" severity failure;
         return result;
      end function;
      constant image : image_t := load_image;
      constant idle_bus : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "10", "1111", '0');
      signal pending : natural := 0;
      signal fetch_word : natural := 0;
   begin
      icard : entity work.nds_card
      port map (
         clk => clk, ce => '1', reset => reset, card7 => '0', fw_boot => CARD_FW_BOOT,
         chipid => std_logic_vector(to_unsigned(CARD_CHIPID, 32)),
         rom_addr_mask => std_logic_vector(to_unsigned(CARD_MASK, 32)),
         bus9 => io_bus, wired_out9 => card_wired_out, wired_done9 => card_wired_done,
         bus7 => idle_bus, wired_out7 => open, wired_done7 => open,
         irq9_xfer => irq9_card, irq7_xfer => open,
         dbg_card => open, dma9_card => open, dma7_card => open,
         card_ena => card_ena, card_addr => card_addr, card_din => card_din, card_done => card_done
      );

      -- One image read in flight, answered CARD_LAT cycles after it is asked.
      process (clk)
         variable a : natural;
      begin
         if rising_edge(clk) then
            card_done <= '0';
            if card_ena = '1' then
               a := to_integer(unsigned(card_addr)) * 4;
               assert a <= CARD_MASK report "card image read outside the image" severity failure;
               fetch_word <= a / 4;
               pending <= CARD_LAT;
            elsif pending = 1 then
               card_din <= image(fetch_word);
               card_done <= '1';
               pending <= 0;
            elsif pending /= 0 then
               pending <= pending - 1;
            end if;
         end if;
      end process;
   end generate;
end architecture;
