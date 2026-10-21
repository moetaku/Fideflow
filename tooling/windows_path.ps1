# Shared process-environment helpers for Windows build, check and release scripts.
function Set-ProcessEnvironmentVariable {
    param([ValidateNotNullOrEmpty()][string]$Name, [AllowNull()][AllowEmptyString()][string]$Value)
    # PowerShell converts $null to an empty string for .NET string parameters.
    # NullString forces actual deletion, including on .NET versions that retain
    # empty environment variables. Remove each inherited case alias first.
    $aliases = @([Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -ieq $Name })
    foreach ($alias in $aliases) {
        [Environment]::SetEnvironmentVariable($alias, [System.Management.Automation.Language.NullString]::Value, 'Process')
    }
    if (-not [string]::IsNullOrEmpty($Value)) {
        [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
    }
}

function Initialize-ProcessEnvironment {
    $variables = [Environment]::GetEnvironmentVariables()
    $visited = @{}
    foreach ($name in $variables.Keys) {
        if ($visited.ContainsKey($name)) { continue }
        $visited[$name] = $true
        $aliases = @($variables.Keys | Where-Object { $_ -ieq $name })
        if ($aliases.Count -lt 2) { continue }
        # Keep Windows' effective value for ordinary variables. For path lists,
        # preserve tools from every alias with the effective value first.
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ($name -ieq 'Path' -or $name -ieq 'PSModulePath') {
            $values = @($value) + @($aliases | ForEach-Object { $variables[$_] })
            $value = Merge-WindowsPath $values
        }
        Set-ProcessEnvironmentVariable $name $value
    }
}

function Merge-WindowsPath {
    param([AllowNull()][string[]]$Values)
    $directories = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($value in $Values) {
        foreach ($directory in ($value -split ';')) {
            if (-not $directory) { continue }
            $key = ConvertTo-WindowsPathKey $directory
            if (-not $key) { $key = $directory }
            if ($seen.Add($key)) { $directories.Add($directory) }
        }
    }
    return $directories -join ';'
}

function ConvertTo-WindowsPathKey([string]$Value) {
    $expanded = [Environment]::ExpandEnvironmentVariables($Value.Trim().Trim('"'))
    if (-not $expanded) { return $null }
    try {
        return [IO.Path]::GetFullPath($expanded).TrimEnd('\', '/').ToUpperInvariant()
    } catch {
        return $null
    }
}

function Test-PathDirectory {
    param([string]$Directory, [AllowNull()][string]$PathValue)
    if (-not $Directory -or -not $PathValue) { return $false }
    $expected = ConvertTo-WindowsPathKey $Directory
    if (-not $expected) { return $false }
    foreach ($entry in ($PathValue -split ';')) {
        if ((ConvertTo-WindowsPathKey $entry) -eq $expected) { return $true }
    }
    return $false
}

function Show-ToolPathStatus {
    param([string]$Tool, [string]$Directory)
    $processReady = Test-PathDirectory $Directory $env:Path
    $userReady = Test-PathDirectory $Directory ([Environment]::GetEnvironmentVariable('Path', 'User'))
    $machineReady = Test-PathDirectory $Directory ([Environment]::GetEnvironmentVariable('Path', 'Machine'))
    Write-Host "bootstrap: $Tool PATH: process=$processReady, user=$userReady, machine=$machineReady; directory=$Directory"
    if (-not $processReady -and ($userReady -or $machineReady)) {
        Write-Warning "$Tool is configured in persistent PATH but this terminal has an older environment. Reopen your terminal (and Codex if launched before the PATH change)."
    }
    return $processReady
}

function Add-ProcessPathDirectory {
    param([string]$Directory)
    if (-not (Test-PathDirectory $Directory $env:Path)) {
        $updatedPath = if ($env:Path) { "$Directory;$env:Path" } else { $Directory }
        Set-ProcessEnvironmentVariable 'Path' $updatedPath
    }
}

function Import-MsvcEnvironment {
    param([string]$Installation)
    Initialize-ProcessEnvironment
    $vsDevCmd = Join-Path $Installation 'Common7/Tools/VsDevCmd.bat'
    $callerPath = $env:Path
    # Avoid cmd.exe's 8191-character expansion limit and collapse PATH aliases
    # in the child environment before running Visual Studio's batch scripts.
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $env:ComSpec
    $startInfo.Arguments = "/d /s /c `"`"$vsDevCmd`" -arch=x64 -host_arch=x64 >nul && set`""
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['PATH'] = "$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\Wbem"
    $startInfo.EnvironmentVariables['__VSCMD_PREINIT_PATH'] = $startInfo.EnvironmentVariables['PATH']
    $environmentProcess = New-Object System.Diagnostics.Process
    $environmentProcess.StartInfo = $startInfo
    try {
        $null = $environmentProcess.Start()
        $stdout = $environmentProcess.StandardOutput.ReadToEndAsync()
        $stderr = $environmentProcess.StandardError.ReadToEndAsync()
        $environmentProcess.WaitForExit()
        $nativeEnvironment = $stdout.GetAwaiter().GetResult() -split '\r?\n'
        $environmentError = $stderr.GetAwaiter().GetResult()
        $environmentExitCode = $environmentProcess.ExitCode
    } finally {
        $environmentProcess.Dispose()
    }
    if ($environmentExitCode -ne 0) { throw "Cannot initialize MSVC environment (exit $environmentExitCode). $environmentError" }
    # Validate before importing so a failed initialization preserves the caller.
    $imported = @{}
    foreach ($line in $nativeEnvironment) {
        $separator = $line.IndexOf('=')
        if ($separator -gt 0) {
            $imported[$line.Substring(0, $separator)] = $line.Substring($separator + 1)
        }
    }
    if (-not $imported['Path']) { throw 'MSVC environment did not provide PATH.' }
    foreach ($name in $imported.Keys) {
        if ($name -ine 'Path' -and $name -ine '__VSCMD_PREINIT_PATH') {
            Set-ProcessEnvironmentVariable $name $imported[$name]
        }
    }
    Set-ProcessEnvironmentVariable 'Path' (Merge-WindowsPath @($imported['Path'], $callerPath))
}
