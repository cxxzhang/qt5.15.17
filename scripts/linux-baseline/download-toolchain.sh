#!/usr/bin/env bash
# SDK jobs consume only accepted repository releases, never source rebuilds.
set -euo pipefail
arch="${1:?target required}"
destination="${2:?extraction directory required}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
read -r url checksum filename < <(python3 - "${QT_TOOLCHAIN_LOCK:-$root/scripts/linux-baseline/toolchains.lock.json}" "$arch" <<'PY'
import json, sys
config = json.load(open(sys.argv[1]))
entry = config['targets'].get(sys.argv[2])
if not entry:
    raise SystemExit('No accepted repository toolchain is pinned for ' + sys.argv[2])
prefix = 'https://api.github.com/repos/' + config['repository'] + '/releases/assets/'
if not entry['api_url'].startswith(prefix):
    raise SystemExit('SDK toolchains must come from this repository')
print(entry['api_url'], entry['sha256'], entry['filename'])
PY
)
test -n "$url" && test -n "$checksum" && test -n "$filename"
if [[ -f "$destination/.accepted-$checksum" ]]; then
  test -x "$destination/bin/clang++"
  echo "$arch: reusing the accepted repository toolchain from cache"
  exit 0
fi
cache="$root/build-temp/accepted-toolchain-downloads"
mkdir -p "$cache" "$destination"
archive="$cache/$filename"
if [[ ! -f "$archive" ]] || ! echo "$checksum  $archive" | sha256sum -c -; then
  headers=(-H 'Accept: application/octet-stream' -H 'User-Agent: qt-sdk-toolchain')
  [[ -z "${GITHUB_TOKEN:-}" ]] || headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  curl -fsSL --retry 5 --connect-timeout 30 "${headers[@]}" "$url" -o "$archive.tmp"
  echo "$checksum  $archive.tmp" | sha256sum -c -
  mv "$archive.tmp" "$archive"
fi
if [[ ! -f "$destination/.accepted-$checksum" ]]; then
  # Reject changing an existing toolchain in place: mixed installations must
  # not become accepted merely by writing the new archive's marker.
  if [[ -n "$(ls -A "$destination")" ]]; then
    echo "Move the previous toolchain before changing the pinned archive: $destination" >&2
    exit 1
  fi
  tar -xJf "$archive" -C "$destination"
  touch "$destination/.accepted-$checksum"
fi
echo "$arch: using checksum-verified repository toolchain $filename"
