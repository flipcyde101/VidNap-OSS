Set-StrictMode -Version Latest

function Get-VidNapTrustedTool($Tools,[string]$Name) {
    $tool=Get-VidNapDataValue $Tools $Name $null
    $path=[string](Get-VidNapDataValue $tool 'Path' '');$expected=[string](Get-VidNapDataValue $tool 'Sha256' '')
    if(-not $tool -or $expected -notmatch '^[A-Fa-f0-9]{64}$'){throw 'VIDNAP_BACKEND_TOOL: An explicitly verified existing tool is required.'}
    try{$actual=Get-VidNapFileSha256 $path}catch{throw 'VIDNAP_BACKEND_TOOL: Existing tool is not a regular D: file.'}
    if($actual -ine $expected){throw 'VIDNAP_BACKEND_TOOL_HASH: Existing tool differs from its approved inventory. No update was attempted.'}
    return [pscustomobject]@{Path=$path;Sha256=$actual}
}

function New-VidNapEngineRequest($Job,$Paths,$Tools,[ValidateSet('Analyze','Download','Captions')][string]$Kind,$Analysis=$null,[bool]$UseBrowserSignIn=$false,[string]$Browser='edge',$CaptionSelection=$null) {
    Get-VidNapSourceIdentity $Job.SourceUrl|Out-Null
    $directory=ConvertTo-VidNapLocalDirectory $Job.Destination
    if([IO.Path]::GetPathRoot($directory) -ine 'D:\' -or -not [IO.Directory]::Exists($directory)){throw 'VIDNAP_BACKEND_STORAGE: Destination must be an existing D: folder.'}
    $environment=Get-VidNapRuntimeEnvironment $Paths
    Assert-VidNapPrivateDirectory $Paths.DataRoot
    foreach($value in $environment.Values){if([IO.Path]::GetPathRoot($value) -ine 'D:\'){throw 'VIDNAP_BACKEND_STORAGE: Scratch and caches must be on D:.'}}
    $tool=Get-VidNapTrustedTool $Tools 'YtDlp'
    $arguments=@('--ignore-config','--no-plugin-dirs','--no-cache-dir','--encoding','utf-8','--no-color','--socket-timeout','30','--retries','3','--fragment-retries','3')
    $ffmpeg=Get-VidNapDataValue $Tools 'Ffmpeg' $null
    if($ffmpeg){$ffmpeg=Get-VidNapTrustedTool $Tools 'Ffmpeg';$arguments+=@('--ffmpeg-location',$ffmpeg.Path)}
    if(Get-VidNapDataValue $Tools 'Deno' $null){$deno=Get-VidNapTrustedTool $Tools 'Deno';$arguments+=@('--js-runtimes',('deno:'+$deno.Path))}
    if($UseBrowserSignIn){
        if($Browser -cnotin @('chrome','edge','firefox')){throw 'VIDNAP_BACKEND_BROWSER: Select a supported browser.'}
        $arguments+=@('--cookies-from-browser',$Browser)
    }
    $allowPlaylist=(Get-VidNapDataValue $Job 'AllowPlaylist' $false) -ceq $true
    $arguments+=@(Get-PlaylistArguments $allowPlaylist)
    if($allowPlaylist){$arguments+=@('--playlist-end','500')}
    if($Kind -eq 'Analyze'){
        $arguments+=@('--dump-single-json','--skip-download','--no-progress')
        $arguments+=@(Get-ExportArguments $Job.Selection.Media $Job.Selection.Format ($null -ne $ffmpeg))
    }elseif($Kind -eq 'Download'){
        if($null -eq $Analysis){throw 'VIDNAP_BACKEND_ANALYSIS: Analyze before starting transfer.'}
        $selection=Copy-VidNapJobSelection $Job.Selection
        $selection|Add-Member NoteProperty HasFfmpeg ($null -ne $ffmpeg)
        $arguments+=@(Get-EngineBaseArguments (Get-FilenameBudget $directory) -TrackDownload)
        # Reconnects do not establish representation continuity. Missing fragments must fail.
        $arguments+=@('--retries','0','--abort-on-unavailable-fragments')
        $arguments+=@(Get-VidNapSelectionArguments $Analysis $selection)
        $arguments+=@('-o',(Get-OutputTemplate $directory -UseWorkingDirectory))
    }else{
        if($null -eq $Analysis -or $null -eq $CaptionSelection){throw 'VIDNAP_BACKEND_ANALYSIS: Analyze and select captions before download.'}
        $arguments+=@(Get-VidNapCaptionArguments $Analysis.Captions $CaptionSelection.Language ($CaptionSelection.AllowAutomatic -ceq $true))
        $arguments+=@('-o',(Get-OutputTemplate $directory -UseWorkingDirectory))
    }
    $arguments+=@('--',$Job.SourceUrl)
    $stdoutLimit=if($Kind -eq 'Analyze'){Get-VidNapAnalysisMetadataLimit}else{8MB}
    return [pscustomobject]@{Kind=$Kind;ToolPath=$tool.Path;ToolSha256=$tool.Sha256;Arguments=$arguments;WorkingDirectory=$directory
        Environment=$environment;StandardOutputLimit=$stdoutLimit;StandardErrorLimit=256KB;TimeoutMilliseconds=120000;AllowPlaylist=$allowPlaylist}
}

function Get-VidNapExpectedOutput($Analysis,$Selection) {
    if($Analysis.Kind -cne 'Media'){throw 'VIDNAP_BACKEND_ANALYSIS: Split analyzed playlists into individual jobs before transfer.'}
    $ids=@(Get-VidNapDataValue $Selection 'FormatIds' @())
    if(-not $ids.Count){$ids=@($Analysis.RequestedFormatIds)}
    $chosen=@(foreach($id in $ids){$Analysis.Formats|Where-Object {$_.FormatId -ceq $id}})
    $video=@($chosen|Where-Object {$_.VideoCodec});$audio=@($chosen|Where-Object {$_.AudioCodec})
    if(-not $chosen.Count -or $video.Count -gt 1 -or $audio.Count -gt 1){throw 'VIDNAP_BACKEND_SELECTION: Engine-selected stream evidence is missing or ambiguous.'}
    $isVideo=$Selection.Media -ceq 'video'
    if(($isVideo -and -not $video.Count) -or (-not $isVideo -and -not $audio.Count)){throw 'VIDNAP_BACKEND_SELECTION: Selected media track is missing.'}
    $expected=@{RequireVideo=$isVideo;RequireAudio=($audio.Count -gt 0);Container=[string]$Selection.Format}
    if($isVideo){
        $expected.VideoCodec=$video[0].VideoCodec
        foreach($field in @('Width','Height','FrameRate')){if($video[0].$field -gt 0){$expected[$field]=$video[0].$field}}
    }
    if($audio.Count){
        $codec=$audio[0].AudioCodec
        if(-not $isVideo -and $Selection.Format -ne 'original'){
            $codec=@{mp3='mp3';m4a='aac';flac='flac';wav='pcm_s16le';opus='opus'}[$Selection.Format]
        }
        $expected.AudioCodec=$codec
    }
    if($Analysis.DurationSeconds -gt 0){$expected.DurationSeconds=$Analysis.DurationSeconds}
    return $expected
}

function Assert-VidNapOutputFile([string]$Path,[string]$Destination) {
    try{
        $parent=ConvertTo-VidNapLocalDirectory ([IO.Path]::GetDirectoryName($Path))
        $root=ConvertTo-VidNapLocalDirectory $Destination
        if(($parent -ine $root -and -not $parent.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) -or
            [IO.Path]::GetFileName($Path) -match '[:*?"<>|]' -or [IO.Path]::GetExtension($Path) -iin @('.part','.ytdl','.tmp') -or
            -not [IO.File]::Exists($Path) -or ([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint)) {throw 'Invalid output.'}
    }catch{throw 'VIDNAP_BACKEND_OUTPUT: Reported output is not a regular file in the selected destination. Nothing was deleted.'}
    return [IO.Path]::GetFullPath($Path)
}

function New-VidNapProbeRequest([string]$MediaFile,$Paths,$Tools) {
    try{Assert-VidNapRegularFile $MediaFile|Out-Null}catch{throw 'VIDNAP_BACKEND_OUTPUT: Local output is missing or unsupported.'}
    $tool=Get-VidNapTrustedTool $Tools 'Ffprobe'
    return [pscustomobject]@{Kind='Probe';ToolPath=$tool.Path;ToolSha256=$tool.Sha256;Arguments=@(Get-VidNapProbeArguments $MediaFile)
        WorkingDirectory=[IO.Path]::GetDirectoryName($MediaFile);Environment=(Get-VidNapRuntimeEnvironment $Paths)
        StandardOutputLimit=1MB;StandardErrorLimit=65536;TimeoutMilliseconds=30000;MediaFile=$MediaFile}
}

function New-VidNapCompilerParameters($Paths) {
    $environment=Get-VidNapRuntimeEnvironment $Paths
    Assert-VidNapPrivateDirectory $Paths.DataRoot
    if([IO.Path]::GetPathRoot($environment.TEMP) -ine 'D:\'){throw 'VIDNAP_BACKEND_STORAGE: Compiler scratch must remain on D:.'}
    [IO.Directory]::CreateDirectory($environment.TEMP)|Out-Null
    Assert-VidNapPrivateDirectory $environment.TEMP
    $parameters=[CodeDom.Compiler.CompilerParameters]::new()
    $parameters.GenerateInMemory=$true
    $parameters.TempFiles=[CodeDom.Compiler.TempFileCollection]::new($environment.TEMP,$false)
    foreach($assembly in @('System.dll','System.Core.dll','System.Security.dll')){[void]$parameters.ReferencedAssemblies.Add($assembly)}
    return $parameters
}

function Initialize-VidNapBackendTypes($Paths) {
    $parameters=New-VidNapCompilerParameters $Paths
    $files=@(foreach($pair in @(@('VidNapBackendProcess','VidNap.BackendProcess.cs'),@('VidNapProcessRunner','VidNap.ProcessRunner.cs'),@('VidNapJobStore','VidNap.JobStore.cs'))){
        if(-not ($pair[0] -as [type])){Join-Path $PSScriptRoot $pair[1]}
    })
    if($files.Count){Add-Type -Path $files -CompilerParameters $parameters}
}

function New-VidNapNativeAdapter($Paths) {
    Initialize-VidNapBackendTypes $Paths
    return [pscustomobject]@{
        Start={param($Request)
            if((Get-VidNapFileSha256 $Request.ToolPath) -cne $Request.ToolSha256){throw 'VIDNAP_BACKEND_TOOL_HASH: Tool changed before process creation.'}
            foreach($value in $Request.Environment.Values){ConvertTo-VidNapLocalDirectory $value|Out-Null;[IO.Directory]::CreateDirectory($value)|Out-Null}
            $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$Request.ToolPath
            $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false,$true);$info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false,$true)
            $info.Arguments=(@($Request.Arguments|ForEach-Object {Quote-Argument ([string]$_)})) -join ' '
            $info.WorkingDirectory=$Request.WorkingDirectory
            foreach($name in $Request.Environment.Keys){$info.EnvironmentVariables[$name]=$Request.Environment[$name]}
            $worker=if($Request.Kind -eq 'Download'){[VidNapProcessRunner]::new()}else{[VidNapBackendProcess]::new()}
            try{
                if($Request.Kind -eq 'Download'){$worker.Start($info)}else{$worker.Start($info,$Request.StandardOutputLimit,$Request.StandardErrorLimit,$Request.TimeoutMilliseconds)}
            }catch{$worker.Dispose();throw 'VIDNAP_BACKEND_START: Owned engine process did not start. No fallback execution route was attempted.'}
            [pscustomobject]@{Worker=$worker;Kind=$Request.Kind;LastError=''}
        }
        Poll={param($Handle)
            $worker=$Handle.Worker;$lines=@();$output='';$errorCode=''
            if($Handle.Kind -eq 'Download'){
                $completion=$worker.CompletionState
                $complete=$completion -cne 'Pending'
                $collected=[Collections.Generic.List[string]]::new();$line=''
                while($worker.Output.TryDequeue([ref]$line)){
                    if($line.StartsWith('VIDNAP_')){$collected.Add($line)}
                    $diagnostic=Get-VidNapDiagnosticError $line
                    if($null -ne $diagnostic){$Handle.LastError=$diagnostic.Code}
                }
                $lines=@($collected.ToArray())
                if($complete -and $worker.ExitCode -ne 0){$errorCode=if($Handle.LastError){$Handle.LastError}else{'VIDNAP_ENGINE_EXIT'}}
                if($completion -ceq 'TimedOut'){$errorCode='VIDNAP_PROCESS_DRAIN_TIMEOUT'}
            }else{
                $complete=$worker.IsComplete
                if($complete){
                    $errorCode=$worker.ErrorCode
                    if(-not $worker.DrainTimedOut){$output=$worker.StandardOutput}
                    if(-not $errorCode -and $worker.ExitCode -ne 0){$errorCode='VIDNAP_ENGINE_EXIT'}
                }
            }
            [pscustomobject]@{Complete=$complete;ExitCode=$(if($complete){$worker.ExitCode}else{$null});ErrorCode=$errorCode;Output=$output;Lines=$lines}
        }
        Cancel={param($Handle) if($Handle.Kind -eq 'Download'){$Handle.Worker.Stop()}else{$Handle.Worker.Cancel()}}
        Dispose={param($Handle) $Handle.Worker.Dispose()}
    }
}

function New-VidNapBackendSession($Queue,$Paths,$Tools,$Adapter=$null) {
    if($null -eq $Adapter){$Adapter=New-VidNapNativeAdapter $Paths}
    foreach($name in @('Start','Poll','Cancel','Dispose')){if((Get-VidNapDataValue $Adapter $name $null) -isnot [scriptblock]){throw 'VIDNAP_BACKEND_ADAPTER: Incomplete trusted adapter.'}}
    return [pscustomobject]@{Queue=$Queue;Paths=$Paths;Tools=$Tools;Adapter=$Adapter;Active=$null;Last=$null;History=[Collections.Generic.List[object]]::new()
        StorePath='';Generation=0L;PersistenceError='';SaveCallback=$null;SaveContext=$null}
}

function New-VidNapPersistentBackendSession([string]$StatePath,$Paths,$Tools,$Adapter=$null) {
    if((ConvertTo-VidNapLocalDirectory ([IO.Path]::GetDirectoryName($StatePath))) -ine (ConvertTo-VidNapLocalDirectory $Paths.DataRoot)){
        throw 'VIDNAP_BACKEND_STORAGE: Queue state must be in the configured state root.'
    }
    if(-not ('VidNapJobStore' -as [type])){Initialize-VidNapBackendTypes $Paths}
    $saved=Read-VidNapJobState $StatePath
    if($saved.ErrorCode){throw 'VIDNAP_BACKEND_RECOVERY: Saved state requires explicit review or recovery. No work was started.'}
    $session=New-VidNapBackendSession (New-VidNapQueue @($saved.Jobs)) $Paths $Tools $Adapter
    $session.StorePath=$StatePath;$session.Generation=$saved.Generation
    foreach($entry in $saved.History){$session.History.Add($entry)}
    return $session
}

function Save-VidNapBackendSession($Session) {
    if($Session.SaveCallback){
        try{
            if($Session.SaveCallback -isnot [scriptblock]){throw 'Invalid persistence callback.'}
            if(Get-VidNapDataValue $Session.SaveContext 'PersistenceError' ''){throw 'Manager persistence requires explicit recovery.'}
            $saved=& $Session.SaveCallback $Session.SaveContext
            if($saved -isnot [bool] -or -not $saved){throw 'Manager persistence failed.'}
            $Session.PersistenceError='';return $true
        }catch{$Session.PersistenceError='VIDNAP_BACKEND_STATE_NOT_SAVED';return $false}
    }
    if(-not $Session.StorePath){return $true}
    try{
        $Session.Generation=Save-VidNapJobState $Session.StorePath @($Session.Queue.Jobs) @($Session.History.ToArray()) $Session.Generation
        $Session.PersistenceError='';return $true
    }catch{$Session.PersistenceError='VIDNAP_BACKEND_STATE_NOT_SAVED';return $false}
}

function Start-VidNapQueueItem($Session,[bool]$UseBrowserSignIn=$false,[string]$Browser='edge') {
    if($Session.Active -or $Session.Queue.ActiveJobId){return $false}
    $job=Get-VidNapNextQueuedJob $Session.Queue
    if(-not $job){return $false}
    return (Start-VidNapBackendAttempt $Session $job 'Analyze' $UseBrowserSignIn $Browser)
}

function Resume-VidNapBackendJob($Session,[string]$JobId,[bool]$UseBrowserSignIn=$false,[string]$Browser='edge') {
    if($Session.Active -or $Session.Queue.ActiveJobId){return $false}
    $jobs=@($Session.Queue.Jobs|Where-Object {$_.JobId -ceq $JobId})
    if($jobs.Count -ne 1){throw 'VIDNAP_BACKEND_JOB: Select one stopped job.'}
    $transitionEvent=if($jobs[0].State -eq 'Interrupted'){'Resume'}else{'Retry'}
    return (Start-VidNapBackendAttempt $Session $jobs[0] $transitionEvent $UseBrowserSignIn $Browser)
}

function Get-VidNapPlannedBytes($Format,[string]$Field) {
    $size=Get-VidNapFiniteNumber (Get-VidNapDataValue $Format $Field)
    if($size -gt 0 -and $size -le 4503599627370495 -and $size -eq [Math]::Truncate($size)){return [long]$size}
    return 0L
}

function Set-VidNapTransferPlan($Transfer,[string]$Line) {
    # A second plan can belong to a different item. Do not call either one the whole download.
    if($Transfer.PlanSeen){$Transfer.Streams=$null;return}
    $Transfer.PlanSeen=$true
    if($Line.Length -gt 4096){return}
    $fields=$Line.Split([char]'|',3)
    if($fields.Count -ne 3){return}
    $json=if($fields[1] -cin @('NA','null','[]')){$fields[2]}else{$fields[1]}
    try {
        $parsed=ConvertFrom-Json $json -ErrorAction Stop
    } catch {return}
    $formats=@($parsed)
    if($formats.Count -notin @(1,2)){return}
    $streams=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($format in $formats){
        $id=Get-VidNapDataValue $format 'format_id'
        if($id -isnot [string] -or -not (Test-VidNapProgressStreamId $id) -or $streams.ContainsKey($id)){return}
        $streams.Add($id,@{Bytes=0L;Exact=(Get-VidNapPlannedBytes $format 'filesize');Estimate=(Get-VidNapPlannedBytes $format 'filesize_approx')})
    }
    $Transfer.Streams=$streams
}

function Update-VidNapTransferCounts($Transfer,$ProgressRecord) {
    if($null -eq $Transfer.Streams){return}
    if(-not $Transfer.Streams.ContainsKey($ProgressRecord.StreamId)){$Transfer.Streams=$null;return}
    $stream=$Transfer.Streams[$ProgressRecord.StreamId]
    # Engine counters are offsets, not deltas. Repeated samples or retries must not be added twice.
    if($ProgressRecord.HasByteCount){$stream.Bytes=[long]$ProgressRecord.Bytes}
    if($ProgressRecord.TotalEstimated){$stream.Estimate=[long]$ProgressRecord.Total}
    elseif($ProgressRecord.Total -gt 0){$stream.Exact=[long]$ProgressRecord.Total}
    if($ProgressRecord.Finished -and $ProgressRecord.HasByteCount -and $ProgressRecord.Bytes -gt 0){$stream.Exact=[long]$ProgressRecord.Bytes}
    if($stream.Exact -lt $stream.Bytes){$stream.Exact=0L}
    if($stream.Estimate -lt $stream.Bytes){$stream.Estimate=0L}
}

function Get-VidNapTransferCounts($Transfer,$Progress) {
    if($null -eq $Transfer.Streams){
        $total=if($Progress.Total -gt 0 -and $Progress.Total -ge $Progress.Bytes){$Progress.Total}else{$null}
        return @{ByteScope='Stream';Bytes=$Progress.Bytes;Total=$total;Estimated=($null -ne $total -and $Progress.TotalEstimated)}
    }
    $bytes=0L;$total=0L;$estimated=$false;$unknown=$false
    foreach($stream in $Transfer.Streams.Values){
        $bytes+=$stream.Bytes
        if($stream.Exact -gt 0){$total+=$stream.Exact}
        elseif($stream.Estimate -gt 0){$total+=$stream.Estimate;$estimated=$true}
        else{$unknown=$true}
    }
    return @{ByteScope='Download';Bytes=$bytes;Total=$(if(-not $unknown){$total}else{$null});Estimated=(-not $unknown -and $estimated)}
}

function Start-VidNapBackendAttempt($Session,$Job,[string]$TransitionEvent,[bool]$UseBrowserSignIn,[string]$Browser) {
    if($Session.Active -or $Session.Queue.ActiveJobId){return $false}
    $transition=Get-VidNapJobTransition $job $TransitionEvent $UseBrowserSignIn
    $job.State=$transition.NextState
    if($job.State -ne 'Analyzing'){return $false}
    $job.AttemptId=[Guid]::NewGuid().ToString();$job.AuthenticationConsent=$UseBrowserSignIn
    if($UseBrowserSignIn){$job.RequiresAuthentication=$true}
    $now=[DateTimeOffset]::UtcNow
    $active=[pscustomobject]@{Job=$job;AttemptId=$job.AttemptId;Phase='Analyze';Handle=$null;Analysis=$null;Expected=$null
        Outputs=[Collections.Generic.List[string]]::new();Verifications=[Collections.Generic.List[object]]::new();ProbeIndex=0
        Progress=(New-OperationProgress $now);Transfer=@{PlanSeen=$false;Streams=$null};SavedFiles=0;SavedBytes=0L
        Started=$now;ErrorCode='';Browser=$Browser;Consent=$UseBrowserSignIn;Ended=$null}
    $active|Add-Member NoteProperty WorkDirectory ''
    $Session.Active=$active;$Session.Queue.ActiveJobId=$job.JobId
    try{
        if(-not (Save-VidNapBackendSession $Session)){Complete-VidNapBackendJob $Session 'Fail' 'VIDNAP_BACKEND_STATE_NOT_SAVED';return $false}
        $request=New-VidNapEngineRequest $job $Session.Paths $Session.Tools 'Analyze' $null $UseBrowserSignIn $Browser
        $active.Handle=& $Session.Adapter.Start $request
    }catch{Complete-VidNapBackendJob $Session 'Fail' 'VIDNAP_BACKEND_START'}
    return ($null -ne $Session.Active)
}

function Complete-VidNapBackendJob($Session,[string]$TransitionEvent,[string]$ErrorCode='') {
    $active=$Session.Active
    if($active.Handle){& $Session.Adapter.Dispose $active.Handle|Out-Null;$active.Handle=$null}
    Receive-VidNapJobEvent $active.Job @{AttemptId=$active.AttemptId;Event=$TransitionEvent} $active.Consent|Out-Null
    $active.ErrorCode=$ErrorCode;$active.Ended=[DateTimeOffset]::UtcNow
    $kind=if($active.Job.State -eq 'Completed'){'Complete'}elseif($active.Job.State -eq 'Cancelled'){'Cancelled'}else{'Failed'}
    Update-OperationProgress $active.Progress $kind $active.Ended
    $Session.History.Add([pscustomobject]@{JobId=$active.Job.JobId;SourceKey=$active.Job.SourceKey;Selection=$active.Job.Selection
        Destination=$active.Job.Destination;OutputFiles=@($active.Outputs.ToArray());Result=$active.Job.State
        Verification=@($active.Verifications.ToArray());ErrorCode=$ErrorCode})
    $active.Consent=$false;$active.Job.AuthenticationConsent=$false
    $Session.Last=$active;$Session.Active=$null;$Session.Queue.ActiveJobId=''
    Save-VidNapBackendSession $Session|Out-Null
}

function Receive-VidNapBackendTick($Session,[DateTimeOffset]$Now) {
    $active=$Session.Active
    if(-not $active){return}
    if($active.AttemptId -cne $active.Job.AttemptId){
        & $Session.Adapter.Cancel $active.Handle|Out-Null;& $Session.Adapter.Dispose $active.Handle|Out-Null
        $Session.Active=$null;$Session.Queue.ActiveJobId='';return
    }
    try{
        $result=& $Session.Adapter.Poll $active.Handle
        # Cancellation takes precedence over output parsing and exit status.
        if($active.Job.State -eq 'Cancelling'){
            if($result.Complete){Complete-VidNapBackendJob $Session 'Stopped'}
            return
        }
        if($result.Complete -and $active.Phase -ceq 'Download' -and $result.ErrorCode -ceq 'VIDNAP_PROCESS_DRAIN_TIMEOUT'){
            Complete-VidNapBackendJob $Session 'Fail' 'VIDNAP_PROCESS_DRAIN_TIMEOUT'
            return
        }
        foreach($line in $result.Lines){
            if($active.Phase -ceq 'Download' -and $line.StartsWith('VIDNAP_PLAN|',[StringComparison]::Ordinal)){
                Set-VidNapTransferPlan $active.Transfer $line
                continue
            }
            $progressRecord=ConvertFrom-ProgressLine $line
            if($null -eq $progressRecord){continue}
            if($progressRecord.Kind -eq 'File'){
                $path=Assert-VidNapOutputFile $progressRecord.Path $active.WorkDirectory
                if(-not $active.Outputs.Contains($path)){
                    if($active.Outputs.Count -ge 50){throw 'VIDNAP_BACKEND_OUTPUT_LIMIT: Too many reported files.'}
                    $active.Outputs.Add($path)
                }
            }elseif($progressRecord.Kind -eq 'Downloading'){
                Update-VidNapTransferCounts $active.Transfer $progressRecord
                if($progressRecord.HasByteCount){
                    Update-OperationProgress $active.Progress 'Downloading' $Now $progressRecord.Bytes $progressRecord.Total $progressRecord.TotalEstimated -StreamId $progressRecord.StreamId
                }elseif(-not $progressRecord.StreamId -or $progressRecord.StreamId -cne $active.Progress.StreamId){
                    # A new or unidentified stream cannot reuse the last stream's counters or rate.
                    $active.Progress=New-OperationProgress $active.Started
                    $active.Progress.StreamId=$progressRecord.StreamId
                    Update-OperationProgress $active.Progress 'Activity' $Now -Activity 'Waiting for readable stream progress'
                }
            }elseif($progressRecord.Kind -eq 'Finishing'){
                Update-OperationProgress $active.Progress 'Finishing' $Now
                if($active.Job.State -eq 'Running'){Receive-VidNapJobEvent $active.Job @{AttemptId=$active.AttemptId;Event='Processing'} $active.Consent|Out-Null}
            }
        }
        if(-not $result.Complete){return}
        & $Session.Adapter.Dispose $active.Handle|Out-Null;$active.Handle=$null
        if($active.Job.State -eq 'Cancelling'){Complete-VidNapBackendJob $Session 'Stopped';return}
        if($result.ErrorCode -or $result.ExitCode -ne 0){
            if($active.Phase -eq 'Probe'){Complete-VidNapBackendJob $Session 'Invalid' 'VIDNAP_PROBE_FAILED'}
            elseif($active.Phase -eq 'Analyze' -and $result.ErrorCode -ceq 'VIDNAP_PROCESS_OUTPUT_LIMIT'){Complete-VidNapBackendJob $Session 'Fail' 'VIDNAP_ANALYSIS_LIMIT'}
            elseif($active.Phase -eq 'Analyze' -and $result.ErrorCode -ceq 'VIDNAP_PROCESS_STDERR_LIMIT'){Complete-VidNapBackendJob $Session 'Fail' 'VIDNAP_PROCESS_STDERR_LIMIT'}
            else{Complete-VidNapBackendJob $Session 'Fail' 'VIDNAP_ENGINE_FAILED'}
            return
        }
        switch($active.Phase){
            Analyze {
                $active.Analysis=ConvertFrom-VidNapAnalysis $result.Output
                $active.Expected=Get-VidNapExpectedOutput $active.Analysis $active.Job.Selection
                foreach($transitionEvent in @('AnalysisReady','Enqueue','Start')){Receive-VidNapJobEvent $active.Job @{AttemptId=$active.AttemptId;Event=$transitionEvent} $active.Consent|Out-Null}
                $active.Phase='Download'
                $work=Join-Path $active.Job.Destination ('.vn-'+[Guid]::NewGuid().ToString('N').Substring(0,12))
                if([IO.Directory]::Exists($work) -or [IO.File]::Exists($work)){throw 'VIDNAP_BACKEND_OUTPUT: Attempt directory already exists and was preserved.'}
                [IO.Directory]::CreateDirectory($work)|Out-Null
                Assert-VidNapPrivateDirectory $work
                $marker=[IO.File]::Open((Join-Path $work '.vidnap-attempt'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try{$bytes=[Text.Encoding]::ASCII.GetBytes($active.AttemptId);$marker.Write($bytes,0,$bytes.Length);$marker.Flush($true)}finally{$marker.Dispose()}
                $active.WorkDirectory=$work
                $downloadJob=$active.Job.PSObject.Copy();$downloadJob.Destination=$work
                $request=New-VidNapEngineRequest $downloadJob $Session.Paths $Session.Tools 'Download' $active.Analysis $active.Consent $active.Browser
                if(-not (Save-VidNapBackendSession $Session)){Complete-VidNapBackendJob $Session 'Fail' 'VIDNAP_BACKEND_STATE_NOT_SAVED';return}
                $active.Handle=& $Session.Adapter.Start $request
            }
            Download {
                if(-not $active.Outputs.Count){Complete-VidNapBackendJob $Session 'Fail' 'VIDNAP_OUTPUT_MISSING';return}
                $transitionEvent=if($active.Job.State -eq 'Processing'){'Probe'}else{'TransferDone'}
                Receive-VidNapJobEvent $active.Job @{AttemptId=$active.AttemptId;Event=$transitionEvent} $active.Consent|Out-Null
                $active.Phase='Probe';Update-OperationProgress $active.Progress 'Finishing' $Now
                if(-not (Save-VidNapBackendSession $Session)){Complete-VidNapBackendJob $Session 'Invalid' 'VIDNAP_BACKEND_STATE_NOT_SAVED';return}
                $request=New-VidNapProbeRequest $active.Outputs[0] $Session.Paths $Session.Tools
                $active.Handle=& $Session.Adapter.Start $request
            }
            Probe {
                $file=Assert-VidNapOutputFile $active.Outputs[$active.ProbeIndex] $active.WorkDirectory
                $verification=Test-VidNapOutput $active.Expected $result.Output ([IO.FileInfo]$file).Length
                $active.Verifications.Add($verification)
                if(-not $verification.CanComplete){Complete-VidNapBackendJob $Session 'Invalid' 'VIDNAP_OUTPUT_VERIFICATION';return}
                $active.ProbeIndex++
                if($active.ProbeIndex -lt $active.Outputs.Count){
                    $request=New-VidNapProbeRequest $active.Outputs[$active.ProbeIndex] $Session.Paths $Session.Tools
                    $active.Handle=& $Session.Adapter.Start $request
                }else{
                    # Never accept an unrelated existing destination as this
                    # attempt's output. File.Move is no-overwrite on Windows.
                    $final=[Collections.Generic.List[string]]::new()
                    foreach($output in $active.Outputs){
                        $target=Join-Path $active.Job.Destination ([IO.Path]::GetFileName($output))
                        if([IO.File]::Exists($target) -or [IO.Directory]::Exists($target)){
                            Complete-VidNapBackendJob $Session 'Invalid' 'VIDNAP_OUTPUT_COLLISION';return
                        }
                        $final.Add($target)
                    }
                    for($i=0;$i -lt $active.Outputs.Count;$i++){
                        try{[IO.File]::Move($active.Outputs[$i],$final[$i])}catch{
                            Complete-VidNapBackendJob $Session 'Invalid' 'VIDNAP_OUTPUT_FINALIZE';return
                        }
                        $active.Outputs[$i]=$final[$i]
                        $active.SavedFiles++
                        $active.SavedBytes+=([IO.FileInfo](Assert-VidNapOutputFile $final[$i] $active.Job.Destination)).Length
                    }
                    $transitionEvent=if(@($active.Verifications|Where-Object {$_.Status -eq 'Indeterminate'}).Count){'Limited'}else{'Validated'}
                    Complete-VidNapBackendJob $Session $transitionEvent
                }
            }
        }
    }catch{
        if($Session.Active){
            $transitionEvent=if($active.Job.State -eq 'Cancelling'){'Stopped'}elseif($active.Job.State -eq 'Verifying'){'Invalid'}else{'Fail'}
            $code=if($active.Phase -eq 'Analyze' -and $_.Exception.Message -clike 'VIDNAP_ANALYSIS_LIMIT:*'){'VIDNAP_ANALYSIS_LIMIT'}else{'VIDNAP_BACKEND_STAGE_FAILED'}
            Complete-VidNapBackendJob $Session $transitionEvent $code
        }
    }
}

function Stop-VidNapBackendJob($Session) {
    if(-not $Session.Active){return}
    $active=$Session.Active
    if($active.Job.State -eq 'Cancelling'){return}
    Receive-VidNapJobEvent $active.Job @{AttemptId=$active.AttemptId;Event='Cancel'} $active.Consent|Out-Null
    & $Session.Adapter.Cancel $active.Handle|Out-Null
    Save-VidNapBackendSession $Session|Out-Null
}

function Get-VidNapBackendProgress($Session,[DateTimeOffset]$Now) {
    $active=if($Session.Active){$Session.Active}else{$Session.Last}
    if(-not $active){return [pscustomobject]@{State='Idle';HeartbeatUtc=$Now;OverallEtaSeconds=$null;EtaReason='No job is active.'}}
    $snapshot=Get-OperationProgressSnapshot $active.Progress $Now $active.Outputs.Count
    $transfer=Get-VidNapTransferCounts $active.Transfer $active.Progress
    $eta=$null;$projected=$null
    if($snapshot.Rate -gt 0 -and $null -ne $transfer.Total -and -not $transfer.Estimated -and $transfer.Total -gt $transfer.Bytes){
        $seconds=($transfer.Total-$transfer.Bytes)/$snapshot.Rate
        if($seconds -le 31536000){
            $projection=$active.Progress.LastAdvance.AddSeconds($seconds)
            if($projection -gt $Now){$projected=$projection.ToLocalTime();$eta=($projection-$Now).TotalSeconds}
        }
    }
    $step=if($active.Job.State -eq 'Completed'){5}elseif($active.Phase -eq 'Probe'){4}elseif($active.Job.State -eq 'Processing'){3}elseif($active.Phase -eq 'Download'){2}else{1}
    $completed=if($active.Job.State -eq 'Completed'){5}else{$step-1}
    return [pscustomobject]@{JobId=$active.Job.JobId;AttemptId=$active.AttemptId;State=$(if($Session.PersistenceError){'NeedsAttention'}else{$active.Job.State});Phase=$active.Phase
        CurrentStep=$step;CompletedSteps=$completed;RemainingSteps=5-$completed;TotalSteps=5
        SavedFiles=$active.SavedFiles;VerifiedFiles=$active.ProbeIndex;TotalFiles=$(if($active.Phase -eq 'Probe'){$active.Outputs.Count}else{$null})
        Bytes=$transfer.Bytes;TotalBytes=$transfer.Total;TotalEstimated=$transfer.Estimated;ByteScope=$transfer.ByteScope
        SavedBytes=$(if($active.Job.State -ceq 'Completed' -and $active.SavedBytes -gt 0){$active.SavedBytes}else{$null})
        RateBytesPerSecond=$snapshot.Rate;LastAdvanceUtc=$active.Progress.LastAdvance
        ElapsedSeconds=($(if($active.Ended){$active.Ended}else{$Now})-$active.Started).TotalSeconds;HeartbeatUtc=$Now
        ActivityState=$snapshot.State;LatestActivity=$active.Phase;CurrentStepEtaSeconds=$eta
        ProjectedLocalCompletion=$projected;OverallEtaSeconds=$null;EtaReason=$snapshot.OverallText
        ErrorCode=$(if($Session.PersistenceError){$Session.PersistenceError}else{$active.ErrorCode});StateSaved=(-not $Session.PersistenceError)}
}
