-- SPDX-License-Identifier: GPL-2.0-or-later

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nds_mainram is
   generic
   (
      Softmap_NDS_MAINRAM_ADDR : integer
   );
   port
   (
      clk1x            : in  std_logic;
      clkMem           : in  std_logic;
      clkMemIndex      : in  unsigned(1 downto 0);
      reset            : in  std_logic;

      arm7_priority    : in  std_logic;

      mem9_ena         : in  std_logic;
      mem9_lock        : in  std_logic := '0';
      mem9_rnw         : in  std_logic;
      mem9_addr        : in  std_logic_vector(21 downto 2);
      mem9_be          : in  std_logic_vector(3 downto 0);
      mem9_writedata   : in  std_logic_vector(31 downto 0);
      mem9_pair        : in  std_logic := '0';
      mem9_done        : out std_logic := '0';
      mem9_readdata    : out std_logic_vector(31 downto 0) := (others => '0');
      mem9_readdata_hi : out std_logic_vector(31 downto 0) := (others => '0');

      mem7_ena         : in  std_logic;
      mem7_lock        : in  std_logic := '0';
      mem7_rnw         : in  std_logic;
      mem7_addr        : in  std_logic_vector(21 downto 2);
      mem7_be          : in  std_logic_vector(3 downto 0);
      mem7_writedata   : in  std_logic_vector(31 downto 0);
      mem7_done        : out std_logic := '0';
      mem7_readdata    : out std_logic_vector(31 downto 0) := (others => '0');

      mainram_allow    : in  std_logic;
      mainram_active   : out std_logic;
      mainram_busy     : out std_logic;

      mr_sdram_ena     : out std_logic := '0';
      mr_sdram_rnw     : out std_logic := '0';
      mr_sdram_Adr     : out std_logic_vector(26 downto 0) := (others => '0');
      mr_sdram_Din     : out std_logic_vector(31 downto 0) := (others => '0');
      mr_sdram_be      : out std_logic_vector(3 downto 0) := (others => '1');
      sdram_Dout       : in  std_logic_vector(31 downto 0);
      sdram_done32     : in  std_logic;
      sdram_Dout_hi    : in  std_logic_vector(31 downto 0) := (others => '0');
      sdram_done64     : in  std_logic := '0';

      dbg_mr           : out std_logic_vector(7 downto 0) := (others => '0')
   );
end entity;

architecture arch of nds_mainram is

   type tState is
   (
      MR_IDLE,
      MR_LOCKWAIT,
      MR_WAIT,
      MR_DONE
   );
   signal state         : tState := MR_IDLE;
   signal serving7      : std_logic := '0';
   signal lock_pair     : std_logic := '0';
   signal lock_second   : std_logic := '0';

   signal req9_pending  : std_logic := '0';
   signal req9_pair     : std_logic := '0';
   signal serving_pair  : std_logic := '0';
   signal saw_done32    : std_logic := '0';
   signal req9_lock     : std_logic := '0';
   signal req9_rnw      : std_logic := '0';
   signal req9_addr     : std_logic_vector(21 downto 2) := (others => '0');
   signal req9_be       : std_logic_vector(3 downto 0)  := (others => '0');
   signal req9_din      : std_logic_vector(31 downto 0) := (others => '0');

   signal req7_pending  : std_logic := '0';
   signal req7_lock     : std_logic := '0';
   signal req7_rnw      : std_logic := '0';
   signal req7_addr     : std_logic_vector(21 downto 2) := (others => '0');
   signal req7_be       : std_logic_vector(3 downto 0)  := (others => '0');
   signal req7_din      : std_logic_vector(31 downto 0) := (others => '0');

   signal done9_6x      : std_logic := '0';
   signal done7_6x      : std_logic := '0';
   signal readdata_6x   : std_logic_vector(31 downto 0) := (others => '0');
   signal readdata_hi_6x : std_logic_vector(31 downto 0) := (others => '0');

begin

   mainram_active <= req9_pending or req7_pending or lock_pair;
   mainram_busy   <= '1' when (state /= MR_IDLE) else '0';

   dbg_mr <= mainram_allow & lock_pair & serving7 & req7_pending & req9_pending &
             "0" & std_logic_vector(to_unsigned(tState'pos(state), 2));

   process (clk1x)
   begin
      if rising_edge(clk1x) then

         mem9_done <= '0';
         mem7_done <= '0';

         if (reset = '1') then
            req9_pending <= '0';
            req7_pending <= '0';
            req9_lock    <= '0';
            req7_lock    <= '0';
         else

            if (mem9_ena = '1') then
               req9_pending <= '1';
               req9_lock    <= mem9_lock;
               req9_rnw     <= mem9_rnw;
               req9_addr    <= mem9_addr;
               req9_be      <= mem9_be;
               req9_din     <= mem9_writedata;
               req9_pair    <= mem9_pair and mem9_rnw;
            elsif (req9_pending = '1' and done9_6x = '1') then
               req9_pending  <= '0';
               mem9_done     <= '1';
               mem9_readdata <= readdata_6x;
               mem9_readdata_hi <= readdata_hi_6x;
            end if;

            if (mem7_ena = '1') then
               req7_pending <= '1';
               req7_lock    <= mem7_lock;
               req7_rnw     <= mem7_rnw;
               req7_addr    <= mem7_addr;
               req7_be      <= mem7_be;
               req7_din     <= mem7_writedata;
            elsif (req7_pending = '1' and done7_6x = '1') then
               req7_pending  <= '0';
               mem7_done     <= '1';
               mem7_readdata <= readdata_6x;
            end if;

         end if;
      end if;
   end process;

   process (clkMem)
      variable pick7 : std_logic;
   begin
      if rising_edge(clkMem) then

         mr_sdram_ena <= '0';

         case (state) is

            when MR_IDLE =>
               done9_6x <= '0';
               done7_6x <= '0';
               lock_pair   <= '0';
               lock_second <= '0';
               if (reset = '0' and (req9_pending = '1' or req7_pending = '1') and
                   clkMemIndex = 0 and mainram_allow = '1' and
                   done9_6x = '0' and done7_6x = '0') then

                  if (req9_pending = '1' and req7_pending = '1') then
                     pick7 := arm7_priority;
                  elsif (req7_pending = '1') then
                     pick7 := '1';
                  else
                     pick7 := '0';
                  end if;

                  serving7     <= pick7;
                  serving_pair <= (not pick7) and req9_pair and (not req9_lock);
                  saw_done32   <= '0';
                  if ((pick7 = '1' and req7_lock = '1') or
                      (pick7 = '0' and req9_lock = '1')) then
                     lock_pair <= '1';
                  end if;
                  mr_sdram_ena <= '1';
                  if (pick7 = '1') then
                     mr_sdram_rnw <= req7_rnw;
                     mr_sdram_Adr <= std_logic_vector(to_unsigned(Softmap_NDS_MAINRAM_ADDR, 27) + (unsigned(req7_addr) & "00"));
                     mr_sdram_Din <= req7_din;
                     mr_sdram_be  <= req7_be;
                  else
                     mr_sdram_rnw <= req9_rnw;
                     mr_sdram_Adr <= std_logic_vector(to_unsigned(Softmap_NDS_MAINRAM_ADDR, 27) + (unsigned(req9_addr) & "00"));
                     mr_sdram_Din <= req9_din;
                     mr_sdram_be  <= req9_be;
                  end if;
                  state <= MR_WAIT;
               end if;

            when MR_LOCKWAIT =>
               if (reset = '1') then
                  lock_pair   <= '0';
                  lock_second <= '0';
                  state       <= MR_IDLE;
               elsif (clkMemIndex = 0 and
                      ((serving7 = '1' and req7_pending = '1') or
                       (serving7 = '0' and req9_pending = '1'))) then
                  mr_sdram_ena <= '1';
                  if (serving7 = '1') then
                     mr_sdram_rnw <= req7_rnw;
                     mr_sdram_Adr <= std_logic_vector(to_unsigned(Softmap_NDS_MAINRAM_ADDR, 27) + (unsigned(req7_addr) & "00"));
                     mr_sdram_Din <= req7_din;
                     mr_sdram_be  <= req7_be;
                  else
                     mr_sdram_rnw <= req9_rnw;
                     mr_sdram_Adr <= std_logic_vector(to_unsigned(Softmap_NDS_MAINRAM_ADDR, 27) + (unsigned(req9_addr) & "00"));
                     mr_sdram_Din <= req9_din;
                     mr_sdram_be  <= req9_be;
                  end if;
                  state <= MR_WAIT;
               end if;

            when MR_WAIT =>
               if (sdram_done32 = '1') then
                  saw_done32 <= '1';
               end if;
               if ((serving_pair = '0' and sdram_done32 = '1') or
                   (serving_pair = '1' and sdram_done64 = '1' and
                    (saw_done32 = '1' or sdram_done32 = '1'))) then
                  readdata_6x    <= sdram_Dout;
                  readdata_hi_6x <= sdram_Dout_hi;
                  if (reset = '1') then
                     lock_pair   <= '0';
                     lock_second <= '0';
                     state <= MR_IDLE;
                  else
                     if (serving7 = '1') then
                        done7_6x <= '1';
                     else
                        done9_6x <= '1';
                     end if;
                     state <= MR_DONE;
                  end if;
               end if;

            when MR_DONE =>
               if (reset = '1') then
                  lock_pair   <= '0';
                  lock_second <= '0';
                  state <= MR_IDLE;
               elsif (serving7 = '1' and req7_pending = '0') then
                  done7_6x <= '0';
                  if (lock_pair = '1' and lock_second = '0') then
                     lock_second <= '1';
                     state       <= MR_LOCKWAIT;
                  else
                     lock_pair   <= '0';
                     lock_second <= '0';
                     state       <= MR_IDLE;
                  end if;
               elsif (serving7 = '0' and req9_pending = '0') then
                  done9_6x <= '0';
                  if (lock_pair = '1' and lock_second = '0') then
                     lock_second <= '1';
                     state       <= MR_LOCKWAIT;
                  else
                     lock_pair   <= '0';
                     lock_second <= '0';
                     state       <= MR_IDLE;
                  end if;
               end if;

         end case;

      end if;
   end process;

end architecture;
