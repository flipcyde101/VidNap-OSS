[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$SourceRoot,[Parameter(Mandatory=$true)][string]$QaRoot,[Parameter(Mandatory=$true)][string]$EngineDirectory,[switch]$TestOnly,[string]$TranscriptionPolicy='',[string]$StateDirectory='',[string]$MediaDirectory='',[Parameter(Mandatory=$true)][ValidatePattern('^[A-Fa-f0-9]{40}$')][string]$SignerThumbprint,[Parameter(Mandatory=$true)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$SignerCertificateSha256)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$thumb=$SignerThumbprint.ToUpperInvariant()
$cert=Get-Item -LiteralPath ('Cert:\CurrentUser\My\'+$thumb)
$sha=[Security.Cryptography.SHA256]::Create()
try{$fingerprint=[BitConverter]::ToString($sha.ComputeHash($cert.RawData)).Replace('-','')}finally{$sha.Dispose()}
if($fingerprint -cne $SignerCertificateSha256.ToUpperInvariant() -or -not $cert.HasPrivateKey -or $cert.NotBefore -gt (Get-Date) -or $cert.NotAfter -le (Get-Date)){throw 'The selected approved development signing identity is unavailable.'}
foreach($p in @($SourceRoot,$QaRoot,$EngineDirectory)){
 $full=[IO.Path]::GetFullPath($p)
 if($full -notmatch '^D:\\' -or $full -match '(?i)(^|\\)OneDrive(?: - [^\\]+)?(\\|$)' -or -not [IO.Directory]::Exists($full)){throw 'An existing explicit D: directory is required.'}
 $cursor=Get-Item -LiteralPath $full
 while($cursor){if($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Redirected preview storage refused.'};$cursor=$cursor.Parent}
}
if(-not [IO.File]::Exists((Join-Path $QaRoot 'vidnap-qa-root.json'))){throw 'The existing owner-approved private QA root is required.'}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
try{$sid=$identity.User.Value}finally{$identity.Dispose()}
foreach($rule in (Get-Acl -LiteralPath $QaRoot).Access){if($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin @($sid,'S-1-5-18','S-1-5-32-544')){throw 'QA root is not private. No permissions were changed.'}}
$run=Join-Path $QaRoot ('ui-'+[Guid]::NewGuid().ToString('N').Substring(0,12))
$bundle=Join-Path $run 'app';$state=Join-Path $run 'state';$media=Join-Path $run 'media'
if([string]::IsNullOrWhiteSpace($StateDirectory) -ne [string]::IsNullOrWhiteSpace($MediaDirectory)){throw 'Supply both existing QA state and media folders, or neither.'}
if($StateDirectory){
    $prefix=[IO.Path]::GetFullPath($QaRoot).TrimEnd('\')+'\'
    foreach($candidate in @($StateDirectory,$MediaDirectory)){
        $full=[IO.Path]::GetFullPath($candidate)
        if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or -not [IO.Directory]::Exists($full)){throw 'Reuse is limited to existing isolated QA folders, never the installed copy.'}
        $cursor=Get-Item -LiteralPath $full
        while($cursor){if($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Redirected QA reuse refused.'};$cursor=$cursor.Parent}
        foreach($rule in (Get-Acl -LiteralPath $full).Access){if($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin @($sid,'S-1-5-18','S-1-5-32-544')){throw 'Reused QA folder is not private.'}}
    }
    $state=[IO.Path]::GetFullPath($StateDirectory);$media=[IO.Path]::GetFullPath($MediaDirectory)
}
foreach($p in @($bundle,$state,$media,(Join-Path $bundle 'tests'),(Join-Path $bundle 'preview\web'),(Join-Path $state 'temp'))){[IO.Directory]::CreateDirectory($p)|Out-Null}
$names=@('VidNap.Core.ps1','VidNap.Storage.ps1','VidNap.Analysis.ps1','VidNap.Jobs.ps1','VidNap.Captions.ps1','VidNap.Backend.ps1','VidNap.Manager.ps1','VidNap.Preview.ps1','VidNap.JobStore.cs','VidNap.BackendProcess.cs','VidNap.ProcessRunner.cs','VidNap.Peer.cs','tests\Backend.TestSupport.ps1','tests\Preview.Manager.Tests.ps1','tests\Preview.Rpc.Probe.ps1')
$files=@($names|Where-Object {Test-Path -LiteralPath (Join-Path $SourceRoot $_)})
if(Test-Path -LiteralPath (Join-Path $SourceRoot 'preview')){$files+=@(Get-ChildItem -LiteralPath (Join-Path $SourceRoot 'preview') -File -Recurse|ForEach-Object {$_.FullName.Substring($SourceRoot.TrimEnd('\').Length+1)})}
$inventory=@(foreach($file in $files){
 $target=Join-Path $bundle $file;[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))|Out-Null
 Copy-Item -LiteralPath (Join-Path $SourceRoot $file) -Destination $target
 if($file.EndsWith('.ps1',[StringComparison]::OrdinalIgnoreCase)){
  $signature=Set-AuthenticodeSignature -LiteralPath $target -Certificate $cert -HashAlgorithm SHA256
  if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -cne $thumb){throw 'Isolated preview signature verification failed.'}
 }
 [pscustomobject]@{File=$file;SourceSha256=(Get-FileHash -LiteralPath (Join-Path $SourceRoot $file)).Hash;ArtifactSha256=(Get-FileHash -LiteralPath $target).Hash}
})
if(Test-Path -LiteralPath (Join-Path $bundle 'preview\Build-Icons.ps1')){
    & (Join-Path $bundle 'preview\Build-Icons.ps1') -Destination (Join-Path $bundle 'preview\web\icons')
    $inventory+=@(Get-ChildItem -LiteralPath (Join-Path $bundle 'preview\web\icons') -Filter '*.png' -File|ForEach-Object {[pscustomobject]@{File=('preview\web\icons\'+$_.Name);SourceSha256=$null;ArtifactSha256=(Get-FileHash -LiteralPath $_.FullName).Hash;GeneratedBy='preview\Build-Icons.ps1'}})
}
$manifestPath=Join-Path $EngineDirectory 'install-manifest.json'
$manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
if($manifest.schemaVersion -ne 3){throw 'A verified schema-3 existing engine inventory is required.'}
$tools=@{YtDlp=@{Path=(Join-Path $EngineDirectory 'yt-dlp.exe');Sha256=$manifest.ytDlpSha256};Ffmpeg=@{Path=(Join-Path $EngineDirectory 'ffmpeg\ffmpeg.exe');Sha256=$manifest.ffmpegBinarySha256.'ffmpeg.exe'};Ffprobe=@{Path=(Join-Path $EngineDirectory 'ffmpeg\ffprobe.exe');Sha256=$manifest.ffmpegBinarySha256.'ffprobe.exe'}}
foreach($t in $tools.Values){if((Get-FileHash -LiteralPath $t.Path).Hash -ine $t.Sha256){throw 'The existing engine no longer matches its inventory.'}}
if($manifest.PSObject.Properties.Name -contains 'denoSha256' -and $manifest.denoSha256){$p=Join-Path $EngineDirectory 'deno.exe';if((Get-FileHash -LiteralPath $p).Hash -ine $manifest.denoSha256){throw 'Deno inventory mismatch.'};$tools.Deno=@{Path=$p;Sha256=$manifest.denoSha256}}
$policy=$null
if($TranscriptionPolicy){
 if($TranscriptionPolicy -notmatch '^D:\\' -or (Get-Item -LiteralPath $TranscriptionPolicy).Length -gt 65536){throw 'Unsupported local transcription policy.'}
 $policy=Get-Content -LiteralPath $TranscriptionPolicy -Raw|ConvertFrom-Json
}
$config=@{schemaVersion=1;applicationRoot=$bundle;dataRoot=$state;mediaRoot=$media;tools=$tools;transcription=$policy;engineInventorySha256=(Get-FileHash -LiteralPath $manifestPath).Hash}
[IO.File]::WriteAllText((Join-Path $bundle 'vidnap-installation.json'),(@{SchemaVersion=1;ApplicationRoot=$bundle;DataRoot=$state;MediaRoot=$media}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $run 'preview-config.json'),($config|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $run 'artifacts.json'),($inventory|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
Write-Output ('PREVIEW_RUN '+$run)
if($TestOnly){
 $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $info.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy AllSigned -WindowStyle Hidden -File "'+(Join-Path $bundle 'tests\Preview.Manager.Tests.ps1')+'"'
 $info.WorkingDirectory=$bundle;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
 $info.EnvironmentVariables['TEMP']=Join-Path $state 'temp';$info.EnvironmentVariables['TMP']=Join-Path $state 'temp'
 $info.EnvironmentVariables['PSModulePath']=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\Modules'
 $p=[Diagnostics.Process]::new();$p.StartInfo=$info
 if(-not $p.Start()){throw 'Signed test process did not start.'}
 $out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();$p.WaitForExit()
 $stdout=$out.GetAwaiter().GetResult();$stderr=$err.GetAwaiter().GetResult();$exit=$p.ExitCode;$p.Dispose()
 [IO.File]::WriteAllText((Join-Path $run 'tests.txt'),$stdout+"`n"+$stderr,[Text.UTF8Encoding]::new($false))
 Write-Output $stdout;if($stderr){Write-Output $stderr};Write-Output ('PREVIEW_TEST_EXIT '+$exit);exit $exit
}
Write-Output ('PREVIEW_CONFIG '+(Join-Path $run 'preview-config.json'))
