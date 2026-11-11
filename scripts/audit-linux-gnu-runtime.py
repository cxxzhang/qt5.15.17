#!/usr/bin/env python3
"""Check that ELF imports are provided by the selected baseline GNU runtimes."""

import argparse
import json
from pathlib import Path
import re
import subprocess


PREFIXES = ("GLIBCXX_", "CXXABI_", "GCC_")


def inspect(readelf, path):
    output = subprocess.check_output(
        [str(readelf), "--wide", "--dyn-syms", "--version-info", str(path)], text=True)
    before, _, needs = output.partition("Version needs section")
    definitions = set(re.findall(r"Name:\s+(\S+)", before))
    requirements = {v for v in re.findall(r"Name:\s+(\S+)", needs)
                    if v.startswith(PREFIXES)}
    imports, exports = set(), set()
    for line in output.splitlines():
        fields = line.split()
        if len(fields) < 8 or not re.fullmatch(r"\d+:", fields[0]):
            continue
        symbol = fields[7]
        parts = re.split(r"@+", symbol)
        if len(parts) != 2 or not parts[1].startswith(PREFIXES):
            continue
        (imports if fields[6] == "UND" else exports).add(tuple(parts))
    return definitions, requirements, imports, exports


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sdk", type=Path)
    parser.add_argument("--libstdcxx", type=Path, required=True)
    parser.add_argument("--libgcc", type=Path, required=True)
    parser.add_argument("--readelf", default="readelf")
    parser.add_argument("--skip-host", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    definitions, exports = set(), set()
    for provider in (args.libstdcxx, args.libgcc):
        provided, _, _, symbols = inspect(args.readelf, provider)
        definitions.update(provided)
        exports.update(symbols)
    files, missing = {}, {}
    for path in sorted(args.sdk.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        relative = path.relative_to(args.sdk)
        if args.skip_host and relative.parts[0] == "host":
            continue
        with path.open("rb") as stream:
            if stream.read(4) != b"\x7fELF":
                continue
        _, required, imported, _ = inspect(args.readelf, path)
        if required:
            files[str(relative)] = sorted(required)
        absent_versions = sorted(required - definitions)
        absent_symbols = sorted(name + "@" + version for name, version in imported - exports)
        if absent_versions or absent_symbols:
            missing[str(relative)] = dict(versions=absent_versions, symbols=absent_symbols)
    all_versions = {v for values in files.values() for v in values}
    maxima = {}
    for prefix in PREFIXES:
        values = [v for v in all_versions if re.fullmatch(re.escape(prefix) + r"\d+(?:\.\d+)*", v)]
        maxima[prefix.rstrip("_")] = max(values, key=lambda v: tuple(map(int, v[len(prefix):].split(".")))) if values else None
    record = dict(accepted=not missing, providers=dict(libstdcxx=str(args.libstdcxx), libgcc=str(args.libgcc)),
                  maximum_required_versions=maxima, files=files, missing=missing)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(record, indent=2) + "\n")
    if missing:
        raise SystemExit("Baseline GNU runtimes cannot provide all imports: " + json.dumps(missing))
    print("Baseline GNU runtime imports verified: " + json.dumps(maxima))


if __name__ == "__main__":
    main()
