#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('All', 'OptionalCleanup', 'InstallRecovery')]
    [string] $Group = 'All',
    [string] $EntryScript
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($EntryScript)) { $EntryScript = $PSCommandPath }
if ([string]::IsNullOrWhiteSpace($EntryScript)) { throw 'EntryScript is required for the test command interface.' }
$KitRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($EntryScript))) '..'))
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
    $literal = $scriptPath.Replace("'", "''")
    $command = "& ([ScriptBlock]::Create([IO.File]::ReadAllText('$literal'))) -Action ValidateOnly -EntryScript '$literal'"
    if (-not [string]::IsNullOrWhiteSpace($Configuration)) { $command += " -ConfigPath '" + $Configuration.Replace("'", "''") + "'" }
    $arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
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
        State = 'Ready'
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

function New-InstallFixture([string] $Name) {
    $script:RuntimeRoot = Join-Path (Join-Path $TemporaryRoot $Name) 'runtime'
    $script:ServerRoot = Join-Path $RuntimeRoot 'server'
    $script:DownloadRoot = Join-Path $RuntimeRoot 'downloads'
    $script:Configuration = [pscustomobject]@{ KitId = '22222222-2222-4222-8222-222222222222'; EnableKeepLaser = $false }
    $script:Metadata = [pscustomobject]@{ Dependencies = [pscustomobject]@{
        Packages = @([pscustomobject]@{ Id = 'steamcmd'; Name = 'steamcmd.zip'; Sha256 = ('0' * 64) })
        KeepLaser = [pscustomobject]@{ Name = 'l4d2_keeplasers.sp'; Sha256 = ('1' * 64) }
    } }
    $script:DownloadCalls = 0
}

function Invoke-InstallBoundary([bool] $ExpectedDownload, [string] $Name) {
    $script:DownloadCalls = 0
    $message = ''
    try { Install-Kit } catch { $message = $_.Exception.Message }
    if ($ExpectedDownload) {
        if ($DownloadCalls -ne 1 -or $message -cne 'TEST_DOWNLOAD_BOUNDARY') { throw ("Installer did not reach the download boundary for {0}: {1}" -f $Name, $message) }
        foreach ($path in @((Join-Path $ServerRoot '.lan-kit-owner.json'), (Join-Path $RuntimeRoot '.lan-kit-runtime.json'))) {
            if ((Read-Json $path).KitId -cne $Configuration.KitId) { throw ('Installation identity was not preserved: ' + $path) }
        }
        $expectedFiles = @('.lan-kit-runtime.json', 'server/.lan-kit-owner.json', 'server/.lan-kit.lock')
        $actualFiles = @(Get-ChildItem -LiteralPath $RuntimeRoot -Recurse -Force -File | ForEach-Object { $_.FullName.Substring($RuntimeRoot.TrimEnd('\', '/').Length + 1).Replace('\', '/') })
        if (@(Compare-Object $expectedFiles $actualFiles).Count -ne 0) { throw 'Bootstrap left an unexpected backup, partial or runtime file.' }
    }
    elseif ($DownloadCalls -ne 0 -or [string]::IsNullOrWhiteSpace($message) -or $message -ceq 'TEST_DOWNLOAD_BOUNDARY') { throw ('Installer accepted unowned files: ' + $Name) }
    Pass $Name
}

function Test-SteamInstall([string] $Name, [object[]] $Plan, [bool] $ExpectedSuccess, [int] $Attempts, [int[]] $Delays, [string] $PreviousLog = '') {
    $script:RuntimeRoot = Join-Path (Join-Path $TemporaryRoot $Name) 'runtime'
    $script:ServerRoot = Join-Path $RuntimeRoot 'server with spaces'
    $null = New-Item -ItemType Directory -Path $RuntimeRoot -Force
    if (-not [string]::IsNullOrEmpty($PreviousLog)) { [IO.File]::WriteAllText((Join-Path $RuntimeRoot 'steamcmd-install.log'), $PreviousLog, $Utf8) }
    $counter = Join-Path $NativeSteamRoot 'calls.txt'
    $arguments = Join-Path $NativeSteamRoot 'arguments.txt'
    foreach ($path in @($counter, $arguments)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
    $lines = @($Plan | ForEach-Object { [string]$_.Code + "`t" + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_.Output)) })
    [IO.File]::WriteAllText((Join-Path $NativeSteamRoot 'plan.txt'), ($lines -join [Environment]::NewLine), $Utf8)
    $script:BinaryChecks = 0
    $script:RetryDelays = @()
    $succeeded = $true
    $location = (Get-Location).Path
    try { Install-SteamServer $NativeSteamRoot } catch { $succeeded = $false }
    if ($succeeded -ne $ExpectedSuccess -or -not (Test-Path -LiteralPath $counter) -or [int][IO.File]::ReadAllText($counter) -ne $Attempts) { throw ('Unexpected SteamCMD retry/result contract: ' + $Name) }
    if (($RetryDelays -join ',') -cne ($Delays -join ',') -or $BinaryChecks -ne [int]$ExpectedSuccess -or (Get-Location).Path -cne $location) { throw ('SteamCMD retry delays, binary verification or working directory differed: ' + $Name) }
    foreach ($line in [IO.File]::ReadAllLines($arguments)) {
        if (-not $line.Contains('+app_info_print|222860') -or -not $line.Contains('+login|anonymous') -or -not $line.Contains('+app_update|222860|validate') -or -not $line.Contains('+force_install_dir|' + $ServerRoot)) { throw 'SteamCMD arguments omitted the official app, anonymous login, metadata refresh or target path.' }
    }
    $last = $Plan[$Attempts - 1].Output
    $log = [IO.File]::ReadAllText((Join-Path $RuntimeRoot 'steamcmd-install.log'))
    if (-not $log.Replace("`r`n", "`n").Contains($last.Replace("`r`n", "`n"))) { throw ('SteamCMD final attempt log was not retained: ' + $Name) }
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
    $functions = @('Get-TaskSid', 'Get-OwnedTask', 'Get-Sha', 'Join-Safe', 'Remove-DisabledOptionalLaser')
    if ($Group -in @('All', 'InstallRecovery')) { $functions += @('Read-Json', 'Write-AtomicText', 'Write-Json', 'Assert-NoReparse', 'Install-Kit', 'Install-SteamServer') }
    if ($Group -eq 'All') { $functions += @('Get-StagePlan', 'Update-LaunchProfile', 'Read-NewLog', 'Check-Kit') }
    foreach ($name in $functions) {
        $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        if ($null -eq $function) { throw ('Missing kit function: ' + $name) }
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

    if ($Group -in @('All', 'InstallRecovery')) {
        function Resolve-Network { param($Configuration) return @{ Address = '192.168.50.2'; Subnet = '192.168.50.0/24' } }
        function Assert-Stopped { }
        function Get-Download { param($Package) $script:DownloadCalls++; throw 'TEST_DOWNLOAD_BOUNDARY' }

        New-InstallFixture 'fresh-install'
        Invoke-InstallBoundary $true 'fresh-default-nested-server-root'
        Invoke-InstallBoundary $true 'retry-after-download-interruption'

        New-InstallFixture 'bootstrap-interruption'
        $null = New-Item -ItemType Directory -Path $ServerRoot -Force
        Write-Json (Join-Path $ServerRoot '.lan-kit-owner.json') @{ SchemaVersion = 1; KitId = $Configuration.KitId }
        [IO.File]::WriteAllText((Join-Path $ServerRoot '.lan-kit.lock'), '', $Utf8)
        Invoke-InstallBoundary $true 'retry-between-ownership-markers'

        New-InstallFixture 'foreign-runtime'
        $null = New-Item -ItemType Directory -Path $RuntimeRoot -Force
        $foreign = Join-Path $RuntimeRoot 'unrelated.txt'
        [IO.File]::WriteAllText($foreign, 'user data', $Utf8)
        Invoke-InstallBoundary $false 'preserve-unowned-runtime-content'
        if ([IO.File]::ReadAllText($foreign, $Utf8) -cne 'user data' -or (Test-Path -LiteralPath $ServerRoot)) { throw 'Rejected runtime content was changed.' }

        New-InstallFixture 'foreign-owner'
        $null = New-Item -ItemType Directory -Path $ServerRoot -Force
        $marker = Join-Path $ServerRoot '.lan-kit-owner.json'
        Write-Json $marker @{ SchemaVersion = 1; KitId = '33333333-3333-4333-8333-333333333333' }
        $before = Get-Sha $marker
        Invoke-InstallBoundary $false 'reject-foreign-server-owner'
        if ((Get-Sha $marker) -cne $before) { throw 'Foreign ownership was changed.' }

        New-InstallFixture 'invalid-bootstrap-lock'
        $null = New-Item -ItemType Directory -Path $ServerRoot -Force
        Write-Json (Join-Path $ServerRoot '.lan-kit-owner.json') @{ SchemaVersion = 1; KitId = $Configuration.KitId }
        $lockFile = Join-Path $ServerRoot '.lan-kit.lock'
        [IO.File]::WriteAllText($lockFile, 'not a kit lock', $Utf8)
        Invoke-InstallBoundary $false 'reject-nonempty-bootstrap-lock'
        if ([IO.File]::ReadAllText($lockFile, $Utf8) -cne 'not a kit lock') { throw 'Rejected bootstrap file was changed.' }

        function Get-Item {
            param([string] $LiteralPath, [switch] $Force)
            if ($LiteralPath -ieq $script:ReparsePath) { return [pscustomobject]@{ Attributes = ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint) } }
            return Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force:$Force
        }
        try {
            foreach ($target in @('runtime', 'downloads')) {
                New-InstallFixture ('linked-' + $target)
                $script:ServerRoot = Join-Path ([IO.Path]::GetDirectoryName($RuntimeRoot)) 'custom-server'
                $null = New-Item -ItemType Directory -Path $DownloadRoot -Force
                $script:ReparsePath = $RuntimeRoot
                if ($target -eq 'downloads') { $script:ReparsePath = $DownloadRoot }
                Invoke-InstallBoundary $false ('reject-linked-' + $target + '-with-custom-server-root')
                if (Test-Path -LiteralPath $ServerRoot) { throw 'Linked cache preflight created server files.' }
            }
        }
        finally { Remove-Item -LiteralPath Function:\Get-Item }

        if ($env:OS -ne 'Windows_NT') { throw 'Native SteamCMD boundary checks require Windows. Run Test.cmd on Windows.' }
        $NativeSteamRoot = Join-Path $TemporaryRoot 'native steamcmd fixture'
        $null = New-Item -ItemType Directory -Path $NativeSteamRoot -Force
        $nativeSource = @'
using System;
using System.IO;
using System.Text;
public static class SteamCmdTestFixture
{
    public static int Main(string[] args)
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string counter = Path.Combine(root, "calls.txt");
        int call = File.Exists(counter) ? int.Parse(File.ReadAllText(counter)) : 0;
        File.WriteAllText(counter, (call + 1).ToString());
        File.AppendAllText(Path.Combine(root, "arguments.txt"), string.Join("|", args) + Environment.NewLine);
        string[] plan = File.ReadAllLines(Path.Combine(root, "plan.txt"));
        if (call >= plan.Length) { Console.WriteLine("Unexpected extra invocation"); return 99; }
        string[] step = plan[call].Split(new char[] { '\t' }, 2);
        string output = Encoding.UTF8.GetString(Convert.FromBase64String(step[1]));
        if (output.Length != 0) Console.WriteLine(output);
        return int.Parse(step[0]);
    }
}
'@
        Add-Type -AssemblyName Microsoft.CSharp
        $provider = [Microsoft.CSharp.CSharpCodeProvider]::new()
        try {
            $compilerOptions = [CodeDom.Compiler.CompilerParameters]::new()
            $compilerOptions.GenerateExecutable = $true
            $compilerOptions.GenerateInMemory = $false
            $compilerOptions.TreatWarningsAsErrors = $true
            $compilerOptions.OutputAssembly = Join-Path $NativeSteamRoot 'steamcmd.exe'
            $compilation = $provider.CompileAssemblyFromSource($compilerOptions, $nativeSource)
            if ($compilation.Errors.Count -ne 0 -or $compilation.NativeCompilerReturnValue -ne 0) { throw ('Native SteamCMD fixture did not compile: ' + ($compilation.Errors -join '; ')) }
        }
        finally { $provider.Dispose() }
        function Assert-ServerBinary { $script:BinaryChecks++ }
        function Start-Sleep { param([int] $Seconds) $script:RetryDelays += $Seconds }
        $success = "Success! App '222860' fully installed."
        $missing = "ERROR! Failed to install app '222860' (Missing configuration)"
        Test-SteamInstall 'steam-success-requires-confirmation-and-exit-zero' @([pscustomobject]@{ Code = 0; Output = $success }) $true 1 @()
        Test-SteamInstall 'steam-success-text-with-error-exit-is-rejected' @([pscustomobject]@{ Code = 9; Output = $success }) $false 1 @()
        Test-SteamInstall 'steam-exit-zero-without-confirmation-is-rejected' @([pscustomobject]@{ Code = 0; Output = 'Download started.' }) $false 1 @()
        Test-SteamInstall 'steam-stale-confirmation-does-not-hide-empty-output' @([pscustomobject]@{ Code = 0; Output = '' }) $false 1 @() $success
        Test-SteamInstall 'steam-missing-configuration-recovers' @([pscustomobject]@{ Code = 7; Output = $missing }, [pscustomobject]@{ Code = 0; Output = "Success! App '222860' already up to date." }) $true 2 @(2)
        Test-SteamInstall 'steam-missing-configuration-has-bounded-retries' @([pscustomobject]@{ Code = 7; Output = $missing }, [pscustomobject]@{ Code = 7; Output = $missing }, [pscustomobject]@{ Code = 7; Output = $missing }) $false 3 @(2, 4)
        Test-SteamInstall 'steam-fatal-error-is-not-retried' @([pscustomobject]@{ Code = 7; Output = "ERROR! Failed to install app '222860' (Disk write failure)" }) $false 1 @()
        Test-SteamInstall 'steam-mixed-errors-are-not-retried' @([pscustomobject]@{ Code = 7; Output = ($missing + "`nERROR! Disk write failure") }) $false 1 @()
    }

    if ($Group -eq 'All') {
        $ServerRoot = Join-Path $TemporaryRoot 'profile-server'
        $Configuration = [pscustomobject]@{ Hostname = 'Test LAN'; EnableKeepLaser = $false; Port = 27016 }
        $profileRelative = 'left4dead2/cfg/lan-kit.cfg'
        $profile = Join-Safe $ServerRoot $profileRelative
        $userConfig = Join-Safe $ServerRoot 'left4dead2/cfg/server.cfg'
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($profile)) -Force
        [IO.File]::WriteAllText($profile, '// previous managed profile', $Utf8)
        [IO.File]::WriteAllText($userConfig, 'sm_cvar z_common_limit 7', $Utf8)
        $State = [pscustomobject]@{ Files = @([pscustomobject]@{ Path = $profileRelative; Sha256 = (Get-Sha $profile) }) }
        Update-LaunchProfile
        $text = [IO.File]::ReadAllText($profile, $Utf8)
        foreach ($setting in @(@('z_common_limit', 18), @('z_mob_spawn_min_size', 6), @('z_mob_spawn_max_size', 18), @('z_mega_mob_size', 30), @('z_non_head_damage_factor_easy', 1))) {
            if ([regex]::Matches($text, ('(?m)^sm_cvar ' + $setting[0] + ' ' + $setting[1] + '\s*$')).Count -ne 1) { throw ('Unexpected casual setting: ' + $setting[0]) }
        }
        if ($text -notmatch '(?m)^hostname "Test LAN"\s*$' -or $text -match '\{\{HOSTNAME\}\}') { throw 'Profile hostname was not rendered.' }
        if ($text.IndexOf('exec server.cfg') -lt $text.IndexOf('sm_cvar z_mega_mob_size') -or $text.IndexOf('sv_lan 1') -lt $text.IndexOf('exec server.cfg')) { throw 'Profile defaults, overrides and LAN guards are out of order.' }
        if ([IO.File]::ReadAllText($userConfig, $Utf8) -cne 'sm_cvar z_common_limit 7') { throw 'User gameplay overrides were overwritten.' }
        if ($State.Files[0].Sha256 -cne (Get-Sha $profile)) { throw 'Managed profile ownership was not updated.' }
        Pass 'update-casual-profile-preserves-user-overrides'
        $profileHash = Get-Sha $profile
        Update-LaunchProfile
        if ((Get-Sha $profile) -cne $profileHash) { throw 'Repeated profile update changed the file.' }
        Pass 'managed-profile-update-is-idempotent'

        $stage = Join-Path $TemporaryRoot 'upgrade-stage'
        $stagedConfig = Join-Safe $stage 'left4dead2/cfg/server.cfg'
        $stagedProfile = Join-Safe $stage $profileRelative
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($stagedConfig)) -Force
        [IO.File]::WriteAllText($stagedConfig, '// new default overrides', $Utf8)
        [IO.File]::WriteAllText($stagedProfile, '// new managed profile', $Utf8)
        $plan = @(Get-StagePlan $stage)
        $userOperation = @($plan | Where-Object { $_.Path -eq 'left4dead2/cfg/server.cfg' })
        $profileOperation = @($plan | Where-Object { $_.Path -eq $profileRelative })
        if ($userOperation.Count -ne 1 -or $userOperation[0].Write -or -not $userOperation[0].Preserve -or $profileOperation.Count -ne 1 -or -not $profileOperation[0].Write) { throw 'Upgrade plan did not preserve overrides while updating the managed profile.' }
        Pass 'upgrade-plan-preserves-user-configuration'
        $binaryRelative = 'left4dead2/addons/sourcemod/plugins/test.smx'
        $sourceBinary = Join-Safe $stage $binaryRelative
        $targetBinary = Join-Safe $ServerRoot $binaryRelative
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($sourceBinary)) -Force
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($targetBinary)) -Force
        [IO.File]::WriteAllText($sourceBinary, 'new component', $Utf8)
        [IO.File]::WriteAllText($targetBinary, 'unowned user component', $Utf8)
        $rejected = $false
        try { $null = Get-StagePlan $stage } catch { $rejected = $true }
        if (-not $rejected -or [IO.File]::ReadAllText($targetBinary, $Utf8) -cne 'unowned user component') { throw 'Upgrade accepted or changed an unknown executable component.' }
        Pass 'upgrade-rejects-unknown-executable'
        [IO.File]::WriteAllText($targetBinary, 'new component', $Utf8)
        $resumed = @((Get-StagePlan $stage) | Where-Object { $_.Path -eq $binaryRelative })
        if ($resumed.Count -ne 1 -or $resumed[0].Write) { throw 'Already-copied component was not recognized after interruption.' }
        Pass 'upgrade-resumes-already-copied-component'

        function Assert-ServerBinary { }
        function Assert-InstalledArtifacts { }
        function Get-NetUDPEndpoint { param($LocalPort, $ErrorAction) return [pscustomobject]@{ OwningProcess = 4321; LocalAddress = '192.168.50.2' } }
        function Get-CimInstance { param($ClassName, $Filter) return [pscustomobject]@{ ProcessId = 4321; ExecutablePath = $ServerExe; CreationDate = [datetime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc) } }
        $TaskName = 'L4D2-LAN-Kit-test'; $OwnerTag = 'L4D2 LAN Kit; KitId=test'
        $ServerExe = Join-Path $ServerRoot 'srcds.exe'
        $ServiceSid = [pscustomobject]@{ Value = 'S-1-5-19' }
        $script:TaskFixture = New-TaskFixture
        $script:TaskFixture.State = 'Running'
        $Metadata = [pscustomobject]@{ Dependencies = (Read-Json (Join-Path $KitRoot 'metadata/dependencies.json')) }
        if ('L4D2 LAN Horde Limits' -notin $Metadata.Dependencies.RuntimePluginNames) { throw 'Mandatory horde plugin is missing from runtime metadata.' }
        $lines = @(); $index = 1
        foreach ($name in $Metadata.Dependencies.RuntimePluginNames) { $lines += ('  {0:00} "{1}" (1.0)' -f $index, $name); $index++ }
        $lines += 'L4D2_LAN_KIT_CONFIG_READY'
        $console = Join-Safe $ServerRoot 'left4dead2/console.log'
        $idle = 'players : 0 humans, 0 bots (4 max) (hibernating) (unreserved)'
        [IO.File]::WriteAllText($console, (($lines + $idle) -join "`n"), $Utf8)
        if (-not (Check-Kit $true $true) -or $script:RoundReady) { throw 'Idle listener was not distinguished from an initialized round.' }
        Pass 'idle-listener-defers-round-initialization'
        $withoutHordePlugin = @($lines | Where-Object { $_ -notmatch '"L4D2 LAN Horde Limits"' })
        [IO.File]::WriteAllText($console, (($withoutHordePlugin + $idle) -join "`n"), $Utf8)
        if (Check-Kit $true $true) { throw 'Idle readiness accepted a missing required plugin.' }
        Pass 'idle-readiness-still-requires-all-plugins'
        $awake = $lines + @($idle, 'Server waking up from hibernation', 'L4D2_LAN_KIT_BOTS_READY')
        [IO.File]::WriteAllText($console, ($awake -join "`n"), $Utf8)
        if ((Check-Kit $true $true) -or $script:RoundReady) { throw 'Awakened round skipped horde initialization using an old idle status.' }
        Pass 'awakened-round-waits-for-horde-initialization'
        $hordeMarker = '[LAN HORDE] coop=1 common=18 mob=6-18 mega=30; scripted timer floors=6/10 seconds'
        [IO.File]::WriteAllText($console, (($awake + $hordeMarker) -join "`n"), $Utf8)
        if (-not (Check-Kit $true $true) -or -not $script:RoundReady) { throw 'Initialized horde profile did not become round-ready.' }
        Pass 'readiness-accepts-initialized-horde-profile'
        $runPath = Join-Safe $ServerRoot '.lan-kit-run.json'
        $previousRun = "previous run must stay excluded`n"
        $currentRun = (($awake + $hordeMarker) -join "`n") + "`n" + ('x' * (300 * 1024)) + "`nend-of-current-run`n"
        [IO.File]::WriteAllText($console, ($previousRun + $currentRun), $Utf8)
        $offset = $Utf8.GetByteCount($previousRun)
        Write-Json $runPath @{ ConsoleOffset = $offset; ErrorOffsets = @{} }
        $window = Read-NewLog $console $offset
        if ($window.Length -gt 262144 -or $window.Contains($previousRun.Trim()) -or -not $window.EndsWith("end-of-current-run`n")) { throw 'Bounded log reader lost its current-run offset or recent tail.' }
        if (-not (Check-Kit $true $true) -or -not $script:RoundReady) { throw 'Long-log readiness lost startup markers before a process readiness cache existed.' }
        Pass 'long-log-readiness-preserves-startup-and-current-tail'
        [IO.File]::AppendAllText($console, "[SM] Exception reported: fresh long-console failure`n", $Utf8)
        $rejected = $false
        try { $null = Check-Kit $true $true } catch { $rejected = $true }
        if (-not $rejected) { throw 'Long-log readiness ignored a fresh console error.' }
        Pass 'long-log-readiness-rejects-fresh-tail-error'
        $run = @{ ConsoleOffset = 0; ErrorOffsets = @{}; ReadyPid = 4321; ReadyCreationUtc = '2025-01-01T00:00:00.0000000Z' }
        Write-Json $runPath $run
        [IO.File]::WriteAllText($console, ($lines -join "`n"), $Utf8)
        if (Check-Kit $true $true) { throw 'A recycled process ID reused stale readiness.' }
        Pass 'readiness-rejects-recycled-process-id'
        $run.ReadyCreationUtc = [datetime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc).ToString('o')
        Write-Json $runPath $run
        if (-not (Check-Kit $true $true) -or -not $script:RoundReady) { throw 'Verified readiness for the same process was lost after old markers rotated.' }
        Pass 'readiness-cache-is-bound-to-process-creation'
        $errors = Join-Safe $ServerRoot 'left4dead2/addons/sourcemod/logs/errors_test.log'
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($errors)) -Force
        [IO.File]::WriteAllText($errors, '[SM] Exception reported: test runtime failure', $Utf8)
        $rejected = $false
        try { $null = Check-Kit $true $true } catch { $rejected = $true }
        if (-not $rejected) { throw 'Cached readiness accepted a fresh plugin error log.' }
        Pass 'cached-readiness-rejects-fresh-plugin-errors'
    }

    if ($Group -in @('All', 'OptionalCleanup')) {
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
    }
    Write-Host ("Validation checks passed: {0}. No game server was installed or started." -f $Passed)
}
finally {
    if (Test-Path -LiteralPath $TemporaryRoot) { Remove-Item -LiteralPath $TemporaryRoot -Force -Recurse }
}
