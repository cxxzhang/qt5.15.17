#!/usr/bin/env bash
# Test the real packaging transformations before spending time compiling Qt.
set -euo pipefail
arch="${1:?cross target required}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
prefix="$root/build-temp/accepted-$arch"
work="$(mktemp -d "$root/build-temp/packaging-probe.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/lib"
readarray -t settings < <(python3 - "$prefix/toolchain.json" "$arch" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['sysroot'])
print('/lib64/ld-linux-loongarch-lp64d.so.1' if sys.argv[2] == 'loong64-newworld' else '/lib64/ld.so.1')
PY
)
"$prefix/bin/clang++" -std=c++17 -pthread "$root/scripts/linux-baseline/probe.cpp" \
  '-Wl,-rpath,$ORIGIN/../lib' -o "$work/bin/probe"
for name in libstdc++.so.6 libgcc_s.so.1; do
  cp -L "$prefix/probe-sdk/lib/$name" "$work/lib/$name"
done
for elf in "$work/bin/probe" "$work/lib/"*; do
  "$prefix/llvm/bin/llvm-strip" --strip-debug "$elf"
  rel="$(realpath --relative-to="$(dirname "$elf")" "$work/lib")"
  python3 "$root/scripts/elf-load-alignment.py" "$elf" "\$ORIGIN/$rel"
done
PYTHONPATH="$root/scripts" python3 - "$prefix/${settings[0]}" "$prefix/bin/qemu" "$work" "${settings[1]}" <<'PY'
from pathlib import Path
import sys
from linux_cross_runtime import TargetRoot
target = TargetRoot(sys.argv[1], sys.argv[2], sys.argv[3])
try:
    staged = target.stage_sdk(Path(sys.argv[3]))
    dependencies = target.list_dependencies(sys.argv[4], staged / 'bin/probe')
    for name in ('libstdc++.so.6', 'libgcc_s.so.1'):
        if target.guest_path(staged / 'lib' / name) not in dependencies:
            raise ValueError('Packaged probe loaded an unexpected provider: ' + dependencies)
    target.execute(staged / 'bin/probe')
    print('Stripped and relocated target ELF packaging probe passed')
finally:
    target.close()
PY
