#!/usr/bin/env bash
# Source this file for upstream LLVM's new-world LoongArch backend.
vendor_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
vendor_work="$vendor_root/build-temp/loong-newworld-inputs"
mkdir -p "$vendor_work/downloads" "$vendor_work/compiler"
vendor_fetch() {
  local name="$1" url="$2" checksum="$3" path="$vendor_work/downloads/$1"
  if [[ ! -s "$path" ]]; then
    local headers=(-H 'User-Agent: qt-linux-baseline')
    if [[ "$url" == https://api.github.com/* ]]; then
      headers+=(-H 'Accept: application/octet-stream' -H "Authorization: Bearer ${GITHUB_TOKEN:?}")
    fi
    curl -fsSL --retry 5 --connect-timeout 30 --max-time 1800 "${headers[@]}" "$url" -o "$path.tmp"
    mv "$path.tmp" "$path"
  fi
  echo "$checksum  $path" | sha256sum -c -
}
vendor_fetch llvm18.tar.xz https://api.github.com/repos/llvm/llvm-project/releases/assets/177973150 54ec30358afcc9fb8aa74307db3046f5187f9fb89fb37064cdde906e062ebf36
if [[ ! -x "$vendor_work/compiler/bin/clang" ]]; then
  tar -xf "$vendor_work/downloads/llvm18.tar.xz" -C "$vendor_work/compiler" --strip-components=1
fi
vendor_compiler="$vendor_work/compiler/bin/clang"
"$vendor_compiler" --version
