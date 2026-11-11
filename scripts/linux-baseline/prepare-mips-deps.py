#!/usr/bin/env python3
"""Audit graphical packages before merging into the source-built glibc 2.17 root."""

import hashlib
import json
from pathlib import Path
import runpy
import subprocess
import sys
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    prefix = ROOT / "build-temp/baseline-mips64el"
    prepared = prefix / "graphics-inputs"
    lock = ROOT / "scripts/linux-baseline/mips-graphics.lock.json"
    config = json.loads(lock.read_text())
    excluded = set(config["excluded_core_packages"])
    if any(p["name"] in excluded for p in config["packages"]):
        raise ValueError("Core glibc/GNU packages must not enter the graphics supplement")
    subprocess.check_call([sys.executable, str(ROOT / "scripts/prepare-linux-sysroot.py"), str(lock), str(prepared)])
    stage = prepared / "sysroot-mips64el-graphics"
    for path in stage.rglob("*"):
        if path.name in ("libc.so.6", "libc.so", "features.h", "ld.so.1") or path.name.startswith("ld-2."):
            raise ValueError("Core glibc file in graphics supplement: " + str(path))
    llvm = ROOT / "build-temp/loong-newworld-inputs/compiler/bin/llvm-readelf"
    # The source distribution's glibc version is not an acceptance claim.
    # Reject any actual ELF that needs a newer libc before copying a byte.
    audit = runpy.run_path(str(ROOT / "scripts/package-linux.py"))["audit"]
    arguments = SimpleNamespace(sdk=stage, machine="MIPS R3000", host_machine=None,
                                limit=(2, 17), interpreter=None, readelf=str(llvm))
    rejected = []
    count = 0
    for path in sorted(stage.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open("rb") as stream:
            magic = stream.read(8)
        if not (magic.startswith(b"\x7fELF") or magic == b"!<arch>\n"):
            continue
        count += 1
        try:
            audit(path, arguments)
        except ValueError as error:
            rejected.append(dict(path=str(path.relative_to(stage)), error=str(error)))
    report = ROOT / "build-temp/logs/mips217-graphics-audit.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(dict(checked=count, rejected=rejected), indent=2) + "\n")
    if rejected:
        raise ValueError("Graphics ELF baseline rejections: " + json.dumps(rejected))
    if not count:
        raise ValueError("No graphical ELF dependencies were audited")
    compilers = list((prefix / "gcc/bin").glob("*-gcc"))
    if len(compilers) != 1:
        raise ValueError("Expected the single source-built MIPS GCC")
    sysroot = Path(subprocess.check_output([str(compilers[0]), "-print-sysroot"], text=True).strip())
    libc = sysroot / "lib64/libc.so.6"
    if not libc.is_file():
        candidates = list(sysroot.rglob("libc-2.17.so"))
        if len(candidates) != 1:
            raise ValueError("Cannot identify the real source-built glibc 2.17")
        libc = candidates[0]
    before = digest(libc)
    subprocess.check_call(["cp", "-a", str(stage) + "/.", str(sysroot) + "/"])
    runpy.run_path(str(ROOT / "scripts/prepare-linux-sysroot.py"))["relative_symlinks"](sysroot)
    if digest(libc) != before:
        raise ValueError("Graphics supplement changed the source-built libc")
    provenance = prefix / "share/baseline"
    provenance.mkdir(parents=True, exist_ok=True)
    (provenance / lock.name).write_bytes(lock.read_bytes())
    (provenance / "graphics-glibc-audit.json").write_text(json.dumps(
        dict(glibc="2.17", libc_sha256=before, packages=len(config["packages"]),
             lock_sha256=digest(lock), audit="Passed ELF glibc requirement gate before merging; source-built libc unchanged"),
        indent=2) + "\n")
    print("Audited non-glibc graphical dependencies; the source-built glibc 2.17 is unchanged")


if __name__ == "__main__":
    main()
