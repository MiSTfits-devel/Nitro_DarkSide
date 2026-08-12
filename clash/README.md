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
