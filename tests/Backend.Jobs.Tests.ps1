. (Join-Path $PSScriptRoot 'Backend.TestSupport.ps1')
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'VidNap.Core.ps1')
. (Join-Path $root 'VidNap.Storage.ps1')
. (Join-Path $root 'VidNap.Analysis.ps1')
$module=Join-Path $root 'VidNap.Jobs.ps1'
if(Test-Path -LiteralPath $module){. $module}
Assert-Backend ($null -ne (Get-Command New-VidNapJob -ErrorAction SilentlyContinue)) 'job backend exists'
$fixture=New-BackendTestDirectory $root
try{
    $job=New-VidNapJob 'https://www.youtube.com/watch?v=abcdefghijk&t=20' $fixture @{Media='video';Format='best'}
    Assert-Backend ($job.State -eq 'Draft' -and $job.JobId -match '^[a-f0-9-]{36}$') 'new job has stable identity and starts stopped'
    Assert-Backend (-not $job.RequiresAuthentication -and $job.Selection.Media -eq 'video') 'authentication is not inferred'
    Assert-BackendCode {New-VidNapJob 'file:///D:/private' $fixture @{Media='video';Format='best'}} 'VIDNAP_JOB_SOURCE'
    Assert-BackendCode {New-VidNapJob 'https://user:secret@example.invalid/video' $fixture @{Media='video';Format='best'}} 'VIDNAP_JOB_SOURCE'
    Assert-BackendCode {New-VidNapJob 'https://example.invalid/video' $fixture @{Media='audio';Format='unsupported'}} 'VIDNAP_JOB_SELECTION'
    $states=@(
        @('Draft','Analyze','Analyzing'),@('Analyzing','AnalysisReady','Ready'),@('Ready','Enqueue','Queued'),
        @('Queued','Start','Running'),@('Running','Processing','Processing'),@('Processing','Probe','Verifying'),
        @('Running','TransferDone','Verifying'),@('Verifying','Validated','Completed'),@('Verifying','Limited','Completed'),
        @('Verifying','Invalid','NeedsReview'),@('Running','Cancel','Cancelling'),@('Cancelling','Stopped','Cancelled'),
        @('Queued','Cancel','Cancelled'),@('Analyzing','Fail','Failed'),@('Running','Crash','Interrupted'),
        @('Interrupted','Resume','Analyzing'),@('Cancelled','Retry','Analyzing'),@('Failed','Retry','Analyzing')
    )
    foreach($case in $states){$candidate=$job.PSObject.Copy();$candidate.State=$case[0];$next=Get-VidNapJobTransition $candidate $case[1] $false;Assert-Backend ($next.NextState -eq $case[2]) ($case[0]+' '+$case[1])}
    $auth=$job.PSObject.Copy();$auth.State='Interrupted';$auth.RequiresAuthentication=$true
    Assert-Backend ((Get-VidNapJobTransition $auth 'Resume' $false).NextState -eq 'NeedsAuthentication') 'restored job cannot restore consent'
    Assert-Backend ((Get-VidNapJobTransition $auth 'Resume' $true).NextState -eq 'Analyzing') 'explicit fresh consent permits analysis'
    $missing=$job.PSObject.Copy();$missing.State='Interrupted';$missing.SourceUrl=''
    Assert-Backend ((Get-VidNapJobTransition $missing 'Resume' $false).NextState -eq 'NeedsSourceUrl') 'missing source requires re-entry'
    Assert-BackendCode {Get-VidNapJobTransition $job 'Validated' $false} 'VIDNAP_JOB_TRANSITION'
    $job.AttemptId=[Guid]::NewGuid().ToString();$job.State='Running'
    $late=Receive-VidNapJobEvent $job @{AttemptId=[Guid]::NewGuid().ToString();Event='Fail'} $false
    Assert-Backend ($late.Ignored -and $job.State -eq 'Running') 'stale attempt events cannot mutate a job'
    $projected=ConvertTo-VidNapPersistedState @($job) @()
    Assert-Backend ($projected.Jobs.Count -eq 1 -and $projected.Jobs[0].SourceUrl -match 'abcdefghijk') 'ordinary service identifier can be restored'
    $job|Add-Member NoteProperty CookieFile 'synthetic-cookie' -Force
    $job|Add-Member NoteProperty Authorization 'synthetic-auth' -Force
    $private=New-VidNapJob 'https://example.invalid/video?token=synthetic-token' $fixture @{Media='video';Format='best'}
    $private.State='Running'
    $privateProjection=ConvertTo-VidNapPersistedState @($job,$private) @()
    $json=$privateProjection|ConvertTo-Json -Depth 12
    Assert-Backend ($json -notmatch 'synthetic-cookie|synthetic-auth|synthetic-token|token=') 'disallowed fields are absent even before encryption'
    Assert-Backend ($privateProjection.Jobs[1].State -eq 'NeedsSourceUrl' -and -not $privateProjection.Jobs[1].SourceUrl) 'non-restorable source is explicitly stopped'
    $loaded=Restore-VidNapJobs $privateProjection.Jobs
    Assert-Backend ($loaded[0].State -eq 'Interrupted' -and -not $loaded[0].AuthenticationConsent) 'queue restore never auto-starts or restores consent'
    $resaved=ConvertTo-VidNapPersistedState @($loaded) @()
    Assert-Backend ($resaved.Jobs[1].State -eq 'NeedsSourceUrl' -and -not $resaved.Jobs[1].SourceUrl) 'a source requiring re-entry can be saved again without a destructive reset'
    $duplicate=Get-VidNapDuplicateDecision @($job) @() (New-VidNapJob 'https://www.youtube.com/watch?v=abcdefghijk&t=40' $fixture @{Media='video';Format='best'})
    Assert-Backend ($duplicate -eq 'AlreadyQueued') 'time offsets do not duplicate the same selected source'
    $saved=Join-Path $fixture 'saved.mp4';[IO.File]::WriteAllText($saved,'fixture')
    $history=@([pscustomobject]@{SourceKey=$job.SourceKey;Selection=$job.Selection;Destination=$fixture;OutputFiles=@($saved)})
    Assert-Backend ((Get-VidNapDuplicateDecision @() $history $job) -eq 'ExistingFileNeedsReview') 'existing output requires a decision'
    [IO.File]::Delete($saved)
    Assert-Backend ((Get-VidNapDuplicateDecision @() $history $job) -eq 'New') 'missing history output is not treated as a saved file'
    $batch=New-VidNapQueue @($job,$private)
    $job.State='Queued';$private.State='Queued'
    $first=Get-VidNapNextQueuedJob $batch
    Assert-Backend ($first.JobId -eq $job.JobId) 'queue preserves order'
    $batch.ActiveJobId=$first.JobId
    Assert-Backend ($null -eq (Get-VidNapNextQueuedJob $batch)) 'serial queue does not start a second job'
    Write-Output "PASS: $script:BackendChecks job checks; states, stale events, privacy, consent, duplicates and serial admission."
}finally{Remove-BackendTestDirectory $fixture $root}
