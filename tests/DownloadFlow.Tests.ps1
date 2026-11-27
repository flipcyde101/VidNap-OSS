$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Offline integration harness, not GUI E2E: use the real offscreen controls and
# source-derived Start-Download, but replace ONLY modal MessageBox statements
# with fail-closed throws. Get-Tools, preference persistence and the process
# boundary are test doubles. No app startup, engine, browser, network or dialog.
$root = Split-Path $PSScriptRoot -Parent
$script:checks = 0
function Assert-Flow([bool]$Condition, [string]$Label) {
    if (-not $Condition) { throw "FAIL: $Label" }
    $script:checks++
}
function Assert-LocalUnlinkedPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -match '(?i)(^|[\\/])OneDrive(?: - [^\\/]+)?([\\/]|$)') { throw 'Test output must not be OneDrive-backed.' }
    $item = Get-Item -LiteralPath $full -Force
    while ($item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Test output ancestry contains a junction or symbolic link.' }
        $item = $item.Parent
    }
    return $full
}
$root = Assert-LocalUnlinkedPath $root
$tempParent = [IO.Path]::GetTempPath()
if ([IO.Path]::GetPathRoot($tempParent) -ine 'D:\') {
    if ([IO.Path]::GetPathRoot($root) -ine 'D:\') { throw 'A D: checkout or D: temporary directory is required for DownloadFlow.' }
    $tempParent = $root
}
$tempParent = Assert-LocalUnlinkedPath $tempParent
$tempRoot = Join-Path $tempParent ('VidNapFlow-' + [Guid]::NewGuid().ToString('N').Substring(0, 12))
$null = New-Item -ItemType Directory -Path $tempRoot
$tempRoot = Assert-LocalUnlinkedPath $tempRoot
$window = $null
$reader = $null

try {
    if ('VidNapProcessRunner' -as [type]) { throw 'Run this harness in an isolated PowerShell process; a process runner is already loaded.' }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

// Deliberately has the production name in this isolated test process only.
// Start captures configuration; there is no Process.Start or child process.
public sealed class VidNapProcessRunner : IDisposable {
    public static readonly List<ProcessStartInfo> Starts = new List<ProcessStartInfo>();
    public static bool FailNextStart;
    public static int Disposals;
    public bool Disposed;
    public void Start(ProcessStartInfo info) {
        Starts.Add(info);
        if (FailNextStart) {
            FailNextStart = false;
            throw new Win32Exception(2, "Synthetic missing executable (offline test).");
        }
    }
    public void Dispose() { if (!Disposed) { Disposed = true; Disposals++; } }
}

public static class VidNapFlowArguments {
    [DllImport("shell32.dll", SetLastError = true)]
    private static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string command, out int count);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
    public static string[] Parse(string arguments) {
        int count;
        IntPtr memory = CommandLineToArgvW("offline-test.exe " + arguments, out count);
        if (memory == IntPtr.Zero) { throw new Win32Exception(); }
        try {
            string[] result = new string[count - 1];
            for (int i = 1; i < count; i++) {
                result[i - 1] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory, i * IntPtr.Size));
            }
            return result;
        } finally { LocalFree(memory); }
    }
}
'@
    $sourcePath = Join-Path $root 'VidNap.ps1'
    $source = Get-Content -Raw -LiteralPath $sourcePath
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
    Assert-Flow ($parseErrors.Count -eq 0) 'Application source parses before extraction'
    $xamlMatch = [regex]::Match($source, "(?s)\[xml\]\$" + "xaml = @'\r?\n(.*?)\r?\n'@")
    Assert-Flow $xamlMatch.Success 'Application XAML found'
    $reader = [Xml.XmlNodeReader]::new([xml]$xamlMatch.Groups[1].Value)
    $window = [Windows.Markup.XamlReader]::Load($reader)
    foreach ($name in @('UrlBox','FolderBox','BrowseButton','MediaTypeBox','ExportFormatBox','UseBrowserBox','BrowserBox','ProfileBox','CookieFileBox','CookieFileButton','ClearCookieButton','PlaylistBox','MetadataBox','ProgressBar','ProgressText','DownloadButton','CancelButton','StatusText','LogBox','EngineText','SetupButton','OpenFolderButton','ReduceMotionBox','ActivityDot','PhaseText','SpeedText','EtaText','AlternateBox')) {
        $control = $window.FindName($name)
        Assert-Flow ($null -ne $control) "Real XAML control $name exists"
        Set-Variable -Name $name -Value $control
    }
    . (Join-Path $root 'VidNap.Core.ps1')
    foreach ($name in @('Update-Motion','Set-UnknownProgress','Set-Running','Add-Log','Add-ExportFormat','Update-ExportFormatOptions','Get-BrowserSessionInfo','Get-AlternateSelectionError','New-AlternateStartInfo','Get-LegacyTransferArguments','Start-Download')) {
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        Assert-Flow ($null -ne $definition) "Source function $name exists"
        $definitionText = $definition.Extent.Text
        if ($name -eq 'Start-Download') {
            $modalCalls = @($definition.FindAll({ param($node)
                $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
                $node.Expression -is [Management.Automation.Language.TypeExpressionAst] -and
                $node.Expression.TypeName.FullName -eq 'System.Windows.MessageBox' -and
                $node.Member.Value -eq 'Show'
            }, $true))
            Assert-Flow ($modalCalls.Count -gt 0) 'Modal safety guard identifies application dialog statements'
            foreach ($call in ($modalCalls | Sort-Object { $_.Extent.StartOffset } -Descending)) {
                $statement = $call
                while ($statement -and $statement -isnot [Management.Automation.Language.PipelineAst]) { $statement = $statement.Parent }
                if (-not $statement -or $statement.Extent.EndOffset -gt $definition.Extent.EndOffset) { throw 'Cannot safely isolate modal statement.' }
                $offset = $statement.Extent.StartOffset - $definition.Extent.StartOffset
                $definitionText = $definitionText.Remove($offset, $statement.Extent.Text.Length).Insert($offset, "throw 'Modal validation path reached; offline harness forbids dialogs.'")
            }
        }
        # Preserve the app filename for automatic $PSScriptRoot in extracted code.
        $safeAst = [Management.Automation.Language.Parser]::ParseInput($definitionText, $sourcePath, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw "Extracted $name does not parse." }
        $visibleCalls = @($safeAst.FindAll({ param($node)
            $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -in @('Show','ShowDialog')
        }, $true))
        Assert-Flow ($visibleCalls.Count -eq 0) "Extracted $name cannot open a window or dialog"
        . $safeAst.GetScriptBlock()
    }

    $stateDirectory = Join-Path $tempRoot 'state'
    $settingsPath = Join-Path $stateDirectory 'settings.json'
    $destination = Join-Path $tempRoot 'media with spaces'
    $cookieFile = Join-Path $tempRoot 'dummy cookies.txt'
    [IO.File]::WriteAllText($cookieFile, "# Netscape HTTP Cookie File`r`n# Synthetic offline fixture; no cookies or credentials.`r`n")
    $cookieBefore = Get-FileHash -LiteralPath $cookieFile -Algorithm SHA256
    $script:preferencesCalls = 0
    $script:toolFixture = @{ YtDlp=(Join-Path $tempRoot 'fake yt-dlp.exe'); Ffmpeg=(Join-Path $tempRoot 'fake tools\ffmpeg.exe'); Ffprobe=(Join-Path $tempRoot 'fake tools\ffprobe.exe'); Deno=(Join-Path $tempRoot 'fake tools\deno.exe') }
    function Get-Tools { return $script:toolFixture }
    function Save-Preferences { $script:preferencesCalls++ }
    function New-LegacyAttempt([string]$Root,[string]$Destination) {
        $rootPath=[IO.Path]::GetFullPath($Root)
        if([IO.Path]::GetPathRoot($rootPath) -ine 'D:\'){throw 'Legacy staging requires D:.'}
        $stage=Join-Path $rootPath ('legacy-attempt-'+[guid]::NewGuid().ToString('N'))
        [pscustomobject]@{Stage=$stage;Destination=[IO.Path]::GetFullPath($Destination)}
    }
    $script:process = $null
    $script:isRunning = $false
    $script:unknownProgress = $false
    $script:operation = 'download'
    $script:alternateTransfer = $false
    $script:cancelRequested = $false
    $script:failureHint = $null
    $script:lastFile = $null
    $script:legacyAttempt = $null
    $ReduceMotionBox.IsChecked = $true

    function Reset-Flow([string]$Media='video', [string]$Format='best') {
        if ($script:process) { $script:process.Dispose(); $script:process = $null }
        Set-Running $false
        $UrlBox.Text = 'https://example.com/watch?v=offline&list=fixture'
        $FolderBox.Text = $destination
        $AlternateBox.IsChecked = $false
        $UseBrowserBox.IsChecked = $false
        $BrowserBox.SelectedIndex = 2
        $ProfileBox.Text = ''
        $CookieFileBox.Text = ''
        $PlaylistBox.IsChecked = $false
        $MetadataBox.IsChecked = $false
        $MediaTypeBox.SelectedItem = @($MediaTypeBox.Items | Where-Object { $_.Tag -eq $Media })[0]
        Update-ExportFormatOptions
        $ExportFormatBox.SelectedItem = @($ExportFormatBox.Items | Where-Object { $_.Tag -eq $Format })[0]
        Assert-Flow ($null -ne $ExportFormatBox.SelectedItem) "UI offers $Media/$Format"
        $StatusText.Text = 'Ready'
        $LogBox.Clear()
    }
    function Start-CapturedFlow {
        $before = [VidNapProcessRunner]::Starts.Count
        Start-Download
        Assert-Flow ([VidNapProcessRunner]::Starts.Count -eq $before + 1) 'Exactly one fake engine start captured'
        $info = [VidNapProcessRunner]::Starts[$before]
        Assert-Flow (-not $info.UseShellExecute -and $info.CreateNoWindow -and $info.RedirectStandardOutput -and $info.RedirectStandardError) 'Hidden launch and captured output flags retained'
        Assert-Flow ($info.WorkingDirectory -eq $stateDirectory) 'Only temporary state directory used'
        Assert-Flow ($info.StandardOutputEncoding.CodePage -eq 65001 -and $info.StandardErrorEncoding.CodePage -eq 65001) 'UTF-8 output retained'
        Assert-Flow ($script:isRunning -and -not $DownloadButton.IsEnabled -and $CancelButton.IsEnabled -and -not $UrlBox.IsEnabled) 'Start locks controls and enables cancellation'
        return $info
    }
    function Assert-ExactArguments($Info, [string[]]$Extra, [string[]]$Export) {
        $expected = @('--ignore-config','--no-plugin-dirs','--newline','--progress','--no-color','--encoding','utf-8','--windows-filenames','--trim-filenames',[string][Math]::Min((Get-FilenameBudget $destination),(Get-FilenameBudget $script:legacyAttempt.Stage)),'--no-overwrites','--socket-timeout','30','--retries','3','--fragment-retries','3','--progress-delta','0.25','--progress-template','download:VIDNAP_PROGRESS|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s','--progress-template','postprocess:VIDNAP_FINISH|%(progress.status)s','--print','after_move:VIDNAP_FILE|%(filepath)s')
        $expected += $Extra
        if ($script:toolFixture.Ffmpeg) { $expected += @('--ffmpeg-location',(Split-Path -Parent $script:toolFixture.Ffmpeg)) }
        if ($script:toolFixture.Deno) { $expected += @('--no-js-runtimes','--js-runtimes',('deno:' + $script:toolFixture.Deno)) }
        $expected += $Export
        $expected += @('--retries','0','--abort-on-unavailable-fragments')
        $expected += @('-o',(Join-Path ($script:legacyAttempt.Stage.Replace('%','%%')) '%(title).200B [%(id)s].%(ext)s'),'--',$UrlBox.Text.Trim())
        $actual = [VidNapFlowArguments]::Parse($Info.Arguments)
        Assert-Flow ($actual.Count -eq $expected.Count) 'Argument count matches independently specified invocation'
        for ($i=0; $i -lt $expected.Count; $i++) { Assert-Flow ($actual[$i] -ceq $expected[$i]) "Argument $i round-trips exactly" }
        Assert-Flow ($Info.FileName -eq $script:toolFixture.YtDlp) 'Selected fake engine executable retained'
    }
    $single = @('--no-playlist','--playlist-items','1')
    $modes = @(
        @{ Media='video'; Format='best'; Export=@('-f','bestvideo*+bestaudio/best') },
        @{ Media='video'; Format='mp4'; Export=@('-f','bestvideo[ext=mp4][vcodec^=avc1]+bestaudio[ext=m4a][acodec^=mp4a]/best[ext=mp4][vcodec^=avc1][acodec^=mp4a]','--merge-output-format','mp4','--remux-video','mp4') },
        @{ Media='video'; Format='mkv'; Export=@('-f','bestvideo+bestaudio/best','--merge-output-format','mkv','--remux-video','mkv') },
        @{ Media='video'; Format='webm'; Export=@('-f','bestvideo[ext=webm]+bestaudio[ext=webm]/best[ext=webm]','--merge-output-format','webm','--remux-video','webm') },
        @{ Media='audio'; Format='original'; Export=@('-f','bestaudio') }
    )
    foreach ($format in @('mp3','m4a','flac','wav','opus')) {
        $modes += @{ Media='audio'; Format=$format; Export=@('-f','bestaudio/best','-x','--audio-format',$format,'--audio-quality','0') }
    }
    foreach ($mode in $modes) {
        Reset-Flow $mode.Media $mode.Format
        $info = Start-CapturedFlow
        Assert-ExactArguments $info $single $mode.Export
    }
    foreach ($mode in @(@{Media='video';Format='best';Export=@('-f','best')},@{Media='audio';Format='original';Export=@('-f','bestaudio')})) {
        Reset-Flow $mode.Media $mode.Format
        $ffmpeg = $script:toolFixture.Ffmpeg
        try {
            $script:toolFixture.Ffmpeg = $null
            $MetadataBox.IsChecked = $true
            $info = Start-CapturedFlow
            Assert-ExactArguments $info $single $mode.Export
        } finally { $script:toolFixture.Ffmpeg = $ffmpeg }
    }
    Reset-Flow
    $PlaylistBox.IsChecked = $true; $MetadataBox.IsChecked = $true
    $info = Start-CapturedFlow
    Assert-ExactArguments $info @('--yes-playlist','--embed-metadata') @('-f','bestvideo*+bestaudio/best')

    # Browser preference must have no credential-enabling event handler, even
    # after the real window loads. A future handler needs explicit test coverage.
    Assert-Flow ($source -notmatch '\$BrowserBox\.Add_SelectionChanged') 'Browser selection has no auto-authentication callback'
    foreach ($browser in @('chrome','edge','firefox')) {
        Reset-Flow
        $BrowserBox.SelectedItem = @($BrowserBox.Items | Where-Object { $_.Tag -eq $browser })[0]
        Assert-Flow (-not $UseBrowserBox.IsChecked) "Selecting $browser leaves sign-in unchecked"
        $info=Start-CapturedFlow
        $argsWithoutConsent=[VidNapFlowArguments]::Parse($info.Arguments)
        Assert-Flow ($argsWithoutConsent -notcontains '--cookies-from-browser') "Selecting $browser cannot request cookies without consent"
        foreach ($profile in @('', ' Profile "One"\ ')) {
            Reset-Flow
            $UseBrowserBox.IsChecked = $true
            $BrowserBox.SelectedItem = @($BrowserBox.Items | Where-Object { $_.Tag -eq $browser })[0]
            $ProfileBox.Text = $profile
            $cookieSource = $browser
            if ($profile.Trim()) { $cookieSource += ':' + $profile.Trim() }
            $info = Start-CapturedFlow
            Assert-ExactArguments $info ($single + @('--cookies-from-browser',$cookieSource)) @('-f','bestvideo*+bestaudio/best')
        }
    }
    Reset-Flow
    $CookieFileBox.Text=$cookieFile
    $BrowserBox.SelectedIndex=1
    Assert-Flow ($CookieFileBox.Text -eq $cookieFile -and -not $UseBrowserBox.IsChecked) 'Browser preference preserves explicit cookie-file selection'
    Reset-Flow
    $FolderBox.Text=Join-Path $tempRoot '50% %TEMP%'
    $info=Start-CapturedFlow
    $literalArgs=[VidNapFlowArguments]::Parse($info.Arguments)
    $outputIndex=[Array]::IndexOf($literalArgs,'-o')
    $expectedStageTemplate=Join-Path ($script:legacyAttempt.Stage.Replace('%','%%')) '%(title).200B [%(id)s].%(ext)s'
    Assert-Flow ($literalArgs[$outputIndex+1] -ceq $expectedStageTemplate) 'Percent in destination inherits to stage path and is escaped in output template'
    Reset-Flow
    $FolderBox.Text=Join-Path $tempRoot '$HOME'
    $before=[VidNapProcessRunner]::Starts.Count
    Start-Download
    Assert-Flow ([VidNapProcessRunner]::Starts.Count -eq $before -and $StatusText.Text -like '*without $*') 'Dollar folder rejected inline before engine launch'
    Reset-Flow
    $UseBrowserBox.IsChecked = $true; $CookieFileBox.Text = $cookieFile
    $ProfileBox.Text = "ignored`nprofile"
    $info = Start-CapturedFlow
    Assert-ExactArguments $info ($single + @('--cookies',$cookieFile)) @('-f','bestvideo*+bestaudio/best')
    Assert-Flow ($LogBox.Text -match 'Cookie file mode' -and $LogBox.Text -notmatch 'saved .* sign-in session') 'Cookie precedence reflected in log'

    Reset-Flow
    $UseBrowserBox.IsChecked = $true; $ProfileBox.Text = "profile`nsecond-line"
    $before = [VidNapProcessRunner]::Starts.Count; $preferencesBefore = $script:preferencesCalls
    Start-Download
    Assert-Flow ([VidNapProcessRunner]::Starts.Count -eq $before -and $script:preferencesCalls -eq $preferencesBefore -and $null -eq $script:process) 'Multiline profile rejected before process or preferences'
    Assert-Flow ($StatusText.Text -eq 'Enter a single browser profile name or path.' -and $DownloadButton.IsEnabled) 'Multiline profile has safe inline recovery'

    # Each alternate incompatibility is rejected inline, before helper creation.
    foreach ($case in @('audio','format','browser','cookie','playlist','metadata')) {
        if ($case -eq 'audio') { Reset-Flow audio original } elseif ($case -eq 'format') { Reset-Flow video mp4 } else { Reset-Flow }
        $AlternateBox.IsChecked = $true
        switch ($case) {
            'browser' { $UseBrowserBox.IsChecked = $true }
            'cookie' { $CookieFileBox.Text = $cookieFile }
            'playlist' { $PlaylistBox.IsChecked = $true }
            'metadata' { $MetadataBox.IsChecked = $true }
        }
        $before = [VidNapProcessRunner]::Starts.Count; $preferencesBefore = $script:preferencesCalls
        Start-Download
        Assert-Flow ([VidNapProcessRunner]::Starts.Count -eq $before -and $script:preferencesCalls -eq $preferencesBefore -and $null -eq $script:process) "Alternate $case rejected before launch or preferences"
        Assert-Flow ($StatusText.Text -like 'Alternate transfer requires Video / Best available.*' -and $DownloadButton.IsEnabled -and -not $CancelButton.IsEnabled) "Alternate $case rejection is inline and recoverable"
    }

    Reset-Flow
    $AlternateBox.IsChecked = $true
    $UrlBox.Text = 'https://example.com/offline.mp4'
    $info = Start-CapturedFlow
    $alternateArguments = [VidNapFlowArguments]::Parse($info.Arguments)
    $expectedAlternate = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'VidNap.Alternate.ps1'),'-Url',$UrlBox.Text,'-Folder',$destination,'-Ffprobe',$script:toolFixture.Ffprobe)
    Assert-Flow ($info.FileName -eq (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -and $alternateArguments.Count -eq $expectedAlternate.Count) 'Alternate mode selects hidden helper invocation only'
    for ($i=0; $i -lt $expectedAlternate.Count; $i++) { Assert-Flow ($alternateArguments[$i] -ceq $expectedAlternate[$i]) "Alternate helper argument $i round-trips exactly" }
    Assert-Flow ($script:alternateTransfer -and $PhaseText.Text -eq 'Alternate: preparing' -and $LogBox.Text -match 'Alternate direct-file transfer') 'Alternate start context and status retained'
    foreach ($case in @('http','missing-ffprobe')) {
        Reset-Flow
        $AlternateBox.IsChecked = $true
        $UrlBox.Text = if ($case -eq 'http') { 'http://example.com/offline.mp4' } else { 'https://example.com/offline.mp4' }
        $ffprobe = $script:toolFixture.Ffprobe
        try {
            if ($case -eq 'missing-ffprobe') { $script:toolFixture.Ffprobe = $null }
            $before = [VidNapProcessRunner]::Starts.Count; $preferencesBefore = $script:preferencesCalls
            Start-Download
            Assert-Flow ([VidNapProcessRunner]::Starts.Count -eq $before -and $script:preferencesCalls -eq $preferencesBefore -and $null -eq $script:process) "Alternate $case rejected before launch or preferences"
            $expectedError = if ($case -eq 'http') { 'Alternate transfer requires a public HTTPS URL without embedded credentials.' } else { 'Alternate transfer requires ffprobe. Use Install engine first.' }
            Assert-Flow ($StatusText.Text -eq $expectedError -and $DownloadButton.IsEnabled -and -not $CancelButton.IsEnabled) "Alternate $case rejection is inline and recoverable"
        } finally { $script:toolFixture.Ffprobe = $ffprobe }
    }

    Reset-Flow
    [VidNapProcessRunner]::FailNextStart = $true
    $before = [VidNapProcessRunner]::Starts.Count; $disposalsBefore = [VidNapProcessRunner]::Disposals
    Start-Download
    Assert-Flow ([VidNapProcessRunner]::Starts.Count -eq $before + 1 -and [VidNapProcessRunner]::Disposals -eq $disposalsBefore + 1) 'Failed launch attempts once and disposes runner'
    Assert-Flow ($null -eq $script:process -and -not $script:isRunning -and $DownloadButton.IsEnabled -and $UrlBox.IsEnabled -and -not $CancelButton.IsEnabled) 'Failed launch restores retry controls and clears process'
    Assert-Flow ($StatusText.Text -eq 'Could not start' -and -not $ProgressBar.IsIndeterminate -and -not $ActivityDot.HasAnimatedProperties) 'Failed launch stops progress and animation'
    Assert-Flow ($LogBox.Text -match 'Synthetic missing executable' -and $LogBox.Text -match 'VidNap result: Download failed before the engine completed') 'Failed launch preserves actionable evidence'
    $info = Start-CapturedFlow
    Assert-ExactArguments $info $single @('-f','bestvideo*+bestaudio/best')
    $before = [VidNapProcessRunner]::Starts.Count; $preferencesBefore = $script:preferencesCalls
    Start-Download
    Assert-Flow ([VidNapProcessRunner]::Starts.Count -eq $before -and $script:preferencesCalls -eq $preferencesBefore) 'Repeated click cannot start a second engine'

    Assert-Flow (-not $window.IsVisible -and -not $window.IsLoaded) 'Window never shown or loaded onscreen'
    Assert-Flow (-not (Test-Path -LiteralPath $settingsPath)) 'Real preference persistence never invoked'
    Assert-Flow ((Get-FileHash -LiteralPath $cookieFile -Algorithm SHA256).Hash -eq $cookieBefore.Hash) 'Synthetic cookie fixture not modified'
    Assert-Flow (@(Get-ChildItem -LiteralPath $destination -Force).Count -eq 0) 'No media or child process output created'
    Write-Output "PASS: download-flow integration $script:checks checks; $([VidNapProcessRunner]::Starts.Count) captured fake starts. Actual source-derived argument/control/retry wiring; modal statements replaced by fail-closed test guards. Offscreen only; no network, engine, real cookies or preferences."
} finally {
    if (Get-Variable -Name process -Scope Script -ErrorAction SilentlyContinue) {
        if ($script:process) { $script:process.Dispose(); $script:process = $null }
    }
    if ($reader) { $reader.Dispose() }
    # Re-resolve and bound recursive cleanup to this run's unique TEMP child.
    if (Test-Path -LiteralPath $tempRoot) {
        $resolved = Assert-LocalUnlinkedPath $tempRoot
        if ([IO.Directory]::GetParent($resolved).FullName.TrimEnd('\') -ne $tempParent.TrimEnd('\') -or [IO.Path]::GetFileName($resolved) -notmatch '^VidNapFlow-[0-9a-f]{12}$') { throw 'Refusing cleanup outside owned test directory.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
