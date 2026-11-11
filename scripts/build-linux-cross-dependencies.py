#!/usr/bin/env python3
"""Fill the LoongArch glibc 2.36 sysroot's graphics library gaps from source."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def run(*command, **kwargs):
    subprocess.check_call([str(part) for part in command], **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prefix", type=Path)
    parser.add_argument("--cross", type=Path)
    parser.add_argument("--sysroot", type=Path)
    parser.add_argument("--llvm", type=Path)
    parser.add_argument("--recipes", type=Path,
                        help="Pinned supplemental recipes with an explicit glibc baseline")
    args = parser.parse_args()
    source = Path(__file__).resolve().parent.parent
    prefix = args.prefix.resolve()
    cross = args.cross.resolve() if args.cross else prefix / "cross-loong64"
    sysroot = args.sysroot.resolve() if args.sysroot else prefix / "sysroot-loong64"
    llvm = args.llvm.resolve() if args.llvm else prefix / "llvm"
    triple = "loongarch64-linux-gnu"
    recipe_path = args.recipes.resolve() if args.recipes else source / "scripts/sysroots/loong64-sources.lock.json"
    recipe_bytes = recipe_path.read_text(encoding="utf-8").encode("utf-8")
    lock = json.loads((source / "scripts/sysroots/loong64.lock.json").read_text())
    if not args.recipes and hashlib.sha256(recipe_bytes).hexdigest() != lock["recipes_sha256"]:
        raise ValueError("Graphics recipes do not match the pinned sysroot")
    recipes = json.loads(recipe_bytes.decode("utf-8"))
    baseline = recipes["glibc"] if args.recipes else lock["glibc"]
    identity = hashlib.sha256(recipe_bytes + Path(__file__).read_bytes()).hexdigest()
    completed = cross / (".graphics-ready-" + identity)
    all_installed = all(((cross / "host" if r["host"] else sysroot)
                         / (".source-" + r["name"] + "-" + identity)).is_file()
                        for r in recipes["sources"])
    if completed.is_file() and all_installed:
        print("Using verified old-glibc graphics dependencies")
        return
    run("apt-get", "-o", "Acquire::Retries=5", "install", "-y", "--no-install-recommends",
        "autoconf", "automake", "libtool", "xutils-dev", "bison", "flex", "gperf", "libexpat1-dev",
        "meson", "ninja-build")
    run("python3", source / "scripts/prepare-linux-sysroot.py", recipe_path, prefix, "--sources-only")
    host = cross / "host"
    host.mkdir(parents=True, exist_ok=True)
    # Vendor sysroots can distribute development metadata over lib and lib64.
    pkg_dirs = ":".join(str(p) for p in sorted({p.parent for p in sysroot.rglob("*.pc")} |
                                             {sysroot / "usr/lib" / triple / "pkgconfig"}))
    pkg_wrapper = cross / "bin/pkg-config"
    pkg_wrapper.write_text("#!/usr/bin/env bash\n"
                           'prefix="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"\n'
                           'export PKG_CONFIG_SYSROOT_DIR="$prefix/' + os.path.relpath(sysroot, cross) + '"\n'
                           "export PKG_CONFIG_LIBDIR='" + pkg_dirs + "'\n"
                           'export PKG_CONFIG_PATH="$prefix/host/lib/pkgconfig:$prefix/host/share/pkgconfig"\n'
                           'exec /usr/bin/pkg-config "$@"\n')
    pkg_wrapper.chmod(0o755)
    private_libs = cross / "dependencies/lib"
    private_libs.mkdir(parents=True, exist_ok=True)
    work = source / "build-temp/loong64-dependencies" / identity
    work.mkdir(parents=True, exist_ok=True)
    target_env = dict(os.environ, CC=str(cross / "bin/clang"), CXX=str(cross / "bin/clang++"),
                      AR=str(llvm / "bin/llvm-ar"), RANLIB=str(llvm / "bin/llvm-ranlib"),
                      NM=str(llvm / "bin/llvm-nm"), LD=str(llvm / "bin/ld.lld"),
                      STRIP=str(llvm / "bin/llvm-strip"),
                      CFLAGS="-O2 -g -fPIC", CXXFLAGS="-O2 -g -fsized-deallocation",
                      PKG_CONFIG=str(cross / "bin/pkg-config"),
                      PKG_CONFIG_PATH=str(host / "lib/pkgconfig") + ":" + str(host / "share/pkgconfig"), PYTHON="python3")
    target_env["PATH"] = str(host / "bin") + os.pathsep + target_env["PATH"]
    target_env.pop("LD_LIBRARY_PATH", None)
    if recipes.get("host_library_dir"):
        target_env["LD_LIBRARY_PATH"] = str(cross / recipes["host_library_dir"])
    options = {
        "libxcb": ["--enable-xkb", "--enable-xinput"],
        "wayland": ["--with-host-scanner", "--disable-documentation", "--disable-dtd-validation",
                    "--disable-fatal-warnings"],
        "libxkbcommon": ["--enable-x11", "--disable-wayland", "--without-doxygen"],
    }
    for recipe in recipes["sources"]:
        name = recipe["name"]
        is_host = recipe["host"]
        marker = (host if is_host else sysroot) / (".source-" + name + "-" + identity)
        if marker.is_file():
            if not is_host:
                for library in json.loads(marker.read_text())["libraries"]:
                    output = private_libs / library
                    if output.is_symlink() or output.exists():
                        output.unlink()
                    shutil.copy2(str(sysroot / "usr/lib" / triple / library), str(output), follow_symlinks=False)
            continue
        project = work / name
        project.mkdir(parents=True, exist_ok=True)
        archive = prefix / "downloads/sources" / (recipe["sha256"] + "-" + Path(recipe["path"]).name)
        run("tar", "-xf", archive, "--strip-components=1", "-C", project)
        if name == "xcb-proto":
            replacements = 0
            for path in project.rglob('*.py'):
                text = path.read_text()
                if 'from fractions import gcd' in text:
                    replacements += text.count('from fractions import gcd')
                    path.write_text(text.replace('from fractions import gcd', 'from math import gcd'))
            if not replacements:
                raise ValueError("Pinned xcb-proto Python compatibility patch no longer applies")
        if name == "libglu":
            # Modern GL headers do not provide NULL through incidental includes.
            error_source = project / "src/libutil/error.c"
            content = error_source.read_text()
            assert content.count('#include "gluos.h"') == 1
            error_source.write_text(content.replace('#include "gluos.h"',
                                                   '#include <stddef.h>\n#include "gluos.h"'))
        # Native source packages may omit the generated autotools files.
        env = dict(os.environ, PYTHON="python3") if is_host else dict(target_env)
        if name == "libglu":
            # GLU 9.0 predates C++17's removal of the register keyword.
            env["CXXFLAGS"] += " -std=gnu++11"
        meson = recipe.get("build_system") == "meson"
        if not meson and not (project / "configure").is_file():
            run("autoreconf", "-fi", cwd=str(project), env=env)
        for filename in ("config.sub", "config.guess"):
            for path in project.rglob(filename):
                shutil.copy2(str(cross / "share" / filename), str(path))
        if name == "wayland":
            # A newer host scanner can emit client calls absent from the old
            # target library. Build the scanner from the same pinned source.
            scanner_build = work / "wayland-host-scanner"
            scanner_build.mkdir(exist_ok=True)
            host_env = dict(os.environ, PYTHON="python3")
            for variable in ("CC", "CXX", "AR", "RANLIB", "LD", "PKG_CONFIG", "PKG_CONFIG_PATH",
                             "PKG_CONFIG_LIBDIR", "PKG_CONFIG_SYSROOT_DIR", "LD_LIBRARY_PATH"):
                host_env.pop(variable, None)
            run(project / "configure", "--prefix=" + str(host), "--disable-libraries",
                "--disable-documentation", "--disable-dtd-validation", cwd=str(scanner_build), env=host_env)
            run("make", "-j" + os.environ.get("QT_BUILD_JOBS", "4"), cwd=str(scanner_build), env=host_env)
            run("make", "install", cwd=str(scanner_build), env=host_env)
            target_env["WAYLAND_SCANNER"] = str(host / "bin/wayland-scanner")
            env["WAYLAND_SCANNER"] = target_env["WAYLAND_SCANNER"]
        configure = [project / "configure", "--prefix=" + (str(host) if is_host else "/usr")]
        if not is_host:
            configure += ["--build=x86_64-linux-gnu", "--host=" + triple,
                          "--libdir=/usr/lib/" + triple, "--with-sysroot=" + str(sysroot),
                          "--enable-shared", "--disable-static"]
        configure += options.get(name, [])
        print("Building {} against glibc {}".format(name, baseline), flush=True)
        log = source / "build-temp/logs" / ("loong64-dependency-" + name + ".log")
        log.parent.mkdir(parents=True, exist_ok=True)
        libraries = []
        try:
            if meson:
                cross_file = project / "cross.ini"
                cross_file.write_text("[binaries]\n" + "\n".join(
                    "{} = '{}'".format(key, value) for key, value in {
                        "c": cross / "bin/clang", "cpp": cross / "bin/clang++",
                        "ar": llvm / "bin/llvm-ar", "strip": llvm / "bin/llvm-strip",
                        "pkgconfig": pkg_wrapper}.items()) +
                    "\n[host_machine]\nsystem = 'linux'\ncpu_family = 'loongarch64'\n"
                    "cpu = 'loongarch64'\nendian = 'little'\n"
                    "[properties]\nneeds_exe_wrapper = true\n")
                meson_build = project / "build"
                run("meson", "setup", meson_build, project, "--cross-file=" + str(cross_file),
                    "--prefix=/usr", "--libdir=lib/" + triple, "--buildtype=debugoptimized",
                    "--default-library=shared", *recipe["meson_options"], env=env)
                run("ninja", "-C", meson_build, "-j" + os.environ.get("QT_BUILD_JOBS", "4"), env=env)
            else:
                run(*configure, cwd=str(project), env=env)
                run("make", "-j" + os.environ.get("QT_BUILD_JOBS", "4"), cwd=str(project), env=env)
            if is_host:
                run("make", "install", cwd=str(project), env=env)
            else:
                stage = project / "install"
                if meson:
                    run("meson", "install", "-C", meson_build, "--no-rebuild",
                        env=dict(env, DESTDIR=str(stage)))
                else:
                    run("make", "DESTDIR=" + str(stage), "install", cwd=str(project), env=env)
                audit = ["python3", source / "scripts/package-linux.py", stage, "--audit-only",
                         "--machine", "LoongArch", "--glibc", baseline,
                         "--readelf", llvm / "bin/llvm-readelf"]
                if recipes.get("elf_flags"):
                    audit += ["--elf-flags", recipes["elf_flags"]]
                run(*audit, env=env)
                # Shared libraries link through their .so names and pkg-config.
                # Old libtool versions cannot consume newer .la sysroot escapes.
                # Do not carry this absolute-path metadata between projects.
                for archive in (stage / "usr/lib" / triple).glob("*.la"):
                    previous = sysroot / "usr/lib" / triple / archive.name
                    if previous.is_file() or previous.is_symlink():
                        previous.unlink()
                    archive.unlink()
                run("cp", "-a", str(stage) + "/.", str(sysroot) + "/")
                for library in sorted((stage / "usr/lib" / triple).glob("*.so*")):
                    libraries.append(library.name)
                    output = private_libs / library.name
                    if output.is_symlink() or output.exists():
                        output.unlink()
                    shutil.copy2(str(library), str(output), follow_symlinks=False)
        finally:
            if (project / "config.log").is_file():
                shutil.copy2(str(project / "config.log"), str(log))
        marker.write_text(json.dumps({"version": recipe["version"], "libraries": libraries}) + "\n")
    modules = recipes.get("required_modules") or "xcb xcb-glx xcb-render xcb-renderutil xcb-image xcb-icccm xcb-keysyms xcb-randr xcb-sync xcb-xinerama xcb-xkb xcb-shm xcb-present xcb-dri3 xkbcommon xkbcommon-x11 wayland-client wayland-server wayland-egl gl egl glesv2 glu".split()
    run(cross / "bin/pkg-config", "--exists", *modules, env=target_env)
    run("python3", source / "scripts/package-linux.py", private_libs, "--audit-only",
        "--machine", "LoongArch", "--glibc", baseline,
        "--readelf", llvm / "bin/llvm-readelf", env=target_env)
    completed.write_text(baseline + "\n")
    print("Old-glibc graphics dependency build and ELF audit passed")


if __name__ == "__main__":
    main()
