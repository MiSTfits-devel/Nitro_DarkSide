
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library MEM;

use work.pnds_vram_map.all;

entity nds_vram is
   generic
   (
      is_simu : std_logic := '0';
      -- a posted write, nothing ever enters the queue, and synthesis removes the
      POSTED_WRITES : boolean := true
   );
   port
   (
      clk       : in  std_logic;
      reset     : in  std_logic;

      vramcnt   : in  std_logic_vector(71 downto 0);

      cpu9_ena  : in  std_logic;
      cpu9_rnw  : in  std_logic;
      cpu9_addr : in  unsigned(23 downto 2);
      cpu9_be   : in  std_logic_vector(3 downto 0);
      cpu9_din  : in  std_logic_vector(31 downto 0);
      cpu9_dout : out std_logic_vector(31 downto 0) := (others => '0');
      cpu9_done : out std_logic := '0';
      -- what makes it keep up: a 16-bit-per-2-cycles writer produces one word
      cpu9_wpost : in  std_logic := '0';
      cpu9_welig : out std_logic;
      cpu9_wok   : out std_logic;

      cpu7_ena  : in  std_logic;
      cpu7_rnw  : in  std_logic;
      cpu7_addr : in  unsigned(23 downto 2);
      cpu7_be   : in  std_logic_vector(3 downto 0);
      cpu7_din  : in  std_logic_vector(31 downto 0);
      cpu7_dout : out std_logic_vector(31 downto 0) := (others => '0');
      cpu7_done : out std_logic := '0';

      srv_req   : out std_logic := '0';
      srv_rnw   : out std_logic := '1';
      srv_bank  : out std_logic_vector(1 downto 0) := "00";
      srv_addr  : out unsigned(16 downto 2) := (others => '0');
      srv_be    : out std_logic_vector(3 downto 0) := (others => '0');
      srv_din   : out std_logic_vector(31 downto 0) := (others => '0');
      srv_dout  : in  std_logic_vector(31 downto 0);
      srv_done  : in  std_logic;

      rdr_bg_req     : in  std_logic := '0';
      rdr_bg_addr    : in  unsigned(18 downto 2) := (others => '0');
      rdr_bg_dout    : out std_logic_vector(31 downto 0) := (others => '0');
      rdr_bg_done    : out std_logic := '0';
      rdr_bg_accept  : out std_logic := '0';

      rdr_obj_req    : in  std_logic := '0';
      rdr_obj_addr   : in  unsigned(17 downto 2) := (others => '0');
      rdr_obj_dout   : out std_logic_vector(31 downto 0) := (others => '0');
      rdr_obj_done   : out std_logic := '0';
      rdr_obj_accept : out std_logic := '0';

      rdr_bgep_req   : in  std_logic := '0';
      rdr_bgep_addr  : in  unsigned(14 downto 2) := (others => '0');
      rdr_bgep_dout  : out std_logic_vector(31 downto 0) := (others => '0');
      rdr_bgep_done  : out std_logic := '0';
      rdr_bgep_accept : out std_logic := '0';

      rdr_objep_req  : in  std_logic := '0';
      rdr_objep_addr : in  unsigned(12 downto 2) := (others => '0');
      rdr_objep_dout : out std_logic_vector(31 downto 0) := (others => '0');
      rdr_objep_done : out std_logic := '0';
      rdr_objep_accept : out std_logic := '0';

      rdr_bgb_req    : in  std_logic := '0';
      rdr_bgb_addr   : in  unsigned(16 downto 2) := (others => '0');
      rdr_bgb_dout   : out std_logic_vector(31 downto 0) := (others => '0');
      rdr_bgb_done   : out std_logic := '0';
      rdr_bgb_accept : out std_logic := '0';

      rdr_objb_req   : in  std_logic := '0';
      rdr_objb_addr  : in  unsigned(16 downto 2) := (others => '0');
      rdr_objb_dout  : out std_logic_vector(31 downto 0) := (others => '0');
      rdr_objb_done  : out std_logic := '0';
      rdr_objb_accept : out std_logic := '0';

      rdr_bgepb_req  : in  std_logic := '0';
      rdr_bgepb_addr : in  unsigned(14 downto 2) := (others => '0');
      rdr_bgepb_dout : out std_logic_vector(31 downto 0) := (others => '0');
      rdr_bgepb_done : out std_logic := '0';
      rdr_bgepb_accept : out std_logic := '0';

      rdr_objepb_req : in  std_logic := '0';
      rdr_objepb_addr: in  unsigned(12 downto 2) := (others => '0');
      rdr_objepb_dout: out std_logic_vector(31 downto 0) := (others => '0');
      rdr_objepb_done: out std_logic := '0';
      rdr_objepb_accept : out std_logic := '0';

      clr_busy  : out std_logic := '1';

      rsrv_req   : out std_logic := '0';
      rsrv_bank  : out std_logic_vector(1 downto 0) := "00";
      rsrv_addr  : out unsigned(16 downto 3) := (others => '0');
      rsrv_dout  : in  std_logic_vector(63 downto 0) := (others => '0');
      rsrv_done  : in  std_logic := '0';
      rsrv_ready : in  std_logic := '1';

      dbg_rbusy    : out std_logic
   );
end entity;

architecture arch of nds_vram is

   signal dec9_hit  : std_logic_vector(8 downto 0);
   signal dec9_offs : t_vram_offs;
   signal dec7_hit  : std_logic_vector(8 downto 0);
   signal dec7_offs : t_vram_offs;

   type t_req is record
      valid : std_logic;
      rnw   : std_logic;
      be    : std_logic_vector(3 downto 0);
      din   : std_logic_vector(31 downto 0);
      hit   : std_logic_vector(8 downto 0);
      offs  : t_vram_offs;
   end record;
   constant REQ_INIT : t_req := ('0', '1', (others => '0'), (others => '0'), (others => '0'), (others => (others => '0')));
   signal req9, req7 : t_req := REQ_INIT;

   type tstate is
   (
      IDLE,
      BRAMWAIT,
      BRAMREAD,
      SRVSCAN,
      SRVWAIT,
      WQ_WAIT,
      CLR_BRAM,
      CLR_SRV,
      CLR_SRVWAIT
   );
   signal state    : tstate := CLR_BRAM;
   signal cur      : t_req := REQ_INIT;
   signal cur_is9  : std_logic := '0';
   signal acc      : std_logic_vector(31 downto 0) := (others => '0');
   signal srv_idx  : integer range 0 to 4 := 0;
   signal prefer9  : std_logic := '1';

   function ad_next (hit : std_logic_vector(8 downto 0); from_idx : integer) return integer is
      variable n : integer range 0 to 4 := 4;
   begin
      for i in BANK_D downto BANK_A loop
         if (i >= from_idx and hit(i) = '1') then
            n := i;
         end if;
      end loop;
      return n;
   end function;

   constant WQ_DEPTH : integer := 3;

   type t_wq_entry is record
      valid : std_logic;
      bank  : integer range BANK_A to BANK_D;
      addr  : unsigned(16 downto 2);
      be    : std_logic_vector(3 downto 0);
      din   : std_logic_vector(31 downto 0);
   end record;
   constant WQ_INIT : t_wq_entry := ('0', BANK_A, (others => '0'), (others => '0'), (others => '0'));
   type t_wq is array (0 to WQ_DEPTH-1) of t_wq_entry;

   signal wq       : t_wq := (others => WQ_INIT);
   signal wq_head  : integer range 0 to WQ_DEPTH-1 := 0;
   signal wq_tail  : integer range 0 to WQ_DEPTH-1 := 0;
   signal wq_count : integer range 0 to WQ_DEPTH := 0;

   signal wq_elig     : std_logic;
   signal wq_push_now : std_logic;
   signal wq_bank_now : integer range 0 to 4;

   signal wq_push_line : unsigned(16 downto 3);

   function wq_touches(q : t_wq; pushv : std_logic; pbank : integer;
                       pline : unsigned(16 downto 3);
                       bank : integer; line : unsigned(16 downto 3)) return boolean is
   begin
      if (pushv = '1' and pbank = bank and pline = line) then
         return true;
      end if;
      for k in 0 to WQ_DEPTH-1 loop
         if (q(k).valid = '1' and q(k).bank = bank and q(k).addr(16 downto 3) = line) then
            return true;
         end if;
      end loop;
      return false;
   end function;

   signal clr_addr : unsigned(14 downto 0) := (others => '0');
   signal clr_bank : integer range 0 to 3 := 0;
   signal clr_bram_en : std_logic;
   constant CLR_BRAM_LAST : natural := 16383;
   constant CLR_SRV_LAST  : natural := 32767;

   type t_bram_dout is array (BANK_E to BANK_I) of std_logic_vector(31 downto 0);
   signal bram_dout : t_bram_dout;
   signal bram_ce   : std_logic_vector(BANK_E to BANK_I);
   signal bram_we   : std_logic_vector(BANK_E to BANK_I);

   signal dispatch    : std_logic;
   signal chosen      : t_req;
   signal chosen_is9  : std_logic;

   type t_addrwidth is array (BANK_E to BANK_I) of natural;
   constant BRAM_AW : t_addrwidth := (BANK_E => 14, BANK_F => 12, BANK_G => 12, BANK_H => 13, BANK_I => 12);

   type t_bram_addr is array (BANK_E to BANK_I) of unsigned(13 downto 0);
   signal bram_addr_a : t_bram_addr;
   signal bram_din_a  : std_logic_vector(31 downto 0);
   signal bram_be_a   : std_logic_vector(3 downto 0);


   signal rdec_bg_addr   : unsigned(23 downto 0);
   signal rdec_obj_addr  : unsigned(23 downto 0);
   signal rdec_bgb_addr  : unsigned(23 downto 0);
   signal rdec_objb_addr : unsigned(23 downto 0);
   signal rdec_bg_hit    : std_logic_vector(8 downto 0);
   signal rdec_bg_offs   : t_vram_offs;
   signal rdec_obj_hit   : std_logic_vector(8 downto 0);
   signal rdec_obj_offs  : t_vram_offs;
   signal rdec_bgb_hit   : std_logic_vector(8 downto 0);
   signal rdec_bgb_offs  : t_vram_offs;
   signal rdec_objb_hit  : std_logic_vector(8 downto 0);
   signal rdec_objb_offs : t_vram_offs;

   signal bgep_hit    : std_logic_vector(8 downto 0);
   signal bgep_offs   : t_vram_offs;
   signal objep_hit   : std_logic_vector(8 downto 0);
   signal objep_offs  : t_vram_offs;
   signal bgepb_hit   : std_logic_vector(8 downto 0);
   signal bgepb_offs  : t_vram_offs;
   signal objepb_hit  : std_logic_vector(8 downto 0);
   signal objepb_offs : t_vram_offs;

   constant RQ_DEPTH : integer := 8;
   constant AD_DEPTH : integer := 4;

   type t_rq_entry is record
      valid    : std_logic;
      chan     : integer range 0 to 7;
      need_br  : std_logic;
      ad_todo  : std_logic_vector(BANK_A to BANK_D);
      ad_owed  : integer range 0 to 4;
      acc      : std_logic_vector(31 downto 0);
   end record;
   constant RQ_INIT : t_rq_entry :=
      ('0', 0, '0', (others => '0'), 0, (others => '0'));
   type t_rq is array (0 to RQ_DEPTH-1) of t_rq_entry;
   signal rq       : t_rq := (others => RQ_INIT);
   signal rq_head  : integer range 0 to RQ_DEPTH-1 := 0;
   signal rq_tail  : integer range 0 to RQ_DEPTH-1 := 0;
   signal rq_count : integer range 0 to RQ_DEPTH := 0;

   signal br_valid : std_logic := '0';
   signal br_slot  : integer range 0 to RQ_DEPTH-1 := 0;
   signal br_hit   : std_logic_vector(BANK_E to BANK_I) := (others => '0');

   signal ad_scan  : integer range 0 to RQ_DEPTH-1 := 0;
   signal ad_hit   : std_logic_vector(BANK_A to BANK_D) := (others => '0');
   signal ad_armed : std_logic := '0';
   type t_adq_entry is record
      slot : integer range 0 to RQ_DEPTH-1;
      bank : integer range BANK_A to BANK_D;
      hi   : std_logic;
      chan : integer range 0 to 7;
      line : unsigned(16 downto 3);
   end record;
   type t_adq is array (0 to AD_DEPTH-1) of t_adq_entry;
   signal adq       : t_adq := (others => (0, BANK_A, '0', 0, (others => '0')));
   signal adq_head  : integer range 0 to AD_DEPTH-1 := 0;
   signal adq_tail  : integer range 0 to AD_DEPTH-1 := 0;
   signal adq_count : integer range 0 to AD_DEPTH := 0;

   signal rreq_vec     : std_logic_vector(7 downto 0);
   signal rpend        : std_logic_vector(7 downto 0) := (others => '0');
   signal rpick        : integer range 0 to 7 := 0;
   signal rpick_valid  : std_logic;
   signal rdispatch    : std_logic;
   signal rchosen_hit  : std_logic_vector(8 downto 0);
   signal rchosen_offs : t_vram_offs;
   signal rr_pri       : integer range 0 to 7 := 0;

   type t_adaddr is array (0 to RQ_DEPTH-1, BANK_A to BANK_D) of unsigned(16 downto 2);
   signal ad_addr : t_adaddr := (others => (others => (others => '0')));

   type t_adline is record
      valid : std_logic;
      bank  : integer range BANK_A to BANK_D;
      line  : unsigned(16 downto 3);
      data  : std_logic_vector(63 downto 0);
   end record;
   constant ADLINE_INIT : t_adline := ('0', BANK_A, (others => '0'), (others => '0'));
   type t_adlines is array (0 to 7) of t_adline;
   signal adline : t_adlines := (others => ADLINE_INIT);

   signal rsp_valid : std_logic := '0';
   signal rsp_data  : std_logic_vector(63 downto 0) := (others => '0');

   signal adhit_valid : std_logic := '0';
   signal adhit_slot  : integer range 0 to RQ_DEPTH-1 := 0;
   signal adhit_word  : std_logic_vector(31 downto 0) := (others => '0');

   constant AD_CACHE_EN : boolean := true;

   signal bram_dout_b : t_bram_dout;
   signal rbram_ce    : std_logic_vector(BANK_E to BANK_I);

   signal rdone_int   : std_logic_vector(7 downto 0) := (others => '0');
   signal rreq_now    : std_logic_vector(7 downto 0);

begin

   idec9 : entity work.nds_vram_map
   port map ( vramcnt => vramcnt, addr => cpu9_addr & "00", is_arm7 => '0', hit => dec9_hit, offs => dec9_offs );

   idec7 : entity work.nds_vram_map
   port map ( vramcnt => vramcnt, addr => cpu7_addr & "00", is_arm7 => '1', hit => dec7_hit, offs => dec7_offs );

   rdec_bg_addr   <= "00000" & rdr_bg_addr & "00";
   rdec_obj_addr  <= "010000" & rdr_obj_addr & "00";
   rdec_bgb_addr  <= "0010000" & rdr_bgb_addr & "00";
   rdec_objb_addr <= "0110000" & rdr_objb_addr & "00";

   irdec_bg : entity work.nds_vram_map
   port map ( vramcnt => vramcnt, addr => rdec_bg_addr, is_arm7 => '0', hit => rdec_bg_hit, offs => rdec_bg_offs );

   irdec_obj : entity work.nds_vram_map
   port map ( vramcnt => vramcnt, addr => rdec_obj_addr, is_arm7 => '0', hit => rdec_obj_hit, offs => rdec_obj_offs );

   irdec_bgb : entity work.nds_vram_map
   port map ( vramcnt => vramcnt, addr => rdec_bgb_addr, is_arm7 => '0', hit => rdec_bgb_hit, offs => rdec_bgb_offs );

   irdec_objb : entity work.nds_vram_map
   port map ( vramcnt => vramcnt, addr => rdec_objb_addr, is_arm7 => '0', hit => rdec_objb_hit, offs => rdec_objb_offs );

   pextpal : process (all)
      variable mstE, mstF, mstG, mstH, mstI : unsigned(2 downto 0);
      variable ofsF, ofsG       : unsigned(1 downto 0);
   begin
      mstE := unsigned(vramcnt(BANK_E*8 + 2 downto BANK_E*8));
      mstF := unsigned(vramcnt(BANK_F*8 + 2 downto BANK_F*8));
      mstG := unsigned(vramcnt(BANK_G*8 + 2 downto BANK_G*8));
      mstH := unsigned(vramcnt(BANK_H*8 + 2 downto BANK_H*8));
      mstI := unsigned(vramcnt(BANK_I*8 + 2 downto BANK_I*8));
      ofsF := unsigned(vramcnt(BANK_F*8 + 4 downto BANK_F*8 + 3));
      ofsG := unsigned(vramcnt(BANK_G*8 + 4 downto BANK_G*8 + 3));

      bgep_hit    <= (others => '0');
      bgep_offs   <= (others => (others => '0'));
      objep_hit   <= (others => '0');
      objep_offs  <= (others => (others => '0'));
      bgepb_hit   <= (others => '0');
      bgepb_offs  <= (others => (others => '0'));
      objepb_hit  <= (others => '0');
      objepb_offs <= (others => (others => '0'));

      if (vramcnt(BANK_H*8 + 7) = '1' and mstH = 2) then
         bgepb_hit(BANK_H)  <= '1';
         bgepb_offs(BANK_H) <= "00" & rdr_bgepb_addr & "00";
      end if;
      if (vramcnt(BANK_I*8 + 7) = '1' and mstI = 3) then
         objepb_hit(BANK_I)  <= '1';
         objepb_offs(BANK_I) <= "0000" & rdr_objepb_addr & "00";
      end if;

      if (vramcnt(BANK_E*8 + 7) = '1' and mstE = 4) then
         bgep_hit(BANK_E)  <= '1';
         bgep_offs(BANK_E) <= "00" & rdr_bgep_addr & "00";
      end if;
      if (vramcnt(BANK_F*8 + 7) = '1' and mstF = 4 and rdr_bgep_addr(14) = ofsF(0)) then
         bgep_hit(BANK_F)  <= '1';
         bgep_offs(BANK_F) <= "000" & rdr_bgep_addr(13 downto 2) & "00";
      end if;
      if (vramcnt(BANK_G*8 + 7) = '1' and mstG = 4 and rdr_bgep_addr(14) = ofsG(0)) then
         bgep_hit(BANK_G)  <= '1';
         bgep_offs(BANK_G) <= "000" & rdr_bgep_addr(13 downto 2) & "00";
      end if;

      if (vramcnt(BANK_F*8 + 7) = '1' and mstF = 5) then
         objep_hit(BANK_F)  <= '1';
         objep_offs(BANK_F) <= "0000" & rdr_objep_addr & "00";
      end if;
      if (vramcnt(BANK_G*8 + 7) = '1' and mstG = 5) then
         objep_hit(BANK_G)  <= '1';
         objep_offs(BANK_G) <= "0000" & rdr_objep_addr & "00";
      end if;
   end process;

   rreq_now <= rdr_objepb_req & rdr_bgepb_req & rdr_objb_req & rdr_bgb_req &
               rdr_objep_req & rdr_bgep_req & rdr_obj_req & rdr_bg_req;

   grreq : for i in 0 to 7 generate
      rreq_vec(i) <= '1' when (rreq_now(i) = '1' or rpend(i) = '1') else '0';
   end generate;

   prpend : process (clk)
   begin
      if rising_edge(clk) then
         if (reset = '1') then
            rpend <= (others => '0');
         else
            for i in 0 to 7 loop
               if (rreq_now(i) = '1' and rpend(i) = '0') then
                  rpend(i) <= '1';
               end if;
            end loop;
            if (rdispatch = '1') then
               rpend(rpick) <= '0';
            end if;
         end if;
      end if;
   end process;

   rdr_bg_accept     <= rdispatch when rpick = 0 else '0';
   rdr_obj_accept    <= rdispatch when rpick = 1 else '0';
   rdr_bgep_accept   <= rdispatch when rpick = 2 else '0';
   rdr_objep_accept  <= rdispatch when rpick = 3 else '0';
   rdr_bgb_accept    <= rdispatch when rpick = 4 else '0';
   rdr_objb_accept   <= rdispatch when rpick = 5 else '0';
   rdr_bgepb_accept  <= rdispatch when rpick = 6 else '0';
   rdr_objepb_accept <= rdispatch when rpick = 7 else '0';

   rdr_bg_done     <= rdone_int(0);
   rdr_obj_done    <= rdone_int(1);
   rdr_bgep_done   <= rdone_int(2);
   rdr_objep_done  <= rdone_int(3);
   rdr_bgb_done    <= rdone_int(4);
   rdr_objb_done   <= rdone_int(5);
   rdr_bgepb_done  <= rdone_int(6);
   rdr_objepb_done <= rdone_int(7);

   prpick : process (all)
      variable idx : integer range 0 to 7;
      variable got : std_logic;
   begin
      idx := 0;
      got := '0';
      for k in 0 to 7 loop
         if (got = '0' and rreq_vec((rr_pri + k) mod 8) = '1') then
            idx := (rr_pri + k) mod 8;
            got := '1';
         end if;
      end loop;
      rpick       <= idx;
      rpick_valid <= got;
   end process;

   rdispatch <= '1' when (rq_count < RQ_DEPTH and rpick_valid = '1') else '0';

   dbg_rbusy <= '0' when rq_count = 0 else '1';

   rchosen_hit  <= rdec_bg_hit    when rpick = 0 else
                   rdec_obj_hit   when rpick = 1 else
                   bgep_hit       when rpick = 2 else
                   objep_hit      when rpick = 3 else
                   rdec_bgb_hit   when rpick = 4 else
                   rdec_objb_hit  when rpick = 5 else
                   bgepb_hit      when rpick = 6 else
                   objepb_hit;
   rchosen_offs <= rdec_bg_offs   when rpick = 0 else
                   rdec_obj_offs  when rpick = 1 else
                   bgep_offs      when rpick = 2 else
                   objep_offs     when rpick = 3 else
                   rdec_bgb_offs  when rpick = 4 else
                   rdec_objb_offs when rpick = 5 else
                   bgepb_offs     when rpick = 6 else
                   objepb_offs;

   grdrctl : for i in BANK_E to BANK_I generate
      rbram_ce(i) <= rdispatch and rchosen_hit(i);
   end generate;

   wq_elig <= '1' when (ad_next(dec9_hit, 0) /= 4 and
                        ad_next(dec9_hit, ad_next(dec9_hit, 0) + 1) = 4 and
                        (dec9_hit(BANK_E) or dec9_hit(BANK_F) or dec9_hit(BANK_G) or
                         dec9_hit(BANK_H) or dec9_hit(BANK_I)) = '0') else '0';

   cpu9_welig  <= '1' when (POSTED_WRITES and cpu9_wpost = '1' and cpu9_rnw = '0' and
                            wq_elig = '1' and clr_busy = '0') else '0';
   cpu9_wok    <= '1' when (cpu9_welig = '1' and wq_count < WQ_DEPTH) else '0';
   wq_push_now  <= cpu9_ena and cpu9_wok;
   wq_bank_now  <= ad_next(dec9_hit, 0);
   wq_push_line <= dec9_offs(wq_bank_now)(16 downto 3);

   dispatch   <= '1' when (state = IDLE and wq_count = 0 and
                           (req9.valid = '1' or req7.valid = '1')) else '0';
   chosen_is9 <= '1' when (req9.valid = '1' and (req7.valid = '0' or prefer9 = '1')) else '0';
   chosen     <= req9 when chosen_is9 = '1' else req7;

   clr_bram_en <= '1' when state = CLR_BRAM else '0';

   gbramctl : for i in BANK_E to BANK_I generate
      bram_ce(i)    <= clr_bram_en or (dispatch and chosen_is9 and chosen.hit(i));
      bram_we(i)    <= clr_bram_en or (dispatch and chosen_is9 and chosen.hit(i) and (not chosen.rnw));
      bram_addr_a(i) <= resize(clr_addr(BRAM_AW(i) - 1 downto 0), 14) when clr_bram_en = '1' else
                        resize(chosen.offs(i)(BRAM_AW(i) + 1 downto 2), 14);
   end generate;

   bram_din_a <= (others => '0') when clr_bram_en = '1' else chosen.din;
   bram_be_a  <= "1111"          when clr_bram_en = '1' else chosen.be;

   gbram : for i in BANK_E to BANK_I generate
      ibank : entity MEM.SyncRamDualByteEnable
      generic map
      (
         is_simu     => is_simu,
         is_cyclone5 => '1',
         BYTE_WIDTH  => 8,
         BYTES       => 4,
         ADDR_WIDTH  => BRAM_AW(i)
      )
      port map
      (
         clk        => clk,

         ce_a       => bram_ce(i),
         addr_a     => to_integer(bram_addr_a(i)(BRAM_AW(i) - 1 downto 0)),
         datain_a0  => bram_din_a( 7 downto  0),
         datain_a1  => bram_din_a(15 downto  8),
         datain_a2  => bram_din_a(23 downto 16),
         datain_a3  => bram_din_a(31 downto 24),
         dataout_a  => bram_dout(i),
         we_a       => bram_we(i),
         be_a       => bram_be_a,

         ce_b       => rbram_ce(i),
         addr_b     => to_integer(rchosen_offs(i)(BRAM_AW(i) + 1 downto 2)),
         datain_b0  => x"00",
         datain_b1  => x"00",
         datain_b2  => x"00",
         datain_b3  => x"00",
         dataout_b  => bram_dout_b(i),
         we_b       => '0',
         be_b       => "0000"
      );
   end generate;

   pad_pick : process (all)
      variable idx   : integer range 0 to RQ_DEPTH-1;
      variable found : boolean;
   begin
      idx   := 0;
      found := false;
      for k in 0 to RQ_DEPTH-1 loop
         if (not found) then
            idx := (rq_head + k) mod RQ_DEPTH;
            if (rq(idx).valid = '1' and rq(idx).ad_todo /= "0000") then
               found := true;
            end if;
         end if;
      end loop;
      if (found) then
         ad_scan  <= idx;
         ad_hit   <= rq(idx).ad_todo;
         ad_armed <= '1';
      else
         ad_scan  <= 0;
         ad_hit   <= (others => '0');
         ad_armed <= '0';
      end if;
   end process;

   prdr : process (clk)
      variable v_rq    : t_rq;
      variable v_cnt   : integer range 0 to RQ_DEPTH;
      variable v_head  : integer range 0 to RQ_DEPTH-1;
      variable v_tail  : integer range 0 to RQ_DEPTH-1;
      variable v_acc   : std_logic_vector(31 downto 0);
      variable v_adcnt : integer range 0 to AD_DEPTH;
      variable v_adh   : integer range 0 to AD_DEPTH-1;
      variable v_adt   : integer range 0 to AD_DEPTH-1;
      variable v_bank  : integer range BANK_A to BANK_D;
      variable v_nad   : integer range 0 to 4;
      variable v_slot  : integer range 0 to RQ_DEPTH-1;
      variable v_adl   : t_adlines;
      variable v_word  : std_logic_vector(31 downto 0);
      variable v_chan  : integer range 0 to 7;
      variable v_line  : unsigned(16 downto 3);
      variable v_hi    : std_logic;
   begin
      if rising_edge(clk) then

         rdone_int <= (others => '0');
         rsp_valid <= rsrv_done;
         rsp_data  <= rsrv_dout;

         if (reset = '1') then

            rq        <= (others => RQ_INIT);
            rq_head   <= 0;
            rq_tail   <= 0;
            rq_count  <= 0;
            br_valid  <= '0';
            adq_head  <= 0;
            adq_tail  <= 0;
            adq_count <= 0;
            rr_pri    <= 0;
            rsrv_req  <= '0';
            adline    <= (others => ADLINE_INIT);
            rsp_valid <= '0';
            adhit_valid <= '0';

         else

            v_rq    := rq;
            v_cnt   := rq_count;
            v_head  := rq_head;
            v_tail  := rq_tail;
            v_adcnt := adq_count;
            v_adh   := adq_head;
            v_adt   := adq_tail;
            v_adl   := adline;

            if (srv_req = '1' and srv_rnw = '0') then
               for i in 0 to 7 loop
                  v_adl(i).valid := '0';
               end loop;
            end if;

            if (wq_push_now = '1') then
               for i in 0 to 7 loop
                  if (v_adl(i).bank = wq_bank_now) then
                     v_adl(i).valid := '0';
                  end if;
               end loop;
            end if;

            if (br_valid = '1') then
               v_acc := v_rq(br_slot).acc;
               for i in BANK_E to BANK_I loop
                  if (br_hit(i) = '1') then
                     v_acc := v_acc or bram_dout_b(i);
                  end if;
               end loop;
               v_rq(br_slot).acc     := v_acc;
               v_rq(br_slot).need_br := '0';
            end if;
            br_valid <= '0';

            -- take the half that was wanted and keep the whole line for the
            if (rsp_valid = '1' and v_adcnt > 0) then
               v_slot := adq(v_adh).slot;
               if (adq(v_adh).hi = '1') then
                  v_word := rsp_data(63 downto 32);
               else
                  v_word := rsp_data(31 downto 0);
               end if;
               v_rq(v_slot).acc     := v_rq(v_slot).acc or v_word;
               v_rq(v_slot).ad_owed := v_rq(v_slot).ad_owed - 1;
               if (AD_CACHE_EN) then
                  v_adl(adq(v_adh).chan) := ('1', adq(v_adh).bank, adq(v_adh).line,
                                             rsp_data);
               end if;
               v_adh   := (v_adh + 1) mod AD_DEPTH;
               v_adcnt := v_adcnt - 1;
            end if;

            if (adhit_valid = '1') then
               v_rq(adhit_slot).acc     := v_rq(adhit_slot).acc or adhit_word;
               v_rq(adhit_slot).ad_owed := v_rq(adhit_slot).ad_owed - 1;
            end if;
            adhit_valid <= '0';

            if (rsrv_req = '0' or rsrv_ready = '1') then
               if (ad_armed = '1' and v_adcnt < AD_DEPTH) then
                  v_bank := BANK_A;
                  for i in BANK_D downto BANK_A loop
                     if (ad_hit(i) = '1') then
                        v_bank := i;
                     end if;
                  end loop;
                  v_chan := v_rq(ad_scan).chan;
                  v_line := ad_addr(ad_scan, v_bank)(16 downto 3);
                  v_hi   := ad_addr(ad_scan, v_bank)(2);

                  if (wq_touches(wq, wq_push_now, wq_bank_now, wq_push_line,
                                 v_bank, v_line)) then
                     rsrv_req <= '0';
                  else

                  if (AD_CACHE_EN and v_adl(v_chan).valid = '1' and
                      v_adl(v_chan).bank = v_bank and v_adl(v_chan).line = v_line) then
                     if (v_hi = '1') then
                        v_word := v_adl(v_chan).data(63 downto 32);
                     else
                        v_word := v_adl(v_chan).data(31 downto 0);
                     end if;
                     adhit_valid <= '1';
                     adhit_slot  <= ad_scan;
                     adhit_word  <= v_word;
                     v_rq(ad_scan).ad_todo(v_bank) := '0';
                     rsrv_req <= '0';
                  else
                     rsrv_req  <= '1';
                     rsrv_bank <= std_logic_vector(to_unsigned(v_bank, 2));
                     rsrv_addr <= v_line;
                     v_rq(ad_scan).ad_todo(v_bank) := '0';
                     adq(v_adt) <= (ad_scan, v_bank, v_hi, v_chan, v_line);
                     v_adt   := (v_adt + 1) mod AD_DEPTH;
                     v_adcnt := v_adcnt + 1;
                  end if;

                  end if;
               else
                  rsrv_req <= '0';
               end if;
            end if;

            if (rdispatch = '1') then
               v_nad := 0;
               for i in BANK_A to BANK_D loop
                  if (rchosen_hit(i) = '1') then
                     v_nad := v_nad + 1;
                  end if;
               end loop;

               v_rq(v_tail).valid   := '1';
               v_rq(v_tail).chan    := rpick;
               v_rq(v_tail).acc     := (others => '0');
               v_rq(v_tail).ad_owed := v_nad;
               for i in BANK_A to BANK_D loop
                  v_rq(v_tail).ad_todo(i) := rchosen_hit(i);
                  ad_addr(v_tail, i) <= rchosen_offs(i)(16 downto 2);
               end loop;
               v_rq(v_tail).need_br := rchosen_hit(BANK_E) or rchosen_hit(BANK_F) or
                                       rchosen_hit(BANK_G) or rchosen_hit(BANK_H) or
                                       rchosen_hit(BANK_I);

               if (v_rq(v_tail).need_br = '1') then
                  br_valid <= '1';
                  br_slot  <= v_tail;
                  for i in BANK_E to BANK_I loop
                     br_hit(i) <= rchosen_hit(i);
                  end loop;
               end if;

               rr_pri  <= (rpick + 1) mod 8;
               v_tail  := (v_tail + 1) mod RQ_DEPTH;
               v_cnt   := v_cnt + 1;
            end if;

            if (v_cnt > 0 and v_rq(v_head).valid = '1' and
                v_rq(v_head).need_br = '0' and v_rq(v_head).ad_owed = 0) then
               case v_rq(v_head).chan is
                  when 0 => rdr_bg_dout     <= v_rq(v_head).acc;
                  when 1 => rdr_obj_dout    <= v_rq(v_head).acc;
                  when 2 => rdr_bgep_dout   <= v_rq(v_head).acc;
                  when 3 => rdr_objep_dout  <= v_rq(v_head).acc;
                  when 4 => rdr_bgb_dout    <= v_rq(v_head).acc;
                  when 5 => rdr_objb_dout   <= v_rq(v_head).acc;
                  when 6 => rdr_bgepb_dout  <= v_rq(v_head).acc;
                  when 7 => rdr_objepb_dout <= v_rq(v_head).acc;
               end case;
               rdone_int(v_rq(v_head).chan) <= '1';
               v_rq(v_head).valid := '0';
               v_head := (v_head + 1) mod RQ_DEPTH;
               v_cnt  := v_cnt - 1;
            end if;

            rq        <= v_rq;
            rq_head   <= v_head;
            rq_tail   <= v_tail;
            rq_count  <= v_cnt;
            adq_head  <= v_adh;
            adq_tail  <= v_adt;
            adq_count <= v_adcnt;
            adline    <= v_adl;

         end if;
      end if;
   end process;

   process (clk)
      variable v_acc  : std_logic_vector(31 downto 0);
      variable v_next : integer range 0 to 4;

      variable v_wq    : t_wq;
      variable v_wh    : integer range 0 to WQ_DEPTH-1;
      variable v_wt    : integer range 0 to WQ_DEPTH-1;
      variable v_wcnt  : integer range 0 to WQ_DEPTH;
      variable v_wprev : integer range 0 to WQ_DEPTH-1;
      variable v_wbusy : boolean;

      procedure issue_srv (r : t_req; nxt : integer) is
      begin
         srv_req  <= '1';
         srv_rnw  <= r.rnw;
         srv_bank <= std_logic_vector(to_unsigned(nxt, 2));
         srv_addr <= r.offs(nxt)(16 downto 2);
         srv_be   <= r.be;
         srv_din  <= r.din;
         srv_idx  <= nxt + 1;
         state    <= SRVWAIT;
      end procedure;

      procedure retire (is9 : std_logic; d : std_logic_vector(31 downto 0)) is
      begin
         if (is9 = '1') then
            cpu9_dout <= d;
            cpu9_done <= '1';
         else
            cpu7_dout <= d;
            cpu7_done <= '1';
         end if;
         state <= IDLE;
      end procedure;
   begin
      if rising_edge(clk) then

         cpu9_done <= '0';
         cpu7_done <= '0';

         v_wq    := wq;
         v_wh    := wq_head;
         v_wt    := wq_tail;
         v_wcnt  := wq_count;
         v_wbusy := (state = WQ_WAIT);

         if (cpu9_ena = '1' and cpu9_wok = '0') then
            req9 <= ('1', cpu9_rnw, cpu9_be, cpu9_din, dec9_hit, dec9_offs);
            -- synthesis translate_off
            assert req9.valid = '0' report "cpu9 request overrun" severity failure;
            -- synthesis translate_on
         end if;
         if (cpu7_ena = '1') then
            req7 <= ('1', cpu7_rnw, cpu7_be, cpu7_din, dec7_hit, dec7_offs);
            -- synthesis translate_off
            assert req7.valid = '0' report "cpu7 request overrun" severity failure;
            -- synthesis translate_on
         end if;

         if (reset = '1') then

            state      <= CLR_BRAM;
            clr_addr   <= (others => '0');
            clr_bank   <= 0;
            clr_busy   <= '1';
            req9.valid <= '0';
            req7.valid <= '0';
            srv_req    <= '0';
            prefer9    <= '1';
            v_wq       := (others => WQ_INIT);
            v_wh       := 0;
            v_wt       := 0;
            v_wcnt     := 0;

         else

            case state is

               when IDLE =>
                  if (v_wcnt > 0) then
                     srv_req  <= '1';
                     srv_rnw  <= '0';
                     srv_bank <= std_logic_vector(to_unsigned(v_wq(v_wh).bank, 2));
                     srv_addr <= v_wq(v_wh).addr;
                     srv_be   <= v_wq(v_wh).be;
                     srv_din  <= v_wq(v_wh).din;
                     state    <= WQ_WAIT;
                     v_wbusy  := true;
                  elsif (dispatch = '1') then
                     cur     <= chosen;
                     cur_is9 <= chosen_is9;
                     acc     <= (others => '0');
                     srv_idx <= 0;
                     if (chosen_is9 = '1') then
                        req9.valid <= '0';
                        prefer9    <= '0';
                     else
                        req7.valid <= '0';
                        prefer9    <= '1';
                     end if;
                     if (chosen_is9 = '1' and chosen.rnw = '1' and
                         (chosen.hit(BANK_E) or chosen.hit(BANK_F) or chosen.hit(BANK_G) or
                          chosen.hit(BANK_H) or chosen.hit(BANK_I)) = '1') then
                        state <= BRAMWAIT;
                     else
                        v_next := ad_next(chosen.hit, 0);
                        if (v_next = 4) then
                           retire(chosen_is9, (others => '0'));
                        else
                           issue_srv(chosen, v_next);
                        end if;
                     end if;
                  end if;

               when BRAMWAIT =>
                  state <= BRAMREAD;

               when BRAMREAD =>
                  v_acc := acc;
                  for i in BANK_E to BANK_I loop
                     if (cur.hit(i) = '1') then
                        v_acc := v_acc or bram_dout(i);
                     end if;
                  end loop;
                  acc    <= v_acc;
                  v_next := ad_next(cur.hit, 0);
                  if (v_next = 4) then
                     retire(cur_is9, v_acc);
                  else
                     issue_srv(cur, v_next);
                  end if;

               when SRVSCAN =>
                  v_next := ad_next(cur.hit, srv_idx);
                  if (v_next = 4) then
                     retire(cur_is9, acc);
                  else
                     issue_srv(cur, v_next);
                  end if;

               when SRVWAIT =>
                  if (srv_done = '1') then
                     v_acc := acc;
                     if (cur.rnw = '1') then
                        v_acc := v_acc or srv_dout;
                        acc   <= v_acc;
                     end if;
                     srv_req <= '0';
                     if (ad_next(cur.hit, srv_idx) = 4) then
                        retire(cur_is9, v_acc);
                     else
                        state <= SRVSCAN;
                     end if;
                  end if;

               when WQ_WAIT =>
                  if (srv_done = '1') then
                     srv_req          <= '0';
                     v_wq(v_wh).valid := '0';
                     if (v_wh = WQ_DEPTH - 1) then
                        v_wh := 0;
                     else
                        v_wh := v_wh + 1;
                     end if;
                     v_wcnt           := v_wcnt - 1;
                     v_wbusy          := false;
                     state            <= IDLE;
                  end if;

               when CLR_BRAM =>
                  if (clr_addr = to_unsigned(CLR_BRAM_LAST, clr_addr'length)) then
                     clr_addr <= (others => '0');
                     state    <= CLR_SRV;
                  else
                     clr_addr <= clr_addr + 1;
                  end if;

               when CLR_SRV =>
                  srv_req  <= '1';
                  srv_rnw  <= '0';
                  srv_bank <= std_logic_vector(to_unsigned(clr_bank, 2));
                  srv_addr <= clr_addr;
                  srv_be   <= "1111";
                  srv_din  <= (others => '0');
                  state    <= CLR_SRVWAIT;

               when CLR_SRVWAIT =>
                  if (srv_done = '1') then
                     srv_req <= '0';
                     if (clr_addr = to_unsigned(CLR_SRV_LAST, clr_addr'length)) then
                        clr_addr <= (others => '0');
                        if (clr_bank = 3) then
                           clr_busy <= '0';
                           state    <= IDLE;
                        else
                           clr_bank <= clr_bank + 1;
                           state    <= CLR_SRV;
                        end if;
                     else
                        clr_addr <= clr_addr + 1;
                        state    <= CLR_SRV;
                     end if;
                  end if;

            end case;

            if (wq_push_now = '1') then
               if (v_wt = 0) then
                  v_wprev := WQ_DEPTH - 1;
               else
                  v_wprev := v_wt - 1;
               end if;
               if (v_wcnt > 0 and v_wq(v_wprev).valid = '1' and
                   v_wq(v_wprev).bank = wq_bank_now and
                   v_wq(v_wprev).addr = dec9_offs(wq_bank_now)(16 downto 2) and
                   not (v_wprev = v_wh and v_wbusy)) then
                  for j in 0 to 3 loop
                     if (cpu9_be(j) = '1') then
                        v_wq(v_wprev).din(j*8 + 7 downto j*8) := cpu9_din(j*8 + 7 downto j*8);
                     end if;
                  end loop;
                  v_wq(v_wprev).be := v_wq(v_wprev).be or cpu9_be;
               else
                  v_wq(v_wt) := ('1', wq_bank_now,
                                 dec9_offs(wq_bank_now)(16 downto 2), cpu9_be, cpu9_din);
                  if (v_wt = WQ_DEPTH - 1) then
                     v_wt := 0;
                  else
                     v_wt := v_wt + 1;
                  end if;
                  v_wcnt := v_wcnt + 1;
               end if;
            end if;

         end if;

         wq       <= v_wq;
         wq_head  <= v_wh;
         wq_tail  <= v_wt;
         wq_count <= v_wcnt;

      end if;
   end process;

end architecture;
