param([Parameter(Mandatory)][string]$ReleaseDirectory)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../windows_path.ps1')
Initialize-ProcessEnvironment
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$release = [IO.Path]::GetFullPath($ReleaseDirectory)
$compiler = & (Join-Path $PSScriptRoot 'tools.ps1')
$identity = [Guid]::NewGuid().ToString().ToUpperInvariant()
$work = Join-Path $repo "native/build/installer-probe-$identity"
$installed = Join-Path $work 'installed'
New-Item -ItemType Directory -Path $work -Force | Out-Null
function Run([string]$File, [string[]]$Arguments) {
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$File failed: $LASTEXITCODE" }
}
function Installer([string]$File, [string[]]$Arguments, [bool]$Success = $true) {
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -WindowStyle Hidden -PassThru
    $null = $process.Handle
    if (-not $process.WaitForExit(60000)) { throw 'Installer timeout.' }
    if ($Success -and $process.ExitCode -ne 0) { throw "Installer failed: $($process.ExitCode)" }
    if (-not $Success -and $process.ExitCode -eq 0) { throw 'Expected installer rejection.' }
}
$key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{$identity}_is1"
$bundle = Join-Path $release 'Fideflow'
$saved = $env:LOCALAPPDATA
try {
    # Unique AppId and /NOICONS isolate installer registry and shell artifacts.
    foreach ($version in '1.0.0.1','1.0.0.2') {
        Run $compiler @('/Qp',"/DBundleDir=$bundle","/DAppIdentity=$identity","/DAppVersion=$version","/DArtifactName=acceptance-$version","/O$work",(Join-Path $PSScriptRoot 'installer.iss'))
    }
    $v1 = Join-Path $work 'acceptance-1.0.0.1.exe'
    $v2 = Join-Path $work 'acceptance-1.0.0.2.exe'
    $arguments = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/NOICONS',"/DIR=`"$installed`"")
    Installer $v1 $arguments
    if ((Get-ItemProperty -LiteralPath $key).DisplayVersion -ne '1.0.0.1') { throw 'Install registry version mismatch.' }
    $userData = Join-Path $work 'userdata'
    New-Item -ItemType Directory -Path $userData -Force | Out-Null
    Add-Type -AssemblyName System.Security
    $plain = [Text.Encoding]::UTF8.GetBytes('acceptance-credential')
    $encrypted = [Security.Cryptography.ProtectedData]::Protect($plain,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.File]::WriteAllBytes((Join-Path $userData 'credential.dpapi'),$encrypted)
    Set-Content -LiteralPath (Join-Path $userData 'settings.json') -Value '{"volume":0.42,"checkpoint":123}'
    $before = @(Get-ChildItem $userData -File | Get-FileHash | Select-Object -ExpandProperty Hash)
    # An upgrade must replace the previous payload, even when version metadata
    # of a native DLL did not change between application builds.
    Set-Content -LiteralPath (Join-Path $installed 'ff_media_core.dll') -Value 'previous-payload'
    Installer $v2 $arguments
    if ((Get-ItemProperty -LiteralPath $key).DisplayVersion -ne '1.0.0.2') { throw 'Upgrade registry version mismatch.' }
    Installer $v1 $arguments $false
    $manifest = Get-Content (Join-Path $release 'release-manifest.json') -Raw | ConvertFrom-Json
    foreach ($file in $manifest.files) {
        if ((Get-FileHash -LiteralPath (Join-Path $installed $file.path) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $file.sha256) { throw "Installed file mismatch: $($file.path)" }
    }
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $repo 'tooling/native/windows/desktop_app_probe.ps1'),'-ExecutablePath',(Join-Path $installed 'fideflow.exe'))
    # Exact runtime mutex simulates an active player without touching user apps.
    $marker = New-Object Threading.Mutex($false,'Local\Fideflow.Running')
    try {
        Installer $v2 $arguments $false
        Installer (Join-Path $installed 'unins000.exe') @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') $false
    } finally { $marker.Dispose() }
    Installer (Join-Path $installed 'unins000.exe') @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART')
    if ((Test-Path -LiteralPath $key) -or (Test-Path -LiteralPath (Join-Path $installed 'fideflow.exe'))) { throw 'Uninstall left application registration or executable.' }
    $after = @(Get-ChildItem $userData -File | Get-FileHash | Select-Object -ExpandProperty Hash)
    if (Compare-Object $before $after) { throw 'User data changed during upgrade/uninstall.' }
    $decrypted = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes((Join-Path $userData 'credential.dpapi')),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    if ([Text.Encoding]::UTF8.GetString($decrypted) -ne 'acceptance-credential') { throw 'DPAPI credential became unreadable.' }
    Write-Host "PASS: install, upgrade, downgrade rejection, running guard, installed runtime, uninstall, retained synthetic settings/DPAPI; logs: $work"
} finally {
    $env:LOCALAPPDATA = $saved
    if ((Test-Path -LiteralPath $key) -and (Test-Path -LiteralPath (Join-Path $installed 'unins000.exe'))) {
        Installer (Join-Path $installed 'unins000.exe') @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART')
    }
}
