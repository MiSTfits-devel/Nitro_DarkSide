-- SPDX-License-Identifier: GPL-2.0-or-later
-- Card-header HLE loader (M4). The .nds image is pre-staged in SDRAM (on
-- MiSTer the HPS puts it there; in sim the testbench preloads the model).
-- On start it parses the header:
--
--   +0x20 ARM9 rom offset   +0x24 ARM9 entry   +0x28 ARM9 load addr  +0x2C size
--   +0x30 ARM7 rom offset   +0x34 ARM7 entry   +0x38 ARM7 load addr  +0x3C size
--
-- then copies both sections word-by-word from the card image to their load
-- addresses and reports the entry points. The write port carries full 32-bit
-- CPU addresses - the integration routes main RAM (0x02xxxxxx) and ARM7 WRAM
-- (0x037xxxxx) targets; anything else is an error (secure-area/ITCM-loading
-- images are out of scope until real card emulation).
--
-- The CPUs are expected to be held in reset while busy='1'; the testbench
-- (and later nds_top) presets their boot PCs from arm9_entry/arm7_entry
-- through the savestate buses before releasing them.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nds_loader is
   port
   (
      clk         : in  std_logic;
      reset       : in  std_logic;
      start       : in  std_logic;                     -- one-cycle pulse
      busy        : out std_logic := '0';
      done        : out std_logic := '0';              -- level, stays high
      load_error  : out std_logic := '0';

      arm9_entry  : out std_logic_vector(31 downto 0) := (others => '0');
      arm7_entry  : out std_logic_vector(31 downto 0) := (others => '0');

      -- card image read port (word addressed into the staged .nds)
      card_ena    : out std_logic := '0';
      card_addr   : out std_logic_vector(26 downto 2) := (others => '0');
      card_done   : in  std_logic;
      card_rdata  : in  std_logic_vector(31 downto 0);

      -- destination write port (full CPU byte address, word writes)
      wr_ena      : out std_logic := '0';
      wr_addr     : out std_logic_vector(31 downto 0) := (others => '0');
      wr_data     : out std_logic_vector(31 downto 0) := (others => '0');
      wr_done     : in  std_logic
   );
end entity;

architecture arch of nds_loader is

   type t_state is
   (
      IDLE,
      HDR_REQ, HDR_WAIT,     -- read the 8 header words at 0x20..0x3C
      CP_RD, CP_RD_WAIT,     -- copy loop: card read ...
      CP_WR, CP_WR_WAIT,     -- ... destination write
      NEXT_CPU,
      FINISHED
   );
   signal state : t_state := IDLE;

   type t_hdr is array (0 to 7) of std_logic_vector(31 downto 0);
   signal hdr     : t_hdr := (others => (others => '0'));
   signal hdr_i   : integer range 0 to 8 := 0;

   signal cpu_sel : integer range 0 to 1 := 0;         -- 0 = ARM9, 1 = ARM7
   signal src     : unsigned(26 downto 2) := (others => '0');
   signal dst     : unsigned(31 downto 0) := (others => '0');
   signal words   : unsigned(21 downto 0) := (others => '0');

begin

   process (clk)
      variable romoff, loadaddr, size : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk) then

         card_ena <= '0';
         wr_ena   <= '0';

         if (reset = '1') then
            state      <= IDLE;
            busy       <= '0';
            done       <= '0';
            load_error <= '0';
         else
            case state is

               when IDLE =>
                  if (start = '1') then
                     busy  <= '1';
                     done  <= '0';
                     hdr_i <= 0;
                     state <= HDR_REQ;
                  end if;

               when HDR_REQ =>
                  card_ena  <= '1';
                  card_addr <= std_logic_vector(to_unsigned(8 + hdr_i, 25)); -- word 8 = byte 0x20
                  state     <= HDR_WAIT;

               when HDR_WAIT =>
                  if (card_done = '1') then
                     hdr(hdr_i) <= card_rdata;
                     if (hdr_i = 7) then
                        cpu_sel <= 0;
                        state   <= NEXT_CPU;
                     else
                        hdr_i <= hdr_i + 1;
                        state <= HDR_REQ;
                     end if;
                  end if;

               when NEXT_CPU =>
                  romoff   := hdr(cpu_sel*4 + 0);
                  loadaddr := hdr(cpu_sel*4 + 2);
                  size     := hdr(cpu_sel*4 + 3);
                  arm9_entry <= hdr(1) and x"FFFFFFFE";
                  arm7_entry <= hdr(5) and x"FFFFFFFE";
                  if (loadaddr(31 downto 24) /= x"02" and loadaddr(31 downto 20) /= x"037") then
                     load_error <= '1';
                     busy       <= '0';
                     state      <= FINISHED;
                  else
                     src <= unsigned(romoff(26 downto 2));
                     dst <= unsigned(loadaddr);
                     if (size(1 downto 0) = "00") then
                        words <= unsigned(size(23 downto 2));
                     else
                        words <= unsigned(size(23 downto 2)) + 1;
                     end if;
                     state <= CP_RD;
                  end if;

               when CP_RD =>
                  if (words = 0) then
                     if (cpu_sel = 0) then
                        cpu_sel <= 1;
                        state   <= NEXT_CPU;
                     else
                        busy  <= '0';
                        done  <= '1';
                        state <= FINISHED;
                     end if;
                  else
                     card_ena  <= '1';
                     card_addr <= std_logic_vector(src);
                     state     <= CP_RD_WAIT;
                  end if;

               when CP_RD_WAIT =>
                  if (card_done = '1') then
                     wr_data <= card_rdata;
                     state   <= CP_WR;
                  end if;

               when CP_WR =>
                  wr_ena  <= '1';
                  wr_addr <= std_logic_vector(dst);
                  state   <= CP_WR_WAIT;

               when CP_WR_WAIT =>
                  if (wr_done = '1') then
                     src   <= src + 1;
                     dst   <= dst + 4;
                     words <= words - 1;
                     state <= CP_RD;
                  end if;

               when FINISHED =>
                  null;

            end case;
         end if;
      end if;
   end process;

end architecture;
