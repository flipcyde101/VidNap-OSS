[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Configuration)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$manager=$null
$startupStage='Configuration'
try {
    if($Configuration -notmatch '^D:\\' -or (Get-Item -LiteralPath $Configuration).Length -gt 65536){throw 'VIDNAP_PREVIEW_CONFIG'}
    $config=Get-Content -LiteralPath $Configuration -Raw|ConvertFrom-Json
    $startupStage='Modules'
    foreach($name in @('Core','Storage','Analysis','Jobs','Captions','Backend','Manager')){. (Join-Path $PSScriptRoot ('VidNap.'+$name+'.ps1'))}
    $startupStage='Storage'
    $paths=Get-VidNapInstallationPaths $PSScriptRoot $config.dataRoot $config.mediaRoot
    foreach($v in (Get-VidNapRuntimeEnvironment $paths).GetEnumerator()){[Environment]::SetEnvironmentVariable($v.Key,$v.Value,'Process')}
    $startupStage='PeerType'
    $parameters=New-VidNapCompilerParameters $paths
    Add-Type -Path (Join-Path $PSScriptRoot 'VidNap.Peer.cs') -CompilerParameters $parameters
    $startupStage='Manager'
    $manager=New-VidNapManager $paths $config.tools $null $config.transcription
    $startupStage='Input'
    [Console]::Out.WriteLine('{"event":"ready"}')
    $reader=[IO.StreamReader]::new([Console]::OpenStandardInput(),[Text.UTF8Encoding]::new($false,$true),$false,4096,$false)
    $lineTask=$reader.ReadLineAsync()
    while($true){
        Receive-VidNapManagerTick $manager
        if($lineTask.IsCompleted){
            $line=$lineTask.GetAwaiter().GetResult()
            if($null -eq $line){break}
            if($line.Length -gt 65536){throw 'VIDNAP_PREVIEW_LIMIT'}
            $id=$null
            try {
                $request=ConvertFrom-Json $line;$id=$request.id;$p=$request.params
                $result=switch([string]$request.method){
                    'authorizePeer' {[VidNapPreviewPeer]::IsCurrentUser([int]$p.clientPort,[int]$p.serverPort);break}
                    'state' {Get-VidNapManagerState $manager ([string](Get-VidNapDataValue $p 'selectedId' ''));break}
                    'add' { $ids=@(Add-VidNapManagerLinks $manager @($p.links) $p.selection ($p.consent -ceq $true) $p.browser);@{ids=$ids};break }
                    'selection' {Set-VidNapManagerSelection $manager $p.id $p.selection;@{saved=$true};break}
                    'start' {Start-VidNapManagerQueue $manager ([string](Get-VidNapDataValue $p 'id' '')) ($p.consent -ceq $true) $p.browser;@{started=$true};break}
                    'cancel' {Stop-VidNapManagerItem $manager $p.id;@{requested=$true};break}
                    'dismiss' {Dismiss-VidNapManagerItem $manager $p.id;@{dismissed=$true};break}
                    'retry' {Resume-VidNapManagerItem $manager $p.id ($p.consent -ceq $true) $p.browser;@{requested=$true};break}
                    'captions' { @{id=(Start-VidNapManagerCaption $manager $p.id $p.language ($p.allowAutomatic -ceq $true) ($p.consent -ceq $true) $p.browser)};break }
                    'generate' { @{id=(Start-VidNapManagerGeneration $manager $p.id ([int]$p.index))};break }
                    'transcript' {Get-VidNapManagerTranscript $manager $p.id;break}
                    'export' {Export-VidNapManagerTranscript $manager $p.id $p.format;break}
                    'media' {Get-VidNapManagerMedia $manager $p.id ([int]$p.index);break}
                    'reveal' {
                        $file=if((Get-VidNapDataValue $p 'kind' '') -eq 'transcript'){(Export-VidNapManagerTranscript $manager $p.id $p.format).path}else{(Get-VidNapManagerMedia $manager $p.id ([int]$p.index)).path}
                        $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=Join-Path $env:WINDIR 'explorer.exe';$info.Arguments='/select,'+(Quote-Argument $file);$info.UseShellExecute=$false;$info.CreateNoWindow=$true
                        [Diagnostics.Process]::Start($info)|Out-Null;@{opened=$true};break
                    }
                    default {throw 'VIDNAP_PREVIEW_METHOD'}
                }
                $response=@{id=$id;ok=$true;result=$result}
            }catch{
                $code=[regex]::Match($_.Exception.Message,'VIDNAP_[A-Z0-9_]+').Value
                if(-not $code){$code='VIDNAP_PREVIEW_OPERATION'}
                Write-VidNapManagerEvent $manager $code
                $response=@{id=$id;ok=$false;error=@{code=$code}}
            }
            [Console]::Out.WriteLine(($response|ConvertTo-Json -Depth 18 -Compress))
            $lineTask=$reader.ReadLineAsync()
        } else {[Threading.Thread]::Sleep(50)}
    }
}catch{
    if($Configuration -match '^D:\\'){
        $diagnostic=@{stage=$startupStage;exceptionType=$_.Exception.GetType().FullName;hresult=$_.Exception.HResult;errorId=([regex]::Replace($_.FullyQualifiedErrorId,'[^A-Za-z0-9_.:-]',''));sourceLine=$_.InvocationInfo.ScriptLineNumber;utc=[DateTimeOffset]::UtcNow.ToString('o')}
        try{[IO.File]::WriteAllText((Join-Path ([IO.Path]::GetDirectoryName($Configuration)) 'startup-diagnostic.json'),($diagnostic|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}catch{}
    }
    [Console]::Out.WriteLine('{"event":"fatal","code":"VIDNAP_PREVIEW_START"}')
    exit 1
}finally{if($manager){Close-VidNapManager $manager}}
