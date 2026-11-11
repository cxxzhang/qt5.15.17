#!/usr/bin/env python3
"""Resolve each packaged ELF's dependencies with its real baseline loader."""

import argparse
from pathlib import Path
import posixpath
import re
import subprocess
from linux_cross_runtime import TargetRoot, clean_environment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sdk", type=Path)
    parser.add_argument("--sysroot", type=Path, required=True)
    parser.add_argument("--qemu", type=Path, required=True)
    parser.add_argument("--loader", required=True)
    parser.add_argument("--readelf", default="readelf")
    args = parser.parse_args()
    args.sdk = args.sdk.resolve()
    target = TargetRoot(args.sysroot, args.qemu, args.sdk)
    staged = target.stage_sdk(args.sdk)
    env = clean_environment()
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
            command = ["ldd", "-r", "-v", str(path)]
            runtime = args.sdk / "host/lib"
        else:
            # Pass trace/binding flags to the guest, not the host chroot
            # executable. This is ldd -r's relocation check in the real root.
            command = target.command("-E", "LD_TRACE_LOADED_OBJECTS=1", "-E", "LD_WARN=1",
                                     "-E", "LD_BIND_NOW=1", args.loader,
                                     target.guest_path(staged / path.relative_to(args.sdk)))
            runtime = Path(target.guest_path(staged / "lib"))
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                universal_newlines=True, env=env)
        if result.returncode or "not found" in result.stdout or "undefined symbol:" in result.stdout:
            raise ValueError("{}: unresolved runtime dependency\n{}".format(path, result.stdout))
        for name in ("libstdc++.so.6", "libgcc_s.so.1"):
            match = re.search(r"^\s*" + re.escape(name) + r"\s+=>\s+(\S+)", result.stdout, re.M)
            resolved = Path(match[1]).resolve() if match and host else Path(posixpath.normpath(match[1])) if match else None
            expected = (runtime / name).resolve() if host else runtime / name
            if match and resolved != expected:
                raise ValueError("{}: {} resolved outside the SDK: {}".format(path, name, match[1]))
        count += 1
    if not count:
        raise ValueError("No dynamic ELF files in {}".format(args.sdk))
    print("Baseline loaders resolved dependencies for {} ELF files".format(count))


if __name__ == "__main__":
    main()
