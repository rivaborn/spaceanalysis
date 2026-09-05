# analyze-disk.tests.ps1
# Self-contained test harness for analyze-disk.ps1 (no Pester dependency).
# Builds synthetic fixtures, runs the script, asserts expected behaviour, cleans up.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/analyze-disk.tests.ps1
# Exits 0 if all checks pass, 1 otherwise.

$ErrorActionPreference = 'Stop'
$TestFailures = 0
$TestCount    = 0

# --- Helpers -----------------------------------------------------------

function Test-Assert {
    param(
        [string]   $Name,
        [bool]     $Condition,
        [string]   $Detail = ''
    )
    $script:TestCount++
    if ($Condition) {
        Write-Host "  PASS: $Name"
    } else {
        Write-Host "  FAIL: $Name $Detail"
        $script:TestFailures++
    }
}

function New-FixtureFile {
    param([string]$Path, [long]$Bytes)
    $fs = [System.IO.File]::Create($Path)
    try {
        if ($Bytes -gt 0) {
            $buf = New-Object byte[] 65536
            $written = 0
            while ($written -lt $Bytes) {
                $chunk = [Math]::Min(65536, [int]($Bytes - $written))
                $fs.Write($buf, 0, $chunk)
                $written += $chunk
            }
        }
    } finally { $fs.Dispose() }
}

function New-SparseFile {
    param([string]$Path, [long]$LogicalBytes)
    $fs = [System.IO.File]::Create($Path)
    try { $fs.SetLength($LogicalBytes) } finally { $fs.Dispose() }
}

function ConvertTo-CmdArg {
    # Quote an argument per CommandLineToArgvW rules so a path with spaces (or
    # a trailing backslash, which would otherwise escape the closing quote)
    # survives the child's command line.
    param([string]$Value)
    if ($Value -match '^[-\w:\\/.]+$') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'      # double backslashes before a quote, escape the quote
    if ($escaped -match '(\\+)$') { $escaped += $Matches[1] }  # double trailing backslashes
    return '"' + $escaped + '"'
}

function Invoke-AnalyzeDisk {
    param(
        [string[]]$ExtraArgs = @(),
        [hashtable]$Environment = @{}
    )
    $allArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $ExtraArgs
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo.FileName    = 'powershell.exe'
    $proc.StartInfo.Arguments   = (($allArgs | ForEach-Object { ConvertTo-CmdArg $_ }) -join ' ')
    $proc.StartInfo.UseShellExecute = $false
    $proc.StartInfo.RedirectStandardOutput = $true
    $proc.StartInfo.RedirectStandardError  = $true
    $proc.StartInfo.CreateNoWindow = $true
    foreach ($k in $Environment.Keys) { $proc.StartInfo.EnvironmentVariables[$k] = [string]$Environment[$k] }
    [void]$proc.Start()
    # Read stdout on a background task: draining one stream to completion before
    # touching the other deadlocks as soon as the child fills the stderr pipe.
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $stderr  = $proc.StandardError.ReadToEnd()
    $stdout  = $outTask.Result
    if (-not $proc.WaitForExit(180000)) {
        try { $proc.Kill() } catch {}
        return @{ ExitCode = -1; StdOut = $stdout; StdErr = "TIMEOUT`n$stderr" }
    }
    return @{
        ExitCode = $proc.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

function Get-Json {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    } catch { return $null }
}

# --- Setup -------------------------------------------------------------

$RepoRoot    = Split-Path -Parent $PSScriptRoot
$ScriptPath  = Join-Path $RepoRoot 'analyze-disk.ps1'
$FixtureRoot = Join-Path $env:TEMP "adisk_test_$(Get-Random)"

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Host "FATAL: cannot find $ScriptPath"
    exit 1
}

try { New-Item -ItemType Directory -Path $FixtureRoot -Force | Out-Null }
catch {
    Write-Host "FATAL: cannot create fixture dir $FixtureRoot : $_"
    exit 1
}

Write-Host "Fixture root: $FixtureRoot"
Write-Host "Script under test: $ScriptPath"
Write-Host ""

# =====================================================================
# TEST 1: Single-pass aggregation (sizes and counts)
# =====================================================================
Write-Host "[Test 1] Single-pass aggregation sizes/counts"

$fix1 = Join-Path $FixtureRoot 't1'
New-Item -ItemType Directory -Path (Join-Path $fix1 'd1') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fix1 'd2') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fix1 'd3') -Force | Out-Null
New-FixtureFile (Join-Path $fix1 'd1\a.bin') 1048576
New-FixtureFile (Join-Path $fix1 'd2\b.bin') 2097152
New-FixtureFile (Join-Path $fix1 'd3\c.bin') 3145728
New-FixtureFile (Join-Path $fix1 'root.bin') 102400

$r1 = Invoke-AnalyzeDisk -ExtraArgs @(
    '-Root', $fix1, '-Top', '10', '-Depth', '0',
    '-JsonReport', (Join-Path $fix1 'report.json')
)
$j1 = Get-Json (Join-Path $fix1 'report.json')

Test-Assert "t1: script exited 0" ($r1.ExitCode -eq 0) "exit=$($r1.ExitCode) err=$($r1.Stderr.Trim())"
Test-Assert "t1: JSON report exists" ($null -ne $j1)
if ($j1) {
    $expectedTotal = [math]::Round((1048576 + 2097152 + 3145728 + 102400) / 1MB, 2)
    Test-Assert "t1: grandTotalMB matches expected" ($j1.grandTotalMB -eq $expectedTotal) "got $($j1.grandTotalMB), want $expectedTotal"
    Test-Assert "t1: topConsumers has 3 entries" ($j1.topConsumers.Count -eq 3) "got $($j1.topConsumers.Count)"
    if ($j1.topConsumers.Count -ge 3) {
        Test-Assert "t1: top consumer is d3" ($j1.topConsumers[0].name -eq 'd3') "got $($j1.topConsumers[0].name)"
        Test-Assert "t1: d3 sizeMB is 3" ($j1.topConsumers[0].sizeMB -eq 3) "got $($j1.topConsumers[0].sizeMB)"
        Test-Assert "t1: d2 sizeMB is 2" ($j1.topConsumers[1].sizeMB -eq 2) "got $($j1.topConsumers[1].sizeMB)"
        Test-Assert "t1: d1 sizeMB is 1" ($j1.topConsumers[2].sizeMB -eq 1) "got $($j1.topConsumers[2].sizeMB)"
    }
}
Write-Host ""

# =====================================================================
# TEST 2: Reparse-point / junction skipping
# =====================================================================
Write-Host "[Test 2] Reparse-point (junction) skipping"

$fix2 = Join-Path $FixtureRoot 't2'
New-Item -ItemType Directory -Path (Join-Path $fix2 'real') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fix2 'empty') -Force | Out-Null
New-FixtureFile (Join-Path $fix2 'real\data.bin') 1048576
New-FixtureFile (Join-Path $fix2 'empty\x.bin')    524288

$linkPath = Join-Path $fix2 'link'
$realPath = Join-Path $fix2 'real'
$null = cmd /c "mklink /J `"$linkPath`" `"$realPath`"" 2>&1
$reparse = [int][System.IO.FileAttributes]::ReparsePoint
$junctionOk = (Test-Path -LiteralPath $linkPath) -and
              ([int](Get-Item -LiteralPath $linkPath -Force).Attributes -band $reparse)
Test-Assert "t2: junction fixture created" $junctionOk "mklink /J did not produce a reparse point; the rest of test 2 proves nothing"

$r2 = Invoke-AnalyzeDisk -ExtraArgs @(
    '-Root', $fix2, '-Top', '10', '-Depth', '0', '-SkipCleanup',
    '-JsonReport', (Join-Path $fix2 'report.json')
)
$j2 = Get-Json (Join-Path $fix2 'report.json')

Test-Assert "t2: script exited 0" ($r2.ExitCode -eq 0) "exit=$($r2.ExitCode)"
if ($j2) {
    $expected = [math]::Round((1048576 + 524288) / 1MB, 2)
    Test-Assert "t2: grandTotalMB excludes junction" ($j2.grandTotalMB -eq $expected) "got $($j2.grandTotalMB), want $expected"
    $linkNames = @($j2.topConsumers | Where-Object { $_.name -eq 'link' })
    Test-Assert "t2: junction not in topConsumers" ($linkNames.Count -eq 0) "junction appeared as consumer"
}
Write-Host ""

# =====================================================================
# TEST 3: Drill-down breadth/depth bounds
# =====================================================================
Write-Host "[Test 3] Drill-down breadth/depth bounds"

$fix3 = Join-Path $FixtureRoot 't3'
$bigDir = Join-Path $fix3 'big'
New-Item -ItemType Directory -Path $bigDir -Force | Out-Null
for ($i = 1; $i -le 15; $i++) {
    $sub = Join-Path $bigDir "sub$i"
    New-Item -ItemType Directory -Path $sub -Force | Out-Null
    New-FixtureFile (Join-Path $sub "f.bin") 1048576
}
New-Item -ItemType Directory -Path (Join-Path $bigDir 'sub1\inner') -Force | Out-Null
New-FixtureFile (Join-Path $bigDir 'sub1\inner\g.bin') 1048576

$r3a = Invoke-AnalyzeDisk -ExtraArgs @(
    '-Root', $fix3, '-Top', '5', '-Depth', '0', '-SkipCleanup',
    '-JsonReport', (Join-Path $fix3 'r0.json')
)
Test-Assert "t3a: Depth 0 has no Drill-down section" ($r3a.StdOut -notmatch '## Drill-down') "found drill-down in depth-0 output"

$r3b = Invoke-AnalyzeDisk -ExtraArgs @(
    '-Root', $fix3, '-Top', '5', '-Depth', '2', '-SkipCleanup',
    '-Output', (Join-Path $fix3 'report.md')
)
$md3 = ''
if (Test-Path (Join-Path $fix3 'report.md')) {
    $md3 = Get-Content (Join-Path $fix3 'report.md') -Raw
} else { $md3 = $r3b.StdOut }

Test-Assert "t3b: Depth 2 has Drill-down section" ($md3 -match '## Drill-down') "missing drill-down section"
$levelOnlyCount = [regex]::Matches($md3, 'this level only').Count
Test-Assert "t3b: breadth bounded (6 non-expanded: 5 at L1 + 1 at L2)" ($levelOnlyCount -eq 6) "got $levelOnlyCount non-expanded, want 6"

Test-Assert "t3c: Depth 2 shows level-2 child dir" ($md3 -match 'inner') "inner dir not found in depth-2 output"
Write-Host ""

# =====================================================================
# TEST 4: Physical vs logical size reporting
# =====================================================================
Write-Host "[Test 4] Physical-vs-logical size reporting"

$fix4 = Join-Path $FixtureRoot 't4'
New-Item -ItemType Directory -Path (Join-Path $fix4 'files') -Force | Out-Null
New-FixtureFile (Join-Path $fix4 'files\regular.bin') 4194304
New-SparseFile (Join-Path $fix4 'files\sparse.bin') 67108864

$r4 = Invoke-AnalyzeDisk -ExtraArgs @(
    '-Root', $fix4, '-Top', '5', '-Depth', '0', '-SkipCleanup',
    '-JsonReport', (Join-Path $fix4 'report.json')
)
$j4 = Get-Json (Join-Path $fix4 'report.json')

Test-Assert "t4: script exited 0" ($r4.ExitCode -eq 0) "exit=$($r4.ExitCode)"
if ($j4) {
    $expectedLogical = [math]::Round((4194304 + 67108864) / 1MB, 2)
    Test-Assert "t4: grandTotalMB reflects logical size" ($j4.grandTotalMB -eq $expectedLogical) "got $($j4.grandTotalMB), want $expectedLogical"
    Test-Assert "t4: grandTotalAllocMB is numeric" ($null -ne $j4.grandTotalAllocMB) "allocMB missing"
    Test-Assert "t4: allocMB is less than or equal to logicalMB" ($j4.grandTotalAllocMB -le $j4.grandTotalMB) "alloc=$($j4.grandTotalAllocMB) logical=$($j4.grandTotalMB)"
}
Write-Host ""

# =====================================================================
# TEST 5: Parallel == serial
# =====================================================================
Write-Host "[Test 5] Parallel equals serial"

$fix5 = Join-Path $FixtureRoot 't5'
for ($i = 1; $i -le 4; $i++) {
    New-Item -ItemType Directory -Path (Join-Path $fix5 "d$i") -Force | Out-Null
    New-FixtureFile (Join-Path $fix5 "d$i\f.bin") ($i * 1048576)
}

$r5s = Invoke-AnalyzeDisk -ExtraArgs @(
    '-Root', $fix5, '-Top', '5', '-Depth', '0', '-SkipCleanup', '-Serial',
    '-JsonReport', (Join-Path $fix5 'serial.json')
)
$j5s = Get-Json (Join-Path $fix5 'serial.json')

$r5p = Invoke-AnalyzeDisk -ExtraArgs @(
    '-Root', $fix5, '-Top', '5', '-Depth', '0', '-Parallel', '-SkipCleanup',
    '-JsonReport', (Join-Path $fix5 'parallel.json')
)
$j5p = Get-Json (Join-Path $fix5 'parallel.json')

Test-Assert "t5: serial exited 0" ($r5s.ExitCode -eq 0) "exit=$($r5s.ExitCode)"
Test-Assert "t5: parallel exited 0" ($r5p.ExitCode -eq 0) "exit=$($r5p.ExitCode) err=$($r5p.Stderr.Trim())"
Test-Assert "t5: -Serial suppresses the parallel banner" ($r5s.StdOut -notmatch '\[parallel\]') "banner shown in serial run"
Test-Assert "t5: parallel run shows the banner" ($r5p.StdOut -match '\[parallel\]') "no banner in parallel run"

# Parallel is now the DEFAULT: a run with no mode switch must scan in parallel
# and produce the same numbers.
$r5d = Invoke-AnalyzeDisk -ExtraArgs @(
    '-Root', $fix5, '-Top', '5', '-Depth', '0', '-SkipCleanup',
    '-JsonReport', (Join-Path $fix5 'default.json')
)
$j5d = Get-Json (Join-Path $fix5 'default.json')
Test-Assert "t5: default run is parallel" ($r5d.StdOut -match '\[parallel\]') "no banner on default run"
if ($j5d -and $j5s) {
    Test-Assert "t5: default equals serial" ($j5d.grandTotalMB -eq $j5s.grandTotalMB) "default=$($j5d.grandTotalMB) serial=$($j5s.grandTotalMB)"
}

# Back-compat: -Parallel:$false still means serial. PowerShell 5.1's -File
# mode cannot pass $false to a switch, so invoke in-session like a dot-caller.
$r5cOut = & powershell -NoProfile -ExecutionPolicy Bypass -Command (
    "& '$ScriptPath' -Root '$fix5' -Top 5 -Depth 0 -SkipCleanup -Parallel:`$false"
) | Out-String
Test-Assert "t5: -Parallel:`$false opts out (in-session)" ($r5cOut -match 'Top space' -and $r5cOut -notmatch '\[parallel\]') "banner shown or no report"

# Back-compat: settings parallel=false still means serial.
$set5 = Join-Path $fix5 'serial-settings.json'
@{ parallel = $false } | ConvertTo-Json | Set-Content -LiteralPath $set5 -Encoding UTF8
$r5e = Invoke-AnalyzeDisk -ExtraArgs @(
    '-Root', $fix5, '-Top', '5', '-Depth', '0', '-SkipCleanup', '-Settings', $set5
)
Test-Assert "t5: settings parallel=false opts out" ($r5e.ExitCode -eq 0 -and $r5e.StdOut -notmatch '\[parallel\]') "banner shown or exit=$($r5e.ExitCode)"

if ($j5s -and $j5p) {
    Test-Assert "t5: grandTotalMB identical" ($j5s.grandTotalMB -eq $j5p.grandTotalMB) "serial=$($j5s.grandTotalMB) parallel=$($j5p.grandTotalMB)"
    Test-Assert "t5: grandTotalAllocMB identical" ($j5s.grandTotalAllocMB -eq $j5p.grandTotalAllocMB) "serial=$($j5s.grandTotalAllocMB) parallel=$($j5p.grandTotalAllocMB)"
    $sKey = ($j5s.topConsumers | ForEach-Object { "$($_.name):$($_.sizeMB):$($_.allocMB)" }) -join ';'
    $pKey = ($j5p.topConsumers | ForEach-Object { "$($_.name):$($_.sizeMB):$($_.allocMB)" }) -join ';'
    Test-Assert "t5: topConsumers identical" ($sKey -eq $pKey) "serial=$sKey | parallel=$pKey"
}
Write-Host ""

# =====================================================================
# TEST 6: Telemetry / control
# =====================================================================
Write-Host "[Test 6] Telemetry writes status.json + control stop aborts"

$fix6 = Join-Path $FixtureRoot 't6'
for ($i = 1; $i -le 3; $i++) {
    New-Item -ItemType Directory -Path (Join-Path $fix6 "dir$i") -Force | Out-Null
    New-FixtureFile (Join-Path $fix6 "dir$i\f.bin") 2097152
}

$statusFile  = Join-Path $fix6 'status.json'
$controlFile = Join-Path $fix6 'control.json'

$r6a = Invoke-AnalyzeDisk -ExtraArgs @(
    '-Root', $fix6, '-Top', '5', '-Depth', '0', '-SkipCleanup',
    '-Telemetry',
    '-StatusFile', $statusFile,
    '-ControlFile', $controlFile,
    '-JsonReport', (Join-Path $fix6 'report.json')
)
Test-Assert "t6a: telemetry run exited 0" ($r6a.ExitCode -eq 0) "exit=$($r6a.ExitCode)"
Test-Assert "t6a: status.json exists" (Test-Path -LiteralPath $statusFile) "status file not found"
if (Test-Path -LiteralPath $statusFile) {
    $st = Get-Json $statusFile
    Test-Assert "t6a: status.json has phase field" ($null -ne $st.phase) "phase missing"
    Test-Assert "t6a: final phase is done" ($st.phase -eq 'done') "phase=$($st.phase)"
    Test-Assert "t6a: filesCounted positive" ($st.filesCounted -gt 0) "filesCounted=$($st.filesCounted)"
    Test-Assert "t6a: bytesCounted positive" ($st.bytesCounted -gt 0) "bytesCounted=$($st.bytesCounted)"
    Test-Assert "t6a: itemsDone equals itemsTotal" ($st.itemsDone -eq $st.itemsTotal) "done=$($st.itemsDone) total=$($st.itemsTotal)"
}
Write-Host ""

# --- 6b: Control stop aborts early ---
$fix6b = Join-Path $FixtureRoot 't6b'
for ($i = 1; $i -le 3; $i++) {
    New-Item -ItemType Directory -Path (Join-Path $fix6b "dir$i") -Force | Out-Null
    New-FixtureFile (Join-Path $fix6b "dir$i\f.bin") 2097152
}
$statusFileB  = Join-Path $fix6b 'status.json'
$controlFileB = Join-Path $fix6b 'control.json'

[System.IO.File]::WriteAllText($controlFileB, '{"action":"stop"}')

$r6b = Invoke-AnalyzeDisk -ExtraArgs @(
    '-Root', $fix6b, '-Top', '5', '-Depth', '0', '-SkipCleanup',
    '-Telemetry',
    '-StatusFile', $statusFileB,
    '-ControlFile', $controlFileB,
    '-JsonReport', (Join-Path $fix6b 'report.json')
)
Test-Assert "t6b: stop run exited 0" ($r6b.ExitCode -eq 0) "exit=$($r6b.ExitCode)"
Test-Assert "t6b: output mentions Stopped" ($r6b.StdOut -match 'Stopped') "no stop message in output"
if (Test-Path -LiteralPath $statusFileB) {
    $stB = Get-Json $statusFileB
    Test-Assert "t6b: status phase is stopped" ($stB.phase -eq 'stopped') "phase=$($stB.phase)"
    Test-Assert "t6b: itemsDone less than itemsTotal" ($stB.itemsDone -lt $stB.itemsTotal) "done=$($stB.itemsDone) total=$($stB.itemsTotal)"
}
$j6b = Get-Json (Join-Path $fix6b 'report.json')
if ($j6b) {
    Test-Assert "t6b: JSON stopped is true" ($j6b.stopped -eq $true) "stopped=$($j6b.stopped)"
}
Write-Host ""

# =====================================================================
# TEST 7: settings.json is honoured, and CLI parameters win over it
# =====================================================================
Write-Host "[Test 7] settings.json merge precedence"

$fix7 = Join-Path $FixtureRoot 't7'
New-Item -ItemType Directory -Path (Join-Path $fix7 'alpha') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fix7 'beta')  -Force | Out-Null
New-FixtureFile (Join-Path $fix7 'alpha\a.bin') 3145728
New-FixtureFile (Join-Path $fix7 'beta\b.bin')  1048576

$settings7 = Join-Path $fix7 'settings.json'
$json7     = Join-Path $fix7 'from-settings.json'
$out7      = Join-Path $fix7 'from-settings.md'
@{
    root        = $fix7
    top         = 1
    depth       = 0
    output      = $out7
    jsonReport  = $json7
    serial      = $true
    skipCleanup = $true
} | ConvertTo-Json | Set-Content -LiteralPath $settings7 -Encoding UTF8

# No -Root/-Top/-Depth/-Output/-JsonReport on the command line: every value
# below has to come from the settings file.
$r7 = Invoke-AnalyzeDisk -ExtraArgs @('-Settings', $settings7)
Test-Assert "t7: settings-only run exited 0" ($r7.ExitCode -eq 0) "exit=$($r7.ExitCode) err=$($r7.StdErr.Trim())"
$j7 = Get-Json $json7
Test-Assert "t7: jsonReport from settings was written" ($null -ne $j7) "no JSON at $json7"
Test-Assert "t7: output from settings was written" (Test-Path -LiteralPath $out7) "no markdown at $out7"
if ($j7) {
    Test-Assert "t7: root came from settings" ($j7.summary.root -eq $fix7) "got $($j7.summary.root)"
    Test-Assert "t7: top came from settings" ($j7.topConsumers.Count -eq 1) "got $($j7.topConsumers.Count) consumers"
    Test-Assert "t7: depth 0 from settings (no drill-down)" ($r7.StdOut -notmatch '## Drill-down') "drill-down present"
    Test-Assert "t7: serial came from settings" ($r7.StdOut -notmatch '\[parallel\]') "parallel banner despite serial=true"
    Test-Assert "t7: skipCleanup came from settings" ($r7.StdOut -match 'skipped: -SkipCleanup') "cleanup scan ran despite settings"
}

# Same settings file, but -Top on the command line must win.
$json7b = Join-Path $fix7 'cli-wins.json'
$r7b = Invoke-AnalyzeDisk -ExtraArgs @('-Settings', $settings7, '-Top', '2', '-JsonReport', $json7b)
$j7b = Get-Json $json7b
Test-Assert "t7: CLI -Top overrides settings" ($null -ne $j7b -and $j7b.topConsumers.Count -eq 2) "got $($j7b.topConsumers.Count) consumers"
Write-Host ""

# =====================================================================
# TEST 8: root validation
# =====================================================================
Write-Host "[Test 8] Root validation"

$fix8 = Join-Path $FixtureRoot 't8'
New-Item -ItemType Directory -Path $fix8 -Force | Out-Null
$file8 = Join-Path $fix8 'notadir.bin'
New-FixtureFile $file8 1024

$r8a = Invoke-AnalyzeDisk -ExtraArgs @('-Root', (Join-Path $fix8 'does-not-exist'))
Test-Assert "t8a: missing root exits 1" ($r8a.ExitCode -eq 1) "exit=$($r8a.ExitCode)"

$r8b = Invoke-AnalyzeDisk -ExtraArgs @('-Root', $file8)
Test-Assert "t8b: file as root exits 1" ($r8b.ExitCode -eq 1) "exit=$($r8b.ExitCode)"
Test-Assert "t8b: file as root explains why" ($r8b.StdErr -match 'directory') "stderr=$($r8b.StdErr.Trim())"

# 8c: relative -Output/-JsonReport must resolve against the caller's location,
# not the .NET process CWD (they differ when invoked in-session after
# Set-Location). Run in-session with the two deliberately different.
$fix8c = Join-Path $fix8 'relout'
New-Item -ItemType Directory -Path (Join-Path $fix8c 'sub') -Force | Out-Null
New-FixtureFile (Join-Path $fix8c 'sub\f.bin') 4096
$r8c = & powershell -NoProfile -ExecutionPolicy Bypass -Command (
    "[System.IO.Directory]::SetCurrentDirectory('$env:TEMP'); " +
    "Set-Location '$fix8c'; " +
    "& '$ScriptPath' -Root '$fix8c' -Top 3 -Depth 0 -SkipCleanup -Output rel.md -JsonReport rel.json | Out-Null"
)
Test-Assert "t8c: relative -Output lands in the caller's location" (Test-Path (Join-Path $fix8c 'rel.md')) "rel.md not in $fix8c"
Test-Assert "t8c: relative -JsonReport lands in the caller's location" (Test-Path (Join-Path $fix8c 'rel.json')) "rel.json not in $fix8c"
Write-Host ""

# =====================================================================
# TEST 9: PowerShell fallback walk agrees with the compiled scanner
# =====================================================================
Write-Host "[Test 9] Fallback walk matches compiled scanner"

$fix9 = Join-Path $FixtureRoot 't9'
for ($i = 1; $i -le 3; $i++) {
    $sub = Join-Path $fix9 "b$i\deep"
    New-Item -ItemType Directory -Path $sub -Force | Out-Null
    New-FixtureFile (Join-Path $sub "f.bin") ($i * 524288)
    New-FixtureFile (Join-Path $fix9 "b$i\top.bin") 131072
}
New-FixtureFile (Join-Path $fix9 'loose.bin') 65536

$fastJson = Join-Path $fix9 'fast.json'
$slowJson = Join-Path $fix9 'slow.json'
$r9a = Invoke-AnalyzeDisk -ExtraArgs @('-Root', $fix9, '-Top', '5', '-Depth', '2', '-SkipCleanup', '-JsonReport', $fastJson)
$r9b = Invoke-AnalyzeDisk -ExtraArgs @('-Root', $fix9, '-Top', '5', '-Depth', '2', '-SkipCleanup', '-JsonReport', $slowJson) `
                          -Environment @{ ANALYZE_DISK_NO_FASTSCAN = '1' }

Test-Assert "t9: fast path exited 0" ($r9a.ExitCode -eq 0) "exit=$($r9a.ExitCode)"
Test-Assert "t9: fallback path exited 0" ($r9b.ExitCode -eq 0) "exit=$($r9b.ExitCode) err=$($r9b.StdErr.Trim())"
# A child powershell.exe writes its warning stream to stdout, so check both.
Test-Assert "t9: fallback announced itself" (($r9b.StdErr + $r9b.StdOut) -match 'falling back') "no fallback warning"

$j9a = Get-Json $fastJson
$j9b = Get-Json $slowJson
if ($j9a -and $j9b) {
    Test-Assert "t9: grandTotalMB identical" ($j9a.grandTotalMB -eq $j9b.grandTotalMB) "fast=$($j9a.grandTotalMB) fallback=$($j9b.grandTotalMB)"
    Test-Assert "t9: grandTotalAllocMB identical" ($j9a.grandTotalAllocMB -eq $j9b.grandTotalAllocMB) "fast=$($j9a.grandTotalAllocMB) fallback=$($j9b.grandTotalAllocMB)"
    $aKey = ($j9a.topConsumers | ForEach-Object { "$($_.name):$($_.sizeMB):$($_.allocMB)" }) -join ';'
    $bKey = ($j9b.topConsumers | ForEach-Object { "$($_.name):$($_.sizeMB):$($_.allocMB)" }) -join ';'
    Test-Assert "t9: topConsumers identical" ($aKey -eq $bKey) "fast=$aKey | fallback=$bKey"
}
Write-Host ""

# =====================================================================
# TEST 10: equal-sized siblings rank deterministically
# =====================================================================
Write-Host "[Test 10] Deterministic ordering of equal-sized siblings"

$fix10 = Join-Path $FixtureRoot 't10'
foreach ($n in 'delta', 'alpha', 'charlie', 'bravo') {
    New-Item -ItemType Directory -Path (Join-Path $fix10 $n) -Force | Out-Null
    New-FixtureFile (Join-Path $fix10 "$n\same.bin") 1048576
}

$keys10 = @()
foreach ($extra in @(@('-Serial'), @())) {
    foreach ($run in 1, 2) {
        $jp = Join-Path $fix10 "r$($extra.Count)$run.json"
        $null = Invoke-AnalyzeDisk -ExtraArgs (@('-Root', $fix10, '-Top', '10', '-Depth', '0', '-SkipCleanup', '-JsonReport', $jp) + $extra)
        $jj = Get-Json $jp
        if ($jj) { $keys10 += (($jj.topConsumers | ForEach-Object { $_.name }) -join ',') }
    }
}
Test-Assert "t10: four rankings collected" ($keys10.Count -eq 4) "got $($keys10.Count)"
Test-Assert "t10: ranking is stable across runs and -Parallel" (@($keys10 | Select-Object -Unique).Count -eq 1) "orders: $($keys10 -join ' | ')"
Write-Host ""

# =====================================================================
# TEST 11: cleanup candidates report physical size too
# =====================================================================
Write-Host "[Test 11] Cleanup candidates carry logical and physical size"

$fix11 = Join-Path $FixtureRoot 't11'
New-Item -ItemType Directory -Path $fix11 -Force | Out-Null
$json11 = Join-Path $fix11 'report.json'
$r11 = Invoke-AnalyzeDisk -ExtraArgs @('-Root', $fix11, '-Top', '5', '-Depth', '0', '-JsonReport', $json11)
$j11 = Get-Json $json11
Test-Assert "t11: run exited 0" ($r11.ExitCode -eq 0) "exit=$($r11.ExitCode)"
if ($j11) {
    $withSize = @($j11.cleanupCandidates | Where-Object { $_.present })
    Test-Assert "t11: cleanupCandidates present" ($j11.cleanupCandidates.Count -gt 0) "none reported"
    $hasAlloc = @($j11.cleanupCandidates | Where-Object { $null -eq $_.allocMB }).Count -eq 0
    Test-Assert "t11: every candidate has allocMB" $hasAlloc "some candidates missing allocMB"
    if ($withSize.Count -gt 0) {
        Test-Assert "t11: present candidates report a numeric size" (($withSize | Where-Object { $_.mb -lt 0 }).Count -eq 0) "negative size reported"
    }
    Test-Assert "t11: markdown shows logical and physical" ($r11.StdOut -match 'MB logical / .* MB physical') "cleanup line missing physical size"
}

# -SkipCleanup: section notes the skip, JSON list is empty.
$json11b = Join-Path $fix11 'skip.json'
$r11b = Invoke-AnalyzeDisk -ExtraArgs @('-Root', $fix11, '-Top', '5', '-Depth', '0', '-SkipCleanup', '-JsonReport', $json11b)
$j11b = Get-Json $json11b
Test-Assert "t11: -SkipCleanup notes the skip" ($r11b.StdOut -match 'skipped: -SkipCleanup') "no skip note in report"
Test-Assert "t11: -SkipCleanup empties cleanupCandidates" ($null -ne $j11b -and $j11b.cleanupCandidates.Count -eq 0) "got $($j11b.cleanupCandidates.Count) candidates"
Write-Host ""

# =====================================================================
# Cleanup and summary
# =====================================================================

Remove-Item -Recurse -Force $FixtureRoot -ErrorAction SilentlyContinue

Write-Host "========================================"
if ($TestFailures -eq 0) {
    Write-Host "ALL $TestCount CHECKS PASSED"
    exit 0
} else {
    Write-Host "$TestFailures / $TestCount CHECKS FAILED"
    exit 1
}
