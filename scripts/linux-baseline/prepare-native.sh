#!/usr/bin/env bash
# Fresh glibc 2.17 toolchain; run inside the matching manylinux2014 image.
set -euo pipefail
arch="${1:?x64 or arm64 required}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
case "$arch:$(uname -m)" in x64:x86_64|arm64:aarch64) ;; *) exit 2 ;; esac
test "$(getconf GNU_LIBC_VERSION)" = 'glibc 2.17'
prefix="$root/build-temp/baseline-$arch"
mkdir -p "$prefix" "$root/build-temp/logs"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fetch() {
  local kind="$1" output="$2" url checksum
  read -r url checksum < <(python3 - "$root/scripts/linux-baseline/targets.json" "$kind" "$arch" <<'PY'
import json, sys
config = json.load(open(sys.argv[1]))
entry = config['clang'][sys.argv[3]] if sys.argv[2] == 'clang' else config['libstdcxx']
print(entry.get('api_url', entry.get('url')), entry['sha256'])
PY
  )
  local headers=()
  if [[ "$url" == https://api.github.com/* ]]; then
    headers+=(-H 'Accept: application/octet-stream')
    [[ -z "${GITHUB_TOKEN:-}" ]] || headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  curl -fsSL --retry 5 --connect-timeout 30 "${headers[@]}" "$url" -o "$output"
  echo "$checksum  $output" | sha256sum -c -
}
if [[ ! -x "$prefix/clang/bin/clang++" ]]; then
  fetch clang "$work/clang.tar.xz"
  tar -xf "$work/clang.tar.xz" -C "$prefix"
fi
compiler="$prefix/clang/bin"
"$compiler/clang++" --version
gcc_triple="$(gcc -dumpmachine)"
gcc_root="${DEVTOOLSET_ROOTPATH:-}/usr"
test -d "$gcc_root/lib/gcc"
mkdir -p "$prefix/bin"
for name in clang clang++; do
  cat >"$prefix/bin/$name" <<EOF
#!/usr/bin/env bash
exec "$compiler/$name" --target="$gcc_triple" --gcc-toolchain="$gcc_root" --gcc-triple="$gcc_triple" -fuse-ld=lld "\$@"
EOF
  chmod +x "$prefix/bin/$name"
done
if [[ ! -f "$prefix/runtime/.ready" ]]; then
  fetch libstdcxx "$work/gcc.tar.xz"
  tar -xf "$work/gcc.tar.xz" -C "$work"
  ln -s gthr-posix.h "$work/gcc-13.3.0/libgcc/gthr-default.h"
  python3 - "$work/gcc-13.3.0/libstdc++-v3/src/c++11/Makefile.in" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
assert text.count('-gno-as-loc-support') == 2
path.write_text(text.replace('-gno-as-loc-support', '-g0'))
PY
  mkdir "$work/build"
  (
    cd "$work/build"
    CC="$prefix/bin/clang" CXX="$prefix/bin/clang++" \
    CFLAGS='-O2 -g -fPIC' CXXFLAGS='-O2 -g -fsized-deallocation' \
    LDFLAGS='-Wl,--undefined-version' \
    AR="$compiler/llvm-ar" RANLIB="$compiler/llvm-ranlib" \
    NM="$compiler/llvm-nm" LD="$compiler/ld.lld" STRIP="$compiler/llvm-strip" \
      "$work/gcc-13.3.0/libstdc++-v3/configure" \
      --build="$gcc_triple" --host="$gcc_triple" --prefix="$prefix/runtime" \
      --with-gxx-include-dir="$prefix/runtime/include/c++/13.3.0" \
      --disable-multilib --disable-libstdcxx-pch --disable-static --enable-shared \
      --enable-libstdcxx-threads
    grep -q '^#define _GLIBCXX_HAS_GTHREADS 1' config.h
    make -j4
    make install
  )
  touch "$prefix/runtime/.ready"
fi
stdlib="$(find "$prefix/runtime" -name libstdc++.so.6 -print -quit)"
test -n "$stdlib"
runtime_lib="$(dirname "$stdlib")"
config_header="$(find "$prefix/runtime/include" -path '*/bits/c++config.h' -print -quit)"
test -n "$config_header"
target_include="$(dirname "$(dirname "$config_header")")"
cat >"$prefix/bin/clang++" <<EOF
#!/usr/bin/env bash
exec "$compiler/clang++" --target="$gcc_triple" --gcc-toolchain="$gcc_root" --gcc-triple="$gcc_triple" -fuse-ld=lld \
  -nostdinc++ -isystem "$prefix/runtime/include/c++/13.3.0" \
  -isystem "$target_include" -L"$runtime_lib" "\$@"
EOF
mkdir -p "$prefix/probe-sdk/bin" "$prefix/probe-sdk/lib"
cp -L "$stdlib" "$prefix/probe-sdk/lib/libstdc++.so.6"
cp -L "$("$prefix/bin/clang" -print-file-name=libgcc_s.so.1)" "$prefix/probe-sdk/lib/"
cat >"$prefix/probe.cpp" <<'CPP'
#include <algorithm>
#include <concepts>
#include <coroutine>
#include <exception>
#include <mutex>
#include <ranges>
#include <span>
#include <thread>
static_assert(_GLIBCXX_RELEASE == 13);
struct Done { struct promise_type {
    Done get_return_object() { return {}; }
    std::suspend_never initial_suspend() noexcept { return {}; }
    std::suspend_never final_suspend() noexcept { return {}; }
    void return_void() {}
    void unhandled_exception() { std::terminate(); }
}; };
Done calculate(std::integral auto x, int &result) {
    int a[]{x, x + 1};
    result = *std::ranges::find(std::span{a}, x + 1);
    co_return;
}
int main() {
    int answer = 0;
    std::mutex mutex;
    std::thread worker([&] { std::lock_guard lock(mutex); calculate(41, answer); });
    worker.join();
    return answer != 42;
}
CPP
"$prefix/bin/clang++" -std=c++20 -pthread "$prefix/probe.cpp" \
  '-Wl,-rpath,$ORIGIN/../lib' -o "$prefix/probe-sdk/bin/probe"
machine="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["targets"][sys.argv[2]]["machine"])' "$root/scripts/linux-baseline/targets.json" "$arch")"
python3 "$root/scripts/package-linux.py" "$prefix/probe-sdk" --audit-only \
  --machine "$machine" --glibc 2.17 --native-dependencies --readelf "$compiler/llvm-readelf"
env -u LD_LIBRARY_PATH -u LD_PRELOAD "$prefix/probe-sdk/bin/probe"
echo "$arch: Clang/libstdc++13 C++20/thread probe passed on glibc 2.17"
