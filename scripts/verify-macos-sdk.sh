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
CC=clang CXX=clang++ bash "$root/scripts/smoke-linux.sh" "$work/sdk" "$work/consumer"
python3 - "$work/sdk" "$work/consumer/smoke" "$consumer_arch" "$@" <<'PY'
from pathlib import Path
import re, subprocess, sys
sdk, program, consumer, *architectures = sys.argv[1:]
config = Path(sdk, 'mkspecs/qconfig.pri').read_text()
advertised = re.findall(r'^QT_ARCHS\s*=\s*(.*)$', config, re.M)
assert len(advertised) == 1 and set(advertised[0].split()) == set(architectures), advertised
actual = set(subprocess.check_output(['lipo', '-archs', program], text=True).split())
assert consumer in actual and actual <= set(architectures), actual
PY
if [[ "$target" == universal ]]; then
  QT_SMOKE_APPLE_ARCHS='x86_64 arm64' CC=clang CXX=clang++ \
    bash "$root/scripts/smoke-linux.sh" "$work/sdk" "$work/universal-consumer"
  python3 - "$work/universal-consumer/smoke" <<'PY'
import subprocess, sys
assert set(subprocess.check_output(['lipo', '-archs', sys.argv[1]], text=True).split()) == {'x86_64', 'arm64'}
PY
fi
python3 - "$archive" "$target" "$consumer_arch" "$root/build-temp/logs" "$work/sdk" "$@" <<'PY'
import hashlib, json, os, sys
from pathlib import Path
archive, target, consumer, logs, sdk, *architectures = sys.argv[1:]
path = Path(archive)
record = dict(accepted=True, target=target, consumer_arch=consumer, architectures=architectures,
              source_run=os.environ['GITHUB_RUN_ID'], source_commit=os.environ['GITHUB_SHA'],
              archive=path.name, sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
              checks=['extracted executable permissions', 'all Mach-O and static archive architectures',
                      'advertised qmake architectures', 'default native qmake consumer',
                      'qmake C++17 consumer', 'offscreen GUI/QML/fonts/TLS execution'])
if target == 'universal': record['checks'].append('explicit dual-architecture consumer')
record['build_provenance'] = {p.name: json.loads(p.read_text()) for p in Path(sdk, 'share').glob('ci-*-source*.json')}
Path(logs, 'verified-macos-' + target + '-' + consumer + '.json').write_text(json.dumps(record, indent=2) + '\n')
PY
