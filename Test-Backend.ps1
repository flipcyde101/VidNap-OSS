[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SourceRoot,
    [string]$Suite='All',
    [switch]$IncludeEngine,
    [string]$EngineDirectory='',
    [string]$QaRoot='',
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Fa-f0-9]{40}$')][string]$SignerThumbprint,
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$SignerCertificateSha256
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$SourceRoot=[IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
if([IO.Path]::GetPathRoot($SourceRoot) -ine 'D:\' -or $SourceRoot -match '(?i)(^|[\\/])OneDrive(?: - [^\\/]+)?([\\/]|$)'){throw 'Verification sources must be on D:, outside OneDrive.'}
$cursor=Get-Item -LiteralPath $SourceRoot
while($cursor){if($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Redirected verification source refused.'};$cursor=$cursor.Parent}
foreach($rule in (Get-Acl -LiteralPath $SourceRoot).Access){
    $sid=$rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
    if($rule.AccessControlType -eq 'Allow' -and $sid -in @('S-1-1-0','S-1-5-11','S-1-5-32-545')){throw 'Verification source folder is not private.'}
}
$thumb=$SignerThumbprint.ToUpperInvariant()
$cert=Get-Item -LiteralPath ('Cert:\CurrentUser\My\'+$thumb)
$sha=[Security.Cryptography.SHA256]::Create()
try{$der=[BitConverter]::ToString($sha.ComputeHash($cert.RawData)).Replace('-','')}finally{$sha.Dispose()}
if($der -cne $SignerCertificateSha256.ToUpperInvariant() -or
    -not $cert.HasPrivateKey -or $cert.NotBefore -gt (Get-Date) -or $cert.NotAfter -le (Get-Date)){throw 'The existing approved development signer is unavailable. No trust or certificate setup is attempted.'}
if($QaRoot){
    $QaRoot=[IO.Path]::GetFullPath($QaRoot).TrimEnd('\')
    if([IO.Path]::GetPathRoot($QaRoot) -ine 'D:\' -or -not [IO.Directory]::Exists($QaRoot) -or -not [IO.File]::Exists((Join-Path $QaRoot 'vidnap-qa-root.json'))){throw 'An existing owner-approved D: QA root and marker are required.'}
    $current=[Security.Principal.WindowsIdentity]::GetCurrent()
    try{$owner=$current.User.Value}finally{$current.Dispose()}
    $cursor=Get-Item -LiteralPath $QaRoot
    while($cursor){if($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Redirected QA root refused.'};$cursor=$cursor.Parent}
    foreach($rule in (Get-Acl -LiteralPath $QaRoot).Access){
        if($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin @($owner,'S-1-5-18','S-1-5-32-544')){throw 'QA root has unreviewed access; no ACL change was attempted.'}
    }
}else{throw 'An explicit existing private D: QaRoot is required. No implicit QA storage was selected.'}
$run=Join-Path $QaRoot ('r-'+[Guid]::NewGuid().ToString('N').Substring(0,12))
$bundle=Join-Path $run 'bundle'
[IO.Directory]::CreateDirectory((Join-Path $bundle 'tests'))|Out-Null
[IO.Directory]::CreateDirectory((Join-Path $bundle 'temp'))|Out-Null
$names=@('VidNap.Core.ps1','VidNap.Storage.ps1','VidNap.Analysis.ps1','VidNap.Jobs.ps1','VidNap.Captions.ps1',
    'VidNap.Update.ps1','VidNap.Backend.ps1','Update-VidNap.ps1','VidNap.JobStore.cs','VidNap.BackendProcess.cs','VidNap.ProcessRunner.cs')
$files=@($names|Where-Object {Test-Path -LiteralPath (Join-Path $SourceRoot $_)})
$files+=@('tests\Core.Tests.ps1','tests\Progress.Tests.ps1','tests\Run-BackendTests.ps1')
$files+=@(Get-ChildItem -LiteralPath (Join-Path $SourceRoot 'tests') -File -Filter 'Backend.*.ps1'|ForEach-Object {'tests\'+$_.Name})
$manifest=@(foreach($file in $files){
    $copy=Join-Path $bundle $file
    Copy-Item -LiteralPath (Join-Path $SourceRoot $file) -Destination $copy
    if($file.EndsWith('.ps1',[StringComparison]::OrdinalIgnoreCase)){
        $signature=Set-AuthenticodeSignature -LiteralPath $copy -Certificate $cert -HashAlgorithm SHA256
        if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -cne $thumb){throw 'QA artifact signature verification failed.'}
    }
    [pscustomobject]@{File=$file;SourceSha256=(Get-FileHash -LiteralPath (Join-Path $SourceRoot $file)).Hash;ArtifactSha256=(Get-FileHash -LiteralPath $copy).Hash}
})
[IO.File]::WriteAllText((Join-Path $run 'artifacts.json'),($manifest|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
$out=Join-Path $run 'stdout.txt';$err=Join-Path $run 'stderr.txt'
$arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy AllSigned -WindowStyle Hidden -STA -File "'+(Join-Path $bundle 'tests\Run-BackendTests.ps1')+'" -Suite '+$Suite
if($IncludeEngine){
    if([string]::IsNullOrWhiteSpace($EngineDirectory)){throw 'An explicit existing engine directory is required for engine fixtures.'}
    $arguments+=' -IncludeEngine -EngineDirectory "'+$EngineDirectory+'"'
}
$info=[Diagnostics.ProcessStartInfo]::new()
$info.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$info.Arguments=$arguments;$info.WorkingDirectory=$bundle;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
foreach($name in @('TEMP','TMP','XDG_CACHE_HOME','DENO_DIR')){$info.EnvironmentVariables[$name]=Join-Path $bundle 'temp'}
$info.EnvironmentVariables['VIDNAP_TEST_SIGNER_THUMBPRINT']=$thumb
$info.EnvironmentVariables['VIDNAP_TEST_SIGNER_CERT_SHA256']=$der
$process=[Diagnostics.Process]::new();$process.StartInfo=$info
if(-not $process.Start()){throw 'The signed QA host did not start.'}
$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
Write-Output ('QA_RUN '+$run)
Write-Output ('QA_PID '+$process.Id)
$process.WaitForExit()
$output=$stdout.GetAwaiter().GetResult();$errors=$stderr.GetAwaiter().GetResult()
[IO.File]::WriteAllText($out,$output,[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($err,$errors,[Text.UTF8Encoding]::new($false))
$result=[ordered]@{Suite=$Suite;ExitCode=$process.ExitCode;RunDirectory=$run;Signer=$thumb;SourceCommit=(git -C $SourceRoot rev-parse HEAD);FinishedUtc=[DateTime]::UtcNow.ToString('o')}
[IO.File]::WriteAllText((Join-Path $run 'result.json'),($result|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
Write-Output $output
if($errors){Write-Output $errors}
$exit=$process.ExitCode;$process.Dispose()
Write-Output ('QA_EXIT '+$exit)
exit $exit
