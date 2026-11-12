# Native SDK debug symbols

New full releases publish three macOS `-symbols.tar.gz` archives and six
Windows `-symbols.zip` archives alongside the binary SDKs. Linux's ten
existing symbol archives remain unchanged. This adds nine assets, making
41 assets in a complete release.

Windows PDBs are removed from the binary SDK ZIP. All installed PDBs are
preserved with their original relative paths in the symbol ZIP. Before
packaging and again after extraction, every executable/DLL with an RSDS
debug record must have exactly one matching PDB GUID and age. PDBs for
static libraries are retained too. Bootstrap qmake has no RSDS/PDB in the
existing compiler outputs; the manifest does not claim a source PDB for it.

macOS builds keep debug information through installation. `dsymutil` runs
before build objects disappear; dSYM UUIDs must match their binaries and
`dwarfdump --verify` must succeed. Packaging strips a copy of the SDK,
preserving externally required symbols, and refreshes ad-hoc signatures.
Native dSYMs are merged with `lipo` for the universal SDK. Static libraries
retain their original DWARF-bearing archives in the symbol package, since
dSYM is for linked Mach-O images. Bootstrap qmake's original symbol table
is retained separately when it has no source DWARF.

Each symbol archive contains `native-symbols.json`, binding binary hashes,
symbol hashes and debug identities to the packaging run and source commit.
Independent SDK consumers check complete coverage and the exact symbol
archive hash. Release collection binds both archives to those verifiers.
The first symbol-enabled macOS build must rebuild: old SDK archives cannot
reconstruct DWARF after the original object files have disappeared.

For Windows, extract the symbol ZIP over the corresponding SDK, or add its
extracted directory to the debugger's symbol search path. For macOS, add
the matching `.dSYM` bundle from the symbol archive to LLDB's symbol files.
Always use the symbol archive from the same release and architecture.
