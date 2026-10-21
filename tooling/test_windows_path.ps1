$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows_path.ps1')
Initialize-ProcessEnvironment
foreach ($name in [Environment]::GetEnvironmentVariables().Keys) {
    if (@([Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -ieq $name }).Count -ne 1) {
        throw "Inherited case aliases remain: $name"
    }
}

$testVariable = 'FF_ENVIRONMENT_REGRESSION_' + [Guid]::NewGuid().ToString('N')
try {
    Set-ProcessEnvironmentVariable $testVariable 'first'
    Set-ProcessEnvironmentVariable $testVariable.ToLowerInvariant() 'second'
    if ([Environment]::GetEnvironmentVariable($testVariable, 'Process') -ne 'second') {
        throw 'Environment updates must ignore name casing.'
    }
    Set-ProcessEnvironmentVariable $testVariable $null
    if (@([Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -ieq $testVariable }).Count) {
        throw 'Clearing an environment variable must remove it, not leave an empty value.'
    }
} finally { Set-ProcessEnvironmentVariable $testVariable $null }

function Assert-PathResult {
    param([bool]$Expected, [string]$Directory, [AllowNull()][string]$PathValue)
    $actual = Test-PathDirectory $Directory $PathValue
    if ($actual -ne $Expected) { throw "PATH assertion failed: directory=$Directory; expected=$Expected; actual=$actual" }
}

Assert-PathResult $true 'C:\Program Files\NASM' 'C:\Windows;"c:/PROGRAM FILES/nasm/";D:\other'
Assert-PathResult $false 'C:\Program Files\NASM' 'C:\Program Files\NASM-old;C:\Windows'
Assert-PathResult $false 'C:\msys64\usr\bin' 'C:\msys64;C:\msys64\mingw64\bin'
Assert-PathResult $true 'C:\msys64\usr\bin' 'C:\Windows;C:\msys64\usr\bin\'
Assert-PathResult $false 'C:\Program Files\NASM' $null
Assert-PathResult $false 'C:\Program Files\NASM' ';;'
if ((Merge-WindowsPath @('C:\Windows;C:\Program Files\NASM', 'c:/Windows/;D:\caller')) -ne 'C:\Windows;C:\Program Files\NASM;D:\caller') {
    throw 'Merging case aliases must retain tools and remove equivalent directories.'
}
if ($env:LOCALAPPDATA) {
    Assert-PathResult $true (Join-Path $env:LOCALAPPDATA 'bin\NASM') '%LOCALAPPDATA%\bin\NASM'
}

$originalPath = $env:Path
try {
    Set-ProcessEnvironmentVariable 'Path' 'C:\Windows'
    Add-ProcessPathDirectory 'C:\Program Files\NASM'
    $afterFirst = $env:Path
    Add-ProcessPathDirectory 'c:/Program Files/NASM/'
    if ($env:Path -ne $afterFirst) { throw 'Repeated equivalent PATH entries must not be added.' }
    if ($env:Path -ne 'C:\Program Files\NASM;C:\Windows') { throw 'Existing PATH entries must be preserved.' }
} finally {
    Set-ProcessEnvironmentVariable 'Path' $originalPath
}
Write-Host 'Windows environment checks passed (case aliases, true deletion, PATH merging, normalization, idempotent updates).'
