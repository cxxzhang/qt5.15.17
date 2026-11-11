#!/usr/bin/env bash
# Preserve upstream archives byte-for-byte after checking their native compiler.
set -euo pipefail
arch="${1:?x64 or arm64 required}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test "$(getconf GNU_LIBC_VERSION)" = 'glibc 2.17'
if [[ ! -x /opt/python/cp311-cp311/bin/python3 ]]; then
  manylinux-interpreters ensure cp311-cp311
fi
export PATH="/opt/python/cp311-cp311/bin:$PATH"
out="$root/build-temp/llvm-mirror-$arch"
mkdir -p "$out" "$out/extracted"
read -r url checksum < <(python3 - "$root/scripts/linux-baseline/targets.json" "$arch" <<'PY'
import json, sys
entry = json.load(open(sys.argv[1]))['clang'][sys.argv[2]]
print(entry.get('upstream_api_url', entry['api_url']), entry['sha256'])
PY
)
archive="static-clang-linux-$arch.tar.xz"
curl -fsSL --retry 5 -H 'Accept: application/octet-stream' \
  -H "Authorization: Bearer ${GITHUB_TOKEN:?}" "$url" -o "$out/$archive"
echo "$checksum  $out/$archive" | sha256sum -c -
tar -xf "$out/$archive" -C "$out/extracted"
"$out/extracted/clang/bin/clang++" --version | tee "$out/version-$arch.txt"
grep -q '20.1.8' "$out/version-$arch.txt"
test -x "$out/extracted/clang/bin/ld.lld"
python3 - "$out" "$url" "$checksum" "$arch" "$archive" "$root" <<'PY'
import hashlib, json, sys, tarfile
from pathlib import Path
out, url, sha, arch, archive, root = sys.argv[1:]
out = Path(out)
with tarfile.open(out / archive) as tar:
    licenses = [m.name for m in tar if m.isfile() and
                any(k in Path(m.name).name.lower() for k in ('license', 'copying'))]
license_root = Path(root) / 'scripts/linux-baseline/llvm-licenses'
for entry in json.loads((license_root / 'sources.json').read_text()):
    if hashlib.sha256((license_root / entry['file']).read_bytes()).hexdigest() != entry['sha256']:
        raise SystemExit('License text checksum mismatch: ' + entry['file'])
with tarfile.open(out / ('licenses-' + arch + '.tar.gz'), 'w:gz') as tar:
    tar.add(license_root, arcname='licenses')
record = dict(upstream_api_url=url, sha256=sha, archive=archive, arch=arch,
              version='20.1.8', host_glibc='2.17', embedded_licenses=licenses,
              supplementary_licenses='licenses-' + arch + '.tar.gz',
              validation='clang++ --version and ld.lld executable in manylinux2014')
(out / ('provenance-' + arch + '.json')).write_text(json.dumps(record, indent=2) + '\n')
(out / ('sha256-' + arch + '.txt')).write_text(sha + '  ' + archive + '\n')
PY
