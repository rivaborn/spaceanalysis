# analyze-disk.ps1
#
# Review disk space usage on this system and report top consumers.
#
# Efficient methodology:
#   - Enumerate filesystem METADATA only (file names + Length). File contents
#     are never opened, so a full recursive pass is fast.
#   - Each analyzed directory is measured in ONE pass over a .NET
#     DirectoryInfo.EnumerateFileSystemInfos iterator (no per-object PowerShell
#     pipeline), skipping directory reparse points (junctions / symlinks).
#   - We rank the top consumers and (in later steps) drill into only the
#     largest ones, instead of doing an exhaustive full-tree scan.
#   - Physical (allocated) size is reported alongside logical size via
#     GetCompressedFileSizeW, matching WinDirStat's logical-vs-physical
#     distinction — physical size is what actually frees space.
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
    [string]$JsonReport = $null,
    [switch]$Parallel
)

if ($Help) {
    Write-Output @"
analyze-disk.ps1 - review disk space usage on this system and recommend ways to free up space (read-only).

Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File analyze-disk.ps1 [-Root <path>] [-Top <n>] [-Depth <n>] [-Output <file>] [-Parallel] [-Telemetry] [-Help]

Parameters:
  -Root         Path to analyze (default: C:\)
  -Top          Number of top-level consumers to rank and drill into (default: 20)
  -Depth        Drill-down depth into top consumers, in levels (default: 2)
  -Output       Write the markdown report to this file in addition to the console (default: none)
  -Settings     Path to a JSON run-config file written by another process; CLI params take precedence (default: none)
  -StatusFile   Path to the telemetry status JSON (default: status.json). Written only when -Telemetry is set.
  -ControlFile  Path to the control JSON an external process writes to issue stop/pause/resume + overrides (default: control.json). Read only when -Telemetry is set.
  -Telemetry    Enable live telemetry (status file) and control-file polling. When off, the script runs the same fast path as before.
  -JsonReport   Path to write a machine-readable JSON run result (summary, topConsumers, cleanupCandidates, grandTotalMB, grandTotalAllocMB, stopped). (default: none)
  -Parallel     Scan top-level branches concurrently via an in-process runspace pool ([System.Management.Automation.Runspaces]). WinDirStat-style multithreading. Default is serial.
  -Help         Show this help and exit

Report sections:
  System summary        host, PowerShell version, run date, drive free space
  Top space consumers   direct child directories of Root, ranked by recursive size (logical and physical/allocated)
  Drill-down            up to -Depth levels into the top consumers (bounded in-memory walk, at most 10 branches/level)
  Cleanup candidates    well-known Windows waste locations with sizes and safe cleanup hints

Methodology (WinDirStat-inspired, single-pass):
  - Metadata-only enumeration via .NET DirectoryInfo.EnumerateFileSystemInfos
    (no per-object PowerShell pipeline). File contents are never read.
  - Each directory is measured in ONE pass; the resulting in-memory tree is
    reused for ranking, drill-down, and grand total (no re-scans).
  - Directory reparse points (junctions / symlinks) are skipped, matching
    WinDirStat's default, to prevent loops and double-counting.
  - Both logical size (file Length) and physical/allocated size
    (GetCompressedFileSizeW) are reported; physical size is what actually
    frees space, which matters for sparse or NTFS-compressed files.
  - With -Parallel, top-level branches are walked concurrently in an in-process
    runspace pool; the merged result is identical to the serial scan.

Safety: the script is strictly read-only. It reports and suggests; it never
modifies or deletes anything.
"@
    exit 0
}

# ============================================================
# P/Invoke for physical (allocated / on-disk) file size
# ============================================================

$Win32_FileSize = $null
try {
    $Win32_FileSize = Add-Type -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern uint GetCompressedFileSizeW(string lpFileName, out uint pFileSizeHigh);
'@ -Namespace Win32 -Name FileSizeApi -ErrorAction Stop -PassThru
} catch {
    # Add-Type failed (e.g. no C# compiler); fall back gracefully.
    $Win32_FileSize = $null
}

function Get-PhysicalSize {
    <#
    .SYNOPSIS
        Returns the on-disk (physical / allocated / compressed) size of a file in bytes.

    .DESCRIPTION
        Uses kernel32 GetCompressedFileSizeW via P/Invoke. Falls back to the
        logical Length if the call fails or is unavailable. For most normal
        files physical == logical; for sparse or NTFS-compressed files it is
        lower, and for files rounded up to the cluster boundary it may be
        slightly higher.
    #>
    param([string]$Path)

    if ($null -eq $Win32_FileSize) { return -1 }  # P/Invoke unavailable; caller falls back to logical
    try {
        $high = [uint32]0
        $low  = $Win32_FileSize::GetCompressedFileSizeW($Path, [ref]$high)
        if ($high -eq 0) {
            # File < 4 GB: low-order DWORD is the full physical size.
            if ($low -eq 0xFFFFFFFF) { return -1 }  # INVALID_FILE_SIZE
            return [long]$low
        } else {
            return ([long]$high -shl 32) -bor [long]$low
        }
    } catch {
        return -1
    }
}

function Get-DirSize {
    <#
    .SYNOPSIS
        Returns the recursive total size (bytes) of a directory.

    .DESCRIPTION
        Metadata-only, single pass over the whole subtree:
        - Fast (default): enumerates each directory with the .NET
          DirectoryInfo.EnumerateFileSystemInfos iterator (no per-object
          PowerShell pipeline) and sums file Lengths.
        - Trackable (-Track): the same walk also updates telemetry status every
          5000 files and honors the control file every 20000 files, so a stop
          aborts mid-scan (returns bytes counted so far).
        Directory reparse points (junctions / symbolic links) are SKIPPED,
        matching WinDirStat's default, to prevent loops and double-counting.
        File contents are never opened.
    #>
    param(
        [string]$Path,
        [switch]$Track,
        [string]$Label = ''
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return 0
    }

    # Working accumulators for this single walk, reset per Get-DirSize call so
    # the global Script: totals are added exactly once (never per level).
    $Script:WalkBytes       = [long]0
    $Script:WalkAllocBytes  = [long]0
    $Script:WalkFiles       = [long]0

    [void](Get-DirSizeWalk -Path $Path -Track:$Track -Label $Label)

    $bytes = [long]$Script:WalkBytes
    $files = [long]$Script:WalkFiles

    if ($Track) {
        $Script:FilesCounted  += $files
        $Script:BytesCounted  += $bytes
    }
    return $bytes
}

function Get-DirSizeWalk {
    <#
    .SYNOPSIS
        Recursive, metadata-only size walk over one directory level at a time.

    .DESCRIPTION
        Enumerates a single directory with the .NET
        DirectoryInfo.EnumerateFileSystemInfos iterator (no per-object PowerShell
        pipeline). Files add their Length to $Script:WalkBytes. Subdirectories are
        recursed into once each, EXCEPT directory reparse points (junctions /
        symlinks), which are skipped entirely (WinDirStat default) to avoid loops
        and double-counting. When -Track is set, telemetry (Write-Status) and
        control (Read-Control) checkpoints run periodically and the walk stops
        early once StopRequested is set.
    #>
    param(
        [string]$Path,
        [switch]$Track,
        [string]$Label = ''
    )

    $statusEvery  = 5000
    $controlEvery = 20000
    $reparseFlag  = [int][System.IO.FileAttributes]::ReparsePoint

    try {
        foreach ($e in [System.IO.DirectoryInfo]::new($Path).EnumerateFileSystemInfos('*', [System.IO.SearchOption]::TopDirectoryOnly)) {
            if ($Track -and $Script:StopRequested) { break }

            if ($e -is [System.IO.FileInfo]) {
                $len = 0L
                try { $len = [long]$e.Length } catch {}
                $Script:WalkBytes += $len
                # Physical (allocated) size via GetCompressedFileSizeW.
                $phys = Get-PhysicalSize -Path $e.FullName
                if ($phys -lt 0) { $phys = $len }  # fallback to logical
                $Script:WalkAllocBytes += $phys
                if ($Track) {
                    $Script:WalkFiles++
                    if ($Script:WalkFiles % $statusEvery -eq 0) {
                        Write-Status -Phase 'measuring' -Current $Label -Bytes $Script:WalkBytes -Files $Script:WalkFiles `
                            -Message ("Measuring {0} : {1} files, {2} bytes" -f $Label, $Script:WalkFiles, $Script:WalkBytes)
                    }
                    if ($Script:WalkFiles % $controlEvery -eq 0) {
                        Read-Control
                    }
                }
            } else {
                # Directory: recurse only if it is NOT a reparse point.
                if (-not ([int]$e.Attributes -band $reparseFlag)) {
                    [void](Get-DirSizeWalk -Path $e.FullName -Track:$Track -Label $Label)
                }
            }
        }
    } catch {
        # Enumeration error (e.g. an inaccessible subtree): keep the count so far.
    }
}

function Get-SizeTreeNode {
    <#
    .SYNOPSIS
        Recursively builds an in-memory size-tree node for a directory.

    .DESCRIPTION
        Enumerates a single directory level with the .NET
        DirectoryInfo.EnumerateFileSystemInfos iterator. Files are summed into
        OwnBytes; subdirectories are recursed into (skipping reparse points).
        Returns a PSCustomObject with Name, Path, OwnBytes, TotalBytes,
        FileCount, and Children (sorted by TotalBytes descending).
        When -Track is set, telemetry (Write-Status) and control (Read-Control)
        checkpoints run periodically; the walk stops early once StopRequested.
    #>
    param(
        [string]$Path,
        [switch]$Track,
        [string]$Label = ''
    )

    $reparseFlag  = [int][System.IO.FileAttributes]::ReparsePoint
    $ownBytes     = [long]0
    $ownAllocBytes = [long]0
    $fileCount    = [long]0
    $childNodes   = [System.Collections.Generic.List[object]]::new()

    try {
        foreach ($e in [System.IO.DirectoryInfo]::new($Path).EnumerateFileSystemInfos('*', [System.IO.SearchOption]::TopDirectoryOnly)) {
            if ($Track -and $Script:StopRequested) { break }

            if ($e -is [System.IO.FileInfo]) {
                $len = 0L
                try { $len = [long]$e.Length } catch {}
                $ownBytes += $len
                # Physical (allocated) size via GetCompressedFileSizeW.
                $phys = Get-PhysicalSize -Path $e.FullName
                if ($phys -lt 0) { $phys = $len }
                $ownAllocBytes += $phys
                $fileCount++
                if ($Track) {
                    $Script:WalkFiles++
                    $Script:WalkBytes += $len
                    if ($Script:WalkFiles % 5000 -eq 0) {
                        Write-Status -Phase 'measuring' -Current $Label -Bytes $Script:WalkBytes -Files $Script:WalkFiles `
                            -Message ("Measuring {0} : {1} files, {2} bytes" -f $Label, $Script:WalkFiles, $Script:WalkBytes)
                    }
                    if ($Script:WalkFiles % 20000 -eq 0) {
                        Read-Control
                    }
                }
            } else {
                # Directory: recurse only if NOT a reparse point.
                if (-not ([int]$e.Attributes -band $reparseFlag)) {
                    $child = Get-SizeTreeNode -Path $e.FullName -Track:$Track -Label $e.Name
                    $childNodes.Add($child)
                }
            }
        }
    } catch {
        # Enumeration error: keep what we have so far.
    }

    # Sort children by TotalBytes descending (most significant first).
    $children = @($childNodes | Sort-Object -Property TotalBytes -Descending)

    $totalBytes     = $ownBytes
    $totalAllocBytes = $ownAllocBytes
    foreach ($c in $children) {
        $totalBytes      += [long]$c.TotalBytes
        $totalAllocBytes += [long]$c.TotalAllocBytes
    }

    $name = [System.IO.Path]::GetFileName($Path)
    if ($name -eq '') { $name = $Path }

    return [pscustomobject]@{
        Name          = $name
        Path          = $Path
        OwnBytes      = $ownBytes
        TotalBytes    = $totalBytes
        OwnAllocBytes = $ownAllocBytes
        TotalAllocBytes = $totalAllocBytes
        FileCount     = $fileCount
        Children      = $children
    }
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
# expanded recursively. The rest are shown with their OwnBytes
# (this-level-only size), so output stays bounded.
$MAX_EXPANDED = 10

function Expand-Tree {
    <#
    .SYNOPSIS
        In-memory drill-down over a size-tree node's children.

    .DESCRIPTION
        Traverses the in-memory tree (no disk I/O). At each level, the top
        $MAX_EXPANDED children (by TotalBytes) are expanded; the rest show
        only their OwnBytes (this-level-only). Returns report lines for this
        level and deeper levels.
    #>
    param(
        $Node,
        [int]$Level,
        [int]$Levels,
        [string]$Indent
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $kids = @($Node.Children)
    if ($kids.Count -eq 0) { return $lines }

    # Determine which children to expand (top MAX_EXPANDED, if levels remain).
    $expandedSet = @{}
    if ($Level -lt $Levels) {
        $expanded = @($kids | Select-Object -First $MAX_EXPANDED)
        foreach ($e in $expanded) { $expandedSet[$e.Path] = $true }
    }

    foreach ($e in $kids) {
        $isFull = $expandedSet.ContainsKey($e.Path)
        $note = if ($isFull) { '' } else { ' (this level only)' }
        # Expanded: show TotalBytes (full recursive). Non-expanded: show OwnBytes (this level only).
        $displayBytes    = if ($isFull) { [long]$e.TotalBytes }      else { [long]$e.OwnBytes }
        $displayAlloc    = if ($isFull) { [long]$e.TotalAllocBytes } else { [long]$e.OwnAllocBytes }
        $lines.Add($Indent + '- `' + $e.Name + '`: ' + (Format-MB $displayBytes) + ' MB / ' + (Format-MB $displayAlloc) + ' MB alloc' + $note)
        if ($isFull) {
            $sub = Expand-Tree -Node $e -Level ($Level + 1) -Levels $Levels -Indent ($Indent + '    ')
            foreach ($dl in $sub) { $lines.Add($dl) }
        }
    }
    return [string[]]$lines
}

function Invoke-ParallelBranches {
    <#
    .SYNOPSIS
        Scans multiple top-level directories concurrently using an in-process runspace pool.

    .DESCRIPTION
        Mirrors WinDirStat's multithreading: each top-level branch is walked in a
        separate in-process runspace via [System.Management.Automation.Runspaces].
        Results are merged back into a single ordered array of tree nodes.
        The P/Invoke type is shared across runspaces (same AppDomain), so no
        re-compilation is needed in the workers.
    #>
    param([string[]]$Paths)

    if ($Paths.Count -le 1) {
        $nodes = @()
        foreach ($p in $Paths) {
            $nodes += (Get-SizeTreeNode -Path $p)
        }
        return $nodes
    }

    # Extract function source to embed in the worker script.
    # In PS 5.1, (Get-Command fn).Definition returns the body without the 'function Name {' wrapper.
    $physFn = (Get-Command Get-PhysicalSize).Definition
    $treeFn = (Get-Command Get-SizeTreeNode).Definition

    # Build a self-contained worker script.
    # [Win32.FileSizeApi] is already loaded in this process (shared AppDomain),
    # so workers reference it directly without re-adding the P/Invoke type.
    $scriptLines = @(
        'param([string]$BranchPath)',
        '$Win32_FileSize = [Win32.FileSizeApi]',
        'function Get-PhysicalSize {',
        $physFn,
        '}',
        'function Get-SizeTreeNode {',
        $treeFn,
        '}',
        'Get-SizeTreeNode -Path $BranchPath'
    )
    $workerScript = [string]::Join("`n", $scriptLines)

    # Create an in-process runspace pool.
    # PS 5.1: use the 2-arg overload CreateRunspacePool(int,int) — the 3-arg form
    # expects a PSHost, not ApartmentState, and is ambiguous in this build.
    $maxConcurrent = [Math]::Min([Environment]::ProcessorCount, 8)
    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $maxConcurrent)
    $runspacePool.Open()

    $nodes = [object[]]::new($Paths.Count)
    $psInstances = @()

    try {
        # Submit all branch scans to the pool (concurrency limited by pool size).
        for ($i = 0; $i -lt $Paths.Count; $i++) {
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $runspacePool
            [void]$ps.AddScript($workerScript)
            [void]$ps.AddArgument($Paths[$i])
            $ar = $ps.BeginInvoke()
            $psInstances += ,@($i, $ps, $ar)
        }

        # Collect results in original order.
        foreach ($entry in $psInstances) {
            $idx = $entry[0]
            $ps  = $entry[1]
            $ar  = $entry[2]
            try {
                $result = @($ps.EndInvoke($ar))
                foreach ($err in $ps.Streams.Error) { Write-Warning "Parallel scan of $($Paths[$idx]): $err" }
                if ($result.Count -gt 0 -and $null -ne $result[0]) {
                    $nodes[$idx] = $result[0]
                } else {
                    Write-Warning "Parallel scan of $($Paths[$idx]) returned no result."
                    $nodes[$idx] = [pscustomobject]@{
                        Name = [System.IO.Path]::GetFileName($Paths[$idx])
                        Path = $Paths[$idx]
                        OwnBytes = 0L; TotalBytes = 0L
                        OwnAllocBytes = 0L; TotalAllocBytes = 0L
                        FileCount = 0L; Children = @()
                    }
                }
            } catch {
                Write-Warning "Parallel scan of $($Paths[$idx]) failed: $_"
                $nodes[$idx] = [pscustomobject]@{
                    Name = [System.IO.Path]::GetFileName($Paths[$idx])
                    Path = $Paths[$idx]
                    OwnBytes = 0L; TotalBytes = 0L
                    OwnAllocBytes = 0L; TotalAllocBytes = 0L
                    FileCount = 0L; Children = @()
                }
            }
            $ps.Dispose()
        }
    }
    finally {
        $runspacePool.Close()
        $runspacePool.Dispose()
    }

    return @($nodes)
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
$report.Add('| Directory | Logical (MB) | Physical (MB) |')
$report.Add('| --- | ---: | ---: |')

# Single-pass tree build: each top-level directory is walked ONCE by
# Get-SizeTreeNode (no re-scanning for drill-down). The in-memory tree is
# reused for ranking, drill-down, and grand total.
$reparseFlag = [int][System.IO.FileAttributes]::ReparsePoint
$rootDirs = @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue | Where-Object { -not ([int]$_.Attributes -band $reparseFlag) })
$totalDirs = $rootDirs.Count
Write-Status -Phase 'top-scan-start' -ItemsTotal $totalDirs -Message ('Scanning ' + $totalDirs + ' top-level directory(ies) under `' + $Root + '`')

# Initialize telemetry accumulators for the tree walk.
$Script:WalkBytes = [long]0
$Script:WalkFiles = [long]0

if ($Parallel -and $rootDirs.Count -gt 1) {
    # --- Parallel path: scan branches concurrently via an in-process runspace pool ---
    $branchPaths = @($rootDirs | ForEach-Object { $_.FullName })
    $maxJobs = [Environment]::ProcessorCount
    if ($maxJobs -gt 8) { $maxJobs = 8 }
    Write-Host "[parallel] Scanning $totalDirs branches concurrently (max $maxJobs workers)"
    $topNodes = Invoke-ParallelBranches -Paths $branchPaths
    $done = $totalDirs
    # Compute telemetry totals from the returned nodes.
    $Script:WalkBytes = [long]0
    $Script:WalkFiles = [long]0
    foreach ($n in $topNodes) {
        $Script:WalkBytes += [long]$n.TotalBytes
        $Script:WalkFiles += [long]$n.FileCount
    }
} else {
    # --- Serial path (default): walk each top-level branch in order ---
    $topNodes = @()
    $done = 0
    foreach ($child in $rootDirs) {
        if ($Script:StopRequested) { break }
        $done++
        Write-Status -Phase 'top-scan' -Current $child.Name -ItemsDone $done -ItemsTotal $totalDirs -Message ('Measuring `' + $child.Name + '`')
        $node = Get-SizeTreeNode -Path $child.FullName -Track:$Script:TelemetryOn -Label $child.Name
        $topNodes += $node
        # Checkpoint at each directory boundary: honor stop / pause / overrides.
        Read-Control
    }
}
Write-Status -Phase 'top-scan-done' -ItemsDone $done -ItemsTotal $totalDirs -Message "Top-level scan complete ($done/$totalDirs measured)"
Read-Control

# Finalize telemetry totals from the walk.
$Script:FilesCounted = $Script:WalkFiles
$Script:BytesCounted = $Script:WalkBytes

# Rank top-level nodes by TotalBytes descending.
$ranked = @($topNodes | Sort-Object -Property TotalBytes -Descending)

# If stop was requested mid-scan, write a terminal status and exit early.
if ($Script:StopRequested) {
    Write-Status -Phase 'stopped' -ItemsDone $done -ItemsTotal $totalDirs -Files $Script:FilesCounted -Bytes $Script:BytesCounted -Message 'stopped by control file'
    Write-Output 'Stopped by control file; report not generated.'
    exit 0
}

# Honor any control-file override of the top-N before selecting.
$effectiveTop = if ($Script:OverrideTop -and $Script:OverrideTop -gt 0) { $Script:OverrideTop } else { $Top }
$topN = @($ranked | Select-Object -First $effectiveTop)
foreach ($item in $topN) {
    $line = '| `' + $item.Name + '` | ' + (Format-MB $item.TotalBytes) + ' | ' + (Format-MB $item.TotalAllocBytes) + ' |'
    $report.Add($line)
}

# --- Drill-down into the top consumers (bounded: effective depth, $MAX_EXPANDED branches/level) ---
$effectiveDepth = if ($Script:OverrideDepth -ne $null -and $Script:OverrideDepth -ge 0) { $Script:OverrideDepth } else { $Depth }
if ($effectiveDepth -ge 1 -and $topN.Count -gt 0) {
    $report.Add('')
    $report.Add('## Drill-down (top consumers, up to ' + $effectiveDepth + ' levels)')
    $report.Add('')
    foreach ($item in $topN) {
        $report.Add('### `' + $item.Name + '`' + ' — ' + (Format-MB $item.TotalBytes) + ' MB')
        $drill = Expand-Tree -Node $item -Level 1 -Levels $effectiveDepth -Indent ''
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

# Grand total = root's own files + all top-level node totals (from the tree).
$rootOwnBytes     = [long]0
$rootOwnAllocBytes = [long]0
try {
    foreach ($e in [System.IO.DirectoryInfo]::new($Root).EnumerateFileSystemInfos('*', [System.IO.SearchOption]::TopDirectoryOnly)) {
        if ($e -is [System.IO.FileInfo]) {
            $len = 0L
            try { $len = [long]$e.Length } catch {}
            $rootOwnBytes += $len
            $phys = Get-PhysicalSize -Path $e.FullName
            if ($phys -lt 0) { $phys = $len }
            $rootOwnAllocBytes += $phys
        }
    }
} catch {}
$grandTotalBytes = $rootOwnBytes
foreach ($item in $ranked) { $grandTotalBytes += [long]$item.TotalBytes }

$report.Add('')
# Grand total physical (allocated) bytes from tree nodes + root loose files.
$grandTotalAllocBytes = $rootOwnAllocBytes
foreach ($item in $ranked) { $grandTotalAllocBytes += [long]$item.TotalAllocBytes }

$report.Add('Total under `' + $Root + '`: ' + (Format-MB $grandTotalBytes) + ' MB logical / ' + (Format-MB $grandTotalAllocBytes) + ' MB physical (' + $grandTotalBytes + ' bytes)')

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
            name        = $_.Name
            sizeMB      = [math]::Round([long]$_.TotalBytes / 1MB, 2)
            allocMB     = [math]::Round([long]$_.TotalAllocBytes / 1MB, 2)
        } })
        cleanupCandidates = @($candidates | ForEach-Object { [ordered]@{
            label   = $_.Label
            mb      = [math]::Round([long]$_.Bytes / 1MB, 2)
            present = [bool]$_.Present
        } })
        grandTotalMB      = [math]::Round([long]$grandTotalBytes / 1MB, 2)
        grandTotalAllocMB = [math]::Round([long]$grandTotalAllocBytes / 1MB, 2)
        stopped           = [bool]$Script:StopRequested
    }
    $jsonStr = $jsonReportData | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($JsonReport, $jsonStr, [System.Text.UTF8Encoding]::new($false))
    Write-Host "JSON report written to $JsonReport"
}
