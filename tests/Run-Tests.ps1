[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($file in Get-ChildItem -LiteralPath $root -Filter '*.ps1' -Recurse | Where-Object { $_.FullName -notmatch '\\(tools|dist|local-verification)\\' }) {
    $tokens=$null; $errors=$null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)|Out-Null
    if($errors.Count){throw "$($file.Name): $($errors[0].Message)"}
}
$source=Get-Content -Raw -LiteralPath (Join-Path $root 'VidNap.ps1')
$xamlMatch=[regex]::Match($source,"(?s)\[xml\]\$" + "xaml = @'\r?\n(.*?)\r?\n'@")
if(-not $xamlMatch.Success){throw 'Missing XAML'}
$xml=[xml]$xamlMatch.Groups[1].Value
$names=@($xml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object { $_.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml') })
if(($names|Select-Object -Unique).Count -ne $names.Count){throw 'Duplicate XAML names'}
if($source -match 'download-request\.json|Stop-Process -Force|Start-Sleep'){throw 'Unexpected startup automation or forced browser closure'}
Write-Output 'PowerShell syntax and XAML structure passed (no UI launch).'
foreach($test in @('Core.Tests.ps1','Setup.Tests.ps1','Process.Tests.ps1','Alternate.Tests.ps1','Layout.Tests.ps1','DownloadFlow.Tests.ps1','Startup.Tests.ps1','Packaging.Tests.ps1')) {
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $test)
    if($LASTEXITCODE -ne 0){throw "$test failed"}
}
Write-Output 'All regression suites passed.'
