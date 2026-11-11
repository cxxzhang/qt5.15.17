# Windows SDK packaging and acceptance

The six Windows variants retain the existing one-key build scripts,
qmake/nmake, VC-LTL and YY-Thunks. MSVC 14.44 is the validated toolset.

The delivered ZIP contains the YY-Thunks objects referenced by its mkspecs
and static-module PRLs. Their paths resolve inside the extracted SDK.
Matching VC-LTL headers and libraries are included and selected by the
installed mkspec, so applications use the same CRT as the Qt DLLs. Mixing
the default MSVC CRT with these DLLs can corrupt the heap when an exported
STL conversion allocates a string in Qt and the application frees it.

From a matching MSVC developer command prompt, ordinary qmake use is:

```bat
C:\Qt\5.15.17\bin\qmake.exe app.pro
nmake
```

Each CI variant extracts its final ZIP into a fresh temporary directory
with spaces, outside the source checkout, and builds/runs two applications:
the C++17 string/GUI/QML/font/TLS probe and a static UiTools consumer.
Offscreen tests use the runner's Windows fonts. They do not activate a
source-tree VC-LTL environment or add custom application library paths.
The release collector checks the exact verified ZIP hash, target, variant,
source identity, runtime files, licenses and object architectures.

The bundled VC-LTL files come from the existing v5.2.2 binary dependency;
its original readmes and EPL-2.0 license are included. Source is available
in `Chuyu-Team/VC-LTL5` on GitHub. YY-Thunks retains its MIT license.

The local x64 proof in `evidence/windows-portable-sdk-20261112.json` is a
preflight only. Publication requires all six independent CI consumers.
