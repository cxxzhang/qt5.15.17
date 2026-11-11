#!/usr/bin/env bash
# Independent acceptance: archives and published toolchains, no Qt build tree.
set -euo pipefail
arch="${1:?target required}"
variant="${2:?variant required}"
artifacts="${3:?artifact directory required}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
artifacts="$(cd "$artifacts" && pwd)"
test ! -e "$root/Output/linux-$arch"
test ! -e "$root/Output/linux-$arch-debug"
read -r baseline < <(python3 - "$root/scripts/linux-baseline/targets.json" "$arch" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['targets'][sys.argv[2]]['glibc'])
PY
)
case "$arch" in
  x64) machine='Advanced Micro Devices X86-64'; cross=false ;;
  arm64) machine=AArch64; cross=false ;;
  loong64-oldworld) machine=LoongArch; cross=true; loader=/lib64/ld.so.1; flags=0x3 ;;
  loong64-newworld) machine=LoongArch; cross=true; loader=/lib64/ld-linux-loongarch-lp64d.so.1; flags=0x43 ;;
  mips64el) machine='MIPS R3000'; cross=true; loader=/lib64/ld.so.1 ;;
  *) exit 2 ;;
esac
name="qt5.15.17_linux_${arch//-/_}"
[[ "$variant" != debug ]] || name+=_debug
sdk="$(mktemp -d /tmp/qt-baseline-sdk.XXXXXXXX)"
work="$(mktemp -d /tmp/qt-baseline-consumer.XXXXXXXX)"
trap 'rm -rf "$sdk" "$work"' EXIT
tar -xzf "$artifacts/$name.tar.gz" -C "$sdk"
python3 "$root/scripts/verify-linux-symbols.py" "$sdk" "$artifacts/$name-symbols.tar.gz"
if "$cross"; then
  prefix="$root/build-temp/accepted-$arch"
  tools="$prefix/llvm/bin"
  audit=(--host-machine 'Advanced Micro Devices X86-64' --host-glibc 2.17 --interpreter "$loader")
  [[ "$arch" != loong64-* ]] || audit+=(--elf-flags "$flags")
  python3 "$root/scripts/package-linux.py" "$sdk" --audit-only --require-stripped \
    --machine "$machine" --glibc "$baseline" --readelf "$tools/llvm-readelf" "${audit[@]}"
  python3 "$root/scripts/audit-linux-cross-runtime.py" "$sdk" --sysroot "${QT_ACCEPTED_SYSROOT:?}" \
    --qemu "$prefix/bin/qemu" --loader "$loader" --readelf "$tools/llvm-readelf"
  qmake="$sdk/host/bin/qmake"
  export CC="$prefix/bin/clang" CXX="$prefix/bin/clang++"
  export QT_CROSS_QEMU="$prefix/bin/qemu" QT_CROSS_SYSROOT="$QT_ACCEPTED_SYSROOT"
else
  test "$(getconf GNU_LIBC_VERSION)" = "glibc $baseline"
  tools="$root/build-temp/accepted-$arch/clang/bin"
  python3 "$root/scripts/package-linux.py" "$sdk" --audit-only --require-stripped \
    --machine "$machine" --glibc "$baseline" --native-dependencies --readelf "$tools/llvm-readelf"
  qmake="$sdk/bin/qmake"
fi
test "$(env -u LD_LIBRARY_PATH "$qmake" -query QT_VERSION)" = 5.15.17
bash "$root/scripts/smoke-linux.sh" "$sdk" "$work"
mkdir -p "$root/build-temp/logs"
python3 - "$artifacts" "$name" "$arch" "$variant" "$baseline" "$root/build-temp/logs" <<'PY'
import hashlib, json, os, sys
from pathlib import Path
artifacts, name, arch, variant, baseline, logs = sys.argv[1:]
def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''): result.update(block)
    return result.hexdigest()
record = dict(target=arch, variant=variant, glibc=baseline, accepted=True,
              source_run=os.environ.get('QT_VERIFY_SOURCE_RUN'),
              source_commit=os.environ.get('QT_VERIFY_SOURCE_COMMIT'),
              verifier_commit=os.environ.get('GITHUB_SHA'),
              archives={suffix: digest(Path(artifacts, name + suffix)) for suffix in ('.tar.gz', '-symbols.tar.gz')},
              checks=['ELF ABI/versions/strip', 'matching symbols/debuglink CRC', 'private C++ runtime resolution',
                      'extracted qmake C++20 consumer', 'offscreen GUI/QML/fonts/TLS runtime'])
Path(logs, 'verified-' + arch + '-' + variant + '.json').write_text(json.dumps(record, indent=2) + '\n')
PY
echo "$arch/$variant: independent extracted SDK acceptance passed"
