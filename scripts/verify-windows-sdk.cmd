@echo off
setlocal
set "SDK_ARCH=%~1"
set "SDK_VARIANT=%~2"
set "SDK_ARCHIVE=%~3"
set "SDK_VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "SDK_COMPONENT=Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
set "SDK_TARGET=%SDK_ARCH%"
set "SDK_HOST=amd64"
if "%SDK_ARCH%" == "x64" set "SDK_TARGET=amd64"
if "%SDK_ARCH%" == "arm64" (
    set "SDK_COMPONENT=Microsoft.VisualStudio.Component.VC.Tools.ARM64"
    set "SDK_HOST=arm64"
)
for /f "usebackq tokens=*" %%i in (`"%SDK_VSWHERE%" -latest -products * -requires %SDK_COMPONENT% -property installationPath`) do set "SDK_VS=%%i"
if not defined SDK_VS exit /b 1
call "%SDK_VS%\Common7\Tools\VsDevCmd.bat" -no_logo -arch=%SDK_TARGET% -host_arch=%SDK_HOST% -vcvars_ver=14.44
if errorlevel 1 exit /b %errorlevel%
if not "%VCToolsVersion:~0,5%" == "14.44" exit /b 1
python "%~dp0verify-windows-sdk.py" --archive "%SDK_ARCHIVE%" --target %SDK_ARCH% --variant %SDK_VARIANT% --source-run "%~4" --source-commit "%~5"
exit /b %errorlevel%
