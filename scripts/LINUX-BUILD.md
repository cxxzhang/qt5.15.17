# Linux Qt SDK builds

The native build uses an Ubuntu 18.04 container with Clang 18.1.8 and
GCC 13.3.0's libstdc++. The intended runtime baseline for x64 and ARM64 is
glibc 2.27. The pipeline rejects newer glibc requirements in SDK ELF files.
It does not bundle glibc or replace the target system's C library.

## Local builds

From the repository root on a Linux Docker host, run:

```bash
docker run --rm -v "$PWD:/workspace" -w /workspace ubuntu:18.04 \
  bash -ec 'bash scripts/setup-linux-toolchain.sh x64
    PATH=/workspace/build-temp/toolchain/bin:$PATH bash scripts/build-linux.sh x64 release'
```

Use `arm64` on an ARM64 host. Use `debug` instead of `release` for the
debug configuration. The `onekey-build-linux-*.sh` scripts call the same
build entry point; prepare the toolchain and put its `bin` directory on
`PATH` before using them. The setup script requires root for apt packages.

The toolchain directory is specific to the native host architecture. Do
not reuse an x64 toolchain cache for ARM64. GCC is built on Ubuntu 18.04.
Clang uses a compatible prebuilt archive on x64 and a source build on
ARM64. Neither path upgrades glibc.

Builds use new directories under `build-temp/linux-<arch>/`. Set
`QT_BUILD_JOBS` to limit parallel compilation. Move an existing
`Output/linux-<arch>` (or `Output/linux-<arch>-debug`) out of the way before
rebuilding; the script refuses to overwrite it.

## Packages and verification

Each successful build produces two archives, for example:

- `Output/qt5.15.17_linux_x64.tar.gz`: development SDK with stripped ELF files.
- `Output/qt5.15.17_linux_x64-symbols.tar.gz`: separate debugging information.

OpenSSL 1.1.1w is linked statically. Qt uses system FreeType, Fontconfig,
X11/XCB, Wayland and graphics libraries from the baseline distribution.
These system dependencies still need to be installed on the target.

The SDK carries `lib/libstdc++.so.6` and `lib/libgcc_s.so.1` built against
the old baseline. Its ELF files receive relative runtime search paths.
During the build, bootstrap tools use GCC's runtime directory through
`LD_LIBRARY_PATH`; dependency audits and runtime smoke checks remove that
variable so it cannot hide a broken package.

Before uploading, the pipeline audits ELF architecture, glibc version
requirements and native runtime dependency resolution. It extracts debug
information, strips ELF files and adds debug links. Static archives are
audited member by member and stripped with `--strip-debug`, preserving
their link symbols; their debug archives are saved separately. It then extracts the
SDK archive to a different directory and runs the relocated qmake to build
and execute a Qt GUI/network consumer with TLS support. The consumer uses
C++20 concepts, coroutines, span and ranges. This verifies those features;
it does not claim complete C++20 library coverage.

Applications that use the newer libstdc++ must deploy compatible C++
runtime libraries too. Place them in the application's private library
directory with an appropriate runtime search path; do not overwrite
system libraries. Build applications in the same baseline environment to
preserve their glibc compatibility.

The publishing gate also has a small functional test using real ELF
files, including rejection of incorrect architecture, excessive glibc
requirements and unresolved shared libraries:

```bash
bash scripts/test-package-linux.sh
```

## GitHub Actions

Pushes affecting the Linux workflow or scripts run the x64 release job
first. Manual `scope=linux-x64` does the same; `scope=linux` selects native
x64/ARM64 release and debug builds. `scope=all` waits for the Linux matrix
to pass before starting Windows/macOS. Publishing is disabled by default.

The workflow caches the prepared toolchain before compiling Qt, preserving
it even when Qt fails later. Build and toolchain logs, `config.log` and
`config.summary` are uploaded as `diagnostics-*` artifacts, including on
failure. Diagnostics are excluded from release packages.

## Remaining work

Native end-to-end CI verification is still in progress. LoongArch64 and
MIPS64EL cross builds are planned in
`openspec/changes/refactor-linux-build-release/` and are not selectable in
the current workflow. Their target sysroots, ABI and glibc limits must be
validated independently; the native glibc 2.27 claim does not apply to
those targets.
