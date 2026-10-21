param(
    [Parameter(Mandatory=$true)][string]$StageDir,
    [ValidateSet('Debug','Profile','Release')][string]$Configuration = 'Release'
)
. (Join-Path $PSScriptRoot 'environment.ps1')
# Dependencies are built explicitly so Flutter never silently downloads tools.
& (Join-Path $PSScriptRoot 'build.ps1') -Command verify
# Always refresh from the verified cached archive, including after a version upgrade.
& (Join-Path $PSScriptRoot 'sqlite.ps1')
$profile = if ($Configuration -eq 'Debug') { 'debug' } else { 'release' }
Push-Location (Join-Path $repoRoot 'native/media_core')
try {
    $arguments = @('build','--locked','-p','fideflow-media-ffi','--target','x86_64-pc-windows-msvc')
    if ($profile -eq 'release') { $arguments += '--release' }
    Invoke-Native 'cargo' $arguments
} finally { Pop-Location }
$library = Join-Path $repoRoot "native/media_core/target/x86_64-pc-windows-msvc/$profile/ff_media_core.dll"
if (-not (Test-Path -LiteralPath $library)) { throw "Missing media library: $library" }
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null
Copy-Item -LiteralPath $library -Destination $StageDir
# Remove obsolete TLS artifacts from a previously staged build, confined to StageDir.
$stageRoot = [IO.Path]::GetFullPath($StageDir)
$obsolete = @(Get-ChildItem -LiteralPath $stageRoot -File | Where-Object { $_.Name -match '(?i)(ssl|crypto).*\.dll$' })
$oldCa = Join-Path $stageRoot 'ssl'
if (Test-Path -LiteralPath $oldCa) { $obsolete += Get-Item -LiteralPath $oldCa }
foreach ($item in $obsolete) {
    $resolved = [IO.Path]::GetFullPath($item.FullName)
    if (-not $resolved.StartsWith($stageRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe staging cleanup: $resolved" }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
foreach ($pattern in 'avcodec-*.dll','avformat-*.dll','avutil-*.dll','swresample-*.dll','swscale-*.dll','soxr.dll','sqlite3.dll') {
    $files = @(Get-ChildItem -LiteralPath (Join-Path $prefix 'bin') -Filter $pattern -File)
    if ($files.Count -ne 1) { throw "Expected one runtime DLL for $pattern" }
    $files | Copy-Item -Destination $StageDir -Force
}
Copy-Item -LiteralPath (Join-Path $prefix 'licenses') -Destination $StageDir -Recurse -Force
Get-ChildItem -LiteralPath (Join-Path $StageDir 'licenses') -File -Filter 'openssl-*' | Remove-Item -Force
$ncmVendor = Join-Path $repoRoot 'native/media_core/crates/ncm-api-compat'
Copy-Item -LiteralPath (Join-Path $repoRoot 'native/media_core/vendor/ncm-api-rs/LICENSE') -Destination (Join-Path $StageDir 'licenses/ncm-api-rs-LICENSE') -Force
foreach ($file in @{'UPSTREAM.json'='ncm-host-UPSTREAM.json';'HOST-PATCH.md'='ncm-host-PATCH.md'}.GetEnumerator()) {
    Copy-Item -LiteralPath (Join-Path $ncmVendor $file.Key) -Destination (Join-Path $StageDir "licenses/$($file.Value)") -Force
}
Copy-Item -LiteralPath (Join-Path $repoRoot 'tooling/native/sources.manifest.json') -Destination $StageDir -Force
Invoke-Native 'python' @((Join-Path $repoRoot 'tooling/native/checks/windows_runtime_probe.py'),$StageDir)
Write-Host "native: Windows $Configuration runtime staged in $StageDir"
