[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ToolPath,
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ToolSha256
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
if([IO.Path]::GetPathRoot($root) -ine 'D:\'){throw 'Selector fixtures must stay on D:.'}
. (Join-Path $root 'VidNap.Core.ps1')
. (Join-Path $root 'VidNap.Analysis.ps1')
function Get-SelectorFixtureHash([string]$Path){
    $hash=[Security.Cryptography.SHA256]::Create();$stream=[IO.File]::OpenRead($Path)
    try{return [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-','')}finally{$stream.Dispose();$hash.Dispose()}
}
if(-not [IO.File]::Exists($ToolPath) -or [IO.Path]::GetFileName($ToolPath) -ine 'yt-dlp.exe' -or
    (Get-SelectorFixtureHash $ToolPath) -ine $ToolSha256){throw 'A verified existing yt-dlp executable is required. No download or fallback is attempted.'}
$fixture=Join-Path $root ('local-verification\selector-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture)|Out-Null
$script:checks=0
$script:pendingSelectorPid=0
function Invoke-SelectorFixture([string]$File,[string]$Selector){
    $arguments=@('--ignore-config','--no-plugin-dirs','--no-cache-dir','--no-check-formats','--simulate','--skip-download',
        '--quiet','--no-warnings','--proxy','http://127.0.0.1:9','--load-info-json',$File,'--format',$Selector,'--print','%(format_id)s')
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$ToolPath;$info.WorkingDirectory=$fixture
    $info.Arguments=(@($arguments|ForEach-Object {Quote-Argument $_})) -join ' '
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($name in @('TEMP','TMP','XDG_CACHE_HOME','DENO_DIR')){$info.EnvironmentVariables[$name]=$fixture}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info;$started=$false
    try{
        if(-not $process.Start()){throw 'The verified engine did not start. No alternate host is attempted.'}
        $started=$true
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(15000)){throw ('Selector fixture still running, PID '+$process.Id+'. Reconcile it before retrying.')}
        $output=$stdout.GetAwaiter().GetResult();$errors=$stderr.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0){throw ('Selector fixture failed, engine exit '+$process.ExitCode+'. '+$errors.Substring(0,[Math]::Min(400,$errors.Length)))}
        return @($output -split '\r?\n'|Where-Object {$_})
    }finally{
        if($started -and -not $process.HasExited){$script:pendingSelectorPid=$process.Id}
        $process.Dispose()
    }
}
try{
    foreach($id in @('all','best','bestaudio','worst','mp4','hls:high')){
        $data=@{_type='video';id='selector-fixture';title='Offline selector fixture';extractor='generic';extractor_key='Generic';webpage_url='https://example.invalid/fixture';formats=@(
            @{format_id=$id;ext='mp4';vcodec='h264';acodec='aac';height=720;url='https://example.invalid/selected.mp4'},
            @{format_id='other';ext='mp4';vcodec='h264';acodec='aac';height=1080;url='https://example.invalid/other.mp4'}
        )}
        $json=$data|ConvertTo-Json -Depth 8
        $file=Join-Path $fixture 'input.json'
        [IO.File]::WriteAllText($file,$json,[Text.UTF8Encoding]::new($false))
        $analysis=ConvertFrom-VidNapAnalysis $json
        $selection=@(Get-VidNapSelectionArguments $analysis @{Media='video';Format='best';HasFfmpeg=$true;FormatIds=@($id)})
        $actual=@(Invoke-SelectorFixture $file $selection[1])
        if($actual.Count -ne 1 -or $actual[0] -cne $id){throw 'Exact-ID selection did not select exactly the requested fixture.'}
        $script:checks++
        if($id -ceq 'all'){
            $control=@(Invoke-SelectorFixture $file 'all')
            if($control.Count -ne 2){throw 'The negative control did not exercise the original selector ambiguity.'}
            $script:checks++
        }
    }
    if((Get-SelectorFixtureHash $ToolPath) -ine $ToolSha256){throw 'Existing engine bytes changed unexpectedly.'}
    Write-Output "PASS: $script:checks offline real-engine selector checks; metadata fixtures, simulate/skip-download, no browser or media download, existing engine unchanged."
}finally{
    $resolved=[IO.Path]::GetFullPath($fixture)
    $parent=[IO.Path]::GetFullPath((Join-Path $root 'local-verification')).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^selector-[a-f0-9]{32}$'){throw 'Unsafe selector fixture cleanup refused.'}
    if($script:pendingSelectorPid -ne 0){
        Write-Output ('Selector fixture retained while PID '+$script:pendingSelectorPid+' needs reconciliation.')
    }elseif([IO.Directory]::Exists($resolved)){
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
