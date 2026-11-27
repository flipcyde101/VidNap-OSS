$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'VidNap.Core.ps1')
$script:checks=0
function Assert-Progress([bool]$Condition,[string]$Label) {
    if(-not $Condition){throw "FAIL: $Label"}; $script:checks++
}
$start=[DateTimeOffset]'2026-10-29T12:00:00-06:00'
$state=New-OperationProgress $start 'download'
$view=Get-OperationProgressSnapshot $state ($start.AddSeconds(3)) 0
Assert-Progress ($view.State -eq 'Waiting' -and $null -eq $view.EtaSeconds) 'Preparation never invents an ETA'
Assert-Progress ($view.EtaText -match 'waiting for measured' -and $view.WorkflowText -match '1 of 3') 'Preparation explains its next step'
Assert-Progress ($view.ElapsedSeconds -eq 3 -and $view.HeartbeatText -match 'Heartbeat') 'Elapsed and textual heartbeat advance without worker output'

Update-OperationProgress $state 'Downloading' ($start.AddSeconds(4)) -Bytes 100 -Total 1100
$view=Get-OperationProgressSnapshot $state ($start.AddSeconds(4)) 0
Assert-Progress ($null -eq $view.EtaSeconds -and $view.EtaText -match 'samples') 'First sample cannot manufacture a measured rate'
Update-OperationProgress $state 'Downloading' ($start.AddSeconds(6)) -Bytes 300 -Total 1100
$view=Get-OperationProgressSnapshot $state ($start.AddSeconds(6)) 1
Assert-Progress ($view.Rate -eq 100 -and $view.EtaSeconds -eq 8) 'ETA uses observed byte delta and elapsed sample time'
Assert-Progress ($view.CompletionTime -eq $start.AddSeconds(14)) 'Current-stream completion time derives from measured ETA'
Assert-Progress ($view.CounterText -match '300 / 1100 bytes' -and $view.CounterText -match '1 file reported') 'Known byte counters and evidenced file count are visible'
Assert-Progress ($view.WorkflowText -match '2 of 3' -and $view.WorkflowText -match '1 completed' -and $view.WorkflowText -match '2 remaining') 'Transfer step includes completed and remaining counts'
Assert-Progress ($view.OverallText -match 'unknown' -and $view.EtaText -match 'current stream') 'Current-stream ETA is not an overall promise'
$quietView=Get-OperationProgressSnapshot $state ($start.AddSeconds(9)) 1
Assert-Progress ($quietView.CompletionTime -eq $start.AddSeconds(14)) 'UI-only heartbeat cannot slide the measured projected finish'
Assert-Progress ($quietView.SampleAgeSeconds -eq 3 -and $quietView.EtaText -match '3s old' -and $quietView.EtaText -match 'last byte sample') 'ETA discloses measurement age instead of inventing byte progress'
$expiredView=Get-OperationProgressSnapshot $state ($start.AddSeconds(15)) 1
Assert-Progress ($null -eq $expiredView.EtaSeconds -and $expiredView.EtaText -match 'projection elapsed') 'Expired projection waits for fresh evidence instead of showing a past finish as current'

# Estimated totals may produce an estimate, but must be labeled as uncertain.
Update-OperationProgress $state 'Downloading' ($start.AddSeconds(8)) -Bytes 500 -Total 1100 -TotalEstimated $true
$view=Get-OperationProgressSnapshot $state ($start.AddSeconds(8)) 1
Assert-Progress ($view.CounterText -match 'estimated total' -and $view.EtaText -match 'estimate') 'Estimated total remains explicitly approximate'

# Worker chatter must not disguise a transfer with no advancing byte count.
Update-OperationProgress $state 'Activity' ($start.AddSeconds(40)) -Activity 'Engine output received'
$view=Get-OperationProgressSnapshot $state ($start.AddSeconds(40)) 1
Assert-Progress ($view.State -eq 'Stalled' -and $view.QuietSeconds -eq 32) 'Stall detection measures byte advance, not log chatter'
Assert-Progress ($null -eq $view.EtaSeconds -and $view.EtaText -match 'no measured byte advance') 'Stalled transfers discard stale ETA'
Assert-Progress ($view.HeartbeatText -match 'engine still running') 'Stalled display does not claim the worker is dead'
Update-OperationProgress $state 'Downloading' ($start.AddSeconds(41)) -Bytes 600 -Total 1100
$view=Get-OperationProgressSnapshot $state ($start.AddSeconds(41)) 1
Assert-Progress ($view.State -eq 'Active') 'Fresh byte progress recovers from stalled state'

# A new stream starts a new measurement; a resumed initial offset is not speed.
Update-OperationProgress $state 'Downloading' ($start.AddSeconds(42)) -Bytes 10 -Total 100
$view=Get-OperationProgressSnapshot $state ($start.AddSeconds(42)) 1
Assert-Progress ($view.Rate -eq 0 -and $null -eq $view.EtaSeconds) 'Stream reset clears previous stream measurements'
Update-OperationProgress $state 'Downloading' ($start.AddSeconds(44)) -Bytes 30 -Total 0
$view=Get-OperationProgressSnapshot $state ($start.AddSeconds(44)) 1
Assert-Progress ($view.CounterText -match '30 bytes / total unknown' -and $null -eq $view.EtaSeconds -and $view.EtaText -match 'total size unknown') 'Unknown-total transfer shows bytes and explains unavailable ETA'
Assert-Progress ($view.Rate -eq 10) 'Unknown-total transfer still exposes measured rate'

$slow=New-OperationProgress $start 'download'
Update-OperationProgress $slow 'Downloading' ($start.AddSeconds(1)) -Bytes 0 -Total 100
Update-OperationProgress $slow 'Downloading' ($start.AddSeconds(11)) -Bytes 10 -Total 100
$slowView=Get-OperationProgressSnapshot $slow ($start.AddSeconds(11)) 0
Assert-Progress ($slowView.Rate -eq 1 -and $slowView.EtaSeconds -eq 90) 'Slow known-size transfer uses measured rate, not a fake countdown'
$slowView=Get-OperationProgressSnapshot $slow ($start.AddSeconds(22)) 0
Assert-Progress ($slowView.State -eq 'Waiting' -and $null -eq $slowView.EtaSeconds) 'Temporary lack of byte advance is waiting before stall threshold'

Update-OperationProgress $state 'Finishing' ($start.AddSeconds(45)) -Activity 'Verifying output'
$view=Get-OperationProgressSnapshot $state ($start.AddSeconds(46)) 2
Assert-Progress ($view.State -eq 'Finalizing' -and $view.WorkflowText -match '3 of 3' -and $null -eq $view.EtaSeconds) 'Finalization remains a separate required step'
Assert-Progress ($view.EtaText -match 'verification' -and $view.LatestActivity -eq 'Verifying output') 'Finalization explains uncertainty and latest activity'

foreach($terminal in @('Complete','Failed','Cancelled')) {
    $copy=$state.Clone()
    Update-OperationProgress $copy $terminal ($start.AddSeconds(50)) -Activity $terminal
    $view=Get-OperationProgressSnapshot $copy ($start.AddSeconds(90)) 2
    Assert-Progress ($view.State -eq $terminal -and $view.ElapsedSeconds -eq 50 -and $null -eq $view.EtaSeconds) "$terminal freezes duration and clears ETA"
    Assert-Progress ($view.HeartbeatText -match 'stopped' -and $view.CounterText -match '2 files reported') "$terminal retains evidence and stops heartbeat"
    if($terminal -eq 'Complete'){Assert-Progress ($view.WorkflowText -match '3 completed' -and $view.WorkflowText -match '0 remaining') 'Completion includes finalization'}
}
$setup=New-OperationProgress $start 'setup'
$view=Get-OperationProgressSnapshot $setup ($start.AddSeconds(2)) 0
Assert-Progress ($view.State -eq 'Waiting' -and $view.WorkflowText -match '1 of 7') 'Setup includes separate final cleanup step'
Update-OperationProgress $setup 'Setup' ($start.AddSeconds(4)) -Step 2 -Activity 'Downloading verified engine'
$view=Get-OperationProgressSnapshot $setup ($start.AddSeconds(5)) 0
Assert-Progress ($view.WorkflowText -match '2 of 7' -and $view.WorkflowText -match '1 completed' -and $view.WorkflowText -match '6 remaining') 'Setup stage counters are factual, not byte percentages'
Assert-Progress ($null -eq $view.EtaSeconds -and $view.EtaText -match 'does not expose byte') 'Setup without byte telemetry cannot invent an ETA'
Update-OperationProgress $setup 'Setup' ($start.AddSeconds(6)) -Step 6 -Activity 'Tools installed; cleaning stage'
$view=Get-OperationProgressSnapshot $setup ($start.AddSeconds(7)) 0
Assert-Progress ($view.State -eq 'Finalizing' -and $view.WorkflowText -match '7 of 7') 'Setup is not complete before worker cleanup/exit'
Update-OperationProgress $setup 'Complete' ($start.AddSeconds(8))
$view=Get-OperationProgressSnapshot $setup ($start.AddSeconds(9)) 0
Assert-Progress ($view.WorkflowText -match '7 completed' -and $view.WorkflowText -match '0 remaining') 'Setup completion includes finalization'

$parsed=ConvertFrom-ProgressLine 'VIDNAP_PROGRESS|50|NA|100|NA|NA'
Assert-Progress ($parsed.Total -eq 100 -and $parsed.TotalEstimated) 'Parser preserves estimated total evidence'
$parsed=ConvertFrom-ProgressLine 'VIDNAP_PROGRESS|50|100|200|NA|NA'
Assert-Progress ($parsed.Total -eq 100 -and -not $parsed.TotalEstimated) 'Exact total takes precedence over estimate'
Write-Output "PASS: $script:checks detailed-progress checks; waiting, samples, ETA, unknown/estimated total, stalled/recovery, stream reset, finalization and terminal states."
