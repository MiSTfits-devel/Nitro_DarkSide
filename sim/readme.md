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
- `run_vram_torture_tb.sh` / `run_mainram_tb.sh` — M1 memory-fabric benches.
- `run_arm7_island.sh` / `run_arm9_island.sh` — CPU islands with self-checking
  mailbox exit tests (M2/M3).
- `run_arm9_cache.sh` — nds_cache9 exercise (write-back, clean/invalidate,
  I-cache staleness) on the island harness.
- `run_arm9_trace.sh` — per-retired-instruction trace for the melonDS
  differential (docs/TRACE_DIFF.md); `LOADADDR=33554432` boots a main-RAM
  workload instead of the boot ROM. The melonDS side lives in
  `sim/melonds_tracer/`.
- `run_gpu_bg.sh` — M5 BG drawer line tests (text/affine/extended + ext
  palettes) vs the `gen_gpu_bg.py` golden model. Regenerate the hex inputs
  with `python3 sim/tests/gen_gpu_bg.py` (from `sim/tests/`) first.
- `run_gpu_obj.sh` — M5 OBJ drawer line tests (tile/bitmap/affine sprites,
  ext palettes, priority merge) vs `gen_gpu_obj.py`; same regenerate flow.
- `run_vram_ls_tb.sh` — M5 VRAM line-server tests: the renderer BG/OBJ/
  ext-palette read channels of `nds_vram` vs the `gen_vram_ls.py` golden
  (independent GBATEK mapping model), with CPU-port differential reads and
  concurrent-channel arbiter checks; same regenerate flow.

## Adding a bench

1. `tb_<x>.vhd` instantiating real RTL (+ `ddrram_model`/`sdram` from GBA sim when the
   fabric is involved), asserting a concrete end condition.
2. `run_<x>_tb.sh` following the existing pattern; generate any ROM/BIOS `.hex` inputs
   inline with python (see GBA_MiSTer/sim/run_gba2p_sdram_tb.sh for the reference).
3. Keep `STOP_TIME` overridable via env, default tight.
