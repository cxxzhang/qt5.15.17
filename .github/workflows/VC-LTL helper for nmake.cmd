@echo off

::
::  VC-LTL自动化加载配置，建议你将此文件单独复制到你的工程再使用，该文件能自动识别当前环境是否存在VC-LTL，并且自动应用。
::
::  使用方法：
::    1. 启动 vcvars32.bat/vcvars64.bat 然后执行此脚本，运行完成后将自动修改include以及lib环境变量，方便nmake以及纯cl用户引用VC-LTL。
::
::  VC-LTL默认搜索顺序
::	  1. “VC-LTL helper for nmake.cmd”所在根目录，即 %~dp0
::	  2. “VC-LTL helper for nmake.cmd”所在根目录下的VC-LTL目录，即 %~dp0VC-LTL
::	  3. “VC-LTL helper for nmake.cmd”所在父目录，即 %~dp0..
::	  3. “VC-LTL helper for nmake.cmd”所在父目录下的VC-LTL目录，即 %~dp0..\VC-LTL
::    4. 当前目录，即 %cd%
::    5. 当前目录下的VC-LTL目录，即 %cd%\VC-LTL
::    6. 当前目录的父目录下的VC-LTL目录，即 %cd%\..\VC-LTL
::    7. 注册表HKEY_CURRENT_USER\Code\VC-LTL@Root
::
::  把VC-LTL放在其中一个位置即可，VC-LTL就能被自动引用。
::
::  如果你对默认搜索顺序不满，你可以修改此文件。你也可以直接指定%VC_LTL_Root%环境变量更加任性的去加载VC-LTL。
::




:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::VC-LTL设置::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

::控制TargetPlatform版本，目前可用版本为 5.1.2600.0    6.0.6000.0（默认）    6.2.9200.0     10.0.10240.0    10.0.19041.0
set WindowsTargetPlatformMinVersion=5.1.2600.0

:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::





if "%VC_LTL_Root%" NEQ "" goto LoadConfig

::搜索VC-LTL目录

::脚本文件根目录存在VC-LTL？
if exist "%~dp0_msvcrt.h" set VC_LTL_Root=%~dp0&& goto LoadConfig

::脚本文件根目录下存在VC-LTL？
if exist "%~dp0VC-LTL\_msvcrt.h" set VC_LTL_Root=%~dp0VC-LTL&& goto LoadConfig

::脚本文件父目录存在VC-LTL？
if exist "%~dp0..\_msvcrt.h" set VC_LTL_Root=%~dp0..&& goto LoadConfig

::脚本文件父目录存在VC-LTL？
if exist "%~dp0..\VC-LTL\_msvcrt.h" set VC_LTL_Root=%~dp0..\VC-LTL&& goto LoadConfig

::当前根目录就是VC-LTL？
if exist "%cd%\_msvcrt.h" set VC_LTL_Root=%cd%&& goto LoadConfig

::当前根目录存在VC-LTL？
if exist "%cd%\VC-LTL\_msvcrt.h" set VC_LTL_Root=%cd%\VC-LTL&& goto LoadConfig

::当前父目录存在VC-LTL？
if exist "%cd%\..\VC-LTL\_msvcrt.h" set VC_LTL_Root=%cd%\..\VC-LTL&& goto LoadConfig


::读取注册表 HKCU\Code\VC-LTL@Root
for /f "tokens=1,2*" %%i in ('reg query "HKCU\Code\VC-LTL" /v Root ') do set VC_LTL_Root=%%k

if "%VC_LTL_Root%" == "" (
    echo VC-LTL was not found. Refusing to build without the configured CRT.
    exit /b 1
)


:LoadConfig

if not exist "%VC_LTL_Root%\config\config.cmd" exit /b 1
if /i "%VSCMD_ARG_TGT_ARCH%" == "x86" set "Platform=x86"
if /i "%VSCMD_ARG_TGT_ARCH%" == "x64" set "Platform=x64"
if /i "%VSCMD_ARG_TGT_ARCH%" == "amd64" set "Platform=x64"
if /i "%VSCMD_ARG_TGT_ARCH%" == "arm64" set "Platform=arm64"

:: VS 2026 can host the same MSVC 14.44 tools as VS 2022. Limit the adapter
:: to that toolset, and restore the real IDE version after vendor setup.
set "QT_SDK_LTL_REAL_VS_VERSION=%VisualStudioVersion%"
if "%VisualStudioVersion%" == "18.0" (
    if not "%VCToolsVersion:~0,5%" == "14.44" (
        echo VC-LTL on VS 2026 requires the validated MSVC 14.44 toolset.
        exit /b 1
    )
    echo Loading VC-LTL for MSVC 14.44 through the VS 2022 configuration path.
    set "VisualStudioVersion=17.0"
)
set "VC_LTL_Helper_Load="
set "InternalLTLCRTVersion="
set "LTLPlatform="
call "%VC_LTL_Root%\config\config.cmd"
set "VisualStudioVersion=%QT_SDK_LTL_REAL_VS_VERSION%"
set "QT_SDK_LTL_REAL_VS_VERSION="
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\scripts\verify-vc-ltl.ps1"
exit /b %ERRORLEVEL%
