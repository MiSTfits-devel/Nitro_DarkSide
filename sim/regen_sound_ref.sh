#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Regenerate sim/nds_sound_ref.vhd from rtl/nds_sound.vhd.
#
# ONLY run this to re-base the reference on a version that is already known
# good. Running it after a refactor compares the refactor against itself and
# the equivalence bench becomes a very convincing no-op.
set -eu
cd "$(dirname "$0")/.."

REV="$(git rev-parse --short HEAD)"
{
   echo "-- SPDX-License-Identifier: GPL-2.0-or-later"
   echo "-- VERBATIM COPY of rtl/nds_sound.vhd as of commit ${REV}, with only the entity"
   echo "-- and architecture names changed. Do not \"improve\" anything in here: its whole"
   echo "-- value is being the thing the refactor is compared against, so any edit that is"
   echo "-- not a mechanical rename destroys the reference."
   echo "--"
   echo "-- Same role as sim/nds_drawer_text_ref.vhd plays for the text drawer."
   echo "-- Regenerate with: sim/regen_sound_ref.sh"
   sed -e 's/^entity nds_sound is$/entity nds_sound_ref is/' \
       -e 's/^architecture arch of nds_sound is$/architecture arch of nds_sound_ref is/' \
       rtl/nds_sound.vhd
} > sim/nds_sound_ref.vhd

echo "regenerated sim/nds_sound_ref.vhd from ${REV}"
