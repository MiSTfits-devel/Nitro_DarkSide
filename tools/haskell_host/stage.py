#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Prepare the pinned host sources, or package a separately accepted NDSHaskell fit."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

HERE = Path(__file__).resolve().parent
SOURCE = '0991315ee3341d7b4eaf6d9283324425c6e4cc567c206072345f79fafdc1b9b7'
PREFIX = 'NDS4MiSTer-1.0.1/'
DONOR_MANIFEST = '4b72e099e2e75d6fa3552e53df9700984b97890c5320083ed07053c29ca68373'
DONOR_FRONTEND = '42c0a1a4b392e6a55326b779814603fbd3f6597e5ca93aeb68b412a227aa8e94'
STOCK_RBF = '1f7809747e255074be986204ee27aa8a456af4d0397f70f5d5450786a50dae65'


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(262144), b''):
            h.update(chunk)
    return h.hexdigest()


def prepare(archive, work):
    if digest(archive) != SOURCE:
        raise ValueError('Expected the pinned public v1.0.1 source tarball')
    with tarfile.open(archive, 'r:gz') as tar:
        for m in tar:
            if not m.name.startswith(PREFIX) or not m.isfile():
                continue
            name = Path(m.name[len(PREFIX):]); path = work / name
            if '..' in name.parts or name.is_absolute():
                raise ValueError('Invalid archive member')
            if not (str(name).startswith('tools/standalone_host/') or name == Path('src/common/GraphicsControl.h')):
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open('xb') as out, tar.extractfile(m) as src:
                shutil.copyfileobj(src, out)
    host = work / 'tools/standalone_host'
    subprocess.run(['patch', '-p1', '-i', str(HERE / 'v1.0.1.patch')], cwd=host, check=True)
    shutil.copyfile(HERE / 'flash_boot.h', host / 'flash_boot.h')
    return host


def package(src, args, out):
    # A digest from an independent fit/assembly record is required; do not
    # auto-enrol whatever file happened to arrive, especially a renamed donor.
    if args.rbf.name != 'NDSHaskell.rbf' or args.rbf.is_symlink() or not args.rbf.is_file():
        raise ValueError('Expected the assembled, separately named NDSHaskell.rbf')
    if args.rbf.stat().st_size == 0 or digest(args.rbf) != args.rbf_sha256 or args.rbf_sha256 == STOCK_RBF:
        raise ValueError('Input does not match the separately accepted Haskell RBF digest')
    scripts = out / 'Scripts'; kit = scripts / '.NDSHaskell'; kit.mkdir(parents=True)
    subprocess.run([args.cxx, '-std=c++17', '-O2', '-Wall', '-Wextra', '-Werror', '-static',
                    '-mcpu=cortex-a9', '-mfpu=neon', '-mfloat-abi=hard', str(src / 'host.cpp'),
                    '-o', str(kit / 'nds_standalone_host')], check=True)
    for name in ('Kickstart.sh', 'supervisor.py', 'video_target.py'):
        shutil.copyfile(src / name, kit / name)
    for name in ('renderer_gate.py', 'launch.py'):
        shutil.copyfile(HERE / name, kit / name)
    shutil.copyfile(args.rbf, kit / 'NDSHaskell.rbf')
    files = {p.name: digest(p) for p in sorted(kit.iterdir())}
    if files['NDSHaskell.rbf'] != args.rbf_sha256:
        raise ValueError('RBF changed during packaging')
    manifest = kit / 'manifest.json'
    manifest.write_text(json.dumps(dict(target='NDSHaskell', donor='v1.0.1', files=files), indent=2) + '\n')
    # The independent launcher pins BOTH manifests and every executable/data
    # file. The stock validator checks its own entire package; no overrides of
    # its manifest, normal launch script, core name, or ownership checks.
    runner = scripts / 'NDSHaskell.sh'
    checks = [f'{digest(manifest)}  manifest.json', *[f'{v}  {k}' for k, v in files.items()],
              f'{DONOR_MANIFEST}  ../.NDS/manifest.json', f'{DONOR_FRONTEND}  ../.NDS/auto_movies.py']
    runner.write_text('#!/bin/sh\nset -eu\ncd /media/fat/Scripts/.NDSHaskell\n'
                      "sha256sum -c - >/dev/null <<'HASHES'\n" + '\n'.join(checks) + '\nHASHES\n'
                      'python3 -I -B ../.NDS/auto_movies.py --validate-only\n'
                      'unset PYTHONOPTIMIZE PYTHONPATH PYTHONHOME H3D_LIFECYCLE_TEST_ROOT\n'
                      'export PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1\n'
                      'export NDS_FMV_AUTO=1 NDS_FMV_COLOR_FAST=1\n'
                      'export NDS_GUEST_PATCH_MANIFEST=/media/fat/Scripts/.NDS/fmv/guest_catalog.json\n'
                      'export NDS_GUEST_PATCH_SHA256=f25d282ac2af1f102865179041937fc50ee3f11c0c5970a9830a49383bd4cfd0\n'
                      'export NDS_GUEST_PATCH_IDS=@catalog NDS_GUEST_PATCH_FALLBACK_FMV=1\n'
                      'exec python3 ./launch.py "$@"\n')
    runner.chmod(0o755)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='codeload.github.com/SplashDev88/NDS4MiSTer/tar.gz/refs/tags/v1.0.1')
    parser.add_argument('out', type=Path, help='new local output directory (never the live SD)')
    sub = parser.add_subparsers(dest='mode', required=True)
    sub.add_parser('sources', help='prepare exact sources for host/marker tests; no package')
    p = sub.add_parser('package', help='compile matched host and emit additive Scripts/ (no installation)')
    p.add_argument('rbf', type=Path); p.add_argument('rbf_sha256'); p.add_argument('--cxx', default='arm-linux-gnueabihf-g++')
    a = parser.parse_args(); dest = a.out.resolve()
    if dest.exists() or not dest.parent.is_dir():
        parser.error('Output must be new with an existing parent')
    with tempfile.TemporaryDirectory(dir=dest.parent) as tmp:
        work = Path(tmp) / 'src'; host = prepare(a.source, work)
        if a.mode == 'sources':
            work.rename(dest)
        else:
            result = Path(tmp) / 'product'; package(host, a, result); result.rename(dest)


if __name__ == '__main__':
    main()
