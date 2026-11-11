#!/usr/bin/env bash
# Reuse runner tools and the accepted native snapshot for LLVM host libraries.
set -euo pipefail
arch="${1:?cross target required}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test "$(id -u)" = 0
for tool in cc make pkg-config patchelf readelf python3; do
  command -v "$tool"
done
cross="$root/build-temp/accepted-$arch"
host="$root/build-temp/accepted-x64"
compgen -G "$cross/.accepted-*" >/dev/null
compgen -G "$host/.accepted-*" >/dev/null
if ! ldconfig -p | grep 'libtinfo.so.5 ' >/dev/null; then
  library="$(find "$host/sysroot/usr/lib64" -type f -name 'libtinfo.so.5*' -print -quit)"
  test -n "$library" || { echo 'Accepted native snapshot lacks LLVM host libtinfo.so.5' >&2; exit 1; }
  readelf -h "$library" | grep -q 'Machine:.*Advanced Micro Devices X86-64'
  readelf -d "$library" | grep -q 'SONAME.*\[libtinfo.so.5\]'
  mkdir -p /usr/local/lib/qt-baseline-host
  cp "$library" /usr/local/lib/qt-baseline-host/libtinfo.so.5
  printf '%s\n' /usr/local/lib/qt-baseline-host >/etc/ld.so.conf.d/qt-baseline-host.conf
  ldconfig
  sha256sum "$library" /usr/local/lib/qt-baseline-host/libtinfo.so.5
fi
env -u LD_LIBRARY_PATH "$cross/bin/clang++" --version
env -u LD_LIBRARY_PATH "$cross/llvm/bin/llvm-readelf" --version
