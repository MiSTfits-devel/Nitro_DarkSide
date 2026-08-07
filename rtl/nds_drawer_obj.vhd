-- SPDX-License-Identifier: GPL-2.0-or-later
-- NDS OBJ drawer (fork of gba_drawer_obj). One instance renders all 128
-- sprites of one line into the OBJ line buffer (color + settings planes).
-- Deltas vs the GBA donor:
--
--   * 256-pixel line, ypos 0..191, 256 KB OBJ char space (18-bit addresses)
--   * 1D tile mapping boundary: base = tileno * (32 << tile_boundary)
--     (DISPCNT 21:20); 2D unchanged (tileno*32, 1 KB row stride). NDS does
--     NOT force even tile numbers for 256-color 2D sprites (melonDS).
--   * OBJ extended palette (obj_extpal, DISPCNT.31): 256-color sprites
--     look up palno*256+color in the engine's 8 KB OBJ ext-pal slot;
--     without it the palette number is ignored (GBA behavior).
--   * bitmap sprites (OBJ mode "11"): direct-color pixels, opaque iff
--     bit15; attr2 palette field is the blend alpha - alpha=0 hides the
--     sprite. Addressing per GBATEK/melonDS:
--       1D (bitmap_1d='1'): base = tileno << (7 + bitmap_1d_boundary),
--          row stride = sprite width * 2   (bitmap_2d_wide='1' + 1D is
--          'reserved', draws nothing)
--       2D: wide: base = (tileno&1F)*16 + (tileno&3E0)*128, stride 512
--           narrow: base = (tileno&0F)*16 + (tileno&3F0)*128, stride 256
--     Affine bitmap sprites fetch base + yyy*stride + xxx*2.
--   * settings plane widened to 8 bits:
--     [1:0] priority, [2] semi-transparent (mode 01), [3] bitmap sprite,
--     [7:4] bitmap alpha (attr2 palette field)
--   * the hardware per-line OBJ time budget IS enforced (HW_TIME_LIMIT):
--     1210 cycles with the H-Blank interval free, 954 without, charged as
--     1 cycle per field pixel for a normal sprite and 10 + 2 per pixel for
--     a rot/scal one. melonDS does not model this, so the golden models do
--     not either - see the generic's comment for why that is still safe.
--
-- OAM layout, affine pipeline and the priority merge into the double
-- line buffer are unchanged from the donor. H-mosaic follows NDS hardware
-- (melonDS ApplySpriteMosaicX): the repeat grid is screen-aligned
-- (restart where x mod (size+1) = 0) and restarts at each sprite's first
-- emitted pixel - the donor counted relative to the sprite edge instead.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nds_drawer_obj is
   generic
   (
      -- Hardware OBJ per-line time budget, per GBATEK. Hardware gives OBJ
      -- rendering 1210 cycles per line when DISPCNT.23 (H-Blank interval
      -- free) is set and 954 when it is not, and charges:
      --
      --    normal sprite   : 1 cycle per pixel of the sprite's field width
      --    rot/scal sprite : 10 cycles of setup + 2 cycles per field pixel
      --
      -- A line that asks for more than that loses its LAST sprites - OAM
      -- order is priority order, so running out of budget drops the lowest
      -- priority ones, which is what this walk does too.
      --
      -- This is counted in HARDWARE cycles, not ours. Charging our own clock
      -- against 1210 would be wrong by whatever the drawer's cycles-per-pixel
      -- happens to be, and would drop sprites hardware keeps.
      --
      -- Set to '0' to render every sprite regardless. melonDS does not model
      -- the limit, so the generated golden models expect '0' behaviour on any
      -- scene that would exceed the budget.
      HW_TIME_LIMIT : std_logic := '1'
   );
   port
   (
      clk                  : in  std_logic;

      drawline             : in  std_logic;
      busy                 : out std_logic := '0';
      ypos                 : in  integer range 0 to 191;
      ypos_mosaic          : in  integer range 0 to 191;

      one_dim_mapping      : in  std_logic;                    -- DISPCNT.4
      tile_boundary        : in  unsigned(1 downto 0);         -- DISPCNT.21:20
      bitmap_1d            : in  std_logic;                    -- DISPCNT.6
      bitmap_2d_wide       : in  std_logic;                    -- DISPCNT.5
      bitmap_1d_boundary   : in  std_logic;                    -- DISPCNT.22
      obj_extpal           : in  std_logic;                    -- DISPCNT.31
      Mosaic_H_Size        : in  unsigned(3 downto 0);

      hblankfree           : in  std_logic;

      pixel_we_color       : out std_logic := '0';
      pixeldata_color      : out std_logic_vector(15 downto 0) := (others => '0');
      pixel_we_settings    : out std_logic := '0';
      pixeldata_settings   : out std_logic_vector(7 downto 0) := (others => '0');
      pixel_x              : out integer range 0 to 255;
      pixel_objwnd         : out std_logic := '0';

      OAMRAM_Drawer_addr   : buffer integer range 0 to 255;
      OAMRAM_Drawer_data   : in  std_logic_vector(31 downto 0);

      PALETTE_Drawer_addr  : out integer range 0 to 127;
      PALETTE_Drawer_data  : in  std_logic_vector(31 downto 0);

      EXTPAL_Drawer_addr   : out integer range 0 to 2047;      -- 8 KB OBJ ext-pal slot
      EXTPAL_Drawer_data   : in  std_logic_vector(31 downto 0);

      -- SEVERAL requests may be in flight: present req with addr, the arbiter
      -- pulses accept when it takes it, and done pulses once per answer IN
      -- ISSUE ORDER (nds_gpu2d's arbiter and nds_vram's server both retire in
      -- order, which is what lets the word queue below be a plain FIFO).
      -- accept defaults to '1' so a bench that does not model it still works.
      VRAM_Drawer_req      : out std_logic := '0';
      VRAM_Drawer_addr     : out integer range 0 to 65535;     -- 256 KB OBJ space
      VRAM_Drawer_data     : in  std_logic_vector(31 downto 0);
      VRAM_Drawer_done     : in  std_logic;
      VRAM_Drawer_accept   : in  std_logic := '1'
   );
end entity;

architecture arch of nds_drawer_obj is

   -- Atr0
   constant OAM_Y_HI         : integer := 7;
   constant OAM_Y_LO         : integer := 0;
   constant OAM_AFFINE       : integer := 8;
   constant OAM_DBLSIZE      : integer := 9;
   constant OAM_OFF_HI       : integer := 9;
   constant OAM_OFF_LO       : integer := 8;
   constant OAM_MODE_HI      : integer := 11;
   constant OAM_MODE_LO      : integer := 10;
   constant OAM_MOSAIC       : integer := 12;
   constant OAM_HICOLOR      : integer := 13;
   constant OAM_OBJSHAPE_HI  : integer := 15;
   constant OAM_OBJSHAPE_LO  : integer := 14;

   -- Atr1
   constant OAM_X_HI         : integer := 8;
   constant OAM_X_LO         : integer := 0;
   constant OAM_AFF_HI       : integer := 13;
   constant OAM_AFF_LO       : integer := 9;
   constant OAM_HFLIP        : integer := 12;
   constant OAM_VFLIP        : integer := 13;
   constant OAM_OBJSIZE_HI   : integer := 15;
   constant OAM_OBJSIZE_LO   : integer := 14;

   -- Atr2
   constant OAM_TILE_HI      : integer := 9;
   constant OAM_TILE_LO      : integer := 0;
   constant OAM_PRIO_HI      : integer := 11;
   constant OAM_PRIO_LO      : integer := 10;
   constant OAM_PALETTE_HI   : integer := 15;
   constant OAM_PALETTE_LO   : integer := 12;

   type t_OAMFetch is
   (
      IDLE,
      READFIRST,
      WAITFIRST,
      READSECOND,
      WAITSECOND,
      READAFFINE0,
      WAITAFFINE0,
      READAFFINE1,
      WAITAFFINE1,
      READAFFINE2,
      WAITAFFINE2,
      READAFFINE3,
      WAITAFFINE3,
      DONE
   );
   signal OAMFetch : t_OAMFetch := IDLE;

   signal output_ok : std_logic := '0';
   signal overdraw  : std_logic := '0';

   signal OAM_currentobj : integer range 0 to 127;

   -- The sprite whose OAM address is ON THE BUS. OAM reads are registered, so
   -- the data arriving this cycle belongs to whatever address went out last
   -- cycle - i.e. OAM_currentobj always trails OAM_scanptr by one.
   --
   -- Keeping the two apart is what lets a skipped sprite cost ONE cycle. The
   -- walk used to be READFIRST (present address) -> WAITFIRST (consume it) ->
   -- READFIRST, so every one of the 128 entries cost two cycles whether or not
   -- it drew anything: a dead-constant 255 cycles per line, measured, on a
   -- 2130-cycle budget. Presenting sprite N+1's address while N's data is
   -- being consumed halves that.
   --
   -- Only the first-word scan pipelines. READSECOND and the affine reads still
   -- address off OAM_currentobj, because those are reads for the sprite being
   -- processed, not the one being scanned ahead.
   signal OAM_scanptr    : integer range 0 to 127 := 0;

   signal OAM_data0 : std_logic_vector(15 downto 0) := (others => '0');
   signal OAM_data1 : std_logic_vector(15 downto 0) := (others => '0');
   signal OAM_data2 : std_logic_vector(15 downto 0) := (others => '0');

   signal OAM_data_aff0 : std_logic_vector(15 downto 0) := (others => '0');
   signal OAM_data_aff1 : std_logic_vector(15 downto 0) := (others => '0');
   signal OAM_data_aff2 : std_logic_vector(15 downto 0) := (others => '0');
   signal OAM_data_aff3 : std_logic_vector(15 downto 0) := (others => '0');

   signal OAM_sizeX     : integer range 8 to 64;
   signal OAM_sizeY     : integer range 8 to 64;
   signal OAM_sizeX2    : integer range 8 to 128;
   signal OAM_sizeY2    : integer range 8 to 128;
   signal OAM_posy      : integer range -256 to 255;
   signal OAM_posyMos   : integer range -512 to 511;
   signal OAM_isbitmap  : std_logic;

   signal OAMfetch_sizeX         : integer range 8 to 64;
   signal OAMfetch_sizeY         : integer range 8 to 64;
   signal OAMfetch_fieldX        : integer range 8 to 128;
   signal OAMfetch_fieldY        : integer range 8 to 128;
   signal OAMfetch_ty            : integer range -256 to 255;
   signal OAMfetch_sizemult      : integer range 16 to 1024;   -- bytes per sprite tile-row / bitmap row
   signal OAMfetch_x_flip_offset : integer range 3 to 7;
   signal OAMfetch_y_flip_offset : integer range 28 to 56;
   signal OAMfetch_x_div         : integer range 1 to 2;
   signal OAMfetch_x_size        : integer range 4 to 8;
   signal OAMfetch_addrbase      : integer range 0 to 262143;

   type t_PIXELGen is
   (
      WAITOAM,
      NEXTADDR,
      AFF_SUM
   );
   signal PIXELGen : t_PIXELGen := WAITOAM;

   signal Pixel_data0       : std_logic_vector(15 downto 0) := (others => '0');
   signal Pixel_data1       : std_logic_vector(15 downto 0) := (others => '0');
   signal Pixel_data2       : std_logic_vector(15 downto 0) := (others => '0');
   signal dx                : integer range -32768 to 32767;
   signal dy                : integer range -32768 to 32767;

   signal posx              : integer range -512 to 511;
   signal sizeX             : integer range 8 to 64;
   signal sizeY             : integer range 8 to 64;
   signal fieldX            : integer range 8 to 128;
   signal pixeladdr_base    : integer range 0 to 262143;
   signal pixeladdr         : integer range -262144 to 262143;
   signal is_bitmap         : std_logic := '0';

   signal sizemult          : integer range 16 to 1024;

   signal x_flip_offset     : integer range 3 to 7;
   signal x_div             : integer range 1 to 2;
   signal x_size            : integer range 4 to 8;

   signal x                 : integer range 0 to 255;
   signal realX             : integer range -8388608 to 8388607;
   signal realY             : integer range -8388608 to 8388607;
   signal target            : integer range 0 to 255;
   signal second_pix        : std_logic := '0';

   -- ==========================================================================
   -- DECOUPLED PIXEL QUEUE
   -- ==========================================================================
   -- v1 walked NEXTADDR -> (reuse | fetch -> PIXELWAIT) -> NEXTADDR one pixel
   -- at a time and STOPPED DEAD in PIXELWAIT on every fetch, so a fetched pixel
   -- cost 1 + the whole VRAM round trip. Measured 3,036 cycles on a
   -- sprite-bearing line against a 2,130 budget - the drops the owner can see.
   --
   -- The address stream is predictable, so the walk now runs AHEAD of the
   -- pixels. Each walked pixel is pushed onto a queue carrying everything the
   -- pixel pipeline needs (byte lane, screen x, half-byte select, first-of-
   -- sprite), tagged either "reuses the word before it" or "consumes the next
   -- word to come back". Fetches are issued as the walk passes them, several
   -- outstanding at once, and a drain stage pops one pixel per cycle - stalling
   -- only when the head pixel's word has not landed yet.
   --
   -- Two consequences worth naming:
   --   * the reuse compare is now on the WORD (bits 17..2), not the halfword
   --     v1 used. One fetched word serves every address sharing those bits -
   --     v1's own AFF_SUM comment says so - which halves the fetches for
   --     4bpp tile sprites.
   --   * it is guarded on walk_seen ("a word for THIS sprite is queued")
   --     rather than v1's firstpix. firstpix was cleared by the first
   --     NEXTADDR whether or not that pixel drew anything, so a sprite whose
   --     first pixels were all skipped compared against the PREVIOUS sprite's
   --     address. That was a live bug on the non-affine path; AFF_SUM already
   --     guarded against it and said why.
   constant PQ_DEPTH : integer := 8;   -- pixels queued between walk and pixels
   constant WQ_DEPTH : integer := 4;   -- VRAM words tracked in flight

   -- Everything the pixel pipeline needs to know about the SPRITE a queued
   -- pixel came from. These used to be read live off Pixel_data* at drain
   -- time, which is why a sprite's settings had to stay current until its last
   -- pixel had drained - the `pq_cnt = 0` term in settings_go. That term cost
   -- a bubble the size of the VRAM round trip once per sprite: measured 390 to
   -- 655 cycles per line on a 128-sprite line, 20-34% of the drawer's time,
   -- with the walk sitting idle for all of it.
   --
   -- Carrying them WITH the pixel is the same fix already applied to the
   -- fetched word (see drain_word): the next sprite can start walking while
   -- the previous one's pixels are still draining, because those pixels no
   -- longer depend on any live register.
   type t_pq_set is record
      prio    : std_logic_vector(1 downto 0);
      mode    : std_logic_vector(1 downto 0);
      hicolor : std_logic;
      affine  : std_logic;
      hflip   : std_logic;
      palette : std_logic_vector(3 downto 0);
      mosaic  : std_logic;
      bitmap  : std_logic;
   end record;
   constant PQ_SET_INIT : t_pq_set := ("00", "00", '0', '0', '0', "0000", '0', '0');

   type t_pq_entry is record
      newword : std_logic;                 -- consumes the next word to arrive
      lane    : unsigned(1 downto 0);      -- byte lane within that word
      target  : integer range 0 to 255;    -- screen x
      second  : std_logic;                 -- odd source pixel (4bpp nibble)
      first   : std_logic;                 -- sprite's first emitted pixel
      set     : t_pq_set;                  -- the sprite this pixel belongs to
   end record;
   constant PQ_INIT : t_pq_entry := ('0', "00", 0, '0', '0', PQ_SET_INIT);
   type t_pq is array (0 to PQ_DEPTH-1) of t_pq_entry;
   signal pq       : t_pq := (others => PQ_INIT);
   signal pq_head  : integer range 0 to PQ_DEPTH-1 := 0;
   signal pq_tail  : integer range 0 to PQ_DEPTH-1 := 0;
   signal pq_cnt   : integer range 0 to PQ_DEPTH := 0;

   type t_wq is array (0 to WQ_DEPTH-1) of std_logic_vector(31 downto 0);
   signal wq       : t_wq := (others => (others => '0'));
   signal wq_head  : integer range 0 to WQ_DEPTH-1 := 0;
   signal wq_tail  : integer range 0 to WQ_DEPTH-1 := 0;
   signal wq_cnt   : integer range 0 to WQ_DEPTH := 0;
   signal inflight : integer range 0 to WQ_DEPTH := 0;   -- asked for, not back

   signal unaccepted : std_logic := '0';   -- request presented, not yet taken
   signal walk_seen  : std_logic := '0';   -- a word for this sprite is queued
   signal last_addr  : unsigned(17 downto 0) := (others => '0');
   signal req_word   : unsigned(15 downto 0) := (others => '0');

   -- drain -> pixel pipeline, all valid the cycle after issue_pixel
   signal issue_pixel  : std_logic := '0';
   signal issue_lane   : unsigned(1 downto 0) := "00";
   signal issue_target : integer range 0 to 255 := 0;
   signal issue_second : std_logic := '0';
   -- the drained pixel's sprite settings, published with it
   signal issue_set    : t_pq_set := PQ_SET_INIT;
   -- the settings of the sprite currently being WALKED, i.e. what gets stamped
   -- into each entry as it is queued
   signal cur_set      : t_pq_set;
   -- the word this pixel reads. It must travel WITH the pixel: a single
   -- "last word fetched" register works only while the FSM stalls per fetch,
   -- and back-to-back drains would overwrite it before the pipeline read it.
   signal drain_word   : std_logic_vector(31 downto 0) := (others => '0');
   signal word_eval    : std_logic_vector(31 downto 0) := (others => '0');

   signal pixeladdr_x_aff0  : unsigned(17 downto 0);
   signal pixeladdr_x_aff1  : unsigned(17 downto 0);
   signal pixeladdr_x_aff2  : unsigned(17 downto 0);
   signal pixeladdr_x_aff3  : unsigned(17 downto 0);
   signal pixeladdr_x_aff4  : unsigned(17 downto 0);
   signal pixeladdr_x_aff5  : unsigned(17 downto 0);

   -- Pixel Pipeline
   signal consumeSettings  : std_logic := '0';
   signal PALETTE_byteaddr : std_logic_vector(8 downto 0);
   signal EXTPAL_byteaddr  : std_logic_vector(12 downto 0);

   type tpixel is record
      transparent : std_logic;
      prio        : std_logic_vector(1 downto 0);
      alpha       : std_logic;
      objwnd      : std_logic;
   end record;

   type t_pixelarray is array(0 to 255) of tpixel;
   signal pixelarray : t_pixelarray;

   signal Pixel_wait        : tpixel;
   signal Pixel_readback    : tpixel;
   signal Pixel_merge       : tpixel;

   signal target_eval       : integer range 0 to 255;
   signal target_wait       : integer range 0 to 255;
   signal target_merge      : integer range 0 to 255;

   signal enable_eval       : std_logic;
   signal enable_wait       : std_logic;
   signal enable_merge      : std_logic;

   signal second_pix_eval   : std_logic;

   signal readaddr_mux_eval : unsigned(1 downto 0);

   -- (the per-sprite *_issue registers that used to sit here are gone: those
   -- values now ride in the pixel queue as t_pq_set, see issue_set)

   signal prio_eval         : std_logic_vector(1 downto 0);
   signal mode_eval         : std_logic_vector(1 downto 0);
   signal hicolor_eval      : std_logic;
   signal affine_eval       : std_logic;
   signal hflip_eval        : std_logic;
   signal palette_eval      : std_logic_vector(3 downto 0);
   signal mosaic_eval       : std_logic;
   signal bitmap_eval       : std_logic;
   signal mosaic_wait       : std_logic;

   signal bitmap_wait       : std_logic;
   signal bitmap_merge      : std_logic;
   signal bmpalpha_wait     : std_logic_vector(3 downto 0);
   signal bmpalpha_merge    : std_logic_vector(3 downto 0);
   signal bmpcolor_wait     : std_logic_vector(15 downto 0);
   signal bmpcolor_merge    : std_logic_vector(15 downto 0);
   signal extpal_wait       : std_logic;
   signal extpal_merge      : std_logic;

   -- H-mosaic screen grid: MOSTAB0(m, x) is true where x mod (m+1) = 0
   type t_mostab is array (0 to 15, 0 to 255) of boolean;
   function init_mostab return t_mostab is
      variable t : t_mostab;
   begin
      for m in 0 to 15 loop
         for x in 0 to 255 loop
            t(m, x) := (x mod (m + 1)) = 0;
         end loop;
      end loop;
      return t;
   end function;
   constant MOSTAB0 : t_mostab := init_mostab;

   signal mos_prevx         : integer range 0 to 256 := 256;  -- last opaque x (256 = none)
   signal issue_first       : std_logic := '0';
   signal sprfirst_eval     : std_logic := '0';
   signal sprfirst_wait     : std_logic := '0';
   signal mosaik_merge      : std_logic;

   signal PALETTE_addrlow   : std_logic;
   signal EXTPAL_addrlow    : std_logic;

   -- Runaway guard, in OUR clock cycles. This is not the hardware budget -
   -- it only exists so a pathological line cannot render forever; the real
   -- limit is hwtime below.
   signal pixeltime         : integer range 0 to 8191;
   signal maxpixeltime      : integer range 0 to 8191;

   -- The hardware OBJ budget, in HARDWARE cycles (see the generic).
   signal hwtime            : integer range 0 to 2047 := 0;
   signal maxhwtime         : integer range 0 to 2047 := 1210;
   signal hw_over           : std_logic;
   signal time_up           : std_logic;
   signal settings_go       : std_logic;

begin

   hw_over <= '1' when (HW_TIME_LIMIT = '1' and hwtime >= maxhwtime) else '0';
   time_up <= '1' when (pixeltime >= maxpixeltime or hw_over = '1') else '0';

   -- The OAM walk hands a sprite to the pixel walk. BOTH sides must agree on
   -- the cycle it happens, so it is one condition, used twice.
   --
   -- v1 let the OAM side leave DONE on `PIXELGen = WAITOAM` alone, which was
   -- safe only because the pixel side took the sprite unconditionally in that
   -- same cycle. It no longer does - it also waits for the pixel queue to
   -- drain - so the two could disagree, and the OAM side would step to the
   -- next sprite while the pixel side was still waiting: the sprite in between
   -- was silently dropped. That showed up as every MULTI-sprite test case
   -- losing its later sprites.
   -- No pq_cnt term: a queued pixel carries its own sprite's settings (see
   -- t_pq_set), so the next sprite may start walking while the previous one is
   -- still draining. Waiting for the queue to empty here was costing 390-655
   -- cycles per line - 20-34% of the drawer's own time - with the walk idle
   -- throughout. The pixel pipeline stays correct across the boundary because
   -- every sprite's first pixel is tagged `first`, which the mosaic block in
   -- the merge stage already uses to restart, so no gap between sprites is
   -- required.
   settings_go <= '1' when (OAMFetch = DONE and PIXELGen = WAITOAM)
                  else '0';

   -- the settings stamped into each queue entry as the walk pushes it
   cur_set <= (prio    => Pixel_data2(OAM_PRIO_HI downto OAM_PRIO_LO),
               mode    => Pixel_data0(OAM_MODE_HI downto OAM_MODE_LO),
               hicolor => Pixel_data0(OAM_HICOLOR),
               affine  => Pixel_data0(OAM_AFFINE),
               hflip   => Pixel_data1(OAM_HFLIP),
               palette => Pixel_data2(OAM_PALETTE_HI downto OAM_PALETTE_LO),
               mosaic  => Pixel_data0(OAM_MOSAIC),
               bitmap  => is_bitmap);

   -- pq_cnt matters here: the walk reaches WAITOAM while queued pixels are
   -- still draining, and a line that reports itself done early would let the
   -- orchestrator retrigger on top of pixels still in flight
   busy <= '1' when (OAMFetch /= IDLE or PIXELGen /= WAITOAM or pq_cnt /= 0
                     or enable_eval = '1' or enable_wait = '1' or enable_merge = '1'
                     or issue_pixel = '1') else '0';

   VRAM_Drawer_addr    <= to_integer(req_word);
   PALETTE_Drawer_addr <= to_integer(unsigned(PALETTE_byteaddr(8 downto 2)));
   EXTPAL_Drawer_addr  <= to_integer(unsigned(EXTPAL_byteaddr(12 downto 2)));

   OAMRAM_Drawer_addr <= (OAM_currentobj * 2) + 1                                                when (OAMFetch = READSECOND) else
                         (to_integer(unsigned(OAM_data1(OAM_AFF_HI downto OAM_AFF_LO))) * 8) + 1 when (OAMFetch = READAFFINE0) else
                         (to_integer(unsigned(OAM_data1(OAM_AFF_HI downto OAM_AFF_LO))) * 8) + 3 when (OAMFetch = READAFFINE1) else
                         (to_integer(unsigned(OAM_data1(OAM_AFF_HI downto OAM_AFF_LO))) * 8) + 5 when (OAMFetch = READAFFINE2) else
                         (to_integer(unsigned(OAM_data1(OAM_AFF_HI downto OAM_AFF_LO))) * 8) + 7 when (OAMFetch = READAFFINE3) else
                         OAM_scanptr * 2; -- READFIRST, WAITFIRST (scanning) or IDLE

   OAM_sizeX <=  8 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "00") else -- square size 0
                16 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "01") else -- square size 1
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "10") else -- square size 2
                64 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "11") else -- square size 3
                16 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "00") else -- Hor size 0
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "01") else -- Hor size 1
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "10") else -- Hor size 2
                64 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "11") else -- Hor size 3
                 8 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "00") else -- Vert size 0
                 8 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "01") else -- Vert size 1
                16 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "10") else -- Vert size 2
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "11") else -- Vert size 3
                 8;

   OAM_sizeY <=  8 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "00") else -- square size 0
                16 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "01") else -- square size 1
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "10") else -- square size 2
                64 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "00" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "11") else -- square size 3
                 8 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "00") else -- Hor size 0
                 8 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "01") else -- Hor size 1
                16 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "10") else -- Hor size 2
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "01" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "11") else -- Hor size 3
                16 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "00") else -- Vert size 0
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "01") else -- Vert size 1
                32 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "10") else -- Vert size 2
                64 when (OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "10" and OAMRAM_Drawer_data(16 + OAM_OBJSIZE_HI downto 16 + OAM_OBJSIZE_LO) = "11") else -- Vert size 3
                 8;

   OAM_sizeX2 <= 2 * OAM_sizeX when (OAMRAM_Drawer_data(OAM_AFFINE) = '1' and OAMRAM_Drawer_data(OAM_DBLSIZE) = '1') else OAM_sizeX;
   OAM_sizeY2 <= 2 * OAM_sizeY when (OAMRAM_Drawer_data(OAM_AFFINE) = '1' and OAMRAM_Drawer_data(OAM_DBLSIZE) = '1') else OAM_sizeY;

   OAM_posy <= to_integer(unsigned(OAMRAM_Drawer_data(OAM_Y_HI downto OAM_Y_LO))) - 16#100# when (to_integer(unsigned(OAMRAM_Drawer_data(OAM_Y_HI downto OAM_Y_LO))) > (16#100# - OAM_sizeY2)) else
               to_integer(unsigned(OAMRAM_Drawer_data(OAM_Y_HI downto OAM_Y_LO)));

   OAM_posyMos <= ypos_mosaic - OAM_posy when (OAMRAM_Drawer_data(OAM_MOSAIC) = '1') else ypos - OAM_posy;

   OAM_isbitmap <= '1' when (OAMRAM_Drawer_data(OAM_MODE_HI downto OAM_MODE_LO) = "11") else '0';

   -- OAM Fetch
   process (clk)
   begin
      if rising_edge(clk) then

         -- hblankfree costs OBJ the H-Blank interval, so it gets LESS time,
         -- not more. Same direction as the runaway guard beside it, which is
         -- the donor's 954/1210 pair scaled up.
         --
         -- POLARITY IS UNVERIFIED for the NDS. GBATEK names the GBA's
         -- DISPCNT.5 "H-Blank Interval Free" (set = the CPU gets H-Blank, so
         -- OBJ loses it = 954) but the NDS's DISPCNT.23 "H-Blank OBJ
         -- Processing" (set = enable), which reads the other way round.
         -- melonDS models neither. Taking the donor's direction because this
         -- register carries the GBA's name here; if a game that sets
         -- DISPCNT.23 comes up short a few sprites, flip this first.
         if (hblankfree = '1') then
            maxpixeltime <= 6400;
            maxhwtime    <= 954;
         else
            maxpixeltime <= 8191;
            maxhwtime    <= 1210;
         end if;

         case (OAMFetch) is

            when IDLE =>
               OAM_currentobj     <= 0;
               OAM_scanptr        <= 0;
               if (drawline = '1') then
                  OAMFetch           <= WAITFIRST;
                  -- sprite 0's address went out during IDLE, so the scan is
                  -- already one ahead when WAITFIRST consumes it
                  OAM_scanptr        <= 1;
                  output_ok          <= '1';
                  overdraw           <= '0';
               end if;

            when READFIRST =>
               -- re-priming after a sprite that actually drew: this cycle puts
               -- OAM_currentobj's address out (scanptr was set to it), and the
               -- scan runs one ahead again from here
               OAMFetch           <= WAITFIRST;
               if (OAM_scanptr < 127) then
                  OAM_scanptr     <= OAM_scanptr + 1;
               end if;

            when WAITFIRST =>
               OAM_data0 <= OAMRAM_Drawer_data(15 downto 0);
               OAM_data1 <= OAMRAM_Drawer_data(31 downto 16);
               OAMFetch  <= READSECOND;

               OAMfetch_sizeX    <= OAM_sizeX;
               OAMfetch_sizeY    <= OAM_sizeY;
               OAMfetch_fieldX   <= OAM_sizeX2;
               OAMfetch_fieldY   <= OAM_sizeY2;

               if (OAM_isbitmap = '1') then
                  if (bitmap_1d = '1') then
                     OAMfetch_sizemult <= OAM_sizeX * 2;          -- bytes per bitmap row
                  elsif (bitmap_2d_wide = '1') then
                     OAMfetch_sizemult <= 512;
                  else
                     OAMfetch_sizemult <= 256;
                  end if;
               elsif (OAMRAM_Drawer_data(OAM_HICOLOR) = '0') then
                  OAMfetch_sizemult <= OAM_sizeX * 4;
               else
                  OAMfetch_sizemult <= OAM_sizeX * 8;
               end if;

               if (OAMRAM_Drawer_data(OAM_HICOLOR) = '0') then
                  OAMfetch_x_flip_offset <= 3;
                  OAMfetch_y_flip_offset <= 28;
                  OAMfetch_x_div         <= 2;
                  OAMfetch_x_size        <= 4;
               else
                  OAMfetch_x_flip_offset <= 7;
                  OAMfetch_y_flip_offset <= 56;
                  OAMfetch_x_div         <= 1;
                  OAMfetch_x_size        <= 8;
               end if;

               -- skip: off-line, disabled, prohibited shape, bitmap sprites
               -- with alpha=0 or the reserved 1D+wide combination
               if (OAM_posyMos < 0 or OAM_posyMos >= OAM_sizeY2
                   or OAMRAM_Drawer_data(OAM_OFF_HI downto OAM_OFF_LO) = "10"
                   or OAMRAM_Drawer_data(OAM_OBJSHAPE_HI downto OAM_OBJSHAPE_LO) = "11"
                   or (OAM_isbitmap = '1' and bitmap_1d = '1' and bitmap_2d_wide = '1')) then
                  if (OAM_currentobj = 127) then
                     OAMFetch      <= IDLE;
                  else
                     -- STAY here: the next sprite's address is already on the
                     -- bus, so its data lands next cycle and a skipped entry
                     -- costs one cycle instead of two. currentobj follows the
                     -- scan pointer, which is exactly the sprite that data
                     -- will belong to.
                     OAMFetch       <= WAITFIRST;
                     OAM_currentobj <= OAM_scanptr;
                     if (OAM_scanptr < 127) then
                        OAM_scanptr <= OAM_scanptr + 1;
                     end if;
                  end if;
               else
                  OAMFetch    <= READSECOND;
                  OAMfetch_ty <= OAM_posyMos;
               end if;

            when READSECOND =>
               OAMFetch <= WAITSECOND;

            when WAITSECOND =>
               OAM_data2 <= OAMRAM_Drawer_data(15 downto 0);
               if (OAM_data0(OAM_MODE_HI downto OAM_MODE_LO) = "11"
                   and OAMRAM_Drawer_data(OAM_PALETTE_HI downto OAM_PALETTE_LO) = "0000") then
                  -- bitmap sprite with alpha=0: invisible
                  if (OAM_currentobj = 127) then
                     OAMFetch      <= IDLE;
                  else
                     -- the scan-ahead was thrown away by the second-word read,
                     -- so re-prime it through READFIRST
                     OAMFetch       <= READFIRST;
                     OAM_currentobj <= OAM_currentobj + 1;
                     OAM_scanptr    <= OAM_currentobj + 1;
                  end if;
               elsif (OAM_data0(OAM_AFFINE) = '1') then
                  OAMFetch           <= READAFFINE0;
               else
                  OAMFetch           <= DONE;
               end if;

               -- char/bitmap base address (byte, in the 256 KB OBJ space)
               if (OAM_data0(OAM_MODE_HI downto OAM_MODE_LO) = "11") then
                  if (bitmap_1d = '1') then
                     if (bitmap_1d_boundary = '1') then
                        OAMfetch_addrbase <= 256 * to_integer(unsigned(OAMRAM_Drawer_data(OAM_TILE_HI downto OAM_TILE_LO)));
                     else
                        OAMfetch_addrbase <= 128 * to_integer(unsigned(OAMRAM_Drawer_data(OAM_TILE_HI downto OAM_TILE_LO)));
                     end if;
                  elsif (bitmap_2d_wide = '1') then
                     OAMfetch_addrbase <= 16 * to_integer(unsigned(OAMRAM_Drawer_data(OAM_TILE_LO + 4 downto OAM_TILE_LO)))
                                        + 128 * (to_integer(unsigned(OAMRAM_Drawer_data(OAM_TILE_HI downto OAM_TILE_LO + 5))) * 32);
                  else
                     OAMfetch_addrbase <= 16 * to_integer(unsigned(OAMRAM_Drawer_data(OAM_TILE_LO + 3 downto OAM_TILE_LO)))
                                        + 128 * (to_integer(unsigned(OAMRAM_Drawer_data(OAM_TILE_HI downto OAM_TILE_LO + 4))) * 16);
                  end if;
               elsif (one_dim_mapping = '1') then
                  OAMfetch_addrbase <= (32 * (2 ** to_integer(tile_boundary))) * to_integer(unsigned(OAMRAM_Drawer_data(OAM_TILE_HI downto OAM_TILE_LO)));
               else
                  OAMfetch_addrbase <= 32 * to_integer(unsigned(OAMRAM_Drawer_data(OAM_TILE_HI downto OAM_TILE_LO)));
               end if;

            when READAFFINE0 => OAMFetch <= WAITAFFINE0;
            when WAITAFFINE0 => OAMFetch <= READAFFINE1; OAM_data_aff0 <= OAMRAM_Drawer_data(31 downto 16);
            when READAFFINE1 => OAMFetch <= WAITAFFINE1;
            when WAITAFFINE1 => OAMFetch <= READAFFINE2; OAM_data_aff1 <= OAMRAM_Drawer_data(31 downto 16);
            when READAFFINE2 => OAMFetch <= WAITAFFINE2;
            when WAITAFFINE2 => OAMFetch <= READAFFINE3; OAM_data_aff2 <= OAMRAM_Drawer_data(31 downto 16);
            when READAFFINE3 => OAMFetch <= WAITAFFINE3;
            when WAITAFFINE3 => OAMFetch <= DONE;        OAM_data_aff3 <= OAMRAM_Drawer_data(31 downto 16);

            when DONE =>
               if (settings_go = '1' or consumeSettings = '1') then
                  if (OAM_currentobj = 127) then
                     OAMFetch      <= IDLE;
                  else
                     OAMFetch           <= READFIRST;
                     OAM_currentobj     <= OAM_currentobj + 1;
                     -- READFIRST re-presents this sprite's address; the scan
                     -- runs ahead again from there
                     OAM_scanptr        <= OAM_currentobj + 1;
                  end if;
               end if;

         end case;

         if (time_up = '1' and OAMFetch /= IDLE) then
            OAMFetch <= IDLE;
            overdraw <= '1';
         end if;

      end if;
   end process;

   -- Pixelgen
   process (clk)
      variable applyNextSettings : std_logic := '0';
      variable pixeladdr_pre_a0  : integer range -8388608 to 8388607; -- 24 bit
      variable pixeladdr_pre_a1  : integer range -8388608 to 8388607;
      variable pixeladdr_pre_a2  : integer range -8388608 to 8388607;
      variable pixeladdr_pre_a3  : integer range -8388608 to 8388607;
      variable pixeladdr_pre_a4  : integer range -8388608 to 8388607;
      variable pixeladdr_pre_a5  : integer range -8388608 to 8388607;
      variable pixeladdr_pre_a6  : integer range -8388608 to 8388607;
      variable pixeladdr_pre_a7  : integer range -8388608 to 8388607;
      variable pixeladdr_pre_0   : integer range -262144 to 262143;
      variable pixeladdr_pre_1   : integer range -262144 to 262143;
      variable pixeladdr_pre_2   : integer range -262144 to 262143;
      variable pixeladdr_pre_3   : integer range -262144 to 262143;
      variable pixeladdr_pre_4   : integer range -262144 to 262143;
      variable pixeladdr_pre_5   : integer range -262144 to 262143;
      variable pixeladdr_pre_6   : integer range -262144 to 262143;
      variable pixeladdr_pre_7   : integer range -262144 to 262143;
      variable xxx               : integer range 0 to 63;
      variable yyy               : integer range 0 to 63;
      variable pixeladdr_calc    : integer;
      variable skip_var          : std_logic;
      variable v_hw              : integer range 0 to 2047;
      -- AFF_SUM needs the summed address as a value before it can decide whether
      -- to fetch it, so it can no longer assign straight into an address signal
      variable v_affaddr         : integer range 0 to 262143;
      -- queue state, taken into variables so a word can arrive and be consumed
      -- in the same cycle (the text drawer's v_tq pattern)
      variable v_pq    : t_pq;
      variable v_pcnt  : integer range 0 to PQ_DEPTH;
      variable v_phead : integer range 0 to PQ_DEPTH-1;
      variable v_ptail : integer range 0 to PQ_DEPTH-1;
      variable v_wq    : t_wq;
      variable v_wcnt  : integer range 0 to WQ_DEPTH;
      variable v_whead : integer range 0 to WQ_DEPTH-1;
      variable v_wtail : integer range 0 to WQ_DEPTH-1;
      variable v_infl  : integer range 0 to WQ_DEPTH;
      variable v_una   : std_logic;
      variable v_addr  : unsigned(17 downto 0);
      variable v_reuse : boolean;
      variable ent     : t_pq_entry;
      variable v_second : std_logic;
   begin
      if rising_edge(clk) then

         consumeSettings   <= '0';
         issue_pixel       <= '0';
         VRAM_Drawer_req   <= '0';
         applyNextSettings := '0';

         v_pq    := pq;
         v_pcnt  := pq_cnt;
         v_phead := pq_head;
         v_ptail := pq_tail;
         v_wq    := wq;
         v_wcnt  := wq_cnt;
         v_whead := wq_head;
         v_wtail := wq_tail;
         v_infl  := inflight;
         v_una   := unaccepted;

         if (VRAM_Drawer_accept = '1') then
            v_una := '0';
         end if;

         -- a fetched word lands, in issue order
         if (VRAM_Drawer_done = '1') then
            v_wq(v_wtail) := VRAM_Drawer_data;
            v_wtail := (v_wtail + 1) mod WQ_DEPTH;
            v_wcnt  := v_wcnt + 1;
            v_infl  := v_infl - 1;
         end if;

         v_hw := hwtime;

         if (drawline = '1') then
            pixeltime <= 0;
            v_hw      := 0;
         elsif (pixeltime < maxpixeltime) then
            pixeltime <= pixeltime + 1;
         end if;

         case (PIXELGen) is

            when WAITOAM =>
               -- The next sprite's settings may only be latched once the queue
               -- has drained: the pixel pipeline captures the LIVE Pixel_data*
               -- one cycle after each drain, so a sprite has to stay current
               -- until its last queued pixel has been issued.
               if (settings_go = '1') then
                  PIXELGen          <= NEXTADDR;
                  applyNextSettings := '1';
               end if;

            when NEXTADDR =>
               skip_var  := '0';
               v_second  := '0';
               if ((x + posX) < 256 and (x + posX) >= 0) then
                  target    <= x + posX;
               else
                  skip_var := '1';
               end if;

               pixeladdr_calc := pixeladdr;

               if (Pixel_data0(OAM_AFFINE) = '1') then
                  if (realX < 0 or (realX / 256) >= sizeX or realY < 0 or (realY / 256) >= sizeY) then
                     skip_var := '1';
                  end if;

                  -- synthesis translate_off
                  if (realX >= 0 and (realX / 256) < sizeX and realY >= 0 and (realY / 256) < sizeY) then
                  -- synthesis translate_on

                     xxx := realX / 256;
                     yyy := realY / 256;
                     if (xxx mod 2 = 1) then v_second := '1'; else v_second := '0'; end if;

                     if (is_bitmap = '1') then
                        -- bitmap: base + yyy*rowstride + xxx*2
                        pixeladdr_x_aff0 <= to_unsigned(yyy * sizemult, 18);
                        pixeladdr_x_aff1 <= (others => '0');
                        pixeladdr_x_aff2 <= to_unsigned(yyy * sizemult, 18);
                        pixeladdr_x_aff3 <= (others => '0');
                        pixeladdr_x_aff4 <= to_unsigned(xxx * 2, 18);
                        pixeladdr_x_aff5 <= (others => '0');
                     else
                        pixeladdr_x_aff0 <= to_unsigned(((yyy mod 8) * x_size), 18);
                        pixeladdr_x_aff1 <= to_unsigned(((yyy / 8) * sizemult), 18);

                        pixeladdr_x_aff2 <= to_unsigned(((yyy mod 8) * x_size), 18);
                        pixeladdr_x_aff3 <= to_unsigned(((yyy / 8) * 1024), 18);

                        pixeladdr_x_aff4 <= to_unsigned(((xxx mod 8) / x_div), 18);
                        if (Pixel_data0(OAM_HICOLOR) = '0') then
                           pixeladdr_x_aff5 <= to_unsigned(((xxx / 8) * 32), 18);
                        else
                           pixeladdr_x_aff5 <= to_unsigned(((xxx / 8) * 64), 18);
                        end if;
                     end if;

                  -- synthesis translate_off
                  end if;
                  -- synthesis translate_on
               else

                  if (x mod 2 = 1) then v_second := '1'; else v_second := '0'; end if;

                  if (is_bitmap = '1') then
                     -- bitmap row base is in pixeladdr; hflip mirrors x
                     if (Pixel_data1(OAM_HFLIP) = '1') then
                        pixeladdr_calc := pixeladdr_calc + (sizeX - 1 - x) * 2;
                     else
                        pixeladdr_calc := pixeladdr_calc + x * 2;
                     end if;
                  elsif (Pixel_data1(OAM_HFLIP) = '1') then
                     pixeladdr_calc := pixeladdr_calc + (x_flip_offset - ((x mod 8) / x_div));
                     if (Pixel_data0(OAM_HICOLOR) = '0') then
                        pixeladdr_calc := pixeladdr_calc - (((x / 8) - ((sizeX / 8) - 1)) * 32);
                     else
                        pixeladdr_calc := pixeladdr_calc - (((x / 8) - ((sizeX / 8) - 1)) * 64);
                     end if;
                  else
                     pixeladdr_calc := pixeladdr_calc + ((x mod 8) / x_div);
                     if (Pixel_data0(OAM_HICOLOR) = '0') then
                        pixeladdr_calc := pixeladdr_calc + ((x / 8) * 32);
                     else
                        pixeladdr_calc := pixeladdr_calc + ((x / 8) * 64);
                     end if;
                  end if;

               end if;

               second_pix <= v_second;

               -- hardware charges one cycle per field pixel walked, two for a
               -- rot/scal sprite. Skipped (off-screen) pixels are charged too:
               -- the cost is the sprite's field width, not how much of it
               -- landed on the screen. Charged where x advances, so a walk
               -- stalled for queue room is not charged twice.
               if (time_up = '1') then
                  PIXELGen <= WAITOAM;
               elsif (x >= fieldX) then
                  PIXELGen <= WAITOAM;
               elsif (skip_var = '1') then
                  -- nothing to fetch or draw; last_addr keeps the last queued
                  -- word so the reuse compare stays truthful
                  realX <= realX + dx;
                  realY <= realY + dy;
                  x     <= x + 1;
                  if (v_hw <= 2046) then v_hw := v_hw + 1; end if;
                  PIXELGen <= NEXTADDR;
               elsif (Pixel_data0(OAM_AFFINE) = '1') then
                  -- the summed address is one cycle away; AFF_SUM queues it
                  realX <= realX + dx;
                  realY <= realY + dy;
                  x     <= x + 1;
                  if (v_hw <= 2045) then v_hw := v_hw + 2; end if;
                  PIXELGen <= AFF_SUM;
               else
                  v_addr  := to_unsigned(pixeladdr_calc mod 262144, 18);
                  v_reuse := (walk_seen = '1') and
                             (v_addr(17 downto 2) = last_addr(17 downto 2));

                  -- room to queue the pixel, and - if it needs a word of its
                  -- own - a free slot to land it in and a channel ready to
                  -- take the request
                  if (v_pcnt < PQ_DEPTH and
                      (v_reuse or (v_wcnt + v_infl < WQ_DEPTH and v_una = '0'))) then
                     ent := ('0', v_addr(1 downto 0), x + posX, v_second,
                             not walk_seen, cur_set);
                     if (not v_reuse) then
                        ent.newword     := '1';
                        req_word        <= v_addr(17 downto 2);
                        VRAM_Drawer_req <= '1';
                        v_una           := '1';
                        v_infl          := v_infl + 1;
                        last_addr       <= v_addr;
                        walk_seen       <= '1';
                     end if;
                     v_pq(v_ptail) := ent;
                     v_ptail := (v_ptail + 1) mod PQ_DEPTH;
                     v_pcnt  := v_pcnt + 1;

                     realX <= realX + dx;
                     realY <= realY + dy;
                     x     <= x + 1;
                     if (v_hw <= 2046) then v_hw := v_hw + 1; end if;
                  end if;
                  -- no room: hold x, realX/realY and the state, and retry
                  PIXELGen <= NEXTADDR;
               end if;

            when AFF_SUM =>
               if (is_bitmap = '1') then
                  v_affaddr := (pixeladdr_base
                                 + to_integer(pixeladdr_x_aff0)
                                 + to_integer(pixeladdr_x_aff4)) mod 262144;
               elsif (one_dim_mapping = '1') then
                  v_affaddr := (pixeladdr_base
                                 + to_integer(pixeladdr_x_aff0) + to_integer(pixeladdr_x_aff1)
                                 + to_integer(pixeladdr_x_aff4) + to_integer(pixeladdr_x_aff5)) mod 262144;
               else
                  v_affaddr := (pixeladdr_base
                                 + to_integer(pixeladdr_x_aff2) + to_integer(pixeladdr_x_aff3)
                                 + to_integer(pixeladdr_x_aff4) + to_integer(pixeladdr_x_aff5)) mod 262144;
               end if;
               -- Word reuse, same rule as the non-affine path: one fetched word
               -- serves every address sharing bits 17..2, because the lane is
               -- bits 1..0. Rotation just makes consecutive pixels land in
               -- different words, and then this falls back to fetching exactly
               -- as before - never wrong, only less effective.
               v_addr  := to_unsigned(v_affaddr, 18);
               v_reuse := (walk_seen = '1') and
                          (v_addr(17 downto 2) = last_addr(17 downto 2));

               if (v_pcnt < PQ_DEPTH and
                   (v_reuse or (v_wcnt + v_infl < WQ_DEPTH and v_una = '0'))) then
                  ent := ('0', v_addr(1 downto 0), target, second_pix,
                          not walk_seen, cur_set);
                  if (not v_reuse) then
                     ent.newword     := '1';
                     req_word        <= v_addr(17 downto 2);
                     VRAM_Drawer_req <= '1';
                     v_una           := '1';
                     v_infl          := v_infl + 1;
                     last_addr       <= v_addr;
                     walk_seen       <= '1';
                  end if;
                  v_pq(v_ptail) := ent;
                  v_ptail := (v_ptail + 1) mod PQ_DEPTH;
                  v_pcnt  := v_pcnt + 1;
                  PIXELGen <= NEXTADDR;
               end if;

         end case;

         -- ------------------------------------------------------------------
         -- DRAIN: one queued pixel per cycle into the pixel pipeline. A pixel
         -- tagged newword waits for its word; a reuse pixel goes immediately,
         -- because drain_word still holds the word it shares.
         -- ------------------------------------------------------------------
         if (v_pcnt > 0) then
            ent := v_pq(v_phead);
            if (ent.newword = '0' or v_wcnt > 0) then
               if (ent.newword = '1') then
                  drain_word <= v_wq(v_whead);
                  v_whead := (v_whead + 1) mod WQ_DEPTH;
                  v_wcnt  := v_wcnt - 1;
               end if;
               issue_pixel  <= '1';
               issue_first  <= ent.first;
               issue_lane   <= ent.lane;
               issue_target <= ent.target;
               issue_second <= ent.second;
               issue_set    <= ent.set;
               v_phead := (v_phead + 1) mod PQ_DEPTH;
               v_pcnt  := v_pcnt - 1;
            end if;
         end if;

         if (applyNextSettings = '1') then
            consumeSettings <= '1';

            -- rot/scal setup: 10 hardware cycles before the first pixel
            if (OAM_data0(OAM_AFFINE) = '1' and v_hw <= 2037) then
               v_hw := v_hw + 10;
            end if;

            x          <= 0;
            walk_seen  <= '0';

            Pixel_data0     <= OAM_data0;
            Pixel_data1     <= OAM_data1;
            Pixel_data2     <= OAM_data2;
            dx              <= to_integer(signed(OAM_data_aff0));
            dy              <= to_integer(signed(OAM_data_aff2));

            -- if/else, not a conditional assignment: Quartus 17's VHDL-2008
            -- subset rejects those in sequential code
            if (OAM_data0(OAM_MODE_HI downto OAM_MODE_LO) = "11") then
               is_bitmap <= '1';
            else
               is_bitmap <= '0';
            end if;

            if (unsigned(OAM_data1(OAM_X_HI downto OAM_X_LO)) > 16#100#) then
               posx <= to_integer(unsigned(OAM_data1(OAM_X_HI downto OAM_X_LO))) - 16#200#;
            else
               posx <= to_integer(unsigned(OAM_data1(OAM_X_HI downto OAM_X_LO)));
            end if;

            sizeX  <= OAMfetch_sizeX;
            sizeY  <= OAMfetch_sizeY;
            fieldX <= OAMfetch_fieldX;

            sizemult      <= OAMfetch_sizemult;
            x_flip_offset <= OAMfetch_x_flip_offset;
            x_div         <= OAMfetch_x_div;
            x_size        <= OAMfetch_x_size;

            pixeladdr_base <= OAMfetch_addrbase;

            -- affine
            pixeladdr_pre_a0 := OAMfetch_sizeX * 128;
            pixeladdr_pre_a1 := (OAMfetch_fieldX / 2) * to_integer(signed(OAM_data_aff0));
            pixeladdr_pre_a2 := (OAMfetch_fieldY / 2) * to_integer(signed(OAM_data_aff1));
            pixeladdr_pre_a3 := OAMfetch_ty * to_integer(signed(OAM_data_aff1));
            pixeladdr_pre_a4 := OAMfetch_sizeY * 128;
            pixeladdr_pre_a5 := (OAMfetch_fieldX / 2) * to_integer(signed(OAM_data_aff2));
            pixeladdr_pre_a6 := (OAMfetch_fieldY / 2) * to_integer(signed(OAM_data_aff3));
            pixeladdr_pre_a7 := OAMfetch_ty * to_integer(signed(OAM_data_aff3));

            -- non affine, tile sprites
            pixeladdr_pre_0 := (OAMfetch_y_flip_offset - (OAMfetch_ty mod 8) * OAMfetch_x_size);
            pixeladdr_pre_1 := ((((OAMfetch_sizeY / 8) - 1) - (OAMfetch_ty / 8)) * OAMfetch_sizemult);
            pixeladdr_pre_2 := (OAMfetch_y_flip_offset - (OAMfetch_ty mod 8) * OAMfetch_x_size);
            pixeladdr_pre_3 := ((((OAMfetch_sizeY / 8) - 1) - (OAMfetch_ty / 8)) * 1024);
            pixeladdr_pre_4 := ((OAMfetch_ty mod 8) * OAMfetch_x_size);
            pixeladdr_pre_5 := ((OAMfetch_ty / 8) * OAMfetch_sizemult);
            pixeladdr_pre_6 := ((OAMfetch_ty mod 8) * OAMfetch_x_size);
            pixeladdr_pre_7 := ((OAMfetch_ty / 8) * 1024);

            -- affine
            realX <= (pixeladdr_pre_a0 - pixeladdr_pre_a1 - pixeladdr_pre_a2 + pixeladdr_pre_a3);
            realY <= (pixeladdr_pre_a4 - pixeladdr_pre_a5 - pixeladdr_pre_a6 + pixeladdr_pre_a7);

            -- non affine
            if (OAM_data0(OAM_MODE_HI downto OAM_MODE_LO) = "11") then
               -- bitmap row base (vflip mirrors the row)
               if (OAM_data1(OAM_VFLIP) = '1') then
                  pixeladdr <= OAMfetch_addrbase + (OAMfetch_sizeY - 1 - OAMfetch_ty) * OAMfetch_sizemult;
               else
                  pixeladdr <= OAMfetch_addrbase + OAMfetch_ty * OAMfetch_sizemult;
               end if;
            elsif (OAM_data1(OAM_VFLIP) = '1') then
               if (one_dim_mapping = '1') then
                  pixeladdr <= OAMfetch_addrbase + pixeladdr_pre_0 + pixeladdr_pre_1;
               else
                  pixeladdr <= OAMfetch_addrbase + pixeladdr_pre_2 + pixeladdr_pre_3;
               end if;
            else
               if (one_dim_mapping = '1') then
                  pixeladdr <= OAMfetch_addrbase + pixeladdr_pre_4 + pixeladdr_pre_5;
               else
                  pixeladdr <= OAMfetch_addrbase + pixeladdr_pre_6 + pixeladdr_pre_7;
               end if;
            end if;
         end if;

         hwtime <= v_hw;

         pq         <= v_pq;
         pq_head    <= v_phead;
         pq_tail    <= v_ptail;
         pq_cnt     <= v_pcnt;
         wq         <= v_wq;
         wq_head    <= v_whead;
         wq_tail    <= v_wtail;
         wq_cnt     <= v_wcnt;
         inflight   <= v_infl;
         unaccepted <= v_una;

      end if;
   end process;

   -- Pixel Pipeline
   process (clk)
      variable colorbyte             : std_logic_vector(7 downto 0);
      variable colorword             : std_logic_vector(15 downto 0);
      variable colordata             : std_logic_vector(3 downto 0);
      variable VRAM_Drawer_dataMuxed : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk) then

         if (drawline = '1') then
            pixelarray <= (others => ('1', "11", '0', '0'));
         end if;

         -- first cycle - take everything the drain published with the pixel.
         -- The WORD travels here too: it can no longer be read out of a single
         -- "last fetched" register, because the drain may publish the next
         -- pixel's word before this one has been consumed.
         enable_eval       <= issue_pixel;
         sprfirst_eval     <= issue_first;
         readaddr_mux_eval <= issue_lane;
         target_eval       <= issue_target;
         second_pix_eval   <= issue_second;
         word_eval         <= drain_word;

         -- ...including which sprite it came from. Reading these off the live
         -- Pixel_data* registers was what forced the drain to finish before
         -- the next sprite could be latched.
         prio_eval       <= issue_set.prio;
         mode_eval       <= issue_set.mode;
         hicolor_eval    <= issue_set.hicolor;
         affine_eval     <= issue_set.affine;
         hflip_eval      <= issue_set.hflip;
         palette_eval    <= issue_set.palette;
         mosaic_eval     <= issue_set.mosaic;
         bitmap_eval     <= issue_set.bitmap;

         -- second cycle - eval vram
         target_wait   <= target_eval;
         enable_wait   <= enable_eval;
         sprfirst_wait <= sprfirst_eval;
         mosaic_wait   <= mosaic_eval;
         bitmap_wait   <= bitmap_eval;
         bmpalpha_wait <= palette_eval;
         extpal_wait   <= hicolor_eval and obj_extpal;

         Pixel_wait.prio        <= prio_eval;
         if (mode_eval = "01") then Pixel_wait.alpha  <= '1'; else Pixel_wait.alpha  <= '0'; end if;
         if (mode_eval = "10") then Pixel_wait.objwnd <= '1'; else Pixel_wait.objwnd <= '0'; end if;

         VRAM_Drawer_dataMuxed := word_eval;

         case (readaddr_mux_eval(1 downto 0)) is
            when "00" => colorbyte := VRAM_Drawer_dataMuxed(7  downto 0);
            when "01" => colorbyte := VRAM_Drawer_dataMuxed(15 downto 8);
            when "10" => colorbyte := VRAM_Drawer_dataMuxed(23 downto 16);
            when "11" => colorbyte := VRAM_Drawer_dataMuxed(31 downto 24);
            when others => null;
         end case;

         if (readaddr_mux_eval(1) = '1') then
            colorword := VRAM_Drawer_dataMuxed(31 downto 16);
         else
            colorword := VRAM_Drawer_dataMuxed(15 downto 0);
         end if;

         if (enable_eval = '1') then
            if (bitmap_eval = '1') then
               bmpcolor_wait <= colorword;
               Pixel_wait.transparent <= not colorword(15);
            elsif (hicolor_eval = '0') then
               if (affine_eval = '1') then
                  if (second_pix_eval = '1') then
                     colordata := colorbyte(7 downto 4);
                  else
                     colordata := colorbyte(3 downto 0);
                  end if;
               else
                  if ((hflip_eval = '1' and second_pix_eval = '0') or (hflip_eval = '0' and second_pix_eval = '1')) then
                     colordata := colorbyte(7 downto 4);
                  else
                     colordata := colorbyte(3 downto 0);
                  end if;
               end if;

               if (colordata = x"0") then Pixel_wait.transparent <= '1'; else Pixel_wait.transparent <= '0'; end if;

               PALETTE_byteaddr <= palette_eval & colordata & '0';

            else

               if (colorbyte = x"00") then Pixel_wait.transparent <= '1'; else Pixel_wait.transparent <= '0'; end if;

               PALETTE_byteaddr <= colorbyte & '0';
               EXTPAL_byteaddr  <= palette_eval & colorbyte & '0';

            end if;
         end if;

         -- third cycle - wait palette + mosaic
         enable_merge    <= enable_wait;
         target_merge    <= target_wait;
         Pixel_readback  <= pixelarray(target_wait);
         PALETTE_addrlow <= PALETTE_byteaddr(1);
         EXTPAL_addrlow  <= EXTPAL_byteaddr(1);
         bitmap_merge    <= bitmap_wait;
         bmpalpha_merge  <= bmpalpha_wait;
         bmpcolor_merge  <= bmpcolor_wait;
         extpal_merge    <= extpal_wait;

         mosaik_merge <= '0';
         if (drawline = '1') then
            mos_prevx <= 256;
         end if;
         if (enable_wait = '1') then
            -- repeat needs: mosaic sprite, opaque pixel, not the sprite's
            -- first emitted pixel, not on the screen-aligned grid restart,
            -- and the previous screen pixel opaque from this sprite
            -- (melonDS objIndex continuity - a transparency hole stays a
            -- hole, restarts the block, and still claims settings like any
            -- transparent pixel)
            if (mosaic_wait = '1' and sprfirst_wait = '0' and
                Pixel_wait.transparent = '0' and
                mos_prevx = target_wait - 1 and
                not MOSTAB0(to_integer(Mosaic_H_Size), target_wait)) then
               mosaik_merge <= '1';      -- repeat the last fresh pixel
               mos_prevx    <= target_wait;
            else
               Pixel_merge <= Pixel_wait;
               if (Pixel_wait.transparent = '0') then
                  mos_prevx <= target_wait;
               else
                  mos_prevx <= 256;
               end if;
            end if;
         end if;

         -- fourth cycle
         pixel_we_color    <= '0';
         pixel_we_settings <= '0';
         pixel_objwnd      <= '0';
         pixel_x           <= target_merge;

         if (enable_merge = '1' and mosaik_merge = '0') then
            if (bitmap_merge = '1') then
               pixeldata_color <= '0' & bmpcolor_merge(14 downto 0);
            elsif (extpal_merge = '1') then
               if (EXTPAL_addrlow = '1') then
                  pixeldata_color <= '0' & EXTPAL_Drawer_data(30 downto 16);
               else
                  pixeldata_color <= '0' & EXTPAL_Drawer_data(14 downto 0);
               end if;
            elsif (PALETTE_addrlow = '1') then
               pixeldata_color <= '0' & PALETTE_Drawer_data(30 downto 16);
            else
               pixeldata_color <= '0' & PALETTE_Drawer_data(14 downto 0);
            end if;
            if (bitmap_merge = '1') then
               pixeldata_settings <= bmpalpha_merge & '1' & Pixel_merge.alpha & Pixel_merge.prio;
            else
               pixeldata_settings <= "0000" & '0' & Pixel_merge.alpha & Pixel_merge.prio;
            end if;
         end if;

         if (enable_merge = '1' and output_ok = '1') then

            if (Pixel_merge.transparent = '0' and Pixel_merge.objwnd = '1') then
               pixel_objwnd <= '1';
            end if;

            if (Pixel_merge.objwnd = '0') then
               if (Pixel_readback.transparent = '1' or unsigned(Pixel_merge.prio) < unsigned(Pixel_readback.prio)) then
                  pixel_we_settings             <= '1';
                  pixelarray(target_merge).prio <= Pixel_merge.prio;
                  if (Pixel_merge.transparent = '0') then
                     pixel_we_color                       <= '1';
                     pixelarray(target_merge).transparent <= '0';
                  end if;
               end if;
            end if;

         end if;

      end if;
   end process;

   -- synthesis translate_off
   -- ==========================================================================
   -- PER-LINE PHASE BREAKDOWN (simulation only)
   -- ==========================================================================
   -- The frame profile reports one number, "obj=2000 of a 2130 budget", which
   -- says the drawer is over but not WHERE. This splits the drawer's own busy
   -- time into the four things it can be doing, so the next optimisation is
   -- aimed by measurement rather than by inspection of the state machine.
   --
   --   fetch     - the OAM state machine is reading OAM (overlaps walk)
   --   walk      - the pixel walk is producing addresses (the useful work)
   --   drainwait - walk finished, waiting for the queue to empty before the
   --               next sprite's settings may be applied (settings_go's
   --               pq_cnt = 0 term). This is the per-sprite bubble.
   --   oamwait   - walk idle with an empty queue, waiting for OAM to deliver
   --               the next sprite
   --
   -- fetch overlaps walk by design, so the four do not sum to total.
   p_objprof : process (clk)
      variable c_fetch : integer := 0;
      variable c_walk  : integer := 0;
      variable c_drain : integer := 0;
      variable c_oam   : integer := 0;
      variable n_spr   : integer := 0;
      variable n_aff   : integer := 0;
      variable tot     : integer := 0;
      variable y_line  : integer := 0;
      variable started : boolean := false;
   begin
      if rising_edge(clk) then

         if (drawline = '1') then
            if (started and y_line < 8) then
               report "OBJPROF y=" & integer'image(y_line) &
                      " total=" & integer'image(tot) &
                      " fetch=" & integer'image(c_fetch) &
                      " walk=" & integer'image(c_walk) &
                      " drainwait=" & integer'image(c_drain) &
                      " oamwait=" & integer'image(c_oam) &
                      " sprites=" & integer'image(n_spr) &
                      " affine=" & integer'image(n_aff);
            end if;
            c_fetch := 0; c_walk := 0; c_drain := 0; c_oam := 0;
            n_spr   := 0; n_aff  := 0; tot     := 0;
            y_line  := ypos;
            started := true;
         end if;

         if (OAMFetch /= IDLE or PIXELGen /= WAITOAM or pq_cnt /= 0) then
            tot := tot + 1;
         end if;

         if (PIXELGen = NEXTADDR or PIXELGen = AFF_SUM) then
            c_walk := c_walk + 1;
         elsif (PIXELGen = WAITOAM) then
            if (pq_cnt /= 0) then
               c_drain := c_drain + 1;
            elsif (OAMFetch /= IDLE and OAMFetch /= DONE) then
               c_oam := c_oam + 1;
            end if;
         end if;

         -- one cycle each, so these count sprites, not cycles
         if (OAMFetch = READSECOND)  then n_spr := n_spr + 1; end if;
         if (OAMFetch = READAFFINE0) then n_aff := n_aff + 1; end if;

         if (OAMFetch /= IDLE and OAMFetch /= DONE) then
            c_fetch := c_fetch + 1;
         end if;

      end if;
   end process;
   -- synthesis translate_on

end architecture;
