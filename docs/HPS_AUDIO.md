# Sound on the ARM

The SPU is moving off the fabric and onto the HPS. This document is the
protocol between the two halves, the reasoning behind the split, and what is
built so far.

## Why

`nds_sound` costs ~7,258 ALMs in context (6,402 per-entity, 10,060 ALUTs
synthesised). The device has 41,910 and two images ship today because they
cannot be combined: `NDS_audio_20260806` at 41,024 ALMs with sound and no HDMI,
`NDS_hdmi_noflicker_20260806` at 38,176 with HDMI and no sound. HDMI is a
measured ~3,600 ALMs. There is no arrangement of the current design that has
both.

The scoped ablation in FITTING.md says where the logic is: deleting decode and
position advance leaves 2,631 of 10,060 ALUTs, and ADPCM decode alone is 4,456.
So the two candidate splits are:

| | RTL keeps | net ALMs freed | 41,024 − freed + HDMI |
|---|---|---:|---:|
| **Full farm-out** | register file, write capture, DDR3 plumbing | ~4,000–5,000 | **~40,100 (96%)** |
| Decode + mix only | timers, position advance, fetch, lifecycle | ~2,450–2,850 | ~41,970 — over the device |

Decode-only is the better-behaved design — exact busy bits, sample words read at
the instant hardware would read them, two one-way streams and no request/response
— and it does not buy the thing this is for. It lands above 41,241 ALMs, which is
the measured point where the router gave up rather than the placer (FITTING.md,
"How audio was made to fit"). So: full farm-out.

## The constraint everything else follows from

NDS main RAM is 4 MB in **board SDRAM** (`rtl/nds_mainram.vhd`), not DDR3. The
HPS has no path to it. This is the same wall the 3D brief hit with textures,
except sample data has no VRAMCNT-equivalent marker saying "this region is
sound", so the shadow-at-write-time trick from `NDS_3D_HPS_BRIEF.md` does not
transfer. The ARM gets sample words by asking the FPGA for them, over the same
ARM7-membus guest port `nds_sound` already uses today (`snd_bus_req/ok/own`).

Bandwidth for that path is bounded by consumption, not by main-RAM write
traffic: 16 channels × 32.73 kHz × 4 bytes is a 2 MB/s worst case and far less
in practice.

## Fidelity costs, stated up front

Three, all inherent to the split rather than to this implementation:

- **Busy-bit latency.** `SOUNDxCNT` bit 31 is cleared by the daemon posting a
  finished mask, so a game polling it sees a one-shot channel end late by the
  daemon's chunk period. This is the `GXSTAT` busy problem from the 3D brief
  wearing a different hat.
- **Reads land late.** The daemon reads main RAM up to a chunk period after
  hardware would have. Typical NitroSDK stream buffers are 100 ms+ and a chunk
  is a few ms, so the margin is large — but it is a divergence, not a rounding
  error, and a game that recycles a sample buffer aggressively will find it.
- **Output delay.** Audio picks up a fixed delay equal to how full the ring is
  kept, 20–40 ms, which the fabric SPU does not have.

Register writes must be captured with a tick timestamp or channel starts jitter
by the chunk period, which is audible. That is cheap and not optional.

## DDR3 region

`0x0FFD0000`, 64 KB, FPGA-side; **HPS `0x3FFD0000`**. Clear of every other
client: above the framebuffer (`0x0FE00000` + 512 KB) and the firmware image
(`0x0FF00000` + 256 KB), below the debug mailbox (`0x0FFF0000`), far above the
128 MB card ceiling.

It rides `ddram` **ch3**, which was a tied-off 16-bit donor channel with a
`[25:1]` address — 64 MB of reach, so it could not name this region at all. It
is now ch4's shape: 64-bit R/W with byte enables and a full `[27:1]` address.

| offset | word | writer | meaning |
|---|---|---|---|
| `+0x0000` | `wr_ptr` | ARM | producer frame count, free-running |
| `+0x0004` | `{0xAD10, flags}` | ARM | bit0 `ENABLE`, bit1 `LOOP` |
| `+0x0008` | `rd_ptr` | FPGA | consumer frame count, free-running |
| `+0x000C` | `{0xAD11, underruns}` | FPGA | saturating underrun count |
| `+0x0100` | ring | ARM | 8192 frames of `{int16 left, int16 right}` |

Frames are 4 bytes; a 64-bit DDR3 beat is exactly 2 frames. **`wr_ptr` must
advance in multiples of 2** — an odd count would strand a frame until its
partner arrived, and requiring even counts removes the case instead of handling
it. The ARM produces in blocks of hundreds of frames regardless.

### The magic words are load-bearing

Same reasoning as the debug mailbox: an all-zero or stale region must never read
as "enabled", or a core carrying this module would emit garbage on every machine
that has never run the daemon. No magic, no audio. That is why the module can be
compiled in by default without changing how any existing image behaves.

### Write ordering

`devmem` and `/dev/mem` do 32-bit accesses, so the two halves of the 64-bit
control beat land separately and the FPGA can poll between them.

- **Enabling:** write `wr_ptr` first, the magic+flags word last. A poll caught in
  between sees the old flags — which read as disabled — and tries again.
- **Disabling:** write the flags word first, for the same reason.
- **Steady state:** only `wr_ptr` ever moves, so the beat cannot tear at all.

The consumer beat is written by the FPGA as one atomic DDR3 beat but read by the
ARM as two loads. Both fields are monotonic counters, so a skew of one writeback
period is harmless.

### Startup and resync

On the 0→1 edge of `ENABLE` the FPGA zeroes both pointers and flushes its FIFO.
The contract is therefore: **fill the ring from frame 0, set `wr_ptr`, then set
`ENABLE`.**

DDR3 survives FPGA reconfiguration, so the core can be reset out from under a
running daemon and come up with `ENABLE` already set in memory. It resyncs to
frame 0, and the daemon sees `rd_ptr` jump **backwards**. That is the agreed
signal to restart the stream: clear `ENABLE`, re-prime from frame 0, set
`ENABLE` again.

## What is built

`rtl/nds_audio_ddr3.sv` — the FPGA end. Polls the control beat, fetches ring
beats through ch3 into a 16-beat FIFO, and drains one frame per 1024 `clk_sys`
cycles (32.729 kHz, the rate `nds_sound` produced). Publishes `rd_ptr` and the
underrun count. Gated by the `NDS_HPS_AUDIO` macro, **on by default** — it is
inert without the magic word, and today's shipping default has no audio at all.

Steady state is one beat per 61 µs against ~977 µs of FIFO, and ch3 outranks the
mailbox and both framebuffer channels in `ddram.sv`'s grant chain. Starvation
here means the ARM stopped producing, not that DDR3 was slow — which is why the
underrun count is published rather than merely counted. On starvation the output
ramps to zero over ~14 ms rather than holding, so a stall cannot park a DC offset
on the DAC.

`AUDIO_L/R` mux to the ring only while it is enabled, so a build carrying both
degrades to the fabric SPU rather than to silence, and a daemon that dies takes
the core back to its old behaviour instead of muting it.

**Verification.** `sim/run_audio_ring_tb.sh` runs the module against the real
`ddram.sv` with a randomised Avalon slave and framebuffer bursts competing for
the port. It checks frame-exact ordering across the ring wrap, exact output
cadence, that silence is the reset state, that starvation counts underruns and
then *resumes* rather than skipping, that the `rd_ptr` writeback matches what
was played, that LOOP wraps seamlessly, that repeated daemon restarts keep
streaming from a rebased `rd_ptr`, and that a rewound `wr_ptr` — a daemon that
crashed and restarted without clearing `ENABLE` — goes silent instead of
playing a ring of garbage at full volume. Eight injected faults are all caught:
swapped beat halves, dropped magic gate, uncounted underruns, LOOP consulting
`wr_ptr`, a frozen `rd_ptr`, a missing flush on re-enable, a missing `avail`
upper bound, and a starvation ramp that never reaches zero.

The bench also carries an always-on white-box invariant on the beat FIFO count.
The ENABLE flush and the FIFO pop both write `f_rd`, and if they ever collided
the count would wrap, `f_full` would stick high and fetching would stop for
good. As written they cannot collide — only one `ddram` op is in flight at a
time, so a push and the *disabling* poll never share a cycle, no fetch is
issued while disabled, and the pop therefore always parks `cur_have` at 1 long
before the next ENABLE edge. The DUT gates the pop on `enable` anyway, to make
that a local invariant rather than a three-step argument. The window is one
cycle wide, so no randomised restart soak reliably reaches it: **a passing
restart phase is not evidence the gate is present** — the invariant is what
guards it.

**Hardware exit test.** `tools/audio-tone.sh on` generates a ring image
(`tools/mkaudioring.py`), `dd`s it to HPS `0x3FFD0000` and sets `ENABLE|LOOP`.
The tone plays with no daemon and no ARM toolchain in the picture. Left and
right carry different frequencies on purpose: a mono tone cannot tell you the
channels arrived in the right order. `tools/audio-tone.sh status` reports
whether `rd_ptr` is advancing and whether anything underran.

## What is not built

Everything above the transport:

1. **Register file + write capture.** Keep the `0x04000400-0x51F` claim and
   readback in RTL; push every write, tick-timestamped, into a DDR3 command ring.
   The ARM7 address claim is not optional decoration — with nothing claiming
   `0x400-0x5FF` the first sound-register access never completes and the CPU
   hangs (see the `gnosound` branch in `rtl/nds_top.vhd`).
2. **Sample pager.** Daemon posts a descriptor list, FPGA reads main RAM through
   the existing ARM7-membus guest port and lands the words in a DDR3 staging
   buffer. Reuses `snd_bus_req/snd_bus_ok/snd_bus_own` — same arbitration, same
   ARM7 cost profile as today.
3. **Busy writeback.** Daemon posts a 16-bit finished mask; RTL drives
   `SOUNDxCNT` bit 31 readback from it.
4. **The daemon.** melonDS `SPU.cpp` logic over the captured register stream,
   mixing into the ring. Launched from `/media/fat/linux/user-startup.sh` via
   the `/tmp/CORENAME` inotify convention (`NDS_3D_HPS_BRIEF.md`). There is no
   HPS daemon in this tree yet — this is the first, and it is the same
   infrastructure the 3D plan needs.
5. **Removing `nds_sound`.** Only after 1–4 are proved against it, since it is
   the reference the daemon gets judged against.

The capture units (`SNDCAP`) are registers-only in `nds_sound` today, so moving
to the ARM is not a regression there and makes actually implementing them easy.
NDS has no sound-FIFO DMA — the SPU reads memory directly — so there is no
DMA-trigger coupling to preserve.
