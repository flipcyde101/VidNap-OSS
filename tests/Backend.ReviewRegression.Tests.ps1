. (Join-Path $PSScriptRoot 'Backend.TestSupport.ps1')
$root=Split-Path $PSScriptRoot -Parent
foreach($name in @('Core','Storage','Analysis','Jobs','Captions','Backend')){. (Join-Path $root ('VidNap.'+$name+'.ps1'))}
if(-not ('VidNapJobStore' -as [type])){Add-Type -Path (Join-Path $root 'VidNap.JobStore.cs') -ReferencedAssemblies System.Security}
$fixture=New-BackendTestDirectory $root
$failures=[Collections.Generic.List[string]]::new()
function Invoke-ReviewCheck([string]$Label,[scriptblock]$Body){
    try{& $Body;Assert-Backend $true $Label}catch{$failures.Add($Label);Write-Output ('FAIL: '+$Label);Write-Output $_.Exception.Message;Write-Output $_.ScriptStackTrace}
}
try{
    $paths=[pscustomobject]@{DataRoot=$fixture};$tool=Join-Path $fixture 'tool.exe';[IO.File]::WriteAllText($tool,'never executed')
    $tools=@{YtDlp=@{Path=$tool;Sha256=(Get-BackendTestHash $tool)};Ffprobe=@{Path=$tool;Sha256=(Get-BackendTestHash $tool)};Ffmpeg=@{Path=$tool;Sha256=(Get-BackendTestHash $tool)}}
    $old=Join-Path $fixture 'existing.mp4';[IO.File]::WriteAllText($old,'pre-existing content');$oldHash=Get-BackendTestHash $old
    $json='{"id":"fixture","title":"fixture","duration":4,"formats":[{"format_id":"one","ext":"mp4","vcodec":"avc1","acodec":"mp4a"}],"format_id":"one"}'
    $probe='{"format":{"format_name":"mp4","duration":"4"},"streams":[{"codec_type":"video","codec_name":"h264"},{"codec_type":"audio","codec_name":"aac"}]}'
    $adapter=[pscustomobject]@{Start={param($r) [pscustomobject]@{Kind=$r.Kind}};Poll={param($h)
        @{Complete=$true;ExitCode=0;ErrorCode='';Output=$(if($h.Kind -eq 'Analyze'){$json}else{$probe});Lines=$(if($h.Kind -eq 'Download'){@('VIDNAP_FILE|'+$old)}else{@()})}
    };Cancel={param($h)};Dispose={param($h)}}
    Invoke-ReviewCheck 'reported pre-existing destination file cannot complete a new attempt' {
        $job=New-VidNapJob 'https://www.youtube.com/watch?v=abcdefghijk' $fixture @{Media='video';Format='best'};$job.State='Queued'
        $session=New-VidNapBackendSession (New-VidNapQueue @($job)) $paths $tools $adapter
        if(-not (Start-VidNapQueueItem $session)){throw 'Fixture analysis was not admitted; output ownership was not exercised.'}
        for($i=0;$i -lt 8 -and $session.Active;$i++){Receive-VidNapBackendTick $session ([DateTimeOffset]::UtcNow)|Out-Null}
        if($job.State -eq 'Completed' -or (Get-BackendTestHash $old) -cne $oldHash){throw 'Existing output incorrectly accepted.'}
    }
    Invoke-ReviewCheck 'terminal queue records never persist source URLs' {
        $job=New-VidNapJob 'https://www.youtube.com/watch?v=abcdefghijk' $fixture @{Media='video';Format='best'};$job.State='Completed'
        $history=@([pscustomobject]@{JobId=$job.JobId;SourceKey=$job.SourceKey;Selection=$job.Selection;Destination=$fixture;OutputFiles=@($old);Result='Completed'})
        $projection=ConvertTo-VidNapPersistedState @($job) $history
        if($projection.Jobs.Count -ne 0 -or ($projection|ConvertTo-Json -Depth 12) -match 'https://|SourceUrl'){throw 'Terminal URL retained.'}
    }
    Invoke-ReviewCheck 'stopped job has an explicit coordinator resume entry point' {
        $job=New-VidNapJob 'https://www.youtube.com/watch?v=abcdefghijk' $fixture @{Media='video';Format='best'};$job.State='Interrupted'
        $session=New-VidNapBackendSession (New-VidNapQueue @($job)) $paths $tools $adapter
        if(-not (Resume-VidNapBackendJob $session $job.JobId $false 'edge') -or $job.State -ne 'Analyzing' -or -not $session.Active){throw 'Resume did not admit stopped work.'}
        Stop-VidNapBackendJob $session;Receive-VidNapBackendTick $session ([DateTimeOffset]::UtcNow)|Out-Null
    }
    Invoke-ReviewCheck 'compiler scratch is explicitly D bounded without changing the host environment' {
        $before=$env:TEMP;$parameters=New-VidNapCompilerParameters $paths
        if($parameters.TempFiles.TempDir -ine (Join-Path $fixture 'temp') -or $env:TEMP -cne $before){throw 'Compiler scratch was not explicitly bounded.'}
    }
    Invoke-ReviewCheck 'private ACL predicates reject other users and unknown local groups' {
        $owner='S-1-5-21-1-2-3-1001'
        foreach($sid in @($owner,'S-1-5-18','S-1-5-32-544','S-1-5-21-1-2-3-1002','S-1-5-21-1-2-3-9999','S-1-5-11')){
            $expected=$sid -in @($owner,'S-1-5-18','S-1-5-32-544')
            if((Test-VidNapPrivatePrincipal $owner $sid) -ne $expected -or [VidNapJobStore]::IsPrivatePrincipal($owner,$sid) -ne $expected){throw 'Unexpected ACL principal policy.'}
        }
    }
    if($failures.Count){throw ('Review regression failures: '+$failures.Count)}
    Write-Output "PASS: $script:BackendChecks independent-review regression checks; output ownership, terminal privacy, resume, compiler routing and private principals."
}finally{Remove-BackendTestDirectory $fixture $root}
