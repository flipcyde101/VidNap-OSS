$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$script:BackendChecks=0
function Assert-Backend($Condition,[string]$Label){
    if(-not $Condition){throw ('FAIL: '+$Label)}
    $script:BackendChecks++
}
function Assert-BackendCode([scriptblock]$Action,[string]$Code){
    $message=''
    try{& $Action|Out-Null}catch{$exception=$_.Exception;while($exception.InnerException){$exception=$exception.InnerException};$message=$exception.Message}
    Assert-Backend ($message.StartsWith($Code,[StringComparison]::Ordinal)) ('expected '+$Code)
}
function Get-BackendTestHash([string]$Path){
    $hash=[Security.Cryptography.SHA256]::Create();$stream=[IO.File]::OpenRead($Path)
    try{return [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-','')}finally{$stream.Dispose();$hash.Dispose()}
}
function New-BackendTestDirectory([string]$Root){
    $path=Join-Path $Root ('local-verification\vf-'+[Guid]::NewGuid().ToString('N').Substring(0,12))
    if([IO.Path]::GetPathRoot($path) -ine 'D:\'){throw 'Test fixtures must stay on D:.'}
    [IO.Directory]::CreateDirectory($path)|Out-Null
    return $path
}
function Remove-BackendTestDirectory([string]$Path,[string]$Root){
    $full=[IO.Path]::GetFullPath($Path)
    $parent=[IO.Path]::GetFullPath((Join-Path $Root 'local-verification')).TrimEnd('\')+'\'
    if(-not $full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^vf-(?:[a-f0-9]{12}|[a-f0-9]{32})$'){throw 'Unsafe fixture cleanup refused.'}
    if(-not [IO.Directory]::Exists($full)){return}
    $pending=[Collections.Generic.Stack[string]]::new();$pending.Push($full)
    while($pending.Count){
        foreach($entry in [IO.Directory]::EnumerateFileSystemEntries($pending.Pop())){
            $attributes=[IO.File]::GetAttributes($entry)
            if($attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Redirected fixture retained.'}
            if($attributes -band [IO.FileAttributes]::Directory){$pending.Push($entry)}
        }
    }
    Remove-Item -LiteralPath $full -Recurse -Force
}
