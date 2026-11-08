#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Start', 'Stop', 'Check', 'ValidateOnly')]
    [string] $Action = 'Check',
    [string] $ConfigPath,
    [string] $EntryScript
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ExplicitConfigPath = $PSBoundParameters.ContainsKey('ConfigPath')
if ([string]::IsNullOrWhiteSpace($EntryScript)) { $EntryScript = $PSCommandPath }
if ([string]::IsNullOrWhiteSpace($EntryScript)) { throw 'EntryScript is required when running the command interface.' }
$EntryScript = [IO.Path]::GetFullPath($EntryScript)
$KitRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($EntryScript)) '..'))
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $KitRoot 'kit.config.json' }
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$Utf8 = [Text.UTF8Encoding]::new($false)
$RuntimeLock = $null
$script:RoundReady = $false

function Read-Json([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing file: $Path" }
    return ([IO.File]::ReadAllText($Path, $Utf8) | ConvertFrom-Json -ErrorAction Stop)
}

function Write-AtomicText([string] $Path, [string] $Text) {
    $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.partial'
    try {
        [IO.File]::WriteAllText($temporary, $Text, $Utf8)
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Write-Json([string] $Path, $Value) {
    Write-AtomicText $Path (($Value | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
}

function Get-Sha([string] $Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Join-Safe([string] $Root, [string] $Relative) {
    $Relative = $Relative.Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($Relative) -or $Relative -match '[:\x00-\x1f]' -or [IO.Path]::IsPathRooted($Relative)) {
        throw "Unsafe relative path: $Relative"
    }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath((Join-Path $Root $Relative.Replace('/', [IO.Path]::DirectorySeparatorChar)))
    if (-not $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw "Path escapes its root: $Relative" }
    return $full
}

function Assert-NoReparse([string] $Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrEmpty($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            if (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are not supported in the installation path: $cursor"
            }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
}

function Assert-Integer($Value, [string] $Name, [long] $Minimum, [long] $Maximum) {
    if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -lt $Minimum -or $Value -gt $Maximum) {
        throw "$Name must be an integer from $Minimum to $Maximum."
    }
}

function Get-Configuration([bool] $Create) {
    $isExample = -not (Test-Path -LiteralPath $ConfigPath)
    if ($isExample -and $ExplicitConfigPath) { throw "The requested configuration does not exist: $ConfigPath" }
    if ($isExample -and -not $Create -and $Action -notin @('ValidateOnly', 'Install')) { throw 'Run Install.cmd first; kit.config.json does not exist.' }
    $path = $ConfigPath
    if ($isExample) { $path = Join-Path $KitRoot 'config.example.json' }
    $raw = [IO.File]::ReadAllText($path, $Utf8)
    $configuration = Read-Json $path
    $fields = @('SchemaVersion', 'KitId', 'ServerRoot', 'ListenIPv4', 'Port', 'StartMap', 'Profile', 'Hostname', 'EnableKeepLaser')
    $actual = @($configuration.PSObject.Properties.Name)
    if (@(Compare-Object $fields $actual -CaseSensitive).Count -ne 0) { throw 'Configuration fields must match config.example.json exactly.' }
    foreach ($field in $fields) {
        if ([regex]::Matches($raw, '"' + [regex]::Escape($field) + '"\s*:').Count -ne 1) { throw "Duplicate or missing configuration field: $field" }
    }
    Assert-Integer $configuration.SchemaVersion 'SchemaVersion' 1 1
    Assert-Integer $configuration.Port 'Port' 1024 65535
    if ($configuration.EnableKeepLaser -isnot [bool]) { throw 'EnableKeepLaser must be true or false.' }
    if ($configuration.Profile -cne 'casual') { throw 'The supported Profile is casual.' }
    if ($configuration.ServerRoot -isnot [string] -or [string]::IsNullOrWhiteSpace($configuration.ServerRoot) -or $configuration.ServerRoot -match '["\x00-\x1f]') { throw 'ServerRoot must be a non-empty local path.' }
    $windowsPath = $configuration.ServerRoot.Replace('/', '\')
    if ($windowsPath -match '^\\' -or $windowsPath -match '(^|\\)\.\.(\\|$)' -or $windowsPath -match '(^|\\)Windows(\\|$)' -or $windowsPath -match '^[A-Za-z]:\\?$' -or ($windowsPath.Contains(':') -and $windowsPath -notmatch '^[A-Za-z]:\\[^:]')) { throw 'ServerRoot must be a local directory, outside a drive root or Windows system directory, without parent traversal.' }
    if ($configuration.StartMap -isnot [string] -or $configuration.StartMap -cnotmatch '^[a-z0-9_]{1,80}$') { throw 'StartMap must be a map identifier, for example c8m1_apartment.' }
    if ($configuration.Hostname -isnot [string] -or $configuration.Hostname.Length -lt 1 -or $configuration.Hostname.Length -gt 100 -or $configuration.Hostname -match '["\\;\x00-\x1f]') { throw 'Hostname contains an unsupported character or length.' }
    if ($null -ne $configuration.ListenIPv4) {
        $parsed = $null
        if ($configuration.ListenIPv4 -isnot [string] -or -not [Net.IPAddress]::TryParse($configuration.ListenIPv4, [ref]$parsed) -or $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $parsed.ToString() -cne $configuration.ListenIPv4 -or $parsed.GetAddressBytes()[0] -in @(0, 127) -or $parsed.GetAddressBytes()[0] -ge 224) { throw 'ListenIPv4 must be null or one canonical local IPv4 address.' }
    }
    if ($null -eq $configuration.KitId -and $Create) { $configuration.KitId = [guid]::NewGuid().ToString('D') }
    if ($null -ne $configuration.KitId) {
        $parsedId = [guid]::Empty
        if ($configuration.KitId -isnot [string] -or -not [guid]::TryParseExact($configuration.KitId, 'D', [ref]$parsedId) -or $parsedId -eq [guid]::Empty) { throw 'KitId must be a non-empty GUID or null before the first installation.' }
    }
    elseif ($Action -notin @('ValidateOnly', 'Install')) { throw 'Run Install.cmd to initialize KitId.' }
    if ($Create -and ($isExample -or $raw -match '"KitId"\s*:\s*null')) { Write-Json $ConfigPath $configuration }
    return $configuration
}

function Assert-Bundle {
    $manifest = Read-Json (Join-Path $KitRoot 'metadata\bundle.json')
    if ($manifest.SchemaVersion -ne 1) { throw 'Unsupported bundle metadata schema.' }
    $seen = @{}
    foreach ($file in $manifest.Files) {
        if ($file.Path -isnot [string] -or $file.Sha256 -notmatch '^[a-f0-9]{64}$' -or $seen.ContainsKey($file.Path)) { throw 'Invalid bundle file metadata.' }
        Assert-Integer $file.Bytes 'Bundled file Bytes' 0 1073741824
        $seen[$file.Path] = $true
        $path = Join-Safe $KitRoot $file.Path
        Assert-NoReparse $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -ne $file.Bytes -or (Get-Sha $path) -ne $file.Sha256) { throw "Bundle integrity failed: $($file.Path)" }
    }
    $dependencies = Read-Json (Join-Path $KitRoot 'metadata\dependencies.json')
    if ($dependencies.SchemaVersion -ne 1 -or $dependencies.Game.AppId -ne 222860 -or $dependencies.Game.ServerDllSha256 -notmatch '^[a-f0-9]{64}$') { throw 'Invalid dependency metadata.' }
    $ids = @{}
    foreach ($package in $dependencies.Packages) {
        $uri = [uri]$package.Url
        if ($uri.Scheme -ne 'https' -or -not $uri.IsAbsoluteUri -or $package.Sha256 -notmatch '^[a-f0-9]{64}$' -or $package.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]+$' -or $ids.ContainsKey($package.Id) -or $package.Id -notin @('steamcmd', 'metamod', 'sourcemod', 'left4lib', 'left4bots', 'acs') -or $package.Kind -notin @('bootstrap', 'zip', 'file')) { throw 'Invalid download metadata.' }
        Assert-Integer $package.Bytes 'Package Bytes' 1 1073741824
        if ($package.Kind -eq 'zip') { $null = Join-Safe $KitRoot $package.DestinationPrefix }
        if ($package.Kind -eq 'file') { $null = Join-Safe $KitRoot $package.Destination }
        $ids[$package.Id] = $true
    }
    foreach ($id in @('steamcmd', 'metamod', 'sourcemod', 'left4lib', 'left4bots', 'acs')) { if (-not $ids.ContainsKey($id)) { throw "Missing package metadata: $id" } }
    if ($dependencies.CompilerSha256 -notmatch '^[a-f0-9]{64}$' -or ([uri]$dependencies.KeepLaser.Url).Scheme -ne 'https' -or $dependencies.KeepLaser.Sha256 -notmatch '^[a-f0-9]{64}$' -or $dependencies.KeepLaser.Name -cne 'l4d2_keeplasers.sp') { throw 'Invalid compiler or optional plugin metadata.' }
    return @{ Bundle = $manifest; Dependencies = $dependencies }
}

function Ensure-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return }
    $scriptLiteral = $EntryScript.Replace("'", "''")
    $configLiteral = $ConfigPath.Replace("'", "''")
    $configArgument = ''
    if ($ExplicitConfigPath) { $configArgument = " -ConfigPath '$configLiteral'" }
    $command = "& ([ScriptBlock]::Create([IO.File]::ReadAllText('$scriptLiteral'))) -Action '$Action' -EntryScript '$scriptLiteral'$configArgument"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded)
    $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    exit $process.ExitCode
}

function Resolve-Network($Configuration) {
    $candidates = @()
    foreach ($address in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop)) {
        if ($address.AddressState -ne 'Preferred' -or $address.IPAddress -match '^(127\.|169\.254\.|0\.)') { continue }
        if ($null -ne $Configuration.ListenIPv4 -and $address.IPAddress -ne $Configuration.ListenIPv4) { continue }
        $profiles = @(Get-NetConnectionProfile -InterfaceIndex $address.InterfaceIndex -ErrorAction SilentlyContinue)
        if ($profiles.Count -eq 1 -and [string]$profiles[0].NetworkCategory -eq 'Private') { $candidates += $address }
    }
    if ($candidates.Count -ne 1) {
        $list = @($candidates | ForEach-Object { $_.IPAddress }) -join ', '
        throw "Expected one IPv4 address on a Private network. Set ListenIPv4 explicitly when several adapters exist. Candidates: $list. Network profiles were not changed."
    }
    if (-not (Get-NetFirewallProfile -Name Private).Enabled) { throw 'The Private firewall profile is disabled; enable it before installing or starting the server.' }
    $address = $candidates[0]
    Assert-Integer ([int]$address.PrefixLength) 'IPv4 prefix' 1 32
    $bytes = ([Net.IPAddress]::Parse($address.IPAddress)).GetAddressBytes()
    $network = @(); $mask = @()
    for ($i = 0; $i -lt 4; $i++) {
        $bits = [Math]::Max(0, [Math]::Min(8, [int]$address.PrefixLength - 8 * $i))
        $m = [int](256 - [Math]::Pow(2, 8 - $bits))
        $mask += $m; $network += ([int]$bytes[$i] -band $m)
    }
    return @{ Address = [string]$address.IPAddress; Subnet = (($network -join '.') + '/' + $address.PrefixLength); NetmaskSubnet = (($network -join '.') + '/' + ($mask -join '.')) }
}

function Get-TaskSid($Task) {
    $id = [string]$Task.Principal.UserId
    if ($id -match '^S-1-') { return $id }
    return ([Security.Principal.NTAccount]::new($id).Translate([Security.Principal.SecurityIdentifier])).Value
}

function Get-OwnedTask {
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($null -eq $task) { return $null }
    if ($task.Description -cne $OwnerTag -or @($task.Actions).Count -ne 1 -or $task.Actions[0].Execute -ine $ServerExe -or $task.Actions[0].WorkingDirectory -ine $ServerRoot -or (Get-TaskSid $task) -ne $ServiceSid.Value -or [string]$task.Principal.RunLevel -ne 'Limited' -or [string]$task.Principal.LogonType -ne 'ServiceAccount' -or ($null -ne $task.Triggers -and @($task.Triggers).Count -gt 0)) { throw "An unknown or modified task owns $TaskName. It was not changed." }
    return $task
}

function Assert-Stopped {
    $task = Get-OwnedTask
    $running = @(Get-CimInstance Win32_Process -Filter "Name = 'srcds.exe'" | Where-Object { $_.ExecutablePath -ieq $ServerExe })
    if (($null -ne $task -and [string]$task.State -eq 'Running') -or $running.Count -gt 0) { throw 'The server is running. Use Stop.cmd before installation.' }
}

function Get-Download($Package) {
    $target = Join-Safe $DownloadRoot $Package.Name
    if (Test-Path -LiteralPath $target) {
        if ((Get-Sha $target) -ne $Package.Sha256 -or (Get-Item -LiteralPath $target).Length -ne $Package.Bytes) { throw "A different cached file exists: $target. It was not overwritten." }
        return $target
    }
    $null = New-Item -ItemType Directory -Path $DownloadRoot -Force
    $temporary = $target + '.' + [guid]::NewGuid().ToString('N') + '.partial'
    try {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Write-Host ("Downloading {0} {1}..." -f $Package.Id, $Package.Version)
                Invoke-WebRequest -Uri $Package.Url -OutFile $temporary -UseBasicParsing -TimeoutSec 300
                break
            }
            catch {
                if ($attempt -eq 3) { throw }
                Start-Sleep -Seconds ([int][Math]::Pow(2, $attempt))
            }
        }
        if ((Get-Sha $temporary) -ne $Package.Sha256 -or (Get-Item -LiteralPath $temporary).Length -ne $Package.Bytes) { throw "Downloaded content failed SHA256/length verification: $($Package.Id). No executable from it was run." }
        [IO.File]::Move($temporary, $target)
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
    return $target
}

function Expand-Package([string] $Archive, [string] $Destination, [string[]] $Exclude) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    $seen = @{}
    try {
        foreach ($entry in $zip.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name)) { continue }
            $relative = $entry.FullName.Replace('\', '/')
            if ($relative -in $Exclude) { continue }
            if ($seen.ContainsKey($relative) -or ((($entry.ExternalAttributes -shr 16) -band 61440) -eq 40960)) { throw "Unsupported duplicate or symbolic link in archive: $relative" }
            $seen[$relative] = $true
            $path = Join-Safe $Destination $relative
            $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($path)) -Force
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $path, $true)
        }
    }
    finally { $zip.Dispose() }
}

function Assert-ServerBinary {
    $dll = Join-Path $ServerRoot 'left4dead2\bin\server.dll'
    if (-not (Test-Path -LiteralPath $ServerExe -PathType Leaf) -or -not (Test-Path -LiteralPath $dll -PathType Leaf)) { throw 'SteamCMD did not install srcds.exe and server.dll.' }
    if ((Get-Sha $dll) -ne $Metadata.Dependencies.Game.ServerDllSha256) { throw 'The official server build differs from the build tested with these plugins. Update the kit compatibility metadata before installing or starting plugins.' }
    $bytes = [IO.File]::ReadAllBytes($dll)
    $pe = [BitConverter]::ToInt32($bytes, 60)
    if ([BitConverter]::ToUInt16($bytes, $pe + 4) -ne 332) { throw 'Expected the Windows x86 server.' }
}

function Set-ServiceAccess([string] $Path, [Security.AccessControl.FileSystemRights] $Rights, [bool] $Container) {
    $inherit = [Security.AccessControl.InheritanceFlags]::None
    if ($Container) { $inherit = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit }
    $acl = Get-Acl -LiteralPath $Path
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($ServiceSid, $Rights, $inherit, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
    $acl.SetAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
    $matching = @((Get-Acl -LiteralPath $Path).GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -eq $ServiceSid.Value -and $_.AccessControlType -eq 'Allow' -and ($_.FileSystemRights -band $Rights) -eq $Rights -and $_.InheritanceFlags -eq $inherit })
    if ($matching.Count -ne 1) { throw "LOCAL SERVICE access was not verified: $Path" }
}

function Set-RuntimePermissions {
    Set-ServiceAccess $ServerRoot ([Security.AccessControl.FileSystemRights]::ReadAndExecute) $true
    foreach ($relative in @('ems', 'logs', 'downloads', 'cfg\sourcemod', 'addons\sourcemod\data', 'addons\sourcemod\logs', 'addons\sourcemod\gamedata', 'addons\sourcemod\configs', 'missions.cache')) {
        $path = Join-Safe (Join-Path $ServerRoot 'left4dead2') $relative
        $null = New-Item -ItemType Directory -Path $path -Force
        Set-ServiceAccess $path ([Security.AccessControl.FileSystemRights]::Modify) $true
    }
    foreach ($relative in @('console.log', 'addonlist.txt')) {
        $path = Join-Safe (Join-Path $ServerRoot 'left4dead2') $relative
        if (-not (Test-Path -LiteralPath $path)) { [IO.File]::WriteAllText($path, '', $Utf8) }
        Set-ServiceAccess $path ([Security.AccessControl.FileSystemRights]::Modify) $false
    }
}

function Set-LaunchConfiguration($Network) {
    $rule = Get-NetFirewallRule -PolicyStore PersistentStore -Name $RuleName -ErrorAction SilentlyContinue
    if ($null -ne $rule) {
        $app = Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule
        if ($rule.Description -cne $OwnerTag -or $app.Program -ine $ServerExe) { throw 'An unknown firewall rule uses the kit rule name; it was not changed.' }
    }
    $parameters = @{ Name = $RuleName; PolicyStore = 'PersistentStore'; Enabled = 'True'; Profile = 'Private'; Direction = 'Inbound'; Action = 'Allow'; EdgeTraversalPolicy = 'Block'; LocalAddress = $Network.Address; RemoteAddress = $Network.Subnet; Protocol = 'UDP'; LocalPort = [string]$Configuration.Port; Program = $ServerExe; Description = $OwnerTag }
    if ($null -eq $rule) { $null = New-NetFirewallRule @parameters -DisplayName ('L4D2 LAN Kit UDP ' + $Configuration.Port) }
    else { Set-NetFirewallRule @parameters }
    $rule = Get-NetFirewallRule -PolicyStore PersistentStore -Name $RuleName
    $ports = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule
    $addresses = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule
    if ([string]$rule.Profile -ne 'Private' -or [string]$ports.LocalPort -ne [string]$Configuration.Port -or [string]$addresses.LocalAddress -ne $Network.Address -or [string]$addresses.RemoteAddress -notin @($Network.Subnet, $Network.NetmaskSubnet)) { throw 'Firewall verification failed.' }
    $task = Get-OwnedTask
    if ($null -ne $task -and [string]$task.State -eq 'Running') { throw 'Stop the server before changing its launch configuration.' }
    $arguments = '-console -condebug -game left4dead2 -ip {0} -port {1} +sv_lan 1 +servercfgfile lan-kit.cfg +map {2}' -f $Network.Address, $Configuration.Port, $Configuration.StartMap
    if ($null -ne $task -and $null -ne $State -and $task.Actions[0].Arguments -cne $State.TaskArguments) { throw 'The existing task arguments were modified outside the kit; they were not overwritten.' }
    $taskAction = New-ScheduledTaskAction -Execute $ServerExe -Argument $arguments -WorkingDirectory $ServerRoot
    $principal = New-ScheduledTaskPrincipal -UserId $ServiceSid.Value -LogonType ServiceAccount -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -Priority 6 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $definition = New-ScheduledTask -Action $taskAction -Principal $principal -Settings $settings -Description $OwnerTag
    $null = Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -InputObject $definition -Force
    $null = Get-OwnedTask
    return $arguments
}

function Build-Plugins([string] $Stage, [string] $Compiler, [bool] $KeepLaser) {
    $sm = Join-Path $Stage 'left4dead2\addons\sourcemod'
    $names = @('left4dhooks', 'l4d_path_to_goal', 'l4d2_item_hint', 'l4d_drop', 'l4d_use_priority', 'trigger_horde_notify', 'l4d2_lan_horde_limits')
    if ($KeepLaser) { $names += 'l4d2_keeplasers' }
    foreach ($name in $names) {
        $source = Join-Path $sm ('scripting\' + $name + '.sp')
        $output = Join-Path $sm ('plugins\' + $name + '.smx')
        Write-Host "Compiling $name with warnings as errors..."
        & $Compiler '-E' '-i' (Join-Path $sm 'scripting\include') $source '-o' $output
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) { throw "Plugin compilation failed: $name" }
    }
}

function Stage-KeepLaser([string] $Stage) {
    $package = $Metadata.Dependencies.KeepLaser
    $source = Join-Safe $DownloadRoot $package.Name
    if (-not (Test-Path -LiteralPath $source)) {
        try { $source = Get-Download $package }
        catch { throw "Optional Keep Laser download failed. Save the original author file from $($package.Url) to $source, then rerun Install.cmd. Its SHA256 is verified. You may also set EnableKeepLaser=false. Original error: $($_.Exception.Message)" }
    }
    if ((Get-Sha $source) -ne $package.Sha256) { throw 'Keep Laser local import SHA256 failed.' }
    $text = [IO.File]::ReadAllText($source, $Utf8)
    $start = $text.IndexOf('public Action LaserDroppedDelay(')
    $end = $text.IndexOf('// ItemPickup is called', $start)
    if ($start -lt 0 -or $end -lt $start) { throw 'Keep Laser source layout differs from the verified source.' }
    $callback = $text.Substring($start, $end - $start)
    if ([regex]::Matches($callback, '\breturn;').Count -ne 4) { throw 'Keep Laser callback shape failed verification.' }
    $callback = [regex]::Replace($callback, '\breturn;', 'return Plugin_Stop;')
    $lastBrace = $callback.LastIndexOf('}')
    $callback = $callback.Insert($lastBrace, "`r`n`treturn Plugin_Stop;`r`n")
    $text = $text.Substring(0, $start) + $callback + $text.Substring($end)
    $upgradeStart = $text.IndexOf('public Action Event_ReceiveUpgrade(')
    $upgradeEnd = $text.IndexOf('public Action Event_WeaponDrop(', $upgradeStart)
    $upgrade = $text.Substring($upgradeStart, $upgradeEnd - $upgradeStart)
    $upgrade = $upgrade.Insert($upgrade.LastIndexOf('}'), "`r`n`treturn Plugin_Continue;`r`n")
    $text = $text.Substring(0, $upgradeStart) + $upgrade + $text.Substring($upgradeEnd)
    $path = Join-Path $Stage 'left4dead2\addons\sourcemod\scripting\l4d2_keeplasers.sp'
    [IO.File]::WriteAllText($path, $text, $Utf8)
    $config = Join-Path $Stage 'left4dead2\cfg\sourcemod\L4D2_KeepLasers.cfg'
    [IO.File]::WriteAllText($config, "sm_keeplasers_enable 1`r`nsm_keeplasers_mode 0`r`nsm_keeplasers_nohint 1`r`nsm_keeplasers_debug 0`r`n", $Utf8)
}

function Get-StagePlan([string] $Stage) {
    $previous = @{}
    if ($null -ne $State) { foreach ($entry in $State.Files) { $previous[$entry.Path] = $entry.Sha256 } }
    $operations = @()
    foreach ($source in @(Get-ChildItem -LiteralPath $Stage -File -Recurse)) {
        $relative = $source.FullName.Substring($Stage.TrimEnd('\').Length + 1).Replace('\', '/')
        $target = Join-Safe $ServerRoot $relative
        Assert-NoReparse $target
        $hash = Get-Sha $source.FullName
        $preserve = $relative -match '^left4dead2/(cfg/|ems/|addons/sourcemod/(configs/|data/))' -and $relative -ne 'left4dead2/cfg/lan-kit.cfg'
        if (Test-Path -LiteralPath $target) {
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "A directory conflicts with a file: $relative" }
            $current = Get-Sha $target
            if ($preserve) { $operations += @{ Path = $relative; Target = $target; Source = $source.FullName; Sha256 = $current; Write = $false; Preserve = $true }; continue }
            if ($current -ne $hash -and (-not $previous.ContainsKey($relative) -or $current -ne $previous[$relative])) { throw "An unknown or modified file would be overwritten: $relative" }
        }
        $operations += @{ Path = $relative; Target = $target; Source = $source.FullName; Sha256 = $hash; Write = (-not (Test-Path -LiteralPath $target) -or (Get-Sha $target) -ne $hash); Preserve = $preserve }
    }
    return $operations
}

function Remove-DisabledOptionalLaser {
    if ($null -eq $State -or -not $State.KeepLaser -or $Configuration.EnableKeepLaser) { return }
    $relative = 'left4dead2/addons/sourcemod/plugins/l4d2_keeplasers.smx'
    $old = @($State.Files | Where-Object { $_.Path -eq $relative })
    if ($old.Count -ne 1) { throw 'The optional laser plugin ownership record is missing or ambiguous.' }
    $active = Join-Safe $ServerRoot $relative
    if (-not (Test-Path -LiteralPath $active)) { return }
    if (-not (Test-Path -LiteralPath $active -PathType Leaf) -or (Get-Sha $active) -ne $old[0].Sha256) {
        throw 'The installed optional laser plugin was changed; it was not disabled or overwritten.'
    }
    Remove-Item -LiteralPath $active -Force
}

function Install-SteamServer([string] $SteamcmdDirectory) {
    $steamcmd = Join-Path $SteamcmdDirectory 'steamcmd.exe'
    $steamLog = Join-Path $RuntimeRoot 'steamcmd-install.log'
    $successPattern = "(?m)^Success!\s+App '222860' (fully installed|already up to date)\.?\s*$"
    $missingPattern = "^\s*ERROR!\s+Failed to install app '222860' \(Missing configuration\)\.?\s*$"
    Push-Location $SteamcmdDirectory
    try {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            [IO.File]::WriteAllText($steamLog, '', $Utf8)
            & $steamcmd '+force_install_dir' $ServerRoot '+login' 'anonymous' '+app_info_print' '222860' '+app_update' '222860' 'validate' '+quit' | Tee-Object -FilePath $steamLog | Out-Host
            $exitCode = $LASTEXITCODE
            $output = [IO.File]::ReadAllText($steamLog)
            if ($exitCode -eq 0 -and $output -match $successPattern) {
                Assert-ServerBinary
                return
            }
            $failures = @(($output -split "`r?`n") | Where-Object {
                $_ -match '^\s*(ERROR[!:]|FATAL\b|FAILED\b)' -or
                $_ -match '^\s*(Connecting anonymously|Waiting for|Logging in).*\bFAILED\b'
            })
            $missingConfiguration = $exitCode -eq 7 -and $failures.Count -eq 1 -and $failures[0] -match $missingPattern
            if (-not $missingConfiguration -or $attempt -eq 3) {
                if ($exitCode -eq 0) { throw "SteamCMD did not confirm successful app installation. Inspect $steamLog." }
                throw "SteamCMD failed with exit code $exitCode. Inspect $steamLog."
            }
            Write-Host ('SteamCMD reported Missing configuration; refreshing app metadata and retrying ({0}/3).' -f ($attempt + 1))
            Start-Sleep -Seconds ([int][Math]::Pow(2, $attempt))
        }
    }
    finally { Pop-Location }
}

function Install-Kit {
    $network = Resolve-Network $Configuration
    Assert-Stopped
    Assert-NoReparse $RuntimeRoot
    Assert-NoReparse $DownloadRoot
    $ownerPath = Join-Path $ServerRoot '.lan-kit-owner.json'
    $serverOwned = $false
    if (Test-Path -LiteralPath $ownerPath) {
        $owner = Read-Json $ownerPath
        if ($owner.KitId -cne $Configuration.KitId) { throw 'ServerRoot belongs to another installation.' }
        $serverOwned = $true
    }
    elseif (Test-Path -LiteralPath $ServerRoot) {
        if (@(Get-ChildItem -LiteralPath $ServerRoot -Force).Count -gt 0) { throw 'ServerRoot is not empty and has no kit ownership marker. Existing files were not changed.' }
    }
    $runtimeOwnerPath = Join-Path $RuntimeRoot '.lan-kit-runtime.json'
    if (Test-Path -LiteralPath $runtimeOwnerPath) {
        if ((Read-Json $runtimeOwnerPath).KitId -cne $Configuration.KitId) { throw 'The runtime directory belongs to another installation.' }
    }
    elseif (Test-Path -LiteralPath $RuntimeRoot) {
        $allowed = @{}
        foreach ($package in @($Metadata.Dependencies.Packages) + @($Metadata.Dependencies.KeepLaser)) { $allowed[$package.Name] = $package.Sha256 }
        foreach ($file in @(Get-ChildItem -LiteralPath $RuntimeRoot -File -Recurse -Force)) {
            # An interrupted bootstrap can own these files before its runtime marker exists.
            if ($serverOwned -and ($file.FullName -ieq $ownerPath -or ($file.FullName -ieq (Join-Path $ServerRoot '.lan-kit.lock') -and $file.Length -eq 0))) { continue }
            if ($file.DirectoryName -ine $DownloadRoot -or -not $allowed.ContainsKey($file.Name) -or (Get-Sha $file.FullName) -ne $allowed[$file.Name]) { throw 'An unknown runtime file exists. It was not executed or overwritten.' }
        }
    }
    $null = New-Item -ItemType Directory -Path $ServerRoot -Force
    $lock = [IO.File]::Open((Join-Path $ServerRoot '.lan-kit.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        if (-not (Test-Path -LiteralPath $ownerPath)) { Write-Json $ownerPath @{ SchemaVersion = 1; KitId = $Configuration.KitId } }
        Write-Json $runtimeOwnerPath @{ SchemaVersion = 1; KitId = $Configuration.KitId }
        $paths = @{}
        foreach ($package in $Metadata.Dependencies.Packages) { $paths[$package.Id] = Get-Download $package }
        $stage = Join-Path $RuntimeRoot ('stage-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $stage
        try {
            foreach ($package in $Metadata.Dependencies.Packages) {
                if ($package.Kind -eq 'zip') { Expand-Package $paths[$package.Id] (Join-Safe $stage $package.DestinationPrefix) @($package.Exclude) }
                elseif ($package.Kind -eq 'file') {
                    $target = Join-Safe $stage $package.Destination
                    $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force
                    Copy-Item -LiteralPath $paths[$package.Id] -Destination $target
                }
            }
            foreach ($file in $Metadata.Bundle.Files) {
                if (-not $file.Path.StartsWith('assets/overlay/', [StringComparison]::Ordinal)) { continue }
                $target = Join-Safe $stage $file.Path.Substring('assets/overlay/'.Length)
                $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force
                Copy-Item -LiteralPath (Join-Safe $KitRoot $file.Path) -Destination $target -Force
            }
            if ($Configuration.EnableKeepLaser) { Stage-KeepLaser $stage }
            $compiler = Join-Path $stage 'left4dead2\addons\sourcemod\scripting\spcomp.exe'
            if ((Get-Sha $compiler) -ne $Metadata.Dependencies.CompilerSha256) { throw 'SourcePawn compiler integrity failed.' }
            Build-Plugins $stage $compiler $Configuration.EnableKeepLaser
            $template = [IO.File]::ReadAllText((Join-Path $KitRoot 'templates\lan-kit.cfg'), $Utf8).Replace('{{HOSTNAME}}', $Configuration.Hostname)
            [IO.File]::WriteAllText((Join-Path $stage 'left4dead2\cfg\lan-kit.cfg'), $template, $Utf8)
            if (-not (Test-Path -LiteralPath (Join-Path $ServerRoot 'left4dead2\cfg\server.cfg'))) { Copy-Item -LiteralPath (Join-Path $KitRoot 'templates\server.cfg') -Destination (Join-Path $stage 'left4dead2\cfg\server.cfg') }
            $steamcmdDirectory = Join-Path $RuntimeRoot 'steamcmd'
            $steamcmd = Join-Path $steamcmdDirectory 'steamcmd.exe'
            if (-not (Test-Path -LiteralPath $steamcmd)) { Expand-Package $paths.steamcmd $steamcmdDirectory @() }
            Write-Host 'SteamCMD will download and validate official app 222860. This can take several minutes.'
            Assert-Stopped
            Install-SteamServer $steamcmdDirectory
            $plan = @(Get-StagePlan $stage)
            Assert-Stopped
            Remove-DisabledOptionalLaser
            foreach ($operation in $plan) {
                if (-not $operation.Write) { continue }
                $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($operation.Target)) -Force
                $temporary = $operation.Target + '.' + [guid]::NewGuid().ToString('N') + '.partial'
                Copy-Item -LiteralPath $operation.Source -Destination $temporary
                if ((Get-Sha $temporary) -ne $operation.Sha256) { throw 'Staged copy hash failed.' }
                if (Test-Path -LiteralPath $operation.Target) { [IO.File]::Replace($temporary, $operation.Target, [System.Management.Automation.Language.NullString]::Value) }
                else { [IO.File]::Move($temporary, $operation.Target) }
            }
            Set-RuntimePermissions
            $arguments = Set-LaunchConfiguration $network
            $files = @($plan | ForEach-Object { @{ Path = $_.Path; Sha256 = $_.Sha256; Preserve = $_.Preserve } })
            Write-Json $StatePath @{ SchemaVersion = 1; KitId = $Configuration.KitId; ServerRoot = $ServerRoot; TaskArguments = $arguments; InstalledUtc = [DateTime]::UtcNow.ToString('o'); KeepLaser = $Configuration.EnableKeepLaser; BundleSha256 = (Get-Sha (Join-Path $KitRoot 'metadata\bundle.json')); Files = $files }
            Write-Host 'Installation complete. The server has not been started. Use Start.cmd.'
            Write-Host ('Keep Laser Sights enabled: ' + $Configuration.EnableKeepLaser)
        }
        finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Force -Recurse } }
    }
    finally { $lock.Dispose() }
}

function Assert-InstalledArtifacts {
    foreach ($file in $State.Files) {
        if ($file.Preserve -or $file.Path -notmatch '\.(smx|dll|vpk)$') { continue }
        $path = Join-Safe $ServerRoot $file.Path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Sha $path) -ne $file.Sha256) { throw "An installed executable addon is missing or changed: $($file.Path). Run Install.cmd after reviewing the change." }
    }
}

function Update-LaunchProfile {
    $relative = 'left4dead2/cfg/lan-kit.cfg'
    $entry = @($State.Files | Where-Object { $_.Path -eq $relative })
    $path = Join-Safe $ServerRoot $relative
    if ($entry.Count -ne 1 -or -not (Test-Path -LiteralPath $path) -or (Get-Sha $path) -ne $entry[0].Sha256) { throw 'The managed launch profile changed. Put persistent gameplay overrides in cfg/server.cfg instead.' }
    $template = [IO.File]::ReadAllText((Join-Path $KitRoot 'templates\lan-kit.cfg'), $Utf8).Replace('{{HOSTNAME}}', $Configuration.Hostname)
    if ([IO.File]::ReadAllText($path, $Utf8) -cne $template) {
        Write-AtomicText $path $template
        $entry[0].Sha256 = Get-Sha $path
    }
}

function Read-NewLog([string] $Path, [long] $Offset) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $start = [Math]::Max(0, $Offset)
        if ($start -gt $stream.Length) { $start = 0 }
        $available = $stream.Length - $start
        if ($available -eq 0) { return '' }
        $spans = @(@{ Offset = $start; Bytes = [Math]::Min($available, 262144) })
        if ($available -gt 262144) {
            # Keep startup markers and recent errors within one bounded read budget.
            $spans = @(@{ Offset = $start; Bytes = 131072 }, @{ Offset = $stream.Length - 131071; Bytes = 131071 })
        }
        $parts = @()
        foreach ($span in $spans) {
            $null = $stream.Seek($span.Offset, [IO.SeekOrigin]::Begin)
            $buffer = [byte[]]::new([int]$span.Bytes)
            $received = 0
            while ($received -lt $buffer.Length) {
                $read = $stream.Read($buffer, $received, $buffer.Length - $received)
                if ($read -eq 0) { break }
                $received += $read
            }
            $memory = [IO.MemoryStream]::new($buffer, 0, $received, $false)
            $reader = [IO.StreamReader]::new($memory, $Utf8)
            try { $parts += $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        return ($parts -join "`n")
    }
    finally { $stream.Dispose() }
}

# A ready listener can await its first player; RoundReady confirms full round initialization.
function Check-Kit([bool] $RequireRunning, [bool] $AllowPending = $false) {
    $script:RoundReady = $false
    Assert-ServerBinary
    if (-not $AllowPending) { Assert-InstalledArtifacts }
    $task = Get-OwnedTask
    if ($null -eq $task) { throw 'The server task is missing. Run Install.cmd.' }
    $endpoints = @(Get-NetUDPEndpoint -LocalPort $Configuration.Port -ErrorAction SilentlyContinue)
    $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'srcds.exe'" | Where-Object { $_.ExecutablePath -ieq $ServerExe })
    $processIds = @($processes | ForEach-Object { $_.ProcessId })
    $owned = @($endpoints | Where-Object { $_.OwningProcess -in $processIds })
    if ([string]$task.State -ne 'Running' -or $owned.Count -eq 0) {
        if ($AllowPending) { return $false }
        $result = (Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath '\').LastTaskResult
        if ($RequireRunning -or [string]$task.State -eq 'Running' -or $processes.Count -gt 0 -or $result -notin @(0, 267011, 267014)) { throw "The server is not ready. Task state: $($task.State); LastTaskResult: $result. Check console.log and missing runtime dependencies." }
        Write-Host ('Server stopped. Task state: ' + $task.State)
        return $true
    }
    $runPath = Join-Path $ServerRoot '.lan-kit-run.json'
    $offset = 0
    $run = $null
    if (Test-Path -LiteralPath $runPath) { $run = Read-Json $runPath; $offset = [long]$run.ConsoleOffset }
    $log = Read-NewLog (Join-Path $ServerRoot 'left4dead2\console.log') $offset
    $errorText = ''
    $errorDirectory = Join-Path $ServerRoot 'left4dead2\addons\sourcemod\logs'
    if (Test-Path -LiteralPath $errorDirectory) {
        foreach ($errorFile in @(Get-ChildItem -LiteralPath $errorDirectory -Filter 'errors_*.log' -File)) {
            $errorOffset = 0
            if ($null -ne $run -and $null -ne $run.PSObject.Properties['ErrorOffsets']) {
                $property = $run.ErrorOffsets.PSObject.Properties[$errorFile.Name]
                if ($null -ne $property) { $errorOffset = [long]$property.Value }
            }
            $errorText += Read-NewLog $errorFile.FullName $errorOffset
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($errorText)) {
        $tail = @($errorText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 12)
        throw ('New SourceMod error-log output: ' + ($tail -join [Environment]::NewLine))
    }
    $bad = @((($log + "`n" + $errorText) -split "`r?`n") | Where-Object { $_ -match '\[SM\].*(Unable to load plugin|Exception reported|Error detected in plugin|was not found)|^\s*\d+\s+<(Failed|Error)>|Fatal error|Host_Error|AN ERROR HAS OCCUR' })
    if ($bad.Count -gt 0) { throw ('Server reported errors: ' + (($bad | Select-Object -Last 8) -join [Environment]::NewLine)) }
    $verified = $false
    if ($null -ne $run -and $null -ne $run.PSObject.Properties['ReadyPid'] -and $null -ne $run.PSObject.Properties['ReadyCreationUtc']) {
        foreach ($process in $processes) {
            if ($process.ProcessId -eq $run.ReadyPid -and $process.CreationDate.ToUniversalTime().ToString('o') -ceq $run.ReadyCreationUtc) { $verified = $true }
        }
    }
    $script:RoundReady = $verified
    if (-not $verified) {
        $missing = @()
        foreach ($name in $Metadata.Dependencies.RuntimePluginNames) {
            if ($log -notmatch ('(?m)^\s*\d+\s+"' + [regex]::Escape($name) + '"\s+\(')) { $missing += $name }
        }
        if ($Configuration.EnableKeepLaser -and $log -notmatch '(?m)^\s*\d+\s+"L4D2 Keep Lasers"\s+\(') { $missing += 'L4D2 Keep Lasers' }
        if ($log -notmatch 'L4D2_LAN_KIT_CONFIG_READY') { $missing += 'server configuration marker' }
        $botsReady = $log -match 'L4D2_LAN_KIT_BOTS_READY'
        $hordeReady = $log -match '(?m)^\[LAN HORDE\] coop=1 common=[1-9]\d* mob=[1-9]\d*-[1-9]\d* mega=[1-9]\d*; scripted timer floors=6/10 seconds\s*$'
        $idleListening = $log -match '(?m)^players\s*:\s*0 humans,\s*\d+ bots[^\r\n]*\(hibernating\)' -and $log -notmatch 'Server waking up from hibernation'
        if (-not $idleListening) {
            if (-not $botsReady) { $missing += 'bot initialization marker' }
            if (-not $hordeReady) { $missing += 'horde profile initialization marker' }
        }
        if ($missing.Count -gt 0) {
            if ($AllowPending) { return $false }
            throw ('Initialization was not confirmed: ' + ($missing -join ', ') + '. Start through Start.cmd and inspect console.log.')
        }
        $script:RoundReady = $botsReady -and $hordeReady
    }
    if ($script:RoundReady) { Write-Host ('Server running. Connect from both clients: connect {0}:{1}' -f $owned[0].LocalAddress, $Configuration.Port) }
    else { Write-Host ('Server listening; round initialization waits for the first player. Connect: connect {0}:{1}' -f $owned[0].LocalAddress, $Configuration.Port) }
    Write-Host ('Console log: ' + (Join-Path $ServerRoot 'left4dead2\console.log'))
    return $true
}

try {
    $Metadata = Assert-Bundle
    if ($Action -ne 'ValidateOnly' -and ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -lt 1)) { throw 'Install, Start, Stop and Check require Windows PowerShell 5.1 on Windows. Use the CMD launchers.' }
    $Configuration = Get-Configuration $false
    if ($Action -eq 'ValidateOnly') {
        Write-Host ('Validation passed: {0} bundled files, {1} pinned downloads, profile {2}. No files or system settings were changed.' -f @($Metadata.Bundle.Files).Count, @($Metadata.Dependencies.Packages).Count, $Configuration.Profile)
        exit 0
    }
    Ensure-Administrator
    if ($Action -eq 'Install') { $Configuration = Get-Configuration $true }
    $ServiceSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-19')
    if ([IO.Path]::IsPathRooted($Configuration.ServerRoot)) { $ServerRoot = [IO.Path]::GetFullPath($Configuration.ServerRoot) }
    else { $ServerRoot = Join-Safe $KitRoot $Configuration.ServerRoot }
    if ($ServerRoot -notmatch '^[A-Za-z]:\\' -or $ServerRoot.TrimEnd('\') -eq [IO.Path]::GetPathRoot($ServerRoot).TrimEnd('\') -or $ServerRoot.StartsWith([Environment]::GetFolderPath('Windows').TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'ServerRoot must be a local directory outside the Windows system directory and drive root.' }
    Assert-NoReparse $ServerRoot
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $TaskName = 'L4D2-LAN-Kit-' + $Configuration.KitId
    $RuleName = $TaskName + '-UDP'
    $OwnerTag = 'L4D2 LAN Kit; KitId=' + $Configuration.KitId
    $RuntimeRoot = Join-Path $KitRoot 'runtime'
    $DownloadRoot = Join-Path $RuntimeRoot 'downloads'
    $ServerExe = Join-Path $ServerRoot 'srcds.exe'
    $StatePath = Join-Path $ServerRoot '.lan-kit-state.json'
    $State = $null
    if (Test-Path -LiteralPath $StatePath) {
        $State = Read-Json $StatePath
        if ($State.KitId -cne $Configuration.KitId -or $State.ServerRoot -ine $ServerRoot) { throw 'Installation state belongs to another kit or server path.' }
    }
    if ($Action -eq 'Install') { Install-Kit }
    else {
        if ($null -eq $State) { throw 'Installation is incomplete. Run Install.cmd.' }
        if ($Action -in @('Start', 'Stop')) { $RuntimeLock = [IO.File]::Open((Join-Path $ServerRoot '.lan-kit.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        $task = Get-OwnedTask
        if ($null -eq $task) { throw 'The server task is missing. Run Install.cmd.' }
        if ($Action -eq 'Stop') {
            if ([string]$task.State -eq 'Running') { Stop-ScheduledTask -TaskName $TaskName -TaskPath '\' }
            for ($wait = 0; $wait -lt 20; $wait++) {
                $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'srcds.exe'" | Where-Object { $_.ExecutablePath -ieq $ServerExe })
                if ($processes.Count -eq 0) { break }
                Start-Sleep -Seconds 1
            }
            if ($processes.Count -gt 0) { throw 'The owned server process did not stop. It was not killed with a broad process-name command.' }
            Write-Host 'Server stopped. Its start map and configuration were preserved.'
        }
        elseif ($Action -eq 'Start') {
            Assert-ServerBinary
            Assert-InstalledArtifacts
            if ($State.BundleSha256 -ne (Get-Sha (Join-Path $KitRoot 'metadata\bundle.json')) -or $State.KeepLaser -ne $Configuration.EnableKeepLaser) { throw 'The selected package or optional components changed. Run Install.cmd before starting.' }
            if ([string]$task.State -eq 'Running') { $null = Check-Kit $true; exit 0 }
            $network = Resolve-Network $Configuration
            Update-LaunchProfile
            $State.TaskArguments = Set-LaunchConfiguration $network
            Write-Json $StatePath $State
            $console = Join-Path $ServerRoot 'left4dead2\console.log'
            $offset = 0
            if (Test-Path -LiteralPath $console) { $offset = (Get-Item -LiteralPath $console).Length }
            $errorOffsets = @{}
            $errorDirectory = Join-Path $ServerRoot 'left4dead2\addons\sourcemod\logs'
            if (Test-Path -LiteralPath $errorDirectory) { foreach ($file in @(Get-ChildItem -LiteralPath $errorDirectory -Filter 'errors_*.log' -File)) { $errorOffsets[$file.Name] = $file.Length } }
            $run = @{ StartedUtc = [DateTime]::UtcNow.ToString('o'); ConsoleOffset = $offset; ErrorOffsets = $errorOffsets }
            Write-Json (Join-Path $ServerRoot '.lan-kit-run.json') $run
            Start-ScheduledTask -TaskName $TaskName -TaskPath '\'
            $ready = $false
            for ($wait = 0; $wait -lt 60; $wait++) {
                $ready = Check-Kit $true $true
                if ($ready) { break }
                Start-Sleep -Seconds 1
            }
            if (-not $ready) { $null = Check-Kit $true }
            if ($script:RoundReady) {
                $process = @(Get-CimInstance Win32_Process -Filter "Name = 'srcds.exe'" | Where-Object { $_.ExecutablePath -ieq $ServerExe })
                if ($process.Count -ne 1) { throw 'The ready process was not uniquely identified.' }
                $run.ReadyPid = $process[0].ProcessId
                $run.ReadyCreationUtc = $process[0].CreationDate.ToUniversalTime().ToString('o')
                Write-Json (Join-Path $ServerRoot '.lan-kit-run.json') $run
            }
        }
        elseif ($Action -eq 'Check') { $null = Check-Kit $false }
    }
    exit 0
}
catch { Write-Error $_ -ErrorAction Continue; exit 1 }
finally { if ($null -ne $RuntimeLock) { $RuntimeLock.Dispose() } }
