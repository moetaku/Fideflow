param([ValidateSet('all','fetch','build','verify')][string]$Command = 'all')
. (Join-Path $PSScriptRoot 'environment.ps1')
$base = Join-Path $repoRoot 'native/build/third_party'
$sources = Join-Path $base 'windows-src'
$build = Join-Path $base 'windows-build'
$downloads = Join-Path $base 'downloads'
New-Item -ItemType Directory -Force -Path $sources,$build,$downloads,$prefix | Out-Null
if ($Command -in 'all','fetch') {
    foreach ($name in 'ffmpeg','libsoxr','portaudio') {
        $entry = $manifest.sources.$name
        $archive = Join-Path $downloads $entry.downloadName
        if (-not (Test-Path -LiteralPath $archive)) {
            Write-Host "native: downloading $name $($entry.version)"
            Invoke-WebRequest -UseBasicParsing -Uri $entry.urls[0] -OutFile $archive
        }
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.sha256) {
            throw "Checksum mismatch: $archive"
        }
        $source = Join-Path $sources $entry.topDir
        $extracted = Join-Path $source '.ff-extracted'
        if (-not (Test-Path -LiteralPath $extracted)) {
            $archivePath = $env:Path
            try {
                Set-ProcessEnvironmentVariable 'Path' "$msysRoot/usr/bin;$archivePath"
                Invoke-Native (Join-Path $msysRoot 'usr/bin/tar.exe') @('-xf',(ConvertTo-MsysPath $archive),'-C',(ConvertTo-MsysPath $sources))
            } finally { Set-ProcessEnvironmentVariable 'Path' $archivePath }
            Set-Content -LiteralPath $extracted -Value $entry.sha256
        }
    }
}
if ($Command -in 'all','build') {
    $soxrBuild = Join-Path $build 'soxr'
    Invoke-Native 'cmake' @('-S',(Join-Path $sources $manifest.sources.libsoxr.topDir),'-B',$soxrBuild,'-G','NMake Makefiles','-DCMAKE_POLICY_VERSION_MINIMUM=3.5',"-DCMAKE_INSTALL_PREFIX=$prefix",'-DCMAKE_BUILD_TYPE=Release','-DBUILD_SHARED_LIBS=ON','-DWITH_OPENMP=OFF','-DBUILD_TESTS=OFF','-DBUILD_EXAMPLES=OFF')
    Invoke-Native 'cmake' @('--build',$soxrBuild)
    Invoke-Native 'cmake' @('--install',$soxrBuild)
    $paBuild = Join-Path $build 'portaudio'
    Invoke-Native 'cmake' @('-S',(Join-Path $sources $manifest.sources.portaudio.topDir),'-B',$paBuild,'-G','NMake Makefiles','-DCMAKE_POLICY_VERSION_MINIMUM=3.5',"-DCMAKE_INSTALL_PREFIX=$prefix",'-DCMAKE_BUILD_TYPE=Release','-DPA_BUILD_SHARED=OFF','-DPA_BUILD_STATIC=ON','-DPA_DLL_LINK_WITH_STATIC_RUNTIME=OFF','-DPA_USE_WASAPI=ON','-DPA_USE_WDMKS=OFF','-DPA_USE_WMME=OFF','-DPA_USE_DS=OFF','-DPA_USE_ASIO=OFF')
    Invoke-Native 'cmake' @('--build',$paBuild)
    Invoke-Native 'cmake' @('--install',$paBuild)
    $ffBuild = Join-Path $build 'ffmpeg'
    New-Item -ItemType Directory -Force -Path $ffBuild | Out-Null
    $env:FF_FFMPEG_SOURCE = ConvertTo-MsysPath (Join-Path $sources $manifest.sources.ffmpeg.topDir)
    $env:FF_FFMPEG_BUILD = ConvertTo-MsysPath $ffBuild
    $env:FF_FFMPEG_PREFIX = ConvertTo-MsysPath $prefix
    $env:FF_FFMPEG_COMPONENTS = ConvertTo-MsysPath (Join-Path $repoRoot 'tooling/native/ffmpeg-components.txt')
    # Passing a script file avoids PowerShell 5.1's embedded-quote argument bug.
    Invoke-Native $bash @('--noprofile','--norc',(ConvertTo-MsysPath (Join-Path $PSScriptRoot 'ffmpeg.sh')))
    # FFmpeg installs its MSVC import libraries beside the DLLs. Consumers
    # share one predictable lib directory with soxr and PortAudio.
    foreach ($library in 'avformat','avcodec','avutil','swresample','swscale') {
        Copy-Item -LiteralPath (Join-Path $prefix "bin/$library.lib") -Destination (Join-Path $prefix 'lib') -Force
    }
    $licenses = Join-Path $prefix 'licenses'
    New-Item -ItemType Directory -Force -Path $licenses | Out-Null
    foreach ($name in 'ffmpeg','libsoxr','portaudio') {
        $entry = $manifest.sources.$name
        foreach ($license in $entry.licenseFiles) {
            $file = Join-Path (Join-Path $sources $entry.topDir) $license
            if (Test-Path -LiteralPath $file) { Copy-Item -LiteralPath $file -Destination (Join-Path $licenses "$name-$license") }
        }
    }
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $prefix 'sources.manifest.json') -Encoding UTF8
}
if ($Command -in 'all','verify') {
    foreach ($file in 'lib/avformat.lib','lib/avcodec.lib','lib/avutil.lib','lib/swresample.lib','lib/portaudio_static_x64.lib','include/portaudio.h','sources.manifest.json') {
        if (-not (Test-Path -LiteralPath (Join-Path $prefix $file))) { throw "Native prefix is incomplete: $file" }
    }
    Write-Host "native: Windows dependency prefix verified: $prefix"
}
