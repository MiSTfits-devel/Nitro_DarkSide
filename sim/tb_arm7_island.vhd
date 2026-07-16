-- ARM7 island (roadmap M2 exit test): the vendored gba_cpu wired through
-- nds_membus7 to BIOS BRAM (sim/tests/arm7_island.hex), main RAM (nds_mainram
-- + behavioral SDRAM controller), shared WRAM (WRAMCNT=3), ARM7-private WRAM,
-- VRAM bank C as ARM7 WRAM (behavioral A..D backing server), timers, IRQ and
-- IPC. The testbench plays the ARM9: it echoes IPCSYNC nibbles and loops IPC
-- FIFO words back +1, and snoops the mailbox the test program keeps at
-- 0x02FFFF00 (+0 progress bitmask, +4 magic 0xCAFEBABE / 0xBADBAD00).
-- Run: sim/run_arm7_island.sh

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.textio.all;

use work.pProc_bus_gba.all;

entity tb_arm7_island is
   generic
   (
      HEXFILE    : string  := "sim/tests/arm7_island.hex";
      TIMEOUT_MS : integer := 10
   );
end entity;

architecture sim of tb_arm7_island is

   constant MAINRAM_BASE : integer := 8388608; -- 8 MB offset inside SDRAM, arbitrary

   signal clk1x       : std_logic := '0';
   signal clkMem      : std_logic := '0';
   signal clkMemIndex : unsigned(1 downto 0) := "10"; -- wraps to 0 on clk1x edge
   signal reset       : std_logic := '1';

   -- CPU <-> membus
   signal cpu_adr      : std_logic_vector(31 downto 0);
   signal cpu_rnw      : std_logic;
   signal cpu_ena      : std_logic;
   signal cpu_acc      : std_logic_vector(1 downto 0);
   signal cpu_dout     : std_logic_vector(31 downto 0);
   signal cpu_din      : std_logic_vector(31 downto 0);
   signal cpu_done     : std_logic;
   signal cpu_lowbits  : std_logic_vector(1 downto 0);
   signal cpu_lastread : std_logic_vector(31 downto 0);
   signal error_cpu    : std_logic;

   signal cpu_irq, cpu_unhalt : std_logic;

   -- idle savestate bus; .rst pulsed during boot so shadow regs load startVals
   signal ss_bus : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '1');

   -- BIOS store (16 KB)
   type t_bios is array (0 to 4095) of std_logic_vector(31 downto 0);
   impure function load_hex(fname : string) return t_bios is
      file f       : text;
      variable l   : line;
      variable w   : std_logic_vector(31 downto 0);
      variable mem : t_bios := (others => (others => '0'));
      variable i   : integer := 0;
   begin
      file_open(f, fname, read_mode);
      while not endfile(f) loop
         readline(f, l);
         hread(l, w);
         mem(i) := w;
         i := i + 1;
      end loop;
      file_close(f);
      report "loaded " & integer'image(i) & " BIOS words from " & fname severity note;
      return mem;
   end function;
   constant bios : t_bios := load_hex(HEXFILE);
   signal bios_addr : unsigned(13 downto 2);
   signal bios_data : std_logic_vector(31 downto 0);

   -- ARM7-private WRAM (64 KB)
   type t_wram7 is array (0 to 16383) of std_logic_vector(31 downto 0);
   signal wram7 : t_wram7 := (others => (others => '0'));
   signal w7p_addr      : unsigned(15 downto 2);
   signal w7p_we        : std_logic;
   signal w7p_be        : std_logic_vector(3 downto 0);
   signal w7p_writedata : std_logic_vector(31 downto 0);
   signal w7p_readdata  : std_logic_vector(31 downto 0);

   -- shared WRAM
   signal wsh_ena, wsh_rnw, wsh_done, wsh_mapped : std_logic;
   signal wsh_addr : unsigned(14 downto 2);
   signal wsh_be   : std_logic_vector(3 downto 0);
   signal wsh_din, wsh_dout : std_logic_vector(31 downto 0);

   -- VRAM
   signal vram_ena, vram_rnw, vram_done : std_logic;
   signal vram_addr : unsigned(23 downto 2);
   signal vram_be   : std_logic_vector(3 downto 0);
   signal vram_din, vram_dout : std_logic_vector(31 downto 0);
   -- bank C: enabled, MST=2 (ARM7 WRAM), OFS=0
   signal vramcnt : std_logic_vector(71 downto 0) := x"000000000000820000";
   signal srv_req, srv_rnw, srv_done : std_logic := '0';
   signal srv_bank : std_logic_vector(1 downto 0);
   signal srv_addr : unsigned(16 downto 2);
   signal srv_be   : std_logic_vector(3 downto 0);
   signal srv_din  : std_logic_vector(31 downto 0);
   signal srv_dout : std_logic_vector(31 downto 0) := (others => '0');

   -- main RAM
   signal mr7_ena, mr7_rnw, mr7_done : std_logic;
   signal mr7_addr : std_logic_vector(21 downto 2);
   signal mr7_be   : std_logic_vector(3 downto 0);
   signal mr7_writedata, mr7_readdata : std_logic_vector(31 downto 0);
   signal mainram_active, mainram_busy : std_logic;
   signal model_allow : std_logic := '1';
   signal sdram_ena, sdram_rnw : std_logic := '0';
   signal sdram_Adr : std_logic_vector(26 downto 0);
   signal sdram_Din : std_logic_vector(31 downto 0);
   signal sdram_be  : std_logic_vector(3 downto 0);
   signal sdram_Dout : std_logic_vector(31 downto 0) := (others => '0');
   signal sdram_done32 : std_logic := '0';

   -- IO register bus
   signal io_bus : proc_bus_gb_type;
   signal io_wired_out : std_logic_vector(31 downto 0);
   signal io_wired_done : std_logic;
   signal irq_wired_out, timer_wired_out, ipc_wired_out7 : std_logic_vector(31 downto 0);
   signal irq_wired_done, timer_wired_done, ipc_wired_done7 : std_logic;

   signal irq_in    : std_logic_vector(31 downto 0);
   signal irp_timer : std_logic_vector(3 downto 0);
   signal ipc_irq_sync, ipc_irq_sendempty, ipc_irq_recv : std_logic;

   -- IPC ARM9 side
   signal bus9 : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "10", "0000", '0');
   signal ipc_wired_out9 : std_logic_vector(31 downto 0);
   signal ipc_wired_done9 : std_logic;

   signal mailbox_bits : std_logic_vector(31 downto 0) := (others => '0');
   signal tests_done   : boolean := false;

   procedure rnd(variable s : inout unsigned(31 downto 0)) is
   begin
      s := s xor shift_left(s, 13);
      s := s xor shift_right(s, 17);
      s := s xor shift_left(s, 5);
   end procedure;

begin

   -- ================= clocks (3 clkMem phases per clk1x, tb_mainram idiom) =================
   clkMem <= not clkMem after 5 ns when not tests_done else '0';

   process (clkMem)
   begin
      if rising_edge(clkMem) then
         if (clkMemIndex = 2) then
            clkMemIndex <= "00";
            clk1x       <= '1';
         else
            clkMemIndex <= clkMemIndex + 1;
         end if;
         if (clkMemIndex = 0) then
            clk1x <= '0';
         end if;
      end if;
   end process;

   process
   begin
      for k in 1 to 8 loop wait until rising_edge(clk1x); end loop;
      reset <= '0';
      wait;
   end process;
   ss_bus.rst <= reset;

   -- ================= CPU =================
   icpu : entity work.gba_cpu
   generic map ( is_simu => '0' )
   port map
   (
      clk             => clk1x,
      ce              => '1',
      reset           => reset,
      cpu_export_done => open,
      cpu_export      => open,
      error_cpu       => error_cpu,
      savestate_bus   => ss_bus,
      ss_wired_out    => open,
      ss_wired_done   => open,
      gb_bus_Adr      => cpu_adr,
      gb_bus_rnw      => cpu_rnw,
      gb_bus_ena      => cpu_ena,
      gb_bus_seq      => open,
      gb_bus_code     => open,
      gb_bus_acc      => cpu_acc,
      gb_bus_dout     => cpu_dout,
      gb_bus_din      => cpu_din,
      gb_bus_done     => cpu_done,
      bus_lowbits     => cpu_lowbits,
      dma_on          => '0',
      done            => open,
      CPU_bus_idle    => open,
      PC_in_BIOS      => open,
      cpu_halt        => open,
      lastread        => cpu_lastread,
      jump_out        => open,
      IRQ_in          => cpu_irq,
      unhalt          => cpu_unhalt,
      new_halt        => '0'
   );

   -- ================= bus decoder =================
   imembus : entity work.nds_membus7
   port map
   (
      clk => clk1x, reset => reset,
      cpu_adr => cpu_adr, cpu_rnw => cpu_rnw, cpu_ena => cpu_ena, cpu_acc => cpu_acc,
      cpu_dout => cpu_dout, cpu_lowbits => cpu_lowbits, cpu_lastread => cpu_lastread,
      cpu_din => cpu_din, cpu_done => cpu_done,
      bios_addr => bios_addr, bios_data => bios_data,
      w7p_addr => w7p_addr, w7p_we => w7p_we, w7p_be => w7p_be,
      w7p_writedata => w7p_writedata, w7p_readdata => w7p_readdata,
      wsh_ena => wsh_ena, wsh_rnw => wsh_rnw, wsh_addr => wsh_addr, wsh_be => wsh_be,
      wsh_din => wsh_din, wsh_dout => wsh_dout, wsh_done => wsh_done, wsh_mapped => wsh_mapped,
      vram_ena => vram_ena, vram_rnw => vram_rnw, vram_addr => vram_addr, vram_be => vram_be,
      vram_din => vram_din, vram_dout => vram_dout, vram_done => vram_done,
      mr_ena => mr7_ena, mr_rnw => mr7_rnw, mr_addr => mr7_addr, mr_be => mr7_be,
      mr_writedata => mr7_writedata, mr_done => mr7_done, mr_readdata => mr7_readdata,
      io_bus => io_bus, io_wired_out => io_wired_out, io_wired_done => io_wired_done
   );

   -- ================= BIOS + private WRAM stores =================
   bios_data <= bios(to_integer(bios_addr));

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (w7p_we = '1') then
            for i in 0 to 3 loop
               if (w7p_be(i) = '1') then
                  wram7(to_integer(w7p_addr))(i*8 + 7 downto i*8) <= w7p_writedata(i*8 + 7 downto i*8);
               end if;
            end loop;
         end if;
      end if;
   end process;
   w7p_readdata <= wram7(to_integer(w7p_addr));

   -- ================= IO register banks =================
   io_wired_out  <= irq_wired_out or timer_wired_out or ipc_wired_out7;
   io_wired_done <= irq_wired_done or timer_wired_done or ipc_wired_done7;

   irq_in <= (3 => irp_timer(0), 4 => irp_timer(1), 5 => irp_timer(2), 6 => irp_timer(3),
              16 => ipc_irq_sync, 17 => ipc_irq_sendempty, 18 => ipc_irq_recv,
              others => '0');

   iirq : entity work.nds_irq
   port map
   (
      clk => clk1x, ce => '1', reset => reset,
      gb_bus => io_bus, wired_out => irq_wired_out, wired_done => irq_wired_done,
      irq_in => irq_in, cpu_irq => cpu_irq, cpu_unhalt => cpu_unhalt
   );

   itimer : entity work.gba_timer
   generic map ( is_simu => '0' )
   port map
   (
      clk => clk1x, ce => '1', reset => reset,
      savestate_bus => ss_bus, ss_wired_out => open, ss_wired_done => open,
      loading_savestate => '0',
      gb_bus => io_bus, wired_out => timer_wired_out, wired_done => timer_wired_done,
      IRP_Timer => irp_timer,
      timer0_tick => open, timer1_tick => open,
      debugout0 => open, debugout1 => open, debugout2 => open, debugout3 => open
   );

   iipc : entity work.nds_ipc
   port map
   (
      clk => clk1x, reset => reset,
      bus7 => io_bus, wired_out7 => ipc_wired_out7, wired_done7 => ipc_wired_done7,
      irq7_sync => ipc_irq_sync, irq7_sendempty => ipc_irq_sendempty, irq7_recv => ipc_irq_recv,
      bus9 => bus9, wired_out9 => ipc_wired_out9, wired_done9 => ipc_wired_done9,
      irq9_sync => open, irq9_sendempty => open, irq9_recv => open
   );

   -- ================= memory fabric =================
   iwram : entity work.nds_wram
   generic map ( is_simu => '1' )
   port map
   (
      clk => clk1x, wramcnt => "11",
      arm9_ena => '0', arm9_rnw => '1', arm9_addr => (others => '0'), arm9_be => "0000",
      arm9_din => (others => '0'), arm9_dout => open, arm9_done => open, arm9_mapped => open,
      arm7_ena => wsh_ena, arm7_rnw => wsh_rnw, arm7_addr => wsh_addr, arm7_be => wsh_be,
      arm7_din => wsh_din, arm7_dout => wsh_dout, arm7_done => wsh_done, arm7_mapped => wsh_mapped
   );

   ivram : entity work.nds_vram
   generic map ( is_simu => '1' )
   port map
   (
      clk => clk1x, reset => reset, vramcnt => vramcnt,
      cpu9_ena => '0', cpu9_rnw => '1', cpu9_addr => (others => '0'), cpu9_be => "0000",
      cpu9_din => (others => '0'), cpu9_dout => open, cpu9_done => open,
      cpu7_ena => vram_ena, cpu7_rnw => vram_rnw, cpu7_addr => vram_addr, cpu7_be => vram_be,
      cpu7_din => vram_din, cpu7_dout => vram_dout, cpu7_done => vram_done,
      srv_req => srv_req, srv_rnw => srv_rnw, srv_bank => srv_bank, srv_addr => srv_addr,
      srv_be => srv_be, srv_din => srv_din, srv_dout => srv_dout, srv_done => srv_done
   );

   imainram : entity work.nds_mainram
   generic map ( Softmap_NDS_MAINRAM_ADDR => MAINRAM_BASE )
   port map
   (
      clk1x => clk1x, clkMem => clkMem, clkMemIndex => clkMemIndex, reset => reset,
      arm7_priority => '0',
      mem9_ena => '0', mem9_rnw => '1', mem9_addr => (others => '0'), mem9_be => "0000",
      mem9_writedata => (others => '0'), mem9_done => open, mem9_readdata => open,
      mem7_ena => mr7_ena, mem7_rnw => mr7_rnw, mem7_addr => mr7_addr, mem7_be => mr7_be,
      mem7_writedata => mr7_writedata, mem7_done => mr7_done, mem7_readdata => mr7_readdata,
      mainram_allow => model_allow, mainram_active => mainram_active, mainram_busy => mainram_busy,
      mr_sdram_ena => sdram_ena, mr_sdram_rnw => sdram_rnw, mr_sdram_Adr => sdram_Adr,
      mr_sdram_Din => sdram_Din, mr_sdram_be => sdram_be,
      sdram_Dout => sdram_Dout, sdram_done32 => sdram_done32
   );

   -- ================= behavioral SDRAM controller (from tb_mainram) =================
   psdram : process
      type t_mem is array (0 to 1048575) of std_logic_vector(31 downto 0);
      variable mem : t_mem := (others => (others => '0'));
      variable a   : integer;
      variable w   : integer;
      variable refresh_cnt : integer := 0;
      variable v_rnw : std_logic;
      variable v_din : std_logic_vector(31 downto 0);
      variable v_be  : std_logic_vector(3 downto 0);
   begin
      wait until rising_edge(clkMem);
      refresh_cnt := refresh_cnt + 1;

      if (refresh_cnt = 740) then
         model_allow <= '0';
      end if;

      if (sdram_ena = '1') then
         a     := to_integer(unsigned(sdram_Adr));
         v_rnw := sdram_rnw;
         v_din := sdram_Din;
         v_be  := sdram_be;
         assert (a >= MAINRAM_BASE and a < MAINRAM_BASE + 4194304)
            report "sdram op outside main-RAM window: " & integer'image(a) severity failure;
         w := (a - MAINRAM_BASE) / 4;

         if (v_rnw = '1') then
            for k in 1 to 6 loop wait until rising_edge(clkMem); end loop;
            sdram_Dout   <= mem(w);
            sdram_done32 <= '1';
            wait until rising_edge(clkMem);
            sdram_done32 <= '0';
            for k in 1 to 3 loop wait until rising_edge(clkMem); end loop;
         else
            for k in 1 to 3 loop wait until rising_edge(clkMem); end loop;
            for j in 0 to 3 loop
               if (v_be(j) = '1') then
                  mem(w)(j*8 + 7 downto j*8) := v_din(j*8 + 7 downto j*8);
               end if;
            end loop;
            sdram_done32 <= '1';
            wait until rising_edge(clkMem);
            sdram_done32 <= '0';
            for k in 1 to 4 loop wait until rising_edge(clkMem); end loop;
         end if;
      elsif (refresh_cnt > 750) then
         for k in 1 to 6 loop
            wait until rising_edge(clkMem);
            assert sdram_ena = '0' report "sdram request during refresh slot" severity failure;
         end loop;
         refresh_cnt := 0;
         model_allow <= '1';
      end if;
   end process;

   -- ================= behavioral VRAM A..D server (from tb_vram_torture) =================
   pserver : process
      type t_bankmem is array (0 to 32767) of std_logic_vector(31 downto 0);
      type t_srvmem is array (0 to 3) of t_bankmem;
      variable mem : t_srvmem := (others => (others => (others => '0')));
      variable rs  : unsigned(31 downto 0) := to_unsigned(98765, 32);
      variable lat : integer;
      variable b   : integer;
      variable w   : integer;
   begin
      wait until rising_edge(clk1x) and srv_req = '1';
      rnd(rs);
      lat := 1 + to_integer(rs(2 downto 0));
      for k in 1 to lat loop
         wait until rising_edge(clk1x);
      end loop;
      b := to_integer(unsigned(srv_bank));
      w := to_integer(srv_addr);
      if (srv_rnw = '1') then
         srv_dout <= mem(b)(w);
      else
         for i in 0 to 3 loop
            if (srv_be(i) = '1') then
               mem(b)(w)(i*8 + 7 downto i*8) := srv_din(i*8 + 7 downto i*8);
            end if;
         end loop;
      end if;
      srv_done <= '1';
      wait until rising_edge(clk1x);
      srv_done <= '0';
   end process;

   -- ================= the testbench plays ARM9: SYNC echo + FIFO loopback =================
   p_arm9 : process
      variable echoed : std_logic_vector(3 downto 0) := x"0";
      variable v      : std_logic_vector(31 downto 0);

      procedure iowrite(a : std_logic_vector(27 downto 0); d : std_logic_vector(31 downto 0)) is
      begin
         bus9.Adr <= a; bus9.Din <= d; bus9.rnw <= '0'; bus9.bEna <= "1111"; bus9.ena <= '1';
         wait until rising_edge(clk1x);
         bus9.ena <= '0'; bus9.rnw <= '1';
      end procedure;

      procedure iopeek(a : std_logic_vector(27 downto 0); variable d : out std_logic_vector(31 downto 0)) is
      begin
         bus9.Adr <= a;
         wait until rising_edge(clk1x);
         d := ipc_wired_out9;
      end procedure;
   begin
      wait until reset = '0';
      wait until rising_edge(clk1x);
      iowrite(x"0000184", x"0000C008");     -- enable FIFO, clear send, ack error
      loop
         iopeek(x"0000180", v);             -- IPCSYNC: echo the ARM7 nibble back
         if (v(3 downto 0) /= echoed) then
            echoed := v(3 downto 0);
            iowrite(x"0000180", x"0000" & "0000" & echoed & x"00");
         end if;
         iopeek(x"0000184", v);             -- IPCFIFOCNT: recv empty?
         if (v(8) = '0') then
            bus9.Adr <= x"0100000"; bus9.rnw <= '1'; bus9.ena <= '1';
            wait until rising_edge(clk1x);
            v := ipc_wired_out9;            -- head sampled on the pop cycle
            bus9.ena <= '0';
            iowrite(x"0000188", std_logic_vector(unsigned(v) + 1));
         end if;
      end loop;
   end process;

   -- ================= mailbox snoop + verdict =================
   p_snoop : process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (mr7_ena = '1' and mr7_rnw = '0') then
            if (mr7_addr = std_logic_vector(to_unsigned(16#FFFC0#, 20))) then
               mailbox_bits <= mr7_writedata;
               report "island progress: bitmask=" & to_hstring(mr7_writedata) severity note;
            elsif (mr7_addr = std_logic_vector(to_unsigned(16#FFFC1#, 20))) then
               if (mr7_writedata = x"CAFEBABE") then
                  report "tb_arm7_island: PASS  bitmask=" & to_hstring(mailbox_bits) severity note;
                  tests_done <= true;
               else
                  report "tb_arm7_island: FAIL magic=" & to_hstring(mr7_writedata) &
                         " bitmask=" & to_hstring(mailbox_bits) severity failure;
               end if;
            end if;
         end if;
         assert error_cpu /= '1' report "gba_cpu error_cpu pulse (unsupported opcode?)" severity failure;
      end if;
   end process;

   -- first CPU bus transactions, for bring-up debugging (silent after 64 ops)
   p_debug : process (clk1x)
      variable n : integer := 0;
   begin
      if rising_edge(clk1x) then
         if (cpu_ena = '1' and n < 64) then
            report "cpu op " & integer'image(n) & ": adr=" & to_hstring(cpu_adr) &
                   " rnw=" & to_string(cpu_rnw) & " acc=" & to_string(cpu_acc) &
                   " dout=" & to_hstring(cpu_dout) severity note;
            n := n + 1;
         end if;
         if (cpu_done = '1' and n <= 64 and n > 0) then
            report "   done: din=" & to_hstring(cpu_din) severity note;
         end if;
      end if;
   end process;

   p_watchdog : process
   begin
      wait for TIMEOUT_MS * 1 ms;
      if not tests_done then
         report "tb_arm7_island: TIMEOUT  bitmask=" & to_hstring(mailbox_bits) severity failure;
      end if;
      wait;
   end process;

end architecture;
