#!/usr/bin/env bash
# Build a real n64 glibc 2.17 sysroot and its GNU support toolchain from source.
# Qt and its consumers use Clang; GCC supplies crt, libgcc and libstdc++.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
prefix="$root/build-temp/baseline-mips64el"
work="$root/build-temp/mips217-source-build"
mkdir -p "$prefix" "$work" "$root/build-temp/logs" "$root/build-temp/baseline-downloads"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get -o Acquire::Retries=5 update
sudo apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
  autoconf automake bison build-essential flex gawk gperf help2man libncurses-dev \
  libtool-bin patch python3 texinfo wget xz-utils unzip rsync libexpat1-dev
archive="$root/build-temp/baseline-downloads/crosstool-ng-1.26.0.tar.xz"
checksum=e8ce69c5c8ca8d904e6923ccf86c53576761b9cf219e2e69235b139c8e1b74fc
if [[ ! -f "$archive" ]] || ! echo "$checksum  $archive" | sha256sum -c -; then
  headers=(-H 'Accept: application/octet-stream')
  [[ -z "${GITHUB_TOKEN:-}" ]] || headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  curl -fsSL --retry 5 "${headers[@]}" \
    https://api.github.com/repos/crosstool-ng/crosstool-ng/releases/assets/127452677 -o "$archive"
  echo "$checksum  $archive" | sha256sum -c -
fi
tar -xf "$archive" -C "$work"
(
  cd "$work/crosstool-ng-1.26.0"
  ./configure --prefix="$work/ct-ng" --disable-nls
  make -j4
  make install
)
mkdir -p "$work/build"
cd "$work/build"
"$work/ct-ng/bin/ct-ng" mips64-unknown-linux-gnu
python3 - "$root" "$prefix" <<'PY'
from pathlib import Path
import sys
root, prefix = sys.argv[1:]
path = Path('.config')
values = {
    'CT_OBSOLETE': 'y', 'CT_ARCH_LE': 'y', 'CT_ARCH_BE': 'n',
    'CT_ARCH_ARCH': '"mips64r2"', 'CT_ARCH_FLOAT_HW': 'y',
    'CT_ARCH_mips_n64': 'y', 'CT_ARCH_64': 'y',
    'CT_GLIBC_V_2_17': 'y', 'CT_GCC_V_4_9': 'y', 'CT_LINUX_V_3_10': 'y',
    'CT_GLIBC_KERNEL_VERSION_CHOSEN': 'y',
    'CT_GLIBC_MIN_KERNEL_VERSION': '"3.10.0"',
    'CT_GLIBC_ENABLE_WERROR': 'n', 'CT_GCC_LIBSANITIZER': 'n',
    'CT_CC_LANG_CXX': 'y', 'CT_DEBUG_GDB': 'n',
    'CT_VERIFY_DOWNLOAD_DIGEST': 'y', 'CT_SAVE_TARBALLS': 'y',
    'CT_LOCAL_TARBALLS_DIR': '"' + root + '/build-temp/baseline-downloads"',
    'CT_PREFIX_DIR': '"' + prefix + '/gcc"',
    'CT_PREFIX_DIR_RO': 'n',
    'CT_PARALLEL_JOBS': '4', 'CT_LOG_EXTRA': 'y',
    'CT_LOG_TO_FILE': 'y', 'CT_LOG_FILE_COMPRESS': 'n',
}
families = ('CT_GLIBC_V_', 'CT_GCC_V_', 'CT_LINUX_V_')
lines = []
for line in path.read_text().splitlines():
    name = line.removeprefix('# ').split('=')[0].split(' is not set')[0]
    if name in values or name.startswith(families):
        continue
    lines.append(line)
lines += [('# ' + k + ' is not set') if v == 'n' else k + '=' + v for k, v in values.items()]
path.write_text('\n'.join(lines) + '\n')
PY
"$work/ct-ng/bin/ct-ng" olddefconfig
grep -q '^CT_GLIBC_VERSION="2.17"$' .config
grep -q '^CT_GCC_VERSION="4.9.4"$' .config
grep -q '^CT_ARCH_LE=y$' .config
grep -q '^CT_ARCH_mips_n64=y$' .config
cp .config "$root/build-temp/logs/mips217-crosstool.config"
trap 'cp build.log "$root/build-temp/logs/mips217-build.log" 2>/dev/null || true' EXIT
"$work/ct-ng/bin/ct-ng" build
sysroot="$(find "$prefix/gcc" -type d -name sysroot -print -quit)"
test -n "$sysroot"
chmod u+w "$sysroot"
touch "$sysroot/.sysroot-mips64el-2.17"
printf '%s\n' "${sysroot#"$prefix/"}" >"$prefix/sysroot-path.txt"
cp .config "$prefix/crosstool.config"
find "$prefix/gcc/bin" -maxdepth 1 -name '*gcc' -exec '{}' --version \;
echo 'Built MIPS64EL n64 GNU support toolchain and glibc 2.17 sysroot'
