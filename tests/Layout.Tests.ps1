$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$root=Split-Path $PSScriptRoot -Parent
$source=Get-Content -Raw (Join-Path $root 'VidNap.ps1')
$match=[regex]::Match($source,"(?s)\[xml\]\$" + "xaml = @'\r?\n(.*?)\r?\n'@")
$xml=[xml]$match.Groups[1].Value
$reader=New-Object System.Xml.XmlNodeReader $xml
$window=[Windows.Markup.XamlReader]::Load($reader)
# Execute only selected pure/UI functions, never the application's startup or network code.
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'UI script does not parse'}
. (Join-Path $root 'VidNap.Core.ps1')
foreach($name in @('ReduceMotionBox','ActivityDot','PhaseText','SpeedText','EtaText','ProgressBar','ProgressText','StatusText','LogBox','DownloadButton','CancelButton','BrowseButton','SetupButton','MediaTypeBox','ExportFormatBox','UrlBox','UseBrowserBox','BrowserBox','ProfileBox','PlaylistBox','MetadataBox','CookieFileButton','ClearCookieButton','CookieFileBox','AlternateBox')) {Set-Variable $name $window.FindName($name)}
foreach($name in 'Update-Motion','Set-UnknownProgress','Set-Running','Add-Log','Receive-OperationLine','Complete-Operation','Get-AlternateSelectionError','New-AlternateStartInfo','Request-OperationCancel','Handle-OperationError') {
    $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    . ([scriptblock]::Create($function.Extent.Text))
}
$script:isRunning=$true; $script:unknownProgress=$true; $script:operation='download'; $script:alternateTransfer=$false
$script:cancelRequested=$false
$script:setupReady=$false; $script:setupFinishing=$false
$script:savedFiles=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:reportedFiles=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:failureHint=$null
$script:legacyAttempt=$null
function Update-EngineStatus { $script:engineRefreshes++ }
$script:engineRefreshes=0
if(Get-AlternateSelectionError 'video' 'best' $false '' $false $false){throw 'Eligible alternate selection rejected'}
foreach($selection in @(@('audio','original',$false,'',$false,$false),@('video','mp4',$false,'',$false,$false),@('video','best',$true,'',$false,$false),@('video','best',$false,'cookies.txt',$false,$false),@('video','best',$false,'',$true,$false),@('video','best',$false,'',$false,$true))) {
    if(-not (Get-AlternateSelectionError @selection)){throw 'Ineligible alternate selection accepted'}
}
$alternateInfo=New-AlternateStartInfo 'https://example.com/video.mp4?x=1&y=2' 'C:\Videos with spaces' 'C:\Tools\ffprobe.exe' 'C:\App\VidNap.Alternate.ps1'
if($alternateInfo.Arguments -notlike '*"C:\Videos with spaces"*' -or $alternateInfo.Arguments -notlike '*-Ffprobe*' -or $alternateInfo.Arguments -match 'cookies|YtDlp|ffmpeg' -or $alternateInfo.UseShellExecute -or -not $alternateInfo.CreateNoWindow){throw 'Alternate process arguments/isolation mismatch'}
foreach($url in 'http://example.com/video.mp4','https://user:pass@example.com/video.mp4') {
    $rejected=$false
    try{New-AlternateStartInfo $url 'C:\Videos' 'C:\ffprobe.exe' 'C:\App\VidNap.Alternate.ps1'|Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw 'Unsafe alternate URL accepted by UI'}
}
Set-Running $true
if($AlternateBox.IsEnabled -or $UrlBox.IsEnabled -or $MediaTypeBox.IsEnabled -or -not $CancelButton.IsEnabled){throw 'Running mode does not lock selection controls'}
$ReduceMotionBox.IsChecked=$true; Update-Motion
if($ProgressBar.IsIndeterminate -or $ActivityDot.HasAnimatedProperties){throw 'Reduced motion must stop animations'}
$ReduceMotionBox.IsChecked=$false; Update-Motion
if(-not $ProgressBar.IsIndeterminate -or -not $ActivityDot.HasAnimatedProperties){throw 'Enabled activity motion missing'}
Receive-OperationLine 'VIDNAP_PROGRESS|50|100|NA|1048576|12'
if($ProgressBar.Value -ne 50 -or $SpeedText.Text -notmatch '1.0 MiB/s' -or $EtaText.Text -ne '12 seconds' -or $PhaseText.Text -ne 'Downloading'){throw 'Live metrics mismatch'}
$script:alternateTransfer=$true
Receive-OperationLine 'VIDNAP_PROGRESS|50|100|NA|1048576|12'
if($PhaseText.Text -ne 'Alternate transfer'){throw 'Alternate engine phase not visible'}
$script:alternateTransfer=$false
Receive-OperationLine 'VIDNAP_PROGRESS|50|NA|NA|NA|NA'
if($SpeedText.Text -ne 'Waiting for data' -or $EtaText.Text -ne 'Not available'){throw 'Unknown metrics must not retain old values'}
Receive-OperationLine 'VIDNAP_FINISH|processing'
if($PhaseText.Text -ne 'Finishing' -or $SpeedText.Text -ne 'Not transferring'){throw 'Finishing metrics mismatch'}
$script:cancelRequested=$true
$PhaseText.Text='Cancelling'; $StatusText.Text='Cancelling...'; $ProgressText.Text='Cancelling...'
Receive-OperationLine 'VIDNAP_PROGRESS|50|100|NA|1048576|12'
Receive-OperationLine 'VIDNAP_FINISH|processing'
if($PhaseText.Text -ne 'Cancelling' -or $StatusText.Text -ne 'Cancelling...' -or $ProgressText.Text -ne 'Cancelling...'){throw 'Queued telemetry overwrote cancellation state'}
Receive-OperationLine 'VIDNAP_FILE|C:\Videos\finished-before-cancel.mp4'
if(-not $script:reportedFiles.Contains('C:\Videos\finished-before-cancel.mp4')){throw 'Cancellation discarded retained staging record'}
Receive-OperationLine 'VIDNAP_FILE|C:\Videos\finished-before-cancel.mp4'
Receive-OperationLine 'VIDNAP_FILE|'
if($script:reportedFiles.Count -ne 1 -or $script:savedFiles.Count -ne 0){throw 'Staged records incorrectly counted as saved'}
Complete-Operation 0
if($PhaseText.Text -ne 'Cancelled' -or $CancelButton.IsEnabled){throw 'Cancelled terminal state not applied to UI'}
$script:cancelRequested=$false
$script:alternateTransfer=$true
[void]$script:savedFiles.Add('C:\Videos\synthetic-alternate.mp4')
Complete-Operation 0
if($PhaseText.Text -ne 'Complete' -or $ProgressBar.Value -ne 100 -or $StatusText.Text -notmatch '1 file reported'){throw 'Successful terminal state not applied'}
$script:failureHint='Test hint'
Complete-Operation 1
if($PhaseText.Text -ne 'Failed' -or $StatusText.Text -notmatch 'Test hint'){throw 'Failed terminal state not applied'}
$script:operation='setup'
Complete-Operation 0
if($PhaseText.Text -ne 'Ready' -or $script:engineRefreshes -ne 1){throw 'Setup success not applied'}
Complete-Operation 1
if($PhaseText.Text -ne 'Setup failed' -or $script:engineRefreshes -ne 2){throw 'Setup failure not applied'}
$cancelRoot=Join-Path $env:TEMP ('VidNapCancelTests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $cancelRoot | Out-Null
try {
    $setupDecisionPath=Join-Path $cancelRoot '.vidnap-setup-decision'
    $script:process=[pscustomobject]@{IsRunning=$true;Stops=0}
    $script:process | Add-Member ScriptMethod Stop { $this.Stops++ }
    $script:process | Add-Member NoteProperty Disposals 0
    $script:process | Add-Member ScriptMethod Dispose { $this.Disposals++ }
    $script:setupReady=$false; $script:setupFinishing=$false; $script:cancelRequested=$false
    Request-OperationCancel
    if($script:process.Stops -ne 0 -or (Test-Path -LiteralPath $setupDecisionPath)){throw 'Cancel ran before setup reset handshake'}
    Receive-OperationLine 'VIDNAP_SETUP_READY'
    if(-not $CancelButton.IsEnabled -or -not $script:setupReady){throw 'Ready handshake did not enable cancel'}
    Request-OperationCancel
    if($script:process.Stops -ne 1 -or -not $script:cancelRequested -or ([IO.File]::ReadAllText($setupDecisionPath)) -ne 'cancel'){throw 'GUI cancel winner must stop precommit setup'}
    Receive-OperationLine '[5/6] Old queued progress'
    if($PhaseText.Text -ne 'Cancelling'){throw 'Queued setup telemetry overwrites cancellation'}
    Complete-Operation 1
    if($PhaseText.Text -ne 'Cancelled'){throw 'Setup cancellation terminal state is wrong'}
    Remove-Item -LiteralPath $setupDecisionPath
    $script:process.Stops=0; $script:cancelRequested=$false; $script:setupFinishing=$false
    $null=Try-ClaimSetupDecision $setupDecisionPath 'commit'
    Request-OperationCancel
    if($script:process.Stops -ne 0 -or $script:cancelRequested -or -not $script:setupFinishing -or $CancelButton.IsEnabled){throw 'GUI must wait when setup wins commit'}
    Receive-OperationLine '[5/6] Old queued progress'
    if($PhaseText.Text -ne 'Finishing'){throw 'Queued setup progress overwrites finishing state'}
    Complete-Operation 0
    if($PhaseText.Text -ne 'Ready'){throw 'Commit-winner setup must finish normally'}
    Set-Running $true
    $runner=$script:process
    Handle-OperationError 'Simulated monitor failure after commit'
    if($runner.Stops -ne 0 -or $runner.Disposals -ne 0 -or $script:process -ne $runner -or -not $script:isRunning){throw 'Monitor error must retain committed setup for polling without Stop/Dispose'}
    if(([IO.File]::ReadAllText($setupDecisionPath)) -ne 'commit'){throw 'Monitor error changed the winning commit decision'}
    # Exercise both actual error entry points through source-derived scriptblocks.
    $tick=$ast.Find({param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'Add_Tick'},$true)
    $timerTry=$tick.Find({param($node) $node -is [Management.Automation.Language.TryStatementAst]},$true)
    $monitorCatch=[scriptblock]::Create($timerTry.CatchClauses[0].Body.Extent.Text.TrimStart('{').TrimEnd('}'))
    try { throw 'Injected timer failure' } catch { & $monitorCatch }
    $dispatch=$ast.Find({param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'add_UnhandledException'},$true)
    $dispatcherHandler=[scriptblock]::Create($dispatch.Arguments[0].ScriptBlock.Extent.Text.TrimStart('{').TrimEnd('}'))
    $stateDirectory=$cancelRoot
    $errorEvent=[pscustomobject]@{Exception=[Exception]::new('Injected dispatcher failure');Handled=$false}
    & $dispatcherHandler $null $errorEvent
    if(-not $errorEvent.Handled -or $runner.Stops -ne 0 -or $runner.Disposals -ne 0 -or $script:process -ne $runner -or -not $script:isRunning){throw 'Exception entry points killed committed setup or abandoned polling'}
    Remove-Item -LiteralPath $setupDecisionPath
    $script:setupReady=$false
    Handle-OperationError 'Before ready'
    if($runner.Stops -ne 0 -or (Test-Path -LiteralPath $setupDecisionPath)){throw 'Monitor error raced setup decision reset'}
    $script:setupReady=$true
    Handle-OperationError 'Precommit monitor failure'
    if($runner.Stops -ne 1 -or $runner.Disposals -ne 1 -or $null -ne $script:process -or ([IO.File]::ReadAllText($setupDecisionPath)) -ne 'cancel'){throw 'Monitor error must win cancel before stopping setup'}
    Write-Output 'PASS: monitor and dispatcher error paths preserve committed setup and polling; precommit errors claim cancel before Stop.'
    Write-Output 'PASS: setup Cancel/commit race orders, reset handshake and queued UI telemetry (real decision file, fake process).'
} finally {
    $script:process=$null; $script:setupReady=$false; $script:setupFinishing=$false; $script:cancelRequested=$false
    Remove-Item -LiteralPath $cancelRoot -Recurse -Force
}
$script:operation='download'
Set-Running $false
if($ActivityDot.HasAnimatedProperties -or $ProgressBar.IsIndeterminate -or $EtaText.Text -ne 'Not available'){throw 'Terminal state leaves animation or stale ETA'}
if(-not $AlternateBox.IsEnabled){throw 'Alternate selector not restored after terminal state'}
$script:operation='setup'; Receive-OperationLine '[2/6] Checking tools'
if($PhaseText.Text -ne 'Installing' -or $ProgressText.Text -ne 'Step 2 of 6'){throw 'Setup state mismatch'}
$PhaseText.Text='Ready'; $ProgressText.Text='0%'; $ProgressBar.Value=0
$SpeedText.Text='Not started'; $EtaText.Text='Not available'
$window.FindName('UrlBox').Text='https://example.com/my-video'
$window.FindName('FolderBox').Text='C:\Users\You\Videos\VidNap'
$window.FindName('ExportFormatBox').Items.Add('Best available (automatic container)')|Out-Null
$window.FindName('ExportFormatBox').SelectedIndex=0
$window.FindName('EngineText').Text='Engine ready: yt-dlp + FFmpeg + ffprobe'
$window.FindName('StatusText').Text='Ready to save your media'
$content=$window.Content
$content.Background=$window.Background
foreach($width in @(652,852)) {
    $content.Measure([Windows.Size]::new($width,752))
    $content.Arrange([Windows.Rect]::new(0,0,$width,752)); $content.UpdateLayout()
    foreach($name in 'UrlBox','ExportFormatBox','DownloadButton','ProgressBar') {
        $control=$window.FindName($name)
        if($control.ActualWidth -lt 40 -or $control.ActualHeight -le 0){throw "$name has unusable dimensions at width $width"}
    }
    $action=$window.FindName('DownloadButton').TransformToAncestor($content).Transform([Windows.Point]::new(0,0))
    if($action.Y + $window.FindName('DownloadButton').ActualHeight -gt 752){throw 'Download action is below default viewport'}
    if($width -eq 652) {
        $preview=[Windows.Media.Imaging.RenderTargetBitmap]::new(652,752,96,96,[Windows.Media.PixelFormats]::Pbgra32)
        $preview.Render($content)
        $png=[Windows.Media.Imaging.PngBitmapEncoder]::new(); $png.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($preview))
        $out=Join-Path $root 'local-verification'; New-Item -ItemType Directory -Force -Path $out|Out-Null
        $file=[IO.File]::Create((Join-Path $out 'layout-preview-min.png'))
        try{$png.Save($file)}finally{$file.Dispose()}
    }
}
# Minimum-height window remains scrollable; advanced controls must retain usable dimensions.
# Keep XAML tree traversal independent of app event handlers.
$queue=[Collections.Queue]::new(); $queue.Enqueue($content)
while($queue.Count) {
    $element=$queue.Dequeue()
    if($element -is [Windows.Controls.Expander]){$element.IsExpanded=$true}
    for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($element);$i++){$queue.Enqueue([Windows.Media.VisualTreeHelper]::GetChild($element,$i))}
}
$content.Measure([Windows.Size]::new(652,512)); $content.Arrange([Windows.Rect]::new(0,0,652,512)); $content.UpdateLayout()
if($content.ScrollableHeight -le 0){throw 'Expanded minimum-height layout must scroll'}
$content.ScrollToBottom(); $content.UpdateLayout()
$footer=$window.FindName('OpenFolderButton').TransformToAncestor($content).Transform([Windows.Point]::new(0,0))
if($footer.Y -lt 0 -or $footer.Y + $window.FindName('OpenFolderButton').ActualHeight -gt 512){throw 'Footer is unreachable in minimum-height layout'}
foreach($name in 'BrowserBox','ProfileBox','CookieFileButton','LogBox') {
    if($window.FindName($name).ActualHeight -le 0){throw "$name collapsed in expanded layout"}
}
$queue.Enqueue($content)
while($queue.Count) {
    $element=$queue.Dequeue()
    if($element -is [Windows.Controls.Expander]){$element.IsExpanded=$false}
    for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($element);$i++){$queue.Enqueue([Windows.Media.VisualTreeHelper]::GetChild($element,$i))}
}
$content.ScrollToTop()
$content.Measure([Windows.Size]::new(852,752)); $content.Arrange([Windows.Rect]::new(0,0,852,752)); $content.UpdateLayout()
# Offscreen XAML only: no application code, engine, or Show/ShowDialog.
$bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(852,752,96,96,[Windows.Media.PixelFormats]::Pbgra32)
$bitmap.Render($content)
$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new()
$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
$out=Join-Path $root 'local-verification'; New-Item -ItemType Directory -Force -Path $out|Out-Null
$stream=[IO.File]::Create((Join-Path $out 'layout-preview.png'))
try {$encoder.Save($stream)} finally {$stream.Dispose(); $reader.Dispose()}
$script:operation='download'; $ReduceMotionBox.IsChecked=$true
Set-Running $true
Receive-OperationLine 'VIDNAP_PROGRESS|65000000|100000000|NA|8388608|4'
$content.UpdateLayout()
$active=[Windows.Media.Imaging.RenderTargetBitmap]::new(852,752,96,96,[Windows.Media.PixelFormats]::Pbgra32)
$active.Render($content)
$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new(); $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($active))
$stream=[IO.File]::Create((Join-Path $out 'layout-preview-active.png'))
try{$encoder.Save($stream)}finally{$stream.Dispose()}
Set-Running $false
Write-Output 'PASS: offscreen layout at two widths plus minimum-height expanded scrolling, synthetic progress/setup/terminal metrics, reduced-motion behavior; no application launch.'
