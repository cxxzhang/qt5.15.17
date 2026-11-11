#!/usr/bin/env bash
# Exercise an older GNU-built shared C++ library with the selected Clang
# consumer and selected GNU runtime, using the same explicitly selected ABI.
set -euo pipefail
prefix="${1:?baseline prefix required}"
legacy_cxx="${LEGACY_CXX:-$(command -v g++)}"
work="$prefix/mixed-cxx"
mkdir -p "$work"
"$legacy_cxx" --version >"$work/legacy-compiler.txt"
cat >"$work/library.cpp" <<'CPP'
#include <stdexcept>
#include <string>
std::string legacy_message(const std::string &value) { return value + "-legacy"; }
void legacy_throw() { throw std::runtime_error("legacy-exception"); }
CPP
cat >"$work/consumer.cpp" <<'CPP'
#include <stdexcept>
#include <string>
std::string legacy_message(const std::string &);
void legacy_throw();
int main() {
    if (legacy_message("clang") != "clang-legacy") return 1;
    try { legacy_throw(); }
    catch (const std::runtime_error &e) {
        return std::string(e.what()) != "legacy-exception";
    }
    return 2;
}
CPP
tested=0
for abi in 0 1; do
  # CentOS devtoolsets can deliberately disable the dual ABI in their
  # distro headers. A command-line ABI=1 then still compiles ABI=0. Detect
  # that configuration instead of mistaking a mismatched link for a new
  # runtime failure or claiming that unavailable ABI was tested.
  macros="$("$legacy_cxx" -std=c++11 -D_GLIBCXX_USE_CXX11_ABI="$abi" \
    -include string -dM -E -x c++ /dev/null)"
  printf '%s\n' "$macros" >"$work/abi-$abi-macros.txt"
  if ! grep -q "^#define _GLIBCXX_USE_CXX11_ABI $abi$" <<<"$macros"; then
    echo "Legacy headers do not support requested C++ ABI=$abi; no interoperability claim for that ABI"
    continue
  fi
  "$legacy_cxx" -std=c++11 -D_GLIBCXX_USE_CXX11_ABI="$abi" \
    -shared -fPIC "$work/library.cpp" -Wl,-soname,libmixed-abi"$abi".so \
    '-Wl,-rpath,$ORIGIN' -o "$prefix/probe-sdk/lib/libmixed-abi$abi.so"
  "$prefix/bin/clang++" -std=c++17 -D_GLIBCXX_USE_CXX11_ABI="$abi" \
    "$work/consumer.cpp" -L"$prefix/probe-sdk/lib" -lmixed-abi"$abi" \
    '-Wl,-rpath,$ORIGIN/../lib' -o "$prefix/probe-sdk/bin/mixed-abi$abi"
  env -u LD_LIBRARY_PATH -u LD_PRELOAD "$prefix/probe-sdk/bin/mixed-abi$abi"
  tested=$((tested + 1))
done
test "$tested" -gt 0
echo 'Older GNU library / Clang consumer strings and exceptions passed for the available matching legacy ABIs'
