[CmdletBinding()]
param([ValidateSet('Storage','Analysis','Verification','Jobs','JobStore','Captions','Transcription','Update','Process','Backend','ReviewRegression','All')][string]$Suite='All',[switch]$IncludeEngine,[string]$EngineDirectory='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
if([IO.Path]::GetPathRoot($root) -ine 'D:\'){throw 'Backend tests must run on D:.'}
if($root -match '(?i)(^|[\\/])OneDrive(?: - [^\\/]+)?([\\/]|$)'){throw 'Backend tests cannot run in OneDrive.'}
$suites=if($Suite -eq 'All'){@('Storage','Analysis','Verification','Jobs','JobStore','Captions','Transcription','Update','Process','Backend','ReviewRegression')}else{@($Suite)}
foreach($name in $suites){
    $file=Join-Path $PSScriptRoot ('Backend.'+$name+'.Tests.ps1')
    if(-not [IO.File]::Exists($file)){throw "Backend suite unavailable: $name"}
    try { & $file } catch {
        Write-Output $_.ScriptStackTrace
        throw
    }
}
if($Suite -eq 'All'){
    & (Join-Path $PSScriptRoot 'Core.Tests.ps1')
    & (Join-Path $PSScriptRoot 'Progress.Tests.ps1')
}
if($IncludeEngine){
    if(-not $EngineDirectory){throw 'An explicit existing engine directory is required.'}
    & (Join-Path $PSScriptRoot 'Backend.EngineIntegration.Tests.ps1') -EngineDirectory $EngineDirectory
    $manifest=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $EngineDirectory 'install-manifest.json')))
    & (Join-Path $PSScriptRoot 'Backend.SelectorIntegration.Tests.ps1') -ToolPath (Join-Path $EngineDirectory 'yt-dlp.exe') -ToolSha256 $manifest.ytDlpSha256
}
Write-Output ('PASS: backend suites '+($suites -join ', ')+'. No UI, launcher, external website, browser sign-in, installation or installed-copy mutation. Full application acceptance is separate.')
