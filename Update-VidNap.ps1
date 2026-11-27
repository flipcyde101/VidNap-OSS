[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PackagePath,
    [Parameter(Mandatory=$true)][string]$InstallationConfigPath,
    [Parameter(Mandatory=$true)][string]$ExpectedPublisherThumbprint,
    [Parameter(Mandatory=$true)][string]$ExpectedCertificateSha256,
    [Parameter(Mandatory=$true)][string]$DecisionFile,
    [Parameter(Mandatory=$true)][string]$ResultFile,
    [switch]$VerifyOnly,
    [int]$WaitForProcessId=0
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
foreach($name in @('Core','Storage','Analysis','Update')){. (Join-Path $PSScriptRoot ('VidNap.'+$name+'.ps1'))}
$exitCode=1
$resultParent='';$paths=$null
try{
    $paths=Get-VidNapInstallationPaths ([IO.Path]::GetDirectoryName($InstallationConfigPath))
    $resultParent=ConvertTo-VidNapLocalDirectory ([IO.Path]::GetDirectoryName($ResultFile))
    if($resultParent -ine $paths.DataRoot -or [IO.Path]::GetFileName($ResultFile) -match '[:*?"<>|]' -or [IO.File]::Exists($ResultFile) -or [IO.Directory]::Exists($ResultFile)){
        throw 'VIDNAP_UPDATE_RESULT: Choose a new result file in the state root.'
    }
    $verified=Get-VidNapVerifiedPackage $PackagePath $ExpectedPublisherThumbprint $ExpectedCertificateSha256
    $verify={param($Directory)
        foreach($file in $verified.Manifest.Files){
            if((Get-VidNapFileSha256 (Join-Path $Directory $file.Path.Replace('/','\'))) -ine $file.Sha256){return $false}
        }
        return $true
    }.GetNewClosure()
    $result=Invoke-VidNapAppUpdate -PackagePath $PackagePath -InstallationConfigPath $InstallationConfigPath -ExpectedPublisherThumbprint $ExpectedPublisherThumbprint -ExpectedCertificateSha256 $ExpectedCertificateSha256 -DecisionFile $DecisionFile -VerifyOnly:$VerifyOnly -WaitForProcessId $WaitForProcessId -PostCommitVerifier $verify -Progress {param($Snapshot) [Console]::Out.WriteLine(($Snapshot|ConvertTo-Json -Compress))}
    # File/signature verification is not proof of Windows launch acceptance.
    if($result.Status -eq 'Committed'){$result.Status='SelectedNeedsLaunchAcceptance'}
    $exitCode=if($result.Status -in @('Verified','SelectedNeedsLaunchAcceptance','Cancelled')){0}else{1}
}catch{
    $result=[pscustomobject]@{Status='Failed';ErrorCode='VIDNAP_UPDATE_WORKER_FAILED';InstalledLaunchTested=$false}
}
if($paths -and $resultParent -and $resultParent -ieq $paths.DataRoot){
    $stream=$null
    $pending=Join-Path $resultParent ('.update-result-'+[Guid]::NewGuid().ToString('N')+'.tmp')
    try{
        $stream=[IO.FileStream]::new($pending,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($result|ConvertTo-Json -Depth 5));$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)
        $stream.Dispose();$stream=$null
        # Publish only a complete, closed receipt. Move never overwrites.
        [IO.File]::Move($pending,$ResultFile)
    }catch{$exitCode=1}finally{if($stream){$stream.Dispose()}}
}
$result|ConvertTo-Json -Depth 5 -Compress
exit $exitCode
