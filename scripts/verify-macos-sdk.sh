#!/usr/bin/env bash
set -euo pipefail
archive="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
target="${2:?SDK target required}"
consumer_arch="${3:?consumer architecture required}"
shift 3
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d /tmp/qt-macos-consumer.XXXXXXXX)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/sdk" "$root/build-temp/logs"
tar -xzf "$archive" -C "$work/sdk"
python3 "$root/scripts/macos-sdk.py" audit "$work/sdk" "$@"
test "$("$work/sdk/bin/qmake" -query QT_VERSION)" = 5.15.17
QT_SMOKE_APPLE_ARCHS="$consumer_arch" CC=clang CXX=clang++ \
  bash "$root/scripts/smoke-linux.sh" "$work/sdk" "$work/consumer"
test "$(lipo -archs "$work/consumer/smoke")" = "$consumer_arch"
python3 - "$archive" "$target" "$consumer_arch" "$root/build-temp/logs" "$@" <<'PY'
import hashlib, json, os, sys
from pathlib import Path
archive, target, consumer, logs, *architectures = sys.argv[1:]
path = Path(archive)
record = dict(accepted=True, target=target, consumer_arch=consumer, architectures=architectures,
              source_run=os.environ['GITHUB_RUN_ID'], source_commit=os.environ['GITHUB_SHA'],
              archive=path.name, sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
              checks=['extracted executable permissions', 'all Mach-O and static archive architectures',
                      'qmake C++17 consumer', 'offscreen GUI/QML/fonts/TLS execution'])
Path(logs, 'verified-macos-' + target + '-' + consumer + '.json').write_text(json.dumps(record, indent=2) + '\n')
PY
