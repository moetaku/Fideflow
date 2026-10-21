$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows_path.ps1')
Initialize-ProcessEnvironment

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Push-Location $repoRoot
try {
    & (Join-Path $PSScriptRoot 'test_windows_path.ps1')
    & (Join-Path $PSScriptRoot 'test_bootstrap.ps1')
    python tooling/check_contracts.py
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    python tooling/check_presentation_boundaries.py
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    python tooling/test_presentation_boundaries.py
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    python tooling/generate_ui_references.py --check
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    python tooling/native/checks/test_platform_manifest.py
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    dart format --output=none --set-exit-if-changed apps packages
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    dart analyze .
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    flutter test apps/fideflow_flutter
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    dart test packages/domain
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    dart test packages/local_data
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    dart test packages/ncm_gateway
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    dart test packages/media_sdk
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    dart test packages/media_host
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    dart test packages/application
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $cargoHome = if ($env:CARGO_HOME) { $env:CARGO_HOME } else {
        Join-Path $env:USERPROFILE '.cargo'
    }
    $cargoBin = Join-Path $cargoHome 'bin'
    $cargo = Join-Path $cargoBin 'cargo.exe'
    if (-not (Test-Path -LiteralPath $cargo)) {
        throw 'Cargo is missing. Run tooling/bootstrap.ps1 after installing Rust.'
    }
    Add-ProcessPathDirectory $cargoBin

    $vswhere = Join-Path ${env:ProgramFiles(x86)} `
        'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $installation = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath
        if ($installation) {
            Import-MsvcEnvironment $installation
        }
    }

    & $cargo fmt --all --manifest-path native/media_core/Cargo.toml --check
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & $cargo clippy --manifest-path native/media_core/Cargo.toml `
        --all-targets -- -D warnings
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & $cargo test --manifest-path native/media_core/Cargo.toml
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Pop-Location
}
