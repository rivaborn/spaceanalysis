# analyze-disk.ps1
#
# Review disk space usage on this system and report top consumers.
#
# Efficient methodology:
#   - Enumerate filesystem METADATA only (file names + Length). File contents
#     are never opened, so a full recursive pass is fast.
#   - The recursive walk runs in a compiled .NET scanner ([DiskScan.Scanner],
#     built once at startup via Add-Type). One pass builds the whole size tree,
#     skipping directory reparse points (junctions / symlinks). A PowerShell
#     fallback walk is used if the scanner cannot be compiled.
#   - We rank the top consumers and drill into only the largest ones, instead
#     of doing an exhaustive full-tree scan.
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
    [switch]$Parallel,
    [switch]$Serial,
    [switch]$SkipCleanup
)

if ($Help) {
    Write-Output @"
analyze-disk.ps1 - review disk space usage on this system and recommend ways to free up space (read-only).

Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File analyze-disk.ps1 [-Root <path>] [-Top <n>] [-Depth <n>] [-Output <file>] [-Serial] [-SkipCleanup] [-Telemetry] [-Help]

Parameters:
  -Root         Directory to analyze (default: C:\). Must exist and be a directory.
  -Top          Number of top-level consumers to rank and drill into (default: 20)
  -Depth        Drill-down depth into top consumers, in levels (default: 2)
  -Output       Write the markdown report to this file in addition to the console (default: none)
  -Settings     Path to a JSON run-config file written by another process; CLI params take precedence (default: none)
  -StatusFile   Path to the telemetry status JSON (default: status.json). Written only when -Telemetry is set.
  -ControlFile  Path to the control JSON an external process writes to issue stop/pause/resume + overrides (default: control.json). Read only when -Telemetry is set.
  -Telemetry    Enable live telemetry (status file) and control-file polling. The scan then runs on a background
                thread so stop/pause take effect within ~0.25s instead of at the next checkpoint.
  -JsonReport   Path to write a machine-readable JSON run result (summary, topConsumers, cleanupCandidates, grandTotalMB, grandTotalAllocMB, stopped). (default: none). Written even when the run is stopped early.
  -Serial       Scan one directory at a time instead of the default multithreaded scan. Slower (about 2.5x on
                a whole drive) but minimizes I/O pressure; results are identical either way.
  -Parallel     Explicitly request the multithreaded scan: top-level branches AND the first levels inside each
                branch (one worker per core, capped at 8). This is now the DEFAULT; the switch is kept for
                compatibility. -Parallel:`$false or -Serial opts out.
  -SkipCleanup  Skip the cleanup-candidates scan (user TEMP, package caches, ...). Saves several seconds of
                fixed cost when only the tree under -Root matters. The report section notes the skip.
  -Help         Show this help and exit

Report sections:
  System summary        host, PowerShell version, run date, drive free space
  Top space consumers   direct child directories of Root, ranked by recursive size (logical and physical/allocated)
  Drill-down            up to -Depth levels into the top consumers (bounded in-memory walk, at most 10 branches/level)
  Cleanup candidates    well-known Windows waste locations with sizes and safe cleanup hints

Methodology (WinDirStat-inspired, single-pass):
  - Metadata-only enumeration via .NET DirectoryInfo.EnumerateFileSystemInfos
    inside a compiled scanner. File contents are never read.
  - Each directory is measured in ONE pass; the resulting in-memory tree is
    reused for ranking, drill-down, and grand total (no re-scans). Child lists
    deeper than the drill-down needs are dropped to bound memory; totals are
    still exact.
  - Directory reparse points (junctions / symlinks) are skipped, matching
    WinDirStat's default, to prevent loops and double-counting.
  - Both logical size (file Length) and physical/allocated size
    (GetCompressedFileSizeW) are reported; physical size is what actually
    frees space, which matters for sparse or NTFS-compressed files.
  - By default, top-level branches AND the first levels inside each branch are
    walked concurrently (pass -Serial to opt out); the merged result is
    identical to the serial scan.

Safety: the script is strictly read-only. It reports and suggests; it never
modifies or deletes anything.
"@
    exit 0
}

# ============================================================
# Compiled scanner (fast path)
# ============================================================
#
# The entire recursive walk lives in C# so that the per-file
# GetCompressedFileSizeW call costs a direct P/Invoke instead of a PowerShell
# function call plus marshalling. On a 10k-file tree this is roughly an order
# of magnitude faster than the equivalent PowerShell walk.
#
# Progress is published through interlocked counters that the PowerShell side
# polls while the scan runs on a background task, so telemetry no longer needs
# checkpoints woven through the walk itself.

# Set ANALYZE_DISK_NO_FASTSCAN=1 to force the PowerShell fallback walk. It is
# what runs on a host without a usable C# compiler, so the test suite exercises
# it deliberately rather than waiting for such a host to turn up.
$Script:FastScan = $false
try {
    if ($env:ANALYZE_DISK_NO_FASTSCAN -eq '1') { throw 'disabled by ANALYZE_DISK_NO_FASTSCAN' }
    if (-not ('DiskScan.Scanner' -as [type])) {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace DiskScan
{
    public sealed class Node
    {
        public string Name;
        public string Path;
        public long   OwnBytes;
        public long   TotalBytes;
        public long   OwnAllocBytes;
        public long   TotalAllocBytes;
        public long   FileCount;
        public Node[] Children;
    }

    public static class Scanner
    {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern uint GetCompressedFileSizeW(string lpFileName, out uint lpFileSizeHigh);

        private const uint INVALID_FILE_SIZE = 0xFFFFFFFF;

        private static readonly Node[] NoChildren = new Node[0];

        private static long _filesSeen;
        private static long _bytesSeen;
        private static long _branchesDone;
        private static int  _stop;
        private static int  _paused;

        public static long FilesSeen    { get { return Interlocked.Read(ref _filesSeen); } }
        public static long BytesSeen    { get { return Interlocked.Read(ref _bytesSeen); } }
        public static long BranchesDone { get { return Interlocked.Read(ref _branchesDone); } }

        public static bool Stop
        {
            get { return Volatile.Read(ref _stop) != 0; }
            set { Volatile.Write(ref _stop, value ? 1 : 0); }
        }

        public static bool Paused
        {
            get { return Volatile.Read(ref _paused) != 0; }
            set { Volatile.Write(ref _paused, value ? 1 : 0); }
        }

        // Resets progress counters only. Stop/Paused are owned by the caller
        // (a control file may already say "stop" before the first scan starts).
        public static void ResetCounters()
        {
            Interlocked.Exchange(ref _filesSeen, 0);
            Interlocked.Exchange(ref _bytesSeen, 0);
            Interlocked.Exchange(ref _branchesDone, 0);
        }

        // Physical (on-disk / allocated) size. Falls back to the logical length
        // when the call fails, matching the reference PowerShell behaviour.
        private static long Physical(string fullPath, long logical)
        {
            try
            {
                string p = fullPath;
                // GetCompressedFileSizeW is MAX_PATH-limited without the
                // extended-length prefix; add it for long paths only.
                if (p.Length >= 260 && !p.StartsWith(@"\\?\", StringComparison.Ordinal))
                {
                    p = p.StartsWith(@"\\", StringComparison.Ordinal)
                        ? @"\\?\UNC\" + p.Substring(2)
                        : @"\\?\" + p;
                }
                uint high;
                uint low = GetCompressedFileSizeW(p, out high);
                if (high == 0)
                {
                    if (low == INVALID_FILE_SIZE) { return logical; }
                    return (long)low;
                }
                return ((long)high << 32) | (long)low;
            }
            catch { return logical; }
        }

        private static string LeafName(string path)
        {
            string n = System.IO.Path.GetFileName(path.TrimEnd('\\', '/'));
            return string.IsNullOrEmpty(n) ? path : n;
        }

        // keepChildren:    how many more levels of Children arrays to retain.
        //                  Totals are always exact; only the child lists are
        //                  pruned, which keeps memory bounded on very large trees.
        // parallelLevels:  how many more levels may fan their subdirectories out
        //                  across worker threads. Branch-level parallelism alone
        //                  is nearly useless on a real disk, where one branch
        //                  (Windows) dominates while the other workers idle.
        private static Node Walk(string path, string name, int keepChildren, int parallelLevels, ParallelOptions po)
        {
            long ownBytes = 0, ownAlloc = 0, fileCount = 0;
            List<FileSystemInfo> subs = null;

            try
            {
                DirectoryInfo di = new DirectoryInfo(path);
                foreach (FileSystemInfo e in di.EnumerateFileSystemInfos("*", SearchOption.TopDirectoryOnly))
                {
                    if (Volatile.Read(ref _stop) != 0) { break; }
                    while (Volatile.Read(ref _paused) != 0 && Volatile.Read(ref _stop) == 0)
                    {
                        Thread.Sleep(50);
                    }

                    FileInfo fi = e as FileInfo;
                    if (fi != null)
                    {
                        long len = 0;
                        try { len = fi.Length; } catch { }
                        ownBytes += len;
                        ownAlloc += Physical(fi.FullName, len);
                        fileCount++;
                    }
                    else
                    {
                        // Directory: recurse only if it is NOT a reparse point.
                        if ((e.Attributes & FileAttributes.ReparsePoint) != 0) { continue; }
                        if (subs == null) { subs = new List<FileSystemInfo>(); }
                        subs.Add(e);
                    }
                }
            }
            catch
            {
                // Inaccessible or vanished subtree: keep what we counted so far.
            }

            // Publish progress once per directory (cheap, and fine-grained
            // enough for a live status file).
            if (fileCount != 0) { Interlocked.Add(ref _filesSeen, fileCount); }
            if (ownBytes  != 0) { Interlocked.Add(ref _bytesSeen, ownBytes); }

            // Children are written into a fixed array by discovery index, so the
            // result is identical whether or not the recursion ran in parallel.
            Node[] kids = null;
            if (subs != null)
            {
                List<FileSystemInfo> local = subs;
                kids = new Node[local.Count];
                if (parallelLevels > 0 && local.Count > 1 && po != null)
                {
                    Node[] target = kids;
                    Parallel.For(0, local.Count, po, delegate(int i)
                    {
                        target[i] = Walk(local[i].FullName, local[i].Name, keepChildren - 1, parallelLevels - 1, po);
                    });
                }
                else
                {
                    for (int i = 0; i < local.Count; i++)
                    {
                        kids[i] = Walk(local[i].FullName, local[i].Name, keepChildren - 1, 0, po);
                    }
                }
            }

            long total = ownBytes, totalAlloc = ownAlloc;
            Node[] children = NoChildren;
            if (kids != null)
            {
                for (int i = 0; i < kids.Length; i++)
                {
                    total      += kids[i].TotalBytes;
                    totalAlloc += kids[i].TotalAllocBytes;
                }
                if (keepChildren > 0)
                {
                    Array.Sort(kids, CompareBySizeDesc);
                    children = kids;
                }
            }

            Node n = new Node();
            n.Name            = name;
            n.Path            = path;
            n.OwnBytes        = ownBytes;
            n.TotalBytes      = total;
            n.OwnAllocBytes   = ownAlloc;
            n.TotalAllocBytes = totalAlloc;
            n.FileCount       = fileCount;
            n.Children        = children;
            return n;
        }

        // Largest first, with a path tiebreak so equal-sized siblings always
        // come out in the same order (Array.Sort is not stable).
        private static int CompareBySizeDesc(Node a, Node b)
        {
            int c = b.TotalBytes.CompareTo(a.TotalBytes);
            if (c != 0) { return c; }
            return string.CompareOrdinal(a.Path, b.Path);
        }

        private static Node Empty(string path)
        {
            Node n = new Node();
            n.Name = LeafName(path);
            n.Path = path;
            n.Children = NoChildren;
            return n;
        }

        // Files directly inside `path` (no recursion) — used for the loose
        // files that sit in the analysis root itself.
        public static Node OwnFiles(string path)
        {
            long ownBytes = 0, ownAlloc = 0, fileCount = 0;
            try
            {
                DirectoryInfo di = new DirectoryInfo(path);
                foreach (FileSystemInfo e in di.EnumerateFileSystemInfos("*", SearchOption.TopDirectoryOnly))
                {
                    FileInfo fi = e as FileInfo;
                    if (fi == null) { continue; }
                    long len = 0;
                    try { len = fi.Length; } catch { }
                    ownBytes += len;
                    ownAlloc += Physical(fi.FullName, len);
                    fileCount++;
                }
            }
            catch { }

            Node n = new Node();
            n.Name            = LeafName(path);
            n.Path            = path;
            n.OwnBytes        = ownBytes;
            n.TotalBytes      = ownBytes;
            n.OwnAllocBytes   = ownAlloc;
            n.TotalAllocBytes = ownAlloc;
            n.FileCount       = fileCount;
            n.Children        = NoChildren;
            return n;
        }

        // Levels below a top-level branch that may still fan out across
        // threads. 3 is enough to keep every worker busy on a real disk without
        // spawning parallel loops over tiny leaf directories.
        private const int ParallelLevels = 3;

        public static Node[] ScanMany(string[] paths, int keepDepth, int maxDegree)
        {
            Node[] result = new Node[paths.Length];
            if (maxDegree <= 1)
            {
                for (int i = 0; i < paths.Length; i++)
                {
                    if (Stop) { result[i] = Empty(paths[i]); continue; }
                    result[i] = Walk(paths[i], LeafName(paths[i]), keepDepth, 0, null);
                    Interlocked.Increment(ref _branchesDone);
                }
                return result;
            }

            ParallelOptions po = new ParallelOptions();
            po.MaxDegreeOfParallelism = maxDegree;

            if (paths.Length == 1)
            {
                // A single branch still parallelises internally.
                if (Stop) { result[0] = Empty(paths[0]); return result; }
                result[0] = Walk(paths[0], LeafName(paths[0]), keepDepth, ParallelLevels, po);
                Interlocked.Increment(ref _branchesDone);
                return result;
            }

            Parallel.For(0, paths.Length, po, delegate(int i)
            {
                if (Stop) { result[i] = Empty(paths[i]); return; }
                result[i] = Walk(paths[i], LeafName(paths[i]), keepDepth, ParallelLevels, po);
                Interlocked.Increment(ref _branchesDone);
            });
            return result;
        }

        public static Task<Node[]> ScanManyAsync(string[] paths, int keepDepth, int maxDegree)
        {
            return Task.Run(delegate { return ScanMany(paths, keepDepth, maxDegree); });
        }
    }
}
'@
    }
    $Script:FastScan = $true
} catch {
    Write-Warning "Compiled scanner unavailable ($($_.Exception.Message)); falling back to the PowerShell walk."
    $Script:FastScan = $false
}

# ============================================================
# PowerShell fallback walk (used only when Add-Type failed)
# ============================================================

$Win32_FileSize = $null
if (-not $Script:FastScan) {
    try {
        $Win32_FileSize = Add-Type -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern uint GetCompressedFileSizeW(string lpFileName, out uint pFileSizeHigh);
'@ -Namespace Win32 -Name FileSizeApi -ErrorAction Stop -PassThru
    } catch {
        # No C# compiler at all; physical size degrades to logical size.
        $Win32_FileSize = $null
    }
}

function Get-PhysicalSize {
    <#
    .SYNOPSIS
        Returns the on-disk (physical / allocated / compressed) size of a file in bytes.

    .DESCRIPTION
        Uses kernel32 GetCompressedFileSizeW via P/Invoke. Returns -1 if the
        call fails or is unavailable, and the caller falls back to the logical
        Length. Only used by the PowerShell fallback walk; the compiled scanner
        does this inline.
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

function Get-SizeTreeNode {
    <#
    .SYNOPSIS
        Recursively builds an in-memory size-tree node for a directory (fallback path).

    .DESCRIPTION
        Enumerates a single directory level with the .NET
        DirectoryInfo.EnumerateFileSystemInfos iterator. Files are summed into
        OwnBytes; subdirectories are recursed into (skipping reparse points).
        Returns a PSCustomObject shaped exactly like [DiskScan.Node] so the
        reporting code is identical on both paths. -KeepChildren bounds how many
        levels of Children arrays are retained (totals stay exact).
        Honors $Script:StopRequested / $Script:PauseRequested between entries.
    #>
    param(
        [string]$Path,
        [string]$Name = '',
        [int]$KeepChildren = 99
    )

    $reparseFlag   = [int][System.IO.FileAttributes]::ReparsePoint
    $ownBytes      = [long]0
    $ownAllocBytes = [long]0
    $fileCount     = [long]0
    $childNodes    = [System.Collections.Generic.List[object]]::new()

    try {
        foreach ($e in [System.IO.DirectoryInfo]::new($Path).EnumerateFileSystemInfos('*', [System.IO.SearchOption]::TopDirectoryOnly)) {
            if ($Script:StopRequested) { break }

            if ($e -is [System.IO.FileInfo]) {
                $len = 0L
                try { $len = [long]$e.Length } catch {}
                $ownBytes += $len
                # Physical (allocated) size via GetCompressedFileSizeW.
                $phys = Get-PhysicalSize -Path $e.FullName
                if ($phys -lt 0) { $phys = $len }
                $ownAllocBytes += $phys
                $fileCount++
            } else {
                # Directory: recurse only if NOT a reparse point.
                if (-not ([int]$e.Attributes -band $reparseFlag)) {
                    $childNodes.Add((Get-SizeTreeNode -Path $e.FullName -Name $e.Name -KeepChildren ($KeepChildren - 1)))
                }
            }
        }
    } catch {
        # Enumeration error: keep what we have so far.
    }

    $Script:FilesCounted += $fileCount
    $Script:BytesCounted += $ownBytes

    $totalBytes      = $ownBytes
    $totalAllocBytes = $ownAllocBytes
    foreach ($c in $childNodes) {
        $totalBytes      += [long]$c.TotalBytes
        $totalAllocBytes += [long]$c.TotalAllocBytes
    }

    # Sort children by TotalBytes descending, but only where the list is
    # actually retained and worth sorting (Sort-Object on every leaf is pure
    # overhead on a large tree).
    $children = @()
    if ($KeepChildren -gt 0 -and $childNodes.Count -gt 0) {
        if ($childNodes.Count -eq 1) {
            $children = @($childNodes[0])
        } else {
            $children = @($childNodes | Sort-Object -Property TotalBytes -Descending)
        }
    }

    if (-not $Name) {
        $Name = [System.IO.Path]::GetFileName($Path.TrimEnd([char]92, [char]47))
        if (-not $Name) { $Name = $Path }
    }

    return [pscustomobject]@{
        Name            = $Name
        Path            = $Path
        OwnBytes        = $ownBytes
        TotalBytes      = $totalBytes
        OwnAllocBytes   = $ownAllocBytes
        TotalAllocBytes = $totalAllocBytes
        FileCount       = $fileCount
        Children        = $children
    }
}

function Get-OwnFilesNodeFallback {
    <#
    .SYNOPSIS
        PowerShell fallback for [DiskScan.Scanner]::OwnFiles - files directly in
        $Path only, no recursion.
    #>
    param([string]$Path)

    $ownBytes = [long]0; $ownAlloc = [long]0; $fileCount = [long]0
    try {
        foreach ($e in [System.IO.DirectoryInfo]::new($Path).EnumerateFileSystemInfos('*', [System.IO.SearchOption]::TopDirectoryOnly)) {
            if ($e -isnot [System.IO.FileInfo]) { continue }
            $len = 0L
            try { $len = [long]$e.Length } catch {}
            $ownBytes += $len
            $phys = Get-PhysicalSize -Path $e.FullName
            if ($phys -lt 0) { $phys = $len }
            $ownAlloc += $phys
            $fileCount++
        }
    } catch {}

    return [pscustomobject]@{
        Name            = [System.IO.Path]::GetFileName($Path.TrimEnd([char]92, [char]47))
        Path            = $Path
        OwnBytes        = $ownBytes
        TotalBytes      = $ownBytes
        OwnAllocBytes   = $ownAlloc
        TotalAllocBytes = $ownAlloc
        FileCount       = $fileCount
        Children        = @()
    }
}

function New-EmptyNode {
    <#
    .SYNOPSIS
        A zero-sized placeholder node for a branch that was never walked.
    #>
    param([string]$Path)

    $name = [System.IO.Path]::GetFileName($Path.TrimEnd([char]92, [char]47))
    if (-not $name) { $name = $Path }
    return [pscustomobject]@{
        Name = $name; Path = $Path
        OwnBytes = [long]0; TotalBytes = [long]0
        OwnAllocBytes = [long]0; TotalAllocBytes = [long]0
        FileCount = [long]0; Children = @()
    }
}

function Format-MB {
    param([long]$Bytes)
    return [math]::Round($Bytes / 1MB, 2)
}

# ============================================================
# Telemetry / control plumbing (active only with -Telemetry)
# ============================================================

function Resolve-UserPath {
    <#
    .SYNOPSIS
        Resolves a possibly-relative user-supplied path against the PowerShell
        location (the path need not exist yet).

    .DESCRIPTION
        .NET file APIs ([System.IO.File]::WriteAllText etc.) resolve relative
        paths against the PROCESS working directory, which differs from the
        PowerShell location when the script is invoked in-session after
        Set-Location — a relative -Output would land in the wrong directory.
        Resolving everything up front makes both worlds agree.
    #>
    param([string]$Path)

    if (-not $Path) { return $Path }
    try {
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    } catch {
        return $Path
    }
}

function Read-JsonFile {
    <#
    .SYNOPSIS
        Reads and parses a JSON file, returning $null on any failure.
    #>
    param([string]$Path, [switch]$Warn)

    if (-not $Path) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        return ([System.IO.File]::ReadAllText((Convert-Path -LiteralPath $Path)) | ConvertFrom-Json)
    } catch {
        if ($Warn) { Write-Warning "Could not parse JSON file '$Path': $($_.Exception.Message)" }
        return $null
    }
}

function Write-JsonFile {
    <#
    .SYNOPSIS
        Writes an object as UTF-8 (no BOM) JSON, warning instead of throwing on failure.

    .DESCRIPTION
        A BOM breaks strict JSON parsers on the consuming side, so it is always
        omitted. Returns $true on success.
    #>
    param($Data, [string]$Path, [int]$JsonDepth = 5)

    try {
        $json = $Data | ConvertTo-Json -Depth $JsonDepth
        [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
        return $true
    } catch {
        Write-Warning "Could not write '$Path': $($_.Exception.Message)"
        return $false
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
        # UTF-8 without BOM: a BOM breaks JSON parsers on the polling side.
        $json = $data | ConvertTo-Json -Depth 5
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
    $ctl = Read-JsonFile -Path $Script:ControlFile
    if ($null -eq $ctl) { return $false }

    switch ([string]$ctl.action) {
        'stop'   { $Script:StopRequested   = $true }
        'pause'  { $Script:PauseRequested  = $true }
        'resume' { $Script:PauseRequested  = $false }
    }
    # A malformed override must not kill a scan that is minutes in. Ignore it,
    # warning once (this runs inside the 250ms polling loop).
    try {
        if ($ctl.PSObject.Properties['depth']) { $Script:OverrideDepth = [int]$ctl.depth }
        if ($ctl.PSObject.Properties['top'])   { $Script:OverrideTop   = [int]$ctl.top }
    } catch {
        if (-not $Script:ControlWarned) {
            $Script:ControlWarned = $true
            Write-Warning "Ignoring invalid depth/top override in '$($Script:ControlFile)': $($_.Exception.Message)"
        }
    }

    # Mirror the flags into the compiled scanner so an in-flight walk reacts.
    if ($Script:FastScan) {
        [DiskScan.Scanner]::Stop   = $Script:StopRequested
        [DiskScan.Scanner]::Paused = ($Script:PauseRequested -and -not $Script:StopRequested)
    }
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

# ============================================================
# Scan driver
# ============================================================

function Get-MaxDegree {
    <#
    .SYNOPSIS
        Worker count for a parallel scan: one per core, capped at 8.
    #>
    param([int]$ItemCount)

    if (-not $Script:UseParallel -or $ItemCount -le 0) { return 1 }
    # Not capped at the branch count: a single large branch is parallelised
    # internally, so extra workers are still useful.
    return [Math]::Max(1, [Math]::Min([Environment]::ProcessorCount, 8))
}

function Invoke-TreeScan {
    <#
    .SYNOPSIS
        Walks each of $Paths and returns one size-tree node per path, in order.

    .DESCRIPTION
        Fast path: the compiled [DiskScan.Scanner]. Without -Telemetry the scan
        runs synchronously; with -Telemetry it runs on a background task while
        this thread publishes status and polls the control file, so stop/pause
        take effect mid-walk instead of only at directory checkpoints.
        Fallback path: the PowerShell walk, one branch at a time.
        $KeepChildren bounds retained child lists; totals are always exact.
    #>
    param(
        [string[]]$Paths,
        [int]$KeepChildren = 3,
        [string]$Phase = 'scan',
        [string]$Message = 'Scanning'
    )

    $total = $Paths.Count
    if ($total -eq 0) { return @() }
    $degree = Get-MaxDegree -ItemCount $total

    if (-not $Script:FastScan) {
        # --- PowerShell fallback: serial walk ---
        $nodes = [object[]]::new($total)
        for ($i = 0; $i -lt $total; $i++) {
            if ($Script:StopRequested) {
                $nodes[$i] = New-EmptyNode -Path $Paths[$i]
                continue
            }
            Write-Status -Phase $Phase -Current $Paths[$i] -ItemsDone $i -ItemsTotal $total `
                -Files $Script:FilesCounted -Bytes $Script:BytesCounted -Message ($Message + ' `' + $Paths[$i] + '`')
            $nodes[$i] = Get-SizeTreeNode -Path $Paths[$i] -KeepChildren $KeepChildren
            $Script:BranchesDone = $i + 1
            Read-Control
        }
        return @($nodes)
    }

    [DiskScan.Scanner]::ResetCounters()
    # Carry the current control state into the scanner: a control file read
    # before the scan started must still stop it.
    [DiskScan.Scanner]::Stop   = $Script:StopRequested
    [DiskScan.Scanner]::Paused = ($Script:PauseRequested -and -not $Script:StopRequested)
    $baseFiles = $Script:FilesCounted
    $baseBytes = $Script:BytesCounted

    if (-not $Script:TelemetryOn) {
        $nodes = [DiskScan.Scanner]::ScanMany($Paths, $KeepChildren, $degree)
        $Script:FilesCounted = $baseFiles + [DiskScan.Scanner]::FilesSeen
        $Script:BytesCounted = $baseBytes + [DiskScan.Scanner]::BytesSeen
        $Script:BranchesDone = [int][DiskScan.Scanner]::BranchesDone
        return @($nodes)
    }

    # --- Telemetry: scan on a background task, poll progress + control here ---
    $task = [DiskScan.Scanner]::ScanManyAsync($Paths, $KeepChildren, $degree)
    try {
        while (-not $task.Wait(250)) {
            $Script:FilesCounted = $baseFiles + [DiskScan.Scanner]::FilesSeen
            $Script:BytesCounted = $baseBytes + [DiskScan.Scanner]::BytesSeen
            $done = [int][DiskScan.Scanner]::BranchesDone
            if ($Script:PauseRequested -and -not $Script:StopRequested) {
                Write-Status -Phase 'paused' -ItemsDone $done -ItemsTotal $total `
                    -Files $Script:FilesCounted -Bytes $Script:BytesCounted `
                    -Message 'Paused by control file; waiting for resume or stop.'
            } else {
                Write-Status -Phase $Phase -ItemsDone $done -ItemsTotal $total `
                    -Files $Script:FilesCounted -Bytes $Script:BytesCounted `
                    -Message ("$Message : {0}/{1} branches, {2} files" -f $done, $total, $Script:FilesCounted)
            }
            # Read-Once-Control mirrors stop/pause into the scanner; the walk
            # itself blocks while paused, so no blocking wait is needed here.
            [void](Read-Once-Control)
        }
        $nodes = $task.Result
    } catch {
        Write-Warning "Scan failed: $($_.Exception.Message)"
        $nodes = [object[]]::new($total)
        for ($i = 0; $i -lt $total; $i++) {
            $nodes[$i] = [pscustomobject]@{
                Name = [System.IO.Path]::GetFileName($Paths[$i]); Path = $Paths[$i]
                OwnBytes = 0L; TotalBytes = 0L; OwnAllocBytes = 0L; TotalAllocBytes = 0L
                FileCount = 0L; Children = @()
            }
        }
    }

    $Script:FilesCounted = $baseFiles + [DiskScan.Scanner]::FilesSeen
    $Script:BytesCounted = $baseBytes + [DiskScan.Scanner]::BytesSeen
    $Script:BranchesDone = [int][DiskScan.Scanner]::BranchesDone
    return @($nodes)
}

function Get-RootOwnFiles {
    <#
    .SYNOPSIS
        Size of the loose files sitting directly in $Path (no recursion).
    #>
    param([string]$Path)

    if ($Script:FastScan) { return [DiskScan.Scanner]::OwnFiles($Path) }
    return (Get-OwnFilesNodeFallback -Path $Path)
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
        level and deeper levels as a [string[]].
    #>
    param(
        $Node,
        [int]$Level,
        [int]$Levels,
        [string]$Indent
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $kids = @($Node.Children)
    if ($kids.Count -eq 0) { return [string[]]@() }

    # Determine which children to expand (top MAX_EXPANDED, if levels remain).
    $expandedSet = @{}
    if ($Level -lt $Levels) {
        foreach ($e in ($kids | Select-Object -First $MAX_EXPANDED)) { $expandedSet[$e.Path] = $true }
    }

    foreach ($e in $kids) {
        $isFull = $expandedSet.ContainsKey($e.Path)
        $note = if ($isFull) { '' } else { ' (this level only)' }
        # Expanded: show TotalBytes (full recursive). Non-expanded: show OwnBytes (this level only).
        $displayBytes = if ($isFull) { [long]$e.TotalBytes }      else { [long]$e.OwnBytes }
        $displayAlloc = if ($isFull) { [long]$e.TotalAllocBytes } else { [long]$e.OwnAllocBytes }
        $lines.Add($Indent + '- `' + $e.Name + '`: ' + (Format-MB $displayBytes) + ' MB / ' + (Format-MB $displayAlloc) + ' MB alloc' + $note)
        if ($isFull) {
            foreach ($dl in (Expand-Tree -Node $e -Level ($Level + 1) -Levels $Levels -Indent ($Indent + '    '))) {
                $lines.Add($dl)
            }
        }
    }
    return [string[]]$lines.ToArray()
}

function Find-CleanupCandidates {
    <#
    .SYNOPSIS
        Scans well-known Windows waste locations and reports reclaimable sizes
        with suggested cleanup commands.

    .DESCRIPTION
        Read-only. Checks a fixed list of known waste locations. For each,
        reports whether it exists, its logical and physical size, and a
        suggested safe cleanup command hint. Missing locations are reported as
        'not present'. Present locations are measured in a single batched scan
        (concurrently with -Parallel). The script itself performs NO deletion.
    #>
    param()

    $systemDrive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }

    $locations = @(
        @{ Path = $env:TEMP; Label = "User TEMP ($($env:TEMP))"; Hint = "Remove-Item -LiteralPath `$env:TEMP\* -Recurse -Force" },
        @{ Path = "$env:SystemRoot\Temp"; Label = 'Windows Temp'; Hint = "Remove-Item -Path '$env:SystemRoot\Temp\*' -Recurse -Force" },
        @{ Path = "$systemDrive\`$Recycle.Bin"; Label = 'Recycle Bin'; Hint = "Clear-RecycleBin -DriveLetter $($systemDrive.TrimEnd(':'))" },
        @{ Path = "$env:SystemRoot\SoftwareDistribution\Download"; Label = 'Windows Update download cache'; Hint = "Remove-Item -Path '$env:SystemRoot\SoftwareDistribution\Download\*' -Recurse -Force" },
        @{ Path = "$env:SystemRoot\Installer"; Label = 'Windows Installer'; Hint = "Run 'cleanmgr' (Disk Cleanup) to reclaim Installer cache" },
        @{ Path = "$env:LOCALAPPDATA\pip\Cache"; Label = 'pip cache'; Hint = "Remove-Item -Path `"$env:LOCALAPPDATA\pip\Cache\*`" -Recurse -Force" },
        @{ Path = "$env:LOCALAPPDATA\npm-cache"; Label = 'npm cache'; Hint = 'npm cache clean --force' },
        @{ Path = "$env:LOCALAPPDATA\NuGet\v3-cache"; Label = 'NuGet cache'; Hint = "Remove-Item -Path `"$env:LOCALAPPDATA\NuGet\v3-cache\*`" -Recurse -Force" }
    )

    # Which locations actually exist? Only those get walked, each unique path
    # once (under some accounts, e.g. SYSTEM, user TEMP and Windows Temp are
    # the same directory).
    $presentPaths = @($locations | Where-Object { $_.Path -and (Test-Path -LiteralPath $_.Path -PathType Container) } |
        ForEach-Object { $_.Path } | Select-Object -Unique)
    $sizes = @{}
    if ($presentPaths.Count -gt 0) {
        # KeepChildren 0: only the totals are needed, so no child lists are retained.
        $nodes = Invoke-TreeScan -Paths $presentPaths -KeepChildren 0 `
            -Phase 'cleanup-scan' -Message 'Measuring cleanup candidate'
        for ($i = 0; $i -lt $presentPaths.Count; $i++) {
            $sizes[$presentPaths[$i]] = $nodes[$i]
        }
    }

    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($loc in $locations) {
        $node = if ($loc.Path) { $sizes[$loc.Path] } else { $null }
        $candidates.Add([pscustomobject]@{
            Present    = ($null -ne $node)
            Label      = $loc.Label
            Path       = $loc.Path
            Bytes      = if ($node) { [long]$node.TotalBytes }      else { [long]0 }
            AllocBytes = if ($node) { [long]$node.TotalAllocBytes } else { [long]0 }
            Hint       = $loc.Hint
        })
    }
    return $candidates
}

# --- Load settings file (another process can pre-configure the run) ---
# CLI parameters always win over settings-file values.
$Script:ParallelSpecified = $PSBoundParameters.ContainsKey('Parallel')
$cfg = Read-JsonFile -Path $Settings -Warn
if ($cfg) {
    # Key -> parameter name, with a converter per kind. A bad value skips that
    # one key with a warning rather than aborting the run.
    $stringKeys = @{ root = 'Root'; output = 'Output'; statusFile = 'StatusFile'; controlFile = 'ControlFile'; jsonReport = 'JsonReport' }
    $intKeys    = @{ top = 'Top'; depth = 'Depth' }
    $boolKeys   = @{ telemetry = 'Telemetry'; parallel = 'Parallel'; serial = 'Serial'; skipCleanup = 'SkipCleanup' }
    foreach ($k in $stringKeys.Keys) {
        if (-not $PSBoundParameters.ContainsKey($stringKeys[$k]) -and $cfg.PSObject.Properties[$k] -and $cfg.$k) {
            Set-Variable -Name $stringKeys[$k] -Value ([string]$cfg.$k) -Scope Script
        }
    }
    foreach ($k in $intKeys.Keys) {
        if (-not $PSBoundParameters.ContainsKey($intKeys[$k]) -and $cfg.PSObject.Properties[$k] -and $null -ne $cfg.$k) {
            try { Set-Variable -Name $intKeys[$k] -Value ([int]$cfg.$k) -Scope Script }
            catch { Write-Warning "Ignoring invalid settings key '$k': $($cfg.$k)" }
        }
    }
    foreach ($k in $boolKeys.Keys) {
        if (-not $PSBoundParameters.ContainsKey($boolKeys[$k]) -and $cfg.PSObject.Properties[$k] -and $null -ne $cfg.$k) {
            try {
                # [bool]'false' is $true in PowerShell; parse strings properly.
                $v = $cfg.$k
                $b = if ($v -is [string]) { [System.Convert]::ToBoolean($v) } else { [bool]$v }
                Set-Variable -Name $boolKeys[$k] -Value ([switch]$b) -Scope Script
                if ($k -eq 'parallel') { $Script:ParallelSpecified = $true }
            }
            catch { Write-Warning "Ignoring invalid settings key '$k': $($cfg.$k)" }
        }
    }
}

# Multithreaded scanning is the default. -Serial (or settings serial=true)
# opts out; an explicit -Parallel:$false (or settings parallel=false) does too,
# for compatibility with pre-default automation.
if ($Serial -and $Parallel) {
    Write-Warning 'Both -Serial and -Parallel were given; running serial.'
}
$Script:UseParallel = $true
if ($Serial) {
    $Script:UseParallel = $false
} elseif ($Script:ParallelSpecified) {
    $Script:UseParallel = [bool]$Parallel
}

# Resolve every user-supplied output/IPC path against the PowerShell location
# (see Resolve-UserPath): a relative path must mean the same directory to both
# the PowerShell cmdlets and the .NET file APIs.
$Output      = Resolve-UserPath $Output
$JsonReport  = Resolve-UserPath $JsonReport
$StatusFile  = Resolve-UserPath $StatusFile
$ControlFile = Resolve-UserPath $ControlFile

# --- Telemetry / control runtime state (script scope) ---
$Script:TelemetryOn     = [bool]$Telemetry
$Script:StatusFile      = $StatusFile
$Script:ControlFile     = $ControlFile
$Script:StartTime       = [DateTime]::Now
$Script:StopRequested   = $false
$Script:PauseRequested  = $false
$Script:FilesCounted    = [long]0
$Script:BytesCounted    = [long]0
$Script:BranchesDone    = 0
$Script:OverrideTop     = $null
$Script:OverrideDepth   = $null
$Script:ControlWarned   = $false

# Validate the root before doing any work.
if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    if (Test-Path -LiteralPath $Root) {
        Write-Error "Root must be a directory, not a file: $Root"
    } else {
        Write-Error "Root path not found: $Root"
    }
    exit 1
}
# Normalize so the drive lookup and node paths are consistent.
$Root = (Convert-Path -LiteralPath $Root)

# --- Start heartbeat (telemetry) ---
Write-Status -Phase 'start' -Message ('Disk analysis starting under `' + $Root + '`')
# Pick up a control file that already exists before the scan begins.
Read-Control

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
    # Derive the volume from the resolved root, so relative and UNC roots work.
    $pathRoot = [System.IO.Path]::GetPathRoot($Root)
    if ($pathRoot -match '^([A-Za-z]):') {
        $driveLetter = $Matches[1]
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

# Single-pass tree build: each top-level directory is walked ONCE (no
# re-scanning for drill-down). The in-memory tree is reused for ranking,
# drill-down, and grand total.
$reparseFlag = [int][System.IO.FileAttributes]::ReparsePoint
$rootDirs = @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { -not ([int]$_.Attributes -band $reparseFlag) })
$totalDirs = $rootDirs.Count
Write-Status -Phase 'top-scan-start' -ItemsTotal $totalDirs -Message ('Scanning ' + $totalDirs + ' top-level directory(ies) under `' + $Root + '`')

if ($Script:UseParallel -and $totalDirs -gt 1) {
    Write-Host "[parallel] Scanning $totalDirs branches concurrently (max $(Get-MaxDegree -ItemCount $totalDirs) workers)"
}

# Retain child lists only as deep as the drill-down can reach (plus one level
# of slack for a control-file depth override). Deeper totals stay exact.
$keepChildren = [Math]::Max(1, $Depth + 1)
$topNodes = Invoke-TreeScan -Paths @($rootDirs | ForEach-Object { $_.FullName }) -KeepChildren $keepChildren `
    -Phase 'top-scan' -Message 'Measuring'

$done = $Script:BranchesDone
Write-Status -Phase 'top-scan-done' -ItemsDone $done -ItemsTotal $totalDirs `
    -Files $Script:FilesCounted -Bytes $Script:BytesCounted -Message "Top-level scan complete ($done/$totalDirs measured)"
Read-Control

# Rank top-level nodes by TotalBytes descending.
$ranked = @($topNodes | Sort-Object -Property TotalBytes -Descending)

# Grand total = root's own files + all top-level node totals (from the tree).
$rootOwn = Get-RootOwnFiles -Path $Root
$grandTotalBytes      = [long]$rootOwn.OwnBytes
$grandTotalAllocBytes = [long]$rootOwn.OwnAllocBytes
foreach ($item in $ranked) {
    $grandTotalBytes      += [long]$item.TotalBytes
    $grandTotalAllocBytes += [long]$item.TotalAllocBytes
}

# Honor any control-file override of the top-N before selecting.
$effectiveTop = if ($Script:OverrideTop -and $Script:OverrideTop -gt 0) { $Script:OverrideTop } else { $Top }
$topN = @($ranked | Select-Object -First $effectiveTop)

function Write-JsonRunReport {
    <#
    .SYNOPSIS
        Writes the machine-readable run result to -JsonReport (if requested).

    .DESCRIPTION
        Written on both the normal and the early-stop path, so an automation
        driver always has a result document to read; `stopped` distinguishes
        the two.
    #>
    param($TopConsumers, $Candidates, [long]$TotalBytes, [long]$TotalAllocBytes)

    if (-not $JsonReport) { return }
    $data = [ordered]@{
        summary = [ordered]@{
            topN = $effectiveTop
            root = $Root
            host = $env:COMPUTERNAME
            date = [DateTime]::Now.ToString('o')
        }
        topConsumers = @($TopConsumers | ForEach-Object { [ordered]@{
            name    = $_.Name
            sizeMB  = [math]::Round([long]$_.TotalBytes / 1MB, 2)
            allocMB = [math]::Round([long]$_.TotalAllocBytes / 1MB, 2)
        } })
        cleanupCandidates = @($Candidates | ForEach-Object { [ordered]@{
            label   = $_.Label
            mb      = [math]::Round([long]$_.Bytes / 1MB, 2)
            allocMB = [math]::Round([long]$_.AllocBytes / 1MB, 2)
            present = [bool]$_.Present
        } })
        grandTotalMB      = [math]::Round($TotalBytes / 1MB, 2)
        grandTotalAllocMB = [math]::Round($TotalAllocBytes / 1MB, 2)
        stopped           = [bool]$Script:StopRequested
    }
    if (Write-JsonFile -Data $data -Path $JsonReport) {
        Write-Host "JSON report written to $JsonReport"
    }
}

# If stop was requested mid-scan, write a terminal status and exit early.
# The JSON report is still emitted (with stopped=true and the partial totals)
# so an automation driver always has a document to read.
if ($Script:StopRequested) {
    Write-Status -Phase 'stopped' -ItemsDone $done -ItemsTotal $totalDirs `
        -Files $Script:FilesCounted -Bytes $Script:BytesCounted -Message 'stopped by control file'
    Write-JsonRunReport -TopConsumers $topN -Candidates @() -TotalBytes $grandTotalBytes -TotalAllocBytes $grandTotalAllocBytes
    Write-Output 'Stopped by control file; report not generated.'
    exit 0
}

foreach ($item in $topN) {
    $report.Add('| `' + $item.Name + '` | ' + (Format-MB $item.TotalBytes) + ' | ' + (Format-MB $item.TotalAllocBytes) + ' |')
}

# --- Drill-down into the top consumers (bounded: effective depth, $MAX_EXPANDED branches/level) ---
$effectiveDepth = if ($null -ne $Script:OverrideDepth -and $Script:OverrideDepth -ge 0) { $Script:OverrideDepth } else { $Depth }
# The tree only retained $keepChildren levels of child lists. Drilling past that
# would silently print "(no subdirectories)" for branches that do have children,
# so clamp instead and say so.
if ($effectiveDepth -gt $keepChildren) {
    Write-Warning "Control-file depth $effectiveDepth exceeds the $keepChildren levels retained by this scan; using $keepChildren."
    $effectiveDepth = $keepChildren
}
if ($effectiveDepth -ge 1 -and $topN.Count -gt 0) {
    $report.Add('')
    $report.Add('## Drill-down (top consumers, up to ' + $effectiveDepth + ' levels)')
    $report.Add('')
    foreach ($item in $topN) {
        $report.Add('### `' + $item.Name + '`' + ' — ' + (Format-MB $item.TotalBytes) + ' MB')
        $drill = @(Expand-Tree -Node $item -Level 1 -Levels $effectiveDepth -Indent '')
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

if ($SkipCleanup) {
    $candidates = @()
    $report.Add('- (skipped: -SkipCleanup)')
} else {
    $candidates = Find-CleanupCandidates
    Read-Control
    foreach ($c in $candidates) {
        if ($c.Present) {
            $report.Add('- **' + $c.Label + '**: ' + (Format-MB $c.Bytes) + ' MB logical / ' + (Format-MB $c.AllocBytes) + ' MB physical')
            $report.Add('  Suggested cleanup: `' + $c.Hint + '`')
        } else {
            $report.Add('- **' + $c.Label + '**: not present')
        }
    }
}
$report.Add('')

$report.Add('Total under `' + $Root + '`: ' + (Format-MB $grandTotalBytes) + ' MB logical / ' + (Format-MB $grandTotalAllocBytes) + ' MB physical (' + $grandTotalBytes + ' bytes)')

# --- Emit report: console, and to -Output file when given ---
$text = $report -join [System.Environment]::NewLine
if ($Output) {
    try {
        [System.IO.File]::WriteAllText($Output, $text, [System.Text.UTF8Encoding]::new($false))
        Write-Host "Report written to $Output"
    } catch {
        Write-Warning "Could not write report to '$Output': $($_.Exception.Message)"
    }
}

# --- Terminal heartbeat (telemetry) ---
Write-Status -Phase 'done' -ItemsDone $done -ItemsTotal $totalDirs `
    -Files $Script:FilesCounted -Bytes $Script:BytesCounted -Message 'Report generated.'
Write-Output $text

# --- Machine-readable JSON report (-JsonReport) ---
Write-JsonRunReport -TopConsumers $topN -Candidates $candidates -TotalBytes $grandTotalBytes -TotalAllocBytes $grandTotalAllocBytes
