# SPDX-License-Identifier: GPL-3.0-only
"""Public companion entry point. Guard is a supervisor-internal recovery mode."""
import argparse
import os
from pathlib import Path
import sys


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--rom')
    parser.add_argument('--seconds', type=int, default=0)
    parser.add_argument('--direct-video-target', choices=('retrotink', 'crt'))
    parser.add_argument('--validate-only', action='store_true')
    args = parser.parse_args()
    if not 0 <= args.seconds <= 86400:
        parser.error('Invalid test duration')
    if args.validate_only:
        print('NDSHaskell_package_valid')
        return
    command = [sys.executable, str(Path(__file__).with_name('supervisor.py')), '--seconds', str(args.seconds)]
    if args.rom:
        command.extend(['--rom', args.rom])
    if args.direct_video_target:
        command.extend(['--direct-video-target', args.direct_video_target])
    os.execv(sys.executable, command)


if __name__ == '__main__':
    main()
