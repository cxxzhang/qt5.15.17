#!/usr/bin/env bash
# Relocate and package only the actually validated old-world 2.28 toolchain.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
prefix="$root/build-temp/baseline-loong64-oldworld"
source "$root/scripts/linux-baseline/load-vendor-clang.sh"
test -f "$prefix/runtime/.symvers-gnu"
mkdir -p "$prefix/share/baseline" "$prefix/bin" "$root/Output/toolchains"
if [[ ! -d "$prefix/llvm" ]]; then
  cp -a "$(dirname "$vendor_compiler")/.." "$prefix/llvm"
fi
cp -a "$vendor_work/host-libs" "$prefix/"
cp -a "$root/scripts/linux-baseline/llvm-licenses" "$prefix/share/baseline/"
cp "$root/scripts/linux-baseline/targets.json" \
  "$root/scripts/linux-baseline/prepare-loongarch-oldworld.sh" \
  "$root/scripts/linux-baseline/package-loongarch-oldworld.sh" \
  "$root/scripts/linux-baseline/load-vendor-clang.sh" "$prefix/share/baseline/"
cp "$vendor_work/downloads/qemu-loongarch64" "$prefix/bin/qemu"
git -C "$root" rev-parse HEAD >"$prefix/share/baseline/source-commit.txt"
ldd "$vendor_compiler" >"$prefix/share/baseline/host-dependencies-ubuntu22.txt"
cat >"$prefix/share/baseline/README.txt" <<'EOF'
Target: LoongArch old world, ELF flags 0x3, glibc 2.28, /lib64/ld.so.1.
Qt/consumer compiler: vendor Clang 20.1.8; private libstdc++ 13.3.0.
The original sysroot includes vendor GCC 8 GNU CRT/libgcc/header support.
It is not a full GCC 13 compiler installation. libstdc++ 13.3 is built by
Clang against those real baseline headers and libraries.
Host tested: Ubuntu 22.04 x86_64. libffi6 is private; other host dependencies
are recorded in host-dependencies-ubuntu22.txt. This cross toolchain is not
declared to run on a glibc 2.17 host. Set PATH to the extracted bin directory.
EOF
for name in clang clang++; do
  mode=gcc
  [[ "$name" != clang++ ]] || mode=g++
  cat >"$prefix/bin/$name" <<EOF
#!/usr/bin/env bash
prefix="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
export LD_LIBRARY_PATH="\$prefix/host-libs/usr/lib/x86_64-linux-gnu\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
for argument in "\$@"; do
  [[ "\$argument" != -print-multi-os-directory ]] || { echo .; exit 0; }
done
extra=()
if [[ "$name" == clang++ ]]; then
  extra=(-nostdinc++ -isystem "\$prefix/runtime/include/c++/13.3.0" \
    -isystem "\$prefix/runtime/include/c++/13.3.0/loongarch64-linux-gnu" -L"\$prefix/runtime/lib")
fi
exec "\$prefix/llvm/bin/clang-20" --driver-mode="$mode" --target=loongarch64-linux-gnu \
  -mabi=lp64 --sysroot="\$prefix/sysroot" \
  --gcc-install-dir="\$prefix/sysroot/usr/lib/gcc/loongarch64-linux-gnu/8" \
  --ld-path="\$prefix/llvm/bin/ld.lld" -Wno-unused-command-line-argument \
  -Wl,-rpath-link,"\$prefix/sysroot/lib/loongarch64-linux-gnu" \
  -Wl,-rpath-link,"\$prefix/sysroot/usr/lib/loongarch64-linux-gnu" "\${extra[@]}" "\$@"
EOF
  chmod +x "$prefix/bin/$name"
done
cat >"$prefix/bin/pkg-config" <<'EOF'
#!/usr/bin/env bash
prefix="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PKG_CONFIG_SYSROOT_DIR="$prefix/sysroot"
export PKG_CONFIG_LIBDIR="$prefix/sysroot/usr/lib/loongarch64-linux-gnu/pkgconfig:$prefix/sysroot/usr/share/pkgconfig"
unset PKG_CONFIG_PATH
exec /usr/bin/pkg-config "$@"
EOF
chmod +x "$prefix/bin/pkg-config"
relocated="$(mktemp -d "$root/build-temp/relocated-loong-oldworld.XXXXXXXX")"
trap 'if [[ -d "$relocated/toolchain" && ! -e "$prefix" ]]; then mv "$relocated/toolchain" "$prefix"; fi; rmdir "$relocated"' EXIT
mv "$prefix" "$relocated/toolchain"
rel="$relocated/toolchain"
env -u LD_LIBRARY_PATH "$rel/bin/clang++" -std=c++20 -pthread "$rel/probe.cpp" \
  '-Wl,-rpath,$ORIGIN/../lib' -o "$rel/probe-sdk/bin/probe"
python3 "$root/scripts/package-linux.py" "$rel/probe-sdk" --audit-only \
  --machine LoongArch --glibc 2.28 --interpreter /lib64/ld.so.1
sudo python3 "$root/scripts/audit-linux-cross-runtime.py" "$rel/probe-sdk" \
  --sysroot "$rel/sysroot" --qemu "$rel/bin/qemu" --loader /lib64/ld.so.1
sudo env PYTHONPATH="$root/scripts" python3 - "$rel" <<'PY'
from pathlib import Path
import sys
from linux_cross_runtime import TargetRoot
prefix = Path(sys.argv[1])
target = TargetRoot(prefix / 'sysroot', prefix / 'bin/qemu', prefix / 'probe-sdk')
sdk = target.stage_sdk(prefix / 'probe-sdk')
target.execute(sdk / 'bin/probe')
PY
mv "$rel" "$prefix"
rmdir "$relocated"
trap - EXIT
name=toolchain-linux-loong64-oldworld-glibc228.tar.xz
tar -C "$prefix" -cJf "$root/Output/toolchains/$name" .
(cd "$root/Output/toolchains" && sha256sum "$name" >"$name.sha256")
echo 'Old-world Clang/libstdc++/sysroot relocated, compiled, audited and executed; bundle ready'
