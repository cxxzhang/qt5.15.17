#!/usr/bin/env bash
set -euo pipefail

arch="${1:?architecture required}"
export DEBIAN_FRONTEND=noninteractive
sed -i 's|http://archive.ubuntu.com/ubuntu|http://azure.archive.ubuntu.com/ubuntu|g; s|http://security.ubuntu.com/ubuntu|http://azure.archive.ubuntu.com/ubuntu|g' /etc/apt/sources.list
apt-get -o Acquire::Retries=5 update
apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
  build-essential binutils ca-certificates curl file git perl python3 python3-pip \
  xz-utils pkg-config patchelf ninja-build libxml2 libtinfo5 \
  libgmp-dev libmpfr-dev libmpc-dev libisl-dev \
  libgl1-mesa-dev libegl1-mesa-dev libgles2-mesa-dev libglu1-mesa-dev \
  libfontconfig1-dev libfreetype6-dev libdbus-1-dev libdrm-dev libx11-dev libx11-xcb-dev \
  libxcb1-dev libxcb-glx0-dev libxcb-render0-dev libxcb-render-util0-dev libxcb-shape0-dev \
  libxcb-xfixes0-dev libxcb-image0-dev libxcb-icccm4-dev libxcb-keysyms1-dev libxcb-randr0-dev \
  libxcb-sync-dev libxcb-xinerama0-dev libxcb-xkb-dev libxcb-shm0-dev libxcb-present-dev \
  libxcb-dri3-dev libxcb-util0-dev libxkbcommon-dev libxkbcommon-x11-dev \
  libwayland-dev wayland-protocols

prefix="$PWD/build-temp/toolchain"
mkdir -p "$prefix/bin"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
jobs="$(nproc)"
(( jobs <= 4 )) || jobs=4
pins="$PWD/scripts/linux-toolchain.lock.json"
fetch() {
  local key="$1" output="$2" url checksum
  read -r url checksum < <(python3 - "$pins" "$key" <<'PY'
import json, sys
entry = json.load(open(sys.argv[1]))[sys.argv[2]]
print(entry.get("api_url", entry["url"]), entry["sha256"])
PY
  )
  local headers=()
  if [[ "$url" == https://api.github.com/* ]]; then
    headers+=(-H 'Accept: application/octet-stream')
    [[ -z "${GITHUB_TOKEN:-}" ]] || headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  curl --fail --location --retry 5 --connect-timeout 30 "${headers[@]}" --output "$output" "$url"
  echo "$checksum  $output" | sha256sum -c -
}

if [[ ! -f "$prefix/gcc/.ready" ]] || [[ "$("$prefix/gcc/bin/gcc" -dumpfullversion)" != 13.3.0 ]]; then
  fetch gcc_source "$work/gcc.tar.xz"
  tar -xf "$work/gcc.tar.xz" -C "$work"
  mkdir "$work/gcc-build"
  (
    cd "$work/gcc-build"
    "$work/gcc-13.3.0/configure" --prefix="$prefix/gcc" --disable-bootstrap \
      --disable-multilib --disable-libsanitizer --disable-libquadmath \
      --disable-libgomp --disable-libssp --disable-libvtv --enable-languages=c,c++
    make -j"$jobs"
    make install
  )
  touch "$prefix/gcc/.ready"
fi

if [[ ! -f "$prefix/llvm/.ready" || ! -x "$prefix/llvm/bin/llvm-readelf" \
      || ! -x "$prefix/llvm/bin/llvm-objcopy" || ! -x "$prefix/llvm/bin/llvm-strip" ]] \
   || ! "$prefix/llvm/bin/clang" --version | head -n1 | grep -q '18\.1\.8'; then
  mkdir -p "$prefix/llvm"
  if [[ "$arch" == x64 ]]; then
    fetch llvm_x64 "$work/llvm.tar.xz"
    tar -xf "$work/llvm.tar.xz" -C "$prefix/llvm" --strip-components=1
  else
    # Build against Bionic rather than assuming the upstream ARM64 binary
    # can run with this container's glibc.
    fetch cmake_arm64 "$work/cmake.tar.gz"
    tar -xf "$work/cmake.tar.gz" -C "$work"
    export PATH="$work/cmake-3.27.9-linux-aarch64/bin:$PATH"
    fetch llvm_source "$work/llvm.tar.xz"
    tar -xf "$work/llvm.tar.xz" -C "$work"
    cmake -S "$work/llvm-project-18.1.8.src/llvm" -B "$work/llvm-build" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix/llvm" \
      -DLLVM_ENABLE_PROJECTS=clang -DLLVM_TARGETS_TO_BUILD=AArch64 \
      -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
      -DLLVM_BUILD_TOOLS=ON -DCLANG_INCLUDE_TESTS=OFF -DLLVM_PARALLEL_LINK_JOBS=1
    cmake --build "$work/llvm-build" --target install-clang install-clang-resource-headers \
      install-llvm-readobj install-llvm-readelf install-llvm-objcopy install-llvm-strip -j "$jobs"
    ln -sfn clang "$prefix/llvm/bin/clang++"
  fi
  "$prefix/llvm/bin/clang" --version
  touch "$prefix/llvm/.ready"
fi

for driver in clang clang++; do
  cat >"$prefix/bin/$driver" <<EOF
#!/usr/bin/env bash
exec "$prefix/llvm/bin/$driver" --gcc-toolchain="$prefix/gcc" "\$@"
EOF
  chmod +x "$prefix/bin/$driver"
done
chown -R --reference=/workspace "$prefix"
