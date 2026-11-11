# Linux pipeline acceptance evidence

Updated 2026-11-11. Acceptance of the full pipeline is still in progress.
Run numbers identify GitHub Actions runs in `cxxzhang/qt5.15.17`.

| Target | Variant | SDK build and upload | Independent extracted SDK test |
| --- | --- | --- | --- |
| x64 | Release | Passed, run `42955634377` | Passed, run `42966673803` |
| x64 | Debug | Passed, run `42960048140` | Passed, run `42966678486` |
| MIPS64EL | Release | Passed MIPS job in run `42969467526` | Passed, run `42972856514` |
| MIPS64EL | Debug | Pending | Pending |
| LoongArch64 | Release | Graphics dependencies passed; Qt architecture patch pending verification | Pending |
| LoongArch64 | Debug | First Qt build in progress | Pending |
| ARM64 | Release / Debug | Deferred until the other Linux targets pass | Pending |

The independent x64 tests used commit `337fb784`, downloaded each SDK from
its producing run, and ran in a fresh Ubuntu 18.04 container without the
original Qt build or installation. They checked stripped ELF files, glibc
requirements, dependency resolution and the separate symbols archive, then
built and ran a qmake consumer. The consumer exercised C++20 concepts,
coroutines, span and ranges; an offscreen GUI; QML object creation; system
font discovery; and a TLS 1.2 handshake with encrypted loopback traffic.

MIPS run `42963764883` passed the static audit of 167 ELF files/archives
against glibc 2.24 and resolved dependencies of 145 dynamic ELF files using
the target loader. Its extracted consumer then received SIGBUS while
running QML. This is a failed acceptance result, not a usable SDK release.
Diagnostic run `42968147029` reproduced it with the existing compiled SDK.
GDB located a 64-bit `ld` from `EngineBase::globalObject` at offset 60;
the packed field was not 8-byte aligned. A cross-build patch adds padding
and compile-time pointer alignment assertions. The MIPS Release job in run
`42969467526` then passed its complete SDK build, audits, relocated consumer
and TLS exchange. The parent workflow failed its separate, older LoongArch
job; this does not represent a successful full Linux matrix. Independent
MIPS artifact verification passed in run `42972856514`, auditing 167 ELF
files/archives and resolving 145 dynamic ELF files before the C++20/GUI/QML/
fonts/TLS consumer passed. The Debug build is still in progress.

The LoongArch glibc 2.36 sysroot needs source-built graphics dependencies.
Run `42966136435` compiled and installed libxcb, then stopped because the
host lacked gperf for xcb-util. The host dependency was added in `aa5fec88`;
run `42967432245` then passed xcb-util and reached xcb-util-image. It exposed
libtool following an absolute target library path outside the sysroot. The
dependency configure commands now pass libtool's explicit `--with-sysroot`;
run `42968482270` then built the XCB, Wayland, xkbcommon and GLVND libraries.
The final GLU dependency needed an explicit `stddef.h` include for `NULL`
with the newer GL headers. Run `42969467526` passed that C compilation and
then reached legacy C++ code using `register`, which Clang's default C++17
rejects. GLU now compiles as C++11 with the same Clang/libstdc++ toolchain;
the Qt SDK consumer remains C++20. Run `42970606668` completed GLU's C/C++
compilation, then its older libtool could not read the newer GLVND `.la`
sysroot metadata. Source dependency installs now retain the shared libraries
and pkg-config files while omitting `.la` files. Run `42971725995` then
passed all graphics dependencies and their glibc 2.36 audit and entered the
Qt SDK build. Qt's bundled Double-Conversion did not recognize LoongArch;
the Qt architecture patch now includes the same LoongArch detection as
upstream Double-Conversion. The next run must prove the complete Qt SDK.

The fixed upstream toolchain digests were recorded successfully in run
`42964385726` and committed in `69020f2c`. Configured target baselines and
local build instructions are in `LINUX-BUILD.md`.

Full acceptance also requires the remaining Linux variants, independent
cross-target artifact tests, the Linux gates, and the subsequent
Windows/macOS builds and package collection. These have not passed yet.
