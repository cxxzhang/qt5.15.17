#!/usr/bin/env python3
"""Merge and verify every Mach-O binary and static library in two macOS SDKs."""

import argparse
from pathlib import Path
import shutil
import subprocess
import sys


MACHO = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
         b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}


def binary_kind(path):
    with path.open("rb") as stream:
        data = stream.read(8)
    if data[:4] in MACHO:
        return "macho"
    if data == b"!<arch>\n":
        return "archive"
    return None


def architectures(path):
    return set(subprocess.check_output(["lipo", "-archs", str(path)], text=True).split())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("x64", type=Path)
    parser.add_argument("arm64", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError("Move the previous universal SDK before merging: " + str(args.output))
    binaries = {}
    for tree in (args.x64, args.arm64):
        for path in tree.rglob("*"):
            if path.is_file() and not path.is_symlink():
                kind = binary_kind(path)
                if kind:
                    binaries[path.relative_to(tree)] = kind
    if not binaries:
        raise ValueError("No macOS binaries or static libraries to merge")
    shutil.copytree(args.arm64, args.output, symlinks=True)
    for relative, kind in sorted(binaries.items()):
        x64, arm, output = args.x64 / relative, args.arm64 / relative, args.output / relative
        if not x64.is_file() or not arm.is_file():
            raise ValueError("Missing architecture counterpart: " + str(relative))
        if architectures(x64) != {"x86_64"} or architectures(arm) != {"arm64"}:
            raise ValueError("Unexpected input architectures: " + str(relative))
        subprocess.check_call(["lipo", "-create", str(x64), str(arm), "-output", str(output)])
        if architectures(output) != {"x86_64", "arm64"}:
            raise ValueError("Incomplete universal binary: " + str(relative))
        if kind == "macho":
            subprocess.check_call(["codesign", "--force", "--sign", "-", str(output)])
    subprocess.check_call([sys.executable, str(Path(__file__).with_name("prepare-macos-bundles.py")),
                           str(args.output), "--verify-only", "--resign"])
    print("Merged and verified {} universal binaries/static libraries".format(len(binaries)))


if __name__ == "__main__":
    main()
