param()
. (Join-Path $PSScriptRoot 'environment.ps1')
& (Join-Path $PSScriptRoot 'build.ps1') -Command verify
$checks = Join-Path $repoRoot 'native/build/windows-checks'
New-Item -ItemType Directory -Force -Path $checks | Out-Null
$probe = Join-Path $checks 'capcheck.exe'
Push-Location $checks
try {
    Invoke-Native 'cl' @('/nologo','/O2','/MD','/utf-8','/std:c11','/DFF_CAPCHECK_EXPECT_NETWORK=0',"/I$prefix/include",(Join-Path $repoRoot 'tooling/native/checks/capcheck.c'),"/Fe$probe",'/link',"/LIBPATH:$prefix/lib",'avformat.lib','avcodec.lib','avutil.lib','swresample.lib')
} finally { Pop-Location }
Add-ProcessPathDirectory (Join-Path $prefix 'bin')
$env:TMPDIR = $checks
$arguments = @('--arch','x86_64','--network','off')
Invoke-Native $probe $arguments

# Inspect the native imports as well as the configuration string.
foreach ($dll in Get-ChildItem -LiteralPath (Join-Path $prefix 'bin') -Filter 'av*.dll' -File) {
    $imports = & dumpbin /nologo /dependents $dll.FullName
    if ($LASTEXITCODE -ne 0) { throw "Cannot inspect imports: $($dll.Name)" }
    if ($imports -match '(?i)libssl|libcrypto') { throw "OpenSSL import remains: $($dll.Name)" }
}
Get-Content -LiteralPath (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'native/build/windows-logs') -Filter 'capcheck-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName -Tail 3
