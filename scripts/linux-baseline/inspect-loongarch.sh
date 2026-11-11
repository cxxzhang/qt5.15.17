#!/usr/bin/env bash
# Inspect the vendor's two-world Clang and old-world sysroot before pinning/building.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$root/build-temp/loong28-inspection"
mkdir -p "$work/downloads" "$work/compiler" "$work/sysroot" "$root/build-temp/logs"
fetch() {
  local name="$1" url="$2" checksum="${3:-}"
  if [[ ! -s "$work/downloads/$name" ]]; then
    curl -fSL --retry 5 --connect-timeout 30 --max-time 1200 "$url" -o "$work/downloads/$name.tmp"
    mv "$work/downloads/$name.tmp" "$work/downloads/$name"
  fi
  if [[ -n "$checksum" ]]; then
    echo "$checksum  $work/downloads/$name" | sha256sum -c -
  fi
  sha256sum "$work/downloads/$name" >>"$root/build-temp/logs/loong28-source-sha256.txt"
}
fetch llvm20.tar.gz https://ftp.loongnix.cn/toolchain/llvm/llvm20/llvm-toolchain_20.1.8-1_amd64-linux-gnu_debian-10.tar.gz b552f93326948c7292cceaf11db7eb442327448d9f45b4b25eafdbfa9b60c25e
fetch sysroot.tar.bz2 https://ftp.loongnix.cn/browser/build/sysroot/debian_bullseye_loong64-sysroot.tar.bz2 34efb077fed691feac2605ec9656c8ecb40e63076fdb76ae06df90f279099a64
# The new-world candidate is inspection-only until its actual libc/ABI are
# reviewed. Never publish it based on its name.
fetch sysroot-newworld.tar.bz2 https://ftp.loongnix.cn/browser/build/sysroot/debian_bullseye_loongarch64-sysroot.tar.bz2 f5f7eb75744935f228afe7298c66e9faf3c52e3134787906290d5d479d8bb252
fetch libffi6.deb https://archive.debian.org/debian/pool/main/libf/libffi/libffi6_3.2.1-9_amd64.deb d4d748d897e8e53aa239ead23a18724a1a30085cc6ca41a8c31b3b1e1b3452f4
# This vendor compiler targets Debian 10 hosts. Keep its legacy libffi
# private to this invocation; never replace the runner's system libraries.
mkdir -p "$work/host-libs"
dpkg-deb -x "$work/downloads/libffi6.deb" "$work/host-libs"
export LD_LIBRARY_PATH="$work/host-libs/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
tar -xf "$work/downloads/llvm20.tar.gz" -C "$work/compiler"
tar -xf "$work/downloads/sysroot.tar.bz2" -C "$work/sysroot"
tar -xf "$work/downloads/sysroot-newworld.tar.bz2" -C "$work/sysroot"
compiler="$(find "$work/compiler" -type f -name clang -print -quit)"
if [[ -z "$compiler" ]]; then
  compiler="$(find "$work/compiler" -type f -name 'clang-[0-9]*' -print -quit)"
fi
test -n "$compiler"
ldd "$compiler" | tee "$root/build-temp/logs/loong28-host-dependencies.txt"
if grep -q 'not found' "$root/build-temp/logs/loong28-host-dependencies.txt"; then
  echo 'Vendor compiler still has unresolved host dependencies' >&2
  exit 1
fi
"$compiler" --version
"$compiler" --print-targets
"$compiler" --help-hidden >"$root/build-temp/logs/loong28-compiler-options.txt"
find "$work/compiler" -name '*clang*' -print >"$root/build-temp/logs/loong28-compiler-files.txt"
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
    if not (re.fullmatch(r'libc-[0-9.]+\.so', path.name) or path.name == 'libc.so.6'): continue
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
