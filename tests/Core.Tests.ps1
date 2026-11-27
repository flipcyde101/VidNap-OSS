$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'VidNap.Core.ps1')
$script:passed=0
function Assert($condition,[string]$name) { if(-not $condition){throw "FAIL: $name"}; $script:passed++ }

$args=Get-ExportArguments audio original $true
Assert ($args.Count -eq 2 -and $args[1] -eq 'bestaudio') 'Original audio requires audio-only source without video fallback'
Assert ($args -notcontains '-x') 'Original audio cannot invoke codec-transcoding extractor'
Assert ((Get-ExportArguments audio original $false)[1] -eq 'bestaudio') 'Original audio works without FFmpeg'
foreach($f in 'mp3','m4a','flac','wav','opus') {
    $a=Get-ExportArguments audio $f $true
    Assert ($a -contains $f -and $a -contains '-x') "Audio $f conversion"
}
foreach($f in 'mp4','mkv','webm') {
    $a=Get-ExportArguments video $f $true
    Assert ($a -contains '--remux-video') "Single-file $f exports remux"
    if($f -ne 'mkv') { Assert (-not $a[1].EndsWith('/best')) "$f has no incompatible generic fallback" }
}
foreach($case in @(@('audio','mp3',$false),@('video','mp4',$false),@('audio','invalid',$true),@('other','best',$true))) {
    $caught=$false; try { Get-ExportArguments $case[0] $case[1] $case[2] | Out-Null } catch { $caught=$true }
    Assert $caught 'Unsupported or missing dependency rejected'
}
Assert ((Get-ExportArguments video best $false)[1] -eq 'best') 'Missing FFmpeg has explicit combined-stream fallback'
Assert ((Quote-Argument '') -ceq '""') 'Empty argument'
Assert ((Quote-Argument 'C:\My Folder\') -ceq '"C:\My Folder\\"') 'Trailing slash preserved under Windows quoting'
Assert ((Quote-Argument 'a"b') -ceq '"a\"b"') 'Embedded quote'
Assert ((Quote-Argument 'C:\a\"b') -ceq '"C:\a\\\"b"') 'Backslash before quote'
$base=Get-EngineBaseArguments
Assert ((Get-DefaultDownloadFolder 'C:\FixtureVideos' 'C:\Users\Test') -eq 'C:\FixtureVideos\VidNap') 'Known Videos folder preferred'
Assert ((Get-DefaultDownloadFolder '' 'C:\Users\Test') -eq 'C:\Users\Test\Videos\VidNap') 'Missing Videos folder falls back without startup failure'
Assert ((Get-DefaultDownloadFolder '' '') -eq '') 'Missing known folders allows user to browse instead of crashing'
Assert ((Get-VidNapDataDirectory 'C:\Users\Test\AppData\Local') -eq 'C:\Users\Test\AppData\Local\VidNap') 'Data defaults to local application storage'
Assert ((Get-VidNapDataDirectory 'C:\Users\Test\AppData\Local' 'D:\VidNap\State') -eq 'D:\VidNap\State') 'Explicit local storage override takes priority'
$validPreferences=[pscustomobject]@{Folder='C:\Videos';Media='video';Format='best';Browser='firefox'}
Assert-Preferences $validPreferences
Assert $true 'Valid preferences accepted'
foreach($json in @('null','{}','{"Folder":"C:\\Videos"}','{"Folder":"relative","Media":"video","Format":"best","Browser":"firefox"}','{"Folder":"C:\\Videos","Media":"audio","Format":"mp4","Browser":"firefox"}','{"Folder":42,"Media":"video","Format":"best","Browser":"firefox"}')) {
    $caught=$false
    try { Assert-Preferences ($json | ConvertFrom-Json) } catch { $caught=$true }
    Assert $caught 'Invalid preference record rejected before applying controls'
}
$single=@(Get-PlaylistArguments $false)
Assert (($single -join '|') -eq '--no-playlist|--playlist-items|1') 'Unchecked playlist mode bounds playlist-only input to first item'
Assert ((@(Get-PlaylistArguments $true) -join '|') -eq '--yes-playlist') 'Explicit playlist mode allows the requested batch'
Assert ($base -contains '--ignore-config' -and $base -contains '--no-plugin-dirs') 'No ambient configuration/plugins'
Assert ($base -contains '--no-overwrites') 'Existing media preserved'
$p=ConvertFrom-ProgressLine 'VIDNAP_PROGRESS|512|1024|NA|1048576|5'
Assert ($p.Percent -eq 50 -and $p.KnownTotal -and $p.Speed -eq 1MB -and $p.Eta -eq 5) 'Structured progress numbers'
$p=ConvertFrom-ProgressLine 'VIDNAP_PROGRESS|512|NA|2048|NA|NA'
Assert ($p.Percent -eq 25) 'Estimated total progress'
$p=ConvertFrom-ProgressLine 'VIDNAP_PROGRESS|512|NA|NA|NA|NA'
Assert (-not $p.KnownTotal) 'Unknown length remains indeterminate'
$p=ConvertFrom-ProgressLine 'VIDNAP_PROGRESS|999|10|0|NaN|Infinity'
Assert ($p.Percent -eq 100 -and $p.Speed -eq 0 -and $p.Eta -eq 0) 'Bad values sanitized'
Assert ($null -eq (ConvertFrom-ProgressLine 'VIDNAP_PROGRESS|bad')) 'Malformed progress ignored'
Assert ((ConvertFrom-ProgressLine 'VIDNAP_FILE|C:\My Files\a.mp4').Path -ceq 'C:\My Files\a.mp4') 'Final path preserved'
Assert ((ConvertFrom-ProgressLine 'VIDNAP_FINISH|started').Kind -eq 'Finishing') 'Postprocessing stage'
$oldCulture=[Threading.Thread]::CurrentThread.CurrentCulture
try {
    [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('de-DE')
    Assert ((ConvertFrom-ProgressLine 'VIDNAP_PROGRESS|0.5|1|0|0|0').Percent -eq 50) 'Progress uses invariant culture'
} finally { [Threading.Thread]::CurrentThread.CurrentCulture=$oldCulture }
Assert ((Protect-LogText 'url https://host/file?token=secret#x end') -eq 'url https://host/file?[redacted] end') 'Signed query redacted'
foreach($scheme in @('https','HTTPS','hTtPs','HTTP')) {
    $safe = Protect-LogText ($scheme + '://synthetic:placeholder@example.test/video?token=synthetic#fragment end')
    Assert ($safe -eq ($scheme + '://[redacted]@example.test/video?[redacted] end')) "URL secrets redacted for $scheme scheme"
    Assert ((Protect-LogText ($scheme + '://example.test/video#synthetic')) -eq ($scheme + '://example.test/video?[redacted]')) "Fragment redacted for $scheme scheme"
}
Assert ((Get-DownloadFailureHint 'ERROR: Requested format is not available') -like '*another export*') 'Format recovery is actionable'
Assert ((Get-DownloadFailureHint 'ERROR: Permission denied') -like '*writable*') 'Destination error recovery'
Assert ((Get-FilenameBudget 'C:\Media') -eq 180) 'Short folders retain useful filenames'
$long='C:\' + ('a'*150)
$budget=Get-FilenameBudget $long
Assert (($long.Length + $budget + 32) -le 240) 'Long folder budgets reserve temporary suffix space'
$caught=$false; try { Get-FilenameBudget ('C:\' + ('a'*200)) | Out-Null } catch { $caught=$true }
Assert $caught 'Excessive folder path rejected'
Assert ((Get-DownloadFailureHint 'Unable to download webpage: curl: (35) BoringSSL SSL_connect: SSL_ERROR_SYSCALL') -like '*secure connection could not be established*') 'TLS error takes precedence over generic webpage failure'
Assert ((Get-DownloadFailureHint 'fragment 3: curl: (35) SSL_connect') -notlike '*webpage*') 'TLS hint does not infer download stage'
Assert ((Get-DownloadFailureHint 'Unable to download webpage: curl: (60) certificate verify failed') -like '*Keep certificate verification enabled*') 'Certificate errors retain security checks'
Assert ((Get-DownloadFailureHint 'Unable to download webpage: timeout') -like '*Check your connection*') 'Ordinary network hint preserved'
foreach($reason in @('HTTP Error 403: Forbidden','HTTP Error 401: Unauthorized','Sign in required','Sign-in required','login required','Please log in','authentication required')) {
    Assert ((Get-DownloadFailureHint "Unable to download webpage: $reason") -like '*access to the media*') "Specific access failure takes precedence: $reason"
}
Assert ((Get-DownloadFailureHint 'Unable to download webpage: HTTP Error 404') -like '*not found*') 'Missing page is not a generic connection error'
Assert ((Get-DownloadFailureHint 'Unable to download webpage: HTTP Error 429') -like '*Wait before retrying*') 'Rate limiting discourages immediate retries'
Assert ((Get-OutputTemplate 'C:\a\50% %TEMP%') -ceq 'C:\a\50%% %%TEMP%%\%(title).200B [%(id)s].%(ext)s') 'Legacy template retains and escapes the selected destination'
Assert ((Get-OutputTemplate 'D:\a\50% %TEMP%' -UseWorkingDirectory) -ceq '%(title).200B [%(id)s].%(ext)s') 'Explicit working-directory output passes only a filename template'
$caught=$false; try { Get-OutputTemplate 'C:\a\$HOME' | Out-Null } catch { $caught=$true }
Assert $caught 'Dollar-sign destination rejected before engine expansion'
$terminalCases=@(
    @{Name='success without file'; Code=0; Count=0; Cancel=$false; Op='download'; Alt=$false; Hint=''; Phase='Complete'; Text='no output file was reported'},
    @{Name='success one file'; Code=0; Count=1; Cancel=$false; Op='download'; Alt=$false; Hint=''; Phase='Complete'; Text='1 file reported'},
    @{Name='success many files'; Code=0; Count=3; Cancel=$false; Op='download'; Alt=$false; Hint=''; Phase='Complete'; Text='3 files reported'},
    @{Name='failure no hint'; Code=1; Count=0; Cancel=$false; Op='download'; Alt=$false; Hint=''; Phase='Failed'; Text='exit code 1'},
    @{Name='failure with hint and files'; Code=2; Count=2; Cancel=$false; Op='download'; Alt=$false; Hint='Choose another folder.'; Phase='Failed'; Text='Choose another folder.'},
    @{Name='cancel no files'; Code=1; Count=0; Cancel=$true; Op='download'; Alt=$false; Hint=''; Phase='Cancelled'; Text='0 files reported'},
    @{Name='cancel after one file'; Code=1; Count=1; Cancel=$true; Op='download'; Alt=$false; Hint=''; Phase='Cancelled'; Text='1 file reported'},
    @{Name='cancel after many files'; Code=1; Count=4; Cancel=$true; Op='download'; Alt=$false; Hint=''; Phase='Cancelled'; Text='4 files reported'},
    @{Name='cancel races successful exit'; Code=0; Count=1; Cancel=$true; Op='download'; Alt=$false; Hint=''; Phase='Cancelled'; Text='1 file reported'},
    @{Name='setup success'; Code=0; Count=0; Cancel=$false; Op='setup'; Alt=$false; Hint=''; Phase='Ready'; Text='Engine installed'},
    @{Name='setup failure'; Code=1; Count=0; Cancel=$false; Op='setup'; Alt=$false; Hint=''; Phase='Setup failed'; Text='Setup failed'},
    @{Name='setup cancellation'; Code=1; Count=0; Cancel=$true; Op='setup'; Alt=$false; Hint=''; Phase='Cancelled'; Text='before install commit'},
    @{Name='alternate success'; Code=0; Count=1; Cancel=$false; Op='download'; Alt=$true; Hint=''; Phase='Complete'; Text='1 file reported'},
    @{Name='alternate failure'; Code=1; Count=0; Cancel=$false; Op='download'; Alt=$true; Hint='Connection failed.'; Phase='Failed'; Text='Connection failed.'},
    @{Name='alternate cancellation'; Code=1; Count=1; Cancel=$true; Op='download'; Alt=$true; Hint=''; Phase='Cancelled'; Text='restart from zero'}
)
foreach($case in $terminalCases) {
    $state=Get-TerminalState -Operation $case.Op -CancelRequested $case.Cancel -ExitCode $case.Code -FailureHint $case.Hint -SavedCount $case.Count -Alternate $case.Alt
    Assert ($state.Phase -ceq $case.Phase -and $state.ProgressText -ceq $case.Phase) "$($case.Name): terminal phase"
    Assert ($state.Status.Contains($case.Text)) "$($case.Name): evidence-based status"
    Assert ($state.Status -notmatch 'already existed|not downloaded again|new file was saved') "$($case.Name): no unsupported history claim"
    if($case.Op -eq 'download') {
        Assert ($state.LogLines.Count -eq 1 -and $state.LogLines[0].Contains($state.Status)) "$($case.Name): terminal evidence logged"
        if($case.Count -gt 0){Assert ($state.Status.Contains("$($case.Count) file")) "$($case.Name): file count retained"}
    }
    $done=$case.Code -eq 0 -and -not $case.Cancel
    Assert (($done -and $state.ProgressValue -eq 100) -or (-not $done -and $null -eq $state.ProgressValue)) "$($case.Name): progress completion"
}
Write-Output "Terminal scenarios passed: $($terminalCases.Count)"
Write-Output "Core tests passed: $script:passed"
