-- SPDX-License-Identifier: GPL-2.0-or-later
-- ARM946E-S caches for the NDS ARM9: 8 KB I-cache + 4 KB write-back D-cache,
-- both 4-way set-associative with 32-byte (8-word) lines and per-set
-- round-robin replacement. Sits between nds_membus9's main-RAM decode and the
-- nds_mainram port; everything else (TCM/IO/VRAM/WRAM) stays uncached, which
-- matches how NDS software actually configures the PU.
--
--   * I-cache: read-allocate on cachable code fetches.
--   * D-cache: read-allocate, write-back. Write hit updates the line and
--     marks it dirty; write miss goes straight to memory (no allocate).
--     Dirty victims are written back before the fill.
--   * Uncachable accesses bypass both caches entirely (like the real PU:
--     changing a region's cachability without cleaning gives stale aliases,
--     on hardware and here).
--   * Maintenance ops (op_* interface, issued by nds_cpu9's MCR c7 path):
--     invalidate I all/line, invalidate D all/line/index, clean D line/index,
--     clean+invalidate D line/index. Invalidate-without-clean drops dirty
--     data - architecturally intended. op_busy is combinationally high from
--     the op_ena pulse until the op retires; the CPU stalls on it.
--
-- Storage (the M9 BRAM passes): line DATA and tags live in independent
-- per-way SyncRamDualByteEnable blocks. All four tags for a set are read in
-- parallel, then compared in an explicit lookup cycle. Valid, dirty and RR
-- state remain as small flop arrays so invalidate-all stays atomic. Cacheable
-- requests and address-based maintenance gain one cycle; associativity,
-- replacement and write-back behavior are unchanged. WB_PREP lets the first
-- data beat's registered read land before a writeback starts.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library MEM;

entity nds_cache9 is
   generic
   (
      is_simu : std_logic := '0'
   );
   port
   (
      clk         : in  std_logic;
      reset       : in  std_logic;

      -- CPU request (main-RAM accesses only, one ena pulse per request)
      req_ena       : in  std_logic;
      req_rnw       : in  std_logic;
      req_code      : in  std_logic;
      req_cacheable : in  std_logic;
      req_addr      : in  std_logic_vector(31 downto 0);
      req_be        : in  std_logic_vector(3 downto 0);
      req_wdata     : in  std_logic_vector(31 downto 0);
      resp_done     : out std_logic := '0';
      resp_rdata    : out std_logic_vector(31 downto 0) := (others => '0');

      -- memory side (nds_mainram mem9 port)
      mem_ena       : out std_logic := '0';
      mem_rnw       : out std_logic := '1';
      mem_addr      : out std_logic_vector(21 downto 2) := (others => '0');
      mem_be        : out std_logic_vector(3 downto 0) := (others => '0');
      mem_wdata     : out std_logic_vector(31 downto 0) := (others => '0');
      mem_done      : in  std_logic;
      mem_rdata     : in  std_logic_vector(31 downto 0);

      -- maintenance (see nds_cpu9 cache_op encoding)
      op_ena        : in  std_logic;
      op            : in  std_logic_vector(3 downto 0);
      op_addr       : in  std_logic_vector(31 downto 0);
      op_busy       : out std_logic;

      -- diagnostic export: {r_code, beat[2:0], state[3:0]}. Read out through the
      -- ch4 debug mailbox so a wedged ARM9 can be told apart from a slow one
      -- without a waveform. Costs a 8-bit encoder; leave it wired.
      dbg_state     : out std_logic_vector(7 downto 0) := (others => '0')
   );
end entity;

architecture arch of nds_cache9 is

   -- I: 4 ways x 64 sets x 8 words, tag = addr(31 downto 11)
   -- D: 4 ways x 32 sets x 8 words, tag = addr(31 downto 10)
   type t_rr6   is array (0 to 63) of unsigned(1 downto 0);
   type t_rr5   is array (0 to 31) of unsigned(1 downto 0);

   signal ivalid  : std_logic_vector(255 downto 0) := (others => '0');
   signal irr     : t_rr6 := (others => "00");

   signal dvalid  : std_logic_vector(127 downto 0) := (others => '0');
   signal ddirty  : std_logic_vector(127 downto 0) := (others => '0');
   signal drr     : t_rr5 := (others => "00");

   -- per-way tag and line-data stores: port A read, port B write
   type t_wayq is array (0 to 3) of std_logic_vector(31 downto 0);
   signal it_raddr : integer range 0 to 63;
   signal dt_raddr : integer range 0 to 31;
   signal it_q     : t_wayq;
   signal dt_q     : t_wayq;
   signal it_we    : std_logic_vector(3 downto 0);
   signal dt_we    : std_logic_vector(3 downto 0);
   signal it_waddr : integer range 0 to 63;
   signal dt_waddr : integer range 0 to 31;
   signal id_raddr : integer range 0 to 511;
   signal dd_raddr : integer range 0 to 255;
   signal id_q     : t_wayq;
   signal dd_q     : t_wayq;
   signal id_we    : std_logic_vector(3 downto 0);
   signal dd_we    : std_logic_vector(3 downto 0);
   signal id_waddr : integer range 0 to 511;
   signal dd_waddr : integer range 0 to 255;
   signal dd_wdata : std_logic_vector(31 downto 0);
   signal dd_wbe   : std_logic_vector(3 downto 0);

   -- response routing: on a hit the data comes off the way BRAM output
   -- (captured at the lookup edge), on a fill/bypass it comes from resp_hold
   signal resp_way   : integer range 0 to 3 := 0;
   signal resp_use_i : std_logic := '0';
   signal resp_use_d : std_logic := '0';

   -- D write hit: the BRAM write commits during HIT_RESP (one cycle after
   -- the lookup - invisible, the next lookup's read capture is >= 2 edges
   -- later, and resp_done timing is unchanged)
   signal dwr_pend : std_logic := '0';
   signal dwr_way  : integer range 0 to 3 := 0;
   signal dwr_addr : integer range 0 to 255 := 0;
   signal dwr_be   : std_logic_vector(3 downto 0) := (others => '0');
   signal dwr_data : std_logic_vector(31 downto 0) := (others => '0');

   -- writeback read cursor (port A of the victim way during WB states)
   signal wb_way   : integer range 0 to 3 := 0;
   signal wb_raddr : integer range 0 to 255 := 0;

   type t_state is
   (
      IDLE,
      REQ_LOOKUP,    -- synchronous per-way tags are now valid; resolve hit
      OP_LOOKUP,     -- resolve an address/index maintenance operation
      HIT_RESP,      -- registered hit / end of fill: put data on resp
      BYPASS_ISSUE,  -- uncachable or D write miss: single memory beat
      BYPASS_WAIT,
      WB_PREP,       -- one cycle so the victim way's beat-0 read lands
      WB_BEAT,       -- write back one dirty line (victim or clean op)
      WB_WAIT,
      FILL_BEAT,     -- fill one line from memory
      FILL_WAIT,
      OP_FINISH
   );
   signal state : t_state := IDLE;

   function state_code (s : t_state) return std_logic_vector is
   begin
      case s is
         when IDLE         => return x"0";
         when REQ_LOOKUP   => return x"1";
         when OP_LOOKUP    => return x"2";
         when HIT_RESP     => return x"3";
         when BYPASS_ISSUE => return x"4";
         when BYPASS_WAIT  => return x"5";
         when WB_PREP      => return x"6";
         when WB_BEAT      => return x"7";
         when WB_WAIT      => return x"8";
         when FILL_BEAT    => return x"9";
         when FILL_WAIT    => return x"A";
         when OP_FINISH    => return x"B";
      end case;
   end function;

   -- latched CPU request
   signal r_rnw   : std_logic := '1';
   signal r_code  : std_logic := '0';
   signal r_addr  : std_logic_vector(31 downto 0) := (others => '0');
   signal r_be    : std_logic_vector(3 downto 0) := (others => '0');
   signal r_wdata : std_logic_vector(31 downto 0) := (others => '0');
   signal r_op     : std_logic_vector(3 downto 0) := (others => '0');
   signal r_opaddr : std_logic_vector(31 downto 0) := (others => '0');

   -- fill/writeback bookkeeping
   signal beat        : unsigned(2 downto 0) := (others => '0');
   signal fill_way    : integer range 0 to 3 := 0;
   signal wb_line     : integer range 0 to 255 := 0;   -- D line being written back
   signal wb_addrbase : std_logic_vector(21 downto 5) := (others => '0');
   signal after_wb_fill : std_logic := '0';            -- WB is a victim clean before a fill
   signal op_invalidate_after : std_logic := '0';      -- clean+invalidate

   -- pending maintenance op (an op can arrive while a fetch is in flight),
   -- and a pending CPU request (a prefetch can arrive while an op runs)
   signal op_pending  : std_logic := '0';
   signal op_active   : std_logic := '0';
   signal p_op        : std_logic_vector(3 downto 0) := (others => '0');
   signal p_addr      : std_logic_vector(31 downto 0) := (others => '0');
   signal req_pending : std_logic := '0';

   signal resp_hold   : std_logic_vector(31 downto 0) := (others => '0');

begin

   op_busy <= op_ena or op_pending or op_active;

   dbg_state <= r_code & std_logic_vector(beat) & state_code(state);

   -- ================= tag and line-data stores =================
   -- At IDLE, select the address of the operation that wins arbitration.
   -- The per-way synchronous tag outputs are consumed in REQ_LOOKUP or
   -- OP_LOOKUP on the following edge.
   it_raddr <= to_integer(unsigned(op_addr(10 downto 5))) when (state = IDLE and op_ena = '1') else
               to_integer(unsigned(p_addr(10 downto 5))) when (state = IDLE and op_pending = '1') else
               to_integer(unsigned(req_addr(10 downto 5)));
   dt_raddr <= to_integer(unsigned(op_addr(9 downto 5))) when (state = IDLE and op_ena = '1') else
               to_integer(unsigned(p_addr(9 downto 5))) when (state = IDLE and op_pending = '1') else
               to_integer(unsigned(req_addr(9 downto 5)));

   it_waddr <= to_integer(unsigned(r_addr(10 downto 5)));
   dt_waddr <= to_integer(unsigned(r_addr(9 downto 5)));

   process (all)
   begin
      it_we <= (others => '0');
      dt_we <= (others => '0');
      if (state = FILL_WAIT and mem_done = '1' and beat = 7) then
         if (r_code = '1') then
            it_we(fill_way) <= '1';
         else
            dt_we(fill_way) <= '1';
         end if;
      end if;
   end process;

   -- Port A: free-running registered-address read. It follows the incoming
   -- request's set/word (the membus holds req_addr stable until resp_done,
   -- so the capture at the lookup edge is the wanted word of every way);
   -- during WB states it follows the writeback cursor instead.
   id_raddr <= to_integer(unsigned(req_addr(10 downto 2)));
   dd_raddr <= wb_raddr when (state = WB_PREP or state = WB_BEAT or state = WB_WAIT)
          else to_integer(unsigned(req_addr(9 downto 2)));

   -- Port B: writes. A pended write hit (during HIT_RESP) or a fill beat.
   process (all)
   begin
      dd_we    <= (others => '0');
      dd_waddr <= dwr_addr;
      dd_wdata <= dwr_data;
      dd_wbe   <= dwr_be;
      if (dwr_pend = '1') then
         dd_we(dwr_way) <= '1';
      elsif (state = FILL_WAIT and mem_done = '1' and r_code = '0') then
         dd_we(fill_way) <= '1';
         dd_waddr <= to_integer(unsigned(r_addr(9 downto 5))) * 8 + to_integer(beat);
         dd_wdata <= mem_rdata;
         dd_wbe   <= "1111";
      end if;
   end process;

   process (all)
   begin
      id_we    <= (others => '0');
      id_waddr <= to_integer(unsigned(r_addr(10 downto 5))) * 8 + to_integer(beat);
      if (state = FILL_WAIT and mem_done = '1' and r_code = '1') then
         id_we(fill_way) <= '1';
      end if;
   end process;

   gways : for w in 0 to 3 generate
   begin
      iitag : entity MEM.SyncRamDualByteEnable
      generic map
      (
         is_simu     => is_simu,
         is_cyclone5 => '1',
         BYTE_WIDTH  => 8,
         ADDR_WIDTH  => 6,
         BYTES       => 4
      )
      port map
      (
         clk       => clk,
         ce_a      => '1',
         addr_a    => it_raddr,
         datain_a0 => x"00", datain_a1 => x"00", datain_a2 => x"00", datain_a3 => x"00",
         dataout_a => it_q(w),
         we_a      => '0',
         be_a      => "0000",
         ce_b      => '1',
         addr_b    => it_waddr,
         datain_b0 => r_addr(18 downto 11),
         datain_b1 => r_addr(26 downto 19),
         datain_b2 => "000" & r_addr(31 downto 27),
         datain_b3 => x"00",
         dataout_b => open,
         we_b      => it_we(w),
         be_b      => "1111"
      );

      idtag : entity MEM.SyncRamDualByteEnable
      generic map
      (
         is_simu     => is_simu,
         is_cyclone5 => '1',
         BYTE_WIDTH  => 8,
         ADDR_WIDTH  => 5,
         BYTES       => 4
      )
      port map
      (
         clk       => clk,
         ce_a      => '1',
         addr_a    => dt_raddr,
         datain_a0 => x"00", datain_a1 => x"00", datain_a2 => x"00", datain_a3 => x"00",
         dataout_a => dt_q(w),
         we_a      => '0',
         be_a      => "0000",
         ce_b      => '1',
         addr_b    => dt_waddr,
         datain_b0 => r_addr(17 downto 10),
         datain_b1 => r_addr(25 downto 18),
         datain_b2 => "00" & r_addr(31 downto 26),
         datain_b3 => x"00",
         dataout_b => open,
         we_b      => dt_we(w),
         be_b      => "1111"
      );

      iidata : entity MEM.SyncRamDualByteEnable
      generic map
      (
         is_simu     => is_simu,
         is_cyclone5 => '1',
         BYTE_WIDTH  => 8,
         ADDR_WIDTH  => 9,
         BYTES       => 4
      )
      port map
      (
         clk       => clk,
         ce_a      => '1',
         addr_a    => id_raddr,
         datain_a0 => x"00", datain_a1 => x"00", datain_a2 => x"00", datain_a3 => x"00",
         dataout_a => id_q(w),
         we_a      => '0',
         be_a      => "0000",
         ce_b      => '1',
         addr_b    => id_waddr,
         datain_b0 => mem_rdata( 7 downto  0),
         datain_b1 => mem_rdata(15 downto  8),
         datain_b2 => mem_rdata(23 downto 16),
         datain_b3 => mem_rdata(31 downto 24),
         dataout_b => open,
         we_b      => id_we(w),
         be_b      => "1111"
      );

      iddata : entity MEM.SyncRamDualByteEnable
      generic map
      (
         is_simu     => is_simu,
         is_cyclone5 => '1',
         BYTE_WIDTH  => 8,
         ADDR_WIDTH  => 8,
         BYTES       => 4
      )
      port map
      (
         clk       => clk,
         ce_a      => '1',
         addr_a    => dd_raddr,
         datain_a0 => x"00", datain_a1 => x"00", datain_a2 => x"00", datain_a3 => x"00",
         dataout_a => dd_q(w),
         we_a      => '0',
         be_a      => "0000",
         ce_b      => '1',
         addr_b    => dd_waddr,
         datain_b0 => dd_wdata( 7 downto  0),
         datain_b1 => dd_wdata(15 downto  8),
         datain_b2 => dd_wdata(23 downto 16),
         datain_b3 => dd_wdata(31 downto 24),
         dataout_b => open,
         we_b      => dd_we(w),
         be_b      => dd_wbe
      );
   end generate;

   process (clk)
      variable iset, dset  : integer range 0 to 63;
      variable ihit, dhit  : boolean;
      variable hway        : integer range 0 to 3;
      variable dline       : integer range 0 to 127;
      variable v_op        : std_logic_vector(3 downto 0);
      variable v_opaddr    : std_logic_vector(31 downto 0);
      variable run_op      : boolean;
   begin
      if rising_edge(clk) then

         mem_ena   <= '0';
         resp_done <= '0';
         dwr_pend  <= '0';

         if (reset = '1') then
            state       <= IDLE;
            ivalid      <= (others => '0');
            dvalid      <= (others => '0');
            ddirty      <= (others => '0');
            op_pending  <= '0';
            op_active   <= '0';
            req_pending <= '0';
         else

            -- park an op that arrives while the FSM is busy
            if (op_ena = '1') then
               op_pending <= '1';
               p_op       <= op;
               p_addr     <= op_addr;
            end if;
            -- park a CPU request that loses arbitration to an op (the request
            -- inputs stay stable: the membus holds them until resp_done)
            if (req_ena = '1' and (state /= IDLE or op_ena = '1' or op_pending = '1')) then
               req_pending <= '1';
            end if;

            case state is

               when IDLE =>
                  run_op := false;
                  if (op_ena = '1') then
                     v_op := op; v_opaddr := op_addr; run_op := true;
                     op_pending <= '0';
                  elsif (op_pending = '1') then
                     v_op := p_op; v_opaddr := p_addr; run_op := true;
                     op_pending <= '0';
                  end if;

                  if (run_op) then
                     op_active <= '1';
                     case v_op is

                        when "0000" =>                    -- invalidate I all
                           ivalid <= (others => '0');
                           state  <= OP_FINISH;

                        when "0001" =>                    -- invalidate I line MVA
                           r_op     <= v_op;
                           r_opaddr <= v_opaddr;
                           state    <= OP_LOOKUP;

                        when "0010" =>                    -- invalidate D all
                           dvalid <= (others => '0');
                           ddirty <= (others => '0');
                           state  <= OP_FINISH;

                        when "0011" | "0100" | "0101" | "0110" | "0111" | "1000" =>
                           r_op     <= v_op;
                           r_opaddr <= v_opaddr;
                           state    <= OP_LOOKUP;

                        when others =>
                           state <= OP_FINISH;
                     end case;

                  elsif (req_ena = '1' or req_pending = '1') then
                     req_pending <= '0';
                     r_rnw   <= req_rnw;
                     r_code  <= req_code;
                     r_addr  <= req_addr;
                     r_be    <= req_be;
                     r_wdata <= req_wdata;

                     if (req_cacheable = '0') then
                        state <= BYPASS_ISSUE;
                     else
                        state <= REQ_LOOKUP;
                     end if;
                  end if;

               when REQ_LOOKUP =>
                  if (r_code = '1') then
                     iset := to_integer(unsigned(r_addr(10 downto 5)));
                     ihit := false;
                     for w in 0 to 3 loop
                        if (ivalid(w*64 + iset) = '1' and it_q(w)(20 downto 0) = r_addr(31 downto 11)) then
                           hway := w;
                           ihit := true;
                        end if;
                     end loop;
                     if (ihit) then
                        -- I-cache read hit: answer in THIS cycle instead of
                        -- spending a HIT_RESP cycle. id_q is already valid here
                        -- (id_raddr is a free-running read off req_addr, which
                        -- the membus holds stable until resp_done), and hway is
                        -- resolved combinationally just above, so the way mux can
                        -- move into this cycle. Saves one cycle on every fetch
                        -- that hits, which is the dominant ARM9 memory event:
                        -- measured CPI was 2.65 against the ARM7's 1.12.
                        -- Reads only - a D-cache *write* hit still needs
                        -- HIT_RESP, where the line update is issued.
                        resp_done  <= '1';
                        resp_rdata <= id_q(hway);
                        resp_use_i <= '0';
                        resp_use_d <= '0';
                        state      <= IDLE;
                     else
                        fill_way <= to_integer(irr(iset));
                        beat     <= (others => '0');
                        state    <= FILL_BEAT;
                     end if;
                  else
                     dset := to_integer(unsigned(r_addr(9 downto 5)));
                     dhit := false;
                     for w in 0 to 3 loop
                        if (dvalid(w*32 + dset) = '1' and dt_q(w)(21 downto 0) = r_addr(31 downto 10)) then
                           hway := w;
                           dhit := true;
                        end if;
                     end loop;

                     if (dhit) then
                        if (r_rnw = '1') then
                           resp_way   <= hway;
                           resp_use_d <= '1';
                           resp_use_i <= '0';
                        else
                           dwr_pend <= '1';
                           dwr_way  <= hway;
                           dwr_addr <= dset*8 + to_integer(unsigned(r_addr(4 downto 2)));
                           dwr_be   <= r_be;
                           dwr_data <= r_wdata;
                           ddirty(hway*32 + dset) <= '1';
                           resp_use_i <= '0';
                           resp_use_d <= '0';
                        end if;
                        state <= HIT_RESP;
                     elsif (r_rnw = '0') then
                        state <= BYPASS_ISSUE;
                     else
                        hway     := to_integer(drr(dset));
                        fill_way <= hway;
                        beat     <= (others => '0');
                        if (dvalid(hway*32 + dset) = '1' and ddirty(hway*32 + dset) = '1') then
                           wb_line       <= hway*32 + dset;
                           wb_way        <= hway;
                           wb_raddr      <= dset*8;
                           wb_addrbase   <= dt_q(hway)(11 downto 0) & r_addr(9 downto 5);
                           after_wb_fill <= '1';
                           state         <= WB_PREP;
                        else
                           state <= FILL_BEAT;
                        end if;
                     end if;
                  end if;

               when OP_LOOKUP =>
                  if (r_op = "0001") then
                     iset := to_integer(unsigned(r_opaddr(10 downto 5)));
                     for w in 0 to 3 loop
                        if (ivalid(w*64 + iset) = '1' and it_q(w)(20 downto 0) = r_opaddr(31 downto 11)) then
                           ivalid(w*64 + iset) <= '0';
                        end if;
                     end loop;
                     state <= OP_FINISH;
                  else
                     dhit := false;
                     dset := to_integer(unsigned(r_opaddr(9 downto 5)));
                     if (r_op = "0100" or r_op = "0110" or r_op = "1000") then
                        hway  := to_integer(unsigned(r_opaddr(31 downto 30)));
                        dline := hway*32 + dset;
                        dhit  := dvalid(dline) = '1';
                     else
                        for w in 0 to 3 loop
                           if (dvalid(w*32 + dset) = '1' and dt_q(w)(21 downto 0) = r_opaddr(31 downto 10)) then
                              hway  := w;
                              dline := w*32 + dset;
                              dhit  := true;
                           end if;
                        end loop;
                     end if;

                     if (not dhit) then
                        state <= OP_FINISH;
                     elsif (r_op = "0011" or r_op = "0100") then
                        dvalid(dline) <= '0';
                        ddirty(dline) <= '0';
                        state <= OP_FINISH;
                     elsif (ddirty(dline) = '0') then
                        if (r_op = "0111" or r_op = "1000") then
                           dvalid(dline) <= '0';
                        end if;
                        state <= OP_FINISH;
                     else
                        wb_line       <= dline;
                        wb_way        <= hway;
                        wb_raddr      <= dset * 8;
                        wb_addrbase   <= dt_q(hway)(11 downto 0) & std_logic_vector(to_unsigned(dset, 5));
                        beat          <= (others => '0');
                        after_wb_fill <= '0';
                        op_invalidate_after <= '0';
                        if (r_op = "0111" or r_op = "1000") then
                           op_invalidate_after <= '1';
                        end if;
                        state <= WB_PREP;
                     end if;
                  end if;

               when HIT_RESP =>
                  resp_done  <= '1';
                  if (resp_use_i = '1') then
                     resp_rdata <= id_q(resp_way);
                  elsif (resp_use_d = '1') then
                     resp_rdata <= dd_q(resp_way);
                  else
                     resp_rdata <= resp_hold;
                  end if;
                  state <= IDLE;

               when BYPASS_ISSUE =>
                  mem_ena   <= '1';
                  mem_rnw   <= r_rnw;
                  mem_addr  <= r_addr(21 downto 2);
                  mem_be    <= r_be;
                  mem_wdata <= r_wdata;
                  state     <= BYPASS_WAIT;

               when BYPASS_WAIT =>
                  if (mem_done = '1') then
                     resp_done  <= '1';
                     resp_rdata <= mem_rdata;
                     state      <= IDLE;
                  end if;

               when WB_PREP =>
                  -- beat 0's registered read (wb_raddr on port A) lands here
                  state <= WB_BEAT;

               when WB_BEAT =>
                  mem_ena   <= '1';
                  mem_rnw   <= '0';
                  mem_addr  <= wb_addrbase & std_logic_vector(beat);
                  mem_be    <= "1111";
                  mem_wdata <= dd_q(wb_way);
                  -- advance the read cursor to the next beat; its data is
                  -- captured at the next edge and holds through WB_WAIT
                  if (beat /= 7) then
                     wb_raddr <= wb_raddr + 1;
                  end if;
                  state <= WB_WAIT;

               when WB_WAIT =>
                  if (mem_done = '1') then
                     if (beat = 7) then
                        ddirty(wb_line) <= '0';
                        if (after_wb_fill = '1') then
                           beat  <= (others => '0');
                           state <= FILL_BEAT;
                        else
                           -- maintenance clean: optionally invalidate too
                           if (op_invalidate_after = '1') then
                              dvalid(wb_line) <= '0';
                           end if;
                           state <= OP_FINISH;
                        end if;
                     else
                        beat  <= beat + 1;
                        state <= WB_BEAT;
                     end if;
                  end if;

               when FILL_BEAT =>
                  mem_ena  <= '1';
                  mem_rnw  <= '1';
                  mem_addr <= r_addr(21 downto 5) & std_logic_vector(beat);
                  mem_be   <= "1111";
                  state    <= FILL_WAIT;

               when FILL_WAIT =>
                  if (mem_done = '1') then
                     -- the beat lands in the way BRAM via port B (see the
                     -- id_we/dd_we processes); only the bookkeeping is here
                     if (beat = to_integer(unsigned(r_addr(4 downto 2)))) then
                        resp_hold <= mem_rdata;
                     end if;
                     if (beat = 7) then
                        if (r_code = '1') then
                           iset := to_integer(unsigned(r_addr(10 downto 5)));
                           ivalid(fill_way*64 + iset) <= '1';
                           irr(iset) <= irr(iset) + 1;
                        else
                           dset := to_integer(unsigned(r_addr(9 downto 5)));
                           dvalid(fill_way*32 + dset) <= '1';
                           ddirty(fill_way*32 + dset) <= '0';
                           drr(dset) <= drr(dset) + 1;
                        end if;
                        resp_use_i <= '0';   -- fill returns via resp_hold
                        resp_use_d <= '0';
                        state <= HIT_RESP;
                     else
                        beat  <= beat + 1;
                        state <= FILL_BEAT;
                     end if;
                  end if;

               when OP_FINISH =>
                  op_active <= '0';
                  state     <= IDLE;

            end case;
         end if;
      end if;
   end process;

end architecture;
