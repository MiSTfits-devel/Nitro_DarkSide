-- SPDX-License-Identifier: GPL-2.0-or-later
-- ARM9 memory bus decoder. Same request/done idiom as nds_membus7 (accepts a
-- new CPU request on every completing cycle), plus the ARM946E-S TCM overlay:
--
--   ITCM: physical 32 KB mirrored through [0, 512B << cp15_itcm_size), takes
--         priority over everything; in load mode writes hit the TCM while
--         reads fall through to the external map
--   DTCM: physical 16 KB mirrored through [base, base + 512B << size); data
--         accesses only (never instruction fetches), below ITCM priority
--
--   external map: 0x02 main RAM, 0x03 shared WRAM, 0x04 IO proc-bus,
--   0x06 VRAM (cpu9 port), 0xFFFF0000 boot ROM (32 KB, read-only).
--   Unmapped: open bus (CPU lastread).
--
-- The TCM and boot-ROM backing stores are external ports (combinational read,
-- clocked write) so the island testbench can own them; the synthesizable core
-- will move them into BRAM primitives later.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity nds_membus9 is
   port
   (
      clk            : in  std_logic;
      reset          : in  std_logic;

      -- CP15 configuration (from nds_cpu9)
      itcm_ena       : in  std_logic;
      itcm_load      : in  std_logic;
      itcm_size      : in  std_logic_vector(4 downto 0);
      dtcm_ena       : in  std_logic;
      dtcm_load      : in  std_logic;
      dtcm_base      : in  std_logic_vector(31 downto 12);
      dtcm_size      : in  std_logic_vector(4 downto 0);

      -- cache attributes of the current address + maintenance (from nds_cpu9)
      bus_cacheable_i : in  std_logic;
      bus_cacheable_d : in  std_logic;
      cache_op_ena    : in  std_logic;
      cache_op        : in  std_logic_vector(3 downto 0);
      cache_op_addr   : in  std_logic_vector(31 downto 0);
      cache_op_busy   : out std_logic;

      -- gba_cpu-style bus
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

      -- ITCM store (32 KB)
      itcm_addr      : out unsigned(14 downto 2) := (others => '0');
      itcm_we        : out std_logic := '0';
      itcm_be        : out std_logic_vector(3 downto 0) := (others => '0');
      itcm_writedata : out std_logic_vector(31 downto 0) := (others => '0');
      itcm_readdata  : in  std_logic_vector(31 downto 0);

      -- DTCM store (16 KB)
      dtcm_addr      : out unsigned(13 downto 2) := (others => '0');
      dtcm_we        : out std_logic := '0';
      dtcm_be        : out std_logic_vector(3 downto 0) := (others => '0');
      dtcm_writedata : out std_logic_vector(31 downto 0) := (others => '0');
      dtcm_readdata  : in  std_logic_vector(31 downto 0);

      -- boot ROM store (32 KB at 0xFFFF0000, read-only)
      brom_addr      : out unsigned(14 downto 2) := (others => '0');
      brom_data      : in  std_logic_vector(31 downto 0);

      -- shared WRAM (nds_wram arm9 port)
      wsh_ena        : out std_logic := '0';
      wsh_rnw        : out std_logic := '1';
      wsh_addr       : out unsigned(14 downto 2) := (others => '0');
      wsh_be         : out std_logic_vector(3 downto 0) := (others => '0');
      wsh_din        : out std_logic_vector(31 downto 0) := (others => '0');
      wsh_dout       : in  std_logic_vector(31 downto 0);
      wsh_done       : in  std_logic;
      wsh_mapped     : in  std_logic;

      -- VRAM (nds_vram cpu9 port)
      vram_ena       : out std_logic := '0';
      vram_rnw       : out std_logic := '1';
      vram_addr      : out unsigned(23 downto 2) := (others => '0');
      vram_be        : out std_logic_vector(3 downto 0) := (others => '0');
      vram_din       : out std_logic_vector(31 downto 0) := (others => '0');
      vram_dout      : in  std_logic_vector(31 downto 0);
      vram_done      : in  std_logic;

      -- main RAM (nds_mainram mem9 port)
      mr_ena         : out std_logic := '0';
      mr_rnw         : out std_logic := '1';
      mr_addr        : out std_logic_vector(21 downto 2) := (others => '0');
      mr_be          : out std_logic_vector(3 downto 0) := (others => '0');
      mr_writedata   : out std_logic_vector(31 downto 0) := (others => '0');
      mr_done        : in  std_logic;
      mr_readdata    : in  std_logic_vector(31 downto 0);

      -- IO register bus. The peripherals may live in a slower ce domain
      -- (33 MHz vs the 66 MHz ARM9): io_ce_next is the value their ce will
      -- have in the NEXT cycle - the 1-cycle io_bus.ena pulse is only issued
      -- when it will land on an active peripheral cycle. Tie to '1' when the
      -- peripherals run at full rate.
      io_ce_next     : in  std_logic := '1';
      io_bus         : out proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');
      io_wired_out   : in  std_logic_vector(31 downto 0);
      io_wired_done  : in  std_logic
   );
end entity;

architecture arch of nds_membus9 is

   type t_target is (T_ITCM, T_DTCM, T_BROM, T_MAIN, T_WRAMSH, T_IO, T_VRAM, T_OPEN);
   type t_state  is (IDLE, FINISH, W_WRAMSH, W_VRAM, W_MAIN, W_IO_ALIGN);

   signal state    : t_state  := IDLE;
   signal target   : t_target := T_OPEN;
   signal r_acc    : std_logic_vector(1 downto 0) := "10";
   signal r_low    : std_logic_vector(1 downto 0) := "00";

   signal itcm_hit   : std_logic;
   signal dtcm_hit   : std_logic;
   signal dec_target : t_target;
   signal wdata      : std_logic_vector(31 downto 0);
   signal be         : std_logic_vector(3 downto 0);

   signal din_unrot  : std_logic_vector(31 downto 0);

   -- cache <-> CPU-request side (main RAM only; the cache owns the mr_* port)
   signal creq_ena       : std_logic := '0';
   signal creq_rnw       : std_logic := '1';
   signal creq_code      : std_logic := '0';
   signal creq_cacheable : std_logic := '0';
   signal creq_addr      : std_logic_vector(31 downto 0) := (others => '0');
   signal creq_be        : std_logic_vector(3 downto 0) := (others => '0');
   signal creq_wdata     : std_logic_vector(31 downto 0) := (others => '0');
   signal cresp_done     : std_logic;
   signal cresp_rdata    : std_logic_vector(31 downto 0);

begin

   icache : entity work.nds_cache9
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
      resp_done     => cresp_done,
      resp_rdata    => cresp_rdata,
      mem_ena       => mr_ena,
      mem_rnw       => mr_rnw,
      mem_addr      => mr_addr,
      mem_be        => mr_be,
      mem_wdata     => mr_writedata,
      mem_done      => mr_done,
      mem_rdata     => mr_readdata,
      op_ena        => cache_op_ena,
      op            => cache_op,
      op_addr       => cache_op_addr,
      op_busy       => cache_op_busy
   );

   -- ================= TCM decode =================
   process (all)
      variable a          : unsigned(32 downto 0);
      variable itcm_limit : unsigned(32 downto 0);
      variable dtcm_lo    : unsigned(32 downto 0);
      variable dtcm_hi    : unsigned(32 downto 0);
   begin
      a := unsigned('0' & cpu_adr);

      itcm_limit := shift_left(to_unsigned(512, 33), to_integer(unsigned(itcm_size)));
      itcm_hit   <= '0';
      if (itcm_ena = '1' and a < itcm_limit) then
         -- load mode: writes land in the TCM, reads see the external map
         if (cpu_rnw = '0' or itcm_load = '0') then
            itcm_hit <= '1';
         end if;
      end if;

      dtcm_lo  := unsigned('0' & dtcm_base & x"000");
      dtcm_hi  := dtcm_lo + shift_left(to_unsigned(512, 33), to_integer(unsigned(dtcm_size)));
      dtcm_hit <= '0';
      if (dtcm_ena = '1' and cpu_code = '0' and a >= dtcm_lo and a < dtcm_hi) then
         if (cpu_rnw = '0' or dtcm_load = '0') then
            dtcm_hit <= '1';
         end if;
      end if;
   end process;

   -- ================= region decode =================
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
                  dec_target <= T_WRAMSH; -- unmapped shared WRAM: ARM9 sees open bus
               end if;
            when x"4" =>
               if (cpu_adr(23) = '0') then
                  dec_target <= T_IO;
               end if;
            when x"6" => dec_target <= T_VRAM;
            when others => null;
         end case;
      end if;
   end process;

   -- ================= write lane placement (gba_mem_writerotate) =================
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

   -- ================= request FSM =================
   process (clk)
      variable can_accept : boolean;
   begin
      if rising_edge(clk) then

         wsh_ena  <= '0';
         vram_ena <= '0';
         creq_ena <= '0';
         itcm_we  <= '0';
         dtcm_we  <= '0';
         io_bus.ena <= '0';
         io_bus.rst <= reset;

         if (reset = '1') then
            state <= IDLE;
         else
            case state is
               when IDLE       => can_accept := true;
               when FINISH     => can_accept := true;
               when W_WRAMSH   => can_accept := (wsh_done  = '1');
               when W_VRAM     => can_accept := (vram_done = '1');
               when W_MAIN     => can_accept := (cresp_done = '1');
               when W_IO_ALIGN => can_accept := false;
            end case;

            if (state = W_IO_ALIGN) then
               if (io_ce_next = '1') then
                  io_bus.ena <= '1';
                  state      <= FINISH;
               end if;
            elsif can_accept then
               state <= IDLE;
               if (cpu_ena = '1') then
                  target <= dec_target;
                  r_acc  <= cpu_acc;
                  r_low  <= cpu_adr(1 downto 0);

                  case dec_target is

                     when T_ITCM =>
                        itcm_addr <= unsigned(cpu_adr(14 downto 2));
                        if (cpu_rnw = '0') then
                           itcm_we        <= '1';
                           itcm_be        <= be;
                           itcm_writedata <= wdata;
                        end if;
                        state <= FINISH;

                     when T_DTCM =>
                        dtcm_addr <= unsigned(cpu_adr(13 downto 2));
                        if (cpu_rnw = '0') then
                           dtcm_we        <= '1';
                           dtcm_be        <= be;
                           dtcm_writedata <= wdata;
                        end if;
                        state <= FINISH;

                     when T_BROM =>
                        brom_addr <= unsigned(cpu_adr(14 downto 2));
                        state     <= FINISH; -- writes are no-ops

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

                     when T_MAIN =>
                        creq_ena   <= '1';
                        creq_rnw   <= cpu_rnw;
                        creq_code  <= cpu_code;
                        creq_addr  <= cpu_adr;
                        creq_be    <= be;
                        creq_wdata <= wdata;
                        if (cpu_code = '1') then
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
                           state      <= FINISH;
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

   cpu_done <= '1'        when state = FINISH   else
               wsh_done   when state = W_WRAMSH else
               vram_done  when state = W_VRAM   else
               cresp_done when state = W_MAIN   else '0';

   -- ================= read data mux + rotation (gba_mem_readrotate) =================
   din_unrot <= itcm_readdata when target = T_ITCM   else
                dtcm_readdata when target = T_DTCM   else
                brom_data     when target = T_BROM   else
                wsh_dout      when target = T_WRAMSH else
                vram_dout     when target = T_VRAM   else
                cresp_rdata   when target = T_MAIN   else
                io_wired_out  when (target = T_IO and io_wired_done = '1') else
                cpu_lastread;

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
