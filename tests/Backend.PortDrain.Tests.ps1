# In-memory regression for incomplete metadata output. No child or media is opened.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'VidNap.Core.ps1')
. (Join-Path $root 'VidNap.Storage.ps1')
Add-Type -Path (Join-Path $root 'VidNap.BackendProcess.cs')
Add-Type -Path (Join-Path $root 'VidNap.ProcessRunner.cs')
. (Join-Path $root 'VidNap.Backend.ps1')
# Polling uses only the supplied worker. Avoid unrelated native type compilation.
function Initialize-VidNapBackendTypes($Paths) {}
$worker=[VidNapBackendProcess]::new()
$flags=[Reflection.BindingFlags]'Instance,NonPublic'
try {
    $type=$worker.GetType()
    [void]$type.GetField('stdout',$flags).GetValue($worker).Append('{"id":"synthetic","title":"incomplete metadata"}')
    $type.GetField('exited',$flags).SetValue($worker,$true)
    $type.GetField('elapsed',$flags).SetValue($worker,[Diagnostics.Stopwatch]::StartNew())
    $type.GetField('exitAt',$flags).SetValue($worker,[long]-3000)
    if(-not $worker.IsComplete){throw 'ASSERT: expired output drain must terminate polling'}
    if($worker.ErrorCode -cne 'VIDNAP_PROCESS_DRAIN_TIMEOUT'){throw 'ASSERT: incomplete output must fail closed with VIDNAP_PROCESS_DRAIN_TIMEOUT'}
    $adapter=New-VidNapNativeAdapter $null
    $handle=[pscustomobject]@{Kind='Analyze';Worker=$worker;LastError=''}
    $poll=& $adapter.Poll $handle
    if(-not $poll.Complete -or $poll.Output -cne '' -or $poll.ErrorCode -cne 'VIDNAP_PROCESS_DRAIN_TIMEOUT'){throw 'ASSERT: adapter must reject incomplete metadata'}
    $type.GetField('ended',$flags).SetValue($worker,2)
    $late=& $adapter.Poll $handle
    if(-not $worker.DrainTimedOut -or $late.Output -cne '' -or $late.ErrorCode -cne 'VIDNAP_PROCESS_DRAIN_TIMEOUT'){throw 'ASSERT: late EOF must preserve timeout latch and suppress metadata'}
    Write-Output 'PASS: incomplete metadata output fails closed'
    $q=[Collections.Concurrent.ConcurrentQueue[string]]::new()
    $q.Enqueue('VIDNAP_FILE|D:\synthetic-missing.mp4')
    $download=[pscustomobject]@{Output=$q;IsComplete=$true;ExitCode=0;CompletionState='TimedOut'}
    $downloadHandle=[pscustomobject]@{Kind='Download';Worker=$download;LastError=''}
    $result=& $adapter.Poll $downloadHandle
    if(-not $result.Complete -or $result.ErrorCode -cne 'VIDNAP_PROCESS_DRAIN_TIMEOUT'){throw 'ASSERT: exit zero must not hide an incomplete download drain'}
    Write-Output 'PASS: incomplete download drain overrides exit zero'
} finally { $type.GetField('ended',$flags).SetValue($worker,2); $worker.Dispose() }

foreach($case in @(
    @{Name='both EOF normal';Ended=2;Prior=$null;Expected='';Output='synthetic metadata'},
    @{Name='one EOF timeout';Ended=1;Prior=$null;Expected='VIDNAP_PROCESS_DRAIN_TIMEOUT';Output=''},
    @{Name='previous error preserved';Ended=1;Prior='VIDNAP_PROCESS_OUTPUT_LIMIT';Expected='VIDNAP_PROCESS_OUTPUT_LIMIT';Output=''}
)) {
    $worker=[VidNapBackendProcess]::new()
    try {
        $type=$worker.GetType()
        $type.GetField('exited',$flags).SetValue($worker,$true)
        $type.GetField('elapsed',$flags).SetValue($worker,[Diagnostics.Stopwatch]::StartNew())
        $type.GetField('exitAt',$flags).SetValue($worker,[long]-3000)
        $type.GetField('ended',$flags).SetValue($worker,[int]$case.Ended)
        $type.GetField('errorCode',$flags).SetValue($worker,$case.Prior)
        [void]$type.GetField('stdout',$flags).GetValue($worker).Append('synthetic metadata')
        $handle=[pscustomobject]@{Kind='Analyze';Worker=$worker;LastError=''}
        $result=& $adapter.Poll $handle
    if(-not $result.Complete -or $result.ExitCode -ne 0 -or $result.Output -cne $case.Output -or [string]$result.ErrorCode -cne $case.Expected){throw ('ASSERT: '+$case.Name)}
        Write-Output ('PASS: '+$case.Name)
    } finally { $type.GetField('ended',$flags).SetValue($worker,2); $worker.Dispose() }
}

# Exercise the real diagnostic classifier through the download adapter.
$q=[Collections.Concurrent.ConcurrentQueue[string]]::new()
$q.Enqueue('VIDNAP_FILE|D:\synthetic-missing.mp4')
$q.Enqueue('ERROR: No space left on device')
$download=[pscustomobject]@{Output=$q;IsComplete=$true;ExitCode=1;CompletionState='Complete'}
$handle=[pscustomobject]@{Kind='Download';Worker=$download;LastError=''}
$result=& $adapter.Poll $handle
if(-not $result.Complete -or $result.ErrorCode -cne 'DISK_FULL' -or $result.Lines.Count -ne 1 -or $result.Lines[0] -cne 'VIDNAP_FILE|D:\synthetic-missing.mp4' -or -not $q.IsEmpty){throw 'ASSERT: download must classify real diagnostics and retain structured output'}
Write-Output 'PASS: download diagnostic classification and structured output'
$racing=[pscustomobject]@{Output=[Collections.Concurrent.ConcurrentQueue[string]]::new();ExitCode=0;Reads=0}
$racing | Add-Member ScriptProperty IsComplete { throw 'ASSERT: adapter reread completion through IsComplete' }
$racing | Add-Member ScriptProperty CompletionState { $this.Reads++;if($this.Reads -eq 1){return 'TimedOut'};return 'Complete' }
$result=& $adapter.Poll ([pscustomobject]@{Kind='Download';Worker=$racing;LastError=''})
if($racing.Reads -ne 1 -or $result.ErrorCode -cne 'VIDNAP_PROCESS_DRAIN_TIMEOUT'){throw 'ASSERT: late EOF replaced timeout snapshot'}
$native=[VidNapProcessRunner]::new()
try {
    $ended=[VidNapProcessRunner].GetField('streamsEnded',$flags)
    if($native.OutputComplete){throw 'ASSERT: no EOF reported complete'}
    $ended.SetValue($native,1);if($native.OutputComplete){throw 'ASSERT: one EOF reported complete'}
    $ended.SetValue($native,2);if(-not $native.OutputComplete){throw 'ASSERT: both EOF not complete'}
}finally{$native.Dispose()}
Write-Output 'PASS: one completion snapshot and native EOF contract'
