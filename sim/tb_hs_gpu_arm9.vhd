-- SPDX-License-Identifier: GPL-3.0-or-later
-- Host-only console CPU slice: the same ARM9 and memory bus as the MiSTer
-- product. Only backing stores and the GPU target are supplied by this bench.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use std.textio.all;
use work.pProc_bus_gba.all;

entity tb_hs_gpu_arm9 is
   generic (ROM_FILE : string);
end entity;

architecture sim of tb_hs_gpu_arm9 is
   subtype word is std_logic_vector(31 downto 0);
   type words is array (natural range <>) of word;
   constant expected : words := (
      x"0000820F", x"00000080", x"0000A526", x"0000A526", x"A5260000", x"00000000"
   );

   impure function load_rom return words is
      file image : text open read_mode is ROM_FILE;
      variable line_in : line;
      variable result : words(0 to 63) := (others => x"E7F000F0"); -- UDF
      variable index : natural := 0;
   begin
      while not endfile(image) loop
         readline(image, line_in);
         hread(line_in, result(index));
         index := index + 1;
      end loop;
      return result;
   end function;

   procedure gpu_start is
   begin
      assert false report "GPU VHPIDIRECT start not bound" severity failure;
   end procedure;
   attribute foreign of gpu_start : procedure is "VHPIDIRECT arm9_gpu_start";

   impure function gpu_transfer(cycle, address, width, is_write, data : integer) return integer is
   begin
      assert false report "GPU VHPIDIRECT transfer not bound" severity failure;
      return 0;
   end function;
   attribute foreign of gpu_transfer : function is "VHPIDIRECT arm9_gpu_transfer";

   procedure gpu_stop is
   begin
      assert false report "GPU VHPIDIRECT stop not bound" severity failure;
   end procedure;
   attribute foreign of gpu_stop : procedure is "VHPIDIRECT arm9_gpu_stop";

   -- The native membus presents an aligned address and byte-lane data/mask.
   -- ABI2 takes the physical byte address, original width and right-justified
   -- data. Put returned bytes back in their lanes; the RTL owns load rotation.
   impure function transfer(cycle : natural; aligned, data : word;
                            be : std_logic_vector(3 downto 0); rnw : std_logic) return word is
      variable lane, width, direction, response : integer;
      variable payload : word := (others => '0');
   begin
      case be is
         when "0001" => lane := 0; width := 1;
         when "0010" => lane := 1; width := 1;
         when "0100" => lane := 2; width := 1;
         when "1000" => lane := 3; width := 1;
         when "0011" => lane := 0; width := 2;
         when "1100" => lane := 2; width := 2;
         when "1111" => lane := 0; width := 4;
         when others => assert false report "invalid ARM9 GPU byte lanes" severity failure;
      end case;
      assert not is_x(aligned) and (rnw = '0' or rnw = '1')
         report "unknown ARM9 GPU request" severity failure;
      direction := 0;
      if rnw = '0' then
         direction := 1;
         payload(width*8-1 downto 0) := data((lane+width)*8-1 downto lane*8);
         assert not is_x(payload) report "unknown ARM9 GPU write data" severity failure;
      end if;
      response := gpu_transfer(cycle, to_integer(unsigned(aligned)) + lane, width,
                               direction, to_integer(signed(payload)));
      return std_logic_vector(shift_left(unsigned(to_signed(response, 32)), lane*8));
   end function;

   constant rom : words := load_rom;
   signal mailbox : words(expected'range) := (others => (others => '0'));
   signal stores : natural := 0;
   signal gpu_requests : natural := 0;
   signal arm9_ticks : natural := 0;
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
   signal io_reply, vram_reply : word := (others => '0');
   signal io_done, vram_done : std_logic := '0';
   signal vram_ena, vram_rnw : std_logic;
   signal vram_addr : unsigned(23 downto 2);
   signal vram_be : std_logic_vector(3 downto 0);
   signal vram_data : word;
   signal mr_ena, mr_rnw, mr_pair : std_logic;
   signal mr_done : std_logic := '0';
   signal mr_addr : std_logic_vector(21 downto 2);
   signal mr_be : std_logic_vector(3 downto 0);
   signal mr_data : word;
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
      dma_on => '0', IRQ_in => '0', unhalt => '0', new_halt => '0',
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
      vram_be => vram_be, vram_din => vram_data, vram_dout => vram_reply, vram_done => vram_done,
      io_bus => io_bus, io_wired_out => io_reply, io_wired_done => io_done,
      mr_ena => mr_ena, mr_rnw => mr_rnw, mr_addr => mr_addr, mr_be => mr_be,
      mr_writedata => mr_data, mr_pair => mr_pair, mr_done => mr_done,
      mr_readdata => (others => 'X'), mr_readdata_hi => (others => 'X')
   );

   process (clk)
      variable word_index : natural;
   begin
      if rising_edge(clk) then
         word_index := to_integer(brom_addr);
         if word_index < rom'length then
            brom_data <= rom(word_index);
         else
            brom_data <= x"E7F000F0";
         end if;
         io_done <= '0';
         vram_done <= '0';
         mr_done <= '0';
         if reset = '0' then
            arm9_ticks <= arm9_ticks + 1;
            assert cpu_error = '0' report "ARM9 instruction error at PC " & to_hstring(pc) severity failure;
            if cpu_ena = '1' then
               assert (cpu_adr(31 downto 15) = "11111111111111110" and cpu_rnw = '1') or
                      cpu_adr(31 downto 24) = x"02" or cpu_adr(31 downto 23) = "000001000" or
                      cpu_adr(31 downto 24) = x"06"
                  report "unwired ARM9 target " & to_hstring(cpu_adr) severity failure;
               assert cpu_acc = ACCESS_8BIT or (cpu_acc = ACCESS_16BIT and cpu_adr(0) = '0') or
                      (cpu_acc = ACCESS_32BIT and cpu_adr(1 downto 0) = "00")
                  report "unsupported ARM9 access width/alignment at " & to_hstring(cpu_adr) severity failure;
            end if;

            assert not (io_bus.ena = '1' and vram_ena = '1') severity failure;
            -- The bench's fast clock is ARM9 clk2x; ABI2 time is clk1x cycles
            -- since release, not the artificial simulation period in ns.
            if io_bus.ena = '1' then
               io_reply <= transfer(arm9_ticks/2, x"04" & io_bus.Adr(23 downto 0),
                                    io_bus.Din, io_bus.bEna, io_bus.rnw);
               io_done <= '1';
               gpu_requests <= gpu_requests + 1;
            elsif vram_ena = '1' then
               vram_reply <= transfer(arm9_ticks/2, x"06" & std_logic_vector(vram_addr) & "00",
                                      vram_data, vram_be, vram_rnw);
               vram_done <= '1';
               gpu_requests <= gpu_requests + 1;
            end if;

            if mr_ena = '1' then
               word_index := to_integer(unsigned(mr_addr));
               assert mr_rnw = '0' and mr_pair = '0' and mr_be = "1111" and
                      word_index = stores and word_index < mailbox'length
                  report "unexpected ARM9 main RAM access at 02" & to_hstring(mr_addr & "00") severity failure;
               mailbox(word_index) <= mr_data;
               stores <= stores + 1;
               mr_done <= '1';
            end if;
         end if;
      end if;
   end process;

   process
   begin
      gpu_start;
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

      wait until stores = expected'length for 10 us;
      assert stores = expected'length report "ARM9 witness did not finish; PC=" & to_hstring(pc) severity failure;
      assert gpu_requests = 10 report "missing or duplicate GPU requests" severity failure;
      for i in expected'range loop
         report "ARM9 RAM[" & integer'image(i*4) & "]=" & to_hstring(mailbox(i));
         assert mailbox(i) = expected(i)
            report "incorrect ARM9 RAM witness at offset " & integer'image(i*4) severity failure;
      end loop;
      gpu_stop;
      report "PASS: product ARM9 and memory bus round-trip through the Haskell GPU";
      stop;
      wait;
   end process;
end architecture;
