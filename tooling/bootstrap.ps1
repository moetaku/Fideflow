param([switch]$CheckOnly)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows_path.ps1')
Initialize-ProcessEnvironment

function Test-RustDependencies([string]$CargoBin) {
    $rustup = Join-Path $CargoBin 'rustup.exe'
    foreach ($tool in 'rustup', 'cargo', 'rustc') {
        $executable = Join-Path $CargoBin "$tool.exe"
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            throw "Rust tool $tool is missing. Run tooling/bootstrap.ps1 without -CheckOnly."
        }
        & $executable --version | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Rust tool $tool cannot run. Run rustup default stable." }
    }
    $components = & $rustup component list --installed
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect Rust components.' }
    foreach ($component in 'rustfmt', 'clippy') {
        if (-not ($components -match "^$component-")) {
            throw "Rust component $component is missing. Run rustup component add rustfmt clippy."
        }
    }
    $targets = & $rustup target list --installed
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect Rust targets.' }
    if ($targets -notcontains 'x86_64-pc-windows-msvc') {
        throw 'Rust MSVC target is missing. Run rustup target add x86_64-pc-windows-msvc.'
    }
    $rustVersion = & (Join-Path $CargoBin 'rustc.exe') -vV
    if ($LASTEXITCODE -ne 0 -or $rustVersion -notcontains 'host: x86_64-pc-windows-msvc') {
        throw 'Use the x64 MSVC host toolchain: rustup default stable-x86_64-pc-windows-msvc.'
    }
}

# A fresh Flutter SDK can print pub/bootstrap progress before the machine JSON.
# Parse from the opening object line; keep the JSON parser strict after that.
function ConvertFrom-FlutterVersionOutput([string]$Output) {
    $jsonStart = [regex]::Match($Output, '(?m)^\s*\{')
    if (-not $jsonStart.Success) { throw 'Flutter version output contains no JSON object.' }
    $version = ($Output.Substring($jsonStart.Index) | ConvertFrom-Json).frameworkVersion
    if ($version -isnot [string] -or [string]::IsNullOrWhiteSpace($version)) {
        throw 'Flutter version output has no frameworkVersion.'
    }
    return $version
}

function Test-WindowsDependencies {
    $missing = [System.Collections.Generic.List[string]]::new()
    $nativeManifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'native\sources.manifest.json') -Raw | ConvertFrom-Json
    $windowsTarget = $nativeManifest.platforms.windows
    if ($windowsTarget.toolchain -ne 'msvc') { throw 'The Windows native manifest must use MSVC.' }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $missing.Add('Git: install with winget install -e --id Git.Git; then reopen PowerShell.')
    }
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        $missing.Add('Python 3: install from https://www.python.org/downloads/windows/ and enable Add python.exe to PATH.')
    } else {
        $pythonVersion = & python --version 2>&1
        if ($LASTEXITCODE -ne 0 -or "$pythonVersion" -notmatch '^Python 3\.') {
            $missing.Add('Python 3 is not runnable. Install from https://www.python.org/downloads/windows/ with PATH enabled; check Windows App execution aliases if python opens the Store.')
        }
    }
    if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
        $missing.Add('Flutter 3.47.5: download the Windows SDK from https://docs.flutter.dev/install/archive, extract it, add its bin directory to PATH, then reopen PowerShell.')
    } else {
        $flutterJson = & flutter --version --machine
        if ($LASTEXITCODE -ne 0) {
            $missing.Add('Flutter cannot run. Repair its SDK/PATH and run flutter doctor -v.')
        } else {
            try {
                $flutterVersion = ConvertFrom-FlutterVersionOutput ($flutterJson | Out-String)
            } catch {
                throw "Cannot read Flutter version. Run flutter --version --machine and flutter doctor -v. $($_.Exception.Message)"
            }
            if ($flutterVersion -ne '3.47.5') {
                Write-Warning "Project/CI use Flutter 3.47.5; current Flutter is $flutterVersion. SDK archive: https://docs.flutter.dev/install/archive"
            }
        }
    }

    # Visual Studio's bundled CMake need not be on the terminal's PATH.
    $installation = $null
    if (${env:ProgramFiles(x86)}) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path -LiteralPath $vswhere) {
            $installation = & $vswhere -latest -products * `
                -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
                    Microsoft.VisualStudio.Component.VC.CMake.Project `
                -property installationPath
        }
    }
    if (-not $installation) {
        $missing.Add('MSVC/CMake: install Visual Studio Build Tools from https://visualstudio.microsoft.com/visual-cpp-build-tools/. Select Desktop development with C++, MSVC x64/x86, C++ CMake tools for Windows, and a Windows 10/11 SDK. For an existing installation use Visual Studio Installer > Modify.')
    }
    $sdkReady = $false
    $sdkRegistry = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue
    if ($sdkRegistry -and $sdkRegistry.KitsRoot10) {
        $sdkLib = Join-Path $sdkRegistry.KitsRoot10 'Lib'
        foreach ($version in (Get-ChildItem -LiteralPath $sdkLib -Directory -ErrorAction SilentlyContinue)) {
            $sdkVersion = $null
            if ([version]::TryParse($version.Name, [ref]$sdkVersion) -and
                $sdkVersion -ge [version]$windowsTarget.deploymentTarget -and
                (Test-Path -LiteralPath (Join-Path $version.FullName 'um\x64\kernel32.lib')) -and
                (Test-Path -LiteralPath (Join-Path $version.FullName 'ucrt\x64\ucrt.lib'))) {
                $sdkReady = $true
                break
            }
        }
    }
    if (-not $sdkReady) {
        $missing.Add('Windows SDK: open Visual Studio Installer > Modify > Individual components and install a Windows 10/11 SDK (including UCRT). Then run flutter doctor -v.')
    }
    $nasm = Get-Command nasm -CommandType Application -ErrorAction SilentlyContinue
    $nasmPath = if ($env:FF_NASM_BINARY) { $env:FF_NASM_BINARY } elseif ($nasm) { $nasm.Source } else { $null }
    if (-not $nasmPath) {
        # The NASM installer defaults to a per-user directory and may not add PATH.
        $candidates = @()
        if ($env:LOCALAPPDATA) {
            $candidates += Join-Path $env:LOCALAPPDATA 'bin\NASM\nasm.exe'
            $candidates += Join-Path $env:LOCALAPPDATA 'NASM\nasm.exe'
        }
        if ($env:ProgramFiles) { $candidates += Join-Path $env:ProgramFiles 'NASM\nasm.exe' }
        if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} 'NASM\nasm.exe' }
        $nasmPath = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    }
    if (-not $nasmPath -or -not (Test-Path -LiteralPath $nasmPath -PathType Leaf)) {
        $missing.Add('NASM: install NASM, add its directory to PATH, or set FF_NASM_BINARY to the full path of nasm.exe. Installer default locations are detected automatically.')
    } else {
        Write-Host "bootstrap: NASM found: $nasmPath"
        & $nasmPath -v | Out-Host
        if ($LASTEXITCODE -ne 0) { $missing.Add('NASM cannot run; repair its installation/PATH.') }
        $nasmDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($nasmPath))
        $nasmOnPath = Show-ToolPathStatus 'NASM' $nasmDirectory
        if (-not $nasmOnPath) {
            if ($CheckOnly) {
                Write-Host 'bootstrap: NASM checked by absolute path; current process PATH is unchanged.'
            } else {
                Add-ProcessPathDirectory $nasmDirectory
                Write-Host 'bootstrap: NASM added to this process PATH for child build commands; persistent PATH is unchanged.'
            }
        }
    }
    # FFmpeg configure needs a POSIX shell even when compilation uses MSVC.
    # Do not accept Git Bash: the build also needs MSYS2 make and pkg-config.
    # Perl, diffutils and patch are not required: Windows disables FFmpeg docs,
    # no longer builds OpenSSL, and does not patch dependency sources.
    $msysRoot = if ($env:FF_MSYS2_ROOT) { $env:FF_MSYS2_ROOT } else { 'C:\msys64' }
    $bash = Join-Path $msysRoot 'usr\bin\bash.exe'
    if (-not (Test-Path -LiteralPath $bash)) {
        $missing.Add('MSYS2: install with winget install -e --id MSYS2.MSYS2. Set FF_MSYS2_ROOT if installed outside C:\msys64. In the MSYS2 shell run pacman -S --needed make pkgconf tar xz.')
    } else {
        Write-Host "bootstrap: MSYS2 found: $msysRoot"
        $null = Show-ToolPathStatus 'MSYS2 usr/bin' (Join-Path $msysRoot 'usr\bin')
        Write-Host 'bootstrap: MSYS2 PATH is supplied inside Bash; no Windows PATH change is required.'
        # A profile-free shell inherits Windows PATH. Add MSYS tools explicitly
        # and identify every absent tool instead of stopping at the first one.
        # Windows PowerShell 5.1 strips embedded double quotes when marshalling
        # native arguments. All expanded values here are controlled tool names
        # or the numeric flag, so this probe needs no embedded double quotes.
        & $bash --noprofile --norc -c 'export PATH=/usr/bin:/bin:$PATH; missing=0; for tool in make pkg-config tar xz; do if ! command -v $tool >/dev/null; then echo bootstrap: MSYS2 missing tool: $tool; missing=1; fi; done; if [ $missing -ne 0 ]; then exit 1; fi; make --version >/dev/null && pkg-config --version >/dev/null && tar --version >/dev/null && xz --version >/dev/null'
        if ($LASTEXITCODE -ne 0) {
            $missing.Add('MSYS2 is installed but its build tools are incomplete or cannot run. Open MSYS2 MSYS and run: pacman -S --needed make pkgconf tar xz. Then rerun tooling/bootstrap.ps1 -CheckOnly.')
        }
    }
    if ($missing.Count -gt 0) {
        foreach ($dependency in $missing) { Write-Host "bootstrap: missing: $dependency" }
        throw 'Install the dependencies listed above, reopen PowerShell, and rerun tooling/bootstrap.ps1.'
    }
    Write-Host 'bootstrap: Git, Python 3, Flutter, MSVC, CMake, Windows SDK, NASM and MSYS2 checks passed.'
}

Push-Location (Join-Path $PSScriptRoot '..')
try {
    Test-WindowsDependencies
    $cargoHome = if ($env:CARGO_HOME) { $env:CARGO_HOME } else {
        Join-Path $env:USERPROFILE '.cargo'
    }
    $cargoBin = Join-Path $cargoHome 'bin'
    $rustup = Join-Path $cargoBin 'rustup.exe'
    if ($CheckOnly) {
        Test-RustDependencies $cargoBin
        Write-Host 'bootstrap: CheckOnly passed; Windows development dependencies are ready.'
        return
    }
    if (-not (Test-Path -LiteralPath $rustup)) {
        $installerDirectory = Join-Path $env:TEMP ("fideflow-rustup-" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $installerDirectory | Out-Null
        # rustup dispatches by executable name; a prefixed filename is treated
        # as an unknown proxy rather than as the installer.
        $rustupInit = Join-Path $installerDirectory 'rustup-init.exe'
        try {
            Write-Host 'Rust is missing; downloading rustup-init'
            Invoke-WebRequest -UseBasicParsing 'https://win.rustup.rs/x86_64' -OutFile $rustupInit
            & $rustupInit -y --profile minimal --default-host x86_64-pc-windows-msvc
            if ($LASTEXITCODE -ne 0) {
                throw "rustup installation failed with exit code $LASTEXITCODE."
            }
        } finally {
            if (Test-Path -LiteralPath $rustupInit) {
                Remove-Item -LiteralPath $rustupInit -Force
            }
            Remove-Item -LiteralPath $installerDirectory -Force
        }
        if (-not (Test-Path -LiteralPath $rustup)) {
            throw 'rustup installation completed but rustup.exe could not be located.'
        }
    }
    # Keep child processes launched by this bootstrap on the same rustup
    # toolchain even when the calling PowerShell has not loaded Cargo's PATH.
    Add-ProcessPathDirectory $cargoBin
    & $rustup component add rustfmt clippy
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & $rustup target add x86_64-pc-windows-msvc
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Test-RustDependencies $cargoBin
    flutter pub get
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-Host 'bootstrap: Windows development dependencies are ready. Reopen PowerShell to use Cargo in a new terminal.'
} finally {
    Pop-Location
}
