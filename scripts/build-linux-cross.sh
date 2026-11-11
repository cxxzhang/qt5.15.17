#!/usr/bin/env bash
set -euo pipefail
source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
arch="${1:?loong64 or mips64el required}"
variant="${2:?release or debug required}"
case "$variant" in release|debug) ;; *) exit 2 ;; esac
case "$arch" in
  loong64) triple=loongarch64-linux-gnu; machine=LoongArch; loader=/lib64/ld-linux-loongarch-lp64d.so.1; openssl_target=linux-generic64 ;;
  mips64el) triple=mips64el-linux-gnuabi64; machine='MIPS R3000'; loader=/lib64/ld.so.1; openssl_target=linux64-mips64 ;;
  *) echo "Unsupported cross target: $arch" >&2; exit 2 ;;
esac
prefix="$source_dir/build-temp/toolchain"
cross="$prefix/cross-$arch"
sysroot="$prefix/sysroot-$arch"
[[ -f "$cross/.ready" ]]
baseline="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["glibc"])' "$source_dir/scripts/sysroots/$arch.lock.json")"
tag="linux-$arch"
[[ "$variant" != debug ]] || tag+=-debug
install="$source_dir/Output/$tag"
work="${QT_BUILD_TEMP:-$source_dir/build-temp}/$tag"
mkdir -p "$work" "$source_dir/Output"
[[ ! -e "$install" ]] || { echo "Move the previous SDK: $install" >&2; exit 1; }
build="$(mktemp -d "$work/build.XXXXXXXX")"
source "$source_dir/scripts/linux-build-diagnostics.sh"
jobs="${QT_BUILD_JOBS:-$(nproc)}"
export PATH="$prefix/bin:$PATH"
export LD_LIBRARY_PATH="$(dirname "$(clang++ -print-file-name=libstdc++.so.6)")"
export PKG_CONFIG="$cross/bin/pkg-config"
export PKG_CONFIG_SYSROOT_DIR="$sysroot"
export PKG_CONFIG_LIBDIR="$sysroot/usr/lib/$triple/pkgconfig:$sysroot/usr/share/pkgconfig"
raw_install="$source_dir/build-temp/installed-sdk/$tag.tar"
if [[ "${QT_REUSE_INSTALL:-false}" == true && -f "$raw_install" ]]; then
  mkdir -p "$install"
  tar -xf "$raw_install" -C "$install"
  echo "Restored the configured Qt installation for packaging and runtime acceptance"
else
if [[ "$arch" == loong64 ]]; then
  patch="$source_dir/Patches/0002-qtbase-loongarch64.patch"
  if ! git -C "$source_dir/qtbase" apply --reverse --check "$patch" >/dev/null 2>&1; then
    git -C "$source_dir/qtbase" apply --check "$patch"
    git -C "$source_dir/qtbase" apply "$patch"
  fi
fi

spec="linux-clang-$arch"
mkdir -p "$source_dir/qtbase/mkspecs/$spec"
cp "$source_dir/qtbase/mkspecs/linux-clang/qplatformdefs.h" "$source_dir/qtbase/mkspecs/$spec/"
cat >"$source_dir/qtbase/mkspecs/$spec/qmake.conf" <<EOF
include(../linux-clang/qmake.conf)
QMAKE_CC = $cross/bin/clang
QMAKE_CXX = $cross/bin/clang++
QMAKE_LINK = $cross/bin/clang++
QMAKE_LINK_SHLIB = $cross/bin/clang++
QMAKE_LINK_C = $cross/bin/clang
QMAKE_LINK_C_SHLIB = $cross/bin/clang
QMAKE_AR = $prefix/llvm/bin/llvm-ar cqs
QMAKE_RANLIB = $prefix/llvm/bin/llvm-ranlib
QMAKE_STRIP = $prefix/llvm/bin/llvm-strip
QMAKE_OBJCOPY = $prefix/llvm/bin/llvm-objcopy
QMAKE_PKG_CONFIG = $cross/bin/pkg-config
QMAKE_LFLAGS =
EOF

tar -xf "$source_dir/openssl/openssl-1.1.1w.tar.gz" -C "$build"
ssl="$build/openssl"
(
  cd "$build/openssl-1.1.1w"
  export CC="$cross/bin/clang" CXX="$cross/bin/clang++" AR="$prefix/llvm/bin/llvm-ar"
  export RANLIB="$prefix/llvm/bin/llvm-ranlib" CFLAGS=-fPIC
  perl ./Configure "$openssl_target" "--$variant" no-shared no-tests no-asm --prefix="$ssl" --libdir=lib
  make -j"$jobs" build_libs
  make install_dev
)
export OPENSSL_INCDIR="$ssl/include" OPENSSL_LIBDIR="$ssl/lib"
export OPENSSL_LIBS="-Wl,--exclude-libs,libssl.a:libcrypto.a -L$ssl/lib -lssl -lcrypto -ldl -lpthread"
export OPENSSL_LIBS_RELEASE="$OPENSSL_LIBS" OPENSSL_LIBS_DEBUG="$OPENSSL_LIBS"
mkdir "$build/qt"
cd "$build/qt"
bash "$source_dir/configure" -prefix /opt/qt5.15.17 -extprefix "$install" \
  -hostprefix "$install/host" -sysroot "$sysroot" -platform linux-clang -xplatform "$spec" \
  -confirm-license -opensource "-$variant" -force-debug-info -no-strip \
  -nomake examples -nomake tests -openssl-linked -force-pkg-config \
  -qt-zlib -qt-libpng -qt-pcre -qt-doubleconversion -system-freetype -qt-harfbuzz \
  -qt-libjpeg -qt-libmd4c -qt-sqlite -no-zstd -no-icu \
  -feature-xcb -feature-wayland-client -feature-wayland-server -no-feature-qml-jit \
  -I "$OPENSSL_INCDIR" -L "$OPENSSL_LIBDIR"
make -j"$jobs"
make install
if [[ "${QT_CACHE_INSTALL:-false}" == true ]]; then
  mkdir -p "$(dirname "$raw_install")"
  tar -C "$install" -cf "$raw_install.tmp" .
  mv "$raw_install.tmp" "$raw_install"
fi
fi

mkdir -p "$install/host/lib" "$install/host/bin"
cp -L "$cross/runtime/lib/libstdc++.so.6" "$install/lib/"
cp -L "$("$cross/bin/clang" -print-file-name=libgcc_s.so.1)" "$install/lib/"
if [[ -d "$cross/dependencies/lib" ]]; then
  cp -a "$cross/dependencies/lib/." "$install/lib/"
fi
for runtime in libstdc++.so.6 libgcc_s.so.1; do
  cp -L "$(clang++ "-print-file-name=$runtime")" "$install/host/lib/$runtime"
done
cat >"$install/host/bin/qt.conf" <<EOF
[Paths]
Prefix=../..
HostPrefix=..
HostData=.
Sysroot=$sysroot
SysrootifyPrefix=false
HostSpec=linux-clang
TargetSpec=$spec
EOF
tools="$prefix/llvm/bin"
symbols="$build/symbols"
python3 "$source_dir/scripts/package-linux.py" "$install" "$symbols" \
  --machine "$machine" --glibc "$baseline" --host-machine 'Advanced Micro Devices X86-64' \
  --host-glibc 2.27 --interpreter "$loader" --readelf "$tools/llvm-readelf" \
  --objcopy "$tools/llvm-objcopy" --strip "$tools/llvm-strip"
while IFS= read -r -d '' elf; do
  if "$tools/llvm-readelf" -h "$elf" >/dev/null 2>&1 && patchelf --print-needed "$elf" >/dev/null 2>&1; then
    library_dir="$install/lib"
    [[ "$elf" != "$install/host/"* ]] || library_dir="$install/host/lib"
    rel="$(realpath --relative-to="$(dirname "$elf")" "$library_dir")"
    patchelf --set-rpath "\$ORIGIN/$rel" "$elf"
  fi
done < <(find "$install" -type f -print0)
python3 "$source_dir/scripts/package-linux.py" "$install" --audit-only --require-stripped \
  --machine "$machine" --glibc "$baseline" --host-machine 'Advanced Micro Devices X86-64' \
  --host-glibc 2.27 --interpreter "$loader" --readelf "$tools/llvm-readelf"
python3 "$source_dir/scripts/audit-linux-cross-runtime.py" "$install" --sysroot "$sysroot" \
  --qemu "$cross/bin/qemu" --loader "$loader" --readelf "$tools/llvm-readelf"
name="qt5.15.17_${tag//-/_}"
tar -C "$install" -czf "$source_dir/Output/$name.tar.gz" .
tar -C "$symbols" -czf "$source_dir/Output/$name-symbols.tar.gz" .
relocated="$build/relocated-sdk"
mkdir "$relocated"
tar -xzf "$source_dir/Output/$name.tar.gz" -C "$relocated"
[[ "$(env -u LD_LIBRARY_PATH "$relocated/host/bin/qmake" -query QT_VERSION)" == 5.15.17 ]]
QT_CROSS_QEMU="$cross/bin/qemu" QT_CROSS_SYSROOT="$sysroot" \
  CC="$cross/bin/clang" CXX="$cross/bin/clang++" \
  bash "$source_dir/scripts/smoke-linux.sh" "$relocated" "$build/smoke"
