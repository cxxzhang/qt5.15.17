#!/usr/bin/env bash
# Install Ubuntu runner tools without repeatedly waiting on a failed mirror.
set -euo pipefail
test "$(id -u)" = 0
options=(-o Acquire::Retries=2 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)
if apt-get "${options[@]}" update && apt-get "${options[@]}" install -y --no-install-recommends "$@"; then
  exit 0
fi
# GitHub's Ubuntu mirror list can select an Azure endpoint whose DNS fails
# while the official archive is available. Retry the same requested packages
# through Ubuntu's archive; this does not change the target sysroot.
python3 - <<'PY'
from pathlib import Path
for name in ('/etc/apt/apt-mirrors.txt', '/etc/apt/apt-mirrors-security.txt', '/etc/apt/sources.list'):
    path = Path(name)
    if path.is_file():
        original = path.read_text()
        updated = original.replace('azure.archive.ubuntu.com', 'archive.ubuntu.com')
        if updated != original:
            path.write_text(updated)
for path in Path('/etc/apt/sources.list.d').glob('*'):
    if path.suffix in ('.list', '.sources') and path.is_file():
        original = path.read_text()
        updated = original.replace('azure.archive.ubuntu.com', 'archive.ubuntu.com')
        if updated != original:
            path.write_text(updated)
PY
apt-get "${options[@]}" update
apt-get "${options[@]}" install -y --no-install-recommends "$@"
