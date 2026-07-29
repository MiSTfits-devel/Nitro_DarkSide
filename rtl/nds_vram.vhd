-- NDS VRAM subsystem — bank stores + CPU datapath + renderer line server (v1).
--
-- Decode is nds_vram_map (unit-tested against the SDK truth table). This module
-- adds the storage and the hardware semantics:
--   * overlapping banks: writes fan out to ALL hit banks, reads OR all hit banks
--   * unmapped reads return 0
--   * banks E..I (144 KB total) are on-chip BRAM (port A = CPU, port B = renderer)
--   * banks A..D (512 KB) live behind the srv_* channel — in the real core that
--     is an SDRAM guest client (docs/MEMORY_MAP.md "Renderer feed"); testbenches
--     attach a behavioral model
--
-- CPU port protocol (both ports): pulse ena with rnw/addr/be/din held stable
-- until done; done pulses for exactly one cycle; reads: dout valid with done.
-- One op in flight per port; ops from the two ports are serialized internally
-- (fairness: alternating grant), matching the single VRAM arbiter on hardware.
--
-- Renderer line server v1 (engine A): four read-only request channels in the
-- renderer's flat spaces —
--   rdr_bg     512 KB main-BG space   (banks A..D MST=1, E MST=1, F/G MST=1)
--   rdr_obj    256 KB main-OBJ space  (banks A/B MST=2, E MST=2, F/G MST=2)
--   rdr_bgep    32 KB BG ext palette, 4 slots (E MST=4 all, F/G MST=4 by OFS.0)
--   rdr_objep    8 KB OBJ ext palette (F/G MST=5)
-- and the engine-B set (M6):
--   rdr_bgb    128 KB sub-BG space    (C MST=4, H MST=1, I MST=1 @ 0x8000)
--   rdr_objb   128 KB sub-OBJ space   (D MST=4, I MST=2)
--   rdr_bgepb   32 KB BG ext palette  (H MST=2, all 4 slots)
--   rdr_objepb   8 KB OBJ ext palette (I MST=3)
-- Protocol per channel: hold req with stable addr until done pulses (1 cycle,
-- dout valid with done); deassert req on the done cycle unless another request
-- follows. Channels are arbitrated round-robin, one op in flight; E..I hits are
-- BRAM port-B reads, A..D hits go through the read-only rsrv_* channel (the
-- future SDRAM line-cache/prefetch client; behavioral model in sim). Multi-hit
-- reads OR, unmapped reads return 0 — same semantics as the CPU side.
-- v1 is correctness-first (one op at a time, ~4 cycles/op); the per-line
-- prefetch/parallelism pass is deferred to the hardware bring-up milestone.
-- Engine B roles (H/I, C/D sub) come with M6.
--
-- Timing is NOT cycle-accurate yet (M1): BRAM ops take ~3 cycles, A..D ops
-- depend on the server. Accuracy pass comes with the membus integration.
--
-- Reset clear pass (CLR_BRAM / CLR_SRV / CLR_SRVWAIT). On a MiSTer the FPGA is
-- NOT reconfigured between ROM loads - only the loader re-runs - so every bank
-- keeps the previous game's contents and the new game shows its leftovers until
-- it happens to overwrite them. Real hardware gets VRAM cleared by the firmware
-- boot direct boot skips, exactly like the main RAM zeroing in nds_loader
-- (CLR_WR). The loader has no path to VRAM, so the clear lives here: on reset
-- the FSM walks E..I (all five BRAMs in parallel, one word per cycle) and then
-- A..D through the srv_* write channel it already owns, and holds clr_busy high
-- until it is finished. nds_top gates the CPU release on clr_busy, so the pass
-- is guaranteed to complete before any CPU or renderer request can arrive -
-- it is NOT gated on is_simu, because gating the equivalent main-RAM clear out
-- of simulation is precisely what hid the SWP cartridge-lock bug (see
-- nds_loader.vhd). tb_vram_torture pre-dirties every bank and re-asserts reset
-- to prove the pass actually zeroes them.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library MEM;

use work.pnds_vram_map.all;

entity nds_vram is
   generic
   (
      is_simu : std_logic := '0'
   );
   port
   (
      clk       : in  std_logic;
      reset     : in  std_logic;

      -- VRAMCNT_A..I raw bytes (from the GX register bank)
      vramcnt   : in  std_logic_vector(71 downto 0);

      -- ARM9 CPU port (word ops; membus produces BE for byte/halfword)
      cpu9_ena  : in  std_logic;
      cpu9_rnw  : in  std_logic;
      cpu9_addr : in  unsigned(23 downto 2);
      cpu9_be   : in  std_logic_vector(3 downto 0);
      cpu9_din  : in  std_logic_vector(31 downto 0);
      cpu9_dout : out std_logic_vector(31 downto 0) := (others => '0');
      cpu9_done : out std_logic := '0';

      -- ARM7 CPU port (only banks C/D in MST=2 can ever hit)
      cpu7_ena  : in  std_logic;
      cpu7_rnw  : in  std_logic;
      cpu7_addr : in  unsigned(23 downto 2);
      cpu7_be   : in  std_logic_vector(3 downto 0);
      cpu7_din  : in  std_logic_vector(31 downto 0);
      cpu7_dout : out std_logic_vector(31 downto 0) := (others => '0');
      cpu7_done : out std_logic := '0';

      -- banks A..D backing-store channel (SDRAM guest client / sim model)
      -- req held high with stable payload until done pulses
      srv_req   : out std_logic := '0';
      srv_rnw   : out std_logic := '1';
      srv_bank  : out std_logic_vector(1 downto 0) := "00";
      srv_addr  : out unsigned(16 downto 2) := (others => '0');
      srv_be    : out std_logic_vector(3 downto 0) := (others => '0');
      srv_din   : out std_logic_vector(31 downto 0) := (others => '0');
      srv_dout  : in  std_logic_vector(31 downto 0);
      srv_done  : in  std_logic;

      -- renderer line-server channels (read-only; see header)
      rdr_bg_req     : in  std_logic := '0';
      rdr_bg_addr    : in  unsigned(18 downto 2) := (others => '0');
      rdr_bg_dout    : out std_logic_vector(31 downto 0) := (others => '0');
      rdr_bg_done    : out std_logic := '0';

      rdr_obj_req    : in  std_logic := '0';
      rdr_obj_addr   : in  unsigned(17 downto 2) := (others => '0');
      rdr_obj_dout   : out std_logic_vector(31 downto 0) := (others => '0');
      rdr_obj_done   : out std_logic := '0';

      rdr_bgep_req   : in  std_logic := '0';
      rdr_bgep_addr  : in  unsigned(14 downto 2) := (others => '0');
      rdr_bgep_dout  : out std_logic_vector(31 downto 0) := (others => '0');
      rdr_bgep_done  : out std_logic := '0';

      rdr_objep_req  : in  std_logic := '0';
      rdr_objep_addr : in  unsigned(12 downto 2) := (others => '0');
      rdr_objep_dout : out std_logic_vector(31 downto 0) := (others => '0');
      rdr_objep_done : out std_logic := '0';

      rdr_bgb_req    : in  std_logic := '0';
      rdr_bgb_addr   : in  unsigned(16 downto 2) := (others => '0');
      rdr_bgb_dout   : out std_logic_vector(31 downto 0) := (others => '0');
      rdr_bgb_done   : out std_logic := '0';

      rdr_objb_req   : in  std_logic := '0';
      rdr_objb_addr  : in  unsigned(16 downto 2) := (others => '0');
      rdr_objb_dout  : out std_logic_vector(31 downto 0) := (others => '0');
      rdr_objb_done  : out std_logic := '0';

      rdr_bgepb_req  : in  std_logic := '0';
      rdr_bgepb_addr : in  unsigned(14 downto 2) := (others => '0');
      rdr_bgepb_dout : out std_logic_vector(31 downto 0) := (others => '0');
      rdr_bgepb_done : out std_logic := '0';

      rdr_objepb_req : in  std_logic := '0';
      rdr_objepb_addr: in  unsigned(12 downto 2) := (others => '0');
      rdr_objepb_dout: out std_logic_vector(31 downto 0) := (others => '0');
      rdr_objepb_done: out std_logic := '0';

      -- high from reset until the reset clear pass has zeroed every bank;
      -- nds_top holds the CPUs until it drops (see the header)
      clr_busy  : out std_logic := '1';

      -- renderer A..D backing channel (read-only)
      rsrv_req  : out std_logic := '0';
      rsrv_bank : out std_logic_vector(1 downto 0) := "00";
      rsrv_addr : out unsigned(16 downto 2) := (others => '0');
      rsrv_dout : in  std_logic_vector(31 downto 0) := (others => '0');
      rsrv_done : in  std_logic := '0'
   );
end entity;

architecture arch of nds_vram is

   -- per-port decoders (combinational, on the live address)
   signal dec9_hit  : std_logic_vector(8 downto 0);
   signal dec9_offs : t_vram_offs;
   signal dec7_hit  : std_logic_vector(8 downto 0);
   signal dec7_offs : t_vram_offs;

   -- latched requests
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

   -- main FSM
   type tstate is
   (
      IDLE,
      BRAMWAIT,   -- E..I registered read settles
      BRAMREAD,   -- capture + OR the BRAM dataouts
      SRVSCAN,    -- find next A..D hit (or finish)
      SRVWAIT,    -- wait for server done
      FINISH,
      CLR_BRAM,   -- reset clear: sweep E..I (all five in parallel)
      CLR_SRV,    -- reset clear: issue one A..D word write
      CLR_SRVWAIT -- reset clear: wait for the server
   );
   signal state    : tstate := CLR_BRAM;
   signal cur      : t_req := REQ_INIT;
   signal cur_is9  : std_logic := '0';
   signal acc      : std_logic_vector(31 downto 0) := (others => '0');
   signal srv_idx  : integer range 0 to 4 := 0;
   signal prefer9  : std_logic := '1';

   -- reset clear pass: one counter for both phases (E..I sweep 0..16383,
   -- each A..D bank 0..32767)
   signal clr_addr : unsigned(14 downto 0) := (others => '0');
   signal clr_bank : integer range 0 to 3 := 0;
   signal clr_bram_en : std_logic;                    -- combinational: state = CLR_BRAM
   constant CLR_BRAM_LAST : natural := 16383;      -- bank E, the largest BRAM
   constant CLR_SRV_LAST  : natural := 32767;      -- 128 KB per A..D bank

   -- E..I BRAM plumbing (CPU side = port A; renderer = port B)
   type t_bram_dout is array (BANK_E to BANK_I) of std_logic_vector(31 downto 0);
   signal bram_dout : t_bram_dout;
   signal bram_ce   : std_logic_vector(BANK_E to BANK_I);
   signal bram_we   : std_logic_vector(BANK_E to BANK_I);

   signal dispatch    : std_logic;
   signal chosen      : t_req;
   signal chosen_is9  : std_logic;

   type t_addrwidth is array (BANK_E to BANK_I) of natural;
   constant BRAM_AW : t_addrwidth := (BANK_E => 14, BANK_F => 12, BANK_G => 12, BANK_H => 13, BANK_I => 12);

   -- port-A payload: normally the dispatched CPU op, during the clear pass the
   -- sweep counter with an all-bytes zero write
   type t_bram_addr is array (BANK_E to BANK_I) of unsigned(13 downto 0);
   signal bram_addr_a : t_bram_addr;
   signal bram_din_a  : std_logic_vector(31 downto 0);
   signal bram_be_a   : std_logic_vector(3 downto 0);

   -- ==================== renderer line server ====================

   -- BG/OBJ channels reuse the CPU decoder at the canonical region addresses
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

   -- ext-palette decode (no CPU mapping; renderer-only roles of E/F/G/H/I)
   signal bgep_hit    : std_logic_vector(8 downto 0);
   signal bgep_offs   : t_vram_offs;
   signal objep_hit   : std_logic_vector(8 downto 0);
   signal objep_offs  : t_vram_offs;
   signal bgepb_hit   : std_logic_vector(8 downto 0);
   signal bgepb_offs  : t_vram_offs;
   signal objepb_hit  : std_logic_vector(8 downto 0);
   signal objepb_offs : t_vram_offs;

   type rtstate is
   (
      RIDLE,
      RBRAMWAIT,
      RBRAMREAD,
      RSRVSCAN,
      RSRVWAIT,
      RFINISH
   );
   signal rstate : rtstate := RIDLE;

   signal rreq_vec     : std_logic_vector(7 downto 0);
   signal rpend        : std_logic_vector(7 downto 0) := (others => '0');
   signal rpick        : integer range 0 to 7 := 0;
   signal rpick_valid  : std_logic;
   signal rdispatch    : std_logic;
   signal rchosen_hit  : std_logic_vector(8 downto 0);
   signal rchosen_offs : t_vram_offs;
   signal rr_pri       : integer range 0 to 7 := 0;

   signal rcur_hit  : std_logic_vector(8 downto 0) := (others => '0');
   signal rcur_offs : t_vram_offs := (others => (others => '0'));
   signal rcur_chan : integer range 0 to 7 := 0;
   signal racc      : std_logic_vector(31 downto 0) := (others => '0');
   signal rsrv_idx  : integer range 0 to 4 := 0;

   signal bram_dout_b : t_bram_dout;
   signal rbram_ce    : std_logic_vector(BANK_E to BANK_I);

   signal rdone_int   : std_logic_vector(7 downto 0) := (others => '0');
   signal rreq_now    : std_logic_vector(7 downto 0);

begin

   idec9 : entity work.nds_vram_map
   port map ( vramcnt => vramcnt, addr => cpu9_addr & "00", is_arm7 => '0', hit => dec9_hit, offs => dec9_offs );

   idec7 : entity work.nds_vram_map
   port map ( vramcnt => vramcnt, addr => cpu7_addr & "00", is_arm7 => '1', hit => dec7_hit, offs => dec7_offs );

   -- renderer BG/OBJ decode: flat renderer spaces are exactly the ARM9 view of
   -- the main-BG (0x000000) and main-OBJ (0x400000) regions
   rdec_bg_addr   <= "00000" & rdr_bg_addr & "00";
   rdec_obj_addr  <= "010000" & rdr_obj_addr & "00";
   rdec_bgb_addr  <= "0010000" & rdr_bgb_addr & "00";   -- 0x06200000 region
   rdec_objb_addr <= "0110000" & rdr_objb_addr & "00";  -- 0x06600000 region

   irdec_bg : entity work.nds_vram_map
   port map ( vramcnt => vramcnt, addr => rdec_bg_addr, is_arm7 => '0', hit => rdec_bg_hit, offs => rdec_bg_offs );

   irdec_obj : entity work.nds_vram_map
   port map ( vramcnt => vramcnt, addr => rdec_obj_addr, is_arm7 => '0', hit => rdec_obj_hit, offs => rdec_obj_offs );

   irdec_bgb : entity work.nds_vram_map
   port map ( vramcnt => vramcnt, addr => rdec_bgb_addr, is_arm7 => '0', hit => rdec_bgb_hit, offs => rdec_bgb_offs );

   irdec_objb : entity work.nds_vram_map
   port map ( vramcnt => vramcnt, addr => rdec_objb_addr, is_arm7 => '0', hit => rdec_objb_hit, offs => rdec_objb_offs );

   -- ext-palette decode (GBATEK "DS Video Memory Control", renderer-only):
   --   BG ext pal, 32 KB / 4 slots: E MST=4 covers all slots; F/G MST=4 cover
   --   slots 0-1 (OFS.0=0) or 2-3 (OFS.0=1)
   --   OBJ ext pal, 8 KB: F/G MST=5 (lower half of the bank)
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

      -- engine B: bank H MST=2 = BG ext pal (all 4 slots), bank I MST=3 =
      -- OBJ ext pal (first 8 KB of the 16 KB bank)
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

   -- renderer channel arbitration: round-robin, one op in flight. Each req is
   -- masked with its own done pulse so a requester that deasserts on the done
   -- cycle is never spuriously re-dispatched.
   -- channels hold req (stable addr) until their done pulse; requests landing
   -- while the FSM serves another channel are latched in rpend (cleared on
   -- dispatch). rpend must NOT re-latch from the still-held req of the
   -- request being served / just completed - that re-dispatched a stale
   -- address whose straggler done could answer the channel's next request
   -- with the previous data (a real bug tb_vram_ls caught with interleaved
   -- CPU reads; back-to-back requests keep req high across done and DO
   -- relatch the cycle after, which is the correct new-request case)
   rreq_now <= rdr_objepb_req & rdr_bgepb_req & rdr_objb_req & rdr_bgb_req &
               rdr_objep_req & rdr_bgep_req & rdr_obj_req & rdr_bg_req;

   grreq : for i in 0 to 7 generate
      rreq_vec(i) <= '1' when ((rreq_now(i) = '1' or rpend(i) = '1') and
                               rdone_int(i) = '0' and
                               not (rstate /= RIDLE and rcur_chan = i)) else '0';
   end generate;

   prpend : process (clk)
   begin
      if rising_edge(clk) then
         if (reset = '1') then
            rpend <= (others => '0');
         else
            for i in 0 to 7 loop
               if (rreq_now(i) = '1' and rdone_int(i) = '0' and
                   not (rstate /= RIDLE and rcur_chan = i)) then
                  rpend(i) <= '1';
               end if;
            end loop;
            if (rdispatch = '1') then
               rpend(rpick) <= '0';
            end if;
         end if;
      end if;
   end process;

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

   rdispatch <= '1' when (rstate = RIDLE and rpick_valid = '1') else '0';

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

   -- arbitration: dispatch a latched request when the FSM is free
   dispatch   <= '1' when (state = IDLE and (req9.valid = '1' or req7.valid = '1')) else '0';
   chosen_is9 <= '1' when (req9.valid = '1' and (req7.valid = '0' or prefer9 = '1')) else '0';
   chosen     <= req9 when chosen_is9 = '1' else req7;

   -- E..I BRAM inputs are driven combinationally in the dispatch cycle so the
   -- RAM samples them on the same edge the FSM leaves IDLE (ARM9 only — the
   -- ARM7 can never hit E..I)
   -- during the clear pass all five BRAMs take the same word index, so E..I go
   -- in parallel; the banks narrower than E are simply swept more than once
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

         -- renderer port (read-only)
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

   -- renderer FSM: mirror of the CPU datapath, read-only, own backing channel
   prdr : process (clk)
      variable v_racc : std_logic_vector(31 downto 0);
      variable v_next : integer range 0 to 4;
   begin
      if rising_edge(clk) then

         rdone_int <= (others => '0');

         if (reset = '1') then

            rstate   <= RIDLE;
            rsrv_req <= '0';
            rr_pri   <= 0;

         else

            case rstate is

               when RIDLE =>
                  if (rdispatch = '1') then
                     rcur_hit  <= rchosen_hit;
                     rcur_offs <= rchosen_offs;
                     rcur_chan <= rpick;
                     racc      <= (others => '0');
                     rsrv_idx  <= 0;
                     rr_pri    <= (rpick + 1) mod 8;
                     if ((rchosen_hit(BANK_E) or rchosen_hit(BANK_F) or rchosen_hit(BANK_G) or
                          rchosen_hit(BANK_H) or rchosen_hit(BANK_I)) = '1') then
                        rstate <= RBRAMWAIT;
                     else
                        rstate <= RSRVSCAN;
                     end if;
                  end if;

               when RBRAMWAIT =>
                  rstate <= RBRAMREAD;

               when RBRAMREAD =>
                  v_racc := racc;
                  for i in BANK_E to BANK_I loop
                     if (rcur_hit(i) = '1') then
                        v_racc := v_racc or bram_dout_b(i);
                     end if;
                  end loop;
                  racc   <= v_racc;
                  rstate <= RSRVSCAN;

               when RSRVSCAN =>
                  v_next := 4;
                  for i in BANK_D downto BANK_A loop
                     if (i >= rsrv_idx and rcur_hit(i) = '1') then
                        v_next := i;
                     end if;
                  end loop;
                  if (v_next = 4) then
                     rstate <= RFINISH;
                  else
                     rsrv_req  <= '1';
                     rsrv_bank <= std_logic_vector(to_unsigned(v_next, 2));
                     rsrv_addr <= rcur_offs(v_next)(16 downto 2);
                     rsrv_idx  <= v_next + 1;
                     rstate    <= RSRVWAIT;
                  end if;

               when RSRVWAIT =>
                  if (rsrv_done = '1') then
                     rsrv_req <= '0';
                     racc     <= racc or rsrv_dout;
                     rstate   <= RSRVSCAN;
                  end if;

               when RFINISH =>
                  case rcur_chan is
                     when 0 => rdr_bg_dout     <= racc;
                     when 1 => rdr_obj_dout    <= racc;
                     when 2 => rdr_bgep_dout   <= racc;
                     when 3 => rdr_objep_dout  <= racc;
                     when 4 => rdr_bgb_dout    <= racc;
                     when 5 => rdr_objb_dout   <= racc;
                     when 6 => rdr_bgepb_dout  <= racc;
                     when 7 => rdr_objepb_dout <= racc;
                  end case;
                  rdone_int(rcur_chan) <= '1';
                  rstate <= RIDLE;

            end case;

         end if;
      end if;
   end process;

   process (clk)
      variable v_acc  : std_logic_vector(31 downto 0);
      variable v_next : integer range 0 to 4;
   begin
      if rising_edge(clk) then

         cpu9_done <= '0';
         cpu7_done <= '0';

         -- request latching (ena is a single-cycle pulse)
         if (cpu9_ena = '1') then
            req9 <= ('1', cpu9_rnw, cpu9_be, cpu9_din, dec9_hit, dec9_offs);
            -- sim guard: no second op while one is in flight
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

            -- reset re-arms the clear pass; it runs once reset releases, and
            -- clr_busy keeps the CPUs held until it is done
            state      <= CLR_BRAM;
            clr_addr   <= (others => '0');
            clr_bank   <= 0;
            clr_busy   <= '1';
            req9.valid <= '0';
            req7.valid <= '0';
            srv_req    <= '0';
            prefer9    <= '1';

         else

            case state is

               when IDLE =>
                  if (dispatch = '1') then
                     cur     <= chosen;
                     cur_is9 <= chosen_is9;
                     acc     <= (others => '0');
                     srv_idx <= 0;
                     if (chosen_is9 = '1') then
                        req9.valid <= '0';
                        prefer9    <= '0';   -- fairness toggle
                     else
                        req7.valid <= '0';
                        prefer9    <= '1';
                     end if;
                     -- E..I writes complete on this same edge (bram_we);
                     -- reads need the registered dataout to settle
                     if (chosen_is9 = '1' and chosen.rnw = '1' and
                         (chosen.hit(BANK_E) or chosen.hit(BANK_F) or chosen.hit(BANK_G) or
                          chosen.hit(BANK_H) or chosen.hit(BANK_I)) = '1') then
                        state <= BRAMWAIT;
                     else
                        state <= SRVSCAN;
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
                  acc   <= v_acc;
                  state <= SRVSCAN;

               when SRVSCAN =>
                  v_next := 4;
                  for i in BANK_D downto BANK_A loop
                     if (i >= srv_idx and cur.hit(i) = '1') then
                        v_next := i;
                     end if;
                  end loop;
                  if (v_next = 4) then
                     state <= FINISH;
                  else
                     srv_req  <= '1';
                     srv_rnw  <= cur.rnw;
                     srv_bank <= std_logic_vector(to_unsigned(v_next, 2));
                     srv_addr <= cur.offs(v_next)(16 downto 2);
                     srv_be   <= cur.be;
                     srv_din  <= cur.din;
                     srv_idx  <= v_next + 1;
                     state    <= SRVWAIT;
                  end if;

               when SRVWAIT =>
                  if (srv_done = '1') then
                     srv_req <= '0';
                     if (cur.rnw = '1') then
                        acc <= acc or srv_dout;
                     end if;
                     state <= SRVSCAN;
                  end if;

               when FINISH =>
                  if (cur_is9 = '1') then
                     cpu9_dout <= acc;
                     cpu9_done <= '1';
                  else
                     cpu7_dout <= acc;
                     cpu7_done <= '1';
                  end if;
                  state <= IDLE;

               -- ===================== reset clear pass =====================
               -- E..I first (one word per cycle into all five BRAMs), then the
               -- four SDRAM-backed banks over the srv_* write channel. No CPU
               -- or renderer op can be in flight: nds_top holds both CPUs and
               -- the render pipe until clr_busy drops, and `dispatch` is gated
               -- on state = IDLE so nothing is issued from here either.
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

         end if;
      end if;
   end process;

end architecture;
