
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nds_drawer_affext is
   generic
   (
      DXYBITS      : integer := 16;
      ACCURACYBITS : integer := 28
   );
   port
   (
      clk                  : in  std_logic;

      line_trigger         : in  std_logic;
      drawline             : in  std_logic;
      busy                 : out std_logic := '0';

      is_affine            : in  std_logic := '0';
      variant              : in  unsigned(1 downto 0);
      mapbase              : in  unsigned(18 downto 0);
      tilebase             : in  unsigned(18 downto 0);
      extpalette           : in  std_logic;
      extpal_slot          : in  unsigned(1 downto 0);
      screensize           : in  unsigned(1 downto 0);
      wrapping             : in  std_logic;
      mosaic               : in  std_logic;
      Mosaic_H_Size        : in  unsigned(3 downto 0);
      refX                 : in  signed;
      refY                 : in  signed;
      refX_mosaic          : in  signed(27 downto 0);
      refY_mosaic          : in  signed(27 downto 0);
      dx                   : in  signed(DXYBITS - 1 downto 0);
      dy                   : in  signed(DXYBITS - 1 downto 0);

      pixel_we             : out std_logic := '0';
      pixeldata            : buffer std_logic_vector(15 downto 0) := (others => '0');
      pixel_x              : out integer range 0 to 255;

      PALETTE_Drawer_addr  : out integer range 0 to 127;
      PALETTE_Drawer_data  : in  std_logic_vector(31 downto 0);
      PALETTE_Drawer_valid : in  std_logic;

      EXTPAL_Drawer_addr   : out integer range 0 to 8191;
      EXTPAL_Drawer_data   : in  std_logic_vector(31 downto 0);
      EXTPAL_Drawer_valid  : in  std_logic;

      VRAM_Drawer_req      : out std_logic := '0';
      VRAM_Drawer_addr     : out integer range 0 to 131071;
      VRAM_Drawer_data     : in  std_logic_vector(31 downto 0);
      VRAM_Drawer_done     : in  std_logic;
      VRAM_Drawer_accept   : in  std_logic := '1'
   );
end entity;

architecture arch of nds_drawer_affext is

   constant PQ_DEPTH  : integer := 4;
   constant TAG_DEPTH : integer := 4;

   signal cfg_affine   : std_logic := '0';
   signal cfg_variant  : unsigned(1 downto 0) := "00";
   signal cfg_mapbase  : unsigned(18 downto 0) := (others => '0');
   signal cfg_tilebase : unsigned(18 downto 0) := (others => '0');
   signal cfg_extpal   : std_logic := '0';
   signal cfg_slot     : unsigned(1 downto 0) := "00";
   signal cfg_size     : unsigned(1 downto 0) := "00";
   signal cfg_wrap     : std_logic := '0';
   signal cfg_mosaic   : std_logic := '0';
   signal cfg_mossize  : unsigned(3 downto 0) := (others => '0');
   signal cfg_xlim     : integer range 128 to 1024 := 128;
   signal cfg_ylim     : integer range 128 to 1024 := 128;
   signal cfg_xlimsel  : unsigned(1 downto 0) := "00";
   signal cfg_ylimsel  : unsigned(1 downto 0) := "00";

   type t_estate is (E_FREE, E_MAPREQ, E_PIXNEED, E_PIXREQ, E_READY);
   type t_pq_entry is record
      state  : t_estate;
      x      : integer range 0 to 255;
      mlane  : unsigned(1 downto 0);
      mchain : std_logic;
      mowner : integer range 0 to PQ_DEPTH-1;
      xlow   : unsigned(2 downto 0);
      ylow   : unsigned(2 downto 0);
      tent   : std_logic_vector(15 downto 0);
      plane  : unsigned(1 downto 0);
      pchain : std_logic;
      powner : integer range 0 to PQ_DEPTH-1;
      color  : std_logic_vector(15 downto 0);
   end record;
   constant PQ_INIT : t_pq_entry :=
      (E_FREE, 0, "00", '0', 0, "000", "000", (others => '0'), "00", '0', 0, (others => '0'));
   type t_pq is array (0 to PQ_DEPTH-1) of t_pq_entry;
   signal pq       : t_pq := (others => PQ_INIT);
   signal pq_head  : integer range 0 to PQ_DEPTH-1 := 0;
   signal pq_tail  : integer range 0 to PQ_DEPTH-1 := 0;
   signal pq_count : integer range 0 to PQ_DEPTH := 0;

   type t_tagkind is (T_MAP, T_PIX);
   type t_tag is record
      kind : t_tagkind;
      slot : integer range 0 to PQ_DEPTH-1;
      addr : unsigned(16 downto 0);
   end record;
   type t_tagq is array (0 to TAG_DEPTH-1) of t_tag;
   signal tagq      : t_tagq := (others => (T_MAP, 0, (others => '0')));
   signal tag_head  : integer range 0 to TAG_DEPTH-1 := 0;
   signal tag_tail  : integer range 0 to TAG_DEPTH-1 := 0;
   signal tag_count : integer range 0 to TAG_DEPTH := 0;

   signal unaccepted : std_logic := '0';

   signal pend_maddr  : unsigned(16 downto 0) := (others => '0');
   signal pend_mvalid : std_logic := '0';
   signal pend_mslot  : integer range 0 to PQ_DEPTH-1 := 0;
   signal pend_paddr  : unsigned(16 downto 0) := (others => '0');
   signal pend_pvalid : std_logic := '0';
   signal pend_pslot  : integer range 0 to PQ_DEPTH-1 := 0;

   signal cache_maddr  : unsigned(16 downto 0) := (others => '0');
   signal cache_mdata  : std_logic_vector(31 downto 0) := (others => '0');
   signal cache_mvalid : std_logic := '0';
   signal cache_paddr  : unsigned(16 downto 0) := (others => '0');
   signal cache_pdata  : std_logic_vector(31 downto 0) := (others => '0');
   signal cache_pvalid : std_logic := '0';

   signal realX    : signed(ACCURACYBITS - 1 downto 0) := (others => '0');
   signal realY    : signed(ACCURACYBITS - 1 downto 0) := (others => '0');
   signal w_active : std_logic := '0';
   signal w_x      : integer range 0 to 256 := 0;

   signal xxx_pre    : signed(19 downto 0);
   signal yyy_pre    : signed(19 downto 0);
   signal xxx        : signed(19 downto 0);
   signal yyy        : signed(19 downto 0);
   signal map_index  : integer range -524288 to 524287 := 0;
   signal map_entry  : integer range -1048576 to 1048574 := 0;
   signal yyy_x_xlim : integer := 0;

   signal p_active    : std_logic := '0';
   signal mosaik_cnt  : integer range 0 to 15 := 0;
   signal last_transp : std_logic := '1';

   signal s_valid  : std_logic := '0';
   signal s_x      : integer range 0 to 255 := 0;
   signal s_hi     : std_logic := '0';
   signal s_ext    : std_logic := '0';
   signal s_direct : std_logic := '0';
   signal s_color  : std_logic_vector(15 downto 0) := (others => '0');
   signal s_repeat : std_logic := '0';
   signal s_rep_we : std_logic := '0';
   signal s_transp : std_logic := '0';

   signal h_ready  : std_logic;
   signal h_color  : std_logic_vector(15 downto 0);
   signal h_palno  : std_logic_vector(3 downto 0);
   signal h_transp : std_logic;
   signal h_pbyte  : unsigned(8 downto 0);
   signal h_ebyte  : unsigned(14 downto 0);

begin

   xxx_pre <= realX(realX'left downto realX'left - 19);
   yyy_pre <= realY(realY'left downto realY'left - 19);

   xxx     <= xxx_pre           when (cfg_wrap = '0') else
              xxx_pre mod 128   when (cfg_xlimsel = "00") else
              xxx_pre mod 256   when (cfg_xlimsel = "01") else
              xxx_pre mod 512   when (cfg_xlimsel = "10") else
              xxx_pre mod 1024;
   yyy     <= yyy_pre           when (cfg_wrap = '0') else
              yyy_pre mod 128   when (cfg_ylimsel = "00") else
              yyy_pre mod 256   when (cfg_ylimsel = "01") else
              yyy_pre mod 512   when (cfg_ylimsel = "10") else
              yyy_pre mod 1024;

   map_index <=
      to_integer((xxx / 8) + shift_left(shift_right(yyy, 3), 4 + to_integer(cfg_size)));
   map_entry <= map_index when (cfg_affine = '1') else map_index * 2;

   yyy_x_xlim <=
      to_integer(yyy) * 128    when (cfg_xlimsel = "00") else
      to_integer(yyy) * 256    when (cfg_xlimsel = "01") else
      to_integer(yyy) * 512    when (cfg_xlimsel = "10") else
      to_integer(yyy) * 1024;

   h_ready  <= '1' when (pq(pq_head).state = E_READY) else '0';
   h_color  <= pq(pq_head).color;
   h_palno  <= pq(pq_head).tent(15 downto 12);

   h_transp <= '1' when (cfg_variant  = "10" and h_color(15) = '0') else
               '1' when (cfg_variant /= "10" and h_color(7 downto 0) = x"00") else
               '0';

   h_pbyte <= unsigned(h_color(7 downto 0) & '0');
   h_ebyte <= unsigned(std_logic_vector(cfg_slot) & h_palno & h_color(7 downto 0) & '0');

   PALETTE_Drawer_addr <= to_integer(h_pbyte(8 downto 2));
   EXTPAL_Drawer_addr  <= to_integer(h_ebyte(14 downto 2));

   process (clk)
      variable v_pq    : t_pq;
      variable v_cnt   : integer range 0 to PQ_DEPTH;
      variable v_head  : integer range 0 to PQ_DEPTH-1;
      variable v_tail  : integer range 0 to PQ_DEPTH-1;
      variable v_tagc  : integer range 0 to TAG_DEPTH;
      variable v_tagh  : integer range 0 to TAG_DEPTH-1;
      variable v_tagt  : integer range 0 to TAG_DEPTH-1;
      variable issued  : boolean;
      variable advance : boolean;
      variable tg      : t_tag;
      variable sel     : integer range 0 to PQ_DEPTH-1;
      variable k2      : integer range 0 to PQ_DEPTH-1;
      variable found   : boolean;
      variable col     : std_logic_vector(15 downto 0);
      variable ment    : std_logic_vector(15 downto 0);
      variable mbyte   : integer range 0 to 524287;
      variable mword   : unsigned(16 downto 0);
      variable pbyte   : integer range 0 to 524287;
      variable pword   : unsigned(16 downto 0);
      variable xf      : unsigned(2 downto 0);
      variable yf      : unsigned(2 downto 0);
      variable oob     : boolean;
      variable vc_maddr : unsigned(16 downto 0);
      variable vc_mdata : std_logic_vector(31 downto 0);
      variable vc_mval  : std_logic;
      variable vc_paddr : unsigned(16 downto 0);
      variable vc_pdata : std_logic_vector(31 downto 0);
      variable vc_pval  : std_logic;
      variable vp_maddr : unsigned(16 downto 0);
      variable vp_mval  : std_logic;
      variable vp_mslot : integer range 0 to PQ_DEPTH-1;
      variable vp_paddr : unsigned(16 downto 0);
      variable vp_pval  : std_logic;
      variable vp_pslot : integer range 0 to PQ_DEPTH-1;

      function pix_col (d : std_logic_vector(31 downto 0);
                        lane : unsigned(1 downto 0);
                        v : unsigned(1 downto 0)) return std_logic_vector is
      begin
         if (v /= "10") then
            case (to_integer(lane)) is
               when 0      => return x"00" & d( 7 downto  0);
               when 1      => return x"00" & d(15 downto  8);
               when 2      => return x"00" & d(23 downto 16);
               when others => return x"00" & d(31 downto 24);
            end case;
         elsif (lane(1) = '0') then
            return d(15 downto 0);
         else
            return d(31 downto 16);
         end if;
      end function;

      function map_ent (d    : std_logic_vector(31 downto 0);
                        lane : unsigned(1 downto 0);
                        aff  : std_logic) return std_logic_vector is
      begin
         if (aff = '1') then
            case (to_integer(lane)) is
               when 0      => return x"00" & d( 7 downto  0);
               when 1      => return x"00" & d(15 downto  8);
               when 2      => return x"00" & d(23 downto 16);
               when others => return x"00" & d(31 downto 24);
            end case;
         elsif (lane(1) = '0') then
            return d(15 downto 0);
         else
            return d(31 downto 16);
         end if;
      end function;
   begin
      if rising_edge(clk) then

         VRAM_Drawer_req <= '0';
         pixel_we        <= '0';

         if (VRAM_Drawer_accept = '1') then
            unaccepted <= '0';
         end if;

         if (drawline = '1') then
            cfg_affine   <= is_affine;
            if (is_affine = '1') then
               cfg_variant <= "00";
               cfg_extpal  <= '0';
            else
               cfg_variant <= variant;
               cfg_extpal  <= extpalette;
            end if;
            cfg_mapbase  <= mapbase;
            cfg_tilebase <= tilebase;
            cfg_slot     <= extpal_slot;
            cfg_size     <= screensize;
            cfg_wrap     <= wrapping;
            cfg_mosaic   <= mosaic;
            cfg_mossize  <= Mosaic_H_Size;
            if (is_affine = '1' or variant = "00") then
               cfg_xlim    <= 128 * (2 ** to_integer(screensize));
               cfg_ylim    <= 128 * (2 ** to_integer(screensize));
               cfg_xlimsel <= screensize;
               cfg_ylimsel <= screensize;
            else
               case (to_integer(screensize)) is
                  when 0      => cfg_xlim <= 128; cfg_ylim <= 128; cfg_xlimsel <= "00"; cfg_ylimsel <= "00";
                  when 1      => cfg_xlim <= 256; cfg_ylim <= 256; cfg_xlimsel <= "01"; cfg_ylimsel <= "01";
                  when 2      => cfg_xlim <= 512; cfg_ylim <= 256; cfg_xlimsel <= "10"; cfg_ylimsel <= "01";
                  when others => cfg_xlim <= 512; cfg_ylim <= 512; cfg_xlimsel <= "10"; cfg_ylimsel <= "10";
               end case;
            end if;

            pq           <= (others => PQ_INIT);
            pq_head      <= 0;
            pq_tail      <= 0;
            pq_count     <= 0;
            tag_head     <= 0;
            tag_tail     <= 0;
            tag_count    <= 0;
            unaccepted   <= '0';
            pend_mvalid  <= '0';
            pend_pvalid  <= '0';
            cache_mvalid <= '0';
            cache_pvalid <= '0';

            busy          <= '1';
            w_active      <= '1';
            w_x           <= 0;
            p_active      <= '1';
            mosaik_cnt    <= 15;
            last_transp   <= '1';
            pixeldata(15) <= '1';
            s_valid       <= '0';

         elsif (line_trigger = '1' and w_active = '0' and p_active = '0') then
            realX <= (others => '0');
            realY <= (others => '0');
            if (mosaic = '1' and unsigned(Mosaic_H_Size) > 0) then
               realX(realX'left downto realX'left - refX_mosaic'length + 1) <= refX_mosaic;
               realY(realY'left downto realY'left - refY_mosaic'length + 1) <= refY_mosaic;
            else
               realX(realX'left downto realX'left - refX'length + 1) <= refX;
               realY(realY'left downto realY'left - refY'length + 1) <= refY;
            end if;

         else

            v_pq    := pq;
            v_cnt   := pq_count;
            v_head  := pq_head;
            v_tail  := pq_tail;
            v_tagc  := tag_count;
            v_tagh  := tag_head;
            v_tagt  := tag_tail;
            issued  := false;
            advance := false;

            vc_maddr := cache_maddr;  vc_mdata := cache_mdata;  vc_mval := cache_mvalid;
            vc_paddr := cache_paddr;  vc_pdata := cache_pdata;  vc_pval := cache_pvalid;
            vp_maddr := pend_maddr;   vp_mval  := pend_mvalid;  vp_mslot := pend_mslot;
            vp_paddr := pend_paddr;   vp_pval  := pend_pvalid;  vp_pslot := pend_pslot;

            if (VRAM_Drawer_done = '1' and v_tagc > 0) then
               tg := tagq(v_tagh);

               if (tg.kind = T_MAP) then
                  vc_maddr := tg.addr;
                  vc_mdata := VRAM_Drawer_data;
                  vc_mval  := '1';
                  if (vp_mval = '1' and vp_maddr = tg.addr) then
                     vp_mval := '0';
                  end if;

                  for kk in 0 to PQ_DEPTH-1 loop
                     if (v_pq(kk).state = E_MAPREQ and
                         (kk = tg.slot or
                          (v_pq(kk).mchain = '1' and v_pq(kk).mowner = tg.slot))) then
                        v_pq(kk).tent  := map_ent(VRAM_Drawer_data, v_pq(kk).mlane, cfg_affine);
                        v_pq(kk).state := E_PIXNEED;
                     end if;
                  end loop;

               else
                  vc_paddr := tg.addr;
                  vc_pdata := VRAM_Drawer_data;
                  vc_pval  := '1';
                  if (vp_pval = '1' and vp_paddr = tg.addr) then
                     vp_pval := '0';
                  end if;

                  for kk in 0 to PQ_DEPTH-1 loop
                     if (v_pq(kk).state = E_PIXREQ and
                         (kk = tg.slot or
                          (v_pq(kk).pchain = '1' and v_pq(kk).powner = tg.slot))) then
                        v_pq(kk).color := pix_col(VRAM_Drawer_data, v_pq(kk).plane, cfg_variant);
                        v_pq(kk).state := E_READY;
                     end if;
                  end loop;
               end if;

               v_tagh := (v_tagh + 1) mod TAG_DEPTH;
               v_tagc := v_tagc - 1;
            end if;

            found := false;
            sel   := 0;
            for k in 0 to PQ_DEPTH-1 loop
               if (not found) then
                  k2 := (v_head + k) mod PQ_DEPTH;
                  if (v_pq(k2).state = E_PIXNEED) then
                     sel   := k2;
                     found := true;
                  end if;
               end if;
            end loop;

            if (found) then
               ment := v_pq(sel).tent;
               if (ment(10) = '0') then xf := v_pq(sel).xlow; else xf := 7 - v_pq(sel).xlow; end if;
               if (ment(11) = '0') then yf := v_pq(sel).ylow; else yf := 7 - v_pq(sel).ylow; end if;
               pbyte := (to_integer(cfg_tilebase)
                         + to_integer(unsigned(ment(9 downto 0))) * 64
                         + to_integer(yf) * 8 + to_integer(xf)) mod 524288;
               pword := to_unsigned(pbyte, 19)(18 downto 2);
               v_pq(sel).plane := to_unsigned(pbyte, 19)(1 downto 0);

               if (vc_pval = '1' and vc_paddr = pword) then
                  v_pq(sel).color  := pix_col(vc_pdata, to_unsigned(pbyte, 19)(1 downto 0), cfg_variant);
                  v_pq(sel).state  := E_READY;
                  v_pq(sel).pchain := '0';
               elsif (vp_pval = '1' and vp_paddr = pword) then
                  v_pq(sel).pchain := '1';
                  v_pq(sel).powner := vp_pslot;
                  v_pq(sel).state  := E_PIXREQ;
               elsif (v_tagc < TAG_DEPTH and (unaccepted = '0' or VRAM_Drawer_accept = '1')) then
                  VRAM_Drawer_addr <= to_integer(pword);
                  VRAM_Drawer_req  <= '1';
                  unaccepted       <= '1';
                  tagq(v_tagt)     <= (T_PIX, sel, pword);
                  v_tagt := (v_tagt + 1) mod TAG_DEPTH;
                  v_tagc := v_tagc + 1;
                  vp_paddr := pword;
                  vp_pval  := '1';
                  vp_pslot := sel;
                  v_pq(sel).pchain := '0';
                  v_pq(sel).state  := E_PIXREQ;
                  issued := true;
               end if;
            end if;

            if (w_active = '1' and v_cnt < PQ_DEPTH) then
               oob := (cfg_wrap = '0') and
                      (xxx_pre < 0 or yyy_pre < 0 or
                       xxx_pre >= cfg_xlim or yyy_pre >= cfg_ylim);

               if (oob) then
                  realX <= realX + dx;
                  realY <= realY + dy;
                  if (w_x = 255) then
                     w_active <= '0';
                     w_x      <= 256;
                  else
                     w_x <= w_x + 1;
                  end if;
               else
                  v_pq(v_tail)      := PQ_INIT;
                  v_pq(v_tail).x    := w_x;
                  v_pq(v_tail).xlow := unsigned(std_logic_vector(xxx(2 downto 0)));
                  v_pq(v_tail).ylow := unsigned(std_logic_vector(yyy(2 downto 0)));

                  found := false;

                  if (cfg_variant = "00") then
                     mbyte := (to_integer(cfg_mapbase) + map_entry) mod 524288;
                     mword := to_unsigned(mbyte, 19)(18 downto 2);
                     v_pq(v_tail).mlane := to_unsigned(mbyte, 19)(1 downto 0);

                     if (vc_mval = '1' and vc_maddr = mword) then
                        v_pq(v_tail).tent   := map_ent(vc_mdata, to_unsigned(mbyte, 19)(1 downto 0), cfg_affine);
                        v_pq(v_tail).mchain := '0';
                        v_pq(v_tail).state  := E_PIXNEED;
                        found := true;
                     elsif (vp_mval = '1' and vp_maddr = mword) then
                        v_pq(v_tail).mchain := '1';
                        v_pq(v_tail).mowner := vp_mslot;
                        v_pq(v_tail).state  := E_MAPREQ;
                        found := true;
                     elsif (not issued and v_tagc < TAG_DEPTH and
                            (unaccepted = '0' or VRAM_Drawer_accept = '1')) then
                        VRAM_Drawer_addr <= to_integer(mword);
                        VRAM_Drawer_req  <= '1';
                        unaccepted       <= '1';
                        tagq(v_tagt)     <= (T_MAP, v_tail, mword);
                        v_tagt := (v_tagt + 1) mod TAG_DEPTH;
                        v_tagc := v_tagc + 1;
                        vp_maddr := mword;
                        vp_mval  := '1';
                        vp_mslot := v_tail;
                        v_pq(v_tail).mchain := '0';
                        v_pq(v_tail).state  := E_MAPREQ;
                        issued := true;
                        found  := true;
                     end if;

                  else
                     if (cfg_variant = "01") then
                        pbyte := (to_integer(cfg_mapbase) + yyy_x_xlim
                                  + to_integer(xxx)) mod 524288;
                     else
                        pbyte := (to_integer(cfg_mapbase)
                                  + (yyy_x_xlim + to_integer(xxx)) * 2) mod 524288;
                     end if;
                     pword := to_unsigned(pbyte, 19)(18 downto 2);
                     v_pq(v_tail).plane := to_unsigned(pbyte, 19)(1 downto 0);

                     if (vc_pval = '1' and vc_paddr = pword) then
                        v_pq(v_tail).color  := pix_col(vc_pdata, to_unsigned(pbyte, 19)(1 downto 0), cfg_variant);
                        v_pq(v_tail).pchain := '0';
                        v_pq(v_tail).state  := E_READY;
                        found := true;
                     elsif (vp_pval = '1' and vp_paddr = pword) then
                        v_pq(v_tail).pchain := '1';
                        v_pq(v_tail).powner := vp_pslot;
                        v_pq(v_tail).state  := E_PIXREQ;
                        found := true;
                     elsif (not issued and v_tagc < TAG_DEPTH and
                            (unaccepted = '0' or VRAM_Drawer_accept = '1')) then
                        VRAM_Drawer_addr <= to_integer(pword);
                        VRAM_Drawer_req  <= '1';
                        unaccepted       <= '1';
                        tagq(v_tagt)     <= (T_PIX, v_tail, pword);
                        v_tagt := (v_tagt + 1) mod TAG_DEPTH;
                        v_tagc := v_tagc + 1;
                        vp_paddr := pword;
                        vp_pval  := '1';
                        vp_pslot := v_tail;
                        v_pq(v_tail).pchain := '0';
                        v_pq(v_tail).state  := E_PIXREQ;
                        issued := true;
                        found  := true;
                     end if;
                  end if;

                  if (found) then
                     v_tail := (v_tail + 1) mod PQ_DEPTH;
                     v_cnt  := v_cnt + 1;
                     realX  <= realX + dx;
                     realY  <= realY + dy;
                     if (w_x = 255) then
                        w_active <= '0';
                        w_x      <= 256;
                     else
                        w_x <= w_x + 1;
                     end if;
                  end if;
               end if;
            end if;

            s_valid <= '0';
            if (p_active = '1' and v_cnt > 0 and h_ready = '1') then
               if (cfg_mosaic = '1' and mosaik_cnt < to_integer(cfg_mossize)) then
                  mosaik_cnt <= mosaik_cnt + 1;
                  s_valid    <= '1';
                  s_repeat   <= '1';
                  s_rep_we   <= not last_transp;
                  s_x        <= v_pq(v_head).x;
               else
                  mosaik_cnt <= 0;
                  s_valid    <= '1';
                  s_repeat   <= '0';
                  s_x        <= v_pq(v_head).x;
                  s_color    <= h_color;
                  if (h_transp = '1') then
                     s_transp    <= '1';
                     last_transp <= '1';
                  else
                     s_transp    <= '0';
                     last_transp <= '0';
                     if (cfg_variant = "10") then
                        s_direct <= '1';
                        s_ext    <= '0';
                     elsif (cfg_variant = "00" and cfg_extpal = '1') then
                        s_direct <= '0';
                        s_ext    <= '1';
                        s_hi     <= h_ebyte(1);
                     else
                        s_direct <= '0';
                        s_ext    <= '0';
                        s_hi     <= h_pbyte(1);
                     end if;
                  end if;
               end if;
               advance := true;
            end if;

            if (advance) then
               v_pq(v_head).state := E_FREE;
               v_head := (v_head + 1) mod PQ_DEPTH;
               v_cnt  := v_cnt - 1;
               if (w_active = '0' and v_cnt = 0) then
                  p_active <= '0';
               end if;
            end if;

            if (s_valid = '1') then
               pixel_x <= s_x;
               if (s_repeat = '1') then
                  pixel_we <= s_rep_we;
               elsif (s_transp = '1') then
                  pixeldata(15) <= '1';
               elsif (s_direct = '1') then
                  pixel_we  <= '1';
                  pixeldata <= '0' & s_color(14 downto 0);
               elsif (s_ext = '1') then
                  pixel_we <= '1';
                  if (s_hi = '1') then
                     pixeldata <= '0' & EXTPAL_Drawer_data(30 downto 16);
                  else
                     pixeldata <= '0' & EXTPAL_Drawer_data(14 downto 0);
                  end if;
               else
                  pixel_we <= '1';
                  if (s_hi = '1') then
                     pixeldata <= '0' & PALETTE_Drawer_data(30 downto 16);
                  else
                     pixeldata <= '0' & PALETTE_Drawer_data(14 downto 0);
                  end if;
               end if;
            end if;

            if (w_active = '0' and v_cnt = 0 and s_valid = '0') then
               busy     <= '0';
               p_active <= '0';
            end if;

            pq        <= v_pq;
            pq_head   <= v_head;
            pq_tail   <= v_tail;
            pq_count  <= v_cnt;
            tag_head  <= v_tagh;
            tag_tail  <= v_tagt;
            tag_count <= v_tagc;

            cache_maddr <= vc_maddr;  cache_mdata <= vc_mdata;  cache_mvalid <= vc_mval;
            cache_paddr <= vc_paddr;  cache_pdata <= vc_pdata;  cache_pvalid <= vc_pval;
            pend_maddr  <= vp_maddr;  pend_mvalid <= vp_mval;   pend_mslot   <= vp_mslot;
            pend_paddr  <= vp_paddr;  pend_pvalid <= vp_pval;   pend_pslot   <= vp_pslot;

         end if;
      end if;
   end process;

end architecture;
