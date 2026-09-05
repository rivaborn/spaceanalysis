# spaceanalysis

`analyze-disk.ps1` reviews disk space usage on a Windows system and recommends
ways to free up space. It is a PowerShell script that is **strictly
read-only**: it reports sizes and suggests cleanups, but never modifies or
deletes anything. The methodology is WinDirStat-inspired: a single-pass,
metadata-only tree walk with reparse-point (junction/symlink) skipping,
dual logical/physical (allocated) size reporting, and optional multithreaded
scanning. The walk itself runs in a small compiled .NET scanner so that a
whole-drive pass finishes in seconds rather than minutes.

## What it produces

A single cohesive markdown report with four sections:

1. **System summary** — host name, PowerShell version, run date, root, top-N
   and depth settings, and the drive's total/used/free space.
2. **Top space consumers** — the root's direct child directories ranked by
   recursive size, descending. Both logical size and physical (allocated)
   size are shown in MB; physical reflects actual on-disk usage (matters for
   sparse and NTFS-compressed files).
3. **Drill-down** — a bounded in-memory walk into the top consumers (up to
   `-Depth` levels, at most 10 branches expanded per level) showing which
   subdirectories drive the big usage. Branches that were not expanded
   recursively are marked `(this level only)`. No disk re-scan is performed.
4. **Cleanup candidates** — well-known Windows waste locations (user TEMP,
   Windows Temp, Recycle Bin, Windows Update download cache, Windows
   Installer, pip/npm/NuGet caches) with their reclaimable logical and
   physical size and a suggested safe cleanup command. Missing locations are
   reported as `not present`. This scan costs a few seconds regardless of
   `-Root`; pass `-SkipCleanup` to omit it when only the tree matters.

The report is printed to the console and, when `-Output` is given, also
written to that file (UTF-8).

## Efficient methodology

Reading every file and folder on a drive can take hours. The script uses a
WinDirStat-inspired, single-pass approach:

- **Metadata only.** The script enumerates file names and sizes via the .NET
  `DirectoryInfo.EnumerateFileSystemInfos` iterator (no per-object PowerShell
  pipeline). File contents are never opened, so a recursive pass is just a
  metadata walk — orders of magnitude faster than reading data.
- **Compiled walk.** The recursive walk lives in a C# type (`DiskScan.Scanner`)
  compiled once at startup with `Add-Type`, so the per-file
  `GetCompressedFileSizeW` lookup is a direct P/Invoke instead of a PowerShell
  function call. This is where most of the speed comes from. If `Add-Type`
  cannot compile (no C# compiler on the host), the script warns once and falls
  back to an equivalent PowerShell walk that produces identical numbers, just
  slower. Set `ANALYZE_DISK_NO_FASTSCAN=1` to force the fallback — the test
  suite uses this to check the two paths agree.
- **Single-pass tree (scan-once).** Each top-level directory is walked exactly
  once, building an in-memory tree of nodes (Name, Path, OwnBytes, TotalBytes,
  TotalAllocBytes, FileCount, Children). Ranking, drill-down, and the grand
  total all read from this tree — no disk re-scans.
- **Bounded memory.** Child lists deeper than the drill-down can reach
  (`-Depth` + 1 levels) are dropped as the tree is built. Every total stays
  exact; only detail that would never be printed is discarded, so scanning a
  drive with millions of directories does not balloon the working set.
- **Reparse-point / junction skipping.** Directory reparse points (junctions
  and symbolic links) are skipped, matching WinDirStat's default, to prevent
  loops and double-counting. This applies at every level of the tree, including
  top-level entries under the scan root.
- **Physical (allocated) size.** Alongside the logical file size (`Length`),
  the script queries `GetCompressedFileSizeW` (via P/Invoke) to report the
  on-disk allocated size. For sparse or NTFS-compressed files the physical
  size is smaller; for normal files it is approximately equal. Physical size
  is what actually frees space.
- **Top-down, bounded drill-down.** Direct children of the root are ranked
  first; only the largest consumers are expanded, at most 10 per level, up
  to `-Depth` levels. Smaller branches are shown with a cheap
  non-recursive size. This finds the big space hogs without an exhaustive
  full-tree scan, keeping runtime bounded.
- **Parallel scanning by default.** Mirrors WinDirStat's multithreading.
  Top-level branches are walked concurrently, *and* the first
  few levels inside each branch fan out too — branch-level parallelism alone
  achieves little on a real disk, where one branch dominates and the other
  workers finish early and idle. Worker count is one per core, capped at 8.
  The result is identical to the serial scan: children are collected by
  discovery index and sorted with a path tiebreak, so equal-sized siblings
  always come out in the same order. Pass `-Serial` to opt out (about 2.5x
  slower on a whole drive, but minimal I/O pressure); `-Parallel` is still
  accepted for compatibility, and `-Parallel:$false` / settings
  `"parallel": false` also mean serial (note `powershell -File` in 5.1 cannot
  pass `$false` to a switch — use `-Serial` on the command line).

## Usage

```powershell
# Default: analyze C:\, top 20, drill 2 levels, print to console
powershell -NoProfile -ExecutionPolicy Bypass -File analyze-disk.ps1

# Custom root, top 10, 3-level drill-down, also write report.md
powershell -NoProfile -ExecutionPolicy Bypass -File analyze-disk.ps1 `
  -Root 'C:\Users\folar' -Top 10 -Depth 3 -Output .\report.md

# One directory at a time (multithreaded scanning is the default)
powershell -NoProfile -ExecutionPolicy Bypass -File analyze-disk.ps1 `
  -Root 'C:\' -Top 20 -Depth 2 -Serial

# Show help
powershell -NoProfile -ExecutionPolicy Bypass -File analyze-disk.ps1 -Help
```

| Parameter      | Default | Description                                                                                                     |
| -------------- | ------- | --------------------------------------------------------------------------------------------------------------- |
| `-Root`        | `C:\`   | Directory to analyze. Must exist and be a directory; anything else exits 1.                                     |
| `-Top`         | `20`    | Number of top-level consumers to rank and drill into.                                                           |
| `-Depth`       | `2`     | Drill-down depth into top consumers, in levels.                                                                 |
| `-Output`      | none    | Also write the markdown report to this file.                                                                    |
| `-Parallel`    | **on**  | Scan concurrently (top-level branches and the first levels within each). On by default; kept for compatibility. |
| `-Serial`      | off     | Scan one directory at a time. Slower; identical results.                                                        |
| `-SkipCleanup` | off     | Skip the cleanup-candidates scan; the report section notes the skip.                                            |
| `-Help`        |         | Print usage and exit.                                                                                           |

## CLI / automation

Besides the basic scan parameters, the script exposes five parameters that let
an external process pre-configure, observe, and steer a run through plain JSON
files on the filesystem. No pipes, sockets, or daemons are needed — the script
is a single-shot process, so file-based JSON is the natural IPC.

### Parameters

| Parameter             | Default        | Description                                                                                                                                                                                                                               |
| --------------------- | -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `-Settings <json>`    | none           | Path to a JSON run-config file (see schema below). CLI parameters take precedence over settings-file values.                                                                                                                              |
| `-StatusFile <json>`  | `status.json`  | Where the script writes live telemetry (see schema below). Written **only** when `-Telemetry` is set.                                                                                                                                     |
| `-ControlFile <json>` | `control.json` | Where an external process writes control actions (see schema below). Read **only** when `-Telemetry` is set.                                                                                                                              |
| `-Telemetry`          | off            | Switch. When set, the scan runs on a background thread while the main thread writes the status file and polls the control file about four times a second, so `stop`/`pause` take effect mid-directory rather than at the next checkpoint. |
| `-JsonReport <file>`  | none           | Path for a machine-readable JSON run result (see schema below). Written on both the normal and the early-stop path.                                                                                                                       |

### `settings.json` — run configuration

An external process writes this file **before** launching the script. Only
keys that are present are applied; any key the CLI already specifies is
ignored (CLI wins).

```json
{
  "root":       "C:\\",
  "top":        20,
  "depth":      2,
  "output":     "C:\\reports\\disk.md",
  "jsonReport": "C:\\reports\\disk.json",
  "serial":      false,
  "telemetry":   false,
  "skipCleanup": false
}
```

| Key           | Type   | Notes                                                                  |
| ------------- | ------ | ---------------------------------------------------------------------- |
| `root`        | string | Directory to analyze. Must exist.                                      |
| `top`         | int    | Number of top-level consumers.                                         |
| `depth`       | int    | Drill-down depth. `0` disables drill-down.                             |
| `output`      | string | Extra output path for the markdown report.                             |
| `jsonReport`  | string | Path for the machine-readable run result.                              |
| `statusFile`  | string | Path for the telemetry status file.                                    |
| `controlFile` | string | Path the script polls for control actions.                             |
| `telemetry`   | bool   | Enable telemetry + control polling.                                    |
| `serial`      | bool   | Scan one directory at a time (the multithreaded scan is the default).  |
| `parallel`    | bool   | Legacy pre-default knob, still honored; `serial` wins if both are set. |
| `skipCleanup` | bool   | Skip the cleanup-candidates scan.                                      |

Every parameter the CLI can set is also settable here, and the CLI always
wins for any parameter it names.

### `control.json` — actions (written by an external process)

During a scan the script polls this file about four times a second; between
phases it re-reads it at each boundary. It is non-blocking: the script never
waits for the file to exist.

```json
{ "action": "stop" }
```

| `action` value | Effect                                                                                                                                                                                      |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `stop`         | Script writes a terminal `stopped` status and exits early (code 0). The markdown report is not generated, but `-JsonReport` is still written with `"stopped": true` and the partial totals. |
| `pause`        | Script blocks, polling every 1 s, until the file says `resume` or `stop`.                                                                                                                   |
| `resume`       | Clears the pause; script continues.                                                                                                                                                         |

The file may also carry optional overrides (applied when the key is present):

```json
{ "action": "pause", "depth": 3, "top": 5 }
```

| Key     | Type | Effect                                                   |
| ------- | ---- | -------------------------------------------------------- |
| `depth` | int  | Overrides drill-down depth for the remainder of the run. |
| `top`   | int  | Overrides the top-N count.                               |

Delete or truncate the file to reset; the script simply skips missing or
empty files.

### `status.json` — live telemetry (written by the script)

Written atomically (write to `.tmp`, then rename) so a poller never sees a
partial document. Only written when `-Telemetry` is set.

```json
{
  "pid": 12345,
  "startTime": "2026-09-04T04:42:14.0645899-04:00",
  "timestamp": "2026-09-04T04:42:46.8283503-04:00",
  "phase": "measuring",
  "current": "Windows",
  "itemsDone": 1,
  "itemsTotal": 32,
  "bytesCounted": 10737418240,
  "filesCounted": 45000,
  "elapsedSeconds": 32.8,
  "message": "Measuring Windows : 45000 files, 10737418240 bytes"
}
```

| Field            | Type              | Notes                                                                                                                        |
| ---------------- | ----------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `pid`            | int               | PID of the PowerShell process.                                                                                               |
| `startTime`      | string (ISO 8601) | When the run started.                                                                                                        |
| `timestamp`      | string (ISO 8601) | When this status was written.                                                                                                |
| `phase`          | string            | `start` → `top-scan-start` → `top-scan` / `measuring` → `top-scan-done` → `cleanup-scan` → `done` (or `stopped` / `paused`). |
| `current`        | string            | Directory currently being measured (empty outside a measurement).                                                            |
| `itemsDone`      | int               | Top-level directories completed.                                                                                             |
| `itemsTotal`     | int               | Total top-level directories to scan.                                                                                         |
| `bytesCounted`   | int               | Running byte total across everything measured so far this run.                                                               |
| `filesCounted`   | int               | Running file count across everything measured so far this run.                                                               |
| `elapsedSeconds` | float             | Seconds since `startTime`.                                                                                                   |
| `message`        | string            | Human-readable status.                                                                                                       |

### `out.json` — machine-readable run result (`-JsonReport`)

Written after the markdown report is emitted, and also on the early-stop path
so a driver always has a document to read — check `stopped` to tell the two
apart. On a stopped run `cleanupCandidates` is empty and the totals are
partial.

```json
{
  "summary": {
    "topN": 2,
    "root": "C:\\",
    "host": "COV-ROG",
    "date": "2026-09-04T04:52:54.0000000-04:00"
  },
  "topConsumers": [
    { "name": "Windows", "sizeMB": 24530.12, "allocMB": 23901.4 },
    { "name": "Users",   "sizeMB": 18432.55, "allocMB": 18102.3 }
  ],
  "cleanupCandidates": [
    { "label": "User TEMP (C:\\Users\\folar\\AppData\\Local\\Temp)", "mb": 1024.5, "allocMB": 1020.1, "present": true },
    { "label": "Recycle Bin", "mb": 0, "allocMB": 0, "present": false }
  ],
  "grandTotalMB": 48210.77,
  "grandTotalAllocMB": 47500.3,
  "stopped": false
}
```

### Worked example: external process drives a scan

```bash
#!/usr/bin/env bash
# 1. Pre-configure the run
ROOT="C:\Coding\rivaborn\spaceanalysis"
cat > "$ROOT/settings.json" <<'JSON'
{"root":"C:\\","top":10,"depth":2}
JSON

# 2. Launch the scan with telemetry + JSON result
powershell -NoProfile -ExecutionPolicy Bypass -File "$ROOT/analyze-disk.ps1" \
  -Settings "$ROOT/settings.json" \
  -Telemetry \
  -StatusFile "$ROOT/status.json" \
  -ControlFile "$ROOT/control.json" \
  -JsonReport "$ROOT/out.json" &
PID=$!

# 3. Poll status every 2 s while running
while kill -0 "$PID" 2>/dev/null; do
  sleep 2
  python3 -c "import json; d = json.load(open('$ROOT/status.json')); print(d['phase'], d['current'], d['filesCounted'])" 2>/dev/null
done
wait "$PID"

# 4. Read the result
python3 -c "import json; d = json.load(open('$ROOT/out.json')); print(d['summary'], d['grandTotalMB'], d['stopped'])"

# 5. To stop mid-scan, from another terminal:
echo '{"action":"stop"}' > "$ROOT/control.json"
# 6. To pause and resume:
echo '{"action":"pause"}'  > "$ROOT/control.json"
# ... later ...
echo '{"action":"resume"}' > "$ROOT/control.json"
```

## Tests

`tests/analyze-disk.tests.ps1` is a self-contained harness (no Pester). It
builds synthetic fixtures under `%TEMP%`, runs the script as a child process,
asserts on the markdown and JSON output, and cleans up after itself.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/analyze-disk.tests.ps1
```

It exits 0 when every check passes, 1 otherwise. Coverage: single-pass
aggregation, junction skipping, drill-down breadth/depth bounds,
physical-vs-logical reporting, parallel-equals-serial, telemetry and control
stop, settings-file precedence, root validation, compiled-scanner-equals-
fallback, deterministic ordering of equal-sized siblings, and cleanup-candidate
sizes.

## Safety

The script performs **no deletion or modification** of any kind. It is a
single-shot, read-only process that only enumerates file-system metadata and
reports results. The cleanup hints in the report (e.g.
`Remove-Item ... -Recurse -Force`, `Clear-RecycleBin`) are suggestions only —
review them before running them, since they are destructive when executed.

The script also does not follow directory reparse points (junctions and
symbolic links), so it will never loop or double-count a path that is
reachable through multiple links.
