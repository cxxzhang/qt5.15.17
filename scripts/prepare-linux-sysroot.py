#!/usr/bin/env python3
"""Download, verify and unpack a fixed cross-compilation sysroot."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def fetch(package, base_url, cache):
    destination = cache / (package["sha256"] + ".deb")
    if destination.is_file() and digest(destination) == package["sha256"]:
        return destination
    partial = destination.with_suffix(".partial")
    url = base_url + "/" + package["path"]
    for attempt in range(4):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "qt-linux-sysroot"})
            with urllib.request.urlopen(request, timeout=45) as response, partial.open("wb") as stream:
                for block in iter(lambda: response.read(1024 * 1024), b""):
                    stream.write(block)
            if partial.stat().st_size != package["size"] or digest(partial) != package["sha256"]:
                raise ValueError("Package checksum/size mismatch: " + package["name"])
            partial.replace(destination)
            return destination
        except Exception:
            if partial.exists():
                partial.unlink()
            if attempt == 3:
                raise
            time.sleep(2 ** attempt)


def relative_symlinks(root):
    # Debian packages may use absolute target paths. Keep host tools, linkers
    # and QEMU from following those links outside the foreign sysroot.
    for directory, subdirs, files in os.walk(str(root), followlinks=False):
        for name in subdirs + files:
            path = Path(directory) / name
            if not path.is_symlink():
                continue
            target = os.readlink(str(path))
            if target.startswith("/"):
                relative = os.path.relpath(str(root / target.lstrip("/")), str(path.parent))
                path.unlink()
                path.symlink_to(relative)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lock", type=Path)
    parser.add_argument("prefix", type=Path)
    parser.add_argument("--download-only", action="store_true")
    args = parser.parse_args()
    raw = args.lock.read_bytes()
    lock = json.loads(raw.decode("utf-8"))
    marker_name = ".sysroot-" + hashlib.sha256(raw).hexdigest()
    pending_name = ".unpacking-" + hashlib.sha256(raw).hexdigest()
    root = args.prefix / ("sysroot-" + lock["architecture"])
    if (root / marker_name).is_file() and not args.download_only:
        print("Using verified sysroot:", root)
        return
    if (root.exists() and any(root.iterdir()) and not (root / pending_name).is_file()
            and not args.download_only):
        raise ValueError("Move the previous sysroot before changing its lock: " + str(root))
    cache = args.prefix / "downloads" / "debs"
    cache.mkdir(parents=True, exist_ok=True)
    packages = lock["packages"]
    with ThreadPoolExecutor(max_workers=4) as pool:
        paths = list(pool.map(lambda p: fetch(p, lock["base_url"], cache), packages))
    print("Verified {} pinned packages".format(len(paths)), flush=True)
    if args.download_only:
        return
    root.mkdir(parents=True, exist_ok=True)
    (root / pending_name).touch()
    for path in paths:
        subprocess.check_call(["dpkg-deb", "-x", str(path), str(root)])
    relative_symlinks(root)
    (root / marker_name).write_text(lock["architecture"] + " glibc " + lock["glibc"] + "\n")
    (root / pending_name).unlink()
    print("Prepared", root)


if __name__ == "__main__":
    main()
