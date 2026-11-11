#!/usr/bin/env bash
# Reuse the original GNU headers/runtime of each real LoongArch sysroot.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
world="${1:-oldworld}"
case "$world" in oldworld|newworld) ;; *) exit 2 ;; esac
prefix="$root/build-temp/baseline-loong64-$world"
mkdir -p "$prefix/bin" "$root/build-temp/logs"
if [[ "$world" == oldworld ]]; then
source "$root/scripts/linux-baseline/load-vendor-clang.sh"
vendor_fetch sysroot.tar.bz2 https://ftp.loongnix.cn/browser/build/sysroot/debian_bullseye_loong64-sysroot.tar.bz2 34efb077fed691feac2605ec9656c8ecb40e63076fdb76ae06df90f279099a64
if [[ ! -d "$prefix/sysroot" ]]; then
  tar -xf "$vendor_work/downloads/sysroot.tar.bz2" -C "$prefix"
  mv "$prefix/debian_bullseye_loong64-sysroot" "$prefix/sysroot"
fi
sysroot="$prefix/sysroot"
gcc_install="$sysroot/usr/lib/gcc/loongarch64-linux-gnu/8"
abi=lp64
else
source "$root/scripts/linux-baseline/load-upstream-clang.sh"
python3 "$root/scripts/prepare-linux-sysroot.py" "$root/scripts/sysroots/loong64.lock.json" "$prefix"
sysroot="$prefix/sysroot-loong64"
gcc_install="$sysroot/usr/lib/gcc/loongarch64-linux-gnu/12"
abi=lp64d
fi
read -r baseline loader elf_flags < <(python3 - "$root/scripts/linux-baseline/targets.json" "$world" <<'PY'
import json, sys
entry = json.load(open(sys.argv[1]))['targets']['loong64-' + sys.argv[2]]
print(entry['glibc'], entry['interpreter'], entry['elf_flags'])
PY
)
test -f "$gcc_install/crtbegin.o"
touch "$sysroot/.sysroot-loong64-$world-$baseline"
compiler_bin="$(dirname "$vendor_compiler")"
write_driver() {
  local name="$1"
  cat >"$prefix/bin/$name" <<EOF
#!/usr/bin/env bash
for argument in "\$@"; do
  [[ "\$argument" != -print-multi-os-directory ]] || { echo .; exit 0; }
done
extra=()
exec "$vendor_compiler" --driver-mode="$([[ "$name" == clang++ ]] && echo g++ || echo gcc)" \
  --target=loongarch64-linux-gnu -mabi="$abi" --sysroot="$sysroot" \
  -fno-sized-deallocation -fno-aligned-allocation \
  --gcc-install-dir="$gcc_install" --ld-path="$compiler_bin/ld.lld" -Wno-unused-command-line-argument \
  -Wl,-rpath-link,"$sysroot/lib/loongarch64-linux-gnu" \
  -Wl,-rpath-link,"$sysroot/usr/lib/loongarch64-linux-gnu" \${extra[@]+"\${extra[@]}"} "\$@"
EOF
  chmod +x "$prefix/bin/$name"
}
write_driver clang
write_driver clang++
cat >"$prefix/bin/pkg-config" <<EOF
#!/usr/bin/env bash
export PKG_CONFIG_SYSROOT_DIR="$sysroot"
export PKG_CONFIG_LIBDIR="$sysroot/usr/lib/loongarch64-linux-gnu/pkgconfig:$sysroot/usr/share/pkgconfig"
export PKG_CONFIG_PATH="$prefix/host/lib/pkgconfig:$prefix/host/share/pkgconfig"
exec /usr/bin/pkg-config "\$@"
EOF
chmod +x "$prefix/bin/pkg-config"
mkdir -p "$prefix/share" "$prefix/runtime/lib" "$prefix/probe-sdk/bin" "$prefix/probe-sdk/lib"
cp /usr/share/misc/config.sub /usr/share/misc/config.guess "$prefix/share/"
bash "$prefix/share/config.sub" loongarch64-linux-gnu
# Only select regular target runtime files. Absolute vendor symlinks must
# never resolve to the x86_64 host's libraries.
stdlib="$(find "$sysroot" -type f -name 'libstdc++.so.6*' -print -quit)"
libgcc="$(find "$sysroot" -type f -name libgcc_s.so.1 -print -quit)"
test -n "$stdlib"
test -n "$libgcc"
cp "$stdlib" "$prefix/runtime/lib/libstdc++.so.6"
cp "$libgcc" "$prefix/runtime/lib/libgcc_s.so.1"
touch "$prefix/runtime/.system-runtime"
"$compiler_bin/llvm-readelf" -V "$stdlib" >"$root/build-temp/logs/loong-$world-libstdcxx-versions.txt"
cp "$stdlib" "$prefix/probe-sdk/lib/libstdc++.so.6"
cp "$libgcc" "$prefix/probe-sdk/lib/libgcc_s.so.1"
patchelf --set-rpath '$ORIGIN' "$prefix/probe-sdk/lib/libstdc++.so.6"
patchelf --set-rpath '$ORIGIN' "$prefix/probe-sdk/lib/libgcc_s.so.1"
cp "$root/scripts/linux-baseline/probe.cpp" "$prefix/probe.cpp"
"$prefix/bin/clang++" -std=c++17 -pthread "$prefix/probe.cpp" \
  '-Wl,-rpath,$ORIGIN/../lib' -o "$prefix/probe-sdk/bin/probe"
python3 "$root/scripts/package-linux.py" "$prefix/probe-sdk" --audit-only \
  --machine LoongArch --glibc "$baseline" --interpreter "$loader" --readelf "$compiler_bin/llvm-readelf" \
  --elf-flags "$elf_flags"
python3 "$root/scripts/audit-linux-gnu-runtime.py" "$prefix/probe-sdk" \
  --libstdcxx "$stdlib" --libgcc "$libgcc" --readelf "$compiler_bin/llvm-readelf" \
  --output "$root/build-temp/logs/loong-$world-system-gnu-probe.json"
qemu="$vendor_work/downloads/qemu-loongarch64"
if [[ ! -f "$qemu" ]]; then
  curl -fsSL --retry 5 -H 'Accept: application/octet-stream' \
    -H "Authorization: Bearer ${GITHUB_TOKEN:?}" \
    https://api.github.com/repos/loongson/build-tools/releases/assets/231245278 -o "$qemu"
fi
echo "794d606a2af4f6277518260eb803f8021e1a5891609fe0c52ef66f18e3e4e265  $qemu" | sha256sum -c -
chmod +x "$qemu"
sudo -E python3 "$root/scripts/linux_cross_runtime.py" probe "$sysroot" "$qemu" \
  "$prefix/probe-sdk/bin/probe" --loader "$loader" \
  --stdlib "$prefix/probe-sdk/lib/libstdc++.so.6" --libgcc "$prefix/probe-sdk/lib/libgcc_s.so.1"
