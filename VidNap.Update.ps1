Set-StrictMode -Version Latest

function Assert-VidNapUpdateEntry([string]$Name) {
    if(-not $Name -or $Name.Length -gt 180 -or $Name.Contains('\') -or $Name.StartsWith('/') -or $Name.EndsWith('/') -or $Name -match '[:*?"<>|\x00-\x1F]'){
        throw 'VIDNAP_UPDATE_ARCHIVE: Unsupported archive path.'
    }
    foreach($part in $Name.Split('/')){
        if(-not $part -or $part -in @('.','..') -or $part.TrimEnd(' ','.') -cne $part -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){
            throw 'VIDNAP_UPDATE_ARCHIVE: Unsafe archive component.'
        }
    }
}

function Read-VidNapUpdateEntry($Entry,[long]$Limit) {
    if($Entry.Length -gt $Limit -or $Entry.Length -lt 0){throw 'VIDNAP_UPDATE_ARCHIVE: Entry size limit exceeded.'}
    $inputStream=$Entry.Open();$output=[IO.MemoryStream]::new()
    try{
        $buffer=[byte[]]::new(65536)
        while(($read=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0){
            if($output.Length+$read -gt $Limit){throw 'VIDNAP_UPDATE_ARCHIVE: Decompressed size limit exceeded.'}
            $output.Write($buffer,0,$read)
        }
        return ,$output.ToArray()
    }finally{$inputStream.Dispose();$output.Dispose()}
}

function Get-VidNapVerifiedPackage([string]$PackagePath,[string]$ExpectedPublisherThumbprint,[string]$ExpectedCertificateSha256) {
    Add-Type -AssemblyName System.Security,System.IO.Compression,System.IO.Compression.FileSystem
    if($ExpectedPublisherThumbprint -notmatch '^[A-Fa-f0-9]{40}$' -or $ExpectedCertificateSha256 -notmatch '^[A-Fa-f0-9]{64}$'){throw 'VIDNAP_UPDATE_PUBLISHER: An explicit approved publisher policy is required.'}
    Get-VidNapFileSha256 $PackagePath|Out-Null
    if(([IO.FileInfo]$PackagePath).Length -gt 128MB){throw 'VIDNAP_UPDATE_ARCHIVE: Package is too large.'}
    $zip=[IO.Compression.ZipFile]::OpenRead($PackagePath)
    try{
        if($zip.Entries.Count -lt 3 -or $zip.Entries.Count -gt 258){throw 'VIDNAP_UPDATE_ARCHIVE: Package entry count is unsupported.'}
        $entries=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
        [long]$total=0
        foreach($entry in $zip.Entries){
            Assert-VidNapUpdateEntry $entry.FullName
            if($entries.ContainsKey($entry.FullName) -or ($entry.ExternalAttributes -band 0x400) -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000){throw 'VIDNAP_UPDATE_ARCHIVE: Duplicate or redirected archive entry.'}
            $entries.Add($entry.FullName,$entry);$total+=$entry.Length
            if($total -gt 64MB){throw 'VIDNAP_UPDATE_ARCHIVE: Package expansion exceeds 64 MiB.'}
        }
        if(-not $entries.ContainsKey('manifest.json') -or -not $entries.ContainsKey('manifest.p7s')){throw 'VIDNAP_UPDATE_SIGNATURE: Signed manifest is missing.'}
        $manifestBytes=Read-VidNapUpdateEntry $entries['manifest.json'] 65536
        $signature=Read-VidNapUpdateEntry $entries['manifest.p7s'] 131072
        $cms=[Security.Cryptography.Pkcs.SignedCms]::new([Security.Cryptography.Pkcs.ContentInfo]::new($manifestBytes),$true)
        try{$cms.Decode($signature);$cms.CheckSignature($true)}catch{throw 'VIDNAP_UPDATE_SIGNATURE: Manifest signature could not be verified.'}
        if($cms.SignerInfos.Count -ne 1){throw 'VIDNAP_UPDATE_SIGNATURE: Exactly one manifest signer is required.'}
        $signer=$cms.SignerInfos[0];$cert=$signer.Certificate
        $hash=[Security.Cryptography.SHA256]::Create()
        try{$der=[BitConverter]::ToString($hash.ComputeHash($cert.RawData)).Replace('-','')}finally{$hash.Dispose()}
        if($cert.Thumbprint -ine $ExpectedPublisherThumbprint -or $der -ine $ExpectedCertificateSha256){throw 'VIDNAP_UPDATE_PUBLISHER: Publisher does not match the approved identity.'}
        $eku=@($cert.Extensions|Where-Object {$_.Oid.Value -eq '2.5.29.37'}|ForEach-Object {$_.EnhancedKeyUsages}|ForEach-Object {$_.Value})
        if($cert.NotBefore -gt (Get-Date) -or $cert.NotAfter -le (Get-Date) -or $eku -notcontains '1.3.6.1.5.5.7.3.3' -or $signer.DigestAlgorithm.Value -ne '2.16.840.1.101.3.4.2.1'){
            throw 'VIDNAP_UPDATE_SIGNATURE: Publisher validity, code-signing use or SHA256 digest check failed.'
        }
        try{$manifest=ConvertFrom-Json -InputObject ([Text.UTF8Encoding]::new($false,$true).GetString($manifestBytes)) -ErrorAction Stop}catch{throw 'VIDNAP_UPDATE_MANIFEST: Manifest JSON is invalid.'}
        $version=$null
        if((Get-VidNapDataValue $manifest 'SchemaVersion' 0) -ne 1 -or (Get-VidNapDataValue $manifest 'Product' '') -cne 'VidNap' -or
            -not [Version]::TryParse([string](Get-VidNapDataValue $manifest 'Version' ''),[ref]$version) -or
            [string]$manifest.Version -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$' -or [string](Get-VidNapDataValue $manifest 'SourceCommit' '') -notmatch '^[a-f0-9]{40}$'){
            throw 'VIDNAP_UPDATE_MANIFEST: Manifest identity is unsupported.'
        }
        $files=@(Get-VidNapDataValue $manifest 'Files' @());$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        if($files.Count -lt 1 -or $files.Count -gt 256 -or $entries.Count -ne $files.Count+2){throw 'VIDNAP_UPDATE_MANIFEST: Inventory does not cover the complete package.'}
        foreach($file in $files){
            $name=[string](Get-VidNapDataValue $file 'Path' '');Assert-VidNapUpdateEntry $name
            if($name -iin @('manifest.json','manifest.p7s','verified-manifest.json') -or -not $seen.Add($name) -or -not $entries.ContainsKey($name) -or
                [string](Get-VidNapDataValue $file 'Sha256' '') -notmatch '^[A-Fa-f0-9]{64}$' -or
                (Get-VidNapDataValue $file 'Bytes' $null) -isnot [ValueType] -or $file.Bytes -ne $entries[$name].Length){throw 'VIDNAP_UPDATE_MANIFEST: Invalid inventory entry.'}
            if($entries[$name].FullName -cne $name){throw 'VIDNAP_UPDATE_MANIFEST: Inventory path case differs from its archive entry.'}
            $bytes=Read-VidNapUpdateEntry $entries[$name] 32MB
            $hash=[Security.Cryptography.SHA256]::Create()
            try{$actual=[BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-','')}finally{$hash.Dispose()}
            if($actual -ine $file.Sha256){throw 'VIDNAP_UPDATE_HASH: Package payload differs from the signed inventory.'}
        }
        return [pscustomobject]@{Manifest=$manifest;Version=$version;PackageSha256=(Get-VidNapFileSha256 $PackagePath);Publisher=$cert.Thumbprint;TotalBytes=($files|Measure-Object -Property Bytes -Sum).Sum}
    }finally{$zip.Dispose()}
}

function Write-VidNapUpdateProgress($Callback,[string]$Step,[int]$Completed,[long]$DoneBytes,[long]$TotalBytes,$Timer) {
    if(-not $Callback){return}
    $rate=if($Step -eq 'Staging verified files' -and $Timer.Elapsed.TotalSeconds -gt 0.25 -and $DoneBytes -gt 0){$DoneBytes/$Timer.Elapsed.TotalSeconds}else{$null}
    $eta=if($null -ne $rate -and $rate -gt 0 -and $TotalBytes -ge $DoneBytes){($TotalBytes-$DoneBytes)/$rate}else{$null}
    try { & $Callback ([pscustomobject]@{Step=$Step;CompletedSteps=$Completed;TotalSteps=5;RemainingSteps=5-$Completed
        DoneBytes=$DoneBytes;TotalBytes=$TotalBytes;RateBytesPerSecond=$rate;ElapsedSeconds=$Timer.Elapsed.TotalSeconds
        HeartbeatUtc=[DateTimeOffset]::UtcNow;EtaSeconds=$eta;ProjectedLocalCompletion=$(if($null -ne $eta){[DateTimeOffset]::Now.AddSeconds($eta)}else{$null})
        EtaReason=$(if($null -eq $eta){'Waiting or too few observed transfer samples.'}else{'Current staging step only; verification time is not predicted.'})})|Out-Null
    } catch { Write-Verbose 'VIDNAP_UPDATE_PROGRESS_UNAVAILABLE: Progress observer failed; the transactional worker continues.' }
}

function Invoke-VidNapAppUpdate {
    param([string]$PackagePath,[string]$InstallationConfigPath,[string]$ExpectedPublisherThumbprint,[string]$ExpectedCertificateSha256,
        [string]$DecisionFile,[switch]$VerifyOnly,[scriptblock]$PostCommitVerifier=$null,[scriptblock]$Progress=$null,
        [int]$WaitForProcessId=0,[int]$WaitSeconds=120)
    $paths=Get-VidNapInstallationPaths ([IO.Path]::GetDirectoryName($InstallationConfigPath))
    if([IO.Path]::GetFileName($InstallationConfigPath) -cne 'vidnap-installation.json'){throw 'VIDNAP_UPDATE_CONFIG: Use the installation sidecar.'}
    foreach($path in @($paths.ApplicationRoot,$paths.DataRoot,$paths.MediaRoot)){
        if([IO.Path]::GetPathRoot($path) -ine 'D:\'){throw 'VIDNAP_UPDATE_STORAGE: All installation roots must remain on D:.'}
    }
    Assert-VidNapPrivateDirectory $paths.ApplicationRoot
    Assert-VidNapPrivateDirectory $paths.DataRoot
    $decisionParent=ConvertTo-VidNapLocalDirectory ([IO.Path]::GetDirectoryName($DecisionFile))
    if($decisionParent -ine $paths.DataRoot -or [IO.Path]::GetFileName($DecisionFile) -match '[:*?"<>|]' -or [IO.Directory]::Exists($DecisionFile) -or
        ([IO.File]::Exists($DecisionFile) -and ([IO.File]::GetAttributes($DecisionFile) -band [IO.FileAttributes]::ReparsePoint))){throw 'VIDNAP_UPDATE_DECISION: Decision file must be an ordinary file in the state root.'}
    $timer=[Diagnostics.Stopwatch]::StartNew()
    Write-VidNapUpdateProgress $Progress 'Authenticating package' 0 0 0 $timer
    $verified=Get-VidNapVerifiedPackage $PackagePath $ExpectedPublisherThumbprint $ExpectedCertificateSha256
    if($VerifyOnly){return [pscustomobject]@{Status='Verified';Version=$verified.Manifest.Version;SourceCommit=$verified.Manifest.SourceCommit}}
    if(-not $PostCommitVerifier){throw 'VIDNAP_UPDATE_VERIFIER: A trusted post-commit verification callback is required; no activation was attempted.'}
    $lockPath=Join-Path $paths.DataRoot 'app-update.lock'
    if([IO.Directory]::Exists($lockPath) -or ([IO.File]::Exists($lockPath) -and ([IO.File]::GetAttributes($lockPath) -band [IO.FileAttributes]::ReparsePoint))){throw 'VIDNAP_UPDATE_STORAGE: Update lock is redirected.'}
    $held=$null
    try{$held=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch [IO.IOException]{throw 'VIDNAP_UPDATE_BUSY: Another update owns the installation lock.'}
    try{
        $pointer=Join-Path $paths.ApplicationRoot 'current.json';$previous=$null
        if([IO.File]::Exists($pointer)){
            Get-VidNapFileSha256 $pointer|Out-Null
            $previous=[IO.File]::ReadAllBytes($pointer)
            try{$old=ConvertFrom-Json ([Text.UTF8Encoding]::new($false,$true).GetString($previous));$oldVersion=[Version]$old.Version}catch{throw 'VIDNAP_UPDATE_RECOVERY: Existing selector is invalid and was preserved.'}
            if($old.SchemaVersion -ne 1 -or $oldVersion -ge $verified.Version){throw 'VIDNAP_UPDATE_VERSION: Update must be newer than the selected version.'}
        }
        if([IO.File]::Exists($DecisionFile)){
            $decision=[IO.File]::ReadAllText($DecisionFile)
            if($decision -ceq 'cancel'){return [pscustomobject]@{Status='Cancelled';VersionDirectory=''}}
            throw 'VIDNAP_UPDATE_DECISION: Decision file is already claimed. Use a fresh run identifier.'
        }
        $versions=ConvertTo-VidNapLocalDirectory (Join-Path $paths.ApplicationRoot 'versions')
        [IO.Directory]::CreateDirectory($versions)|Out-Null
        $run=[Guid]::NewGuid().ToString('N');$stage=Join-Path $versions ('.stage-'+$run)
        [IO.Directory]::CreateDirectory($stage)|Out-Null
        $versionDirectory=Join-Path $versions ($verified.Manifest.Version+'-'+$verified.Manifest.SourceCommit.Substring(0,12)+'-'+$run)
        foreach($file in $verified.Manifest.Files){
            if((Join-Path $versionDirectory $file.Path.Replace('/','\')).Length -gt 248){throw 'VIDNAP_UPDATE_STORAGE: Choose a shorter application root; staged files were retained.'}
        }
        # Reopen only if the complete archive still matches the authenticated bytes.
        if((Get-VidNapFileSha256 $PackagePath) -cne $verified.PackageSha256){throw 'VIDNAP_UPDATE_HASH: Package changed after verification.'}
        $zip=[IO.Compression.ZipFile]::OpenRead($PackagePath);[long]$done=0
        try{
            foreach($file in $verified.Manifest.Files){
                $target=Join-Path $stage $file.Path.Replace('/','\')
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))|Out-Null
                $bytes=Read-VidNapUpdateEntry $zip.GetEntry($file.Path) 32MB
                $output=[IO.FileStream]::new($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,65536,[IO.FileOptions]::WriteThrough)
                try{$output.Write($bytes,0,$bytes.Length);$output.Flush($true)}finally{$output.Dispose()}
                if((Get-VidNapFileSha256 $target) -ine $file.Sha256){throw 'VIDNAP_UPDATE_HASH: Staged payload verification failed.'}
                if([IO.Path]::GetExtension($target) -iin @('.ps1','.exe','.dll')){
                    $signature=Get-AuthenticodeSignature -LiteralPath $target
                    if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ine $ExpectedPublisherThumbprint){throw 'VIDNAP_UPDATE_SIGNATURE: Application code must retain a valid approved publisher signature.'}
                }
                $done+=$bytes.Length
                Write-VidNapUpdateProgress $Progress 'Staging verified files' 1 $done $verified.TotalBytes $timer
            }
        }finally{$zip.Dispose()}
        $wait=[Diagnostics.Stopwatch]::StartNew()
        while($WaitForProcessId -gt 0 -and (Get-Process -Id $WaitForProcessId -ErrorAction SilentlyContinue)){
            if([IO.File]::Exists($DecisionFile) -and [IO.File]::ReadAllText($DecisionFile) -ceq 'cancel'){return [pscustomobject]@{Status='Cancelled';VersionDirectory=$stage}}
            if($wait.Elapsed.TotalSeconds -ge $WaitSeconds){throw 'VIDNAP_UPDATE_WAIT: Host has not closed. Staged files were retained; no selector changed.'}
            Write-VidNapUpdateProgress $Progress 'Waiting for application to close' 2 $done $verified.TotalBytes $timer
            Start-Sleep -Milliseconds 200
        }
        Write-VidNapUpdateProgress $Progress 'Ready to commit' 2 $done $verified.TotalBytes $timer
        if(-not (Try-ClaimSetupDecision $DecisionFile 'commit')){
            if([IO.File]::ReadAllText($DecisionFile) -ceq 'cancel'){return [pscustomobject]@{Status='Cancelled';VersionDirectory=$stage}}
            throw 'VIDNAP_UPDATE_DECISION: Commit was not claimed. Staged files were preserved.'
        }
        [IO.Directory]::Move($stage,$versionDirectory)
        $selector=[ordered]@{SchemaVersion=1;Version=$verified.Manifest.Version;SourceCommit=$verified.Manifest.SourceCommit;Directory=$versionDirectory}
        $pending=Join-Path $paths.ApplicationRoot ('.selector-'+$run+'.tmp')
        [IO.File]::WriteAllText($pending,($selector|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        $backup=Join-Path $paths.ApplicationRoot ('current.previous-'+$run+'.json')
        if($null -ne $previous){[IO.File]::Replace($pending,$pointer,$backup,$false)}else{[IO.File]::Move($pending,$pointer)}
        Write-VidNapUpdateProgress $Progress 'Verifying selected version' 3 $done $verified.TotalBytes $timer
        $valid=$false
        try{$response=& $PostCommitVerifier $versionDirectory;$valid=($response -is [bool] -and $response)}catch{$valid=$false}
        if(-not $valid){
            if($null -ne $previous){
                $rollback=Join-Path $paths.ApplicationRoot ('.rollback-'+$run+'.tmp');[IO.File]::WriteAllBytes($rollback,$previous)
                [IO.File]::Replace($rollback,$pointer,(Join-Path $paths.ApplicationRoot ('current.failed-'+$run+'.json')),$false)
            }else{[IO.File]::Move($pointer,(Join-Path $paths.ApplicationRoot ('current.failed-'+$run+'.json')))}
            Write-VidNapUpdateProgress $Progress 'Rolled back; both versions retained' 5 $done $verified.TotalBytes $timer
            return [pscustomobject]@{Status='RolledBack';VersionDirectory=$versionDirectory}
        }
        Write-VidNapUpdateProgress $Progress 'Complete' 5 $done $verified.TotalBytes $timer
        return [pscustomobject]@{Status='Committed';VersionDirectory=$versionDirectory}
    }finally{$held.Dispose()}
}

function Get-VidNapAppUpdateRecovery([string]$ApplicationRoot) {
    $root=ConvertTo-VidNapLocalDirectory $ApplicationRoot
    $pointer=Join-Path $root 'current.json'
    $stages=@();$versions=Join-Path $root 'versions'
    if([IO.Directory]::Exists($versions)){
        ConvertTo-VidNapLocalDirectory $versions|Out-Null
        $stages=@(Get-ChildItem -LiteralPath $versions -Directory -Filter '.stage-*'|ForEach-Object {$_.FullName})
    }
    return [pscustomobject]@{Status=$(if([IO.File]::Exists($pointer)){'InspectCurrent'}else{'NeedsReview'});Selector=$pointer
        StagedDirectories=$stages;PreviousSelectors=@(Get-ChildItem -LiteralPath $root -File -Filter 'current.previous-*.json'|ForEach-Object {$_.FullName})
        AutomaticMutation=$false}
}
