. (Join-Path $PSScriptRoot 'Backend.TestSupport.ps1')
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'VidNap.Core.ps1')
$source=Join-Path $root 'VidNap.BackendProcess.cs'
if((Test-Path -LiteralPath $source) -and -not ('VidNapBackendProcess' -as [type])){Add-Type -Path $source}
Assert-Backend ($null -ne ('VidNapBackendProcess' -as [type])) 'bounded asynchronous process backend exists'
$fixture=New-BackendTestDirectory $root
function Start-FixtureProcess([string]$Code,[int]$Limit=100000,[int]$Timeout=10000){
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))
    $info.Arguments='-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand '+$encoded
    $info.WorkingDirectory=$fixture
    $p=[VidNapBackendProcess]::new();$p.Start($info,$Limit,65536,$Timeout);return $p
}
function Wait-FixtureProcess($Process){
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while(-not $Process.IsComplete -and $timer.Elapsed.TotalSeconds -lt 20){Start-Sleep -Milliseconds 20}
    Assert-Backend $Process.IsComplete 'owned fixture process completes within bounded wait'
}
try{
    $p=Start-FixtureProcess "[Console]::Out.Write(('x'*20000));[Console]::Error.Write('notice');exit 7"
    try{Wait-FixtureProcess $p;Assert-Backend ($p.StandardOutput.Length -eq 20000 -and $p.StandardError -ceq 'notice' -and $p.ExitCode -eq 7) 'long metadata lines are not truncated; stderr separate'}finally{$p.Dispose()}
    $p=Start-FixtureProcess "[Console]::Out.Write(('x'*200000))" 1024
    try{Wait-FixtureProcess $p;Assert-Backend ($p.ErrorCode -eq 'VIDNAP_PROCESS_OUTPUT_LIMIT' -and $p.StandardOutput.Length -le 1024) 'output overflow fails closed with bounded memory'}finally{$p.Dispose()}
    $p=Start-FixtureProcess "[Console]::Out.Write('tiny');[Console]::Error.Write(('x'*200000))" 1024
    try{Wait-FixtureProcess $p;Assert-Backend ($p.ErrorCode -ceq 'VIDNAP_PROCESS_STDERR_LIMIT' -and $p.StandardError.Length -le 65536 -and $p.StandardOutput.Length -le 4) 'stderr-only overflow is distinct from large source metadata'}finally{$p.Dispose()}
    $p=Start-FixtureProcess 'Start-Sleep -Seconds 30' 1024 250
    try{Wait-FixtureProcess $p;Assert-Backend ($p.ErrorCode -eq 'VIDNAP_PROCESS_TIMEOUT') 'quiet metadata timeout terminates only owned work'}finally{$p.Dispose()}
    $p=Start-FixtureProcess 'Start-Sleep -Seconds 30'
    try{$p.Cancel();Wait-FixtureProcess $p;Assert-Backend ($p.ErrorCode -eq 'VIDNAP_PROCESS_CANCELLED') 'explicit cancellation has a distinct result'}finally{$p.Dispose()}
    Write-Output "PASS: $script:BackendChecks process checks; actual hidden child processes, long output, bounds, timeout and cancellation."
}finally{Remove-BackendTestDirectory $fixture $root}
