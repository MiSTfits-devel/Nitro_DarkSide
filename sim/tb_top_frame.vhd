-- M5 exit test: boot a .nds image through nds_top's HLE loader and dump the
-- engine-A frames the integrated render path produces.
--
-- nds_top carries the whole system now (dual CPUs, membuses, WRAM, main RAM,
-- IPC/IRQ/timers/syscnt, VRAM, gpu timing + gpu2d); this bench provides only
-- what nds_wrap will own on hardware: the staged card image, a behavioral
-- SDRAM for main RAM (from tb_mainram), behavioral stores for VRAM banks
-- A..D, and the frame collector.
--
-- Every visible frame after boot_done is dumped to DUMPFILE as "frame <n>"
-- followed by 49152 BGR666 hex lines (5 hex digits, B in [17:12]). The run stops
-- after FRAMES dumps. Compare against melonDS with sim/tests/compare_fb.py.
-- Run: sim/run_top_frame.sh <image.hex>  (heavy - remote pod only)

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.textio.all;

entity tb_top_frame is
   generic
   (
      HEXFILE    : string  := "sim/tests/nds_dual.hex";
      DUMPFILE   : string  := "top_frame_fb.txt";
      CARD_WORDS : integer := 1048576;   -- 4 MB staging window
      FRAMES     : integer := 3;
      TIMEOUT_MS : integer := 400
   );
end entity;

architecture sim of tb_top_frame is

   constant MAINRAM_BASE : integer := 8388608;

   signal clk1x       : std_logic := '0';
   signal clkMem      : std_logic := '0';
   signal clkMemIndex : unsigned(1 downto 0) := "10";
   signal reset       : std_logic := '1';

   -- ================= card store =================
   type t_card is array (0 to CARD_WORDS - 1) of std_logic_vector(31 downto 0);
   impure function load_hex(fname : string) return t_card is
      file f       : text;
      variable l   : line;
      variable w   : std_logic_vector(31 downto 0);
      variable mem : t_card := (others => (others => '0'));
      variable i   : integer := 0;
   begin
      file_open(f, fname, read_mode);
      while not endfile(f) and i < CARD_WORDS loop
         readline(f, l);
         hread(l, w);
         mem(i) := w;
         i := i + 1;
      end loop;
      file_close(f);
      report "loaded " & integer'image(i) & " card words from " & fname severity note;
      return mem;
   end function;
   constant card : t_card := load_hex(HEXFILE);

   signal card_ena, card_done : std_logic := '0';
   signal card_addr  : std_logic_vector(26 downto 2);
   signal card_rdata : std_logic_vector(31 downto 0) := (others => '0');

   -- ================= nds_top interface =================
   signal boot_done, boot_error : std_logic;

   signal mainram_active, mainram_busy : std_logic;
   signal model_allow : std_logic := '1';
   signal sdram_ena, sdram_rnw : std_logic := '0';
   signal sdram_Adr : std_logic_vector(26 downto 0);
   signal sdram_Din : std_logic_vector(31 downto 0);
   signal sdram_be  : std_logic_vector(3 downto 0);
   signal sdram_Dout : std_logic_vector(31 downto 0) := (others => '0');
   signal sdram_done32 : std_logic := '0';

   signal vsrv_req, vsrv_rnw, vsrv_done : std_logic := '0';
   signal vsrv_bank : std_logic_vector(1 downto 0);
   signal vsrv_addr : unsigned(16 downto 2);
   signal vsrv_be   : std_logic_vector(3 downto 0);
   signal vsrv_din, vsrv_dout : std_logic_vector(31 downto 0) := (others => '0');
   signal vrsrv_req, vrsrv_done : std_logic := '0';
   signal vrsrv_bank : std_logic_vector(1 downto 0);
   signal vrsrv_addr : unsigned(16 downto 2);
   signal vrsrv_dout : std_logic_vector(31 downto 0) := (others => '0');

   signal pixel_out_x    : integer range 0 to 255;
   signal pixel_out_y    : integer range 0 to 191;
   signal pixel_out_data : std_logic_vector(17 downto 0);
   signal pixel_out_we   : std_logic;
   signal vblank_out     : std_logic;

   signal dbg_line_drop, dbg_line_busy, dbg_cpu_err9, dbg_cpu_err7 : std_logic;

   -- ================= collectors =================
   type t_frame is array (0 to 49151) of std_logic_vector(17 downto 0);
   signal framebuf : t_frame := (others => (others => '0'));

   -- VRAM banks A..D backing store (512 KB)
   type t_banks is array (0 to 131071) of std_logic_vector(31 downto 0);
   shared variable banks : t_banks := (others => (others => '0'));

   signal drops      : integer := 0;
   signal tests_done : boolean := false;

begin

   -- ================= clocks (3 clkMem phases per clk1x, tb_dual_boot idiom) =================
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

   -- ================= DUT =================
   idut : entity work.nds_top
   generic map
   (
      is_simu                  => '1',
      Softmap_NDS_MAINRAM_ADDR => MAINRAM_BASE
   )
   port map
   (
      clk1x => clk1x, clkMem => clkMem, clkMemIndex => clkMemIndex,
      reset => reset, nds_on => '1',
      KeyA => '0', KeyB => '0', KeySelect => '0', KeyStart => '0',
      KeyRight => '0', KeyLeft => '0', KeyUp => '0', KeyDown => '0',
      KeyR => '0', KeyL => '0', KeyX => '0', KeyY => '0', lid_closed => '0',
      touch_active => '0', touch_x => x"00", touch_y => x"00",
      boot_done => boot_done, boot_error => boot_error,
      card_ena => card_ena, card_addr => card_addr,
      card_din => card_rdata, card_done => card_done,
      mainram_allow => model_allow, mainram_active => mainram_active, mainram_busy => mainram_busy,
      sdram_ena => sdram_ena, sdram_rnw => sdram_rnw, sdram_Adr => sdram_Adr,
      sdram_Din => sdram_Din, sdram_be => sdram_be,
      sdram_Dout => sdram_Dout, sdram_done32 => sdram_done32,
      vsrv_req => vsrv_req, vsrv_rnw => vsrv_rnw, vsrv_bank => vsrv_bank, vsrv_addr => vsrv_addr,
      vsrv_be => vsrv_be, vsrv_din => vsrv_din, vsrv_dout => vsrv_dout, vsrv_done => vsrv_done,
      vrsrv_req => vrsrv_req, vrsrv_bank => vrsrv_bank, vrsrv_addr => vrsrv_addr,
      vrsrv_dout => vrsrv_dout, vrsrv_done => vrsrv_done,
      pixel_out_x => pixel_out_x, pixel_out_y => pixel_out_y,
      pixel_out_data => pixel_out_data, pixel_out_we => pixel_out_we,
      pixel_out_engB => open, vblank_out => vblank_out,
      sound_out_left => open, sound_out_right => open,
      dbg_line_drop => dbg_line_drop, dbg_line_busy => dbg_line_busy,
      dbg_cpu_err9 => dbg_cpu_err9, dbg_cpu_err7 => dbg_cpu_err7
   );

   -- ================= behavioral card =================
   p_card : process (clk1x)
   begin
      if rising_edge(clk1x) then
         card_done <= '0';
         if (card_ena = '1') then
            card_rdata <= card(to_integer(unsigned(card_addr)));
            card_done  <= '1';
         end if;
      end if;
   end process;

   -- ================= behavioral SDRAM (from tb_mainram/tb_dual_boot) =================
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

   -- ================= behavioral VRAM A..D stores =================
   -- CPU channel (read/write) and renderer channel (read-only), each ~2-cycle
   pserv : process
      variable w : integer;
   begin
      wait until rising_edge(clk1x) and vsrv_req = '1';
      wait until rising_edge(clk1x);
      w := to_integer(unsigned(vsrv_bank)) * 32768 + to_integer(vsrv_addr);
      if (vsrv_rnw = '1') then
         vsrv_dout <= banks(w);
      else
         for j in 0 to 3 loop
            if (vsrv_be(j) = '1') then
               banks(w)(j*8 + 7 downto j*8) := vsrv_din(j*8 + 7 downto j*8);
            end if;
         end loop;
      end if;
      vsrv_done <= '1';
      wait until rising_edge(clk1x);
      vsrv_done <= '0';
   end process;

   prserv : process
   begin
      wait until rising_edge(clk1x) and vrsrv_req = '1';
      wait until rising_edge(clk1x);
      vrsrv_dout <= banks(to_integer(unsigned(vrsrv_bank)) * 32768 + to_integer(vrsrv_addr));
      vrsrv_done <= '1';
      wait until rising_edge(clk1x);
      vrsrv_done <= '0';
   end process;

   -- ================= collectors + monitors =================
   p_collect : process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (pixel_out_we = '1') then
            framebuf(pixel_out_y * 256 + pixel_out_x) <= pixel_out_data;
         end if;
      end if;
   end process;

   p_monitor : process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (dbg_line_drop = '1') then
            drops <= drops + 1;
            report "tb_top_frame: drawline dropped (render budget overrun)" severity warning;
         end if;
         assert dbg_cpu_err9 /= '1' report "nds_cpu9 error_cpu pulse" severity failure;
         assert dbg_cpu_err7 /= '1' report "gba_cpu error_cpu pulse" severity failure;
         assert boot_error /= '1' report "nds_loader flagged load_error" severity failure;
      end if;
   end process;

   -- ================= frame dump =================
   pmain : process
      file fdump   : text open write_mode is DUMPFILE;
      variable fdl : line;
      variable n   : integer := 0;
   begin
      wait until boot_done = '1';
      report "boot done, collecting " & integer'image(FRAMES) & " frames" severity note;

      -- skip the partial frame the cadence may be mid-way through
      wait until rising_edge(clk1x) and vblank_out = '1';

      while n < FRAMES loop
         wait until rising_edge(clk1x) and vblank_out = '1';
         -- let the last line's render/merge drain fully
         while dbg_line_busy = '1' loop
            wait until rising_edge(clk1x);
         end loop;
         for k in 1 to 100 loop wait until rising_edge(clk1x); end loop;
         write(fdl, string'("frame ") & integer'image(n));
         writeline(fdump, fdl);
         for i in 0 to 49151 loop
            write(fdl, to_hstring("00" & framebuf(i)));
            writeline(fdump, fdl);
         end loop;
         write(fdl, string'("frame ") & integer'image(n));
         writeline(fdumpb, fdl);
         for i in 0 to 49151 loop
            write(fdl, to_hstring("00" & framebuf_b(i)));
            writeline(fdumpb, fdl);
         end loop;
         report "frame " & integer'image(n) & " dumped, drops so far " &
                integer'image(drops) severity note;
         n := n + 1;
      end loop;

      report "tb_top_frame: DONE  " & integer'image(FRAMES) & " frames, " &
             integer'image(drops) & " dropped lines" severity note;
      tests_done <= true;
      wait;
   end process;

   p_watchdog : process
   begin
      wait for TIMEOUT_MS * 1 ms;
      if not tests_done then
         report "tb_top_frame: TIMEOUT" severity failure;
      end if;
      wait;
   end process;

end architecture;
