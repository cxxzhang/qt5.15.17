param([Parameter(Mandatory=$true)][string]$SdkRoot, [int]$ToolTimeoutSeconds = 900)
$ErrorActionPreference = 'Stop'
$rootPath = [IO.Path]::GetFullPath($SdkRoot).TrimEnd('\') + '\'
$logPath = Join-Path $rootPath 'build-temp/logs'
New-Item -ItemType Directory -Force -Path $logPath | Out-Null
Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class SdkToolWindows {
    private delegate bool EnumProc(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder text, int count);
    public static string[] Read(uint process) {
        var text = new List<string>();
        EnumProc read = (window, data) => {
            var buffer = new StringBuilder(8192);
            if (GetWindowText(window, buffer, buffer.Capacity) > 0) text.Add(buffer.ToString());
            return true;
        };
        EnumWindows((window, data) => {
            uint owner; GetWindowThreadProcessId(window, out owner);
            if (owner == process) { read(window, data); EnumChildWindows(window, read, data); }
            return true;
        }, IntPtr.Zero);
        return text.ToArray();
    }
}
'@
$deadline = (Get-Date).AddHours(5)
while ((Get-Date) -lt $deadline) {
    foreach ($tool in Get-Process -Name moc,rcc,uic,qmltyperegistrar,qmlcachegen,qmlplugindump,lrelease,lupdate -ErrorAction SilentlyContinue) {
        try {
            if (-not $tool.Path.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $started = $tool.StartTime
            if (((Get-Date) - $started).TotalSeconds -lt $ToolTimeoutSeconds) { continue }
            $report = Join-Path $logPath ("tool-timeout-{0}-{1}.txt" -f $tool.ProcessName, $tool.Id)
            @("Process: $($tool.ProcessName)", "PID: $($tool.Id)", "Started: $started", "CPU seconds: $($tool.TotalProcessorTime.TotalSeconds)", "Path: $($tool.Path)") | Set-Content -Encoding utf8 $report
            [SdkToolWindows]::Read([uint32]$tool.Id) | Add-Content -Encoding utf8 $report
            $debuggerArch = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'x64' }
            $debugger = "${env:ProgramFiles(x86)}/Windows Kits/10/Debuggers/$debuggerArch/cdb.exe"
            if (Test-Path -LiteralPath $debugger) {
                try {
                    $trace = Start-Process -FilePath $debugger -WindowStyle Hidden -PassThru -ArgumentList @('-pv','-p',"$($tool.Id)",'-c','"~*k; q"') -RedirectStandardOutput "$report.stack.txt" -RedirectStandardError "$report.debugger-errors.txt"
                    if (-not $trace.WaitForExit(30000)) { Stop-Process -Id $trace.Id -Force -ErrorAction SilentlyContinue }
                } catch {
                    $_.Exception.Message | Add-Content -Encoding utf8 "$report.debugger-errors.txt"
                }
            }
            $current = Get-Process -Id $tool.Id -ErrorAction SilentlyContinue
            if ($current -and $current.StartTime -eq $started -and $current.Path.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
                Stop-Process -Id $current.Id -Force
                'Stopped stalled SDK generator after collecting diagnostics' | Add-Content -Encoding utf8 $report
            }
        } catch {
            $_.Exception.Message | Add-Content -Encoding utf8 (Join-Path $logPath 'tool-watch-errors.txt')
        }
    }
    Start-Sleep -Seconds 15
}
