# SPDX-License-Identifier: GPL-3.0-only
"""Observe the v1.0.1 H3D1/H3P1 attach, without becoming a renderer or SPI owner."""
from contextlib import contextmanager
import mmap
import os
import struct
import time


@contextmanager
def control_page():
    # Only the documented first H3D control page. Never write the request or ACK.
    fd = os.open('/dev/mem', os.O_RDONLY | os.O_SYNC)
    try:
        with mmap.mmap(fd, 4096, flags=mmap.MAP_SHARED, prot=mmap.PROT_READ,
                       offset=0x3fc00000) as page:
            yield page
    finally:
        os.close(fd)


def prior_token():
    with control_page() as page:
        return struct.unpack_from('<I', page, 0x70)[0]


def acknowledged(page, old):
    # Hybrid3DAbi.h / Hybrid3DSessionPolicy.h / nds_h3d_control_init.sv.
    # Ignore changing telemetry and frame counters. Require the same current
    # session around both immutable policy reads; acknowledge no data here.
    magic, version_size, session, reserved = struct.unpack_from('<4I', page)
    if (magic, version_size, reserved) != (0x31443348, 0x00800001, 0) or session in (0, old):
        return None
    if struct.unpack_from('<4I', page, 0x20) != (0, 0, 2, session):
        return None
    if struct.unpack_from('<4I', page, 0x70) != (session, 0, session, 0):
        return None
    policy = struct.unpack_from('<8I', page, 0x300)
    # MatchedDisplay | EngineBOptional, with or without EngineBPixels.
    if policy != (0x31503348, 0x00200001, session, policy[3], session, 0, session, 0) or policy[3] not in (6, 7):
        return None
    if struct.unpack_from('<8I', page, 0x340) != policy:
        return None
    if struct.unpack_from('<3I', page) != (magic, version_size, session):
        return None
    return session


def wait_for_renderer(old):
    deadline = time.monotonic() + 15
    with control_page() as page:
        while time.monotonic() < deadline:
            session = acknowledged(page, old)
            if session is not None:
                return session
            time.sleep(0.01)
    raise RuntimeError('No fresh NDSHaskell renderer/policy acknowledgment; refusing SPI takeover')
