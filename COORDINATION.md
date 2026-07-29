# Agent coordination log

Originally a shared log for several agents working this repo in parallel (file
claims, pod assignments, a running changelog). It grew to ~2,300 lines of mostly
superseded narrative and was cut back on 2026-07-28.

**`git log` is the changelog.** Commit messages in this repo carry the reasoning,
the measurements and the retractions — prefer them over any prose kept here.
**`HANDOFF.md` is the current state of the project.**

---

## If more than one agent works this repo again

Claim files here before editing them, with a date, what you are doing, and why.
That was the one part of this document that earned its keep: three separate
sessions collided on `rtl/nds_top.vhd` and `NDS.sv` without it.

Currently: **no active claims, single agent.**

## Pods

`build/remote-sim.sh` and `build/remote-build.sh` take `POD=<name>` so runs do not
collide; artifacts land in `simout/<pod>/` and `ARTIFACT_DIR` respectively. Check
`kubectl describe node slacker` before fanning out — it is a single node and each
sim pod requests 1 CPU, so three parallel `POD=` names can schedule **zero** pods.

## Standing warnings that outlived their entries

- **Do not treat this file or `HANDOFF.md` as ground truth.** Their measured
  artifacts are usually sound; their rules and thresholds have repeatedly turned out
  to be invented. Several load-bearing claims were disproved on 2026-07-28 alone:
  the 2.32 ARM9:ARM7 ratio requirement, "there is no timing-clean fallback", "a
  handshake does not survive 1:1", the `IO9 path` dropped-request counter, and
  "judge the screen only after ~600 frames".
- **`remote-build.sh` snapshots the tree at launch.** Edits made during a 25-minute
  build are silently not in the RBF.
- **Audit drivers after any domain split.** `nvc` sees neither multiple drivers nor
  undriven signals; Quartus catches them only after a full fit.
- **One change per build.** Bundling fitter knobs with RTL edits cost a build and
  1.6 ns of confusion.

## Where the detail went

- Fitter/area war (July 18-19), BRAM conversions, the async-read-array disease and
  its recipes: `FITTING.md`, RESOLUTION and MEASURED RESULTS sections.
- Trace diffing against melonDS: `docs/TRACE_DIFF.md`.
- Everything else: `git log`.
