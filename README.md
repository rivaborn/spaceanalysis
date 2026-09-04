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

## Safety

The script performs **no deletion or modification** of any kind. The cleanup
hints in the report (e.g. `Remove-Item ... -Recurse -Force`,
`Clear-RecycleBin`) are suggestions only — review them before running them,
since they are destructive when executed.
