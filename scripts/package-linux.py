#!/usr/bin/env python3
"""Audit and split an installed Qt SDK before publishing it."""

import argparse
import os
from pathlib import Path
import re
import subprocess


def run(*args):
    return subprocess.check_output(args, universal_newlines=True)


def versions(output):
    needed = output.partition("Version needs section")[2]
    return set(re.findall(r"Name:\s+(\S+)", needed))


def audit(path, args):
    header = run(args.readelf, "-h", str(path))
    if not re.search(r"Machine:\s+" + re.escape(args.machine) + r"\s*$", header, re.M):
        raise ValueError("{}: unexpected ELF architecture".format(path))
    if not re.search(r"Data:.*little endian", header):
        raise ValueError("{}: unexpected ELF byte order".format(path))
    for name in versions(run(args.readelf, "-V", str(path))):
        if not name.startswith("GLIBC_"):
            continue
        match = re.fullmatch(r"GLIBC_([0-9]+(?:\.[0-9]+)+)", name)
        if not match or tuple(map(int, match[1].split("."))) > args.limit:
            raise ValueError("{}: {} exceeds glibc baseline".format(path, name))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sdk", type=Path)
    parser.add_argument("symbols", type=Path)
    parser.add_argument("--machine", required=True)
    parser.add_argument("--glibc", required=True)
    parser.add_argument("--readelf", default="readelf")
    parser.add_argument("--objcopy", default="objcopy")
    parser.add_argument("--strip", default="strip")
    args = parser.parse_args()
    args.limit = tuple(map(int, args.glibc.split(".")))
    os.environ["LC_ALL"] = "C"
    files = []
    for path in sorted(args.sdk.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            if stream.read(4) != b"\x7fELF":
                continue
        audit(path, args)
        files.append(path)
    if not files:
        raise ValueError("No ELF files in {}".format(args.sdk))
    args.symbols.mkdir(parents=True, exist_ok=False)
    for path in files:
        debug = args.symbols / path.relative_to(args.sdk)
        debug = debug.with_name(debug.name + ".debug")
        sections = run(args.readelf, "-SW", str(path))
        if re.search(r"\.(?:z?debug_info|gnu_debugdata)\s", sections):
            debug.parent.mkdir(parents=True, exist_ok=True)
            run(args.objcopy, "--only-keep-debug", str(path), str(debug))
        run(args.strip, "--strip-unneeded", str(path))
        if debug.is_file():
            run(args.objcopy, "--add-gnu-debuglink=" + str(debug.resolve()), str(path))
        if re.search(r"\.(?:z?debug_info|gnu_debugdata)\s", run(args.readelf, "-SW", str(path))):
            raise ValueError("{}: debug information survived strip".format(path))
    print("Audited and stripped {} ELF files (glibc <= {})".format(len(files), args.glibc))


if __name__ == "__main__":
    main()
