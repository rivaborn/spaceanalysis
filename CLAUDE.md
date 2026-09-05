# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-file Windows PowerShell tool. `analyze-disk.ps1` (~1200 lines) is the
entire product; `tests/analyze-disk.tests.ps1` is the entire test suite. There
is no build step, no package manifest, and no dependencies beyond Windows
PowerShell 5.1 and .NET Framework.

Target runtime is **Windows PowerShell 5.1**, not PowerShell 7. No
`ForEach-Object -Parallel`, no ternary/null-coalescing operators, no
`-AsHashtable`. Concurrency comes from .NET (`System.Threading.Tasks`) inside
the compiled scanner.

## Commands

```powershell
# Full test suite — exits 0 on success, 1 on any failure
powershell -NoProfile -ExecutionPolicy Bypass -File tests/analyze-disk.tests.ps1

# Run the tool. Parallel is the default; -Serial opts out,
# -SkipCleanup omits the fixed-cost scan of TEMP/package caches.
powershell -NoProfile -ExecutionPolicy Bypass -File analyze-disk.ps1 `
  -Root 'C:\' -Top 20 -Depth 2 -Output .\report.md

# Force the PowerShell fallback walk instead of the compiled scanner
$env:ANALYZE_DISK_NO_FASTSCAN = '1'

# Syntax check without executing
powershell -NoProfile -Command "`$e=`$null; [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\analyze-disk.ps1).Path,[ref]`$null,[ref]`$e); `$e"
```

The harness has **no test-selection flag**. Tests are numbered top-to-bottom
blocks (`# TEST 7: ...`) sharing helper functions defined at the top. To iterate
on one, comment out the others' blocks locally — don't commit that. Fixtures are
built under `%TEMP%\adisk_test_<random>` and deleted at the end, so a failed run
that aborts early can leave one behind.

## Architecture

### Two implementations of the same walk

This is the single most important thing to know. The recursive size walk exists
**twice**, and both must produce byte-identical results:

- `DiskScan.Scanner` — a C# type compiled at startup via `Add-Type`, embedded as
  a here-string near the top of the script. This is the fast path and where all
  real work happens.
- `Get-SizeTreeNode` — a PowerShell fallback used only when `Add-Type` cannot
  compile (host without a C# compiler).

Test 9 runs the same fixture through both and asserts the JSON matches. **Any
change to walk semantics must be made in both places**, or that test fails.

The two produce structurally identical nodes — a C# class and a
`[pscustomobject]` with the same members — and every consumer downstream
(`Expand-Tree`, ranking, the report, the JSON) is duck-typed against that shape:

```
Name, Path, OwnBytes, TotalBytes, OwnAllocBytes, TotalAllocBytes, FileCount, Children
```

`Own*` is this-directory-only; `Total*` is recursive. Adding a member means
adding it to both node producers.

### One scan entry point

`Invoke-TreeScan -Paths <string[]> -KeepChildren <int>` is the only way anything
gets scanned — top-level branches and cleanup-candidate directories both go
through it. It picks fast vs. fallback, serial vs. parallel, and sync vs.
background-task-with-polling. Don't add a second scanning route.

### Memory pruning changes what the tree contains

`KeepChildren` drops `Children` arrays deeper than the drill-down can reach
(`Depth + 1` levels). Totals stay exact at every depth; only child *detail*
disappears. This is what keeps a full `C:\` scan at ~160 MB instead of ~800 MB.

The consequence: a control-file `depth` override larger than what was retained
would silently print "(no subdirectories)" for branches that do have children.
There is a clamp guarding this — keep it if you touch `$effectiveDepth`.

### Telemetry is a background scan plus a polling main thread

With `-Telemetry`, `Invoke-TreeScan` calls `ScanManyAsync` and the main thread
loops on `$task.Wait(250)`, writing `status.json` and re-reading `control.json`
each tick. Stop/pause are `volatile` statics inside the scanner that the walk
checks per directory entry, mirrored from PowerShell by `Read-Once-Control`.

`ResetCounters()` deliberately resets *only* the progress counters — `Stop` and
`Paused` are owned by the PowerShell side, because a control file may already
say `stop` before the first scan begins. Don't "helpfully" reset them there.

### File-based automation contract

Four JSON documents (`settings.json`, `control.json`, `status.json`, and the
`-JsonReport` output) are the external API, fully specified in README.md with
field tables. External processes are documented as depending on these shapes —
changing a field name or its meaning is a breaking change, and README.md must be
updated in the same edit.

## Invariants

- **Read-only.** The script never deletes or modifies anything; cleanup
  suggestions are printed as text only. This is stated in the README, the
  `-Help` output, and the report itself.
- **Reparse points are never traversed** (junctions/symlinks), at every level,
  matching WinDirStat. This prevents loops and double-counting.
- **Physical size comes from `GetCompressedFileSizeW`, per file.** It is ~70% of
  scan time, which makes "round `Length` up to the cluster size instead" very
  tempting. It is wrong — measured on this machine, the two disagree for ~28% of
  ordinary files. Make it faster with concurrency, not arithmetic.
- **Parallel output must equal serial output.** Parallel is the default
  (`-Serial` or settings `parallel=false` opts out; `-Parallel` is kept for
  compatibility). Children
  are collected by discovery index and sorted with an ordinal path tiebreak so
  equal-sized siblings always order the same way. Test 5 and test 10 enforce
  this.

## Gotchas

- A child `powershell.exe` writes its **warning stream to stdout**, not stderr.
  Test assertions about `Write-Warning` output must check both streams.
- Don't put benchmark fixtures under `%TEMP%` — the cleanup-candidate scan walks
  `$env:TEMP` on every run, so fixtures there inflate the measured baseline and
  make before/after comparisons meaningless. For benchmarks and tests that don't
  assert on cleanup output, pass `-SkipCleanup` (most of the suite does).
- User-supplied paths (`-Output`, `-JsonReport`, `-StatusFile`, `-ControlFile`)
  are normalized against the PowerShell location at startup via
  `Resolve-UserPath`, because .NET file APIs resolve relative paths against the
  process CWD, which differs in-session after `Set-Location`. Any new
  user-facing path parameter must go through the same normalization.
- `.pi/plans/` holds the step-by-step plan files that drove earlier work. They
  are historical records of intent, not current specifications.
