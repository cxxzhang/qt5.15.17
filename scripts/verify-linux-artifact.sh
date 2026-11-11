#!/usr/bin/env bash
# Run in a new Ubuntu 18.04 container with artifacts and compiler caches only.
set -euo pipefail
arch="${1:?architecture required}"
variant="${2:?release or debug required}"
artifacts="${3:?artifact directory required}"
case "$variant" in release|debug) ;; *) exit 2 ;; esac
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host_arch=x64
cross=false
case "$arch" in
  x64) machine='Advanced Micro Devices X86-64'; baseline=2.27 ;;
  arm64) host_arch=arm64; machine=AArch64; baseline=2.27 ;;
  loong64) cross=true; machine=LoongArch; loader=/lib64/ld-linux-loongarch-lp64d.so.1 ;;
  mips64el) cross=true; machine='MIPS R3000'; loader=/lib64/ld.so.1 ;;
  *) exit 2 ;;
esac
bash "$root/scripts/setup-linux-toolchain.sh" "$host_arch"
prefix="$root/build-temp/toolchain"
export PATH="$prefix/bin:$PATH"
if "$cross"; then
  bash "$root/scripts/setup-cross-linux-toolchain.sh" "$arch"
  baseline="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["glibc"])' "$root/scripts/sysroots/$arch.lock.json")"
fi
tag="qt5.15.17_linux_$arch"
[[ "$variant" != debug ]] || tag+=_debug
test ! -e "$root/Output/linux-$arch"
test ! -e "$root/Output/linux-$arch-debug"
sdk=/opt/extracted-sdk
mkdir "$sdk"
tar -xzf "$artifacts/$tag.tar.gz" -C "$sdk"
tar -tzf "$artifacts/$tag-symbols.tar.gz" >/tmp/debug-files
grep -q '\.debug$' /tmp/debug-files
audit=(python3 "$root/scripts/package-linux.py" "$sdk" --audit-only --require-stripped
       --machine "$machine" --glibc "$baseline")
if "$cross"; then
  "${audit[@]}" --host-machine 'Advanced Micro Devices X86-64' --host-glibc 2.27 \
    --interpreter "$loader" --readelf "$prefix/llvm/bin/llvm-readelf"
  python3 "$root/scripts/audit-linux-cross-runtime.py" "$sdk" \
    --sysroot "$prefix/sysroot-$arch" --qemu "$prefix/cross-$arch/bin/qemu" \
    --loader "$loader" --readelf "$prefix/llvm/bin/llvm-readelf"
  qmake="$sdk/host/bin/qmake"
  export CC="$prefix/cross-$arch/bin/clang" CXX="$prefix/cross-$arch/bin/clang++"
  export QT_CROSS_QEMU="$prefix/cross-$arch/bin/qemu" QT_CROSS_SYSROOT="$prefix/sysroot-$arch"
else
  "${audit[@]}" --native-dependencies
  qmake="$sdk/bin/qmake"
fi
test "$(env -u LD_LIBRARY_PATH "$qmake" -query QT_VERSION)" = 5.15.17
bash "$root/scripts/smoke-linux.sh" "$sdk" /tmp/sdk-consumer
