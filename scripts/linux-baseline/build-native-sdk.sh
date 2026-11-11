#!/usr/bin/env bash
# Restore a published baseline environment, then build/audit the Qt SDK.
set -euo pipefail
arch="${1:?x64 or arm64 required}"
variant="${2:?release or debug required}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
prefix="$root/build-temp/accepted-$arch"
test -f /.dockerenv
test "$(id -u)" = 0
test "$(getconf GNU_LIBC_VERSION)" = 'glibc 2.17'
compgen -G "$prefix/.accepted-*" >/dev/null
test -x "$prefix/bin/clang++"
test -f "$prefix/share/baseline/qt-dependency-rpms.txt"
if [[ ! -x /opt/python/cp311-cp311/bin/python3 ]]; then
  manylinux-interpreters ensure cp311-cp311
fi
# The released sysroot already contains the baseline dependencies. Restore
# their runtime files into this disposable matching container without yum.
for directory in usr/lib64 usr/include usr/share/pkgconfig usr/share/fonts etc/fonts usr/share/wayland usr/share/wayland-protocols; do
  if [[ -d "$prefix/sysroot/$directory" ]]; then
    mkdir -p "/$directory"
    cp -a "$prefix/sysroot/$directory/." "/$directory/"
  fi
done
if [[ -x "$prefix/host/bin/wayland-scanner" ]]; then
  cp "$prefix/host/bin/wayland-scanner" /usr/bin/wayland-scanner
fi
ldconfig
export PATH="$prefix/bin:$prefix/host/bin:/opt/python/cp311-cp311/bin:$PATH"
export CC="$prefix/bin/clang" CXX="$prefix/bin/clang++"
export PKG_CONFIG_SYSROOT_DIR="$prefix/sysroot"
export PKG_CONFIG_LIBDIR="$prefix/sysroot/usr/lib64/pkgconfig:$prefix/sysroot/usr/share/pkgconfig"
unset PKG_CONFIG_PATH
export QT_BUILD_JOBS="${QT_BUILD_JOBS:-4}"
bash "$root/scripts/build-linux.sh" "$arch" "$variant"
