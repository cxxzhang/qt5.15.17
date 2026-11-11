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
python3 "$root/scripts/package-linux.py" "$work/sdk" "$work/symbols" \
  --machine "$machine" --glibc 99.0 --native-dependencies
test -s "$work/symbols/probe.debug"
test -s "$work/symbols/libprobe.a.debug"
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
echo 'Packaging gate functional checks passed'
