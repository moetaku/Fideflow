param([switch]$RuntimeOnly)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $repoRoot 'tooling/windows_path.ps1')
Initialize-ProcessEnvironment
# Flutter/MSBuild may inherit PowerShell 7's module path while launching 5.1.
# Resolve built-in modules from the shell actually running these scripts.
$nativeModuleDirectory = Join-Path $PSHOME 'Modules'
$otherModuleDirectories = @($env:PSModulePath -split ';' | Where-Object { $_ -and $_ -ine $nativeModuleDirectory })
$env:PSModulePath = (@($nativeModuleDirectory) + $otherModuleDirectories) -join ';'
Import-Module (Join-Path $nativeModuleDirectory 'Microsoft.PowerShell.Utility') -ErrorAction Stop
# Keep build subprocesses on a supported deterministic locale.
$env:LC_ALL = 'C'
$env:LC_CTYPE = 'C'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $repoRoot 'tooling/windows_path.ps1')
if (-not $RuntimeOnly) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $installation = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $installation) { throw 'Visual Studio C++ x64 tools are required.' }
    Import-MsvcEnvironment $installation
    Add-ProcessPathDirectory (Join-Path $installation 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin')
    $cargoHome = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $env:USERPROFILE '.cargo' }
    Add-ProcessPathDirectory (Join-Path $cargoHome 'bin')
    $msysRoot = if ($env:FF_MSYS2_ROOT) { $env:FF_MSYS2_ROOT } else { 'C:/msys64' }
    $bash = Join-Path $msysRoot 'usr/bin/bash.exe'
    $nasm = if ($env:FF_NASM_BINARY) { $env:FF_NASM_BINARY } else { (Get-Command nasm -ErrorAction SilentlyContinue).Source }
    if (-not $nasm) {
        foreach ($candidate in @("$env:LOCALAPPDATA/bin/NASM/nasm.exe", "$env:ProgramFiles/NASM/nasm.exe")) {
            if (Test-Path -LiteralPath $candidate) { $nasm = $candidate; break }
        }
    }
    if (-not $nasm -or -not (Test-Path -LiteralPath $bash)) { throw 'Run tooling/bootstrap.ps1 -CheckOnly; NASM and MSYS2 are required.' }
    Add-ProcessPathDirectory (Split-Path -Parent $nasm)
}
$manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'tooling/native/sources.manifest.json') -Raw | ConvertFrom-Json
$prefix = Join-Path $repoRoot 'native/build/third_party/windows/x86_64'
$env:FF_NATIVE_PREFIX = $prefix
function Invoke-Native {
    param([string]$Executable, [string[]]$Arguments)
    $logDirectory = Join-Path $repoRoot 'native/build/windows-logs'
    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    $log = Join-Path $logDirectory (([IO.Path]::GetFileNameWithoutExtension($Executable)) + '-' + [Guid]::NewGuid().ToString('N') + '.log')
    Write-Host "native: $Executable $($Arguments -join ' ') (log: $log)"
    $null = Get-Command $Executable -CommandType Application -ErrorAction Stop
    $savedErrorPreference = $ErrorActionPreference
    try {
        # PowerShell 5.1 wraps native stderr as ErrorRecords even on success.
        # Preserve diagnostics in the log and judge the actual exit code.
        $ErrorActionPreference = 'Continue'
        & $Executable @Arguments > $log 2>&1
        $nativeExitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedErrorPreference }
    if ($nativeExitCode -ne 0) {
        Get-Content -LiteralPath $log -Tail 40 | Write-Host
        throw "$Executable failed with exit code $nativeExitCode; see $log"
    }
}
function ConvertTo-MsysPath([string]$Path) {
    return (& (Join-Path $msysRoot 'usr/bin/cygpath.exe') -u ([IO.Path]::GetFullPath($Path))).Trim()
}
