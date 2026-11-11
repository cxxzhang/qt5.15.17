# Linux SDK acceptance

Accepted on 2026-11-12 (Asia/Singapore), GitHub Actions run `43062567326`,
source commit `b1cdae6ef59dfb5daf45e56cfdb9d87a023ff69e`.
The complete workflow finished successfully. Its original manifest is
preserved verbatim in `evidence/linux-acceptance-20261112.json`
(Actions artifact `13874202996`).

| Target | Release / Debug | GLIBC ceiling | Maximum GLIBCXX import | Maximum CXXABI import |
| --- | --- | --- | --- | --- |
| x64 | passed / passed | 2.17 | 3.4.19 | 1.3.7 |
| ARM64 | passed / passed | 2.17 | 3.4.19 | 1.3.7 |
| MIPS64EL LE n64 | passed / passed | 2.17 | 3.4.20 | 1.3.7 |
| LoongArch old world | passed / passed | 2.28 | 3.4.21 | 1.3.7 |
| LoongArch new world | passed / passed | 2.36 | 3.4.30 | 1.3.13 |

These are actual imported-symbol maxima, equal for both variants, rather
than compiler version claims. Old world retains ELF flags `0x3` and loader
`/lib64/ld.so.1`; new world retains `0x43` and
`/lib64/ld-linux-loongarch-lp64d.so.1`.

The run passed ten builds, ten independent extracted SDK verifiers, four
native modern GCC/Clang consumer jobs, and the exact-matrix/hash collector.
Checks cover architecture/ABI, GLIBC and GNU imports, real loader providers
and relocations, stripped binaries, matching debuglink CRCs/static archive
symbols, relocated qmake consumers, C++17 language mode, ordinary and wide
string round trips, offscreen GUI, QML, fonts, and a real loopback TLS exchange.
The manifest binds all twenty SDK/symbol archive hashes to one source run
and commit. Seven collector rejection/positive tests and workflow static
checks also pass; those infrastructure tests are additional evidence.

Native SDKs use system GNU runtimes compatible with the validated GNU 4.8.5
baseline. Cross SDKs deliver their original baseline GNU runtimes. Clang
builds Qt in every Linux target; native modern compiler tests consume the
same delivered SDK using the host's newer GNU runtime. C++20 is not a gate.
New application library APIs can raise that application's runtime floor.

All compiler/sysroot bundles are immutable repository assets pinned in
`toolchains.lock.json`. Old-world keysyms and MIPS liblzma supplements retain
their released base provenance; earlier assets remain available. SDK retries
reuse the prepared compilers and matching raw Qt installs, then repeat all
packaging and acceptance gates. ELF alignment work is internal packaging.

For native consumers, use qmake's normal compiler specification selection:

```sh
"$SDK/bin/qmake" -spec linux-clang app.pro
make
# Or use the same SDK with GCC:
"$SDK/bin/qmake" -spec linux-g++ app.pro
make
```

Install the target system's normal graphics/font dependencies. This
acceptance records the Linux matrix; Windows/macOS and the first rebuilt
multi-platform SDK release are tracked separately.
