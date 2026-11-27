$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'VidNap.Core.ps1')
$source=Get-Content -Raw -LiteralPath (Join-Path $root 'VidNap.ps1')
$guard=$source.IndexOf("if (`$env:VIDNAP_SMOKE_TEST -eq '1')")
if($guard -lt 0 -or $source.IndexOf('$UrlBox.Focus()') -lt $guard -or $source.IndexOf('$window.ShowDialog()') -lt $guard){throw 'Smoke mode must precede focus and visible-window calls'}
$temp=[IO.Path]::GetFullPath($env:TEMP)
if($temp -match '(?i)(^|[\\/])OneDrive[^\\/]*([\\/]|$)'){throw 'Startup fixture must stay outside OneDrive'}
$ancestor=Get-Item -LiteralPath $temp
while($null -ne $ancestor){
    if($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Startup fixture parent cannot be redirected'}
    $ancestor=$ancestor.Parent
}
$fixture=Join-Path $temp ('VidNapStartupTests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$process=New-Object Diagnostics.Process
try {
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $info.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -File "'+(Join-Path $root 'VidNap.ps1')+'"'
    $info.WorkingDirectory=$root
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $info.EnvironmentVariables['LOCALAPPDATA']=$fixture
    $info.EnvironmentVariables['TEMP']=$fixture
    $info.EnvironmentVariables['TMP']=$fixture
    $info.EnvironmentVariables['VIDNAP_SMOKE_TEST']='1'
    $process.StartInfo=$info
    if(-not $process.Start()){throw 'Startup smoke process did not start'}
    $stdout=$process.StandardOutput.ReadToEndAsync()
    $stderr=$process.StandardError.ReadToEndAsync()
    if(-not $process.WaitForExit(30000)){throw 'Startup smoke exceeded 30 seconds'}
    $output=$stdout.GetAwaiter().GetResult()
    $errors=$stderr.GetAwaiter().GetResult()
    if($process.ExitCode -ne 0 -or $errors -or $output -notmatch 'VidNap WPF initialization OK'){
        $details=Protect-LogText ("stdout: $output`nstderr: $errors")
        if($details.Length -gt 2000){$details=$details.Substring(0,2000)+' [truncated]'}
        throw "Isolated startup smoke failed (exit $($process.ExitCode)). $details"
    }
    if(Test-Path -LiteralPath (Join-Path $fixture 'VidNap\settings.json')){throw 'Smoke startup persisted preferences'}
    Write-Output 'PASS: real WPF startup in isolated LocalAppData, no focus/ShowDialog path, no persisted preferences; not an interactive UI test.'
} finally {
    try {if(-not $process.HasExited){$process.Kill(); $process.WaitForExit(5000)|Out-Null}} catch {}
    $process.Dispose()
    $resolved=[IO.Path]::GetFullPath($fixture)
    if(-not $resolved.StartsWith(($temp.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^VidNapStartupTests-[a-f0-9]{32}$'){throw 'Unsafe startup cleanup refused'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
