Set-StrictMode -Version Latest

function Get-VidNapSourceIdentity([string]$PageUrl) {
    $uri=$null
    if($PageUrl.Length -gt 8192 -or -not [Uri]::TryCreate($PageUrl,[UriKind]::Absolute,[ref]$uri) -or
        $uri.Scheme -notin @('http','https') -or $uri.UserInfo -or -not $uri.Host -or $PageUrl -match '[\x00-\x20]'){
        throw 'VIDNAP_JOB_SOURCE: Supply an ordinary HTTP or HTTPS page URL without embedded credentials.'
    }
    $hostName=$uri.DnsSafeHost.ToLowerInvariant()
    $query=@{}
    $safe=$true
    foreach($pair in $uri.Query.TrimStart('?').Split('&')){
        if(-not $pair){continue}
        $parts=$pair.Split('=',2)
        $key=[Uri]::UnescapeDataString($parts[0]);$value=if($parts.Count -eq 2){[Uri]::UnescapeDataString($parts[1])}else{''}
        if($query.ContainsKey($key)){$safe=$false};$query[$key]=$value
    }
    $identity=$uri.GetLeftPart([UriPartial]::Path)
    $restore=$identity
    if($hostName -in @('youtube.com','www.youtube.com','m.youtube.com','youtu.be')){
        $id=if($hostName -eq 'youtu.be'){$uri.AbsolutePath.Trim('/')}elseif($uri.AbsolutePath -match '^/(shorts|embed)/([A-Za-z0-9_-]{11})$'){$Matches[2]}else{$query['v']}
        if($id -match '^[A-Za-z0-9_-]{11}$'){
            $identity='youtube:'+ $id
            foreach($key in $query.Keys){if($key -cnotin @('v','list','index','t') -or $query[$key] -notmatch '^[A-Za-z0-9_-]{1,128}$'){$safe=$false}}
            $restore='https://www.youtube.com/watch?v='+$id
        }else{$safe=$false}
    }elseif($hostName -in @('pornhub.com','www.pornhub.com')){
        $id=$query['viewkey']
        if($uri.AbsolutePath -ceq '/view_video.php' -and $id -match '^[A-Za-z0-9_-]{1,128}$' -and $query.Count -eq 1){
            $identity='pornhub:'+ $id;$restore='https://www.pornhub.com/view_video.php?viewkey='+$id
        }else{$safe=$false}
    }elseif($uri.Query){$safe=$false}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$key=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity))).Replace('-','')}finally{$sha.Dispose()}
    return [pscustomobject]@{SourceKey=$key;RestorableUrl=$(if($safe){$restore}else{''});SourceHost=$hostName}
}

function Copy-VidNapJobSelection($Selection) {
    $media=[string](Get-VidNapDataValue $Selection 'Media' '')
    $format=[string](Get-VidNapDataValue $Selection 'Format' '')
    try{Get-ExportArguments $media $format $true|Out-Null}catch{throw 'VIDNAP_JOB_SELECTION: Choose a supported export.'}
    $ids=@(Get-VidNapDataValue $Selection 'FormatIds' @())
    if($ids.Count -gt 2 -or @($ids|Where-Object {$_ -isnot [string] -or $_ -notmatch '^[A-Za-z0-9_.:-]{1,128}$'}).Count){throw 'VIDNAP_JOB_SELECTION: Invalid exact format selection.'}
    return [pscustomobject]@{Media=$media;Format=$format;FormatIds=$ids}
}

function New-VidNapJob([string]$PageUrl,[string]$Destination,$Selection) {
    $source=Get-VidNapSourceIdentity $PageUrl
    $folder=ConvertTo-VidNapLocalDirectory $Destination
    if([IO.Path]::GetPathRoot($folder) -ine 'D:\'){throw 'VIDNAP_JOB_STORAGE: Jobs require explicit D: storage.'}
    return [pscustomobject]@{
        SchemaVersion=1;JobId=[Guid]::NewGuid().ToString();AttemptId='';State='Draft';SourceUrl=$PageUrl
        SourceKey=$source.SourceKey;SourceHost=$source.SourceHost;Destination=$folder;Selection=(Copy-VidNapJobSelection $Selection)
        RequiresAuthentication=$false;AuthenticationConsent=$false;CreatedUtc=[DateTimeOffset]::UtcNow.ToString('o')
    }
}

function Get-VidNapJobTransition($Job,[string]$Event,[bool]$HasAuthenticationConsent) {
    $state=[string](Get-VidNapDataValue $Job 'State' '')
    $next=$null;$actions=@()
    $map=@{
        'Draft/Analyze'='Analyzing';'Queued/Analyze'='Analyzing';'Analyzing/AnalysisReady'='Ready';'Ready/Enqueue'='Queued';'Queued/Start'='Running'
        'Running/Processing'='Processing';'Processing/Probe'='Verifying';'Running/TransferDone'='Verifying'
        'Verifying/Validated'='Completed';'Verifying/Limited'='Completed';'Verifying/Invalid'='NeedsReview'
        'Running/Cancel'='Cancelling';'Processing/Cancel'='Cancelling';'Verifying/Cancel'='Cancelling';'Analyzing/Cancel'='Cancelling'
        'Cancelling/Stopped'='Cancelled';'Queued/Cancel'='Cancelled';'Ready/Cancel'='Cancelled';'Draft/Cancel'='Cancelled'
        'Interrupted/Resume'='Analyzing';'Cancelled/Retry'='Analyzing';'Failed/Retry'='Analyzing';'NeedsReview/Retry'='Analyzing'
        'NeedsAuthentication/Retry'='Analyzing';'NeedsSourceUrl/Retry'='Analyzing'
    }
    if($map.ContainsKey($state+'/'+$Event)){$next=$map[$state+'/'+$Event]}
    elseif($Event -eq 'Fail' -and $state -in @('Analyzing','Running','Processing','Verifying','Cancelling')){$next='Failed'}
    elseif($Event -eq 'Crash' -and $state -in @('Analyzing','Running','Processing','Verifying','Cancelling')){$next='Interrupted'}
    if(-not $next){throw 'VIDNAP_JOB_TRANSITION: This action is not valid for the current state.'}
    if($next -in @('Analyzing','Running')){
        if(-not (Get-VidNapDataValue $Job 'SourceUrl' '')){$next='NeedsSourceUrl'}
        elseif((Get-VidNapDataValue $Job 'RequiresAuthentication' $false) -and -not $HasAuthenticationConsent){$next='NeedsAuthentication'}
    }
    if($next -eq 'Analyzing'){$actions=@('NewAttempt','Analyze')}
    elseif($next -eq 'Running'){$actions=@('StartTransfer')}
    elseif($next -eq 'Verifying'){$actions=@('VerifyLocalOutput')}
    elseif($next -eq 'Cancelling'){$actions=@('CancelOwnedWorker')}
    return [pscustomobject]@{NextState=$next;Actions=$actions}
}

function Receive-VidNapJobEvent($Job,$Event,[bool]$HasAuthenticationConsent=$false) {
    if([string](Get-VidNapDataValue $Event 'AttemptId' '') -cne [string]$Job.AttemptId){return [pscustomobject]@{Ignored=$true;Actions=@()}}
    $transition=Get-VidNapJobTransition $Job ([string](Get-VidNapDataValue $Event 'Event' '')) $HasAuthenticationConsent
    $Job.State=$transition.NextState
    if($transition.Actions -contains 'NewAttempt'){$Job.AttemptId=[Guid]::NewGuid().ToString()}
    $Job.AuthenticationConsent=$HasAuthenticationConsent
    return [pscustomobject]@{Ignored=$false;Actions=$transition.Actions}
}

function ConvertTo-VidNapPersistedState([object[]]$Jobs,[object[]]$History) {
    if($Jobs.Count -gt 500 -or $History.Count -gt 2000){throw 'VIDNAP_JOB_LIMIT: Queue or history exceeds its bounded size.'}
    $projected=@(foreach($job in $Jobs){
        # Terminal records live in URL-free history, not the pending queue.
        if($job.State -in @('Completed','Cancelled','Failed','NeedsReview')){continue}
        $source=if($job.SourceUrl){Get-VidNapSourceIdentity $job.SourceUrl}else{
            if([string]$job.SourceKey -notmatch '^[A-Fa-f0-9]{64}$'){throw 'VIDNAP_JOB_SCHEMA: Missing saved source identity.'}
            [pscustomobject]@{RestorableUrl='';SourceKey=[string]$job.SourceKey;SourceHost=[string]$job.SourceHost}
        }
        $state=[string]$job.State
        if(-not $source.RestorableUrl){$state='NeedsSourceUrl'}
        [pscustomobject]@{SchemaVersion=1;JobId=[string]$job.JobId;AttemptId=[string]$job.AttemptId;State=$state
            SourceUrl=$source.RestorableUrl;SourceKey=$source.SourceKey;SourceHost=$source.SourceHost
            Destination=(ConvertTo-VidNapLocalDirectory $job.Destination);Selection=(Copy-VidNapJobSelection $job.Selection)
            RequiresAuthentication=[bool]$job.RequiresAuthentication;CreatedUtc=[string]$job.CreatedUtc}
    })
    $past=@(foreach($entry in $History){
        $outputs=@(Get-VidNapDataValue $entry 'OutputFiles' @())
        if($outputs.Count -gt 50){throw 'VIDNAP_JOB_LIMIT: Too many output files.'}
        foreach($file in $outputs){
            if($file -isnot [string] -or [IO.Path]::GetFileName($file) -match '[:*?"<>|]'){throw 'VIDNAP_JOB_SCHEMA: History contains an invalid output reference.'}
            $parent=ConvertTo-VidNapLocalDirectory ([IO.Path]::GetDirectoryName($file))
            if([IO.Path]::GetPathRoot($parent) -ine 'D:\'){throw 'VIDNAP_JOB_STORAGE: History output references must remain on D:.'}
        }
        $verifications=@(Get-VidNapDataValue $entry 'Verification' @())
        $verification=@(foreach($item in $verifications){
            $status=[string](Get-VidNapDataValue $item 'Status' '')
            $codes=@(Get-VidNapDataValue $item 'Codes' @())
            if($status -cnotin @('Validated','Failed','Indeterminate') -or $codes.Count -gt 64 -or @($codes|Where-Object {$_ -isnot [string] -or $_ -notmatch '^[A-Z][A-Z0-9_]{0,63}$'}).Count){throw 'VIDNAP_JOB_SCHEMA: Invalid verification evidence.'}
            [pscustomobject]@{Status=$status;Codes=$codes}
        })
        [pscustomobject]@{JobId=[string](Get-VidNapDataValue $entry 'JobId' '');SourceKey=[string](Get-VidNapDataValue $entry 'SourceKey' '')
            Selection=(Copy-VidNapJobSelection $entry.Selection);Destination=(ConvertTo-VidNapLocalDirectory $entry.Destination)
            OutputFiles=$outputs;Result=[string](Get-VidNapDataValue $entry 'Result' 'NeedsReview');Verification=$verification}
    })
    return [pscustomobject]@{SchemaVersion=1;Jobs=$projected;History=$past}
}

function Restore-VidNapJobs([object[]]$PersistedJobs) {
    if($PersistedJobs.Count -gt 500){throw 'VIDNAP_JOB_LIMIT: Queue exceeds its bounded size.'}
    foreach($record in $PersistedJobs){
        $id=[Guid]::Empty
        if((Get-VidNapDataValue $record 'SchemaVersion' 0) -ne 1 -or -not [Guid]::TryParse([string]$record.JobId,[ref]$id) -or $id -eq [Guid]::Empty){throw 'VIDNAP_JOB_SCHEMA: Invalid saved job.'}
        $state=[string]$record.State
        if($state -notin @('Draft','Analyzing','Ready','Queued','Running','Processing','Verifying','Cancelling','Cancelled','Failed','Interrupted','Completed','NeedsReview','NeedsAuthentication','NeedsSourceUrl')){throw 'VIDNAP_JOB_SCHEMA: Unknown saved state.'}
        $url=[string]$record.SourceUrl
        $source=if($url){Get-VidNapSourceIdentity $url}else{$null}
        if(-not $source -or -not $source.RestorableUrl){$state='NeedsSourceUrl';$url=''}
        elseif($state -in @('Analyzing','Queued','Running','Processing','Verifying','Cancelling')){$state='Interrupted'}
        $destination=ConvertTo-VidNapLocalDirectory $record.Destination
        if([IO.Path]::GetPathRoot($destination) -ine 'D:\'){throw 'VIDNAP_JOB_STORAGE: Saved job is not on D:.'}
        [pscustomobject]@{SchemaVersion=1;JobId=$id.ToString();AttemptId='';State=$state;SourceUrl=$url
            SourceKey=[string]$record.SourceKey;SourceHost=[string]$record.SourceHost;Destination=$destination
            Selection=(Copy-VidNapJobSelection $record.Selection);RequiresAuthentication=[bool]$record.RequiresAuthentication
            AuthenticationConsent=$false;CreatedUtc=[string]$record.CreatedUtc}
    }
}

function Get-VidNapDuplicateDecision([object[]]$Jobs,[object[]]$History,$Candidate) {
    $selection=Copy-VidNapJobSelection $Candidate.Selection|ConvertTo-Json -Compress -Depth 4
    foreach($job in $Jobs){
        if($job.SourceKey -ceq $Candidate.SourceKey -and $job.Destination -ieq $Candidate.Destination -and
            ((Copy-VidNapJobSelection $job.Selection|ConvertTo-Json -Compress -Depth 4) -ceq $selection) -and
            $job.State -notin @('Completed','Cancelled','Failed','NeedsReview')){return 'AlreadyQueued'}
    }
    foreach($entry in $History){
        if($entry.SourceKey -ceq $Candidate.SourceKey -and $entry.Destination -ieq $Candidate.Destination -and
            ((Copy-VidNapJobSelection $entry.Selection|ConvertTo-Json -Compress -Depth 4) -ceq $selection)){
            foreach($file in $entry.OutputFiles){if([IO.File]::Exists($file)){return 'ExistingFileNeedsReview'}}
        }
    }
    return 'New'
}

function New-VidNapQueue([object[]]$Jobs) {return [pscustomobject]@{Jobs=$Jobs;ActiveJobId=''}}
function Get-VidNapNextQueuedJob($Queue) {
    if($Queue.ActiveJobId){return $null}
    foreach($job in $Queue.Jobs){if($job.State -eq 'Queued'){return $job}}
    return $null
}

function Save-VidNapJobState([string]$Path,[object[]]$Jobs,[object[]]$History,[long]$ExpectedGeneration) {
    $snapshot=ConvertTo-VidNapPersistedState $Jobs $History
    return [VidNapJobStore]::Write($Path,($snapshot|ConvertTo-Json -Depth 12 -Compress),$ExpectedGeneration)
}

function Read-VidNapJobState([string]$Path) {
    $stored=[VidNapJobStore]::Read($Path)
    if(-not $stored.Json){return [pscustomobject]@{Generation=$stored.Generation;Jobs=@();History=@();ErrorCode=$stored.ErrorCode}}
    try{$parsed=ConvertFrom-Json -InputObject $stored.Json -ErrorAction Stop}catch{throw 'VIDNAP_JOB_SCHEMA: Saved JSON is invalid; no state was changed.'}
    if((Get-VidNapDataValue $parsed 'SchemaVersion' 0) -ne 1){throw 'VIDNAP_JOB_SCHEMA: Saved schema is unsupported; no state was changed.'}
    $history=(ConvertTo-VidNapPersistedState @() @($parsed.History)).History
    return [pscustomobject]@{Generation=$stored.Generation;Jobs=@(Restore-VidNapJobs $parsed.Jobs);History=$history;ErrorCode=$stored.ErrorCode}
}
