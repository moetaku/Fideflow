param([string]$ExecutablePath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../windows_path.ps1')
Initialize-ProcessEnvironment
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$executable = if ($ExecutablePath) { [IO.Path]::GetFullPath($ExecutablePath) } else {
    Join-Path $repoRoot 'apps/fideflow_flutter/build/windows/x64/runner/Release/fideflow.exe'
}
if (-not (Test-Path -LiteralPath $executable)) { throw 'Build Windows Release first.' }
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class FfDesktopProbeWindow {
    [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr hwnd, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
    private delegate bool EnumCallback(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumCallback callback, IntPtr data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(IntPtr hwnd, StringBuilder value, int length);
    public static IntPtr Find(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hwnd, data) => {
            uint owner; GetWindowThreadProcessId(hwnd, out owner);
            var name = new StringBuilder(256); GetClassNameW(hwnd, name, name.Capacity);
            if (owner == pid && name.ToString() == "FLUTTER_RUNNER_WIN32_WINDOW") { found = hwnd; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@
$isolatedData = Join-Path $repoRoot ('native/build/desktop-app-probe-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $isolatedData | Out-Null
# Fresh profiles default to asking how to close. Select background explicitly
# in this probe's isolated profile so the smoke test needs no dialog input.
$settings = Join-Path $isolatedData 'Fideflow/settings'
New-Item -ItemType Directory -Path $settings -Force | Out-Null
Set-Content -LiteralPath (Join-Path $settings 'desktop-close.json') `
    -Value '{"version":1,"behavior":"background"}' -Encoding ASCII
$savedLocal = $env:LOCALAPPDATA
$savedProvider = $env:FF_PROVIDER_MODE
$process = $null
$childIds = @()
try {
    Set-ProcessEnvironmentVariable 'LOCALAPPDATA' $isolatedData
    Set-ProcessEnvironmentVariable 'FF_PROVIDER_MODE' 'host'
    $process = Start-Process -FilePath $executable -WorkingDirectory (Split-Path $executable) `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $isolatedData 'stdout.log') `
        -RedirectStandardError (Join-Path $isolatedData 'stderr.log')
    # Retain the handle before the short-lived app exits so PowerShell 5.1 can
    # still read its exit code after WaitForExit (instead of returning null).
    $null = $process.Handle
    Set-ProcessEnvironmentVariable 'LOCALAPPDATA' $savedLocal
    Set-ProcessEnvironmentVariable 'FF_PROVIDER_MODE' $savedProvider
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    $hwnd = [IntPtr]::Zero
    do {
        $process.Refresh()
        if ($process.HasExited) { throw "Application exited during startup: $($process.ExitCode)" }
        $hwnd = [FfDesktopProbeWindow]::Find([uint32]$process.Id)
        if ($hwnd -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($hwnd -eq [IntPtr]::Zero) { throw 'Flutter window was not created.' }
    # The hidden launch can suppress the runner's first ShowWindow call. Show
    # the window explicitly and allow prepare() and the first frame to finish.
    [void][FfDesktopProbeWindow]::ShowWindow($hwnd, 5)
    Start-Sleep -Seconds 3
    [void][FfDesktopProbeWindow]::ShowWindow($hwnd, 5)
    # Closing is asynchronous: native code waits for Dart's preference decision
    # and posts the result back to the window. A close during initialization is
    # queued by the runner. The visible first frame must actually become hidden.
    [void][FfDesktopProbeWindow]::SendMessageW($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $process.Refresh()
        if ($process.HasExited -or -not [FfDesktopProbeWindow]::IsWindowVisible($hwnd)) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($process.HasExited -or [FfDesktopProbeWindow]::IsWindowVisible($hwnd)) { throw "Close-to-tray failed (exited=$($process.HasExited))." }
    Set-ProcessEnvironmentVariable 'LOCALAPPDATA' $isolatedData
    $duplicate = Start-Process -FilePath $executable -WorkingDirectory (Split-Path $executable) -WindowStyle Hidden -PassThru
    $null = $duplicate.Handle
    Set-ProcessEnvironmentVariable 'LOCALAPPDATA' $savedLocal
    if (-not $duplicate.WaitForExit(5000) -or $duplicate.ExitCode -ne 0) { throw 'Duplicate instance did not exit successfully.' }
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not [FfDesktopProbeWindow]::IsWindowVisible($hwnd) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if (-not [FfDesktopProbeWindow]::IsWindowVisible($hwnd)) { throw 'Duplicate instance did not restore the existing window.' }
    [void][FfDesktopProbeWindow]::SendMessageW($hwnd, 0x0111, [IntPtr]200, [IntPtr]::Zero)
    if (-not [FfDesktopProbeWindow]::IsWindowVisible($hwnd)) { throw 'Tray restore failed.' }
    [void][FfDesktopProbeWindow]::ShowWindow($hwnd, 0)
    [void][FfDesktopProbeWindow]::SendMessageW($hwnd, 0x0111, [IntPtr]201, [IntPtr]::Zero)
    if (-not $process.WaitForExit(20000)) { throw 'Graceful application exit timed out.' }
    if ($process.ExitCode -ne 0) { throw "Application exit failed: $($process.ExitCode)" }
    Write-Host "native: Release application startup, close-to-tray, restore, graceful exit passed; isolatedData=$isolatedData"
} finally {
    Set-ProcessEnvironmentVariable 'LOCALAPPDATA' $savedLocal
    Set-ProcessEnvironmentVariable 'FF_PROVIDER_MODE' $savedProvider
    if ($process -and -not $process.HasExited) {
        # Only the exact process created above; never stop another app instance.
        if ([IO.Path]::GetFullPath($process.Path) -ne $executable) { throw 'Unexpected probe process identity.' }
        $process.Kill()
        $process.WaitForExit()
    }
}
