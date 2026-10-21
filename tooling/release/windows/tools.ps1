param([switch]$Install, [switch]$Optional)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../windows_path.ps1')
Initialize-ProcessEnvironment
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$tool = (Get-Content (Join-Path $PSScriptRoot 'tools.json') -Raw | ConvertFrom-Json).innoSetup
$directory = Join-Path $repoRoot "native/build/tools/inno-$($tool.version)"
$compiler = Join-Path $directory 'ISCC.exe'
$record = Join-Path $directory 'ff-tool.json'
if (-not (Test-Path -LiteralPath $compiler) -or -not (Test-Path -LiteralPath $record)) {
    if ($Optional -and -not $Install) {
        Write-Warning 'Inno Setup is missing or unregistered. Only the portable ZIP will be packaged; the installer will be skipped. Run tooling/release/windows/tools.ps1 -Install to enable installer packaging.'
        return
    }
    if (-not $Install) { throw 'Run tooling/release/windows/tools.ps1 -Install to install the pinned packaging compiler.' }
    $downloadDirectory = Join-Path $repoRoot 'native/build/tools/downloads'
    New-Item -ItemType Directory -Force -Path $downloadDirectory | Out-Null
    $installer = Join-Path $downloadDirectory "innosetup-$($tool.version).exe"
    if (-not (Test-Path -LiteralPath $installer)) { Invoke-WebRequest -UseBasicParsing $tool.url -OutFile $installer }
    if ((Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant() -ne $tool.sha256) { throw 'Packaging compiler checksum mismatch.' }
    $signature = Get-AuthenticodeSignature -LiteralPath $installer
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike "*O=$($tool.publisher),*") {
        throw 'Packaging compiler publisher signature verification failed.'
    }
    $process = Start-Process -FilePath $installer -WindowStyle Hidden -Wait -PassThru `
        -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/CURRENTUSER','/NOICONS','/TASKS=',"/DIR=`"$directory`"")
    if ($process.ExitCode -ne 0) { throw "Packaging compiler install failed: $($process.ExitCode)" }
    @{ version = $tool.version; installerSha256 = $tool.sha256; compilerSha256 = (Get-FileHash $compiler -Algorithm SHA256).Hash } |
        ConvertTo-Json | Set-Content -LiteralPath $record -Encoding UTF8
}
if (-not (Test-Path -LiteralPath $compiler)) { throw 'Packaging compiler is missing.' }
$installed = Get-Content $record -Raw | ConvertFrom-Json
if ($installed.version -ne $tool.version -or $installed.installerSha256 -ne $tool.sha256 -or
    (Get-FileHash $compiler -Algorithm SHA256).Hash -ne $installed.compilerSha256) { throw 'Packaging compiler verification failed.' }
Write-Output $compiler
