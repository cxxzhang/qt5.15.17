#!/usr/bin/env python3
"""Preserve target page alignment when editing an ELF's runtime search path."""

from pathlib import Path
import struct
import subprocess
import sys


def load_segments(path):
    with Path(path).open('rb') as stream:
        header = stream.read(64)
        if header[:6] != b'\x7fELF\x02\x01':
            raise ValueError('{}: expected ELF64 little endian'.format(path))
        machine = struct.unpack_from('<H', header, 18)[0]
        offset = struct.unpack_from('<Q', header, 32)[0]
        size, count = struct.unpack_from('<HH', header, 54)
        if size < 56 or count == 0xffff:
            raise ValueError('{}: unsupported program header table'.format(path))
        segments = []
        for index in range(count):
            stream.seek(offset + index * size)
            fields = struct.unpack('<IIQQQQQQ', stream.read(56))
            if fields[0] == 1:  # PT_LOAD
                segments.append((fields[2], fields[3], fields[7]))
    return machine, segments


def audit(path):
    _, segments = load_segments(path)
    for offset, address, alignment in segments:
        if alignment > 1 and (alignment & (alignment - 1) or
                              (address - offset) % alignment):
            raise ValueError('{}: invalid PT_LOAD offset={:#x} vaddr={:#x} align={:#x}'.format(
                path, offset, address, alignment))


def set_rpath(path, rpath):
    machine, segments = load_segments(path)
    # Preserve the input's target page alignment rather than patchelf's host
    # default. A larger invented page size cannot realign existing segments.
    page_size = max([4096] + [segment[2] for segment in segments])
    subprocess.check_call(['patchelf', '--page-size', str(page_size),
                           '--set-rpath', rpath, str(path)])
    audit(path)
    _, segments = load_segments(path)
    if any((address - offset) % page_size for offset, address, _ in segments):
        raise ValueError('{}: PT_LOAD does not support {} byte pages'.format(path, page_size))


if __name__ == '__main__':
    set_rpath(sys.argv[1], sys.argv[2])
