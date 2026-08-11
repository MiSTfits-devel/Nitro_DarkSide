-- M5 part 1: NDS BG drawer line tests. Instantiates nds_drawer_text and
-- nds_drawer_affext against behavioral VRAM (512 KB flat BG space), std
-- palette and ext-pal stores. Palettes answer UNCONDITIONALLY one cycle after
-- the address (the private per-BG read ports nds_gpu2d now has) and VRAM
-- answers in issue order with several requests in flight (the line-server
-- contract) - see the two model blocks below, both of which had to be brought
-- forward when the drawers were pipelined. nds_drawer_affext is elaborated
-- TWICE here, once with is_affine='1' and once with '0'.
-- Cases come from sim/tests/gpu_bg_vectors.hex
-- (gen_gpu_bg.py golden model): 16 header words + 256 expected pixels per
-- case; the rendered line (0x8000 where nothing was written) must match
-- exactly. Run: sim/run_gpu_bg.sh  (regenerate vectors first)

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.textio.all;

entity tb_gpu_bg is
   generic
   (
      VRAMFILE   : string := "sim/tests/gpu_bg_vram.hex";
      PALFILE    : string := "sim/tests/gpu_bg_pal.hex";
      EXTPALFILE : string := "sim/tests/gpu_bg_extpal.hex";
      VECFILE    : string := "sim/tests/gpu_bg_vectors.hex";
      TIMEOUT_MS : integer := 10
   );
end entity;

architecture sim of tb_gpu_bg is

   signal clk : std_logic := '0';

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

   constant vram    : t_words(0 to 131071) := load_hex(VRAMFILE, 131072);
   constant pal     : t_words(0 to 127)    := load_hex(PALFILE, 128);
   constant extpal  : t_words(0 to 8191)   := load_hex(EXTPALFILE, 8192);
   -- 1 count word + up to 64 cases x 272 words
   constant vectors : t_words(0 to 17408)  := load_hex(VECFILE, 17409);

   -- config (shared by both drawers)
   signal ypos, ypos_mosaic : integer range 0 to 191 := 0;
   signal mapbase, tilebase : unsigned(18 downto 0) := (others => '0');
   signal hicolor, extpalette, mosaic, wrapping : std_logic := '0';
   signal extpal_slot : unsigned(1 downto 0) := "00";
   signal mosaic_h    : unsigned(3 downto 0) := (others => '0');
   signal screensize  : unsigned(1 downto 0) := "00";
   signal scrollX, scrollY : unsigned(8 downto 0) := (others => '0');
   signal refX, refY  : signed(27 downto 0) := (others => '0');
   signal dx, dy      : signed(15 downto 0) := (others => '0');

   signal drawline_t, drawline_a, drawline_e, line_trigger : std_logic := '0';
   signal busy_t, busy_a, busy_e : std_logic;
   signal variant : unsigned(1 downto 0) := "00";

   -- text drawer memory ports
   signal t_pal_addr    : integer range 0 to 127;
   signal t_extpal_addr : integer range 0 to 8191;
   signal t_vram_addr   : integer range 0 to 131071;
   signal t_pal_data, t_extpal_data, t_vram_data : std_logic_vector(31 downto 0);
   signal t_vram_req : std_logic;
   signal t_vram_done : std_logic := '0';

   -- affine drawer memory ports
   signal a_pal_addr    : integer range 0 to 127;
   signal a_extpal_addr : integer range 0 to 8191;
   signal a_vram_addr   : integer range 0 to 131071;
   signal a_pal_data, a_extpal_data, a_vram_data : std_logic_vector(31 downto 0);
   signal a_vram_req : std_logic;
   signal a_vram_done : std_logic := '0';

   -- extended drawer memory ports
   signal e_pal_addr    : integer range 0 to 127;
   signal e_extpal_addr : integer range 0 to 8191;
   signal e_vram_addr   : integer range 0 to 131071;
   signal e_pal_data, e_extpal_data, e_vram_data : std_logic_vector(31 downto 0);
   signal e_vram_req : std_logic;
   signal e_vram_done : std_logic := '0';

   signal mem_valid : std_logic := '0';
   -- done defaults


   -- pixel outputs
   signal pixel_we_t, pixel_we_a, pixel_we_e : std_logic;
   signal pixeldata_t, pixeldata_a, pixeldata_e : std_logic_vector(15 downto 0);
   signal pixel_x_t, pixel_x_a, pixel_x_e : integer range 0 to 255;

   type t_line is array (0 to 255) of std_logic_vector(15 downto 0);
   signal linebuf : t_line := (others => (others => '0'));
   signal clear_line : std_logic := '0';

   signal tests_done : boolean := false;

begin

   clk <= not clk after 5 ns when not tests_done else '0';

   idrawer_text : entity work.nds_drawer_text
   port map
   (
      clk                  => clk,
      drawline             => drawline_t,
      busy                 => busy_t,
      ypos                 => ypos,
      ypos_mosaic          => ypos_mosaic,
      mapbase              => mapbase,
      tilebase             => tilebase,
      hicolor              => hicolor,
      extpalette           => extpalette,
      extpal_slot          => extpal_slot,
      mosaic               => mosaic,
      Mosaic_H_Size        => mosaic_h,
      screensize           => screensize,
      scrollX              => scrollX,
      scrollY              => scrollY,
      pixel_we             => pixel_we_t,
      pixeldata            => pixeldata_t,
      pixel_x              => pixel_x_t,
      PALETTE_Drawer_addr  => t_pal_addr,
      PALETTE_Drawer_data  => t_pal_data,
      PALETTE_Drawer_valid => mem_valid,
      EXTPAL_Drawer_addr   => t_extpal_addr,
      EXTPAL_Drawer_data   => t_extpal_data,
      EXTPAL_Drawer_valid  => mem_valid,
      VRAM_Drawer_req      => t_vram_req,
      VRAM_Drawer_addr     => t_vram_addr,
      VRAM_Drawer_data     => t_vram_data,
      VRAM_Drawer_done     => t_vram_done
   );

   -- the merged rot/scale drawer in AFFINE mode. variant / extpalette are fed
   -- the extended stimulus on purpose: is_affine must override both.
   idrawer_affine : entity work.nds_drawer_affext
   port map
   (
      clk                  => clk,
      line_trigger         => line_trigger,
      drawline             => drawline_a,
      busy                 => busy_a,
      is_affine            => '1',
      variant              => variant,
      extpalette           => extpalette,
      extpal_slot          => extpal_slot,
      mapbase              => mapbase,
      tilebase             => tilebase,
      screensize           => screensize,
      wrapping             => wrapping,
      mosaic               => mosaic,
      Mosaic_H_Size        => mosaic_h,
      refX                 => refX,
      refY                 => refY,
      refX_mosaic          => refX,
      refY_mosaic          => refY,
      dx                   => dx,
      dy                   => dy,
      pixel_we             => pixel_we_a,
      pixeldata            => pixeldata_a,
      pixel_x              => pixel_x_a,
      PALETTE_Drawer_addr  => a_pal_addr,
      PALETTE_Drawer_data  => a_pal_data,
      PALETTE_Drawer_valid => mem_valid,
      EXTPAL_Drawer_addr   => a_extpal_addr,
      EXTPAL_Drawer_data   => a_extpal_data,
      EXTPAL_Drawer_valid  => mem_valid,
      VRAM_Drawer_req      => a_vram_req,
      VRAM_Drawer_addr     => a_vram_addr,
      VRAM_Drawer_data     => a_vram_data,
      VRAM_Drawer_done     => a_vram_done
   );

   idrawer_ext : entity work.nds_drawer_affext
   port map
   (
      clk                  => clk,
      line_trigger         => line_trigger,
      drawline             => drawline_e,
      busy                 => busy_e,
      is_affine            => '0',
      variant              => variant,
      mapbase              => mapbase,
      tilebase             => tilebase,
      extpalette           => extpalette,
      extpal_slot          => extpal_slot,
      screensize           => screensize,
      wrapping             => wrapping,
      mosaic               => mosaic,
      Mosaic_H_Size        => mosaic_h,
      refX                 => refX,
      refY                 => refY,
      refX_mosaic          => refX,
      refY_mosaic          => refY,
      dx                   => dx,
      dy                   => dy,
      pixel_we             => pixel_we_e,
      pixeldata            => pixeldata_e,
      pixel_x              => pixel_x_e,
      PALETTE_Drawer_addr  => e_pal_addr,
      PALETTE_Drawer_data  => e_pal_data,
      PALETTE_Drawer_valid => mem_valid,
      EXTPAL_Drawer_addr   => e_extpal_addr,
      EXTPAL_Drawer_data   => e_extpal_data,
      EXTPAL_Drawer_valid  => mem_valid,
      VRAM_Drawer_req      => e_vram_req,
      VRAM_Drawer_addr     => e_vram_addr,
      VRAM_Drawer_data     => e_vram_data,
      VRAM_Drawer_done     => e_vram_done
   );

   -- Palette / ext-pal service: UNCONDITIONAL, one cycle after the address.
   --
   -- This model used to answer on alternate cycles, standing in for the old
   -- round-robin arbitration, and mem_valid toggled with it. That contract no
   -- longer exists anywhere: nds_gpu2d gives every BG a PRIVATE palette read
   -- port (see gpal_bg and bgp_valid, which is hardwired '1'), so the answer
   -- always lands the next cycle and no drawer ever waits for its turn. All
   -- three v2 drawers therefore take the palette word one cycle after they
   -- present the address and do not consult PALETTE_Drawer_valid at all -
   -- against an every-other-cycle model they latch a stale word on half the
   -- pixels. This is the same staleness the VRAM model below was fixed for,
   -- and it hit the TEXT cases as well, which is what gives it away.
   --
   -- mem_valid is now held high: nothing reads it but the port maps.
   p_mem : process (clk)
   begin
      if rising_edge(clk) then
         t_pal_data    <= pal(t_pal_addr);
         t_extpal_data <= extpal(t_extpal_addr);
         a_pal_data    <= pal(a_pal_addr);
         e_pal_data    <= pal(e_pal_addr);
         a_extpal_data <= extpal(a_extpal_addr);
         e_extpal_data <= extpal(e_extpal_addr);
         mem_valid     <= '1';
      end if;
   end process;

   -- VRAM on the line-server contract AS IT IS TODAY: one request accepted per
   -- cycle, answered IN ISSUE ORDER a fixed number of cycles later.
   --
   -- The previous model waited for one request to retire before it would even
   -- look at the next. Every BG drawer now runs its fetch stage ahead of its
   -- pixel stage and keeps several requests in flight, so that model silently
   -- dropped all but the first and the bench timed out - it had already been
   -- doing so since the text drawer was pipelined, before affine and extended
   -- joined it. Accept is left at its default '1', which is exactly true of a
   -- model that takes a request every cycle.
   --
   -- Latencies differ per stream so the three drawers do not march in lockstep.
   p_vram_t : process (clk)
      type t_pipe is array (0 to 5) of std_logic_vector(31 downto 0);
      variable d : t_pipe := (others => (others => '0'));
      variable v : std_logic_vector(0 to 5) := (others => '0');
   begin
      if rising_edge(clk) then
         for k in 5 downto 1 loop d(k) := d(k-1); v(k) := v(k-1); end loop;
         v(0) := '0';
         if (t_vram_req = '1') then
            v(0) := '1';
            d(0) := vram(t_vram_addr);
         end if;
         t_vram_done <= v(5);
         t_vram_data <= d(5);
      end if;
   end process;

   p_vram_a : process (clk)
      type t_pipe is array (0 to 3) of std_logic_vector(31 downto 0);
      variable d : t_pipe := (others => (others => '0'));
      variable v : std_logic_vector(0 to 3) := (others => '0');
   begin
      if rising_edge(clk) then
         for k in 3 downto 1 loop d(k) := d(k-1); v(k) := v(k-1); end loop;
         v(0) := '0';
         if (a_vram_req = '1') then
            v(0) := '1';
            d(0) := vram(a_vram_addr);
         end if;
         a_vram_done <= v(3);
         a_vram_data <= d(3);
      end if;
   end process;

   p_vram_e : process (clk)
      type t_pipe is array (0 to 4) of std_logic_vector(31 downto 0);
      variable d : t_pipe := (others => (others => '0'));
      variable v : std_logic_vector(0 to 4) := (others => '0');
   begin
      if rising_edge(clk) then
         for k in 4 downto 1 loop d(k) := d(k-1); v(k) := v(k-1); end loop;
         v(0) := '0';
         if (e_vram_req = '1') then
            v(0) := '1';
            d(0) := vram(e_vram_addr);
         end if;
         e_vram_done <= v(4);
         e_vram_data <= d(4);
      end if;
   end process;

   -- pixel collect
   p_collect : process (clk)
   begin
      if rising_edge(clk) then
         if (clear_line = '1') then
            linebuf <= (others => x"8000");
         else
            if (pixel_we_t = '1') then
               linebuf(pixel_x_t) <= pixeldata_t;
            end if;
            if (pixel_we_a = '1') then
               linebuf(pixel_x_a) <= pixeldata_a;
            end if;
            if (pixel_we_e = '1') then
               linebuf(pixel_x_e) <= pixeldata_e;
            end if;
         end if;
      end if;
   end process;

   -- case driver
   p_drive : process
      variable ncases : integer;
      variable base   : integer;
      variable kind   : integer;
      variable flags  : std_logic_vector(31 downto 0);
      variable exp    : std_logic_vector(15 downto 0);
      variable nfail  : integer := 0;
      variable v_busy : std_logic;
   begin
      -- Settle before the FIRST case. The drawers have no reset port: they come
      -- up on their signal initial values and need a few cycles of clock before
      -- the first drawline, which the real engine always gets (nds_gpu2d resets
      -- them and the first drawline is a whole frame-start away). This bench
      -- used to fire its first drawline ~7 cycles after t=0, and case 0 - and
      -- ONLY case 0, whatever it was configured as - rendered wrong.
      --
      -- Measured threshold: 8 settle cycles still fails, 16 and above pass, and
      -- duplicating case 0 at the front makes the copy fail while the original
      -- passes at index 1. So it tracks position in the run, not configuration.
      -- 64 leaves plenty of margin and costs nothing.
      for k in 1 to 64 loop wait until rising_edge(clk); end loop;
      ncases := to_integer(unsigned(vectors(0)));
      report "running " & integer'image(ncases) & " cases" severity note;

      for c in 0 to ncases - 1 loop
         base := 1 + c * 272;
         kind := to_integer(unsigned(vectors(base + 0)));

         ypos        <= to_integer(unsigned(vectors(base + 1)));
         ypos_mosaic <= to_integer(unsigned(vectors(base + 2)));
         mapbase     <= unsigned(vectors(base + 3)(18 downto 0));
         tilebase    <= unsigned(vectors(base + 4)(18 downto 0));
         flags       := vectors(base + 5);
         hicolor     <= flags(0);
         extpalette  <= flags(1);
         mosaic      <= flags(2);
         wrapping    <= flags(3);
         extpal_slot <= unsigned(vectors(base + 6)(1 downto 0));
         mosaic_h    <= unsigned(vectors(base + 7)(3 downto 0));
         screensize  <= unsigned(vectors(base + 8)(1 downto 0));
         scrollX     <= unsigned(vectors(base + 9)(8 downto 0));
         scrollY     <= unsigned(vectors(base + 10)(8 downto 0));
         refX        <= signed(vectors(base + 11)(27 downto 0));
         refY        <= signed(vectors(base + 12)(27 downto 0));
         dx          <= signed(vectors(base + 13)(15 downto 0));
         dy          <= signed(vectors(base + 14)(15 downto 0));
         variant     <= unsigned(vectors(base + 15)(1 downto 0));

         -- clear the collected line
         clear_line <= '1';
         wait until rising_edge(clk);
         wait until rising_edge(clk);
         clear_line <= '0';

         for k in 1 to 4 loop wait until rising_edge(clk); end loop;

         if (kind = 1 or kind = 2) then
            line_trigger <= '1';
            wait until rising_edge(clk);
            line_trigger <= '0';
            wait until rising_edge(clk);
            if (kind = 1) then
               drawline_a <= '1';
            else
               drawline_e <= '1';
            end if;
            wait until rising_edge(clk);
            drawline_a <= '0';
            drawline_e <= '0';
         else
            drawline_t <= '1';
            wait until rising_edge(clk);
            drawline_t <= '0';
         end if;

         -- wait for completion (busy rises on the drawline cycle)
         loop
            wait until rising_edge(clk);
            if (kind = 1) then v_busy := busy_a;
            elsif (kind = 2) then v_busy := busy_e;
            else v_busy := busy_t; end if;
            exit when v_busy = '0';
         end loop;
         for k in 1 to 4 loop wait until rising_edge(clk); end loop;

         -- compare
         for x in 0 to 255 loop
            exp := vectors(base + 16 + x)(15 downto 0);
            if (linebuf(x) /= exp) then
               nfail := nfail + 1;
               report "case " & integer'image(c) & " x=" & integer'image(x) &
                      " expected=" & to_hstring(exp) & " got=" & to_hstring(linebuf(x))
                      severity error;
            end if;
         end loop;
         report "case " & integer'image(c) & " done" severity note;
      end loop;

      if (nfail = 0) then
         report "tb_gpu_bg: PASS  " & integer'image(ncases) & " cases" severity note;
      else
         report "tb_gpu_bg: FAIL  " & integer'image(nfail) & " pixel mismatches" severity failure;
      end if;
      tests_done <= true;
      wait;
   end process;

   p_watchdog : process
   begin
      wait for TIMEOUT_MS * 1 ms;
      if not tests_done then
         report "tb_gpu_bg: TIMEOUT" severity failure;
      end if;
      wait;
   end process;

end architecture;
