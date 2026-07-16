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

   signal cpu7_ena, cpu7_rnw, cpu7_done : std_logic := '0';
   signal cpu7_addr : unsigned(23 downto 2) := (others => '0');
   signal cpu7_be   : std_logic_vector(3 downto 0) := (others => '0');
   signal cpu7_din, cpu7_dout : std_logic_vector(31 downto 0) := (others => '0');

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
      cpu7_ena => cpu7_ena, cpu7_rnw => cpu7_rnw, cpu7_addr => cpu7_addr,
      cpu7_be => cpu7_be, cpu7_din => cpu7_din, cpu7_dout => cpu7_dout, cpu7_done => cpu7_done,
      srv_req => srv_req, srv_rnw => srv_rnw, srv_bank => srv_bank, srv_addr => srv_addr,
      srv_be => srv_be, srv_din => srv_din, srv_dout => srv_dout, srv_done => srv_done
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
   begin
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';
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

      report "tb_vram_torture: PASS  vram_ops=" & integer'image(vramops) &
             " wram_ops=" & integer'image(wramops) &
             " reconfigs=" & integer'image(cfgops)
         severity note;
      tests_done <= true;
      wait;
   end process;

end architecture;
