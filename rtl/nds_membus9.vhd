-- SPDX-License-Identifier: GPL-2.0-or-later

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity nds_membus9 is
   generic
   (
      is_simu : std_logic := '0'
   );
   port
   (
      clk            : in  std_logic;
      reset          : in  std_logic;

      itcm_ena       : in  std_logic;
      itcm_load      : in  std_logic;
      itcm_size      : in  std_logic_vector(4 downto 0);
      dtcm_ena       : in  std_logic;
      dtcm_load      : in  std_logic;
      dtcm_base      : in  std_logic_vector(31 downto 12);
      dtcm_size      : in  std_logic_vector(4 downto 0);

      bus_cacheable_i : in  std_logic;
      bus_cacheable_d : in  std_logic;
      cache_op_ena    : in  std_logic;
      cache_op        : in  std_logic_vector(3 downto 0);
      cache_op_addr   : in  std_logic_vector(31 downto 0);
      cache_op_busy   : out std_logic;

      dma_bus        : in  std_logic := '0';

      cpu_adr        : in  std_logic_vector(31 downto 0);
      cpu_rnw        : in  std_logic;
      cpu_ena        : in  std_logic;
      cpu_code       : in  std_logic;
      cpu_acc        : in  std_logic_vector(1 downto 0);
      cpu_dout       : in  std_logic_vector(31 downto 0);
      cpu_lowbits    : in  std_logic_vector(1 downto 0);
      cpu_lastread   : in  std_logic_vector(31 downto 0);
      cpu_din        : out std_logic_vector(31 downto 0);
      cpu_done       : out std_logic;

      itcm_addr      : out unsigned(14 downto 2);
      itcm_we        : out std_logic;
      itcm_be        : out std_logic_vector(3 downto 0);
      itcm_writedata : out std_logic_vector(31 downto 0);
      itcm_readdata  : in  std_logic_vector(31 downto 0);

      dtcm_addr        : out unsigned(13 downto 2);
      dtcm_readdata    : in  std_logic_vector(31 downto 0);
      dtcm_addr_b      : out unsigned(13 downto 2) := (others => '0');
      dtcm_we_b        : out std_logic := '0';
      dtcm_be_b        : out std_logic_vector(3 downto 0) := (others => '0');
      dtcm_writedata_b : out std_logic_vector(31 downto 0) := (others => '0');

      brom_addr      : out unsigned(14 downto 2) := (others => '0');
      brom_data      : in  std_logic_vector(31 downto 0);

      wsh_ena        : out std_logic := '0';
      wsh_rnw        : out std_logic := '1';
      wsh_addr       : out unsigned(14 downto 2) := (others => '0');
      wsh_be         : out std_logic_vector(3 downto 0) := (others => '0');
      wsh_din        : out std_logic_vector(31 downto 0) := (others => '0');
      wsh_dout       : in  std_logic_vector(31 downto 0);
      wsh_done       : in  std_logic;
      wsh_mapped     : in  std_logic;

      vram_ena       : out std_logic := '0';
      vram_rnw       : out std_logic := '1';
      vram_addr      : out unsigned(23 downto 2) := (others => '0');
      vram_be        : out std_logic_vector(3 downto 0) := (others => '0');
      vram_din       : out std_logic_vector(31 downto 0) := (others => '0');
      vram_dout      : in  std_logic_vector(31 downto 0);
      vram_done      : in  std_logic;

      pal_we         : out std_logic := '0';
      pal_addr       : out integer range 0 to 511 := 0;
      pal_din        : out std_logic_vector(31 downto 0) := (others => '0');
      pal_be         : out std_logic_vector(3 downto 0) := (others => '0');
      oam_we         : out std_logic := '0';
      oam_addr       : out integer range 0 to 511 := 0;
      oam_din        : out std_logic_vector(31 downto 0) := (others => '0');
      oam_be         : out std_logic_vector(3 downto 0) := (others => '0');

      mr_ena         : out std_logic := '0';
      mr_rnw         : out std_logic := '1';
      mr_addr        : out std_logic_vector(21 downto 2) := (others => '0');
      mr_be          : out std_logic_vector(3 downto 0) := (others => '0');
      mr_writedata   : out std_logic_vector(31 downto 0) := (others => '0');
      mr_done        : in  std_logic;
      mr_readdata    : in  std_logic_vector(31 downto 0);
      mr_pair        : out std_logic := '0';
      mr_readdata_hi : in  std_logic_vector(31 downto 0) := (others => '0');

      io_ce_next     : in  std_logic := '1';
      io_bus         : out proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');
      io_wired_out   : in  std_logic_vector(31 downto 0);
      io_wired_done  : in  std_logic;

      dbg_mb         : out std_logic_vector(7 downto 0) := (others => '0');
      dbg_cache      : out std_logic_vector(7 downto 0) := (others => '0')
   );
end entity;

architecture arch of nds_membus9 is

   type t_target is (T_ITCM, T_DTCM, T_BROM, T_MAIN, T_WRAMSH, T_IO, T_VRAM, T_PAL, T_OAM, T_OPEN);
   type t_state  is (IDLE, FINISH, W_WRAMSH, W_VRAM, W_MAIN, W_IO_ALIGN, W_IO_RESP);

   signal state    : t_state  := IDLE;
   signal target   : t_target := T_OPEN;
   signal r_acc    : std_logic_vector(1 downto 0) := "10";
   signal r_low    : std_logic_vector(1 downto 0) := "00";

   function region_mask (size : std_logic_vector(4 downto 0)) return unsigned is
      variable m : unsigned(32 downto 0) := (others => '0');
   begin
      for i in 0 to 32 loop
         if (i >= 9 + to_integer(unsigned(size))) then
            m(i) := '1';
         end if;
      end loop;
      return m;
   end function;

   signal itcm_size_ovf : std_logic;
   signal dtcm_size_ovf : std_logic;

   signal itcm_hit   : std_logic;
   signal dtcm_hit   : std_logic;
   signal dec_target : t_target;
   signal wdata      : std_logic_vector(31 downto 0);
   signal be         : std_logic_vector(3 downto 0);

   signal accept_now : std_logic;
   signal itcm_sel   : std_logic;
   signal dtcm_sel   : std_logic;

   signal din_unrot  : std_logic_vector(31 downto 0);

   signal dw_pend    : std_logic := '0';
   signal dw_addr    : unsigned(13 downto 2) := (others => '0');
   signal dw_data    : std_logic_vector(31 downto 0) := (others => '0');
   signal dw_be      : std_logic_vector(3 downto 0) := (others => '0');

   signal dwq_pend   : std_logic := '0';
   signal dwq_addr   : unsigned(13 downto 2) := (others => '0');
   signal dwq_data   : std_logic_vector(31 downto 0) := (others => '0');
   signal dwq_be     : std_logic_vector(3 downto 0) := (others => '0');

   signal dr_pend    : std_logic := '0';
   signal dr_addr    : unsigned(13 downto 2) := (others => '0');
   signal dtcm_rd_eff : std_logic_vector(31 downto 0);

   signal creq_ena       : std_logic := '0';
   signal creq_rnw       : std_logic := '1';
   signal creq_code      : std_logic := '0';
   signal creq_cacheable : std_logic := '0';
   signal creq_addr      : std_logic_vector(31 downto 0) := (others => '0');
   signal creq_be        : std_logic_vector(3 downto 0) := (others => '0');
   signal creq_wdata     : std_logic_vector(31 downto 0) := (others => '0');
   signal cresp_done     : std_logic;
   signal cresp_rdata    : std_logic_vector(31 downto 0);

   signal io_rd_hold     : std_logic_vector(31 downto 0) := (others => '0');
   signal io_rd_eff      : std_logic_vector(31 downto 0);

begin

   brom_addr <= unsigned(cpu_adr(14 downto 2));

   icache : entity work.nds_cache9
   generic map
   (
      is_simu => is_simu
   )
   port map
   (
      clk           => clk,
      reset         => reset,
      req_ena       => creq_ena,
      req_rnw       => creq_rnw,
      req_code      => creq_code,
      req_cacheable => creq_cacheable,
      req_addr      => creq_addr,
      req_be        => creq_be,
      req_wdata     => creq_wdata,
      spec_addr     => cpu_adr,
      resp_done     => cresp_done,
      resp_rdata    => cresp_rdata,
      mem_ena       => mr_ena,
      mem_rnw       => mr_rnw,
      mem_addr      => mr_addr,
      mem_be        => mr_be,
      mem_wdata     => mr_writedata,
      mem_done      => mr_done,
      mem_rdata     => mr_readdata,
      mem_pair      => mr_pair,
      mem_rdata_hi  => mr_readdata_hi,
      op_ena        => cache_op_ena,
      op            => cache_op,
      op_addr       => cache_op_addr,
      op_busy       => cache_op_busy,
      dbg_state     => dbg_cache
   );

   dbg_mb <= cpu_ena & accept_now & cresp_done & mr_done & "0" &
             std_logic_vector(to_unsigned(t_state'pos(state), 3));

   accept_now <= '1' when reset = '0' and
                          (state = IDLE or state = FINISH or
                           (state = W_WRAMSH and wsh_done   = '1') or
                           (state = W_VRAM   and vram_done  = '1') or
                           (state = W_MAIN   and cresp_done = '1') or
                           (state = W_IO_RESP and io_wired_done = '1')) else '0';

   itcm_sel       <= accept_now and cpu_ena and itcm_hit;
   itcm_addr      <= unsigned(cpu_adr(14 downto 2));
   itcm_we        <= itcm_sel and not cpu_rnw;
   itcm_be        <= be;
   itcm_writedata <= wdata;

   dtcm_sel       <= accept_now and cpu_ena and dtcm_hit and not itcm_hit;
   dtcm_addr      <= unsigned(cpu_adr(13 downto 2));

   process (clk)
   begin
      if rising_edge(clk) then
         dwq_pend <= dw_pend;
         dwq_addr <= dw_addr;
         dwq_data <= dw_data;
         dwq_be   <= dw_be;

         dw_pend  <= '0';
         dr_pend  <= '0';

         if (reset = '0') then
            dw_addr <= unsigned(cpu_adr(13 downto 2));
            dw_data <= wdata;
            dw_be   <= be;
            dr_addr <= unsigned(cpu_adr(13 downto 2));

            if (dtcm_sel = '1') then
               dw_pend <= not cpu_rnw;
               dr_pend <=     cpu_rnw;
            end if;
         else
            dwq_pend <= '0';
         end if;
      end if;
   end process;

   dtcm_addr_b      <= dw_addr;
   dtcm_we_b        <= dw_pend;
   dtcm_be_b        <= dw_be;
   dtcm_writedata_b <= dw_data;

   process (all)
   begin
      dtcm_rd_eff <= dtcm_readdata;
      if (dr_pend = '1' and dwq_pend = '1' and dwq_addr = dr_addr) then
         for i in 0 to 3 loop
            if (dwq_be(i) = '1') then
               dtcm_rd_eff(8*i + 7 downto 8*i) <= dwq_data(8*i + 7 downto 8*i);
            end if;
         end loop;
      end if;
   end process;

   itcm_size_ovf <= '1' when (unsigned(itcm_size) > 23) else '0';
   dtcm_size_ovf <= '1' when (unsigned(dtcm_size) > 23) else '0';

   process (all)
      variable a         : unsigned(32 downto 0);
      variable itcm_mask : unsigned(32 downto 0);
      variable dtcm_mask : unsigned(32 downto 0);
      variable dtcm_lo   : unsigned(32 downto 0);
   begin
      a := unsigned('0' & cpu_adr);

      itcm_mask := region_mask(itcm_size);
      itcm_hit  <= '0';
      if (itcm_ena = '1' and itcm_size_ovf = '0' and (a and itcm_mask) = 0 and dma_bus = '0') then
         if (cpu_rnw = '0' or itcm_load = '0') then
            itcm_hit <= '1';
         end if;
      end if;

      dtcm_mask := region_mask(dtcm_size);
      dtcm_lo   := unsigned('0' & dtcm_base & x"000") and dtcm_mask;
      dtcm_hit  <= '0';
      if (dtcm_ena = '1' and cpu_code = '0' and dtcm_size_ovf = '0' and
          ((a xor dtcm_lo) and dtcm_mask) = 0 and dma_bus = '0') then
         if (cpu_rnw = '0' or dtcm_load = '0') then
            dtcm_hit <= '1';
         end if;
      end if;
   end process;

   process (all)
   begin
      dec_target <= T_OPEN;
      if (itcm_hit = '1') then
         dec_target <= T_ITCM;
      elsif (dtcm_hit = '1') then
         dec_target <= T_DTCM;
      elsif (cpu_adr(31 downto 16) = x"FFFF" and cpu_adr(15) = '0') then
         dec_target <= T_BROM;
      elsif (cpu_adr(31 downto 28) = x"0") then
         case cpu_adr(27 downto 24) is
            when x"2" => dec_target <= T_MAIN;
            when x"3" =>
               if (wsh_mapped = '1') then
                  dec_target <= T_WRAMSH;
               end if;
            when x"4" =>
               if (cpu_adr(23) = '0') then
                  dec_target <= T_IO;
               end if;
            when x"5" => dec_target <= T_PAL;
            when x"6" => dec_target <= T_VRAM;
            when x"7" => dec_target <= T_OAM;
            when others => null;
         end case;
      end if;
   end process;

   process (all)
   begin
      wdata <= cpu_dout;
      if (cpu_acc = ACCESS_8BIT) then
         case (cpu_adr(1 downto 0)) is
            when "00" => wdata( 7 downto  0) <= cpu_dout(7 downto 0);
            when "01" => wdata(15 downto  8) <= cpu_dout(7 downto 0);
            when "10" => wdata(23 downto 16) <= cpu_dout(7 downto 0);
            when "11" => wdata(31 downto 24) <= cpu_dout(7 downto 0);
            when others => null;
         end case;
      elsif (cpu_acc = ACCESS_16BIT and cpu_adr(1) = '1') then
         wdata(31 downto 16) <= cpu_dout(15 downto 0);
      end if;

      be <= "1111";
      case (cpu_acc) is
         when ACCESS_8BIT =>
            case (cpu_adr(1 downto 0)) is
               when "00" => be <= "0001";
               when "01" => be <= "0010";
               when "10" => be <= "0100";
               when "11" => be <= "1000";
               when others => null;
            end case;
         when ACCESS_16BIT =>
            if (cpu_adr(1) = '1') then be <= "1100"; else be <= "0011"; end if;
         when others => null;
      end case;
   end process;

   process (clk)
      variable can_accept : boolean;
   begin
      if rising_edge(clk) then

         wsh_ena  <= '0';
         vram_ena <= '0';
         creq_ena <= '0';
         pal_we   <= '0';
         oam_we   <= '0';
         io_bus.ena <= '0';
         io_bus.rst <= reset;

         if (reset = '1') then
            state <= IDLE;
         else
            can_accept := (accept_now = '1');

            if (state = W_IO_ALIGN) then
               if (io_ce_next = '1') then
                  io_bus.ena <= '1';
                  state      <= W_IO_RESP;
               end if;
            elsif can_accept then
               state <= IDLE;
               if (cpu_ena = '1') then
                  target <= dec_target;
                  r_acc  <= cpu_acc;
                  r_low  <= cpu_adr(1 downto 0);

                  case dec_target is

                     when T_ITCM =>
                        state <= FINISH;

                     when T_DTCM =>
                        state <= FINISH;

                     when T_BROM =>
                        state     <= FINISH;

                     when T_WRAMSH =>
                        wsh_ena  <= '1';
                        wsh_rnw  <= cpu_rnw;
                        wsh_addr <= unsigned(cpu_adr(14 downto 2));
                        wsh_be   <= be;
                        wsh_din  <= wdata;
                        state    <= W_WRAMSH;

                     when T_VRAM =>
                        vram_ena  <= '1';
                        vram_rnw  <= cpu_rnw;
                        vram_addr <= unsigned(cpu_adr(23 downto 2));
                        vram_be   <= be;
                        vram_din  <= wdata;
                        state     <= W_VRAM;

                     when T_PAL =>
                        if (cpu_rnw = '0') then
                           pal_we   <= '1';
                           pal_addr <= to_integer(unsigned(cpu_adr(10 downto 2)));
                           pal_be   <= be;
                           pal_din  <= wdata;
                        end if;
                        state <= FINISH;

                     when T_OAM =>
                        if (cpu_rnw = '0') then
                           oam_we   <= '1';
                           oam_addr <= to_integer(unsigned(cpu_adr(10 downto 2)));
                           oam_be   <= be;
                           oam_din  <= wdata;
                        end if;
                        state <= FINISH;

                     when T_MAIN =>
                        creq_ena   <= '1';
                        creq_rnw   <= cpu_rnw;
                        creq_code  <= cpu_code;
                        creq_addr  <= cpu_adr;
                        creq_be    <= be;
                        creq_wdata <= wdata;
                        if (dma_bus = '1') then
                           creq_cacheable <= '0';
                        elsif (cpu_code = '1') then
                           creq_cacheable <= bus_cacheable_i;
                        else
                           creq_cacheable <= bus_cacheable_d;
                        end if;
                        state <= W_MAIN;

                     when T_IO =>
                        io_bus.rnw  <= cpu_rnw;
                        io_bus.Adr  <= x"0" & cpu_adr(23 downto 2) & "00";
                        io_bus.acc  <= cpu_acc;
                        io_bus.Din  <= wdata;
                        io_bus.bEna <= be;
                        if (io_ce_next = '1') then
                           io_bus.ena <= '1';
                           state      <= W_IO_RESP;
                        else
                           state <= W_IO_ALIGN;
                        end if;

                     when T_OPEN =>
                        state <= FINISH;

                  end case;
               end if;
            end if;
         end if;
      end if;
   end process;

   cpu_done <= '1'            when state = FINISH    else
               wsh_done       when state = W_WRAMSH  else
               vram_done      when state = W_VRAM    else
               cresp_done     when state = W_MAIN    else
               io_wired_done  when state = W_IO_RESP else '0';

   din_unrot <= itcm_readdata when target = T_ITCM   else
                dtcm_rd_eff   when target = T_DTCM   else
                brom_data     when target = T_BROM   else
                wsh_dout      when target = T_WRAMSH else
                vram_dout     when target = T_VRAM   else
                x"00000000"   when (target = T_PAL or target = T_OAM) else
                cresp_rdata   when target = T_MAIN   else
                io_rd_eff     when target = T_IO     else
                cpu_lastread;

   io_rd_eff <= io_wired_out when io_wired_done = '1' else io_rd_hold;

   process (clk)
   begin
      if rising_edge(clk) then
         if (io_wired_done = '1') then
            io_rd_hold <= io_wired_out;
         end if;
      end if;
   end process;

   process (all)
   begin
      cpu_din <= (others => '0');
      if (r_acc = ACCESS_8BIT) then
         case (r_low) is
            when "00" => cpu_din <= x"000000" & din_unrot(7 downto 0);
            when "01" => cpu_din <= x"000000" & din_unrot(15 downto 8);
            when "10" => cpu_din <= x"000000" & din_unrot(23 downto 16);
            when "11" => cpu_din <= x"000000" & din_unrot(31 downto 24);
            when others => null;
         end case;
      elsif (r_acc = ACCESS_16BIT) then
         case (r_low) is
            when "00" => cpu_din <= x"0000" & din_unrot(15 downto 0);
            when "01" => cpu_din <= din_unrot(7 downto 0) & x"0000" & din_unrot(15 downto 8);
            when "10" => cpu_din <= x"0000" & din_unrot(31 downto 16);
            when "11" => cpu_din <= din_unrot(23 downto 16) & x"0000" & din_unrot(31 downto 24);
            when others => null;
         end case;
      else
         case (r_low) is
            when "00" => cpu_din <= din_unrot;
            when "01" => cpu_din <= din_unrot(7 downto 0) & din_unrot(31 downto 8);
            when "10" => cpu_din <= din_unrot(15 downto 0) & din_unrot(31 downto 16);
            when "11" => cpu_din <= din_unrot(23 downto 0) & din_unrot(31 downto 24);
            when others => null;
         end case;
      end if;
   end process;

end architecture;
