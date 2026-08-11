-- SPDX-License-Identifier: GPL-2.0-or-later
--
-- Exhaustive equivalence check for the mosaic-Y counter rewrite in
-- nds_gpu2d.vhd.
--
-- What changed and why: `linecounter mod (size + 1)` needs a variable divisor,
-- so Quartus built a general divider for each of the two uses -
-- lpm_divide:Mod0 and Mod1, a MEASURED 37.7 + 35.6 ALMs per 2D engine and 146
-- across both. melonDS does the same job with an incrementing 4-bit counter
-- ("Y mosaic uses incrementing 4-bit counters", GPU2D.cpp
-- UpdateMosaicCounters), which is a counter and a subtract in logic.
--
-- The counter and the divider agree only while MOSAIC holds still, and they
-- are MEANT to disagree when it does not: melonDS re-latches BGMosaicYMax from
-- the register only when the counter wraps, so a mid-frame MOSAIC write lands
-- at the next block boundary rather than on the next line, and the counter
-- keeps its phase from the frame start instead of re-snapping against absolute
-- linecounter. That divergence is the fix, not a regression, so it is
-- deliberately NOT checked here.
--
-- What IS checked, because it must not regress, is that for a CONSTANT mosaic
-- size the counter reproduces the divider exactly - same block boundaries,
-- same phase - for every line of a frame and every one of the 16 sizes, on
-- both the BG and the OBJ path.
--
-- Phase being right is the whole risk of the rewrite, and it rests on where
-- the per-line tick sits (nds_gpu_timing.vhd):
--
--   BG  - refpoint_update fires on lines 1..191 ONLY, and lands before
--         drawline in the same line. So line 0 uses the vblank-cleared
--         counter and line L uses it after exactly L advances.
--   OBJ - drawObj fires once per line with linecounter_obj already set to
--         melonDS's "line + 1", and the base register updates on that edge,
--         so it is stable for the line the pulse starts. The counter is
--         preloaded to the size at vblank so the frame's first pulse wraps and
--         latches base = line 0.
--
-- Self-contained: no RTL dependencies, runs in seconds. Both the reference and
-- the implementation are modelled here, so a phase change in nds_gpu2d.vhd
-- will NOT be caught by this bench on its own - it pins the algebra. The
-- wiring is covered by run_top_frame / run_gpu2d / run_gpu_bg.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity tb_mosaic_equiv is
end entity;

architecture arch of tb_mosaic_equiv is

   constant LAST_LINE : integer := 191;

begin

   process
      variable mos_bgy     : integer range 0 to 15;
      variable mos_bgy_max : integer range 0 to 15;
      variable mos_bgbase  : integer range 0 to 191;
      variable mos_objcnt  : integer range 0 to 15;
      variable mos_objbase : integer range 0 to 191;
      variable ref_bg      : integer;
      variable got_bg      : integer;
      variable ref_obj     : integer;
      variable got_obj     : integer;
      variable k           : integer;
      variable checks      : integer := 0;
      variable bad         : integer := 0;
   begin

      for size in 0 to 15 loop

         k := size + 1;

         -- ---------------- BG path ----------------
         -- vblank_trigger
         mos_bgy     := 0;
         mos_bgy_max := size;
         mos_bgbase  := 0;

         for line in 0 to LAST_LINE loop

            -- refpoint_update: lines 1..191 only, and it lands BEFORE drawline
            -- sets linecounter <= line, so linecounter still reads line-1 at
            -- this tick and the base latches linecounter + 1. Modelling that
            -- lag is the point: driving ypos_mosaic_bg as
            -- `linecounter - mos_bgy` instead went to -1 on the 0 -> 1 tick.
            if (line > 0) then
               if (mos_bgy >= mos_bgy_max) then
                  mos_bgy     := 0;
                  mos_bgy_max := size;
                  mos_bgbase  := (line - 1) + 1;
               else
                  mos_bgy := mos_bgy + 1;
               end if;
            end if;

            got_bg := mos_bgbase;
            ref_bg := line - (line mod k);

            checks := checks + 1;
            if (got_bg /= ref_bg) then
               bad := bad + 1;
               report "BG  mismatch size=" & integer'image(size) &
                      " line=" & integer'image(line) &
                      " got=" & integer'image(got_bg) &
                      " ref=" & integer'image(ref_bg)
                  severity error;
            end if;

         end loop;

         -- ---------------- OBJ path ----------------
         -- vblank_trigger preloads the counter so the first pulse wraps
         mos_objcnt  := size;
         mos_objbase := 0;

         -- drawObj pulses carry linecounter_obj, which runs 0, 1, 2, ...
         for lobj in 0 to LAST_LINE loop

            if (mos_objcnt >= size) then
               mos_objcnt  := 0;
               mos_objbase := lobj;
            else
               mos_objcnt := mos_objcnt + 1;
            end if;

            got_obj := mos_objbase;
            ref_obj := lobj - (lobj mod k);

            checks := checks + 1;
            if (got_obj /= ref_obj) then
               bad := bad + 1;
               report "OBJ mismatch size=" & integer'image(size) &
                      " lobj=" & integer'image(lobj) &
                      " got=" & integer'image(got_obj) &
                      " ref=" & integer'image(ref_obj)
                  severity error;
            end if;

         end loop;

      end loop;

      if (bad = 0) then
         report "tb_mosaic_equiv: PASS  " & integer'image(checks) &
                " comparisons, 0 mismatches" severity note;
      else
         report "tb_mosaic_equiv: FAIL  " & integer'image(bad) & " of " &
                integer'image(checks) & " comparisons mismatched"
            severity failure;
      end if;

      wait;
   end process;

end architecture;
