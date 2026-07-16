-- Torture test for nds_mainram: dual guest channels sharing one SDRAM request
-- port. Behavioral controller model (single outstanding 32-bit op, read done32
-- after ~6 clkMem cycles, write after 3, periodic refresh stalls), byte-accurate
-- reference model, two phases:
--   1: sequential random ops from random ports (same-address collisions legal)
--   2: concurrent op pairs from both ports on disjoint addresses (arbiter test),
--      with arm7_priority toggling
-- Run: sim/run_mainram_tb.sh  (OPCOUNT env for longer soaks)

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity tb_mainram is
   generic
   (
      OPCOUNT : integer := 10000;
      SEED    : integer := 1
   );
end entity;

architecture sim of tb_mainram is

   constant MAINRAM_BASE : integer := 8388608; -- 8 MB offset inside SDRAM, arbitrary

   signal clk1x       : std_logic := '0';
   signal clkMem      : std_logic := '0';
   signal clkMemIndex : unsigned(1 downto 0) := "10"; -- so it wraps to 0 on clk1x edge
   signal reset       : std_logic := '1';

   signal arm7_priority : std_logic := '0';

   signal mem9_ena, mem9_rnw, mem9_done : std_logic := '0';
   signal mem9_addr : std_logic_vector(21 downto 2) := (others => '0');
   signal mem9_be   : std_logic_vector(3 downto 0) := (others => '0');
   signal mem9_writedata, mem9_readdata : std_logic_vector(31 downto 0) := (others => '0');

   signal mem7_ena, mem7_rnw, mem7_done : std_logic := '0';
   signal mem7_addr : std_logic_vector(21 downto 2) := (others => '0');
   signal mem7_be   : std_logic_vector(3 downto 0) := (others => '0');
   signal mem7_writedata, mem7_readdata : std_logic_vector(31 downto 0) := (others => '0');

   signal mainram_active, mainram_busy : std_logic;
   signal model_allow : std_logic := '1';   -- scheduler-side gate, owned by the model

   signal sdram_ena, sdram_rnw : std_logic := '0';
   signal sdram_Adr : std_logic_vector(26 downto 0);
   signal sdram_Din : std_logic_vector(31 downto 0);
   signal sdram_be  : std_logic_vector(3 downto 0);
   signal sdram_Dout : std_logic_vector(31 downto 0) := (others => '0');
   signal sdram_done32 : std_logic := '0';

   signal tests_done : boolean := false;

   procedure rnd(variable s : inout unsigned(31 downto 0)) is
   begin
      s := s xor shift_left(s, 13);
      s := s xor shift_right(s, 17);
      s := s xor shift_left(s, 5);
   end procedure;

begin

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
            clk1x <= '0';   -- ~33% duty; only the rising edge matters
         end if;
      end if;
   end process;

   uut : entity work.nds_mainram
   generic map ( Softmap_NDS_MAINRAM_ADDR => MAINRAM_BASE )
   port map
   (
      clk1x => clk1x, clkMem => clkMem, clkMemIndex => clkMemIndex, reset => reset,
      arm7_priority => arm7_priority,
      mem9_ena => mem9_ena, mem9_rnw => mem9_rnw, mem9_addr => mem9_addr, mem9_be => mem9_be,
      mem9_writedata => mem9_writedata, mem9_done => mem9_done, mem9_readdata => mem9_readdata,
      mem7_ena => mem7_ena, mem7_rnw => mem7_rnw, mem7_addr => mem7_addr, mem7_be => mem7_be,
      mem7_writedata => mem7_writedata, mem7_done => mem7_done, mem7_readdata => mem7_readdata,
      mainram_allow => model_allow, mainram_active => mainram_active, mainram_busy => mainram_busy,
      mr_sdram_ena => sdram_ena, mr_sdram_rnw => sdram_rnw, mr_sdram_Adr => sdram_Adr,
      mr_sdram_Din => sdram_Din, mr_sdram_be => sdram_be,
      sdram_Dout => sdram_Dout, sdram_done32 => sdram_done32
   );

   -- ================= behavioral SDRAM controller model =================
   psdram : process
      type t_mem is array (0 to 1048575) of std_logic_vector(31 downto 0); -- 4 MB as dwords
      variable mem : t_mem := (others => (others => '0'));
      variable rs  : unsigned(31 downto 0) := to_unsigned(424242, 32);
      variable a   : integer;
      variable w   : integer;
      variable refresh_cnt : integer := 0;
      variable v_rnw : std_logic;
      variable v_din : std_logic_vector(31 downto 0);
      variable v_be  : std_logic_vector(3 downto 0);
   begin
      wait until rising_edge(clkMem);
      refresh_cnt := refresh_cnt + 1;

      -- announce the upcoming refresh like the extern scheduler would: allow
      -- drops well before the refresh slot so no new op can be granted
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
            for k in 1 to 6 loop
               assert sdram_ena = '0' or k = 1 report "sdram request while busy (read)" severity failure;
               wait until rising_edge(clkMem);
            end loop;
            sdram_Dout   <= mem(w);
            sdram_done32 <= '1';
            wait until rising_edge(clkMem);
            sdram_done32 <= '0';
            -- recovery slot
            for k in 1 to 3 loop wait until rising_edge(clkMem); end loop;
         else
            for k in 1 to 3 loop
               assert sdram_ena = '0' or k = 1 report "sdram request while busy (write)" severity failure;
               wait until rising_edge(clkMem);
            end loop;
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
         -- allow has been low for 10+ cycles; nothing can be in flight
         assert sdram_ena = '0' report "sdram request during refresh slot" severity failure;
         for k in 1 to 6 loop
            wait until rising_edge(clkMem);
            assert sdram_ena = '0' report "sdram request during refresh slot" severity failure;
         end loop;
         refresh_cnt := 0;
         model_allow <= '1';
      end if;
   end process;

   -- ================= stimulus + reference model =================
   pmain : process
      type t_mem is array (0 to 1048575) of std_logic_vector(31 downto 0);
      variable model : t_mem := (others => (others => '0'));
      variable rs    : unsigned(31 downto 0) := to_unsigned((SEED mod 65521)*31337 + 777, 32);
      variable is7   : boolean;
      variable rnw9, rnw7 : boolean;
      variable w, w9, w7  : integer;
      variable be9, be7   : std_logic_vector(3 downto 0);
      variable d9, d7     : std_logic_vector(31 downto 0);
      variable exp        : std_logic_vector(31 downto 0);
      variable got9, got7 : boolean;
      variable seqops, conops : integer := 0;

      procedure apply_write(variable wa : in integer; variable be : in std_logic_vector(3 downto 0);
                            variable d : in std_logic_vector(31 downto 0)) is
      begin
         for j in 0 to 3 loop
            if (be(j) = '1') then
               model(wa)(j*8 + 7 downto j*8) := d(j*8 + 7 downto j*8);
            end if;
         end loop;
      end procedure;
   begin
      for k in 1 to 6 loop wait until rising_edge(clk1x); end loop;
      reset <= '0';
      wait until rising_edge(clk1x);

      -- ============ phase 1: sequential ============
      for op in 1 to OPCOUNT loop
         rnd(rs); is7  := (rs(0) = '1');
         rnd(rs); rnw9 := (rs(1) = '1');
         rnd(rs); w    := to_integer(rs(19 downto 0));
         rnd(rs); be9  := std_logic_vector(rs(3 downto 0));
         rnd(rs); d9   := std_logic_vector(rs);

         if is7 then
            mem7_addr <= std_logic_vector(to_unsigned(w, 20)); mem7_be <= be9; mem7_writedata <= d9;
            if rnw9 then mem7_rnw <= '1'; else mem7_rnw <= '0'; end if;
            wait until rising_edge(clk1x);
            mem7_ena <= '1'; wait until rising_edge(clk1x); mem7_ena <= '0';
            wait until rising_edge(clk1x) and mem7_done = '1' for 20 us;
            assert mem7_done = '1' report "phase1: mem7 timeout" severity failure;
            if rnw9 then
               assert mem7_readdata = model(w)
                  report "phase1: mem7 read mismatch w=" & integer'image(w) &
                         " got " & to_hstring(mem7_readdata) & " exp " & to_hstring(model(w))
                  severity failure;
            else
               apply_write(w, be9, d9);
            end if;
         else
            mem9_addr <= std_logic_vector(to_unsigned(w, 20)); mem9_be <= be9; mem9_writedata <= d9;
            if rnw9 then mem9_rnw <= '1'; else mem9_rnw <= '0'; end if;
            wait until rising_edge(clk1x);
            mem9_ena <= '1'; wait until rising_edge(clk1x); mem9_ena <= '0';
            wait until rising_edge(clk1x) and mem9_done = '1' for 20 us;
            assert mem9_done = '1' report "phase1: mem9 timeout" severity failure;
            if rnw9 then
               assert mem9_readdata = model(w)
                  report "phase1: mem9 read mismatch w=" & integer'image(w) &
                         " got " & to_hstring(mem9_readdata) & " exp " & to_hstring(model(w))
                  severity failure;
            else
               apply_write(w, be9, d9);
            end if;
         end if;
         seqops := seqops + 1;
      end loop;

      -- ============ phase 2: concurrent pairs, disjoint addresses ============
      for op in 1 to OPCOUNT loop
         rnd(rs); arm7_priority <= rs(5);
         rnd(rs); rnw9 := (rs(0) = '1');
         rnd(rs); rnw7 := (rs(1) = '1');
         rnd(rs); w9   := to_integer(rs(19 downto 1) & '0');  -- even words
         rnd(rs); w7   := to_integer(rs(19 downto 1) & '1');  -- odd words
         rnd(rs); be9  := std_logic_vector(rs(3 downto 0));
         rnd(rs); be7  := std_logic_vector(rs(7 downto 4));
         rnd(rs); d9   := std_logic_vector(rs);
         rnd(rs); d7   := std_logic_vector(not rs);

         mem9_addr <= std_logic_vector(to_unsigned(w9, 20)); mem9_be <= be9; mem9_writedata <= d9;
         if rnw9 then mem9_rnw <= '1'; else mem9_rnw <= '0'; end if;
         mem7_addr <= std_logic_vector(to_unsigned(w7, 20)); mem7_be <= be7; mem7_writedata <= d7;
         if rnw7 then mem7_rnw <= '1'; else mem7_rnw <= '0'; end if;
         wait until rising_edge(clk1x);
         mem9_ena <= '1'; mem7_ena <= '1';
         wait until rising_edge(clk1x);
         mem9_ena <= '0'; mem7_ena <= '0';

         got9 := false; got7 := false;
         while not (got9 and got7) loop
            wait until rising_edge(clk1x) for 40 us;
            assert clk1x'event report "phase2: op pair timeout" severity failure;
            if (mem9_done = '1') then
               assert not got9 report "phase2: double done on mem9" severity failure;
               got9 := true;
               if rnw9 then
                  assert mem9_readdata = model(w9)
                     report "phase2: mem9 read mismatch w=" & integer'image(w9) &
                            " got " & to_hstring(mem9_readdata) & " exp " & to_hstring(model(w9))
                     severity failure;
               end if;
            end if;
            if (mem7_done = '1') then
               assert not got7 report "phase2: double done on mem7" severity failure;
               got7 := true;
               if rnw7 then
                  assert mem7_readdata = model(w7)
                     report "phase2: mem7 read mismatch w=" & integer'image(w7) &
                            " got " & to_hstring(mem7_readdata) & " exp " & to_hstring(model(w7))
                     severity failure;
               end if;
            end if;
         end loop;
         if not rnw9 then apply_write(w9, be9, d9); end if;
         if not rnw7 then apply_write(w7, be7, d7); end if;
         conops := conops + 1;
      end loop;

      report "tb_mainram: PASS  sequential=" & integer'image(seqops) &
             " concurrent_pairs=" & integer'image(conops) severity note;
      tests_done <= true;
      wait;
   end process;

end architecture;
