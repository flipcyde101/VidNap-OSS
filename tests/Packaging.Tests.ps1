$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$script:checks = 0
function Assert-Packaging([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Assert-PackagingThrows([scriptblock]$Action, [string]$ExpectedMessage) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    Assert-Packaging ($null -ne $caught -and $caught.Exception.Message -like $ExpectedMessage) ('Expected failure: ' + $ExpectedMessage + '; actual: ' + $caught.Exception.Message)
}
$batch = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'Start-VidNap.cmd')
$invoke = [regex]::Match($batch, '(?im)^"%SystemRoot%\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe"[^\r\n]*-File[^\r\n]*\r?$')
$capture = [regex]::Match($batch, '(?im)^set\s+"vidnapExit=%errorlevel%"\s*$')
$pause = [regex]::Match($batch, '(?im)^if\s+not\s+"%vidnapExit%"=="0"\s+pause\s*$')
$exit = [regex]::Match($batch, '(?im)^exit\s+/b\s+%vidnapExit%\s*$')
Assert-Packaging ($invoke.Success -and $capture.Success -and $pause.Success -and $exit.Success) 'Batch fallback captures and returns the PowerShell exit code'
Assert-Packaging ($invoke.Index -lt $capture.Index -and $capture.Index -lt $pause.Index -and $pause.Index -lt $exit.Index) 'Batch preserves failure exit code before pause'

$tempParent = [IO.Path]::GetFullPath($env:TEMP)
Assert-Packaging ($tempParent -notmatch '(?i)(^|[\\/])OneDrive(?:[^\\/]*)?([\\/]|$)') 'Packaging fixtures stay outside OneDrive'
$ancestor = Get-Item -LiteralPath $tempParent -Force
while ($null -ne $ancestor) {
    if (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Packaging fixture parent must not contain a junction or symbolic link' }
    $ancestor = $ancestor.Parent
}
$script:fixtureRoot = Join-Path $tempParent ('VidNapPackagingTests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:fixtureRoot | Out-Null
function Get-PackagingSourceSnapshot {
    @(Get-ChildItem -LiteralPath $script:fixtureRoot -Recurse -Force -File | Where-Object {
        $_.FullName -notlike "$script:fixtureRoot\.git\*" -and $_.FullName -notlike "$script:fixtureRoot\dist\*"
    } | ForEach-Object { '{0}={1}' -f $_.FullName.Substring($script:fixtureRoot.Length + 1), (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } | Sort-Object) -join "`n"
}
function Read-ZipText($Entry) {
    $reader = New-Object IO.StreamReader($Entry.Open())
    try { $reader.ReadToEnd() } finally { $reader.Dispose() }
}
function Test-PackagingArchives([string]$Version, [string]$ExpectedCommit, [string]$ExpectedDocumentationHash) {
    foreach ($kind in @('windows','source')) {
        $zipPath = Join-Path $script:fixtureRoot "dist\VidNap-v$Version-$kind.zip"
        Assert-Packaging (Test-Path -LiteralPath $zipPath -PathType Leaf) "$kind ZIP exists"
        $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $prefix = "VidNap-v$Version-$kind/"
            $entries = @{}
            # Do not normalize names: the actual ZIP must be portable as written.
            foreach ($entry in $archive.Entries) {
                Assert-Packaging (-not $entry.FullName.Contains('\')) 'ZIP entry contains no backslash'
                $entries[$entry.FullName] = $entry
            }
            Assert-Packaging ($entries.ContainsKey($prefix + 'docs/FALLBACK-DESIGN.md')) "$kind ZIP includes linked documentation"
            Assert-Packaging ($entries.ContainsKey($prefix + 'LICENSE')) "$kind ZIP includes the project license"
            Assert-Packaging (-not $entries.ContainsKey($prefix + 'docs/ignored-fixture.md')) "$kind ZIP excludes the real gitignored fixture"
            $manifest = Read-ZipText $entries[$prefix + 'MANIFEST.json'] | ConvertFrom-Json
            Assert-Packaging ($manifest.sourceCommit -eq $ExpectedCommit) "$kind manifest records the exact requested commit"
            Assert-Packaging (@($manifest.files | Where-Object { $_.path -eq 'docs/ignored-fixture.md' }).Count -eq 0) 'Manifest excludes ignored fixture'
            foreach ($file in $manifest.files) {
                Assert-Packaging ($entries.ContainsKey($prefix + $file.path)) 'Every manifested file is in the archive'
                $stream = $entries[$prefix + $file.path].Open()
                $sha = [Security.Cryptography.SHA256]::Create()
                try { $hash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') } finally { $sha.Dispose(); $stream.Dispose() }
                Assert-Packaging ($hash -eq $file.sha256) 'Every manifest hash matches archived bytes'
            }
            $documentation = @($manifest.files | Where-Object { $_.path -eq 'docs/FALLBACK-DESIGN.md' })
            Assert-Packaging ($documentation.Count -eq 1 -and $documentation[0].sha256 -eq $ExpectedDocumentationHash) 'Documentation bytes come from selected commit, not working tree'
            $readme = Read-ZipText $entries[$prefix + 'README.md']
            Assert-Packaging ($readme -match '\]\(docs/FALLBACK-DESIGN\.md\)') 'README capabilities link retained'
            if ($kind -eq 'source') { Assert-Packaging ($entries.ContainsKey($prefix + 'docs/tracked-fixture.txt')) 'Source archive contains tracked files beyond the old extension allowlist' }
        } finally { $archive.Dispose() }
    }
}
try {
    foreach ($directory in @('docs','tests','.github')) { New-Item -ItemType Directory -Path (Join-Path $script:fixtureRoot $directory) | Out-Null }
    $files = @('VidNapLauncher.exe','VidNap.ps1','VidNap.Core.ps1','VidNap.ProcessRunner.cs','VidNap.Alternate.ps1','Test-Connection.ps1','Setup-VidNap.ps1','Start-VidNap.cmd','LICENSE','README.md','SECURITY.md','VidNapLauncher.cs','Build-Release.ps1','CONTRIBUTING.md','.gitattributes','.gitignore','docs/FALLBACK-DESIGN.md','docs/RELEASE-0.3.2.md')
    foreach ($relative in $files) { Copy-Item -LiteralPath (Join-Path $projectRoot $relative) -Destination (Join-Path $script:fixtureRoot $relative) }
    Set-Content -LiteralPath (Join-Path $script:fixtureRoot 'Build-Launcher.ps1') -Value "throw 'Packaging must not invoke Build-Launcher.ps1'" -Encoding UTF8
    Add-Content -LiteralPath (Join-Path $script:fixtureRoot '.gitignore') -Value "`ndocs/ignored-fixture.md"
    Set-Content -LiteralPath (Join-Path $script:fixtureRoot 'docs/ignored-fixture.md') -Value 'Ignored fixture must not ship'
    Set-Content -LiteralPath (Join-Path $script:fixtureRoot 'docs/tracked-fixture.txt') -Value 'Tracked fixture must ship in source'
    git -C $script:fixtureRoot init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Fixture git init failed' }
    git -C $script:fixtureRoot -c core.autocrlf=false add --all
    if ($LASTEXITCODE -ne 0) { throw 'Fixture git add failed' }
    git -C $script:fixtureRoot -c user.name='VidNap test fixture' -c user.email='fixture@example.invalid' -c commit.gpgSign=false commit --quiet -m 'Packaging fixture'
    if ($LASTEXITCODE -ne 0) { throw 'Fixture git commit failed' }
    $commit = git -C $script:fixtureRoot rev-parse HEAD
    git -C $script:fixtureRoot check-ignore --quiet docs/ignored-fixture.md
    Assert-Packaging ($LASTEXITCODE -eq 0) 'Ignored fixture is actually excluded by Git'
    $documentationHash = (Get-FileHash -LiteralPath (Join-Path $script:fixtureRoot 'docs/FALLBACK-DESIGN.md')).Hash
    $fileVersion = (Get-Item -LiteralPath (Join-Path $script:fixtureRoot 'VidNapLauncher.exe')).VersionInfo.FileVersion
    Assert-Packaging ($fileVersion -match '^(\d+\.\d+\.\d+)\.0$') 'Existing launcher has a release-compatible version'
    $version = $Matches[1]
    Assert-Packaging ([Reflection.AssemblyName]::GetAssemblyName((Join-Path $script:fixtureRoot 'VidNapLauncher.exe')).Version.ToString() -eq "$version.0") 'Launcher assembly and file versions agree'
    $uiSource = Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'VidNap.ps1') -Raw
    Assert-Packaging ($uiSource.Contains('Title="VidNap ' + $version + '"')) 'UI title agrees with launcher version'
    $readmeSource = Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'README.md') -Raw
    Assert-Packaging ($readmeSource.StartsWith('# VidNap ' + $version + ' (review build)')) 'README identifies the same review-build version'
    Assert-Packaging (Test-Path -LiteralPath (Join-Path $script:fixtureRoot "docs/RELEASE-$version.md")) 'Matching review-build notes exist'
    $builder = Join-Path $script:fixtureRoot 'Build-Release.ps1'
    Assert-Packaging ((Get-Content -LiteralPath $builder -Raw).Contains("[string]`$Version = '$version'")) 'Packaging default agrees with launcher version'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $snapshot = Get-PackagingSourceSnapshot
    $output = @(& $builder -Version $version)
    Assert-Packaging ($output.Count -eq 2) 'Default packaging returns both archive checksums'
    Test-PackagingArchives $version $commit $documentationHash
    Assert-Packaging ((Get-PackagingSourceSnapshot) -eq $snapshot) 'Packaging preserves all fixture source bytes'
    Assert-Packaging (@(Get-ChildItem -LiteralPath (Join-Path $script:fixtureRoot 'dist') -Directory -Filter 'stage-*').Count -eq 0) 'Packaging cleans its stage'
    Assert-Packaging (Test-Path -LiteralPath (Join-Path $script:fixtureRoot 'dist/SHA256SUMS.txt')) 'Checksum file produced'

    # Move HEAD to a new clean commit, then explicitly package the old one.
    Add-Content -LiteralPath (Join-Path $script:fixtureRoot 'docs/FALLBACK-DESIGN.md') -Value 'Newer commit bytes must not appear in the selected older commit'
    git -C $script:fixtureRoot -c core.autocrlf=false add -- docs/FALLBACK-DESIGN.md
    git -C $script:fixtureRoot -c user.name='VidNap test fixture' -c user.email='fixture@example.invalid' -c commit.gpgSign=false commit --quiet -m 'Advance fixture HEAD'
    if ($LASTEXITCODE -ne 0) { throw 'Fixture second commit failed' }
    $snapshot = Get-PackagingSourceSnapshot
    $output = @(& $builder -Version $version -Commit $commit -SkipBuild)
    Assert-Packaging ($output.Count -eq 2) 'Explicit commit and legacy SkipBuild accepted'
    Test-PackagingArchives $version $commit $documentationHash
    Assert-Packaging ((Get-PackagingSourceSnapshot) -eq $snapshot) 'Explicit-commit packaging preserves newer working files'
    Assert-PackagingThrows { & $builder -Version $version -Commit 'not-a-real-commit' 2>$null } '*Cannot resolve the exact source commit*'
    Assert-PackagingThrows { & $builder -Version '999.999.999' } '*Launcher version does not match release*'
    Add-Content -LiteralPath (Join-Path $script:fixtureRoot 'README.md') -Value 'Dirty fixture'
    Assert-PackagingThrows { & $builder -Version $version } '*clean source commit*'
    Write-Output "PASS: $script:checks packaging and batch checks; real isolated Git commits and archives, no builds or application launches."
} finally {
    $resolved = [IO.Path]::GetFullPath($script:fixtureRoot)
    $safeParent = $tempParent.TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($safeParent, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^VidNapPackagingTests-[a-f0-9]{32}$') { throw 'Unsafe packaging fixture cleanup refused' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
