#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Build a DDR3 audio-ring image for rtl/nds_audio_ddr3.sv.

The image is written to HPS physical 0x3FFD0000 with dd and then played by the
FPGA in LOOP mode, which ignores wr_ptr and walks the ring forever. That makes
milestone 0 - "the DDR3 audio pipe works end to end" - testable with no daemon,
no ARM toolchain and no cross-compiler: generate here, copy, dd, devmem.

The control block is deliberately left ZEROED in the image. dd writes the region
front to back, so an image carrying an already-enabled control word would switch
the FPGA on while the ring behind it was still half old garbage. tools/
audio-tone.sh writes the control word afterwards, with devmem, as a separate
step - see the ordering note there.

Left and right get DIFFERENT frequencies by default. A mono tone cannot tell you
that the channels arrived in the right order, and {left, right} packing inside
the 64-bit beat is exactly the kind of thing that is easy to get backwards and
impossible to hear.
"""

import argparse
import struct
import sys

CLK_SYS     = 33513982      # NDS system clock, Hz (rtl/pll, docs/MEMORY_MAP.md)
FRAME_DIV   = 1024          # nds_audio_ddr3 FRAME_DIV
RATE        = CLK_SYS / FRAME_DIV        # 32728.5 Hz
RING_FRAMES = 8192          # nds_audio_ddr3 RING_LOG2 = 13
RING_OFF    = 0x100         # ring start, bytes from the region base
IMAGE_LEN   = 0x9000        # page-aligned length covering control + ring


def snap(freq):
    """Nearest frequency that fits a whole number of periods in the ring.

    A loop is seamless only if the waveform closes on itself; anything else
    clicks once per ring at ~4 Hz, which sounds like a fault in the transport
    rather than in the test signal.
    """
    periods = max(1, round(freq * RING_FRAMES / RATE))
    return periods, periods * RATE / RING_FRAMES


def sine_ring(periods, amp):
    import math
    return [int(round(amp * math.sin(2 * math.pi * periods * n / RING_FRAMES)))
            for n in range(RING_FRAMES)]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out", help="output image file")
    ap.add_argument("--left", type=float, default=440.0, help="left tone Hz (default 440)")
    ap.add_argument("--right", type=float, default=660.0, help="right tone Hz (default 660)")
    ap.add_argument("--mono", action="store_true", help="use the left tone on both channels")
    ap.add_argument("--amp", type=float, default=0.2,
                    help="amplitude as a fraction of full scale (default 0.2)")
    args = ap.parse_args()

    if not 0.0 < args.amp <= 1.0:
        sys.exit("--amp must be in (0, 1]")

    amp = args.amp * 32767
    lp, lf = snap(args.left)
    rp, rf = snap(args.left if args.mono else args.right)

    left = sine_ring(lp, amp)
    right = sine_ring(rp, amp)

    img = bytearray(IMAGE_LEN)          # control block stays zero: see the docstring
    for n in range(RING_FRAMES):
        struct.pack_into("<hh", img, RING_OFF + 4 * n, left[n], right[n])

    with open(args.out, "wb") as f:
        f.write(img)

    print(f"{args.out}: {IMAGE_LEN} bytes, ring {RING_FRAMES} frames @ {RATE:.1f} Hz")
    print(f"  left  {lf:8.2f} Hz ({lp} periods, exact loop)")
    print(f"  right {rf:8.2f} Hz ({rp} periods, exact loop)")
    print(f"  amplitude {amp:.0f} / 32767")

    # Two readback points for the staging script to check the copy actually
    # landed. They are chosen by magnitude rather than fixed, because frame 0 of
    # a sine is 0 and a zero word verifies nothing against stale DDR3 - it
    # matches whatever was already there. Emitted as byte offsets from the
    # region base, so the shell can hand them straight to devmem.
    peaks = sorted(range(RING_FRAMES),
                   key=lambda n: -(abs(left[n]) + abs(right[n])))
    for n in (peaks[0], peaks[len(peaks) // 4]):
        word = struct.unpack_from("<I", img, RING_OFF + 4 * n)[0]
        print(f"VERIFY 0x{RING_OFF + 4 * n:x} {word:08x}")


if __name__ == "__main__":
    main()
