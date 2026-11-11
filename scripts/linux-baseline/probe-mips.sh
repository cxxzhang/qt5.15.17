#!/usr/bin/env bash
# Validate Clang against the source-built n64/glibc 2.17 GNU toolchain.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
prefix="$root/build-temp/baseline-mips64el"
sudo apt-get -o Acquire::Retries=5 update
sudo apt-get -o Acquire::Retries=5 install -y --no-install-recommends patchelf libtinfo5 libxml2
# The vendor LLVM 20 emitted invalid local CALL16 coroutine relocations on
# MIPS at -O0. Use upstream LLVM 18, which also includes the required backend.
source "$root/scripts/linux-baseline/load-upstream-clang.sh"
gcc="$(find -L "$prefix/gcc/bin" -name '*-gcc' -type f -print -quit)"
test -x "$gcc"
triple="$("$gcc" -dumpmachine)"
sysroot="$("$gcc" -print-sysroot)"
gcc_install="$(dirname "$("$gcc" -print-libgcc-file-name)")"
mkdir -p "$prefix/bin" "$prefix/probe-sdk/bin" "$prefix/probe-sdk/lib"
for name in clang clang++; do
  cat >"$prefix/bin/$name" <<EOF
#!/usr/bin/env bash
exec "$vendor_compiler" --driver-mode="$([[ "$name" == clang++ ]] && echo g++ || echo gcc)" \
  --target="$triple" -march=mips64r2 -mabi=64 -EL --sysroot="$sysroot" \
  -fno-sized-deallocation -fno-aligned-allocation \
  --gcc-install-dir="$gcc_install" --ld-path="$prefix/gcc/bin/$triple-ld" "\$@"
EOF
  chmod +x "$prefix/bin/$name"
done
stdlib="$("${gcc%gcc}g++" -print-file-name=libstdc++.so.6)"
libgcc="$("$gcc" -print-file-name=libgcc_s.so.1)"
cp -L "$stdlib" "$prefix/probe-sdk/lib/libstdc++.so.6"
cp -L "$libgcc" "$prefix/probe-sdk/lib/libgcc_s.so.1"
patchelf --set-rpath '$ORIGIN' "$prefix/probe-sdk/lib/libstdc++.so.6"
patchelf --set-rpath '$ORIGIN' "$prefix/probe-sdk/lib/libgcc_s.so.1"
cp "$root/scripts/linux-baseline/probe.cpp" "$prefix/probe.cpp"
"$prefix/bin/clang++" -std=c++17 -pthread "$prefix/probe.cpp" \
  '-Wl,-rpath,$ORIGIN/lib' -o "$prefix/probe-sdk/bin/probe"
python3 "$root/scripts/package-linux.py" "$prefix/probe-sdk" --audit-only \
  --machine 'MIPS R3000' --glibc 2.17 --interpreter /lib64/ld.so.1
python3 "$root/scripts/audit-linux-gnu-runtime.py" "$prefix/probe-sdk" \
  --libstdcxx "$stdlib" --libgcc "$libgcc" --readelf "$(dirname "$vendor_compiler")/llvm-readelf" \
  --output "$root/build-temp/logs/mips-system-gnu-probe.json"
qemu_deb="$root/build-temp/baseline-downloads/mips-qemu.deb"
if [[ ! -f "$qemu_deb" ]]; then
  curl -fsSL --retry 5 -H 'Accept: application/octet-stream' \
    -H "Authorization: Bearer ${GITHUB_TOKEN:?}" \
    https://api.github.com/repos/YooDesk/desk/releases/assets/730044611 -o "$qemu_deb"
fi
echo "83ad62bfe0e28a5645cb6a40d8b99e7a629fdac9e1a9cea9949d1c59a01322c7  $qemu_deb" | sha256sum -c -
mkdir -p "$prefix/qemu"
dpkg-deb -x "$qemu_deb" "$prefix/qemu"
sudo -E python3 "$root/scripts/linux_cross_runtime.py" probe "$sysroot" \
  "$prefix/qemu/usr/bin/qemu-mips64el-static" "$prefix/probe-sdk/bin/probe" \
  --loader /lib64/ld.so.1 --stdlib "$prefix/probe-sdk/lib/libstdc++.so.6" \
  --libgcc "$prefix/probe-sdk/lib/libgcc_s.so.1"
