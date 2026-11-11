#!/usr/bin/env python3
"""Freeze a Qt development sysroot's Debian package dependency closure.

This is a maintainer tool. Builds consume the resulting manifest, rather
than resolving a changing distribution or silently omitting dependencies.
"""

import argparse
import hashlib
import json
import lzma
from pathlib import Path
import re


ROOTS = """
libc6-dev linux-libc-dev libfontconfig1-dev libdbus-1-dev libdrm-dev
libgl1-mesa-dev libegl1-mesa-dev libgles2-mesa-dev libglu1-mesa-dev
libx11-dev libx11-xcb-dev libxcb1-dev libxcb-glx0-dev libxcb-render0-dev
libxcb-render-util0-dev libxcb-shape0-dev libxcb-xfixes0-dev libxcb-image0-dev
libxcb-icccm4-dev libxcb-keysyms1-dev libxcb-randr0-dev libxcb-sync-dev
libxcb-xinerama0-dev libxcb-xkb-dev libxcb-shm0-dev libxcb-present-dev
libxcb-dri3-dev libxcb-util0-dev libxkbcommon-dev libxkbcommon-x11-dev
libwayland-dev wayland-protocols
""".split()


def paragraphs(text):
    fields = {}
    key = None
    for line in text.splitlines() + [""]:
        if not line:
            if fields:
                yield fields
            fields, key = {}, None
        elif line[0].isspace():
            if key:
                fields[key] += " " + line.strip()
        elif ":" in line:
            key, value = line.split(":", 1)
            fields[key] = value.lstrip()


def dependency_names(clause):
    # These indexes contain binary runtime dependencies, not source Build-Depends.
    # Record the full original clauses in the lock for review of version constraints.
    for alternative in clause.split("|"):
        match = re.match(r"\s*([a-z0-9][a-z0-9.+-]*)(?::[a-z0-9-]+)?", alternative)
        if not match:
            raise ValueError("Invalid dependency: " + clause)
        yield match[1]


def resolve(packages, roots):
    providers = {}
    for name, fields in packages.items():
        for provision in fields.get("Provides", "").split(","):
            if provision.strip():
                virtual = next(dependency_names(provision))
                providers.setdefault(virtual, []).append(name)
    selected = set()

    def choose(clause):
        for name in dependency_names(clause):
            if name in packages:
                return name
            candidates = sorted(providers.get(name, []))
            present = [name for name in candidates if name in selected or name in roots]
            if present:
                return present[0]
            if len(candidates) == 1:
                return candidates[0]
        raise ValueError("Unresolved or ambiguous dependency: " + clause)

    queue = list(roots)
    while queue:
        clause = queue.pop(0)
        name = choose(clause)
        if name in selected:
            continue
        selected.add(name)
        fields = packages[name]
        for key in ("Pre-Depends", "Depends"):
            queue.extend(item.strip() for item in fields.get(key, "").split(",") if item.strip())
    return [packages[name] for name in sorted(selected)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("arch", choices=["loong64", "mips64el"])
    parser.add_argument("index", type=Path)
    parser.add_argument("base_url")
    parser.add_argument("output", type=Path)
    parser.add_argument("--supplement", type=Path)
    args = parser.parse_args()
    data = args.index.read_bytes()
    packages = {fields["Package"]: fields for fields in paragraphs(lzma.decompress(data).decode("utf-8"))
                if fields.get("Architecture") in (args.arch, "all") and "Filename" in fields}
    if args.supplement:
        supplement = args.supplement.read_bytes()
        packages.update({fields["Package"]: fields for fields in paragraphs(lzma.decompress(supplement).decode("utf-8"))
                         if fields.get("Architecture") in (args.arch, "all") and "Filename" in fields})
    roots = list(ROOTS)
    freetype = "libfreetype6-dev" if "libfreetype6-dev" in packages else "libfreetype-dev"
    gcc_versions = [version for version in range(13, 5, -1)
                    if "libstdc++-{}-dev".format(version) in packages
                    and "libgcc-{}-dev".format(version) in packages]
    if not gcc_versions:
        raise ValueError("No compatible target GCC development package pair")
    gcc_version = gcc_versions[0]
    roots.extend([freetype, "libstdc++-{}-dev".format(gcc_version),
                  "libgcc-{}-dev".format(gcc_version)])
    baseline = re.match(r"([0-9]+\.[0-9]+)", packages["libc6"]["Version"])[1]
    records = []
    for fields in resolve(packages, roots):
        sha = fields.get("SHA256", "")
        if not re.fullmatch(r"[a-f0-9]{64}", sha):
            raise ValueError("Missing SHA256: " + fields["Package"])
        records.append({"name": fields["Package"], "version": fields["Version"],
                        "architecture": fields["Architecture"], "path": fields["Filename"],
                        "sha256": sha, "size": int(fields["Size"]),
                        "depends": fields.get("Depends", ""),
                        "pre_depends": fields.get("Pre-Depends", "")})
    result = {"architecture": args.arch, "glibc": baseline, "gcc_version": gcc_version,
              "base_url": args.base_url.rstrip("/"), "index_sha256": hashlib.sha256(data).hexdigest(),
              "roots": roots, "packages": records}
    if args.supplement:
        result["supplement_sha256"] = hashlib.sha256(supplement).hexdigest()
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print("Locked {} packages, {:.1f} MiB".format(len(records), sum(p["size"] for p in records) / 2**20))


if __name__ == "__main__":
    main()
