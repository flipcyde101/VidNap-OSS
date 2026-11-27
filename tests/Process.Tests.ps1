$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PSScriptRoot '..\VidNap.ProcessRunner.cs')
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function New-Info([string]$Code) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $PSHOME 'powershell.exe'
    $info.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))
    return $info
}
function Wait-Complete($Runner) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not $Runner.IsComplete -and $timer.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 20 }
    Assert $Runner.IsComplete 'Run failed to complete within 15 seconds.'
}
$runner = New-Object VidNapProcessRunner
try {
    $runner.Start((New-Info '[Console]::Out.WriteLine("stdout"); [Console]::Error.WriteLine("stderr"); [Console]::Out.Write("final-no-newline"); exit 7'))
    Wait-Complete $runner
    $lines = $runner.Output.ToArray()
    Assert ($runner.ExitCode -eq 7) 'Nonzero exit code lost.'
    Assert ($lines -contains 'stdout') 'stdout missing.'
    Assert ($lines -contains 'stderr') 'stderr missing.'
    Assert ($lines -contains 'final-no-newline') 'Final unterminated line missing.'
    for ($i = 0; $i -lt 3; $i++) {
        $runner.Start((New-Info '[Console]::Out.WriteLine("repeat"); exit 0'))
        Wait-Complete $runner
        Assert ($runner.ExitCode -eq 0) 'Repeated run failed.'
    }
} finally { $runner.Dispose(); $runner.Dispose() }
$runner = New-Object VidNapProcessRunner -ArgumentList 8
try {
    $runner.Start((New-Info '1..5000 | ForEach-Object { [Console]::Out.WriteLine($_) }'))
    Wait-Complete $runner
    Assert ($runner.Output.Count -le 8) 'Output queue exceeded configured bound.'
    Assert ($runner.Output.ToArray() -contains '5000') 'Latest output was not retained.'
} finally { $runner.Dispose() }
# Harmless parent/child cancellation: the child only sleeps. Never launches VidNap,
# media tools, browser windows, or network traffic.
$runner = New-Object VidNapProcessRunner
$childId = 0
try {
    $code = '$p = Start-Process -FilePath (Join-Path $PSHOME "powershell.exe") -ArgumentList "-NoProfile -NonInteractive -Command Start-Sleep -Seconds 60" -WindowStyle Hidden -PassThru; [Console]::Out.WriteLine("CHILD:" + $p.Id); Start-Sleep -Seconds 60'
    $runner.Start((New-Info $code))
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($childId -eq 0 -and $timer.Elapsed.TotalSeconds -lt 10) {
        foreach ($line in $runner.Output.ToArray()) { if ($line -match '^CHILD:(\d+)$') { $childId = [int]$Matches[1] } }
        Start-Sleep -Milliseconds 20
    }
    Assert ($childId -gt 0) 'Child did not report its PID.'
    Assert ([bool](Get-Process -Id $childId -ErrorAction SilentlyContinue)) 'Child exited before cancellation.'
    $runner.Stop()
    Wait-Complete $runner
    $timer.Restart()
    while ((Get-Process -Id $childId -ErrorAction SilentlyContinue) -and $timer.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 20 }
    Assert (-not (Get-Process -Id $childId -ErrorAction SilentlyContinue)) 'Cancellation left a child process alive.'
} finally {
    $runner.Dispose()
    if ($childId -gt 0) { Stop-Process -Id $childId -ErrorAction SilentlyContinue }
}
$runner = New-Object VidNapProcessRunner
$childId = 0
try {
    $code = '$p = Start-Process -FilePath (Join-Path $PSHOME "powershell.exe") -ArgumentList "-NoProfile -NonInteractive -Command Start-Sleep -Seconds 60" -WindowStyle Hidden -PassThru; [Console]::Out.WriteLine("CHILD:" + $p.Id); exit 0'
    $runner.Start((New-Info $code))
    Wait-Complete $runner
    foreach ($line in $runner.Output.ToArray()) { if ($line -match '^CHILD:(\d+)$') { $childId = [int]$Matches[1] } }
    Assert ($childId -gt 0) 'Root-exit helper did not report child PID.'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ((Get-Process -Id $childId -ErrorAction SilentlyContinue) -and $timer.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 20 }
    Assert (-not (Get-Process -Id $childId -ErrorAction SilentlyContinue)) 'Root exit left its child alive.'
    Assert ($runner.ExitCode -eq 0) 'Root exit status changed by descendant cleanup.'
} finally {
    $runner.Dispose()
    if ($childId -gt 0) { Stop-Process -Id $childId -ErrorAction SilentlyContinue }
}
for ($i = 0; $i -lt 3; $i++) {
    $runner = New-Object VidNapProcessRunner
    $runner.Start((New-Info 'Start-Sleep -Seconds 60'))
    $runner.Dispose()
    $runner.Dispose()
}
$runner = New-Object VidNapProcessRunner
try {
    $bad = New-Info 'exit 0'
    $bad.FileName = 'C:\__VidNap_test_nonexistent__\missing.exe'
    $failed = $false
    try { $runner.Start($bad) } catch { $failed = $true }
    Assert $failed 'Missing executable should fail.'
    $runner.Start((New-Info 'exit 0'))
    Wait-Complete $runner
    Assert ($runner.ExitCode -eq 0) 'Runner failed to recover after failed start.'
} finally { $runner.Dispose() }
'PASS: process output, final line, exit code, bounded queue, repeated start/dispose, parent/child cancellation, root-exit descendant cleanup, failed-start recovery.'
