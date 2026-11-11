#!/usr/bin/env python3
"""Resolve each packaged ELF's dependencies with its real baseline loader."""

import argparse
import os
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sdk", type=Path)
    parser.add_argument("--sysroot", type=Path, required=True)
    parser.add_argument("--qemu", type=Path, required=True)
    parser.add_argument("--loader", required=True)
    parser.add_argument("--readelf", default="readelf")
    args = parser.parse_args()
    env = dict(os.environ, LC_ALL="C")
    for key in ("LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT"):
        env.pop(key, None)
    count = 0
    for path in sorted(args.sdk.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            if stream.read(4) != b"\x7fELF":
                continue
        dynamic = subprocess.check_output([args.readelf, "-d", str(path)],
                                          universal_newlines=True, env=env)
        if "(NEEDED)" not in dynamic:
            continue
        host = path.relative_to(args.sdk).parts[0] == "host"
        if host:
            command = ["ldd", "-v", str(path)]
            runtime = args.sdk / "host/lib"
        else:
            command = [str(args.qemu), "-L", str(args.sysroot),
                       str(args.sysroot / args.loader.lstrip("/")), "--list", str(path)]
            runtime = args.sdk / "lib"
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                universal_newlines=True, env=env)
        if result.returncode or "not found" in result.stdout:
            raise ValueError("{}: unresolved runtime dependency\n{}".format(path, result.stdout))
        for name in ("libstdc++.so.6", "libgcc_s.so.1"):
            match = re.search(r"^\s*" + re.escape(name) + r"\s+=>\s+(\S+)", result.stdout, re.M)
            if match and Path(match[1]).resolve() != (runtime / name).resolve():
                raise ValueError("{}: {} resolved outside the SDK: {}".format(path, name, match[1]))
        count += 1
    if not count:
        raise ValueError("No dynamic ELF files in {}".format(args.sdk))
    print("Baseline loaders resolved dependencies for {} ELF files".format(count))


if __name__ == "__main__":
    main()
