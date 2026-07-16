-- VRAM line-server tests (M5). Instantiates nds_vram, fills banks E..I
-- through the ARM9 CPU port in LCDC mode with a deterministic pattern
-- (banks A..D live in the behavioral srv/rsrv models which compute the
-- same pattern on the fly), then walks the gen_vram_ls.py vector list:
-- per VRAMCNT config, renderer-channel reads (BG / OBJ / BG ext pal /
-- OBJ ext pal) are checked against the independent python golden; BG and
-- OBJ reads are additionally cross-checked against the CPU port at the
-- canonical region address (same decode, different datapath). The last
-- four reads of each config are fired on all four channels simultaneously
-- to exercise the round-robin arbiter.
-- Run: sim/run_vram_ls_tb.sh  (regenerate vectors first)

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.textio.all;

use work.pnds_vram_map.all;

entity tb_vram_ls is
   generic
   (
      VECFILE    : string := "sim/tests/vram_ls_vectors.hex";
      TIMEOUT_MS : integer := 20
   );
end entity;

architecture sim of tb_vram_ls is

   signal clk   : std_logic := '0';
   signal reset : std_logic := '1';

   type t_words is array (natural range <>) of std_logic_vector(31 downto 0);

   impure function load_hex(fname : string; size : integer) return t_words is
      file f       : text;
      variable l   : line;
      variable w   : std_logic_vector(31 downto 0);
      variable mem : t_words(0 to size - 1) := (others => (others => '0'));
      variable i   : integer := 0;
   begin
      file_open(f, fname, read_mode);
      while not endfile(f) and i < size loop
         readline(f, l);
         hread(l, w);
         mem(i) := w;
         i := i + 1;
      end loop;
      file_close(f);
      report "loaded " & integer'image(i) & " words from " & fname severity note;
      return mem;
   end function;

   constant vectors : t_words(0 to 8191) := load_hex(VECFILE, 8192);

   -- shared deterministic bank fill (same formula as gen_vram_ls.py)
   function fillword(b : integer; w : integer) return std_logic_vector is
      variable p, q : unsigned(63 downto 0);
   begin
      p := to_unsigned(w, 32) * unsigned'(x"9E3779B1");
      q := to_unsigned(b + 1, 32) * unsigned'(x"85EBCA77");
      return std_logic_vector(p(31 downto 0) + q(31 downto 0));
   end function;

   signal vramcnt : std_logic_vector(71 downto 0) := (others => '0');

   signal cpu9_ena, cpu9_rnw, cpu9_done : std_logic := '0';
   signal cpu9_addr : unsigned(23 downto 2) := (others => '0');
   signal cpu9_be   : std_logic_vector(3 downto 0) := (others => '0');
   signal cpu9_din, cpu9_dout : std_logic_vector(31 downto 0) := (others => '0');

   signal srv_req, srv_rnw, srv_done : std_logic := '0';
   signal srv_bank : std_logic_vector(1 downto 0);
   signal srv_addr : unsigned(16 downto 2);
   signal srv_be   : std_logic_vector(3 downto 0);
   signal srv_din, srv_dout : std_logic_vector(31 downto 0) := (others => '0');

   signal rdr_bg_req, rdr_bg_done       : std_logic := '0';
   signal rdr_bg_addr                   : unsigned(18 downto 2) := (others => '0');
   signal rdr_bg_dout                   : std_logic_vector(31 downto 0);
   signal rdr_obj_req, rdr_obj_done     : std_logic := '0';
   signal rdr_obj_addr                  : unsigned(17 downto 2) := (others => '0');
   signal rdr_obj_dout                  : std_logic_vector(31 downto 0);
   signal rdr_bgep_req, rdr_bgep_done   : std_logic := '0';
   signal rdr_bgep_addr                 : unsigned(14 downto 2) := (others => '0');
   signal rdr_bgep_dout                 : std_logic_vector(31 downto 0);
   signal rdr_objep_req, rdr_objep_done : std_logic := '0';
   signal rdr_objep_addr                : unsigned(12 downto 2) := (others => '0');
   signal rdr_objep_dout                : std_logic_vector(31 downto 0);

   signal rsrv_req, rsrv_done : std_logic := '0';
   signal rsrv_bank : std_logic_vector(1 downto 0);
   signal rsrv_addr : unsigned(16 downto 2);
   signal rsrv_dout : std_logic_vector(31 downto 0) := (others => '0');

   signal tests_done : boolean := false;

begin

   clk <= not clk after 5 ns when not tests_done else '0';

   ivram : entity work.nds_vram
   generic map ( is_simu => '1' )
   port map
   (
      clk => clk, reset => reset, vramcnt => vramcnt,
      cpu9_ena => cpu9_ena, cpu9_rnw => cpu9_rnw, cpu9_addr => cpu9_addr,
      cpu9_be => cpu9_be, cpu9_din => cpu9_din, cpu9_dout => cpu9_dout, cpu9_done => cpu9_done,
      cpu7_ena => '0', cpu7_rnw => '1', cpu7_addr => (others => '0'),
      cpu7_be => (others => '0'), cpu7_din => (others => '0'),
      cpu7_dout => open, cpu7_done => open,
      srv_req => srv_req, srv_rnw => srv_rnw, srv_bank => srv_bank, srv_addr => srv_addr,
      srv_be => srv_be, srv_din => srv_din, srv_dout => srv_dout, srv_done => srv_done,
      rdr_bg_req => rdr_bg_req, rdr_bg_addr => rdr_bg_addr,
      rdr_bg_dout => rdr_bg_dout, rdr_bg_done => rdr_bg_done,
      rdr_obj_req => rdr_obj_req, rdr_obj_addr => rdr_obj_addr,
      rdr_obj_dout => rdr_obj_dout, rdr_obj_done => rdr_obj_done,
      rdr_bgep_req => rdr_bgep_req, rdr_bgep_addr => rdr_bgep_addr,
      rdr_bgep_dout => rdr_bgep_dout, rdr_bgep_done => rdr_bgep_done,
      rdr_objep_req => rdr_objep_req, rdr_objep_addr => rdr_objep_addr,
      rdr_objep_dout => rdr_objep_dout, rdr_objep_done => rdr_objep_done,
      rsrv_req => rsrv_req, rsrv_bank => rsrv_bank, rsrv_addr => rsrv_addr,
      rsrv_dout => rsrv_dout, rsrv_done => rsrv_done
   );

   -- behavioral A..D backing store, CPU side (reads only in this TB)
   pserv : process
      variable rs : unsigned(31 downto 0) := to_unsigned(4242, 32);
   begin
      wait until rising_edge(clk) and srv_req = '1';
      assert srv_rnw = '1' report "unexpected A..D CPU write" severity failure;
      rs := rs xor shift_left(rs, 13); rs := rs xor shift_right(rs, 17); rs := rs xor shift_left(rs, 5);
      for k in 1 to 1 + to_integer(rs(1 downto 0)) loop
         wait until rising_edge(clk);
      end loop;
      srv_dout <= fillword(to_integer(unsigned(srv_bank)), to_integer(srv_addr));
      srv_done <= '1';
      wait until rising_edge(clk);
      srv_done <= '0';
   end process;

   -- behavioral A..D backing store, renderer side (read-only channel)
   prserv : process
      variable rs : unsigned(31 downto 0) := to_unsigned(777, 32);
   begin
      wait until rising_edge(clk) and rsrv_req = '1';
      rs := rs xor shift_left(rs, 13); rs := rs xor shift_right(rs, 17); rs := rs xor shift_left(rs, 5);
      for k in 1 to 1 + to_integer(rs(1 downto 0)) loop
         wait until rising_edge(clk);
      end loop;
      rsrv_dout <= fillword(to_integer(unsigned(rsrv_bank)), to_integer(rsrv_addr));
      rsrv_done <= '1';
      wait until rising_edge(clk);
      rsrv_done <= '0';
   end process;

   pmain : process
      variable nfail : integer := 0;

      procedure cpu9write(byteaddr : integer; data : std_logic_vector(31 downto 0)) is
      begin
         cpu9_addr <= to_unsigned(byteaddr, 24)(23 downto 2);
         cpu9_rnw  <= '0';
         cpu9_be   <= "1111";
         cpu9_din  <= data;
         cpu9_ena  <= '1';
         wait until rising_edge(clk);
         cpu9_ena  <= '0';
         wait until rising_edge(clk) and cpu9_done = '1';
      end procedure;

      procedure cpu9read(byteaddr : integer; data : out std_logic_vector(31 downto 0)) is
      begin
         cpu9_addr <= to_unsigned(byteaddr, 24)(23 downto 2);
         cpu9_rnw  <= '1';
         cpu9_ena  <= '1';
         wait until rising_edge(clk);
         cpu9_ena  <= '0';
         wait until rising_edge(clk) and cpu9_done = '1';
         data := cpu9_dout;
      end procedure;

      procedure fillbank(b : integer; lcdc_base : integer; words : integer) is
      begin
         for w in 0 to words - 1 loop
            cpu9write(lcdc_base + w * 4, fillword(b, w));
         end loop;
      end procedure;

      -- single renderer read on one channel
      procedure rdrread(chan : integer; byteaddr : integer; data : out std_logic_vector(31 downto 0)) is
      begin
         case chan is
            when 0 =>
               rdr_bg_addr <= to_unsigned(byteaddr, 19)(18 downto 2);
               rdr_bg_req  <= '1';
               wait until rising_edge(clk) and rdr_bg_done = '1';
               rdr_bg_req  <= '0';
               data := rdr_bg_dout;
            when 1 =>
               rdr_obj_addr <= to_unsigned(byteaddr, 18)(17 downto 2);
               rdr_obj_req  <= '1';
               wait until rising_edge(clk) and rdr_obj_done = '1';
               rdr_obj_req  <= '0';
               data := rdr_obj_dout;
            when 2 =>
               rdr_bgep_addr <= to_unsigned(byteaddr, 15)(14 downto 2);
               rdr_bgep_req  <= '1';
               wait until rising_edge(clk) and rdr_bgep_done = '1';
               rdr_bgep_req  <= '0';
               data := rdr_bgep_dout;
            when others =>
               rdr_objep_addr <= to_unsigned(byteaddr, 13)(12 downto 2);
               rdr_objep_req  <= '1';
               wait until rising_edge(clk) and rdr_objep_done = '1';
               rdr_objep_req  <= '0';
               data := rdr_objep_dout;
         end case;
      end procedure;

      procedure check(cfg, idx : integer; name : string;
                      got, exp : std_logic_vector(31 downto 0)) is
      begin
         if (got /= exp) then
            nfail := nfail + 1;
            report "config " & integer'image(cfg) & " read " & integer'image(idx) &
                   " (" & name & ") expected=" & to_hstring(exp) &
                   " got=" & to_hstring(got) severity error;
         end if;
      end procedure;

      variable nconfigs, nreads, p : integer;
      variable rw, exp, got, gotc : std_logic_vector(31 downto 0);
      variable chan, byteaddr     : integer;
      variable cc                 : std_logic;
      variable cc_addr            : t_words(0 to 3);
      variable cc_exp             : t_words(0 to 3);
      variable cc_got             : t_words(0 to 3);
      variable cc_done            : std_logic_vector(3 downto 0);
      variable cc_n               : integer;
   begin
      -- reset
      for k in 1 to 4 loop wait until rising_edge(clk); end loop;
      reset <= '0';
      wait until rising_edge(clk);

      -- ================= fill E..I via LCDC =================
      vramcnt <= x"80" & x"80808080" & x"00000000";   -- I=LCDC, H..E=LCDC, D..A off
      wait until rising_edge(clk);
      fillbank(BANK_E, 16#880000#, 16384);
      fillbank(BANK_F, 16#890000#,  4096);
      fillbank(BANK_G, 16#894000#,  4096);
      fillbank(BANK_H, 16#898000#,  8192);
      fillbank(BANK_I, 16#8A0000#,  4096);
      report "bank fill done" severity note;

      -- ================= config walk =================
      nconfigs := to_integer(unsigned(vectors(0)));
      p := 1;
      for c in 0 to nconfigs - 1 loop
         vramcnt(31 downto  0) <= vectors(p);
         vramcnt(63 downto 32) <= vectors(p + 1);
         vramcnt(71 downto 64) <= vectors(p + 2)(7 downto 0);
         nreads := to_integer(unsigned(vectors(p + 3)));
         p := p + 4;
         for k in 1 to 4 loop wait until rising_edge(clk); end loop;

         cc_n := 0;
         for r in 0 to nreads - 1 loop
            rw       := vectors(p);
            exp      := vectors(p + 1);
            p        := p + 2;
            chan     := to_integer(unsigned(rw(29 downto 28)));
            cc       := rw(27);
            byteaddr := to_integer(unsigned(rw(19 downto 0)));

            if (cc = '1') then
               cc_addr(cc_n) := std_logic_vector(to_unsigned(byteaddr, 32));
               cc_exp(cc_n)  := exp;
               cc_n := cc_n + 1;
            else
               rdrread(chan, byteaddr, got);
               check(c, r, "rdr chan " & integer'image(chan), got, exp);
               -- CPU differential at the canonical region address
               if (chan = 0) then
                  cpu9read(byteaddr, gotc);
                  check(c, r, "cpu bg", gotc, exp);
               elsif (chan = 1) then
                  cpu9read(16#400000# + byteaddr, gotc);
                  check(c, r, "cpu obj", gotc, exp);
               end if;
            end if;
         end loop;

         -- concurrent batch: all four channels at once (arbiter exercise)
         assert cc_n = 4 report "bad cc batch" severity failure;
         rdr_bg_addr    <= unsigned(cc_addr(0)(18 downto 2));
         rdr_obj_addr   <= unsigned(cc_addr(1)(17 downto 2));
         rdr_bgep_addr  <= unsigned(cc_addr(2)(14 downto 2));
         rdr_objep_addr <= unsigned(cc_addr(3)(12 downto 2));
         rdr_bg_req     <= '1';
         rdr_obj_req    <= '1';
         rdr_bgep_req   <= '1';
         rdr_objep_req  <= '1';
         cc_done := "0000";
         while cc_done /= "1111" loop
            wait until rising_edge(clk);
            if (rdr_bg_done = '1')    then cc_got(0) := rdr_bg_dout;    cc_done(0) := '1'; rdr_bg_req    <= '0'; end if;
            if (rdr_obj_done = '1')   then cc_got(1) := rdr_obj_dout;   cc_done(1) := '1'; rdr_obj_req   <= '0'; end if;
            if (rdr_bgep_done = '1')  then cc_got(2) := rdr_bgep_dout;  cc_done(2) := '1'; rdr_bgep_req  <= '0'; end if;
            if (rdr_objep_done = '1') then cc_got(3) := rdr_objep_dout; cc_done(3) := '1'; rdr_objep_req <= '0'; end if;
         end loop;
         for k in 0 to 3 loop
            check(c, 1000 + k, "concurrent chan " & integer'image(k), cc_got(k), cc_exp(k));
         end loop;

         report "config " & integer'image(c) & " done" severity note;
      end loop;

      if (nfail = 0) then
         report "tb_vram_ls: PASS  " & integer'image(nconfigs) & " configs" severity note;
      else
         report "tb_vram_ls: FAIL  " & integer'image(nfail) & " mismatches" severity failure;
      end if;
      tests_done <= true;
      wait;
   end process;

   p_watchdog : process
   begin
      wait for TIMEOUT_MS * 1 ms;
      if not tests_done then
         report "tb_vram_ls: TIMEOUT" severity failure;
      end if;
      wait;
   end process;

end architecture;
