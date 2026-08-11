-- Randomized torture test for nds_vram + nds_wram (roadmap M1).
--
-- Drives random read/write ops from both CPU ports through the real datapath
-- (E..I BRAM banks + behavioral A..D server with random latency), interleaved
-- with random VRAMCNT/WRAMCNT reconfiguration, and compares every read against
-- a byte-accurate behavioral model. The decode itself is trusted (unit-tested
-- in tb_vram_map); this bench targets storage, OR/fan-out, BE handling, the
-- server handshake and the WRAM block mapping.
--
-- Op count via generic OPCOUNT (override: nvc -e tb_vram_torture -gOPCOUNT=...).
--
-- The last phase is the reset-clear check. nds_vram zeroes all nine banks out of
-- reset (the VRAM half of the "firmware boot we skip" clearing that nds_loader's
-- CLR_WR does for main RAM), because a MiSTer ROM change does not reconfigure
-- the FPGA and the previous game's VRAM would otherwise show through. Sim
-- memories start at zero, so a clear pass looks like it works whether or not it
-- exists - this phase therefore PRE-DIRTIES every bank with a non-zero pattern
-- through the CPU port (all nine mapped at once in LCDC mode), asserts that the
-- pattern really landed, then re-asserts reset and requires every probe to read
-- back zero. Disable the CLR_* states in nds_vram and this phase fails.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.pnds_vram_map.all;

entity tb_vram_torture is
   generic
   (
      OPCOUNT : integer := 20000;
      SEED    : integer := 1
   );
end entity;

architecture sim of tb_vram_torture is

   signal clk   : std_logic := '0';
   signal reset : std_logic := '1';

   signal vramcnt : std_logic_vector(71 downto 0) := (others => '0');
   signal wramcnt : std_logic_vector(1 downto 0)  := "00";

   -- DUT: nds_vram
   signal cpu9_ena, cpu9_rnw, cpu9_done : std_logic := '0';
   signal cpu9_addr : unsigned(23 downto 2) := (others => '0');
   signal cpu9_be   : std_logic_vector(3 downto 0) := (others => '0');
   signal cpu9_din, cpu9_dout : std_logic_vector(31 downto 0) := (others => '0');
   signal cpu9_wpost : std_logic := '0';
   signal cpu9_welig, cpu9_wok : std_logic;

   signal cpu7_ena, cpu7_rnw, cpu7_done : std_logic := '0';
   signal cpu7_addr : unsigned(23 downto 2) := (others => '0');
   signal cpu7_be   : std_logic_vector(3 downto 0) := (others => '0');
   signal cpu7_din, cpu7_dout : std_logic_vector(31 downto 0) := (others => '0');

   signal clr_busy : std_logic;

   signal srv_req, srv_rnw, srv_done : std_logic := '0';
   signal srv_bank : std_logic_vector(1 downto 0);
   signal srv_addr : unsigned(16 downto 2);
   signal srv_be   : std_logic_vector(3 downto 0);
   signal srv_din, srv_dout : std_logic_vector(31 downto 0) := (others => '0');

   -- DUT: nds_wram
   signal w9_ena, w9_rnw, w9_done, w9_mapped : std_logic := '0';
   signal w9_addr : unsigned(14 downto 2) := (others => '0');
   signal w9_be   : std_logic_vector(3 downto 0) := (others => '0');
   signal w9_din, w9_dout : std_logic_vector(31 downto 0) := (others => '0');

   signal w7_ena, w7_rnw, w7_done, w7_mapped : std_logic := '0';
   signal w7_addr : unsigned(14 downto 2) := (others => '0');
   signal w7_be   : std_logic_vector(3 downto 0) := (others => '0');
   signal w7_din, w7_dout : std_logic_vector(31 downto 0) := (others => '0');

   -- expected-decode probe (same DUT decoder entity, tb-driven)
   signal exp_addr : unsigned(23 downto 0) := (others => '0');
   signal exp_arm7 : std_logic := '0';
   signal exp_hit  : std_logic_vector(8 downto 0);
   signal exp_offs : t_vram_offs;

   signal tests_done : boolean := false;

   procedure rnd(variable s : inout unsigned(31 downto 0)) is
   begin
      s := s xor shift_left(s, 13);
      s := s xor shift_right(s, 17);
      s := s xor shift_left(s, 5);
   end procedure;

begin

   clk <= not clk after 5 ns when not tests_done else '0';

   ivram : entity work.nds_vram
   generic map ( is_simu => '1' )
   port map
   (
      clk => clk, reset => reset, vramcnt => vramcnt,
      cpu9_ena => cpu9_ena, cpu9_rnw => cpu9_rnw, cpu9_addr => cpu9_addr,
      cpu9_be => cpu9_be, cpu9_din => cpu9_din, cpu9_dout => cpu9_dout, cpu9_done => cpu9_done,
      cpu9_wpost => cpu9_wpost, cpu9_welig => cpu9_welig, cpu9_wok => cpu9_wok,
      cpu7_ena => cpu7_ena, cpu7_rnw => cpu7_rnw, cpu7_addr => cpu7_addr,
      cpu7_be => cpu7_be, cpu7_din => cpu7_din, cpu7_dout => cpu7_dout, cpu7_done => cpu7_done,
      srv_req => srv_req, srv_rnw => srv_rnw, srv_bank => srv_bank, srv_addr => srv_addr,
      srv_be => srv_be, srv_din => srv_din, srv_dout => srv_dout, srv_done => srv_done,
      clr_busy => clr_busy
   );

   iwram : entity work.nds_wram
   generic map ( is_simu => '1' )
   port map
   (
      clk => clk, wramcnt => wramcnt,
      arm9_ena => w9_ena, arm9_rnw => w9_rnw, arm9_addr => w9_addr, arm9_be => w9_be,
      arm9_din => w9_din, arm9_dout => w9_dout, arm9_done => w9_done, arm9_mapped => w9_mapped,
      arm7_ena => w7_ena, arm7_rnw => w7_rnw, arm7_addr => w7_addr, arm7_be => w7_be,
      arm7_din => w7_din, arm7_dout => w7_dout, arm7_done => w7_done, arm7_mapped => w7_mapped
   );

   iexpdec : entity work.nds_vram_map
   port map ( vramcnt => vramcnt, addr => exp_addr, is_arm7 => exp_arm7, hit => exp_hit, offs => exp_offs );

   -- ============ behavioral A..D server: random 1..8 cycle latency ============
   pserver : process
      type t_bankmem is array (0 to 32767) of std_logic_vector(31 downto 0);
      type t_srvmem is array (0 to 3) of t_bankmem;
      variable mem : t_srvmem := (others => (others => (others => '0')));
      variable rs  : unsigned(31 downto 0) := to_unsigned(98765, 32);
      variable lat : integer;
      variable b   : integer;
      variable w   : integer;
   begin
      wait until rising_edge(clk) and srv_req = '1';
      rnd(rs);
      lat := 1 + to_integer(rs(2 downto 0));
      for k in 1 to lat loop
         wait until rising_edge(clk);
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
      wait until rising_edge(clk);
      srv_done <= '0';
   end process;

   -- ============ stimulus + behavioral model ============
   pmain : process
      type t_bankmem is array (0 to 32767) of std_logic_vector(31 downto 0);
      type t_allmem  is array (0 to 8) of t_bankmem;
      type t_wrammem is array (0 to 8191) of std_logic_vector(31 downto 0);
      variable model  : t_allmem  := (others => (others => (others => '0')));
      variable wmodel : t_wrammem := (others => (others => '0'));

      variable rs      : unsigned(31 downto 0) := to_unsigned((SEED mod 65521)*32749 + 12345, 32);
      variable is7     : boolean;
      variable rnw     : boolean;
      variable be      : std_logic_vector(3 downto 0);
      variable din     : std_logic_vector(31 downto 0);
      variable a       : unsigned(23 downto 0);
      variable region  : integer;
      variable expdata : std_logic_vector(31 downto 0);
      variable w       : integer;
      variable phys    : integer;
      variable mapped  : boolean;
      variable vramops, wramops, cfgops : integer := 0;

      procedure vram_op is
      begin
         -- generate address: pick a mapped region so hits are frequent
         rnd(rs); region := to_integer(rs(2 downto 0)) mod 5;
         rnd(rs);
         case region is
            when 0 => a := to_unsigned(to_integer(rs(18 downto 0)), 24);                    -- main BG
            when 1 => a := to_unsigned(16#200000# + to_integer(rs(16 downto 0)), 24);       -- sub BG
            when 2 => a := to_unsigned(16#400000# + to_integer(rs(17 downto 0)), 24);       -- main OBJ
            when 3 => a := to_unsigned(16#600000# + to_integer(rs(16 downto 0)), 24);       -- sub OBJ
            when others => a := to_unsigned(16#800000# + to_integer(rs(19 downto 0)) mod 16#A4000#, 24); -- LCDC
         end case;
         a(1 downto 0) := "00";
         rnd(rs); is7 := (rs(0) = '1');
         rnd(rs); rnw := (rs(0) = '1');
         rnd(rs); be  := std_logic_vector(rs(3 downto 0));
         rnd(rs); din := std_logic_vector(rs);

         -- expected decode
         exp_addr <= a;
         if is7 then exp_arm7 <= '1'; else exp_arm7 <= '0'; end if;
         wait for 1 ns;

         -- drive the op
         if is7 then
            cpu7_addr <= a(23 downto 2); cpu7_be <= be; cpu7_din <= din;
            if rnw then cpu7_rnw <= '1'; else cpu7_rnw <= '0'; end if;
            wait until rising_edge(clk);
            cpu7_ena <= '1';
            wait until rising_edge(clk);
            cpu7_ena <= '0';
            wait until rising_edge(clk) and cpu7_done = '1' for 5 us;
            assert cpu7_done = '1' report "cpu7 op timeout" severity failure;
         else
            cpu9_addr <= a(23 downto 2); cpu9_be <= be; cpu9_din <= din;
            if rnw then cpu9_rnw <= '1'; else cpu9_rnw <= '0'; end if;
            wait until rising_edge(clk);
            cpu9_ena <= '1';
            wait until rising_edge(clk);
            cpu9_ena <= '0';
            wait until rising_edge(clk) and cpu9_done = '1' for 5 us;
            assert cpu9_done = '1' report "cpu9 op timeout" severity failure;
         end if;

         -- model update / compare
         if rnw then
            expdata := (others => '0');
            for i in 0 to 8 loop
               if (exp_hit(i) = '1') then
                  expdata := expdata or model(i)(to_integer(exp_offs(i)(16 downto 2)));
               end if;
            end loop;
            if is7 then
               assert cpu7_dout = expdata
                  report "cpu7 read mismatch @" & to_hstring(a) & " got " & to_hstring(cpu7_dout) &
                         " exp " & to_hstring(expdata) & " hits " & to_string(exp_hit)
                  severity failure;
            else
               assert cpu9_dout = expdata
                  report "cpu9 read mismatch @" & to_hstring(a) & " got " & to_hstring(cpu9_dout) &
                         " exp " & to_hstring(expdata) & " hits " & to_string(exp_hit)
                  severity failure;
            end if;
         else
            for i in 0 to 8 loop
               if (exp_hit(i) = '1') then
                  w := to_integer(exp_offs(i)(16 downto 2));
                  for j in 0 to 3 loop
                     if (be(j) = '1') then
                        model(i)(w)(j*8 + 7 downto j*8) := din(j*8 + 7 downto j*8);
                     end if;
                  end loop;
               end if;
            end loop;
         end if;
         vramops := vramops + 1;
      end procedure;

      procedure wram_op is
      begin
         rnd(rs); is7 := (rs(0) = '1');
         rnd(rs); rnw := (rs(1) = '1');
         rnd(rs); be  := std_logic_vector(rs(3 downto 0));
         rnd(rs); din := std_logic_vector(rs);
         rnd(rs); w   := to_integer(rs(12 downto 0));   -- word index in 32 KB space

         -- model mapping (melonDS MapSharedWRAM)
         mapped := true;
         phys   := 0;
         case wramcnt is
            when "00" => if is7 then mapped := false; else phys := w; end if;
            when "01" => if is7 then phys := w mod 4096; else phys := 4096 + (w mod 4096); end if;
            when "10" => if is7 then phys := 4096 + (w mod 4096); else phys := w mod 4096; end if;
            when others => if is7 then phys := w; else mapped := false; end if;
         end case;

         if is7 then
            w7_addr <= to_unsigned(w, 13); w7_be <= be; w7_din <= din;
            if rnw then w7_rnw <= '1'; else w7_rnw <= '0'; end if;
            wait until rising_edge(clk);
            w7_ena <= '1';
            wait until rising_edge(clk);
            w7_ena <= '0';
            wait until rising_edge(clk) and w7_done = '1' for 1 us;
            assert w7_done = '1' report "wram7 op timeout" severity failure;
         else
            w9_addr <= to_unsigned(w, 13); w9_be <= be; w9_din <= din;
            if rnw then w9_rnw <= '1'; else w9_rnw <= '0'; end if;
            wait until rising_edge(clk);
            w9_ena <= '1';
            wait until rising_edge(clk);
            w9_ena <= '0';
            wait until rising_edge(clk) and w9_done = '1' for 1 us;
            assert w9_done = '1' report "wram9 op timeout" severity failure;
         end if;

         if rnw then
            if mapped then expdata := wmodel(phys); else expdata := (others => '0'); end if;
            if is7 then
               assert w7_dout = expdata
                  report "wram7 read mismatch w=" & integer'image(w) & " cnt=" & to_string(wramcnt) &
                         " got " & to_hstring(w7_dout) & " exp " & to_hstring(expdata)
                  severity failure;
            else
               assert w9_dout = expdata
                  report "wram9 read mismatch w=" & integer'image(w) & " cnt=" & to_string(wramcnt) &
                         " got " & to_hstring(w9_dout) & " exp " & to_hstring(expdata)
                  severity failure;
            end if;
         elsif mapped then
            for j in 0 to 3 loop
               if (be(j) = '1') then
                  wmodel(phys)(j*8 + 7 downto j*8) := din(j*8 + 7 downto j*8);
               end if;
            end loop;
         end if;
         wramops := wramops + 1;
      end procedure;

      variable pick : integer;

      -- plain (un-modelled) ARM9 word access, used by the clear-check phase
      procedure cpu9w(byteaddr : integer; data : std_logic_vector(31 downto 0)) is
      begin
         cpu9_addr <= to_unsigned(byteaddr, 24)(23 downto 2);
         cpu9_rnw  <= '0';
         cpu9_be   <= "1111";
         cpu9_din  <= data;
         wait until rising_edge(clk);
         cpu9_ena  <= '1';
         wait until rising_edge(clk);
         cpu9_ena  <= '0';
         wait until rising_edge(clk) and cpu9_done = '1' for 5 us;
         assert cpu9_done = '1' report "clear-check write timeout" severity failure;
      end procedure;

      procedure cpu9r(byteaddr : integer) is
      begin
         cpu9_addr <= to_unsigned(byteaddr, 24)(23 downto 2);
         cpu9_rnw  <= '1';
         cpu9_be   <= "1111";
         wait until rising_edge(clk);
         cpu9_ena  <= '1';
         wait until rising_edge(clk);
         cpu9_ena  <= '0';
         wait until rising_edge(clk) and cpu9_done = '1' for 5 us;
         assert cpu9_done = '1' report "clear-check read timeout" severity failure;
      end procedure;

      -- LCDC layout (nds_vram_map): every bank is CPU-visible at once with
      -- VRAMCNT_x = 0x80 (enabled, MST=0)
      constant NBANK  : integer := 9;
      type t_ia is array (0 to NBANK - 1) of integer;
      constant LCDC_BASE  : t_ia := (16#800000#, 16#820000#, 16#840000#, 16#860000#,
                                     16#880000#, 16#890000#, 16#894000#, 16#898000#, 16#8A0000#);
      constant LCDC_WORDS : t_ia := (32768, 32768, 32768, 32768, 16384, 4096, 4096, 8192, 4096);
      -- Posted A..D writes. cpu9wp drives the port exactly the way nds_dma9 does:
      -- hold wpost, present the access, and treat wok as the acknowledgement -
      -- no cpu9_done follows a posted write. Bank D at LCDC, so the reads below
      -- come back over the same srv channel the queue drains onto.
      constant POST_BASE : integer := 16#860000#;
      -- comfortably more than nds_vram's WQ_DEPTH, so the queue is certainly full
      constant POST_BURST : integer := 8;
      variable postops : integer := 0;
      variable stalls  : integer := 0;

      procedure cpu9wp(byteaddr : integer; be_in : std_logic_vector(3 downto 0);
                       data : std_logic_vector(31 downto 0)) is
         variable guard : integer := 0;
      begin
         cpu9_addr  <= to_unsigned(byteaddr, 24)(23 downto 2);
         cpu9_rnw   <= '0';
         cpu9_be    <= be_in;
         cpu9_din   <= data;
         cpu9_wpost <= '1';
         -- ena goes high only in a cycle where wok is already high. With ena high
         -- and wok low the DUT would - correctly - latch the access as an ordinary
         -- request, and the retry would then perform it twice. nds_dma9 gates its
         -- ena on wok for exactly this reason, so the bench must too.
         loop
            wait until rising_edge(clk);
            exit when cpu9_wok = '1';
            stalls := stalls + 1;
            guard  := guard + 1;
            assert guard < 200 report "posted queue never drained" severity failure;
         end loop;
         assert cpu9_welig = '1'
            report "posted write unexpectedly not eligible @" &
                   to_hstring(to_unsigned(byteaddr, 24))
            severity failure;
         cpu9_ena <= '1';
         wait until rising_edge(clk);
         cpu9_ena   <= '0';
         cpu9_wpost <= '0';
         assert cpu9_done = '0'
            report "posted write also pulsed cpu9_done: performed twice"
            severity failure;
         postops := postops + 1;
      end procedure;

      constant NPROBE : integer := 32;
      type t_probe is array (0 to NBANK - 1, 0 to NPROBE - 1) of integer;
      variable probe   : t_probe := (others => (others => 0));
      variable patt    : std_logic_vector(31 downto 0);
      variable nprobes : integer := 0;
   begin
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';
      -- the clear pass owns the datapath out of reset; nds_top holds the CPUs
      -- the same way (see the clr_busy gate in its boot FSM)
      wait until rising_edge(clk) and clr_busy = '0';
      wait until rising_edge(clk);

      for op in 1 to OPCOUNT loop
         rnd(rs); pick := to_integer(rs(6 downto 0));
         if (pick < 6) then
            -- reconfigure a random VRAMCNT bank (random byte: random MST/OFS/enable)
            rnd(rs);
            vramcnt((to_integer(rs(11 downto 8)) mod 9)*8 + 7 downto (to_integer(rs(11 downto 8)) mod 9)*8) <=
               std_logic_vector(rs(7 downto 0));
            wait until rising_edge(clk);
            cfgops := cfgops + 1;
         elsif (pick < 12) then
            rnd(rs);
            wramcnt <= std_logic_vector(rs(1 downto 0));
            wait until rising_edge(clk);
            cfgops := cfgops + 1;
         elsif (pick < 70) then
            vram_op;
         else
            wram_op;
         end if;
      end loop;

      -- map every bank in LCDC mode so the CPU port can reach all nine
      for b in 0 to NBANK - 1 loop
         vramcnt(b*8 + 7 downto b*8) <= x"80";
      end loop;
      wait until rising_edge(clk);

      -- ================= posted A..D writes =================
      -- The posted queue acknowledges a write before it reaches the store, which
      -- buys nds_dma9 a 16-bit unit every two bus cycles and costs a
      -- read-after-write window silicon does not have. This phase drives the
      -- window on purpose. The srv server above answers with a random 1..8 cycle
      -- latency, so the queue fills and backpressures on its own.

      -- 1. halfword pairs sharing a word, presented back to back. Each pair must
      --    be COMBINED into one srv write, and both halves must survive: a merge
      --    that loses byte enables or overwrites the wrong lane shows up here.
      for k in 0 to 63 loop
         cpu9wp(POST_BASE + k*4,
                "0011", x"0000" & std_logic_vector(to_unsigned(16#1000# + k, 16)));
         cpu9wp(POST_BASE + k*4 + 2,
                "1100", std_logic_vector(to_unsigned(16#2000# + k, 16)) & x"0000");
      end loop;

      -- Read back through the ordinary path, NEWEST FIRST. The order matters:
      -- reading in write order only ever reads words that have already drained,
      -- so it cannot see the read-after-write window at all. Descending puts the
      -- reads on exactly the words still sitting in the queue.
      for k in 63 downto 0 loop
         cpu9r(POST_BASE + k*4);
         assert cpu9_dout = std_logic_vector(to_unsigned(16#2000# + k, 16)) &
                            std_logic_vector(to_unsigned(16#1000# + k, 16))
            report "posted write lost or mis-merged: word " & integer'image(k) &
                   " reads " & to_hstring(cpu9_dout)
            severity failure;
      end loop;

      -- 2. the window with nothing at all in between: fill the queue, then read
      --    the most recent entry first. One posted write is not enough to show a
      --    violation - the drain starts on the next edge and is already in flight
      --    by the time a read could be presented - so this fills WQ_DEPTH so that
      --    entries are still queued behind the one on the wire.
      for k in 0 to POST_BURST - 1 loop
         cpu9wp(POST_BASE + 16#400# + k*4, "1111",
                x"C0FFEE" & std_logic_vector(to_unsigned(k, 8)));
      end loop;
      for k in POST_BURST - 1 downto 0 loop
         cpu9r(POST_BASE + 16#400# + k*4);
         assert cpu9_dout = x"C0FFEE" & std_logic_vector(to_unsigned(k, 8))
            report "read overtook a posted write: word " & integer'image(k) &
                   " reads " & to_hstring(cpu9_dout)
            severity failure;
      end loop;

      -- 3. a write that cannot be posted must say so and still land. Bank E is
      --    BRAM, retired on the dispatch edge, so it is never queue-eligible.
      cpu9_addr  <= to_unsigned(16#880000#, 24)(23 downto 2);
      cpu9_rnw   <= '0';
      cpu9_be    <= "1111";
      cpu9_din   <= x"BEEF0001";
      cpu9_wpost <= '1';
      wait until rising_edge(clk);
      assert cpu9_welig = '0' and cpu9_wok = '0'
         report "an E..I write must not be postable" severity failure;
      cpu9_ena <= '1';
      wait until rising_edge(clk);
      cpu9_ena <= '0';
      wait until rising_edge(clk) and cpu9_done = '1' for 5 us;
      assert cpu9_done = '1' report "non-postable fallback never completed" severity failure;
      cpu9_wpost <= '0';
      cpu9r(16#880000#);
      assert cpu9_dout = x"BEEF0001"
         report "non-postable fallback lost the write: " & to_hstring(cpu9_dout)
         severity failure;

      assert stalls > 0
         report "posted queue never backpressured - the full-queue path is untested"
         severity failure;
      report "tb_vram_torture: posted writes OK  ops=" & integer'image(postops) &
             " stall_cycles=" & integer'image(stalls) severity note;

      -- ================= reset-clear check (see header) =================

      -- pick probe words per bank: always the first and last word (a clear that
      -- truncates a bank is the likely failure), the rest pseudo-random
      for b in 0 to NBANK - 1 loop
         probe(b, 0) := 0;
         probe(b, 1) := LCDC_WORDS(b) - 1;
         for k in 2 to NPROBE - 1 loop
            rnd(rs);
            probe(b, k) := to_integer(rs(19 downto 0)) mod LCDC_WORDS(b);
         end loop;
      end loop;

      -- PRE-DIRTY: without this the check would pass vacuously, because the sim
      -- BRAMs and the behavioral A..D model both power up all-zero
      for b in 0 to NBANK - 1 loop
         for k in 0 to NPROBE - 1 loop
            patt := x"DEAD" & std_logic_vector(to_unsigned(b*4096 + k, 16));
            cpu9w(LCDC_BASE(b) + probe(b, k) * 4, patt);
         end loop;
      end loop;

      -- and prove the pattern really landed (catches a broken probe/decode
      -- rather than a working clear)
      for b in 0 to NBANK - 1 loop
         for k in 0 to NPROBE - 1 loop
            cpu9r(LCDC_BASE(b) + probe(b, k) * 4);
            assert cpu9_dout /= x"00000000"
               report "pre-dirty did not land: bank " & integer'image(b) &
                      " word " & integer'image(probe(b, k))
               severity failure;
         end loop;
      end loop;
      report "tb_vram_torture: banks pre-dirtied" severity note;

      -- now reset and require every probe back at zero
      reset <= '1';
      for k in 1 to 4 loop wait until rising_edge(clk); end loop;
      reset <= '0';
      wait until rising_edge(clk) and clr_busy = '0' for 200 ms;
      assert clr_busy = '0' report "VRAM clear pass never finished" severity failure;
      wait until rising_edge(clk);

      for b in 0 to NBANK - 1 loop
         for k in 0 to NPROBE - 1 loop
            cpu9r(LCDC_BASE(b) + probe(b, k) * 4);
            assert cpu9_dout = x"00000000"
               report "VRAM not cleared on reset: bank " & integer'image(b) &
                      " word " & integer'image(probe(b, k)) &
                      " reads " & to_hstring(cpu9_dout)
               severity failure;
            nprobes := nprobes + 1;
         end loop;
      end loop;

      report "tb_vram_torture: PASS  vram_ops=" & integer'image(vramops) &
             " wram_ops=" & integer'image(wramops) &
             " reconfigs=" & integer'image(cfgops) &
             " clear_probes=" & integer'image(nprobes)
         severity note;
      tests_done <= true;
      wait;
   end process;

end architecture;
