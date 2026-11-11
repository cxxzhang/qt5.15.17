#!/usr/bin/env bash
# Build the C++20 runtime against the vendor's real old-world glibc 2.28.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
prefix="$root/build-temp/baseline-loong64-oldworld"
mkdir -p "$prefix/bin" "$root/build-temp/logs"
source "$root/scripts/linux-baseline/load-vendor-clang.sh"
vendor_fetch sysroot.tar.bz2 https://ftp.loongnix.cn/browser/build/sysroot/debian_bullseye_loong64-sysroot.tar.bz2 34efb077fed691feac2605ec9656c8ecb40e63076fdb76ae06df90f279099a64
if [[ ! -d "$prefix/sysroot" ]]; then
  tar -xf "$vendor_work/downloads/sysroot.tar.bz2" -C "$prefix"
  mv "$prefix/debian_bullseye_loong64-sysroot" "$prefix/sysroot"
fi
sysroot="$prefix/sysroot"
gcc_install="$sysroot/usr/lib/gcc/loongarch64-linux-gnu/8"
test -f "$gcc_install/crtbegin.o"
touch "$sysroot/.sysroot-loong64-oldworld-2.28"
compiler_bin="$(dirname "$vendor_compiler")"
write_driver() {
  local name="$1"
  cat >"$prefix/bin/$name" <<EOF
#!/usr/bin/env bash
for argument in "\$@"; do
  [[ "\$argument" != -print-multi-os-directory ]] || { echo .; exit 0; }
done
extra=()
if [[ "$name" == clang++ && -f "$prefix/runtime/.ready" ]]; then
  extra=(-nostdinc++ -isystem "$prefix/runtime/include/c++/13.3.0" \
    -isystem "$prefix/runtime/include/c++/13.3.0/loongarch64-linux-gnu" -L"$prefix/runtime/lib")
fi
exec "$vendor_compiler" --driver-mode="$([[ "$name" == clang++ ]] && echo g++ || echo gcc)" \
  --target=loongarch64-linux-gnu -mabi=lp64 --sysroot="$sysroot" \
  --gcc-install-dir="$gcc_install" --ld-path="$compiler_bin/ld.lld" \
  -Wl,-rpath-link,"$sysroot/lib/loongarch64-linux-gnu" \
  -Wl,-rpath-link,"$sysroot/usr/lib/loongarch64-linux-gnu" \${extra[@]+"\${extra[@]}"} "\$@"
EOF
  chmod +x "$prefix/bin/$name"
}
write_driver clang
write_driver clang++
archive="$vendor_work/downloads/gcc-13.3.0.tar.xz"
vendor_fetch gcc-13.3.0.tar.xz https://gcc.gnu.org/pub/gcc/releases/gcc-13.3.0/gcc-13.3.0.tar.xz 0845e9621c9543a13f484e94584a49ffc0129970e9914624235fc1d061a0c083
if [[ ! -f "$prefix/runtime/.ready" ]]; then
  work="$(mktemp -d)"
  trap 'cp "$work/build/config.log" "$root/build-temp/logs/loong-oldworld-libstdcxx-config.log" 2>/dev/null || true; rm -rf "$work"' EXIT
  tar -xf "$archive" -C "$work"
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
    AR="$compiler_bin/llvm-ar" RANLIB="$compiler_bin/llvm-ranlib" \
    NM="$compiler_bin/llvm-nm" LD="$compiler_bin/ld.lld" STRIP="$compiler_bin/llvm-strip" \
      "$work/gcc-13.3.0/libstdc++-v3/configure" \
      --build=x86_64-linux-gnu --host=loongarch64-linux-gnu --target=loongarch64-linux-gnu \
      --with-cross-host=x86_64-linux-gnu --prefix="$prefix/runtime" \
      --with-gxx-include-dir="$prefix/runtime/include/c++/13.3.0" \
      --disable-multilib --disable-libstdcxx-pch --disable-static --enable-shared \
      --enable-libstdcxx-threads
    grep -q '^#define _GLIBCXX_HAS_GTHREADS 1' config.h
    make -j4
    make install
    cp "$work/gcc-13.3.0/COPYING3" "$work/gcc-13.3.0/COPYING.RUNTIME" "$prefix/runtime/"
  )
  test -e "$prefix/runtime/lib" || ln -s loongarch64-linux-gnu/lib "$prefix/runtime/lib"
  touch "$prefix/runtime/.ready"
fi
mkdir -p "$prefix/probe-sdk/bin" "$prefix/probe-sdk/lib"
cp -L "$prefix/runtime/lib/libstdc++.so.6" "$prefix/probe-sdk/lib/"
cp -L "$sysroot/lib/loongarch64-linux-gnu/libgcc_s.so.1" "$prefix/probe-sdk/lib/"
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
Done calculate(std::integral auto value, int &answer) {
  int values[]{value, value + 1};
  answer = *std::ranges::find(std::span{values}, value + 1);
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
  '-Wl,-rpath,$ORIGIN/lib' -o "$prefix/probe-sdk/bin/probe"
python3 "$root/scripts/package-linux.py" "$prefix/probe-sdk" --audit-only \
  --machine LoongArch --glibc 2.28 --interpreter /lib64/ld.so.1
python3 - "$prefix/probe-sdk" <<'PY'
from pathlib import Path
import struct, sys
for path in Path(sys.argv[1]).rglob('*'):
    if not path.is_file() or path.is_symlink(): continue
    data = path.read_bytes()[:64]
    if data[:4] == b'\x7fELF' and struct.unpack_from('<I', data, 48)[0] != 3:
        raise SystemExit('Not old-world ABI: ' + str(path))
PY
qemu="$vendor_work/downloads/qemu-loongarch64"
if [[ ! -f "$qemu" ]]; then
  curl -fsSL --retry 5 -H 'Accept: application/octet-stream' \
    -H "Authorization: Bearer ${GITHUB_TOKEN:?}" \
    https://api.github.com/repos/loongson/build-tools/releases/assets/231245278 -o "$qemu"
fi
echo "794d606a2af4f6277518260eb803f8021e1a5891609fe0c52ef66f18e3e4e265  $qemu" | sha256sum -c -
chmod +x "$qemu"
sudo -E python3 "$root/scripts/linux_cross_runtime.py" probe "$sysroot" "$qemu" \
  "$prefix/probe-sdk/bin/probe" --loader /lib64/ld.so.1 \
  --stdlib "$prefix/probe-sdk/lib/libstdc++.so.6" --libgcc "$prefix/probe-sdk/lib/libgcc_s.so.1"
