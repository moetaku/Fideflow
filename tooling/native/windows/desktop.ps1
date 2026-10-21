param()
. (Join-Path $PSScriptRoot 'environment.ps1')
$buildDirectory = Join-Path $repoRoot 'apps/fideflow_flutter/build/windows/x64'
if (-not (Test-Path -LiteralPath (Join-Path $buildDirectory 'CMakeCache.txt'))) {
    throw 'Run flutter build windows --release before the desktop probe.'
}
Invoke-Native 'cmake' @('--build',$buildDirectory,'--config','Release','--target','ff_desktop_probe')
$probe = Join-Path $repoRoot 'native/build/windows-desktop-probe/Release/ff_desktop_probe.exe'
Invoke-Native $probe @()
Write-Host 'native: Windows desktop integration probe passed (tray, SMTC, hotkeys, lifecycle, quit).'
