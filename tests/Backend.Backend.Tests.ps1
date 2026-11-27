. (Join-Path $PSScriptRoot 'Backend.TestSupport.ps1')
$root=Split-Path $PSScriptRoot -Parent
foreach($name in @('Core','Storage','Analysis','Jobs','Captions')){. (Join-Path $root ('VidNap.'+$name+'.ps1'))}
if(Test-Path -LiteralPath (Join-Path $root 'VidNap.Backend.ps1')){. (Join-Path $root 'VidNap.Backend.ps1')}
Assert-Backend ($null -ne (Get-Command New-VidNapBackendSession -ErrorAction SilentlyContinue)) 'backend coordinator exists'
$fixture=New-BackendTestDirectory $root
try{
    $paths=[pscustomobject]@{DataRoot=$fixture;MediaRoot=$fixture;TempRoot=$fixture;CacheRoot=$fixture;DenoRoot=$fixture}
    $tool=Join-Path $fixture 'tool.exe';[IO.File]::WriteAllText($tool,'synthetic fixture, never executed')
    $tools=@{YtDlp=@{Path=$tool;Sha256=(Get-BackendTestHash $tool)};Ffprobe=@{Path=$tool;Sha256=(Get-BackendTestHash $tool)};Ffmpeg=@{Path=$tool;Sha256=(Get-BackendTestHash $tool)}}
    $job=New-VidNapJob 'https://www.youtube.com/watch?v=abcdefghijk' $fixture @{Media='video';Format='best'}
    $request=New-VidNapEngineRequest $job $paths $tools 'Analyze' $null $false 'firefox'
    Assert-Backend ($request.Arguments -contains '--dump-single-json' -and $request.Arguments -notcontains '--cookies-from-browser' -and $request.TimeoutMilliseconds -eq 120000) 'analysis is bounded metadata-only, browser selection is not consent'
    Assert-Backend ($request.StandardOutputLimit -eq 16MB -and $request.StandardErrorLimit -eq 256KB) 'metadata collection admits the larger catalog without widening stderr'
    $consented=New-VidNapEngineRequest $job $paths $tools 'Analyze' $null $true 'firefox'
    Assert-Backend ($consented.Arguments -contains '--cookies-from-browser') 'explicit transient browser consent is respected'
    Assert-BackendCode {New-VidNapEngineRequest $job $paths $tools 'Analyze' $null $true 'arbitrary'} 'VIDNAP_BACKEND_BROWSER'
    $analysisJson='{"id":"fixture","title":"private title","duration":4,"webpage_url":"https://example.invalid","formats":[{"format_id":"one","ext":"mp4","vcodec":"avc1","acodec":"mp4a","width":320,"height":180,"fps":25}],"format_id":"one","subtitles":{"en":[{"ext":"vtt"}]}}'
    $analysis=ConvertFrom-VidNapAnalysis $analysisJson
    foreach($kind in @('Download','Captions')){
        $outputRequest=New-VidNapEngineRequest $job $paths $tools $kind $analysis $false 'edge' @{Language='en';AllowAutomatic=$false}
        $outputIndex=[Array]::IndexOf($outputRequest.Arguments,'-o')
        Assert-Backend ($outputIndex -ge 0 -and $outputRequest.Arguments[$outputIndex+1] -ceq '%(title).200B [%(id)s].%(ext)s' -and $outputRequest.WorkingDirectory -ceq $fixture) ($kind+' uses the destination as its working directory and a filename-only template')
    }
    $expected=Get-VidNapExpectedOutput $analysis $job.Selection
    Assert-Backend ($expected.VideoCodec -eq 'h264' -and $expected.AudioCodec -eq 'aac' -and $expected.Height -eq 180) 'verification policy uses actual engine-selected stream evidence'
    $saved=Join-Path $fixture 'saved.mp4';[IO.File]::WriteAllText($saved,'synthetic file, never played')
    $script:fixtureMode='valid';$script:starts=0;$script:cancels=0
    $adapter=[pscustomobject]@{
        Start={param($Request)
            $script:starts++
            if($Request.Kind -eq 'Download'){
                $name=if($script:fixtureMode -eq 'collision'){'collision.mp4'}else{'saved-'+$script:starts+'.mp4'}
                $script:stageSaved=Join-Path $Request.WorkingDirectory $name
                if(-not [IO.File]::Exists($script:stageSaved)){[IO.File]::WriteAllText($script:stageSaved,'new synthetic transfer')}
            }
            [pscustomobject]@{Kind=$Request.Kind;Cancelled=$false}
        }
        Poll={param($Handle)
            if($Handle.Cancelled){return @{Complete=$true;ExitCode=1;ErrorCode='VIDNAP_PROCESS_CANCELLED';Lines=@();Output=''}}
            switch($Handle.Kind){
                Analyze {
                    if($script:fixtureMode -eq 'capture-limit'){return @{Complete=$true;ExitCode=1;ErrorCode='VIDNAP_PROCESS_OUTPUT_LIMIT';Lines=@();Output=''}}
                    if($script:fixtureMode -eq 'stderr-limit'){return @{Complete=$true;ExitCode=1;ErrorCode='VIDNAP_PROCESS_STDERR_LIMIT';Lines=@();Output=''}}
                    $metadata=if($script:fixtureMode -eq 'parser-limit'){'x'*(16MB+1)}else{$analysisJson}
                    return @{Complete=$true;ExitCode=0;ErrorCode='';Lines=@();Output=$metadata}
                }
                Download {
                    if($script:fixtureMode -eq 'progress' -and $script:transferTicks.Count){
                        return @{Complete=$false;ExitCode=0;ErrorCode='';Lines=$script:transferTicks.Dequeue();Output=''}
                    }
                    return @{Complete=$true;ExitCode=0;ErrorCode='';Lines=$(if($script:fixtureMode -eq 'missing'){@()}elseif($script:fixtureMode -eq 'outside'){@('VIDNAP_FILE|'+$saved)}else{@('VIDNAP_FILE|'+$script:stageSaved)});Output=''}
                }
                Probe {return @{Complete=$true;ExitCode=0;ErrorCode='';Lines=@();Output=$(if($script:fixtureMode -eq 'badprobe'){'{"streams":[]}'}else{'{"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"4"},"streams":[{"codec_type":"video","codec_name":"h264","width":320,"height":180,"avg_frame_rate":"25/1"},{"codec_type":"audio","codec_name":"aac"}]}'})}}
            }
        }
        Cancel={param($Handle) $script:cancels++;$Handle.Cancelled=$true}
        Dispose={param($Handle)}
    }
    $collision=Join-Path $fixture 'collision.mp4';[IO.File]::WriteAllText($collision,'preserved original');$collisionHash=Get-BackendTestHash $collision
    foreach($case in @(@('valid','Completed'),@('badprobe','NeedsReview'),@('missing','Failed'),@('outside','Failed'),@('collision','NeedsReview'))){
        $script:fixtureMode=$case[0]
        $candidate=New-VidNapJob $job.SourceUrl $fixture $job.Selection;$candidate.State='Queued'
        $queue=New-VidNapQueue @($candidate)
        $session=New-VidNapBackendSession $queue $paths $tools $adapter
        Start-VidNapQueueItem $session $false 'edge'|Out-Null
        Assert-Backend ($candidate.State -eq 'Analyzing' -and $candidate.AttemptId) 'queued job reanalyzes with a new attempt before transfer'
        for($i=0;$i -lt 8 -and $session.Active;$i++){Receive-VidNapBackendTick $session ([DateTimeOffset]::UtcNow)|Out-Null}
        if($candidate.State -ne $case[1]){Write-Output ('Fixture diagnostic: '+$candidate.State+' / '+$session.Last.ErrorCode);Write-Output ($session.Last.Verifications|ConvertTo-Json -Depth 5)}
        Assert-Backend ($candidate.State -eq $case[1] -and -not $queue.ActiveJobId) ($case[0]+' terminal decision releases serial ownership')
        Assert-Backend ([IO.File]::Exists($saved)) 'output bytes remain even when verification fails'
        Assert-Backend ((Get-BackendTestHash $collision) -ceq $collisionHash) 'no-overwrite finalization preserves pre-existing destination bytes'
        if($case[0] -eq 'collision'){Assert-Backend ([IO.File]::Exists($script:stageSaved) -and $session.Last.ErrorCode -eq 'VIDNAP_OUTPUT_COLLISION') 'colliding new output is retained in its attempt folder for an explicit decision'}
        if($candidate.State -ne 'Completed'){
            $p=Get-VidNapBackendProgress $session ([DateTimeOffset]::UtcNow)
            Assert-Backend ($null -eq $p.SavedBytes -and $p.SavedFiles -eq 0) 'failed validation or collision does not report a saved output'
        }
    }
    $script:fixtureMode='progress'
    $candidate=New-VidNapJob $job.SourceUrl $fixture $job.Selection;$candidate.State='Queued'
    $session=New-VidNapBackendSession (New-VidNapQueue @($candidate)) $paths $tools $adapter
    $script:transferTicks=[Collections.Generic.Queue[object]]::new()
    $script:transferTicks.Enqueue(@('VIDNAP_PLAN|[{"format_id":"v","filesize":800000},{"format_id":"a","filesize":200000}]|{}','VIDNAP_PROGRESS|400000|800000|NA|NA|NA|v|downloading'))
    $script:transferTicks.Enqueue(@('VIDNAP_PROGRESS|NA|800000|NA|NA|NA|v|finished','VIDNAP_PROGRESS|40000|200000|NA|NA|NA|a|downloading'))
    $script:transferTicks.Enqueue(@('VIDNAP_PROGRESS|10000|200000|NA|NA|NA|a|downloading'))
    $script:transferTicks.Enqueue(@('VIDNAP_PROGRESS|200000|200000|NA|NA|NA|a|finished'))
    Start-VidNapQueueItem $session $false 'edge'|Out-Null
    $tick=[DateTimeOffset]::UtcNow
    Receive-VidNapBackendTick $session $tick|Out-Null
    foreach($count in @(400000,840000,810000,1000000)){
        $tick=$tick.AddSeconds(1);Receive-VidNapBackendTick $session $tick|Out-Null
        $p=Get-VidNapBackendProgress $session $tick
        Assert-Backend ($p.Bytes -eq $count -and $p.TotalBytes -eq 1000000) ('video and audio combined without duplicate counts at '+$count+" bytes (got $($p.Bytes)/$($p.TotalBytes), $($p.ByteScope))")
        Assert-Backend ($p.ByteScope -ceq 'Download' -and -not $p.TotalEstimated -and $null -eq $p.SavedBytes) 'exact whole-download metrics are distinct from the not-yet-saved file size'
    }
    Receive-VidNapBackendTick $session $tick|Out-Null
    $p=Get-VidNapBackendProgress $session $tick
    Assert-Backend ($candidate.State -eq 'Verifying' -and $null -eq $p.SavedBytes -and $p.SavedFiles -eq 0) 'transfer completion is not save completion'
    Receive-VidNapBackendTick $session $tick|Out-Null
    $p=Get-VidNapBackendProgress $session $tick
    $finalLength=([IO.FileInfo]$session.Last.Outputs[0]).Length
    Assert-Backend ($p.State -ceq 'Completed' -and $p.SavedFiles -eq 1 -and $p.SavedBytes -eq $finalLength -and $finalLength -gt 0 -and $finalLength -ne $p.TotalBytes) 'completed display receives the measured final file size, not the sum of stream sizes'
    $candidate=New-VidNapJob $job.SourceUrl $fixture $job.Selection;$candidate.State='Queued'
    $session=New-VidNapBackendSession (New-VidNapQueue @($candidate)) $paths $tools $adapter
    $script:transferTicks.Enqueue(@('VIDNAP_PLAN|[{"format_id":"v","filesize":800},{"format_id":"a","filesize":200}]|{}','VIDNAP_PROGRESS|100|800|NA|NA|NA|v|downloading'))
    $script:transferTicks.Enqueue(@('VIDNAP_PROGRESS|200|800|NA|NA|NA|v|downloading'))
    $script:transferTicks.Enqueue(@('VIDNAP_PROGRESS|NA|NA|NA|NA|NA|unexpected|downloading'))
    $script:transferTicks.Enqueue(@('VIDNAP_PROGRESS|25|300|NA|NA|NA|unexpected|downloading'))
    $script:transferTicks.Enqueue(@('VIDNAP_PROGRESS|50|300|NA|NA|NA|unexpected|downloading'))
    Start-VidNapQueueItem $session $false 'edge'|Out-Null
    $tick=[DateTimeOffset]::UtcNow
    Receive-VidNapBackendTick $session $tick|Out-Null
    for($i=0;$i -lt 2;$i++){$tick=$tick.AddSeconds(1);Receive-VidNapBackendTick $session $tick|Out-Null}
    $p=Get-VidNapBackendProgress $session $tick
    Assert-Backend ($p.ByteScope -ceq 'Download' -and $p.Bytes -eq 200 -and $p.RateBytesPerSecond -gt 0) 'identified stream has a measured rate before the fallback'
    $tick=$tick.AddSeconds(1);Receive-VidNapBackendTick $session $tick|Out-Null
    $p=Get-VidNapBackendProgress $session $tick
    Assert-Backend ($p.ByteScope -ceq 'Stream' -and $p.Bytes -eq 0 -and $null -eq $p.TotalBytes -and $p.RateBytesPerSecond -eq 0 -and $null -eq $p.CurrentStepEtaSeconds) 'unidentified byte position never inherits the previous stream counters or ETA'
    $tick=$tick.AddSeconds(1);Receive-VidNapBackendTick $session $tick|Out-Null
    $p=Get-VidNapBackendProgress $session $tick
    Assert-Backend ($p.ByteScope -ceq 'Stream' -and $p.Bytes -eq 25 -and $p.TotalBytes -eq 300 -and $p.RateBytesPerSecond -eq 0) 'first valid counter after a gap does not measure a rate from an invented zero'
    $tick=$tick.AddSeconds(1);Receive-VidNapBackendTick $session $tick|Out-Null
    Assert-Backend ((Get-VidNapBackendProgress $session $tick).RateBytesPerSecond -eq 25) 'a second measured counter restores a current-stream rate'
    Receive-VidNapBackendTick $session $tick|Out-Null
    Receive-VidNapBackendTick $session $tick|Out-Null
    Assert-Backend ($candidate.State -ceq 'Completed') 'missing progress telemetry does not prevent a verified save'
    $tracker=@{PlanSeen=$false;Streams=$null}
    $raw=@{Bytes=100;Total=500;TotalEstimated=$false}
    Set-VidNapTransferPlan $tracker 'VIDNAP_PLAN|[{"format_id":"v","filesize_approx":500},{"format_id":"a"}]|{}'
    Update-VidNapTransferCounts $tracker (ConvertFrom-ProgressLine 'VIDNAP_PROGRESS|100|NA|500|NA|NA|v|downloading')
    $p=Get-VidNapTransferCounts $tracker $raw
    Assert-Backend ($p.ByteScope -ceq 'Download' -and $p.Bytes -eq 100 -and $null -eq $p.Total -and -not $p.Estimated) 'one missing stream size keeps the whole total unknown'
    Update-VidNapTransferCounts $tracker (ConvertFrom-ProgressLine 'VIDNAP_PROGRESS|100|NA|300|NA|NA|a|downloading')
    $p=Get-VidNapTransferCounts $tracker $raw
    Assert-Backend ($p.Bytes -eq 200 -and $p.Total -eq 800 -and $p.Estimated) 'an estimated stream makes the whole total estimated'
    Update-VidNapTransferCounts $tracker (ConvertFrom-ProgressLine 'VIDNAP_PROGRESS|500|500|NA|NA|NA|v|finished')
    Update-VidNapTransferCounts $tracker (ConvertFrom-ProgressLine 'VIDNAP_PROGRESS|100|200|NA|NA|NA|a|downloading')
    $p=Get-VidNapTransferCounts $tracker $raw
    Assert-Backend ($p.Bytes -eq 600 -and $p.Total -eq 700 -and -not $p.Estimated) 'exact reported totals supersede estimates for the same selected streams'
    Update-VidNapTransferCounts $tracker (ConvertFrom-ProgressLine 'VIDNAP_PROGRESS|100|500|NA|NA|NA|unexpected|downloading')
    Assert-Backend ((Get-VidNapTransferCounts $tracker $raw).ByteScope -ceq 'Stream') 'an unplanned stream invalidates the whole-download claim'
    $tracker=@{PlanSeen=$false;Streams=$null}
    Set-VidNapTransferPlan $tracker 'VIDNAP_PLAN|NA|{"format_id":"a","filesize":100}'
    Update-VidNapTransferCounts $tracker (ConvertFrom-ProgressLine 'VIDNAP_PROGRESS|101|100|NA|NA|NA|a|downloading')
    $p=Get-VidNapTransferCounts $tracker $raw
    Assert-Backend ($p.Bytes -eq 101 -and $null -eq $p.Total) 'an exact total contradicted by observed bytes no longer bounds progress'
    Set-VidNapTransferPlan $tracker 'VIDNAP_PLAN|NA|{"format_id":"a","filesize":200}'
    Assert-Backend ((Get-VidNapTransferCounts $tracker $raw).ByteScope -ceq 'Stream') 'a second selected plan is not combined with the first item'
    foreach($invalid in @('VIDNAP_PLAN|[{"format_id":"v"},{"format_id":"v"}]|{}','VIDNAP_PLAN|not-json|{}')){
        $tracker=@{PlanSeen=$false;Streams=$null};Set-VidNapTransferPlan $tracker $invalid
        Assert-Backend ((Get-VidNapTransferCounts $tracker $raw).ByteScope -ceq 'Stream') 'ambiguous or malformed plan falls back to labeled stream progress'
    }
    foreach($limitCase in @(@('capture-limit','VIDNAP_ANALYSIS_LIMIT'),@('parser-limit','VIDNAP_ANALYSIS_LIMIT'),@('stderr-limit','VIDNAP_PROCESS_STDERR_LIMIT'))){
        $script:fixtureMode=$limitCase[0]
        $candidate=New-VidNapJob $job.SourceUrl $fixture $job.Selection;$candidate.State='Queued'
        $session=New-VidNapBackendSession (New-VidNapQueue @($candidate)) $paths $tools $adapter
        $before=$script:starts
        Start-VidNapQueueItem $session $false 'edge'|Out-Null
        Receive-VidNapBackendTick $session ([DateTimeOffset]::UtcNow)|Out-Null
        Assert-Backend ($candidate.State -eq 'Failed' -and $session.Last.ErrorCode -ceq $limitCase[1] -and $script:starts -eq ($before+1)) ($limitCase[0]+' reports the correct limit and never starts transfer')
    }
    $script:fixtureMode='valid'
    $candidate=New-VidNapJob $job.SourceUrl $fixture $job.Selection;$candidate.State='Queued'
    $queue=New-VidNapQueue @($candidate);$session=New-VidNapBackendSession $queue $paths $tools $adapter
    Start-VidNapQueueItem $session $false 'edge'|Out-Null
    Stop-VidNapBackendJob $session
    Receive-VidNapBackendTick $session ([DateTimeOffset]::UtcNow)|Out-Null
    Assert-Backend ($candidate.State -eq 'Cancelled' -and $script:cancels -eq 1) 'cooperative controller cancellation stops only its owned worker'
    $snapshot=Get-VidNapBackendProgress $session ([DateTimeOffset]::UtcNow)
    Assert-Backend ($null -eq $snapshot.OverallEtaSeconds -and $snapshot.HeartbeatUtc -and $snapshot.EtaReason -and $null -eq $snapshot.SavedBytes) 'cancelled snapshot reports no saved bytes and explains unavailable overall ETA'
    $later=Get-VidNapBackendProgress $session ([DateTimeOffset]::UtcNow.AddMinutes(5))
    Assert-Backend ($snapshot.CompletedSteps -eq 0 -and $later.ElapsedSeconds -eq $snapshot.ElapsedSeconds) 'early cancellation does not invent completed steps or keep elapsed time running'
    Assert-BackendCode {New-VidNapProbeRequest (Join-Path $fixture 'missing.mp4') $paths $tools} 'VIDNAP_BACKEND_OUTPUT'
    $loaded=New-VidNapJob $job.SourceUrl $fixture $job.Selection;$loaded.State='Queued';$loaded.RequiresAuthentication=$true
    $session=New-VidNapBackendSession (New-VidNapQueue @($loaded)) $paths $tools $adapter
    $before=$script:starts;Start-VidNapQueueItem $session $false 'edge'|Out-Null
    Assert-Backend ($loaded.State -eq 'NeedsAuthentication' -and $script:starts -eq $before) 'no worker starts when fresh authentication consent is absent'
    if(-not ('VidNapJobStore' -as [type])){Add-Type -Path (Join-Path $root 'VidNap.JobStore.cs') -ReferencedAssemblies System.Security}
    Assert-Backend ($null -ne (Get-Command New-VidNapPersistentBackendSession -ErrorAction SilentlyContinue)) 'persistent coordinator adapter exists'
    $statePath=Join-Path $fixture 'coordinator.vnjs'
    $session=New-VidNapPersistentBackendSession $statePath $paths $tools $adapter
    $candidate=New-VidNapJob $job.SourceUrl $fixture $job.Selection;$candidate.State='Queued'
    $session.Queue.Jobs=@($candidate)
    Assert-Backend (Save-VidNapBackendSession $session) 'queue addition can be durably acknowledged'
    Start-VidNapQueueItem $session $false 'edge'|Out-Null
    $restarted=New-VidNapPersistentBackendSession $statePath $paths $tools $adapter
    Assert-Backend ($restarted.Queue.Jobs[0].State -eq 'Interrupted' -and -not $restarted.Active) 'in-flight coordinator checkpoint restores stopped, no process admission'
    & $adapter.Cancel $session.Active.Handle;& $adapter.Dispose $session.Active.Handle
    $session.Active=$null;$session.Queue.ActiveJobId=''
    Assert-Backend (Resume-VidNapBackendJob $restarted $restarted.Queue.Jobs[0].JobId $false 'edge') 'restored job explicitly resumes through the coordinator'
    Stop-VidNapBackendJob $restarted;Receive-VidNapBackendTick $restarted ([DateTimeOffset]::UtcNow)|Out-Null
    $after=Read-VidNapJobState $statePath
    Assert-Backend ($after.Jobs.Count -eq 0 -and $after.History[-1].Result -eq 'Cancelled' -and $after.Generation -ge 3) 'cancel terminal decision is durably committed in URL-free history'
    Write-Output "PASS: $script:BackendChecks backend coordinator checks; request contracts and synthetic serial lifecycle, verification, failure, cancellation and consent."
}finally{Remove-BackendTestDirectory $fixture $root}
