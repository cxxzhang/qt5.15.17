#!/usr/bin/env bash
set -euo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
arch="${1:?architecture required}"
variant="${2:?release or debug required}"
case "$variant" in release|debug) ;; *) exit 2;; esac
tag="linux-$arch"
[[ "$variant" != debug ]] || tag+=-debug
case "$arch" in
  x64) openssl_target=linux-x86_64; machine='Advanced Micro Devices X86-64' ;;
  arm64) openssl_target=linux-aarch64; machine=AArch64 ;;
  *) echo "Unsupported target: $arch" >&2; exit 2 ;;
esac
baseline="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["targets"][sys.argv[2]]["glibc"])' "$source_dir/scripts/linux-baseline/targets.json" "$arch")"
test "$(getconf GNU_LIBC_VERSION)" = "glibc $baseline"

work="${QT_BUILD_TEMP:-$source_dir/build-temp}/$tag"
install="$source_dir/Output/$tag"
mkdir -p "$work" "$source_dir/Output"
[[ ! -e "$install" ]] || { echo "Remove or move the previous SDK: $install" >&2; exit 1; }
build="$(mktemp -d "$work/build.XXXXXXXX")"
source "$source_dir/scripts/linux-build-diagnostics.sh"
jobs="${QT_BUILD_JOBS:-$(nproc)}"
export CC="${CC:-clang}" CXX="${CXX:-clang++}"
export CFLAGS=-fPIC
# configure builds and immediately runs a bootstrap qmake. It needs the
# selected GCC runtime before the SDK's private runtime has been installed.
runtime_dir="${QT_CXX_RUNTIME_DIR:-$(dirname "$("$CXX" -print-file-name=libstdc++.so.6)")}"
[[ -f "$runtime_dir/libstdc++.so.6" ]]
export LD_LIBRARY_PATH="$runtime_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$CC" --version
getconf GNU_LIBC_VERSION
readelf="$("$CXX" -print-prog-name=llvm-readelf)"
objcopy="$("$CXX" -print-prog-name=llvm-objcopy)"
strip="$("$CXX" -print-prog-name=llvm-strip)"
for tool in "$readelf" "$objcopy" "$strip"; do
  "$tool" --version
done

tar -xf "$source_dir/openssl/openssl-1.1.1w.tar.gz" -C "$build"
ssl="$build/openssl"
(
  cd "$build/openssl-1.1.1w"
  perl ./Configure "$openssl_target" "--$variant" no-shared no-tests --prefix="$ssl" --libdir=lib
  make -j"$jobs" build_libs
  make install_dev
)
export OPENSSL_INCDIR="$ssl/include" OPENSSL_LIBDIR="$ssl/lib"
export OPENSSL_LIBS="-Wl,--exclude-libs,libssl.a:libcrypto.a -L$ssl/lib -lssl -lcrypto -ldl -lpthread"
export OPENSSL_LIBS_RELEASE="$OPENSSL_LIBS" OPENSSL_LIBS_DEBUG="$OPENSSL_LIBS"

mkdir "$build/qt"
cd "$build/qt"
bash "$source_dir/configure" -prefix "$install" -confirm-license -opensource "-$variant" \
  -c++std c++11 \
  -force-debug-info -no-strip -nomake examples -nomake tests -openssl-linked \
  -qt-zlib -qt-libpng -qt-pcre -qt-doubleconversion -system-freetype -qt-harfbuzz \
  -qt-libjpeg -qt-libmd4c -qt-sqlite -no-zstd -no-icu \
  -feature-xcb -feature-wayland-client -feature-wayland-server \
  -platform linux-clang "QMAKE_CC=$CC" "QMAKE_CXX=$CXX" "QMAKE_LFLAGS=" \
  'QMAKE_CFLAGS+=-Wno-unused-command-line-argument' 'QMAKE_CXXFLAGS+=-Wno-unused-command-line-argument' \
  -I "$OPENSSL_INCDIR" -L "$OPENSSL_LIBDIR"
make -j"$jobs"
make install

if [[ "${QT_SYSTEM_GNU_RUNTIME:-0}" != 1 ]]; then
for runtime in libstdc++.so.6 libgcc_s.so.1; do
  if [[ -n "${QT_CXX_RUNTIME_DIR:-}" ]]; then
    runtime_path="$QT_CXX_RUNTIME_DIR/$runtime"
  else
    runtime_path="$("$CXX" "-print-file-name=$runtime")"
  fi
  [[ -f "$runtime_path" ]]
  cp -L "$runtime_path" "$install/lib/$runtime"
done
fi

# Split debug information before changing the ELF segment layout. In
# particular, old objcopy cannot split some patchelf-expanded executables.
symbols="$build/symbols"
python3 "$source_dir/scripts/package-linux.py" "$install" "$symbols" \
  --machine "$machine" --glibc "$baseline" \
  --readelf "$readelf" --objcopy "$objcopy" --strip "$strip"

# Use the matching runtime after extracting the SDK to a different directory.
while IFS= read -r -d '' elf; do
  if "$readelf" -h "$elf" >/dev/null 2>&1 && patchelf --print-needed "$elf" >/dev/null 2>&1; then
    rel="$(realpath --relative-to="$(dirname "$elf")" "$install/lib")"
    patchelf --set-rpath "\$ORIGIN/$rel" "$elf"
  fi
done < <(find "$install" -type f -print0)

runtime_audit=()
if [[ "${QT_SYSTEM_GNU_RUNTIME:-0}" == 1 ]]; then
  runtime_audit=(--system-libstdcxx /usr/lib64/libstdc++.so.6 --system-libgcc /lib64/libgcc_s.so.1)
  python3 "$source_dir/scripts/audit-linux-gnu-runtime.py" "$install" \
    --libstdcxx /usr/lib64/libstdc++.so.6 --libgcc /lib64/libgcc_s.so.1 --readelf "$readelf" \
    --output "$source_dir/build-temp/logs/gnu-requirements-$arch-$variant.json"
fi
python3 "$source_dir/scripts/package-linux.py" "$install" \
  --machine "$machine" --glibc "$baseline" --native-dependencies \
  --audit-only --require-stripped --readelf "$readelf" "${runtime_audit[@]}"
name="qt5.15.17_${tag//-/_}"
tar -C "$install" -czf "$source_dir/Output/$name.tar.gz" .
tar -C "$symbols" -czf "$source_dir/Output/$name-symbols.tar.gz" .

# Verify the packaged SDK after moving it out of the configured prefix.
relocated="$build/relocated-sdk"
mkdir "$relocated"
tar -xzf "$source_dir/Output/$name.tar.gz" -C "$relocated"
python3 "$source_dir/scripts/verify-linux-symbols.py" "$relocated" "$source_dir/Output/$name-symbols.tar.gz"
[[ "$(env -u LD_LIBRARY_PATH "$relocated/bin/qmake" -query QT_VERSION)" == 5.15.17 ]]
bash "$source_dir/scripts/smoke-linux.sh" "$relocated" "$build/smoke"
