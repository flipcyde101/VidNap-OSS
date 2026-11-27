[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version = '0.3.2',
    [string]$Commit = 'HEAD',
    [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
# -SkipBuild remains accepted for older callers. Packaging never builds a launcher.
$dirty = @(git -C $PSScriptRoot status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Review and commit the source and launcher before running Build-Release.ps1. Release manifests require a clean source commit.' }
$resolvedCommit = @(git -C $PSScriptRoot rev-parse --verify --quiet --end-of-options "$Commit^{commit}")
if ($LASTEXITCODE -ne 0 -or $resolvedCommit.Count -ne 1 -or $resolvedCommit[0] -notmatch '^[a-f0-9]{40,64}$') { throw 'Cannot resolve the exact source commit.' }
$sourceCommit = $resolvedCommit[0]
$runtime = @('VidNapLauncher.exe','VidNap.ps1','VidNap.Core.ps1','VidNap.ProcessRunner.cs','VidNap.Alternate.ps1','Test-Connection.ps1','Setup-VidNap.ps1','Start-VidNap.cmd','LICENSE','README.md','SECURITY.md','docs/FALLBACK-DESIGN.md','docs/RELEASE-0.3.2.md')
$out = Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$stage = Join-Path $out ('stage-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
try {
    # Capture the resolved object, never a moving ref or the current working files.
    $snapshotZip = Join-Path $stage 'snapshot.zip'
    git -C $PSScriptRoot archive --format=zip "--output=$snapshotZip" $sourceCommit
    if ($LASTEXITCODE -ne 0) { throw 'git archive failed; no release was packaged.' }
    $snapshot = Join-Path $stage 'snapshot'
    $archive = [IO.Compression.ZipFile]::OpenRead($snapshotZip)
    try {
        $source = @($archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') } | ForEach-Object {
            $name = $_.FullName
            if ($name.Contains('\') -or $name.StartsWith('/') -or $name.Contains(':') -or @($name.Split('/') | Where-Object { $_ -in @('..','.') }).Count) { throw "Unsafe git archive entry: $name" }
            $name
        } | Sort-Object -Unique)
    } finally { $archive.Dispose() }
    [IO.Compression.ZipFile]::ExtractToDirectory($snapshotZip, $snapshot)
    $exe = Join-Path $snapshot 'VidNapLauncher.exe'
    if ((Get-Item -LiteralPath $exe).VersionInfo.FileVersion -ne "$Version.0") { throw 'Launcher version does not match release' }
    $artifacts = @()
    foreach ($kind in @('windows','source')) {
        $files = if ($kind -eq 'windows') { $runtime } else { $source }
        $manifest = @(foreach ($relative in $files) {
            if ($source -notcontains $relative) { throw "Missing release file in source commit: $relative" }
            [pscustomobject]@{ path = $relative; sha256 = (Get-FileHash -LiteralPath (Join-Path $snapshot $relative) -Algorithm SHA256).Hash }
        })
        $manifestPath = Join-Path $stage "$kind-manifest.json"
        @{ version = $Version; sourceCommit = $sourceCommit; files = $manifest } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        $zipPath = Join-Path $out "VidNap-v$Version-$kind.zip"
        $stream = [IO.File]::Open($zipPath, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $prefix = "VidNap-v$Version-$kind/"
            foreach ($relative in $files) {
                [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $snapshot $relative), ($prefix + $relative), [IO.Compression.CompressionLevel]::Optimal) | Out-Null
            }
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $manifestPath, ($prefix + 'MANIFEST.json'), [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        } finally { $zip.Dispose(); $stream.Dispose() }
        $artifacts += $zipPath
    }
    $checks = @($artifacts | ForEach-Object { '{0}  {1}' -f (Get-FileHash -LiteralPath $_).Hash, [IO.Path]::GetFileName($_) })
    $checks | Set-Content -LiteralPath (Join-Path $out 'SHA256SUMS.txt') -Encoding ASCII
    $checks
} finally {
    $resolved = [IO.Path]::GetFullPath($stage)
    if (-not $resolved.StartsWith(([IO.Path]::GetFullPath($out).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup refused' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
