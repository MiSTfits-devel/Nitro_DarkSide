# Clash migration boundary

This directory is the beginning of a source-owned replacement for the small
part of the MiSTer framework that the NDS core instantiates directly.

| NDS use | Current owner | Migration status |
| --- | --- | --- |
| `hps_io` | `nds_hps_io_boundary.sv` | Compatibility wrapper around the mature HPS transport; `Mister.HpsIoSubset` is the Clash state machine for the NDS control-plane commands. File transfer and the tri-state bus wrapper remain legacy until the protocol has hardware traces. |
| `video_mixer` | `Mister.VideoMixer` | Replaced in `NDS.sv`. The checked-in Clash-aligned core implements the NDS-active path: no scandoubler/HQ2x and `HDMI_FREEZE=0`. `gamma_corr` remains a deliberately tiny SystemVerilog island because it is a dual-clock RAM. |
| `video_freak` | `sys/video_freak.sv` | Still legacy. It contains the asynchronous HDMI-size integer-scaling calculator; port it after its HPS-visible timing is captured. |

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

For deterministic, 50,000-cycle differential fuzzing of the active mixer
branch, run `clash/tests/run_video_mixer_diff.sh`. The isolated dirty-tree
Quartus integration build is `clash/tests/remote_quartus_integration.sh`
(default pod: `nds-quartus-clash-9`).

The fuzzer accepts `CYCLES` and `SEED`, for example:
`CYCLES=250000 SEED=0xc001d00d clash/tests/run_video_mixer_diff.sh`.

The HPS module is intentionally not selected by the wrapper yet. A half
ported HPS transport would make controller input and ROM download appear to
work until an unimplemented transaction corrupts state; the boundary keeps
that replacement a one-module change once the complete protocol is covered.
