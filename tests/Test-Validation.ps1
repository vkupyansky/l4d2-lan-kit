#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('All', 'OptionalCleanup')]
    [string] $Group = 'All'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$KitRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Utf8 = [Text.UTF8Encoding]::new($false)
$Passed = 0
$TemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('l4d2-lan-kit-tests-' + [guid]::NewGuid().ToString('N'))
# Use the physical macOS temp path so the package's link guard remains enabled.
if ($env:OS -ne 'Windows_NT' -and $TemporaryRoot.StartsWith('/var/', [StringComparison]::Ordinal) -and (Test-Path -LiteralPath '/private/var')) {
    $TemporaryRoot = '/private' + $TemporaryRoot
}
$FixtureRoot = Join-Path $TemporaryRoot 'kit'
$Executable = (Get-Process -Id $PID).Path

function Pass([string] $Name) {
    $script:Passed++
    Write-Host ('PASS ' + $Name)
}

function Save-Json([string] $Path, $Value) {
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 30) + [Environment]::NewLine), $Utf8)
}

function Invoke-Validation([string] $Configuration, [bool] $ExpectedSuccess, [string] $Name) {
    $scriptPath = Join-Path $FixtureRoot 'scripts/LanKit.ps1'
    $arguments = '-NoLogo -NoProfile -NonInteractive -File "{0}" -Action ValidateOnly' -f $scriptPath
    if (-not [string]::IsNullOrWhiteSpace($Configuration)) { $arguments += ' -ConfigPath "{0}"' -f $Configuration }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.Arguments = $arguments
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Validation process did not start.' }
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw ('Validation timed out: ' + $Name) }
        $text = $output.GetAwaiter().GetResult() + $errors.GetAwaiter().GetResult()
        if (($process.ExitCode -eq 0) -ne $ExpectedSuccess) { throw ("Unexpected validation result for {0}:`n{1}" -f $Name, $text) }
        Pass $Name
    }
    finally { $process.Dispose() }
}

function Configuration-Case([string] $Name, [scriptblock] $Change) {
    $configuration = [IO.File]::ReadAllText((Join-Path $KitRoot 'config.example.json'), $Utf8) | ConvertFrom-Json
    & $Change $configuration
    $path = Join-Path $TemporaryRoot ($Name + '.json')
    Save-Json $path $configuration
    Invoke-Validation $path $false $Name
}

function New-TaskFixture {
    return [pscustomobject]@{
        Description = $OwnerTag
        Actions = @([pscustomobject]@{ Execute = $ServerExe; WorkingDirectory = $ServerRoot })
        Principal = [pscustomobject]@{ UserId = 'S-1-5-19'; RunLevel = 'Limited'; LogonType = 'ServiceAccount' }
        Triggers = $null
    }
}

function Get-ScheduledTask {
    param([string] $TaskName, [string] $TaskPath, [string] $ErrorAction)
    return $script:TaskFixture
}

function Reject-Task([string] $Name, [scriptblock] $Change) {
    $script:TaskFixture = New-TaskFixture
    & $Change $script:TaskFixture
    $rejected = $false
    try { $null = Get-OwnedTask } catch { $rejected = $true }
    if (-not $rejected) { throw ('Task guard accepted ' + $Name) }
    Pass $Name
}

try {
    $null = New-Item -ItemType Directory -Path $FixtureRoot
    if ($Group -eq 'All') {
    $manifest = [IO.File]::ReadAllText((Join-Path $KitRoot 'metadata/bundle.json'), $Utf8) | ConvertFrom-Json
    $paths = @('scripts/LanKit.ps1', 'config.example.json', 'metadata/bundle.json', 'metadata/dependencies.json')
    $paths += @($manifest.Files | ForEach-Object { $_.Path })
    foreach ($relative in @($paths | Sort-Object -Unique)) {
        if ($relative -match '(^|/)\.\.(/|$)|[:\x00-\x1f]' -or [IO.Path]::IsPathRooted($relative)) { throw 'Unsafe fixture source path.' }
        $source = Join-Path $KitRoot $relative
        $target = Join-Path $FixtureRoot $relative
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force
        Copy-Item -LiteralPath $source -Destination $target
    }
    $before = @(Get-ChildItem -LiteralPath $FixtureRoot -File -Recurse | ForEach-Object { $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join "`n"
    Invoke-Validation '' $true 'default-package'
    $after = @(Get-ChildItem -LiteralPath $FixtureRoot -File -Recurse | ForEach-Object { $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join "`n"
    if ($before -cne $after) { throw 'ValidateOnly changed package files.' }
    Pass 'validation-does-not-write'
    Configuration-Case 'invalid-port' { param($c) $c.Port = 0 }
    Configuration-Case 'string-boolean' { param($c) $c.EnableKeepLaser = 'true' }
    Configuration-Case 'unknown-field' { param($c) $c | Add-Member -NotePropertyName Unexpected -NotePropertyValue 1 }
    Configuration-Case 'ipv6-address' { param($c) $c.ListenIPv4 = '::1' }
    Configuration-Case 'hostname-command-separator' { param($c) $c.Hostname = 'name; quit' }
    Configuration-Case 'map-command-separator' { param($c) $c.StartMap = 'c8m1_apartment; quit' }
    Configuration-Case 'parent-server-path' { param($c) $c.ServerRoot = '../outside' }
    Configuration-Case 'network-server-path' { param($c) $c.ServerRoot = '\\host\share\server' }
    Configuration-Case 'drive-root' { param($c) $c.ServerRoot = 'C:\' }
    Configuration-Case 'system-directory' { param($c) $c.ServerRoot = 'C:\Windows\server' }
    Configuration-Case 'empty-installation-id' { param($c) $c.KitId = '00000000-0000-0000-0000-000000000000' }
    Invoke-Validation (Join-Path $TemporaryRoot 'missing.json') $false 'explicit-missing-config'
    $duplicate = Join-Path $TemporaryRoot 'duplicate.json'
    $raw = [IO.File]::ReadAllText((Join-Path $KitRoot 'config.example.json'), $Utf8).Replace('"Port": 27016', '"Port": 27015, "Port": 27016')
    [IO.File]::WriteAllText($duplicate, $raw, $Utf8)
    Invoke-Validation $duplicate $false 'duplicate-config-key'
    $asset = Join-Path $FixtureRoot $manifest.Files[0].Path
    [IO.File]::AppendAllText($asset, "`n", $Utf8)
    Invoke-Validation '' $false 'changed-bundle-file'
    Copy-Item -LiteralPath (Join-Path $KitRoot $manifest.Files[0].Path) -Destination $asset -Force
    $bundlePath = Join-Path $FixtureRoot 'metadata/bundle.json'
    $manifest.Files[0].Path = '../outside.txt'
    Save-Json $bundlePath $manifest
    Invoke-Validation '' $false 'bundle-path-traversal'
    Copy-Item -LiteralPath (Join-Path $KitRoot 'metadata/bundle.json') -Destination $bundlePath -Force
    $dependenciesPath = Join-Path $FixtureRoot 'metadata/dependencies.json'
    $dependencies = [IO.File]::ReadAllText($dependenciesPath, $Utf8) | ConvertFrom-Json
    $dependencies.Packages[0].Url = 'http://example.invalid/package.zip'
    Save-Json $dependenciesPath $dependencies
    Invoke-Validation '' $false 'unencrypted-download-url'
    }

    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $KitRoot 'scripts/LanKit.ps1'), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw 'PowerShell syntax errors.' }
    foreach ($name in @('Get-TaskSid', 'Get-OwnedTask', 'Get-Sha', 'Join-Safe', 'Remove-DisabledOptionalLaser')) {
        $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        if ($null -eq $function) { throw ('Missing task guard function: ' + $name) }
        . ([scriptblock]::Create($function.Extent.Text))
    }
    if ($Group -eq 'All') {
    $TaskName = 'L4D2-LAN-Kit-test'
    $OwnerTag = 'L4D2 LAN Kit; KitId=test'
    $ServerRoot = 'C:\Games\LAN Kit\server'
    $ServerExe = $ServerRoot + '\srcds.exe'
    $ServiceSid = [pscustomobject]@{ Value = 'S-1-5-19' }
    $script:TaskFixture = New-TaskFixture
    $null = Get-OwnedTask
    Pass 'manual-task-with-null-triggers'
    Reject-Task 'foreign-task-description' { param($t) $t.Description = 'Other application' }
    Reject-Task 'task-with-trigger' { param($t) $t.Triggers = @([pscustomobject]@{}) }
    Reject-Task 'elevated-server-task' { param($t) $t.Principal.RunLevel = 'Highest' }
    Reject-Task 'interactive-server-task' { param($t) $t.Principal.LogonType = 'Interactive' }
    }

    $ServerRoot = Join-Path $TemporaryRoot 'owned-server'
    $relative = 'left4dead2/addons/sourcemod/plugins/l4d2_keeplasers.smx'
    $active = Join-Safe $ServerRoot $relative
    $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($active)) -Force
    [IO.File]::WriteAllText($active, 'owned test component', $Utf8)
    $State = [pscustomobject]@{ KeepLaser = $true; Files = @([pscustomobject]@{ Path = $relative; Sha256 = (Get-Sha $active) }) }
    $Configuration = [pscustomobject]@{ EnableKeepLaser = $false }
    Remove-DisabledOptionalLaser
    if (Test-Path -LiteralPath $active) { throw 'Disabled owned component remains active.' }
    Pass 'disable-owned-optional-component'
    Remove-DisabledOptionalLaser
    Pass 'resume-optional-disable-after-interruption'
    [IO.File]::WriteAllText($active, 'modified test component', $Utf8)
    $rejected = $false
    try { Remove-DisabledOptionalLaser } catch { $rejected = $true }
    if (-not $rejected -or [IO.File]::ReadAllText($active, $Utf8) -cne 'modified test component') { throw 'A modified component was removed.' }
    Pass 'preserve-modified-optional-component'
    $Configuration.EnableKeepLaser = $true
    Remove-DisabledOptionalLaser
    if (-not (Test-Path -LiteralPath $active)) { throw 'An enabled component was removed.' }
    Pass 'preserve-enabled-optional-component'
    Write-Host ("Validation checks passed: {0}. No game server was installed or started." -f $Passed)
}
finally {
    if (Test-Path -LiteralPath $TemporaryRoot) { Remove-Item -LiteralPath $TemporaryRoot -Force -Recurse }
}
