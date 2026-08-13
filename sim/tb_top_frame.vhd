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
      FRAMES     : integer := 3;
      TIMEOUT_MS : integer := 400;
      DIRECT     : integer := 0;         -- 1 = firmware direct-boot env (stock ROMs)
      -- 1 = FIRMWARE BOOT: no image staging, no env block, and the boot FSM leaves
      -- both PCs alone so the retail BIOSes run from their reset vectors. Requires
      -- FWFILE to be a real firmware image and BIOS9/BIOS7 to be the retail dumps.
      FWBOOT     : integer := 0;
      -- ms of DS time between p_heartbeat's two-PC progress lines (0 = off)
      HEARTBEAT_MS : integer := 0;
      -- 1 = count renderer VRAM arbiter ops per frame (p_vramops)
      VRAMOPS      : integer := 0;
      -- >0 with VRAMOPS: dump the per-line cost of the first 16 engine-A lines of
      -- that frame. The per-frame average cannot explain why the SAME three lines
      -- drop every frame while the mean sits at 62% of budget - only the
      -- distribution can, and this is it. Pick a steady-state frame, not 0 or 1.
      LINEPROF_FRAME : integer := -1;
      -- 1 = run both 2D engines on clkMem (3x). See rtl/nds_gpu2d_fast.vhd.
      GPUFAST      : integer := 0;
      -- 0 = compile nds_sound out (nds_top SOUND_ENABLE). Sim-side A/B for the
      -- area switch: a run with sound gated out must behave identically in
      -- everything that is not audio, and this is how that gets checked.
      SOUND        : integer := 1;
      -- A..D renderer read model (vrsrv_*). The default has been UNLIMITED
      -- IN-FLIGHT with a fixed 4-cycle pipe and vrsrv_ready never driven at all,
      -- which does not resemble the hardware: NDS.sv assigns
      --   vrsrv_ready_c = ~vr_busy & ~vr_fin
      -- so silicon allows exactly ONE A..D renderer read at a time, and the
      -- backpressure path was therefore never exercised in simulation. That
      -- matters a lot more since the drawers were pipelined, because they issue
      -- ~73% more requests per line (271 -> 469).
      --   VRSRV_LAT : response latency in clk1x cycles
      --   VRSRV_ONE : 1 = model hardware, ready low from acceptance until done
      VRSRV_LAT    : integer := 4;
      VRSRV_ONE    : integer := 0;
      --   VRSRV_OUT : max ops outstanding (0 = unlimited). NDS.sv now allows 2,
      --               which is what sdram.sv's ch1 can hold: one awaiting grant
      --               plus one in service.
      --   VRSRV_GAP : minimum clk1x cycles between accepts. The controller's ch1
      --               slot is 8 clkMem cycles (grant, WAIT, RW1, IDLE_5..IDLE),
      --               which at 3x is 2.67 clk1x - modelled as 3, so this bench
      --               is slightly PESSIMISTIC about the real throughput rather
      --               than flattering it.
      VRSRV_OUT    : integer := 0;
      VRSRV_GAP    : integer := 0;
      ISLAND     : integer := 1;         -- 0 = tie clk2x to clk1x, i.e. no ARM9 island
      -- clk2x half period in ps. 7500 = 66.67 MHz, the 2:1-with-coincident-edges
      -- relationship the hardware PLL currently produces because the island
      -- SHARES the 67.028 MHz video clock (NDS.sv: `assign CLK_VIDEO =
      -- clk_video_67`) rather than because the ARM9 needs 67 MHz. Raising this
      -- models giving the island its own slower PLL output, which is the only
      -- lever that closes clk2x timing without restructuring nds_cpu9 - at the
      -- cost of breaking the exact 2:1 the clk1x<->clk2x handshakes have only
      -- ever run at. That is what this generic exists to test.
      ISLAND_HALF_PS : integer := 7500;
                                         -- (nds_top.vhd:67). The island is what fails
                                         -- 67 MHz timing by -7.6 ns, so a 0 build is the
                                         -- only deployable one; this switch is how to ask
                                         -- whether it still needs the island to boot.
      DBG_T0     : integer := 0;         -- ARM9 pipeline debug window start/end in us (0 = off)
      DBG_T1     : integer := 0;
      DBG_TRIGPC : integer := 0;         -- alternative: trigger on decode_PC (dumps 256 cycles before, 768 after)
      TRACEFILE  : string  := "";        -- non-empty: ARM9 retired-instruction trace (TRACE_DIFF format)
      TRACEFILE7 : string  := "";        -- non-empty: ARM7 retired-instruction trace (same format)
      TRACE_START_FRAME  : integer := 0;  -- defer ARM9 trace until this dump-frame interval
      TRACE7_START_FRAME : integer := 0;  -- defer ARM7 trace until this dump-frame interval
      -- Time-gated ARM7 trace window, in us. TRACE7_T1 > 0 enables it and
      -- REPLACES the dump-frame gate above. Firmware boot needs a time gate:
      -- dump_frame_index only advances once the display is running, and the
      -- fault worth tracing is at 1.588 s with POWCNT1 not initialised until
      -- 1.49 s, so a frame-gated trace comes out empty or starts in the wrong
      -- place. Lines are flushed as they are written and the file is closed at
      -- T1, so the trace survives the fatal decode assertion in gba_cpu - an
      -- unflushed trace of the instructions leading to a crash is worth nothing.
      TRACE7_T0  : integer := 0;
      TRACE7_T1  : integer := 0;
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
      MEM_LAT    : integer := 0;
      -- >0: print a cumulative ARM9 memory-path cycle histogram every N clk1x
      CYCLE_HIST : integer := 0;
      -- /=0: stage the ARM9/ARM7 main-RAM sections directly into the SDRAM model
      -- and let nds_loader skip copying them. Same end state, ~70 ms of simulated
      -- time cheaper per boot. See preload_main below.
      PRELOAD    : integer := 0;
      -- >0: fail with a full dump if ONE engine-A line render stays busy this
      -- many clk1x cycles. A line is 2,130 cycles at the 1-of-1 dot pace, so a few
      -- thousand is over budget and tens of thousands is a wedge - and the two
      -- are indistinguishable in the frame output, which is what made the
      -- renderer's backpressure failure so hard to place. Reaches into the
      -- GPU_FAST=0 pass-through branch, so use it with GPUFAST=0 only; the
      -- generate guard keeps every other run from elaborating those names.
      STALL_CYC  : integer := 0;
      -- /=0: ARM7 firmware-boot instruments (built for the ldm^ context-restore
      -- hunt, root cause in 96a52c7). Both are trace-free on purpose: the fault
      -- surfaced at 1.588 s,
      -- ~30M ARM7 instructions, and TRACEFILE costs ~40x, so the answers have to
      -- come out of counters and a write watch rather than out of a trace.
      --   * IRQ census - every ARM7 source's pulse count plus each delivery.
      --     "Which IRQ source asserts here and not in melonDS" needs exactly
      --     this: loopdiff.py compares control flow and cannot tell an IRQ at a
      --     different time from an IRQ that should never have fired.
      --   * ARM7 WRAM write watch on the faulting word, so "the bytes simply
      --     differ" becomes "this store, at this time, from this PC, put them
      --     there" - or nothing ever wrote it, which is just as decisive.
      ARM7DBG    : integer := 0;
      -- byte address to watch, ARM7-visible. 0x0380E28C is the faulting
      -- 0x037FE28C reached through the ARM7-WRAM 64 KB mirror: nds_membus7 masks
      -- both with 0xFFFF (w7p_addr <= cpu_adr(15 downto 2)), exactly as melonDS
      -- does, so the two addresses are the same storage.
      ARM7WATCH  : integer := 16#0380E28C#;
      -- /=0: catch the ARM7 PC RUNNING AWAY, and print the instructions that led
      -- to it. Nothing legitimately executes at or above 0x04000000 on the ARM7 -
      -- that is the I/O region - so the first retire there is unambiguous
      -- corruption, and it reads as 0x00000000 = `andeq r0,r0,r0`, which decodes
      -- happily. So a derailed ARM7 does not crash: it marches +4 through the
      -- address space, 16384 instructions per 64 KB, until it finally lands on a
      -- word that will not decode, thousands of instructions and hundreds of
      -- milliseconds later, in code that has nothing to do with the bug.
      --
      -- That is what the 1.588 s "unhandled opcode 1C0E1C05" fault is: by 1.55 s
      -- the ARM7 was already walking 0x0439xxxx..0x0483xxxx. This trigger fires at
      -- the moment of departure instead, which no trace window can be aimed at
      -- without knowing the answer first.
      ARM7RUNAWAY : integer := 0
   );
end entity;

architecture sim of tb_top_frame is

   constant MAINRAM_BASE : integer := 8388608;

   function itosl(i : integer) return std_logic is
   begin
      if (i /= 0) then return '1'; else return '0'; end if;
   end function;

   signal clk1x       : std_logic := '0';
   signal clk2x       : std_logic := '0';
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

   -- ================= main-RAM backing store (+ optional preload) =================
   -- PRELOAD/=0 stages the ARM9 and ARM7 sections straight into the SDRAM model
   -- and lets nds_loader skip its copy passes (nds_top's skip_copy generic). The
   -- end state is identical - same words at the same addresses - but it removes
   -- ~443k word copies, about 70 ms of simulated time, from the front of every
   -- boot-length run. Steady-state memory timing is untouched, so a ratio or CPI
   -- number measured with PRELOAD=1 is still comparable to one measured without.
   -- Only main-RAM sections are staged; a WRAM7 section is left to the loader.
   type t_mem is array (0 to 1048575) of std_logic_vector(31 downto 0);
   impure function preload_main(c : t_card) return t_mem is
      variable m    : t_mem := (others => (others => '0'));
      variable off  : integer;
      variable ram  : integer;
      variable sz   : integer;
      variable base : integer;
      variable n    : integer := 0;
   begin
      if (PRELOAD = 0) then
         return m;
      end if;
      -- .nds header: word 8 = byte 0x20. Per CPU: rom offset, entry, ram addr, size.
      for cpu in 0 to 1 loop
         off := to_integer(unsigned(c(8 + cpu*4 + 0)));
         ram := to_integer(unsigned(c(8 + cpu*4 + 2)));
         sz  := to_integer(unsigned(c(8 + cpu*4 + 3)));
         if (ram >= 16#02000000# and ram < 16#02400000#) then
            base := (ram - 16#02000000#) / 4;
            for i in 0 to (sz + 3) / 4 - 1 loop
               if (base + i <= 1048575 and off / 4 + i < CARD_WORDS) then
                  m(base + i) := c(off / 4 + i);
                  n := n + 1;
               end if;
            end loop;
            report "preload: cpu" & integer'image(cpu) & " " & integer'image(sz) &
                   " bytes from rom 0x" & integer'image(off) & " to 0x" &
                   integer'image(ram) severity note;
         else
            report "preload: cpu" & integer'image(cpu) &
                   " target is not main RAM - left to the loader" severity note;
         end if;
      end loop;
      report "preload: staged " & integer'image(n) & " words into main RAM" severity note;
      return m;
   end function;
   shared variable mainram : t_mem := preload_main(card);

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
   -- Pair fills. These MUST be driven: nds_mainram will not retire a pair read
   -- on done32 alone, so leaving them at the nds_top port defaults ('0') wedges
   -- the main-RAM channel on the ARM9's first cache line fill - and because the
   -- ARM7 shares that channel, both CPUs stop. That is what it looked like:
   -- 35 ARM9 instructions retired, then nothing, forever.
   signal sdram_Dout_hi : std_logic_vector(31 downto 0) := (others => '0');
   signal sdram_done64  : std_logic := '0';

   signal vsrv_req, vsrv_rnw, vsrv_done : std_logic := '0';
   signal vsrv_bank : std_logic_vector(1 downto 0);
   signal vsrv_addr : unsigned(16 downto 2);
   signal vsrv_be   : std_logic_vector(3 downto 0);
   signal vsrv_din, vsrv_dout : std_logic_vector(31 downto 0) := (others => '0');
   signal vrsrv_req, vrsrv_done : std_logic := '0';
   signal vrsrv_bank : std_logic_vector(1 downto 0);
   signal vrsrv_addr : unsigned(16 downto 3);
   signal vrsrv_dout : std_logic_vector(63 downto 0) := (others => '0');

   -- in-order response delay line for the pipelined A..D model (see prserv)
   type t_vrsrvpipe is record
      v : std_logic;
      d : std_logic_vector(63 downto 0);
   end record;
   type t_vrsrvpipe_arr is array (0 to VRSRV_LAT - 1) of t_vrsrvpipe;
   signal vrsrvpipe : t_vrsrvpipe_arr := (others => ('0', (others => '0')));
   -- hardware-shaped backpressure. VRSRV_ONE is the old one-in-flight model,
   -- kept so existing measurements stay reproducible; VRSRV_OUT/VRSRV_GAP model
   -- the pipelined channel NDS.sv presents now.
   signal vrsrv_busy_m  : std_logic := '0';
   signal vrsrv_out_m   : integer range 0 to 15 := 0;
   signal vrsrv_gap_m   : integer range 0 to 15 := 0;
   signal vrsrv_ready_s : std_logic;
   -- protocol checker: a request this model did not take must still be on the
   -- wire, unchanged, at the next edge (valid/ready). A requester that pulses
   -- and forgets fails here instead of silently losing the word.
   signal vrsrv_held      : std_logic := '0';
   signal vrsrv_held_bank : std_logic_vector(1 downto 0) := "00";
   signal vrsrv_held_addr : unsigned(16 downto 3) := (others => '0');
   -- 64-bit-line hit-rate probe (VRAMOPS /= 0). sdram.sv's ch1 already returns
   -- FOUR halfwords per read (BURST_LENGTH=4, ACCESS_TYPE sequential, so the
   -- aligned 8-byte block containing the request) and NDS.sv uses 32 bits of it.
   -- This measures what a line cache of each size WOULD have saved before any of
   -- it is built: eight renderer channels interleave, so a one-line cache would
   -- thrash, and the fitter has no room for a guess.
   constant NPROBE : integer := 5;
   type t_probe_sizes is array (0 to NPROBE-1) of integer;
   constant PROBE_SIZES : t_probe_sizes := (1, 2, 4, 8, 16);

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
   signal dbg_line_drop_a, dbg_line_drop_b : std_logic;
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
   signal drops_a    : integer := 0;
   signal drops_b    : integer := 0;
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

   -- clk2x: exactly 2x clk1x with COINCIDENT rising edges, matching the PLL on
   -- hardware (outclk_1 = 2 x outclk_2, same VCO, 0 ps). clk1x rises at 5 ns and
   -- every 30 ns after (3 clkMem phases of 10 ns), so clk2x rises at 5 ns and
   -- every 15 ns. Not derivable from clkMem: 2x clk1x is 2/3 of clkMem.
   gisland : if ISLAND /= 0 generate
      p_clk2x : process
      begin
         clk2x <= '0';
         wait for 5 ns;
         while not tests_done loop
            clk2x <= '1';
            wait for ISLAND_HALF_PS * 1 ps;
            clk2x <= '0';
            wait for ISLAND_HALF_PS * 1 ps;
         end loop;
         clk2x <= '0';
         wait;
      end process;
   end generate;

   -- ISLAND=0: the ARM9 runs at clk1x like everything else. Everything that
   -- crosses the bridge still works, it just crosses within one domain.
   --
   -- This MUST NOT be written `clk2x <= clk1x`. clk1x is itself a signal driven
   -- from the clkMem process below, so a concurrent copy puts clk2x one DELTA
   -- CYCLE behind it, and that delta is not a harmless modelling detail - it
   -- inverts the behaviour of every clk1x->clk2x edge detector in nds_top:
   --
   --   delta 1: clk1x rises, the clk1x process schedules the new cdc_io_cpl
   --   delta 2: cdc_io_cpl becomes new AND clk2x rises, so the clk2x process
   --            samples the ALREADY-UPDATED value
   --
   -- so cdc_io_cpl_d tracks cdc_io_cpl exactly and i9_io_done can never pulse.
   -- membus9 then parks in W_IO_RESP on its first IO access: Kirby retires ONE
   -- ARM9 instruction, bootreq gets 90 accepts and reports pass=0. On hardware,
   -- clk2x tied to clk1x is one net, both flops see the same edge, and the
   -- detector works - so that stall was an artifact of this line, and the
   -- 2026-07-26 handoff's "there is no timing-clean fallback, ISLAND=0 does not
   -- work" conclusion was built on it.
   --
   -- Driving clk2x from the same clkMem edge and the same clkMemIndex as clk1x
   -- puts both updates in the same delta, which is what one shared net does.
   gnoisland : if ISLAND = 0 generate
      process (clkMem)
      begin
         if rising_edge(clkMem) then
            if (clkMemIndex = 2) then clk2x <= '1'; end if;
            if (clkMemIndex = 0) then clk2x <= '0'; end if;
         end if;
      end process;
   end generate;

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
      GPU_FAST                 => GPUFAST,
      SOUND_ENABLE             => SOUND,
      skip_copy                => itosl(PRELOAD)
   )
   port map
   (
      clk1x => clk1x, clk2x => clk2x, clkMem => clkMem, clkMemIndex => clkMemIndex,
      reset => reset, nds_on => '1',
      direct_boot => itosl(DIRECT),
      fw_boot     => itosl(FWBOOT),
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
      sdram_Dout_hi => sdram_Dout_hi, sdram_done64 => sdram_done64,
      vsrv_req => vsrv_req, vsrv_rnw => vsrv_rnw, vsrv_bank => vsrv_bank, vsrv_addr => vsrv_addr,
      vsrv_be => vsrv_be, vsrv_din => vsrv_din, vsrv_dout => vsrv_dout, vsrv_done => vsrv_done,
      vrsrv_req => vrsrv_req, vrsrv_bank => vrsrv_bank, vrsrv_addr => vrsrv_addr,
      vrsrv_dout => vrsrv_dout, vrsrv_done => vrsrv_done,
      vrsrv_ready => vrsrv_ready_s,
      pixel_out_x => pixel_out_x, pixel_out_y => pixel_out_y,
      pixel_out_data => pixel_out_data, pixel_out_we => pixel_out_we,
      pixelb_out_x => pixelb_out_x, pixelb_out_y => pixelb_out_y,
      pixelb_out_data => pixelb_out_data, pixelb_out_we => pixelb_out_we,
      vblank_out => vblank_out,
      sound_out_left => open, sound_out_right => open,
      dbg_line_drop => dbg_line_drop, dbg_line_busy => dbg_line_busy,
      dbg_line_drop_a => dbg_line_drop_a, dbg_line_drop_b => dbg_line_drop_b,
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
      alias a_bgmode  is << signal .tb_top_frame.idut.igpu2d_b.dbg_bgmode : std_logic_vector(2 downto 0) >>;
      alias a_fblank  is << signal .tb_top_frame.idut.igpu2d_b.dbg_fblank : std_logic >>;
      variable nz : integer;
   begin
      wait until tests_done;
      report "PROBE vramcnt(A..I low->high)=" & to_hstring(a_vramcnt) &
             " engineB bgmode=" & to_hstring(a_bgmode) &
             " fblank=" & std_logic'image(a_fblank)(2);
      for b in 0 to 3 loop
         nz := 0;
         for i in 0 to 32767 loop
            if (banks(b*32768 + i) /= x"00000000") then nz := nz + 1; end if;
         end loop;
         report "PROBE vram bank " & integer'image(b) & " nonzero words (first 128KB): " & integer'image(nz);
      end loop;
      wait;
   end process;

   -- ============ ARM9 memory-path cycle histogram (CYCLE_HIST /= 0) ============
   -- Where do the ARM9's cycles actually go? Measured CPI is 2.65 against the
   -- ARM7's 1.12, and guessing at which subsystem burns them has cost several
   -- build rounds. This counts clk1x cycles per nds_cache9 state (and the
   -- membus9 state) straight off nds_top's dbg_probe word, using the same
   -- external-name trick as the palette/OAM taps above - so it is sim-only and
   -- needs no RTL change. Prints a running cumulative table; the last one wins.
   gcycles : if CYCLE_HIST /= 0 generate
   begin
      process
         alias a_probe is << signal .tb_top_frame.idut.dbg_probe : std_logic_vector(31 downto 0) >>;
         type t_hist is array (0 to 15) of natural;
         variable ch, mh  : t_hist := (others => 0);
         variable n       : natural := 0;
         constant CNAME : string := "IDLE      REQ_LOOKUPOP_LOOKUP HIT_RESP  BYPASS_ISSBYPASS_WAIWB_PREP   WB_BEAT   WB_WAIT   FILL_BEAT FILL_WAIT OP_FINISH ";
         -- JOINT counters. Counting the two FSMs independently produced the
         -- headline anomaly of the last round - membus9 in W_MAIN 78% of cycles
         -- while cache9 was busy only 37%, i.e. ~41% of all cycles apparently
         -- spent waiting on an idle cache. Independent histograms cannot tell
         -- "the cache already answered and membus9 has not moved yet" from
         -- "the request was never issued", because they never sample the same
         -- cycle. jc(s) does: for membus9 state s, how many of those cycles had
         -- cache9 IDLE. wm_* then splits the W_MAIN+IDLE cell by cresp_done
         -- (probe bit 13), which is exactly the term W_MAIN waits on:
         --   cresp_done=1 -> handoff latency (cache done, membus still parked)
         --   cresp_done=0 -> the request is not in flight anywhere: a real hole
         variable jc      : t_hist := (others => 0);
         variable wm_done, wm_stuck : natural := 0;
         variable wm_ena  : natural := 0;
         -- "the ARM9 issued nothing at all" diagnostics. A membus9 that never
         -- leaves IDLE means the CPU never presented a request, which is a
         -- different failure from a slow CPU and is invisible in the state
         -- histograms. These count the three things that can hold the core off
         -- the bus: reset, the debug-mailbox halt, and the DMA stealing the
         -- membus (mbus_ena is muxed to the DMA whenever dma_bus_on is high).
         alias a_rstcpu is << signal .tb_top_frame.idut.resetCpu  : std_logic >>;
         alias a_hold9  is << signal .tb_top_frame.idut.dbg_hold9 : std_logic >>;
         variable n_rst, n_hold, n_dmaon, n_cpuena : natural := 0;
         -- Where the boot FSM stalls, if it does. resetCpu is only released in
         -- B_RUN, and two states before it are terminal traps: B_RESET spins until
         -- nds_on, and B_ERROR is entered on ld_error and never left - both leave
         -- resetCpu asserted forever, which is indistinguishable from "the ARM9 is
         -- slow" in every other counter here.
         alias a_ndson  is << signal .tb_top_frame.idut.nds_on   : std_logic >>;
         alias a_ldbusy is << signal .tb_top_frame.idut.ld_busy  : std_logic >>;
         alias a_lddone is << signal .tb_top_frame.idut.ld_done  : std_logic >>;
         alias a_lderr  is << signal .tb_top_frame.idut.ld_error : std_logic >>;
         variable n_on, n_ldb, n_ldd, n_lde : natural := 0;
         -- Where do the ~11.5 cycles of a bypass access actually go? BYPASS_WAIT
         -- is the single largest ARM9 cost once the PU is on, and the choice of
         -- fix depends entirely on the split: cycles with mr9_ena/mr9_done low and
         -- mem9_ena low are pure clk1x<->clk2x bridge latency (fix the bridge),
         -- cycles with mem9_ena high are nds_mainram actually working (fix the
         -- memory path or post the writes instead of stalling on them).
         variable bw_tot, bw_mr_ena, bw_mem_ena, bw_mem_done, bw_idle : natural := 0;
         -- Global main-RAM occupancy, split by which CPU it is serving, plus a
         -- count of ops (MR_IDLE -> busy transitions). Divided by each CPU's
         -- retired-instruction count from the traces this says whether the ARM7's
         -- uncached fetch stream is issuing about one op per instruction (expected,
         -- ARM7TDMI has no cache) or several (a fetch inefficiency worth fixing).
         -- This is the term that decides the next optimisation: main RAM is busy
         -- 70% of the ARM9's stall, so the path is bandwidth-bound, not latency-
         -- bound, and only less traffic or more throughput helps.
         variable mr_busy7, mr_busy9, mr_ops7, mr_ops9 : natural := 0;
         variable mr_prev_busy : std_logic := '0';
      begin
         loop
            -- island clock: cache9 and membus9 moved to clk2x with the ARM9
            wait until rising_edge(clk2x);
            ch(to_integer(unsigned(a_probe(3 downto 0))))  := ch(to_integer(unsigned(a_probe(3 downto 0)))) + 1;
            mh(to_integer(unsigned(a_probe(10 downto 8)))) := mh(to_integer(unsigned(a_probe(10 downto 8)))) + 1;
            if (a_probe(3 downto 0) = "0000") then
               jc(to_integer(unsigned(a_probe(10 downto 8)))) :=
                  jc(to_integer(unsigned(a_probe(10 downto 8)))) + 1;
               -- W_MAIN is membus9 state 4
               if (a_probe(10 downto 8) = "100") then
                  if (a_probe(13) = '1') then wm_done  := wm_done  + 1;
                  else                        wm_stuck := wm_stuck + 1;
                  end if;
                  -- mem9_ena (probe bit 27): is a main-RAM op live on the
                  -- clk1x side while both island FSMs look idle? That is the
                  -- signature of the bridge, not of either FSM.
                  if (a_probe(27) = '1') then wm_ena := wm_ena + 1; end if;
               end if;
            end if;
            if (a_rstcpu     = '1') then n_rst    := n_rst    + 1; end if;
            if (a_hold9      = '1') then n_hold   := n_hold   + 1; end if;
            if (a_probe(31)  = '1') then n_dmaon  := n_dmaon  + 1; end if;
            if (a_probe(24)  = '1') then n_cpuena := n_cpuena + 1; end if;
            if (a_ndson      = '1') then n_on  := n_on  + 1; end if;
            if (a_ldbusy     = '1') then n_ldb := n_ldb + 1; end if;
            if (a_lddone     = '1') then n_ldd := n_ldd + 1; end if;
            if (a_lderr      = '1') then n_lde := n_lde + 1; end if;
            -- cache9 BYPASS_WAIT is state code 5 in the low nibble. Split by what
            -- nds_mainram is doing on the same edge: probe(17:16) is its state
            -- (MR_IDLE=0) and probe(19) is req9_pending. mem9_ena/mem9_done are
            -- pulses, so counting "neither asserted" wrongly folds the SDRAM's own
            -- latency into the bridge's - the mainram FSM state does not.
            if (a_probe(3 downto 0) = "0101") then
               bw_tot := bw_tot + 1;
               if (a_probe(17 downto 16) /= "00") then
                  bw_mem_ena := bw_mem_ena + 1;         -- mainram actually working
               elsif (a_probe(19) = '1') then
                  bw_mem_done := bw_mem_done + 1;       -- latched, awaiting arbitration
               else
                  bw_idle := bw_idle + 1;               -- mainram idle: bridge/protocol
               end if;
               if (a_probe(21) = '1') then bw_mr_ena := bw_mr_ena + 1; end if;  -- serving7
            end if;
            if (a_probe(17 downto 16) /= "00") then
               if (a_probe(21) = '1') then mr_busy7 := mr_busy7 + 1;
               else                        mr_busy9 := mr_busy9 + 1;
               end if;
               if (mr_prev_busy = '0') then
                  if (a_probe(21) = '1') then mr_ops7 := mr_ops7 + 1;
                  else                        mr_ops9 := mr_ops9 + 1;
                  end if;
               end if;
               mr_prev_busy := '1';
            else
               mr_prev_busy := '0';
            end if;
            n := n + 1;
            if (n mod CYCLE_HIST = 0) then
               report "=== ARM9 memory-path cycles after " & integer'image(n) & " clk1x ===";
               for s in 0 to 11 loop
                  if (ch(s) /= 0) then
                     report "  cache9 " & CNAME(s*10 + 1 to s*10 + 10) & " " &
                            integer'image(ch(s)) & "  (" &
                            integer'image(integer(real(ch(s)) * 100.0 / real(n))) & "%)";
                  end if;
               end loop;
               for s in 0 to 5 loop
                  if (mh(s) /= 0) then
                     report "  membus9 state " & integer'image(s) & ": " &
                            integer'image(mh(s)) & "  (" &
                            integer'image(integer(real(mh(s)) * 100.0 / real(n))) & "%)" &
                            "  of which cache9 IDLE: " & integer'image(jc(s)) &
                            "  (" & integer'image(integer(real(jc(s)) * 100.0 / real(n))) & "% of all)";
                  end if;
               end loop;
               report "  W_MAIN & cache9 IDLE split: cresp_done=1 (handoff) " &
                      integer'image(wm_done) & "  cresp_done=0 (not in flight) " &
                      integer'image(wm_stuck) & "  mem9_ena=1 (bridge in flight) " &
                      integer'image(wm_ena);
               report "  ARM9 off-bus holds: resetCpu " & integer'image(n_rst) &
                      "  dbg_hold9 " & integer'image(n_hold) &
                      "  dma_bus_on " & integer'image(n_dmaon) &
                      "  cpu9_ena " & integer'image(n_cpuena) &
                      "   (of " & integer'image(n) & " cycles)";
               report "  boot: nds_on " & integer'image(n_on) &
                      "  ld_busy " & integer'image(n_ldb) &
                      "  ld_done " & integer'image(n_ldd) &
                      "  ld_error " & integer'image(n_lde);
               report "  BYPASS_WAIT split: total " & integer'image(bw_tot) &
                      "  mainram-working " & integer'image(bw_mem_ena) &
                      "  latched-awaiting-arb " & integer'image(bw_mem_done) &
                      "  mainram-IDLE(bridge/protocol) " & integer'image(bw_idle) &
                      "  [serving7 " & integer'image(bw_mr_ena) & "]";
               report "  mainram occupancy: arm7 " & integer'image(mr_busy7) &
                      " cyc / " & integer'image(mr_ops7) & " ops   arm9 " &
                      integer'image(mr_busy9) & " cyc / " & integer'image(mr_ops9) &
                      " ops   (idle " & integer'image(n - mr_busy7 - mr_busy9) & ")";
            end if;
         end loop;
      end process;
   end generate;

   -- ================= IPC FIFO watch =================
   -- Kirby freezes with the ARM9 asleep in the NitroSDK idle thread: IE9 enables
   -- VBlank + IPC-recv, IF9 bit 18 NEVER latches, and IF7 bit 18 DOES. So the
   -- ARM7 receives from the ARM9 and never sends back, and the ARM9's main thread
   -- never becomes runnable. The IPC RECV off-by-one (fixed) was not the cause -
   -- hardware is bit-identical with and without that fix.
   --
   -- Hardware cannot answer the next question: IPCFIFOCNT is IO space, which PEEK
   -- cannot reach, and peek7 aliases to main RAM so the ARM7's own state is
   -- unreadable. In sim it is all visible. Reports on CHANGE so a long run stays
   -- a handful of lines.
   --
   --   en9/en7     FIFO enable   (IPCFIFOCNT bit 15) - sends are DROPPED if clear
   --   rirq9/rirq7 recv IRQ enable (bit 10)
   --   cnt79       words queued ARM7 -> ARM9   (drives IF9 bit 18)
   --   cnt97       words queued ARM9 -> ARM7   (drives IF7 bit 18)
   --   w79/w97     cumulative sends in each direction
   p_ipcfifo : process
      alias a_en9   is << signal .tb_top_frame.idut.iipc.en9   : std_logic >>;
      alias a_en7   is << signal .tb_top_frame.idut.iipc.en7   : std_logic >>;
      alias a_ri9   is << signal .tb_top_frame.idut.iipc.rirq9 : std_logic >>;
      alias a_ri7   is << signal .tb_top_frame.idut.iipc.rirq7 : std_logic >>;
      alias a_c79   is << signal .tb_top_frame.idut.iipc.cnt79 : integer range 0 to 16 >>;
      alias a_c97   is << signal .tb_top_frame.idut.iipc.cnt97 : integer range 0 to 16 >>;
      alias a_w79   is << signal .tb_top_frame.idut.iipc.wr79  : integer range 0 to 15 >>;
      alias a_w97   is << signal .tb_top_frame.idut.iipc.wr97  : integer range 0 to 15 >>;
      variable p9, p7, pr9, pr7 : std_logic := 'U';
      variable pc79, pc97, pw79, pw97 : integer := -1;
      variable n79, n97 : natural := 0;
   begin
      wait until rising_edge(clk1x);
      if (a_w79 /= pw79 and pw79 >= 0) then n79 := n79 + 1; end if;
      if (a_w97 /= pw97 and pw97 >= 0) then n97 := n97 + 1; end if;
      if (a_en9 /= p9 or a_en7 /= p7 or a_ri9 /= pr9 or a_ri7 /= pr7 or
          a_c79 /= pc79 or a_c97 /= pc97) then
         report "IPCFIFO en9=" & std_logic'image(a_en9)(2) &
                " rirq9=" & std_logic'image(a_ri9)(2) &
                " en7=" & std_logic'image(a_en7)(2) &
                " rirq7=" & std_logic'image(a_ri7)(2) &
                "  cnt79(7->9)=" & integer'image(a_c79) &
                " cnt97(9->7)=" & integer'image(a_c97) &
                "  sends 7->9=" & integer'image(n79) &
                " 9->7=" & integer'image(n97) &
                " @" & time'image(now) severity note;
      end if;
      p9 := a_en9; p7 := a_en7; pr9 := a_ri9; pr7 := a_ri7;
      pc79 := a_c79; pc97 := a_c97; pw79 := a_w79; pw97 := a_w97;
   end process;

   -- ================= IPCSYNC watch =================
   -- Does the ARM9's echo actually land in the register? The ARM7 reads 0 for the
   -- ARM9's nibble at instruction 231,344 where the oracle reads 8, and the
   -- instruction-count evidence says the ARM9 is AHEAD by then - so "too slow" may
   -- be the wrong story. Only io_bus9.ena is synchronised across the island bridge;
   -- Adr/Din/bEna cross unsynchronised, so a write can land with the wrong payload
   -- or not at all while the ARM9's own trace stays perfect. This reports every
   -- change to either side's out-nibble with a timestamp, which distinguishes
   -- "never written", "written late", and "written with the wrong value".
   -- Counts the ARM9 IO write path end to end, so a dropped store can be pinned to
   -- a stage instead of guessed at: membus9 issuing (i9_io_bus.ena, island), the
   -- bridge delivering (io_bus9.ena, clk1x), and how many of each are writes.
   p_iocount : process
      alias a_i9ena is << signal .tb_top_frame.idut.i9_io_bus : proc_bus_gb_type >>;
      alias a_io9   is << signal .tb_top_frame.idut.io_bus9   : proc_bus_gb_type >>;
      alias a_mb_adr is << signal .tb_top_frame.idut.mbus_adr : std_logic_vector(31 downto 0) >>;
      alias a_mb_ena is << signal .tb_top_frame.idut.mbus_ena : std_logic >>;
      alias a_mb_acc is << signal .tb_top_frame.idut.imembus9.accept_now : std_logic >>;
      alias a_itcm   is << signal .tb_top_frame.idut.imembus9.itcm_hit : std_logic >>;
      alias a_dtcm   is << signal .tb_top_frame.idut.imembus9.dtcm_hit : std_logic >>;
      variable c_isl, c_isl_wr, c_1x, c_1x_wr, c_sync : natural := 0;
      variable prev_isl : std_logic := '0';
      variable prev_1x  : std_logic := '0';
      variable cyc : natural := 0;
      variable b_tot, b_r2, b_r3, b_r4, b_ro, b_hi : natural := 0;
      variable b_itcm, b_dtcm, b_io_eaten : natural := 0;
   begin
      wait until rising_edge(clk2x);
      cyc := cyc + 1;
      -- island side: membus9's one-island-cycle request pulse
      if (a_i9ena.ena = '1' and prev_isl = '0') then
         c_isl := c_isl + 1;
         if (a_i9ena.rnw = '0') then c_isl_wr := c_isl_wr + 1; end if;
      end if;
      prev_isl := a_i9ena.ena;
      -- clk1x side: RISING-EDGE detect, not a level sample. This used to read
      -- `clk1x = '1' and a_io9.ena = '1'`, which counted correctly only by
      -- accident of the exact 2:1 coincident-edge relationship: clk1x is high
      -- for one of every two clk2x edges, so a one-clk1x-wide ena pulse
      -- overlapped exactly one sample. At any other ratio (e.g. an island on its
      -- own slower PLL output) that coincidence is gone and the count silently
      -- drops requests that were never dropped - it reported 183 of 314 at
      -- 1.705:1 and looked exactly like the CDC losing them. An edge detector is
      -- correct at any ratio where the pulse is at least one island cycle wide.
      if (a_io9.ena = '1' and prev_1x = '0') then
         c_1x := c_1x + 1;
         if (a_io9.rnw = '0') then
            c_1x_wr := c_1x_wr + 1;
            if (a_io9.Adr = x"0000180") then
               c_sync := c_sync + 1;
               -- The write reaches the bus but sync9_out never moves, so print
               -- what nds_ipc actually receives. It applies the write only when
               -- bEna(1)='1' and takes the nibble from Din(11:8).
               if (c_sync <= 12) then
                  report "IPCSYNC WR#" & integer'image(c_sync) & " Adr=" &
                         to_hstring(a_io9.Adr) & " Din=" & to_hstring(a_io9.Din) &
                         " bEna=" & to_hstring(a_io9.bEna) & " acc=" &
                         to_hstring(a_io9.acc) & " at " & time'image(now) severity note;
               end if;
            end if;
         end if;
      end if;
      prev_1x := a_io9.ena;
      -- Census of every request membus9 ACCEPTS, bucketed by address region and by
      -- whether a TCM claimed it. If the ARM9's IO stores are executed (the trace
      -- proves they are) but io_bus.ena almost never pulses, they must be landing
      -- on some other target - this says which, instead of guessing.
      if (a_mb_ena = '1' and a_mb_acc = '1') then
         b_tot := b_tot + 1;
         case a_mb_adr(27 downto 24) is
            when x"2"   => b_r2 := b_r2 + 1;
            when x"3"   => b_r3 := b_r3 + 1;
            when x"4"   => b_r4 := b_r4 + 1;
            when others => b_ro := b_ro + 1;
         end case;
         if (a_mb_adr(31 downto 28) /= x"0") then b_hi := b_hi + 1; end if;
         if (a_itcm = '1') then b_itcm := b_itcm + 1; end if;
         if (a_dtcm = '1') then b_dtcm := b_dtcm + 1; end if;
         -- an IO-range access that a TCM swallowed is the smoking gun
         if (a_mb_adr(31 downto 24) = x"04" and (a_itcm = '1' or a_dtcm = '1')) then
            b_io_eaten := b_io_eaten + 1;
         end if;
      end if;
      if (cyc mod 200000 = 0) then
         report "IO9 path: island req " & integer'image(c_isl) & " (wr " &
                integer'image(c_isl_wr) & ")   clk1x seen " & integer'image(c_1x) &
                " (wr " & integer'image(c_1x_wr) & ")   IPCSYNC writes " &
                integer'image(c_sync) severity note;
         report "  mbus9 accepts " & integer'image(b_tot) & ": 0x02 " &
                integer'image(b_r2) & "  0x03 " & integer'image(b_r3) & "  0x04 " &
                integer'image(b_r4) & "  other " & integer'image(b_ro) &
                "  above-0x0FFFFFFF " & integer'image(b_hi) &
                "   itcm_hit " & integer'image(b_itcm) & "  dtcm_hit " &
                integer'image(b_dtcm) & "  IO-eaten-by-TCM " &
                integer'image(b_io_eaten) severity note;
      end if;
   end process;

   -- Walks the IO completion chain stage by stage: membus9's request pulse, the
   -- island toggle, the clk1x enable, the clk1x completion toggle, and the pulse
   -- the island finally sees. Whichever count is the first zero is the broken link.
   p_iochain : process
      alias a_ena   is << signal .tb_top_frame.idut.i9_io_bus : proc_bus_gb_type >>;
      alias a_rq    is << signal .tb_top_frame.idut.cdc_req_io : std_logic >>;
      alias a_io9e  is << signal .tb_top_frame.idut.io9_ena : std_logic >>;
      alias a_cpl   is << signal .tb_top_frame.idut.cdc_io_cpl : std_logic >>;
      alias a_done  is << signal .tb_top_frame.idut.i9_io_done : std_logic >>;
      variable n_ena, n_rq, n_io9e, n_cpl, n_done, cyc : natural := 0;
      variable p_ena, p_rq, p_io9e, p_cpl : std_logic := '0';
   begin
      wait until rising_edge(clk2x);
      cyc := cyc + 1;
      if (a_ena.ena = '1' and p_ena = '0') then n_ena  := n_ena  + 1; end if;
      if (a_rq   /= p_rq)                  then n_rq   := n_rq   + 1; end if;
      if (a_io9e = '1' and p_io9e = '0')    then n_io9e := n_io9e + 1; end if;
      if (a_cpl  /= p_cpl)                 then n_cpl  := n_cpl  + 1; end if;
      if (a_done = '1')                    then n_done := n_done + 1; end if;
      p_ena := a_ena.ena; p_rq := a_rq; p_io9e := a_io9e; p_cpl := a_cpl;
      if (cyc mod 100000 = 0) then
         report "IO chain: membus9.ena " & integer'image(n_ena) &
                " -> cdc_req_io tgl " & integer'image(n_rq) &
                " -> io9_ena " & integer'image(n_io9e) &
                " -> cdc_io_cpl tgl " & integer'image(n_cpl) &
                " -> i9_io_done " & integer'image(n_done) severity note;
      end if;
   end process;

   -- Every observable event on the ARM9 DMA path, in order. bootreq runs exactly
   -- one DMA, so this is a handful of lines and not a firehose. Everything is
   -- sampled on clk2x: the clk1x-domain signals are stable for two island cycles,
   -- so an edge detector here sees each of them exactly once, while dmab_ena_i9
   -- and cpu9_done_1x are one-island-cycle pulses that a clk1x sampler would miss.
   -- Every ARM9 write to a video-mode register that CHANGES it, reported as it
   -- happens. This is how you find out what video mode a commercial ROM actually
   -- programs, which is the prerequisite for writing a devkitPro render-test ROM
   -- that exercises the SAME modes instead of a guess. Engine A is at
   -- 0x0400_0000, engine B at 0x0400_1000, and POWCNT1 at 0x0400_0304 decides
   -- which engine reaches which screen at all.
   --
   -- Reported on change rather than summarised at the end, and that is not a
   -- style choice: tests_done is set only on normal completion (line 1335), while
   -- every Kirby-length run ends at p_watchdog's `severity failure`, which
   -- --exit-severity=failure turns into an immediate abort. An end-of-run
   -- summary in this bench is a summary that never prints. Dedup keeps it to a
   -- handful of lines - games write DISPCNT every frame with the same value.
   p_vidregs : process
      alias a_iob is << signal .tb_top_frame.idut.io_bus9 : proc_bus_gb_type >>;
      type t_seen is array (0 to 16#40#) of std_logic_vector(31 downto 0);
      variable segA, segB : t_seen := (others => (others => 'U'));
      variable powcnt : std_logic_vector(31 downto 0) := (others => 'U');
      variable p_ena : std_logic := '0';
      variable adr : natural;
   begin
      wait until rising_edge(clk2x);
      if (a_iob.ena = '1' and p_ena = '0' and a_iob.rnw = '0') then
         -- Adr is the byte offset into 0x0400_0000, word-aligned: BG0CNT is
         -- 0x008 (reg_nds_display.vhd:58), engine B is the 0x1000 window
         -- (nds_top.vhd:1663), POWCNT1 is 0x304.
         adr := to_integer(unsigned(a_iob.Adr));
         if (adr <= 16#03C#) then
            if (segA(adr / 4) /= a_iob.Din) then
               segA(adr / 4) := a_iob.Din;
               report "VIDREG A +" & to_hstring(to_unsigned(adr, 12)) &
                      " = " & to_hstring(a_iob.Din) &
                      " bEna=" & to_hstring(a_iob.bEna) &
                      " @" & time'image(now) severity note;
            end if;
         elsif (adr >= 16#1000# and adr <= 16#103C#) then
            if (segB((adr - 16#1000#) / 4) /= a_iob.Din) then
               segB((adr - 16#1000#) / 4) := a_iob.Din;
               report "VIDREG B +" & to_hstring(to_unsigned(adr - 16#1000#, 12)) &
                      " = " & to_hstring(a_iob.Din) &
                      " bEna=" & to_hstring(a_iob.bEna) &
                      " @" & time'image(now) severity note;
            end if;
         elsif (adr = 16#304#) then
            if (powcnt /= a_iob.Din) then
               powcnt := a_iob.Din;
               report "VIDREG POWCNT1 = " & to_hstring(a_iob.Din) &
                      " @" & time'image(now) severity note;
            end if;
         end if;
      end if;
      p_ena := a_iob.ena;
   end process;

   p_dmawatch : process
      alias a_iob   is << signal .tb_top_frame.idut.io_bus9       : proc_bus_gb_type >>;
      alias a_on    is << signal .tb_top_frame.idut.dma_on        : std_logic >>;
      alias a_bus   is << signal .tb_top_frame.idut.dma_bus_on    : std_logic >>;
      alias a_idle  is << signal .tb_top_frame.idut.cpu9_bus_idle : std_logic >>;
      alias a_ena   is << signal .tb_top_frame.idut.dmab_ena      : std_logic >>;
      alias a_enai  is << signal .tb_top_frame.idut.dmab_ena_i9   : std_logic >>;
      alias a_rnw   is << signal .tb_top_frame.idut.dmab_rnw      : std_logic >>;
      alias a_adr   is << signal .tb_top_frame.idut.dmab_adr      : std_logic_vector(31 downto 0) >>;
      alias a_dout  is << signal .tb_top_frame.idut.dmab_dout     : std_logic_vector(31 downto 0) >>;
      alias a_dn1x  is << signal .tb_top_frame.idut.cpu9_done_1x  : std_logic >>;
      alias a_din   is << signal .tb_top_frame.idut.cpu9_din      : std_logic_vector(31 downto 0) >>;
      alias a_mbena is << signal .tb_top_frame.idut.mbus_ena      : std_logic >>;
      -- the stale, CPU-derived cacheability that membus9 used to apply to DMA
      -- accesses: decoded in nds_cpu9 from the CPU's own address register, so
      -- while the DMA owns the bus it describes some unrelated CPU access
      alias a_cchd  is << signal .tb_top_frame.idut.bus_cacheable_d : std_logic >>;
      alias a_cchi  is << signal .tb_top_frame.idut.bus_cacheable_i : std_logic >>;
      alias a_cadr  is << signal .tb_top_frame.idut.cpu9_adr       : std_logic_vector(31 downto 0) >>;
      variable p_iobe, p_on, p_bus : std_logic := '0';
      variable n : natural := 0;
      variable adr : unsigned(27 downto 0);
      variable rw : string(1 to 2);
   begin
      wait until rising_edge(clk2x);
      if (n < 400) then
         -- register traffic to 0x040000B0..0x040000EF (the whole DMA9 block)
         if (a_iob.ena = '1' and p_iobe = '0') then
            adr := unsigned(a_iob.Adr);
            if (adr >= 16#0B0# and adr < 16#0F0#) then
               if (a_iob.rnw = '1') then rw := "rd"; else rw := "wr"; end if;
               report "DMAREG " & rw &
                      " adr=" & to_hstring(a_iob.Adr) & " Din=" & to_hstring(a_iob.Din) &
                      " bEna=" & to_hstring(a_iob.bEna) & " @" & time'image(now) severity note;
               n := n + 1;
            end if;
         end if;
         if (a_on /= p_on) then
            report "DMA dma_on " & std_logic'image(p_on) & " -> " & std_logic'image(a_on) &
                   " (cpu9_bus_idle=" & std_logic'image(a_idle) & ") @" & time'image(now) severity note;
            n := n + 1;
         end if;
         if (a_bus /= p_bus) then
            report "DMA dma_bus_on " & std_logic'image(p_bus) & " -> " & std_logic'image(a_bus) &
                   " @" & time'image(now) severity note;
            n := n + 1;
         end if;
         -- the narrowed request the island actually sees, and the stretched done
         if (a_enai = '1') then
            if (a_rnw = '1') then rw := "RD"; else rw := "WR"; end if;
            report "DMA req " & rw &
                   " adr=" & to_hstring(a_adr) & " dout=" & to_hstring(a_dout) &
                   " mbus_ena=" & std_logic'image(a_mbena) &
                   " [stale cacheable_d=" & std_logic'image(a_cchd) &
                   " _i=" & std_logic'image(a_cchi) &
                   " from cpu9_adr=" & to_hstring(a_cadr) & "]" &
                   " @" & time'image(now) severity note;
            n := n + 1;
         end if;
         if (a_dn1x = '1' and a_bus = '1') then
            report "DMA done din=" & to_hstring(a_din) & " @" & time'image(now) severity note;
            n := n + 1;
         end if;
         -- a raw request that never became a narrowed one is a dropped access
         if (a_ena = '1' and a_enai = '0' and a_bus = '0') then
            report "DMA req WHILE NOT GRANTED adr=" & to_hstring(a_adr) &
                   " @" & time'image(now) severity note;
            n := n + 1;
         end if;
      end if;
      p_iobe := a_iob.ena; p_on := a_on; p_bus := a_bus;
   end process;

   p_ipcwatch : process
      alias a_s9 is << signal .tb_top_frame.idut.iipc.sync9_out : std_logic_vector(3 downto 0) >>;
      alias a_s7 is << signal .tb_top_frame.idut.iipc.sync7_out : std_logic_vector(3 downto 0) >>;
      variable p9, p7 : std_logic_vector(3 downto 0) := (others => '0');
      variable n : integer := 0;
   begin
      wait until rising_edge(clk1x);
      if (a_s9 /= p9) then
         report "IPCSYNC arm9_out " & to_hstring(p9) & " -> " & to_hstring(a_s9) &
                " at " & time'image(now) severity note;
         p9 := a_s9;
         n := n + 1;
      end if;
      if (a_s7 /= p7) then
         report "IPCSYNC arm7_out " & to_hstring(p7) & " -> " & to_hstring(a_s7) &
                " at " & time'image(now) severity note;
         p7 := a_s7;
         n := n + 1;
      end if;
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
            -- clk2x, not clk1x: the ARM9 is in the 67 MHz island, so half its
            -- retires land on island cycles that clk1x never sees. Sampling on
            -- clk1x here silently produced an EMPTY ARM9 trace.
            wait until rising_edge(clk2x);
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
               -- Timestamp the instruction stream. Without this an instruction
               -- index cannot be converted to a time, so "the ARM9 had not echoed
               -- when the ARM7 read IPCSYNC" cannot be turned into a cycle count -
               -- and the size of that margin is what decides whether the fix is a
               -- tweak or a memory-subsystem redesign.
               if (n mod 10000 = 0) then
                  report "T9 " & integer'image(n) & " " & time'image(now) severity note;
               end if;
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
            -- close on leaving a time window, so the file is complete even
            -- though the run goes on (and may then die on an assertion)
            if (TRACE7_T1 > 0 and now > TRACE7_T1 * 1 us) then
               report "tb_top_frame: ARM7 trace window closed, " &
                      integer'image(n) & " instructions in " & TRACEFILE7 severity note;
               file_close(tf);
               wait;
            end if;
            if (dbg_export7_done = '1' and
                ((TRACE7_T1 > 0 and now >= TRACE7_T0 * 1 us) or
                 (TRACE7_T1 = 0 and dump_frame_index >= TRACE7_START_FRAME))) then
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
               -- a windowed trace exists to be read after a crash, so pay the
               -- flush per line rather than lose the tail that matters
               if (TRACE7_T1 > 0) then
                  flush(tf);
               end if;
               n := n + 1;
               if (n mod 10000 = 0) then
                  report "T7 " & integer'image(n) & " " & time'image(now) severity note;
               end if;
               -- The handshake instruction itself (see COORDINATION.md): the ARM7
               -- reads IPCSYNC here and the oracle sees the ARM9's echo nibble
               -- already set. Report it exactly rather than interpolating.
               if (n = 231344 or n = 231343 or n = 231345) then
                  report "T7 HANDSHAKE instr " & integer'image(n) & " pc=" &
                         to_hstring(dbg_export7.pc) & " r0=" &
                         to_hstring(dbg_export7.regs(0)) & " at " & time'image(now)
                         severity note;
               end if;
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
            sdram_Dout   <= mainram(w);
            sdram_done32 <= '1';
            wait until rising_edge(clkMem);
            sdram_done32 <= '0';
            -- The real controller runs BURST_LENGTH=4, so the upper 32 bits of
            -- the aligned 8-byte block arrive two clocks after done32 and
            -- done64 marks them (rtl/sdram.sv ch2_dout_hi / ch2_ready64). The
            -- pairing is w with w xor 1 rather than w+1 because ACCESS_TYPE is
            -- sequential: a burst from an odd word wraps inside its aligned
            -- block, so the "high" half of an odd base is the EVEN word. Pair
            -- mode is only ever issued on even addresses, but modelling the
            -- wrap is what makes a violation of that show up here rather than
            -- as silently transposed data on hardware.
            -- Kept identical to sim/tb_arm9_island.vhd's model on purpose: two
            -- behavioural SDRAMs that disagree about pair timing would make the
            -- island bench and the system bench disagree about the CPU.
            wait until rising_edge(clkMem);
            if (w mod 2) = 0 then
               sdram_Dout_hi <= mainram(w + 1);
            else
               sdram_Dout_hi <= mainram(w - 1);
            end if;
            sdram_done64 <= '1';
            wait until rising_edge(clkMem);
            sdram_done64 <= '0';
            -- the slot stays 10 clkMem cycles long, exactly as before pair mode
            -- existed, so a non-pair read is cycle-identical to baseline
            wait until rising_edge(clkMem);
         else
            for k in 1 to 3 loop wait until rising_edge(clkMem); end loop;
            for j in 0 to 3 loop
               if (v_be(j) = '1') then
                  mainram(w)(j*8 + 7 downto j*8) := v_din(j*8 + 7 downto j*8);
               end if;
            end loop;
            sdram_done32 <= '1';
            sdram_done64 <= '1';   -- a write returns no data; both dones fire
            wait until rising_edge(clkMem);
            sdram_done32 <= '0';
            sdram_done64 <= '0';
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

   -- Renderer A..D feed: PIPELINED, one request accepted per cycle, answered in
   -- issue order VRSRV_LAT+1 cycles later. On hardware this channel is SDRAM
   -- (NDS.sv's vrsrv handler on ch1), so the old two-cycle blocking model both
   -- understated its cost and hid the renderer's outstanding-request behaviour.
   -- ready mirrors NDS.sv's `~vr_busy & ~vr_fin` when VRSRV_ONE is set, and is
   -- tied high otherwise (the historical behaviour).
   --
   -- The handshake is valid/ready: a request is taken on the edge at which the
   -- model sees req high and is able to accept, which is the same edge the core
   -- samples ready on, so both ends agree. This model does NOT latch a request
   -- it could not take - if the core stops holding it, the word is lost, which
   -- is exactly what silicon does, and the checker below turns that into a
   -- failure rather than a wedge 400,000 cycles later.
   -- three models, in precedence order: explicit depth/gap, then the legacy
   -- one-in-flight bit, then always-ready.
   vrsrv_ready_s <= '1' when (VRSRV_OUT /= 0 or VRSRV_GAP /= 0) and
                             (VRSRV_OUT = 0 or vrsrv_out_m < VRSRV_OUT) and
                             (vrsrv_gap_m = 0)
               else '0' when (VRSRV_OUT /= 0 or VRSRV_GAP /= 0)
               else '1' when VRSRV_ONE = 0
               else (not vrsrv_busy_m);

   prserv : process (clk1x)
      variable accept_v : boolean;
      -- line-cache hit-rate model, one per candidate size. Fully associative with
      -- round-robin replacement, which is the cheapest thing worth building and so
      -- the honest thing to measure. tags hold bank & addr(16 downto 3).
      type t_tags is array (0 to NPROBE-1, 0 to 15) of integer;
      variable ptag  : t_tags := (others => (others => -1));
      variable pnext : integer_vector(0 to NPROBE-1) := (others => 0);
      variable phit  : integer_vector(0 to NPROBE-1) := (others => 0);
      variable pops  : natural := 0;
      variable pline : integer;
      variable found : boolean;
      variable pcyc  : natural := 0;
      variable l     : line;
   begin
      if rising_edge(clk1x) then
         for k in VRSRV_LAT - 1 downto 1 loop
            vrsrvpipe(k) <= vrsrvpipe(k - 1);
         end loop;
         vrsrvpipe(0).v <= '0';
         accept_v := (vrsrv_req = '1') and (vrsrv_ready_s = '1');
         if (vrsrv_gap_m > 0) then vrsrv_gap_m <= vrsrv_gap_m - 1; end if;
         if (accept_v) then
            vrsrvpipe(0).v <= '1';
            -- 64-bit line: both words of the aligned 8-byte block, which is what
            -- sdram.sv's four-halfword burst actually delivers
            vrsrvpipe(0).d <= banks(to_integer(unsigned(vrsrv_bank)) * 32768 +
                                    to_integer(vrsrv_addr) * 2 + 1) &
                              banks(to_integer(unsigned(vrsrv_bank)) * 32768 +
                                    to_integer(vrsrv_addr) * 2);
            if (VRSRV_ONE /= 0) then vrsrv_busy_m <= '1'; end if;
            if (VRSRV_GAP > 1) then vrsrv_gap_m <= VRSRV_GAP - 1; end if;
         end if;
         vrsrv_done <= vrsrvpipe(VRSRV_LAT - 1).v;
         vrsrv_dout <= vrsrvpipe(VRSRV_LAT - 1).d;
         if (vrsrvpipe(VRSRV_LAT - 1).v = '1') then vrsrv_busy_m <= '0'; end if;
         -- outstanding counter, handling accept and completion on the same edge
         if (accept_v and vrsrvpipe(VRSRV_LAT - 1).v = '0') then
            vrsrv_out_m <= vrsrv_out_m + 1;
         elsif (not accept_v and vrsrvpipe(VRSRV_LAT - 1).v = '1') then
            vrsrv_out_m <= vrsrv_out_m - 1;
         end if;

         -- ---- valid/ready protocol checker (see the header above)
         assert vrsrv_held = '0' or
                (vrsrv_req = '1' and vrsrv_bank = vrsrv_held_bank and
                 vrsrv_addr = vrsrv_held_addr)
            report "vrsrv: request dropped - not held until ready (bank " &
                   to_string(vrsrv_held_bank) & " addr " &
                   to_hstring(vrsrv_held_addr) & ")"
            severity failure;
         vrsrv_held <= '0';
         if (vrsrv_req = '1' and not accept_v) then
            vrsrv_held      <= '1';
            vrsrv_held_bank <= vrsrv_bank;
            vrsrv_held_addr <= vrsrv_addr;
         end if;

         -- ---- 64-bit-line hit-rate probe. Counted per ACCEPTED request, which is
         -- one SDRAM read today; a hit is a read that would not have happened.
         if (VRAMOPS /= 0 and accept_v) then
            pops  := pops + 1;
            pline := to_integer(unsigned(vrsrv_bank)) * 16384 +
                     to_integer(vrsrv_addr);
            for s in 0 to NPROBE-1 loop
               found := false;
               for e in 0 to PROBE_SIZES(s) - 1 loop
                  if (not found and ptag(s, e) = pline) then found := true; end if;
               end loop;
               if (found) then
                  phit(s) := phit(s) + 1;
               else
                  ptag(s, pnext(s)) := pline;
                  pnext(s) := (pnext(s) + 1) mod PROBE_SIZES(s);
               end if;
            end loop;
         end if;
         pcyc := pcyc + 1;
         if (VRAMOPS /= 0 and pcyc = 560190) then   -- one frame
            pcyc := 0;
            write(l, string'("LINEPROBE ops="));
            write(l, pops);
            for s in 0 to NPROBE-1 loop
               write(l, string'("  n="));
               write(l, PROBE_SIZES(s));
               write(l, string'(":"));
               if (pops = 0) then
                  write(l, string'("-"));
               else
                  write(l, phit(s) * 100 / pops);
                  write(l, string'("%"));
               end if;
            end loop;
            report l.all severity note;
            deallocate(l);
            pops := 0;
            phit := (others => 0);
         end if;
      end if;
   end process;

   -- ============ reset-clear ordering monitor ============
   -- nds_vram and both gpu2d engines zero VRAM / palette / OAM out of reset (a
   -- MiSTer ROM change does not reconfigure the FPGA, so without this the new
   -- game shows the previous game's leftovers - the video-memory half of what
   -- nds_loader's CLR_WR does for main RAM). nds_top's boot FSM holds the CPUs
   -- until all three clr_busy drop, so the ordering is guaranteed by
   -- construction; this monitor MEASURES it rather than assuming it, and says
   -- which of the loader or the clear was the long pole.
   -- Renderer VRAM arbiter occupancy, per frame. VRAMOPS=1 to enable.
   --
   -- This exists to verify or kill the leading explanation for the 3x frame
   -- stretch. nds_vram's renderer side is documented as "arbitrated round-robin,
   -- ONE OP IN FLIGHT ... ~4 cycles/op", with the parallelism pass deferred, and
   -- both 2D engines' BG/OBJ/palette fetches queue through it. If the renderer
   -- needs ~18 clk1x cycles/dot against 6 available, and ops cost ~4 cycles,
   -- then ~4-5 ops/dot would explain the whole deficit - but that number was an
   -- estimate chosen to make the arithmetic work, which is exactly the kind of
   -- reasoning this project has been burned by. So measure it:
   -- Counts rdispatch pulses (one per renderer VRAM op) per frame and per line.
   -- Multiply ops/line by the documented ~4 cycles/op and compare against the
   -- 2,130 clk1x cycles a line has at the 1-of-1 dot pace: if that product is at or over
   -- the budget, the serial arbiter IS the wall and no pixel-pipeline work will
   -- help. `rstate` is not aliasable from here - its type is declared inside the
   -- architecture body and is not visible externally - so occupancy is derived
   -- from the op count rather than sampled directly.
   p_vramops : process
      alias a_rdisp is << signal .tb_top_frame.idut.ivram.rdispatch : std_logic >>;
      -- Actual blocked time, not inferred. Each channel holds req until its done
      -- pulse, so "any renderer req asserted" is exactly "some renderer is
      -- waiting on VRAM". This matters because the ~4 cycles/op in nds_vram's
      -- header is a floor: the same header says "BRAM ops take ~3 cycles, A..D
      -- ops depend on the server", and A..D go through the rsrv_* channel, so
      -- ops/line x 4 is a LOWER BOUND on occupancy and cannot on its own settle
      -- whether the arbiter is the wall.
      -- TRUE renderer-memory occupancy from nds_vram's own FSM. The previous
      -- version counted cycles with any srv_*_req asserted, which is NOT
      -- occupancy: nds_gpu2d drives req as a one-cycle pulse, so it counted
      -- REQUESTS (measured 0.94 cycles per op, where an op takes ~4) - and worse,
      -- it was not comparable across configurations, because nds_gpu2d_fast HOLDS
      -- req until done, giving 6.14. The "12% -> 84% inversion" that produced was
      -- an artifact of the two configs driving req differently, not a real change.
      alias a_rbusy is << signal .tb_top_frame.idut.dbg_rbusy_s   : std_logic >>;
      alias a_bg    is << signal .tb_top_frame.idut.r_bg_req     : std_logic >>;
      alias a_obj   is << signal .tb_top_frame.idut.r_obj_req    : std_logic >>;
      alias a_bgep  is << signal .tb_top_frame.idut.r_bgep_req   : std_logic >>;
      alias a_objep is << signal .tb_top_frame.idut.r_objep_req  : std_logic >>;
      alias b_bg    is << signal .tb_top_frame.idut.rb_bg_req    : std_logic >>;
      alias b_obj   is << signal .tb_top_frame.idut.rb_obj_req   : std_logic >>;
      alias b_bgep  is << signal .tb_top_frame.idut.rb_bgep_req  : std_logic >>;
      -- per-engine render busy and the per-line trigger (dbg_line_busy at bench
      -- level is the OR of both engines, which is what needed splitting)
      alias a_busy  is << signal .tb_top_frame.idut.line_busy     : std_logic >>;
      alias b_busy  is << signal .tb_top_frame.idut.line_busy_b   : std_logic >>;
      alias a_draw  is << signal .tb_top_frame.idut.drawline      : std_logic >>;
      alias a_line  is << signal .tb_top_frame.idut.linecounter   : integer range 0 to 191 >>;
      -- the two things that could be stealing the renderer's VRAM/bus at the top
      -- of a frame, so a drop report says WHICH rather than leaving it to a guess:
      -- the ext-palette shadow refill (per frame, from vblank_trigger, 10,240 VRAM
      -- ops) and the ARM9 DMA the game fires from its vblank IRQ.
      alias a_epf   is << signal .tb_top_frame.idut.epfill_busy   : std_logic >>;
      alias a_dmab  is << signal .tb_top_frame.idut.dma_bus_on    : std_logic >>;
      -- Engine A's drawer busies. nds_gpu2d's linestate goes
      -- LIDLE -> LDRAW -> LMERGE -> LFLUSH; LMERGE is a fixed 256 cycles (one
      -- pixel per cycle, already optimal) and LFLUSH is 8, so anything above
      -- ~264 cycles per line is LDRAW waiting for these two. Splitting them says
      -- whether the BG drawers or the OBJ drawer is the cost. linestate itself
      -- is not aliasable - its type is declared inside gpu2d's architecture.
      alias a_bgbusy  is << signal .tb_top_frame.idut.igpu2d_a.dbg_bg_busy : std_logic >>;
      alias a_objbusy is << signal .tb_top_frame.idut.igpu2d_a.dbg_obj_busy : std_logic >>;
      -- ...and engine B's. Every per-line number in this bench was engine A
      -- only, so "the renderer fits the budget" was a claim about the TOP
      -- screen alone - the bottom screen has its own gpu2d instance, its own
      -- drawers and its own 2130-cycle budget, and nothing here ever looked at
      -- it. Both engines share `drawline`/`linecounter` (nds_top.vhd:2065
      -- derives dbg_line_drop_b from the same drawline), so the engine-A line
      -- number and trigger are reused rather than duplicated.
      alias b_bgbusy  is << signal .tb_top_frame.idut.igpu2d_b.dbg_bg_busy : std_logic >>;
      alias b_objbusy is << signal .tb_top_frame.idut.igpu2d_b.dbg_obj_busy : std_logic >>;
      -- OBJ pixel writes, counted FREE-RUNNING and reported per frame, not per
      -- line. A per-line version gated on line_busy was tried and read zero on
      -- the very lines where OBJ burns 3,036 cycles - because the OBJ drawer
      -- pre-renders the NEXT line and runs partly while linestate is LIDLE, i.e.
      -- outside that window. It looked exactly like "the drawer draws nothing",
      -- which is why the frame totals are here instead: they are unambiguous.
      -- Attributing OBJ work to a line needs the drawer's own line boundary
      -- (linecounter_obj), not the BG line FSM's.
      alias a_objpx is << signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.iobj.pixel_we_color : std_logic >>;
      alias a_objpxs is << signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.iobj.pixel_we_settings : std_logic >>;
      variable ops, cyc, blocked, blk_a, blk_b : natural := 0;
      variable objpx_all, objpxs_all : natural := 0;
      variable busy_a, busy_b, lines : natural := 0;
      variable starts_a, starts_b : natural := 0;
      variable dones_a, drops_a   : natural := 0;
      variable bgcyc, objcyc : natural := 0;
      variable prev_abusy, prev_bbusy : std_logic := '0';
      -- cycles the IN-PROGRESS engine-A line has burned so far. At a drop this is
      -- how far over the 2,130 budget the line that caused it has run, which is
      -- the difference between "one pathological line" and "everything is slow".
      variable linecyc : natural := 0;
      variable linebg, lineobj, linevr, lineobjq : natural := 0;
      variable linestart : natural := 0;
      -- the same set for engine B
      variable linecyc_b : natural := 0;
      variable linebg_b, lineobj_b, lineobjq_b : natural := 0;
      variable linestart_b : natural := 0;
      variable drops_b_r : natural := 0;
      variable nlines, nstarts : positive := 1;
      variable frames : natural := 0;
   begin
      if (VRAMOPS = 0) then
         wait;
      end if;
      loop
         wait until rising_edge(clk1x);
         cyc := cyc + 1;
         if (a_rdisp = '1') then ops := ops + 1; end if;
         if (a_objpx = '1')  then objpx_all  := objpx_all + 1;  end if;
         if (a_objpxs = '1') then objpxs_all := objpxs_all + 1; end if;
         if (a_bg = '1' or a_obj = '1' or a_bgep = '1' or a_objep = '1') then
            blk_a := blk_a + 1;
         end if;
         if (b_bg = '1' or b_obj = '1' or b_bgep = '1') then
            blk_b := blk_b + 1;
         end if;
         if (a_rbusy = '1') then
            blocked := blocked + 1;
         end if;
         -- Render time per line: the number this whole section now turns on.
         -- A line has 2,130 clk1x cycles at the 1-of-1 dot pace and 256 dots, so 8.3
         -- cycles/dot. busy/line well over 2,130 with blocked% near zero means
         -- the drawer/merge chain itself is the cost, and busy/line divided by
         -- 256 is the per-pixel figure that says whether it is an FSM stepping
         -- one pixel at a time (pipelineable) or genuinely that much work.
         if (a_busy = '1') then busy_a := busy_a + 1; end if;
         if (b_busy = '1') then busy_b := busy_b + 1; end if;
         if (a_draw = '1') then lines := lines + 1; end if;
         -- Renders STARTED, counted as line_busy rising edges. This is the right
         -- denominator for cycles-per-line: dividing by drawline count mixes in
         -- the DROPPED lines, which contribute no busy cycles at all, and so
         -- understates the cost of a line that actually gets rendered. With 2/3
         -- of lines dropped that error is a factor of 3.
         if (a_bgbusy = '1')  then bgcyc  := bgcyc + 1;  end if;
         if (a_objbusy = '1') then objcyc := objcyc + 1; end if;
         if (a_busy = '1') then
            if (prev_abusy = '0') then
               linecyc := 1; linebg := 0; lineobj := 0; linevr := 0;
               lineobjq := 0;
               linestart := a_line;
            else
               linecyc := linecyc + 1;
            end if;
            if (a_bgbusy = '1')  then linebg  := linebg + 1;  end if;
            if (a_objbusy = '1') then lineobj := lineobj + 1; end if;
            if (a_rbusy = '1')   then linevr  := linevr + 1;  end if;
            -- The OBJ channel holds req until its done pulse, so this is exactly
            -- the time the OBJ drawer spent STALLED on a VRAM round trip. Against
            -- `obj` it splits the drawer's cost into round-trip stall and its own
            -- work, which is what bounds the accept-protocol rework: only the
            -- stall part can be pipelined away.
            if (a_obj = '1')     then lineobjq := lineobjq + 1; end if;
         end if;
         -- PER-LINE cost profile for the top of one steady-state frame. The
         -- averages say a line costs ~1300 of 2130 and yet the same three lines
         -- drop every frame, so the average is the wrong statistic entirely -
         -- this is the distribution that explains it.
         if (a_busy = '0' and prev_abusy = '1' and frames = LINEPROF_FRAME and
             linestart < 16) then
            report "LINEPROF line " & integer'image(linestart) &
                   " busy=" & integer'image(linecyc) &
                   " bg=" & integer'image(linebg) &
                   " obj=" & integer'image(lineobj) &
                   " obj-vramstall=" & integer'image(lineobjq) &
                   " rvram=" & integer'image(linevr) &
                   " (budget 2130)" severity note;
         end if;
         -- engine B, same shape as engine A above
         if (b_busy = '1') then
            if (prev_bbusy = '0') then
               linecyc_b := 1; linebg_b := 0; lineobj_b := 0; lineobjq_b := 0;
               linestart_b := a_line;
            else
               linecyc_b := linecyc_b + 1;
            end if;
            if (b_bgbusy = '1')  then linebg_b  := linebg_b + 1;  end if;
            if (b_objbusy = '1') then lineobj_b := lineobj_b + 1; end if;
            if (b_obj = '1')     then lineobjq_b := lineobjq_b + 1; end if;
         end if;
         if (b_busy = '0' and prev_bbusy = '1' and frames = LINEPROF_FRAME and
             linestart_b < 16) then
            report "LINEPROF-B line " & integer'image(linestart_b) &
                   " busy=" & integer'image(linecyc_b) &
                   " bg=" & integer'image(linebg_b) &
                   " obj=" & integer'image(lineobj_b) &
                   " obj-vramstall=" & integer'image(lineobjq_b) &
                   " (budget 2130)" severity note;
         end if;
         if (a_draw = '1' and b_busy = '1') then
            drops_b_r := drops_b_r + 1;
            if (drops_b_r <= 12) then
               report "DROP engine B: line " & integer'image(a_line) &
                      " (frame " & integer'image(frames) & ")" &
                      "  cur-line busy so far=" & integer'image(linecyc_b) severity note;
            end if;
         end if;
         if (a_busy = '1' and prev_abusy = '0') then starts_a := starts_a + 1; end if;
         if (b_busy = '1' and prev_bbusy = '0') then starts_b := starts_b + 1; end if;
         -- renders STARTED is a rising-edge count, so a renderer that never goes
         -- idle reports ONE render per frame however many lines it actually
         -- finished - which reads exactly like a wedge and is not one. These two
         -- say what really happened: line renders COMPLETED (falling edges) and
         -- drawlines DROPPED because the previous line was still busy.
         if (a_busy = '0' and prev_abusy = '1') then dones_a := dones_a + 1; end if;
         if (a_draw = '1' and a_busy = '1')     then
            drops_a := drops_a + 1;
            -- WHICH lines drop, not just how many. A count alone cannot tell a
            -- cold-start transient at the top of the frame from an overloaded
            -- scene, and those want completely different fixes. Capped so a
            -- badly overloaded run does not bury the report.
            if (drops_a <= 12) then
               report "DROP engine A: line " & integer'image(a_line) &
                      " (frame " & integer'image(frames) & ")" &
                      "  epfill=" & to_string(a_epf) &
                      " dma_bus=" & to_string(a_dmab) &
                      "  cur-line busy so far=" & integer'image(linecyc) severity note;
            end if;
         end if;
         prev_abusy := a_busy;
         prev_bbusy := b_busy;
         if (vblank_out = '1' and cyc > 1000) then
            frames := frames + 1;
            -- lines can legitimately be 0 before the GPU starts issuing
            -- drawline; guard the divisions rather than special-casing later
            if (lines = 0) then nlines := 1; else nlines := lines; end if;
            if (starts_a = 0) then nstarts := 1; else nstarts := starts_a; end if;
            report "VRAMOPS frame " & integer'image(frames) &
                   " ops=" & integer'image(ops) &
                   " cycles=" & integer'image(cyc) &
                   " ops/line=" & integer'image(ops / 263) &
                   " rvram_busy%=" & integer'image(blocked * 100 / cyc) &
                   " (A " & integer'image(blk_a * 100 / cyc) &
                   " / B " & integer'image(blk_b * 100 / cyc) & ")" &
                   "  lines=" & integer'image(lines) &
                   " busy/line A=" & integer'image(busy_a / nlines) &
                   " B=" & integer'image(busy_b / nlines) &
                   "  renders=" & integer'image(starts_a) &
                   " done=" & integer'image(dones_a) &
                   " dropped=" & integer'image(drops_a) &
                   " cyc/render A=" & integer'image(busy_a / nstarts) &
                   " (budget 2130, " &
                   integer'image(busy_a / (nstarts * 256)) &
                   " cyc/dot)" &
                   "  OBJ px_color=" & integer'image(objpx_all) &
                   " px_settings=" & integer'image(objpxs_all) &
                   "  bg/render=" & integer'image(bgcyc / nstarts) &
                   " obj/render=" & integer'image(objcyc / nstarts) severity note;
            ops := 0;
            cyc := 0;
            blocked := 0;
            blk_a := 0;
            blk_b := 0;
            busy_a := 0;
            busy_b := 0;
            lines := 0;
            starts_a := 0;
            starts_b := 0;
            dones_a := 0;
            drops_a := 0;
            objpx_all := 0; objpxs_all := 0;
            bgcyc := 0;
            objcyc := 0;
         end if;
      end loop;
   end process;

   -- ============ ARM7 firmware-boot instruments (ARM7DBG /= 0) ============
   garm7dbg : if ARM7DBG /= 0 generate

      -- ---- IRQ census. irq_in7 is the per-source pulse vector nds_irq ORs into
      -- IF; cpu7_irq is a delivery. Counts per source over the whole boot are
      -- directly comparable with the oracle, and a source that fires here and
      -- never there is the answer to next step 1.
      p_irq7log : process (clk1x)
         alias a_irqin7 is << signal .tb_top_frame.idut.irq_in7 : std_logic_vector(31 downto 0) >>;
         alias a_irq7   is << signal .tb_top_frame.idut.cpu7_irq : std_logic >>;
         alias a_ie7    is << signal .tb_top_frame.idut.irq7_dbg_ie  : std_logic_vector(31 downto 0) >>;
         alias a_if7    is << signal .tb_top_frame.idut.irq7_dbg_if  : std_logic_vector(31 downto 0) >>;
         alias a_ime7   is << signal .tb_top_frame.idut.irq7_dbg_ime : std_logic_vector(31 downto 0) >>;
         variable src   : integer_vector(0 to 31) := (others => 0);
         variable deliv : natural := 0;
         variable prev  : std_logic := '0';
         variable cyc   : natural := 0;
         variable l     : line;
      begin
         if rising_edge(clk1x) then
            for i in 0 to 31 loop
               if (a_irqin7(i) = '1') then src(i) := src(i) + 1; end if;
            end loop;
            if (a_irq7 = '1' and prev = '0') then
               deliv := deliv + 1;
               -- the first few in full; after that the counters carry it
               if (deliv <= 32) then
                  report "IRQ7 deliver #" & integer'image(deliv) &
                         " IF=" & to_hstring(a_if7) & " IE=" & to_hstring(a_ie7) &
                         " IME=" & to_hstring(a_ime7) &
                         " pc=" & to_hstring(dbg_export7.pc) severity note;
               end if;
            end if;
            prev := a_irq7;

            -- census every 10 ms of DS time; a source firing here and not in the
            -- oracle shows up as a count that has no business being non-zero
            cyc := cyc + 1;
            if (cyc = 335140) then
               cyc := 0;
               write(l, string'("IRQ7 census deliveries="));
               write(l, deliv);
               for i in 0 to 31 loop
                  if (src(i) /= 0) then
                     write(l, string'("  b"));
                     write(l, i);
                     write(l, string'("="));
                     write(l, src(i));
                  end if;
               end loop;
               report l.all severity note;
               deallocate(l);
            end if;
         end if;
      end process;

      -- ---- Write watch on the faulting word, in BOTH memories it can live in.
      -- This is the part that is easy to get half right: which storage an ARM7
      -- fetch from 0x037FE28C lands in depends on WRAMCNT. melonDS's ARM7 read
      -- of the 0x03000000 region is
      --     if (SWRAM_ARM7.Mem) SWRAM_ARM7.Mem[addr & SWRAM_ARM7.Mask]
      --     else                ARM7WRAM[addr & 0xFFFF]
      -- and nds_membus7 decodes the same way (`cpu_adr(23) = '1' or
      -- wsh_mapped = '0'` picks ARM7-WRAM). So watching only ARM7-WRAM 0xE28C
      -- would have watched the wrong memory for a whole 4.5 h run if the
      -- firmware runs with shared WRAM mapped to the ARM7. Both are watched, and
      -- WRAMCNT is printed so the census says which one was live.
      --
      -- w7m_* is the ARM7-WRAM write port after the loader mux, so it sees CPU
      -- stores and nds_loader staging both; wsh7/wsh9 are nds_wram's two ports.
      -- The shadow copies are what make "nothing ever wrote it" reportable -
      -- there is no way to read the BRAMs back from here - and that answer would
      -- be just as decisive as a wrong value: the fault would then be executing
      -- WRAM nobody filled.
      p_wramwatch : process (clk1x)
         alias a_we    is << signal .tb_top_frame.idut.w7m_we        : std_logic >>;
         alias a_addr  is << signal .tb_top_frame.idut.w7m_addr      : unsigned(15 downto 2) >>;
         alias a_din   is << signal .tb_top_frame.idut.w7m_writedata : std_logic_vector(31 downto 0) >>;
         alias a_be    is << signal .tb_top_frame.idut.w7m_be        : std_logic_vector(3 downto 0) >>;
         alias s7_ena  is << signal .tb_top_frame.idut.wsh7_ena  : std_logic >>;
         alias s7_rnw  is << signal .tb_top_frame.idut.wsh7_rnw  : std_logic >>;
         alias s7_addr is << signal .tb_top_frame.idut.wsh7_addr : unsigned(14 downto 2) >>;
         alias s7_din  is << signal .tb_top_frame.idut.wsh7_din  : std_logic_vector(31 downto 0) >>;
         alias s9_ena  is << signal .tb_top_frame.idut.i9_wsh_ena : std_logic >>;
         alias s9_rnw  is << signal .tb_top_frame.idut.wsh9_rnw   : std_logic >>;
         alias s9_addr is << signal .tb_top_frame.idut.wsh9_addr  : unsigned(14 downto 2) >>;
         alias s9_din  is << signal .tb_top_frame.idut.wsh9_din   : std_logic_vector(31 downto 0) >>;
         alias a_wcnt  is << signal .tb_top_frame.idut.wramcnt : std_logic_vector(1 downto 0) >>;
         -- the watched word plus three either side in each memory, so a copy loop
         -- that lands next to it rather than on it is still visible
         constant P_LO : integer := (ARM7WATCH mod 65536) / 4 - 3;   -- ARM7 WRAM, &0xFFFF
         constant P_HI : integer := (ARM7WATCH mod 65536) / 4 + 3;
         constant S_LO : integer := (ARM7WATCH mod 32768) / 4 - 3;   -- shared WRAM, &0x7FFF
         constant S_HI : integer := (ARM7WATCH mod 32768) / 4 + 3;
         -- shadows are std_logic_vector, NOT integer: to_integer on a word with
         -- bit 31 set overflows VHDL's 32-bit signed INTEGER and kills the run
         -- (it killed one at 1.070 s, 35 minutes in, on the first write it saw).
         type t_shadow is array (integer range <>) of std_logic_vector(31 downto 0);
         variable pshad : t_shadow(P_LO to P_HI) := (others => (others => '0'));
         variable sshad : t_shadow(S_LO to S_HI) := (others => (others => '0'));
         variable pwrit : integer_vector(P_LO to P_HI) := (others => 0);
         variable swrit : integer_vector(S_LO to S_HI) := (others => 0);
         variable idx    : integer;
         variable hits   : natural := 0;
         variable cyc    : natural := 0;
         variable l      : line;
      begin
         if rising_edge(clk1x) then
            -- ARM7-private WRAM
            if (a_we = '1') then
               idx := to_integer(a_addr);
               if (idx >= P_LO and idx <= P_HI) then
                  hits := hits + 1;
                  pwrit(idx) := pwrit(idx) + 1;
                  pshad(idx) := a_din;
                  if (hits <= 64) then
                     report "WRAMWATCH arm7wram byte=" & integer'image(idx * 4) &
                            " data=" & to_hstring(a_din) & " be=" & to_string(a_be) &
                            " wramcnt=" & to_string(a_wcnt) &
                            " pc7=" & to_hstring(dbg_export7.pc) severity note;
                  end if;
               end if;
            end if;
            -- shared WRAM, either port (the ARM9 can only reach it here, and if
            -- the ARM9 is the one filling the ARM7's handler that is the finding)
            if (s7_ena = '1' and s7_rnw = '0') then
               idx := to_integer(s7_addr);
               if (idx >= S_LO and idx <= S_HI) then
                  hits := hits + 1;
                  swrit(idx) := swrit(idx) + 1;
                  sshad(idx) := s7_din;
                  if (hits <= 64) then
                     report "WRAMWATCH shared(arm7) byte=" & integer'image(idx * 4) &
                            " data=" & to_hstring(s7_din) &
                            " wramcnt=" & to_string(a_wcnt) &
                            " pc7=" & to_hstring(dbg_export7.pc) severity note;
                  end if;
               end if;
            end if;
            if (s9_ena = '1' and s9_rnw = '0') then
               idx := to_integer(s9_addr);
               if (idx >= S_LO and idx <= S_HI) then
                  hits := hits + 1;
                  swrit(idx) := swrit(idx) + 1;
                  sshad(idx) := s9_din;
                  if (hits <= 64) then
                     report "WRAMWATCH shared(arm9) byte=" & integer'image(idx * 4) &
                            " data=" & to_hstring(s9_din) &
                            " wramcnt=" & to_string(a_wcnt) &
                            " pc9=" & to_hstring(dbg_export9.pc) severity note;
                  end if;
               end if;
            end if;

            cyc := cyc + 1;
            if (cyc = 3351398) then   -- every 100 ms of DS time
               cyc := 0;
               write(l, string'("WRAMWATCH writes="));
               write(l, hits);
               write(l, string'(" wramcnt="));
               write(l, to_string(a_wcnt));
               write(l, string'("  arm7wram:"));
               for i in P_LO to P_HI loop
                  write(l, string'(" ["));
                  write(l, i * 4);
                  write(l, string'("]="));
                  if (pwrit(i) = 0) then
                     write(l, string'("never"));
                  else
                     write(l, to_hstring(pshad(i)));
                     write(l, string'("/"));
                     write(l, pwrit(i));
                  end if;
               end loop;
               write(l, string'("  shared:"));
               for i in S_LO to S_HI loop
                  write(l, string'(" ["));
                  write(l, i * 4);
                  write(l, string'("]="));
                  if (swrit(i) = 0) then
                     write(l, string'("never"));
                  else
                     write(l, to_hstring(sshad(i)));
                     write(l, string'("/"));
                     write(l, swrit(i));
                  end if;
               end loop;
               report l.all severity note;
               deallocate(l);
            end if;
         end if;
      end process;

   end generate;

   -- ============ ARM7 runaway-PC catcher (ARM7RUNAWAY /= 0) ============
   garm7runaway : if ARM7RUNAWAY /= 0 generate
      p_runaway : process (clk1x)
         constant DEPTH : integer := 96;
         type t_ring is array (0 to DEPTH - 1) of std_logic_vector(31 downto 0);
         variable rpc, rop, rps : t_ring := (others => (others => '0'));
         variable rtm  : integer_vector(0 to DEPTH - 1) := (others => 0);
         variable head : integer := 0;
         variable n    : natural := 0;
         variable fired : boolean := false;
         variable idx   : integer;
         variable l     : line;
      begin
         if rising_edge(clk1x) then
            if (dbg_export7_done = '1') then
               if (not fired) then
                  rpc(head) := std_logic_vector(dbg_export7.pc);
                  rop(head) := std_logic_vector(dbg_export7.opcode);
                  rps(head) := std_logic_vector(dbg_export7.CPSR);
                  -- us, not ns and certainly not fs: VHDL INTEGER is 32-bit
                  -- signed, so ns overflows past ~2.1 s of simulated time and fs
                  -- overflows in 2 us. A 32-bit value in an INTEGER already
                  -- killed one 35-minute run on this ticket. The exact instant is
                  -- printed with time'image in the header line; the ring index is
                  -- what gives the ordering.
                  rtm(head) := now / 1 us;
                  head := (head + 1) mod DEPTH;
                  if (n < DEPTH) then n := n + 1; end if;

                  if (dbg_export7.pc >= unsigned'(x"04000000")) then
                     fired := true;
                     report "ARM7RUNAWAY: pc=" & to_hstring(dbg_export7.pc) &
                            " at " & time'image(now) &
                            " - dumping the " & integer'image(n) &
                            " retires that led here (oldest first)" severity note;
                     for i in 0 to n - 1 loop
                        idx := (head + DEPTH - n + i) mod DEPTH;
                        write(l, string'("  R7 "));
                        write(l, i - (n - 1));            -- 0 is the offending one
                        write(l, string'("  t="));
                        write(l, rtm(idx));
                        write(l, string'("us pc="));
                        write(l, to_hstring(rpc(idx)));
                        write(l, string'(" op="));
                        write(l, to_hstring(rop(idx)));
                        write(l, string'(" cpsr="));
                        write(l, to_hstring(rps(idx)));
                        report l.all severity note;
                        deallocate(l);
                     end loop;
                     -- Stop here. Letting it run costs hours and lands on an
                     -- unrelated instruction, which is exactly how this bug got
                     -- diagnosed at the wrong address twice.
                     report "ARM7RUNAWAY: stopping at the point of departure" severity failure;
                  end if;
               end if;
            end if;
         end if;
      end process;
   end generate;

   -- ============ engine-A stall probe (STALL_CYC > 0) ============
   -- Names the party that is waiting. The chain is
   --   text drawer -> gpu2d BG arbiter -> nds_vram queue -> rsrv channel
   -- and every layer is a one-deep present/accept handshake over a latch, so a
   -- lost request or a lost done anywhere in it looks identical from outside:
   -- line_busy never falls. Each layer's occupancy is printed so the first one
   -- holding something that will never complete is visible directly.
   gstall : if STALL_CYC > 0 generate
      p_stall : process (clk1x)
         alias s_rdisp is << signal .tb_top_frame.idut.ivram.rdispatch : std_logic >>;
         alias s_rpick is << signal .tb_top_frame.idut.ivram.rpick : integer range 0 to 7 >>;
         variable busy_run : natural := 0;
         -- where the renderer's service actually went during this line: one
         -- counter per nds_vram renderer channel, in rpick order
         --   0 bgA 1 objA 2 bgepA 3 objepA 4 bgB 5 objB 6 bgepB 7 objepB
         variable chan_ops : integer_vector(0 to 7) := (others => 0);
         variable tot_ops  : natural := 0;
      begin
         if rising_edge(clk1x) then
            if (<< signal .tb_top_frame.idut.line_busy : std_logic >> = '1') then
               busy_run := busy_run + 1;
            else
               busy_run := 0;
               chan_ops := (others => 0);
               tot_ops  := 0;
            end if;
            if (s_rdisp = '1') then
               chan_ops(s_rpick) := chan_ops(s_rpick) + 1;
               tot_ops := tot_ops + 1;
            end if;
            if (busy_run = STALL_CYC) then
               report "STALL: engine A busy " & integer'image(busy_run) & " cycles" & LF &
                  "  gpu2d: busy_text=" & to_string(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.busy_text : std_logic_vector(0 to 3) >>) &
                  " obj_busy=" & to_string(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.obj_busy : std_logic >>) &
                  " cur_y=" & integer'image(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.cur_y : integer range 0 to 191 >>) & LF &
                  "  arb: bgv_req=" & to_string(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.bgv_req : std_logic_vector(0 to 3) >>) &
                  " bgv_done=" & to_string(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.bgv_done : std_logic_vector(0 to 3) >>) &
                  " pending=" & to_string(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.b_arb.pending : std_logic_vector(0 to 3) >>) &
                  " unaccepted=" & to_string(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.b_arb.unaccepted : std_logic >>) &
                  " os_count=" & integer'image(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.b_arb.os_count : integer range 0 to 8 >>) & LF &
                  "  text0: tq=" & integer'image(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.gen_text(0).itext.tq_count : integer range 0 to 4 >>) &
                  " tag=" & integer'image(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.gen_text(0).itext.tag_count : integer range 0 to 8 >>) &
                  " f_tile=" & integer'image(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.gen_text(0).itext.f_tile : integer range 0 to 33 >>) &
                  " unacc=" & to_string(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.gen_text(0).itext.unaccepted : std_logic >>) &
                  " p_active=" & to_string(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.gen_text(0).itext.p_active : std_logic >>) &
                  " p_x=" & integer'image(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.gen_text(0).itext.p_x : integer range 0 to 256 >>) & LF &
                  "  text1: tq=" & integer'image(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.gen_text(1).itext.tq_count : integer range 0 to 4 >>) &
                  " tag=" & integer'image(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.gen_text(1).itext.tag_count : integer range 0 to 8 >>) &
                  " f_tile=" & integer'image(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.gen_text(1).itext.f_tile : integer range 0 to 33 >>) &
                  " unacc=" & to_string(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.gen_text(1).itext.unaccepted : std_logic >>) &
                  " p_active=" & to_string(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.gen_text(1).itext.p_active : std_logic >>) & LF &
                  "  text2: tq=" & integer'image(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.gen_text(2).itext.tq_count : integer range 0 to 4 >>) &
                  " tag=" & integer'image(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.gen_text(2).itext.tag_count : integer range 0 to 8 >>) &
                  " unacc=" & to_string(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.gen_text(2).itext.unaccepted : std_logic >>) &
                  "  text3: tq=" & integer'image(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.gen_text(3).itext.tq_count : integer range 0 to 4 >>) &
                  " tag=" & integer'image(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.gen_text(3).itext.tag_count : integer range 0 to 8 >>) &
                  " unacc=" & to_string(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.gen_text(3).itext.unaccepted : std_logic >>) & LF &
                  "  vram: rq_count=" & integer'image(<< signal .tb_top_frame.idut.ivram.rq_count : integer range 0 to 8 >>) &
                  " adq_count=" & integer'image(<< signal .tb_top_frame.idut.ivram.adq_count : integer range 0 to 4 >>) &
                  " rdispatch=" & to_string(<< signal .tb_top_frame.idut.ivram.rdispatch : std_logic >>) &
                  " rpick=" & integer'image(<< signal .tb_top_frame.idut.ivram.rpick : integer range 0 to 7 >>) &
                  " rpend=" & to_string(<< signal .tb_top_frame.idut.ivram.rpend : std_logic_vector(7 downto 0) >>) &
                  " rreq_now=" & to_string(<< signal .tb_top_frame.idut.ivram.rreq_now : std_logic_vector(7 downto 0) >>) & LF &
                  "  rsrv: req=" & to_string(vrsrv_req) & " ready=" & to_string(vrsrv_ready_s) &
                  " done=" & to_string(vrsrv_done) & " busy_m=" & to_string(vrsrv_busy_m) &
                  " bank=" & to_string(vrsrv_bank) & " addr=" & to_hstring(vrsrv_addr) & LF &
                  "  epfill: A=" & to_string(<< signal .tb_top_frame.idut.igpu2d_a.gslow.igpu.epfill_busy : std_logic >>) &
                  " B=" & to_string(<< signal .tb_top_frame.idut.igpu2d_b.gslow.igpu.epfill_busy : std_logic >>) & LF &
                  "  dispatches this line: total=" & integer'image(tot_ops) &
                  "  bgA=" & integer'image(chan_ops(0)) &
                  " objA=" & integer'image(chan_ops(1)) &
                  " bgepA=" & integer'image(chan_ops(2)) &
                  " objepA=" & integer'image(chan_ops(3)) &
                  "  bgB=" & integer'image(chan_ops(4)) &
                  " objB=" & integer'image(chan_ops(5)) &
                  " bgepB=" & integer'image(chan_ops(6)) &
                  " objepB=" & integer'image(chan_ops(7))
                  severity failure;
            end if;
         end if;
      end process;
   end generate;

   -- Video-mode registers, reported when they CHANGE. The melonDS side of this
   -- (VIDLOG in main_fbdump) is what turned "is the screen white because the
   -- renderer is broken or because the display is off" from a guess into one
   -- grep, and the RTL bench had no equivalent: the only way to ask was to dump
   -- hundreds of 49,152-line framebuffers and diff them. DISPCNT mode 0 with
   -- POWCNT1 clear is display OFF and renders uniform white, which is the
   -- hardware behaving correctly.
   --   0x000 engine A DISPCNT, 0x1000 engine B DISPCNT, 0x304 POWCNT1
   -- Snoops ARM9 IO writes rather than reading the registers, so it needs no
   -- new ports; a register the CPU never writes stays at its reset value and is
   -- reported as such by the first line.
   p_vidlog : process
      alias a_io9 is << signal .tb_top_frame.idut.io_bus9 : proc_bus_gb_type >>;
      variable da, db, pw : std_logic_vector(31 downto 0) := (others => '0');
      variable chg : boolean;
   begin
      loop
         wait until rising_edge(clk1x);
         chg := false;
         -- only on an actual VALUE change: games rewrite DISPCNT every frame,
         -- and reporting each write buries the one line that matters
         if (a_io9.ena = '1' and a_io9.rnw = '0') then
            if (a_io9.Adr = x"0000000" and a_io9.Din /= da) then
               da := a_io9.Din; chg := true;
            elsif (a_io9.Adr = x"0001000" and a_io9.Din /= db) then
               db := a_io9.Din; chg := true;
            elsif (a_io9.Adr = x"0000304" and a_io9.Din /= pw) then
               pw := a_io9.Din; chg := true;
            end if;
         end if;
         if (chg) then
            report "VIDLOG " & time'image(now) &
                   " DISPCNT_A=" & to_hstring(da) &
                   " DISPCNT_B=" & to_hstring(db) &
                   " POWCNT1="   & to_hstring(pw) severity note;
         end if;
      end loop;
   end process;

   -- Both CPUs' PCs on a slow tick, plus a retired-instruction count each.
   -- Long untraced runs (a firmware boot is tens of millions of instructions,
   -- and TRACEFILE costs ~40x) otherwise give no way to tell "grinding through
   -- a boot stage" from "wedged in a polling loop": the IO counters keep rising
   -- in both cases. Two PCs and two counts distinguish them in one line.
   -- HEARTBEAT_MS = 0 disables it.
   p_heartbeat : process
      variable n9, n7 : natural := 0;
      variable p9, p7 : natural := 0;
      variable pc9, pc7 : unsigned(31 downto 0) := (others => '0');
   begin
      if (HEARTBEAT_MS = 0) then
         wait;
      end if;
      loop
         -- clk1x is clkMem/3 = 33.33 MHz, so 33333 edges is 1.0 ms of DS time.
         -- Every edge has to be visited anyway to count retires.
         for i in 1 to HEARTBEAT_MS loop
            for j in 1 to 33333 loop
               wait until rising_edge(clk1x);
               -- Latch each PC on its own retire pulse. The export registers are
               -- only meaningful when *_done pulses; sampling them at an
               -- arbitrary cycle returns stale or half-updated values. That is
               -- not theoretical - it printed ARM7 pc=E0B2D060, an instruction
               -- word where an address should be, which reads exactly like the
               -- CPU having jumped into garbage and is nothing of the kind.
               if (dbg_export9_done = '1') then
                  n9 := n9 + 1;
                  pc9 := dbg_export9.pc;
               end if;
               if (dbg_export7_done = '1') then
                  n7 := n7 + 1;
                  pc7 := dbg_export7.pc;
               end if;
            end loop;
         end loop;
         report "HB " & time'image(now) &
                "  ARM9 pc=" & to_hstring(pc9) & " n=" & integer'image(n9) &
                " (+" & integer'image(n9 - p9) & ")" &
                "  ARM7 pc=" & to_hstring(pc7) & " n=" & integer'image(n7) &
                " (+" & integer'image(n7 - p7) & ")" severity note;
         p9 := n9;
         p7 := n7;
      end loop;
   end process;

   p_clrorder : process
      alias a_vclr  is << signal .tb_top_frame.idut.vclr_busy   : std_logic >>;
      alias a_pclra is << signal .tb_top_frame.idut.pclr_busy_a : std_logic >>;
      alias a_pclrb is << signal .tb_top_frame.idut.pclr_busy_b : std_logic >>;
      alias a_ldd   is << signal .tb_top_frame.idut.ld_done     : std_logic >>;
      alias a_ldb   is << signal .tb_top_frame.idut.ld_busy     : std_logic >>;
      alias a_rstc  is << signal .tb_top_frame.idut.resetCpu    : std_logic >>;
      variable t_pal, t_vram, t_load : time := 0 ns;
   begin
      wait until rising_edge(clk1x) and (a_pclra = '0' and a_pclrb = '0');
      t_pal := now;
      report "CLRORDER: palette/OAM clear done at " & time'image(t_pal) severity note;

      wait until rising_edge(clk1x) and a_vclr = '0';
      t_vram := now;
      report "CLRORDER: VRAM clear done at " & time'image(t_vram) severity note;

      wait until rising_edge(clk1x) and a_rstc = '0';
      report "CLRORDER: CPUs released at " & time'image(now) &
             " (VRAM clear finished " & time'image(now - t_vram) & " earlier)" severity note;
      assert now > t_vram and now > t_pal
         report "CPUs released before the clear passes finished" severity failure;
      wait;
   end process;

   -- when did the loader itself finish? together with the two above this says
   -- whether the clear or the loader gates the release
   p_ldorder : process
      alias a_ldd is << signal .tb_top_frame.idut.ld_done : std_logic >>;
      alias a_ldb is << signal .tb_top_frame.idut.ld_busy : std_logic >>;
   begin
      wait until rising_edge(clk1x) and a_ldd = '1' and a_ldb = '0';
      report "CLRORDER: loader done at " & time'image(now) severity note;
      wait;
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
         end if;
         -- per engine, because the combined count cannot size the renderer work:
         -- engine B runs the simpler configuration in Kirby's mode, so which
         -- engine is behind changes what has to get faster
         if (dbg_line_drop_a = '1') then drops_a <= drops_a + 1; end if;
         if (dbg_line_drop_b = '1') then drops_b <= drops_b + 1; end if;
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
                integer'image(drops) & " (A " & integer'image(drops_a) &
                " / B " & integer'image(drops_b) & ")" severity note;
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
