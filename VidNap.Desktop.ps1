Set-StrictMode -Version Latest

function Get-VidNapDesktopHash([string]$Path) {
    $hash=[Security.Cryptography.SHA256]::Create();$stream=[IO.File]::OpenRead($Path)
    try{return [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-','')}finally{$stream.Dispose();$hash.Dispose()}
}

function Assert-VidNapDesktopContent($Context,[string]$Root) {
    try {
        Assert-VidNapPrivateDirectory $Root
        $prefix=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
        foreach($entry in $Context.Files){
            $relative=[string]$entry.file
            if(-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.{1,2}([\\/]|$)' -or $relative -match '[:*?"<>|]'){throw 'Invalid entry'}
            $file=[IO.Path]::GetFullPath((Join-Path $Root $relative))
            if(-not $file.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Escaped entry'}
            Assert-VidNapRegularFile $file|Out-Null
            if([string]$entry.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or (Get-VidNapDesktopHash $file) -ine $entry.sha256){throw 'Hash mismatch'}
        }
    }catch{throw 'VIDNAP_DESKTOP_INTEGRITY: Application files changed or cannot be verified. No replacement was run.'}
}

function Read-VidNapDesktopConfiguration([string]$Path) {
    try {
        Assert-VidNapRegularFile $Path|Out-Null
        if(([IO.FileInfo]$Path).Length -gt 65536){throw 'Large configuration'}
        $config=ConvertFrom-Json ([IO.File]::ReadAllText($Path))
        if($config.schemaVersion -ne 1){throw 'Unsupported configuration'}
        foreach($name in @('applicationRoot','dataRoot','mediaRoot')){
            $folder=ConvertTo-VidNapLocalDirectory ([string]$config.$name)
            if([IO.Path]::GetPathRoot($folder) -ine 'D:\'){throw 'Wrong drive'}
            Assert-VidNapPrivateDirectory $folder
        }
    }catch{throw 'VIDNAP_DESKTOP_STORAGE: Private D: application, settings and media folders are required. No C: fallback was used.'}
    $node=[string]$config.nodePath
    if(-not [IO.File]::Exists($node) -or ([IO.File]::GetAttributes($node) -band [IO.FileAttributes]::ReparsePoint) -or
        [string]$config.nodeSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or (Get-VidNapDesktopHash $node) -ine $config.nodeSha256){
        throw 'VIDNAP_DESKTOP_RUNTIME: The pinned existing Node runtime is missing or changed. Nothing was installed.'
    }
    foreach($file in @([string]$config.runtimeTemplate,[string]$config.inventory)){
        Assert-VidNapRegularFile $file|Out-Null
        $prefix=[IO.Path]::GetFullPath($config.applicationRoot).TrimEnd('\')+'\'
        if(-not ([IO.Path]::GetFullPath($file)).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or ([IO.FileInfo]$file).Length -gt 65536){throw 'VIDNAP_DESKTOP_INTEGRITY: Unsupported application configuration.'}
    }
    $files=@((ConvertFrom-Json ([IO.File]::ReadAllText($config.inventory))).files)
    if(-not $files.Count -or $files.Count -gt 200){throw 'VIDNAP_DESKTOP_INTEGRITY: Unsupported application inventory.'}
    $allowed=@(foreach($p in @($config.allowedApplicationRoots)){
        $folder=ConvertTo-VidNapLocalDirectory ([string]$p)
        if([IO.Path]::GetPathRoot($folder) -ine 'D:\'){throw 'VIDNAP_DESKTOP_STORAGE: Application roots must stay on D:.'}
        $folder
    })
    if($allowed -inotcontains $config.applicationRoot){throw 'VIDNAP_DESKTOP_INTEGRITY: Primary application root is not approved.'}
    $context=[pscustomobject]@{ApplicationRoot=[string]$config.applicationRoot;DataRoot=[string]$config.dataRoot;MediaRoot=[string]$config.mediaRoot
        NodePath=$node;RuntimeTemplate=[string]$config.runtimeTemplate;Files=$files;AllowedRoots=$allowed
        InitialInstance=(Get-VidNapDataValue $config 'initialInstance' $null)}
    Assert-VidNapDesktopContent $context $context.ApplicationRoot
    return $context
}

function Write-VidNapDesktopEvent($Context,[string]$Code) {
    if($Code -notmatch '^VIDNAP_[A-Z0-9_]{1,60}$'){return}
    $path=Join-Path $Context.DataRoot 'desktop-startup.jsonl'
    if([IO.File]::Exists($path)){Assert-VidNapRegularFile $path|Out-Null}
    if([IO.File]::Exists($path) -and ([IO.FileInfo]$path).Length -ge 256KB){return}
    [IO.File]::AppendAllText($path,((@{utc=[DateTimeOffset]::UtcNow.ToString('o');code=$Code}|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
}

function Find-VidNapDesktopProcesses($Context) {
    $nodes=[Collections.Generic.List[object]]::new();$workers=[Collections.Generic.List[object]]::new()
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try{$sid=$identity.User.Value}finally{$identity.Dispose()}
    foreach($root in $Context.AllowedRoots){
        foreach($kind in @('node','worker')){
            $script=if($kind -eq 'node'){Join-Path $root 'preview\server.mjs'}else{Join-Path $root 'VidNap.Preview.ps1'}
            $name=if($kind -eq 'node'){'node.exe'}else{'powershell.exe'}
            $needle=$script.Replace('\','\\').Replace("'","\'")
            $filter="Name='$name' AND CommandLine LIKE '%$needle%'"
            foreach($process in @(Get-CimInstance Win32_Process -Filter $filter -ErrorAction Stop)){
                $pattern=if($kind -eq 'node'){'(?i)(?:"'+[regex]::Escape($script)+'"|'+[regex]::Escape($script)+')\s+(?:"(?<config>[^"]+)"|(?<config>\S+))\s*$'}else{'(?i)-Configuration\s+(?:"(?<config>[^"]+)"|(?<config>\S+))'}
                $match=[regex]::Match([string]$process.CommandLine,$pattern)
                if(-not $match.Success){throw 'VIDNAP_DESKTOP_INSTANCE: A matching VidNap process has ambiguous startup arguments. No duplicate was started.'}
                $configuration=$match.Groups['config'].Value
                try {
                    Assert-VidNapRegularFile $configuration|Out-Null
                    if(([IO.FileInfo]$configuration).Length -gt 65536){throw 'Large configuration'}
                    $runtime=ConvertFrom-Json ([IO.File]::ReadAllText($configuration))
                    if($runtime.dataRoot -ine $Context.DataRoot -or $runtime.mediaRoot -ine $Context.MediaRoot){continue}
                    if($runtime.applicationRoot -ine $root){throw 'Different application root'}
                    $owner=Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid
                    $expected=if($kind -eq 'node'){$Context.NodePath}else{Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'}
                    if($process.ExecutablePath -ine $expected -or $owner.ReturnValue -ne 0 -or $owner.Sid -cne $sid){throw 'Different process identity'}
                    Assert-VidNapDesktopContent $Context $root
                }catch{throw 'VIDNAP_DESKTOP_INSTANCE: An existing VidNap process needs review. No duplicate was started.'}
                $record=[pscustomobject]@{pid=[int]$process.ProcessId;configuration=$configuration}
                if($kind -eq 'node'){$nodes.Add($record)}else{$workers.Add($record)}
            }
        }
    }
    return [pscustomobject]@{Nodes=@($nodes.ToArray());Workers=@($workers.ToArray())}
}

function Get-VidNapDesktopProbe($Context,$Record) {
    if(-not $Record){return [pscustomobject]@{State='Missing';Record=$null}}
    $processId=0
    if(-not [int]::TryParse([string](Get-VidNapDataValue $Record 'pid' ''),[ref]$processId) -or $processId -le 0){return [pscustomobject]@{State='Missing';Record=$null}}
    $process=Get-CimInstance Win32_Process -Filter ('ProcessId='+$processId) -ErrorAction Stop
    if(-not $process){return [pscustomobject]@{State='Missing';Record=$null}}
    if($process.ExecutablePath -ine $Context.NodePath){return [pscustomobject]@{State='Missing';Record=$null}}
    $configuration=[string](Get-VidNapDataValue $Record 'configuration' '')
    try {
        Assert-VidNapRegularFile $configuration|Out-Null
        if(([IO.FileInfo]$configuration).Length -gt 65536){throw 'Unsupported configuration'}
        $runtime=ConvertFrom-Json ([IO.File]::ReadAllText($configuration))
        if($runtime.applicationRoot -inotIn $Context.AllowedRoots -or $runtime.dataRoot -ine $Context.DataRoot -or $runtime.mediaRoot -ine $Context.MediaRoot){throw 'Different storage'}
        $server=Join-Path $runtime.applicationRoot 'preview\server.mjs'
        $owner=Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        try{$sid=$identity.User.Value}finally{$identity.Dispose()}
        if($owner.ReturnValue -ne 0 -or $owner.Sid -cne $sid -or $process.ExecutablePath -ine $Context.NodePath -or
            $process.CommandLine -notmatch ('"'+[regex]::Escape($server)+'"') -or $process.CommandLine -notmatch ('"'+[regex]::Escape($configuration)+'"')){throw 'Different process'}
        Assert-VidNapDesktopContent $Context $runtime.applicationRoot
    }catch{throw 'VIDNAP_DESKTOP_INSTANCE: An existing startup record requires review. No process was stopped and no duplicate worker was started.'}
    $addressFile=Join-Path ([IO.Path]::GetDirectoryName($configuration)) 'preview-address.json'
    if(-not [IO.File]::Exists($addressFile)){return [pscustomobject]@{State='Unready';Record=$Record}}
    try {
        Assert-VidNapRegularFile $addressFile|Out-Null
        if(([IO.FileInfo]$addressFile).Length -gt 8192){throw 'Large address'}
        $address=ConvertFrom-Json ([IO.File]::ReadAllText($addressFile))
        $url=[string]$address.url
        if($address.pid -ne $processId -or $address.configuration -ine $configuration -or $url -notmatch '^http://127\.0\.0\.1:([0-9]{1,5})/$' -or [int]$Matches[1] -lt 1 -or [int]$Matches[1] -gt 65535){throw 'Unsupported address'}
        $state=Invoke-RestMethod ($url+'api/state') -Headers @{'X-VidNap-Request'='1'} -TimeoutSec 1
        if($state.dataRoot -ine $Context.DataRoot -or $state.mediaRoot -ine $Context.MediaRoot -or $state.maxConcurrent -ne 2){throw 'Different worker'}
        return [pscustomobject]@{State='Healthy';Record=$address}
    }catch{return [pscustomobject]@{State='Unready';Record=$Record}}
}

function Get-OrStartVidNapDesktop($Context,[ValidateRange(1,60)][int]$TimeoutSeconds=45) {
    $watch=[Diagnostics.Stopwatch]::StartNew();$lock=$null;$created=$null
    $currentFile=Join-Path $Context.DataRoot 'desktop-instance.json'
    try {
        foreach($file in @($currentFile,(Join-Path $Context.DataRoot 'desktop-start.lock'))){if([IO.File]::Exists($file)){Assert-VidNapRegularFile $file|Out-Null}}
        while(-not $lock){
            try{$lock=[IO.File]::Open((Join-Path $Context.DataRoot 'desktop-start.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
            catch [IO.IOException]{if($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds){throw 'VIDNAP_DESKTOP_BUSY: Another startup is finishing. Wait, then open VidNap again.'};[Threading.Thread]::Sleep(100)}
        }
        $record=$Context.InitialInstance
        if([IO.File]::Exists($currentFile)){
            try{if(([IO.FileInfo]$currentFile).Length -gt 8192){throw 'Large receipt'};$record=ConvertFrom-Json ([IO.File]::ReadAllText($currentFile))}catch{throw 'VIDNAP_DESKTOP_INSTANCE: The retained startup record could not be read. No process was changed.'}
        }
        $probe=Get-VidNapDesktopProbe $Context $record
        while($probe.State -eq 'Missing'){
            $running=Find-VidNapDesktopProcesses $Context
            if($running.Nodes.Count -gt 1){throw 'VIDNAP_DESKTOP_INSTANCE: Multiple existing VidNap proxies require review. No process was stopped.'}
            if($running.Nodes.Count -eq 1){$record=$running.Nodes[0];$probe=Get-VidNapDesktopProbe $Context $record;if($probe.State -eq 'Missing'){continue};break}
            if(-not $running.Workers.Count){break}
            if($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds){throw 'VIDNAP_DESKTOP_WORKER_ALIVE: The previous download worker is still running or finishing. Wait for it to exit; no replacement was started.'}
            [Threading.Thread]::Sleep(150)
        }
        if($probe.State -eq 'Missing'){
            $runtime=ConvertFrom-Json ([IO.File]::ReadAllText($Context.RuntimeTemplate))
            if($runtime.applicationRoot -ine $Context.ApplicationRoot -or $runtime.dataRoot -ine $Context.DataRoot -or $runtime.mediaRoot -ine $Context.MediaRoot){throw 'VIDNAP_DESKTOP_STORAGE: Runtime paths do not match the pinned D: folders.'}
            $directory=ConvertTo-VidNapLocalDirectory (Join-Path $Context.DataRoot ('Runtime\run-'+[Guid]::NewGuid().ToString('N')))
            [IO.Directory]::CreateDirectory($directory)|Out-Null;Assert-VidNapPrivateDirectory $directory
            $configuration=Join-Path $directory 'preview-config.json'
            [IO.File]::WriteAllText($configuration,($runtime|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
            $server=Join-Path $Context.ApplicationRoot 'preview\server.mjs'
            $environment=@{}
            foreach($name in @('TEMP','TMP','XDG_CACHE_HOME','DENO_DIR')){$environment[$name]=[Environment]::GetEnvironmentVariable($name,'Process');[Environment]::SetEnvironmentVariable($name,(Join-Path $Context.DataRoot 'temp'),'Process')}
            try{$created=Start-Process -FilePath $Context.NodePath -ArgumentList @(('"'+$server+'"'),('"'+$configuration+'"')) -WorkingDirectory $Context.ApplicationRoot -WindowStyle Hidden -RedirectStandardOutput (Join-Path $directory 'server.stdout.txt') -RedirectStandardError (Join-Path $directory 'server.stderr.txt') -PassThru}
            finally{foreach($name in $environment.Keys){[Environment]::SetEnvironmentVariable($name,$environment[$name],'Process')}}
            $record=[pscustomobject]@{pid=$created.Id;configuration=$configuration;startedUtc=[DateTimeOffset]::UtcNow.ToString('o')}
            try{[IO.File]::WriteAllText($currentFile,($record|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))}
            catch{$created.Refresh();if(-not $created.HasExited){$created.Kill()};throw 'VIDNAP_DESKTOP_STORAGE: Startup ownership could not be saved. The new unready process was stopped.'}
            Write-VidNapDesktopEvent $Context 'VIDNAP_DESKTOP_STARTED'
        }
        while($true){
            $probe=Get-VidNapDesktopProbe $Context $record
            if($probe.State -eq 'Healthy'){
                [IO.File]::WriteAllText($currentFile,($probe.Record|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
                Write-VidNapDesktopEvent $Context 'VIDNAP_DESKTOP_READY'
                return $probe.Record
            }
            if($probe.State -eq 'Missing'){throw 'VIDNAP_DESKTOP_START_FAILED: The local worker exited before it was ready. Check the D: startup logs.'}
            if($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds){throw 'VIDNAP_DESKTOP_NOT_READY: The existing worker is still starting or needs review. No duplicate worker was started. Check the D: startup logs.'}
            [Threading.Thread]::Sleep(150)
        }
    }catch{
        $code=[regex]::Match($_.Exception.Message,'VIDNAP_[A-Z0-9_]+').Value
        try{if($code){Write-VidNapDesktopEvent $Context $code}}catch{}
        throw
    }finally{if($lock){$lock.Dispose()};if($created){$created.Dispose()}}
}
