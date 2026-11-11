param(
    [string]$InstallDir,
    [ValidateSet('environment','release','debug')][string]$Variant = 'environment'
)
$ErrorActionPreference = 'Stop'
function Canonical([string]$Path) {
    return [IO.Path]::GetFullPath($Path.Trim('"')).TrimEnd('\')
}
function Entries([string]$Value) {
    return @($Value.Split(';') | Where-Object { $_.Trim() } | ForEach-Object { Canonical $_ })
}
$platforms = @{ x86='Win32'; x64='x64'; arm64='arm64' }
$versions = @{ x86='5.1.2600.0'; x64='5.2.3790.0'; arm64='10.0.10240.0' }
$arch = $env:Platform.ToLowerInvariant()
if (-not $platforms.ContainsKey($arch) -or $env:LTLPlatform -ne $platforms[$arch]) {
    throw 'VC-LTL target architecture was not initialized correctly'
}
if ($env:InternalLTLCRTVersion -ne $versions[$arch] -or $env:VC_LTL_Helper_Load -ne 'true') {
    throw 'VC-LTL runtime selection did not take effect'
}
if ($env:VCToolsVersion -notlike '14.44.*') { throw 'SDK builds require MSVC 14.44' }
$ltlRoot = Canonical $env:VC_LTL_Root
$headers = @(Entries $env:INCLUDE)
$libraries = @(Entries $env:LIB)
$header = Canonical (Join-Path $ltlRoot 'TargetPlatform/header')
$versionHeader = Canonical (Join-Path $ltlRoot "TargetPlatform/$($versions[$arch])/header")
$library = Canonical (Join-Path $ltlRoot "TargetPlatform/$($versions[$arch])/lib/$($platforms[$arch])")
$headerIndex = [Array]::IndexOf(@($headers | ForEach-Object { $_.ToLowerInvariant() }), $header.ToLowerInvariant())
$libraryIndex = [Array]::IndexOf(@($libraries | ForEach-Object { $_.ToLowerInvariant() }), $library.ToLowerInvariant())
if ($headerIndex -lt 0 -or $headerIndex + 1 -ge $headers.Count -or $headers[$headerIndex + 1] -ne $versionHeader -or $libraryIndex -lt 0) {
    throw 'VC-LTL headers or libraries are absent from the compiler environment'
}
foreach ($path in @($headers | Select-Object -First $headerIndex) + @($libraries | Select-Object -First $libraryIndex)) {
    if ($path -match '(?i)[\\/]Microsoft Visual Studio[\\/]|[\\/]Windows Kits[\\/]') {
        throw "A system compiler/runtime path precedes VC-LTL: $path"
    }
}
foreach ($name in 'libucrt.lib','libucrtd.lib','libvcruntime.lib','libvcruntimed.lib') {
    if (-not (Test-Path -LiteralPath (Join-Path $library $name))) { throw "Missing VC-LTL library: $name" }
    foreach ($path in $libraries | Select-Object -First $libraryIndex) {
        if (Test-Path -LiteralPath (Join-Path $path $name)) { throw "Another library shadows VC-LTL: $name" }
    }
}
$record = [ordered]@{
    schema = 1; vc_ltl_active = $true; target_arch = $arch; variant = $Variant
    toolset_version = $env:VCToolsVersion; visual_studio_version = $env:VisualStudioVersion
    runtime_version = $versions[$arch]; platform = $platforms[$arch]
    header_paths = @($header,$versionHeader); library_path = $library
    source_commit = $env:GITHUB_SHA; source_run = $env:GITHUB_RUN_ID
    checks = @('VC-LTL header precedence','VC-LTL library precedence','release and debug CRT libraries present','matching target platform')
}
if ($InstallDir) {
    if ($Variant -eq 'environment') { throw 'Installed SDK proof requires a release/debug variant' }
    $core = if ($Variant -eq 'debug') { 'Qt5Cored.dll' } else { 'Qt5Core.dll' }
    foreach ($file in @('bin/qmake.exe', "bin/$core")) {
        if (-not (Test-Path -LiteralPath (Join-Path $InstallDir $file))) { throw "Installed SDK is missing $file" }
    }
    $destination = Join-Path $InstallDir 'share/ci-windows-toolchain.json'
} else {
    $destination = Join-Path $PSScriptRoot '../build-temp/logs/vc-ltl-env.json'
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
[IO.File]::WriteAllText([IO.Path]::GetFullPath($destination), ($record | ConvertTo-Json -Depth 5) + "`n", [Text.UTF8Encoding]::new($false))
Write-Output "Verified VC-LTL $($versions[$arch]) for $arch with MSVC $env:VCToolsVersion (VS $env:VisualStudioVersion)"
