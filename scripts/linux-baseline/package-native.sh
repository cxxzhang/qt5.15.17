#!/usr/bin/env bash
# Package a reusable native toolchain only after its glibc 2.17 probes pass.
set -euo pipefail
arch="${1:?x64 or arm64 required}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
prefix="$root/build-temp/baseline-$arch"
out="$root/Output/toolchains"
mkdir -p "$prefix/sysroot" "$prefix/share/baseline" "$out"
test "$(getconf GNU_LIBC_VERSION)" = 'glibc 2.17'
test -f "$prefix/gcc/.ready"
# Snapshot real baseline headers, startup objects, linker scripts and glibc.
# rpm enumerates the package files so /usr/lib64 from unrelated packages
# cannot accidentally become part of this target sysroot.
rpm -q glibc glibc-devel glibc-headers kernel-headers >"$prefix/share/baseline/sysroot-rpms.txt"
rpm -ql glibc glibc-devel glibc-headers kernel-headers \
  | sed 's|^/||' | sort -u >"$prefix/share/baseline/sysroot-files.txt"
python3 - "$prefix/share/baseline/sysroot-files.txt" <<'PY'
from pathlib import Path
import sys
listing = Path(sys.argv[1])
paths = listing.read_text().splitlines()
# manylinux strips RPM documentation while retaining the RPM database.
# Record that omission, and snapshot only paths that actually exist.
present = [p for p in paths if (Path('/') / p).exists() or (Path('/') / p).is_symlink()]
listing.with_name('sysroot-omitted-rpm-files.txt').write_text('\n'.join(p for p in paths if p not in present) + '\n')
listing.write_text('\n'.join(present) + '\n')
PY
tar -C / --no-recursion -cf - -T "$prefix/share/baseline/sysroot-files.txt" \
  | tar -C "$prefix/sysroot" -xf -
test -f "$prefix/sysroot/usr/include/features.h"
test -e "$prefix/sysroot/lib64/libc.so.6"
test -f "$prefix/sysroot/usr/lib64/Scrt1.o"
cp -a "$root/scripts/linux-baseline/glibc-licenses" "$prefix/share/baseline/"
cp "$root/scripts/linux-baseline/targets.json" "$prefix/share/baseline/"
cp -a "$root/scripts/linux-baseline/llvm-licenses" "$prefix/share/baseline/"
git -c safe.directory="$root" -C "$root" rev-parse HEAD >"$prefix/share/baseline/source-commit.txt"
cp "$root/scripts/linux-baseline/prepare-native.sh" "$root/scripts/linux-baseline/probe-mixed-cxx.sh" \
  "$root/scripts/linux-baseline/package-native.sh" "$prefix/share/baseline/"
cp "$root/build-temp/logs/$arch-image.txt" "$prefix/share/baseline/"
gcc_triple="$("$prefix/gcc/bin/gcc" -dumpmachine)"
# GCC host tools were built by the container compiler and also need private
# GNU runtime resolution when used outside that container's devtoolset PATH.
python3 - "$prefix/gcc" <<'PY'
import os, subprocess, sys
from pathlib import Path
gcc = Path(sys.argv[1])
runtime = Path(subprocess.check_output([str(gcc / 'bin/g++'), '-print-file-name=libstdc++.so.6'], text=True).strip()).resolve().parent
for path in gcc.rglob('*'):
    if not path.is_file() or path.is_symlink(): continue
    with path.open('rb') as stream:
        if stream.read(4) != b'\x7fELF': continue
    result = subprocess.run(['patchelf', '--print-needed', str(path)], capture_output=True, text=True)
    if result.returncode: continue
    subprocess.check_call(['patchelf', '--set-rpath', '$ORIGIN/' + os.path.relpath(runtime, path.parent), str(path)])
PY
for name in clang clang++; do
  cat >"$prefix/bin/$name" <<EOF
#!/usr/bin/env bash
prefix="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
for argument in "\$@"; do
  [[ "\$argument" != -print-multi-os-directory ]] || { echo .; exit 0; }
done
exec "\$prefix/clang/bin/$name" --target="$gcc_triple" --sysroot="\$prefix/sysroot" \
  --gcc-install-dir="\$prefix/gcc/lib/gcc/$gcc_triple/13.3.0" -fuse-ld=lld \
  -B"\$prefix/sysroot/usr/lib64/" -L"\$prefix/gcc/lib64" \
  -L"\$prefix/sysroot/usr/lib64" -L"\$prefix/sysroot/lib64" \
  -Wl,-rpath-link,"\$prefix/sysroot/lib64" "\$@"
EOF
  chmod +x "$prefix/bin/$name"
done
machine="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["targets"][sys.argv[2]]["machine"])' "$root/scripts/linux-baseline/targets.json" "$arch")"
python3 "$root/scripts/package-linux.py" "$prefix/gcc" --audit-only \
  --machine "$machine" --glibc 2.17 --readelf "$prefix/clang/bin/llvm-readelf"
# Move the whole directory to prove the compiler, GNU search paths, target
# sysroot and runtime work without the original configured prefix.
relocated="$(mktemp -d "$root/build-temp/relocated-$arch.XXXXXXXX")"
trap 'if [[ -d "$relocated/toolchain" && ! -e "$prefix" ]]; then mv "$relocated/toolchain" "$prefix"; fi; rmdir "$relocated"' EXIT
mv "$prefix" "$relocated/toolchain"
rel="$relocated/toolchain"
"$rel/bin/clang++" -std=c++20 -pthread "$rel/probe.cpp" \
  '-Wl,-rpath,$ORIGIN/../lib' -o "$rel/probe-sdk/bin/probe"
env -u LD_LIBRARY_PATH -u LD_PRELOAD "$rel/probe-sdk/bin/probe"
bash "$root/scripts/linux-baseline/probe-mixed-cxx.sh" "$rel"
python3 "$root/scripts/package-linux.py" "$rel/probe-sdk" --audit-only \
  --machine "$machine" --glibc 2.17 --native-dependencies --readelf "$rel/clang/bin/llvm-readelf"
env -u LD_LIBRARY_PATH -u LD_PRELOAD "$rel/gcc/bin/g++" --sysroot="$rel/sysroot" -std=c++20 -pthread "$rel/probe.cpp" \
  -B"$rel/sysroot/usr/lib64/" -L"$rel/gcc/lib64" \
  -L"$rel/sysroot/usr/lib64" -L"$rel/sysroot/lib64" \
  '-Wl,-rpath,$ORIGIN/../lib' -o "$rel/probe-sdk/bin/gcc-probe"
env -u LD_LIBRARY_PATH -u LD_PRELOAD "$rel/probe-sdk/bin/gcc-probe"
mv "$rel" "$prefix"
rmdir "$relocated"
trap - EXIT
archive="toolchain-linux-$arch-glibc217.tar.xz"
XZ_OPT='-T2 -3' tar -C "$prefix" -cJf "$out/$archive" .
(cd "$out" && sha256sum "$archive" >"$archive.sha256")
echo "$arch: relocated Clang/GCC/sysroot and both private C++ ABI probes passed; packaged $archive"
