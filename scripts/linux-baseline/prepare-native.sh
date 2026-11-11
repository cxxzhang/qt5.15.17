#!/usr/bin/env bash
# Fresh glibc 2.17 toolchain; run inside the matching manylinux2014 image.
set -euo pipefail
arch="${1:?x64 or arm64 required}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
case "$arch:$(uname -m)" in x64:x86_64|arm64:aarch64) ;; *) exit 2 ;; esac
test "$(getconf GNU_LIBC_VERSION)" = 'glibc 2.17'
if [[ ! -x /opt/python/cp311-cp311/bin/python3 ]]; then
  manylinux-interpreters ensure cp311-cp311
fi
export PATH="/opt/python/cp311-cp311/bin:$PATH"
python3 --version
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
  local headers=(-H 'User-Agent: qt-baseline-builder')
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
for pair in llvm-ranlib:llvm-ar llvm-strip:llvm-objcopy llvm-readelf:llvm-readobj; do
  alias_name="${pair%%:*}"
  executable="${pair#*:}"
  if [[ ! -e "$compiler/$alias_name" && -x "$compiler/$executable" ]]; then
    ln -s "$executable" "$compiler/$alias_name"
  fi
done
for tool in clang clang++ llvm-ar llvm-ranlib llvm-nm llvm-strip llvm-readelf ld.lld; do
  [[ -x "$compiler/$tool" ]] || { echo "Missing required LLVM tool: $tool" >&2; exit 1; }
done
"$compiler/clang++" --version
gcc_triple="$(gcc -dumpmachine)"
gcc_root="$prefix/gcc"
# Build GCC with GCC: libstdc++ uses GCC-specific target builtins. Qt and
# consumers below still use Clang exclusively. Install the full GNU toolchain
# so it can be released instead of depending on the image's /opt/rh tree.
if [[ ! -f "$gcc_root/.ready" ]]; then
  fetch libstdcxx "$work/gcc.tar.xz"
  tar -xf "$work/gcc.tar.xz" -C "$work"
  (
    cd "$work/gcc-13.3.0"
    ./contrib/download_prerequisites
  )
  mkdir "$work/build"
  (
    cd "$work/build"
    "$work/gcc-13.3.0/configure" --prefix="$gcc_root" \
      --disable-bootstrap --disable-multilib --disable-libsanitizer \
      --disable-libquadmath --disable-libgomp --disable-libssp \
      --disable-libvtv --disable-nls --enable-languages=c,c++ \
      --with-pkgversion='Qt Linux baseline GNU support 13.3.0'
    make -j"${BASELINE_JOBS:-4}"
    make install
    cp config.log "$root/build-temp/logs/$arch-gcc-config.log"
    cp "$work/gcc-13.3.0/contrib/prerequisites.sha512" "$gcc_root/"
    cp "$work/gcc-13.3.0/COPYING" "$work/gcc-13.3.0/COPYING3" \
      "$work/gcc-13.3.0/COPYING.RUNTIME" "$gcc_root/"
  )
  touch "$gcc_root/.ready"
fi
test "$("$gcc_root/bin/gcc" -dumpfullversion)" = 13.3.0
mkdir -p "$prefix/bin"
for name in clang clang++; do
  cat >"$prefix/bin/$name" <<EOF
#!/usr/bin/env bash
for argument in "\$@"; do
  [[ "\$argument" != -print-multi-os-directory ]] || { echo .; exit 0; }
done
prefix="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
exec "\$prefix/clang/bin/$name" --target="$gcc_triple" --gcc-toolchain="\$prefix/gcc" --gcc-triple="$gcc_triple" -fuse-ld=lld "\$@"
EOF
  chmod +x "$prefix/bin/$name"
done
stdlib="$("$gcc_root/bin/g++" -print-file-name=libstdc++.so.6)"
test -n "$stdlib"
runtime_lib="$(dirname "$stdlib")"
mkdir -p "$prefix/probe-sdk/bin" "$prefix/probe-sdk/lib"
cp -L "$stdlib" "$prefix/probe-sdk/lib/libstdc++.so.6"
cp -L "$("$gcc_root/bin/gcc" -print-file-name=libgcc_s.so.1)" "$prefix/probe-sdk/lib/"
# DT_RUNPATH on the executable is not inherited by libstdc++'s libgcc
# dependency. Each private shared runtime must resolve its own siblings.
patchelf --set-rpath '$ORIGIN' "$prefix/probe-sdk/lib/libstdc++.so.6"
patchelf --set-rpath '$ORIGIN' "$prefix/probe-sdk/lib/libgcc_s.so.1"
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
