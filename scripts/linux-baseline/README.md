# Requested Linux baselines

This replaces the previous Ubuntu 18.04/Stretch/early-Debian-port build
baselines. Earlier successful SDKs are historical evidence and do not
satisfy the new requested limits.

| Target | Maximum required glibc | ABI distinction |
| --- | --- | --- |
| x64 | 2.17 | x86-64 |
| ARM64 | 2.17 | AArch64 |
| MIPS64EL | 2.17 | little-endian n64 |
| LoongArch old world | 2.28 | ELF flags 0x3, `/lib64/ld.so.1` |
| LoongArch new world | 2.36 | ELF flags 0x43, `/lib64/ld-linux-loongarch-lp64d.so.1` |

On 2026-11-11 the user authorized glibc 2.36 for the new-world target
when 2.28 is unavailable. The old-world limit remains 2.28. The upstream
new-world ABI starts at 2.36; merely rebuilding glibc 2.28 does not add
that architecture port. Never substitute the inspected 2.38 candidate.

`targets.json` is the target specification. All five targets retain Clang
and libstdc++; none may pass by raising the glibc limit or changing ELF
version metadata. Runtime checks must use the matching baseline loader and
libraries and must exercise the actual extracted SDK.

The initial native toolchain preparation runs x64 and ARM64 concurrently
inside manylinux2014/glibc 2.17 containers. It records the exact container
digest before execution, downloads checksum-pinned static Clang 20.1.8,
reuses the image's GNU tools together with its original CentOS 7 C++
headers and libstdc++ 4.8.5, then uses Clang to compile, audit and run
the thread/string/exception probe. Compiler age and runtime age are separate.
The C++20 requirement was explicitly cancelled on 2026-11-11. Qt builds
as C++11; an extracted SDK consumer checks C++17 language support without
requiring newer standard-library APIs. Native SDKs use the baseline system
GNU shared runtimes instead of forcing deployment of GCC 13 libraries.

Both GLIBC and GNU runtime requirements are acceptance gates. The GNU gate
checks imported symbols and their versions against the actual baseline
libstdc++/libgcc providers. It must cover every installed target ELF,
including plugins and tools. Newer compiler consumers must match the target
ABI; using new standard-library APIs can raise the application's own floor.

Container digest recording is a preparation step. Final SDK builds must
use the recorded digests as committed inputs. All five low-GNU-runtime
toolchain bundles have now been validated, published and pinned. Their
successful preparation does not constitute complete Qt SDK acceptance.

Acceptance requires Release and Debug SDKs, separate matching symbols,
ELF architecture/ABI/version/dependency checks, relocated Qt consumers,
and execution in the baseline environment. ARM64 is authorized to run
concurrently with the other Linux targets.

`MirrorLinuxLLVM.yml` verifies both original static LLVM archives on their
native glibc 2.17 runners before publishing a separate immutable compiler
mirror release. It preserves upstream archives, supplementary licenses, SHA256
and provenance. This mirror is not Qt SDK acceptance. GNU toolchains and
sysroots must also pass their runtime checks and be released before SDK
workflows consume pinned repository assets. Native compiler wrappers now
locate their installed GCC and LLVM relative to their own directory;
relocation of a complete sysroot bundle still requires separate validation.

The dedicated `linux-toolchains-v1` tag/release stores validated LLVM,
GNU support and sysroot bundles separately from Qt SDK releases. Archives
use content hashes in their names; existing different content is never
overwritten. Every archive has a SHA256 sidecar and source-run/commit/API
asset provenance. `targets.json` pins the native LLVM API assets there;
`toolchains.lock.json` pins complete accepted bundles for SDK jobs. Earlier
per-build toolchain releases remain historical; new uploads use the one
dedicated cache release.

The native LLVM mirror validation run was `42989460116`. The original static compiler
has X86/AArch64 backends but no MIPS/LoongArch backend; cross targets require
a separately validated compiler and must not silently use this native bundle.

After these targets pass, build every configured Windows/macOS platform,
verify the complete selected asset set, then publish the first release
from the rebuilt pipeline. Publication is explicitly authorized by the user.

`LinuxPipeline.yml` runs builds, independent extracted SDK verification,
modern GCC/Clang consumers for native SDKs, and a complete archive-hash
manifest gate. `BuildBinaries.yml` now calls this pipeline; Windows/macOS
jobs depend on its success. Release collection repeats the full five-target,
Release/Debug proof and hash checks and includes the acceptance manifest.
Use Linux-only dispatches while acceptance remains incomplete. No new Qt
SDK release has passed this complete sequence yet.

Cross jobs first strip and relocate a small C++ program and both GNU
runtimes, then execute it with the real target loader in the baseline root.
RPATH edits explicitly preserve target load-segment page alignment.
Completed raw Qt installs are cached separately as unverified inputs, bound
to source-module identities, build scripts, patches and both toolchain hashes.
Restoration always repeats packaging and runtime acceptance.
