# analyze-disk.ps1
#
# Review disk space usage on this system and report top consumers.
#
# Efficient methodology:
#   - Enumerate filesystem METADATA only (file names + Length). File contents
#     are never opened, so a full recursive pass is fast.
#   - Each analyzed directory is measured in ONE pass
#     (Get-ChildItem -File -Recurse | Measure-Object Length).
#   - We rank the top consumers and (in later steps) drill into only the
#     largest ones, instead of doing an exhaustive full-tree scan.
#
# Read-only: this script never modifies or deletes anything.

param(
    [string]$Root = 'C:\',
    [int]$Top = 20,
    [string]$Output = $null,
    [int]$Depth = 2,
    [switch]$Help
)

if ($Help) {
    Write-Output @"
analyze-disk.ps1 - review disk space usage on this system and recommend ways to free up space (read-only).

Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File analyze-disk.ps1 [-Root <path>] [-Top <n>] [-Depth <n>] [-Output <file>] [-Help]

Parameters:
  -Root     Path to analyze (default: C:\)
  -Top      Number of top-level consumers to rank and drill into (default: 20)
  -Depth    Drill-down depth into top consumers, in levels (default: 2)
  -Output   Write the markdown report to this file in addition to the console (default: none)
  -Help     Show this help and exit

Report sections:
  System summary      host, PowerShell version, run date, drive free space
  Top space consumers direct child directories of Root, ranked by recursive size
  Drill-down          up to -Depth levels into the top consumers (bounded walk)
  Cleanup candidates  well-known Windows waste locations with sizes and safe cleanup hints

Methodology: metadata-only enumeration (file names + Length, file contents are
never read); each analyzed directory is measured in ONE pass; only the largest
branches are expanded, so runtime stays bounded instead of exhaustively
scanning every directory.

Safety: the script is strictly read-only. It reports and suggests; it never
modifies or deletes anything.
"@
    exit 0
}

function Get-DirSize {
    <#
    .SYNOPSIS
        Returns the recursive total size (bytes) of a directory.

    .DESCRIPTION
        Single-pass, metadata-only enumeration: enumerates every file under
        the directory and sums the Length property. File contents are never
        read. Returns 0 for missing or inaccessible paths.
    #>
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return 0
    }

    $sum = @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return [long]$sum
}

function Format-MB {
    param([long]$Bytes)
    return [math]::Round($Bytes / 1MB, 2)
}

# Bounds the drill-down: at each level, at most this many children are
# measured recursively (full size). The rest are shown with their
# non-recursive (this-level-only) size, so runtime stays bounded.
$MAX_EXPANDED = 10

function Expand-Top {
    <#>
    .SYNOPSIS
        Drills into a directory's child directories, one level per call,
        descending up to $Levels total. Prints each level's children
        sorted by size. Only the largest $MAX_EXPANDED children at each
        level are measured recursively; the rest are sized non-recursively.
    .DESCRIPTION
        Read-only. Returns a list of report lines for this level and all
        deeper levels (recursion happens inside).
    #>
    param(
        [string]$Path,
        [int]$Level,
        [int]$Levels,
        [string]$Indent
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $kids = @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue)
    if ($kids.Count -eq 0) { return $lines }

    # Cheap first pass: this-level-only size per child.
    $entries = @()
    foreach ($k in $kids) {
        $lvl = @(Get-ChildItem -LiteralPath $k.FullName -File -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        $entries += [pscustomobject]@{
            Name  = $k.Name
            Path  = $k.FullName
            Bytes = if ($null -eq $lvl) { 0L } else { [long]$lvl }
            Full  = $false
        }
    }
    $entries = @($entries | Sort-Object -Property Bytes -Descending)

    # Recurse only into the largest children, and only while levels remain.
    $expanded = @($entries | Select-Object -First $MAX_EXPANDED)
    if ($Level -lt $Levels) {
        foreach ($e in $expanded) {
            $e.Full  = $true
            $e.Bytes = Get-DirSize -Path $e.Path
        }
        $entries = @($entries | Sort-Object -Property Bytes -Descending)
    }

    # Emit each child line immediately followed by its own subtree, so the
    # hierarchy stays unambiguous (children of sibling dirs don't mix).
    foreach ($e in $entries) {
        $note = if ($e.Full) { '' } else { ' (this level only)' }
        $lines.Add($Indent + '-' + ' `' + $e.Name + '`: ' + (Format-MB $e.Bytes) + ' MB' + $note)
        if ($e.Full) {
            $sub = Expand-Top -Path $e.Path -Level ($Level + 1) -Levels $Levels -Indent ($Indent + '    ')
            foreach ($dl in $sub) { $lines.Add($dl) }
        }
    }
    return [string[]]$lines
}

function Find-CleanupCandidates {
    <#
    .SYNOPSIS
        Scans well-known Windows waste locations and reports reclaimable sizes
        with suggested cleanup commands.

    .DESCRIPTION
        Read-only. Checks a fixed list of known waste locations. For each,
        reports whether it exists, its size, and a suggested safe cleanup
        command hint. Missing locations are reported as 'not present'.
        The script itself performs NO deletion.
    #>
    param()

    $candidates = [System.Collections.Generic.List[object]]::new()

    $locations = @(
        @{ Path = $env:TEMP; Label = "User TEMP ($($env:TEMP))"; Hint = "Remove-Item -LiteralPath `$env:TEMP\* -Recurse -Force" },
        @{ Path = 'C:\Windows\Temp'; Label = 'Windows Temp'; Hint = "Remove-Item -Path 'C:\Windows\Temp\*' -Recurse -Force" },
        @{ Path = 'C:\$Recycle.Bin'; Label = 'Recycle Bin'; Hint = 'Clear-RecycleBin -DriveLetter C' },
        @{ Path = 'C:\Windows\SoftwareDistribution\Download'; Label = 'Windows Update download cache'; Hint = "Remove-Item -Path 'C:\Windows\SoftwareDistribution\Download\*' -Recurse -Force" },
        @{ Path = 'C:\Windows\Installer'; Label = 'Windows Installer'; Hint = "Run 'cleanmgr' (Disk Cleanup) to reclaim Installer cache" },
        @{ Path = "$env:LOCALAPPDATA\pip\Cache"; Label = 'pip cache'; Hint = "Remove-Item -Path `"$env:LOCALAPPDATA\pip\Cache\*`" -Recurse -Force" },
        @{ Path = "$env:LOCALAPPDATA\npm-cache"; Label = 'npm cache'; Hint = 'npm cache clean --force' },
        @{ Path = "$env:LOCALAPPDATA\NuGet\v3-cache"; Label = 'NuGet cache'; Hint = "Remove-Item -Path `"$env:LOCALAPPDATA\NuGet\v3-cache\*`" -Recurse -Force" }
    )

    foreach ($loc in $locations) {
        if (Test-Path -LiteralPath $loc.Path -PathType Container) {
            $size = Get-DirSize -Path $loc.Path
            $candidates.Add([pscustomobject]@{
                Present = $true
                Label   = $loc.Label
                Path    = $loc.Path
                Bytes   = $size
                Hint    = $loc.Hint
            })
        } else {
            $candidates.Add([pscustomobject]@{
                Present = $false
                Label   = $loc.Label
                Path    = $loc.Path
                Bytes   = 0
                Hint    = $loc.Hint
            })
        }
    }

    return $candidates
}

# Validate the root before doing any work.
if (-not (Test-Path -LiteralPath $Root)) {
    Write-Error "Root path not found: $Root"
    exit 1
}

$report = [System.Collections.Generic.List[string]]::new()
$report.Add('# Disk space analysis')
$report.Add('')

# --- System summary ---
$report.Add('## System summary')
$report.Add('')
$report.Add('| Item | Value |')
$report.Add('| --- | --- |')
$report.Add('| Host | ' + $env:COMPUTERNAME + ' |')
$report.Add('| PowerShell | ' + $PSVersionTable.PSVersion.ToString() + ' |')
$report.Add('| Run date | ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' |')
$report.Add('| Root | `' + $Root + '` |')
$report.Add('| Top N | ' + $Top + ' |')
$report.Add('| Drill depth | ' + $Depth + ' |')
try {
    $driveLetter = ($Root -split ':')[0]
    if ($driveLetter) {
        $disk = @(Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${driveLetter}:'" -ErrorAction SilentlyContinue)[0]
        if ($disk -and $disk.Size) {
            $totalGB = [math]::Round($disk.Size / 1GB, 1)
            $usedGB  = [math]::Round(($disk.Size - $disk.FreeSpace) / 1GB, 1)
            $freeGB  = [math]::Round($disk.FreeSpace / 1GB, 1)
            $pct     = [math]::Round(100 * ($disk.Size - $disk.FreeSpace) / $disk.Size, 1)
            $report.Add('| Drive ' + $driveLetter + ': | ' + $totalGB + ' GB total, ' + $usedGB + ' GB used (' + $pct + '%), ' + $freeGB + ' GB free |')
        }
    }
} catch {}
$report.Add('')
$report.Add('> Read-only: this script only reports and suggests; it never modifies or deletes anything.')
$report.Add('')

# --- Ranked top space consumers (direct child directories of $Root) ---
$report.Add('## Top space consumers under `' + $Root + '`')
$report.Add('')
$report.Add('| Directory | Size (MB) |')
$report.Add('| --- | ---: |')

# One size measurement per top-level child; the grand total is derived from
# these same measurements plus top-level loose files, so the tree is walked
# exactly once in total.
$children = @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue)
$ranked = @()
foreach ($child in $children) {
    $ranked += [pscustomobject]@{
        Name  = $child.Name
        Path  = $child.FullName
        Bytes = Get-DirSize -Path $child.FullName
    }
}
if ($ranked.Count -gt 0) {
    $ranked = $ranked | Sort-Object -Property Bytes -Descending
}

$topN = @($ranked | Select-Object -First $Top)
foreach ($item in $topN) {
    $line = '| `' + $item.Name + '` | ' + (Format-MB $item.Bytes) + ' |'
    $report.Add($line)
}

# --- Drill-down into the top consumers (bounded: -Depth levels, $MAX_EXPANDED branches/level) ---
if ($Depth -ge 1 -and $topN.Count -gt 0) {
    $report.Add('')
    $report.Add('## Drill-down (top consumers, up to ' + $Depth + ' levels)')
    $report.Add('')
    foreach ($item in $topN) {
        $report.Add('### `' + $item.Name + '`' + ' — ' + (Format-MB $item.Bytes) + ' MB')
        $drill = Expand-Top -Path $item.Path -Level 1 -Levels $Depth -Indent ''
        if ($drill.Count -eq 0) {
            $report.Add('- (no subdirectories)')
        } else {
            foreach ($dl in $drill) { $report.Add($dl) }
        }
        $report.Add('')
    }
}

# --- Cleanup candidates (well-known Windows waste locations) ---
$report.Add('')
$report.Add('## Cleanup candidates')
$report.Add('')
$report.Add('> This script is read-only and performs NO deletion. The hints below are suggestions only.')
$report.Add('')

$candidates = Find-CleanupCandidates
foreach ($c in $candidates) {
    if ($c.Present) {
        $report.Add('- **' + $c.Label + '**: ' + (Format-MB $c.Bytes) + ' MB')
        $report.Add('  Suggested cleanup: `' + $c.Hint + '`')
    } else {
        $report.Add('- **' + $c.Label + '**: not present')
    }
}
$report.Add('')

# Grand total = all child directories + files directly in the root.
$allChildrenBytes = 0L
foreach ($item in $ranked) {
    $allChildrenBytes += [long]$item.Bytes
}
$rootFilesSum = @(Get-ChildItem -LiteralPath $Root -File -Force -ErrorAction SilentlyContinue |
    Measure-Object -Property Length -Sum).Sum
$rootFilesBytes = if ($null -eq $rootFilesSum) { 0L } else { [long]$rootFilesSum }
$grandTotalBytes = $allChildrenBytes + $rootFilesBytes

$report.Add('')
$report.Add('Total under `' + $Root + '`: ' + (Format-MB $grandTotalBytes) + ' MB (' + $grandTotalBytes + ' bytes)')

# --- Emit report: console, and to -Output file when given ---
$text = $report -join [System.Environment]::NewLine
if ($Output) {
    Set-Content -LiteralPath $Output -Value $text -Encoding utf8
    Write-Host "Report written to $Output"
}
Write-Output $text
