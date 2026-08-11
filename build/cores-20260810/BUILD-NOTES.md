# NDS cores, 2026-08-10 — cart-prefetch images

Built from `c753ef8` plus the uncommitted cart-access work in the tree at build
time (`nds_card.vhd` prefetch queue, `nds_top.vhd` `CARDSPEED_SHIFT => 2`).
Streamed with `DIRTY=1`, so there was no commit to point at — the patch is kept
beside these files as `cartprefetch.patch`, and it stays the reproduction recipe
for *these* binaries.

That cart work has since landed as `e745b05`, but do not rebuild from it and
expect a match: the commit sits on top of the drawer merge, the GPU_CE_DIV
removal and the ARM9 pair fills, none of which were in these images. The RTL
delta is the same; the base is not.

Device is `5CSEBA6U23I7`: 41,910 ALMs, 553 M10K, 4,191 LABs.

## The images

| file | SOUND | DEBUG | HDMI | ring | seed | ALMs | RAM | worst setup | worst hold |
|---|---|---|---|---|---|---|---|---|---|
| `NDS_cart_audio_20260810.rbf` | 1 | 0 | no | no | 3 | 41,206 (98%) | 481 (87%) | +1.539 | +0.248 |
| `NDS_cart_hdmi_20260810.rbf` | 0 | 1 | yes | no | 1 | 39,100 (93%) | 526 (95%) | +0.126 | +0.242 |
| `NDS_cart_hdmihps_20260810.rbf` | 0 | 1 | yes | yes | 0 | 40,519 (97%) | 528 (95%) | −0.015 | +0.238 |
| `NDS_cart_hdmi_s3_20260810.rbf` | 0 | 1 | yes | no | 3 | 39,072 (93%) | 526 (95%) | −0.223 | +0.173 |

The first three are clean or effectively clean. The fourth is kept only because
it is the image the owner approved before the seed sweep finished; the seed-1
build supersedes it at the same config.

### `NDS_cart_audio_20260810.rbf`
Fabric SPU, real game audio. **Analog only** — no HDMI, so this needs the IO
board. Clean on both axes. `nitrodbg` will not work against it: `DEBUG_ENABLE=0`
compiles out `nds_debug`, and `nds_perf` with it (gated on the same generic at
`nds_top.vhd:1261`).

### `NDS_cart_hdmi_20260810.rbf`
HDMI out, **no audio at all**. `DEBUG_ENABLE=1`, so this is the image where
`nitrodbg card` reports the new prefetch queue depth.

### `NDS_cart_hdmihps_20260810.rbf`
HDMI plus the DDR3 audio ring (`NDS_HPS_AUDIO=1`, ~198 ALMs). **This is not
game audio.** The FPGA half of the transport is built; the SPU daemon is not
(`docs/HPS_AUDIO.md`, "What is not built", item 4). What it can do today is
play the `tools/audio-tone.sh` test tone, which is what makes it the image that
proves the ring on silicon. Pixel clock is −0.015 ns, i.e. zero within any
meaning the tool has at this resolution.

## The two marginal families, measured across eight fits

Every build below is the same RTL; only `SEED` changes. Neither family is the
new cart logic.

**Pixel clock** (`pll_hdmi ... counter[0]`), setup:

| seed | 0 | 1 | 3 | 5 |
|---|---|---|---|---|
| hdmi | +0.083 | **+0.126** | −0.223 | −0.219 |
| hdmi+ring | −0.015 | — | +0.064 | — |

The QSF note at line 256 called "fails setup on nearly every seed" folklore
after measuring +0.352 on seed 3. That rebuttal was over-confident: on this
tree the domain sits within ±0.22 ns of zero and which side it lands on is a
coin flip on seed. It is neither folklore nor reliable — it is marginal, and a
build that needs HDMI should sweep rather than assume.

**Main-RAM request crossing**, hold — `nds_mainram|req9_din[19]` ->
`nds_mainram|mr_sdram_Din[19]`, launch clk_sys (`general[2]`), latch clk_mem
(`general[0]`), skew −0.001:

| seed | 0 | 1 | 3 | 5 |
|---|---|---|---|---|
| audio | −0.538 | — | clean | — |
| hdmi | −0.578 | clean | clean | clean |
| hdmi+ring | clean | — | −0.204 | — |

Seed 0 fails it in both configs at ~−0.55, which is not a nick. This is a
second marginal family alongside the `sdram.sv` `ch1_rq/state.* -> SDRAM_A[7:8]`
one at `NDS.qsf:195`, and unlike that one it is a real intra-design crossing
rather than an I/O path. Worth a look before the next area push: a config at
98% has very little say in where the placer puts it.

## Area

The prefetch queue cost **+7 ALMs** against the shipped `NDS_snd_20260809`
(41,199 -> 41,206, same config). `CARDPREFETCH` never had to be reduced.

## Deploying

    HOST=192.168.1.243 tools/deploy-core.sh \
      build/cores-20260810/NDS_cart_audio_20260810.rbf NDS_cart_audio_20260810

`deploy-core.sh` refuses to overwrite an existing remote name and verifies
sha256 on the device before moving the file into place. Add `NOLOAD=1` to
upload without switching the running core.

    NDS_cart_audio_20260810    7b0fc0892f435c25d4a2ff17b16721bcea95f487d20039efe54ee2d0838d9a73
    NDS_cart_hdmi_20260810     6108578282154105db88bedbee52d92f668c9895eb4403ed0316bbc095889d33
    NDS_cart_hdmihps_20260810  a508281f26eb758311e4fd6cd3dae718c0d8a49dde36c5cfa71184fd4bdc9895
    NDS_cart_hdmi_s3_20260810  4040473cae96310065c55ae655e807e0449ca6b103821c98474f18d0004d702e
