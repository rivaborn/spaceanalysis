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
    [string]$Output = $null
)

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

# Validate the root before doing any work.
if (-not (Test-Path -LiteralPath $Root)) {
    Write-Error "Root path not found: $Root"
    exit 1
}

$report = [System.Collections.Generic.List[string]]::new()
$report.Add('# Disk space analysis')
$report.Add('')
$report.Add('Root: `' + $Root + '`')
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

Write-Output ($report -join [System.Environment]::NewLine)
