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
for arch in x86_64 arm64; do
  clang++ -g -O2 -arch "$arch" -c "$work/probe.cpp" -o "$work/probe-$arch.o"
  ar crs "$work/libprobe-$arch.a" "$work/probe-$arch.o"
  clang++ -g -arch "$arch" -dynamiclib "$work/probe-$arch.o" -o "$work/libprobe-$arch.dylib"
done
lipo -create "$work/libprobe-x86_64.a" "$work/libprobe-arm64.a" -output "$work/sdk/lib/libprobe-fat.a"
lipo -create "$work/libprobe-x86_64.dylib" "$work/libprobe-arm64.dylib" -output "$work/sdk/lib/libprobe-fat.dylib"
# Retain a regression fixture from the first accepted SDK: this complete
# Bootstrap archive exposed DWARF that the tiny archive did not reproduce.
curl --fail --location --retry 3 --silent --show-error \
  https://github.com/cxxzhang/qt5.15.17/releases/download/qt5.15.17-43120765189/qt5.15.17_macos_x64.tar.gz \
  --output "$work/bootstrap-fixture.tar.gz"
echo '57d37dc88c36a7cc3cce8055faab63d26d438e5a533bba34bb4123d92c74cccc  '"$work/bootstrap-fixture.tar.gz" | shasum -a 256 -c -
mkdir "$work/fixture"
tar -xzf "$work/bootstrap-fixture.tar.gz" -C "$work/fixture" ./lib/libQt5Bootstrap.a
cp "$work/fixture/lib/libQt5Bootstrap.a" "$work/sdk/lib/libQt5Bootstrap.a"
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
