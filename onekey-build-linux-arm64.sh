#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QT_BUILD_TEMP="${QT_BUILD_TEMP:-"$SCRIPT_DIR/build-temp"}"
OPENSSL_ARCHIVE="$SCRIPT_DIR/openssl/openssl-1.1.1w.tar.gz"
OPENSSL_VERSION="openssl-1.1.1w"
TARGET_TAG="linux-arm64"
INSTALL_DIR="$SCRIPT_DIR/Output/linux-arm64"
OPENSSL_ROOT="$QT_BUILD_TEMP/openssl/$TARGET_TAG"
OPENSSL_WORK="$OPENSSL_ROOT/work"
OPENSSL_INSTALL_ROOT="$SCRIPT_DIR/install"
OPENSSL_INSTALL_PREFIX="$OPENSSL_INSTALL_ROOT/linux-arm64"
OPENSSL_INCLUDE="$OPENSSL_INSTALL_PREFIX/include"
OPENSSL_LIB_RELEASE="$OPENSSL_INSTALL_PREFIX/lib"
OPENSSL_SYMBOL_HIDE_FLAGS="-Wl,--exclude-libs,libssl.a:libcrypto.a"
COMMON_CFLAGS="-fPIC"
GRAPHICS_FEATURE_FLAGS=(
  -feature-xcb
  -feature-wayland-client
  -feature-wayland-server
)
export CFLAGS="$COMMON_CFLAGS"
export CXXFLAGS="$COMMON_CFLAGS"

if [[ ! -f "$OPENSSL_ARCHIVE" ]]; then
  echo "Missing OpenSSL archive at $OPENSSL_ARCHIVE" >&2
  exit 1
fi

cpu_count() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  else
    sysctl -n hw.logicalcpu
  fi
}

build_openssl() {
  local variant_root="$OPENSSL_WORK/$1"
  local config_target="$2"
  rm -rf "$variant_root"
  mkdir -p "$variant_root"
  tar -xf "$OPENSSL_ARCHIVE" -C "$variant_root"
  local src="$variant_root/$OPENSSL_VERSION"
  (
    set -e
    cd "$src"
    perl ./Configure "$config_target" no-shared
    make -j"$(cpu_count)" build_libs
    make install_sw INSTALLTOP="$OPENSSL_INSTALL_PREFIX"
  )
}

rm -rf "$OPENSSL_WORK" "$OPENSSL_INSTALL_PREFIX"
mkdir -p "$QT_BUILD_TEMP" "$OPENSSL_INSTALL_ROOT" "$INSTALL_DIR"
build_openssl release linux-aarch64
echo "OpenSSL installed to $OPENSSL_INSTALL_PREFIX"
ls "$OPENSSL_LIB_RELEASE" >/dev/null

export OPENSSL_INCDIR="$OPENSSL_INCLUDE"
export OPENSSL_LIBDIR="$OPENSSL_LIB_RELEASE"
export OPENSSL_LIBS="${OPENSSL_SYMBOL_HIDE_FLAGS} -L${OPENSSL_LIB_RELEASE} -lssl -lcrypto -ldl -lpthread"
export OPENSSL_LIBS_RELEASE="$OPENSSL_LIBS"
export PATH="$SCRIPT_DIR/qtbase/bin:$PATH"

bash ./configure \
  -prefix "$INSTALL_DIR" \
  -confirm-license \
  -opensource \
  -release \
  -force-debug-info \
  -nomake examples \
  -nomake tests \
  -openssl-linked \
  -qt-zlib \
  -qt-libpng \
  -qt-pcre \
  -qt-doubleconversion \
  -system-freetype \
  -qt-harfbuzz \
  -qt-libjpeg \
  -qt-libmd4c \
  -qt-sqlite \
  -no-zstd \
  -no-icu \
  -platform linux-g++ \
  -I "$OPENSSL_INCDIR" \
  -L "$OPENSSL_LIBDIR" \
  "${GRAPHICS_FEATURE_FLAGS[@]}"
make -j"$(cpu_count)"
make install
