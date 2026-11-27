[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path $PSScriptRoot 'VidNapLauncher.cs'
$outputPath = Join-Path $PSScriptRoot 'VidNapLauncher.exe'

if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw 'VidNapLauncher.cs was not found.'
}

$temporaryPath = Join-Path $PSScriptRoot ('VidNapLauncher.build-' + [guid]::NewGuid().ToString('N') + '.exe')
try {
    Add-Type -Path $sourcePath -ReferencedAssemblies System.Windows.Forms -OutputAssembly $temporaryPath -OutputType WindowsApplication
    if (-not (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) { throw 'Compiler did not produce an executable; previous launcher retained.' }
    if (Test-Path -LiteralPath $outputPath) {
        $backupPath = $temporaryPath + '.previous'
        [IO.File]::Replace($temporaryPath, $outputPath, $backupPath)
        Remove-Item -LiteralPath $backupPath -Force
    }
    else { [IO.File]::Move($temporaryPath, $outputPath) }
} finally { if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force } }
Write-Host "Built $outputPath" -ForegroundColor Green
