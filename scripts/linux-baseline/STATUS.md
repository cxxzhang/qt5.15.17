# Linux baseline progress (2026-11-11)

## Current requirements

Clang builds Qt against GNU headers/runtimes. x64/ARM64/MIPS64EL require
glibc <= 2.17, LoongArch old world <= 2.28 and new world <= 2.36.
The user cancelled C++20 as a gate and explicitly requested the oldest
practical GNU runtime requirements. A modern compiler may be reused with
old headers/runtimes: its version is not the runtime floor.
Keep all existing cache assets. Append validated replacements to the
single dedicated cache release `linux-toolchains-v1`; never overwrite
historical bytes. Linux acceptance precedes Windows/macOS execution.

## Historical Qt SDKs: pass their original gates, fail the new GNU floor

x64 Release/Debug build run `43007057520` and ARM64 run `43002661756`
passed independent extracted acceptance with bundled GNU 13 runtimes.
The four historical SDKs were subsequently inspected without rebuilding:
inspection runs `43016083628`, `43016088080`, `43016092102`, `43016096725`.
Every SDK actually needs GLIBCXX_3.4.32; QtCore needs up to 3.4.29 and
QtQml up to 3.4.32. They cannot be relabelled as using old system GNU
runtimes, or fixed by just removing their private runtime files.
See `evidence/gnu-runtime-inspection-20261111.json` for source commits,
artifact IDs and exact requirements. These SDKs are not final acceptance
of the user's latest requirement. No new Qt SDK release is published.

## Newly accepted native toolchains

Run `43015711265`, source `93a523881dcffc95290e2db00c3762a7a941787d`,
succeeded for both native targets and published additional hashed bundles.
These reuse static Clang 20 and image GNU 10 compiler support, but explicitly
select original CentOS 7 GNU 4.8.5 headers and shared runtimes. The compiler
support version is not a GCC 10 shared-runtime requirement. C++17 Clang
thread/string/exception probes require GLIBCXX_3.4.11 and run on glibc 2.17.
GCC 10 C++11 consumers using those old headers/runtimes also run after
relocation. The snapshot omits unrelated 32-bit multilib files.
Clang wrappers disable sized deallocation and aligned allocation to avoid
implicitly generating new runtime calls when using old standard headers.

`toolchains.lock.json` now pins these published native replacements.
New SDK jobs use system GNU runtimes, audit every ELF import/version and
verify the actual loader provider, with negative tests for wrong providers.
Qt itself uses C++11; the smoke consumer uses C++17 language features.
The initial low-runtime Qt builds exposed old-header assumptions in Qt
type traits, a pointer comparator, HarfBuzz traits and vector mutation
iterators. `Patches/0004-qtbase-clang-old-libstdcxx-traits.patch` preserves
the runtime floor while fixing those compile-time uses. HarfBuzz now has
an early translation-unit check before the full Qt build.
ARM64 compiled Core/Network/Gui before the latest two iterator fixes;
the complete SDK is still unaccepted. Native run `43028655734` at
`5c0b62f` retries Release/Debug for both targets. Do not restart live jobs
solely because observation takes time.

## All five low-runtime toolchains published; cross SDKs still incomplete

LoongArch preparation now reuses each original sysroot's GNU 8 / GNU 12
headers/runtimes instead of building libstdc++ 13. Old-world source patches
retain ELF flags 0x3; new world remains 0x43. Latest probe fixes address the
staging RPATH and avoid selecting a GDB Python script as the runtime ELF.
Old-world ICCCM, XCB-XKB and matching XKB-X11 libraries now pass their
source/ELF gates. Run `43027862457` at `472b483` completed relocation,
target execution and publication of the GNU 8 / glibc 2.28 bundle.
Its LLVM host aliases resolve private libffi even in clean environments,
while preserving multicall argv[0] and original executable payload bytes.

Run `43015725721` finished the GNU 4.9.4 / glibc 2.17 MIPS preparation.
Run `43020389433` reused that cache (GNU compilation was skipped), passed
graphics GLIBC/GNU symbol audits and published the replacement bundle.
Unused target Wayland-scanner/XML/ICU dependencies no longer raise its
GNU floor; cross builds use the already published native host scanner.
New-world run `43017704941` validated/published its original GNU 12 /
glibc 2.36 bundle with the full graphical supplement. All five replacements
are pinned in `toolchains.lock.json`; all older cache assets remain intact.

MIPS SDK run `43025278752` and new-world run `43025273164` at `57bc296`
were last observed live. A derived host link name adapts the native GNU
support's /lib64 linker script to Ubuntu's layout without changing cached
bytes. Baseline host GNU libraries are not globally injected into the
separately downloaded dynamic cross LLVM process.

Independent native verification now includes modern GCC and Clang C++17
consumers on Ubuntu 22.04, in addition to the baseline old-system run.
This new modern-consumer job has not passed against a complete new SDK yet.
The main all-platform workflow is now wired to the final five-target
acceptance gate (`565b34e`), including release-time proof/hash revalidation.
This wiring passed actionlint and the seven collector tests locally;
the complete SDK acceptance sequence has not passed yet. Complete all
Release/Debug SDKs and independent verification, then the Linux-first
Windows/macOS chain before the authorized SDK release.

## Workspace protection

Native ARM64 Debug in run `43036480483` completed Qt build/install,
stripped/audited 177 ELF/archive files and verified 155 ELF debug links plus
22 static archive symbol files. Its GNU report checks 151 files with no
missing imports: maximum GLIBCXX_3.4.19, CXXABI_1.3.7 and GCC_4.2.0.
It then failed compiling the C++17 extracted consumer because qflags.h used
the newer underlying_type_t alias with GNU 4.8 headers. The added qflags
patch uses equivalent C++11 underlying_type::type casts. Native builds now
check configured C++17 headers before compiling Qt, check installed headers
before compression, and retain unverified raw installs for packaging retries.
See `evidence/arm64-low-gnu-20261111.json`; it explicitly records that this
is GNU-import evidence and not final SDK acceptance. Artifact: 13865460806.

Update: native end-to-end run `43036480483` at `542cab2` is building
all four x64/ARM64 variants after the QtQuick old-header helper fix.
MIPS run `43025278752` and new-world run `43025273164` completed Qt
compilation and installation (226 and 210 audited ELF/archive files),
then failed after RPATH editing with a target-loader PT_LOAD alignment
error in libstdc++. Old-world run `43030047088` instead failed configure
because xcb-keysyms was absent. The next changes add its pinned source,
target page-size-aware RPATH editing, an actual strip/relocate/load probe
before expensive Qt compilation, and unverified raw-install caching.
These fixes still require actual Linux CI validation; no SDK is accepted.
At `5bb329c`, MIPS retry `43038651680` and new-world retry `43038658081`
use the new preflight and raw-install cache. Old-world supplement run
`43038645737` adds xcb-keysyms and publishes an additional immutable cache
asset only after toolchain relocation/runtime gates. Pin its new asset
before restarting old-world Qt builds. Existing assets are retained.

Preserve the six submodules' user untracked content. Keep the original
`HANDOFF-LINUX-PIPELINE.md` uncommitted. No product-icon changes remain.
