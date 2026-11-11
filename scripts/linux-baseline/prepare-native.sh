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
gcc_root="$prefix/gcc"
# Reuse the image's GNU tools, but use its original system C++ headers and
# shared runtime. SCL compiler age must not raise the target runtime floor.
if [[ ! -f "$gcc_root/.system-runtime" ]]; then
  test ! -e "$gcc_root/.ready"
  image_gcc="$(command -v gcc)"
  image_gnu="$(cd "$(dirname "$image_gcc")/.." && pwd)"
  [[ "$image_gnu" == /opt/rh/*/root/usr ]]
  cp -a "$image_gnu" "$gcc_root"
  headers="$(find /usr/include/c++ -mindepth 1 -maxdepth 1 -type d | sort -V | head -n1)"
  test -n "$headers"
  mkdir -p "$gcc_root/system-headers" "$gcc_root/lib64" "$prefix/share/baseline"
  cp -a "$headers/." "$gcc_root/system-headers/"
  for library in libstdc++.so.6 libgcc_s.so.1; do
    if [[ -L "$gcc_root/lib64/$library" ]]; then unlink "$gcc_root/lib64/$library"; fi
  done
  cp -L /usr/lib64/libstdc++.so.6 "$gcc_root/lib64/libstdc++.so.6"
  cp -L /lib64/libgcc_s.so.1 "$gcc_root/lib64/libgcc_s.so.1"
  ln -sfn libstdc++.so.6 "$gcc_root/lib64/libstdc++.so"
  rpm -q libstdc++ libstdc++-devel libgcc >"$prefix/share/baseline/system-gnu-rpms.txt"
  printf '%s\n' "$headers" >"$prefix/share/baseline/system-gnu-headers.txt"
  touch "$gcc_root/.system-runtime" "$gcc_root/.ready"
fi
gcc_triple="$("$gcc_root/bin/gcc" -dumpmachine)"
gcc_install="$(dirname "$("$gcc_root/bin/gcc" -print-libgcc-file-name)")"
gcc_install_rel="${gcc_install#"$prefix/"}"
header_config="$(find "$gcc_root/system-headers" -name c++config.h -print -quit)"
test -n "$header_config"
header_config_rel="$(dirname "$(dirname "${header_config#"$prefix/"}")")"
python3 - "$prefix" "$gcc_install_rel" "$header_config_rel" <<'PY'
import json, sys
from pathlib import Path
prefix, install, config = sys.argv[1:]
Path(prefix, 'gnu-support.json').write_text(json.dumps(dict(
    gcc_install=install, header_config=config, runtime_policy='baseline-system')) + '\n')
PY
mkdir -p "$prefix/bin"
for name in clang clang++; do
  mode=gcc
  [[ "$name" != clang++ ]] || mode=g++
  cat >"$prefix/bin/$name" <<EOF
#!/usr/bin/env bash
prefix="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
extra=()
if [[ "$name" == clang++ ]]; then
  extra=(-nostdinc++ -isystem "\$prefix/gcc/system-headers" \
    -isystem "\$prefix/$header_config_rel" -isystem "\$prefix/gcc/system-headers/backward")
fi
exec "\$prefix/clang/bin/clang" --driver-mode=$mode --target="$gcc_triple" \
  --gcc-install-dir="\$prefix/$gcc_install_rel" -fuse-ld=lld \
  -L"\$prefix/gcc/lib64" "\${extra[@]}" "\$@"
EOF
  chmod +x "$prefix/bin/$name"
done
stdlib="$gcc_root/lib64/libstdc++.so.6"
test -n "$stdlib"
runtime_lib="$(dirname "$stdlib")"
mkdir -p "$prefix/probe-sdk/bin" "$prefix/probe-sdk/lib"
cp -L "$stdlib" "$prefix/probe-sdk/lib/libstdc++.so.6"
cp -L "$gcc_root/lib64/libgcc_s.so.1" "$prefix/probe-sdk/lib/"
# DT_RUNPATH on the executable is not inherited by libstdc++'s libgcc
# dependency. Each private shared runtime must resolve its own siblings.
patchelf --set-rpath '$ORIGIN' "$prefix/probe-sdk/lib/libstdc++.so.6"
patchelf --set-rpath '$ORIGIN' "$prefix/probe-sdk/lib/libgcc_s.so.1"
cp "$root/scripts/linux-baseline/probe.cpp" "$prefix/probe.cpp"
"$prefix/bin/clang++" -std=c++17 -pthread "$prefix/probe.cpp" \
  '-Wl,-rpath,$ORIGIN/../lib' -o "$prefix/probe-sdk/bin/probe"
bash "$root/scripts/linux-baseline/probe-mixed-cxx.sh" "$prefix"
machine="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["targets"][sys.argv[2]]["machine"])' "$root/scripts/linux-baseline/targets.json" "$arch")"
python3 "$root/scripts/package-linux.py" "$prefix/probe-sdk" --audit-only \
  --machine "$machine" --glibc 2.17 --native-dependencies --readelf "$compiler/llvm-readelf"
python3 "$root/scripts/audit-linux-gnu-runtime.py" "$prefix/probe-sdk" \
  --libstdcxx /usr/lib64/libstdc++.so.6 --libgcc /lib64/libgcc_s.so.1 \
  --readelf "$compiler/llvm-readelf" --output "$root/build-temp/logs/$arch-system-gnu-probe.json"
env -u LD_LIBRARY_PATH -u LD_PRELOAD "$prefix/probe-sdk/bin/probe"
echo "$arch: Clang/system-libstdc++ C++17/thread probe passed on glibc 2.17"
