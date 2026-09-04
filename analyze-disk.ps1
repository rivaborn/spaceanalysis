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
    [switch]$Help,
    [string]$Settings = $null,
    [string]$StatusFile = 'status.json',
    [string]$ControlFile = 'control.json',
    [switch]$Telemetry,
    [string]$JsonReport = $null
)

if ($Help) {
    Write-Output @"
analyze-disk.ps1 - review disk space usage on this system and recommend ways to free up space (read-only).

Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File analyze-disk.ps1 [-Root <path>] [-Top <n>] [-Depth <n>] [-Output <file>] [-Help]

Parameters:
  -Root         Path to analyze (default: C:\)
  -Top          Number of top-level consumers to rank and drill into (default: 20)
  -Depth        Drill-down depth into top consumers, in levels (default: 2)
  -Output       Write the markdown report to this file in addition to the console (default: none)
  -Settings     Path to a JSON run-config file written by another process; CLI params take precedence (default: none)
  -StatusFile   Path to the telemetry status JSON (default: status.json). Written only when -Telemetry is set.
  -ControlFile  Path to the control JSON an external process writes to issue stop/pause/resume + overrides (default: control.json). Read only when -Telemetry is set.
  -Telemetry    Enable live telemetry (status file) and control-file polling. When off, the script runs the same fast path as before.
  -JsonReport   Path to write a machine-readable JSON run result (summary, topConsumers, cleanupCandidates, grandTotalMB, stopped). (default: none)
  -Help         Show this help and exit

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
        Two paths:
        - Fast (default): single-pass Get-ChildItem -Recurse | Measure-Object.
        - Trackable (-Track): walks files via EnumerateFiles in a foreach loop,
          updating telemetry status every 5000 files and honoring the control
          file every 20000 files. Returns bytes counted so far if stop is
          requested. Still metadata-only; file contents are never read.
    #>
    param(
        [string]$Path,
        [switch]$Track,
        [string]$Label = ''
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return 0
    }

    # Fast path: metadata-only single pass, no telemetry (behavior/speed unchanged).
    if (-not $Track) {
        $sum = @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { return 0 }
        return [long]$sum
    }

    # Trackable path: per-file walk with periodic telemetry + control checks.
    $bytesSoFar   = [long]0
    $filesCounted = [long]0
    $statusEvery  = 5000
    $controlEvery = 20000

    try {
        foreach ($file in [System.IO.Directory]::EnumerateFiles($Path, '*', [System.IO.SearchOption]::AllDirectories)) {
            if ($Script:StopRequested) { break }
            try {
                $bytesSoFar += [long]([System.IO.FileInfo]::new($file)).Length
            } catch {}
            $filesCounted++
            if ($filesCounted % $statusEvery -eq 0) {
                Write-Status -Phase 'measuring' -Current $Label -Bytes $bytesSoFar -Files $filesCounted `
                    -Message ("Measuring {0} : {1} files, {2} bytes" -f $Label, $filesCounted, $bytesSoFar)
            }
            if ($filesCounted % $controlEvery -eq 0) {
                Read-Control
            }
        }
    } catch {
        # Enumeration error (e.g. an inaccessible subtree): keep the count so far.
    }

    $Script:FilesCounted += $filesCounted
    $Script:BytesCounted  += $bytesSoFar
    return $bytesSoFar
}

function Format-MB {
    param([long]$Bytes)
    return [math]::Round($Bytes / 1MB, 2)
}

# ============================================================
# Telemetry / control plumbing (active only with -Telemetry)
# ============================================================

function Load-Settings {
    <#
    .SYNOPSIS
        Loads a run-config JSON file written by another process.

    .DESCRIPTION
        Returns a PSCustomObject if the file exists and parses, else $null.
        Recognized keys: root, top, depth, output (jsonReport is handled
        by a later feature).
    #>
    param([string]$SettingsPath)

    if (-not $SettingsPath) { return $null }
    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $SettingsPath).Path)
        return ($raw | ConvertFrom-Json)
    } catch {
        Write-Warning "Could not parse settings file '$SettingsPath': $($_.Exception.Message)"
        return $null
    }
}

function Write-Status {
    <#
    .SYNOPSIS
        Atomically writes the current run status as JSON to the status file.

    .DESCRIPTION
        Writes to a .tmp file, then Move-Item over the status file, so a
        polling process always reads a complete, valid document.
        No-op unless -Telemetry.
    #>
    param(
        [string]$Phase,
        [string]$Current = '',
        [int]$ItemsDone = 0,
        [int]$ItemsTotal = 0,
        [long]$Bytes = 0,
        [long]$Files = 0,
        [string]$Message = ''
    )

    if (-not $Script:TelemetryOn -or -not $Script:StatusFile) { return }
    try {
        $elapsed = [math]::Round(([DateTime]::Now - $Script:StartTime).TotalSeconds, 1)
        $data = [ordered]@{
            pid            = [int]$PID
            startTime      = $Script:StartTime.ToString('o')
            timestamp      = [DateTime]::Now.ToString('o')
            phase          = $Phase
            current        = $Current
            itemsDone      = $ItemsDone
            itemsTotal     = $ItemsTotal
            bytesCounted   = $Bytes
            filesCounted   = $Files
            elapsedSeconds = $elapsed
            message        = $Message
        }
        $tmp = "$($Script:StatusFile).tmp"
        $json = $data | ConvertTo-Json -Depth 5
        # UTF-8 without BOM: a BOM breaks JSON parsers on the polling side.
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $Script:StatusFile -Force
    } catch {
        Write-Warning "Telemetry write failed: $($_.Exception.Message)"
    }
}

function Read-Once-Control {
    <#
    .SYNOPSIS
        Reads the control file once; updates stop/pause flags and overrides.

    .DESCRIPTION
        Non-blocking. Returns $true if a control file was read. No-op unless
        -Telemetry; never errors when the file is missing.
    #>
    if (-not $Script:TelemetryOn -or -not $Script:ControlFile) { return $false }
    if (-not (Test-Path -LiteralPath $Script:ControlFile -PathType Leaf)) { return $false }
    try {
        $ctl = (Get-Content -LiteralPath $Script:ControlFile -Raw -ErrorAction Stop | ConvertFrom-Json)
    } catch { return $false }
    if ($null -eq $ctl) { return $false }

    switch ([string]$ctl.action) {
        'stop'   { $Script:StopRequested   = $true }
        'pause'  { $Script:PauseRequested  = $true }
        'resume' { $Script:PauseRequested  = $false }
    }
    if ($ctl.PSObject.Properties['depth']) { $Script:OverrideDepth = [int]$ctl.depth }
    if ($ctl.PSObject.Properties['top'])   { $Script:OverrideTop   = [int]$ctl.top }
    return $true
}

function Wait-WhilePaused {
    <#
    .SYNOPSIS
        Blocks until the control file says resume or stop (or pause clears).
    #>
    if (-not $Script:PauseRequested -or $Script:StopRequested) { return }
    Write-Status -Phase 'paused' -Message 'Paused by control file; waiting for resume or stop.'
    while ($Script:PauseRequested -and -not $Script:StopRequested) {
        Start-Sleep -Seconds 1
        [void](Read-Once-Control)
    }
}

function Read-Control {
    <#
    .SYNOPSIS
        Checkpoint hook: read the control file, then honor pause (blocking) / stop.
    #>
    [void](Read-Once-Control)
    Wait-WhilePaused
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
            $e.Bytes = Get-DirSize -Path $e.Path -Track:$Script:TelemetryOn -Label $e.Name
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

# --- Load settings file (another process can pre-configure the run) ---
$cfg = $null
if ($Settings -and (Test-Path -LiteralPath $Settings -PathType Leaf)) {
    try {
        $raw = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Settings).Path)
        $cfg = $raw | ConvertFrom-Json
    } catch {
        Write-Warning "Could not parse settings file '$Settings': $($_.Exception.Message)"
    }
}
if ($cfg) {
    if (-not $PSBoundParameters.ContainsKey('Root')   -and $null -ne $cfg.root   -and $cfg.root   -ne '') { $Root   = [string]$cfg.root }
    if (-not $PSBoundParameters.ContainsKey('Top')    -and $null -ne $cfg.top)                                { $Top    = [int]$cfg.top }
    if (-not $PSBoundParameters.ContainsKey('Depth')  -and $null -ne $cfg.depth)                               { $Depth  = [int]$cfg.depth }
    if (-not $PSBoundParameters.ContainsKey('Output') -and $null -ne $cfg.output -and $cfg.output -ne '') { $Output = [string]$cfg.output }
}

# --- Telemetry / control runtime state (script scope) ---
$Script:TelemetryOn     = [bool]$Telemetry
$Script:StatusFile      = $StatusFile
$Script:ControlFile     = $ControlFile
$Script:StartTime       = [DateTime]::Now
$Script:StopRequested   = $false
$Script:PauseRequested  = $false
$Script:FilesCounted    = [long]0
$Script:BytesCounted    = [long]0
$Script:OverrideTop     = $null
$Script:OverrideDepth   = $null

# Validate the root before doing any work.
if (-not (Test-Path -LiteralPath $Root)) {
    Write-Error "Root path not found: $Root"
    exit 1
}

# --- Start heartbeat (telemetry) ---
Write-Status -Phase 'start' -Message ('Disk analysis starting under `' + $Root + '`')

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
$totalDirs = $children.Count
Write-Status -Phase 'top-scan-start' -ItemsTotal $totalDirs -Message ('Scanning ' + $totalDirs + ' top-level directory(ies) under `' + $Root + '`')
$ranked = @()
$done = 0
foreach ($child in $children) {
    if ($Script:StopRequested) { break }
    $done++
    Write-Status -Phase 'top-scan' -Current $child.Name -ItemsDone $done -ItemsTotal $totalDirs -Message ('Measuring `' + $child.Name + '`')
    $ranked += [pscustomobject]@{
        Name  = $child.Name
        Path  = $child.FullName
        Bytes = Get-DirSize -Path $child.FullName -Track:$Script:TelemetryOn -Label $child.Name
    }
    # Checkpoint at each directory boundary: honor stop / pause / overrides.
    Read-Control
}
Write-Status -Phase 'top-scan-done' -ItemsDone $done -ItemsTotal $totalDirs -Message "Top-level scan complete ($done/$totalDirs measured)"
Read-Control

# If stop was requested mid-scan, write a terminal status and exit early.
if ($Script:StopRequested) {
    Write-Status -Phase 'stopped' -ItemsDone $done -ItemsTotal $totalDirs -Files $Script:FilesCounted -Bytes $Script:BytesCounted -Message 'stopped by control file'
    Write-Output 'Stopped by control file; report not generated.'
    exit 0
}

if ($ranked.Count -gt 0) {
    $ranked = $ranked | Sort-Object -Property Bytes -Descending
}

# Honor any control-file override of the top-N before selecting.
$effectiveTop = if ($Script:OverrideTop -and $Script:OverrideTop -gt 0) { $Script:OverrideTop } else { $Top }
$topN = @($ranked | Select-Object -First $effectiveTop)
foreach ($item in $topN) {
    $line = '| `' + $item.Name + '` | ' + (Format-MB $item.Bytes) + ' |'
    $report.Add($line)
}

# --- Drill-down into the top consumers (bounded: effective depth, $MAX_EXPANDED branches/level) ---
$effectiveDepth = if ($Script:OverrideDepth -ne $null -and $Script:OverrideDepth -ge 0) { $Script:OverrideDepth } else { $Depth }
if ($effectiveDepth -ge 1 -and $topN.Count -gt 0) {
    $report.Add('')
    $report.Add('## Drill-down (top consumers, up to ' + $effectiveDepth + ' levels)')
    $report.Add('')
    foreach ($item in $topN) {
        $report.Add('### `' + $item.Name + '`' + ' — ' + (Format-MB $item.Bytes) + ' MB')
        $drill = Expand-Top -Path $item.Path -Level 1 -Levels $effectiveDepth -Indent ''
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
    [System.IO.File]::WriteAllText($Output, $text, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Report written to $Output"
}

# --- Terminal heartbeat (telemetry) ---
Write-Status -Phase 'done' -ItemsDone $done -ItemsTotal $totalDirs -Files $Script:FilesCounted -Bytes $Script:BytesCounted -Message 'Report generated.'
Write-Output $text

# --- Machine-readable JSON report (-JsonReport) ---
if ($JsonReport) {
    $jsonReportData = [ordered]@{
        summary = [ordered]@{
            topN   = $effectiveTop
            root   = $Root
            host   = $env:COMPUTERNAME
            date   = [DateTime]::Now.ToString('o')
        }
        topConsumers = @($topN | ForEach-Object { [ordered]@{
            name   = $_.Name
            sizeMB = [math]::Round([long]$_.Bytes / 1MB, 2)
        } })
        cleanupCandidates = @($candidates | ForEach-Object { [ordered]@{
            label   = $_.Label
            mb      = [math]::Round([long]$_.Bytes / 1MB, 2)
            present = [bool]$_.Present
        } })
        grandTotalMB = [math]::Round([long]$grandTotalBytes / 1MB, 2)
        stopped      = [bool]$Script:StopRequested
    }
    $jsonStr = $jsonReportData | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($JsonReport, $jsonStr, [System.Text.UTF8Encoding]::new($false))
    Write-Host "JSON report written to $JsonReport"
}
