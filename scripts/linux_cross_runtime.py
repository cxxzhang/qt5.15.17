#!/usr/bin/env python3
"""Execute target acceptance checks in the target filesystem using static QEMU.

QEMU's -L interpreter prefix does not redirect every filesystem syscall.
In particular, QEMU 9.2's statx path is not prefixed. A real chroot lets
the old target loader inspect the same files that it opens.
"""

import argparse
import atexit
import hashlib
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess


def clean_environment():
    env = dict(os.environ, LC_ALL="C", HOME="/")
    for key in ("LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT", "GITHUB_TOKEN"):
        env.pop(key, None)
    return env


class TargetRoot:
    def __init__(self, sysroot, qemu, identity, devices=False):
        self.root = Path(sysroot).resolve()
        if not any(self.root.glob(".sysroot-*")):
            raise ValueError("Not a prepared target sysroot: " + str(self.root))
        qemu = Path(qemu).resolve()
        program_headers = subprocess.check_output(["readelf", "-l", str(qemu)], universal_newlines=True)
        if "INTERP" in program_headers:
            raise ValueError("Target-root checks require a static QEMU: " + str(qemu))
        self.base = self.root / ".qt-acceptance" / hashlib.sha256(str(identity).encode()).hexdigest()[:16]
        self.base.mkdir(parents=True, exist_ok=True)
        (self.root / "tmp").mkdir(exist_ok=True)
        (self.root / "tmp").chmod(0o1777)
        self.emulator = self.root / ".qt-acceptance/qemu-host"
        self.devices = []
        atexit.register(self.close)
        shutil.copy2(str(qemu), str(self.emulator))
        if devices:
            (self.root / "dev").mkdir(exist_ok=True)
            for name, minor in (("null", 3), ("zero", 5), ("random", 8), ("urandom", 9)):
                node = self.root / "dev" / name
                if not node.exists() and not node.is_symlink():
                    os.mknod(str(node), stat.S_IFCHR | 0o666, os.makedev(1, minor))
                    self.devices.append(node)

    def close(self):
        for node in self.devices:
            if node.exists():
                node.unlink()
        if self.base.is_dir():
            shutil.rmtree(str(self.base))
        if self.emulator.is_file():
            self.emulator.unlink()

    def guest_path(self, path):
        return "/" + str(Path(path).relative_to(self.root)).replace(os.sep, "/")

    def command(self, *arguments):
        return ["chroot", str(self.root), self.guest_path(self.emulator), "-L", "/"] + [str(a) for a in arguments]

    def stage_sdk(self, sdk):
        destination = self.base / "sdk"
        destination.mkdir(exist_ok=True)
        subprocess.check_call(["cp", "-a", str(Path(sdk).resolve()) + "/.", str(destination) + "/"])
        return destination

    def stage_program(self, program):
        destination = self.base / "app"
        destination.mkdir(exist_ok=True)
        output = destination / Path(program).name
        shutil.copy2(str(program), str(output))
        return output

    def list_dependencies(self, loader, program):
        result = subprocess.run(self.command(loader, "--list", self.guest_path(program)),
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                universal_newlines=True, env=clean_environment())
        if result.returncode or "not found" in result.stdout:
            raise ValueError("{}: unresolved runtime dependency\n{}".format(program, result.stdout))
        return result.stdout

    def execute(self, program, extra_env=None):
        env = clean_environment()
        if extra_env:
            env.update(extra_env)
        result = subprocess.run(self.command(self.guest_path(program)), env=env)
        if result.returncode:
            subprocess.run(self.command("-E", "LD_DEBUG=libs", self.guest_path(program)), env=env)
            raise subprocess.CalledProcessError(result.returncode, result.args)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["probe", "smoke"])
    parser.add_argument("sysroot", type=Path)
    parser.add_argument("qemu", type=Path)
    parser.add_argument("program", type=Path)
    parser.add_argument("--loader")
    parser.add_argument("--stdlib", type=Path)
    parser.add_argument("--libgcc", type=Path)
    parser.add_argument("--sdk", type=Path)
    args = parser.parse_args()
    root = TargetRoot(args.sysroot, args.qemu, args.program.resolve(), devices=args.mode == "smoke")
    program = root.stage_program(args.program)
    if args.mode == "probe":
        if not (args.loader and args.stdlib and args.libgcc):
            parser.error("probe requires --loader, --stdlib and --libgcc")
        libraries = program.parent / "lib"
        libraries.mkdir(exist_ok=True)
        for source, name in ((args.stdlib, "libstdc++.so.6"), (args.libgcc, "libgcc_s.so.1")):
            shutil.copy2(str(source.resolve()), str(libraries / name))
        dependencies = root.list_dependencies(args.loader, program)
        for name in ("libstdc++.so.6", "libgcc_s.so.1"):
            expected = root.guest_path(libraries / name)
            match = re.search(r"^\s*" + re.escape(name) + r"\s+=>\s+(\S+)", dependencies, re.M)
            if not match or match[1] != expected:
                raise ValueError("Probe did not load its selected private runtime: " + dependencies)
        root.execute(program)
        print("Target-root C++20/thread probe loaded the selected libstdc++ and libgcc")
    else:
        if not args.sdk:
            parser.error("smoke requires --sdk")
        sdk = root.stage_sdk(args.sdk)
        subprocess.check_call(["patchelf", "--set-rpath", "$ORIGIN/../sdk/lib", str(program)])
        root.execute(program, {"QT_QPA_PLATFORM": "offscreen", "QML2_IMPORT_PATH": root.guest_path(sdk / "qml")})
        print("Extracted target SDK consumer passed inside its baseline filesystem")


if __name__ == "__main__":
    main()
