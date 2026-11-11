#!/usr/bin/env bash
# Source this file to select the checksum-pinned vendor cross compiler.
vendor_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
vendor_work="$vendor_root/build-temp/loong28-inspection"
mkdir -p "$vendor_work/downloads" "$vendor_work/compiler" "$vendor_work/host-libs"
vendor_fetch() {
  local name="$1" url="$2" checksum="$3" path="$vendor_work/downloads/$1"
  if [[ ! -s "$path" ]]; then
    curl -fsSL --retry 5 --connect-timeout 30 --max-time 1200 "$url" -o "$path.tmp"
    mv "$path.tmp" "$path"
  fi
  echo "$checksum  $path" | sha256sum -c -
}
vendor_fetch llvm20.tar.gz https://ftp.loongnix.cn/toolchain/llvm/llvm20/llvm-toolchain_20.1.8-1_amd64-linux-gnu_debian-10.tar.gz b552f93326948c7292cceaf11db7eb442327448d9f45b4b25eafdbfa9b60c25e
vendor_fetch libffi6.deb https://archive.debian.org/debian/pool/main/libf/libffi/libffi6_3.2.1-9_amd64.deb d4d748d897e8e53aa239ead23a18724a1a30085cc6ca41a8c31b3b1e1b3452f4
if [[ ! -d "$vendor_work/compiler/llvm-toolchain_20.1.8-1_amd64-linux-gnu_debian-10" ]]; then
  tar -xf "$vendor_work/downloads/llvm20.tar.gz" -C "$vendor_work/compiler"
fi
dpkg-deb -x "$vendor_work/downloads/libffi6.deb" "$vendor_work/host-libs"
export LD_LIBRARY_PATH="$vendor_work/host-libs/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
vendor_compiler="$vendor_work/compiler/llvm-toolchain_20.1.8-1_amd64-linux-gnu_debian-10/llvm_install/bin/clang-20"
test -x "$vendor_compiler"
"$vendor_compiler" --version
