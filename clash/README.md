# Clash migration boundary

This directory is a source-owned replacement for the small part of the MiSTer
framework that the NDS core instantiates directly. None of the checked-in RTL
carries a GPL license; it is written fresh to the interface and timing
contracts the framework's consumers rely on.

| NDS use | Current owner | Migration status |
| --- | --- | --- |
| `hps_io` | `nds_hps_io.sv` + `nds_hps_io_boundary.sv` | Replaced. `nds_hps_io` decodes the uio/fp command subset the core uses (config, joystick, status, gamma, analog, file transfer); SD and unused commands are answered with protocol-legal values instead of implemented. Differential-fuzzed against the framework reference by `clash/tests/run_hps_io_diff.sh`. |
| `video_mixer` | `Mister.VideoMixer` | Replaced in `NDS.sv`. The checked-in Clash-aligned core implements the NDS-active path: no scandoubler/HQ2x and `HDMI_FREEZE=0`. `gamma_corr` remains a deliberately tiny SystemVerilog island because it is a dual-clock RAM. |
| `video_freak` | `nds_clash_video_freak.sv` | Replaced in `NDS.sv`. Source-owned port of the integer aspect/scaling calculator (crop path present but inert, since NDS ties CROP_SIZE=0). Differential-fuzzed against a fresh reference by `clash/tests/run_video_freak_diff.sh`. |

The checked-in RTL in `rtl/` is the build input, so a Quartus build never
depends on a local Haskell installation. It mirrors the Clash source and is
kept beside it to make the exact hardware reviewable. Regenerate it with Clash
and check in the reviewed result whenever the Haskell changes.

To regenerate after installing Clash (the command may vary slightly by
Clash release):

```sh
cd clash
clash --verilog -isrc --outputdir rtl src/Mister/VideoMixer.hs
```

`nds-mister-clash.cabal` pins the source dependency range; `cabal build` is a
quick type-check before emitting HDL.

Run the smoke test from the repository root with
`sim/run_clash_video_mixer_tb.sh`. It exercises the checked-in core's CE
recovery and one-cycle output pipeline. (The stock framework relies on a
Quartus-accepted declaration order in `gamma_corr.sv` that Icarus rejects, so
the direct stock-vs-generated comparison belongs in the Quartus build.)

Differential fuzzers (deterministic, `SEED`-driven):

- `clash/tests/run_video_mixer_diff.sh` — mixer core vs the NDS-selected
  video_mixer branch. `CYCLES=250000 SEED=0xc001d00d` for a long run.
- `clash/tests/run_video_freak_diff.sh` — `nds_clash_video_freak` vs a fresh
  reference of the aspect/scale calculator.
- `clash/tests/run_hps_io_diff.sh` — `nds_hps_io` vs the framework hps_io
  reference over the core's command set.

The isolated dirty-tree Quartus integration build is
`clash/tests/remote_quartus_integration.sh` (default pod: `nds-quartus-clash-9`).

## 3D inversion

The 3D path is moving into Clash and the 2D path is moving to the ARM; see
[the inversion plan](../docs/GPU3D_CLASH.md). The first block is the exact
melonDS edge walk in `src/Nds/Gpu3D/Slope.hs`, gated on the host by
`tests/run_slope_check.sh`. The flat triangle fill is `src/Nds/Gpu3D/Raster.hs`,
gated by `tests/run_raster_check.sh`. The streaming top is
`src/Nds/Gpu3D/Flat.hs`, gated under Clash simulation by
`tests/run_flat_check.sh`, with the exhaustive row-union gate in
`tests/run_flat_property.sh` and the reciprocal-table gate in
`tests/run_recip_check.sh`. The depth interpolator is `src/Nds/Gpu3D/Depth.hs`,
gated by `tests/run_depth_check.sh` against the production `Interpolator` and
`Slope` classes. `Nds.Gpu3D.Flat` carries FinalZ and the raw depth-interpolator
endpoints on every span; its gate compares every expanded pixel against
`rasterTriFinalDepth`. `Nds.Gpu3D.Frame` is the depth-tested frame model;
`tests/run_frame_check.sh` renders directed and seeded random frames through the
production `RenderFrame` and compares all 49,152 pixels on colour and final
depth. `Nds.Gpu3D.DepthPipe` is the streaming depth engine (Clash top
`nds_gpu3d_depth`); `tests/run_depth_pipe_check.sh` runs it against a
behavioural memory and compares the framebuffer and every depth word.
`tests/run_pixel_gate.sh` type-checks every module, runs the cheap checks
first and the melonDS oracle gates last. No Quartus build is attempted until those
gates are green.

The native toolchain is `stack` with `stack.yaml` (GHC 9.6.6, Clash 1.8.4). The
gate needs no Clash install: the pure model is base-only. Synthesis uses
`stack exec clash -- --verilog ...`; the checked-in results are
`rtl/nds_gpu3d_slope.v` and `rtl/nds_gpu3d_flat.v`.

`tools/gx3d_oracle` is the headless melonDS raster oracle. It constructs
polygons directly, calls the production `SoftRenderer3D::RenderFrame`, and writes
the 256x192 RGBA buffer, so the Clash rasteriser can be compared against the
same code the hybrid core runs. `tools/gx3d_oracle/gen_main.py` generates the
oracle from the vendored headers so layout constants cannot be retyped wrong.
