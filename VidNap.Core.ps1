Set-StrictMode -Version Latest

function Quote-Argument([AllowEmptyString()][string]$value) {
    # Windows CommandLineToArgvW/CRT quoting: double backslashes before quotes and the closing quote.
    $escaped = [regex]::Replace($value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Get-ExportArguments([string]$mediaType, [string]$format, [bool]$hasFfmpeg) {
    if ($mediaType -notin @('audio','video')) { throw 'Choose Video or Audio.' }
    if ((($mediaType -eq 'audio' -and $format -ne 'original') -or ($mediaType -eq 'video' -and $format -ne 'best')) -and -not $hasFfmpeg) {
        throw 'This export needs FFmpeg. Install the engine first.'
    }
    if ($mediaType -eq 'audio') {
        if ($format -notin @('original','mp3','m4a','flac','wav','opus')) { throw 'Choose a supported audio format.' }
        # Fail if there is no audio-only source. FFmpeg's automatic extraction
        # can transcode uncommon codecs, which would violate this mode's promise.
        if ($format -eq 'original') { return @('-f','bestaudio') }
        return @('-f','bestaudio/best','-x','--audio-format',$format,'--audio-quality','0')
    }
    switch ($format) {
        'mp4' { return @('-f','bestvideo[ext=mp4][vcodec^=avc1]+bestaudio[ext=m4a][acodec^=mp4a]/best[ext=mp4][vcodec^=avc1][acodec^=mp4a]','--merge-output-format','mp4','--remux-video','mp4') }
        'mkv' { return @('-f','bestvideo+bestaudio/best','--merge-output-format','mkv','--remux-video','mkv') }
        'webm' { return @('-f','bestvideo[ext=webm]+bestaudio[ext=webm]/best[ext=webm]','--merge-output-format','webm','--remux-video','webm') }
        'best' {
            if ($hasFfmpeg) { return @('-f','bestvideo*+bestaudio/best') }
            return @('-f','best')
        }
        default { throw 'Choose a supported video format.' }
    }
}

function Get-VidNapDataDirectory([string]$LocalAppData, [string]$OverrideDirectory='') {
    if (-not [string]::IsNullOrWhiteSpace($OverrideDirectory)) {
        if ($OverrideDirectory -notmatch '^[A-Za-z]:[\\/]') { throw 'VidNap data directory override must be an absolute local path.' }
        if ($OverrideDirectory -match '(?i)(^|[\\/])OneDrive(?: - [^\\/]+)?([\\/]|$)') { throw 'VidNap data directory must not be in OneDrive.' }
        return [IO.Path]::GetFullPath($OverrideDirectory)
    }
    if ([string]::IsNullOrWhiteSpace($LocalAppData)) { throw 'Local AppData is unavailable. Set VIDNAP_DATA_DIRECTORY to an absolute local folder.' }
    return Join-Path $LocalAppData 'VidNap'
}

function Initialize-VidNapRuntime([string]$DataDirectory) {
    $data = Get-VidNapDataDirectory '' $DataDirectory
    $paths = @{
        TEMP = Join-Path $data 'temp'
        TMP = Join-Path $data 'temp'
        XDG_CACHE_HOME = Join-Path $data 'cache'
        DENO_DIR = Join-Path $data 'deno-cache'
    }
    # Create all paths before changing the process environment. In particular,
    # direct-script launches must set compiler scratch output before Add-Type.
    foreach ($path in $paths.Values) { [IO.Directory]::CreateDirectory($path) | Out-Null }
    $env:VIDNAP_DATA_DIRECTORY = $data
    foreach ($name in $paths.Keys) { [Environment]::SetEnvironmentVariable($name, $paths[$name], 'Process') }
    # Leave LOCALAPPDATA/APPDATA alone: browser discovery needs real profiles,
    # and credentials remain protected by the separate explicit sign-in option.
}

function Get-DefaultDownloadFolder([string]$videosFolder, [string]$userFolder) {
    if ([string]::IsNullOrWhiteSpace($videosFolder)) {
        if ([string]::IsNullOrWhiteSpace($userFolder)) { return '' }
        $videosFolder = Join-Path $userFolder 'Videos'
    }
    return Join-Path $videosFolder 'VidNap'
}

function Assert-Preferences($preferences) {
    if ($null -eq $preferences) { throw 'Missing preferences.' }
    foreach ($name in @('Folder','Media','Format','Browser')) {
        $property=$preferences.PSObject.Properties[$name]
        if ($null -eq $property -or $property.Value -isnot [string]) { throw 'Incomplete or invalid preferences.' }
    }
    if ([string]::IsNullOrWhiteSpace($preferences.Folder) -or -not [IO.Path]::IsPathRooted($preferences.Folder)) { throw 'Invalid destination preference.' }
    if ($preferences.Media -notin @('video','audio') -or $preferences.Browser -notin @('chrome','edge','firefox')) { throw 'Invalid selection preference.' }
    $formats=if ($preferences.Media -eq 'audio') { @('original','mp3','m4a','flac','wav','opus') } else { @('best','mp4','mkv','webm') }
    if ($preferences.Format -notin $formats) { throw 'Invalid export preference.' }
}

function Get-PlaylistArguments([bool]$allowPlaylist) {
    if ($allowPlaylist) { return @('--yes-playlist') }
    # --no-playlist alone only resolves mixed video/playlist URLs. Bound
    # playlist-only inputs too, so an unchecked option cannot request a batch.
    return @('--no-playlist','--playlist-items','1')
}

function Get-OutputTemplate([string]$folder,[switch]$UseWorkingDirectory) {
    if ($folder.Contains('$')) { throw 'Choose a destination folder without $; the download engine may expand dollar-sign variables.' }
    $filename='%(title).200B [%(id)s].%(ext)s'
    # Desktop requests already run from the destination. Keep its path out of
    # yt-dlp's filename trimming. Legacy callers run from the state folder.
    if($UseWorkingDirectory){return $filename}
    return Join-Path ($folder.Replace('%','%%')) $filename
}

function Try-ClaimSetupDecision {
    param([string]$Path, [ValidateSet('commit','cancel')][string]$Decision)
    # CreateNew is the arbiter, not a read-then-write check. An existing file
    # (even incomplete/unreadable) always loses safely; other IO errors surface.
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $bytes = [Text.Encoding]::ASCII.GetBytes($Decision)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        return $true
    } catch [IO.IOException] {
        if ($null -eq $stream -and (Test-Path -LiteralPath $Path)) { return $false }
        throw
    } finally { if ($stream) { $stream.Dispose() } }
}

function Get-TerminalState {
    param(
        [ValidateSet('download','setup')][string]$Operation='download',
        [bool]$CancelRequested=$false,
        [int]$ExitCode=0,
        [string]$FailureHint='',
        [ValidateRange(0,2147483647)][int]$SavedCount=0,
        [bool]$Alternate=$false
    )
    # Pure decision: file records are evidence of reported output, not proof of
    # a new download. Missing progress and source modification times prove neither.
    $state=@{Phase=''; Status=''; ProgressText=''; ProgressValue=$null; LogLines=@()}
    if ($Operation -eq 'setup') {
        if ($CancelRequested) {
            $state.Phase='Cancelled'; $state.Status='Setup cancelled before install commit. Temporary files may remain until the next setup.'
        } elseif ($ExitCode -eq 0) {
            $state.Phase='Ready'; $state.Status='Engine installed. Paste a media URL to begin.'; $state.ProgressValue=100
        } else {
            $state.Phase='Setup failed'; $state.Status='Setup failed. Details are retained below; select Install engine to retry.'
        }
        $state.ProgressText=$state.Phase
        return $state
    }
    $files=if ($SavedCount -eq 1) { '1 file reported.' } else { "$SavedCount files reported." }
    if ($CancelRequested) {
        $state.Phase='Cancelled'
        $partial=if ($Alternate) { 'An unfinished .part file may remain; alternate transfers restart from zero.' } else { 'Partial files may remain for a later retry.' }
        $state.Status="Cancelled. $files $partial"
    } elseif ($ExitCode -eq 0) {
        $state.Phase='Complete'; $state.ProgressValue=100
        $state.Status=if ($SavedCount -eq 0) { 'Finished, but no output file was reported. See Activity details.' } else { "Finished. $files Use Open folder to inspect the output; files may be new or previously present." }
    } else {
        $state.Phase='Failed'
        $state.Status="Download failed (exit code $ExitCode). $files"
        if ($FailureHint) { $state.Status += " $FailureHint" }
    }
    $state.ProgressText=$state.Phase
    $state.LogLines=@('VidNap result: ' + $state.Status)
    return $state
}

function Get-FilenameBudget([string]$folder) {
    # Leave space for the separator, extension, format ID and temporary suffixes.
    $available = 240 - [IO.Path]::GetFullPath($folder).Length - 32
    if ($available -lt 40) { throw 'Choose a shorter destination folder (under 169 characters).' }
    return [Math]::Min(180,$available)
}

function Get-EngineBaseArguments([int]$filenameBudget=180,[switch]$TrackDownload) {
    $progress='download:VIDNAP_PROGRESS|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s'
    $plan=@()
    if($TrackDownload){
        $progress+='|%(info.format_id)s|%(progress.status)s'
        # Emit only selected IDs and sizes, never URLs or request headers.
        $plan=@('--print','before_dl:VIDNAP_PLAN|%(requested_formats.:.{format_id,filesize,filesize_approx})j|%(.{format_id,filesize,filesize_approx})j')
    }
    return @('--ignore-config','--no-plugin-dirs','--newline','--progress','--no-color',
        '--encoding','utf-8','--windows-filenames','--trim-filenames',[string]$filenameBudget,'--no-overwrites',
        '--socket-timeout','30','--retries','3','--fragment-retries','3',
        '--progress-delta','0.25','--progress-template',$progress,
        '--progress-template','postprocess:VIDNAP_FINISH|%(progress.status)s',
        '--print','after_move:VIDNAP_FILE|%(filepath)s')+$plan
}

function Test-VidNapProgressStreamId([string]$Id) {
    return ($Id -cmatch '\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z')
}

function ConvertFrom-ProgressLine([string]$line) {
    if ($line.StartsWith('VIDNAP_FILE|')) { return @{ Kind='File'; Path=$line.Substring(12) } }
    if ($line.StartsWith('VIDNAP_FINISH|')) { return @{ Kind='Finishing' } }
    if (-not $line.StartsWith('VIDNAP_PROGRESS|')) { return $null }
    $fields = $line.Split('|')
    if ($fields.Count -notin @(6,8)) { return $null }
    $tracked=$fields.Count -eq 8
    $finished=$tracked -and $fields[7] -ceq 'finished'
    $id=if($tracked -and $fields[7] -cin @('downloading','finished') -and (Test-VidNapProgressStreamId $fields[6])){$fields[6]}else{''}
    $hasBytes=$false
    $numbers = @()
    for ($i=1; $i -lt 6; $i++) {
        $n = 0.0
        $valid=[double]::TryParse($fields[$i], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n) -and -not [double]::IsNaN($n) -and -not [double]::IsInfinity($n) -and $n -ge 0
        # Keep the sum of two counters inside JavaScript's exact integer range.
        if($tracked -and $i -le 3 -and ($n -gt 4503599627370495 -or $n -ne [Math]::Truncate($n))){$valid=$false}
        if($i -eq 1){$hasBytes=$valid}
        if(-not $valid){$n=0.0}
        $numbers += $n
    }
    if($finished -and -not $hasBytes -and $numbers[1] -gt 0){$numbers[0]=$numbers[1];$hasBytes=$true}
    $total = if ($numbers[1] -gt 0) { $numbers[1] } else { $numbers[2] }
    $percent = if ($total -gt 0) { [Math]::Min(100, 100*$numbers[0]/$total) } else { 0 }
    return @{ Kind='Downloading'; Percent=$percent; KnownTotal=($total -gt 0); Total=$total; TotalEstimated=($numbers[1] -le 0 -and $numbers[2] -gt 0); Bytes=$numbers[0]; Speed=$numbers[3]; Eta=$numbers[4]
        StreamId=$id; HasByteCount=$hasBytes; Finished=$finished }
}

function New-OperationProgress([DateTimeOffset]$Now, [ValidateSet('download','setup')][string]$Operation='download') {
    return @{
        Operation=$Operation; Started=$Now; Ended=$null; LastOutput=$Now; LastAdvance=$Now
        SampleAt=$Now; SampleBytes=0.0; Samples=0; Rate=0.0; Bytes=0.0; Total=0.0
        TotalEstimated=$false; StreamId=''; Stage='Waiting'; Step=1; LatestActivity='Waiting for the engine to begin'
    }
}

function Update-OperationProgress {
    param($State, [ValidateSet('Activity','Downloading','Setup','Finishing','Complete','Failed','Cancelled')][string]$Kind,
        [DateTimeOffset]$Now, [double]$Bytes=-1, [double]$Total=0, [bool]$TotalEstimated=$false,
        [string]$Activity='', [int]$Step=0, [string]$StreamId='')
    if ($null -ne $State.Ended) { return }
    $State.LastOutput=$Now
    if ($Activity) { $State.LatestActivity=$Activity }
    switch ($Kind) {
        'Downloading' {
            if ($State.Stage -ne 'Downloading' -or $Bytes -lt $State.Bytes -or $StreamId -cne $State.StreamId) {
                $State.SampleAt=$Now; $State.SampleBytes=$Bytes; $State.Samples=0; $State.Rate=0.0
                $State.LastAdvance=$Now
            } else {
                $seconds=($Now-$State.SampleAt).TotalSeconds
                if ($seconds -ge 1 -and $Bytes -gt $State.SampleBytes) {
                    $State.Rate=($Bytes-$State.SampleBytes)/$seconds
                    $State.Samples++; $State.SampleAt=$Now; $State.SampleBytes=$Bytes
                }
                if ($Bytes -gt $State.Bytes) { $State.LastAdvance=$Now }
            }
            $State.Bytes=[Math]::Max(0,$Bytes); $State.Total=[Math]::Max(0,$Total)
            $State.TotalEstimated=$TotalEstimated; $State.StreamId=$StreamId; $State.Stage='Downloading'; $State.Step=2
            $State.LatestActivity='Receiving current stream'
        }
        'Setup' {
            $State.Step=[Math]::Max(1,[Math]::Min(6,$Step)); $State.Stage='Setup'
            if ($Step -eq 6) { $State.Step=7; $State.Stage='Finishing' }
        }
        'Finishing' { $State.Stage='Finishing'; $State.Step=if ($State.Operation -eq 'setup') { 7 } else { 3 } }
        { $_ -in @('Complete','Failed','Cancelled') } { $State.Stage=$Kind; $State.Ended=$Now; $State.Rate=0.0 }
    }
}

function Get-OperationProgressSnapshot($State, [DateTimeOffset]$Now, [int]$SavedCount=0) {
    # Pure view calculation: no clock reads, filesystem access, or guessed totals.
    $done=$null -ne $State.Ended
    $at=if ($done) { $State.Ended } else { $Now }
    $elapsed=[Math]::Max(0,[Math]::Floor(($at-$State.Started).TotalSeconds))
    $since=if ($State.Stage -eq 'Downloading') { $State.LastAdvance } else { $State.LastOutput }
    $quiet=[Math]::Max(0,[Math]::Floor(($at-$since).TotalSeconds))
    $sampleAge=[Math]::Max(0,[Math]::Floor(($at-$State.LastAdvance).TotalSeconds))
    $status=switch ($State.Stage) {
        'Waiting' { 'Waiting' }; 'Finishing' { 'Finalizing' }; 'Downloading' { 'Active' }; 'Setup' { 'Active' }
        default { $State.Stage }
    }
    if (-not $done -and $State.Stage -eq 'Downloading') {
        if ($quiet -ge 30) { $status='Stalled' } elseif ($quiet -ge 10) { $status='Waiting' }
    } elseif (-not $done -and $State.Stage -in @('Setup','Waiting')) {
        if ($quiet -ge 90) { $status='Stalled' } elseif ($quiet -ge 30) { $status='Waiting' }
    }
    $steps=if ($State.Operation -eq 'setup') { 7 } else { 3 }
    $step=$State.Step; $completed=$step-1
    if ($State.Stage -eq 'Complete') { $step=$steps; $completed=$steps }
    $remaining=$steps-$completed
    $workflow="Step $step of ${steps}: $completed completed; $remaining remaining (includes final verification/cleanup)"
    $files=if ($SavedCount -eq 1) { '1 file reported' } else { "$SavedCount files reported" }
    $counter=if ($State.Total -gt 0) {
        $totalLabel=if ($State.TotalEstimated) { 'estimated total' } else { 'known total' }
        '{0:0} / {1:0} bytes ({2}); {3}' -f $State.Bytes,$State.Total,$totalLabel,$files
    } else { '{0:0} bytes / total unknown; {1}' -f $State.Bytes,$files }
    $rate=if (-not $done -and $State.Stage -eq 'Downloading' -and $quiet -lt 10) { $State.Rate } else { 0.0 }
    $eta=$null; $completion=$null
    $overall='Overall ETA unavailable: remaining streams/items and finalization duration are unknown.'
    if ($done) {
        $etaText='Current-step ETA: not applicable; operation stopped.'
        $overall='Overall operation stopped. Elapsed time and reported-file counts retained.'
    } elseif ($State.Stage -eq 'Finishing') {
        $etaText='Current-step ETA unavailable: verification, merging or cleanup duration is not measured; waiting for engine exit.'
    } elseif ($State.Operation -eq 'setup') {
        $counter='Transfer byte totals unavailable: setup emits stage messages only.'
        $etaText='Current-step ETA unavailable: setup does not expose byte counters; waiting for the next verified stage.'
        $overall='Overall ETA unavailable: setup stages have unequal, unmeasured durations.'
    } elseif ($State.Stage -eq 'Waiting') {
        $etaText='Current-step ETA unavailable: waiting for measured transfer progress.'
    } elseif ($quiet -ge 10) {
        $etaText="Current-stream ETA unavailable: no measured byte advance for ${quiet}s; wait, inspect Activity details, or Cancel."
    } elseif ($State.Total -le 0) {
        $etaText='Current-stream ETA unavailable: total size unknown; waiting for a known total or finalization.'
    } elseif ($State.Samples -lt 1 -or $rate -le 0) {
        $etaText='Current-stream ETA unavailable: collecting measured rate samples.'
    } else {
        $eta=[Math]::Ceiling([Math]::Max(0,$State.Total-$State.Bytes)/$rate)
        # Ignore unreasonable upstream totals rather than overflow the projected clock.
        if ($eta -le 31536000) {
            $completion=$State.LastAdvance.AddSeconds($eta)
            $etaText='Measured current stream estimate ({0:0}s old): ~{1:0}s remaining at last byte sample; local finish ~{2} (may change).' -f $sampleAge,$eta,$completion.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')
            if ($completion -lt $Now) {
                $eta=$null; $completion=$null
                $etaText='Current-stream ETA unavailable: last projection elapsed without new byte telemetry; waiting for a fresh measured sample.'
            }
        } else { $eta=$null; $etaText='Current-stream ETA unavailable: measured estimate exceeds one year; waiting for reliable progress.' }
    }
    $heartbeat=if ($done) { 'Heartbeat stopped; worker exited or operation stopped.' } else {
        'Heartbeat {0} local; {1}; {2}s since {3}; engine still running.' -f $Now.ToLocalTime().ToString('HH:mm:ss'),$status,$quiet,$(if ($State.Stage -eq 'Downloading') { 'byte advance' } else { 'activity' })
    }
    return @{
        State=$status; ElapsedSeconds=$elapsed; QuietSeconds=$quiet; SampleAgeSeconds=$sampleAge; Rate=$rate; EtaSeconds=$eta; CompletionTime=$completion
        WorkflowText=$workflow; CounterText=$counter; EtaText=$etaText; OverallText=$overall
        ElapsedText=('Elapsed ' + [TimeSpan]::FromSeconds($elapsed).ToString()); HeartbeatText=$heartbeat; LatestActivity=$State.LatestActivity
    }
}

function Protect-LogText([string]$text) {
    # Drop URL queries and fragments that can contain signed access tokens.
    $text = [regex]::Replace($text, '(https?://)[^/\s@]+@', '$1[redacted]@', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    return [regex]::Replace($text, '(https?://[^\s?#]+)[?#][^\s]*', '$1?[redacted]', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Get-VidNapDiagnosticError([string]$Line) {
    # Never persist an arbitrary engine message: it may contain URLs, titles,
    # cookies or credentials. Return only fixed technical classifications.
    if($Line -notmatch '(?i)^\s*(ERROR:|Setup failed:)'){return $null}
    $rules=@(
        @('CERTIFICATE_VERIFY_FAILED|certificate verify failed|curl:\s*\(60\)','TLS_CERTIFICATE','TLS','Certificate verification failed; keep verification enabled and check date/time and network trust.'),
        @('SSL_connect|SSL_ERROR_SYSCALL|TLS handshake|curl:\s*\(35\)','TLS_HANDSHAKE','TLS','The TLS handshake failed or closed unexpectedly; server, network or engine compatibility may be involved.'),
        @('cookie database|database is locked','AUTH_DATABASE_LOCKED','Authentication','The selected browser database is unavailable or locked; close it yourself before retrying.'),
        @('DPAPI|decrypt.*cookie|cookie.*decrypt','AUTH_DECRYPTION','Authentication','Browser-cookie decryption failed; keep browser security protections enabled.'),
        @('No space left|not enough space|disk full','DISK_FULL','Storage','The destination has insufficient free space.'),
        @('Permission denied|Access is denied|UnauthorizedAccess','ACCESS_DENIED','Storage','The requested operation was denied; check the selected folder permissions.'),
        @('Requested format is not available','FORMAT_UNAVAILABLE','Format','The source does not offer the selected format.'),
        @('Unsupported URL','EXTRACTOR_UNSUPPORTED','Extractor','The engine did not recognize or support this URL.'),
        @('Unable to extract','EXTRACTOR_PARSE','Extractor','The engine could not parse the page or media information.'),
        @('timed out|timeout','NETWORK_TIMEOUT','Network','The engine reported a timeout; inspect connectivity and service availability.')
    )
    foreach($rule in $rules){
        if($Line -match ('(?i)'+$rule[0])){return @{Code=$rule[1];Category=$rule[2];Summary=$rule[3]}}
    }
    if($Line -match '(?i)HTTP Error\s+(\d{3})'){
        return @{Code=('HTTP_'+$Matches[1]);Category='HTTP';Summary=('The server returned HTTP '+$Matches[1]+'.')}
    }
    if($Line -match '(?i)^\s*(ERROR:|Setup failed:)'){
        return @{Code='ENGINE_UNCLASSIFIED';Category='Engine';Summary='The engine reported an unclassified error; original details remain in the application window.'}
    }
    return $null
}

function New-VidNapDiagnosticJson {
    param(
        [ValidateSet('run-start','engine-error','run-end','interface-error','setup-stage')][string]$Event,
        [Guid]$RunId,
        [ValidateSet('download','setup','startup')][string]$Operation,
        [hashtable]$Details,
        [DateTimeOffset]$Now=[DateTimeOffset]::UtcNow
    )
    $record=[ordered]@{schema=1;utc=$Now.UtcDateTime.ToString('o');event=$Event;runId=$RunId.ToString('N');appVersion='0.3.2';operation=$Operation}
    switch($Event){
        'run-start' {
            $uri=$null;$hostName=$null
            if([Uri]::TryCreate([string]$Details['SourceUrl'],[UriKind]::Absolute,[ref]$uri) -and $uri.Scheme -in @('http','https')){$hostName=$uri.IdnHost.ToLowerInvariant()}
            $record.sourceHost=$hostName
            $record.media=if($Details['Media'] -in @('video','audio')){$Details['Media']}else{'unknown'}
            $record.format=if($Details['Format'] -in @('best','mp4','mkv','webm','original','mp3','m4a','flac','wav','opus')){$Details['Format']}else{'unknown'}
            $record.authMode=if($Details['AuthMode'] -in @('none','browser','cookie-file')){$Details['AuthMode']}else{'unknown'}
            $record.engineManifestTag=if([string]$Details['EngineTag'] -match '^\d{4}\.\d{2}\.\d{2}(?:\.\d{1,12})?$'){$Details['EngineTag']}else{'unknown'}
        }
        'engine-error' {
            $errorInfo=Get-VidNapDiagnosticError ([string]$Details['Line'])
            if($null -eq $errorInfo){return $null}
            $record.errorCode=$errorInfo.Code;$record.category=$errorInfo.Category;$record.summary=$errorInfo.Summary
        }
        'run-end' {
            $record.exitCode=[int]$Details['ExitCode'];$record.cancelled=[bool]$Details['Cancelled']
            $record.reportedFiles=[Math]::Max(0,[int]$Details['FileCount']);$record.progressEvents=[Math]::Max(0,[int]$Details['ProgressCount'])
        }
        'interface-error' {$record.errorCode='INTERFACE_ERROR';$record.hresult=[int]$Details['HResult'];$record.summary='The interface or operation monitor reported an error; inspect the application window.'}
        'setup-stage' {$record.step=[Math]::Max(1,[Math]::Min(6,[int]$Details['Step']))}
    }
    return ($record|ConvertTo-Json -Depth 3 -Compress)
}

function Get-DownloadFailureHint([string]$line) {
    switch -Regex ($line) {
        'CERTIFICATE_VERIFY_FAILED|certificate verify failed|curl:\s*\(60\)' { return 'The secure connection failed certificate verification. Check the Windows date and time or contact your network administrator. Keep certificate verification enabled.' }
        'SSL_connect|SSL_ERROR_SYSCALL|TLS handshake|curl:\s*\(35\)' { return 'A secure connection could not be established. The cause may be the server, network, or downloader compatibility; this message alone cannot identify which. Keep certificate verification enabled.' }
        'Requested format is not available' { return 'This source does not offer the selected format. Try another export choice. Original audio requires an audio-only source; VidNap will not silently convert it.' }
        'cookie database|database is locked' { return 'Save your browser work, close the selected browser yourself, and retry. You can also choose another profile or a cookie file.' }
        'DPAPI|decrypt.*cookie|cookie.*decrypt' { return 'Windows blocked browser-cookie access. Try Firefox or a fresh cookie file. Keep browser security protections enabled.' }
        'No space left|not enough space|disk full' { return 'The destination is out of space. Choose another folder or free space and retry.' }
        'Permission denied|Access is denied|UnauthorizedAccess' { return 'VidNap cannot write to that location. Choose a writable folder and retry.' }
        'HTTP Error 40[13]|sign[ -]?in|log[ -]?in|authentication' { return 'This source may require sign-in or deny downloads. Check browser sign-in settings and your access to the media.' }
        'HTTP Error 404' { return 'The media page was not found. Check the URL and whether the media is still available.' }
        'HTTP Error 429' { return 'The service is limiting requests. Wait before retrying; repeated immediate retries may prolong the limit.' }
        'timed out|timeout|Unable to download webpage|HTTP Error 5\d\d' { return 'Check your connection and retry. Partial downloads are kept so the engine can resume when supported.' }
        'Unsupported URL|Unable to extract|JavaScript|runtime' { return 'Update the engine and retry. This site may require additional supported dependencies or may not currently be supported.' }
    }
    return $null
}
