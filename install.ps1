[CmdletBinding()]
param(
    [string]$LibraryRoot,
    [string]$CodexSkillsRoot,
    [string]$CodexHome,
    [string]$SkillName,
    [switch]$VerifyOnly
)
$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\','/')
$layout = Get-Content -LiteralPath (Join-Path $sourceRoot 'install-layout.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$manifest = Get-Content -LiteralPath (Join-Path $sourceRoot 'install-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
function Child([string]$Root, [string]$Relative) {
    if ([IO.Path]::IsPathRooted($Relative)) { throw "Absolute payload path: $Relative" }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $path = [IO.Path]::GetFullPath((Join-Path $base $Relative))
    if (-not $path.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)) { throw "Path escapes root: $Relative" }
    return $path
}
function Assert-RealPath([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Unexpected linked path: $cursor" }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
}
function Hash([string]$Path, [bool]$Normalize) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($Normalize) { $bytes = [Text.Encoding]::UTF8.GetBytes([Text.Encoding]::UTF8.GetString($bytes).Replace("`r`n","`n")) }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Check-Payload([string]$Root) {
    foreach ($file in $manifest.files) {
        $path = Child $Root $file.path
        Assert-RealPath $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing payload: $($file.path)" }
        if ((Hash $path ([bool]$file.normalize_lf)) -ne $file.sha256) { throw "Checksum differs: $($file.path)" }
    }
    foreach ($spec in $layout.skills) {
        $path = if ($spec.path -eq '.') { $Root } else { Child $Root $spec.path }
        $skill = Get-Content -LiteralPath (Join-Path $path 'SKILL.md') -Raw -Encoding UTF8
        if ($skill -notmatch ('(?m)^name:\s*'+[regex]::Escape($spec.name)+'\s*$')) { throw "Skill name differs: $($spec.name)" }
    }
}
if ($manifest.schema_version -ne 1 -or $manifest.suite_id -ne $layout.suite_id -or @($manifest.files).Count -eq 0) { throw 'Invalid installation manifest.' }
if ($layout.suite_id -notmatch '^[a-z0-9-]+$') { throw 'Invalid suite ID.' }
if (@($manifest.files.path | Sort-Object -Unique).Count -ne @($manifest.files).Count) { throw 'Duplicate payload paths.' }
foreach ($spec in $layout.skills) { if ($spec.name -notmatch '^[a-z0-9-]+$') { throw 'Invalid skill name.' } }
$selected = @($layout.skills)
if ($SkillName) {
    $selected = @($layout.skills | Where-Object name -eq $SkillName)
    if ($selected.Count -ne 1) { throw "Unknown SkillName. Choose: $($layout.skills.name -join ', ')" }
}
Check-Payload $sourceRoot
if ($VerifyOnly) {
    [pscustomobject]@{status='VERIFIED'; suite=$layout.suite_id; files=@($manifest.files).Count; skills=@($selected.name)} | ConvertTo-Json -Depth 5
    return
}
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This installer requires Windows.' }
if (-not $LibraryRoot) { $LibraryRoot = $layout.default_library }
if ($CodexHome -and $CodexSkillsRoot) { throw 'Choose CodexHome OR CodexSkillsRoot.' }
if (-not $CodexSkillsRoot) {
    if (-not $CodexHome) { $CodexHome = $env:CODEX_HOME }
    if (-not $CodexHome) { $CodexHome = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex' }
    $CodexSkillsRoot = Join-Path $CodexHome 'skills'
}
$LibraryRoot = [IO.Path]::GetFullPath($LibraryRoot).TrimEnd('\','/')
$CodexSkillsRoot = [IO.Path]::GetFullPath($CodexSkillsRoot).TrimEnd('\','/')
$roots = @($sourceRoot,$LibraryRoot,$CodexSkillsRoot)
for ($i=0; $i -lt $roots.Count; $i++) {
    $p = $roots[$i]
    Assert-RealPath $p
    if ($p -eq [IO.Path]::GetPathRoot($p).TrimEnd('\','/')) { throw 'A drive root cannot be an installation directory.' }
    if ((Test-Path -LiteralPath $p) -and -not (Test-Path -LiteralPath $p -PathType Container)) { throw "Not a directory: $p" }
    for ($j=$i+1; $j -lt $roots.Count; $j++) {
        $q = $roots[$j]
        if ($p -eq $q -or $p.StartsWith($q+'\',[StringComparison]::OrdinalIgnoreCase) -or $q.StartsWith($p+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Source, library and client entry roots must be separate.' }
    }
}
if (Test-Path -LiteralPath (Join-Path $LibraryRoot '.git')) { throw 'Do not replace a Git working tree. Choose a separate LibraryRoot.' }
$stamp = $layout.suite_id+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$parent = [IO.Path]::GetDirectoryName($LibraryRoot)
$stage = Child $parent ('.suite-stage/'+$stamp)
$backup = Child $parent ('.suite-backups/'+$stamp)
$entryBackup = Child $CodexSkillsRoot ('.suite-entry-backups/'+$stamp)
foreach ($p in @($stage,$backup,$entryBackup)) { Assert-RealPath $p }
New-Item -ItemType Directory -Path $stage,$backup,$entryBackup -Force | Out-Null
foreach ($file in $manifest.files) {
    $dest = Child $stage $file.path
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($dest)) -Force | Out-Null
    Copy-Item -LiteralPath (Child $sourceRoot $file.path) -Destination $dest
}
Copy-Item -LiteralPath (Join-Path $sourceRoot 'install-manifest.json') -Destination $stage
Check-Payload $stage
$movedLibrary = $false
$installed = $false
$transactions = [Collections.Generic.List[object]]::new()
try {
    if (Test-Path -LiteralPath $LibraryRoot) {
        Move-Item -LiteralPath $LibraryRoot -Destination (Child $backup 'previous-library')
        $movedLibrary = $true
    }
    Move-Item -LiteralPath $stage -Destination $LibraryRoot
    $installed = $true
    foreach ($spec in $selected) {
        $entry = Child $CodexSkillsRoot $spec.name
        $target = if ($spec.path -eq '.') { $LibraryRoot } else { Child $LibraryRoot $spec.path }
        $tx = [pscustomobject]@{entry=$entry; old=(Child $entryBackup $spec.name); moved=$false; created=$false}
        $transactions.Add($tx)
        $existing = Get-Item -LiteralPath $entry -Force -ErrorAction SilentlyContinue
        $same = $existing -and $existing.LinkType -eq 'Junction' -and @($existing.Target)[0] -eq $target
        if (-not $same) {
            if ($existing) { Move-Item -LiteralPath $entry -Destination $tx.old; $tx.moved=$true }
            New-Item -ItemType Junction -Path $entry -Target $target | Out-Null
            $tx.created=$true
        }
        if (-not (Test-Path -LiteralPath (Join-Path $entry 'SKILL.md') -PathType Leaf)) { throw "Unreadable client entry: $entry" }
    }
    Check-Payload $LibraryRoot
    $record = [pscustomobject]@{status='INSTALLED'; suite=$layout.suite_id; version=$layout.version; installedAt=(Get-Date).ToString('o'); libraryRoot=$LibraryRoot; codexSkillsRoot=$CodexSkillsRoot; skills=@($selected.name); backup=$backup; entryBackup=$entryBackup}
    $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $LibraryRoot '.suite-installation.json') -Encoding UTF8
} catch {
    $failure = $_
    $rollbackErrors = @()
    for ($i=$transactions.Count-1; $i -ge 0; $i--) {
        $tx=$transactions[$i]
        try {
            if ($tx.created) { Move-Item -LiteralPath $tx.entry -Destination (Child $entryBackup ('failed-'+$i)) }
            if ($tx.moved) { Move-Item -LiteralPath $tx.old -Destination $tx.entry }
        } catch { $rollbackErrors += $_.Exception.Message }
    }
    try {
        if ($installed) { Move-Item -LiteralPath $LibraryRoot -Destination (Child $backup 'failed-library') }
        if ($movedLibrary) { Move-Item -LiteralPath (Child $backup 'previous-library') -Destination $LibraryRoot }
    } catch { $rollbackErrors += $_.Exception.Message }
    if ($rollbackErrors.Count) { Write-Warning ('Rollback needs attention. Backups: '+$backup+'; '+$entryBackup+'; '+($rollbackErrors -join '; ')) }
    throw $failure
}
$record | ConvertTo-Json -Depth 5
