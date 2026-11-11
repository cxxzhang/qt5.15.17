#!/usr/bin/env bash
# Exercise an older GNU-built shared C++ library with the selected Clang
# consumer and private newer runtime, using the same explicitly selected ABI.
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
for abi in 0 1; do
  "$legacy_cxx" -std=c++11 -D_GLIBCXX_USE_CXX11_ABI="$abi" \
    -shared -fPIC "$work/library.cpp" -Wl,-soname,libmixed-abi"$abi".so \
    '-Wl,-rpath,$ORIGIN' -o "$prefix/probe-sdk/lib/libmixed-abi$abi.so"
  "$prefix/bin/clang++" -std=c++20 -D_GLIBCXX_USE_CXX11_ABI="$abi" \
    "$work/consumer.cpp" -L"$prefix/probe-sdk/lib" -lmixed-abi"$abi" \
    '-Wl,-rpath,$ORIGIN/../lib' -o "$prefix/probe-sdk/bin/mixed-abi$abi"
  env -u LD_LIBRARY_PATH -u LD_PRELOAD "$prefix/probe-sdk/bin/mixed-abi$abi"
done
echo 'Older GNU library / Clang consumer strings and exceptions passed for matching ABI=0 and ABI=1'
