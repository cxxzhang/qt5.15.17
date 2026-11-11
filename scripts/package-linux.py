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
    relative = path.relative_to(args.sdk)
    host_tool = args.host_machine and relative.parts[0] == "host"
    machine = args.host_machine if host_tool else args.machine
    limit = args.host_limit if host_tool else args.limit
    if not re.search(r"Machine:\s+" + re.escape(machine) + r"\s*$", header, re.M):
        raise ValueError("{}: unexpected ELF architecture".format(path))
    if not re.search(r"Data:.*little endian", header) or not re.search(r"Class:\s+ELF64", header):
        raise ValueError("{}: expected a 64-bit little-endian ELF".format(path))
    if not host_tool and args.interpreter:
        program = run(args.readelf, "-l", str(path))
        loader = re.search(r"Requesting program interpreter: ([^\]]+)", program)
        if loader and loader[1] != args.interpreter:
            raise ValueError("{}: unexpected ELF interpreter {}".format(path, loader[1]))
    for name in versions(run(args.readelf, "-V", str(path))):
        if not name.startswith("GLIBC_"):
            continue
        match = re.fullmatch(r"GLIBC_([0-9]+(?:\.[0-9]+)+)", name)
        if not match or tuple(map(int, match[1].split("."))) > limit:
            raise ValueError("{}: {} exceeds glibc baseline".format(path, name))
    return bool(re.search(r"Type:\s+REL\b", header))


def audit_native_dependencies(path, args):
    dynamic = run(args.readelf, "-d", str(path))
    if "(NEEDED)" not in dynamic:
        return
    env = dict(os.environ)
    for key in ("LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT"):
        env.pop(key, None)
    result = subprocess.run(["ldd", "-v", str(path)], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, universal_newlines=True, env=env)
    if result.returncode or "not found" in result.stdout:
        raise ValueError("{}: unresolved runtime dependency\n{}".format(path, result.stdout))
    for runtime in ("libstdc++.so.6", "libgcc_s.so.1"):
        match = re.search(r"^\s*" + re.escape(runtime) + r"\s+=>\s+(\S+)", result.stdout, re.M)
        if match and Path(match[1]).resolve() != (args.sdk / "lib" / runtime).resolve():
            raise ValueError("{}: {} resolved outside the SDK: {}".format(path, runtime, match[1]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sdk", type=Path)
    parser.add_argument("symbols", type=Path)
    parser.add_argument("--machine", required=True)
    parser.add_argument("--glibc", required=True)
    parser.add_argument("--host-machine")
    parser.add_argument("--host-glibc", default="2.27")
    parser.add_argument("--interpreter")
    parser.add_argument("--readelf", default="readelf")
    parser.add_argument("--objcopy", default="objcopy")
    parser.add_argument("--strip", default="strip")
    parser.add_argument("--native-dependencies", action="store_true")
    args = parser.parse_args()
    args.limit = tuple(map(int, args.glibc.split(".")))
    args.host_limit = tuple(map(int, args.host_glibc.split(".")))
    os.environ["LC_ALL"] = "C"
    files = []
    for path in sorted(args.sdk.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            if stream.read(4) != b"\x7fELF":
                continue
        relocatable = audit(path, args)
        if args.native_dependencies:
            audit_native_dependencies(path, args)
        files.append((path, relocatable))
    if not files:
        raise ValueError("No ELF files in {}".format(args.sdk))
    args.symbols.mkdir(parents=True, exist_ok=False)
    for path, relocatable in files:
        debug = args.symbols / path.relative_to(args.sdk)
        debug = debug.with_name(debug.name + ".debug")
        sections = run(args.readelf, "-SW", str(path))
        if re.search(r"\.(?:z?debug_info|gnu_debugdata)\s", sections):
            debug.parent.mkdir(parents=True, exist_ok=True)
            run(args.objcopy, "--only-keep-debug", str(path), str(debug))
        run(args.strip, "--strip-debug" if relocatable else "--strip-unneeded", str(path))
        if debug.is_file():
            run(args.objcopy, "--add-gnu-debuglink=" + str(debug.resolve()), str(path))
        if re.search(r"\.(?:z?debug_info|gnu_debugdata)\s", run(args.readelf, "-SW", str(path))):
            raise ValueError("{}: debug information survived strip".format(path))
    print("Audited and stripped {} ELF files (glibc <= {})".format(len(files), args.glibc))


if __name__ == "__main__":
    main()
