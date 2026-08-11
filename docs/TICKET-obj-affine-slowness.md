# TICKET — affine OBJ is ~4x more VRAM traffic than it needs, serialized

Opened 2026-08-06 from play-testing Kirby: Squeak Squad on hardware
(`NDS_audio_20260806`). Symptoms reported by the owner, in their words:

- the bottom screen with the bubbles on the title/menu "lags the top screen much
  harder", *despite* the top screen carrying lots of OAM
- the intro stampede of Squeak Squad mice "lags proportional to some limit on OAM"
- some items that should become bubbles render as a **solid colour square**
- the overworld background is **blank white**

These are not one bug. This ticket covers the first two, which are the same
cause. The other two are separate and are recorded at the bottom.

## Cause 1 — affine sprites have no fetched-word reuse

`rtl/nds_drawer_obj.vhd` asserts `VRAM_Drawer_req` in exactly two places:

- **non-affine** (~line 646) is guarded by a reuse compare:
  ```vhdl
  elsif (pixeladdr_calc / 2 = pixeladdr_x(pixeladdr_x'left downto 1) and firstpix = '0') then
     -- same halfword as the last access: reuse the fetched word
  ```
  One fetch per halfword = **4 pixels at 4bpp**.
- **affine** (`AFF_SUM`, ~line 676) asserts it **unconditionally**, and the
  affine branch jumps straight to `AFF_SUM` without ever reaching that compare.
  **One VRAM round trip per pixel.**

So a rotated/scaled sprite costs ~4x the requests of an identical unrotated one.
This is what makes it look like "engine B is slow": it is not. The A/B bench
shows VRAM service is near-symmetric (`busy/line A=1372 B=1379`). It is
affine-vs-non-affine, not top-vs-bottom. Bubbles that scale and a stampeding
crowd are affine; a HUD full of static OAM is not.

## Cause 2 — three of the four drawers never got the pipelined protocol

| drawer | VRAM handshake |
|---|---|
| `nds_drawer_text` | `req` / **`accept`** / `done` |
| `nds_drawer_affine` | `req` / `done` |
| `nds_drawer_extended` | `req` / `done` |
<!-- Historical: those two entities have since been pipelined AND merged into
     rtl/nds_drawer_affext.vhd, which speaks req/accept/done. -->

| `nds_drawer_obj` | `req` / `done` |

The BG arbiter in `nds_gpu2d.vhd` supports `OS_DEPTH` ops in flight, but a
`done`-only drawer must issue one request and wait for it. So affine/extended/OBJ
never overlap requests — each of those 4x requests *also* costs a full serialized
round trip. The two multiply.

This is why neither prior win helped these scenes: the text drawer rework
(3119 -> 947 cyc/line) and the vrsrv pipelining (2067 -> 1379 steady-state) both
landed entirely on paths these three drawers do not use.

## Why this is not an overclocking problem

`maxpixeltime` lets the OBJ engine burn **6400–8191 clk cycles** per line
against a whole-line budget of **2130** (`bg/render=1050 obj/render=393` sums to
~1443 of 2130). Real NDS truncates sprites to fit the line — they vanish. This
core overruns and stretches the frame instead, which is the "lag proportional to
OAM" being seen.

Raising the SDRAM clock 100 -> 134 MHz is 1.33x bandwidth against a 4x
request-count problem plus serialization, and it cannot help sprites whose tiles
live in VRAM banks E–I, which are already on-chip BRAM. The measured lever sizes
in this codebase are all access-pattern changes at unchanged clock.

## Proposed order

1. Give the affine path the same halfword reuse the non-affine path has.
2. Re-measure with the drawer equivalence bench (the mosaic-coverage lesson:
   frame benches do not catch drawer regressions).
3. Only then decide whether `maxpixeltime` should enforce the real NDS budget so
   overload degrades like hardware (sprites drop) instead of stuttering.

## Related but SEPARATE — do not conflate

- **Solid colour square.** Unrooted. Confirmed *not* caused by the OBJ data
  capture (the drawer does latch on the done pulse, `nds_drawer_obj.vhd:829`).
  The owner reports these squares never rotate or scale, which does not by
  itself exclude the affine path — the square *is* the broken output. Leading
  candidate is the OBJ **extended palette**, since that would explain "others
  were fine" (standard-palette sprites unaffected). Note `objep_shadow` is a
  properly inferred 2048x32 M10K (0 ALUTs), refilled once per vblank from a
  zeroed array with no valid gating reads during the refill; the refill is
  10,240 sequential VRAM round trips against ~151,000 cycles of vblank, so it
  *should* normally complete. **Next measurement: is the square's colour one of
  the bubble's own palette entries (address collapsed) or unrelated (lookup
  wrong)?**
- **Blank white overworld BG.** Probably not a bug. Two stubs produce exactly
  this: `bgtype <= (0,0,0,0)` for modes 6/7 ("everything off for now"), and the
  3D-as-BG0 stub which renders nothing on engine A. If that background is drawn
  through the 3D engine, this is a missing feature, not a regression. `dbg_bgmode`
  exists in `nds_gpu2d` but is not wired above it, so the mode cannot be read on
  hardware today — check DISPCNT in melonDS on that screen instead.
- **HP bar missing exactly one tile.** Plausibly `maxpixeltime` truncation
  dropping the last objects in OAM order, which would be deterministic and would
  only appear in scenes busy enough to hit the cap. Unmeasured.

## Sim caveat that applies to all of the above

`nds_drawer_obj.vhd` is the only drawer containing `synthesis translate_off`, and
it wraps the affine address computation's bounds guard (lines ~568 and ~599).
Simulation runs that path guarded; hardware runs it unguarded. Out-of-bounds
pixels are skipped from drawing either way, so this is not obviously a bug — but
it does mean **no sim in this tree reproduces the affine OBJ path as built.**
