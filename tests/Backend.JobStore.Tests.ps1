. (Join-Path $PSScriptRoot 'Backend.TestSupport.ps1')
$root=Split-Path $PSScriptRoot -Parent
foreach($name in @('Core','Storage','Analysis','Jobs')){. (Join-Path $root ('VidNap.'+$name+'.ps1'))}
$source=Join-Path $root 'VidNap.JobStore.cs'
if((Test-Path -LiteralPath $source) -and -not ('VidNapJobStore' -as [type])){Add-Type -Path $source -ReferencedAssemblies System.Security}
Assert-Backend ($null -ne ('VidNapJobStore' -as [type])) 'encrypted atomic job store exists'
$fixture=New-BackendTestDirectory $root
$path=Join-Path $fixture 'queue.vnjs'
try{
    $empty=[VidNapJobStore]::Read($path)
    Assert-Backend ($empty.Generation -eq 0 -and -not $empty.ErrorCode -and -not $empty.Json) 'new store is empty without fabricated jobs'
    $one='{"SchemaVersion":1,"Jobs":[{"Title":"private-fixture-title"}],"History":[]}'
    $two='{"SchemaVersion":1,"Jobs":[],"History":[{"Result":"Completed"}]}'
    Assert-Backend ([VidNapJobStore]::Write($path,$one,0) -eq 1) 'first generation committed'
    $read=[VidNapJobStore]::Read($path)
    Assert-Backend ($read.Generation -eq 1 -and $read.Json -ceq $one -and -not $read.RecoveredFromBackup) 'real DPAPI round trip'
    $raw=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($path))
    Assert-Backend ($raw -notmatch 'private-fixture-title|SchemaVersion|History') 'store bytes are not plaintext'
    Assert-Backend ([VidNapJobStore]::Write($path,$two,1) -eq 2) 'second generation atomically replaces current'
    $backup=$path+'.previous'
    Assert-Backend ([IO.File]::Exists($backup) -and ([VidNapJobStore]::Read($backup)).Generation -eq 1) 'previous generation is recoverable'
    $before=Get-BackendTestHash $path
    Assert-BackendCode {[VidNapJobStore]::Write($path,$one,1)} 'VIDNAP_STORE_CONFLICT'
    Assert-Backend ((Get-BackendTestHash $path) -ceq $before) 'stale writer cannot modify current'
    $held=[IO.File]::Open($path+'.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{Assert-BackendCode {[VidNapJobStore]::Write($path,$one,2)} 'VIDNAP_STORE_BUSY'}finally{$held.Dispose()}
    Assert-BackendCode {[VidNapJobStore]::Write($path,('x'*(4MB+1)),2)} 'VIDNAP_STORE_LIMIT'
    Assert-Backend ((Get-BackendTestHash $path) -ceq $before) 'failed write preserves current'
    $bytes=[IO.File]::ReadAllBytes($path);$bytes[$bytes.Length-1]=$bytes[$bytes.Length-1] -bxor 1;[IO.File]::WriteAllBytes($path,$bytes)
    $corruptHash=Get-BackendTestHash $path
    $recovered=[VidNapJobStore]::Read($path)
    Assert-Backend ($recovered.RecoveredFromBackup -and $recovered.Generation -eq 1 -and $recovered.ErrorCode -eq 'VIDNAP_STORE_RECOVERY_REQUIRED') 'corruption offers last valid snapshot without overwriting'
    Assert-Backend ((Get-BackendTestHash $path) -ceq $corruptHash) 'read recovery leaves corrupt data untouched'
    Assert-BackendCode {[VidNapJobStore]::Write($path,$two,1)} 'VIDNAP_STORE_RECOVERY_REQUIRED'
    $backupHash=Get-BackendTestHash $backup
    [VidNapJobStore]::Recover($path,$backupHash)
    Assert-Backend (([VidNapJobStore]::Read($path)).Json -ceq $one) 'explicit recovery restores authenticated backup'
    Assert-Backend (@(Get-ChildItem -LiteralPath $fixture -Filter '*.corrupt-*').Count -eq 1) 'corrupt current retained for inspection'
    Assert-Backend ((Get-BackendTestHash $backup) -ceq $backupHash) 'recovery preserves backup'
    $schema=Join-Path $fixture 'future.vnjs';[IO.File]::WriteAllBytes($schema,[Text.Encoding]::ASCII.GetBytes('VNJS9future'))
    $unknown=[VidNapJobStore]::Read($schema)
    Assert-Backend ($unknown.ErrorCode -eq 'VIDNAP_STORE_SCHEMA' -and -not $unknown.Json) 'unknown version is not reset'
    Assert-Backend ([IO.File]::ReadAllText($schema) -ceq 'VNJS9future') 'unknown-version bytes preserved'
    $orphan=Join-Path $fixture 'orphan.vnjs';[IO.File]::WriteAllBytes(($orphan+'.previous'),$bytes)
    Assert-Backend (([VidNapJobStore]::Read($orphan)).ErrorCode -eq 'VIDNAP_STORE_RECOVERY_REQUIRED') 'an invalid orphan backup is not reported as a fresh empty store'
    Assert-BackendCode {[VidNapJobStore]::Write((Join-Path $fixture 'NUL.vnjs'),$one,0)} 'VIDNAP_STORE_PATH'
    $state=Join-Path $fixture 'state.vnjs'
    $job=New-VidNapJob 'https://www.youtube.com/watch?v=abcdefghijk' $fixture @{Media='video';Format='best'}
    $job.State='Running';$job.RequiresAuthentication=$true;$job.AuthenticationConsent=$true
    $history=@([pscustomobject]@{JobId=$job.JobId;SourceKey=$job.SourceKey;Selection=$job.Selection;Destination=$fixture;OutputFiles=@();Result='Completed';Verification=@(@{Status='Indeterminate';Codes=@('DURATION_UNKNOWN')})})
    Save-VidNapJobState $state @($job) $history 0|Out-Null
    $restored=Read-VidNapJobState $state
    Assert-Backend ($restored.Jobs[0].State -eq 'Interrupted' -and -not $restored.Jobs[0].AuthenticationConsent -and $restored.Jobs[0].RequiresAuthentication) 'real encrypted restart retains work but never authentication consent'
    Assert-Backend ($restored.History[0].Verification[0].Status -eq 'Indeterminate') 'limited verification evidence survives an encrypted history round trip'
    $link=Join-Path $fixture 'redirect';New-Item -ItemType Junction -Path $link -Target $fixture|Out-Null
    try{Assert-BackendCode {[VidNapJobStore]::Write((Join-Path $link 'other.vnjs'),$one,0)} 'VIDNAP_STORE_PATH'}finally{[IO.Directory]::Delete($link)}
    Write-Output "PASS: $script:BackendChecks encrypted-store checks; real DPAPI, atomic generations, conflicts, recovery, corruption and path guards."
}finally{Remove-BackendTestDirectory $fixture $root}
