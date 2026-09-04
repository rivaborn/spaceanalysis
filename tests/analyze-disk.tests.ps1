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

function Invoke-AnalyzeDisk {
    param([string[]]$ExtraArgs = @())
    $allArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $ExtraArgs
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo.FileName    = 'powershell.exe'
    $proc.StartInfo.Arguments   = ($allArgs -join ' ')
    $proc.StartInfo.UseShellExecute = $false
    $proc.StartInfo.RedirectStandardOutput = $true
    $proc.StartInfo.RedirectStandardError  = $true
    $proc.StartInfo.CreateNoWindow = $true
    [void]$proc.Start()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    [void]$proc.WaitForExit(120000)
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
try {
    $null = cmd /c "mklink /J `"$linkPath`" `"$realPath`"" 2>&1
    $junctionOk = $true
} catch { $junctionOk = $false }

$r2 = Invoke-AnalyzeDisk -ExtraArgs @(
    '-Root', $fix2, '-Top', '10', '-Depth', '0',
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
    '-Root', $fix3, '-Top', '5', '-Depth', '0',
    '-JsonReport', (Join-Path $fix3 'r0.json')
)
Test-Assert "t3a: Depth 0 has no Drill-down section" ($r3a.StdOut -notmatch '## Drill-down') "found drill-down in depth-0 output"

$r3b = Invoke-AnalyzeDisk -ExtraArgs @(
    '-Root', $fix3, '-Top', '5', '-Depth', '2',
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
    '-Root', $fix4, '-Top', '5', '-Depth', '0',
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
    '-Root', $fix5, '-Top', '5', '-Depth', '0',
    '-JsonReport', (Join-Path $fix5 'serial.json')
)
$j5s = Get-Json (Join-Path $fix5 'serial.json')

$r5p = Invoke-AnalyzeDisk -ExtraArgs @(
    '-Root', $fix5, '-Top', '5', '-Depth', '0', '-Parallel',
    '-JsonReport', (Join-Path $fix5 'parallel.json')
)
$j5p = Get-Json (Join-Path $fix5 'parallel.json')

Test-Assert "t5: serial exited 0" ($r5s.ExitCode -eq 0) "exit=$($r5s.ExitCode)"
Test-Assert "t5: parallel exited 0" ($r5p.ExitCode -eq 0) "exit=$($r5p.ExitCode) err=$($r5p.Stderr.Trim())"

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
    '-Root', $fix6, '-Top', '5', '-Depth', '0',
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
    '-Root', $fix6b, '-Top', '5', '-Depth', '0',
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
