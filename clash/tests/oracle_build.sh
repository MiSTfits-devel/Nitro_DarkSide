# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Sarah Truffle
#
# Sourced by the textured/translucent gates: builds melonDS oracle targets in
# one CMake tree keyed by this checkout's path, so worktrees never share a
# CMake cache, and a rerun after an interrupted build just resumes it.
#
# Expects $repo; sets $oracle_build. Usage: build_oracle TARGET...

melonds=${MELONDS_DIR:-$repo/../NDS4MiSTer/third_party/melonDS}
oracle_key=$(printf '%s' "$repo" | cksum | cut -d' ' -f1)
oracle_build=${TMPDIR:-/tmp}/nds-gpu3d-oracle-$oracle_key

build_oracle() {
  mkdir -p "$oracle_build"
  cmake -S "$repo/tools/gx3d_oracle" -B "$oracle_build" \
      -DMELONDS_DIR="$melonds" >/dev/null
  for target in "$@"; do
    cmake --build "$oracle_build" --target "$target" >/dev/null
  done
}
