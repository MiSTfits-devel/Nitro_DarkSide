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
-- direct='1' additionally synthesizes the firmware direct-boot environment
-- (M7, spec = melonDS SetupDirectBoot; calico's bootstubs do their own CP15
-- and stack setup so only the memory image matters):
--   0x02FFFE00  header copy (0x170 bytes from card offset 0)
--   0x02FFF800/C00 blocks: chip ID x2 (melonDS size formula), header +
--     secure-area CRC16 (read from the header itself), boot flags,
--     user-settings mirror words for melonDS's generated default firmware
--   0x02FFFC80  0x70-byte default user settings (version 5, all defaults)
-- The integration also presets WRAMCNT=3, POSTFLG=1, POWCNT1=0x820F when
-- direct (nds_syscnt preset_direct) - firmware leaves them that way.
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
      direct      : in  std_logic := '0';              -- synth direct-boot env
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
      ENV_SET, ENV_WR, ENV_WR_WAIT,   -- direct-boot env table
      FINISHED
   );
   signal state : t_state := IDLE;

   type t_hdr is array (0 to 7) of std_logic_vector(31 downto 0);
   signal hdr     : t_hdr := (others => (others => '0'));
   signal hdr_i   : integer range 0 to 8 := 0;

   signal cpu_sel : integer range 0 to 2 := 0;         -- 0 = ARM9, 1 = ARM7, 2 = header env copy
   signal src     : unsigned(26 downto 2) := (others => '0');
   signal dst     : unsigned(31 downto 0) := (others => '0');
   signal words   : unsigned(21 downto 0) := (others => '0');

   -- direct-boot env: values captured during the header copy pass
   signal env_size   : unsigned(31 downto 0) := (others => '0');       -- hdr+0x80 used ROM size
   signal env_hdrcrc : std_logic_vector(15 downto 0) := (others => '0'); -- hdr+0x15E
   signal env_seccrc : std_logic_vector(15 downto 0) := (others => '0'); -- hdr+0x6C
   signal cartid     : std_logic_vector(31 downto 0) := (others => '0');
   signal crcword    : std_logic_vector(31 downto 0) := (others => '0');
   signal env_i      : integer range 0 to 41 := 0;

   -- melonDS chip-ID formula: 0xC2 | size byte (pow2-padded ROM)
   function cart_id(size : unsigned(31 downto 0)) return std_logic_vector is
      variable p  : unsigned(31 downto 0) := to_unsigned(512, 32);
      variable id : unsigned(31 downto 0) := x"000000C2";
   begin
      for i in 9 to 27 loop
         if (p < size) then p := shift_left(p, 1); end if;
      end loop;
      if (p >= x"00100000") then
         id := id or shift_left(resize(shift_right(p, 20) - 1, 32), 8);
      else
         id := id or x"00010000";                      -- melonDS: 0x100 - (sz>>28)
      end if;
      return std_logic_vector(id);
   end function;

   -- table entries 0..12, then the 0x70-byte default user settings block
   -- (melonDS LoadDefaultFirmware: version 5, defaults, name empty)
   function env_addr(i : integer) return unsigned is
   begin
      case i is
         when  0 => return x"02FFF800";
         when  1 => return x"02FFF804";
         when  2 => return x"02FFF808";
         when  3 => return x"02FFF850";
         when  4 => return x"02FFFC00";
         when  5 => return x"02FFFC04";
         when  6 => return x"02FFFC08";
         when  7 => return x"02FFFC10";
         when  8 => return x"02FFFC30";
         when  9 => return x"02FFFC40";
         when 10 => return x"02FFF864";
         when 11 => return x"02FFF868";
         when 12 => return x"02FFF874";
         when others => return to_unsigned(16#02FFFC80# + (i - 13) * 4, 32);
      end case;
   end function;

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
                     elsif (cpu_sel = 1 and direct = '1') then
                        cpu_sel <= 2;                  -- header copy to 0x02FFFE00
                        src     <= (others => '0');
                        dst     <= x"02FFFE00";
                        words   <= to_unsigned(16#5C#, words'length);
                        state   <= CP_RD;
                     elsif (cpu_sel = 2) then
                        cartid  <= cart_id(env_size);
                        crcword <= env_seccrc & env_hdrcrc;
                        env_i   <= 0;
                        state   <= ENV_SET;
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
                     if (cpu_sel = 2) then             -- env values ride along
                        if (src = 16#1B#) then         -- byte 0x6C: secure-area CRC16
                           env_seccrc <= card_rdata(15 downto 0);
                        elsif (src = 16#20#) then      -- byte 0x80: used ROM size
                           env_size <= unsigned(card_rdata);
                        elsif (src = 16#57#) then      -- byte 0x15C: header CRC16 in [31:16]
                           env_hdrcrc <= card_rdata(31 downto 16);
                        end if;
                     end if;
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

               when ENV_SET =>
                  if (env_i = 41) then
                     busy  <= '0';
                     done  <= '1';
                     state <= FINISHED;
                  else
                     dst <= env_addr(env_i);
                     case env_i is
                        when 0 | 1 | 4 | 5 => wr_data <= cartid;
                        when 2 | 6         => wr_data <= crcword;
                        when 3 | 7         => wr_data <= x"00005835";
                        when 8             => wr_data <= x"0000FFFF";
                        when 9             => wr_data <= x"00000001";
                        when 10            => wr_data <= x"00000000";
                        when 11            => wr_data <= x"0007FE00"; -- fw user-settings offset
                        when 12            => wr_data <= x"0000FFFF"; -- fw data/gui CRC16s
                        -- user settings: version 5, favorite color/birthday
                        -- defaults, halfword 0x0031 at +0x64
                        when 13            => wr_data <= x"01000005";
                        when 14            => wr_data <= x"00000001";
                        when 38            => wr_data <= x"00000031";
                        when others        => wr_data <= x"00000000";
                     end case;
                     state <= ENV_WR;
                  end if;

               when ENV_WR =>
                  wr_ena  <= '1';
                  wr_addr <= std_logic_vector(dst);
                  state   <= ENV_WR_WAIT;

               when ENV_WR_WAIT =>
                  if (wr_done = '1') then
                     env_i <= env_i + 1;
                     state <= ENV_SET;
                  end if;

               when FINISHED =>
                  null;

            end case;
         end if;
      end if;
   end process;

end architecture;
