#!/usr/bin/env bash
# Link the same old-runtime Qt binaries with modern host GNU and Clang tools.
set -euo pipefail
arch="${1:?native architecture required}"
variant="${2:?release or debug required}"
artifacts="${3:?original SDK artifact directory required}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
artifacts="$(cd "$artifacts" && pwd)"
prefix="$root/build-temp/accepted-$arch"
name="qt5.15.17_linux_$arch"
[[ "$variant" != debug ]] || name+=_debug
work="$(mktemp -d /tmp/qt-modern-consumer.XXXXXXXX)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/sdk" "$work/bin" "$root/build-temp/logs"
tar -xzf "$artifacts/$name.tar.gz" -C "$work/sdk"
# Native system-runtime SDKs must not override the application's newer GNU
# runtime. The baseline verifier separately proves execution on old glibc.
test ! -e "$work/sdk/lib/libstdc++.so.6"
test ! -e "$work/sdk/lib/libgcc_s.so.1"
gnu_cxx="$(command -v g++)"
gnu_cc="$(command -v gcc)"
triple="$("$gnu_cc" -dumpmachine)"
gnu_install="$(dirname "$("$gnu_cc" -print-libgcc-file-name)")"
for name in clang clang++; do
  cat >"$work/bin/$name" <<EOF
#!/usr/bin/env bash
exec "$prefix/clang/bin/$name" --target="$triple" --gcc-install-dir="$gnu_install" -fuse-ld=lld "\$@"
EOF
  chmod +x "$work/bin/$name"
done
"$gnu_cxx" --version >"$root/build-temp/logs/modern-gcc-$arch-$variant.txt"
"$work/bin/clang++" --version >"$root/build-temp/logs/modern-clang-$arch-$variant.txt"
CC="$gnu_cc" CXX="$gnu_cxx" bash "$root/scripts/smoke-linux.sh" "$work/sdk" "$work/gnu"
CC="$work/bin/clang" CXX="$work/bin/clang++" bash "$root/scripts/smoke-linux.sh" "$work/sdk" "$work/clang"
python3 - "$arch" "$variant" "$artifacts" "$root/build-temp/logs" <<'PY'
import hashlib, json, os, sys
from pathlib import Path
arch, variant, artifacts, logs = sys.argv[1:]
def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''): result.update(block)
    return result.hexdigest()
record = dict(target=arch, variant=variant, accepted=True,
              source_run=os.environ['QT_VERIFY_SOURCE_RUN'],
              verifier_commit=os.environ['GITHUB_SHA'],
              host='Ubuntu 22.04; baseline deployment is checked by the separate verifier',
              compilers={kind: Path(logs, 'modern-' + kind + '-' + arch + '-' + variant + '.txt').read_text()
                         for kind in ('gcc', 'clang')},
              archives={p.name: digest(p) for p in Path(artifacts).glob('*.tar.gz')},
              checks=['same extracted Qt SDK', 'no bundled GNU shared runtime',
                      'GCC and Clang C++17 consumers', 'GUI/QML/fonts/TLS execution'])
Path(logs, 'modern-consumers-' + arch + '-' + variant + '.json').write_text(json.dumps(record, indent=2) + '\n')
PY
