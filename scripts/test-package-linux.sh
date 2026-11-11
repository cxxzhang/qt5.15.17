#!/usr/bin/env bash
# Functional checks for the publishing gate using real compiler/linker output.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export LC_ALL=C
mkdir "$work/sdk"
printf '#include <stdio.h>\nint main(void) { return puts("packaging probe") < 0; }\n' >"$work/main.c"
cc -g "$work/main.c" -o "$work/sdk/probe"
printf 'int sdk_function(void) { return 42; }\n' >"$work/static.c"
cc -g -c "$work/static.c" -o "$work/static.o"
ar crs "$work/sdk/libprobe.a" "$work/static.o"
machine="$(readelf -h "$work/sdk/probe" | sed -n 's/^ *Machine: *//p')"
expect_rejection() {
  if python3 "$root/scripts/package-linux.py" "$work/sdk" "$work/symbols" "$@" >"$work/error.log" 2>&1; then
    echo "The publishing gate accepted an invalid SDK" >&2
    exit 1
  fi
}
expect_rejection --machine invalid --glibc 99.0
grep -q 'unexpected ELF architecture' "$work/error.log"
expect_rejection --machine "$machine" --glibc 1.0
grep -q 'exceeds glibc baseline' "$work/error.log"
expect_rejection --machine "$machine" --glibc 99.0 --audit-only --elf-flags 0xffffffff
grep -q 'unexpected ELF ABI flags' "$work/error.log"
expect_rejection --machine "$machine" --glibc 99.0 --audit-only --require-stripped
grep -q 'debug information survived strip' "$work/error.log"
test ! -e "$work/symbols"
python3 "$root/scripts/package-linux.py" "$work/sdk" "$work/symbols" \
  --machine "$machine" --glibc 99.0 --native-dependencies
test -s "$work/symbols/probe.debug"
test -s "$work/symbols/libprobe.a.debug"
tar -C "$work/symbols" -czf "$work/symbols.tar.gz" .
python3 "$root/scripts/verify-linux-symbols.py" "$work/sdk" "$work/symbols.tar.gz"
printf 'corrupt' >>"$work/symbols/probe.debug"
tar -C "$work/symbols" -czf "$work/corrupt-symbols.tar.gz" .
if python3 "$root/scripts/verify-linux-symbols.py" "$work/sdk" "$work/corrupt-symbols.tar.gz" \
    >"$work/error.log" 2>&1; then
  echo "The symbol verifier accepted a corrupt debug file" >&2
  exit 1
fi
grep -q 'CRC mismatch' "$work/error.log"
readelf -SW "$work/sdk/probe" >"$work/sections"
! grep -q '\.debug_info ' "$work/sections"
grep -q '\.gnu_debuglink ' "$work/sections"
"$work/sdk/probe"
# Stripping archive members must preserve symbols used by SDK consumers.
printf 'int sdk_function(void); int main(void) { return sdk_function() != 42; }\n' >"$work/static-main.c"
cc "$work/static-main.c" "$work/sdk/libprobe.a" -o "$work/static-consumer"
"$work/static-consumer"
readelf -SW "$work/sdk/libprobe.a" >"$work/archive-sections"
! grep -q '\.debug_info ' "$work/archive-sections"
sha256sum "$work/sdk/probe" "$work/sdk/libprobe.a" >"$work/stripped-checksums"
python3 "$root/scripts/package-linux.py" "$work/sdk" \
  --machine "$machine" --glibc 99.0 --audit-only --require-stripped --native-dependencies
sha256sum -c "$work/stripped-checksums"

# A library that exists only at link time must block publication.
mkdir "$work/broken"
printf 'int dependency(void) { return 0; }\n' >"$work/dep.c"
cc -shared -fPIC "$work/dep.c" -Wl,-soname,libpackaging_probe.so -o "$work/libpackaging_probe.so"
printf 'int dependency(void); int main(void) { return dependency(); }\n' >"$work/consumer.c"
cc "$work/consumer.c" -L"$work" -lpackaging_probe -o "$work/broken/probe"
if env -u LD_LIBRARY_PATH python3 "$root/scripts/package-linux.py" \
  "$work/broken" "$work/broken-symbols" --machine "$machine" --glibc 99.0 \
  --native-dependencies >"$work/error.log" 2>&1; then
  echo "The publishing gate accepted an unresolved shared library" >&2
  exit 1
fi
grep -q 'unresolved runtime dependency' "$work/error.log"
# A missing lazy function relocation must fail even when every SONAME exists.
mkdir "$work/unresolved-symbol"
printf '#include <stdio.h>\nint missing_runtime_api(void); int probe(void) { puts("probe"); return missing_runtime_api(); }\n' >"$work/unresolved.c"
cc -shared -fPIC "$work/unresolved.c" -o "$work/unresolved-symbol/libprobe.so"
if python3 "$root/scripts/package-linux.py" "$work/unresolved-symbol" --audit-only \
    --machine "$machine" --glibc 99.0 --native-dependencies >"$work/error.log" 2>&1; then
  echo 'The runtime gate accepted an unresolved lazy function symbol' >&2
  exit 1
fi
grep -q 'undefined symbol: missing_runtime_api' "$work/error.log"

# Check real system C++ providers, including deliberate mismatches.
mkdir "$work/system-cxx"
printf '#include <string>\nint main() { return std::string("system").size() != 6; }\n' >"$work/system-cxx.cpp"
g++ -std=c++11 "$work/system-cxx.cpp" -o "$work/system-cxx/probe"
stdlib="$(g++ -print-file-name=libstdc++.so.6)"
libgcc="$(gcc -print-file-name=libgcc_s.so.1)"
python3 "$root/scripts/package-linux.py" "$work/system-cxx" --audit-only \
  --machine "$machine" --glibc 99.0 --native-dependencies \
  --system-libstdcxx "$stdlib" --system-libgcc "$libgcc"
python3 "$root/scripts/audit-linux-gnu-runtime.py" "$work/system-cxx" \
  --libstdcxx "$stdlib" --libgcc "$libgcc" --output "$work/system-cxx.json"
if python3 "$root/scripts/audit-linux-gnu-runtime.py" "$work/system-cxx" \
    --libstdcxx "$libgcc" --libgcc "$libgcc" --output "$work/wrong-gnu.json" >"$work/error.log" 2>&1; then
  echo 'The GNU gate accepted a provider without the imported C++ symbols' >&2
  exit 1
fi
grep -q 'cannot provide imports' "$work/error.log"
if python3 "$root/scripts/package-linux.py" "$work/system-cxx" --audit-only \
    --machine "$machine" --glibc 99.0 --native-dependencies \
    --system-libstdcxx "$libgcc" --system-libgcc "$libgcc" >"$work/error.log" 2>&1; then
  echo 'The resolver accepted a provider different from the selected baseline' >&2
  exit 1
fi
grep -q 'outside the selected runtime' "$work/error.log"
echo 'Packaging gate functional checks passed'
