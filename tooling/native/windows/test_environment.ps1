$ErrorActionPreference = 'Stop'
# Integration check: run in a disposable PowerShell process with MSVC installed.
$env:Path = ((@("$env:SystemRoot\System32") * 500) -join ';') + ';' + $env:Path
$sentinel = 'C:\fideflow-path-regression-sentinel'
$env:Path += ";$sentinel"
if ($env:Path.Length -le 8191) { throw 'Regression setup requires a long PATH.' }
foreach ($attempt in 1..2) {
    . (Join-Path $PSScriptRoot 'environment.ps1')
    if (-not (Get-Command cl.exe -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'MSVC compiler missing after initialization.'
    }
    if (@([Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -ieq 'Path' }).Count -ne 1) {
        throw 'PATH must have one spelling in the process environment.'
    }
    $null = & "$env:SystemRoot\System32\where.exe" cl.exe
    if ($LASTEXITCODE -ne 0) { throw 'Child processes cannot find the MSVC compiler.' }
    if (-not (Test-PathDirectory $sentinel $env:Path)) {
        throw 'Caller PATH was not preserved.'
    }
    if (@($env:Path -split ';' | Where-Object { $_ -eq $sentinel }).Count -ne 1) {
        throw 'Repeated initialization duplicated caller PATH entries.'
    }
    if ($attempt -eq 1) {
        $firstModulePath = $env:PSModulePath
    } elseif ($env:PSModulePath -ne $firstModulePath) {
        throw 'Repeated initialization changed PSModulePath.'
    }
}
$pathBeforeFailure = $env:Path
$preinitBeforeFailure = $env:__VSCMD_PREINIT_PATH
$initializationFailure = $null
try {
    Import-MsvcEnvironment (Join-Path $PSScriptRoot ('missing-visual-studio-' + [Guid]::NewGuid().ToString('N')))
} catch { $initializationFailure = $_.Exception.Message }
if ($initializationFailure -notlike 'Cannot initialize MSVC environment*') {
    throw "Expected MSVC initialization failure, got: $initializationFailure"
}
if ($env:Path -ne $pathBeforeFailure -or $env:__VSCMD_PREINIT_PATH -ne $preinitBeforeFailure) {
    throw 'Failed MSVC initialization changed the caller environment.'
}
Write-Host 'MSVC environment checks passed (long PATH, caller tools preserved, repeated initialization, failure preservation).'
