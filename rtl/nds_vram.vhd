-- NDS VRAM subsystem — bank stores + CPU datapath.
--
-- Decode is nds_vram_map (unit-tested against the SDK truth table). This module
-- adds the storage and the hardware semantics:
--   * overlapping banks: writes fan out to ALL hit banks, reads OR all hit banks
--   * unmapped reads return 0
--   * banks E..I (144 KB total) are on-chip BRAM (port B reserved for the
--     renderer, wired in M5)
--   * banks A..D (512 KB) live behind the srv_* channel — in the real core that
--     is an SDRAM guest client (docs/MEMORY_MAP.md "Renderer feed"); testbenches
--     attach a behavioral model
--
-- CPU port protocol (both ports): pulse ena with rnw/addr/be/din held stable
-- until done; done pulses for exactly one cycle; reads: dout valid with done.
-- One op in flight per port; ops from the two ports are serialized internally
-- (fairness: alternating grant), matching the single VRAM arbiter on hardware.
--
-- Timing is NOT cycle-accurate yet (M1): BRAM ops take ~3 cycles, A..D ops
-- depend on the server. Accuracy pass comes with the membus integration.

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
      srv_done  : in  std_logic
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
      FINISH
   );
   signal state    : tstate := IDLE;
   signal cur      : t_req := REQ_INIT;
   signal cur_is9  : std_logic := '0';
   signal acc      : std_logic_vector(31 downto 0) := (others => '0');
   signal srv_idx  : integer range 0 to 4 := 0;
   signal prefer9  : std_logic := '1';

   -- E..I BRAM plumbing (CPU side = port A; port B reserved for the renderer)
   type t_bram_dout is array (BANK_E to BANK_I) of std_logic_vector(31 downto 0);
   signal bram_dout : t_bram_dout;
   signal bram_ce   : std_logic_vector(BANK_E to BANK_I);
   signal bram_we   : std_logic_vector(BANK_E to BANK_I);

   signal dispatch    : std_logic;
   signal chosen      : t_req;
   signal chosen_is9  : std_logic;

   type t_addrwidth is array (BANK_E to BANK_I) of natural;
   constant BRAM_AW : t_addrwidth := (BANK_E => 14, BANK_F => 12, BANK_G => 12, BANK_H => 13, BANK_I => 12);

begin

   idec9 : entity work.nds_vram_map
   port map ( vramcnt => vramcnt, addr => cpu9_addr & "00", is_arm7 => '0', hit => dec9_hit, offs => dec9_offs );

   idec7 : entity work.nds_vram_map
   port map ( vramcnt => vramcnt, addr => cpu7_addr & "00", is_arm7 => '1', hit => dec7_hit, offs => dec7_offs );

   -- arbitration: dispatch a latched request when the FSM is free
   dispatch   <= '1' when (state = IDLE and (req9.valid = '1' or req7.valid = '1')) else '0';
   chosen_is9 <= '1' when (req9.valid = '1' and (req7.valid = '0' or prefer9 = '1')) else '0';
   chosen     <= req9 when chosen_is9 = '1' else req7;

   -- E..I BRAM inputs are driven combinationally in the dispatch cycle so the
   -- RAM samples them on the same edge the FSM leaves IDLE (ARM9 only — the
   -- ARM7 can never hit E..I)
   gbramctl : for i in BANK_E to BANK_I generate
      bram_ce(i) <= dispatch and chosen_is9 and chosen.hit(i);
      bram_we(i) <= bram_ce(i) and (not chosen.rnw);
   end generate;

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
         addr_a     => to_integer(chosen.offs(i)(BRAM_AW(i) + 1 downto 2)),
         datain_a0  => chosen.din( 7 downto  0),
         datain_a1  => chosen.din(15 downto  8),
         datain_a2  => chosen.din(23 downto 16),
         datain_a3  => chosen.din(31 downto 24),
         dataout_a  => bram_dout(i),
         we_a       => bram_we(i),
         be_a       => chosen.be,

         -- renderer port, M5
         ce_b       => '0',
         addr_b     => 0,
         datain_b0  => x"00",
         datain_b1  => x"00",
         datain_b2  => x"00",
         datain_b3  => x"00",
         dataout_b  => open,
         we_b       => '0',
         be_b       => "0000"
      );
   end generate;

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

            state      <= IDLE;
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

            end case;

         end if;
      end if;
   end process;

end architecture;
