#!/usr/bin/env bash
# Run after setup-linux-toolchain.sh x64, inside the Ubuntu 18.04 container.
set -euo pipefail
arch="${1:?loong64 or mips64el required}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prefix="$root/build-temp/toolchain"
cross="$prefix/cross-$arch"
case "$arch" in
  loong64) triple=loongarch64-linux-gnu ;;
  mips64el) triple=mips64el-linux-gnuabi64 ;;
  *) echo "Unsupported cross target: $arch" >&2; exit 2 ;;
esac
gcc_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["gcc_version"])' "$root/scripts/sysroots/$arch.lock.json")"
[[ "$(uname -m)" == x86_64 ]]
[[ -x "$prefix/llvm/bin/ld.lld" ]]
python3 "$root/scripts/prepare-linux-sysroot.py" "$root/scripts/sysroots/$arch.lock.json" "$prefix"
sysroot="$prefix/sysroot-$arch"
gcc_install="$sysroot/usr/lib/gcc/$triple/$gcc_version"
[[ -f "$gcc_install/crtbegin.o" ]]
mkdir -p "$cross/bin" "$prefix/downloads"

write_driver() {
  local language="$1" runtime_flags=""
  if [[ "$language" == clang++ && -f "$cross/runtime/.ready" ]]; then
    runtime_flags="-nostdinc++ -isystem $cross/runtime/include/c++/13.3.0 -isystem $cross/runtime/include/c++/13.3.0/$triple -L$cross/runtime/lib"
  fi
  cat >"$cross/bin/$language" <<EOF
#!/usr/bin/env bash
if [[ "\$#" == 1 && "\$1" == -print-multi-os-directory ]]; then
  printf '.\\n'
  exit 0
fi
exec "$prefix/llvm/bin/$language" --target="$triple" --sysroot="$sysroot" \
  --gcc-install-dir="$gcc_install" -fuse-ld="$prefix/llvm/bin/ld.lld" \
  -Wl,-rpath-link,"$sysroot/lib/$triple" -Wl,-rpath-link,"$sysroot/usr/lib/$triple" \
  $runtime_flags "\$@"
EOF
  chmod +x "$cross/bin/$language"
}
write_driver clang
write_driver clang++

# Build the same libstdc++ generation against each target's own old glibc.
# The distro GCC installation supplies its compatible libgcc and crt objects;
# Clang compiles libstdc++ itself, so no foreign GCC executable runs on the host.
if [[ ! -f "$cross/runtime/.ready" ]]; then
  archive="$prefix/downloads/gcc-13.3.0.tar.xz"
  checksum=ed5f2f4c6ed2c796fcf2c93707159e9dbd3ddb1ba063d549804dd68cdabbb6d550985ae1c8465ae9a336cfe29274a6eb0f42e21924360574ebd8e5d5c7c9a801
  if [[ ! -f "$archive" ]] || ! echo "$checksum  $archive" | sha512sum -c -; then
    curl --fail --location --retry 5 --connect-timeout 30 \
      https://gcc.gnu.org/pub/gcc/releases/gcc-13.3.0/gcc-13.3.0.tar.xz -o "$archive"
    echo "$checksum  $archive" | sha512sum -c -
  fi
  work="$(mktemp -d)"
  mkdir -p "$root/build-temp/logs"
  trap 'cp "$work/build/config.log" "$root/build-temp/logs/$arch-libstdcxx-config.log" 2>/dev/null || true; rm -rf "$work"' EXIT
  tar -xf "$archive" -C "$work"
  # A standalone libstdc++ build has no preceding libgcc configure step to
  # select the POSIX gthread backend. Supply that header before feature tests.
  ln -s gthr-posix.h "$work/gcc-13.3.0/libgcc/gthr-default.h"
  # The dual-ABI ios_failure bridge rewrites generated assembly. Its GCC-only
  # flag suppresses assembler line directives; Clang uses -g0 for that file.
  python3 - "$work/gcc-13.3.0/libstdc++-v3/src/c++11/Makefile.in" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
assert source.count("-gno-as-loc-support") == 2
path.write_text(source.replace("-gno-as-loc-support", "-g0"))
PY
  mkdir "$work/build"
  (
    cd "$work/build"
    CC="$cross/bin/clang" CXX="$cross/bin/clang++" \
    CFLAGS='-O2 -g -fPIC' CXXFLAGS='-O2 -g -fsized-deallocation' \
    AR="$prefix/llvm/bin/llvm-ar" RANLIB="$prefix/llvm/bin/llvm-ranlib" \
    "$work/gcc-13.3.0/libstdc++-v3/configure" \
      --build=x86_64-linux-gnu --host="$triple" --target="$triple" \
      --with-cross-host=x86_64-linux-gnu --prefix="$cross/runtime" \
      --libdir="$cross/runtime/lib" \
      --with-gxx-include-dir="$cross/runtime/include/c++/13.3.0" \
      --disable-multilib --disable-libstdcxx-pch --disable-static --enable-shared \
      --enable-libstdcxx-threads
    grep -q '^#define _GLIBCXX_HAS_GTHREADS 1' config.h
    make -j"${QT_BUILD_JOBS:-4}"
    make install
  )
  touch "$cross/runtime/.ready"
fi
write_driver clang++

fetch_qemu() {
  local url="$1" checksum="$2" output="$3"
  local headers=(-H 'Accept: application/octet-stream')
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  curl --fail --location --retry 5 --connect-timeout 30 "${headers[@]}" "$url" -o "$output"
  echo "$checksum  $output" | sha256sum -c -
}
if [[ ! -x "$cross/bin/qemu" ]]; then
  case "$arch" in
    loong64)
      fetch_qemu https://api.github.com/repos/loongson/build-tools/releases/assets/231245278 \
        794d606a2af4f6277518260eb803f8021e1a5891609fe0c52ef66f18e3e4e265 "$cross/bin/qemu"
      ;;
    mips64el)
      fetch_qemu https://api.github.com/repos/YooDesk/desk/releases/assets/730044611 \
        83ad62bfe0e28a5645cb6a40d8b99e7a629fdac9e1a9cea9949d1c59a01322c7 "$cross/qemu.deb"
      mkdir -p "$cross/qemu-root"
      dpkg-deb -x "$cross/qemu.deb" "$cross/qemu-root"
      cp "$cross/qemu-root/usr/bin/qemu-mips64el-static" "$cross/bin/qemu"
      ;;
  esac
  chmod +x "$cross/bin/qemu"
fi

# Execute a C++20 binary with the actual target loader and private runtime
# before spending time on Qt. The final SDK receives relative RUNPATHs.
cat >"$cross/probe.cpp" <<'EOF'
#include <concepts>
#include <coroutine>
#include <exception>
#include <ranges>
#include <span>
#include <algorithm>
#include <mutex>
#include <thread>
struct Done {
    struct promise_type {
        Done get_return_object() { return {}; }
        std::suspend_never initial_suspend() noexcept { return {}; }
        std::suspend_never final_suspend() noexcept { return {}; }
        void return_void() {}
        void unhandled_exception() { std::terminate(); }
    };
};
Done calculate(std::integral auto value, int &result) {
    int values[]{value, value + 1};
    result = *std::ranges::find(std::span{values}, value + 1);
    co_return;
}
int main() {
    int result = 0;
    std::mutex mutex;
    std::thread worker([&] { std::lock_guard<std::mutex> lock(mutex); calculate(41, result); });
    worker.join();
    return result != 42;
}
EOF
"$cross/bin/clang++" -std=c++20 -pthread "$cross/probe.cpp" \
  -Wl,-rpath,"$cross/runtime/lib" -o "$cross/probe"
env -u LD_LIBRARY_PATH "$cross/bin/qemu" -L "$sysroot" "$cross/probe"
touch "$cross/.ready"
chown -R --reference="$root" "$cross" "$sysroot" "$prefix/downloads"
