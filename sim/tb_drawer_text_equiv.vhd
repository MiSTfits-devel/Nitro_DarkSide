-- SPDX-License-Identifier: GPL-2.0-or-later
-- Equivalence test: the pipelined text drawer (nds_drawer_text, v2) against the
-- serial one it replaced (sim/nds_drawer_text_ref.vhd, a verbatim copy of v1).
--
-- WHY THIS EXISTS. The full-frame benches compare against gen_gpu2d_frame.py,
-- and that model states plainly that "Mosaic stays off" - it does not implement
-- BG mosaic at all. So the frame benches CANNOT check the mosaic path, and v2
-- deliberately changed it: v1 decided each mosaic repeat from pixeldata(15),
-- which a pipelined pixel path cannot read (pixeldata is written a cycle later,
-- so the next pixel would see a stale bit), and v2 tracks last_transp instead.
-- A change to an unverified path is exactly the kind that quietly ships broken.
--
-- v1 is the proven-correct reference - it renders pixel-exact against the
-- melonDS oracle - so comparing against it directly covers what the golden
-- model cannot: mosaic at every size, both flips, all four screen sizes, both
-- colour depths, ext palettes on and off, and scrolls that do and do not land
-- on a tile boundary.
--
-- Each drawer gets its OWN memory and palette models, so neither can perturb
-- the other through arbitration. Both models answer the way the real ones now
-- do: VRAM with a fixed latency (the v1 model one request at a time, the v2
-- model pipelined and in-order, which is the whole point of v2), and palettes
-- unconditionally one cycle after the address.
--
-- The comparison is on the LINE BUFFER, not on the pixel stream: v2 writes
-- pixels at different times and can write them in a different order, and that
-- is legitimate. What must match is the resulting line.
--
-- Run: sim/run_drawer_text_equiv.sh

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity tb_drawer_text_equiv is
   generic
   (
      -- VRAM answer latency in clk cycles, for both models
      VLAT : integer := 5
   );
end entity;

architecture sim of tb_drawer_text_equiv is

   signal clk        : std_logic := '0';
   signal tests_done : boolean := false;

   -- ================= stimulus config, driven to both drawers =================
   signal drawline    : std_logic := '0';
   signal ypos        : integer range 0 to 191 := 0;
   signal ypos_mosaic : integer range 0 to 191 := 0;
   signal mapbase     : unsigned(18 downto 0) := (others => '0');
   signal tilebase    : unsigned(18 downto 0) := (others => '0');
   signal hicolor     : std_logic := '0';
   signal extpalette  : std_logic := '0';
   signal extpal_slot : unsigned(1 downto 0) := "00";
   signal mosaic      : std_logic := '0';
   signal mos_h       : unsigned(3 downto 0) := (others => '0');
   signal screensize  : unsigned(1 downto 0) := "00";
   signal scrollX     : unsigned(8 downto 0) := (others => '0');
   signal scrollY     : unsigned(8 downto 0) := (others => '0');

   -- ================= backing stores, shared CONTENT =================
   -- 512 KB BG space as words, and the two palette spaces. Filled with a
   -- deterministic pattern that produces plenty of index-0 (transparent) and
   -- plenty of set flip bits, so the transparency and flip paths are exercised.
   type t_bgmem is array (0 to 131071) of std_logic_vector(31 downto 0);
   type t_pal   is array (0 to 127) of std_logic_vector(31 downto 0);
   type t_epal  is array (0 to 8191) of std_logic_vector(31 downto 0);

   impure function fill_bg return t_bgmem is
      variable m : t_bgmem;
      variable s : unsigned(31 downto 0) := to_unsigned(16#1234567#, 32);
   begin
      for i in t_bgmem'range loop
         s := s xor shift_left(s, 13);
         s := s xor shift_right(s, 17);
         s := s xor shift_left(s, 5);
         -- force a good share of zero nibbles/bytes so transparency is hit
         if (i mod 5 = 0) then
            m(i) := std_logic_vector(s and x"0F0F0F0F");
         elsif (i mod 7 = 0) then
            m(i) := std_logic_vector(s and x"00FF00FF");
         else
            m(i) := std_logic_vector(s);
         end if;
      end loop;
      return m;
   end function;

   impure function fill_pal return t_pal is
      variable m : t_pal;
      variable s : unsigned(31 downto 0) := to_unsigned(16#89ABCDE#, 32);
   begin
      for i in t_pal'range loop
         s := s xor shift_left(s, 13);
         s := s xor shift_right(s, 17);
         s := s xor shift_left(s, 5);
         m(i) := std_logic_vector(s);
      end loop;
      return m;
   end function;

   impure function fill_epal return t_epal is
      variable m : t_epal;
      variable s : unsigned(31 downto 0) := to_unsigned(16#FEDCBA9#, 32);
   begin
      for i in t_epal'range loop
         s := s xor shift_left(s, 13);
         s := s xor shift_right(s, 17);
         s := s xor shift_left(s, 5);
         m(i) := std_logic_vector(s);
      end loop;
      return m;
   end function;

   constant bgmem : t_bgmem := fill_bg;
   constant palm  : t_pal   := fill_pal;
   constant epalm : t_epal  := fill_epal;

   -- ================= per-drawer wiring =================
   -- reference (v1)
   signal a_busy    : std_logic;
   signal a_we      : std_logic;
   signal a_data    : std_logic_vector(15 downto 0);
   signal a_x       : integer range 0 to 255;
   signal a_paddr   : integer range 0 to 127;
   signal a_pdata   : std_logic_vector(31 downto 0) := (others => '0');
   signal a_eaddr   : integer range 0 to 8191;
   signal a_edata   : std_logic_vector(31 downto 0) := (others => '0');
   signal a_vreq    : std_logic;
   signal a_vaddr   : integer range 0 to 131071;
   signal a_vdata   : std_logic_vector(31 downto 0) := (others => '0');
   signal a_vdone   : std_logic := '0';

   -- pipelined (v2)
   signal b_busy    : std_logic;
   signal b_we      : std_logic;
   signal b_data    : std_logic_vector(15 downto 0);
   signal b_x       : integer range 0 to 255;
   signal b_paddr   : integer range 0 to 127;
   signal b_pdata   : std_logic_vector(31 downto 0) := (others => '0');
   signal b_eaddr   : integer range 0 to 8191;
   signal b_edata   : std_logic_vector(31 downto 0) := (others => '0');
   signal b_vreq    : std_logic;
   signal b_vaddr   : integer range 0 to 131071;
   signal b_vdata   : std_logic_vector(31 downto 0) := (others => '0');
   signal b_vdone   : std_logic := '0';
   signal b_vaccept : std_logic := '0';

   -- line buffers, plus a written mask so "never written" is distinguishable
   type t_line is array (0 to 255) of std_logic_vector(15 downto 0);
   signal a_line, b_line : t_line := (others => (others => '0'));
   signal a_seen, b_seen : std_logic_vector(0 to 255) := (others => '0');

   -- v2's pipelined in-order VRAM model
   type t_vpipe is record
      v : std_logic;
      d : std_logic_vector(31 downto 0);
   end record;
   type t_vpipe_arr is array (0 to VLAT - 1) of t_vpipe;
   signal bpipe : t_vpipe_arr := (others => ('0', (others => '0')));

   signal cycles_a, cycles_b : integer := 0;

begin

   clk <= not clk after 5 ns when not tests_done else '0';

   -- ==========================================================================
   -- reference drawer (v1) + its models
   -- ==========================================================================
   iref : entity work.nds_drawer_text_ref
   port map
   (
      clk => clk, drawline => drawline, busy => a_busy,
      ypos => ypos, ypos_mosaic => ypos_mosaic,
      mapbase => mapbase, tilebase => tilebase,
      hicolor => hicolor, extpalette => extpalette, extpal_slot => extpal_slot,
      mosaic => mosaic, Mosaic_H_Size => mos_h, screensize => screensize,
      scrollX => scrollX, scrollY => scrollY,
      pixel_we => a_we, pixeldata => a_data, pixel_x => a_x,
      PALETTE_Drawer_addr => a_paddr, PALETTE_Drawer_data => a_pdata,
      PALETTE_Drawer_valid => '1',
      EXTPAL_Drawer_addr => a_eaddr, EXTPAL_Drawer_data => a_edata,
      EXTPAL_Drawer_valid => '1',
      VRAM_Drawer_req => a_vreq, VRAM_Drawer_addr => a_vaddr,
      VRAM_Drawer_data => a_vdata, VRAM_Drawer_done => a_vdone
   );

   -- palettes: unconditional, one cycle after the address (what the private
   -- read ports in nds_gpu2d now provide)
   process (clk)
   begin
      if rising_edge(clk) then
         a_pdata <= palm(a_paddr);
         a_edata <= epalm(a_eaddr);
         b_pdata <= palm(b_paddr);
         b_edata <= epalm(b_eaddr);
      end if;
   end process;

   -- v1's VRAM model: one request at a time, fixed latency
   pa_vram : process
   begin
      wait until rising_edge(clk) and a_vreq = '1';
      for k in 1 to VLAT loop
         wait until rising_edge(clk);
      end loop;
      a_vdata <= bgmem(a_vaddr);
      a_vdone <= '1';
      wait until rising_edge(clk);
      a_vdone <= '0';
   end process;

   -- ==========================================================================
   -- pipelined drawer (v2) + its models
   -- ==========================================================================
   ipipe : entity work.nds_drawer_text
   port map
   (
      clk => clk, drawline => drawline, busy => b_busy,
      ypos => ypos, ypos_mosaic => ypos_mosaic,
      mapbase => mapbase, tilebase => tilebase,
      hicolor => hicolor, extpalette => extpalette, extpal_slot => extpal_slot,
      mosaic => mosaic, Mosaic_H_Size => mos_h, screensize => screensize,
      scrollX => scrollX, scrollY => scrollY,
      pixel_we => b_we, pixeldata => b_data, pixel_x => b_x,
      PALETTE_Drawer_addr => b_paddr, PALETTE_Drawer_data => b_pdata,
      PALETTE_Drawer_valid => '1',
      EXTPAL_Drawer_addr => b_eaddr, EXTPAL_Drawer_data => b_edata,
      EXTPAL_Drawer_valid => '1',
      VRAM_Drawer_req => b_vreq, VRAM_Drawer_addr => b_vaddr,
      VRAM_Drawer_data => b_vdata, VRAM_Drawer_done => b_vdone,
      VRAM_Drawer_accept => b_vaccept
   );

   -- v2's VRAM model: accepts one request per cycle, answers IN ISSUE ORDER
   -- after VLAT cycles. Accepting immediately is the strongest case for the
   -- pipeline (most requests in flight at once).
   b_vaccept <= b_vreq;

   pb_vram : process (clk)
   begin
      if rising_edge(clk) then
         for k in VLAT - 1 downto 1 loop
            bpipe(k) <= bpipe(k - 1);
         end loop;
         bpipe(0).v <= '0';
         if (b_vreq = '1') then
            bpipe(0).v <= '1';
            bpipe(0).d <= bgmem(b_vaddr);
         end if;
         b_vdone <= bpipe(VLAT - 1).v;
         b_vdata <= bpipe(VLAT - 1).d;
      end if;
   end process;

   -- ==========================================================================
   -- line collection + busy-time measurement
   -- ==========================================================================
   process (clk)
   begin
      if rising_edge(clk) then
         if (drawline = '1') then
            a_seen <= (others => '0');
            b_seen <= (others => '0');
         else
            if (a_we = '1') then
               a_line(a_x) <= a_data;
               a_seen(a_x) <= '1';
            end if;
            if (b_we = '1') then
               b_line(b_x) <= b_data;
               b_seen(b_x) <= '1';
            end if;
         end if;
         if (a_busy = '1') then cycles_a <= cycles_a + 1; end if;
         if (b_busy = '1') then cycles_b <= cycles_b + 1; end if;
      end if;
   end process;

   -- ==========================================================================
   -- stimulus
   -- ==========================================================================
   pmain : process
      variable nfail   : integer := 0;
      variable ncase   : integer := 0;
      variable nlines  : integer := 0;
      variable ca, cb  : integer;

      procedure run_line(y : integer) is
      begin
         ypos        <= y;
         ypos_mosaic <= y - (y mod (to_integer(mos_h) + 1));
         wait until rising_edge(clk);
         drawline <= '1';
         wait until rising_edge(clk);
         drawline <= '0';
         -- both drawers must finish; they take different numbers of cycles
         wait until rising_edge(clk);
         while (a_busy = '1' or b_busy = '1') loop
            wait until rising_edge(clk);
         end loop;
         -- let the last registered pixel write settle
         wait until rising_edge(clk);
         wait until rising_edge(clk);

         for x in 0 to 255 loop
            if (a_seen(x) /= b_seen(x)) then
               nfail := nfail + 1;
               if (nfail <= 20) then
                  report "case " & integer'image(ncase) & " y=" & integer'image(y) &
                         " x=" & integer'image(x) & " written ref=" &
                         std_logic'image(a_seen(x)) & " pipe=" &
                         std_logic'image(b_seen(x)) severity error;
               end if;
            elsif (a_seen(x) = '1' and a_line(x) /= b_line(x)) then
               nfail := nfail + 1;
               if (nfail <= 20) then
                  report "case " & integer'image(ncase) & " y=" & integer'image(y) &
                         " x=" & integer'image(x) & " ref=" & to_hstring(a_line(x)) &
                         " pipe=" & to_hstring(b_line(x)) severity error;
               end if;
            end if;
         end loop;
         nlines := nlines + 1;
      end procedure;

      -- one configuration, swept over a handful of lines
      procedure run_case(hc, ep, mos : std_logic; msz : integer; sz : integer;
                         sx, sy : integer) is
      begin
         hicolor     <= hc;
         extpalette  <= ep;
         mosaic      <= mos;
         mos_h       <= to_unsigned(msz, 4);
         screensize  <= to_unsigned(sz, 2);
         scrollX     <= to_unsigned(sx, 9);
         scrollY     <= to_unsigned(sy, 9);
         extpal_slot <= to_unsigned(ncase mod 4, 2);
         mapbase     <= to_unsigned(((ncase mod 8) * 2048) mod 524288, 19);
         tilebase    <= to_unsigned(16#20000# + ((ncase mod 4) * 16384), 19);
         wait until rising_edge(clk);
         for y in 0 to 5 loop
            run_line(y * 37);
         end loop;
         ncase := ncase + 1;
      end procedure;
   begin
      wait until rising_edge(clk);
      wait until rising_edge(clk);

      -- One warm-up line, NOT compared. Both drawers hold their configuration
      -- and caches across lines and are only re-armed by drawline, so the very
      -- first line of a simulation runs against power-up register values rather
      -- than a configured BG - which is a property of this bench, not of the
      -- hardware, where the CPU has written the registers long before the first
      -- drawline. Comparing it would only assert that two different pieces of
      -- uninitialised state happen to agree.
      hicolor    <= '0';
      extpalette <= '0';
      mosaic     <= '0';
      mos_h      <= (others => '0');
      screensize <= "00";
      scrollX    <= (others => '0');
      scrollY    <= (others => '0');
      mapbase    <= (others => '0');
      tilebase   <= to_unsigned(16#20000#, 19);
      wait until rising_edge(clk);
      ypos        <= 0;
      ypos_mosaic <= 0;
      wait until rising_edge(clk);
      drawline <= '1';
      wait until rising_edge(clk);
      drawline <= '0';
      wait until rising_edge(clk);
      while (a_busy = '1' or b_busy = '1') loop
         wait until rising_edge(clk);
      end loop;
      wait until rising_edge(clk);
      wait until rising_edge(clk);

      -- colour depth x screen size x scroll alignment, mosaic off
      for sz in 0 to 3 loop
         run_case('0', '0', '0', 0, sz, 0,   0);     -- 4bpp, tile-aligned scroll
         run_case('0', '0', '0', 0, sz, 13,  200);   -- 4bpp, unaligned
         run_case('1', '0', '0', 0, sz, 45,  511);   -- 8bpp, std palette
         run_case('1', '1', '0', 0, sz, 137, 250);   -- 8bpp, ext palette
      end loop;

      -- scrolls that put the first pixel at every sub-tile offset, and that
      -- cross the 256/512 map wrap
      for k in 0 to 7 loop
         run_case('0', '0', '0', 0, 1, 248 + k, 100);
         run_case('1', '1', '0', 0, 3, 504 - k, 300);
      end loop;

      -- MOSAIC: every horizontal size, both depths. This is the path
      -- gen_gpu2d_frame.py cannot reach at all.
      for msz in 0 to 15 loop
         run_case('0', '0', '1', msz, 0, 7,   40);
         run_case('1', '1', '1', msz, 3, 130, 88);
      end loop;

      ca := cycles_a;
      cb := cycles_b;
      report "busy cycles over " & integer'image(nlines) & " lines: ref=" &
             integer'image(ca) & " (" & integer'image(ca / nlines) &
             "/line), pipelined=" & integer'image(cb) & " (" &
             integer'image(cb / nlines) & "/line)" severity note;

      if (nfail = 0) then
         report "tb_drawer_text_equiv: PASS  " & integer'image(ncase) &
                " configurations, " & integer'image(nlines) &
                " lines, identical line buffers" severity note;
      else
         report "tb_drawer_text_equiv: FAIL  " & integer'image(nfail) &
                " mismatches" severity failure;
      end if;

      tests_done <= true;
      wait;
   end process;

end architecture;
