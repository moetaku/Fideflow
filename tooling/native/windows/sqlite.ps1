. (Join-Path $PSScriptRoot 'environment.ps1') -RuntimeOnly
# Official Windows x64 DLL, pinned independently of macOS's system SQLite.
$sqlite = $manifest.platforms.windows.sqlite
$archive = Join-Path $repoRoot "native/build/third_party/downloads/$($sqlite.downloadName)"
$sha256 = $sqlite.sha256
if (-not (Test-Path -LiteralPath $archive)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $archive) | Out-Null
    # Publish only a complete, verified download so a failed request cannot
    # leave a corrupt archive that blocks every subsequent Flutter build.
    $temporaryArchive = "$archive.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        Write-Host "native: downloading SQLite $($sqlite.version) from $($sqlite.url)"
        Invoke-WebRequest -UseBasicParsing $sqlite.url -OutFile $temporaryArchive
        if ((Get-FileHash -LiteralPath $temporaryArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha256) {
            throw 'SQLite archive checksum mismatch.'
        }
        Move-Item -LiteralPath $temporaryArchive -Destination $archive
    } catch {
        throw "Cannot prepare SQLite $($sqlite.version): $($_.Exception.Message) Check network access to $($sqlite.url), then rerun tooling/native/windows/sqlite.ps1 before building Flutter."
    } finally {
        if (Test-Path -LiteralPath $temporaryArchive) { Remove-Item -LiteralPath $temporaryArchive -Force }
    }
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha256) { throw 'SQLite archive checksum mismatch.' }
$sources = Join-Path $repoRoot 'native/build/third_party/windows-src'
$source = Join-Path $sources $sqlite.topDir
Expand-Archive -LiteralPath $archive -DestinationPath $source -Force
$library = Join-Path $source 'sqlite3.dll'
if (-not (Test-Path -LiteralPath $library)) { throw 'SQLite precompiled package is missing sqlite3.dll.' }
Invoke-Native 'python' @((Join-Path $repoRoot 'tooling/native/checks/sqlite_probe.py'),$library,$sqlite.version)
$output = Join-Path $prefix 'bin'
New-Item -ItemType Directory -Force -Path $output | Out-Null
Copy-Item -LiteralPath $library -Destination (Join-Path $output 'sqlite3.dll') -Force
New-Item -ItemType Directory -Force -Path (Join-Path $prefix 'licenses') | Out-Null
Set-Content -LiteralPath (Join-Path $prefix 'licenses/sqlite.txt') -Value "SQLite $($sqlite.version), public domain. https://www.sqlite.org/copyright.html`nOfficial Windows x64 precompiled package: $($sqlite.url)`nSHA256: $sha256"
