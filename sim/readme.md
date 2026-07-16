# Simulation

Same flow as GBA_MiSTfits: [nvc](https://github.com/nickg/nvc), three logical libraries
(`altera_mf` stub / `mem` primitives / `work`), self-checking testbenches run by
`run_*.sh` scripts with `--exit-severity=failure` as the pass/fail gate.

Short unit tests run fine on a laptop. Full-system benches (CPU boot, game boot,
differential traces vs melonDS) go to the x86_64 k8s host — budget hours-to-days for
seconds of sim time and design the benches to be checkpointable/self-checking, never
eyeball-checked.

## Scripts

- `run_analyze_all.sh` — analyzes + elaborates every RTL file; the CI smoke gate.
  Run after every RTL change.
- `run_vram_map_tb.sh` — unit test for `nds_vram_map` (VRAMCNT decode) against the
  NitroSDK `gx_vramcnt.c` truth table. 84 checks.

## Adding a bench

1. `tb_<x>.vhd` instantiating real RTL (+ `ddrram_model`/`sdram` from GBA sim when the
   fabric is involved), asserting a concrete end condition.
2. `run_<x>_tb.sh` following the existing pattern; generate any ROM/BIOS `.hex` inputs
   inline with python (see GBA_MiSTer/sim/run_gba2p_sdram_tb.sh for the reference).
3. Keep `STOP_TIME` overridable via env, default tight.
