-- SPDX-License-Identifier: GPL-2.0-or-later

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.textio.all;

use work.pexport.all;
use work.pProc_bus_gba.all;
use work.pReg_savestates.all;

entity nds_cpu9 is
   generic
   (
      is_simu : std_logic;
      SS_PRESET_ONLY : std_logic := '1'
   );
   port
   (
      clk              : in    std_logic;
      ce               : in    std_logic;
      reset            : in    std_logic;

-- synthesis translate_off
      cpu_export_done  : out std_logic := '0';
      cpu_export       : out cpu_export_type := export_init;
-- synthesis translate_on

      error_cpu        : out   std_logic := '0';
      dbg_pc           : out   std_logic_vector(31 downto 0) := (others => '0');
      dbg_r0           : out   std_logic_vector(31 downto 0) := (others => '0');
      dbg_lr           : out   std_logic_vector(31 downto 0) := (others => '0');
      dbg_cpsr         : out   std_logic_vector(31 downto 0) := (others => '0');
      dbg_regsel       : in    unsigned(4 downto 0) := (others => '0');
      dbg_regval       : out   std_logic_vector(31 downto 0) := (others => '0');

      savestate_bus    : in    proc_bus_gb_type;
      ss_wired_out     : out   std_logic_vector(proc_buswidth-1 downto 0) := (others => '0');
      ss_wired_done    : out   std_logic;

      gb_bus_Adr       : out   std_logic_vector(31 downto 0);
      gb_bus_rnw       : out   std_logic;
      gb_bus_ena       : out   std_logic;
      gb_bus_seq       : out   std_logic;
      gb_bus_code      : out   std_logic;
      gb_bus_acc       : out   std_logic_vector(1 downto 0);
      gb_bus_dout      : out   std_logic_vector(31 downto 0);
      gb_bus_din       : in    std_logic_vector(31 downto 0);
      gb_bus_done      : in    std_logic;
      gb_bus_lock      : out   std_logic := '0';

      bus_lowbits      : out   std_logic_vector(1 downto 0) := "00";

      dma_on           : in    std_logic;
      done             : buffer std_logic := '0';
      CPU_bus_idle     : out   std_logic;
      PC_in_BIOS       : out   std_logic;
      cpu_halt         : out   std_logic;
      lastread         : out   std_logic_vector(31 downto 0);
      jump_out         : out   std_logic;

      IRQ_in           : in    std_logic;
      unhalt           : in    std_logic;
      new_halt         : in    std_logic;

      cp15_vector_hi   : out   std_logic;
      cp15_pu_enable   : out   std_logic;
      cp15_icache_ena  : out   std_logic;
      cp15_dcache_ena  : out   std_logic;
      cp15_itcm_ena    : out   std_logic;
      cp15_itcm_load   : out   std_logic;
      cp15_dtcm_ena    : out   std_logic;
      cp15_dtcm_load   : out   std_logic;
      cp15_dtcm_base   : out   std_logic_vector(31 downto 12);
      cp15_dtcm_size   : out   std_logic_vector(4 downto 0);
      cp15_itcm_size   : out   std_logic_vector(4 downto 0);

      bus_cacheable_i  : out   std_logic;
      bus_cacheable_d  : out   std_logic;

      cache_op_ena     : out   std_logic := '0';
      cache_op         : out   std_logic_vector(3 downto 0) := (others => '0');
      cache_op_addr    : out   std_logic_vector(31 downto 0) := (others => '0');
      cache_op_busy    : in    std_logic
   );
end entity;

architecture arch of nds_cpu9 is


   constant CPUMODE_USER       : std_logic_vector(3 downto 0) := x"0";
   constant CPUMODE_FIQ        : std_logic_vector(3 downto 0) := x"1";
   constant CPUMODE_IRQ        : std_logic_vector(3 downto 0) := x"2";
   constant CPUMODE_SUPERVISOR : std_logic_vector(3 downto 0) := x"3";
   constant CPUMODE_ABORT      : std_logic_vector(3 downto 0) := x"7";
   constant CPUMODE_UNDEFINED  : std_logic_vector(3 downto 0) := x"B";
   constant CPUMODE_SYSTEM     : std_logic_vector(3 downto 0) := x"F";

   signal thumbmode        : std_logic := '0';

   signal IRQ_disable      : std_logic := '1';
   signal FIQ_disable      : std_logic := '1';

   signal Flag_Zero        : std_logic := '0';
   signal Flag_Carry       : std_logic := '0';
   signal Flag_Negative    : std_logic := '0';
   signal Flag_V_Overflow  : std_logic := '0';
   signal Flag_Q_Sticky    : std_logic := '0';

   signal cp15_control     : std_logic_vector(31 downto 0) := x"00012078";
   signal cp15_dtcm_reg    : std_logic_vector(31 downto 0) := x"0300000A";
   signal cp15_itcm_reg    : std_logic_vector(31 downto 0) := x"00000020";
   type t_cp15_regions is array (0 to 7) of std_logic_vector(31 downto 0);
   type t_cp15_masks   is array (0 to 7) of unsigned(31 downto 12);
   signal cp15_pu_mask : t_cp15_masks;
   signal cp15_pu_region   : t_cp15_regions :=
   (
      0 => x"04000033", 1 => x"0200002B", 2 => x"00000000", 3 => x"08000035",
      4 => x"0300001B", 5 => x"00000000", 6 => x"FFFF001D", 7 => x"027FF017"
   );
   signal cp15_pu_dcache   : std_logic_vector(31 downto 0) := x"00000042";
   signal cp15_pu_icache   : std_logic_vector(31 downto 0) := x"00000042";
   signal cp15_pu_wbuf     : std_logic_vector(31 downto 0) := x"00000002";
   signal cp15_pu_dperm    : std_logic_vector(31 downto 0) := x"15111011";
   signal cp15_pu_iperm    : std_logic_vector(31 downto 0) := x"05100011";
   signal cp15_dcache_lock : std_logic_vector(31 downto 0) := (others => '0');
   signal cp15_icache_lock : std_logic_vector(31 downto 0) := (others => '0');
   signal cp15_trace_pid   : std_logic_vector(31 downto 0) := (others => '0');

   signal execute_wfi      : std_logic;
   signal execute_cp15_cacheop : std_logic;

   signal cpu_mode         : std_logic_vector(3 downto 0) := CPUMODE_SUPERVISOR;

   signal CPSR             : unsigned(31 downto 0);
   signal SPSR             : unsigned(31 downto 0);

   type t_regs is array(0 to 15) of unsigned(31 downto 0);
   signal regs : t_regs := (others => (others => '0'));

   signal regs_0_8  : unsigned(31 downto 0) := (others => '0');
   signal regs_0_9  : unsigned(31 downto 0) := (others => '0');
   signal regs_0_10 : unsigned(31 downto 0) := (others => '0');
   signal regs_0_11 : unsigned(31 downto 0) := (others => '0');
   signal regs_0_12 : unsigned(31 downto 0) := (others => '0');
   signal regs_0_13 : unsigned(31 downto 0) := (others => '0');
   signal regs_0_14 : unsigned(31 downto 0) := (others => '0');
   signal regs_1_8  : unsigned(31 downto 0) := (others => '0');
   signal regs_1_9  : unsigned(31 downto 0) := (others => '0');
   signal regs_1_10 : unsigned(31 downto 0) := (others => '0');
   signal regs_1_11 : unsigned(31 downto 0) := (others => '0');
   signal regs_1_12 : unsigned(31 downto 0) := (others => '0');
   signal regs_1_13 : unsigned(31 downto 0) := (others => '0');
   signal regs_1_14 : unsigned(31 downto 0) := (others => '0');
   signal regs_1_17 : unsigned(31 downto 0) := (others => '0');
   signal regs_2_13 : unsigned(31 downto 0) := (others => '0');
   signal regs_2_14 : unsigned(31 downto 0) := (others => '0');
   signal regs_2_17 : unsigned(31 downto 0) := (others => '0');
   signal regs_3_13 : unsigned(31 downto 0) := (others => '0');
   signal regs_3_14 : unsigned(31 downto 0) := (others => '0');
   signal regs_3_17 : unsigned(31 downto 0) := (others => '0');
   signal regs_4_13 : unsigned(31 downto 0) := (others => '0');
   signal regs_4_14 : unsigned(31 downto 0) := (others => '0');
   signal regs_4_17 : unsigned(31 downto 0) := (others => '0');
   signal regs_5_13 : unsigned(31 downto 0) := (others => '0');
   signal regs_5_14 : unsigned(31 downto 0) := (others => '0');
   signal regs_5_17 : unsigned(31 downto 0) := (others => '0');

   type tbusState is
   (
      BUSSTATE_IDLE,
      BUSSTATE_WAITFETCH,
      BUSSTATE_WAITDATA
   );

   signal busState : tbusState := BUSSTATE_IDLE;

   signal bus_accessFetch     : std_logic;
   signal bus_AddrFetch       : unsigned(31 downto 0);

   signal gb_bus_save         : std_logic;
   signal gb_bus_saved        : std_logic := '0';
   signal gb_bus_saved_st1    : std_logic := '0';
   signal gb_bus_saved_Adr    : std_logic_vector(31 downto 0);
   signal gb_bus_saved_rnw    : std_logic;
   signal gb_bus_saved_seq    : std_logic;
   signal gb_bus_saved_acc    : std_logic_vector(1 downto 0);
   signal gb_bus_saved_dout   : std_logic_vector(31 downto 0);
   signal gb_bus_lock_active  : std_logic := '0';

   signal dma_on_1            : std_logic := '0';

   signal fetch_done       : std_logic;
   signal fetch_PC         : unsigned(31 downto 0) := (others => '0');
   signal fetch_data       : std_logic_vector(31 downto 0) := (others => '0');
   signal fetch_ready      : std_logic := '0';
   signal fetch_first      : std_logic := '0';

   type tFunctions is
   (
      branch_and_exchange,
      data_processing,
      single_data_swap,
      multiply_long,
      multiply,
      halfword_data_transfer_regoffset,
      halfword_data_transfer_immoffset,
      single_data_transfer,
      block_data_transfer,
      branch,
      software_interrupt,
      long_branch_with_link,
      v5_misc,
      coprocessor_op,
      v5_nop
   );

   type tFunctions_detail is
   (
      alu_and,
      alu_xor,
      alu_sub,
      alu_add,
      alu_add_withcarry,
      alu_sub_withcarry,
      alu_or,
      alu_mov,
      alu_and_not,
      alu_mov_not,
      mulboth,
      data_processing_MRS,
      data_processing_MSR,
      branch_all,
      data_read,
      data_write,
      block_read,
      block_write,
      software_interrupt_detail,
      IRQ,
      alu_clz,
      sat_arith,
      mul_dsp,
      cp15_op,
      nop_detail
   );

   type tdatareceivetype is
   (
      RECEIVETYPE_BYTE,
      RECEIVETYPE_DWORD,
      RECEIVETYPE_WORD,
      RECEIVETYPE_SIGNEDBYTE,
      RECEIVETYPE_SIGNEDWORD
   );

   signal decode_condition                : std_logic_vector(3 downto 0);

   signal decode_ready                    : std_logic := '0';
   signal decode_data                     : std_logic_vector(31 downto 0);
   signal decode_data_1                   : std_logic_vector(31 downto 0) := (others => '0');
   signal decode_halt                     : std_logic := '0';
   signal decode_unhalt                   : std_logic := '0';
   signal decode_PC                       : unsigned(31 downto 0) := (others => '0');
   signal decode_functions_detail         : tFunctions_detail;
   signal decode_datareceivetype          : tdatareceivetype;
   signal decode_clearbit1                : std_logic := '0';
   signal decode_rdest                    : std_logic_vector(3 downto 0) := (others => '0');
   signal decode_rdest_save               : std_logic_vector(3 downto 0) := (others => '0');
   signal decode_Rn_op1                   : std_logic_vector(3 downto 0) := (others => '0');
   signal decode_Rn_op1_save              : std_logic_vector(3 downto 0) := (others => '0');
   signal decode_RM_op2                   : std_logic_vector(3 downto 0) := (others => '0');
   attribute preserve : boolean;
   attribute preserve of decode_Rn_op1 : signal is true;
   signal decode_alu_use_immi             : std_logic := '0';
   signal decode_alu_use_shift            : std_logic := '0';
   signal decode_immidiate                : unsigned(31 downto 0) := (others => '0');
   signal decode_shift_regbased           : std_logic;
   signal decode_shift_mode               : std_logic_vector(1 downto 0);
   signal decode_shift_amount             : integer range 0 to 255;
   signal decode_shift_RRX                : std_logic;
   signal decode_shiftcarry               : std_logic := '0';
   signal decode_useoldcarry              : std_logic := '0';
   signal decode_updateflags              : std_logic := '0';
   signal decode_mul_signed               : std_logic := '0';
   signal decode_mul_useadd               : std_logic := '0';
   signal decode_mul_long                 : std_logic := '0';
   signal decode_writeback                : std_logic := '0';
   signal decode_switch_op                : std_logic := '0';
   signal decode_set_thumbmode            : std_logic := '0';
   signal decode_branch_usereg            : std_logic := '0';
   signal decode_branch_link              : std_logic := '0';
   signal decode_branch_long              : std_logic := '0';
   signal decode_branch_immi              : signed(25 downto 0) := (others => '0');
   signal decode_datatransfer_type        : std_logic_vector(1 downto 0) := (others => '0');
   signal decode_datatransfer_preadd      : std_logic := '0';
   signal decode_datatransfer_addup       : std_logic := '0';
   signal decode_datatransfer_writeback   : std_logic := '0';
   signal decode_datatransfer_addvalue    : unsigned(11 downto 0)  := (others => '0');
   signal decode_datatransfer_shiftval    : std_logic := '0';
   signal decode_datatransfer_regoffset   : std_logic := '0';
   signal decode_datatransfer_swap        : std_logic := '0';
   signal decode_block_usermoderegs       : std_logic := '0';
   signal decode_block_switchmode         : std_logic := '0';
   signal decode_block_addrmod            : integer range -64 to 64 := 0;
   signal decode_block_endmod             : integer range -64 to 64 := 0;
   signal decode_block_addrmod_baseRlist  : integer range -64 to 64 := 0;
   signal decode_block_reglist            : std_logic_vector(15 downto 0) := (others => '0');
   signal decode_block_emptylist          : std_logic := '0';
   signal decode_psr_with_spsr            : std_logic := '0';
   signal decode_leaveirp                 : std_logic := '0';

   signal decode_sat_sub                  : std_logic := '0';
   signal decode_sat_double               : std_logic := '0';
   signal decode_dsp_x                    : std_logic := '0';
   signal decode_dsp_y                    : std_logic := '0';
   signal decode_dsp_acc                  : std_logic := '0';
   signal decode_dsp_long                 : std_logic := '0';
   signal decode_dsp_word                 : std_logic := '0';
   signal decode_dsp_acchi                : std_logic_vector(3 downto 0) := (others => '0');
   signal decode_cp15_mrc                 : std_logic := '0';
   signal decode_cp15_crn                 : std_logic_vector(3 downto 0) := (others => '0');
   signal decode_cp15_crm                 : std_logic_vector(3 downto 0) := (others => '0');
   signal decode_cp15_op2                 : std_logic_vector(2 downto 0) := (others => '0');
   signal decode_datatransfer_double      : std_logic := '0';
   signal decode_branch_forcethumb        : std_logic := '0';
   signal decode_branch_forcearm          : std_logic := '0';

   signal execute_op1                     : unsigned(31 downto 0);
   signal execute_op2                     : unsigned(31 downto 0);
   signal execute_opDest                  : unsigned(31 downto 0);

   signal shiftervalue                    : unsigned(31 downto 0);
   signal shiftresult                     : unsigned(31 downto 0);
   signal shiftercarry                    : std_logic;

   type t_shfill is (FILL_ZERO, FILL_SIGN, FILL_CARRY);
   type t_shcsel is (CSEL_ZERO, CSEL_CARRY, CSEL_VALUE);
   signal sh_rot                          : integer range 0 to 31;
   signal sh_keep                         : std_logic_vector(31 downto 0);
   signal sh_fill                         : t_shfill;
   signal sh_cidx                         : integer range 0 to 31;
   signal sh_csel                         : t_shcsel;
   signal sh_rotv                         : unsigned(31 downto 0);
   signal sh_fillb                        : std_logic;


   signal alu_op1                         : unsigned(31 downto 0);
   signal alu_op2                         : unsigned(31 downto 0);
   signal alu_result                      : unsigned(31 downto 0);
   signal alu_result_add                  : unsigned(32 downto 0);
   signal alu_shiftercarry                : std_logic;
   signal alu_wait_shift                  : std_logic := '0';
   signal alu_pcwrite_wait                : std_logic := '0';
   signal execute_cacheop_wait            : std_logic := '0';

   signal execute_flag_Carry              : std_logic;
   signal execute_flag_Zero               : std_logic;
   signal execute_flag_Negative           : std_logic;
   signal execute_flag_V_Overflow         : std_logic;

   signal execute_writeback               : std_logic;
   signal execute_writedata               : unsigned(31 downto 0);
   signal execute_writereg                : unsigned(3 downto 0);

   signal execute_branch                  : std_logic;
   signal execute_nextIsthumb             : std_logic;
   signal execute_branchPC                : unsigned(31 downto 0);
   signal execute_branchPC_masked         : unsigned(31 downto 0);
   signal pcwrite_fetch                   : std_logic;
   signal pcwrite_Addr                    : unsigned(31 downto 0);
   signal bus_AddrFetch_eff               : unsigned(31 downto 0);
   signal adr_early                       : std_logic_vector(31 downto 0);
   signal adr_is_pcw                      : std_logic;

   signal execute_stall                   : std_logic := '0';
   signal execute_done                    : std_logic;
   signal execute_now                     : std_logic;
   signal execute_skip                    : std_logic;


   type texecute_MUL_State is
   (
      MUL_IDLE,
      MUL_MUL,
      MUL_ADD,
      MUL_STOREHI,
      MUL_DSP_ACC,
      MUL_DSP_ACCHI
   );
   signal execute_MUL_State : texecute_MUL_State := MUL_IDLE;
   signal execute_mul_opaddlow            : unsigned(31 downto 0) := (others => '0');
   signal execute_mul_opaddhigh           : unsigned(31 downto 0) := (others => '0');
   signal execute_mul_result              : unsigned(63 downto 0) := (others => '0');
   signal execute_mul_wait                : integer range 0 to 3 := 0;

   type texecute_RW_State is
   (
      DATARW_IDLE,
      DATARW_ADDRWAIT,
      DATARW_READSTART,
      DATARW_READWAIT,
      DATARW_READWAITDMA,
      DATARW_WRITE,
      DATARW_SWAPWRITE,
      DATARW_SWAPWAIT,
      DATARW_BLOCKREAD,
      DATARW_BLOCKWRITE,
      DATARW_BLOCKSWITCH,
      DATARW_PCWRITE,
      DATARW_READSTART_D2,
      DATARW_WRITE_D2
   );
   signal execute_RW_State : texecute_RW_State := DATARW_IDLE;
   signal execute_RW_data                 : std_logic_vector(31 downto 0);
   signal execute_RW_addr                 : unsigned(31 downto 0);
   signal execute_RW_addr_last            : unsigned(31 downto 0);
   signal execute_RW_rnw                  : std_logic;
   signal execute_RW_acc                  : std_logic_vector(1 downto 0);
   signal execute_RW_ena                  : std_logic;
   signal execute_busaddress              : unsigned(31 downto 0);
   signal execute_busaddmod               : unsigned(31 downto 0);
   signal execute_RW_dataRead             : std_logic_vector(31 downto 0);
   attribute preserve of execute_RW_dataRead : signal is true;
   signal execute_RW_WBaddr               : unsigned(31 downto 0) := (others => '0');

   signal execute_blockRW_addr            : unsigned(31 downto 0) := (others => '0');
   signal execute_blockRW_writereg        : unsigned(3 downto 0) := (others => '0');
   signal execute_blockRW_last            : std_logic;
   signal execute_blockRW_endaddr         : unsigned(31 downto 0) := (others => '0');

   signal execute_msr_fetchvalue          : unsigned(31 downto 0);
   signal execute_msr_writevalue          : unsigned(31 downto 0);
   signal execute_msr_setvalue            : unsigned(31 downto 0);
   signal execute_msr_setvalue_ena        : std_logic;

   signal execute_switchmode_now          : std_logic;
   signal execute_switchmode_state        : std_logic;
   signal execute_switchmode_val          : std_logic_vector(3 downto 0);
   signal execute_switchmode_new          : std_logic_vector(3 downto 0);

   signal exception_base                  : unsigned(31 downto 0);
   signal execute_clz_result              : unsigned(31 downto 0);
   signal execute_sat_result              : unsigned(31 downto 0);
   signal execute_sat_qset                : std_logic;
   signal execute_dsp_sum                 : unsigned(31 downto 0);
   signal execute_dsp_qset                : std_logic;
   signal execute_dsp_carry               : std_logic := '0';
   signal cp15_rdata                      : std_logic_vector(31 downto 0);

   signal SAVESTATE_PC_in  : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_PC_out : std_logic_vector(31 downto 0) := (others => '0');

   type t_regs_slv is array(0 to 17) of std_logic_vector(31 downto 0);
   signal SAVESTATE_REGS : t_regs_slv := (others => (others => '0'));

   type t_ss_wired_or is array(0 to 46) of std_logic_vector(31 downto 0);
   signal save_wired_or   : t_ss_wired_or;
   signal save_wired_done : unsigned(0 to 46);

   signal SAVESTATE_REGS_0_8  : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_0_9  : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_0_10 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_0_11 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_0_12 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_0_13 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_0_14 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_1_8  : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_1_9  : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_1_10 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_1_11 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_1_12 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_1_13 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_1_14 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_1_17 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_2_13 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_2_14 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_2_17 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_3_13 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_3_14 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_3_17 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_4_13 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_4_14 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_4_17 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_5_13 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_5_14 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_5_17 : std_logic_vector(31 downto 0) := (others => '0');

   signal SAVESTATE_HALT            : std_logic;
   signal SAVESTATE_Flag_Zero       : std_logic;
   signal SAVESTATE_Flag_Carry      : std_logic;
   signal SAVESTATE_Flag_Negative   : std_logic;
   signal SAVESTATE_Flag_V_Overflow : std_logic;
   signal SAVESTATE_thumbmode       : std_logic;
   signal SAVESTATE_cpu_mode        : std_logic_vector(3 downto 0);
   signal SAVESTATE_IRQ_disable     : std_logic;
   signal SAVESTATE_FIQ_disable     : std_logic;

   signal SAVESTATE_mixed_in        : std_logic_vector(11 downto 0);
   signal SAVESTATE_mixed_out       : std_logic_vector(11 downto 0);

-- synthesis translate_off
   signal decode_opcode_export  : std_logic_vector(31 downto 0) := (others => '0');
   signal execute_opcode_export : std_logic_vector(31 downto 0) := (others => '0');
-- synthesis translate_on

begin

   dbg_pc <= std_logic_vector(regs(15));
   dbg_r0 <= std_logic_vector(regs(0));
   dbg_lr <= std_logic_vector(regs(14));
   dbg_cpsr <= std_logic_vector(CPSR);
   dbg_regval <= std_logic_vector(CPSR) when dbg_regsel(4) = '1' else
                 std_logic_vector(regs(to_integer(dbg_regsel(3 downto 0))));
   gb_bus_lock <= gb_bus_lock_active or
                  (execute_RW_ena and decode_datatransfer_swap);

   process (clk)
   begin
      if rising_edge(clk) then
         if (reset = '1') then
            gb_bus_lock_active <= '0';
         elsif (ce = '1') then
            if (execute_RW_ena = '1' and decode_datatransfer_swap = '1') then
               gb_bus_lock_active <= '1';
            elsif (gb_bus_lock_active = '1' and gb_bus_done = '1' and
                   execute_RW_State = DATARW_SWAPWRITE) then
               gb_bus_lock_active <= '0';
            end if;
         end if;
      end if;
   end process;

   CPSR(3 downto 0)  <= unsigned(cpu_mode);
   CPSR(4)           <= '1';
   CPSR(5)           <= thumbmode;
   CPSR(6)           <= FIQ_disable;
   CPSR(7)           <= IRQ_disable;
   CPSR(26 downto 8) <= (others => '0');
   CPSR(27)          <= Flag_Q_Sticky;
   CPSR(28)          <= Flag_V_Overflow;
   CPSR(29)          <= Flag_Carry;
   CPSR(30)          <= Flag_Zero;
   CPSR(31)          <= Flag_Negative;

   SPSR <= regs_1_17 when (cpu_mode = CPUMODE_FIQ) else
           regs_2_17 when (cpu_mode = CPUMODE_IRQ) else
           regs_3_17 when (cpu_mode = CPUMODE_SUPERVISOR) else
           regs_4_17 when (cpu_mode = CPUMODE_ABORT) else
           regs_5_17 when (cpu_mode = CPUMODE_UNDEFINED) else
           CPSR;


   PC_in_BIOS <= '1' when bus_AddrFetch(31 downto 16) = x"FFFF" else '0';

   cpu_halt   <= decode_halt;

   cp15_vector_hi  <= cp15_control(13);
   cp15_pu_enable  <= cp15_control(0);
   cp15_icache_ena <= cp15_control(12);
   cp15_dcache_ena <= cp15_control(2);
   cp15_itcm_ena   <= cp15_control(18);
   cp15_itcm_load  <= cp15_control(19);
   cp15_dtcm_ena   <= cp15_control(16);
   cp15_dtcm_load  <= cp15_control(17);
   cp15_dtcm_base  <= cp15_dtcm_reg(31 downto 12);
   cp15_dtcm_size  <= cp15_dtcm_reg(5 downto 1);
   cp15_itcm_size  <= cp15_itcm_reg(5 downto 1);

   process (all)
      variable sz : integer range 0 to 31;
   begin
      for r in 0 to 7 loop
         sz := to_integer(unsigned(cp15_pu_region(r)(5 downto 1)));
         for i in 12 to 31 loop
            if (i > sz) then cp15_pu_mask(r)(i) <= '1';
            else             cp15_pu_mask(r)(i) <= '0';
            end if;
         end loop;
      end loop;
   end process;

   process (all)
      variable a : unsigned(31 downto 12);
   begin
      bus_cacheable_i <= '0';
      bus_cacheable_d <= '0';
      a := unsigned(gb_bus_Adr(31 downto 12));
      if (cp15_control(0) = '1') then
         for r in 0 to 7 loop
            if (cp15_pu_region(r)(0) = '1') then
               if (((a xor unsigned(cp15_pu_region(r)(31 downto 12)))
                    and cp15_pu_mask(r)) = 0) then
                  bus_cacheable_i <= cp15_control(12) and cp15_pu_icache(r);
                  bus_cacheable_d <= cp15_control(2)  and cp15_pu_dcache(r);
               end if;
            end if;
         end loop;
      end if;
   end process;

   gss_full : if SS_PRESET_ONLY = '0' generate
   begin
   gSAVESTATE_REGS : for i in 0 to 15 generate
   begin
      iSAVESTATE_REGS : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS, i) port map (clk, savestate_bus, save_wired_or(i), save_wired_done(i), std_logic_vector(regs(i)) , SAVESTATE_REGS(i));
   end generate;

   iSAVESTATE_REGS_16   : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS, 16 ) port map (clk, savestate_bus, save_wired_or(16), save_wired_done(16), std_logic_vector(CPSR)      , open );
   iSAVESTATE_REGS_17   : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS, 17 ) port map (clk, savestate_bus, save_wired_or(17), save_wired_done(17), std_logic_vector(SPSR)      , open );

   iSAVESTATE_PC        : entity work.eProcReg_gba generic map (REG_SAVESTATE_PC       ) port map (clk, savestate_bus, save_wired_or(18), save_wired_done(18), SAVESTATE_PC_out            , SAVESTATE_PC_in);

   iSAVESTATE_REGS_0_8  : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_0_8 ) port map (clk, savestate_bus, save_wired_or(19), save_wired_done(19), std_logic_vector(regs_0_8 ) , SAVESTATE_REGS_0_8 );
   iSAVESTATE_REGS_0_9  : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_0_9 ) port map (clk, savestate_bus, save_wired_or(20), save_wired_done(20), std_logic_vector(regs_0_9 ) , SAVESTATE_REGS_0_9 );
   iSAVESTATE_REGS_0_10 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_0_10) port map (clk, savestate_bus, save_wired_or(21), save_wired_done(21), std_logic_vector(regs_0_10) , SAVESTATE_REGS_0_10);
   iSAVESTATE_REGS_0_11 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_0_11) port map (clk, savestate_bus, save_wired_or(22), save_wired_done(22), std_logic_vector(regs_0_11) , SAVESTATE_REGS_0_11);
   iSAVESTATE_REGS_0_12 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_0_12) port map (clk, savestate_bus, save_wired_or(23), save_wired_done(23), std_logic_vector(regs_0_12) , SAVESTATE_REGS_0_12);
   iSAVESTATE_REGS_0_13 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_0_13) port map (clk, savestate_bus, save_wired_or(24), save_wired_done(24), std_logic_vector(regs_0_13) , SAVESTATE_REGS_0_13);
   iSAVESTATE_REGS_0_14 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_0_14) port map (clk, savestate_bus, save_wired_or(25), save_wired_done(25), std_logic_vector(regs_0_14) , SAVESTATE_REGS_0_14);
   iSAVESTATE_REGS_1_8  : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_1_8 ) port map (clk, savestate_bus, save_wired_or(26), save_wired_done(26), std_logic_vector(regs_1_8 ) , SAVESTATE_REGS_1_8 );
   iSAVESTATE_REGS_1_9  : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_1_9 ) port map (clk, savestate_bus, save_wired_or(27), save_wired_done(27), std_logic_vector(regs_1_9 ) , SAVESTATE_REGS_1_9 );
   iSAVESTATE_REGS_1_10 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_1_10) port map (clk, savestate_bus, save_wired_or(28), save_wired_done(28), std_logic_vector(regs_1_10) , SAVESTATE_REGS_1_10);
   iSAVESTATE_REGS_1_11 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_1_11) port map (clk, savestate_bus, save_wired_or(29), save_wired_done(29), std_logic_vector(regs_1_11) , SAVESTATE_REGS_1_11);
   iSAVESTATE_REGS_1_12 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_1_12) port map (clk, savestate_bus, save_wired_or(30), save_wired_done(30), std_logic_vector(regs_1_12) , SAVESTATE_REGS_1_12);
   iSAVESTATE_REGS_1_13 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_1_13) port map (clk, savestate_bus, save_wired_or(31), save_wired_done(31), std_logic_vector(regs_1_13) , SAVESTATE_REGS_1_13);
   iSAVESTATE_REGS_1_14 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_1_14) port map (clk, savestate_bus, save_wired_or(32), save_wired_done(32), std_logic_vector(regs_1_14) , SAVESTATE_REGS_1_14);
   iSAVESTATE_REGS_1_17 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_1_17) port map (clk, savestate_bus, save_wired_or(33), save_wired_done(33), std_logic_vector(regs_1_17) , SAVESTATE_REGS_1_17);
   iSAVESTATE_REGS_2_13 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_2_13) port map (clk, savestate_bus, save_wired_or(34), save_wired_done(34), std_logic_vector(regs_2_13) , SAVESTATE_REGS_2_13);
   iSAVESTATE_REGS_2_14 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_2_14) port map (clk, savestate_bus, save_wired_or(35), save_wired_done(35), std_logic_vector(regs_2_14) , SAVESTATE_REGS_2_14);
   iSAVESTATE_REGS_2_17 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_2_17) port map (clk, savestate_bus, save_wired_or(36), save_wired_done(36), std_logic_vector(regs_2_17) , SAVESTATE_REGS_2_17);
   iSAVESTATE_REGS_3_13 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_3_13) port map (clk, savestate_bus, save_wired_or(37), save_wired_done(37), std_logic_vector(regs_3_13) , SAVESTATE_REGS_3_13);
   iSAVESTATE_REGS_3_14 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_3_14) port map (clk, savestate_bus, save_wired_or(38), save_wired_done(38), std_logic_vector(regs_3_14) , SAVESTATE_REGS_3_14);
   iSAVESTATE_REGS_3_17 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_3_17) port map (clk, savestate_bus, save_wired_or(39), save_wired_done(39), std_logic_vector(regs_3_17) , SAVESTATE_REGS_3_17);
   iSAVESTATE_REGS_4_13 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_4_13) port map (clk, savestate_bus, save_wired_or(40), save_wired_done(40), std_logic_vector(regs_4_13) , SAVESTATE_REGS_4_13);
   iSAVESTATE_REGS_4_14 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_4_14) port map (clk, savestate_bus, save_wired_or(41), save_wired_done(41), std_logic_vector(regs_4_14) , SAVESTATE_REGS_4_14);
   iSAVESTATE_REGS_4_17 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_4_17) port map (clk, savestate_bus, save_wired_or(42), save_wired_done(42), std_logic_vector(regs_4_17) , SAVESTATE_REGS_4_17);
   iSAVESTATE_REGS_5_13 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_5_13) port map (clk, savestate_bus, save_wired_or(43), save_wired_done(43), std_logic_vector(regs_5_13) , SAVESTATE_REGS_5_13);
   iSAVESTATE_REGS_5_14 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_5_14) port map (clk, savestate_bus, save_wired_or(44), save_wired_done(44), std_logic_vector(regs_5_14) , SAVESTATE_REGS_5_14);
   iSAVESTATE_REGS_5_17 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_5_17) port map (clk, savestate_bus, save_wired_or(45), save_wired_done(45), std_logic_vector(regs_5_17) , SAVESTATE_REGS_5_17);

   iSAVESTATE_CPUMIXED  : entity work.eProcReg_gba generic map (REG_SAVESTATE_CPUMIXED)  port map (clk, savestate_bus, save_wired_or(46), save_wired_done(46), SAVESTATE_mixed_out , SAVESTATE_mixed_in);

   process (save_wired_or)
      variable wired_or : std_logic_vector(31 downto 0);
   begin
      wired_or := save_wired_or(0);
      for i in 1 to (save_wired_or'length - 1) loop
         wired_or := wired_or or save_wired_or(i);
      end loop;
      ss_wired_out <= wired_or;
   end process;
   ss_wired_done <= '0' when (save_wired_done = 0) else '1';
   end generate;

   gss_preset : if SS_PRESET_ONLY = '1' generate
   begin
      gkeep_regs : for i in 12 to 14 generate
      begin
         iSAVESTATE_REGS : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS, i) port map (clk, savestate_bus, open, open, std_logic_vector(regs(i)) , SAVESTATE_REGS(i));
      end generate;

      iSAVESTATE_PC        : entity work.eProcReg_gba generic map (REG_SAVESTATE_PC       ) port map (clk, savestate_bus, open, open, SAVESTATE_PC_out            , SAVESTATE_PC_in);

      iSAVESTATE_REGS_0_13 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_0_13) port map (clk, savestate_bus, open, open, std_logic_vector(regs_0_13) , SAVESTATE_REGS_0_13);
      iSAVESTATE_REGS_2_13 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_2_13) port map (clk, savestate_bus, open, open, std_logic_vector(regs_2_13) , SAVESTATE_REGS_2_13);
      iSAVESTATE_REGS_3_13 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_3_13) port map (clk, savestate_bus, open, open, std_logic_vector(regs_3_13) , SAVESTATE_REGS_3_13);

      gzero_lo : for i in 0 to 11 generate
      begin
         SAVESTATE_REGS(i) <= (others => '0');
      end generate;
      SAVESTATE_REGS(15)  <= (others => '0');

      SAVESTATE_REGS_0_8  <= (others => '0');
      SAVESTATE_REGS_0_9  <= (others => '0');
      SAVESTATE_REGS_0_10 <= (others => '0');
      SAVESTATE_REGS_0_11 <= (others => '0');
      SAVESTATE_REGS_0_12 <= (others => '0');
      SAVESTATE_REGS_0_14 <= (others => '0');
      SAVESTATE_REGS_1_8  <= (others => '0');
      SAVESTATE_REGS_1_9  <= (others => '0');
      SAVESTATE_REGS_1_10 <= (others => '0');
      SAVESTATE_REGS_1_11 <= (others => '0');
      SAVESTATE_REGS_1_12 <= (others => '0');
      SAVESTATE_REGS_1_13 <= (others => '0');
      SAVESTATE_REGS_1_14 <= (others => '0');
      SAVESTATE_REGS_1_17 <= (others => '0');
      SAVESTATE_REGS_2_14 <= (others => '0');
      SAVESTATE_REGS_2_17 <= (others => '0');
      SAVESTATE_REGS_3_14 <= (others => '0');
      SAVESTATE_REGS_3_17 <= (others => '0');
      SAVESTATE_REGS_4_13 <= (others => '0');
      SAVESTATE_REGS_4_14 <= (others => '0');
      SAVESTATE_REGS_4_17 <= (others => '0');
      SAVESTATE_REGS_5_13 <= (others => '0');
      SAVESTATE_REGS_5_14 <= (others => '0');
      SAVESTATE_REGS_5_17 <= (others => '0');

      SAVESTATE_mixed_in <= std_logic_vector(to_unsigned(16#CC0#, 12));

      ss_wired_out  <= (others => '0');
      ss_wired_done <= '0';
   end generate;

   SAVESTATE_mixed_out(0) <= decode_halt;
   SAVESTATE_mixed_out(1) <= Flag_Zero;
   SAVESTATE_mixed_out(2) <= Flag_Carry;
   SAVESTATE_mixed_out(3) <= Flag_Negative;
   SAVESTATE_mixed_out(4) <= Flag_V_Overflow;
   SAVESTATE_mixed_out(5) <= thumbmode;
   SAVESTATE_mixed_out(9 downto 6) <= cpu_mode;
   SAVESTATE_mixed_out(10) <= IRQ_disable;
   SAVESTATE_mixed_out(11) <= FIQ_disable;

   SAVESTATE_HALT            <= SAVESTATE_mixed_in(0);
   SAVESTATE_Flag_Zero       <= SAVESTATE_mixed_in(1);
   SAVESTATE_Flag_Carry      <= SAVESTATE_mixed_in(2);
   SAVESTATE_Flag_Negative   <= SAVESTATE_mixed_in(3);
   SAVESTATE_Flag_V_Overflow <= SAVESTATE_mixed_in(4);
   SAVESTATE_thumbmode       <= SAVESTATE_mixed_in(5);
   SAVESTATE_cpu_mode        <= SAVESTATE_mixed_in(9 downto 6);
   SAVESTATE_IRQ_disable     <= SAVESTATE_mixed_in(10);
   SAVESTATE_FIQ_disable     <= SAVESTATE_mixed_in(11);

   process (all)
   begin

      gb_bus_ena  <= '0';
      gb_bus_save <= '0';

      if (reset = '0' and ce = '1') then

         if (bus_accessFetch = '1' and (busState <= BUSSTATE_IDLE or gb_bus_done = '1')) then
            gb_bus_ena  <= not dma_on;
            gb_bus_save <= dma_on;
         end if;

         if (execute_RW_ena = '1') then
            gb_bus_ena  <= not dma_on;
            gb_bus_save <= dma_on;
         end if;

         if (gb_bus_saved = '1' and dma_on = '0') then
            gb_bus_ena   <= '1';
         end if;

      end if;

   end process;


   process (clk)
   begin
      if (rising_edge(clk)) then

         dma_on_1 <= dma_on;

         if (reset = '1') then

            busState     <= BUSSTATE_IDLE;
            CPU_bus_idle <= '1';
            gb_bus_saved <= '0';

         elsif (ce = '1') then

            if (gb_bus_done = '1') then
               busState     <= BUSSTATE_IDLE;
               CPU_bus_idle <= '1';

               if (thumbmode = '1') then
                  lastread     <= gb_bus_din(15 downto 0) & gb_bus_din(15 downto 0);
               else
                  lastread     <= gb_bus_din;
               end if;
            end if;

            if (bus_accessFetch = '1' and gb_bus_ena = '1') then
               busState     <= BUSSTATE_WAITFETCH;
               CPU_bus_idle <= '0';
            end if;

            if (execute_now = '1' and execute_skip = '0' and
                execute_RW_State = DATARW_IDLE and
                (decode_functions_detail = data_read or decode_functions_detail = data_write) and
                decode_datatransfer_shiftval = '1') then
               execute_RW_addr_last <= execute_RW_addr;
            end if;

            if (execute_RW_ena = '1') then
               execute_RW_addr_last <= execute_RW_addr;
               if (gb_bus_ena = '1') then
                  busState             <= BUSSTATE_WAITDATA;
                  CPU_bus_idle         <= '0';
               end if;
            end if;

            if (gb_bus_saved = '1' and gb_bus_ena = '1') then
               CPU_bus_idle         <= '0';
               if (gb_bus_saved_st1 = '1') then
                  busState             <= BUSSTATE_WAITFETCH;
               else
                  busState             <= BUSSTATE_WAITDATA;
               end if;
            end if;

            if (gb_bus_save = '1') then
               gb_bus_saved      <= '1';
               gb_bus_saved_st1  <= bus_accessFetch;
               gb_bus_saved_Adr  <= gb_bus_Adr;
               gb_bus_saved_rnw  <= gb_bus_rnw;
               gb_bus_saved_seq  <= gb_bus_seq;
               gb_bus_saved_acc  <= gb_bus_acc;
               gb_bus_saved_dout <= gb_bus_dout;
            elsif (gb_bus_ena = '1') then
               gb_bus_saved <= '0';
            end if;

         end if;

      end if;
   end process;

   pcwrite_fetch <= '1' when (alu_pcwrite_wait = '1' or
                              (execute_RW_State = DATARW_PCWRITE and
                               (decode_functions_detail = data_read or
                                decode_functions_detail = block_read))) else '0';

   pcwrite_Addr <= unsigned(execute_RW_dataRead(31 downto 2) &
                            (execute_RW_dataRead(1) and execute_nextIsthumb) & '0');

   bus_AddrFetch_eff <= pcwrite_Addr when (pcwrite_fetch = '1') else bus_AddrFetch;

   adr_early <= gb_bus_saved_Adr                when (gb_bus_saved = '1') else
                std_logic_vector(bus_AddrFetch) when (bus_accessFetch = '1') else
                std_logic_vector(execute_RW_addr);

   adr_is_pcw <= bus_accessFetch and pcwrite_fetch and not gb_bus_saved;

   gb_bus_Adr <= std_logic_vector(pcwrite_Addr) when (adr_is_pcw = '1') else adr_early;


   gb_bus_rnw  <= gb_bus_saved_rnw when (gb_bus_saved = '1') else
                  '1'              when (bus_accessFetch = '1') else
                  execute_RW_rnw;

   gb_bus_acc  <= gb_bus_saved_acc when (gb_bus_saved = '1') else
                  "10"             when (bus_accessFetch = '1' and execute_nextIsthumb = '0') else
                  "01"             when (bus_accessFetch = '1' and execute_nextIsthumb = '1') else
                  execute_RW_acc;

   gb_bus_dout <= gb_bus_saved_dout when (gb_bus_saved = '1') else
                  execute_RW_data;


   gb_bus_seq  <= gb_bus_saved_seq when (gb_bus_saved = '1') else
                  '1' when (bus_accessFetch = '1' and execute_branch = '0' and execute_stall = '0' and fetch_first = '0') else
                  '1' when (execute_RW_ena = '1' and (execute_RW_State = DATARW_BLOCKREAD or execute_RW_State = DATARW_BLOCKWRITE)) else
                  '0';

   gb_bus_code <= gb_bus_saved_st1 when (gb_bus_saved = '1') else
                  '1'              when (bus_accessFetch = '1') else
                  '0';

   jump_out <= execute_branch and not execute_stall;

   bus_accessFetch <= '1' when (decode_unhalt = '1') else
                      '1' when (execute_done = '1' and decode_halt = '0') else
                      '1' when (decode_ready = '0' and decode_halt = '0') else
                      '0';

   bus_AddrFetch <= execute_branchPC_masked when (execute_branch = '1') else
                    fetch_PC;

   fetch_done <= '1' when (busState = BUSSTATE_WAITFETCH and gb_bus_done = '1') else '0';

   process (clk)
   begin
      if (rising_edge(clk)) then

         if (reset = '1') then

            fetch_PC    <= unsigned(SAVESTATE_PC_in);
            fetch_ready <= '0';
            fetch_first <= '1';

         elsif (ce = '1') then

            fetch_first <= '0';

            if (gb_bus_code = '1' and gb_bus_ena = '1') then
               if (execute_nextIsthumb = '1') then
                  fetch_PC <= bus_AddrFetch_eff + 2;
               else
                  fetch_PC <= bus_AddrFetch_eff + 4;
               end if;
            end if;

            if (fetch_done = '1') then
               fetch_data  <= gb_bus_din;
-- synthesis translate_off
               if (thumbmode = '1') then
                  fetch_data(31 downto 16) <= (others => '0');
               end if;
-- synthesis translate_on
               fetch_ready <= '1';
            end if;

            if (execute_branch = '1') then
               fetch_ready <= '0';
               if ((execute_stall = '1' and execute_done = '0') or dma_on = '1') then
                  fetch_PC <= bus_AddrFetch_eff;
               end if;
            end if;

            if (jump_out = '1') then
               SAVESTATE_PC_out <= std_logic_vector(bus_AddrFetch_eff);
            end if;

         end if;

      end if;
   end process;



   decode_data <= decode_data_1 when (execute_stall = '1') else fetch_data;

   process (clk)
      variable opcode_high3      : std_logic_vector(2 downto 0);
      variable opcode_mid        : std_logic_vector(3 downto 0);
      variable opcode_low        : std_logic_vector(3 downto 0);
      variable bitcount8_low     : integer range 0 to 8;
      variable bitcount8_high    : integer range 0 to 8;

      variable decode_functions  : tFunctions;
      variable decode_datacomb   : std_logic_vector(27 downto 0) := (others => '0');
      variable decode_blockbits  : std_logic_vector(15 downto 0) := (others => '0');

      variable opcode       : std_logic_vector(3 downto 0);
      variable use_imm      : std_logic;
      variable updateflags  : std_logic;
      variable Rn_op1       : std_logic_vector(3 downto 0);
      variable Rdest        : std_logic_vector(3 downto 0);
      variable RM_op2       : std_logic_vector(3 downto 0);
      variable OP2          : std_logic_vector(11 downto 0);

      variable rotateamount  : unsigned(4 downto 0);
      variable immidiate    : unsigned(31 downto 0);
      variable shiftcarry   : std_logic;
      variable useoldcarry  : std_logic;

      variable v5_blximm    : std_logic;
      variable v5_blxreg    : std_logic;

   begin

      if (rising_edge(clk)) then

         if (reset = '1') then

            decode_ready   <= '0';
            decode_halt    <= SAVESTATE_HALT;
            decode_unhalt  <= '0';

         elsif (ce = '1') then

            decode_unhalt <= '0';

            if (execute_done = '1') then
               decode_ready <= '0';
            end if;

            if (execute_done = '0' and fetch_done = '1') then
               decode_data_1 <= fetch_data;
            end if;

            if (new_halt = '1') then
               decode_halt <= '1';
            elsif (decode_halt = '1' and unhalt = '1') then
               decode_halt   <= '0';
               decode_unhalt <= '1';
            end if;

            if (decode_functions_detail = block_read or decode_functions_detail = block_write) then
               if (execute_RW_ena = '1') then
                  decode_blockbits := decode_block_reglist;
                  decode_blockbits(to_integer(unsigned(decode_RM_op2))) := '0';
                  decode_block_reglist <= decode_blockbits;
                  for i in 15 downto 0 loop
                     if (decode_blockbits(i) = '1') then
                        decode_RM_op2 <= std_logic_vector(to_unsigned(i,4));
                     end if;
                  end loop;
               end if;
            end if;

            if (execute_now = '1' and decode_shift_regbased = '1') then
               decode_Rn_op1 <= decode_Rn_op1_save;
               if (decode_shift_mode = "11" and unsigned(execute_op1(7 downto 0)) > 32) then
                  if (unsigned(execute_op1(4 downto 0)) = 0) then
                     decode_shift_amount <= 32;
                  else
                     decode_shift_amount <= to_integer(unsigned(execute_op1(4 downto 0)));
                  end if;
               else
                  decode_shift_amount <= to_integer(unsigned(execute_op1(7 downto 0)));
               end if;
            end if;

            if (execute_now = '1' and decode_functions_detail = mulboth) then
               decode_Rn_op1 <= decode_Rn_op1_save;
               decode_RM_op2 <= decode_rdest_save;
            end if;

            if (execute_now = '1' and decode_functions_detail = mul_dsp) then
               decode_Rn_op1 <= decode_Rn_op1_save;
            end if;
            if (execute_stall = '1' and decode_functions_detail = mul_dsp and execute_MUL_State = MUL_DSP_ACC) then
               decode_Rn_op1 <= decode_dsp_acchi;
            end if;

            if (execute_wfi = '1') then
               decode_halt <= '1';
            end if;

            if (decode_halt = '0' and fetch_ready = '1' and
                (((fetch_done = '1' and decode_ready = '0') or execute_done = '1'))) then
               decode_ready <= '1';
               decode_PC    <= fetch_PC;

               -- synthesis translate_off
               decode_opcode_export <= decode_data;
               -- synthesis translate_on

               decode_datacomb  := decode_data(27 downto 0);

               decode_clearbit1 <= '0';
               v5_blximm        := '0';
               v5_blxreg        := '0';

               bitcount8_low  := 0;
               bitcount8_high := 0;
               for i in 0 to 7 loop
                  if (decode_data(i) = '1')     then bitcount8_low  := bitcount8_low + 1;  end if;
                  if (decode_data(8 + i) = '1') then bitcount8_high := bitcount8_high + 1; end if;
               end loop;

               if (thumbmode = '0') then

                  decode_condition <= decode_data(31 downto 28);

                  opcode_high3  := decode_data(27 downto 25);
                  opcode_mid    := decode_data(24 downto 21);
                  opcode_low    := decode_data(7 downto 4);

                  case (to_integer(unsigned(opcode_high3))) is

                     when 0 =>
                        case (opcode_low) is

                           when x"1" =>
                              if (decode_data(24 downto 8) = '1' & x"2FFF") then
                                 decode_functions := branch_and_exchange;
                              elsif (opcode_mid = x"B" and decode_data(20) = '0') then
                                 decode_functions := v5_misc;
                              else
                                 decode_functions := data_processing;
                              end if;

                           when x"3" =>
                              if (opcode_mid = x"9" and decode_data(20) = '0') then
                                 decode_functions := branch_and_exchange;
                              else
                                 decode_functions := data_processing;
                              end if;

                           when x"5" =>
                              if (decode_data(24 downto 23) = "10" and decode_data(20) = '0') then
                                 decode_functions := v5_misc;
                              else
                                 decode_functions := data_processing;
                              end if;

                           when x"8" | x"A" | x"C" | x"E" =>
                              if (decode_data(24 downto 23) = "10" and decode_data(20) = '0') then
                                 decode_functions := v5_misc;
                              else
                                 decode_functions := data_processing;
                              end if;

                           when x"9" =>
                              if (unsigned(opcode_mid) >= 8) then
                                 decode_functions := single_data_swap;
                              elsif (unsigned(opcode_mid) >= 4) then
                                 decode_functions := multiply_long;
                              else
                                 decode_functions := multiply;
                              end if;

                           when x"B" | x"D" | x"F" =>
                              if (decode_data(22) = '1') then
                                 decode_functions := halfword_data_transfer_immoffset;
                              else
                                 decode_functions := halfword_data_transfer_regoffset;
                              end if;

                           when others =>
                              decode_functions := data_processing;

                        end case;

                     when 1 =>
                        decode_functions := data_processing;

                     when 2 | 3 =>
                        decode_functions := single_data_transfer;

                     when 4 =>
                        decode_functions := block_data_transfer;

                     when 5 =>
                        decode_functions := branch;

                     when 6 =>
                        decode_functions := v5_nop;

                     when 7 =>
                        if (decode_data(24) = '1') then
                           decode_functions := software_interrupt;
                        elsif (decode_data(4) = '1') then
                           decode_functions := coprocessor_op;
                        else
                           decode_functions := v5_nop;
                        end if;

                     when others => null;

                  end case;

                  if (decode_data(31 downto 28) = x"F") then
                     decode_condition <= x"E";
                     if (opcode_high3 = "101") then
                        decode_functions := branch;
                        v5_blximm        := '1';
                     else
                        decode_functions := v5_nop;
                     end if;
                  end if;

               else

                  decode_condition <= x"E";

                  case (to_integer(unsigned(decode_data(15 downto 13)))) is

                     when 0 =>
                        if (decode_data(12 downto 11) = "11") then
                           decode_datacomb(27 downto 26)  := "00";
                           decode_datacomb(25)            := decode_data(10);
                           if (decode_data(9) = '1') then
                              decode_datacomb(24 downto 21)  := x"2";
                           else
                              decode_datacomb(24 downto 21)  := x"4";
                           end if;
                           decode_datacomb(20)            := '1';
                           decode_datacomb(19 downto 16)  := '0' & decode_data(5 downto 3);
                           decode_datacomb(15 downto 12)  := '0' & decode_data(2 downto 0);
                           if (decode_data(10) = '1') then
                              decode_datacomb(11 downto  0)  := x"00" & '0' & decode_data(8 downto 6);
                           else
                              decode_datacomb(11 downto  4)  := x"00";
                              decode_datacomb( 3 downto  0)  := '0' & decode_data(8 downto 6);
                           end if;
                           decode_functions := data_processing;
                        else
                           decode_datacomb(27 downto 26)  := "00";
                           decode_datacomb(25)            := '0';
                           decode_datacomb(24 downto 21)  := x"D";
                           decode_datacomb(20)            := '1';
                           decode_datacomb(19 downto 16)  := x"0";
                           decode_datacomb(15 downto 12)  := '0' & decode_data(2 downto 0);
                           decode_datacomb(11 downto  7)  := decode_data(10 downto 6);
                           decode_datacomb( 6 downto  5)  := decode_data(12 downto 11);
                           decode_datacomb( 4)            := '0';
                           decode_datacomb( 3 downto  0)  := '0' & decode_data(5 downto 3);
                           decode_functions := data_processing;
                        end if;

                     when 1 =>
                        decode_datacomb(27 downto 26)  := "00";
                        decode_datacomb(25)            := '1';
                        case (decode_data(12 downto 11)) is
                           when "00" => decode_datacomb(24 downto 21)  := x"D";
                           when "01" => decode_datacomb(24 downto 21)  := x"A";
                           when "10" => decode_datacomb(24 downto 21)  := x"4";
                           when "11" => decode_datacomb(24 downto 21)  := x"2";
                           when others => report "should never happen" severity failure;
                        end case;
                        decode_datacomb(20)            := '1';
                        decode_datacomb(19 downto 16)  := '0' & decode_data(10 downto 8);
                        decode_datacomb(15 downto 12)  := '0' & decode_data(10 downto 8);
                        decode_datacomb(11 downto  0)  := x"0" & decode_data(7 downto 0);
                        decode_functions := data_processing;

                     when 2 =>
                        case (to_integer(unsigned(decode_data(12 downto 10)))) is

                           when 0 =>
                              decode_datacomb(27 downto 26)  := "00";
                              decode_datacomb(25)            := '0';
                              decode_datacomb(20)            := '1';
                              decode_datacomb(19 downto 16)  := '0' & decode_data(2 downto 0);
                              decode_datacomb(15 downto 12)  := '0' & decode_data(2 downto 0);
                              decode_datacomb(11 downto  0)  := x"00" & '0' & decode_data(5 downto 3);
                              decode_functions := data_processing;
                              case (decode_data(9 downto 6)) is
                                 when x"0" => decode_datacomb(24 downto 21)  := x"0";
                                 when x"1" => decode_datacomb(24 downto 21)  := x"1";

                                 when x"2" =>
                                    decode_datacomb(24 downto 21)  := x"D";
                                    decode_datacomb(11 downto  0)  := '0' & decode_data(5 downto 3) & "0001" & '0' & decode_data(2 downto 0);

                                 when x"3" =>
                                    decode_datacomb(24 downto 21)  := x"D";
                                    decode_datacomb(11 downto  0)  := '0' & decode_data(5 downto 3) & "0011" & '0' & decode_data(2 downto 0);

                                 when x"4" =>
                                    decode_datacomb(24 downto 21)  := x"D";
                                    decode_datacomb(11 downto  0)  := '0' & decode_data(5 downto 3) & "0101" & '0' & decode_data(2 downto 0);

                                 when x"5" => decode_datacomb(24 downto 21)  := x"5";
                                 when x"6" => decode_datacomb(24 downto 21)  := x"6";

                                 when x"7" =>
                                    decode_datacomb(24 downto 21)  := x"D";
                                    decode_datacomb(11 downto  0)  := '0' & decode_data(5 downto 3) & "0111" & '0' & decode_data(2 downto 0);

                                 when x"8" => decode_datacomb(24 downto 21)  := x"8";

                                 when x"9" =>
                                    decode_datacomb(24 downto 21)  := x"3";
                                    decode_datacomb(25)            := '1';
                                    decode_datacomb(11 downto  0)  := x"000";
                                    decode_datacomb(19 downto 16)  := '0' & decode_data(5 downto 3);

                                 when x"A" => decode_datacomb(24 downto 21)  := x"A";
                                 when x"B" => decode_datacomb(24 downto 21)  := x"B";
                                 when x"C" => decode_datacomb(24 downto 21)  := x"C";

                                 when x"D" =>
                                    decode_datacomb(27 downto 20)  := x"01";
                                    decode_datacomb( 7 downto  4)  := x"9";
                                    decode_datacomb(11 downto  8)  := '0' & decode_data(2 downto 0);
                                    decode_functions := multiply;

                                 when x"E" => decode_datacomb(24 downto 21)  := x"E";
                                 when x"F" => decode_datacomb(24 downto 21)  := x"F";
                                 when others => report "should never happen" severity failure;
                              end case;


                           when 1 =>
                              decode_datacomb(27 downto 26)  := "00";
                              decode_datacomb(25)            := '0';
                              decode_datacomb(20)            := '0';
                              decode_datacomb(19 downto 16)  := '0' & decode_data(2 downto 0);
                              decode_datacomb(15 downto 12)  := '0' & decode_data(2 downto 0);
                              decode_datacomb(11 downto  0)  := x"00" & '0' & decode_data(5 downto 3);
                              decode_functions               := data_processing;
                              case (decode_data(9 downto 6)) is
                                 when x"1" => decode_datacomb(24 downto 21) := x"4"; decode_datacomb( 3) := '1';
                                 when x"2" => decode_datacomb(24 downto 21) := x"4"; decode_datacomb(19) := '1'; decode_datacomb(15) := '1';
                                 when x"3" => decode_datacomb(24 downto 21) := x"4"; decode_datacomb( 3) := '1'; decode_datacomb(19) := '1'; decode_datacomb(15) := '1';

                                 when x"5" => decode_datacomb(24 downto 21) := x"A"; decode_datacomb( 3) := '1';                                                         decode_datacomb(20) := '1';
                                 when x"6" => decode_datacomb(24 downto 21) := x"A"; decode_datacomb(19) := '1'; decode_datacomb(15) := '1';                             decode_datacomb(20) := '1';
                                 when x"7" => decode_datacomb(24 downto 21) := x"A"; decode_datacomb( 3) := '1'; decode_datacomb(19) := '1'; decode_datacomb(15) := '1'; decode_datacomb(20) := '1';

                                 when x"8" => decode_datacomb(24 downto 21) := x"D";
                                 when x"9" => decode_datacomb(24 downto 21) := x"D"; decode_datacomb( 3) := '1';
                                 when x"A" => decode_datacomb(24 downto 21) := x"D"; decode_datacomb(19) := '1'; decode_datacomb(15) := '1';
                                 when x"B" => decode_datacomb(24 downto 21) := x"D"; decode_datacomb( 3) := '1'; decode_datacomb(19) := '1'; decode_datacomb(15) := '1';

                                 when x"C" => decode_functions := branch_and_exchange;
                                 when x"D" => decode_functions := branch_and_exchange; decode_datacomb(3) := '1';
                                 when x"E" => decode_functions := branch_and_exchange; v5_blxreg := '1';
                                 when x"F" => decode_functions := branch_and_exchange; v5_blxreg := '1'; decode_datacomb(3) := '1';

                                 when others => null;
                              end case;


                           when 2 | 3 =>
                              decode_datacomb(27 downto 26)  := "01";
                              decode_datacomb(25)            := '0';
                              decode_datacomb(24)            := '1';
                              decode_datacomb(23)            := '1';
                              decode_datacomb(22)            := '0';
                              decode_datacomb(21)            := '0';
                              decode_datacomb(20)            := decode_data(11);
                              decode_datacomb(19 downto 16)  := x"F";
                              decode_datacomb(15 downto 12)  := '0' & decode_data(10 downto 8);
                              decode_datacomb(11 downto  0)  := "00" & decode_data(7 downto 0) & "00";
                              decode_functions := single_data_transfer;

                           when 4 | 5 | 6 | 7 =>
                              if (decode_data(9) = '0') then
                                 decode_datacomb(27 downto 26)  := "01";
                                 decode_datacomb(25)            := '1';
                                 decode_datacomb(24)            := '1';
                                 decode_datacomb(23)            := '1';
                                 decode_datacomb(22)            := decode_data(10);
                                 decode_datacomb(21)            := '0';
                                 decode_datacomb(20)            := decode_data(11);
                                 decode_datacomb(19 downto 16)  := '0' & decode_data(5 downto 3);
                                 decode_datacomb(15 downto 12)  := '0' & decode_data(2 downto 0);
                                 decode_datacomb(11 downto  4)  := x"00";
                                 decode_datacomb( 3 downto  0)  := '0' & decode_data(8 downto 6);
                                 decode_functions := single_data_transfer;
                              else
                                 decode_datacomb(27 downto 25)  := "000";
                                 decode_datacomb(24)            := '1';
                                 decode_datacomb(23)            := '1';
                                 decode_datacomb(22)            := '1';
                                 decode_datacomb(21)            := '0';
                                 decode_datacomb(19 downto 16)  := '0' & decode_data(5 downto 3);
                                 decode_datacomb(15 downto 12)  := '0' & decode_data(2 downto 0);
                                 decode_datacomb(11 downto  8)  := "0000";
                                 decode_datacomb( 7)            := '1';
                                 decode_datacomb( 4)            := '1';
                                 decode_datacomb( 3 downto  0)  := '0' & decode_data(8 downto 6);
                                 case (decode_data(11 downto 10)) is
                                    when "00" => decode_datacomb(20) := '0'; decode_datacomb(6) := '0'; decode_datacomb(5) := '1';
                                    when "01" => decode_datacomb(20) := '1'; decode_datacomb(6) := '1'; decode_datacomb(5) := '0';
                                    when "10" => decode_datacomb(20) := '1'; decode_datacomb(6) := '0'; decode_datacomb(5) := '1';
                                    when "11" => decode_datacomb(20) := '1'; decode_datacomb(6) := '1'; decode_datacomb(5) := '1';
                                    when others => null;
                                 end case;
                                 decode_functions := halfword_data_transfer_regoffset;
                              end if;

                           when others => report "should never happen" severity failure;

                        end case;

                     when 3 =>
                        decode_datacomb(27 downto 26)  := "01";
                        decode_datacomb(25)            := '0';
                        decode_datacomb(24)            := '1';
                        decode_datacomb(23)            := '1';
                        decode_datacomb(22)            := decode_data(12);
                        decode_datacomb(21)            := '0';
                        decode_datacomb(20)            := decode_data(11);
                        decode_datacomb(19 downto 16)  := '0' & decode_data(5 downto 3);
                        decode_datacomb(15 downto 12)  := '0' & decode_data(2 downto 0);
                        if (decode_data(12) = '1') then
                           decode_datacomb(11 downto  0)  := "0000000" & decode_data(10 downto 6);
                        else
                           decode_datacomb(11 downto  0)  := "00000" & decode_data(10 downto 6) & "00";
                        end if;
                        decode_functions := single_data_transfer;

                     when 4 =>
                        if (decode_data(12) = '0') then
                           decode_datacomb(27 downto 25)  := "000";
                           decode_datacomb(24)            := '1';
                           decode_datacomb(23)            := '1';
                           decode_datacomb(22)            := '1';
                           decode_datacomb(21)            := '0';
                           decode_datacomb(20)            := decode_data(11);
                           decode_datacomb(19 downto 16)  := '0' & decode_data(5 downto 3);
                           decode_datacomb(15 downto 12)  := '0' & decode_data(2 downto 0);
                           decode_datacomb(11 downto  8)  := "00" & decode_data(10 downto 9);
                           decode_datacomb( 7)            := '1';
                           decode_datacomb( 6)            := '0';
                           decode_datacomb( 5)            := '1';
                           decode_datacomb( 4)            := '1';
                           decode_datacomb( 3 downto  0)  := decode_data(8 downto 6) & '0';
                           decode_functions := halfword_data_transfer_immoffset;
                        else
                           decode_datacomb(27 downto 26)  := "01";
                           decode_datacomb(25)            := '0';
                           decode_datacomb(24)            := '1';
                           decode_datacomb(23)            := '1';
                           decode_datacomb(22)            := '0';
                           decode_datacomb(21)            := '0';
                           decode_datacomb(20)            := decode_data(11);
                           decode_datacomb(19 downto 16)  := x"D";
                           decode_datacomb(15 downto 12)  := '0' & decode_data(10 downto 8);
                           decode_datacomb(11 downto  0)  := "00" & decode_data(7 downto 0) & "00";
                           decode_functions := single_data_transfer;
                        end if;

                     when 5 =>
                        if (decode_data(12) = '0') then
                           decode_datacomb(27 downto 26)  := "00";
                           decode_datacomb(25)            := '1';
                           decode_datacomb(24 downto 21)  := x"4";
                           decode_datacomb(20)            := '0';
                           if (decode_data(11) = '1') then
                              decode_datacomb(19 downto 16)  := x"D";
                           else
                              decode_datacomb(19 downto 16)  := x"F";
                              decode_clearbit1               <= '1';
                           end if;
                           decode_datacomb(15 downto 12)  := '0' & decode_data(10 downto 8);
                           decode_datacomb(11 downto  0)  := x"F" & decode_data(7 downto 0);
                           decode_functions := data_processing;
                        else
                           if (decode_data(10) = '0') then
                              decode_datacomb(27 downto 26)  := "00";
                              decode_datacomb(25)            := '1';
                              if (decode_data(7) = '1') then
                                 decode_datacomb(24 downto 21)  := x"2";
                              else
                                 decode_datacomb(24 downto 21)  := x"4";
                              end if;
                              decode_datacomb(20)            := '0';
                              decode_datacomb(19 downto 16)  := x"D";
                              decode_datacomb(15 downto 12)  := x"D";
                              decode_datacomb(11 downto  0)  := x"F" & '0' & decode_data(6 downto 0);
                              decode_functions := data_processing;
                           else
                              decode_datacomb(27 downto 25)  := "100";
                              decode_datacomb(22)            := '0';
                              decode_datacomb(21)            := '1';
                              decode_datacomb(20)            := decode_data(11);
                              decode_datacomb(15 downto 0)   := x"00" & decode_data(7 downto 0);
                              decode_datacomb(19 downto 16)  := x"D";
                              bitcount8_high := 0;
                              if (decode_data(8) = '1') then
                                 bitcount8_high := 1;
                                 if (decode_data(11) = '1') then
                                    decode_datacomb(15) := '1';
                                 else
                                    decode_datacomb(14) := '1';
                                 end if;
                              end if;
                              decode_datacomb(24) := not decode_data(11);
                              decode_datacomb(23) := decode_data(11);
                              decode_functions := block_data_transfer;
                           end if;
                        end if;

                     when 6 =>
                        if (decode_data(12) = '0') then
                           decode_datacomb(27 downto 25)  := "100";
                           decode_datacomb(24)            := '0';
                           decode_datacomb(23)            := '1';
                           decode_datacomb(22)            := '0';
                           decode_datacomb(21)            := '1';
                           decode_datacomb(20)            := decode_data(11);
                           decode_datacomb(19 downto 16)  := '0' & decode_data(10 downto 8);
                           decode_datacomb(15 downto 0)   := x"00" & decode_data(7 downto 0);
                           bitcount8_high                 := 0;
                           decode_functions               := block_data_transfer;
                        else
                           if (decode_data(11 downto 8) = x"F") then
                              decode_functions := software_interrupt;
                           else
                              decode_datacomb(27 downto 25) := "101";
                              decode_datacomb(24)           := '0';
                              decode_datacomb(23 downto 0)  := std_logic_vector(resize(signed(decode_data(7 downto 0)), 24));
                              decode_condition              <= decode_data(11 downto 8);
                              decode_functions := branch;
                           end if;
                        end if;

                     when 7 =>
                        if (decode_data(12) = '0') then
                           if (decode_data(11) = '1') then
                              decode_datacomb(11) := '1';
                              decode_functions    := long_branch_with_link;
                              v5_blxreg           := '1';
                           else
                              decode_datacomb(27 downto 25) := "101";
                              decode_datacomb(24)           := '0';
                              decode_datacomb(23 downto 0)  := std_logic_vector(resize(signed(decode_data(10 downto 0)), 24));
                              decode_functions := branch;
                           end if;
                        else
                           decode_functions := long_branch_with_link;
                        end if;

                     when others => report "should never happen" severity failure;

                  end case;

               end if;


               use_imm       := decode_datacomb(25);
               updateflags   := decode_datacomb(20);
               Rn_op1        := decode_datacomb(19 downto 16);
               Rdest         := decode_datacomb(15 downto 12);
               RM_op2        := decode_datacomb(3 downto 0);
               OP2           := decode_datacomb(11 downto 0);
               opcode        := decode_datacomb(24 downto 21);

               decode_updateflags            <= '1';
               decode_alu_use_immi           <= '0';
               decode_alu_use_shift          <= '0';
               decode_switch_op              <= '0';
               decode_datatransfer_shiftval  <= '0';
               decode_datatransfer_regoffset <= '0';
               decode_datatransfer_swap      <= '0';
               decode_datatransfer_writeback <= '0';
               decode_leaveirp               <= '0';
               decode_branch_long            <= '0';
               decode_set_thumbmode          <= '0';
               decode_writeback              <= '0';
               decode_datatransfer_double    <= '0';
               decode_branch_forcethumb      <= '0';
               decode_branch_forcearm        <= '0';

               decode_shift_regbased   <= '0';
               decode_shift_mode       <= decode_datacomb(6 downto 5);
               decode_shift_amount     <= to_integer(unsigned(decode_datacomb(11 downto 7)));
               decode_shift_RRX        <= '0';

               if (decode_datacomb(4) = '0') then
                  if ((decode_datacomb(6 downto 5) = "01" or decode_datacomb(6 downto 5) = "10") and decode_datacomb(11 downto 7) = "00000") then
                     decode_shift_amount <= 32;
                  end if;

                  if (decode_datacomb(6 downto 5) = "11" and decode_datacomb(11 downto 7) = "00000") then
                     decode_shift_RRX <= '1';
                  end if;
               end if;

               case (decode_functions) is
                  when data_processing =>

                     rotateamount := unsigned(Op2(11 downto 8)) & '0';
                     immidiate   := x"000000" & unsigned(Op2(7 downto 0));

                     useoldcarry := '0';
                     shiftcarry  := '0';
                     if (rotateamount = 0) then
                        useoldcarry := '1';
                     else
                        shiftcarry  := immidiate(to_integer(rotateamount) - 1);
                     end if;

                     immidiate   := immidiate ror to_integer(rotateamount);

                     decode_rdest            <= Rdest;
                     decode_Rn_op1           <= Rn_op1;
                     decode_Rn_op1_save      <= Rn_op1;
                     decode_RM_op2           <= RM_op2;
                     decode_alu_use_immi     <= use_imm;
                     decode_immidiate        <= immidiate;
                     decode_shiftcarry       <= shiftcarry;
                     decode_useoldcarry      <= useoldcarry;
                     decode_updateflags      <= updateflags;

                     decode_alu_use_immi     <= use_imm;
                     decode_alu_use_shift    <= not use_imm;

                     if (use_imm = '0') then
                        decode_shift_regbased   <= decode_datacomb(4);
                        if (decode_datacomb(4) = '1') then
                           decode_Rn_op1 <= decode_datacomb(11 downto 8);
                        end if;
                     end if;

                     if (updateflags = '0' and unsigned(opcode) >= 8 and unsigned(opcode) <= 11) then

                        decode_psr_with_spsr    <= decode_datacomb(22);

                        if (decode_datacomb(21 downto 16) = "001111") then
                           decode_functions_detail <= data_processing_MRS;
                        else
                           decode_functions_detail <= data_processing_MSR;
                        end if;

                     else

                        case opcode is
                           when x"0" => decode_functions_detail <= alu_and;           decode_writeback <= '1'; decode_switch_op <= '0';
                           when x"1" => decode_functions_detail <= alu_xor;           decode_writeback <= '1'; decode_switch_op <= '0';
                           when x"2" => decode_functions_detail <= alu_sub;           decode_writeback <= '1'; decode_switch_op <= '0';
                           when x"3" => decode_functions_detail <= alu_sub;           decode_writeback <= '1'; decode_switch_op <= '1';
                           when x"4" => decode_functions_detail <= alu_add;           decode_writeback <= '1'; decode_switch_op <= '0';
                           when x"5" => decode_functions_detail <= alu_add_withcarry; decode_writeback <= '1'; decode_switch_op <= '0';
                           when x"6" => decode_functions_detail <= alu_sub_withcarry; decode_writeback <= '1'; decode_switch_op <= '0';
                           when x"7" => decode_functions_detail <= alu_sub_withcarry; decode_writeback <= '1'; decode_switch_op <= '1';
                           when x"8" => decode_functions_detail <= alu_and;           decode_writeback <= '0'; decode_switch_op <= '0';
                           when x"9" => decode_functions_detail <= alu_xor;           decode_writeback <= '0'; decode_switch_op <= '0';
                           when x"A" => decode_functions_detail <= alu_sub;           decode_writeback <= '0'; decode_switch_op <= '0';
                           when x"B" => decode_functions_detail <= alu_add;           decode_writeback <= '0'; decode_switch_op <= '0';
                           when x"C" => decode_functions_detail <= alu_or;            decode_writeback <= '1'; decode_switch_op <= '0';
                           when x"D" => decode_functions_detail <= alu_mov;           decode_writeback <= '1'; decode_switch_op <= '0';
                           when x"E" => decode_functions_detail <= alu_and_not;       decode_writeback <= '1'; decode_switch_op <= '0';
                           when x"F" => decode_functions_detail <= alu_mov_not;       decode_writeback <= '1'; decode_switch_op <= '0';
                           when others => report "should never happen" severity failure;
                        end case;

                        if (Rdest = x"F" and updateflags = '1') then
                           decode_leaveirp <= '1';
                        end if;

                     end if;

                  when multiply | multiply_long =>
                     decode_functions_detail <= mulboth;
                     decode_rdest            <= decode_datacomb(19 downto 16);
                     decode_rdest_save       <= Rdest;
                     decode_Rn_op1           <= decode_datacomb(3 downto 0);
                     decode_Rn_op1_save      <= Rn_op1;
                     decode_RM_op2           <= decode_datacomb(11 downto 8);
                     decode_updateflags      <= decode_datacomb(20);
                     decode_mul_signed       <= decode_datacomb(22);
                     decode_mul_useadd       <= decode_datacomb(21);
                     decode_mul_long         <= '0';
                     if (decode_functions = multiply_long) then
                        decode_mul_long <= '1';
                     end if;

                  when branch =>
                     decode_functions_detail <= branch_all;
                     decode_branch_link      <= decode_datacomb(24);
                     if (thumbmode = '1') then
                        decode_branch_immi   <= resize(signed(decode_datacomb(23 downto 0)), 25) & "0";
                     else
                        decode_branch_immi   <= signed(decode_datacomb(23 downto 0)) & "00";
                     end if;
                     decode_rdest            <= x"E";
                     decode_branch_usereg    <= '0';
                     if (v5_blximm = '1') then
                        decode_branch_link       <= '1';
                        decode_branch_forcethumb <= '1';
                        decode_branch_immi       <= signed(decode_datacomb(23 downto 0)) & decode_data(24) & '0';
                     end if;

                  when branch_and_exchange =>
                     decode_functions_detail <= branch_all;
                     decode_set_thumbmode    <= '1';
                     decode_RM_op2           <= RM_op2;
                     decode_branch_usereg    <= '1';
                     decode_branch_link      <= '0';
                     if (thumbmode = '0' and decode_datacomb(5) = '1') then
                        decode_branch_link <= '1';
                     end if;
                     if (thumbmode = '1' and v5_blxreg = '1') then
                        decode_branch_link <= '1';
                        decode_branch_long <= '1';
                        decode_immidiate   <= (others => '0');
                     end if;

                  when single_data_transfer | halfword_data_transfer_regoffset | halfword_data_transfer_immoffset | single_data_swap =>
                     if (decode_datacomb(20) = '1') then
                        decode_functions_detail <= data_read;
                     else
                        decode_functions_detail <= data_write;
                     end if;
                     decode_RM_op2 <= RM_op2;
                     decode_Rn_op1 <= Rn_op1;
                     decode_rdest  <= Rdest;

                     decode_datatransfer_preadd    <= opcode(3);
                     decode_datatransfer_addup     <= opcode(2);
                     decode_datatransfer_writeback <= (not opcode(3)) or opcode(0);
                     if (Rn_op1 = Rdest and decode_datacomb(20) = '1') then
                        decode_datatransfer_writeback <= '0';
                     end if;

                     if (Rn_op1 = x"F") then
                        decode_clearbit1 <= '1';
                     end if;

                     decode_datatransfer_shiftval  <= '0';
                     decode_datatransfer_regoffset <= '0';
                     decode_datatransfer_swap      <= '0';
                     decode_datatransfer_addvalue  <= (others => '0');

                     if (decode_functions = single_data_transfer) then
                        decode_datatransfer_addvalue  <= unsigned(op2);
                        decode_datatransfer_shiftval  <= use_imm;
                        decode_datatransfer_regoffset <= use_imm;
                        if (opcode(1) = '1') then
                           decode_datatransfer_type <= ACCESS_8BIT;
                           decode_datareceivetype   <= RECEIVETYPE_BYTE;
                        else
                           decode_datatransfer_type <= ACCESS_32BIT;
                           decode_datareceivetype   <= RECEIVETYPE_DWORD;
                        end if;

                        if (use_imm = '1') then
                           decode_shift_regbased   <= decode_datacomb(4);
                           if (decode_datacomb(4) = '1') then
                              decode_Rn_op1 <= decode_datacomb(11 downto 8);
                           end if;
                        end if;

                     elsif (decode_functions = halfword_data_transfer_regoffset or decode_functions = halfword_data_transfer_immoffset) then
                        case (decode_datacomb(6 downto 5)) is
                           when "01" => decode_datatransfer_type <= ACCESS_16BIT; decode_datareceivetype <= RECEIVETYPE_WORD;
                           when "10" => decode_datatransfer_type <= ACCESS_8BIT;  decode_datareceivetype <= RECEIVETYPE_SIGNEDBYTE;
                           when "11" => decode_datatransfer_type <= ACCESS_16BIT; decode_datareceivetype <= RECEIVETYPE_SIGNEDWORD;
                           when others => report "should never happen" severity failure;
                        end case;
                        if (decode_datacomb(20) = '0' and decode_datacomb(6) = '1') then
                           if (decode_datacomb(5) = '0') then
                              decode_functions_detail <= data_read;
                           else
                              decode_functions_detail <= data_write;
                           end if;
                           decode_datatransfer_double <= '1';
                           decode_datatransfer_type   <= ACCESS_32BIT;
                           decode_datareceivetype     <= RECEIVETYPE_DWORD;
                        end if;
                        decode_datatransfer_addvalue <= x"0" & unsigned(decode_datacomb(11 downto 8)) & unsigned(decode_datacomb(3 downto 0));
                        if (decode_functions = halfword_data_transfer_regoffset) then
                           decode_datatransfer_regoffset <= '1';
                        end if;
                     elsif (decode_functions = single_data_swap) then
                        decode_datatransfer_writeback <= '0';
                        decode_functions_detail       <= data_read;
                        decode_datatransfer_swap      <= '1';
                        if (opcode(1) = '1') then
                           decode_datatransfer_type <= ACCESS_8BIT;
                           decode_datareceivetype   <= RECEIVETYPE_BYTE;
                        else
                           decode_datatransfer_type <= ACCESS_32BIT;
                           decode_datareceivetype   <= RECEIVETYPE_DWORD;
                        end if;
                     end if;

                  when block_data_transfer  =>
                     if (decode_datacomb(20) = '1') then
                        decode_functions_detail <= block_read;
                     else
                        decode_functions_detail <= block_write;
                     end if;

                     decode_Rn_op1                 <= Rn_op1;
                     decode_block_reglist          <= decode_datacomb(15 downto 0);
                     decode_blockbits              := decode_datacomb(15 downto 0);
                     decode_datatransfer_preadd    <= opcode(3);
                     decode_datatransfer_addup     <= opcode(2);
                     decode_datatransfer_writeback <= opcode(0);
                     if (decode_datacomb(to_integer(unsigned(Rn_op1))) = '1' and decode_datacomb(20) = '1') then
                        decode_datatransfer_writeback <= '0';
                     end if;
                     if (decode_blockbits = x"0000") then
                        decode_block_reglist(15) <= '1';
                        decode_block_emptylist   <= '1';
                     else
                        decode_block_emptylist   <= '0';
                     end if;

                     decode_block_usermoderegs <= '0';
                     decode_block_switchmode   <= '0';
                     if (opcode(1) = '1') then
                        if ((decode_datacomb(15) = '1' and decode_datacomb(20) = '0') or (decode_datacomb(15) = '0')) then
                           decode_block_usermoderegs <= '1';
                        end if;
                        if (decode_datacomb(15) = '1' and decode_datacomb(20) = '1') then
                           decode_block_switchmode <= '1';
                        end if;
                     end if;

                     decode_block_addrmod <= 0;
                     decode_block_endmod  <= 0;
                     if (opcode(2) = '0') then
                        if (decode_blockbits = x"0000") then
                           decode_block_endmod  <= -64;
                           decode_block_addrmod <= -64;
                           if (opcode(3) = '0') then
                              decode_block_addrmod <= -60;
                           end if;
                        else
                           decode_block_endmod <= (-4) * (bitcount8_low + bitcount8_high);
                           if (opcode(3) = '0') then
                              decode_block_addrmod <= ((-4) * (bitcount8_low + bitcount8_high)) + 4;
                           else
                              decode_block_addrmod <= (-4) * (bitcount8_low + bitcount8_high);
                           end if;
                           decode_block_addrmod_baseRlist <= (-4) * (bitcount8_low + bitcount8_high);
                        end if;
                     elsif (opcode(3) = '1') then
                        decode_block_addrmod <= 4;
                     end if;
                     if (opcode(2) = '1') then
                        decode_block_addrmod_baseRlist <= 4 * (bitcount8_low + bitcount8_high);
                        decode_block_endmod <= 4 * (bitcount8_low + bitcount8_high);
                        if (decode_blockbits = x"0000") then
                           decode_block_endmod <= 64;
                        end if;
                     end if;

                     decode_RM_op2 <= x"F";
                     for i in 15 downto 0 loop
                        if (decode_blockbits(i) = '1') then
                           decode_RM_op2 <= std_logic_vector(to_unsigned(i,4));
                        end if;
                     end loop;



                  when software_interrupt =>
                     decode_functions_detail <= software_interrupt_detail;
                     decode_rdest            <= x"E";


                  when long_branch_with_link =>
                     if (decode_datacomb(11) = '0') then
                        decode_functions_detail <= alu_add;
                        decode_writeback        <= '1';
                        decode_rdest            <= x"E";
                        decode_Rn_op1           <= x"F";
                        decode_alu_use_immi     <= '1';
                        decode_updateflags      <= '0';
                        decode_immidiate        <= unsigned(resize(signed(decode_datacomb(10 downto 0)), 20)) & x"000";
                     else
                        decode_functions_detail <= branch_all;
                        decode_RM_op2           <= x"E";
                        decode_immidiate        <= x"00000" & "0" & unsigned(decode_datacomb(10 downto 0));
                        decode_branch_long      <= '1';
                        decode_branch_link      <= '1';
                        if (v5_blxreg = '1') then
                           decode_branch_forcearm <= '1';
                        end if;
                     end if;


                  when v5_misc =>
                     decode_updateflags <= '0';
                     if (decode_datacomb(7 downto 4) = x"1") then
                        decode_functions_detail <= alu_clz;
                        decode_rdest  <= Rdest;
                        decode_RM_op2 <= RM_op2;
                     elsif (decode_datacomb(7 downto 4) = x"5") then
                        decode_functions_detail <= sat_arith;
                        decode_rdest      <= Rdest;
                        decode_RM_op2     <= RM_op2;
                        decode_Rn_op1     <= Rn_op1;
                        decode_sat_sub    <= decode_datacomb(21);
                        decode_sat_double <= decode_datacomb(22);
                     else
                        decode_functions_detail <= mul_dsp;
                        decode_rdest       <= Rn_op1;
                        decode_RM_op2      <= RM_op2;
                        decode_Rn_op1      <= decode_datacomb(11 downto 8);
                        decode_Rn_op1_save <= Rdest;
                        decode_dsp_acchi   <= Rn_op1;
                        decode_dsp_x       <= decode_datacomb(5);
                        decode_dsp_y       <= decode_datacomb(6);
                        decode_dsp_acc     <= '0';
                        decode_dsp_long    <= '0';
                        decode_dsp_word    <= '0';
                        case decode_datacomb(22 downto 21) is
                           when "00"   => decode_dsp_acc  <= '1';
                           when "01"   => decode_dsp_word <= '1';
                                          decode_dsp_acc  <= not decode_datacomb(5);
                           when "10"   => decode_dsp_long <= '1';
                                          decode_dsp_acc  <= '1';
                           when others => null;
                        end case;
                     end if;

                  when coprocessor_op =>
                     decode_functions_detail <= cp15_op;
                     decode_updateflags <= '0';
                     decode_rdest       <= Rdest;
                     decode_cp15_mrc    <= decode_datacomb(20);
                     decode_cp15_crn    <= Rn_op1;
                     decode_cp15_crm    <= RM_op2;
                     decode_cp15_op2    <= decode_datacomb(7 downto 5);
                     if (decode_datacomb(11 downto 8) /= x"F" or decode_datacomb(23 downto 21) /= "000") then
                        decode_functions_detail <= nop_detail;
                     end if;

                  when v5_nop =>
                     decode_functions_detail <= nop_detail;
                     decode_updateflags <= '0';

               end case;

            end if;

            if (IRQ_in = '1' and IRQ_disable = '0' and (busState /= BUSSTATE_WAITFETCH or gb_bus_done = '1') and (decode_functions_detail /= IRQ or execute_now = '0')) then
               if (decode_unhalt = '1') then
                  decode_ready  <= '1';
               end if;
               if (decode_unhalt = '1' or execute_done = '1' or (execute_now = '0' and execute_stall = '0')) then
                  decode_functions_detail <= IRQ;
                  decode_condition        <= x"E";
                  decode_rdest            <= x"E";
                  if (decode_unhalt = '1') then
                     if (decode_ready = '0') then
                        decode_PC <= fetch_PC;
                     end if;
                  elsif (fetch_done = '1') then
                     decode_PC <= fetch_PC;
                  end if;
               end if;
            end if;

            if (execute_branch = '1') then
               decode_ready <= '0';
            end if;

         end if;

      end if;

   end process;



   process (all)
   begin
      if (decode_Rn_op1 = x"F") then
         if (execute_stall = '1') then
            execute_op1 <= fetch_PC;
         else
            execute_op1 <= decode_PC;
         end if;
      else
         execute_op1 <= regs(to_integer(unsigned(decode_Rn_op1)));
      end if;
      if (decode_clearbit1 = '1') then
         execute_op1(1) <= '0';
      end if;

      if (decode_alu_use_immi = '1') then
         execute_op2 <= decode_immidiate;
      elsif  (decode_RM_op2 = x"F") then
         if (execute_stall = '1' or decode_functions_detail = block_write) then
            execute_op2 <= fetch_PC;
         else
            execute_op2 <= decode_PC;
         end if;
      else
         execute_op2  <= regs(to_integer(unsigned(decode_RM_op2)));
      end if;

      if (decode_rdest = x"F") then
         if (execute_stall = '1') then
            execute_opDest <= fetch_PC;
         else
            execute_opDest <= decode_PC;
         end if;
      else
         execute_opDest <= regs(to_integer(unsigned(decode_rdest)));
      end if;

   end process;

   shiftervalue <= execute_op2;

   process (all)
      variable n : integer range 0 to 255;
   begin
      n       := decode_shift_amount;

      sh_rot  <= 0;
      sh_keep <= (others => '1');
      sh_fill <= FILL_ZERO;
      sh_cidx <= 0;
      sh_csel <= CSEL_CARRY;

      if (decode_shift_RRX = '1') then
         sh_rot  <= 1;
         sh_keep <= (31 => '0', others => '1');
         sh_fill <= FILL_CARRY;
         sh_csel <= CSEL_VALUE;
         sh_cidx <= 0;

      elsif (n /= 0) then
         case (decode_shift_mode) is

            when "00" =>
               if (n < 32) then
                  sh_rot  <= 32 - n;
                  for i in 0 to 31 loop
                     if (i < n) then sh_keep(i) <= '0'; end if;
                  end loop;
                  sh_csel <= CSEL_VALUE;
                  sh_cidx <= 32 - n;
               else
                  sh_keep <= (others => '0');
                  if (n = 32) then
                     sh_csel <= CSEL_VALUE;
                     sh_cidx <= 0;
                  else
                     sh_csel <= CSEL_ZERO;
                  end if;
               end if;

            when "01" =>
               if (n < 32) then
                  sh_rot  <= n;
                  for i in 0 to 31 loop
                     if (i > 31 - n) then sh_keep(i) <= '0'; end if;
                  end loop;
                  sh_csel <= CSEL_VALUE;
                  sh_cidx <= n - 1;
               else
                  sh_keep <= (others => '0');
                  if (n = 32) then
                     sh_csel <= CSEL_VALUE;
                     sh_cidx <= 31;
                  else
                     sh_csel <= CSEL_ZERO;
                  end if;
               end if;

            when "10" =>
               sh_fill <= FILL_SIGN;
               sh_csel <= CSEL_VALUE;
               if (n < 32) then
                  sh_rot  <= n;
                  for i in 0 to 31 loop
                     if (i > 31 - n) then sh_keep(i) <= '0'; end if;
                  end loop;
                  sh_cidx <= n - 1;
               else
                  sh_keep <= (others => '0');
                  sh_cidx <= 31;
               end if;

            when others =>
               sh_csel <= CSEL_VALUE;
               if (n < 32) then
                  sh_rot  <= n;
                  sh_cidx <= n - 1;
               else
                  sh_rot  <= 0;
                  sh_cidx <= 31;
               end if;

         end case;
      end if;
   end process;

   sh_rotv  <= shiftervalue ror sh_rot;
   sh_fillb <= Flag_Carry       when sh_fill = FILL_CARRY else
               shiftervalue(31) when sh_fill = FILL_SIGN  else '0';

   gshiftbit : for i in 0 to 31 generate
      shiftresult(i) <= sh_rotv(i) when sh_keep(i) = '1' else sh_fillb;
   end generate;

   shiftercarry <= Flag_Carry            when sh_csel = CSEL_CARRY else
                   shiftervalue(sh_cidx) when sh_csel = CSEL_VALUE else '0';

   alu_op1 <= shiftresult when (decode_switch_op = '1' and decode_alu_use_shift = '1') else
              execute_op2 when (decode_switch_op = '1' and decode_alu_use_shift = '0') else
              execute_op1;

   alu_op2 <= shiftresult when (decode_switch_op = '0' and decode_alu_use_shift = '1') else
              execute_op2 when (decode_switch_op = '0' and decode_alu_use_shift = '0') else
              execute_op1;

   process (all)
      variable adc_wide : unsigned(33 downto 0);
      variable sub_wide : unsigned(33 downto 0);
      variable sub_cin  : std_logic;
   begin
      adc_wide := ('0' & alu_op1 & '1') + ('0' & alu_op2 & Flag_Carry);
      sub_cin := Flag_Carry;
      if (decode_functions_detail = alu_sub) then
         sub_cin := '1';
      end if;
      sub_wide := ('0' & alu_op1 & '1') + ('0' & (not alu_op2) & sub_cin);
      alu_result     <= (others => '0');
      alu_result_add <= (others => '0');
      case (decode_functions_detail) is
         when alu_and =>     alu_result <= alu_op1 and alu_op2;
         when alu_xor =>     alu_result <= alu_op1 xor alu_op2;
         when alu_or  =>     alu_result <= alu_op1  or alu_op2;
         when alu_and_not => alu_result <= alu_op1 and (not alu_op2);
         when alu_mov =>     alu_result <= alu_op2;
         when alu_mov_not => alu_result <= not alu_op2;

         when alu_add =>
            alu_result_add <= ('0' & alu_op1) + ('0' & alu_op2);
            alu_result <= alu_result_add(31 downto 0);

         when alu_sub =>
            alu_result <= sub_wide(32 downto 1);

         when alu_add_withcarry =>
            alu_result_add <= adc_wide(33 downto 1);
            alu_result <= alu_result_add(31 downto 0);

         when alu_sub_withcarry =>
            alu_result <= sub_wide(32 downto 1);

         when others => null;
      end case;

      execute_flag_Carry      <= Flag_Carry;
      execute_flag_Zero       <= Flag_Zero;
      execute_flag_Negative   <= Flag_Negative;
      execute_flag_V_Overflow <= Flag_V_Overflow;

      if (decode_alu_use_shift = '1') then
         alu_shiftercarry <= shiftercarry;
      elsif (decode_useoldcarry = '1') then
         alu_shiftercarry <= Flag_Carry;
      else
         alu_shiftercarry <= decode_shiftcarry;
      end if;



      if (decode_updateflags = '1' and (execute_skip = '0' or execute_stall = '1')) then

         case (decode_functions_detail) is
            when alu_and =>     execute_flag_Carry <= alu_shiftercarry; if (alu_result = 0) then execute_flag_Zero <= '1'; else execute_flag_Zero <= '0'; end if; execute_flag_Negative <= alu_result(31);
            when alu_xor =>     execute_flag_Carry <= alu_shiftercarry; if (alu_result = 0) then execute_flag_Zero <= '1'; else execute_flag_Zero <= '0'; end if; execute_flag_Negative <= alu_result(31);
            when alu_or  =>     execute_flag_Carry <= alu_shiftercarry; if (alu_result = 0) then execute_flag_Zero <= '1'; else execute_flag_Zero <= '0'; end if; execute_flag_Negative <= alu_result(31);
            when alu_and_not => execute_flag_Carry <= alu_shiftercarry; if (alu_result = 0) then execute_flag_Zero <= '1'; else execute_flag_Zero <= '0'; end if; execute_flag_Negative <= alu_result(31);
            when alu_mov =>     execute_flag_Carry <= alu_shiftercarry; if (alu_result = 0) then execute_flag_Zero <= '1'; else execute_flag_Zero <= '0'; end if; execute_flag_Negative <= alu_result(31);
            when alu_mov_not => execute_flag_Carry <= alu_shiftercarry; if (alu_result = 0) then execute_flag_Zero <= '1'; else execute_flag_Zero <= '0'; end if; execute_flag_Negative <= alu_result(31);

            when alu_add | alu_add_withcarry =>
               if (alu_result_add(31 downto 0) = 0) then execute_flag_Zero <= '1'; else execute_flag_Zero <= '0'; end if;
               execute_flag_Negative <= alu_result_add(31);
               execute_flag_Carry <= alu_result_add(32);
               if ((alu_op1(31) xor alu_result_add(31)) = '1' and (alu_op2(31) xor alu_result_add(31)) = '1') then
                  execute_flag_V_Overflow <= '1';
               else
                  execute_flag_V_Overflow <= '0';
               end if;

            when alu_sub =>
               if (alu_result = 0) then execute_flag_Zero <= '1'; else execute_flag_Zero <= '0'; end if;
               execute_flag_Negative <= alu_result(31);
               if (alu_op1(31) /= alu_op2(31) and alu_op1(31) /= alu_result(31)) then
                  execute_flag_V_Overflow <= '1';
               else
                  execute_flag_V_Overflow <= '0';
               end if;
               execute_flag_Carry <= sub_wide(33);

            when alu_sub_withcarry =>
               if (alu_result = 0) then execute_flag_Zero <= '1'; else execute_flag_Zero <= '0'; end if;
               execute_flag_Negative <= alu_result(31);
               if (alu_op1(31) /= alu_op2(31) and alu_op1(31) /= alu_result(31)) then
                  execute_flag_V_Overflow <= '1';
               else
                  execute_flag_V_Overflow <= '0';
               end if;
               execute_flag_Carry <= sub_wide(33);

            when mulboth =>
               if (decode_mul_long = '1') then
                  if (execute_mul_result = 0) then execute_flag_Zero <= '1'; else execute_flag_Zero <= '0'; end if;
                  execute_flag_Negative <= execute_mul_result(63);
               else
                  if (execute_mul_result(31 downto 0) = 0) then execute_flag_Zero <= '1'; else execute_flag_Zero <= '0'; end if;
                  execute_flag_Negative <= execute_mul_result(31);
               end if;

            when others => null;
         end case;
      end if;

   end process;



   process (all)
      variable found : boolean;
      variable cnt   : integer range 0 to 32;
   begin
      found := false;
      cnt   := 32;
      for i in 31 downto 0 loop
         if (not found and execute_op2(i) = '1') then
            cnt   := 31 - i;
            found := true;
         end if;
      end loop;
      execute_clz_result <= to_unsigned(cnt, 32);
   end process;

   process (all)
      variable dbl    : signed(32 downto 0);
      variable dblsat : signed(31 downto 0);
      variable sum    : signed(32 downto 0);
      variable qflag  : std_logic;
   begin
      qflag := '0';

      if (decode_sat_double = '1') then
         dbl := resize(signed(execute_op1), 33) + resize(signed(execute_op1), 33);
      else
         dbl := resize(signed(execute_op1), 33);
      end if;
      if (dbl > to_signed(2147483647, 33)) then
         dblsat := x"7FFFFFFF";
         qflag  := '1';
      elsif (dbl < to_signed(-2147483648, 33)) then
         dblsat := x"80000000";
         qflag  := '1';
      else
         dblsat := dbl(31 downto 0);
      end if;

      if (decode_sat_sub = '1') then
         sum := resize(signed(execute_op2), 33) - resize(dblsat, 33);
      else
         sum := resize(signed(execute_op2), 33) + resize(dblsat, 33);
      end if;
      if (sum > to_signed(2147483647, 33)) then
         execute_sat_result <= x"7FFFFFFF";
         qflag := '1';
      elsif (sum < to_signed(-2147483648, 33)) then
         execute_sat_result <= x"80000000";
         qflag := '1';
      else
         execute_sat_result <= unsigned(sum(31 downto 0));
      end if;
      execute_sat_qset <= qflag;
   end process;

   process (all)
      variable p : unsigned(31 downto 0);
      variable s : unsigned(31 downto 0);
   begin
      p := execute_mul_result(31 downto 0);
      if (decode_dsp_acc = '1') then
         s := p + execute_op1;
      else
         s := p;
      end if;
      execute_dsp_sum <= s;
      if (decode_dsp_acc = '1' and decode_dsp_long = '0' and
          p(31) = execute_op1(31) and s(31) /= p(31)) then
         execute_dsp_qset <= '1';
      else
         execute_dsp_qset <= '0';
      end if;
   end process;

   process (all)
   begin
      cp15_rdata <= (others => '0');
      case (decode_cp15_crn) is
         when x"0" =>
            case (decode_cp15_op2) is
               when "001"  => cp15_rdata <= x"0F0D2112";
               when "010"  => cp15_rdata <= x"00140180";
               when others => cp15_rdata <= x"41059461";
            end case;
         when x"1" => cp15_rdata <= cp15_control;
         when x"2" =>
            if (decode_cp15_op2 = "001") then
               cp15_rdata <= cp15_pu_icache;
            else
               cp15_rdata <= cp15_pu_dcache;
            end if;
         when x"3" => cp15_rdata <= cp15_pu_wbuf;
         when x"5" =>
            if (decode_cp15_op2(0) = '1') then
               cp15_rdata <= cp15_pu_iperm;
            else
               cp15_rdata <= cp15_pu_dperm;
            end if;
         when x"6" => cp15_rdata <= cp15_pu_region(to_integer(unsigned(decode_cp15_crm(2 downto 0))));
         when x"9" =>
            if (decode_cp15_crm = x"1") then
               if (decode_cp15_op2 = "001") then
                  cp15_rdata <= cp15_itcm_reg;
               else
                  cp15_rdata <= cp15_dtcm_reg;
               end if;
            else
               if (decode_cp15_op2 = "001") then
                  cp15_rdata <= cp15_icache_lock;
               else
                  cp15_rdata <= cp15_dcache_lock;
               end if;
            end if;
         when x"D" => cp15_rdata <= cp15_trace_pid;
         when others => null;
      end case;
   end process;

   execute_wfi <= '1' when (decode_functions_detail = cp15_op and execute_now = '1' and execute_skip = '0' and
                            decode_cp15_mrc = '0' and decode_cp15_crn = x"7" and
                            decode_cp15_crm = x"0" and decode_cp15_op2 = "100") else '0';

   execute_cp15_cacheop <=
      '1' when (decode_cp15_mrc = '0' and decode_cp15_crn = x"7" and
                ((decode_cp15_crm = x"5" and (decode_cp15_op2 = "000" or decode_cp15_op2 = "001")) or
                 (decode_cp15_crm = x"6" and (decode_cp15_op2 = "000" or decode_cp15_op2 = "001" or decode_cp15_op2 = "010")) or
                 (decode_cp15_crm = x"A" and (decode_cp15_op2 = "001" or decode_cp15_op2 = "010")) or
                 (decode_cp15_crm = x"E" and (decode_cp15_op2 = "001" or decode_cp15_op2 = "010")))) else '0';

   execute_blockRW_last <= '1' when (decode_block_reglist = x"0000") else '0';

   process (all)
   begin

      execute_RW_data <= (others => '0');
      execute_RW_addr <= (others => '0');
      execute_RW_rnw  <= '1';
      execute_RW_acc  <= "10";
      execute_RW_ena  <= '0';

      execute_busaddress <= execute_op1;

      bus_lowbits <= "00";

      if (decode_datatransfer_shiftval = '1') then
         execute_busaddmod <= shiftresult;
      elsif (decode_datatransfer_regoffset = '1') then
         execute_busaddmod <= execute_op2;
      else
         execute_busaddmod <= x"00000" & decode_datatransfer_addvalue;
      end if;

      if (decode_functions_detail = data_read or decode_functions_detail = data_write) then
         execute_RW_acc <= decode_datatransfer_type;
         if (decode_datatransfer_swap = '1') then
            execute_RW_data <= std_logic_vector(execute_op2);
         elsif (decode_rdest = x"F") then
            execute_RW_data <= std_logic_vector(fetch_PC);
         else
            execute_RW_data <= std_logic_vector(execute_opDest);
         end if;

         if (decode_datatransfer_preadd = '1') then
            if (decode_datatransfer_addup = '1') then
               execute_RW_addr <= execute_busaddress + execute_busaddmod;
            else
               execute_RW_addr <= execute_busaddress - execute_busaddmod;
            end if;
         else
            execute_RW_addr <= execute_busaddress;
         end if;

         if (execute_RW_State = DATARW_IDLE) then
            if (decode_datatransfer_shiftval = '0') then
               execute_RW_ena <= execute_now and (not execute_skip);
            end if;
            if (decode_functions_detail = data_write) then
               execute_RW_rnw <= '0';
            end if;
         elsif (execute_RW_State = DATARW_ADDRWAIT) then
            execute_RW_addr <= execute_RW_addr_last;
            execute_RW_ena  <= '1';
            if (decode_functions_detail = data_write) then
               execute_RW_rnw <= '0';
            end if;
         end if;

         if (execute_RW_State = DATARW_READSTART and decode_datatransfer_swap = '1') then
            if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
               execute_RW_ena <= '1';
               execute_RW_rnw <= '0';
            end if;
         end if;

         if (decode_datatransfer_double = '1' and busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
            if (execute_RW_State = DATARW_READSTART) then
               execute_RW_ena  <= '1';
               execute_RW_addr <= execute_RW_addr_last + 4;
            elsif (execute_RW_State = DATARW_WRITE) then
               execute_RW_ena  <= '1';
               execute_RW_rnw  <= '0';
               execute_RW_addr <= execute_RW_addr_last + 4;
               execute_RW_data <= std_logic_vector(regs(to_integer(unsigned(decode_rdest) + 1)));
            end if;
         end if;

      end if;

      if (decode_functions_detail = block_read or decode_functions_detail = block_write) then
         execute_RW_data <= std_logic_vector(execute_op2);

         if (decode_block_usermoderegs = '1' and cpu_mode /= CPUMODE_USER and cpu_mode /= CPUMODE_SYSTEM and
             ((unsigned(decode_RM_op2) >= 13 and unsigned(decode_RM_op2) <= 14) or
              (unsigned(decode_RM_op2) >= 8  and unsigned(decode_RM_op2) <= 12 and cpu_mode = CPUMODE_FIQ))) then
            case (to_integer(unsigned(decode_RM_op2))) is
               when 8  => execute_RW_data <= std_logic_vector(regs_0_8);
               when 9  => execute_RW_data <= std_logic_vector(regs_0_9);
               when 10 => execute_RW_data <= std_logic_vector(regs_0_10);
               when 11 => execute_RW_data <= std_logic_vector(regs_0_11);
               when 12 => execute_RW_data <= std_logic_vector(regs_0_12);
               when 13 => execute_RW_data <= std_logic_vector(regs_0_13);
               when 14 => execute_RW_data <= std_logic_vector(regs_0_14);
               when others => null;
            end case;
         end if;

         if (execute_stall = '1' and decode_RM_op2 = decode_Rn_op1) then
            execute_RW_data <= std_logic_vector(execute_blockRW_endaddr);
         end if;

         if (execute_stall = '0') then
            execute_RW_ena  <= execute_now and (not execute_skip);
            execute_RW_addr <= unsigned(signed(execute_busaddress) + decode_block_addrmod);
         else
            execute_RW_addr <= execute_blockRW_addr;
            if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
               execute_RW_ena <= not execute_blockRW_last;
            end if;
         end if;
         bus_lowbits <= std_logic_vector(execute_op1(1 downto 0));
         execute_RW_addr(1 downto 0) <= "00";

         if (decode_functions_detail = block_write) then
            execute_RW_rnw <= '0';
         end if;
      end if;

   end process;

   process (all)
   begin

      if (decode_alu_use_immi = '1') then
         execute_msr_fetchvalue <= decode_immidiate;
      else
         execute_msr_fetchvalue <= execute_op2;
      end if;

      execute_msr_writevalue <= SPSR;
      if (decode_Rn_op1(0) = '1') then execute_msr_writevalue( 7 downto  0) <= execute_msr_fetchvalue( 7 downto  0); end if;
      if (decode_Rn_op1(1) = '1') then execute_msr_writevalue(15 downto  8) <= execute_msr_fetchvalue(15 downto  8); end if;
      if (decode_Rn_op1(2) = '1') then execute_msr_writevalue(23 downto 16) <= execute_msr_fetchvalue(23 downto 16); end if;
      if (decode_Rn_op1(3) = '1') then execute_msr_writevalue(31 downto 24) <= execute_msr_fetchvalue(31 downto 24); end if;


      execute_switchmode_now   <= '0';
      execute_switchmode_state <= '0';
      execute_msr_setvalue     <= CPSR;
      execute_msr_setvalue_ena <= '0';
      execute_switchmode_val   <= std_logic_vector(execute_msr_setvalue(3 downto 0));

      if (decode_functions_detail = data_processing_MSR) then

         if (decode_psr_with_spsr = '0') then
            execute_msr_setvalue_ena <= execute_now;
            if (cpu_mode /= CPUMODE_USER) then
               if (decode_Rn_op1(0) = '1') then execute_msr_setvalue( 7 downto  0) <= execute_msr_fetchvalue( 7 downto  0); execute_switchmode_now <= execute_now; end if;
               if (decode_Rn_op1(1) = '1') then execute_msr_setvalue(15 downto  8) <= execute_msr_fetchvalue(15 downto  8); end if;
               if (decode_Rn_op1(2) = '1') then execute_msr_setvalue(23 downto 16) <= execute_msr_fetchvalue(23 downto 16); end if;
            end if;
            if (decode_Rn_op1(3) = '1') then execute_msr_setvalue(31 downto 24) <= execute_msr_fetchvalue(31 downto 24); end if;
         end if;

         if (execute_now = '0' or execute_skip = '1') then
            execute_msr_setvalue_ena <= '0';
            execute_switchmode_now   <= '0';
         end if;

      end if;

      if (decode_leaveirp = '1') then
         if (decode_alu_use_shift = '0' or decode_shift_regbased = '0' or execute_stall = '1') then
            if (cpu_mode = CPUMODE_USER or cpu_mode = CPUMODE_SYSTEM) then
               execute_switchmode_now   <= '1';
               execute_switchmode_val   <= cpu_mode;
            else
               execute_switchmode_now   <= '1';
               execute_switchmode_val   <= std_logic_vector(SPSR(3 downto 0));
               execute_msr_setvalue     <= SPSR;
               execute_msr_setvalue_ena <= '1';
            end if;
         end if;

         if (execute_stall = '0' and (execute_now = '0' or execute_skip = '1')) then
            execute_msr_setvalue_ena <= '0';
         end if;

      end if;

      if (decode_functions_detail = block_read and decode_block_switchmode = '1' and
          execute_RW_State = DATARW_BLOCKSWITCH) then
         execute_switchmode_now   <= '1';
         execute_switchmode_val   <= std_logic_vector(SPSR(3 downto 0));
         execute_msr_setvalue     <= SPSR;
         execute_msr_setvalue_ena <= '1';
      end if;

      if (decode_functions_detail = IRQ) then
         execute_switchmode_now   <= execute_now;
         execute_switchmode_state <= '1';
         execute_switchmode_val   <= CPUMODE_IRQ;
         execute_msr_setvalue     <= SPSR;
         execute_msr_setvalue_ena <= execute_now;
      end if;

      if (decode_functions_detail = software_interrupt_detail) then
         execute_switchmode_now   <= execute_now and not execute_skip;
         execute_switchmode_state <= '1';
         execute_switchmode_val   <= CPUMODE_SUPERVISOR;
         execute_msr_setvalue     <= SPSR;
         execute_msr_setvalue_ena <= execute_now and not execute_skip;
      end if;

   end process;

   execute_switchmode_new <= execute_switchmode_val when (execute_switchmode_val = CPUMODE_FIQ        or execute_switchmode_val = CPUMODE_IRQ   or execute_switchmode_val = CPUMODE_SUPERVISOR or
                                                          execute_switchmode_val = CPUMODE_SUPERVISOR or execute_switchmode_val = CPUMODE_ABORT or execute_switchmode_val = CPUMODE_UNDEFINED or
                                                          execute_switchmode_val = CPUMODE_SYSTEM) else CPUMODE_USER;

   process (all)
   begin
      execute_skip <= '1';
      case (decode_condition) is
         when x"0" => if (Flag_Zero = '1')                                        then execute_skip <= '0'; end if;
         when x"1" => if (Flag_Zero = '0')                                        then execute_skip <= '0'; end if;
         when x"2" => if (Flag_Carry = '1')                                       then execute_skip <= '0'; end if;
         when x"3" => if (Flag_Carry = '0')                                       then execute_skip <= '0'; end if;
         when x"4" => if (Flag_Negative = '1')                                    then execute_skip <= '0'; end if;
         when x"5" => if (Flag_Negative = '0')                                    then execute_skip <= '0'; end if;
         when x"6" => if (Flag_V_Overflow = '1')                                  then execute_skip <= '0'; end if;
         when x"7" => if (Flag_V_Overflow = '0')                                  then execute_skip <= '0'; end if;
         when x"8" => if (Flag_Carry = '1' and Flag_Zero = '0')                   then execute_skip <= '0'; end if;
         when x"9" => if (Flag_Carry = '0' or Flag_Zero = '1')                    then execute_skip <= '0'; end if;
         when x"A" => if (Flag_Negative = Flag_V_Overflow)                        then execute_skip <= '0'; end if;
         when x"B" => if (Flag_Negative /= Flag_V_Overflow)                       then execute_skip <= '0'; end if;
         when x"C" => if (Flag_Zero = '0' and (Flag_Negative = Flag_V_Overflow))  then execute_skip <= '0'; end if;
         when x"D" => if (Flag_Zero = '1' or (Flag_Negative /= Flag_V_Overflow))  then execute_skip <= '0'; end if;
         when x"E" => execute_skip <= '0';
         when others => null;
      end case;
   end process;

   execute_now      <= ce when (fetch_done = '1' and decode_ready = '1' and decode_halt = '0' and execute_stall = '0') else
                       '0';

   execute_branch   <= '1'                                  when (pcwrite_fetch = '1') else
                       (execute_now and (not execute_skip)) when (decode_functions_detail = branch_all or decode_functions_detail = IRQ or decode_functions_detail = software_interrupt_detail) else
                       '0';

   execute_nextIsthumb <= '0'                     when (execute_now = '1' and execute_skip = '0' and (decode_functions_detail = IRQ or decode_functions_detail = software_interrupt_detail)) else
                          execute_msr_setvalue(5) when (execute_msr_setvalue_ena = '1') else
                          thumbmode               when (decode_functions_detail = block_read and decode_block_switchmode = '1' and
                                                        execute_RW_State = DATARW_PCWRITE) else
                          SPSR(5)                 when (decode_functions_detail = block_read and decode_block_switchmode = '1' and
                                                        ((execute_writeback = '1' and execute_writereg = x"F") or
                                                         execute_RW_State = DATARW_READWAIT or
                                                         execute_RW_State = DATARW_READWAITDMA or
                                                         execute_RW_State = DATARW_BLOCKSWITCH)) else
                          execute_RW_dataRead(0)  when (pcwrite_fetch = '1' and
                                                        (decode_functions_detail = data_read or decode_functions_detail = block_read)) else
                          '1'                     when (decode_branch_forcethumb = '1' and execute_branch = '1' and decode_functions_detail = branch_all) else
                          '0'                     when (decode_branch_forcearm   = '1' and execute_branch = '1' and decode_functions_detail = branch_all) else
                          execute_op2(0)          when (decode_set_thumbmode = '1' and execute_branch = '1' and decode_functions_detail = branch_all) else
                          thumbmode;

   exception_base <= x"FFFF0000" when (cp15_control(13) = '1') else x"00000000";

   execute_branchPC <= exception_base + 16#18#                                                  when (decode_functions_detail = IRQ) else
                       exception_base + 16#08#                                                  when (decode_functions_detail = software_interrupt_detail) else
                       (execute_op2(31 downto 1) & '0' + (decode_immidiate(10 downto 0) & '0')) when (decode_branch_long = '1') else
                       execute_op2(31 downto 1) & '0'                                           when (decode_branch_usereg = '1') else
                       unsigned(signed(decode_PC) + resize(decode_branch_immi, 32));

   execute_branchPC_masked(31 downto 2) <= execute_branchPC(31 downto 2);
   execute_branchPC_masked(1) <= execute_branchPC(1) when (execute_nextIsthumb = '1') else '0';
   execute_branchPC_masked(0) <= '0';


   process (all)
   begin

      execute_done      <= '0';

      execute_writeback <= '0';
      execute_writedata <= (others => '0');
      execute_writereg  <= unsigned(decode_rdest);

      if (execute_now) then

         if (execute_skip = '1') then

            execute_done <= '1';

         else

            case decode_functions_detail is

               when alu_and | alu_xor | alu_add | alu_sub | alu_add_withcarry | alu_sub_withcarry | alu_or | alu_mov | alu_and_not | alu_mov_not =>
                  if (decode_alu_use_shift = '1' and decode_shift_regbased = '1') then
                  elsif (decode_writeback = '1' and decode_rdest = x"F") then
                  else
                     execute_writedata <= alu_result;
                     execute_writeback <= decode_writeback;
                     execute_done      <= '1';
                  end if;

               when data_processing_MRS =>
                  if (decode_psr_with_spsr = '1') then
                     execute_writedata <= SPSR;
                  else
                     execute_writedata <= CPSR;
                  end if;
                  execute_writeback <= '1';
                  execute_done      <= '1';

               when data_processing_MSR =>
                  execute_done <= '1';

               when branch_all =>
                  execute_done <= '1';

               when alu_clz =>
                  execute_writedata <= execute_clz_result;
                  execute_writeback <= '1';
                  execute_done      <= '1';

               when sat_arith =>
                  execute_writedata <= execute_sat_result;
                  execute_writeback <= '1';
                  execute_done      <= '1';

               when cp15_op =>
                  if (execute_cp15_cacheop = '1') then
                  else
                     execute_done <= '1';
                     if (decode_cp15_mrc = '1' and decode_rdest /= x"F") then
                        execute_writedata <= unsigned(cp15_rdata);
                        execute_writeback <= '1';
                     end if;
                  end if;

               when nop_detail =>
                  execute_done <= '1';

               when IRQ =>
                  execute_done      <= '1';
                  execute_writeback <= '1';
                  if (thumbmode = '1') then
                     execute_writedata <= decode_PC;
                  else
                     execute_writedata <= decode_PC - 4;
                  end if;

               when software_interrupt_detail =>
                  execute_done      <= '1';
                  execute_writeback <= '1';
                  if (thumbmode = '1') then
                     execute_writedata <= decode_PC - 2;
                  else
                     execute_writedata <= decode_PC - 4;
                  end if;

               when others => null;

            end case;

         end if;

      end if;

      if (execute_stall = '1') then

         case decode_functions_detail is

            when alu_and | alu_xor | alu_add | alu_sub | alu_add_withcarry | alu_sub_withcarry | alu_or | alu_mov | alu_and_not | alu_mov_not =>
               if (alu_pcwrite_wait = '1') then
                  execute_writedata <= unsigned(execute_RW_dataRead);
                  execute_writeback <= '1';
                  execute_done      <= '1';
               elsif (alu_wait_shift = '1' and decode_writeback = '1' and decode_rdest = x"F") then
               else
                  execute_writedata <= alu_result;
                  execute_writeback <= decode_writeback;
                  execute_done      <= '1';
               end if;

            when mulboth =>
               case (execute_MUL_State) is
                  when MUL_MUL =>
                     if (execute_mul_wait = 0) then
                        if (decode_mul_useadd = '0') then
                           execute_writeback <= '1';
                           execute_writereg  <= unsigned(decode_RM_op2);
                           execute_writedata <= execute_mul_result(31 downto 0);
                           if (decode_mul_long = '0') then
                              execute_done <= '1';
                              execute_writereg  <= unsigned(decode_rdest);
                           end if;
                        end if;
                     end if;

                  when MUL_ADD =>
                     execute_writeback <= '1';
                     execute_writereg  <= unsigned(decode_RM_op2);
                     execute_writedata <= execute_mul_result(31 downto 0);
                     if (decode_mul_long = '0') then
                        execute_done <= '1';
                        execute_writereg  <= unsigned(decode_rdest);
                     end if;

                  when MUL_STOREHI =>
                     execute_done <= '1';
                     execute_writeback <= '1';
                     execute_writereg  <= unsigned(decode_rdest);
                     execute_writedata <= execute_mul_result(63 downto 32);

                  when others => null;
               end case;

            when cp15_op =>
               if (execute_cacheop_wait = '1' and cache_op_ena = '0' and cache_op_busy = '0') then
                  execute_done <= '1';
               end if;

            when mul_dsp =>
               case (execute_MUL_State) is
                  when MUL_DSP_ACC =>
                     execute_writeback <= '1';
                     execute_writedata <= execute_dsp_sum;
                     if (decode_dsp_long = '1') then
                        execute_writereg <= unsigned(decode_Rn_op1);
                     else
                        execute_writereg <= unsigned(decode_rdest);
                        execute_done     <= '1';
                     end if;

                  when MUL_DSP_ACCHI =>
                     execute_writeback <= '1';
                     execute_writereg  <= unsigned(decode_rdest);
                     if (execute_dsp_carry = '1') then
                        execute_writedata <= execute_mul_result(63 downto 32) + execute_op1 + 1;
                     else
                        execute_writedata <= execute_mul_result(63 downto 32) + execute_op1;
                     end if;
                     execute_done <= '1';

                  when others => null;
               end case;

            when data_read | data_write =>
               if (execute_RW_State = DATARW_READWAITDMA) then
                  if (dma_on = '0') then
                     execute_done <= '1';
                  end if;
               end if;

               if (execute_RW_State = DATARW_READWAIT) then
                  if (dma_on_1 = '0' or dma_on = '0') then
                     execute_done      <= '1';
                  end if;
               end if;

               if (execute_RW_State = DATARW_READWAIT or execute_RW_State = DATARW_SWAPWRITE) then
                  execute_writeback <= '1';
                  case (decode_datareceivetype) is
                     when RECEIVETYPE_BYTE       => execute_writedata <= x"000000" & unsigned(execute_RW_dataRead(7 downto 0));
                     when RECEIVETYPE_WORD       => execute_writedata <= unsigned(execute_RW_dataRead);
                     when RECEIVETYPE_DWORD      => execute_writedata <= unsigned(execute_RW_dataRead);
                     when RECEIVETYPE_SIGNEDBYTE => execute_writedata <= unsigned(resize(signed(execute_RW_dataRead(7 downto 0)), 32));
                     when RECEIVETYPE_SIGNEDWORD =>
                        if (execute_RW_addr_last(0) = '0') then
                           execute_writedata <= unsigned(resize(signed(execute_RW_dataRead(15 downto 0)), 32));
                        else
                           execute_writedata <= unsigned(resize(signed(execute_RW_dataRead(7 downto 0)), 32));
                        end if;
                  end case;
                  if (decode_datatransfer_double = '1') then
                     execute_writereg <= unsigned(decode_rdest) + 1;
                  end if;
               end if;

               if (decode_datatransfer_double = '1' and execute_RW_State = DATARW_READSTART and
                   busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
                  execute_writeback <= '1';
                  execute_writereg  <= unsigned(decode_rdest);
                  execute_writedata <= unsigned(gb_bus_din);
               end if;

               if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
                  if (decode_functions_detail = data_write and
                      (decode_datatransfer_double = '0' or execute_RW_State = DATARW_WRITE_D2)) then
                     execute_done      <= '1';
                  end if;
                  if (decode_datatransfer_writeback = '1' and
                      (decode_datatransfer_double = '0' or
                       execute_RW_State = DATARW_READSTART_D2 or execute_RW_State = DATARW_WRITE_D2)) then
                     execute_writeback <= '1';
                     execute_writereg  <= unsigned(decode_Rn_op1);
                     execute_writedata <= execute_RW_WBaddr;
                  end if;
               end if;

               if (execute_RW_State = DATARW_SWAPWAIT) then
                  execute_done      <= '1';
               end if;

               if (decode_functions_detail = data_read and
                   decode_datatransfer_double = '0' and decode_rdest = x"F") then
                  if (execute_RW_State = DATARW_READWAIT or
                      execute_RW_State = DATARW_READWAITDMA) then
                     execute_writeback <= '0';
                     execute_done      <= '0';
                  elsif (execute_RW_State = DATARW_PCWRITE) then
                     execute_writeback <= '1';
                     execute_writereg  <= x"F";
                     execute_writedata <= unsigned(execute_RW_dataRead);
                     execute_done      <= '1';
                  end if;
               end if;

            when block_read | block_write =>
               if (execute_RW_State = DATARW_READWAITDMA) then
                  if (dma_on = '0' and decode_block_switchmode = '0' and execute_blockRW_writereg /= 15) then
                     execute_done <= '1';
                  end if;
               end if;

               if (execute_RW_State = DATARW_READWAIT or (decode_functions_detail = block_write and busState = BUSSTATE_WAITDATA and gb_bus_done = '1' and execute_blockRW_last = '1')) then
                  if (decode_datatransfer_writeback = '1') then
                     execute_writeback <= '1';
                     execute_writereg  <= unsigned(decode_Rn_op1);
                     execute_writedata <= execute_blockRW_endaddr;
                  end if;
               end if;

               if (execute_RW_State = DATARW_READWAIT) then
                  if ((dma_on_1 = '0' or dma_on = '0') and decode_block_switchmode = '0' and
                      execute_blockRW_writereg /= 15) then
                     execute_done      <= '1';
                  end if;
               end if;

               if (execute_RW_State = DATARW_BLOCKSWITCH and execute_blockRW_writereg /= 15) then
                  execute_done <= '1';
               end if;

               if (execute_RW_State = DATARW_PCWRITE) then
                  execute_writeback <= '1';
                  execute_writereg  <= x"F";
                  execute_writedata <= unsigned(execute_RW_dataRead);
                  execute_done      <= '1';
               end if;

               if (decode_functions_detail = block_read) then
                  if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
                     if (execute_blockRW_writereg /= 15 and
                         (decode_block_usermoderegs = '0' or cpu_mode = CPUMODE_USER or cpu_mode = CPUMODE_SYSTEM or
                          execute_blockRW_writereg < 8 or execute_blockRW_writereg > 14 or
                          (execute_blockRW_writereg <= 12 and cpu_mode /= CPUMODE_FIQ))) then
                        execute_writeback <= '1';
                     end if;
                     execute_writereg  <= execute_blockRW_writereg;
                     execute_writedata <= unsigned(gb_bus_din);
                  end if;
               else
                  if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1' and execute_blockRW_last = '1') then
                     execute_done      <= '1';
                  end if;
               end if;

             when others => null;

         end case;

      end if;

   end process;

   process (clk)
      variable dsp_ra    : signed(15 downto 0);
      variable dsp_rb    : signed(15 downto 0);
      variable dsp_p     : signed(31 downto 0);
      variable dsp_pw    : signed(47 downto 0);
      variable dsp_sum33 : unsigned(32 downto 0);
      variable cp15_wval : std_logic_vector(31 downto 0);
      variable v_cacheop : std_logic_vector(3 downto 0);
   begin
      if (rising_edge(clk)) then

         done <= execute_done;

         error_cpu <= '0';

         if (reset = '1') then

            execute_stall        <= '0';
            Flag_Q_Sticky     <= '0';
            execute_dsp_carry <= '0';
            cp15_control      <= x"00012078";
            cp15_dtcm_reg     <= x"0300000A";
            cp15_itcm_reg     <= x"00000020";
            cp15_pu_region(0) <= x"04000033";
            cp15_pu_region(1) <= x"0200002B";
            cp15_pu_region(2) <= x"00000000";
            cp15_pu_region(3) <= x"08000035";
            cp15_pu_region(4) <= x"0300001B";
            cp15_pu_region(5) <= x"00000000";
            cp15_pu_region(6) <= x"FFFF001D";
            cp15_pu_region(7) <= x"027FF017";
            cp15_pu_dcache    <= x"00000042";
            cp15_pu_icache    <= x"00000042";
            cp15_pu_wbuf      <= x"00000002";
            cp15_pu_dperm     <= x"15111011";
            cp15_pu_iperm     <= x"05100011";
            cp15_dcache_lock  <= (others => '0');
            cp15_icache_lock  <= (others => '0');
            cp15_trace_pid    <= (others => '0');

            Flag_Zero       <= SAVESTATE_Flag_Zero;
            Flag_Carry      <= SAVESTATE_Flag_Carry;
            Flag_Negative   <= SAVESTATE_Flag_Negative;
            Flag_V_Overflow <= SAVESTATE_Flag_V_Overflow;
            thumbmode       <= SAVESTATE_thumbmode;
            cpu_mode        <= SAVESTATE_cpu_mode;
            IRQ_disable     <= SAVESTATE_IRQ_disable;
            FIQ_disable     <= SAVESTATE_FIQ_disable;

            for i in 0 to 15 loop
               regs(i) <= unsigned(SAVESTATE_REGS(i));
            end loop;

            regs_0_8  <= unsigned(SAVESTATE_REGS_0_8 );
            regs_0_9  <= unsigned(SAVESTATE_REGS_0_9 );
            regs_0_10 <= unsigned(SAVESTATE_REGS_0_10);
            regs_0_11 <= unsigned(SAVESTATE_REGS_0_11);
            regs_0_12 <= unsigned(SAVESTATE_REGS_0_12);
            regs_0_13 <= unsigned(SAVESTATE_REGS_0_13);
            regs_0_14 <= unsigned(SAVESTATE_REGS_0_14);
            regs_1_8  <= unsigned(SAVESTATE_REGS_1_8 );
            regs_1_9  <= unsigned(SAVESTATE_REGS_1_9 );
            regs_1_10 <= unsigned(SAVESTATE_REGS_1_10);
            regs_1_11 <= unsigned(SAVESTATE_REGS_1_11);
            regs_1_12 <= unsigned(SAVESTATE_REGS_1_12);
            regs_1_13 <= unsigned(SAVESTATE_REGS_1_13);
            regs_1_14 <= unsigned(SAVESTATE_REGS_1_14);
            regs_1_17 <= unsigned(SAVESTATE_REGS_1_17);
            regs_2_13 <= unsigned(SAVESTATE_REGS_2_13);
            regs_2_14 <= unsigned(SAVESTATE_REGS_2_14);
            regs_2_17 <= unsigned(SAVESTATE_REGS_2_17);
            regs_3_13 <= unsigned(SAVESTATE_REGS_3_13);
            regs_3_14 <= unsigned(SAVESTATE_REGS_3_14);
            regs_3_17 <= unsigned(SAVESTATE_REGS_3_17);
            regs_4_13 <= unsigned(SAVESTATE_REGS_4_13);
            regs_4_14 <= unsigned(SAVESTATE_REGS_4_14);
            regs_4_17 <= unsigned(SAVESTATE_REGS_4_17);
            regs_5_13 <= unsigned(SAVESTATE_REGS_5_13);
            regs_5_14 <= unsigned(SAVESTATE_REGS_5_14);
            regs_5_17 <= unsigned(SAVESTATE_REGS_5_17);

            execute_RW_State  <= DATARW_IDLE;
            execute_MUL_State <= MUL_IDLE;
            alu_wait_shift    <= '0';
            alu_pcwrite_wait  <= '0';
            cache_op_ena         <= '0';
            execute_cacheop_wait <= '0';

         elsif (ce = '1') then

            cache_op_ena <= '0';

            if (execute_writeback = '1' and execute_writereg /= 15) then
               regs(to_integer(execute_writereg)) <= execute_writedata;
            end if;

            if (execute_writeback = '1' and execute_writereg = 15 and
                (decode_functions_detail = data_read or
                 (decode_functions_detail = block_read and decode_block_switchmode = '0'))) then
               thumbmode <= execute_writedata(0);
            end if;

            if (execute_done = '1') then
               Flag_Carry      <= execute_flag_Carry;
               Flag_Zero       <= execute_flag_Zero;
               Flag_Negative   <= execute_flag_Negative;
               Flag_V_Overflow <= execute_flag_V_Overflow;
            end if;

            if (execute_msr_setvalue_ena = '1') then
               cpu_mode           <= execute_switchmode_new;
               thumbmode          <= execute_msr_setvalue(5);
               FIQ_disable        <= execute_msr_setvalue(6);
               IRQ_disable        <= execute_msr_setvalue(7);
               Flag_Negative      <= execute_msr_setvalue(31);
               Flag_Zero          <= execute_msr_setvalue(30);
               Flag_Carry         <= execute_msr_setvalue(29);
               Flag_V_Overflow    <= execute_msr_setvalue(28);
               Flag_Q_Sticky      <= execute_msr_setvalue(27);
            end if;

            if (execute_stall = '1') then

               if (alu_pcwrite_wait = '1') then
                  execute_stall        <= '0';
                  alu_pcwrite_wait    <= '0';
               elsif (alu_wait_shift = '1') then
                  alu_wait_shift <= '0';
                  if (decode_writeback = '1' and decode_rdest = x"F") then
                     execute_RW_dataRead <= std_logic_vector(alu_result);
                     alu_pcwrite_wait <= '1';
                  else
                     execute_stall        <= '0';
                  end if;
               end if;

               if (execute_cacheop_wait = '1' and cache_op_ena = '0' and cache_op_busy = '0') then
                  execute_cacheop_wait <= '0';
                  execute_stall        <= '0';
               end if;

               if (decode_functions_detail = mulboth) then
                  case (execute_MUL_State) is
                     when MUL_MUL =>
                        if (execute_mul_wait > 0) then
                           execute_mul_wait <= execute_mul_wait - 1;
                        else
                           if (decode_mul_useadd = '1') then
                              execute_MUL_State  <= MUL_ADD;
                              if (decode_mul_long = '1') then
                                 execute_mul_result <= execute_mul_result + (execute_op1 & execute_op2);
                              else
                                 execute_mul_result <= execute_mul_result + execute_op2;
                              end if;
                           elsif (decode_mul_long = '1') then
                              execute_MUL_State <= MUL_STOREHI;
                           else
                              execute_MUL_State <= MUL_IDLE;
                              execute_stall        <= '0';
                           end if;
                        end if;

                     when MUL_ADD =>
                        if (decode_mul_long = '1') then
                           execute_MUL_State <= MUL_STOREHI;
                        else
                           execute_MUL_State <= MUL_IDLE;
                           execute_stall        <= '0';
                        end if;

                     when MUL_STOREHI =>
                        execute_MUL_State <= MUL_IDLE;
                        execute_stall        <= '0';

                     when others => null;
                  end case;
               end if;

               if (decode_functions_detail = mul_dsp) then
                  case (execute_MUL_State) is
                     when MUL_DSP_ACC =>
                        if (decode_dsp_long = '1') then
                           dsp_sum33 := ('0' & execute_mul_result(31 downto 0)) + ('0' & execute_op1);
                           execute_dsp_carry <= dsp_sum33(32);
                           execute_MUL_State <= MUL_DSP_ACCHI;
                        else
                           if (execute_dsp_qset = '1') then
                              Flag_Q_Sticky <= '1';
                           end if;
                           execute_MUL_State <= MUL_IDLE;
                           execute_stall        <= '0';
                        end if;

                     when MUL_DSP_ACCHI =>
                        execute_MUL_State <= MUL_IDLE;
                        execute_stall        <= '0';

                     when others => null;
                  end case;
               end if;

               if (decode_functions_detail = block_read) then
                  if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
                     if (execute_blockRW_writereg = 15) then
                        execute_RW_dataRead <= gb_bus_din;
                     end if;
                     if (decode_block_usermoderegs = '1' and cpu_mode /= CPUMODE_USER and cpu_mode /= CPUMODE_SYSTEM and
                         ((execute_blockRW_writereg >= 13 and execute_blockRW_writereg <= 14) or
                          (execute_blockRW_writereg >= 8  and execute_blockRW_writereg <= 12 and cpu_mode = CPUMODE_FIQ))) then
                        case (to_integer(unsigned(execute_blockRW_writereg))) is
                           when 8  => regs_0_8  <= unsigned(gb_bus_din);
                           when 9  => regs_0_9  <= unsigned(gb_bus_din);
                           when 10 => regs_0_10 <= unsigned(gb_bus_din);
                           when 11 => regs_0_11 <= unsigned(gb_bus_din);
                           when 12 => regs_0_12 <= unsigned(gb_bus_din);
                           when 13 => regs_0_13 <= unsigned(gb_bus_din);
                           when 14 => regs_0_14 <= unsigned(gb_bus_din);
                           when others => null;
                        end case;
                     end if;
                  end if;
               end if;

               case (execute_RW_State) is
                  when DATARW_ADDRWAIT =>
                     if (decode_functions_detail = data_read) then
                        execute_RW_State <= DATARW_READSTART;
                     else
                        execute_RW_State <= DATARW_WRITE;
                     end if;

                  when DATARW_READSTART =>
                     if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
                        execute_RW_dataRead <= gb_bus_din;
                        if (decode_datatransfer_swap = '1') then
                           execute_RW_State <= DATARW_SWAPWRITE;
                        elsif (decode_datatransfer_double = '1') then
                           execute_RW_State <= DATARW_READSTART_D2;
                        else
                           execute_RW_State <= DATARW_READWAIT;
                        end if;
                     end if;

                  when DATARW_READSTART_D2 =>
                     if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
                        execute_RW_dataRead <= gb_bus_din;
                        execute_RW_State    <= DATARW_READWAIT;
                     end if;

                  when DATARW_READWAIT =>
                     if (dma_on_1 = '0' or dma_on = '0') then
                        if (decode_functions_detail = block_read and decode_block_switchmode = '1') then
                           execute_RW_State <= DATARW_BLOCKSWITCH;
                        elsif (decode_functions_detail = block_read and execute_blockRW_writereg = 15) then
                           execute_RW_State <= DATARW_PCWRITE;
                        elsif (decode_functions_detail = data_read and
                               decode_datatransfer_double = '0' and decode_rdest = x"F") then
                           execute_RW_State <= DATARW_PCWRITE;
                        else
                           execute_RW_State <= DATARW_IDLE;
                           execute_stall        <= '0';
                        end if;
                     else
                        execute_RW_State <= DATARW_READWAITDMA;
                     end if;

                  when DATARW_READWAITDMA =>
                     if (dma_on = '0') then
                        if (decode_functions_detail = block_read and decode_block_switchmode = '1') then
                           execute_RW_State <= DATARW_BLOCKSWITCH;
                        elsif (decode_functions_detail = block_read and execute_blockRW_writereg = 15) then
                           execute_RW_State <= DATARW_PCWRITE;
                        elsif (decode_functions_detail = data_read and
                               decode_datatransfer_double = '0' and decode_rdest = x"F") then
                           execute_RW_State <= DATARW_PCWRITE;
                        else
                           execute_RW_State <= DATARW_IDLE;
                           execute_stall        <= '0';
                        end if;
                     end if;

                  when DATARW_WRITE =>
                     if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
                        if (decode_datatransfer_double = '1') then
                           execute_RW_State <= DATARW_WRITE_D2;
                        else
                           execute_RW_State <= DATARW_IDLE;
                           execute_stall        <= '0';
                        end if;
                     end if;

                  when DATARW_WRITE_D2 =>
                     if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
                        execute_RW_State <= DATARW_IDLE;
                        execute_stall        <= '0';
                     end if;

                  when DATARW_SWAPWRITE =>
                     if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
                        execute_RW_State <= DATARW_SWAPWAIT;
                     end if;

                  when DATARW_SWAPWAIT =>
                     execute_RW_State <= DATARW_IDLE;
                     execute_stall        <= '0';

                  when DATARW_BLOCKREAD =>
                     if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
                        if (execute_blockRW_last = '1') then
                           execute_RW_State <= DATARW_READWAIT;
                        else
                           execute_blockRW_addr <= execute_RW_addr + 4;
                        end if;
                        if (execute_RW_ena = '1') then
                           execute_blockRW_writereg <= unsigned(decode_RM_op2);
                        end if;
                     end if;

                  when DATARW_BLOCKWRITE =>
                     if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
                        execute_blockRW_addr <= execute_RW_addr + 4;
                        if (execute_blockRW_last = '1') then
                           execute_RW_State   <= DATARW_IDLE;
                           execute_stall        <= '0';
                        end if;
                     end if;

                  when DATARW_BLOCKSWITCH =>
                     if (execute_blockRW_writereg = 15) then
                        execute_RW_State <= DATARW_PCWRITE;
                     else
                        execute_RW_State <= DATARW_IDLE;
                        execute_stall        <= '0';
                     end if;

                  when DATARW_PCWRITE =>
                     execute_RW_State <= DATARW_IDLE;
                     execute_stall        <= '0';

                  when others => null;
               end case;

            elsif (execute_now = '1') then

               regs(15) <= decode_PC;

               -- synthesis translate_off
               execute_opcode_export <= decode_opcode_export;
               -- synthesis translate_on

               if (execute_skip = '0') then
                  case decode_functions_detail is

                     when branch_all =>
                        if (decode_branch_link = '1') then
                           if (decode_branch_long = '1') then
                              regs(14) <= decode_PC - 2;
                              regs(14)(0) <= '1';
                           else
                              regs(14) <= decode_PC - 4;
                           end if;
                        end if;
                        if (decode_set_thumbmode = '1') then
                           thumbmode <= execute_op2(0);
                        end if;
                        if (decode_branch_forcethumb = '1') then
                           thumbmode <= '1';
                        end if;
                        if (decode_branch_forcearm = '1') then
                           thumbmode <= '0';
                        end if;

                     when alu_and | alu_xor | alu_add | alu_sub | alu_add_withcarry | alu_sub_withcarry | alu_or | alu_mov | alu_and_not | alu_mov_not =>
                        if (decode_alu_use_shift = '1' and decode_shift_regbased = '1') then
                           execute_stall        <= '1';
                           alu_wait_shift <= '1';
                        elsif (decode_writeback = '1' and decode_rdest = x"F") then
                           execute_stall        <= '1';
                           alu_pcwrite_wait   <= '1';
                           execute_RW_dataRead <= std_logic_vector(alu_result);
                        end if;

                     when data_processing_MRS => null;

                     when data_processing_MSR =>
                        if (decode_psr_with_spsr = '1') then
                           case (cpu_mode) is
                              when CPUMODE_FIQ        => regs_1_17 <= execute_msr_writevalue;
                              when CPUMODE_IRQ        => regs_2_17 <= execute_msr_writevalue;
                              when CPUMODE_SUPERVISOR => regs_3_17 <= execute_msr_writevalue;
                              when CPUMODE_ABORT      => regs_4_17 <= execute_msr_writevalue;
                              when CPUMODE_UNDEFINED  => regs_5_17 <= execute_msr_writevalue;
                              when others => null;
                           end case;
                        end if;

                     when mulboth =>
                        execute_stall        <= '1';
                        execute_MUL_State    <= MUL_MUL;

                        execute_mul_wait <= 3;
                        if    (execute_op2(31 downto 8)  = x"000000") then execute_mul_wait <= 0;
                        elsif (execute_op2(31 downto 16) = x"0000"  ) then execute_mul_wait <= 1;
                        elsif (execute_op2(31 downto 24) = x"00"    ) then execute_mul_wait <= 2; end if;
                        if (decode_mul_long = '0' or decode_mul_signed = '1') then
                           if    (execute_op2(31 downto 8)  = x"FFFFFF") then execute_mul_wait <= 0;
                           elsif (execute_op2(31 downto 16) = x"FFFF"  ) then execute_mul_wait <= 1;
                           elsif (execute_op2(31 downto 24) = x"FF"    ) then execute_mul_wait <= 2; end if;
                        end if;

                        if (decode_mul_long = '0' or decode_mul_signed = '0') then
                           execute_mul_result <= execute_op1 * execute_op2;
                        else
                           execute_mul_result <= unsigned(signed(execute_op1) * signed(execute_op2));
                        end if;

                     when data_read | data_write =>
                        execute_stall        <= '1';
                        if (decode_datatransfer_shiftval = '1') then
                           execute_RW_State <= DATARW_ADDRWAIT;
                        elsif (decode_functions_detail = data_read) then
                           execute_RW_State <= DATARW_READSTART;
                        else
                           execute_RW_State <= DATARW_WRITE;
                        end if;

                        if (decode_datatransfer_addup = '1') then
                           execute_RW_WBaddr <= execute_busaddress + execute_busaddmod;
                        else
                           execute_RW_WBaddr <= execute_busaddress - execute_busaddmod;
                        end if;
                        if (decode_shift_regbased = '1') then
                           error_cpu <= '1';
                        end if;

                     when block_read | block_write =>
                        if (decode_functions_detail = block_read) then
                           execute_RW_State         <= DATARW_BLOCKREAD;
                        else
                           execute_RW_State         <= DATARW_BLOCKWRITE;
                        end if;
                        execute_stall            <= '1';
                        execute_blockRW_writereg <= unsigned(decode_RM_op2);
                        execute_blockRW_endaddr  <= unsigned(signed(execute_busaddress) + decode_block_endmod);
                        execute_blockRW_addr     <= unsigned(signed(execute_busaddress) + (decode_block_addrmod + 4));
                        execute_blockRW_addr(1 downto 0) <= "00";

                     when IRQ =>
                        IRQ_disable <= '1';
                        thumbmode   <= '0';
                        done        <= '0';
                        cpu_mode    <= CPUMODE_IRQ;

                     when software_interrupt_detail =>
                        IRQ_disable <= '1';
                        thumbmode   <= '0';
                        cpu_mode    <= CPUMODE_SUPERVISOR;


                     when alu_clz | nop_detail => null;

                     when sat_arith =>
                        if (execute_sat_qset = '1') then
                           Flag_Q_Sticky <= '1';
                        end if;

                     when mul_dsp =>
                        execute_stall        <= '1';
                        execute_MUL_State <= MUL_DSP_ACC;
                        if (decode_dsp_x = '1') then
                           dsp_ra := signed(execute_op2(31 downto 16));
                        else
                           dsp_ra := signed(execute_op2(15 downto 0));
                        end if;
                        if (decode_dsp_y = '1') then
                           dsp_rb := signed(execute_op1(31 downto 16));
                        else
                           dsp_rb := signed(execute_op1(15 downto 0));
                        end if;
                        if (decode_dsp_word = '1') then
                           dsp_pw := signed(execute_op2) * dsp_rb;
                           execute_mul_result <= unsigned(resize(dsp_pw(47 downto 16), 64));
                        else
                           dsp_p := dsp_ra * dsp_rb;
                           execute_mul_result <= unsigned(resize(dsp_p, 64));
                        end if;

                     when cp15_op =>
                        if (decode_cp15_mrc = '1') then
                           if (decode_rdest = x"F") then
                              Flag_Negative   <= cp15_rdata(31);
                              Flag_Zero       <= cp15_rdata(30);
                              Flag_Carry      <= cp15_rdata(29);
                              Flag_V_Overflow <= cp15_rdata(28);
                           end if;
                        else
                           cp15_wval := std_logic_vector(execute_opDest);
                           case (decode_cp15_crn) is
                              when x"1" =>
                                 cp15_control <= (cp15_wval and x"000FF085") or x"00000078";
                              when x"2" =>
                                 if (decode_cp15_op2(0) = '1') then
                                    cp15_pu_icache <= cp15_wval;
                                 else
                                    cp15_pu_dcache <= cp15_wval;
                                 end if;
                              when x"3" => cp15_pu_wbuf <= cp15_wval;
                              when x"5" =>
                                 if (decode_cp15_op2(0) = '1') then
                                    cp15_pu_iperm <= cp15_wval;
                                 else
                                    cp15_pu_dperm <= cp15_wval;
                                 end if;
                              when x"6" =>
                                 cp15_pu_region(to_integer(unsigned(decode_cp15_crm(2 downto 0)))) <= cp15_wval;
                              when x"7" =>
                                 v_cacheop := "1111";
                                 case (decode_cp15_crm) is
                                    when x"5" =>
                                       if    (decode_cp15_op2 = "000") then v_cacheop := "0000";
                                       elsif (decode_cp15_op2 = "001") then v_cacheop := "0001";
                                       end if;
                                    when x"6" =>
                                       if    (decode_cp15_op2 = "000") then v_cacheop := "0010";
                                       elsif (decode_cp15_op2 = "001") then v_cacheop := "0011";
                                       elsif (decode_cp15_op2 = "010") then v_cacheop := "0100";
                                       end if;
                                    when x"A" =>
                                       if    (decode_cp15_op2 = "001") then v_cacheop := "0101";
                                       elsif (decode_cp15_op2 = "010") then v_cacheop := "0110";
                                       end if;
                                    when x"E" =>
                                       if    (decode_cp15_op2 = "001") then v_cacheop := "0111";
                                       elsif (decode_cp15_op2 = "010") then v_cacheop := "1000";
                                       end if;
                                    when others => null;
                                 end case;
                                 if (v_cacheop /= "1111") then
                                    cache_op             <= v_cacheop;
                                    cache_op_addr        <= cp15_wval;
                                    cache_op_ena         <= '1';
                                    execute_stall        <= '1';
                                    execute_cacheop_wait <= '1';
                                 end if;
                              when x"9" =>
                                 if (decode_cp15_crm = x"1") then
                                    if (decode_cp15_op2 = "001") then
                                       cp15_itcm_reg <= cp15_wval;
                                    else
                                       cp15_dtcm_reg <= cp15_wval;
                                    end if;
                                 else
                                    if (decode_cp15_op2 = "001") then
                                       cp15_icache_lock <= cp15_wval;
                                    else
                                       cp15_dcache_lock <= cp15_wval;
                                    end if;
                                 end if;
                              when x"D" => cp15_trace_pid <= cp15_wval;
                              when others => null;
                           end case;
                        end if;

                     when others =>
                        error_cpu <= '1';
                        report "not implemented execute function" severity failure;

                  end case;

               end if;


            end if;

            if (execute_switchmode_now = '1' and
                (execute_now = '1' or execute_RW_State = DATARW_BLOCKSWITCH)) then

                  if (execute_switchmode_new = CPUMODE_FIQ and cpu_mode /= CPUMODE_FIQ) then
                     regs_0_8  <= regs(8);
                     regs_0_9  <= regs(9);
                     regs_0_10 <= regs(10);
                     regs_0_11 <= regs(11);
                     regs_0_12 <= regs(12);
                  end if;

                  case (cpu_mode) is
                     when CPUMODE_USER | CPUMODE_SYSTEM =>
                        regs_0_13 <= regs(13);
                        regs_0_14 <= regs(14);

                     when CPUMODE_FIQ =>
                        regs_1_8  <= regs(8);
                        regs_1_9  <= regs(9);
                        regs_1_10 <= regs(10);
                        regs_1_11 <= regs(11);
                        regs_1_12 <= regs(12);
                        regs_1_13 <= regs(13);
                        regs_1_14 <= regs(14);

                     when CPUMODE_IRQ =>
                        regs_2_13 <= regs(13);
                        regs_2_14 <= regs(14);

                     when CPUMODE_SUPERVISOR =>
                        regs_3_13 <= regs(13);
                        regs_3_14 <= regs(14);

                     when CPUMODE_ABORT =>
                        regs_4_13 <= regs(13);
                        regs_4_14 <= regs(14);

                     when CPUMODE_UNDEFINED =>
                        regs_5_13 <= regs(13);
                        regs_5_14 <= regs(14);

                     when others => report "should never happen" severity failure;
                  end case;

                  case (execute_switchmode_new) is
                     when CPUMODE_USER | CPUMODE_SYSTEM =>
                        if (cpu_mode /= CPUMODE_USER and cpu_mode /= CPUMODE_SYSTEM) then
                           regs(13) <= regs_0_13;
                           regs(14) <= regs_0_14;
                        end if;

                     when CPUMODE_FIQ =>
                        if (cpu_mode /= CPUMODE_FIQ) then
                           regs(8)  <= regs_1_8 ;
                           regs(9)  <= regs_1_9 ;
                           regs(10) <= regs_1_10;
                           regs(11) <= regs_1_11;
                           regs(12) <= regs_1_12;
                           regs(13) <= regs_1_13;
                           regs(14) <= regs_1_14;
                        end if;
                        if (execute_switchmode_state = '1') then regs_1_17 <= CPSR; end if;

                     when CPUMODE_IRQ =>
                        if (cpu_mode /= CPUMODE_IRQ) then
                           regs(13) <= regs_2_13;
                           if (decode_functions_detail /= IRQ) then
                              regs(14) <= regs_2_14;
                           end if;
                        end if;
                        if (execute_switchmode_state = '1') then regs_2_17 <= CPSR; end if;

                     when CPUMODE_SUPERVISOR =>
                        if (cpu_mode /= CPUMODE_SUPERVISOR) then
                           regs(13) <= regs_3_13;
                           if (decode_functions_detail /= software_interrupt_detail) then
                              regs(14) <= regs_3_14;
                           end if;
                        end if;
                        if (execute_switchmode_state = '1') then regs_3_17 <= CPSR; end if;

                     when CPUMODE_ABORT =>
                        if (cpu_mode /= CPUMODE_ABORT) then
                           regs(13) <= regs_4_13;
                           regs(14) <= regs_4_14;
                        end if;
                        if (execute_switchmode_state = '1') then regs_4_17 <= CPSR; end if;

                     when CPUMODE_UNDEFINED =>
                        if (cpu_mode /= CPUMODE_UNDEFINED) then
                           regs(13) <= regs_5_13;
                           regs(14) <= regs_5_14;
                        end if;
                        if (execute_switchmode_state = '1') then regs_5_17 <= CPSR; end if;

                     when others => report "should never happen" severity failure;
                  end case;

                  if (cpu_mode = CPUMODE_FIQ and execute_switchmode_new /= CPUMODE_FIQ) then
                     regs(8)  <= regs_0_8;
                     regs(9)  <= regs_0_9;
                     regs(10) <= regs_0_10;
                     regs(11) <= regs_0_11;
                     regs(12) <= regs_0_12;
                  end if;

            end if;

         end if;

      end if;
   end process;


   -- synthesis translate_off
   goutput : if is_simu = '1' generate
      signal export_halt     : std_logic := '0';
      signal decode_unhalt_1 : std_logic := '0';
   begin

      process
      begin

         while (true) loop
            wait until rising_edge(clk);

            cpu_export_done <= '0';

            if (execute_done = '1') then
               export_halt <= decode_halt;
            elsif (IRQ_in = '1') then
               export_halt <= '0';
            end if;

            decode_unhalt_1 <= decode_unhalt;

            if (((done = '1' or (export_halt = '1' and dma_on_1 = '0')) and decode_unhalt = '0') or decode_unhalt_1 = '1') then

               while (decode_ready = '0' and export_halt = '0' and reset = '0') loop
                  wait until rising_edge(clk);
               end loop;

               cpu_export_done <= not reset;
               for i in 0 to 14 loop
                  cpu_export.regs(i) <= regs(i);
               end loop;
               cpu_export.pc     <= regs(15);
               cpu_export.opcode <= unsigned(execute_opcode_export);
               cpu_export.CPSR   <= CPSR;
               cpu_export.SPSR   <= SPSR;
               cpu_export.regs_0_8  <= regs_0_8 ;
               cpu_export.regs_0_9  <= regs_0_9 ;
               cpu_export.regs_0_10 <= regs_0_10;
               cpu_export.regs_0_11 <= regs_0_11;
               cpu_export.regs_0_12 <= regs_0_12;
               cpu_export.regs_0_13 <= regs_0_13;
               cpu_export.regs_0_14 <= regs_0_14;
               cpu_export.regs_1_8  <= regs_1_8 ;
               cpu_export.regs_1_9  <= regs_1_9 ;
               cpu_export.regs_1_10 <= regs_1_10;
               cpu_export.regs_1_11 <= regs_1_11;
               cpu_export.regs_1_12 <= regs_1_12;
               cpu_export.regs_1_13 <= regs_1_13;
               cpu_export.regs_1_14 <= regs_1_14;
               cpu_export.regs_1_17 <= regs_1_17;
               cpu_export.regs_2_13 <= regs_2_13;
               cpu_export.regs_2_14 <= regs_2_14;
               cpu_export.regs_2_17 <= regs_2_17;
               cpu_export.regs_3_13 <= regs_3_13;
               cpu_export.regs_3_14 <= regs_3_14;
               cpu_export.regs_3_17 <= regs_3_17;
               cpu_export.regs_4_13 <= regs_4_13;
               cpu_export.regs_4_14 <= regs_4_14;
               cpu_export.regs_4_17 <= regs_4_17;
               cpu_export.regs_5_13 <= regs_5_13;
               cpu_export.regs_5_14 <= regs_5_14;
               cpu_export.regs_5_17 <= regs_5_17;

            end if;

         end loop;

      end process;

   end generate goutput;
-- synthesis translate_on



end architecture;
