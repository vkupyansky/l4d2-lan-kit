#requires -Version 5.1
[CmdletBinding()]
param([string] $EntryScript)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($EntryScript)) { $EntryScript = $PSCommandPath }
if ([string]::IsNullOrWhiteSpace($EntryScript)) { throw 'EntryScript is required for the manifest command interface.' }
$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($EntryScript))) '..'))
$manifestPath = Join-Path $root 'metadata\bundle.json'
$manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
$files = @()
foreach ($folder in @('assets', 'templates', 'licenses')) {
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root $folder) -File -Recurse | Sort-Object FullName)) {
        if ($file.Name -eq '.DS_Store') { continue }
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $file.Extension -notin @('.sp', '.inc', '.nut', '.cfg', '.txt', '.json')) { throw "Unsupported bundle file: $($file.FullName)" }
        $files += $file
    }
}
$files += Get-Item -LiteralPath (Join-Path $root 'config.example.json')
$files += Get-Item -LiteralPath (Join-Path $root 'metadata\dependencies.json')
$manifest.Files = @($files | ForEach-Object {
    [ordered]@{ Path = $_.FullName.Substring($root.TrimEnd('\', '/').Length + 1).Replace('\', '/'); Bytes = $_.Length; Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
})
$json = ($manifest | ConvertTo-Json -Depth 30).Replace("`r`n", "`n") + "`n"
[IO.File]::WriteAllText($manifestPath, $json, [Text.UTF8Encoding]::new($false))
Write-Host ("Updated {0} bundle file hashes." -f $manifest.Files.Count)
