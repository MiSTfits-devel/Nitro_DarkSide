-- SPDX-License-Identifier: GPL-2.0-or-later

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

      req_ena       : in  std_logic;
      req_rnw       : in  std_logic;
      req_code      : in  std_logic;
      req_cacheable : in  std_logic;
      req_addr      : in  std_logic_vector(31 downto 0);
      req_be        : in  std_logic_vector(3 downto 0);
      req_wdata     : in  std_logic_vector(31 downto 0);
      spec_addr     : in  std_logic_vector(31 downto 0);
      resp_done     : out std_logic := '0';
      resp_rdata    : out std_logic_vector(31 downto 0) := (others => '0');

      mem_ena       : out std_logic := '0';
      mem_rnw       : out std_logic := '1';
      mem_addr      : out std_logic_vector(21 downto 2) := (others => '0');
      mem_be        : out std_logic_vector(3 downto 0) := (others => '0');
      mem_wdata     : out std_logic_vector(31 downto 0) := (others => '0');
      mem_done      : in  std_logic;
      mem_rdata     : in  std_logic_vector(31 downto 0);
      mem_pair      : out std_logic := '0';
      mem_rdata_hi  : in  std_logic_vector(31 downto 0) := (others => '0');

      op_ena        : in  std_logic;
      op            : in  std_logic_vector(3 downto 0);
      op_addr       : in  std_logic_vector(31 downto 0);
      op_busy       : out std_logic;

      dbg_state     : out std_logic_vector(7 downto 0) := (others => '0')
   );
end entity;

architecture arch of nds_cache9 is

   type t_rr6   is array (0 to 63) of unsigned(1 downto 0);
   type t_rr5   is array (0 to 31) of unsigned(1 downto 0);

   signal ivalid  : std_logic_vector(255 downto 0) := (others => '0');
   signal irr     : t_rr6 := (others => "00");

   signal dvalid  : std_logic_vector(127 downto 0) := (others => '0');
   signal ddirty  : std_logic_vector(127 downto 0) := (others => '0');
   signal drr     : t_rr5 := (others => "00");

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
   signal id_wdata : std_logic_vector(31 downto 0);
   signal dd_waddr : integer range 0 to 255;
   signal dd_wdata : std_logic_vector(31 downto 0);
   signal dd_wbe   : std_logic_vector(3 downto 0);

   signal resp_way   : integer range 0 to 3 := 0;
   signal resp_use_i : std_logic := '0';
   signal resp_use_d : std_logic := '0';

   signal dwr_pend : std_logic := '0';
   signal dwr_way  : integer range 0 to 3 := 0;
   signal dwr_addr : integer range 0 to 255 := 0;
   signal dwr_be   : std_logic_vector(3 downto 0) := (others => '0');
   signal dwr_data : std_logic_vector(31 downto 0) := (others => '0');

   signal wb_way   : integer range 0 to 3 := 0;
   signal wb_raddr : integer range 0 to 255 := 0;

   signal spec_sel : std_logic := '0';
   signal spec_ok  : std_logic := '0';

   signal cmp_addr : std_logic_vector(31 downto 0);
   signal ihit_c   : std_logic;
   signal dhit_c   : std_logic;
   signal ihway_c  : integer range 0 to 3;
   signal dhway_c  : integer range 0 to 3;

   type t_state is
   (
      IDLE,
      REQ_LOOKUP,
      OP_LOOKUP,
      HIT_RESP,
      BYPASS_ISSUE,
      BYPASS_WAIT,
      WB_PREP,
      WB_BEAT,
      WB_WAIT,
      FILL_BEAT,
      FILL_WAIT,
      FILL_HI,
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
         when FILL_HI      => return x"C";
      end case;
   end function;

   signal r_rnw   : std_logic := '1';
   signal r_code  : std_logic := '0';
   signal r_addr  : std_logic_vector(31 downto 0) := (others => '0');
   signal r_be    : std_logic_vector(3 downto 0) := (others => '0');
   signal r_wdata : std_logic_vector(31 downto 0) := (others => '0');
   signal r_op     : std_logic_vector(3 downto 0) := (others => '0');
   signal r_opaddr : std_logic_vector(31 downto 0) := (others => '0');

   signal beat        : unsigned(2 downto 0) := (others => '0');
   signal fill_cnt    : unsigned(1 downto 0) := (others => '0');
   signal fill_way    : integer range 0 to 3 := 0;
   signal wb_line     : integer range 0 to 255 := 0;
   signal wb_addrbase : std_logic_vector(21 downto 5) := (others => '0');
   signal after_wb_fill : std_logic := '0';
   signal op_invalidate_after : std_logic := '0';

   signal op_pending  : std_logic := '0';
   signal op_active   : std_logic := '0';
   signal p_op        : std_logic_vector(3 downto 0) := (others => '0');
   signal p_addr      : std_logic_vector(31 downto 0) := (others => '0');
   signal req_pending : std_logic := '0';

   signal resp_hold   : std_logic_vector(31 downto 0) := (others => '0');

begin

   op_busy <= op_ena or op_pending or op_active;

   dbg_state <= r_code & std_logic_vector(beat) & state_code(state);

   spec_sel <= '1' when (state = IDLE and op_ena = '0' and op_pending = '0' and
                         req_ena = '0' and req_pending = '0') else '0';

   it_raddr <= to_integer(unsigned(op_addr(10 downto 5))) when (state = IDLE and op_ena = '1') else
               to_integer(unsigned(p_addr(10 downto 5))) when (state = IDLE and op_pending = '1') else
               to_integer(unsigned(spec_addr(10 downto 5))) when (spec_sel = '1') else
               to_integer(unsigned(req_addr(10 downto 5)));
   dt_raddr <= to_integer(unsigned(op_addr(9 downto 5))) when (state = IDLE and op_ena = '1') else
               to_integer(unsigned(p_addr(9 downto 5))) when (state = IDLE and op_pending = '1') else
               to_integer(unsigned(spec_addr(9 downto 5))) when (spec_sel = '1') else
               to_integer(unsigned(req_addr(9 downto 5)));

   cmp_addr <= req_addr when (state = IDLE) else r_addr;

   process (all)
      variable s : integer range 0 to 63;
   begin
      ihit_c  <= '0';
      ihway_c <= 0;
      s := to_integer(unsigned(cmp_addr(10 downto 5)));
      for w in 0 to 3 loop
         if (ivalid(w*64 + s) = '1' and it_q(w)(20 downto 0) = cmp_addr(31 downto 11)) then
            ihit_c  <= '1';
            ihway_c <= w;
         end if;
      end loop;
   end process;

   process (all)
      variable s : integer range 0 to 31;
   begin
      dhit_c  <= '0';
      dhway_c <= 0;
      s := to_integer(unsigned(cmp_addr(9 downto 5)));
      for w in 0 to 3 loop
         if (dvalid(w*32 + s) = '1' and dt_q(w)(21 downto 0) = cmp_addr(31 downto 10)) then
            dhit_c  <= '1';
            dhway_c <= w;
         end if;
      end loop;
   end process;

   it_waddr <= to_integer(unsigned(r_addr(10 downto 5)));
   dt_waddr <= to_integer(unsigned(r_addr(9 downto 5)));

   process (all)
   begin
      it_we <= (others => '0');
      dt_we <= (others => '0');
      if (state = FILL_HI and fill_cnt = 3) then
         if (r_code = '1') then
            it_we(fill_way) <= '1';
         else
            dt_we(fill_way) <= '1';
         end if;
      end if;
   end process;

   id_raddr <= to_integer(unsigned(spec_addr(10 downto 2))) when (spec_sel = '1')
          else to_integer(unsigned(req_addr(10 downto 2)));
   dd_raddr <= wb_raddr when (state = WB_PREP or state = WB_BEAT or state = WB_WAIT)
          else to_integer(unsigned(spec_addr(9 downto 2))) when (spec_sel = '1')
          else to_integer(unsigned(req_addr(9 downto 2)));

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
      elsif (state = FILL_HI and r_code = '0') then
         dd_we(fill_way) <= '1';
         dd_waddr <= to_integer(unsigned(r_addr(9 downto 5))) * 8 + to_integer(beat) + 1;
         dd_wdata <= mem_rdata_hi;
         dd_wbe   <= "1111";
      end if;
   end process;

   process (all)
   begin
      id_we    <= (others => '0');
      id_waddr <= to_integer(unsigned(r_addr(10 downto 5))) * 8 + to_integer(beat);
      id_wdata <= mem_rdata;
      if (state = FILL_WAIT and mem_done = '1' and r_code = '1') then
         id_we(fill_way) <= '1';
      elsif (state = FILL_HI and r_code = '1') then
         id_we(fill_way) <= '1';
         id_waddr <= to_integer(unsigned(r_addr(10 downto 5))) * 8 + to_integer(beat) + 1;
         id_wdata <= mem_rdata_hi;
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
         datain_b0 => id_wdata( 7 downto  0),
         datain_b1 => id_wdata(15 downto  8),
         datain_b2 => id_wdata(23 downto 16),
         datain_b3 => id_wdata(31 downto 24),
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
         spec_ok   <= spec_sel;

         if (reset = '1') then
            spec_ok     <= '0';
            state       <= IDLE;
            ivalid      <= (others => '0');
            dvalid      <= (others => '0');
            ddirty      <= (others => '0');
            op_pending  <= '0';
            op_active   <= '0';
            req_pending <= '0';
         else

            if (op_ena = '1') then
               op_pending <= '1';
               p_op       <= op;
               p_addr     <= op_addr;
            end if;
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

                        when "0000" =>
                           ivalid <= (others => '0');
                           state  <= OP_FINISH;

                        when "0001" =>
                           r_op     <= v_op;
                           r_opaddr <= v_opaddr;
                           state    <= OP_LOOKUP;

                        when "0010" =>
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
                     elsif (spec_ok = '1' and req_pending = '0' and
                            ((req_code = '1' and ihit_c = '1') or
                             (req_code = '0' and dhit_c = '1' and req_rnw = '1'))) then
                        resp_done  <= '1';
                        resp_use_i <= '0';
                        resp_use_d <= '0';
                        if (req_code = '1') then
                           resp_rdata <= id_q(ihway_c);
                        else
                           resp_rdata <= dd_q(dhway_c);
                        end if;
                     else
                        state <= REQ_LOOKUP;
                     end if;
                  end if;

               when REQ_LOOKUP =>
                  if (r_code = '1') then
                     iset := to_integer(unsigned(r_addr(10 downto 5)));
                     ihit := (ihit_c = '1');
                     hway := ihway_c;
                     if (ihit) then
                        resp_done  <= '1';
                        resp_rdata <= id_q(hway);
                        resp_use_i <= '0';
                        resp_use_d <= '0';
                        state      <= IDLE;
                     else
                        fill_way <= to_integer(irr(iset));
                        beat     <= unsigned(r_addr(4 downto 3)) & '0';
                        fill_cnt <= (others => '0');
                        state    <= FILL_BEAT;
                     end if;
                  else
                     dset := to_integer(unsigned(r_addr(9 downto 5)));
                     dhit := (dhit_c = '1');
                     hway := dhway_c;

                     if (dhit) then
                        if (r_rnw = '1') then
                           resp_done  <= '1';
                           resp_rdata <= dd_q(hway);
                           resp_use_i <= '0';
                           resp_use_d <= '0';
                           state      <= IDLE;
                        else
                           dwr_pend <= '1';
                           dwr_way  <= hway;
                           dwr_addr <= dset*8 + to_integer(unsigned(r_addr(4 downto 2)));
                           dwr_be   <= r_be;
                           dwr_data <= r_wdata;
                           ddirty(hway*32 + dset) <= '1';
                           resp_use_i <= '0';
                           resp_use_d <= '0';
                           state    <= HIT_RESP;
                        end if;
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
                           beat     <= unsigned(r_addr(4 downto 3)) & '0';
                           fill_cnt <= (others => '0');
                           state    <= FILL_BEAT;
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
                  mem_pair  <= '0';
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
                  state <= WB_BEAT;

               when WB_BEAT =>
                  mem_ena   <= '1';
                  mem_pair  <= '0';
                  mem_rnw   <= '0';
                  mem_addr  <= wb_addrbase & std_logic_vector(beat);
                  mem_be    <= "1111";
                  mem_wdata <= dd_q(wb_way);
                  if (beat /= 7) then
                     wb_raddr <= wb_raddr + 1;
                  end if;
                  state <= WB_WAIT;

               when WB_WAIT =>
                  if (mem_done = '1') then
                     if (beat = 7) then
                        ddirty(wb_line) <= '0';
                        if (after_wb_fill = '1') then
                           beat     <= unsigned(r_addr(4 downto 3)) & '0';
                           fill_cnt <= (others => '0');
                           state    <= FILL_BEAT;
                        else
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
                  mem_pair <= '1';
                  mem_rnw  <= '1';
                  mem_addr <= r_addr(21 downto 5) & std_logic_vector(beat);
                  mem_be   <= "1111";
                  state    <= FILL_WAIT;

               when FILL_WAIT =>
                  if (mem_done = '1') then
                     if (beat = to_integer(unsigned(r_addr(4 downto 2)))) then
                        resp_rdata <= mem_rdata;
                        resp_done  <= '1';
                     end if;
                     state <= FILL_HI;
                  end if;

               when FILL_HI =>
                  if (beat + 1 = unsigned(r_addr(4 downto 2))) then
                     resp_rdata <= mem_rdata_hi;
                     resp_done  <= '1';
                  end if;
                  if (fill_cnt = 3) then
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
                     state <= IDLE;
                  else
                     beat     <= beat + 2;
                     fill_cnt <= fill_cnt + 1;
                     state    <= FILL_BEAT;
                  end if;

               when OP_FINISH =>
                  op_active <= '0';
                  state     <= IDLE;

            end case;
         end if;
      end if;
   end process;

end architecture;
