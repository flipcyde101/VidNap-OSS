[CmdletBinding()]
param(
    [ValidateSet('nightly','stable')][string]$Channel = 'nightly',
    [string]$ToolsDirectory = (Join-Path $env:LOCALAPPDATA 'VidNap\tools'),
    [switch]$LibraryOnly
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VidNap.Core.ps1')
function Save-Download([string]$Uri, [string]$Destination) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination -TimeoutSec 600
}
function Get-ExpectedHash([string]$Text, [string]$FileName) {
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line.Trim() -match '^([a-fA-F0-9]{64})\s+\*?(.+)$' -and $Matches[2].Trim() -eq $FileName) { return $Matches[1].ToUpperInvariant() }
        if ($line.Trim() -match '^[a-fA-F0-9]{64}$') { return $line.Trim().ToUpperInvariant() }
    }
    throw "No valid SHA256 checksum found for $FileName. Nothing has been installed."
}
function Assert-FileHash([string]$Path, [string]$Expected) {
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Expected) { throw "Checksum mismatch for $([IO.Path]::GetFileName($Path)). Nothing has been installed; retry setup." }
}
function Assert-PortableExecutable([string]$Path, [long]$MinimumSize = 1MB) {
    $stream = [IO.File]::OpenRead($Path); $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($stream.Length -lt $MinimumSize -or $reader.ReadUInt16() -ne 0x5A4D) { throw "Invalid or truncated Windows executable: $Path" }
        $stream.Position = 0x3C; $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt ($stream.Length - 4)) { throw "Invalid PE header: $Path" }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550) { throw "Invalid PE signature: $Path" }
    } finally { $reader.Dispose(); $stream.Dispose() }
}
function Remove-SetupDirectory([string]$Path, [string]$Parent) {
    $full = [IO.Path]::GetFullPath($Path); $root = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^\.vidnap-(stage|backup)-[a-f0-9]{32}$') { throw "Unsafe cleanup path refused: $full" }
    if (Test-Path -LiteralPath $full) {
        Assert-SetupTree $full
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
function Assert-SetupTree([string]$Path) {
    # Do not traverse junctions/symlinks while validating, moving or cleaning.
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Setup refuses a reparse point.' }
    if ($item.PSIsContainer) {
        foreach ($child in Get-ChildItem -LiteralPath $Path -Force) { Assert-SetupTree $child.FullName }
    }
}
function Restore-InterruptedSetup([string]$Destination) {
    $parent = Split-Path -Parent $Destination
    $backups = @(Get-ChildItem -LiteralPath $parent -Force | Where-Object { $_.Name -like '.vidnap-backup-*' })
    if (Test-Path -LiteralPath $Destination) {
        if ($backups.Count) { Write-Warning 'Existing tools and retained backups left in place; no recovery performed.' }
        return
    }
    if (-not $backups.Count) { return }
    if ($backups.Count -ne 1) {
        Write-Warning ("Multiple backups retained untouched; continuing a fresh install. Paths: " + (($backups | ForEach-Object { $_.FullName }) -join '; '))
        return
    }
    $backup = $backups[0]
    try {
        if (-not $backup.PSIsContainer -or $backup.Name -notmatch '^\.vidnap-backup-[a-f0-9]{32}$') { throw 'Unexpected backup name/type.' }
        Assert-SetupTree $backup.FullName
        $manifest = Get-Content -LiteralPath (Join-Path $backup.FullName 'install-manifest.json') -Raw | ConvertFrom-Json
        $hashes = @{'yt-dlp.exe'=$manifest.ytDlpSha256; 'ffmpeg\ffmpeg.exe'=$manifest.ffmpegBinarySha256.'ffmpeg.exe'; 'ffmpeg\ffprobe.exe'=$manifest.ffmpegBinarySha256.'ffprobe.exe'}
        if ($manifest.PSObject.Properties.Name -contains 'denoSha256') { $hashes['deno.exe']=$manifest.denoSha256 }
        foreach ($relative in $hashes.Keys) {
            if ($hashes[$relative] -notmatch '^[a-fA-F0-9]{64}$') { throw 'Missing or invalid manifest hash.' }
            Assert-FileHash (Join-Path $backup.FullName $relative) $hashes[$relative]
        }
        foreach ($file in Get-ChildItem -LiteralPath $backup.FullName -Recurse -File -Force) {
            $relative = $file.FullName.Substring($backup.FullName.Length + 1)
            if ($relative -ne 'install-manifest.json' -and -not $hashes.ContainsKey($relative)) { throw 'Backup contains an unmanifested file.' }
        }
    } catch {
        Write-Warning "Invalid backup retained untouched at $($backup.FullName); continuing a fresh install. $($_.Exception.Message)"
        return
    }
    Move-Item -LiteralPath $backup.FullName -Destination $Destination -ErrorAction Stop
    Write-Output 'Recovered previous tools from the single hash-verified backup.'
}
function Install-StagedTools([string]$Staged, [string]$Destination, [string]$Backup) {
    $Destination = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
    $Staged = [IO.Path]::GetFullPath($Staged).TrimEnd('\')
    $Backup = [IO.Path]::GetFullPath($Backup).TrimEnd('\')
    $parentPath = [IO.Path]::GetDirectoryName($Destination).TrimEnd('\') + '\'
    if ([IO.Path]::GetFileName($Destination) -ne 'tools' -or -not $Staged.StartsWith($parentPath, [StringComparison]::OrdinalIgnoreCase) -or -not $Backup.StartsWith($parentPath, [StringComparison]::OrdinalIgnoreCase) -or $Staged -eq $Destination -or $Backup -eq $Destination -or $Backup -eq $Staged) { throw 'Unsafe installation paths refused.' }
    if (Test-Path -LiteralPath $Backup) { throw "Backup path already exists; refusing to overwrite: $Backup" }
    $hadExisting = Test-Path -LiteralPath $Destination
    if ($hadExisting) { Move-Item -LiteralPath $Destination -Destination $Backup -ErrorAction Stop }
    try { Move-Item -LiteralPath $Staged -Destination $Destination -ErrorAction Stop }
    catch {
        $failure = $_.Exception.Message
        if ($hadExisting) {
            try { Move-Item -LiteralPath $Backup -Destination $Destination -ErrorAction Stop }
            catch { throw "Install failed ($failure). Rollback failed: $($_.Exception.Message). Old tools are preserved at $Backup. Close VidNap and restore that folder to $Destination." }
        }
        throw "Install failed: $failure. Previous tools were preserved/restored. Close applications using these tools and retry."
    }
}
function Invoke-VidNapSetup([string]$Destination, [string]$ReleaseChannel) {
    $destinationPath = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
    if ([IO.Path]::GetFileName($destinationPath) -ne 'tools') { throw 'ToolsDirectory must name a dedicated tools folder.' }
    foreach ($cloudRoot in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial)) {
        if ($cloudRoot -and ($destinationPath + '\').StartsWith(([IO.Path]::GetFullPath($cloudRoot).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Install tools outside OneDrive; use the default LocalAppData location.' }
    }
    $parent = Split-Path -Parent $destinationPath
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $lock = $null; $stage = Join-Path $parent ('.vidnap-stage-' + [guid]::NewGuid().ToString('N')); $backup = Join-Path $parent ('.vidnap-backup-' + [guid]::NewGuid().ToString('N'))
    try {
        try { $lock = [IO.File]::Open((Join-Path $parent '.vidnap-setup.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch { throw 'Another setup is running, or the tools folder is not writable. Close the other setup and retry.' }
        $decisionPath = Join-Path $parent '.vidnap-setup-decision'
        # GUI cannot claim until this run emits READY below. Clear only while
        # holding the setup lock, before recovery or any cancellable work.
        if (Test-Path -LiteralPath $decisionPath) { Remove-Item -LiteralPath $decisionPath -Force }
        Restore-InterruptedSetup $destinationPath
        foreach ($stale in Get-ChildItem -LiteralPath $parent -Directory -Force -Filter '.vidnap-stage-*') {
            Remove-SetupDirectory $stale.FullName $parent
        }
        New-Item -ItemType Directory -Path $stage | Out-Null
        Write-Output 'VIDNAP_SETUP_READY'
        $payload = Join-Path $stage 'tools'; New-Item -ItemType Directory -Path (Join-Path $payload 'ffmpeg') -Force | Out-Null
        $repo = if ($ReleaseChannel -eq 'nightly') { 'yt-dlp-nightly-builds' } else { 'yt-dlp' }
        $releasePath = Join-Path $stage 'yt-dlp-release.json'
        Save-Download "https://api.github.com/repos/yt-dlp/$repo/releases/latest" $releasePath
        $release = Get-Content -LiteralPath $releasePath -Raw | ConvertFrom-Json
        $tag = [string]$release.tag_name
        if ($tag -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$') { throw 'Invalid yt-dlp release tag.' }
        $base = "https://github.com/yt-dlp/$repo/releases/download/$tag"
        Write-Output '[1/6] Fetching official yt-dlp checksums...'
        $sums = Join-Path $stage 'SHA2-256SUMS'; Save-Download "$base/SHA2-256SUMS" $sums
        $expected = Get-ExpectedHash (Get-Content -LiteralPath $sums -Raw) 'yt-dlp.exe'
        Write-Output "[2/6] Downloading yt-dlp $ReleaseChannel..."
        $yt = Join-Path $payload 'yt-dlp.exe'; Save-Download "$base/yt-dlp.exe" $yt
        Assert-FileHash $yt $expected; Assert-PortableExecutable $yt
        Write-Output '[3/6] Fetching official FFmpeg checksum and archive...'
        $ffbase = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
        $ffsum = Join-Path $stage 'ffmpeg.sha256'; Save-Download "$ffbase.sha256" $ffsum
        $ffhash = Get-ExpectedHash (Get-Content -LiteralPath $ffsum -Raw) 'ffmpeg-release-essentials.zip'
        $reuse = $false
        try {
            $prior = Get-Content -LiteralPath (Join-Path $destinationPath 'install-manifest.json') -Raw | ConvertFrom-Json
            if ($prior.ffmpegArchiveSha256 -eq $ffhash) {
                foreach ($name in @('ffmpeg.exe','ffprobe.exe')) {
                    $cached = Join-Path (Join-Path $destinationPath 'ffmpeg') $name
                    $cachedHash = $prior.ffmpegBinarySha256.$name
                    if ($cachedHash -notmatch '^[a-fA-F0-9]{64}$') { throw 'Missing cached binary hash.' }
                    Assert-FileHash $cached $cachedHash; Assert-PortableExecutable $cached
                }
                $reuse = $true
            }
        } catch { $reuse = $false }
        if ($reuse) {
            Write-Output '[4/6] Reusing unchanged FFmpeg (upstream checksum and both local binary hashes verified)...'
            $extracted = Join-Path $destinationPath 'ffmpeg'
        } else {
            $archive = Join-Path $stage 'ffmpeg.zip'; Save-Download $ffbase $archive
            Assert-FileHash $archive $ffhash
            if ((Get-Item -LiteralPath $archive).Length -lt 1MB) { throw 'FFmpeg archive is unexpectedly small.' }
            Write-Output '[4/6] Extracting verified FFmpeg archive...'
            $extracted = Join-Path $stage 'extracted'; Expand-Archive -LiteralPath $archive -DestinationPath $extracted
        }
        $binaryHashes = @{}
        foreach ($name in @('ffmpeg.exe','ffprobe.exe')) {
            $files = @(Get-ChildItem -LiteralPath $extracted -Recurse -Filter $name -File)
            if ($files.Count -ne 1) { throw "Expected exactly one $name in the verified archive." }
            Assert-PortableExecutable $files[0].FullName
            Copy-Item -LiteralPath $files[0].FullName -Destination (Join-Path (Join-Path $payload 'ffmpeg') $name)
            $binaryHashes[$name] = (Get-FileHash -LiteralPath (Join-Path (Join-Path $payload 'ffmpeg') $name) -Algorithm SHA256).Hash
            if ($reuse) { Assert-FileHash (Join-Path (Join-Path $payload 'ffmpeg') $name) $prior.ffmpegBinarySha256.$name }
        }
        Write-Output '[4/6] Fetching and verifying the Deno JavaScript runtime for YouTube...'
        $denoReleasePath = Join-Path $stage 'deno-release.json'
        Save-Download 'https://api.github.com/repos/denoland/deno/releases/latest' $denoReleasePath
        $denoRelease = Get-Content -LiteralPath $denoReleasePath -Raw | ConvertFrom-Json
        $denoTag = [string]$denoRelease.tag_name
        if ($denoTag -notmatch '^v\d+\.\d+\.\d+$' -or [version]$denoTag.Substring(1) -lt [version]'2.3.0') { throw 'Unsupported Deno release metadata.' }
        $denoAssetName = 'deno-x86_64-pc-windows-msvc.zip'
        $denoAssets = @($denoRelease.assets | Where-Object { $_.name -eq $denoAssetName })
        if ($denoAssets.Count -ne 1 -or $denoAssets[0].digest -notmatch '^sha256:([a-fA-F0-9]{64})$') { throw 'Deno release has no unique verified archive digest.' }
        $denoArchiveHash = $Matches[1].ToUpperInvariant()
        $denoUri = "https://github.com/denoland/deno/releases/download/$denoTag/$denoAssetName"
        if ($denoAssets[0].browser_download_url -cne $denoUri) { throw 'Unexpected Deno archive location.' }
        $denoArchive = Join-Path $stage 'deno.zip'
        Save-Download $denoUri $denoArchive
        Assert-FileHash $denoArchive $denoArchiveHash
        $denoExtracted = Join-Path $stage 'deno'
        Expand-Archive -LiteralPath $denoArchive -DestinationPath $denoExtracted
        $denoFiles = @(Get-ChildItem -LiteralPath $denoExtracted -Recurse -Filter 'deno.exe' -File)
        if ($denoFiles.Count -ne 1) { throw 'Expected exactly one deno.exe in the verified archive.' }
        Assert-PortableExecutable $denoFiles[0].FullName
        Copy-Item -LiteralPath $denoFiles[0].FullName -Destination (Join-Path $payload 'deno.exe')
        $denoHash = (Get-FileHash -LiteralPath (Join-Path $payload 'deno.exe') -Algorithm SHA256).Hash
        @{ schemaVersion = 3; channel = $ReleaseChannel; installedUtc = [DateTime]::UtcNow.ToString('o'); ytDlpTag = $tag; ytDlpSha256 = $expected; ffmpegArchiveSha256 = $ffhash; ffmpegBinarySha256 = $binaryHashes; denoVersion = $denoTag; denoArchiveSha256 = $denoArchiveHash; denoSha256 = $denoHash } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $payload 'install-manifest.json') -Encoding UTF8
        Write-Output '[5/6] Installing verified tools (previous installation preserved until commit)...'
        if (-not (Try-ClaimSetupDecision $decisionPath 'commit')) { throw 'Setup cancelled before install commit.' }
        Install-StagedTools $payload $destinationPath $backup
        if (Test-Path -LiteralPath $backup) { try { Remove-SetupDirectory $backup $parent } catch { Write-Warning "Tools installed; old backup retained at $backup. $($_.Exception.Message)" } }
        Write-Output "[6/6] Setup complete: $destinationPath"
    } finally {
        if (Test-Path -LiteralPath $stage) { try { Remove-SetupDirectory $stage $parent } catch { Write-Warning "Temporary setup files remain at $stage" } }
        if ($lock) { $lock.Dispose() }
    }
}
if (-not $LibraryOnly) {
    try { Invoke-VidNapSetup $ToolsDirectory $Channel }
    catch { [Console]::Error.WriteLine("Setup failed: " + $_.Exception.Message); exit 1 }
}
