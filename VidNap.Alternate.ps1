param([string]$Url, [string]$Folder, [string]$Ffprobe, [string]$YtDlp, [switch]$LibraryOnly)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'VidNap.Core.ps1')

function Test-AlternatePublicAddress([System.Net.IPAddress]$Address) {
    if ($Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $b = $Address.GetAddressBytes()
    if ($b[0] -in @(0,10,127) -or $b[0] -ge 224) { return $false }
    if (($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) -or
        ($b[0] -eq 169 -and $b[1] -eq 254) -or
        ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or
        ($b[0] -eq 192 -and ($b[1] -eq 168 -or $b[1] -eq 0 -or ($b[1] -eq 88 -and $b[2] -eq 99))) -or
        ($b[0] -eq 198 -and ($b[1] -in @(18,19) -or ($b[1] -eq 51 -and $b[2] -eq 100))) -or
        ($b[0] -eq 203 -and $b[1] -eq 0 -and $b[2] -eq 113)) { return $false }
    return $true
}

function Get-AlternateUri([string]$Value) {
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        $uri.HostNameType -ne [UriHostNameType]::Dns -or $uri.Host -notmatch '\.') {
        throw 'Alternate transfer needs a public direct HTTPS media URL without credentials, query parameters or fragments.'
    }
    if ([IO.Path]::GetExtension($uri.AbsolutePath).ToLowerInvariant() -notin @('.mp4','.webm','.mkv','.mov')) {
        throw 'Alternate transfer accepts direct MP4, WebM, MKV or MOV files, not website pages.'
    }
    return $uri
}

function Get-AlternateCurlArguments([Uri]$Uri, [string]$Address, [string]$PartialPath) {
    if (-not (Test-AlternatePublicAddress ([Net.IPAddress]::Parse($Address)))) { throw 'Non-public address rejected.' }
    return @('--disable','--globoff','--silent','--fail','--proto','=https','--proto-redir','=https',
        '--proxy','','--noproxy','*','--ipv4','--resolve',($Uri.DnsSafeHost + ':443:' + $Address),
        '--connect-timeout','15','--max-time','600','--max-filesize','1073741824','--retry','0',
        '--output',$PartialPath,'--write-out','%{http_code}','--url',$Uri.AbsoluteUri)
}

function Get-AlternateSafeError([string]$Message) {
    $safe = @(
        'Alternate transfer needs a public direct HTTPS media URL without credentials, query parameters or fragments.',
        'Alternate transfer accepts direct MP4, WebM, MKV or MOV files, not website pages.',
        'Choose an existing short local destination folder.',
        'Alternate transfer requires at least 1.125 GB free disk space for its 1 GB pilot limit.',
        'Alternate transfer requires Windows curl and installed FFprobe.',
        'Alternate transfer requires curl 8.4.0 or newer for bounded-size transfers.',
        'Public host lookup timed out.', 'Alternate transfer requires a public IPv4 destination.',
        'Alternate operation timed out.', 'Unexpectedly large diagnostic output.',
        'Alternate transfer exceeds the 1 GB pilot limit.',
        'Alternate HTTPS transfer failed or returned a redirect/non-success response. Certificate checks remain enabled; no automatic retry was made.',
        'Downloaded file is empty or exceeds the pilot limit.',
        'Downloaded data is not a supported standalone video file.',
        'Downloaded file does not contain a video stream.'
    )
    if ($safe -ccontains $Message) { return $Message }
    return 'The operation could not be completed safely. Check destination access, available tools and your connection.'
}

function Invoke-AlternateProcess([string]$Executable, [string[]]$Arguments, [int]$TimeoutSeconds, [string]$ProgressPath = '') {
    if (-not ('VidNapProcessRunner' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'VidNap.ProcessRunner.cs') }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = ($Arguments | ForEach-Object { Quote-Argument $_ }) -join ' '
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $runner = New-Object VidNapProcessRunner
    $lines = New-Object System.Collections.Generic.List[string]
    $watch = [Diagnostics.Stopwatch]::StartNew(); $lastProgress = -1
    try {
        $runner.Start($info)
        while (-not $runner.IsComplete) {
            if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { $runner.Stop(); throw 'Alternate operation timed out.' }
            $line = ''
            while ($runner.Output.TryDequeue([ref]$line)) {
                if ($lines.Count -ge 256) { $runner.Stop(); throw 'Unexpectedly large diagnostic output.' }
                $lines.Add($line)
            }
            if ($ProgressPath -and [int]$watch.Elapsed.TotalSeconds -gt $lastProgress) {
                $lastProgress = [int]$watch.Elapsed.TotalSeconds
                $length = if (Test-Path -LiteralPath $ProgressPath) { (Get-Item -LiteralPath $ProgressPath).Length } else { 0 }
                if ($length -gt 1GB) { $runner.Stop(); throw 'Alternate transfer exceeds the 1 GB pilot limit.' }
                $averageSpeed = ([double]$length / [Math]::Max(0.001, $watch.Elapsed.TotalSeconds)).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
                [Console]::Out.WriteLine('VIDNAP_PROGRESS|' + $length + '|NA|NA|' + $averageSpeed + '|NA')
            }
            Start-Sleep -Milliseconds 100
        }
        $line = ''; while ($runner.Output.TryDequeue([ref]$line)) { if ($lines.Count -lt 256) { $lines.Add($line) } }
        return [pscustomobject]@{ ExitCode = $runner.ExitCode; Text = ($lines -join "`n") }
    } finally { $runner.Dispose() }
}

if ($LibraryOnly) { return }
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
try {
    $uri = Get-AlternateUri $Url
    $destination = [IO.Path]::GetFullPath($Folder)
    if ($destination.StartsWith('\\') -or -not (Test-Path -LiteralPath $destination -PathType Container) -or $destination.Length -gt 170) { throw 'Choose an existing short local destination folder.' }
    $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($destination))
    if ($drive.AvailableFreeSpace -lt 1152MB) { throw 'Alternate transfer requires at least 1.125 GB free disk space for its 1 GB pilot limit.' }
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path -LiteralPath $curl -PathType Leaf) -or -not (Test-Path -LiteralPath $Ffprobe -PathType Leaf)) { throw 'Alternate transfer requires Windows curl and installed FFprobe.' }
    $capability = Invoke-AlternateProcess $curl @('--disable','--version') 10
    if ($capability.ExitCode -ne 0 -or $capability.Text -notmatch '^curl (\d+\.\d+\.\d+)' -or [version]$Matches[1] -lt [version]'8.4.0') { throw 'Alternate transfer requires curl 8.4.0 or newer for bounded-size transfers.' }
    $dns = [Net.Dns]::GetHostAddressesAsync($uri.DnsSafeHost)
    if (-not $dns.Wait(10000)) { throw 'Public host lookup timed out.' }
    $ipv4 = @($dns.Result | Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork })
    if ($ipv4.Count -eq 0 -or @($ipv4 | Where-Object { -not (Test-AlternatePublicAddress $_) }).Count -gt 0) { throw 'Alternate transfer requires a public IPv4 destination.' }
    $name = 'VidNap-' + [Guid]::NewGuid().ToString('N')
    $partial = Join-Path $destination ($name + '.part')
    $final = Join-Path $destination ($name + [IO.Path]::GetExtension($uri.AbsolutePath).ToLowerInvariant())
    # GUID-owned file is created exclusively. No existing output is overwritten.
    $stream = [IO.File]::Open($partial, [IO.FileMode]::CreateNew); $stream.Dispose()
    $result = Invoke-AlternateProcess $curl (Get-AlternateCurlArguments $uri $ipv4[0].ToString() $partial) 615 $partial
    if ($result.ExitCode -ne 0 -or $result.Text.Trim() -ne '200') { throw 'Alternate HTTPS transfer failed or returned a redirect/non-success response. Certificate checks remain enabled; no automatic retry was made.' }
    if ((Get-Item -LiteralPath $partial).Length -le 0 -or (Get-Item -LiteralPath $partial).Length -gt 1GB) { throw 'Downloaded file is empty or exceeds the pilot limit.' }
    [Console]::Out.WriteLine('VIDNAP_FINISH|verifying')
    $probe = Invoke-AlternateProcess $Ffprobe @('-v','error','-protocol_whitelist','file','-format_whitelist','mov,matroska,webm','-show_entries','stream=codec_type:format=duration','-of','json',$partial) 30
    if ($probe.ExitCode -ne 0) { throw 'Downloaded data is not a supported standalone video file.' }
    $media = $probe.Text | ConvertFrom-Json
    if (@($media.streams | Where-Object { $_.codec_type -eq 'video' }).Count -eq 0) { throw 'Downloaded file does not contain a video stream.' }
    [IO.File]::Move($partial, $final)
    [Console]::Out.WriteLine('VIDNAP_FILE|' + $final)
    exit 0
} catch {
    # Never print tool output, URLs or native exceptions containing sensitive input.
    [Console]::Error.WriteLine('ERROR: Alternate transfer stopped. ' + (Get-AlternateSafeError $_.Exception.Message))
    [Console]::Error.WriteLine('Use a public direct HTTPS video file, check free space and installed tools. Attempt-owned .part files remain; no output was marked complete.')
    exit 1
}
