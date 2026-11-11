@setlocal

@echo off
set "SCRIPT_DIR=%~dp0"

set "VisualStudioInstallerFolder=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer"
if "%PROCESSOR_ARCHITECTURE%"=="x86" set "VisualStudioInstallerFolder=%ProgramFiles%\Microsoft Visual Studio\Installer"

set "VSWHERE_EXE=%VisualStudioInstallerFolder%\vswhere.exe"
if not exist "%VSWHERE_EXE%" (
  echo vswhere not found at "%VSWHERE_EXE%"
  exit /b 1
)
for /f "usebackq tokens=*" %%i in (`"%VSWHERE_EXE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do (
  set "VisualStudioInstallDir=%%i"
)

rem MSVC 14.51 ARM64 hits C1001 in optimized QtQuick hash code. Use the
rem installed stable 14.44 toolset with native ARM64 host tools.
call "%VisualStudioInstallDir%\Common7\Tools\VsDevCmd.bat" -no_logo -arch=arm64 -host_arch=arm64 -vcvars_ver=14.44
if %ERRORLEVEL% NEQ 0 exit /B %ERRORLEVEL%
if not "%VCToolsVersion:~0,5%"=="14.44" (
  echo Expected the installed MSVC 14.44 ARM64 toolset, got %VCToolsVersion%.
  exit /B 1
)
echo Using native ARM64 MSVC %VCToolsVersion%
where cl

set WindowsTargetPlatformMinVersion=10.0.10240.0
call "%~dp0.github\workflows\VC-LTL helper for nmake.cmd"
if %ERRORLEVEL% NEQ 0 exit /B %ERRORLEVEL%

set InstallDir="%~dp0Output\arm64"

mkdir %InstallDir%

if not defined QT_BUILD_TEMP (
  set "QT_BUILD_TEMP=%SCRIPT_DIR%build-temp"
)
if not exist "%QT_BUILD_TEMP%" (
  mkdir "%QT_BUILD_TEMP%"
)

set "OPENSSL_ARCHIVE=%SCRIPT_DIR%openssl\openssl-1.1.1w.tar.gz"
set "OPENSSL_VERSION=openssl-1.1.1w"
set "OPENSSL_TARGET=win-arm64"
set "OPENSSL_STAGE_ROOT=%QT_BUILD_TEMP%\openssl\%OPENSSL_TARGET%"
set "OPENSSL_WORK_ROOT=%OPENSSL_STAGE_ROOT%\work"

set "OPENSSL_INSTALL_ROOT=%SCRIPT_DIR%install"
set "OPENSSL_INSTALL_RELEASE=%OPENSSL_INSTALL_ROOT%\arm64"
set "OpenSSLInclude=%OPENSSL_INSTALL_RELEASE%\include"
set "OpenSSLLibRelease=%OPENSSL_INSTALL_RELEASE%\lib"

call :BuildReleaseOpenSSL "VC-WIN64-ARM" "%OPENSSL_INSTALL_RELEASE%"
if %ERRORLEVEL% NEQ 0 exit /B %ERRORLEVEL%

set "OPENSSL_INCDIR=%OpenSSLInclude%"
set "OPENSSL_LIBDIR=%OpenSSLLibRelease%"
set "OPENSSL_LIBS=/LIBPATH:""%OpenSSLLibRelease%"" libssl.lib libcrypto.lib Crypt32.lib User32.lib Ws2_32.lib Gdi32.lib Advapi32.lib"
set "OPENSSL_LIBS_RELEASE=%OPENSSL_LIBS%"

if defined INCLUDE (
  set "INCLUDE=%OpenSSLInclude%;%INCLUDE%"
) else (
  set "INCLUDE=%OpenSSLInclude%"
)
if defined LIB (
  set "LIB=%OpenSSLLibRelease%;%LIB%"
) else (
  set "LIB=%OpenSSLLibRelease%"
)
if defined LIBPATH (
  set "LIBPATH=%OpenSSLLibRelease%;%LIBPATH%"
) else (
  set "LIBPATH=%OpenSSLLibRelease%"
)

set PATH=%~dp0qtbase\bin;%PATH%

cd /d "%~dp0"

call configure -prefix %InstallDir% -confirm-license -opensource -force-debug-info -opengl dynamic -no-directwrite -mp -nomake examples -nomake tests -recheck-all -release -openssl-linked
if %ERRORLEVEL% NEQ 0 exit /B %ERRORLEVEL%
nmake

if %ERRORLEVEL% NEQ 0 exit /B %ERRORLEVEL%
nmake install
if %ERRORLEVEL% NEQ 0 exit /B %ERRORLEVEL%
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%scripts\verify-vc-ltl.ps1" -InstallDir %InstallDir% -Variant release
if %ERRORLEVEL% NEQ 0 exit /B %ERRORLEVEL%

goto :script_end

:BuildReleaseOpenSSL
set "OPENSSL_RELEASE_CONFIG=%~1"
set "INSTALL_TARGET=%~2"
if not exist "%OPENSSL_ARCHIVE%" (
  echo OpenSSL archive not found: %OPENSSL_ARCHIVE%
  exit /b 1
)
call :CleanDir "%OPENSSL_STAGE_ROOT%"
call :CleanDir "%OPENSSL_WORK_ROOT%"
mkdir "%OPENSSL_STAGE_ROOT%"
mkdir "%OPENSSL_WORK_ROOT%"
call :BuildOpenSSLVariant "%OPENSSL_RELEASE_CONFIG%" "%INSTALL_TARGET%" "release"
exit /b %ERRORLEVEL%

:BuildOpenSSLVariant
set "CONFIG_TARGET=%~1"
set "INSTALL_DIR=%~2"
set "VARIANT_NAME=%~3"
set "VARIANT_ROOT=%OPENSSL_WORK_ROOT%\%VARIANT_NAME%"
set "RUNTIME_FLAG=/MT"
call :CleanDir "%VARIANT_ROOT%"
call :CleanDir "%INSTALL_DIR%"
mkdir "%VARIANT_ROOT%"
mkdir "%INSTALL_DIR%"
tar -xf "%OPENSSL_ARCHIVE%" -C "%VARIANT_ROOT%"
if %ERRORLEVEL% NEQ 0 (
  echo Failed to extract OpenSSL sources for %VARIANT_NAME%.
  goto BuildVariantFail
)
set "CURRENT_OPENSSL_SRC=%VARIANT_ROOT%\%OPENSSL_VERSION%"
pushd "%CURRENT_OPENSSL_SRC%"
perl Configure %CONFIG_TARGET% no-shared no-unit-test --prefix="%INSTALL_DIR%" --openssldir="%INSTALL_DIR%\ssl"
if %ERRORLEVEL% NEQ 0 (
  popd
  echo OpenSSL Configure failed for %VARIANT_NAME%.
  goto BuildVariantFail
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%scripts\force-runtime.ps1" "%CURRENT_OPENSSL_SRC%\makefile" "%RUNTIME_FLAG%"
if %ERRORLEVEL% NEQ 0 (
  popd
  echo Failed to enforce %RUNTIME_FLAG% for %VARIANT_NAME%.
  echo Makefile path: %CURRENT_OPENSSL_SRC%\makefile
  goto BuildVariantFail
)

nmake /nologo build_libs
if %ERRORLEVEL% NEQ 0 (
  popd
  echo OpenSSL build failed for %VARIANT_NAME%.
  goto BuildVariantFail
)
nmake /nologo install_dev >NUL
if %ERRORLEVEL% NEQ 0 (
  popd
  echo OpenSSL install_dev failed for %VARIANT_NAME%.
  goto BuildVariantFail
)
nmake /nologo clean >NUL 2>&1
popd
goto BuildVariantSuccess

:BuildVariantSuccess
exit /b 0

:BuildVariantFail
exit /b 1


:CleanDir
set "TARGET_PATH=%~1"
if exist "%TARGET_PATH%" (
  rmdir /s /q "%TARGET_PATH%"
)
exit /b 0

:script_end
@endlocal







