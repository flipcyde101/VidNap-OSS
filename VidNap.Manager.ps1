Set-StrictMode -Version Latest

function Get-VidNapManagerHandleError($Handle) {
    if(-not $Handle){return ''}
    $known=@('TLS_CERTIFICATE','TLS_HANDSHAKE','AUTH_DATABASE_LOCKED','AUTH_DECRYPTION','DISK_FULL','ACCESS_DENIED','FORMAT_UNAVAILABLE','EXTRACTOR_UNSUPPORTED','EXTRACTOR_PARSE','NETWORK_TIMEOUT')
    $last=[string](Get-VidNapDataValue $Handle 'LastError' '')
    if($last -cin $known -or $last -cmatch '^HTTP_[0-9]{3}$'){return $last}
    $worker=Get-VidNapDataValue $Handle 'Worker' $null
    if($worker -and $worker.PSObject.Properties.Name -contains 'StandardError'){
        foreach($line in [regex]::Split([string]$worker.StandardError,"\r?\n")){
            $diagnostic=Get-VidNapDiagnosticError $line
            if($diagnostic -and ($diagnostic.Code -cin $known -or $diagnostic.Code -cmatch '^HTTP_[0-9]{3}$')){return $diagnostic.Code}
        }
    }
    return ''
}

function New-VidNapManagerEntry($Job) {
    return [pscustomobject]@{Job=$Job;Mode='Restored';Analysis=$null;Handle=$null;Session=$null;Consent=$false;Browser='edge';AutoDownload=$false
        Dismissed=$false;ErrorCode='';Started=$null;Ended=$null;Progress=$null;HistoryRecorded=$false}
}

function Write-VidNapManagerEvent($Manager,[string]$Code) {
    if($Code -notmatch '^[A-Z][A-Z0-9_]{0,63}$'){return}
    try {
        $path=Join-Path $Manager.Paths.DataRoot 'preview-events.jsonl'
        if([IO.File]::Exists($path) -and ([IO.FileInfo]$path).Length -ge 1MB){$Manager.DiagnosticError='VIDNAP_LOG_FULL';return}
        $line=@{utc=[DateTimeOffset]::UtcNow.ToString('o');code=$Code}|ConvertTo-Json -Compress
        [IO.File]::AppendAllText($path,$line+"`n",[Text.UTF8Encoding]::new($false))
    }catch{$Manager.DiagnosticError='VIDNAP_LOG_WRITE'}
}

function Save-VidNapManager($Manager) {
    try {
        # Fold terminal session records into the same durable snapshot as job state.
        foreach($entry in $Manager.Entries){
            if($entry.Session){foreach($record in $entry.Session.History){
                if(-not $Manager.History.Contains($record)){$Manager.History.Add($record)}
            }}
        }
        $Manager.Generation=Save-VidNapJobState $Manager.StorePath @($Manager.Entries|ForEach-Object {$_.Job}) @($Manager.History.ToArray()) $Manager.Generation
        $Manager.PersistenceError='';return $true
    }catch{$Manager.PersistenceError='VIDNAP_BACKEND_STATE_NOT_SAVED';Write-VidNapManagerEvent $Manager $Manager.PersistenceError;return $false}
}

function New-VidNapManager($Paths,$Tools,$Adapter=$null,$TranscriptionPolicy=$null) {
    foreach($path in @($Paths.DataRoot,$Paths.MediaRoot)) {
        $local=ConvertTo-VidNapLocalDirectory $path
        if([IO.Path]::GetPathRoot($local) -ine 'D:\' -or -not [IO.Directory]::Exists($local)){throw 'VIDNAP_PREVIEW_STORAGE: Existing explicit D: storage is required.'}
        Assert-VidNapPrivateDirectory $local
    }
    Initialize-VidNapBackendTypes $Paths
    if($null -eq $Adapter){$Adapter=New-VidNapNativeAdapter $Paths}
    $store=Join-Path $Paths.DataRoot 'queue.vnjs';$saved=Read-VidNapJobState $store
    if($saved.ErrorCode){throw 'VIDNAP_PREVIEW_RECOVERY: Saved queue requires review. No work started.'}
    $m=[pscustomobject]@{Paths=$Paths;Tools=$Tools;Adapter=$Adapter;StorePath=$store;Generation=$saved.Generation;PersistenceError='';DiagnosticError=''
        Entries=[Collections.Generic.List[object]]::new();History=[Collections.Generic.List[object]]::new();Operations=[Collections.Generic.List[object]]::new()
        Transcripts=[Collections.Generic.List[object]]::new();TranscriptGeneration=0L;TranscriptionPolicy=$TranscriptionPolicy;TranscriptionReady=$false;MaxConcurrent=2}
    foreach($job in $saved.Jobs){$m.Entries.Add((New-VidNapManagerEntry $job))}
    foreach($entry in $saved.History){$m.History.Add($entry)}
    $index=[VidNapJobStore]::Read((Join-Path $Paths.DataRoot 'transcripts.vnjs'))
    if($index.ErrorCode){throw 'VIDNAP_PREVIEW_RECOVERY: Transcript index requires review. Existing files were preserved.'}
    $m.TranscriptGeneration=$index.Generation
    if($index.Json){
        $records=@((ConvertFrom-Json $index.Json).records)
        if($records.Count -gt 1000){throw 'VIDNAP_PREVIEW_LIMIT: Transcript index is too large.'}
        foreach($record in $records){
            $id=[Guid]::Empty
            if(-not [Guid]::TryParse([string]$record.id,[ref]$id) -or $record.provenance -cnotin @('SourceManual','SourceAutomatic','LocalGenerated')){throw 'VIDNAP_PREVIEW_RECOVERY: Unsupported transcript index.'}
            foreach($f in @($record.files.txt,$record.files.srt,$record.files.vtt)){
                $parent=ConvertTo-VidNapLocalDirectory ([IO.Path]::GetDirectoryName($f))
                if($parent -ine (Join-Path $Paths.MediaRoot 'Transcripts')){throw 'VIDNAP_PREVIEW_RECOVERY: Unsupported transcript output reference.'}
            }
            $m.Transcripts.Add($record)
        }
    }
    if($TranscriptionPolicy -and (Get-VidNapDataValue $TranscriptionPolicy 'Approved' $false) -ceq $true){
        $tool=[string](Get-VidNapDataValue $TranscriptionPolicy 'ToolPath' '');$model=[string](Get-VidNapDataValue $TranscriptionPolicy 'ModelFile' '')
        try {
            Assert-VidNapRegularFile $tool|Out-Null;Assert-VidNapRegularFile $model|Out-Null
            $m.TranscriptionReady=((Get-VidNapFileSha256 $tool) -ieq $TranscriptionPolicy.ToolSha256 -and (Get-VidNapFileSha256 $model) -ieq $TranscriptionPolicy.ModelSha256)
        }catch{$m.TranscriptionReady=$false}
    }
    Write-VidNapManagerEvent $m 'VIDNAP_PREVIEW_STARTED'
    return $m
}

function Get-VidNapManagerEntry($Manager,[string]$Id) {
    $found=@($Manager.Entries|Where-Object {$_.Job.JobId -ceq $Id})
    if($found.Count -ne 1){throw 'VIDNAP_PREVIEW_JOB: Select one existing item.'}
    return $found[0]
}

function Get-VidNapManagerActiveCount($Manager) {
    return @($Manager.Entries|Where-Object {$null -ne $_.Handle -or ($_.Session -and $_.Session.Active)}).Count+@($Manager.Operations|Where-Object {$null -ne $_.Handle}).Count
}

function Add-VidNapManagerLinks($Manager,[string[]]$Links,$Selection,[bool]$Consent=$false,[string]$Browser='edge') {
    if(-not $Links.Count -or $Links.Count -gt 50){throw 'VIDNAP_PREVIEW_LIMIT: Add 1 to 50 links, within the 500-item limit.'}
    if($Browser -cnotin @('edge','chrome','firefox')){throw 'VIDNAP_BACKEND_BROWSER: Select a supported browser.'}
    $pending=[Collections.Generic.List[object]]::new()
    $bindings=@{}
    foreach($link in $Links){
        $job=New-VidNapJob $link $Manager.Paths.MediaRoot $Selection
        $selectionKey=$job.Selection|ConvertTo-Json -Compress -Depth 4
        $missing=@($Manager.Entries|Where-Object {$_.Job.State -ceq 'NeedsSourceUrl' -and $_.Job.SourceKey -ceq $job.SourceKey -and $_.Job.Destination -ieq $job.Destination -and
            (($_.Job.Selection|ConvertTo-Json -Compress -Depth 4) -ceq $selectionKey)})
        if($missing.Count -gt 1){throw 'VIDNAP_PREVIEW_RECOVERY: Multiple stopped rows match this source. Cancel the unwanted rows before adding it again.'}
        $existing=@($Manager.Entries|Where-Object {-not $missing.Count -or $_.Job.JobId -cne $missing[0].Job.JobId}|ForEach-Object {$_.Job})+@($pending.ToArray())
        if((Get-VidNapDuplicateDecision $existing @($Manager.History.ToArray()) $job) -cne 'New'){throw 'VIDNAP_DUPLICATE: This source and export already exists in the queue or saved history.'}
        if($missing.Count){$bindings[$job.JobId]=$missing[0]}
        $pending.Add($job)
    }
    if($Manager.Entries.Count+$pending.Count-$bindings.Count -gt 500){throw 'VIDNAP_PREVIEW_LIMIT: Dismissed rows still count toward the 500-item limit for this session.'}
    $ids=@(foreach($job in $pending){
        if($bindings.ContainsKey($job.JobId)){
            $entry=$bindings[$job.JobId];$entry.Job.SourceUrl=$job.SourceUrl;$entry.Job.State='Draft';$entry.Job.RequiresAuthentication=$false;$entry.Job.AuthenticationConsent=$false
            $entry.ErrorCode='';$entry.Dismissed=$false;$entry.Analysis=$null;$entry.Session=$null;$entry.Progress=$null;$entry.Started=$null;$entry.Ended=$null;$entry.HistoryRecorded=$false
        }else{$entry=New-VidNapManagerEntry $job;$Manager.Entries.Add($entry)}
        $entry.Mode='AnalyzeQueued';$entry.Consent=$Consent;$entry.Browser=$Browser
        $entry.Job.JobId
    })
    if(-not (Save-VidNapManager $Manager)){throw 'VIDNAP_BACKEND_STATE_NOT_SAVED: Links remain visible but were not durably saved. Work was not started.'}
    Write-VidNapManagerEvent $Manager 'VIDNAP_LINKS_ADDED'
    return $ids
}

function Set-VidNapManagerSelection($Manager,[string]$Id,$Selection) {
    $entry=Get-VidNapManagerEntry $Manager $Id
    if($entry.Handle -or ($entry.Session -and $entry.Session.Active) -or $entry.Job.State -notin @('Draft','Ready')){throw 'VIDNAP_PREVIEW_BUSY: Change an export before the item is queued.'}
    $safe=Copy-VidNapJobSelection $Selection
    if($entry.Analysis){$check=$safe.PSObject.Copy();$check|Add-Member NoteProperty HasFfmpeg $true;Get-VidNapSelectionArguments $entry.Analysis $check|Out-Null}
    $candidate=$entry.Job.PSObject.Copy();$candidate.Selection=$safe
    $others=@($Manager.Entries|Where-Object {$_.Job.JobId -cne $Id}|ForEach-Object {$_.Job})
    if((Get-VidNapDuplicateDecision $others @($Manager.History.ToArray()) $candidate) -cne 'New'){throw 'VIDNAP_DUPLICATE: This source and export is already queued or saved. The prior selection was preserved.'}
    $entry.Job.Selection=$safe
    if(-not (Save-VidNapManager $Manager)){throw 'VIDNAP_BACKEND_STATE_NOT_SAVED: Selection was not durably saved.'}
}

function Start-VidNapManagerQueue($Manager,[string]$Id='',[bool]$Consent=$false,[string]$Browser='edge') {
    if($Manager.PersistenceError){throw 'VIDNAP_BACKEND_STATE_NOT_SAVED: Resolve storage before starting work.'}
    if($Browser -cnotin @('edge','chrome','firefox')){throw 'VIDNAP_BACKEND_BROWSER: Select a supported browser.'}
    if($Id){Get-VidNapManagerEntry $Manager $Id|Out-Null}
    foreach($entry in $Manager.Entries){
        if($Id -and $entry.Job.JobId -cne $Id){continue}
        if($entry.Job.State -in @('Draft','Ready','Analyzing','Queued')){
            $entry.Consent=$Consent;$entry.Browser=$Browser
            $entry.AutoDownload=$true
            if($entry.Job.State -eq 'Ready'){$entry.Job.State='Queued';$entry.Mode='DownloadQueued'}
            elseif($entry.Job.State -eq 'Draft'){$entry.Mode='AnalyzeQueued'}
        }
    }
    if(-not (Save-VidNapManager $Manager)){throw 'VIDNAP_BACKEND_STATE_NOT_SAVED: Queue was not started.'}
}

function Resume-VidNapManagerItem($Manager,[string]$Id,[bool]$Consent=$false,[string]$Browser='edge') {
    $entry=Get-VidNapManagerEntry $Manager $Id
    if($entry.Job.State -notin @('Interrupted','Failed','Cancelled','NeedsReview','NeedsAuthentication','NeedsSourceUrl')){throw 'VIDNAP_PREVIEW_BUSY: Only stopped work can be retried.'}
    if(-not $entry.Job.SourceUrl){throw 'VIDNAP_SOURCE_REQUIRED: Paste the source link again.'}
    if($Browser -cnotin @('edge','chrome','firefox')){throw 'VIDNAP_BACKEND_BROWSER: Unsupported browser.'}
    $entry.Job.State='Queued';$entry.Mode='DownloadQueued';$entry.Session=$null;$entry.Progress=$null;$entry.Started=$null;$entry.Ended=$null
    $entry.AutoDownload=$true;$entry.Dismissed=$false;$entry.Consent=$Consent;$entry.Browser=$Browser;$entry.ErrorCode='';$entry.HistoryRecorded=$false
    if(-not (Save-VidNapManager $Manager)){throw 'VIDNAP_BACKEND_STATE_NOT_SAVED: Retry was not started.'}
}

function Add-VidNapManagerTerminalHistory($Manager,$Entry) {
    if($Entry.HistoryRecorded){return}
    if($Entry.Session -and $Entry.Session.History.Count){
        $record=$Entry.Session.History[$Entry.Session.History.Count-1]
        if(-not $Manager.History.Contains($record)){$Manager.History.Add($record)}
    }
    else {$Manager.History.Add([pscustomobject]@{JobId=$Entry.Job.JobId;SourceKey=$Entry.Job.SourceKey;Selection=$Entry.Job.Selection;Destination=$Entry.Job.Destination;OutputFiles=@();Result=$Entry.Job.State;Verification=@()})}
    $Entry.HistoryRecorded=$true;$Entry.Consent=$false;$Entry.Job.AuthenticationConsent=$false;$Entry.Ended=[DateTimeOffset]::UtcNow
    Write-VidNapManagerEvent $Manager $(if($Entry.ErrorCode){$Entry.ErrorCode}else{'VIDNAP_ITEM_'+$Entry.Job.State.ToUpperInvariant()})
    Save-VidNapManager $Manager|Out-Null
}

function Stop-VidNapManagerItem($Manager,[string]$Id) {
    $op=@($Manager.Operations|Where-Object {$_.Id -ceq $Id})
    if($op.Count -eq 1){
        $op[0].CancelRequested=$true
        if($op[0].Handle){& $Manager.Adapter.Cancel $op[0].Handle|Out-Null;$op[0].State='Cancelling'}else{$op[0].State='Cancelled'}
        return
    }
    $entry=Get-VidNapManagerEntry $Manager $Id
    $entry.AutoDownload=$false
    if($entry.Session -and $entry.Session.Active){Stop-VidNapBackendJob $entry.Session;return}
    if($entry.Handle){$entry.Job.State='Cancelling';& $Manager.Adapter.Cancel $entry.Handle|Out-Null;return}
    if($entry.Job.State -in @('Draft','Ready','Queued','Interrupted','NeedsSourceUrl','NeedsAuthentication')){$entry.Job.State='Cancelled';$entry.Mode='Idle';Add-VidNapManagerTerminalHistory $Manager $entry}
}

function Dismiss-VidNapManagerItem($Manager,[string]$Id) {
    $operations=@($Manager.Operations|Where-Object {$_.Id -ceq $Id})
    if($operations.Count -eq 1){
        if($operations[0].State -notin @('Completed','Failed','Cancelled')){throw 'VIDNAP_PREVIEW_BUSY: Stop transcript work before dismissing it.'}
        $Manager.Operations.Remove($operations[0])|Out-Null;return
    }
    $entry=Get-VidNapManagerEntry $Manager $Id
    if($entry.Job.State -notin @('Completed','Failed','Cancelled','NeedsReview')){throw 'VIDNAP_PREVIEW_BUSY: Stop the item before dismissing it.'}
    $entry.Dismissed=$true
}

function Receive-VidNapManagerTick($Manager) {
    $now=[DateTimeOffset]::UtcNow
    foreach($entry in $Manager.Entries){
        if($entry.Handle){
            try {
                $result=& $Manager.Adapter.Poll $entry.Handle
                if($result.Complete){
                    $classified=Get-VidNapManagerHandleError $entry.Handle
                    & $Manager.Adapter.Dispose $entry.Handle|Out-Null;$entry.Handle=$null
                    if($entry.Job.State -eq 'Cancelling'){$entry.Job.State='Cancelled';$entry.Mode='Idle';Add-VidNapManagerTerminalHistory $Manager $entry}
                    elseif($result.ExitCode -ne 0 -or $result.ErrorCode){
                        $entry.ErrorCode=if($result.ErrorCode -ceq 'VIDNAP_PROCESS_OUTPUT_LIMIT'){'VIDNAP_ANALYSIS_LIMIT'}
                            elseif($classified){$classified}
                            elseif($result.ErrorCode -ceq 'VIDNAP_PROCESS_STDERR_LIMIT'){'VIDNAP_PROCESS_STDERR_LIMIT'}
                            else{'VIDNAP_ENGINE_FAILED'}
                        throw 'VIDNAP_ENGINE_FAILED: Source analysis failed.'
                    }
                    else {
                        $entry.Analysis=ConvertFrom-VidNapAnalysis $result.Output
                        if($entry.Analysis.Kind -ne 'Media'){throw 'VIDNAP_ANALYSIS_PLAYLIST_CONSENT: Add individual links in this preview.'}
                        $entry.Job.State=if($entry.AutoDownload){'Queued'}else{'Ready'}
                        $entry.Mode=if($entry.AutoDownload){'DownloadQueued'}else{'Idle'}
                        Save-VidNapManager $Manager|Out-Null
                    }
                }
            }catch{
                if($entry.Handle){& $Manager.Adapter.Dispose $entry.Handle|Out-Null;$entry.Handle=$null}
                $entry.Job.State='Failed';$entry.Mode='Idle'
                if(-not $entry.ErrorCode){$entry.ErrorCode=if($_.Exception.Message -clike 'VIDNAP_ANALYSIS_LIMIT:*'){'VIDNAP_ANALYSIS_LIMIT'}else{'VIDNAP_ENGINE_FAILED'}}
                Add-VidNapManagerTerminalHistory $Manager $entry
            }
        }elseif($entry.Session -and $entry.Session.Active){
            $before=$entry.Job.State
            $handle=$entry.Session.Active.Handle
            Receive-VidNapBackendTick $entry.Session $now
            $entry.Progress=Get-VidNapBackendProgress $entry.Session $now
            if($entry.Session.Active){$entry.Analysis=$entry.Session.Active.Analysis}
            else {
                $entry.Analysis=$entry.Session.Last.Analysis;$entry.ErrorCode=$entry.Session.Last.ErrorCode;$entry.Mode='Idle'
                if($entry.Job.State -in @('Failed','NeedsReview') -and $entry.ErrorCode -cnotin @('VIDNAP_ANALYSIS_LIMIT','VIDNAP_PROCESS_DRAIN_TIMEOUT')){$classified=Get-VidNapManagerHandleError $handle;if($classified){$entry.ErrorCode=$classified}}
                Add-VidNapManagerTerminalHistory $Manager $entry
            }
            if($before -ne $entry.Job.State){Save-VidNapManager $Manager|Out-Null}
        }
    }
    Receive-VidNapManagerOperations $Manager $now
    if($Manager.PersistenceError){return}
    foreach($entry in $Manager.Entries){
        if((Get-VidNapManagerActiveCount $Manager) -ge $Manager.MaxConcurrent){break}
        if($entry.Mode -notin @('AnalyzeQueued','DownloadQueued','RetryQueued') -or $entry.Handle -or ($entry.Session -and $entry.Session.Active)){continue}
        try {
            if($entry.Mode -eq 'AnalyzeQueued'){
                $transition=Get-VidNapJobTransition $entry.Job 'Analyze' $entry.Consent;$entry.Job.State=$transition.NextState
                if($entry.Job.State -ne 'Analyzing'){$entry.Mode='Idle';continue}
                $entry.Job.AttemptId=[Guid]::NewGuid().ToString();$entry.Job.RequiresAuthentication=$entry.Consent;$entry.Job.AuthenticationConsent=$entry.Consent
                $entry.Started=$now;$entry.Mode='Analyzing'
                if(-not (Save-VidNapManager $Manager)){break}
                $request=New-VidNapEngineRequest $entry.Job $Manager.Paths $Manager.Tools 'Analyze' $null $entry.Consent $entry.Browser
                $entry.Handle=& $Manager.Adapter.Start $request
            }else {
                $entry.Session=New-VidNapBackendSession (New-VidNapQueue @($entry.Job)) $Manager.Paths $Manager.Tools $Manager.Adapter
                $entry.Session.SaveCallback=${function:Save-VidNapManager};$entry.Session.SaveContext=$Manager
                $entry.Started=$now;$entry.Ended=$null;$entry.HistoryRecorded=$false
                $started=if($entry.Mode -eq 'RetryQueued'){Resume-VidNapBackendJob $entry.Session $entry.Job.JobId $entry.Consent $entry.Browser}else{Start-VidNapQueueItem $entry.Session $entry.Consent $entry.Browser}
                $entry.Mode='Downloading'
                if(-not $started -and -not $entry.Session.Active){$entry.Mode='Idle';if($entry.Session.Last){$entry.ErrorCode=$entry.Session.Last.ErrorCode;Add-VidNapManagerTerminalHistory $Manager $entry}}
                if(-not (Save-VidNapManager $Manager)){
                    if($entry.Session.Active){Stop-VidNapBackendJob $entry.Session}
                    break
                }
            }
        }catch{
            $entry.Job.State='Failed';$entry.Mode='Idle';$entry.ErrorCode='VIDNAP_BACKEND_START';Add-VidNapManagerTerminalHistory $Manager $entry
        }
    }
    Start-VidNapManagerOperations $Manager $now
}

function ConvertTo-VidNapPreviewAnalysis($Analysis) {
    if(-not $Analysis){return $null}
    return [pscustomobject]@{title=$Analysis.Title;durationSeconds=$Analysis.DurationSeconds;formats=@(foreach($f in $Analysis.Formats){
        [pscustomobject]@{formatId=$f.FormatId;extension=$f.Extension;videoCodec=$f.VideoCodec;audioCodec=$f.AudioCodec;width=$f.Width;height=$f.Height;frameRate=$f.FrameRate
            audioBitrateKbps=(Get-VidNapDataValue $f 'AudioBitrateKbps' $null);sizeBytes=$f.SizeBytes;sizeEstimated=($f.SizeKind -eq 'Estimated')}
    });captions=@(foreach($c in $Analysis.Captions){[pscustomobject]@{language=$c.Language;automatic=$c.Automatic;formats=$c.Formats}})}
}

function ConvertTo-VidNapPreviewProgress($Progress) {
    if(-not $Progress){return $null}
    return [pscustomobject]@{state=$Progress.State;phase=$Progress.Phase;currentStep=$Progress.CurrentStep;completedSteps=$Progress.CompletedSteps;remainingSteps=$Progress.RemainingSteps;totalSteps=$Progress.TotalSteps
        bytes=$Progress.Bytes;totalBytes=$Progress.TotalBytes;rateBytesPerSecond=$Progress.RateBytesPerSecond;lastAdvanceUtc=$Progress.LastAdvanceUtc.ToString('o')
        elapsedSeconds=$Progress.ElapsedSeconds;heartbeatUtc=$Progress.HeartbeatUtc.ToString('o')
        activityState=$Progress.ActivityState;totalEstimated=$Progress.TotalEstimated;byteScope=$Progress.ByteScope;savedBytes=$Progress.SavedBytes
        savedFiles=$Progress.SavedFiles;verifiedFiles=$Progress.VerifiedFiles;totalFiles=$Progress.TotalFiles;etaReason=$Progress.EtaReason;errorCode=$Progress.ErrorCode}
}

function Get-VidNapManagerState($Manager,[string]$SelectedId='') {
    $now=[DateTimeOffset]::UtcNow
    if(-not $SelectedId){$first=@($Manager.Entries|Where-Object {-not $_.Dismissed}|Select-Object -First 1);if($first.Count){$SelectedId=$first[0].Job.JobId}}
    $jobs=@(foreach($entry in $Manager.Entries){
        $p=if($entry.Session -and ($entry.Session.Active -or $entry.Session.Last)){
            ConvertTo-VidNapPreviewProgress (Get-VidNapBackendProgress $entry.Session $now)
        }else{
            [pscustomobject]@{state=$entry.Job.State;phase=$(if($entry.Handle){'Analyze'}else{'Waiting'});bytes=0;totalBytes=$null;rateBytesPerSecond=$null
                elapsedSeconds=$(if($entry.Started){($(if($entry.Ended){$entry.Ended}else{$now})-$entry.Started).TotalSeconds}else{0});heartbeatUtc=$now.ToString('o');currentStep=1;completedSteps=0;remainingSteps=5;totalSteps=5}
        }
        [pscustomobject]@{id=$entry.Job.JobId;state=$entry.Job.State;title=$(if($entry.Analysis){$entry.Analysis.Title}else{$entry.Job.SourceHost});sourceHost=$entry.Job.SourceHost
            selection=[pscustomobject]@{media=$entry.Job.Selection.Media;format=$entry.Job.Selection.Format;formatIds=@($entry.Job.Selection.FormatIds)}
            analysis=$(if($entry.Job.JobId -ceq $SelectedId){ConvertTo-VidNapPreviewAnalysis $entry.Analysis}else{$null});progress=$p;dismissed=$entry.Dismissed;errorCode=$entry.ErrorCode;waitingRetry=($entry.Mode -eq 'RetryQueued')}
    })
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $history=@(for($i=$Manager.History.Count-1;$i -ge 0;$i--){$h=$Manager.History[$i];if($seen.Add($h.JobId)){
        [pscustomobject]@{id=$h.JobId;result=$h.Result;files=@($h.OutputFiles|ForEach-Object {[IO.Path]::GetFileName($_)});verification=@($h.Verification);media=$h.Selection.Media;format=$h.Selection.Format}
    }})
    return [pscustomobject]@{jobs=$jobs;history=$history;operations=@(Get-VidNapManagerOperationViews $Manager $now);transcripts=@($Manager.Transcripts.ToArray());activeCount=(Get-VidNapManagerActiveCount $Manager)
        maxConcurrent=2;mediaRoot=$Manager.Paths.MediaRoot;dataRoot=$Manager.Paths.DataRoot;heartbeatUtc=$now.ToString('o');persistenceError=$Manager.PersistenceError;diagnosticError=$Manager.DiagnosticError
        transcription=[pscustomobject]@{ready=$Manager.TranscriptionReady;model=$(if($Manager.TranscriptionReady){[IO.Path]::GetFileName($Manager.TranscriptionPolicy.ModelFile)}else{''});threads=2;reason=$(if($Manager.TranscriptionReady){'Approved local engine and model. Audio stays on this PC.'}else{'An approved local engine and model are required. Nothing is downloaded automatically.'})}
        mobile=[pscustomobject]@{phoneAccessEnabled=$false;reason='Local preview only. Secure phone connectivity has not been configured.'}}
}

function Get-VidNapManagerMedia($Manager,[string]$Id,[int]$Index=0) {
    $completedJobs=@($Manager.History|Where-Object {$_.JobId -ceq $Id -and $_.Result -eq 'Completed'})
    if(-not $completedJobs.Count){throw 'VIDNAP_PREVIEW_JOB: Select saved and verified media.'}
    $files=@($completedJobs[$completedJobs.Count-1].OutputFiles)
    if($Index -lt 0 -or $Index -ge $files.Count){throw 'VIDNAP_PREVIEW_JOB: Select an existing output.'}
    $path=Assert-VidNapOutputFile $files[$Index] $Manager.Paths.MediaRoot
    Assert-VidNapRegularFile $path|Out-Null
    if([IO.Path]::GetExtension($path).ToLowerInvariant() -notin @('.mp4','.mkv','.webm','.mp3','.m4a','.flac','.wav','.opus','.ogg','.mov','.avi')){throw 'VIDNAP_PREVIEW_MEDIA: Unsupported media extension.'}
    return [pscustomobject]@{path=$path;name=[IO.Path]::GetFileName($path);bytes=([IO.FileInfo]$path).Length}
}

function New-VidNapManagerOperation([string]$Kind,[string]$JobId) {
    return [pscustomobject]@{Id=[Guid]::NewGuid().ToString();Kind=$Kind;JobId=$JobId;State='Queued';Phase='Waiting';Handle=$null;Started=$null;Ended=$null;ErrorCode='';CancelRequested=$false
        SourceJob=$null;Analysis=$null;Language='';AllowAutomatic=$false;Consent=$false;Browser='edge';Provenance='';WorkDirectory='';MediaFile='';Request=$null;DurationSeconds=$null
        Percent=$null;LastPercent=$null;LastSample=$null;Rate=$null;TranscriptId=''}
}

function Start-VidNapManagerCaption($Manager,[string]$Id,[string]$Language,[bool]$AllowAutomatic=$false,[bool]$Consent=$false,[string]$Browser='edge') {
    if($Manager.Operations.Count -ge 500){throw 'VIDNAP_PREVIEW_LIMIT: Dismiss finished transcript activity before adding more.'}
    if(@($Manager.Operations|Where-Object {$_.JobId -ceq $Id -and $_.Kind -eq 'Captions' -and $_.State -notin @('Completed','Failed','Cancelled')}).Count){throw 'VIDNAP_DUPLICATE: Caption work for this item is already queued or active.'}
    $entry=Get-VidNapManagerEntry $Manager $Id
    if(-not $entry.Analysis -or -not $entry.Job.SourceUrl){throw 'VIDNAP_SOURCE_REQUIRED: Analyze the source before choosing captions.'}
    Get-VidNapCaptionArguments $entry.Analysis.Captions $Language $AllowAutomatic|Out-Null
    if($Browser -cnotin @('edge','chrome','firefox')){throw 'VIDNAP_BACKEND_BROWSER: Select a supported browser.'}
    $op=New-VidNapManagerOperation 'Captions' $Id
    $op.SourceJob=$entry.Job.PSObject.Copy();$op.Analysis=$entry.Analysis;$op.Language=$Language;$op.AllowAutomatic=$AllowAutomatic;$op.Consent=$Consent;$op.Browser=$Browser
    $op.Provenance=if(@($entry.Analysis.Captions|Where-Object {$_.Language -ceq $Language -and -not $_.Automatic}).Count){'SourceManual'}else{'SourceAutomatic'}
    $Manager.Operations.Add($op);return $op.Id
}

function Start-VidNapManagerGeneration($Manager,[string]$Id,[int]$Index=0) {
    if(-not $Manager.TranscriptionReady){throw 'VIDNAP_TRANSCRIPTION_APPROVAL: Configure the separately approved local engine and model first.'}
    if($Manager.Operations.Count -ge 500){throw 'VIDNAP_PREVIEW_LIMIT: Dismiss finished transcript activity before adding more.'}
    if(@($Manager.Operations|Where-Object {$_.JobId -ceq $Id -and $_.Kind -eq 'Generate' -and $_.State -notin @('Completed','Failed','Cancelled')}).Count){throw 'VIDNAP_DUPLICATE: Generation for this item is already queued or active.'}
    $media=Get-VidNapManagerMedia $Manager $Id $Index
    $op=New-VidNapManagerOperation 'Generate' $Id;$op.MediaFile=$media.path;$op.Provenance='LocalGenerated'
    $Manager.Operations.Add($op);return $op.Id
}

function New-VidNapManagerToolRequest($Manager,[string]$Name,[string]$Kind,[string[]]$Arguments,[string]$Directory,[int]$Timeout=120000) {
    $tool=Get-VidNapTrustedTool $Manager.Tools $Name
    return [pscustomobject]@{Kind=$Kind;ToolPath=$tool.Path;ToolSha256=$tool.Sha256;Arguments=$Arguments;WorkingDirectory=$Directory;Environment=(Get-VidNapRuntimeEnvironment $Manager.Paths)
        StandardOutputLimit=4MB;StandardErrorLimit=256KB;TimeoutMilliseconds=$Timeout}
}

function Start-VidNapManagerOperations($Manager,[DateTimeOffset]$Now) {
    if($Manager.PersistenceError){return}
    foreach($op in $Manager.Operations){
        if((Get-VidNapManagerActiveCount $Manager) -ge $Manager.MaxConcurrent){break}
        if($op.State -ne 'Queued'){continue}
        try {
            $op.Started=$Now;$op.State='Running'
            if($op.Kind -eq 'Captions'){
                $op.WorkDirectory=Join-Path $Manager.Paths.DataRoot ('captions-'+$op.Id)
                [IO.Directory]::CreateDirectory($op.WorkDirectory)|Out-Null;Assert-VidNapPrivateDirectory $op.WorkDirectory
                $job=$op.SourceJob.PSObject.Copy();$job.Destination=$op.WorkDirectory
                $request=New-VidNapEngineRequest $job $Manager.Paths $Manager.Tools 'Captions' $op.Analysis $op.Consent $op.Browser @{Language=$op.Language;AllowAutomatic=$op.AllowAutomatic}
                $op.Phase='Captions'
            }else{$request=New-VidNapProbeRequest $op.MediaFile $Manager.Paths $Manager.Tools;$op.Phase='Probe'}
            $op.Handle=& $Manager.Adapter.Start $request
        }catch{$op.State='Failed';$op.Ended=$Now;$op.ErrorCode='VIDNAP_TRANSCRIPT_START';Write-VidNapManagerEvent $Manager $op.ErrorCode}
    }
}

function Add-VidNapManagerTranscript($Manager,$Operation,[object[]]$Cues) {
    if(-not $Cues.Count -or $Manager.Transcripts.Count -ge 1000){throw 'VIDNAP_TRANSCRIPTION_EMPTY: No supported transcript cues were produced, or the index is full.'}
    $folder=Join-Path $Manager.Paths.MediaRoot 'Transcripts';[IO.Directory]::CreateDirectory($folder)|Out-Null;Assert-VidNapPrivateDirectory $folder
    $id=[Guid]::NewGuid().ToString();$files=@{}
    foreach($format in @('txt','srt','vtt')){$files[$format]=Export-VidNapCaption $Cues $format (Join-Path $folder ('Transcript-'+$id+'.'+$format)) ($format -eq 'txt')}
    $record=[pscustomobject]@{id=$id;jobId=$Operation.JobId;provenance=$Operation.Provenance;createdUtc=[DateTimeOffset]::UtcNow.ToString('o');cueCount=$Cues.Count;files=$files}
    $Manager.Transcripts.Add($record)
    try{$Manager.TranscriptGeneration=[VidNapJobStore]::Write((Join-Path $Manager.Paths.DataRoot 'transcripts.vnjs'),(@{records=@($Manager.Transcripts.ToArray())}|ConvertTo-Json -Depth 6 -Compress),$Manager.TranscriptGeneration)}catch{$Manager.PersistenceError='VIDNAP_TRANSCRIPT_INDEX_NOT_SAVED';throw 'VIDNAP_TRANSCRIPT_INDEX_NOT_SAVED: Transcript files were saved but their index could not be committed.'}
    $Operation.TranscriptId=$id;$Operation.State='Completed';$Operation.Ended=[DateTimeOffset]::UtcNow
    Write-VidNapManagerEvent $Manager 'VIDNAP_TRANSCRIPT_SAVED'
}

function Receive-VidNapManagerOperations($Manager,[DateTimeOffset]$Now) {
    foreach($op in $Manager.Operations){
        if(-not $op.Handle){continue}
        try {
            if($op.Phase -eq 'Generate' -and $op.Handle.PSObject.Properties.Name -contains 'Worker'){
                $samples=[regex]::Matches($op.Handle.Worker.StandardError,'progress\s*=\s*(\d{1,3})%')
                if($samples.Count){
                    $pct=[Math]::Min(100,[int]$samples[$samples.Count-1].Groups[1].Value)
                    if($null -ne $op.Percent -and $pct -gt $op.Percent -and $op.LastSample){$op.Rate=($pct-$op.Percent)/[Math]::Max(0.001,($Now-$op.LastSample).TotalSeconds)}
                    if($null -eq $op.Percent -or $pct -gt $op.Percent){$op.Percent=$pct;$op.LastSample=$Now}
                }
            }
            $result=& $Manager.Adapter.Poll $op.Handle
            if(-not $result.Complete){continue}
            $classified=Get-VidNapManagerHandleError $op.Handle
            & $Manager.Adapter.Dispose $op.Handle|Out-Null;$op.Handle=$null
            if($op.CancelRequested){$op.State='Cancelled';$op.Ended=$Now;continue}
            if($result.ExitCode -ne 0 -or $result.ErrorCode){if($classified){$op.ErrorCode=$classified};throw 'VIDNAP_TRANSCRIPT_ENGINE: Local caption or transcription process failed.'}
            switch($op.Phase){
                Captions {
                    $files=@(Get-ChildItem -LiteralPath $op.WorkDirectory -File|Where-Object {$_.Extension -in @('.vtt','.srt')})
                    if($files.Count -ne 1 -or $files[0].Length -gt 4MB){throw 'VIDNAP_CAPTION_PARSE: Expected one bounded source caption file.'}
                    Assert-VidNapRegularFile $files[0].FullName|Out-Null
                    $cues=@(ConvertFrom-VidNapCaption ([IO.File]::ReadAllText($files[0].FullName,[Text.UTF8Encoding]::new($false,$true))) $files[0].Extension.TrimStart('.') $op.Provenance)
                    $op.Phase='Finalize';Add-VidNapManagerTranscript $Manager $op $cues
                }
                Probe {
                    $probe=ConvertFrom-Json $result.Output
                    if(-not @($probe.streams|Where-Object {$_.codec_type -eq 'audio'}).Count){throw 'VIDNAP_TRANSCRIPTION_AUDIO: No local audio track was verified.'}
                    $duration=Get-VidNapFiniteNumber (Get-VidNapDataValue $probe.format 'duration' $null)
                    $policy=@{Approved=$true;ToolPath=$Manager.TranscriptionPolicy.ToolPath;ToolSha256=$Manager.TranscriptionPolicy.ToolSha256;ModelSha256=$Manager.TranscriptionPolicy.ModelSha256
                        ModelLicense=$Manager.TranscriptionPolicy.ModelLicense;ModelSource=$Manager.TranscriptionPolicy.ModelSource;HasAudio=$true;DurationSeconds=$duration;AvailableBytes=[IO.DriveInfo]::new('D:\').AvailableFreeSpace}
                    $op.Request=New-VidNapTranscriptionRequest $op.MediaFile $Manager.TranscriptionPolicy.ModelFile $Manager.Paths.DataRoot $policy
                    $op.WorkDirectory=$op.Request.ScratchDirectory;$op.DurationSeconds=$duration
                    [IO.Directory]::CreateDirectory($op.WorkDirectory)|Out-Null;Assert-VidNapPrivateDirectory $op.WorkDirectory
                    $op.Phase='PrepareAudio';$request=New-VidNapManagerToolRequest $Manager 'Ffmpeg' 'PrepareAudio' $op.Request.PrepareAudioArguments $op.WorkDirectory 7200000
                    $op.Handle=& $Manager.Adapter.Start $request
                }
                PrepareAudio {
                    Assert-VidNapRegularFile $op.Request.AudioFile|Out-Null
                    $op.Phase='Generate';$op.LastSample=$null;$op.Percent=$null;$op.Rate=$null
                    $request=[pscustomobject]@{Kind='Whisper';ToolPath=$op.Request.ToolPath;ToolSha256=$op.Request.ToolSha256;Arguments=@($op.Request.Arguments)+@('-pp');WorkingDirectory=$op.WorkDirectory
                        Environment=(Get-VidNapRuntimeEnvironment $Manager.Paths);StandardOutputLimit=4MB;StandardErrorLimit=256KB;TimeoutMilliseconds=14400000}
                    $op.Handle=& $Manager.Adapter.Start $request
                }
                Generate {
                    $file=$op.Request.OutputPrefix+'.srt';Assert-VidNapRegularFile $file|Out-Null
                    if(([IO.FileInfo]$file).Length -gt 4MB){throw 'VIDNAP_CAPTION_LIMIT: Generated captions exceed the supported bound.'}
                    $cues=@(ConvertFrom-VidNapCaption ([IO.File]::ReadAllText($file,[Text.UTF8Encoding]::new($false,$true))) 'srt' 'LocalGenerated')
                    $op.Phase='Finalize';Add-VidNapManagerTranscript $Manager $op $cues
                }
            }
        }catch{
            if($op.Handle){& $Manager.Adapter.Dispose $op.Handle|Out-Null;$op.Handle=$null}
            $code=[regex]::Match($_.Exception.Message,'VIDNAP_[A-Z0-9_]+').Value
            if(-not $op.ErrorCode){$op.ErrorCode=if($code){$code}else{'VIDNAP_TRANSCRIPT_FAILED'}};$op.State='Failed';$op.Ended=$Now
            Write-VidNapManagerEvent $Manager $op.ErrorCode
        }
    }
}

function Get-VidNapManagerOperationViews($Manager,[DateTimeOffset]$Now) {
    foreach($op in $Manager.Operations){
        $step=if($op.Phase -in @('Waiting','Probe','Captions')){1}elseif($op.Phase -eq 'PrepareAudio'){2}elseif($op.Phase -eq 'Generate'){3}else{4}
        [pscustomobject]@{id=$op.Id;jobId=$op.JobId;kind=$op.Kind;state=$op.State;phase=$op.Phase;errorCode=$op.ErrorCode;transcriptId=$op.TranscriptId
            progress=[pscustomobject]@{state=$op.State;phase=$op.Phase;currentStep=$step;completedSteps=$(if($op.State -eq 'Completed'){4}else{$step-1});remainingSteps=$(if($op.State -eq 'Completed'){0}else{5-$step});totalSteps=4
                bytes=0;totalBytes=$null;rateBytesPerSecond=$null;stepPercent=$op.Percent;ratePercentPerSecond=$op.Rate;durationSeconds=$op.DurationSeconds
                savedFiles=$(if($op.State -eq 'Completed'){3}else{0});verifiedFiles=$(if($op.State -eq 'Completed'){3}else{0});totalFiles=3
                elapsedSeconds=$(if($op.Started){($(if($op.Ended){$op.Ended}else{$Now})-$op.Started).TotalSeconds}else{0});heartbeatUtc=$Now.ToString('o');activityState=$(if($op.LastSample -and ($Now-$op.LastSample).TotalSeconds -gt 20){'Stalled'}else{'Active'})}}
    }
}

function Get-VidNapManagerTranscript($Manager,[string]$Id) {
    $records=@($Manager.Transcripts|Where-Object {$_.id -ceq $Id})
    if($records.Count -ne 1){throw 'VIDNAP_PREVIEW_TRANSCRIPT: Select one saved transcript.'}
    $record=$records[0];$file=Assert-VidNapOutputFile $record.files.srt (Join-Path $Manager.Paths.MediaRoot 'Transcripts')
    Assert-VidNapRegularFile $file|Out-Null
    if(([IO.FileInfo]$file).Length -gt 4MB){throw 'VIDNAP_CAPTION_LIMIT: Transcript exceeds its supported bound.'}
    $cues=@(ConvertFrom-VidNapCaption ([IO.File]::ReadAllText($file,[Text.UTF8Encoding]::new($false,$true))) 'srt' $record.provenance)
    return [pscustomobject]@{record=$record;cues=@(foreach($c in $cues){[pscustomobject]@{startMs=$c.StartMs;endMs=$c.EndMs;text=$c.Text;provenance=$c.Provenance}})}
}

function Export-VidNapManagerTranscript($Manager,[string]$Id,[string]$Format) {
    if($Format -cnotin @('txt','srt','vtt')){throw 'VIDNAP_CAPTION_FORMAT: Choose TXT, SRT or VTT.'}
    $view=Get-VidNapManagerTranscript $Manager $Id
    $path=Assert-VidNapOutputFile $view.record.files.$Format (Join-Path $Manager.Paths.MediaRoot 'Transcripts')
    return [pscustomobject]@{path=$path;name=[IO.Path]::GetFileName($path);savedOnDrive='D:'}
}

function Close-VidNapManager($Manager) {
    foreach($entry in $Manager.Entries){
        if($entry.Handle){& $Manager.Adapter.Cancel $entry.Handle|Out-Null;& $Manager.Adapter.Dispose $entry.Handle|Out-Null;$entry.Handle=$null;$entry.Job.State='Interrupted'}
        if($entry.Session -and $entry.Session.Active){& $Manager.Adapter.Cancel $entry.Session.Active.Handle|Out-Null;& $Manager.Adapter.Dispose $entry.Session.Active.Handle|Out-Null;$entry.Job.State='Interrupted'}
        $entry.Consent=$false;$entry.Job.AuthenticationConsent=$false
    }
    foreach($op in $Manager.Operations){if($op.Handle){& $Manager.Adapter.Cancel $op.Handle|Out-Null;& $Manager.Adapter.Dispose $op.Handle|Out-Null;$op.Handle=$null}}
    Save-VidNapManager $Manager|Out-Null
}
