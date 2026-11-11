#!/usr/bin/env bash
# Inspect the vendor's two-world Clang and old-world sysroot before pinning/building.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$root/build-temp/loong28-inspection"
mkdir -p "$work/downloads" "$work/compiler" "$work/sysroot" "$root/build-temp/logs"
fetch() {
  local name="$1" url="$2"
  if [[ ! -s "$work/downloads/$name" ]]; then
    curl -fSL --retry 5 --connect-timeout 30 --max-time 1200 "$url" -o "$work/downloads/$name.tmp"
    mv "$work/downloads/$name.tmp" "$work/downloads/$name"
  fi
  sha256sum "$work/downloads/$name" >>"$root/build-temp/logs/loong28-source-sha256.txt"
}
fetch llvm20.tar.gz https://ftp.loongnix.cn/toolchain/llvm/llvm20/llvm-toolchain_20.1.8-1_amd64-linux-gnu_debian-10.tar.gz
fetch sysroot.tar.bz2 https://ftp.loongnix.cn/browser/build/sysroot/debian_bullseye_loong64-sysroot.tar.bz2
tar -xf "$work/downloads/llvm20.tar.gz" -C "$work/compiler"
tar -xf "$work/downloads/sysroot.tar.bz2" -C "$work/sysroot"
compiler="$(find "$work/compiler" -type f -name clang -print -quit)"
if [[ -z "$compiler" ]]; then
  compiler="$(find "$work/compiler" -type f -name 'clang-[0-9]*' -print -quit)"
fi
test -n "$compiler"
"$compiler" --version
"$compiler" --print-targets
printf 'int probe(void) { return 42; }\n' >"$work/probe.c"
python3 - "$work" "$compiler" <<'PY'
import json, re, struct, subprocess, sys
from pathlib import Path
work, compiler = Path(sys.argv[1]), sys.argv[2]
report = {'compiler': compiler, 'objects': [], 'libc': [], 'crt': []}
for triple in ('loongarch64-linux-gnu', 'loongarch64-unknown-linux-gnu', 'la64-linux-gnu'):
    for abi in ('default', 'lp64d', 'lp64'):
        output = work / (triple + '-' + abi + '.o')
        command = [compiler, '--target=' + triple, '-c', str(work / 'probe.c'), '-o', str(output)]
        if abi != 'default': command += ['-mabi=' + abi]
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        entry = {'triple': triple, 'abi': abi, 'returncode': result.returncode, 'output': result.stdout}
        if result.returncode == 0:
            data = output.read_bytes()[:64]
            entry.update(machine=struct.unpack_from('<H', data, 18)[0],
                         flags=hex(struct.unpack_from('<I', data, 48)[0]))
        report['objects'].append(entry)
for path in (work / 'sysroot').rglob('*'):
    if not path.is_file() or path.is_symlink(): continue
    if path.name in ('crt1.o', 'Scrt1.o', 'crtbegin.o', 'libgcc_s.so.1'):
        report['crt'].append(str(path.relative_to(work)))
    if not re.fullmatch(r'libc-[0-9.]+\.so', path.name): continue
    with path.open('rb') as stream: data = stream.read(64)
    versions = subprocess.check_output(['readelf', '-V', str(path)], text=True)
    names = sorted(set(re.findall(r'GLIBC_[0-9.]+', versions)),
                   key=lambda v: tuple(map(int, v[6:].split('.'))))
    report['libc'].append({'path': str(path.relative_to(work)),
                          'machine': struct.unpack_from('<H', data, 18)[0],
                          'flags': hex(struct.unpack_from('<I', data, 48)[0]),
                          'symbol_versions': names})
target = Path('build-temp/logs/loong28-inspection.json')
target.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
if not report['libc']: raise SystemExit('No target libc identified in the candidate sysroot')
PY
