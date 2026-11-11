#!/usr/bin/env bash
# Consume only published cross/native toolchains; never rebuild them here.
set -euo pipefail
arch="${1:?cross target required}"
variant="${2:?release or debug required}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test "$(id -u)" = 0
for directory in "$root" "$root/qtbase" "$root/qtdeclarative"; do
  git config --global --add safe.directory "$directory"
done
cross="$root/build-temp/accepted-$arch"
host="$root/build-temp/accepted-x64"
compgen -G "$cross/.accepted-*" >/dev/null
compgen -G "$host/.accepted-*" >/dev/null
test -x "$cross/bin/clang++"
test -x "$cross/bin/qemu"
test -x "$host/bin/clang++"
if [[ -f "$cross/toolchain.json" ]]; then
  sysroot_rel="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sysroot"])' "$cross/toolchain.json")"
else
  [[ "$arch" == loong64-oldworld ]]
  sysroot_rel=sysroot
fi
sysroot="$cross/$sysroot_rel"
compgen -G "$sysroot/.sysroot-*" >/dev/null
test -f "$cross/probe-sdk/lib/libstdc++.so.6"
test -f "$cross/probe-sdk/lib/libgcc_s.so.1"
context="$root/build-temp/cross-sdk-context-$arch"
mkdir -p "$context"
scanner="$cross/host/bin/wayland-scanner"
[[ -x "$scanner" ]] || scanner="$host/host/bin/wayland-scanner"
test -x "$scanner"
cat >"$context/pkg-config" <<EOF
#!/usr/bin/env bash
for argument in "\$@"; do
  if [[ "\$argument" == --variable=wayland_scanner ]]; then
    printf '%s\\n' "$scanner"
    exit 0
  fi
done
exec "$cross/bin/pkg-config" "\$@"
EOF
chmod +x "$context/pkg-config"
"$context/pkg-config" --print-errors --exists freetype2 fontconfig x11 xcb xcb-renderutil \
  xcb-icccm xkbcommon xkbcommon-x11 wayland-client wayland-server
export QT_ACCEPTED_CROSS_PREFIX="$cross" QT_ACCEPTED_HOST_PREFIX="$host" QT_ACCEPTED_SYSROOT="$sysroot"
export QT_CROSS_PKG_CONFIG="$context/pkg-config" WAYLAND_SCANNER="$scanner"
export CC="$host/bin/clang" CXX="$host/bin/clang++"
export QT_BUILD_JOBS="${QT_BUILD_JOBS:-4}"
bash "$root/scripts/build-linux-cross.sh" "$arch" "$variant"
