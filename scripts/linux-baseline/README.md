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
| LoongArch new world | 2.28 | ELF flags 0x43, `/lib64/ld-linux-loongarch-lp64d.so.1` |

`targets.json` is the target specification. All five targets retain Clang
and libstdc++; none may pass by raising the glibc limit or changing ELF
version metadata. Runtime checks must use the matching baseline loader and
libraries and must exercise the actual extracted SDK.

The initial native toolchain preparation runs x64 and ARM64 concurrently
inside manylinux2014/glibc 2.17 containers. It records the exact container
digest before execution, downloads checksum-pinned static Clang 20.1.8,
builds libstdc++ 13.3 against that old libc, and compiles, audits and runs
the C++20/thread probe with the selected private C++ runtime.

Container digest recording is a preparation step. Final SDK builds must
use the recorded digests as committed inputs. Cross-target sysroots and
toolchains are still being prepared against the exact limits above.

Acceptance requires Release and Debug SDKs, separate matching symbols,
ELF architecture/ABI/version/dependency checks, relocated Qt consumers,
and execution in the baseline environment. ARM64 is authorized to run
concurrently with the other Linux targets.

After these targets pass, build every configured Windows/macOS platform,
verify the complete selected asset set, then publish the first release
from the rebuilt pipeline. Publication is explicitly authorized by the user.
