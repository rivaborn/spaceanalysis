# spaceanalysis

`analyze-disk.ps1` reviews disk space usage on a Windows system and recommends
ways to free up space. It is a PowerShell script that is **strictly
read-only**: it reports sizes and suggests cleanups, but never modifies or
deletes anything.

## What it produces

A single cohesive markdown report with four sections:

1. **System summary** — host name, PowerShell version, run date, root, top-N
   and depth settings, and the drive's total/used/free space.
2. **Top space consumers** — the root's direct child directories ranked by
   recursive size, descending.
3. **Drill-down** — a bounded walk into the top consumers (up to `-Depth`
   levels, at most 10 branches expanded per level) showing which
   subdirectories drive the big usage. Branches that were not expanded
   recursively are marked `(this level only)`.
4. **Cleanup candidates** — well-known Windows waste locations (user TEMP,
   Windows Temp, Recycle Bin, Windows Update download cache, Windows
   Installer, pip/npm/NuGet caches) with their reclaimable size and a
   suggested safe cleanup command. Missing locations are reported as
   `not present`.

The report is printed to the console and, when `-Output` is given, also
written to that file (UTF-8).

## Efficient methodology

Reading every file and folder on a drive can take hours. Instead:

- **Metadata only.** The script enumerates file names and sizes (`Length`).
  File contents are never opened, so a recursive pass is just a metadata
  walk — orders of magnitude faster than reading data.
- **One pass per analyzed directory.** Each measured directory is scanned
  exactly once with
  `Get-ChildItem -File -Recurse | Measure-Object Length`; nothing is
  re-scanned to compute the grand total (it is derived from the per-directory
  measurements plus the root's loose files).
- **Top-down, bounded drill-down.** Direct children of the root are ranked
  first; only the largest consumers are expanded, at most 10 per level, up
  to `-Depth` levels. Smaller branches are shown with a cheap
  non-recursive size. This finds the big space hogs without an exhaustive
  full-tree scan, keeping runtime bounded.

## Usage

```powershell
# Default: analyze C:\, top 20, drill 2 levels, print to console
powershell -NoProfile -ExecutionPolicy Bypass -File analyze-disk.ps1

# Custom root, top 10, 3-level drill-down, also write report.md
powershell -NoProfile -ExecutionPolicy Bypass -File analyze-disk.ps1 `
  -Root 'C:\Users\folar' -Top 10 -Depth 3 -Output .\report.md

# Show help
powershell -NoProfile -ExecutionPolicy Bypass -File analyze-disk.ps1 -Help
```

| Parameter | Default | Description |
| --- | --- | --- |
| `-Root` | `C:\` | Path to analyze. |
| `-Top` | `20` | Number of top-level consumers to rank and drill into. |
| `-Depth` | `2` | Drill-down depth into top consumers, in levels. |
| `-Output` | none | Also write the markdown report to this file. |
| `-Help` | | Print usage and exit. |

## CLI / automation

Besides the basic scan parameters, the script exposes four parameters that let
an external process pre-configure or observe a run through plain JSON files on
the filesystem. No pipes, sockets, or daemons are needed — the script is a
single-shot, single-threaded process, so file-based JSON is the natural IPC.

### Parameters

| Parameter | Default | Description |
| --- | --- | --- |
| `-Settings <json>` | none | Path to a JSON run-config file (see schema below). CLI parameters take precedence over settings-file values. |
| `-StatusFile <json>` | `status.json` | Where the script writes live telemetry (see schema below). Written **only** when `-Telemetry` is set. |
| `-ControlFile <json>` | `control.json` | Where an external process writes control actions (see schema below). Read **only** when `-Telemetry` is set. |
| `-Telemetry` | off | Switch. When set, the script writes the status file and polls the control file at directory boundaries and every 20 000 files during a scan. |
| `-JsonReport <file>` | none | Path for a machine-readable JSON run result (see schema below). Written after the markdown report is emitted. |

### `settings.json` — run configuration

An external process writes this file **before** launching the script. Only
keys that are present are applied; any key the CLI already specifies is
ignored (CLI wins).

```json
{
  "root":  "C:\",
  "top":   20,
  "depth": 2,
  "output": "C:\reports\disk.md"
}
```

| Key | Type | Notes |
| --- | --- | --- |
| `root` | string | Path to analyze. Must exist. |
| `top` | int | Number of top-level consumers. |
| `depth` | int | Drill-down depth. `0` disables drill-down. |
| `output` | string | Extra output path for the markdown report. |

`jsonReport` is **not** read from settings.json; use the `-JsonReport` CLI
flag instead.

### `control.json` — actions (written by an external process)

The script reads this file at every top-level directory boundary and every
20 000 files during a tracked scan. It is non-blocking: the script never
waits for the file to exist.

```json
{ "action": "stop" }
```

| `action` value | Effect |
| --- | --- |
| `stop` | Script writes a terminal `stopped` status and exits early (code 0). No report is generated. |
| `pause` | Script blocks, polling every 1 s, until the file says `resume` or `stop`. |
| `resume` | Clears the pause; script continues. |

The file may also carry optional overrides (applied when the key is present):

```json
{ "action": "pause", "depth": 3, "top": 5 }
```

| Key | Type | Effect |
| --- | --- | --- |
| `depth` | int | Overrides drill-down depth for the remainder of the run. |
| `top` | int | Overrides the top-N count. |

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

| Field | Type | Notes |
| --- | --- | --- |
| `pid` | int | PID of the PowerShell process. |
| `startTime` | string (ISO 8601) | When the run started. |
| `timestamp` | string (ISO 8601) | When this status was written. |
| `phase` | string | `start` → `top-scan-start` → `top-scan` / `measuring` → `top-scan-done` → `done` (or `stopped` / `paused`). |
| `current` | string | Directory currently being measured (empty outside a measurement). |
| `itemsDone` | int | Top-level directories completed. |
| `itemsTotal` | int | Total top-level directories to scan. |
| `bytesCounted` | int | Running byte total for the current measured directory (tracked path only). |
| `filesCounted` | int | Running file count for the current measured directory (tracked path only). |
| `elapsedSeconds` | float | Seconds since `startTime`. |
| `message` | string | Human-readable status. |

### `out.json` — machine-readable run result (`-JsonReport`)

Written after the markdown report is emitted (or skipped on early stop).

```json
{
  "summary": {
    "topN": 2,
    "root": "C:\",
    "host": "COV-ROG",
    "date": "2026-09-04T04:52:54.0000000-04:00"
  },
  "topConsumers": [
    { "name": "Windows", "sizeMB": 24530.12 },
    { "name": "Users",   "sizeMB":  18432.55 }
  ],
  "cleanupCandidates": [
    { "label": "User TEMP (C:\\Users\\folar\\AppData\\Local\\Temp)", "mb": 1024.5, "present": true },
    { "label": "Recycle Bin", "mb": 0, "present": false }
  ],
  "grandTotalMB": 48210.77,
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
  python3 -c "import json;d=json.load(open('$ROOT/status.json'));\" \
            "print(d['phase'], d['current'], d['filesCounted'])"
done
wait "$PID"

# 4. Read the result
python3 -c "import json;d=json.load(open('$ROOT/out.json'));\" \
           "print(d['summary'], d['grandTotalMB'], d['stopped'])"

# 5. To stop mid-scan, from another terminal:
echo '{"action":"stop"}' > "$ROOT/control.json"
# 6. To pause and resume:
echo '{"action":"pause"}'  > "$ROOT/control.json"
# ... later ...
echo '{"action":"resume"}' > "$ROOT/control.json"
```

## Safety

The script performs **no deletion or modification** of any kind. The cleanup
hints in the report (e.g. `Remove-Item ... -Recurse -Force`,
`Clear-RecycleBin`) are suggestions only — review them before running them,
since they are destructive when executed.
