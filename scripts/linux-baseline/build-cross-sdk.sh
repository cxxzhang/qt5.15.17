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
  sysroot_rel="$(python3 - "$cross/toolchain.json" <<'PY'
import json, sys
from pathlib import Path
entry = json.load(open(sys.argv[1]))
# The first validated original-GNU LoongArch bundles predate the JSON field.
system_marker = Path(sys.argv[1]).parent / 'runtime/.system-runtime'
assert entry.get('gnu_runtime_policy') == 'baseline-system' or system_marker.is_file(), 'Replace the historical high-GNU-runtime bundle before SDK acceptance'
print(entry['sysroot'])
PY
)"
else
  echo 'The published cross toolchain needs a validated baseline GNU runtime manifest' >&2
  exit 1
fi
sysroot="$cross/$sysroot_rel"
compgen -G "$sysroot/.sysroot-*" >/dev/null
test -f "$cross/probe-sdk/lib/libstdc++.so.6"
test -f "$cross/probe-sdk/lib/libgcc_s.so.1"
context="$root/build-temp/cross-sdk-context-$arch"
mkdir -p "$context/native-link"
# The image's libgcc linker script names /lib64, which is not Ubuntu's
# library layout. Supply a derived link name without modifying the cache.
ln -sfn "$host/gcc/lib64/libgcc_s.so.1" "$context/native-link/libgcc_s.so"
for name in clang clang++; do
  cat >"$context/$name" <<EOF
#!/usr/bin/env bash
exec "$host/bin/$name" -L"$context/native-link" "\$@"
EOF
  chmod +x "$context/$name"
done
pkg_dirs="$(python3 - "$sysroot" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
print(':'.join(str(p) for p in sorted({p.parent for p in root.rglob('*.pc')})))
PY
)"
if [[ -z "$pkg_dirs" ]]; then
  echo 'The accepted sysroot contains no pkg-config metadata; inspecting its development inputs' >&2
  python3 - "$sysroot" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for name in ('freetype.h', 'fontconfig.h', 'Xlib.h', 'xcb.h', 'xkbcommon.h', 'wayland-client.h', 'status'):
    print(name, [str(p.relative_to(root)) for p in root.rglob(name)][:20])
PY
  exit 1
fi
scanner="$cross/host/bin/wayland-scanner"
[[ -x "$scanner" ]] || scanner="$host/host/bin/wayland-scanner"
test -x "$scanner"
cat >"$context/pkg-config" <<EOF
#!/usr/bin/env bash
export PKG_CONFIG_SYSROOT_DIR="$sysroot"
export PKG_CONFIG_LIBDIR="$pkg_dirs"
export PKG_CONFIG_PATH="$cross/host/lib/pkgconfig:$cross/host/share/pkgconfig"
for argument in "\$@"; do
  if [[ "\$argument" == --variable=wayland_scanner ]]; then
    printf '%s\\n' "$scanner"
    exit 0
  fi
done
exec /usr/bin/pkg-config "\$@"
EOF
chmod +x "$context/pkg-config"
for package in freetype2 fontconfig x11 xcb xcb-renderutil xcb-icccm xkbcommon xkbcommon-x11 wayland-client wayland-server; do
  printf 'Target dependency %s: ' "$package"
  "$context/pkg-config" --modversion "$package" || true
done
"$context/pkg-config" --print-errors --exists freetype2 fontconfig x11 xcb xcb-renderutil \
  xcb-icccm xkbcommon xkbcommon-x11 wayland-client wayland-server
export QT_ACCEPTED_CROSS_PREFIX="$cross" QT_ACCEPTED_HOST_PREFIX="$host" QT_ACCEPTED_SYSROOT="$sysroot"
export QT_CROSS_PKG_CONFIG="$context/pkg-config" WAYLAND_SCANNER="$scanner"
export QT_NATIVE_COMPILER_BIN="$context"
export CC="$context/clang" CXX="$context/clang++"
export QT_BUILD_JOBS="${QT_BUILD_JOBS:-4}"
if [[ -n "${3:-}" ]]; then
  bash "$root/scripts/linux-baseline/verify-sdk.sh" "$arch" "$variant" "$3"
else
  bash "$root/scripts/build-linux-cross.sh" "$arch" "$variant"
fi
