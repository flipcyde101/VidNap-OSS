. (Join-Path $PSScriptRoot 'Backend.TestSupport.ps1')
$root=Split-Path $PSScriptRoot -Parent
foreach($name in @('Core','Storage','Analysis','Jobs','Captions','Backend')){. (Join-Path $root ('VidNap.'+$name+'.ps1'))}
if(Test-Path -LiteralPath (Join-Path $root 'VidNap.Manager.ps1')){. (Join-Path $root 'VidNap.Manager.ps1')}
Assert-Backend ($null -ne (Get-Command New-VidNapManager -ErrorAction SilentlyContinue)) 'preview manager is implemented'
Assert-Backend ($null -ne (Get-Command Get-VidNapManagerHandleError -ErrorAction SilentlyContinue)) 'preview retains privacy-safe error classifications'
$diagnosticHandle=[pscustomobject]@{LastError='';Worker=[pscustomobject]@{StandardError="WARNING: unrelated preface`nERROR: Failed curl: (35) SSL_connect private-source-title"}}
Assert-Backend ((Get-VidNapManagerHandleError $diagnosticHandle) -ceq 'TLS_HANDSHAKE') 'multiline transport errors become fixed technical codes, not raw private text'
$fixture=New-BackendTestDirectory $root
try {
 $data=Join-Path $fixture 'state';$media=Join-Path $fixture 'media'
 [IO.Directory]::CreateDirectory($data)|Out-Null;[IO.Directory]::CreateDirectory($media)|Out-Null
 $paths=[pscustomobject]@{DataRoot=$data;MediaRoot=$media;ApplicationRoot=$root}
 Initialize-VidNapBackendTypes $paths
 $tool=Join-Path $fixture 'fixture.exe';[IO.File]::WriteAllText($tool,'not executed')
 $tools=@{};foreach($n in @('YtDlp','Ffmpeg','Ffprobe')){$tools[$n]=@{Path=$tool;Sha256=(Get-BackendTestHash $tool)}}
 $script:mode='hold';$script:started=0;$script:cancelled=0
 $analysis='{"id":"fixture","title":"<script>private title</script>","duration":4,"formats":[{"format_id":"one","ext":"mp4","vcodec":"avc1","acodec":"mp4a","abr":128,"width":320,"height":180,"fps":25}],"format_id":"one","subtitles":{"en":[{"ext":"vtt"}]},"automatic_captions":{"es":[{"ext":"vtt"}]}}'
 $normalized=ConvertFrom-VidNapAnalysis $analysis
 Assert-Backend ((Get-VidNapDataValue $normalized.Formats[0] 'AudioBitrateKbps' $null) -eq 128) 'normalized audio bitrate evidence is retained for quality-preserving choices'
 $adapter=[pscustomobject]@{
  Start={param($r)
   $script:started++
   $file=Join-Path $r.WorkingDirectory ('fixture-'+$script:started+'.mp4')
   if($r.Kind -eq 'Download'){[IO.File]::WriteAllText($file,'new synthetic output')}
   if($r.Kind -eq 'Captions'){$file=Join-Path $r.WorkingDirectory 'source.en.vtt';[IO.File]::WriteAllText($file,"WEBVTT`n`n00:00:00.000 --> 00:00:01.000`n&lt;b&gt;private caption&lt;/b&gt;`n")}
   if($r.Kind -eq 'PrepareAudio'){[IO.File]::WriteAllText($r.Arguments[-1],'synthetic audio, never executed')}
   if($r.Kind -eq 'Whisper'){$at=[Array]::IndexOf($r.Arguments,'-of');[IO.File]::WriteAllText(($r.Arguments[$at+1]+'.srt'),"1`n00:00:00,000 --> 00:00:01,000`nsynthetic generated speech`n")}
   $h=[pscustomobject]@{Kind=$r.Kind;Cancelled=$false;File=$file}
   if($r.Kind -eq 'Analyze' -and $script:mode -eq 'stderr-classified'){
    $h|Add-Member NoteProperty Worker ([pscustomobject]@{StandardError='ERROR: SSL_connect private-source-title'})
   }
   $h
  }
  Poll={param($h)
   if($h.Cancelled){return @{Complete=$true;ExitCode=1;ErrorCode='VIDNAP_PROCESS_CANCELLED';Output='';Lines=@()}}
   if($script:mode -eq 'hold'){return @{Complete=$false;ExitCode=$null;ErrorCode='';Output='';Lines=@()}}
   if($h.Kind -eq 'Analyze' -and $script:mode -eq 'capture-limit'){return @{Complete=$true;ExitCode=1;ErrorCode='VIDNAP_PROCESS_OUTPUT_LIMIT';Output='';Lines=@()}}
   if($h.Kind -eq 'Analyze' -and $script:mode -eq 'parser-limit'){return @{Complete=$true;ExitCode=0;ErrorCode='';Output=('x'*(16MB+1));Lines=@()}}
   if($h.Kind -eq 'Analyze' -and $script:mode -in @('stderr-limit','stderr-classified')){return @{Complete=$true;ExitCode=1;ErrorCode='VIDNAP_PROCESS_STDERR_LIMIT';Output='';Lines=@()}}
   $out=if($h.Kind -eq 'Analyze'){$analysis}elseif($h.Kind -eq 'Probe'){'{"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"4"},"streams":[{"codec_type":"video","codec_name":"h264","width":320,"height":180,"avg_frame_rate":"25/1"},{"codec_type":"audio","codec_name":"aac"}]}'}else{''}
   @{Complete=$true;ExitCode=0;ErrorCode='';Output=$out;Lines=$(if($h.Kind -eq 'Download'){@('VIDNAP_FILE|'+$h.File)}else{@()})}
  }
  Cancel={param($h) $h.Cancelled=$true;$script:cancelled++}
  Dispose={param($h)}
 }
 $manager=New-VidNapManager $paths $tools $adapter
 $added=Add-VidNapManagerLinks $manager @('https://example.com/a','https://example.com/b','https://example.com/c') @{Media='video';Format='best'} $false 'firefox'
 Assert-Backend ($added.Count -eq 3) 'batch admission retains all three links'
 Receive-VidNapManagerTick $manager
 $s=Get-VidNapManagerState $manager
 Assert-Backend ($s.activeCount -eq 2 -and @($s.jobs|Where-Object state -eq 'Analyzing').Count -eq 2) 'only two engine slots are admitted'
 Assert-Backend (@($s.jobs|Where-Object state -eq 'Draft').Count -eq 1) 'additional link remains visibly waiting'
 Stop-VidNapManagerItem $manager $added[0]
 Receive-VidNapManagerTick $manager
 $s=Get-VidNapManagerState $manager
 Assert-Backend ($script:cancelled -eq 1 -and $s.jobs[0].state -eq 'Cancelled' -and $s.activeCount -eq 2) 'one cancellation releases a slot without stopping the other job'
 Assert-Backend (@($s.jobs|Where-Object state -eq 'Analyzing').Count -eq 2) 'waiting link uses the released slot'
 $script:mode='complete'
 Receive-VidNapManagerTick $manager
 Assert-Backend (@((Get-VidNapManagerState $manager).jobs|Where-Object state -eq 'Ready').Count -eq 2) 'analysis does not silently begin a download'
 Assert-BackendCode {Add-VidNapManagerLinks $manager @('https://example.com/b') @{Media='video';Format='best'} $false 'edge'} 'VIDNAP_DUPLICATE'
 Start-VidNapManagerQueue $manager
 for($i=0;$i -lt 8;$i++){Receive-VidNapManagerTick $manager;Assert-Backend ((Get-VidNapManagerState $manager).activeCount -le 2) 'two-slot limit holds through analysis transfer and verification'}
 $s=Get-VidNapManagerState $manager
 Assert-Backend (@($s.jobs|Where-Object state -eq 'Completed').Count -eq 2 -and $s.activeCount -eq 0) 'both independently verified outputs finish'
 foreach($jobView in @($s.jobs|Where-Object state -eq 'Completed')){
  $output=Get-VidNapManagerMedia $manager $jobView.id 0
  Assert-Backend ($jobView.progress.savedBytes -eq ([IO.FileInfo]$output.Path).Length -and $jobView.progress.savedFiles -eq 1) 'each concurrent job publishes its own final D: file length'
 }
 Assert-Backend (@($s.history|Where-Object result -eq 'Completed').Count -eq 2) 'completed outputs enter history'
 $clear=Read-VidNapJobState $manager.StorePath
 Assert-Backend ($clear.Jobs.Count -eq 0 -and ($clear|ConvertTo-Json -Depth 12) -notmatch 'private title|example.com') 'terminal history persists without source URL or title'
 $restarted=New-VidNapManager $paths $tools $adapter
 Assert-Backend ((Get-VidNapManagerState $restarted).activeCount -eq 0 -and $script:started -gt 0) 'restoring state never starts an engine'
 Dismiss-VidNapManagerItem $manager $added[0]
 Assert-Backend (@((Get-VidNapManagerState $manager).jobs|Where-Object dismissed).Count -eq 1) 'dismissal hides a terminal row without removing history'
 Assert-Backend (@(Get-ChildItem -LiteralPath $media -Filter '*.mp4' -File).Count -eq 2) 'dismissal preserves media files'
 Assert-BackendCode {Dismiss-VidNapManagerItem $manager 'not-a-job'} 'VIDNAP_PREVIEW_JOB'
 Assert-BackendCode {Get-VidNapManagerMedia $manager 'not-a-job' 0} 'VIDNAP_PREVIEW_JOB'
 Assert-BackendCode {Start-VidNapManagerGeneration $manager $added[1] 0} 'VIDNAP_TRANSCRIPTION_APPROVAL'
 Assert-Backend ((Get-VidNapManagerState $manager).transcription.ready -eq $false) 'generation does not pretend missing prerequisites are ready'
 Assert-BackendCode {Start-VidNapManagerCaption $manager $added[1] 'es' $false} 'VIDNAP_CAPTION_CONSENT'
 $captionId=Start-VidNapManagerCaption $manager $added[1] 'en' $false
 $waiting=@(Get-VidNapManagerOperationViews $manager ([DateTimeOffset]::UtcNow))[0].progress
 Assert-Backend ($waiting.currentStep -eq 1 -and $waiting.completedSteps -eq 0 -and $waiting.remainingSteps -eq 4) 'queued transcript work does not invent completed steps'
 Assert-BackendCode {Start-VidNapManagerCaption $manager $added[1] 'en' $false} 'VIDNAP_DUPLICATE'
 Receive-VidNapManagerTick $manager;Receive-VidNapManagerTick $manager
 $s=Get-VidNapManagerState $manager
 Assert-Backend ($s.operations[0].state -eq 'Completed' -and $s.transcripts[0].provenance -eq 'SourceManual') 'manual source captions have explicit provenance and complete only after export'
 $view=Get-VidNapManagerTranscript $manager $s.transcripts[0].id
 Assert-Backend ($view.cues.Count -eq 1 -and $view.cues[0].text -ceq '<b>private caption</b>') 'caption markup-looking content stays literal text at the API boundary'
 foreach($format in @('txt','srt','vtt')){Assert-Backend ([IO.File]::Exists((Export-VidNapManagerTranscript $manager $view.record.id $format).path)) ('source transcript '+$format+' is saved on D:')}
 Dismiss-VidNapManagerItem $manager $captionId
 Assert-Backend ((Get-VidNapManagerState $manager).operations.Count -eq 0 -and [IO.File]::Exists($view.record.files.srt)) 'dismissing transcript activity preserves the saved transcript'
 $restored=New-VidNapManager $paths $tools $adapter
 Assert-Backend ((Get-VidNapManagerState $restored).transcripts.Count -eq 1) 'encrypted transcript index survives restart without starting work'
 $model=Join-Path $fixture 'fixture-model.bin';[IO.File]::WriteAllText($model,'synthetic model, never executed')
 $policy=@{Approved=$true;ToolPath=$tool;ToolSha256=(Get-BackendTestHash $tool);ModelFile=$model;ModelSha256=(Get-BackendTestHash $model);ModelLicense='fixture only';ModelSource='local fixture'}
 $generated=New-VidNapManager $paths $tools $adapter $policy
 $opId=Start-VidNapManagerGeneration $generated $added[1] 0
 for($i=0;$i -lt 6;$i++){Receive-VidNapManagerTick $generated}
 $gs=Get-VidNapManagerState $generated
 Assert-Backend ($gs.operations[0].state -eq 'Completed' -and @($gs.transcripts|Where-Object provenance -eq 'LocalGenerated').Count -eq 1) 'generation state machine probes audio prepares PCM and labels the generated result'
 $script:mode='complete'
 $more=Add-VidNapManagerLinks $manager @('https://example.com/d','https://example.com/e') @{Media='video';Format='best'} $false 'chrome'
 Receive-VidNapManagerTick $manager;Receive-VidNapManagerTick $manager;Start-VidNapManagerQueue $manager
 Receive-VidNapManagerTick $manager;Receive-VidNapManagerTick $manager
 $script:mode='hold';Stop-VidNapManagerItem $manager $more[0];Receive-VidNapManagerTick $manager
 $s=Get-VidNapManagerState $manager
 Assert-Backend ((Get-VidNapManagerEntry $manager $more[0]).Job.State -eq 'Cancelled' -and (Get-VidNapManagerEntry $manager $more[1]).Job.State -eq 'Running') 'cancelling a running transfer never cancels its concurrent neighbor'
 Close-VidNapManager $manager
 $reopened=New-VidNapManager $paths $tools $adapter
 Assert-Backend (@((Get-VidNapManagerState $reopened).jobs|Where-Object state -eq 'Interrupted').Count -eq 1 -and (Get-VidNapManagerState $reopened).activeCount -eq 0) 'an interrupted transfer restores stopped and requires an explicit resume'
 Assert-Backend (-not $reopened.Entries[0].Consent -and -not $reopened.Entries[0].Job.AuthenticationConsent) 'restart does not restore sign-in consent'
 $consentData=Join-Path $fixture 'consent-state';[IO.Directory]::CreateDirectory($consentData)|Out-Null
 $consentPaths=[pscustomobject]@{DataRoot=$consentData;MediaRoot=$media;ApplicationRoot=$root}
 $cm=New-VidNapManager $consentPaths $tools $adapter
 $one=@(Add-VidNapManagerLinks $cm @('https://example.com/consent') @{Media='video';Format='best'} $true 'firefox')
 $script:mode='complete';Receive-VidNapManagerTick $cm;Receive-VidNapManagerTick $cm
 Start-VidNapManagerQueue $cm '' $false 'edge'
 $ce=Get-VidNapManagerEntry $cm $one[0]
 $request=New-VidNapEngineRequest $ce.Job $consentPaths $tools 'Analyze' $null $ce.Consent $ce.Browser
 Assert-Backend ($request.Arguments -notcontains '--cookies-from-browser') 'unchecking sign-in before Download suppresses cookie access even after consented analysis'
 Assert-BackendCode {Start-VidNapManagerQueue $cm 'not-a-job'} 'VIDNAP_PREVIEW_JOB'
 $selectionIds=@(Add-VidNapManagerLinks $cm @('https://example.com/selection') @{Media='video';Format='best'})
 $selectionIds+=@(Add-VidNapManagerLinks $cm @('https://example.com/selection') @{Media='video';Format='mp4'})
 Assert-BackendCode {Set-VidNapManagerSelection $cm $selectionIds[1] @{Media='video';Format='best'}} 'VIDNAP_DUPLICATE'
 Assert-Backend ((Get-VidNapManagerEntry $cm $selectionIds[1]).Job.Selection.Format -ceq 'mp4') 'a duplicate selection edit preserves the previous valid export'
 Set-VidNapManagerSelection $cm $selectionIds[0] @{Media='video';Format='best'}
 Assert-Backend ((Get-VidNapManagerEntry $cm $selectionIds[0]).Job.Selection.Format -ceq 'best') 'an unchanged selection does not collide with its own row'
 $retryData=Join-Path $fixture 'retry-state';[IO.Directory]::CreateDirectory($retryData)|Out-Null
 $retryPaths=[pscustomobject]@{DataRoot=$retryData;MediaRoot=$media;ApplicationRoot=$root}
 $rm=New-VidNapManager $retryPaths $tools $adapter
 $retryIds=@(Add-VidNapManagerLinks $rm @('https://example.com/retry-a','https://example.com/retry-b','https://example.com/retry-c') @{Media='video';Format='best'})
 $script:mode='hold';Receive-VidNapManagerTick $rm
 Stop-VidNapManagerItem $rm $retryIds[0];Receive-VidNapManagerTick $rm
 Resume-VidNapManagerItem $rm $retryIds[0]
 $queued=Get-VidNapManagerEntry $rm $retryIds[0]
 Assert-Backend ($queued.Job.State -ceq 'Queued') 'a retry waiting for an occupied slot is visibly queued, not terminal'
 Assert-BackendCode {Dismiss-VidNapManagerItem $rm $retryIds[0]} 'VIDNAP_PREVIEW_BUSY'
 $beforeRetry=$script:started;Stop-VidNapManagerItem $rm $retryIds[0]
 Receive-VidNapManagerTick $rm
 Assert-Backend ($queued.Job.State -ceq 'Cancelled' -and $queued.Mode -ceq 'Idle' -and $script:started -eq $beforeRetry) 'a cancelled waiting retry cannot start later or become hidden active work'
 Close-VidNapManager $rm
 $relinkData=Join-Path $fixture 'relink-state';[IO.Directory]::CreateDirectory($relinkData)|Out-Null
 $relinkPaths=[pscustomobject]@{DataRoot=$relinkData;MediaRoot=$media;ApplicationRoot=$root}
 $lm=New-VidNapManager $relinkPaths $tools $adapter
 $originalId=@(Add-VidNapManagerLinks $lm @('https://example.com/private?case=fixture') @{Media='video';Format='best'})[0]
 $lm=New-VidNapManager $relinkPaths $tools $adapter
 Assert-Backend ($lm.Entries[0].Job.State -ceq 'NeedsSourceUrl') 'an unsafe-to-persist query restores without its private URL'
 Assert-BackendCode {Add-VidNapManagerLinks $lm @('https://example.com/private?case=fixture','https://example.com/private?case=fixture') @{Media='video';Format='best'}} 'VIDNAP_DUPLICATE'
 Assert-Backend ($lm.Entries[0].Job.State -ceq 'NeedsSourceUrl' -and -not $lm.Entries[0].Job.SourceUrl) 'an invalid relink batch leaves the existing row unchanged'
 $restoredId=@(Add-VidNapManagerLinks $lm @('https://example.com/private?case=fixture') @{Media='video';Format='best'})[0]
 Assert-Backend ($restoredId -ceq $originalId -and $lm.Entries.Count -eq 1 -and $lm.Entries[0].Job.SourceUrl -and $lm.Entries[0].Mode -ceq 'AnalyzeQueued') 'pasting a missing source rebinds its existing stopped row without a duplicate dead end'
 Stop-VidNapManagerItem $lm $originalId
 Assert-Backend ($lm.Entries[0].Job.State -ceq 'Cancelled') 'a rebound source can be cancelled before work starts'
 $lm.Entries[0].Job.State='NeedsSourceUrl';$lm.Entries[0].Job.SourceUrl='';$lm.Entries[0].HistoryRecorded=$false
 Stop-VidNapManagerItem $lm $originalId;Dismiss-VidNapManagerItem $lm $originalId
 Assert-Backend ($lm.Entries[0].Job.State -ceq 'Cancelled' -and $lm.Entries[0].Dismissed) 'a missing-source row can be discarded without any engine or source access'
 $limitData=Join-Path $fixture 'limit-state';[IO.Directory]::CreateDirectory($limitData)|Out-Null
 $limitPaths=[pscustomobject]@{DataRoot=$limitData;MediaRoot=$media;ApplicationRoot=$root}
 $limited=New-VidNapManager $limitPaths $tools $adapter
 foreach($case in @(@('capture-limit','VIDNAP_ANALYSIS_LIMIT'),@('parser-limit','VIDNAP_ANALYSIS_LIMIT'),@('stderr-limit','VIDNAP_PROCESS_STDERR_LIMIT'),@('stderr-classified','TLS_HANDSHAKE'))){
  $script:mode=$case[0]
  $id=@(Add-VidNapManagerLinks $limited @('https://example.com/'+$case[0]) @{Media='video';Format='best'})[0]
  $before=$script:started
  Receive-VidNapManagerTick $limited;Receive-VidNapManagerTick $limited
  $row=@((Get-VidNapManagerState $limited).jobs|Where-Object id -eq $id)[0]
  Assert-Backend ($row.state -ceq 'Failed' -and $row.errorCode -ceq $case[1] -and $script:started -eq ($before+1)) ($case[0]+' reports the correct initial analysis error before transfer')
  $before=$script:started
  Resume-VidNapManagerItem $limited $id
  Receive-VidNapManagerTick $limited;Receive-VidNapManagerTick $limited
  $row=@((Get-VidNapManagerState $limited).jobs|Where-Object id -eq $id)[0]
  Assert-Backend ($row.state -ceq 'Failed' -and $row.errorCode -ceq $case[1] -and $script:started -eq ($before+1)) ($case[0]+' reports the correct retry error before transfer')
 }
 $log=Join-Path $data 'preview-events.jsonl'
 Assert-Backend ([IO.File]::Exists($log) -and [IO.File]::ReadAllText($log) -notmatch 'example.com|private title|private caption|generated speech|script>') 'diagnostics contain codes not source title or transcript data'
 Write-Output "PASS: $script:BackendChecks preview manager checks; concurrent scheduling, independent cancellation, evidence-based completion, encrypted persistence, consent and private diagnostics."
}finally {Remove-BackendTestDirectory $fixture $root}
