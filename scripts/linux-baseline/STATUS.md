# Linux baseline progress (2026-11-11)

The requested limits remain x64/ARM64/MIPS64EL glibc 2.17 and both
LoongArch ABIs glibc 2.28. No Qt SDK has been accepted against all five
requested targets. Validate Linux first; Windows/macOS builds follow later.

## Published compiler inputs

Release `toolchain-llvm-20.1.8-v1` in this repository contains the original
static LLVM archives, supplementary license notices, provenance and checksums.
Validation run `42989460116` passed native compiler startup in the pinned
x64/ARM64 glibc 2.17 containers. `targets.json` pins repository asset IDs
734794935 (x64) and 734794943 (ARM64) and the unchanged upstream SHA256.
This compiler mirror is not Qt SDK acceptance. It has no MIPS/LoongArch backend.

## Native GNU support and sysroots

Full GCC 13.3 replaces standalone Clang-built native libstdc++. The first
ARM64 build completed GCC installation, then exposed an incorrect driver
triple; the driver now reads the newly installed GCC's `-dumpmachine`.
Run `42990454902` checks the corrected setup, matching ABI=0/1 shared C++
library interoperability, private runtime resolution and relocated toolchain
packaging. Results must be read before reporting acceptance or publication.

The reusable bundle contains GCC, LLVM, a real baseline glibc/header/CRT
sysroot, source pins, licenses and build scripts. The native workflow publishes
only after both architectures pass; it keeps a completed GNU installation
cached even when a later runtime/package check fails.

## MIPS64EL n64

Run `42986014393` completed the crosstool-ng GCC 13.2/glibc 2.17 build.
Its job failed when writing the sysroot marker because crosstool-ng made
the installed directory read-only. `CT_PREFIX_DIR_RO` is now disabled.
Run `42990771717` retries the fixed build and caches it before executing the
new Clang C++20/thread probe in a real target chroot with private GNU runtimes.
The cross compiler uses the vendor LLVM because the native static LLVM
does not include a MIPS backend. No MIPS toolchain release is published yet.

## LoongArch old world

The vendor Clang starts after extracting pinned Debian libffi6 into private
host libraries. Inspection run `42988766479` confirmed old-world compiler
objects with ELF flags 0x3 and a real candidate libc-2.28.so exporting
GLIBC_2.27/2.28. This is input inspection, not runtime acceptance.

Run `42991207254` builds libstdc++ 13.3 against that sysroot and executes
a Clang C++20/thread probe with `/lib64/ld.so.1` in a real target chroot.
Its wrappers are still preparation paths and must be made relocatable and
tested before releasing a complete toolchain.

## LoongArch new world: requested baseline unresolved

Inspection run `42990459326` records the separate official candidate
`debian_bullseye_loongarch64-sysroot.tar.bz2` (SHA256
`f5f7eb75744935f228afe7298c66e9faf3c52e3134787906290d5d479d8bb252`).
Its real libc is `usr/lib64/libc.so.6`, ELF flags 0x43, exporting
GLIBC_2.36 and GLIBC_2.38. It does not satisfy the requested 2.28 baseline.
The libc inspection now handles regular `libc.so.6` as well as older
`libc-VERSION.so` filenames.

The requested deployment distribution/version needs clarification to identify
whether a vendor-specific new-world glibc 2.28 environment exists. Do not
raise the accepted limit, relabel old-world libraries, or edit ELF flags or
symbol version metadata to make this target pass.

## Remaining integration

The main `BuildBinaries.yml` still uses the historical Linux implementation.
Do not dispatch its old Linux jobs as acceptance of these baselines. Full
Qt dependency sysroots, the new five-target SDK jobs, Release/Debug runtime
and symbol checks, and independent extracted SDK verification remain to be
completed before an SDK release. Existing Windows/macOS changes and user
submodule untracked files are preserved. The user's original handoff document
remains uncommitted.
