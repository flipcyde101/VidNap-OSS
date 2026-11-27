$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
$module=Join-Path $root 'VidNap.Storage.ps1'
if(Test-Path -LiteralPath $module){. $module}
$script:checks=0
function Assert-Storage($condition,[string]$label){
    if(-not $condition){throw ('FAIL: '+$label)}
    $script:checks++
}
function Assert-StorageCode([scriptblock]$Action,[string]$Code){
    $message=''
    try{& $Action|Out-Null}catch{$message=$_.Exception.Message}
    Assert-Storage ($message.StartsWith($Code,[StringComparison]::Ordinal)) ('rejects with '+$Code)
}
function Get-StorageFixtureHash([string]$Path){
    $algorithm=[Security.Cryptography.SHA256]::Create()
    $stream=[IO.File]::OpenRead($Path)
    try{return [BitConverter]::ToString($algorithm.ComputeHash($stream))}finally{$stream.Dispose();$algorithm.Dispose()}
}
Assert-Storage ($null -ne (Get-Command Get-VidNapInstallationPaths -ErrorAction SilentlyContinue)) 'explicit storage resolver exists'
$fixture=Join-Path $root ('local-verification\storage-'+[Guid]::NewGuid().ToString('N'))
$app=Join-Path $fixture 'app'
$data=Join-Path $fixture 'state'
$media=Join-Path $fixture 'literal % and %TEMP%\media'
[IO.Directory]::CreateDirectory($app)|Out-Null
[IO.Directory]::CreateDirectory($data)|Out-Null
[IO.Directory]::CreateDirectory($media)|Out-Null
$config=Join-Path $app 'vidnap-installation.json'
function Write-StorageFixture($Value){
    [IO.File]::WriteAllText($config,($Value|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
}
$good=@{SchemaVersion=1;ApplicationRoot=$app;DataRoot=$data;MediaRoot=$media}
try{
    Assert-StorageCode {Get-VidNapInstallationPaths $app '' ''} 'VIDNAP_STORAGE_CONFIG_MISSING'
    Write-StorageFixture $good
    $hash=Get-StorageFixtureHash $config
    $beforeTemp=$env:TEMP;$beforeLocal=$env:LOCALAPPDATA
    $result=Get-VidNapInstallationPaths $app '' ''
    Assert-Storage ($result.ApplicationRoot -ceq $app) 'application root is explicit'
    Assert-Storage ($result.DataRoot -ceq $data) 'data root is explicit'
    Assert-Storage ($result.MediaRoot -ceq $media) 'literal percent folder is preserved'
    Assert-Storage ($result.TempRoot -ceq (Join-Path $data 'temp')) 'temp is under data root'
    Assert-Storage ($result.CacheRoot -ceq (Join-Path $data 'cache')) 'cache is under data root'
    Assert-Storage ($result.DenoRoot -ceq (Join-Path $data 'deno-cache')) 'Deno cache is under data root'
    Assert-Storage ($env:TEMP -ceq $beforeTemp -and $env:LOCALAPPDATA -ceq $beforeLocal) 'resolution does not alter environment'
    Assert-Storage ((Get-StorageFixtureHash $config) -ceq $hash) 'resolution does not rewrite configuration'
    $overrideData=Join-Path $fixture 'override-data'
    $overrideMedia=Join-Path $fixture 'override-media'
    $overridden=Get-VidNapInstallationPaths $app $overrideData $overrideMedia
    Assert-Storage ($overridden.DataRoot -ceq $overrideData -and $overridden.MediaRoot -ceq $overrideMedia) 'explicit overrides stay explicit'
    Assert-Storage (-not [IO.Directory]::Exists($overrideData)) 'resolution alone does not create folders'
    Assert-StorageCode {Get-VidNapInstallationPaths $app $overrideData ''} 'VIDNAP_STORAGE_OVERRIDE_PAIR'
    foreach($bad in @('relative\state','D:relative','\\example.invalid\share','D:\OneDrive\VidNap','D:\folder\state:stream')){
        $value=@{SchemaVersion=1;ApplicationRoot=$app;DataRoot=$bad;MediaRoot=$media}
        Write-StorageFixture $value
        Assert-StorageCode {Get-VidNapInstallationPaths $app '' ''} 'VIDNAP_STORAGE_PATH'
    }
    $unused=@('Z','Y','X','W','V','U','T','S','R','Q')|Where-Object {-not [IO.Directory]::Exists(($_+':\'))}|Select-Object -First 1
    if(-not $unused){throw 'No unused drive available for the missing-drive fixture.'}
    Write-StorageFixture @{SchemaVersion=1;ApplicationRoot=$app;DataRoot=($unused+':\VidNap');MediaRoot=$media}
    Assert-StorageCode {Get-VidNapInstallationPaths $app '' ''} 'VIDNAP_STORAGE_DRIVE'
    foreach($badSchema in @('1',2,$null)){
        Write-StorageFixture @{SchemaVersion=$badSchema;ApplicationRoot=$app;DataRoot=$data;MediaRoot=$media}
        Assert-StorageCode {Get-VidNapInstallationPaths $app '' ''} 'VIDNAP_STORAGE_SCHEMA'
    }
    Write-StorageFixture @{SchemaVersion=1;ApplicationRoot=$app;DataRoot=$data;MediaRoot=$media;Unexpected='ignored is unsafe'}
    Assert-StorageCode {Get-VidNapInstallationPaths $app '' ''} 'VIDNAP_STORAGE_SCHEMA'
    [IO.File]::WriteAllText($config,'{not json',[Text.UTF8Encoding]::new($false))
    Assert-StorageCode {Get-VidNapInstallationPaths $app '' ''} 'VIDNAP_STORAGE_CONFIG_INVALID'
    foreach($json in @('null','[]','"text"','42','true')){
        [IO.File]::WriteAllText($config,$json,[Text.UTF8Encoding]::new($false))
        Assert-StorageCode {Get-VidNapInstallationPaths $app '' ''} 'VIDNAP_STORAGE_SCHEMA'
    }
    Write-StorageFixture @{SchemaVersion=1;ApplicationRoot=$app;DataRoot=$app;MediaRoot=$media}
    Assert-StorageCode {Get-VidNapInstallationPaths $app '' ''} 'VIDNAP_STORAGE_PATH'
    Write-StorageFixture @{SchemaVersion=1;ApplicationRoot=$app;DataRoot=$data;MediaRoot=(Join-Path $data 'inside-state')}
    Assert-StorageCode {Get-VidNapInstallationPaths $app '' ''} 'VIDNAP_STORAGE_PATH'
    Write-StorageFixture $good
    $link=Join-Path $fixture 'redirected'
    New-Item -ItemType Junction -Path $link -Target $data|Out-Null
    try{
        Write-StorageFixture @{SchemaVersion=1;ApplicationRoot=$app;DataRoot=(Join-Path $link 'state');MediaRoot=$media}
        Assert-StorageCode {Get-VidNapInstallationPaths $app '' ''} 'VIDNAP_STORAGE_REPARSE'
    }finally{[IO.Directory]::Delete($link)}
    Write-StorageFixture $good
    foreach($child in @('temp','cache','deno-cache')){
        $redirect=Join-Path $data $child
        New-Item -ItemType Junction -Path $redirect -Target $media|Out-Null
        try{
            Assert-StorageCode {Get-VidNapInstallationPaths $app '' ''} 'VIDNAP_STORAGE_REPARSE'
            Assert-StorageCode {Get-VidNapRuntimeEnvironment ([pscustomobject]@{DataRoot=$data})} 'VIDNAP_STORAGE_REPARSE'
        }finally{[IO.Directory]::Delete($redirect)}
    }
    $paths=Get-VidNapInstallationPaths $app '' ''
    $operation=[Guid]::NewGuid()
    Assert-VidNapDirectoryWritable $data $operation
    Assert-Storage (-not [IO.File]::Exists((Join-Path $data ('.vidnap-probe-'+$operation.ToString('N')+'.tmp')))) 'write probe cleans only its own file'
    $collision=Join-Path $data ('.vidnap-probe-'+$operation.ToString('N')+'.tmp')
    [IO.File]::WriteAllText($collision,'preserve existing bytes')
    Assert-StorageCode {Assert-VidNapDirectoryWritable $data $operation} 'VIDNAP_STORAGE_WRITE'
    Assert-Storage ([IO.File]::ReadAllText($collision) -ceq 'preserve existing bytes') 'failed write probe preserves existing file'
    $runtime=Get-VidNapRuntimeEnvironment $paths
    Assert-Storage ($runtime.TEMP -ceq (Join-Path $data 'temp') -and $runtime.TMP -ceq $runtime.TEMP) 'child scratch paths are D-backed'
    Assert-Storage (-not $runtime.ContainsKey('LOCALAPPDATA') -and -not $runtime.ContainsKey('APPDATA')) 'browser profile locations are not redirected'
    Write-Output "PASS: $script:checks backend storage checks; real isolated configuration, literal paths, missing drive, reparse rejection and write failures."
}finally{
    $resolved=[IO.Path]::GetFullPath($fixture)
    $expectedParent=[IO.Path]::GetFullPath((Join-Path $root 'local-verification')).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($expectedParent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^storage-[a-f0-9]{32}$'){throw 'Unsafe fixture cleanup refused.'}
    if([IO.Directory]::Exists($resolved)){
        $pending=[Collections.Generic.Stack[string]]::new();$pending.Push($resolved)
        while($pending.Count){
            foreach($entry in [IO.Directory]::EnumerateFileSystemEntries($pending.Pop())){
                $attributes=[IO.File]::GetAttributes($entry)
                if($attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Redirected fixture entry retained; recursive cleanup refused.'}
                if($attributes -band [IO.FileAttributes]::Directory){$pending.Push($entry)}
            }
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
