#!/usr/bin/env bash
# Prepare Qt's graphical dependencies inside the real glibc 2.17 image.
set -euo pipefail
test "$(getconf GNU_LIBC_VERSION)" = 'glibc 2.17'
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
arch="${1:?x64 or arm64 required}"
prefix="$root/build-temp/baseline-$arch"
mkdir -p "$root/build-temp/logs" "$prefix/share/baseline"
yum -y install freetype-devel fontconfig-devel dbus-devel libdrm-devel \
  libX11-devel libxcb-devel xcb-util-devel xcb-util-image-devel \
  xcb-util-keysyms-devel xcb-util-renderutil-devel xcb-util-wm-devel \
  libxkbcommon-devel libxkbcommon-x11-devel wayland-devel \
  wayland-protocols-devel mesa-libGL-devel mesa-libEGL-devel dejavu-sans-fonts
rpm -qa | sort >"$prefix/share/baseline/qt-dependency-rpms.txt"
for package in freetype2 fontconfig dbus-1 libdrm x11 xcb xcb-renderutil \
  xcb-icccm xkbcommon xkbcommon-x11 wayland-client wayland-server gl egl; do
  pkg-config --modversion "$package"
done
# Retain a reusable target dependency sysroot. It contains only the baseline
# container's include/library/pkg-config/font data, not its host executables.
mkdir -p "$prefix/sysroot/usr/include" "$prefix/sysroot/usr/lib64" \
  "$prefix/sysroot/usr/share/pkgconfig" "$prefix/sysroot/usr/share/fonts" \
  "$prefix/sysroot/etc/fonts"
cp -a /usr/include/. "$prefix/sysroot/usr/include/"
cp -a /usr/lib64/. "$prefix/sysroot/usr/lib64/"
cp -a /usr/share/pkgconfig/. "$prefix/sysroot/usr/share/pkgconfig/"
cp -a /usr/share/fonts/. "$prefix/sysroot/usr/share/fonts/"
cp -a /etc/fonts/. "$prefix/sysroot/etc/fonts/"
echo "$arch: glibc 2.17 Qt graphical dependency sysroot prepared"
