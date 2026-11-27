$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Setup-VidNap.ps1') -LibraryOnly
$script:checks = 0
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:checks++ }
function Assert-Throws([scriptblock]$Action, [string]$Message) { $thrown = $false; try { & $Action } catch { $thrown = $true }; Assert $thrown $Message }
function Get-BackupSnapshot([string]$Path) {
    @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $hash=if ($_.PSIsContainer) { 'directory' } else { (Get-FileHash -LiteralPath $_.FullName).Hash }
        # Directory timestamps can settle after Copy-Item returns on Windows.
        # Compare directory membership plus every file's bytes and write time.
        $writeTime=if ($_.PSIsContainer) { '' } else { $_.LastWriteTimeUtc.Ticks }
        '{0}|{1}|{2}' -f $_.FullName, $hash, $writeTime
    }) -join "`n"
}
$root = Join-Path $env:TEMP ('VidNapSetupTests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $hash = 'A' * 64
    Assert ((Get-ExpectedHash "$hash  yt-dlp.exe" 'yt-dlp.exe') -eq $hash) 'named SHA256 parsing'
    Assert ((Get-ExpectedHash $hash 'ffmpeg.zip') -eq $hash) 'bare SHA256 parsing'
    Assert-Throws { Get-ExpectedHash "$hash  other.exe" 'yt-dlp.exe' } 'wrong file must fail'
    Assert-Throws { Get-ExpectedHash 'not a checksum' 'yt-dlp.exe' } 'invalid checksum must fail'
    $fixture = Join-Path $root 'fixture.exe'
    $bytes = New-Object byte[] 1048576; $bytes[0] = 0x4d; $bytes[1] = 0x5a; $bytes[60] = 128; $bytes[128] = 0x50; $bytes[129] = 0x45
    [IO.File]::WriteAllBytes($fixture, $bytes)
    Assert-PortableExecutable $fixture; $script:checks++
    $actual = (Get-FileHash -LiteralPath $fixture).Hash
    Assert-FileHash $fixture $actual; $script:checks++
    Assert-Throws { Assert-FileHash $fixture $hash } 'hash mismatch must fail'
    $bytes[128] = 0; [IO.File]::WriteAllBytes($fixture, $bytes)
    Assert-Throws { Assert-PortableExecutable $fixture } 'bad PE signature must fail'
    Assert-Throws { Remove-SetupDirectory $root $root } 'cleanup root must be refused'
    $decision = Join-Path $root '.vidnap-setup-decision'
    foreach ($order in @(@('cancel','commit'),@('commit','cancel'))) {
        Assert (Try-ClaimSetupDecision $decision $order[0]) "$($order[0]) wins first CreateNew"
        Assert (-not (Try-ClaimSetupDecision $decision $order[1])) "$($order[1]) loses second CreateNew"
        Assert (([IO.File]::ReadAllText($decision)) -eq $order[0]) 'loser cannot overwrite winner'
        Remove-Item -LiteralPath $decision
    }
    $destination = Join-Path $root 'tools'; $stage = Join-Path $root 'staged'; $backup = Join-Path $root 'backup'
    New-Item -ItemType Directory -Path $destination, $stage | Out-Null
    [IO.File]::WriteAllText((Join-Path $destination 'old.txt'), 'old')
    [IO.File]::WriteAllText((Join-Path $stage 'new.txt'), 'new')
    Install-StagedTools $stage $destination $backup
    Assert (Test-Path (Join-Path $destination 'new.txt')) 'commit should install new payload'
    Assert (Test-Path (Join-Path $backup 'old.txt')) 'commit should preserve old payload'
    $backup2 = Join-Path $root 'backup2'
    Assert-Throws { Install-StagedTools (Join-Path $root 'missing-stage') $destination $backup2 } 'missing staged payload must fail'
    Assert (Test-Path (Join-Path $destination 'new.txt')) 'failed commit must restore old payload'
    Assert (-not (Test-Path $backup2)) 'successful rollback should consume backup'
    function Save-Download { throw 'MOCK: network unavailable' }
    Assert-Throws { Invoke-VidNapSetup $destination 'nightly' } 'network failure should fail setup'
    Assert (Test-Path (Join-Path $destination 'new.txt')) 'network failure must preserve existing tools'
    Assert (@(Get-ChildItem -LiteralPath $root -Directory -Filter '.vidnap-stage-*').Count -eq 0) 'failed setup must clean stage'
    $bytes[128] = 0x50; [IO.File]::WriteAllBytes($fixture, $bytes)
    $script:fixturePath = $fixture; $script:fixtureHash = (Get-FileHash $fixture).Hash; $script:mockUris = @(); $script:corruptDownload = $false
    function Save-Download([string]$Uri, [string]$Destination) {
        $script:mockUris += $Uri
        if ($Uri -like 'https://api.github.com/repos/yt-dlp/*/releases/latest') {
            $script:ytApiCalls++
            @{tag_name=$script:latestTag} | ConvertTo-Json | Set-Content -LiteralPath $Destination
        }
        elseif ($Uri -eq 'https://api.github.com/repos/denoland/deno/releases/latest') {
            $digest = if ($script:badDenoDigest) { 'sha256:invalid' } else { 'sha256:' + $script:fixtureHash }
            $denoUrl = if ($script:badDenoUrl) { 'https://example.test/deno.zip' } else { 'https://github.com/denoland/deno/releases/download/v2.9.8/deno-x86_64-pc-windows-msvc.zip' }
            @{tag_name='v2.9.8'; assets=@(@{name='deno-x86_64-pc-windows-msvc.zip';digest=$digest;browser_download_url=$denoUrl})} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Destination
        }
        elseif ($Uri.EndsWith('SHA2-256SUMS')) {
            [IO.File]::WriteAllText($Destination, "$script:fixtureHash  yt-dlp.exe")
            $script:latestTag='2099.12.31' # latest moves after checksum fetch
            if ($script:cancelDuringDownload) { $null = Try-ClaimSetupDecision $script:decisionForRun 'cancel' }
        }
        elseif ($Uri.EndsWith('.sha256')) { [IO.File]::WriteAllText($Destination, $script:fixtureHash) }
        else {
            Copy-Item -LiteralPath $script:fixturePath -Destination $Destination
            if ($script:corruptDownload) { [IO.File]::AppendAllText($Destination, 'corrupt') }
        }
    }
    function Expand-Archive([string]$LiteralPath, [string]$DestinationPath) {
        New-Item -ItemType Directory -Path $DestinationPath | Out-Null
        if ([IO.Path]::GetFileName($LiteralPath) -eq 'deno.zip') {
            Copy-Item -LiteralPath $script:fixturePath -Destination (Join-Path $DestinationPath 'deno.exe')
            return
        }
        Copy-Item -LiteralPath $script:fixturePath -Destination (Join-Path $DestinationPath 'ffmpeg.exe')
        Copy-Item -LiteralPath $script:fixturePath -Destination (Join-Path $DestinationPath 'ffprobe.exe')
    }
    $script:badDenoDigest=$false; $script:badDenoUrl=$false
    $script:ytApiCalls=0; $script:latestTag='2026.10.23'; $script:cancelDuringDownload=$false
    $script:decisionForRun=$decision
    Invoke-VidNapSetup $destination 'stable'
    Assert (Test-Path (Join-Path $destination 'ffmpeg\ffprobe.exe')) 'mock setup installs full payload'
    $manifest = Get-Content (Join-Path $destination 'install-manifest.json') -Raw | ConvertFrom-Json
    Assert ($manifest.channel -eq 'stable' -and $manifest.ytDlpSha256 -eq $script:fixtureHash) 'manifest records channel and verified hash'
    Assert ($script:mockUris -contains 'https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.23/SHA2-256SUMS') 'stable checksums use resolved tag'
    Assert ($script:mockUris -contains 'https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.23/yt-dlp.exe') 'binary uses same tag even after latest changes'
    Assert ($script:ytApiCalls -eq 1 -and $manifest.ytDlpTag -eq '2026.10.23') 'resolve latest only once and record exact tag'
    Assert (([IO.File]::ReadAllText($decision)) -eq 'commit') 'successful setup claims commit'
    Assert ($manifest.ffmpegBinarySha256.'ffmpeg.exe' -eq $script:fixtureHash -and $manifest.ffmpegBinarySha256.'ffprobe.exe' -eq $script:fixtureHash) 'manifest records both binary hashes'
    Assert ($manifest.denoSha256 -eq $script:fixtureHash -and $manifest.denoVersion -eq 'v2.9.8') 'manifest records verified Deno runtime'
    Assert (Test-Path -LiteralPath (Join-Path $destination 'deno.exe')) 'setup installs Deno alongside yt-dlp'
    $script:mockUris = @()
    Invoke-VidNapSetup $destination 'stable'
    Assert ($script:mockUris -notcontains 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip') 'valid unchanged FFmpeg avoids archive download'
    [IO.File]::AppendAllText((Join-Path $destination 'ffmpeg\ffprobe.exe'), 'corrupt')
    $script:mockUris = @()
    Invoke-VidNapSetup $destination 'stable'
    Assert ($script:mockUris -contains 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip') 'corrupt FFprobe invalidates cache'
    Assert-FileHash (Join-Path $destination 'ffmpeg\ffprobe.exe') $script:fixtureHash; $script:checks++
    $script:corruptDownload = $true
    Assert-Throws { Invoke-VidNapSetup $destination 'nightly' } 'corrupt staged download must fail'
    Assert-FileHash (Join-Path $destination 'yt-dlp.exe') $script:fixtureHash; $script:checks++
    Assert ($script:mockUris -contains 'https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/download/2099.12.31/SHA2-256SUMS') 'nightly uses official nightly repository and tag'
    $script:corruptDownload=$false; $script:badDenoDigest=$true
    Assert-Throws { Invoke-VidNapSetup $destination 'stable' } 'missing Deno digest fails closed'
    Assert-FileHash (Join-Path $destination 'yt-dlp.exe') $script:fixtureHash; $script:checks++
    $script:badDenoDigest=$false; $script:badDenoUrl=$true
    Assert-Throws { Invoke-VidNapSetup $destination 'stable' } 'unexpected Deno download host fails closed'
    Assert-FileHash (Join-Path $destination 'deno.exe') $script:fixtureHash; $script:checks++
    $script:badDenoUrl=$false; $script:cancelDuringDownload=$true
    $before = (Get-FileHash -LiteralPath (Join-Path $destination 'install-manifest.json')).Hash
    Assert-Throws { Invoke-VidNapSetup $destination 'stable' } 'cancel winner prevents install commit'
    Assert ((Get-FileHash -LiteralPath (Join-Path $destination 'install-manifest.json')).Hash -eq $before) 'cancel leaves installed manifest unchanged'
    Assert (([IO.File]::ReadAllText($decision)) -eq 'cancel') 'cancel winner is not overwritten by commit'
    $script:cancelDuringDownload=$false
    Invoke-VidNapSetup $destination 'stable' | Out-Null
    Assert (([IO.File]::ReadAllText($decision)) -eq 'commit') 'new run clears prior cancel before accepting decisions'

    # Recovery fixtures represent interrupted filesystem transitions, not live installs.
    $recoveryRoot = Join-Path $root 'recovery'; New-Item -ItemType Directory -Path $recoveryRoot | Out-Null
    $recoveryTools = Join-Path $recoveryRoot 'tools'
    $recoveryBackup = Join-Path $recoveryRoot ('.vidnap-backup-' + ('a'*32))
    Copy-Item -LiteralPath $destination -Destination $recoveryBackup -Recurse
    Restore-InterruptedSetup $recoveryTools | Out-Null
    Assert ((Test-Path -LiteralPath $recoveryTools) -and -not (Test-Path -LiteralPath $recoveryBackup)) 'single verified backup restores missing tools'
    Copy-Item -LiteralPath $recoveryTools -Destination $recoveryBackup -Recurse
    Restore-InterruptedSetup $recoveryTools -WarningAction SilentlyContinue
    Assert (Test-Path -LiteralPath $recoveryBackup) 'existing tools leave backup untouched'
    Remove-Item -LiteralPath $recoveryTools -Recurse -Force
    $backupOther = Join-Path $recoveryRoot ('.vidnap-backup-' + ('b'*32))
    Copy-Item -LiteralPath $recoveryBackup -Destination $backupOther -Recurse
    $ambiguousBefore=@((Get-BackupSnapshot $recoveryBackup),(Get-BackupSnapshot $backupOther))
    # Enumerated full paths may differ from TEMP's short/relative spelling.
    $backupPaths=@(Get-ChildItem -LiteralPath $recoveryRoot -Force -Filter '.vidnap-backup-*' | Sort-Object Name | ForEach-Object { $_.FullName })
    $warnings=@(Restore-InterruptedSetup $recoveryTools 3>&1)
    Assert (($warnings -join ' ').Contains($backupPaths[0]) -and ($warnings -join ' ').Contains($backupPaths[1])) 'ambiguous warning lists every retained backup path'
    Assert ((Test-Path -LiteralPath $recoveryBackup) -and (Test-Path -LiteralPath $backupOther) -and -not (Test-Path -LiteralPath $recoveryTools)) 'ambiguous recovery changes nothing'
    Invoke-VidNapSetup $recoveryTools 'stable' | Out-Null
    Assert (Test-Path -LiteralPath (Join-Path $recoveryTools 'install-manifest.json')) 'fresh install completes despite multiple backups'
    Assert ((Get-BackupSnapshot $recoveryBackup) -ceq $ambiguousBefore[0]) 'first ambiguous backup remains unchanged after fresh install'
    Assert ((Get-BackupSnapshot $backupOther) -ceq $ambiguousBefore[1]) 'second ambiguous backup remains unchanged after fresh install'
    Remove-Item -LiteralPath $recoveryTools -Recurse -Force
    Remove-SetupDirectory $backupOther $recoveryRoot
    [IO.File]::AppendAllText((Join-Path $recoveryBackup 'deno.exe'), 'corrupt')
    $warnings=@(Restore-InterruptedSetup $recoveryTools 3>&1)
    Assert (($warnings -join ' ').Contains($backupPaths[0])) 'invalid hash warning includes retained backup path'
    Assert (Test-Path -LiteralPath $recoveryBackup) 'bad backup retained for inspection'
    Copy-Item -LiteralPath (Join-Path $destination 'deno.exe') -Destination (Join-Path $recoveryBackup 'deno.exe') -Force
    [IO.File]::WriteAllText((Join-Path $recoveryBackup 'extra.exe'), 'unmanifested')
    $warnings=@(Restore-InterruptedSetup $recoveryTools 3>&1)
    Assert (($warnings -join ' ').Contains($backupPaths[0])) 'unmanifested file warning includes retained backup path'
    $stale = Join-Path $recoveryRoot ('.vidnap-stage-' + ('c'*32))
    New-Item -ItemType Directory -Path $stale | Out-Null
    $invalidBefore=Get-BackupSnapshot $recoveryBackup
    Invoke-VidNapSetup $recoveryTools 'stable' | Out-Null
    Assert (Test-Path -LiteralPath (Join-Path $recoveryTools 'install-manifest.json')) 'fresh install completes despite invalid backup'
    Assert ((Test-Path -LiteralPath $recoveryBackup) -and (Get-BackupSnapshot $recoveryBackup) -ceq $invalidBefore) 'invalid backup remains unchanged after fresh install'
    Assert (-not (Test-Path -LiteralPath $stale)) 'fresh install cleans stale stage through guarded cleanup'
    Remove-Item -LiteralPath $recoveryTools -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $recoveryBackup 'extra.exe')
    # Under-lock full entry point restores then cleans stale stage before network failure.
    function Save-Download { throw 'MOCK: network unavailable' }
    Assert-Throws { Invoke-VidNapSetup $recoveryTools 'stable' } 'network fails after guarded recovery'
    Assert ((Test-Path -LiteralPath $recoveryTools) -and -not (Test-Path -LiteralPath $stale)) 'full setup recovers backup and removes stale stage'
    $lockedDecision = Join-Path $recoveryRoot '.vidnap-setup-decision'
    [IO.File]::WriteAllText($lockedDecision, 'commit')
    $heldLock = [IO.File]::Open((Join-Path $recoveryRoot '.vidnap-setup.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        Assert-Throws { Invoke-VidNapSetup $recoveryTools 'stable' } 'second setup cannot bypass lock'
        Assert (([IO.File]::ReadAllText($lockedDecision)) -eq 'commit') 'lock loser does not clear active decision'
    } finally { $heldLock.Dispose() }
    Write-Output "PASS: $script:checks setup checks; no network or helpers executed."
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^VidNapSetupTests-[a-f0-9]{32}$') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
