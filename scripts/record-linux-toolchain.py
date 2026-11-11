#!/usr/bin/env python3
"""Record primary-source digests for the fixed Linux build inputs.

Run this on a CI runner when intentionally reviewing toolchain pins. Large
archives are streamed into hashes, rather than retained or extracted.
"""

import hashlib
import json
import os
from pathlib import Path
import sys
import time
import urllib.parse
import urllib.request


class Redirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, destination):
        result = super().redirect_request(request, fp, code, message, headers, destination)
        if result and urllib.parse.urlsplit(request.full_url).netloc != urllib.parse.urlsplit(destination).netloc:
            result.remove_header("Authorization")
        return result


def request(url, accept="application/json", token=None):
    headers = {"Accept": accept, "User-Agent": "qt-linux-toolchain-digests", "Cache-Control": "no-cache"}
    if token:
        headers["Authorization"] = "Bearer " + token
    return urllib.request.Request(url, headers=headers)


def read_json(url, token=None):
    with urllib.request.urlopen(request(url, token=token), timeout=45) as response:
        return json.load(response)


def main():
    token = os.environ.get("GITHUB_TOKEN")
    assets = [
        ("llvm_x64", "llvm/llvm-project", 177973150,
         "clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04.tar.xz", 1044930068),
        ("llvm_source", "llvm/llvm-project", 175206835,
         "llvm-project-18.1.8.src.tar.xz", 132067260),
        ("cmake_arm64", "Kitware/CMake", 137866107,
         "cmake-3.27.9-linux-aarch64.tar.gz", 53604675),
    ]
    result = {}
    opener = urllib.request.build_opener(Redirect)
    for key, repo, asset_id, name, expected_size in assets:
        api = "https://api.github.com/repos/{}/releases/assets/{}".format(repo, asset_id)
        metadata = read_json(api + "?metadata=1", token)
        if metadata["name"] != name or metadata["size"] != expected_size:
            raise ValueError("The fixed release asset metadata changed: " + name)
        digest = hashlib.sha256()
        size = 0
        magic = None
        print("Hashing", name, flush=True)
        with opener.open(request(api + "?download=" + str(int(time.time() * 1000000)),
                                 "application/octet-stream", token), timeout=60) as response:
            for block in iter(lambda: response.read(1024 * 1024), b""):
                if magic is None:
                    magic = block[:6]
                digest.update(block)
                size += len(block)
        expected_magic = b"\xfd7zXZ\x00" if name.endswith(".xz") else b"\x1f\x8b"
        if size != expected_size or not magic.startswith(expected_magic):
            raise ValueError("Release asset download is incomplete or not an archive: " + name)
        result[key] = {"url": metadata["browser_download_url"], "api_url": api,
                       "sha256": digest.hexdigest(), "size": size}
        print(key, result[key]["sha256"], flush=True)
    url = "https://gcc.gnu.org/pub/gcc/releases/gcc-13.3.0/gcc-13.3.0.tar.xz"
    sha256, sha512 = hashlib.sha256(), hashlib.sha512()
    print("Hashing GCC 13.3.0 source", flush=True)
    with urllib.request.urlopen(url, timeout=60) as response:
        for block in iter(lambda: response.read(1024 * 1024), b""):
            sha256.update(block)
            sha512.update(block)
    expected = "ed5f2f4c6ed2c796fcf2c93707159e9dbd3ddb1ba063d549804dd68cdabbb6d550985ae1c8465ae9a336cfe29274a6eb0f42e21924360574ebd8e5d5c7c9a801"
    if sha512.hexdigest() != expected:
        raise ValueError("GCC source does not match the published SHA512 pin")
    result["gcc_source"] = {"url": url, "sha256": sha256.hexdigest(), "sha512": expected}
    registry_token = read_json("https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/ubuntu:pull")["token"]
    url = "https://registry-1.docker.io/v2/library/ubuntu/manifests/18.04"
    accept = "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json"
    with urllib.request.urlopen(request(url, accept, registry_token), timeout=45) as response:
        raw = response.read()
        digest = response.headers["Docker-Content-Digest"]
    if digest != "sha256:" + hashlib.sha256(raw).hexdigest():
        raise ValueError("Container index digest mismatch")
    platforms = [entry.get("platform", {}) for entry in json.loads(raw.decode())["manifests"]]
    if not all(any(p.get("os") == "linux" and p.get("architecture") == arch for p in platforms)
               for arch in ("amd64", "arm64")):
        raise ValueError("Ubuntu index does not contain both native architectures")
    result["container"] = {"image": "ubuntu:18.04@" + digest, "platforms": platforms}
    output = Path(sys.argv[1])
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8", newline="\n") as stream:
        json.dump(result, stream, indent=2)
        stream.write("\n")
    print("Recorded fixed source digests:", output)


if __name__ == "__main__":
    main()
