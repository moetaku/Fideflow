$ErrorActionPreference = 'Stop'

# Load only the validator: regression checks must never run setup/install steps.
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'bootstrap.ps1'), [ref]$tokens, [ref]$errors)
if ($errors) { throw ($errors | Out-String) }
$validator = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Test-RustDependencies'
}, $true)
if (-not $validator) { throw 'Rust validator not found.' }
. ([scriptblock]::Create($validator.Extent.Text))

# Exercise the same parser used by the dependency check, including first-run noise.
$versionParser = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'ConvertFrom-FlutterVersionOutput'
}, $true)
if (-not $versionParser) { throw 'Flutter version parser not found.' }
. ([scriptblock]::Create($versionParser.Extent.Text))
foreach ($prefix in @('', "Building flutter tool...`nRunning pub upgrade...`nResolving dependencies...`nDownloading packages...`n")) {
    $output = $prefix + "{`n  `"frameworkVersion`": `"3.47.5`"`n}"
    if ((ConvertFrom-FlutterVersionOutput $output) -ne '3.47.5') {
        throw 'Flutter version parser failed for clean or first-run output.'
    }
}
foreach ($output in @('Resolving dependencies...', '{broken}', '{}', '{"frameworkVersion":42}')) {
    $failed = $false
    try { $null = ConvertFrom-FlutterVersionOutput $output } catch { $failed = $true }
    if (-not $failed) { throw "Flutter version parser accepted invalid output: $output" }
}
Write-Host 'Bootstrap Flutter version checks passed (clean, first-run, invalid output).'

# Native command doubles exercise errors without depending on installed Rust.
function Join-Path { param($Path, $ChildPath) return $ChildPath }
function Test-Path { param($LiteralPath, $PathType) return $LiteralPath -ne $script:missingTool }
function rustup.exe {
    $global:LASTEXITCODE = 0
    switch ($args[0]) {
        '--version' { return 'rustup test' }
        'component' {
            $global:LASTEXITCODE = $script:componentExit
            return $script:components
        }
        'target' { return $script:targets }
    }
}
function cargo.exe { $global:LASTEXITCODE = 0; return 'cargo test' }
function rustc.exe {
    $global:LASTEXITCODE = 0
    if ($args[0] -eq '-vV') { return "host: $script:rustHost" }
    return 'rustc test'
}

foreach ($scenario in 'ready', 'missingTool', 'missingComponent', 'componentFailure', 'missingTarget', 'wrongHost') {
    $script:missingTool = ''
    $script:components = @('rustfmt-x86_64-pc-windows-msvc', 'clippy-x86_64-pc-windows-msvc')
    $script:componentExit = 0
    $script:targets = @('x86_64-pc-windows-msvc')
    $script:rustHost = 'x86_64-pc-windows-msvc'
    $expected = switch ($scenario) {
        'missingTool' { $script:missingTool = 'cargo.exe'; 'Rust tool cargo is missing' }
        'missingComponent' { $script:components = @('rustfmt-x86_64-pc-windows-msvc'); 'Rust component clippy is missing' }
        'componentFailure' { $script:componentExit = 1; 'Cannot inspect Rust components' }
        'missingTarget' { $script:targets = @(); 'Rust MSVC target is missing' }
        'wrongHost' { $script:rustHost = 'x86_64-pc-windows-gnu'; 'Use the x64 MSVC host toolchain' }
        default { $null }
    }
    $failure = $null
    try { Test-RustDependencies 'test-bin' } catch { $failure = $_.Exception.Message }
    if (($expected -and $failure -notlike "$expected*") -or (-not $expected -and $failure)) {
        throw "Scenario $scenario failed: expected=$expected; actual=$failure"
    }
}
Write-Host 'Bootstrap checks passed (Rust readiness, missing tools/components/target, command failure, wrong host).'
