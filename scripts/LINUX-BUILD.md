# Linux Qt SDK builds

The current requested glibc limits are x64/ARM64/MIPS64EL 2.17 and both
LoongArch worlds 2.28. See `linux-baseline/README.md` for the replacement
pipeline. The instructions and results below describe the superseded
2.27/2.24/2.36 implementation and are retained as historical reference.

The native build uses an Ubuntu 18.04 container with Clang 18.1.8 and
GCC 13.3.0's libstdc++. The intended runtime baseline for x64 and ARM64 is
glibc 2.27. The pipeline rejects newer glibc requirements in SDK ELF files.
It does not bundle glibc or replace the target system's C library.

`scripts/linux-toolchain.lock.json` pins the container manifest digest and
the SHA-256 of each compiler/source archive. GitHub release assets are
downloaded through the GitHub API. The manual **Record fixed Linux toolchain
source digests** workflow records these values and checks GCC's upstream
SHA-512 manifest before a maintainer updates the lock file.

## Local builds

From the repository root on a Linux Docker host, run:

```bash
qt_container=$(python3 -c 'import json; print(json.load(open("scripts/linux-toolchain.lock.json"))["container"]["image"])')
docker run --rm -v "$PWD:/workspace" -w /workspace "$qt_container" \
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
Before upload, it also verifies the separate symbol archive against the
extracted SDK's debuglink filenames and CRCs.

The consumer performs a TLS 1.2 handshake and exchanges encrypted data over
the loopback interface. `scripts/smoke-tls/` contains its public self-signed
test certificate and key. Peer verification is disabled for this fixture;
the check verifies TLS operation without external network or CA services.

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
and both cross-target variants to pass before starting Windows/macOS.
`scope=linux` also runs LoongArch64/MIPS64EL release and debug builds through
the reusable cross workflow. Publishing is disabled by default.

The workflow caches the prepared toolchain before compiling Qt, preserving
it even when Qt fails later. Build and toolchain logs, `config.log` and
`config.summary` are uploaded as `diagnostics-*` artifacts, including on
failure. Diagnostics are excluded from release packages.

The manual **Verify an extracted Linux SDK** workflow takes the producing
workflow's run ID, architecture and variant. It downloads the SDK and
symbols, extracts into a fresh baseline container without the original Qt
build or install directory, audits the extracted ELF files and dependencies,
then builds and runs the qmake consumer. Compiler and target sysroot caches
are reused; the extracted SDK comes exclusively from the selected artifact.
The symbol check reads the delivered archive and verifies each ELF debug
file's GNU debuglink filename and CRC, checks static-archive counterparts,
and rejects missing files referenced by generated debug links.

## Cross targets and acceptance status

| Target | Selected sysroot | glibc ceiling | ABI |
| --- | --- | --- | --- |
| x64 | Ubuntu 18.04 | 2.27 | x86-64 |
| ARM64 | Ubuntu 18.04 | 2.27 | AArch64 |
| MIPS64EL | Debian Stretch | 2.24 | little-endian n64 |
| LoongArch64 | early Debian port plus source-built graphics dependencies | 2.36 | LP64D, ELF object ABI v1 |

These are the configured verification ceilings. Full matrix acceptance is
still in progress; they are not a claim that every target already passed.
ARM64 verification is deferred while the other Linux targets are being fixed.
glibc 2.17 was discussed as a possible later target and has not been selected.

The manual **Check Linux cross toolchains** workflow can select either cross
architecture. Its default runs only the toolchain test. Set `build_sdk=true`
to continue to the complete Qt SDK build and `variant=release` or `debug`.
The toolchain test runs C++20 concepts, coroutines, span and ranges with a
POSIX thread and mutex under pinned QEMU. It must pass before Qt is built.

Cross builds use the same Clang 18/libstdc++ 13 generation. The standard
library is rebuilt against each target's own headers and C library. MIPS
uses a pinned GNU linker for n64 exception-frame relocations; Clang remains
the C/C++ compiler. LoongArch's missing graphics libraries are built from
checksummed source against glibc 2.36, rather than borrowing a newer glibc
dependency stack. The resulting compatibility libraries are included in
the SDK's private library directory.

Cross SDKs keep x64 host tools in `host/`, with a separate private host C++
runtime (glibc <= 2.27). Invoke `host/bin/qmake` on the build host. Target
libraries and programs use the target ABI and glibc ceiling above. The
external target compiler/sysroot paths in `host/bin/qt.conf` and the installed
cross mkspec must be configured when consuming the SDK on a different host.

Qt 5.15's QML JIT does not support these two cross targets. QML is built
with its interpreter and tested by creating a QML object after SDK extraction.
The cross build also patches QML's packed engine structure to align pointer
members on 64-bit targets. The unpatched structure triggered SIGBUS on
MIPS64EL when a pointer member was passed by reference during QML evaluation.
OpenSSL uses its portable C implementation on the cross targets. The SDK
consumer also checks system font discovery through FreeType/Fontconfig.
Target dependency closure is resolved using the target's actual glibc loader
under QEMU, including symbol versions and the SDK's private C++ runtime paths.
This does not exercise desktop display servers or hardware GPU drivers.
