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
The new four-variant native build has been dispatched at `a97010d`.
Read the live CI result before claiming SDK acceptance.

## Cross targets still incomplete

LoongArch preparation now reuses each original sysroot's GNU 8 / GNU 12
headers/runtimes instead of building libstdc++ 13. Old-world source patches
retain ELF flags 0x3; new world remains 0x43. Latest probe fixes address the
staging RPATH and avoid selecting a GDB Python script as the runtime ELF.
Old-world graphics still require matching ICCCM/XKB-X11 libraries; recipes
are pinned in `oldworld-graphics.lock.json`. Graphics source audits use the
vendor compiler's private host-library environment.

A lower-runtime MIPS source preparation run `43015725721` is still live;
do not restart it solely because observation takes time. Earlier GNU 13
MIPS bundles remain in the cache release. Remaining graphics dependencies
must also pass GNU symbol compatibility before publishing a replacement.
The main all-platform workflow remains unwired to the final five-target
acceptance gate. Complete all Release/Debug SDKs, independent verification,
then the Linux-first Windows/macOS chain before the authorized SDK release.

## Workspace protection

Preserve the six submodules' user untracked content. Keep the original
`HANDOFF-LINUX-PIPELINE.md` uncommitted. No product-icon changes remain.
