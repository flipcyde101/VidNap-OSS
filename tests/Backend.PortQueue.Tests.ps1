# Synthetic persistence barriers only. Coordinator runs under approved AllSigned setup.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($name in @('Core','Storage','Analysis','Jobs','Captions')){. (Join-Path $root ('VidNap.'+$name+'.ps1'))}
. (Join-Path $root 'VidNap.Backend.ps1')
. (Join-Path $root 'VidNap.Manager.ps1')
$session=[pscustomobject]@{SaveCallback={param($context) $context.Calls++;return $context.Success};SaveContext=[pscustomobject]@{Calls=0;Success=$false;PersistenceError=''};PersistenceError='';StorePath=''}
if(Save-VidNapBackendSession $session){throw 'ASSERT: failed checkpoint must block start'}
if($session.PersistenceError -cne 'VIDNAP_BACKEND_STATE_NOT_SAVED'){throw 'ASSERT: checkpoint failure must be visible'}
$session.SaveContext.Success=$true
if(-not (Save-VidNapBackendSession $session)){throw 'ASSERT: successful checkpoint must permit start'}
if($session.PersistenceError -or $session.SaveContext.Calls -ne 2){throw 'ASSERT: callback must run on every checkpoint'}
$session.SaveCallback={throw 'synthetic storage failure'}
if(Save-VidNapBackendSession $session){throw 'ASSERT: thrown checkpoint failure must fail closed'}
Write-Output 'PASS: low-level callback failure contract'
$session.SaveCallback={param($context) $context.Calls++;return $context.Success}
$session.SaveContext.Success=$true
$session.SaveContext.PersistenceError='synthetic-prior-error'
$session.PersistenceError=''
if(Save-VidNapBackendSession $session){throw 'ASSERT: nonempty SaveContext.PersistenceError must block checkpoint'}
if($session.PersistenceError -cne 'VIDNAP_BACKEND_STATE_NOT_SAVED' -or $session.SaveContext.Calls -ne 2){throw 'ASSERT: blocked checkpoint must mark session error without invoking its callback'}
Write-Output 'PASS: SaveContext.PersistenceError blocks checkpoint recovery gate'
$fixture=Join-Path $PSScriptRoot ('q'+[guid]::NewGuid().ToString('N').Substring(0,8))
$data=Join-Path $fixture 'state';$media=Join-Path $fixture 'media'
[void][IO.Directory]::CreateDirectory($data);[void][IO.Directory]::CreateDirectory($media)
$paths=[pscustomobject]@{DataRoot=$data;MediaRoot=$media;ApplicationRoot=$root}
$tool=Join-Path $fixture 'synthetic-tool.txt';[IO.File]::WriteAllText($tool,'never executed')
$tools=@{YtDlp=@{Path=$tool;Sha256=(Get-VidNapFileSha256 $tool)}}
$script:starts=0;$script:downloadRoots=[Collections.Generic.List[string]]::new()
$script:metadata='{"id":"abcdefghijk","title":"synthetic","duration":4,"format_id":"one","formats":[{"format_id":"one","ext":"mp4","vcodec":"avc1","acodec":"mp4a","width":320,"height":180,"fps":25}]}'
$adapter=[pscustomobject]@{
 Start={param($request)
    $snapshot=[VidNapJobStore]::Read($script:manager.StorePath)
    if($snapshot.ErrorCode -or -not $snapshot.Json){throw 'ASSERT: Start preceded durable snapshot'}
    $pending=@((ConvertFrom-Json $snapshot.Json).Jobs)
    if($pending.Count -ne 1 -or $pending[0].AttemptId -cne $script:manager.Entries[0].Job.AttemptId){throw 'ASSERT: checkpoint has wrong attempt'}
    if($request.Kind -eq 'Download'){
        $args=@($request.Arguments);$retry=-1
        for($i=0;$i -lt $args.Count-1;$i++){if($args[$i] -ceq '--retries'){$retry=[int]$args[$i+1]}}
        if($retry -ne 0 -or '--abort-on-unavailable-fragments' -cnotin $args){throw 'ASSERT: unsafe transfer flags'}
        if($pending[0].State -cne 'Running'){throw 'ASSERT: transfer preceded Running checkpoint'}
        $script:downloadRoots.Add($request.WorkingDirectory)
        [IO.File]::WriteAllText((Join-Path $request.WorkingDirectory 'sentinel.part'),'retained synthetic bytes')
    }
    $script:starts++;return [pscustomobject]@{Kind=$request.Kind}
 }
 Poll={param($handle) if($handle.Kind -eq 'Analyze'){return [pscustomobject]@{Complete=$true;ExitCode=0;ErrorCode='';Output=$script:metadata;Lines=@()}}
    return [pscustomobject]@{Complete=$true;ExitCode=0;ErrorCode='VIDNAP_PROCESS_DRAIN_TIMEOUT';Output='';Lines=@('VIDNAP_FILE|D:\missing.mp4')}}
 Cancel={param($handle)};Dispose={param($handle)}
}
$script:manager=New-VidNapManager $paths $tools $adapter
$job=New-VidNapJob 'https://www.youtube.com/watch?v=abcdefghijk' $media @{Media='video';Format='best';FormatIds=@('one')}
$job.State='Queued';$entry=New-VidNapManagerEntry $job;$entry.Mode='DownloadQueued';$script:manager.Entries.Add($entry)
$normalized=ConvertFrom-VidNapAnalysis $script:metadata
[void](Get-VidNapExpectedOutput $normalized $job.Selection)
[void](New-VidNapEngineRequest $job $paths $tools 'Download' $normalized)
Receive-VidNapManagerTick $script:manager
Receive-VidNapManagerTick $script:manager
if($script:downloadRoots.Count -ne 1){throw 'ASSERT: transfer did not start after checkpoint'}
Stop-VidNapManagerItem $script:manager $job.JobId
Receive-VidNapManagerTick $script:manager
if($job.State -cne 'Cancelled'){throw 'ASSERT: cancellation lost to late drain/clean exit'}
$reloaded=New-VidNapManager $paths $tools $adapter
if($reloaded.History.Count -ne 1 -or $reloaded.History[0].Result -cne 'Cancelled'){throw 'ASSERT: terminal history missing or duplicated after reload'}
$again=New-VidNapManager $paths $tools $adapter
if($again.History.Count -ne 1){throw 'ASSERT: terminal history duplicated on second reload'}
Resume-VidNapManagerItem $script:manager $job.JobId
Receive-VidNapManagerTick $script:manager
Receive-VidNapManagerTick $script:manager
if($script:downloadRoots.Count -ne 2 -or $script:downloadRoots[0] -ceq $script:downloadRoots[1]){throw 'ASSERT: retry reused attempt directory'}
foreach($dir in $script:downloadRoots){if([IO.File]::ReadAllText((Join-Path $dir 'sentinel.part')) -cne 'retained synthetic bytes'){throw 'ASSERT: retry changed partial'}}
Receive-VidNapManagerTick $script:manager
if($job.State -cne 'Failed' -or $entry.ErrorCode -cne 'VIDNAP_PROCESS_DRAIN_TIMEOUT' -or $entry.Session.Last.Verifications.Count -ne 0){throw 'ASSERT: incomplete file marker was processed or drain failure obscured'}
Write-Output 'PASS: durable manager checkpoints, request safeguards, cancellation, reload history and fresh retry'
# A directory at the state-file path forces actual checkpoint I/O failure.
$badData=Join-Path $fixture 'bad-state';[void][IO.Directory]::CreateDirectory($badData)
$badPaths=[pscustomobject]@{DataRoot=$badData;MediaRoot=$media;ApplicationRoot=$root}
$bad=New-VidNapManager $badPaths $tools $adapter
[void][IO.Directory]::CreateDirectory($bad.StorePath)
$badJob=New-VidNapJob 'https://www.youtube.com/watch?v=abcdefghijk' $media @{Media='video';Format='best';FormatIds=@('one')};$badJob.State='Queued'
$badEntry=New-VidNapManagerEntry $badJob;$badEntry.Mode='DownloadQueued';$bad.Entries.Add($badEntry)
$before=$script:starts;Receive-VidNapManagerTick $bad
if($script:starts -ne $before -or -not $bad.PersistenceError){throw 'ASSERT: failed durable checkpoint started work or hid error'}
Write-Output 'PASS: real checkpoint failure prevents adapter Start'
