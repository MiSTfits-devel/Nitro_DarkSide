# Project provenance

This repository joins the complete published histories of two related Nintendo
DS-on-MiSTer projects:

- `Nitro_DarkSide`, developed by Heni. Her work includes the original ARM9 CPU,
  FPGA 2D engines, memory/VRAM fabric, DMA, system integration, and the
  supporting tests and documentation.
- `NDS4MiSTer`, maintained by SplashDev88, including the later public release
  line and its substantial ARM-assisted 3D renderer, integration, performance,
  packaging, and release work.

The working tree follows the NDS4MiSTer layout and release line. Git history
remains authoritative for individual changes and authorship; no graft
reassigns copyright or authorship from either parent.

## Grafts

- `f854add` joins Nitro_DarkSide (`753708a`) to NDS4MiSTer's public tip of the
  time, `306abb8` (v0.3.0-beta.6).
- `af82e7e` is a squashed import of SplashDev88's uncommitted 2026-09-02 HPS
  Engine B development tree, joined by `f4697fc`. Its bundled `SHA256SUMS`
  still described beta.6 and did not authenticate the 54 files it modified. It
  was never part of NDS4MiSTer's history and no longer contributes to the tree;
  it stays reachable as a record of what was supplied.
- `fda23e8` grafts NDS4MiSTer's real history through v0.9.0-rc.13 (`8cbbc35`)
  and supersedes that snapshot: the same work now arrives as the commits that
  shipped it, with their original authors, dates and hashes. `1e1a2a7` and
  `bc2e83a` add NDS4MiSTer `main` (`c52055c`) and `feat/a9-raster-bench`
  (`fb5921a`), which carry the offline A9 raster bench on top of rc12. Each
  merge message records how its conflicts were resolved.

`SHA256SUMS` and `SOURCE_PACKAGE.txt` are NDS4MiSTer's published release
metadata. They do not authenticate this repository's tree.

## Licensing

The combined work is distributed under GNU GPL version 3. The root
`LICENSE.txt` holds the complete GPLv3 text from the NDS4MiSTer parent, and
NDS4MiSTer's audit and release tooling reads it under that name. The earlier
root license files from both parents remain inspectable in Git history. The
write-combining kernel module in `kernel/nds_mem_wc` is GPL-2.0, and vendored
components retain the licenses and notices found in their own trees.
