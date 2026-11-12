#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d /tmp/qt-macos-symbol-test.XXXXXXXX)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/sdk/lib" "$work/sdk/bin"
printf 'int probe() { return 42; }\n' > "$work/probe.cpp"
printf 'int main() { return 0; }\n' > "$work/main.cpp"
clang++ -g -O2 -c "$work/probe.cpp" -o "$work/probe.o"
clang++ -g -dynamiclib "$work/probe.o" -o "$work/sdk/lib/libprobe.dylib"
ar crs "$work/sdk/lib/libprobe.a" "$work/probe.o"
clang++ -g -O2 -c "$work/main.cpp" -o "$work/main.o"
clang++ -g "$work/main.o" -o "$work/sdk/bin/probe"
python3 "$root/scripts/native-symbols.py" capture-macos "$work/sdk"
python3 "$root/scripts/native-symbols.py" macos "$work/sdk" "$work/sdk.tar.gz" "$work/sdk-symbols.tar.gz"
mkdir "$work/extracted"
tar -xzf "$work/sdk.tar.gz" -C "$work/extracted"
python3 "$root/scripts/native-symbols.py" verify "$work/extracted" "$work/sdk-symbols.tar.gz"
"$work/extracted/bin/probe"
printf 'tampered' >> "$work/extracted/lib/libprobe.dylib"
if python3 "$root/scripts/native-symbols.py" verify "$work/extracted" "$work/sdk-symbols.tar.gz"; then
  echo 'Tampered binary unexpectedly matched symbols' >&2
  exit 1
fi
echo 'macOS real dSYM/static archive separation and tamper rejection passed'
