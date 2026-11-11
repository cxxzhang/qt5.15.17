#!/usr/bin/env python3
"""Check that an SDK's separate symbol archive matches its GNU debug links."""

import argparse
from pathlib import Path, PurePosixPath
import struct
import tarfile
import zlib


def debug_link(path):
    with path.open("rb") as stream:
        header = stream.read(64)
        if not header.startswith(b"\x7fELF"):
            return None
        if len(header) != 64 or header[4:6] != b"\x02\x01":
            raise ValueError("Expected a 64-bit little-endian ELF: " + str(path))
        offset = struct.unpack_from("<Q", header, 40)[0]
        stride, count, strings = struct.unpack_from("<HHH", header, 58)
        if stride < 64:
            raise ValueError("Invalid ELF section table: " + str(path))

        def section(index):
            stream.seek(offset + index * stride)
            return struct.unpack("<IIQQQQIIQQ", stream.read(64))

        if count == 0:
            count = section(0)[5]
        if strings == 0xffff:
            strings = section(0)[6]
        names_section = section(strings)
        stream.seek(names_section[4])
        names = stream.read(names_section[5])
        for index in range(count):
            entry = section(index)
            name = names[entry[0]:].partition(b"\0")[0]
            if name != b".gnu_debuglink":
                continue
            stream.seek(entry[4])
            data = stream.read(entry[5])
            filename, delimiter, _ = data.partition(b"\0")
            checksum_offset = (len(filename) + 4) & ~3
            if not delimiter or len(data) != checksum_offset + 4:
                raise ValueError("Invalid GNU debug link: " + str(path))
            return filename.decode("utf-8"), struct.unpack_from("<I", data, checksum_offset)[0]
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sdk", type=Path)
    parser.add_argument("symbols", type=Path)
    args = parser.parse_args()
    links = {}
    for path in args.sdk.rglob("*"):
        if path.is_file() and not path.is_symlink():
            link = debug_link(path)
            if link:
                links[path.relative_to(args.sdk).as_posix()] = link
    verified = set()
    archives = 0
    with tarfile.open(str(args.symbols), "r|gz") as symbols:
        for member in symbols:
            if member.isdir():
                continue
            relative = PurePosixPath(member.name)
            if (relative.is_absolute() or ".." in relative.parts or not member.isfile()
                    or not relative.name.endswith(".debug")):
                raise ValueError("Unexpected symbol archive entry: " + member.name)
            name = relative.as_posix()[:-6]
            if name in verified:
                raise ValueError("Duplicate symbol archive entry: " + name)
            counterpart = args.sdk / name
            if counterpart.is_symlink() or not counterpart.is_file():
                raise ValueError("Symbol file has no SDK counterpart: " + member.name)
            with counterpart.open("rb") as stream:
                original = stream.read(8)
            source = symbols.extractfile(member)
            magic = source.read(8)
            elf = magic.startswith(b"\x7fELF") and magic[:7] == original[:7]
            archive = magic == original == b"!<arch>\n"
            if not (elf or archive):
                raise ValueError("Symbol file format differs from SDK: " + member.name)
            checksum = zlib.crc32(magic)
            for block in iter(lambda: source.read(1024 * 1024), b""):
                checksum = zlib.crc32(block, checksum)
            if archive:
                archives += 1
            elif links.get(name) != (relative.name, checksum):
                raise ValueError("GNU debug link filename/CRC mismatch: " + name)
            verified.add(name)
    if not verified:
        raise ValueError("Empty symbol archive")
    for name, link in links.items():
        if link[0] == PurePosixPath(name).name + ".debug" and name not in verified:
            raise ValueError("Generated debug link has no delivered symbol file: " + name)
    print("Verified {} ELF debug links and {} static-archive symbol files".format(
        len(verified) - archives, archives))


if __name__ == "__main__":
    main()
