-- SPDX-License-Identifier: GPL-2.0-or-later
-- Equivalence test: the merged rot/scale BG drawer (rtl/nds_drawer_affext,
-- pipelined v2) in BOTH of its modes, against the two separate serial drawers
-- it replaced (sim/nds_drawer_affine_ref.vhd and sim/nds_drawer_extended_ref
-- .vhd, verbatim copies of v1).
--
-- This bench therefore gates two independent changes at once, and both of
-- them against the SAME v1 references: the v2 pipelining, and the later
-- collapse of nds_drawer_affine into nds_drawer_affext (see that file's
-- header for why plain affine is a strict subset of extended variant 0).
-- ONE instance is elaborated with is_affine = '1' and one with '0'.
--
-- WHY THIS EXISTS. Same reason as tb_drawer_text_equiv, and the same trap.
-- The full-frame benches compare against gen_gpu2d_frame.py, whose BG model
-- does not implement mosaic at all, so they CANNOT check the mosaic path -
-- and v2 deliberately changed it: v1 decided each mosaic repeat from
-- pixeldata(15), which a pipelined pixel path cannot read (pixeldata is
-- written a cycle later, so the next pixel would see a stale bit), and v2
-- tracks last_transp instead. The four frame cases also fix one screen size
-- and one wrapping setting per BG, and never exercise a rotation extreme
-- enough to defeat the word-reuse chaining.
--
-- v1 is the proven-correct reference - it renders pixel-exact against the
-- melonDS oracle - so comparing against it directly covers what the golden
-- model cannot: mosaic at every horizontal size, all four screen sizes,
-- wrapping on and off, all three extended variants, ext palettes on and off,
-- tile flips, and rotations from axis-aligned (maximum word reuse) to steep
-- (none, so every pixel is its own fetch).
--
-- Both pairs are driven from the SAME configuration signals every line, so
-- one sweep exercises both drawers. Extended ignores nothing that affine
-- uses; affine ignores variant/extpalette/extpal_slot.
--
-- Each drawer gets its OWN memory and palette models, so neither can perturb
-- the other through arbitration. Both models answer the way the real ones do:
-- VRAM with a fixed latency (the v1 model one request at a time, the v2 model
-- pipelined and in-order, which is the whole point of v2), and palettes
-- unconditionally one cycle after the address.
--
-- The comparison is on the LINE BUFFER, not on the pixel stream: v2 writes
-- pixels at different times and can write them in a different order, and that
-- is legitimate. What must match is the resulting line, including WHICH
-- pixels were written at all - an out-of-bounds pixel on a non-wrapping BG
-- must stay unwritten in both.
--
-- Run: sim/run_drawer_affext_equiv.sh

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity tb_drawer_affext_equiv is
   generic
   (
      -- VRAM answer latency in clk cycles, for both models
      VLAT : integer := 5
   );
end entity;

architecture sim of tb_drawer_affext_equiv is

   signal clk        : std_logic := '0';
   signal tests_done : boolean := false;

   -- ================= stimulus config, driven to all four drawers =============
   signal line_trigger : std_logic := '0';
   signal drawline     : std_logic := '0';
   signal variant      : unsigned(1 downto 0) := "00";
   signal mapbase      : unsigned(18 downto 0) := (others => '0');
   signal tilebase     : unsigned(18 downto 0) := (others => '0');
   signal extpalette   : std_logic := '0';
   signal extpal_slot  : unsigned(1 downto 0) := "00";
   signal screensize   : unsigned(1 downto 0) := "00";
   signal wrapping     : std_logic := '0';
   signal mosaic       : std_logic := '0';
   signal mos_h        : unsigned(3 downto 0) := (others => '0');
   signal refX         : signed(27 downto 0) := (others => '0');
   signal refY         : signed(27 downto 0) := (others => '0');
   signal dx           : signed(15 downto 0) := to_signed(256, 16);
   signal dy           : signed(15 downto 0) := (others => '0');

   -- ================= backing stores, shared CONTENT =========================
   -- 512 KB BG space as words, and the two palette spaces. Filled with a
   -- deterministic pattern that produces plenty of index-0 (transparent),
   -- plenty of set flip bits, and - for the direct-colour variant - plenty of
   -- both alpha polarities.
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
         -- force a good share of zero bytes so transparency is hit, and a good
         -- share of clear bit15/bit31 so variant 2's alpha=0 path is hit
         if (i mod 5 = 0) then
            m(i) := std_logic_vector(s and x"0F0F0F0F");
         elsif (i mod 7 = 0) then
            m(i) := std_logic_vector(s and x"00FF00FF");
         elsif (i mod 11 = 0) then
            m(i) := std_logic_vector(s and x"7FFF7FFF");
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
   -- suffix r = reference (v1), p = pipelined (v2); a = affine, e = extended
   signal ar_busy, ap_busy, er_busy, ep_busy : std_logic;
   signal ar_we,   ap_we,   er_we,   ep_we   : std_logic;
   signal ar_data, ap_data, er_data, ep_data : std_logic_vector(15 downto 0);
   signal ar_x,    ap_x,    er_x,    ep_x    : integer range 0 to 255;

   signal ar_paddr, ap_paddr, er_paddr, ep_paddr : integer range 0 to 127;
   signal ar_pdata, ap_pdata, er_pdata, ep_pdata : std_logic_vector(31 downto 0) := (others => '0');
   signal ap_eaddr, er_eaddr, ep_eaddr : integer range 0 to 8191;
   signal ap_edata, er_edata, ep_edata : std_logic_vector(31 downto 0) := (others => '0');

   signal ar_vreq, ap_vreq, er_vreq, ep_vreq : std_logic;
   signal ar_vaddr, ap_vaddr, er_vaddr, ep_vaddr : integer range 0 to 131071;
   signal ar_vdata, ap_vdata, er_vdata, ep_vdata : std_logic_vector(31 downto 0) := (others => '0');
   signal ar_vdone, ap_vdone, er_vdone, ep_vdone : std_logic := '0';
   signal ap_vaccept, ep_vaccept : std_logic := '0';

   -- line buffers, plus a written mask so "never written" is distinguishable
   type t_line is array (0 to 255) of std_logic_vector(15 downto 0);
   signal ar_line, ap_line, er_line, ep_line : t_line := (others => (others => '0'));
   signal ar_seen, ap_seen, er_seen, ep_seen : std_logic_vector(0 to 255) := (others => '0');

   -- the v2 drawers' pipelined in-order VRAM model
   type t_vpipe is record
      v : std_logic;
      d : std_logic_vector(31 downto 0);
   end record;
   type t_vpipe_arr is array (0 to VLAT - 1) of t_vpipe;
   signal apipe : t_vpipe_arr := (others => ('0', (others => '0')));
   signal epipe : t_vpipe_arr := (others => ('0', (others => '0')));

   signal cyc_ar, cyc_ap, cyc_er, cyc_ep : integer := 0;

begin

   clk <= not clk after 5 ns when not tests_done else '0';

   -- ==========================================================================
   -- affine: reference (v1) and pipelined (v2)
   -- ==========================================================================
   i_aff_ref : entity work.nds_drawer_affine_ref
   port map
   (
      clk => clk, line_trigger => line_trigger, drawline => drawline, busy => ar_busy,
      mapbase => mapbase, tilebase => tilebase, screensize => screensize,
      wrapping => wrapping, mosaic => mosaic, Mosaic_H_Size => mos_h,
      refX => refX, refY => refY, refX_mosaic => refX, refY_mosaic => refY,
      dx => dx, dy => dy,
      pixel_we => ar_we, pixeldata => ar_data, pixel_x => ar_x,
      PALETTE_Drawer_addr => ar_paddr, PALETTE_Drawer_data => ar_pdata,
      PALETTE_Drawer_valid => '1',
      VRAM_Drawer_req => ar_vreq, VRAM_Drawer_addr => ar_vaddr,
      VRAM_Drawer_data => ar_vdata, VRAM_Drawer_done => ar_vdone
   );

   -- The merged drawer in AFFINE mode. variant / extpalette / extpal_slot are
   -- deliberately fed the SAME sweeping stimulus the extended instance gets,
   -- with is_affine tied high: plain affine must ignore all three, so this
   -- tests the override rather than assuming it. Its own EXTPAL port is wired
   -- to the real palette model for the same reason - if affine ever sourced a
   -- pixel from there, the comparison against v1 would break.
   i_aff_pipe : entity work.nds_drawer_affext
   port map
   (
      clk => clk, line_trigger => line_trigger, drawline => drawline, busy => ap_busy,
      is_affine => '1',
      variant => variant, mapbase => mapbase, tilebase => tilebase,
      extpalette => extpalette, extpal_slot => extpal_slot,
      screensize => screensize,
      wrapping => wrapping, mosaic => mosaic, Mosaic_H_Size => mos_h,
      refX => refX, refY => refY, refX_mosaic => refX, refY_mosaic => refY,
      dx => dx, dy => dy,
      pixel_we => ap_we, pixeldata => ap_data, pixel_x => ap_x,
      PALETTE_Drawer_addr => ap_paddr, PALETTE_Drawer_data => ap_pdata,
      PALETTE_Drawer_valid => '1',
      EXTPAL_Drawer_addr => ap_eaddr, EXTPAL_Drawer_data => ap_edata,
      EXTPAL_Drawer_valid => '1',
      VRAM_Drawer_req => ap_vreq, VRAM_Drawer_addr => ap_vaddr,
      VRAM_Drawer_data => ap_vdata, VRAM_Drawer_done => ap_vdone,
      VRAM_Drawer_accept => ap_vaccept
   );

   -- ==========================================================================
   -- extended: reference (v1) and pipelined (v2)
   -- ==========================================================================
   i_ext_ref : entity work.nds_drawer_extended_ref
   port map
   (
      clk => clk, line_trigger => line_trigger, drawline => drawline, busy => er_busy,
      variant => variant, mapbase => mapbase, tilebase => tilebase,
      extpalette => extpalette, extpal_slot => extpal_slot,
      screensize => screensize, wrapping => wrapping,
      mosaic => mosaic, Mosaic_H_Size => mos_h,
      refX => refX, refY => refY, refX_mosaic => refX, refY_mosaic => refY,
      dx => dx, dy => dy,
      pixel_we => er_we, pixeldata => er_data, pixel_x => er_x,
      PALETTE_Drawer_addr => er_paddr, PALETTE_Drawer_data => er_pdata,
      PALETTE_Drawer_valid => '1',
      EXTPAL_Drawer_addr => er_eaddr, EXTPAL_Drawer_data => er_edata,
      EXTPAL_Drawer_valid => '1',
      VRAM_Drawer_req => er_vreq, VRAM_Drawer_addr => er_vaddr,
      VRAM_Drawer_data => er_vdata, VRAM_Drawer_done => er_vdone
   );

   i_ext_pipe : entity work.nds_drawer_affext
   port map
   (
      clk => clk, line_trigger => line_trigger, drawline => drawline, busy => ep_busy,
      is_affine => '0',
      variant => variant, mapbase => mapbase, tilebase => tilebase,
      extpalette => extpalette, extpal_slot => extpal_slot,
      screensize => screensize, wrapping => wrapping,
      mosaic => mosaic, Mosaic_H_Size => mos_h,
      refX => refX, refY => refY, refX_mosaic => refX, refY_mosaic => refY,
      dx => dx, dy => dy,
      pixel_we => ep_we, pixeldata => ep_data, pixel_x => ep_x,
      PALETTE_Drawer_addr => ep_paddr, PALETTE_Drawer_data => ep_pdata,
      PALETTE_Drawer_valid => '1',
      EXTPAL_Drawer_addr => ep_eaddr, EXTPAL_Drawer_data => ep_edata,
      EXTPAL_Drawer_valid => '1',
      VRAM_Drawer_req => ep_vreq, VRAM_Drawer_addr => ep_vaddr,
      VRAM_Drawer_data => ep_vdata, VRAM_Drawer_done => ep_vdone,
      VRAM_Drawer_accept => ep_vaccept
   );

   -- palettes: unconditional, one cycle after the address (what the private
   -- read ports in nds_gpu2d now provide)
   process (clk)
   begin
      if rising_edge(clk) then
         ar_pdata <= palm(ar_paddr);
         ap_pdata <= palm(ap_paddr);
         er_pdata <= palm(er_paddr);
         ep_pdata <= palm(ep_paddr);
         ap_edata <= epalm(ap_eaddr);
         er_edata <= epalm(er_eaddr);
         ep_edata <= epalm(ep_eaddr);
      end if;
   end process;

   -- v1's VRAM model: one request at a time, fixed latency
   p_aff_ref_vram : process
   begin
      wait until rising_edge(clk) and ar_vreq = '1';
      for k in 1 to VLAT loop
         wait until rising_edge(clk);
      end loop;
      ar_vdata <= bgmem(ar_vaddr);
      ar_vdone <= '1';
      wait until rising_edge(clk);
      ar_vdone <= '0';
   end process;

   p_ext_ref_vram : process
   begin
      wait until rising_edge(clk) and er_vreq = '1';
      for k in 1 to VLAT loop
         wait until rising_edge(clk);
      end loop;
      er_vdata <= bgmem(er_vaddr);
      er_vdone <= '1';
      wait until rising_edge(clk);
      er_vdone <= '0';
   end process;

   -- v2's VRAM model: accepts one request per cycle, answers IN ISSUE ORDER
   -- after VLAT cycles. Accepting immediately is the strongest case for the
   -- pipeline (most requests in flight at once).
   ap_vaccept <= ap_vreq;
   ep_vaccept <= ep_vreq;

   p_aff_pipe_vram : process (clk)
   begin
      if rising_edge(clk) then
         for k in VLAT - 1 downto 1 loop
            apipe(k) <= apipe(k - 1);
         end loop;
         apipe(0).v <= '0';
         if (ap_vreq = '1') then
            apipe(0).v <= '1';
            apipe(0).d <= bgmem(ap_vaddr);
         end if;
         ap_vdone <= apipe(VLAT - 1).v;
         ap_vdata <= apipe(VLAT - 1).d;
      end if;
   end process;

   p_ext_pipe_vram : process (clk)
   begin
      if rising_edge(clk) then
         for k in VLAT - 1 downto 1 loop
            epipe(k) <= epipe(k - 1);
         end loop;
         epipe(0).v <= '0';
         if (ep_vreq = '1') then
            epipe(0).v <= '1';
            epipe(0).d <= bgmem(ep_vaddr);
         end if;
         ep_vdone <= epipe(VLAT - 1).v;
         ep_vdata <= epipe(VLAT - 1).d;
      end if;
   end process;

   -- ==========================================================================
   -- line collection + busy-time measurement
   -- ==========================================================================
   process (clk)
   begin
      if rising_edge(clk) then
         if (drawline = '1') then
            ar_seen <= (others => '0');
            ap_seen <= (others => '0');
            er_seen <= (others => '0');
            ep_seen <= (others => '0');
         else
            if (ar_we = '1') then ar_line(ar_x) <= ar_data; ar_seen(ar_x) <= '1'; end if;
            if (ap_we = '1') then ap_line(ap_x) <= ap_data; ap_seen(ap_x) <= '1'; end if;
            if (er_we = '1') then er_line(er_x) <= er_data; er_seen(er_x) <= '1'; end if;
            if (ep_we = '1') then ep_line(ep_x) <= ep_data; ep_seen(ep_x) <= '1'; end if;
         end if;
         if (ar_busy = '1') then cyc_ar <= cyc_ar + 1; end if;
         if (ap_busy = '1') then cyc_ap <= cyc_ap + 1; end if;
         if (er_busy = '1') then cyc_er <= cyc_er + 1; end if;
         if (ep_busy = '1') then cyc_ep <= cyc_ep + 1; end if;
      end if;
   end process;

   -- ==========================================================================
   -- stimulus
   -- ==========================================================================
   pmain : process
      variable nfail  : integer := 0;
      variable ncase  : integer := 0;
      variable nlines : integer := 0;

      procedure check(name : string; y : integer;
                      rseen, pseen : std_logic_vector(0 to 255);
                      rline, pline : t_line) is
      begin
         for x in 0 to 255 loop
            if (rseen(x) /= pseen(x)) then
               nfail := nfail + 1;
               if (nfail <= 20) then
                  report name & " case " & integer'image(ncase) &
                         " y=" & integer'image(y) & " x=" & integer'image(x) &
                         " written ref=" & std_logic'image(rseen(x)) &
                         " pipe=" & std_logic'image(pseen(x)) severity error;
               end if;
            elsif (rseen(x) = '1' and rline(x) /= pline(x)) then
               nfail := nfail + 1;
               if (nfail <= 20) then
                  report name & " case " & integer'image(ncase) &
                         " y=" & integer'image(y) & " x=" & integer'image(x) &
                         " ref=" & to_hstring(rline(x)) &
                         " pipe=" & to_hstring(pline(x)) severity error;
               end if;
            end if;
         end loop;
      end procedure;

      -- one line: load the reference point, draw, wait for all four, compare
      procedure run_line(y : integer; rx, ry : integer) is
      begin
         refX <= to_signed(rx, 28);
         refY <= to_signed(ry, 28);
         wait until rising_edge(clk);
         line_trigger <= '1';
         wait until rising_edge(clk);
         line_trigger <= '0';
         wait until rising_edge(clk);
         drawline <= '1';
         wait until rising_edge(clk);
         drawline <= '0';
         wait until rising_edge(clk);
         while (ar_busy = '1' or ap_busy = '1' or er_busy = '1' or ep_busy = '1') loop
            wait until rising_edge(clk);
         end loop;
         -- let the last registered pixel write settle
         wait until rising_edge(clk);
         wait until rising_edge(clk);

         check("affine",   y, ar_seen, ap_seen, ar_line, ap_line);
         check("extended", y, er_seen, ep_seen, er_line, ep_line);
         nlines := nlines + 1;
      end procedure;

      -- one configuration, swept over a handful of lines
      procedure run_case(vr : integer; sz : integer; wrap, ep, mos : std_logic;
                         msz : integer; idx, idy : integer) is
      begin
         variant     <= to_unsigned(vr, 2);
         screensize  <= to_unsigned(sz, 2);
         wrapping    <= wrap;
         extpalette  <= ep;
         mosaic      <= mos;
         mos_h       <= to_unsigned(msz, 4);
         dx          <= to_signed(idx, 16);
         dy          <= to_signed(idy, 16);
         extpal_slot <= to_unsigned(ncase mod 4, 2);
         mapbase     <= to_unsigned(((ncase mod 8) * 2048) mod 524288, 19);
         tilebase    <= to_unsigned(16#20000# + ((ncase mod 4) * 16384), 19);
         wait until rising_edge(clk);
         for y in 0 to 3 loop
            run_line(y * 41, (y * 37 - 60) * 256, (y * 53 + 20) * 256);
         end loop;
         ncase := ncase + 1;
      end procedure;
   begin
      wait until rising_edge(clk);
      wait until rising_edge(clk);

      -- One warm-up line, NOT compared. Both drawers hold their configuration
      -- and caches across lines and are only re-armed by drawline, so the very
      -- first line of a simulation runs against power-up register values rather
      -- than a configured BG - a property of this bench, not of the hardware,
      -- where the CPU has written the registers long before the first drawline.
      wait until rising_edge(clk);
      line_trigger <= '1';
      wait until rising_edge(clk);
      line_trigger <= '0';
      wait until rising_edge(clk);
      drawline <= '1';
      wait until rising_edge(clk);
      drawline <= '0';
      wait until rising_edge(clk);
      while (ar_busy = '1' or ap_busy = '1' or er_busy = '1' or ep_busy = '1') loop
         wait until rising_edge(clk);
      end loop;
      wait until rising_edge(clk);
      wait until rising_edge(clk);

      -- ---- variant x screen size x wrapping, axis-aligned (max word reuse) --
      for vr in 0 to 2 loop
         for sz in 0 to 3 loop
            run_case(vr, sz, '0', '0', '0', 0, 256, 0);
            run_case(vr, sz, '1', '0', '0', 0, 256, 0);
         end loop;
      end loop;

      -- ---- ext palettes (extended variant 0 only path that uses them) -------
      for sz in 0 to 3 loop
         run_case(0, sz, '0', '1', '0', 0, 256, 0);
         run_case(0, sz, '1', '1', '0', 0, 256, 0);
      end loop;

      -- ---- rotations: from gentle to steep. The steep ones defeat the word
      -- reuse chaining entirely, so every pixel becomes its own fetch and the
      -- queue runs at its deepest.
      for vr in 0 to 2 loop
         run_case(vr, 2, '1', '0', '0', 0,  256,   64);
         run_case(vr, 2, '1', '0', '0', 0,  181,  181);
         run_case(vr, 3, '1', '0', '0', 0,   64,  256);
         run_case(vr, 3, '0', '0', '0', 0, -256,  128);
         run_case(vr, 1, '0', '0', '0', 0,  512, -512);   -- 2x zoom out, steep
         run_case(vr, 1, '1', '0', '0', 0,  128,  -64);
      end loop;

      -- ---- scaling that lands many pixels on the SAME source texel, which is
      -- the opposite extreme: one fetched word serves a long run of pixels
      for vr in 0 to 2 loop
         run_case(vr, 2, '1', '0', '0', 0, 64,  0);
         run_case(vr, 2, '1', '0', '0', 0, 16, 16);
      end loop;

      -- ---- MOSAIC: every horizontal size. This is the path
      -- gen_gpu2d_frame.py cannot reach at all.
      for msz in 0 to 15 loop
         run_case(0, 1, '1', '0', '1', msz, 256,  0);
         run_case(1, 2, '1', '0', '1', msz, 181, 181);
         run_case(2, 3, '0', '0', '1', msz, 256, 64);
         run_case(0, 2, '1', '1', '1', msz, 128, 32);
      end loop;

      report "busy cycles over " & integer'image(nlines) & " lines/drawer: " &
             "affine ref=" & integer'image(cyc_ar / nlines) &
             "/line pipelined=" & integer'image(cyc_ap / nlines) &
             "/line, extended ref=" & integer'image(cyc_er / nlines) &
             "/line pipelined=" & integer'image(cyc_ep / nlines) & "/line"
             severity note;

      if (nfail = 0) then
         report "tb_drawer_affext_equiv: PASS  " & integer'image(ncase) &
                " configurations, " & integer'image(nlines) &
                " lines x 2 drawers, identical line buffers" severity note;
      else
         report "tb_drawer_affext_equiv: FAIL  " & integer'image(nfail) &
                " mismatches" severity failure;
      end if;

      tests_done <= true;
      wait;
   end process;

end architecture;
