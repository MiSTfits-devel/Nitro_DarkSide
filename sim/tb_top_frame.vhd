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
use work.pexport.all;
use work.pProc_bus_gba.all;

entity tb_top_frame is
   generic
   (
      HEXFILE    : string  := "sim/tests/nds_dual.hex";
      FWFILE     : string  := "sim/tests/nds_firmware.hex";  -- SPI firmware flash image (up to
                                         -- 256 KB; sim/tests/firmware_retail.hex, when present,
                                         -- is auto-preferred - same pattern as the retail BIOS)
      DUMPFILE   : string  := "top_frame_fb.txt";
      DUMPFILE_B : string  := "top_frame_fb_b.txt";
      DUMP_START_FRAME : integer := 0;    -- skip expensive text dumps before this frame
      CARD_WORDS : integer := 1048576;   -- 4 MB staging window
      GPUCEDIV   : integer := 3;         -- render clocks per dot (1 = full-rate video,
                                         -- ~110 dropped lines/frame with line server v1:
                                         -- pixels bad, but game pacing = real hardware)
      FRAMES     : integer := 3;
      TIMEOUT_MS : integer := 400;
      DIRECT     : integer := 0;         -- 1 = firmware direct-boot env (stock ROMs)
      DBG_T0     : integer := 0;         -- ARM9 pipeline debug window start/end in us (0 = off)
      DBG_T1     : integer := 0;
      DBG_TRIGPC : integer := 0;         -- alternative: trigger on decode_PC (dumps 256 cycles before, 768 after)
      TRACEFILE  : string  := "";        -- non-empty: ARM9 retired-instruction trace (TRACE_DIFF format)
      TRACEFILE7 : string  := "";        -- non-empty: ARM7 retired-instruction trace (same format)
      TRACE_START_FRAME  : integer := 0;  -- defer ARM9 trace until this dump-frame interval
      TRACE7_START_FRAME : integer := 0;  -- defer ARM7 trace until this dump-frame interval
      DUMP_STATE : integer := 0;          -- dump final raw VRAM/palette/OAM/register state
      MAXINSTR   : integer := 20000000;  -- trace line cap (per CPU)
      -- Card/firmware read latency injection. The donor models answer in one
      -- clk1x cycle, but on hardware both ports go through DDR3 (card = ddram
      -- ch2, firmware = ch1) at tens of variable cycles, contending with each
      -- other and the framebuffer. 0 keeps the original one-cycle behaviour so
      -- every existing gate is unchanged; >0 adds that many clk1x cycles plus
      -- 0..15 cycles of deterministic jitter before the done pulse.
      CARD_LAT   : integer := 0;
      FW_LAT     : integer := 0;
      -- Main-RAM (SDRAM) latency injection. The behavioral model answers every
      -- op in a fixed 6 (read) / 3 (write) clkMem cycles, which is both far
      -- faster and far more regular than the real ddram ch2 path. Every arbiter
      -- race in nds_mainram / nds_cache9 that needs a long, *variable* main-RAM
      -- op to open its window is therefore unreachable in simulation. >0 adds
      -- that many clkMem cycles plus 0..15 of jitter to each op.
      MEM_LAT    : integer := 0
   );
end entity;

architecture sim of tb_top_frame is

   constant MAINRAM_BASE : integer := 8388608;

   function itosl(i : integer) return std_logic is
   begin
      if (i /= 0) then return '1'; else return '0'; end if;
   end function;

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

   -- ================= SPI firmware flash store (256 KB) =================
   type t_fw is array (0 to 65535) of std_logic_vector(31 downto 0);
   impure function load_fw(fname : string) return t_fw is
      file f       : text;
      variable st  : file_open_status;
      variable l   : line;
      variable w   : std_logic_vector(31 downto 0);
      variable mem : t_fw := (others => (others => '0'));
      variable i   : integer := 0;
   begin
      -- retail image auto-preferred when present (gitignored, generated by
      -- sim/tests/make_retail_bios.sh) - same opt-in pattern as the BIOS ROMs
      file_open(st, f, "sim/tests/firmware_retail.hex", read_mode);
      if (st /= open_ok) then
         file_open(f, fname, read_mode);
      end if;
      while not endfile(f) and i < 65536 loop
         readline(f, l);
         hread(l, w);
         mem(i) := w;
         i := i + 1;
      end loop;
      file_close(f);
      if (st = open_ok) then
         report "loaded " & integer'image(i) & " firmware words (RETAIL image)" severity note;
      else
         report "loaded " & integer'image(i) & " firmware words from " & fname severity note;
      end if;
      return mem;
   end function;
   constant fwimg : t_fw := load_fw(FWFILE);

   signal fw_addr : unsigned(17 downto 2);
   signal fw_req  : std_logic;
   signal fw_done : std_logic := '0';
   signal fw_data : std_logic_vector(31 downto 0) := (others => '0');

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
   signal pixelb_out_x    : integer range 0 to 255;
   signal pixelb_out_y    : integer range 0 to 191;
   signal pixelb_out_data : std_logic_vector(17 downto 0);
   signal pixelb_out_we   : std_logic;
   signal vblank_out     : std_logic;

   signal dbg_line_drop, dbg_line_busy, dbg_cpu_err9, dbg_cpu_err7 : std_logic;
   signal dbg_export9_done : std_logic;
   signal dbg_export9      : cpu_export_type;
   signal dbg_export7_done : std_logic;
   signal dbg_export7      : cpu_export_type;
   signal dbg_pc9_s, dbg_irq_ie9_s, dbg_irq_if9_s : std_logic_vector(31 downto 0);
   signal dbg_irq_live9_s, dbg_irq_src9_s : std_logic_vector(31 downto 0);

   -- ================= collectors =================
   type t_frame is array (0 to 49151) of std_logic_vector(17 downto 0);
   signal framebuf   : t_frame := (others => (others => '0'));
   signal framebuf_b : t_frame := (others => (others => '0'));

   type t_shadow256 is array (0 to 255) of std_logic_vector(31 downto 0);
   type t_gpu_regs is array (0 to 21) of std_logic_vector(31 downto 0);
   signal pal_shadow, oam_shadow : t_shadow256 := (others => (others => '0'));
   signal gpu_regs_shadow : t_gpu_regs := (others => (others => '0'));

   -- VRAM banks A..D backing store (512 KB)
   type t_banks is array (0 to 131071) of std_logic_vector(31 downto 0);
   shared variable banks : t_banks := (others => (others => '0'));

   signal drops      : integer := 0;
   signal tests_done : boolean := false;
   -- Interval currently being rendered: 0 is the interval ending at dump
   -- frame 0.  This makes TRACE*_START_FRAME match melonds_fbdump, which
   -- enables its trace immediately before RunFrame(n).
   signal dump_frame_index : integer := -1;

begin

   -- Shadow CPU-visible engine-A state for late-frame differential dumps.
   -- These observe the same committed write strobes consumed by nds_gpu2d.
   p_state_shadow : process (clk1x)
      alias a_pal_we   is << signal .tb_top_frame.idut.pal_we_a : std_logic >>;
      alias a_pal_addr is << signal .tb_top_frame.idut.pal_addr_lo : integer range 0 to 255 >>;
      alias a_pal_din  is << signal .tb_top_frame.idut.pal_din : std_logic_vector(31 downto 0) >>;
      alias a_pal_be   is << signal .tb_top_frame.idut.pal_be : std_logic_vector(3 downto 0) >>;
      alias a_oam_we   is << signal .tb_top_frame.idut.oam_we_a : std_logic >>;
      alias a_oam_addr is << signal .tb_top_frame.idut.oam_addr_lo : integer range 0 to 255 >>;
      alias a_oam_din  is << signal .tb_top_frame.idut.oam_din : std_logic_vector(31 downto 0) >>;
      alias a_oam_be   is << signal .tb_top_frame.idut.oam_be : std_logic_vector(3 downto 0) >>;
      alias a_io       is << signal .tb_top_frame.idut.io_bus9 : proc_bus_gb_type >>;
      variable off : integer;
   begin
      if rising_edge(clk1x) then
         if (a_pal_we = '1') then
            for j in 0 to 3 loop
               if (a_pal_be(j) = '1') then
                  pal_shadow(a_pal_addr)(j*8 + 7 downto j*8) <= a_pal_din(j*8 + 7 downto j*8);
               end if;
            end loop;
         end if;
         if (a_oam_we = '1') then
            for j in 0 to 3 loop
               if (a_oam_be(j) = '1') then
                  oam_shadow(a_oam_addr)(j*8 + 7 downto j*8) <= a_oam_din(j*8 + 7 downto j*8);
               end if;
            end loop;
         end if;
         if (a_io.ena = '1' and a_io.rnw = '0') then
            off := to_integer(unsigned(a_io.Adr(11 downto 2)));
            if (off <= 21) then
               for j in 0 to 3 loop
                  if (a_io.bEna(j) = '1') then
                     gpu_regs_shadow(off)(j*8 + 7 downto j*8) <= a_io.Din(j*8 + 7 downto j*8);
                  end if;
               end loop;
            end if;
         end if;
      end if;
   end process;

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
      Softmap_NDS_MAINRAM_ADDR => MAINRAM_BASE,
      GPU_CE_DIV               => GPUCEDIV
   )
   port map
   (
      clk1x => clk1x, clkMem => clkMem, clkMemIndex => clkMemIndex,
      reset => reset, nds_on => '1',
      direct_boot => itosl(DIRECT),
      KeyA => '0', KeyB => '0', KeySelect => '0', KeyStart => '0',
      KeyRight => '0', KeyLeft => '0', KeyUp => '0', KeyDown => '0',
      KeyR => '0', KeyL => '0', KeyX => '0', KeyY => '0', lid_closed => '0',
      touch_active => '0', touch_x => x"00", touch_y => x"00",
      boot_done => boot_done, boot_error => boot_error,
      card_ena => card_ena, card_addr => card_addr,
      card_din => card_rdata, card_done => card_done,
      fw_addr => fw_addr, fw_req => fw_req, fw_done => fw_done, fw_data => fw_data,
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
      pixelb_out_x => pixelb_out_x, pixelb_out_y => pixelb_out_y,
      pixelb_out_data => pixelb_out_data, pixelb_out_we => pixelb_out_we,
      vblank_out => vblank_out,
      sound_out_left => open, sound_out_right => open,
      dbg_line_drop => dbg_line_drop, dbg_line_busy => dbg_line_busy,
      dbg_cpu_err9 => dbg_cpu_err9, dbg_cpu_err7 => dbg_cpu_err7,
      dbg_export9_done => dbg_export9_done, dbg_export9 => dbg_export9,
      dbg_export7_done => dbg_export7_done, dbg_export7 => dbg_export7,
      dbg_pc9 => dbg_pc9_s,
      dbg_r0_9 => dbg_irq_ie9_s, dbg_lr9 => dbg_irq_if9_s,
      dbg_cpsr9 => dbg_irq_live9_s, dbg_pc7 => dbg_irq_src9_s
   );

   -- SPI firmware flash image. FW_LAT = 0 keeps the original behaviour
   -- cycle-exactly: combinational data, done one cycle after the request.
   g_fw_fast : if FW_LAT = 0 generate
      fw_data <= fwimg(to_integer(fw_addr));
      process (clk1x)
      begin
         if rising_edge(clk1x) then
            fw_done <= fw_req;
         end if;
      end process;
   end generate;

   -- FW_LAT > 0 models the real ddram ch1 path instead: the word is captured at
   -- the request and only presented together with the done pulse, FW_LAT plus
   -- 0..15 cycles later. Note this also drops the combinational-data crutch -
   -- on hardware fw_data is a register that is only valid at fw_done, so any
   -- reliance on it tracking fw_addr shows up here. nds_spi holds SPI busy
   -- until fw_done, so a lost done pulse stalls ARM7 outright.
   g_fw_slow : if FW_LAT /= 0 generate
      process (clk1x)
         variable cnt  : integer := 0;
         variable pend : std_logic := '0';
         variable lfsr : unsigned(15 downto 0) := x"BEEF";
         variable hold : std_logic_vector(31 downto 0) := (others => '0');
      begin
         if rising_edge(clk1x) then
            fw_done <= '0';
            if (fw_req = '1') then
               hold := fwimg(to_integer(fw_addr));
               pend := '1';
               lfsr := lfsr(14 downto 0) &
                       (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
               cnt  := FW_LAT + to_integer(lfsr(3 downto 0));
            elsif (pend = '1') then
               if (cnt <= 0) then
                  pend    := '0';
                  fw_data <= hold;
                  fw_done <= '1';
               else
                  cnt := cnt - 1;
               end if;
            end if;
         end if;
      end process;
   end generate;

   -- ARM9 pipeline debug (same as tb_arm9_trace): per-cycle handshake dump
   -- into pipe_debug.log between DBG_T0 and DBG_T1 (microseconds)
   gdbg : if DBG_T1 > 0 or DBG_TRIGPC /= 0 generate
      pdbg : process (clk1x)
         file df : text open write_mode is "pipe_debug.log";
         variable l : line;
         alias a_fetch_PC     is << signal .tb_top_frame.idut.icpu9.fetch_PC       : unsigned(31 downto 0) >>;
         alias a_fetch_ready  is << signal .tb_top_frame.idut.icpu9.fetch_ready    : std_logic >>;
         alias a_fetch_done   is << signal .tb_top_frame.idut.icpu9.fetch_done     : std_logic >>;
         alias a_dec_ready    is << signal .tb_top_frame.idut.icpu9.decode_ready   : std_logic >>;
         alias a_dec_PC       is << signal .tb_top_frame.idut.icpu9.decode_PC      : unsigned(31 downto 0) >>;
         alias a_ex_branch    is << signal .tb_top_frame.idut.icpu9.execute_branch : std_logic >>;
         alias a_ex_done      is << signal .tb_top_frame.idut.icpu9.execute_done   : std_logic >>;
         alias a_ex_stall     is << signal .tb_top_frame.idut.icpu9.execute_stall  : std_logic >>;
         alias a_ex_now       is << signal .tb_top_frame.idut.icpu9.execute_now    : std_logic >>;
         alias a_bus_ena      is << signal .tb_top_frame.idut.icpu9.gb_bus_ena     : std_logic >>;
         alias a_bus_done     is << signal .tb_top_frame.idut.icpu9.gb_bus_done    : std_logic >>;
         alias a_bus_adr      is << signal .tb_top_frame.idut.icpu9.gb_bus_Adr     : std_logic_vector(31 downto 0) >>;
         alias a_bus_acc      is << signal .tb_top_frame.idut.icpu9.gb_bus_acc     : std_logic_vector(1 downto 0) >>;
         alias a_bus_din      is << signal .tb_top_frame.idut.icpu9.gb_bus_din     : std_logic_vector(31 downto 0) >>;
         alias a_branchPC     is << signal .tb_top_frame.idut.icpu9.execute_branchPC_masked : unsigned(31 downto 0) >>;
         alias a_nthumb       is << signal .tb_top_frame.idut.icpu9.execute_nextIsthumb : std_logic >>;
         alias a_thumb        is << signal .tb_top_frame.idut.icpu9.thumbmode      : std_logic >>;
         alias a_fdata        is << signal .tb_top_frame.idut.icpu9.fetch_data     : std_logic_vector(31 downto 0) >>;
         alias a_dma_on       is << signal .tb_top_frame.idut.icpu9.dma_on         : std_logic >>;
         type t_ring is array (0 to 255) of string(1 to 220);
         variable ring   : t_ring;
         variable rlen   : t_ring;  -- unused pad
         variable rl     : integer := 0;
         variable rfill  : integer := 0;
         variable fired  : boolean := false;
         variable post   : integer := 0;
         variable s      : string(1 to 220);
         variable slen   : integer;
      begin
         if rising_edge(clk1x) then
            if (DBG_T1 > 0 and now >= DBG_T0 * 1 us and now <= DBG_T1 * 1 us) or DBG_TRIGPC /= 0 then
               write(l, to_hstring(a_dec_PC) & " fPC=" & to_hstring(a_fetch_PC) &
                        " fdat=" & to_hstring(a_fdata) &
                        " fr=" & std_logic'image(a_fetch_ready)(2) &
                        " fd=" & std_logic'image(a_fetch_done)(2) &
                        " dr=" & std_logic'image(a_dec_ready)(2) &
                        " en=" & std_logic'image(a_ex_now)(2) &
                        " br=" & std_logic'image(a_ex_branch)(2) &
                        " ed=" & std_logic'image(a_ex_done)(2) &
                        " st=" & std_logic'image(a_ex_stall)(2) &
                        " be=" & std_logic'image(a_bus_ena)(2) &
                        " bd=" & std_logic'image(a_bus_done)(2) &
                        " ba=" & to_hstring(a_bus_adr) &
                        " ac=" & to_hstring(a_bus_acc) &
                        " bi=" & to_hstring(a_bus_din) &
                        " tgt=" & to_hstring(a_branchPC) &
                        " nt=" & std_logic'image(a_nthumb)(2) &
                        " tm=" & std_logic'image(a_thumb)(2) &
                        " dm=" & std_logic'image(a_dma_on)(2));
               if (DBG_TRIGPC = 0) then
                  writeline(df, l);
               elsif (not fired) then
                  -- ring-buffer until decode_PC hits the trigger
                  s := (others => ' ');
                  slen := l'length;
                  if slen > 220 then slen := 220; end if;
                  s(1 to slen) := l.all(1 to slen);
                  deallocate(l);
                  ring(rl) := s;
                  rl := (rl + 1) mod 256;
                  if rfill < 256 then rfill := rfill + 1; end if;
                  -- fire on the exception return into the window: a branch
                  -- whose target lands in [DBG_TRIGPC, +16) issued from ARM
                  -- mode (the IRQ handler's ldm^) - thumb-mode entries into
                  -- the same window (beq / bx r0) stay in the pre-ring
                  if (a_ex_branch = '1' and a_thumb = '0' and
                      a_branchPC >= to_unsigned(DBG_TRIGPC, 32) and
                      a_branchPC < to_unsigned(DBG_TRIGPC, 32) + 16) then
                     fired := true;
                     post  := 768;
                     for k in 0 to rfill - 1 loop
                        write(l, ring((rl + 256 - rfill + k) mod 256));
                        writeline(df, l);
                     end loop;
                  end if;
               elsif (post > 0) then
                  writeline(df, l);
                  post := post - 1;
                  if (post = 0) then
                     file_close(df);   -- force the capture to disk
                     report "PIPEDBG: trigger capture complete";
                  end if;
               else
                  deallocate(l);
               end if;
            end if;
         end if;
      end process;
   end generate;

   -- end-of-run video-state probe (VRAMCNT, engine B regs, VRAM bank fill)
   pprobe : process
      alias a_vramcnt is << signal .tb_top_frame.idut.vramcnt : std_logic_vector(71 downto 0) >>;
      alias a_bgmode  is << signal .tb_top_frame.idut.igpu2d_b.R_bgmode : std_logic_vector(2 downto 0) >>;
      alias a_fblank  is << signal .tb_top_frame.idut.igpu2d_b.R_forced_blank : std_logic_vector(7 downto 7) >>;
      variable nz : integer;
   begin
      wait until tests_done;
      report "PROBE vramcnt(A..I low->high)=" & to_hstring(a_vramcnt) &
             " engineB bgmode=" & to_hstring(a_bgmode) &
             " fblank=" & std_logic'image(a_fblank(7))(2);
      for b in 0 to 3 loop
         nz := 0;
         for i in 0 to 32767 loop
            if (banks(b*32768 + i) /= x"00000000") then nz := nz + 1; end if;
         end loop;
         report "PROBE vram bank " & integer'image(b) & " nonzero words (first 128KB): " & integer'image(nz);
      end loop;
      wait;
   end process;

   -- ================= ARM9 trace writer (TRACEFILE /= "") =================
   -- Same line format as tb_arm9_trace / melonds_tracer (docs/TRACE_DIFF.md):
   -- <pc> <opcode> <cpsr> <r0>..<r14>, one line per retired instruction.
   gtrace : if TRACEFILE'length > 0 generate
   begin
      p_trace : process
         file tf     : text;
         variable l  : line;
         variable n  : integer := 0;
      begin
         file_open(tf, TRACEFILE, write_mode);
         loop
            wait until rising_edge(clk1x);
            if (dbg_export9_done = '1' and dump_frame_index >= TRACE_START_FRAME) then
               write(l, to_hstring(dbg_export9.pc));
               write(l, ' ');
               write(l, to_hstring(dbg_export9.opcode));
               write(l, ' ');
               write(l, to_hstring(dbg_export9.CPSR));
               for i in 0 to 14 loop
                  write(l, ' ');
                  write(l, to_hstring(dbg_export9.regs(i)));
               end loop;
               writeline(tf, l);
               n := n + 1;
               if (n mod 500000 = 0) then
                  report "traced " & integer'image(n) & " instructions" severity note;
               end if;
               if (n >= MAXINSTR) then
                  report "tb_top_frame: trace cap reached, closing " & TRACEFILE severity note;
                  file_close(tf);
                  wait;
               end if;
            end if;
         end loop;
      end process;
   end generate;

   gtrace7 : if TRACEFILE7'length > 0 generate
   begin
      p_trace7 : process
         file tf     : text;
         variable l  : line;
         variable n  : integer := 0;
      begin
         file_open(tf, TRACEFILE7, write_mode);
         loop
            wait until rising_edge(clk1x);
            if (dbg_export7_done = '1' and dump_frame_index >= TRACE7_START_FRAME) then
               write(l, to_hstring(dbg_export7.pc));
               write(l, ' ');
               write(l, to_hstring(dbg_export7.opcode));
               write(l, ' ');
               write(l, to_hstring(dbg_export7.CPSR));
               for i in 0 to 14 loop
                  write(l, ' ');
                  write(l, to_hstring(dbg_export7.regs(i)));
               end loop;
               writeline(tf, l);
               n := n + 1;
               if (n >= MAXINSTR) then
                  report "tb_top_frame: ARM7 trace cap reached, closing " & TRACEFILE7 severity note;
                  file_close(tf);
                  wait;
               end if;
            end if;
         end loop;
      end process;
   end generate;

   g_state_dump : if DUMP_STATE /= 0 generate
   begin
      p_state_dump : process
         file fv : text open write_mode is "rtl_state_banks.hex";
         file fp : text open write_mode is "rtl_state_pal.hex";
         file fo : text open write_mode is "rtl_state_oam.hex";
         file fr : text open write_mode is "rtl_state_gpu_regs.hex";
         variable l : line;
         alias a_vramcnt is << signal .tb_top_frame.idut.vramcnt : std_logic_vector(71 downto 0) >>;
      begin
         wait until tests_done;
         for i in 0 to 131071 loop
            write(l, to_hstring(banks(i)));
            writeline(fv, l);
         end loop;
         for i in 0 to 255 loop
            write(l, to_hstring(pal_shadow(i)));
            writeline(fp, l);
            write(l, to_hstring(oam_shadow(i)));
            writeline(fo, l);
         end loop;
         for i in 0 to 21 loop
            write(l, to_hstring(gpu_regs_shadow(i)));
            writeline(fr, l);
         end loop;
         report "STATE vramcnt(A..I low->high)=" & to_hstring(a_vramcnt);
         file_close(fv); file_close(fp); file_close(fo); file_close(fr);
         wait;
      end process;
   end generate;

   -- ================= behavioral card =================
   p_card : process (clk1x)
      variable cnt    : integer := 0;
      variable pend   : std_logic := '0';
      variable lfsr   : unsigned(15 downto 0) := x"ACE1";
      variable warned : boolean := false;
   begin
      if rising_edge(clk1x) then
         card_done <= '0';
         if (card_ena = '1') then
            -- reads beyond the staged window return zero (real carts mirror,
            -- but nothing sane reads past its own ROM end). To the game this is
            -- indistinguishable from a core bug, so say so once: a truncated
            -- CARD_WORDS silently stalled every integrated Kirby run for days.
            if (to_integer(unsigned(card_addr)) < CARD_WORDS) then
               card_rdata <= card(to_integer(unsigned(card_addr)));
            else
               card_rdata <= (others => '0');
               if not warned then
                  warned := true;
                  report "tb_top_frame: CARD READ PAST STAGED WINDOW at word " &
                         to_hstring(card_addr) & " (CARD_WORDS=" &
                         integer'image(CARD_WORDS) & ") - returning zeros. " &
                         "Raise CARD_WORDS and use a full-size image."
                         severity warning;
               end if;
            end if;
            if (CARD_LAT = 0) then
               card_done <= '1';
            else
               pend := '1';
               lfsr := lfsr(14 downto 0) &
                       (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
               cnt  := CARD_LAT + to_integer(lfsr(3 downto 0));
            end if;
         elsif (pend = '1') then
            if (cnt <= 0) then
               pend      := '0';
               card_done <= '1';
            else
               cnt := cnt - 1;
            end if;
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
      variable lfsr  : unsigned(15 downto 0) := x"7A5C";
      variable extra : integer;
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

         if (MEM_LAT = 0) then
            extra := 0;
         else
            lfsr  := (lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10)));
            extra := MEM_LAT + to_integer(lfsr(3 downto 0));
         end if;
         for k in 1 to extra loop wait until rising_edge(clkMem); end loop;

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
         if (pixelb_out_we = '1') then
            framebuf_b(pixelb_out_y * 256 + pixelb_out_x) <= pixelb_out_data;
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
      file fdumpb  : text open write_mode is DUMPFILE_B;
      variable fdl : line;
      variable n   : integer := 0;
   begin
      wait until boot_done = '1';
      report "boot done, collecting " & integer'image(FRAMES) & " frames" severity note;

      -- skip the partial frame the cadence may be mid-way through
      wait until rising_edge(clk1x) and vblank_out = '1';
      dump_frame_index <= 0;

      while n < FRAMES loop
         wait until rising_edge(clk1x) and vblank_out = '1';
         -- let the last line's render/merge drain fully
         while dbg_line_busy = '1' loop
            wait until rising_edge(clk1x);
         end loop;
         for k in 1 to 100 loop wait until rising_edge(clk1x); end loop;
         if n >= DUMP_START_FRAME then
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
         end if;
         report "frame " & integer'image(n) & " dumped, drops so far " &
                integer'image(drops) severity note;
         report "irq9 frame=" & integer'image(n) &
                " pc=" & to_hstring(dbg_pc9_s) &
                " ie=" & to_hstring(dbg_irq_ie9_s) &
                " if=" & to_hstring(dbg_irq_if9_s) &
                " live=" & to_hstring(dbg_irq_live9_s) &
                " src=" & to_hstring(dbg_irq_src9_s) severity note;
         n := n + 1;
         dump_frame_index <= n;
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
