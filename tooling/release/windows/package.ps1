param(
    [switch]$SkipBuild,
    [switch]$Overwrite,
    [switch]$RequireSignature,
    [string]$CertificateThumbprint,
    [string]$TimestampUrl = 'https://timestamp.digicert.com'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../windows_path.ps1')
Initialize-ProcessEnvironment
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Run([string]$File, [string[]]$Arguments) {
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$File failed: $LASTEXITCODE" }
}
function Publish-Release([string]$Work, [string]$Output, [switch]$Overwrite) {
    $releaseRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build/release/windows')) + [IO.Path]::DirectorySeparatorChar
    $Output = [IO.Path]::GetFullPath($Output)
    if (-not $Output.StartsWith($releaseRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Release destination is outside the Windows release directory.'
    }
    $backup = $null
    if (Test-Path -LiteralPath $Output) {
        if (-not $Overwrite) { throw "Output already exists: $Output; use -Overwrite to replace it." }
        $backup = $Output + '.previous-' + [Guid]::NewGuid().ToString('N')
        # Move only verified destinations inside the release directory. Keep
        # the previous package for recovery instead of deleting it recursively.
        if (-not $backup.StartsWith($releaseRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid backup destination.' }
        Move-Item -LiteralPath $Output -Destination $backup -ErrorAction Stop
    }
    try {
        Move-Item -LiteralPath $Work -Destination $Output -ErrorAction Stop
    } catch {
        if ($backup -and -not (Test-Path -LiteralPath $Output)) {
            Move-Item -LiteralPath $backup -Destination $Output -ErrorAction Stop
        }
        throw
    }
    if ($backup) { Write-Host "Previous release retained: $backup" }
}
if ($RequireSignature -and -not $CertificateThumbprint) { throw 'A certificate thumbprint is required for a signed release.' }
$compiler = & (Join-Path $PSScriptRoot 'tools.ps1') -Optional
$versionText = Get-Content (Join-Path $repoRoot 'apps/fideflow_flutter/pubspec.yaml') -Raw
if ($versionText -notmatch '(?m)^version: (\d+\.\d+\.\d+)\+(\d+)\s*$') { throw 'Expected numeric app version and build number.' }
$version = $Matches[1]; $number = $Matches[2]
$packageVersion = "$version+$number"
$artifact = "Fideflow-windows-x86_64-$packageVersion"
$output = Join-Path $repoRoot "build/release/windows/$packageVersion/x64"
if ((Test-Path -LiteralPath $output) -and -not $Overwrite) { throw "Output already exists: $output; use -Overwrite to replace it." }
$saved = @{}
foreach ($name in 'FF_SKIP_NATIVE_EMBED','FF_NETWORK_MODE') {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
    Set-ProcessEnvironmentVariable $name $null
}
try {
    if (-not $SkipBuild) {
        Push-Location (Join-Path $repoRoot 'apps/fideflow_flutter')
        try { Run 'flutter' @('build','windows','--release') } finally { Pop-Location }
    }
    $source = Join-Path $repoRoot 'apps/fideflow_flutter/build/windows/x64/runner/Release'
    $fileInfo = (Get-Item -LiteralPath (Join-Path $source 'fideflow.exe')).VersionInfo
    $builtVersion = "$($fileInfo.FileMajorPart).$($fileInfo.FileMinorPart).$($fileInfo.FileBuildPart).$($fileInfo.FilePrivatePart)"
    if ($builtVersion -ne "$version.$number") { throw "Built executable version $builtVersion differs from $version.$number" }
    $work = Join-Path $repoRoot ('build/release-windows-' + [Guid]::NewGuid().ToString('N'))
    $bundle = Join-Path $work 'Fideflow'
    New-Item -ItemType Directory -Path $bundle -Force | Out-Null
    # Flutter's installed Release directory includes plugin and FFI runtime DLLs.
    # Copy all installed DLLs so new plugins and their bundled dependencies ship;
    # verify.py checks PE imports and rejects probes and obsolete TLS libraries.
    # Flutter packages NativeAssetsManifest.json inside data/flutter_assets;
    # native_assets.json is a build intermediate, not a required root file.
    foreach ($pattern in 'fideflow.exe','*.dll','sources.manifest.json') {
        $files = @(Get-ChildItem -Path (Join-Path $source $pattern) -File)
        if (-not $files.Count) { throw "Missing runtime file: $pattern" }
        $files | Copy-Item -Destination $bundle
    }
    foreach ($directory in 'data','licenses') { Copy-Item -LiteralPath (Join-Path $source $directory) -Destination $bundle -Recurse }
    Copy-Item -LiteralPath (Join-Path $repoRoot 'pubspec.lock') -Destination (Join-Path $bundle 'licenses/pubspec.lock')
    Run 'python' @((Join-Path $repoRoot 'tooling/release/licenses.py'),'--target',(Join-Path $bundle 'licenses'),
        '--triple','x86_64-pc-windows-msvc','--fetch-metadata','--notices',(Join-Path $bundle 'data/flutter_assets/NOTICES.Z'))
    Run 'python' @((Join-Path $repoRoot 'tooling/release/licenses.py'),'--sources',(Join-Path $work "$artifact-sources.tar.xz"),'--platform','windows')
    $signing = 'unsigned'
    $signTool = $null
    if ($CertificateThumbprint) {
        if ($CertificateThumbprint -notmatch '^[0-9a-fA-F]{40}$') { throw 'Invalid certificate thumbprint.' }
        if ($TimestampUrl -notmatch '^https://[A-Za-z0-9./_?=&%:-]+$') { throw 'Timestamp URL must be an HTTPS URL without command quoting characters.' }
        $signTool = (Get-Command signtool.exe -ErrorAction Stop).Source
        foreach ($file in 'fideflow.exe','ff_media_core.dll') {
            Run $signTool @('sign','/sha1',$CertificateThumbprint,'/fd','SHA256','/tr',$TimestampUrl,'/td','SHA256',(Join-Path $bundle $file))
            Run $signTool @('verify','/pa',(Join-Path $bundle $file))
        }
        $signing = 'authenticode'
    }
    Run 'python' @((Join-Path $PSScriptRoot 'verify.py'),$bundle,'--repo',$repoRoot,'--version',$packageVersion,'--signing',$signing,'--output',$work)
    Run 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $repoRoot 'tooling/native/windows/desktop_app_probe.ps1'),'-ExecutablePath',(Join-Path $bundle 'fideflow.exe'))
    if ($compiler) {
        $arguments = @('/Qp',"/DBundleDir=$bundle","/DAppVersion=$version.$number","/DArtifactName=$artifact","/O$work",(Join-Path $PSScriptRoot 'installer.iss'))
        if ($signTool) {
            $arguments = @('/DSigningCommand=1',"/Sff=`"$signTool`" sign /sha1 $CertificateThumbprint /fd SHA256 /tr $TimestampUrl /td SHA256 `$f") + $arguments
        }
        Run $compiler $arguments
        if ($signTool) { Run $signTool @('verify','/pa',(Join-Path $work "$artifact.exe")) }
    }
    Run 'python' @((Join-Path $PSScriptRoot 'verify.py'),$bundle,'--create-archive',(Join-Path $work "$artifact.zip"))
    Run 'python' @((Join-Path $repoRoot 'tooling/release/licenses.py'),'--verify-archive',(Join-Path $work "$artifact.zip"),'--platform','windows')
    Run 'python' @((Join-Path $PSScriptRoot 'verify.py'),$bundle,'--archive',(Join-Path $work "$artifact.zip"),'--manifest',(Join-Path $work 'release-manifest.json'))
    $record = Get-Content (Join-Path $work 'release-manifest.json') -Raw | ConvertFrom-Json
    $record | Add-Member -NotePropertyName gitRevision -NotePropertyValue (& git -C $repoRoot rev-parse HEAD)
    $record | Add-Member -NotePropertyName dirtyWorktree -NotePropertyValue ([bool](& git -C $repoRoot status --porcelain))
    $record | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $work 'release-manifest.json') -Encoding UTF8
    $sums = foreach ($file in Get-ChildItem -LiteralPath $work -File | Sort-Object Name) {
        (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $file.Name
    }
    $sums | Set-Content -LiteralPath (Join-Path $work 'SHA256SUMS') -Encoding ASCII
    New-Item -ItemType Directory -Path (Split-Path $output) -Force | Out-Null
    Publish-Release -Work $work -Output $output -Overwrite:$Overwrite
    Write-Host "Release ready ($signing): $output"
} finally {
    foreach ($name in $saved.Keys) { Set-ProcessEnvironmentVariable $name $saved[$name] }
}
