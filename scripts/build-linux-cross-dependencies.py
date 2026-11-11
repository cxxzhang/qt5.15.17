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
    args = parser.parse_args()
    source = Path(__file__).resolve().parent.parent
    prefix = args.prefix.resolve()
    cross = prefix / "cross-loong64"
    sysroot = prefix / "sysroot-loong64"
    triple = "loongarch64-linux-gnu"
    recipe_path = source / "scripts/sysroots/loong64-sources.lock.json"
    recipe_bytes = recipe_path.read_bytes()
    lock = json.loads((source / "scripts/sysroots/loong64.lock.json").read_text())
    if hashlib.sha256(recipe_bytes).hexdigest() != lock["recipes_sha256"]:
        raise ValueError("Graphics recipes do not match the pinned sysroot")
    recipes = json.loads(recipe_bytes.decode("utf-8"))
    identity = hashlib.sha256(recipe_bytes + Path(__file__).read_bytes()).hexdigest()
    completed = cross / (".graphics-ready-" + identity)
    all_installed = all(((cross / "host" if r["host"] else sysroot)
                         / (".source-" + r["name"] + "-" + identity)).is_file()
                        for r in recipes["sources"])
    if completed.is_file() and all_installed:
        print("Using verified old-glibc graphics dependencies")
        return
    run("apt-get", "-o", "Acquire::Retries=5", "install", "-y", "--no-install-recommends",
        "autoconf", "automake", "libtool", "xutils-dev", "bison", "flex")
    run("python3", source / "scripts/prepare-linux-sysroot.py", recipe_path, prefix, "--sources-only")
    host = cross / "host"
    host.mkdir(parents=True, exist_ok=True)
    private_libs = cross / "dependencies/lib"
    private_libs.mkdir(parents=True, exist_ok=True)
    work = source / "build-temp/loong64-dependencies" / identity
    work.mkdir(parents=True, exist_ok=True)
    target_env = dict(os.environ, CC=str(cross / "bin/clang"), CXX=str(cross / "bin/clang++"),
                      AR=str(prefix / "llvm/bin/llvm-ar"), RANLIB=str(prefix / "llvm/bin/llvm-ranlib"),
                      NM=str(prefix / "llvm/bin/llvm-nm"), LD=str(prefix / "llvm/bin/ld.lld"),
                      STRIP=str(prefix / "llvm/bin/llvm-strip"),
                      CFLAGS="-O2 -g -fPIC", CXXFLAGS="-O2 -g -fsized-deallocation",
                      PKG_CONFIG=str(cross / "bin/pkg-config"),
                      PKG_CONFIG_PATH=str(host / "share/pkgconfig"), PYTHON="python3")
    target_env.pop("LD_LIBRARY_PATH", None)
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
        # Native source packages may omit the generated autotools files.
        env = dict(os.environ, PYTHON="python3") if is_host else target_env
        if not (project / "configure").is_file():
            run("autoreconf", "-fi", cwd=str(project), env=env)
        for filename in ("config.sub", "config.guess"):
            for path in project.rglob(filename):
                shutil.copy2(str(cross / "share" / filename), str(path))
        configure = [project / "configure", "--prefix=" + (str(host) if is_host else "/usr")]
        if not is_host:
            configure += ["--build=x86_64-linux-gnu", "--host=" + triple,
                          "--libdir=/usr/lib/" + triple, "--enable-shared", "--disable-static"]
        configure += options.get(name, [])
        print("Building {} against glibc {}".format(name, lock["glibc"]), flush=True)
        log = source / "build-temp/logs" / ("loong64-dependency-" + name + ".log")
        log.parent.mkdir(parents=True, exist_ok=True)
        libraries = []
        try:
            run(*configure, cwd=str(project), env=env)
            run("make", "-j" + os.environ.get("QT_BUILD_JOBS", "4"), cwd=str(project), env=env)
            if is_host:
                run("make", "install", cwd=str(project), env=env)
            else:
                stage = project / "install"
                run("make", "DESTDIR=" + str(stage), "install", cwd=str(project), env=env)
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
    run("python3", source / "scripts/prepare-linux-sysroot.py",
        source / "scripts/sysroots/loong64.lock.json", prefix)
    modules = "xcb xcb-glx xcb-render xcb-renderutil xcb-image xcb-icccm xcb-keysyms xcb-randr xcb-sync xcb-xinerama xcb-xkb xcb-shm xcb-present xcb-dri3 xkbcommon xkbcommon-x11 wayland-client wayland-server wayland-egl gl egl glesv2 glu".split()
    run(cross / "bin/pkg-config", "--exists", *modules, env=target_env)
    run("python3", source / "scripts/package-linux.py", private_libs, "--audit-only",
        "--machine", "LoongArch", "--glibc", lock["glibc"],
        "--readelf", prefix / "llvm/bin/llvm-readelf")
    completed.write_text(lock["glibc"] + "\n")
    print("Old-glibc graphics dependency build and ELF audit passed")


if __name__ == "__main__":
    main()
