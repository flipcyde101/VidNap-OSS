[CmdletBinding()]
param([string]$Configuration='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$env:PSModulePath=[IO.Path]::Combine($env:WINDIR,'System32\WindowsPowerShell\v1.0\Modules')
try {
    if([string]::IsNullOrWhiteSpace($Configuration)){$Configuration=[IO.Path]::Combine($PSScriptRoot,'desktop-launch.json')}
    foreach($name in @('Core','Storage','Analysis','Desktop')){. (Join-Path $PSScriptRoot ('VidNap.'+$name+'.ps1'))}
    $context=Read-VidNapDesktopConfiguration $Configuration
    $address=Get-OrStartVidNapDesktop $context
    $open=[Diagnostics.ProcessStartInfo]::new();$open.FileName=$address.url;$open.UseShellExecute=$true
    [Diagnostics.Process]::Start($open)|Out-Null
}catch{
    $code=[regex]::Match($_.Exception.Message,'VIDNAP_[A-Z0-9_]+').Value
    if(-not $code){$code='VIDNAP_DESKTOP_START_FAILED'}
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.MessageBox]::Show("VidNap could not open ($code).`n`nCheck that D: is available. Your files were preserved. Startup logs and settings remain in the configured private D: folder. No Windows security setting was changed.",'VidNap',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error)|Out-Null
    exit 1
}
