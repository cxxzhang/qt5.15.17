#!/usr/bin/env bash
# Relocate and publish the real compiler, GNU support and target sysroot.
set -euo pipefail
arch="${1:?cross target required}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
prefix="$root/build-temp/baseline-$arch"
case "$arch" in
  loong64-oldworld)
    source "$root/scripts/linux-baseline/load-vendor-clang.sh"
    test -f "$prefix/runtime/.system-runtime"
    sysroot_rel=sysroot
    gcc_rel=sysroot/usr/lib/gcc/loongarch64-linux-gnu/8
    triple=loongarch64-linux-gnu
    target_flags='-mabi=lp64'
    linker_rel=llvm/bin/ld.lld
    qemu="$vendor_work/downloads/qemu-loongarch64"
    ;;
  loong64-newworld)
    source "$root/scripts/linux-baseline/load-upstream-clang.sh"
    test -f "$prefix/runtime/.system-runtime"
    sysroot_rel=sysroot-loong64
    gcc_rel=sysroot-loong64/usr/lib/gcc/loongarch64-linux-gnu/12
    triple=loongarch64-linux-gnu
    target_flags='-mabi=lp64d'
    linker_rel=llvm/bin/ld.lld
    qemu="$vendor_work/downloads/qemu-loongarch64"
    ;;
  mips64el)
    source "$root/scripts/linux-baseline/load-upstream-clang.sh"
    gcc="$(find -L "$prefix/gcc/bin" -name '*-gcc' -type f -print -quit)"
    triple="$("$gcc" -dumpmachine)"
    sysroot="$("$gcc" -print-sysroot)"
    sysroot_rel="${sysroot#"$prefix/"}"
    gcc_install="$(dirname "$("$gcc" -print-libgcc-file-name)")"
    gcc_rel="${gcc_install#"$prefix/"}"
    target_flags='-march=mips64r2 -mabi=64 -EL'
    linker_rel="gcc/bin/$triple-ld"
    qemu="$prefix/qemu/usr/bin/qemu-mips64el-static"
    ;;
  *) exit 2 ;;
esac
compiler_bin="$(dirname "$vendor_compiler")"
read -r baseline machine_code loader < <(python3 - "$root/scripts/linux-baseline/targets.json" "$arch" <<'PY'
import json, sys
entry = json.load(open(sys.argv[1]))['targets'][sys.argv[2]]
print(entry['glibc'], 258 if entry['machine'] == 'LoongArch' else 8,
      entry.get('interpreter', '/lib64/ld.so.1'))
PY
)
machine=LoongArch
[[ "$arch" != mips64el ]] || machine='MIPS R3000'
mkdir -p "$prefix/share/baseline" "$prefix/bin" "$root/Output/toolchains"
if [[ ! -d "$prefix/llvm" ]]; then
  cp -al "$compiler_bin/.." "$prefix/llvm"
fi
if [[ ! -e "$prefix/llvm/bin/clang" && -x "$prefix/llvm/bin/clang-20" ]]; then
  ln -s clang-20 "$prefix/llvm/bin/clang"
fi
if [[ "$arch" == loong64-oldworld ]]; then
  cp -a "$vendor_work/host-libs" "$prefix/"
fi
cp "$qemu" "$prefix/bin/qemu"
cp "$root/scripts/linux-baseline/targets.json" "$root/scripts/linux-baseline/package-cross.sh" \
  "$root/scripts/linux-baseline/prepare-loongarch-oldworld.sh" "$root/scripts/linux-baseline/probe-mips.sh" \
  "$root/scripts/linux-baseline/prepare-mips.sh" "$root/scripts/linux-baseline/load-upstream-clang.sh" \
  "$root/scripts/linux-baseline/load-vendor-clang.sh" "$prefix/share/baseline/"
if [[ "$arch" == loong64-newworld ]]; then
  cp "$root/scripts/sysroots/loong64.lock.json" "$prefix/share/baseline/"
fi
cp -a "$root/scripts/linux-baseline/llvm-licenses" "$prefix/share/baseline/"
python3 - "$prefix/host" <<'PY'
from pathlib import Path
import re, sys
host = Path(sys.argv[1])
if host.is_dir():
    for directory in (host / 'lib/pkgconfig', host / 'share/pkgconfig'):
        for path in directory.glob('*.pc'):
            text = path.read_text()
            path.write_text(re.sub(r'^prefix=.*$', 'prefix=${pcfiledir}/../..', text, flags=re.M))
PY
git -C "$root" rev-parse HEAD >"$prefix/share/baseline/source-commit.txt"
ldd "$vendor_compiler" >"$prefix/share/baseline/host-dependencies-ubuntu22.txt"
python3 - "$prefix" "$arch" "$baseline" "$sysroot_rel" "$gcc_rel" "$triple" "$loader" <<'PY'
import json, sys
from pathlib import Path
prefix, arch, glibc, sysroot, gcc, triple, loader = sys.argv[1:]
record = dict(target=arch, glibc=glibc, sysroot=sysroot, gcc_install=gcc,
              gnu_runtime_policy='baseline-system',
              triple=triple, interpreter=loader, host='Ubuntu 22.04 x86_64 (tested)',
              acceptance='Relocated Clang C++17/thread probe using the baseline GNU runtime in target chroot')
Path(prefix, 'toolchain.json').write_text(json.dumps(record, indent=2) + '\n')
PY
for name in clang clang++; do
  mode=gcc
  [[ "$name" != clang++ ]] || mode=g++
  cat >"$prefix/bin/$name" <<EOF
#!/usr/bin/env bash
prefix="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -d "\$prefix/host-libs/usr/lib/x86_64-linux-gnu" ]]; then
  export LD_LIBRARY_PATH="\$prefix/host-libs/usr/lib/x86_64-linux-gnu\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
fi
link=true
for argument in "\$@"; do
  [[ "\$argument" != -print-multi-os-directory ]] || { echo .; exit 0; }
  case "\$argument" in -c|-E|-S|-fsyntax-only|-M|-MM) link=false ;; esac
done
extra=()
if [[ "$name" == clang++ ]]; then
  extra=(-fno-sized-deallocation -fno-aligned-allocation)
fi
if [[ "$arch" == mips64el ]] && "\$link"; then
  extra+=(-L"\$prefix/$sysroot_rel/usr/lib/mips64el-linux-gnuabi64" \
    -L"\$prefix/$sysroot_rel/lib/mips64el-linux-gnuabi64" \
    -Wl,-rpath-link,"\$prefix/$sysroot_rel/usr/lib/mips64el-linux-gnuabi64" \
    -Wl,-rpath-link,"\$prefix/$sysroot_rel/lib/mips64el-linux-gnuabi64")
fi
if "\$link"; then
  extra+=(-Wl,-rpath-link,"\$prefix/$sysroot_rel/lib/$triple" \
    -Wl,-rpath-link,"\$prefix/$sysroot_rel/usr/lib/$triple")
fi
exec "\$prefix/llvm/bin/clang" --driver-mode="$mode" --target="$triple" $target_flags \
  --sysroot="\$prefix/$sysroot_rel" --gcc-install-dir="\$prefix/$gcc_rel" \
  --ld-path="\$prefix/$linker_rel" -Wno-unused-command-line-argument \
  "\${extra[@]}" "\$@"
EOF
  chmod +x "$prefix/bin/$name"
done
cat >"$prefix/bin/pkg-config" <<EOF
#!/usr/bin/env bash
prefix="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
export PKG_CONFIG_SYSROOT_DIR="\$prefix/$sysroot_rel"
export PKG_CONFIG_LIBDIR="\$prefix/$sysroot_rel/usr/lib/$triple/pkgconfig:\$prefix/$sysroot_rel/usr/lib64/pkgconfig:\$prefix/$sysroot_rel/usr/lib/pkgconfig:\$prefix/$sysroot_rel/usr/share/pkgconfig"
export PKG_CONFIG_PATH="\$prefix/host/lib/pkgconfig:\$prefix/host/share/pkgconfig"
if [[ "$arch" == mips64el ]]; then
  export PKG_CONFIG_LIBDIR="\$prefix/$sysroot_rel/usr/lib/mips64el-linux-gnuabi64/pkgconfig:\$PKG_CONFIG_LIBDIR"
fi
exec /usr/bin/pkg-config "\$@"
EOF
chmod +x "$prefix/bin/pkg-config"
if [[ -f "$prefix/share/baseline/graphics-glibc-audit.json" ]]; then
  "$prefix/bin/pkg-config" --exists freetype2 fontconfig x11 xcb xkbcommon wayland-client wayland-server
fi
relocated="$(mktemp -d "$root/build-temp/relocated-$arch.XXXXXXXX")"
trap 'if [[ -d "$relocated/toolchain" && ! -e "$prefix" ]]; then mv "$relocated/toolchain" "$prefix"; fi; rmdir "$relocated"' EXIT
mv "$prefix" "$relocated/toolchain"
rel="$relocated/toolchain"
env -u LD_LIBRARY_PATH "$rel/bin/clang++" -std=c++17 -pthread "$rel/probe.cpp" \
  '-Wl,-rpath,$ORIGIN/../lib' -o "$rel/probe-sdk/bin/probe"
if [[ "$arch" == mips64el ]]; then
  env -u LD_LIBRARY_PATH "$rel/gcc/bin/$triple-g++" --sysroot="$rel/$sysroot_rel" \
    -std=c++11 -pthread "$rel/probe.cpp" '-Wl,-rpath,$ORIGIN/../lib' \
    -o "$rel/probe-sdk/bin/gcc-probe"
fi
python3 "$root/scripts/package-linux.py" "$rel/probe-sdk" --audit-only \
  --machine "$machine" --glibc "$baseline" --interpreter "$loader" --readelf "$rel/llvm/bin/llvm-readelf"
sudo python3 "$root/scripts/audit-linux-cross-runtime.py" "$rel/probe-sdk" \
  --sysroot "$rel/$sysroot_rel" --qemu "$rel/bin/qemu" --loader "$loader" --readelf "$rel/llvm/bin/llvm-readelf"
sudo env PYTHONPATH="$root/scripts" python3 - "$rel" "$sysroot_rel" <<'PY'
from pathlib import Path
import sys
from linux_cross_runtime import TargetRoot
prefix = Path(sys.argv[1])
target = TargetRoot(prefix / sys.argv[2], prefix / 'bin/qemu', prefix / 'probe-sdk')
sdk = target.stage_sdk(prefix / 'probe-sdk')
target.execute(sdk / 'bin/probe')
if (sdk / 'bin/gcc-probe').is_file():
    target.execute(sdk / 'bin/gcc-probe')
PY
mv "$rel" "$prefix"
rmdir "$relocated"
trap - EXIT
name="toolchain-linux-$arch-glibc${baseline//./}.tar.xz"
XZ_OPT='-T2 -3' tar -C "$prefix" --exclude=./graphics-inputs --exclude=./downloads \
  --exclude=./qemu -cJf "$root/Output/toolchains/$name" .
(cd "$root/Output/toolchains" && sha256sum "$name" >"$name.sha256")
echo "$arch: compiler, GNU support and sysroot relocated, compiled, audited and executed; bundle ready"
