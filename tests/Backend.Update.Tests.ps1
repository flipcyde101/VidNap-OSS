. (Join-Path $PSScriptRoot 'Backend.TestSupport.ps1')
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'VidNap.Core.ps1')
. (Join-Path $root 'VidNap.Storage.ps1')
. (Join-Path $root 'VidNap.Analysis.ps1')
Add-Type -AssemblyName System.Security,System.IO.Compression,System.IO.Compression.FileSystem
if(Test-Path -LiteralPath (Join-Path $root 'VidNap.Update.ps1')){. (Join-Path $root 'VidNap.Update.ps1')}
Assert-Backend ($null -ne (Get-Command Invoke-VidNapAppUpdate -ErrorAction SilentlyContinue)) 'transactional update backend exists'
$thumb=([string]$env:VIDNAP_TEST_SIGNER_THUMBPRINT).ToUpperInvariant()
$der=([string]$env:VIDNAP_TEST_SIGNER_CERT_SHA256).ToUpperInvariant()
if($thumb -notmatch '^[A-F0-9]{40}$' -or $der -notmatch '^[A-F0-9]{64}$'){throw 'Run signed update tests through Test-Backend.ps1 with an approved development signer.'}
$fixture=New-BackendTestDirectory $root
$cleanupSafe=$true
function New-UpdateFixture([string]$Version,[string]$Name='data.txt',[bool]$BadHash=$false,[bool]$Tamper=$false){
    $bytes=[Text.Encoding]::UTF8.GetBytes('synthetic update data')
    $sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')}finally{$sha.Dispose()}
    if($BadHash){$hash='0'*64}
    $manifest=[ordered]@{SchemaVersion=1;Product='VidNap';Version=$Version;SourceCommit=('a'*40);Files=@(@{Path=$Name;Sha256=$hash;Bytes=$bytes.Length})}|ConvertTo-Json -Depth 5 -Compress
    $raw=[Text.Encoding]::UTF8.GetBytes($manifest)
    $cms=[Security.Cryptography.Pkcs.SignedCms]::new([Security.Cryptography.Pkcs.ContentInfo]::new($raw),$true)
    $signer=[Security.Cryptography.Pkcs.CmsSigner]::new((Get-Item -LiteralPath ('Cert:\CurrentUser\My\'+$thumb)))
    $signer.DigestAlgorithm=[Security.Cryptography.Oid]::new('2.16.840.1.101.3.4.2.1')
    $cms.ComputeSignature($signer)
    if($Tamper){$raw=[Text.Encoding]::UTF8.GetBytes($manifest.Replace('VidNap','OtherX'))}
    $package=Join-Path $fixture ('package-'+[Guid]::NewGuid().ToString('N')+'.zip')
    $zip=[IO.Compression.ZipFile]::Open($package,[IO.Compression.ZipArchiveMode]::Create)
    try{
        foreach($pair in @(@('manifest.json',$raw),@('manifest.p7s',$cms.Encode()),@($Name,$bytes))){
            $stream=$zip.CreateEntry($pair[0]).Open();try{$stream.Write($pair[1],0,$pair[1].Length)}finally{$stream.Dispose()}
        }
    }finally{$zip.Dispose()}
    return $package
}
function Invoke-UpdateFixture([string]$Package,[string]$Decision,[switch]$VerifyOnly,[scriptblock]$Verifier={param($Path) $true}){
    Invoke-VidNapAppUpdate -PackagePath $Package -InstallationConfigPath $config -ExpectedPublisherThumbprint $thumb -ExpectedCertificateSha256 $der -DecisionFile $Decision -VerifyOnly:$VerifyOnly -PostCommitVerifier $Verifier
}
try{
    foreach($name in @('app','data','media')){[IO.Directory]::CreateDirectory((Join-Path $fixture $name))|Out-Null}
    $app=Join-Path $fixture 'app';$data=Join-Path $fixture 'data';$config=Join-Path $app 'vidnap-installation.json'
    [IO.File]::WriteAllText($config,(@{SchemaVersion=1;ApplicationRoot=$app;DataRoot=$data;MediaRoot=(Join-Path $fixture 'media')}|ConvertTo-Json))
    $package=New-UpdateFixture '0.3.2'
    $decision=Join-Path $data 'decision'
    $result=Invoke-UpdateFixture $package $decision -VerifyOnly
    Assert-Backend ($result.Status -eq 'Verified' -and -not (Test-Path -LiteralPath (Join-Path $app 'versions'))) 'verify-only authenticates without staging or selection'
    Assert-BackendCode {Invoke-VidNapAppUpdate -PackagePath $package -InstallationConfigPath $config -ExpectedPublisherThumbprint ('0'*40) -ExpectedCertificateSha256 $der -DecisionFile $decision -VerifyOnly} 'VIDNAP_UPDATE_PUBLISHER'
    Assert-BackendCode {Invoke-UpdateFixture (New-UpdateFixture '0.3.2' 'data.txt' $false $true) $decision -VerifyOnly} 'VIDNAP_UPDATE_SIGNATURE'
    Assert-BackendCode {Invoke-UpdateFixture (New-UpdateFixture '0.3.2' 'data.txt' $true) $decision -VerifyOnly} 'VIDNAP_UPDATE_HASH'
    foreach($name in @('../escape.txt','x\escape.txt','data.txt:stream','/root.txt','CON.txt')){
        Assert-BackendCode {Invoke-UpdateFixture (New-UpdateFixture '0.3.2' $name) $decision -VerifyOnly} 'VIDNAP_UPDATE_ARCHIVE'
    }
    Try-ClaimSetupDecision $decision 'cancel'|Out-Null
    $cancelled=Invoke-UpdateFixture $package $decision
    Assert-Backend ($cancelled.Status -eq 'Cancelled' -and -not [IO.File]::Exists((Join-Path $app 'current.json'))) 'cancel wins before commit, no selector changed'
    [IO.File]::Delete($decision)
    $installed=Invoke-UpdateFixture $package $decision
    Assert-Backend ($installed.Status -eq 'Committed' -and [IO.File]::Exists((Join-Path $installed.VersionDirectory 'data.txt'))) 'verified version stages and selects atomically'
    Assert-Backend (-not (Try-ClaimSetupDecision $decision 'cancel')) 'commit wins, late cancellation cannot undo finalization'
    $pointer=Join-Path $app 'current.json';$before=Get-BackendTestHash $pointer
    $decision2=Join-Path $data 'decision2'
    $rolled=Invoke-UpdateFixture (New-UpdateFixture '0.3.3') $decision2 -Verifier {param($Path) $false}
    Assert-Backend ($rolled.Status -eq 'RolledBack' -and (Get-BackendTestHash $pointer) -ceq $before) 'failed post-commit verification restores exact prior selector'
    Assert-Backend ([IO.Directory]::Exists($installed.VersionDirectory) -and [IO.Directory]::Exists($rolled.VersionDirectory)) 'old and failed new versions are retained'
    $held=[IO.File]::Open((Join-Path $data 'app-update.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{Assert-BackendCode {Invoke-UpdateFixture $package (Join-Path $data 'decision3')} 'VIDNAP_UPDATE_BUSY'}finally{$held.Dispose()}
    Assert-BackendCode {Invoke-UpdateFixture (New-UpdateFixture '0.3.1') (Join-Path $data 'decision4')} 'VIDNAP_UPDATE_VERSION'
    $script:lateCancel=$true
    $result=Invoke-VidNapAppUpdate -PackagePath (New-UpdateFixture '0.3.4') -InstallationConfigPath $config -ExpectedPublisherThumbprint $thumb -ExpectedCertificateSha256 $der -DecisionFile (Join-Path $data 'decision5') -PostCommitVerifier {param($Path) $true} -Progress {
        param($Status)
        if($Status.Step -eq 'Verifying selected version'){$script:lateCancel=Try-ClaimSetupDecision (Join-Path $data 'decision5') 'cancel';throw 'Synthetic monitor failure'}
    }
    Assert-Backend ($result.Status -eq 'Committed' -and -not $script:lateCancel) 'post-commit monitor failure cannot cancel or abort finalization'
    $resultFile=Join-Path $data 'worker-result.json'
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $workerArguments=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','AllSigned','-WindowStyle','Hidden','-File',(Join-Path $root 'Update-VidNap.ps1'),'-PackagePath',$package,'-InstallationConfigPath',$config,'-ExpectedPublisherThumbprint',$thumb,'-ExpectedCertificateSha256',$der,'-DecisionFile',(Join-Path $data 'worker-decision'),'-ResultFile',$resultFile,'-VerifyOnly')
    $info.Arguments=(@($workerArguments|ForEach-Object {Quote-Argument $_})) -join ' '
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($name in @('TEMP','TMP','XDG_CACHE_HOME','DENO_DIR')){$info.EnvironmentVariables[$name]=Join-Path $root 'temp'}
    $worker=[Diagnostics.Process]::new();$worker.StartInfo=$info
    try{
        Assert-Backend ($worker.Start()) 'standalone signed update verification worker starts hidden'
        $out=$worker.StandardOutput.ReadToEndAsync();$err=$worker.StandardError.ReadToEndAsync()
        if(-not $worker.WaitForExit(30000)){$cleanupSafe=$false;throw 'Owned updater fixture timed out; retained for inspection.'}
        $output=$out.GetAwaiter().GetResult();$errors=$err.GetAwaiter().GetResult()
        Assert-Backend ($worker.ExitCode -eq 0 -and -not $errors -and [IO.File]::Exists($resultFile)) 'separate worker returns an explicit terminal receipt'
        Assert-Backend ((ConvertFrom-Json ([IO.File]::ReadAllText($resultFile))).Status -eq 'Verified') 'worker only verifies the isolated package, no app launch'
    }finally{$worker.Dispose()}
    $detachedResult=Join-Path $data 'detached-result.json';$pidFile=Join-Path $data 'worker.pid'
    $detachedArguments=(@($workerArguments|ForEach-Object {if($_ -ceq $resultFile){Quote-Argument $detachedResult}else{Quote-Argument $_}})) -join ' '
    $encodedArguments=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($detachedArguments))
    $parentCode='$i=[Diagnostics.ProcessStartInfo]::new();$i.FileName=Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe";$i.Arguments=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("'+$encodedArguments+'"));$i.UseShellExecute=$false;$i.CreateNoWindow=$true;$p=[Diagnostics.Process]::new();$p.StartInfo=$i;if(-not $p.Start()){exit 1};[IO.File]::WriteAllText("'+$pidFile+'",[string]$p.Id);exit 0'
    $parentInfo=[Diagnostics.ProcessStartInfo]::new();$parentInfo.FileName=$info.FileName
    $parentInfo.Arguments='-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($parentCode))
    $parentInfo.UseShellExecute=$false;$parentInfo.CreateNoWindow=$true
    foreach($name in @('TEMP','TMP','XDG_CACHE_HOME','DENO_DIR')){$parentInfo.EnvironmentVariables[$name]=Join-Path $root 'temp'}
    $parent=[Diagnostics.Process]::new();$parent.StartInfo=$parentInfo
    try{
        Assert-Backend ($parent.Start() -and $parent.WaitForExit(10000) -and $parent.ExitCode -eq 0) 'temporary parent exits normally after starting the standalone worker'
        $timer=[Diagnostics.Stopwatch]::StartNew()
        while(-not [IO.File]::Exists($detachedResult) -and $timer.Elapsed.TotalSeconds -lt 30){Start-Sleep -Milliseconds 50}
        if(-not [IO.File]::Exists($detachedResult)){$cleanupSafe=$false;throw 'Detached owned worker did not finish; fixture and worker identity retained.'}
        Assert-Backend ((ConvertFrom-Json ([IO.File]::ReadAllText($detachedResult))).Status -eq 'Verified') 'worker finishes and records its result after its parent has exited'
    }finally{$parent.Dispose()}
    Write-Output "PASS: $script:BackendChecks update checks; real CMS signatures, inventory, hostile ZIP paths, decision races, locking and exact selector rollback."
}finally{if($cleanupSafe){Remove-BackendTestDirectory $fixture $root}}
