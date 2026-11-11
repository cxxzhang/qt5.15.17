These supplementary notices accompany the original, unmodified static LLVM
archives from mayeut/static-clang-images v20.1.8.0. The upstream archives do
not contain license files. The upstream build recipe is:
https://github.com/mayeut/static-clang-images/blob/v20.1.8.0/Dockerfile

That recipe builds LLVM/Clang/LLD 20.1.8 and statically links the Alpine
3.22 GNU C++ runtime, musl, zlib and zstd. The notice source revisions in
sources.json identify the copied license texts, not a verified inventory
of the binary's dependency versions. The original build uses unpinned
Alpine packages. Exact dependency versions cannot be inferred from that
recipe alone. Preserve these notices when redistributing the binaries.

LLVM source: https://github.com/llvm/llvm-project/tree/llvmorg-20.1.8
Packaging source: https://github.com/mayeut/static-clang-images/tree/v20.1.8.0
Alpine source package recipes: https://gitlab.alpinelinux.org/alpine/aports/-/tree/3.22-stable
musl source: https://git.musl-libc.org/cgit/musl/
GCC source: https://gcc.gnu.org/releases.html
zlib source: https://github.com/madler/zlib
zstd source: https://github.com/facebook/zstd

The GNU runtime exception is included alongside GPLv3. These static
compiler dependencies are distinct from the GCC 13.3 target runtime built
and distributed by this repository's baseline toolchain workflow.
