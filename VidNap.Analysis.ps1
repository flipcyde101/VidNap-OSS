Set-StrictMode -Version Latest

function Get-VidNapDataValue($Value, [string]$Name, $Default=$null) {
    if ($null -eq $Value) { return $Default }
    if ($Value -is [Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
    } else {
        $property = $Value.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
    }
    return $Default
}

function Get-VidNapFiniteNumber($Value) {
    if ($null -eq $Value -or $Value -is [bool]) { return $null }
    [double]$number = 0
    $text = [Convert]::ToString($Value,[Globalization.CultureInfo]::InvariantCulture)
    if (-not [double]::TryParse($text,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -or
        [double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0) { return $null }
    return $number
}

function Get-VidNapCodecName($Value) {
    if ($null -eq $Value -or $Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or $Value -ieq 'none') { return $null }
    $codec = $Value.ToLowerInvariant()
    if ($codec.Length -gt 128 -or $codec -notmatch '^[a-z0-9_.-]+$') { return $null }
    switch -Regex ($codec) {
        '^(avc1|avc3|h264)(\.|$)' { return 'h264' }
        '^(mp4a|aac)(\.|$)' { return 'aac' }
        '^(hev1|hvc1|hevc)(\.|$)' { return 'hevc' }
        '^(vp09|vp9)(\.|$)' { return 'vp9' }
        '^(av01|av1)(\.|$)' { return 'av1' }
        default { return $codec }
    }
}

function ConvertTo-VidNapFormat($Value) {
    $id = Get-VidNapDataValue $Value 'format_id'
    if ($id -isnot [string] -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$') {
        throw 'VIDNAP_ANALYSIS_INVALID: A source format identifier is unsupported.'
    }
    $exact = Get-VidNapFiniteNumber (Get-VidNapDataValue $Value 'filesize')
    $estimated = Get-VidNapFiniteNumber (Get-VidNapDataValue $Value 'filesize_approx')
    $size = $null; $kind = 'Unknown'
    if ($null -ne $exact -and $exact -gt 0 -and $exact -le [long]::MaxValue -and [Math]::Floor($exact) -eq $exact) {
        $size = [long]$exact; $kind = 'Exact'
    } elseif ($null -ne $estimated -and $estimated -gt 0 -and $estimated -lt [long]::MaxValue) {
        $size = [long][Math]::Ceiling($estimated); $kind = 'Estimated'
    }
    $extension = [string](Get-VidNapDataValue $Value 'ext' '')
    if ($extension -and $extension -notmatch '^[A-Za-z0-9]{1,12}$') { throw 'VIDNAP_ANALYSIS_INVALID: A source extension is unsupported.' }
    $language = [string](Get-VidNapDataValue $Value 'language' '')
    if ($language.Length -gt 64) { throw 'VIDNAP_ANALYSIS_INVALID: Source language metadata is too long.' }
    return [pscustomobject]@{
        FormatId=$id; Extension=$extension.ToLowerInvariant()
        VideoCodec=Get-VidNapCodecName (Get-VidNapDataValue $Value 'vcodec')
        AudioCodec=Get-VidNapCodecName (Get-VidNapDataValue $Value 'acodec')
        Width=Get-VidNapFiniteNumber (Get-VidNapDataValue $Value 'width')
        Height=Get-VidNapFiniteNumber (Get-VidNapDataValue $Value 'height')
        FrameRate=Get-VidNapFiniteNumber (Get-VidNapDataValue $Value 'fps')
        Language=$language; SizeBytes=$size; SizeKind=$kind
        AudioBitrateKbps=Get-VidNapFiniteNumber (Get-VidNapDataValue $Value 'abr')
    }
}

function ConvertTo-VidNapMediaAnalysis($Value) {
    $id = Get-VidNapDataValue $Value 'id'
    if ($id -isnot [string] -or [string]::IsNullOrWhiteSpace($id) -or $id.Length -gt 256) {
        throw 'VIDNAP_ANALYSIS_INVALID: Source identity is missing or invalid.'
    }
    $title = [string](Get-VidNapDataValue $Value 'title' '')
    $truncated = $title.Length -gt 1024
    if ($truncated) { $title = $title.Substring(0,1024) }
    $rawFormats = Get-VidNapDataValue $Value 'formats'
    $formats = @(if ($null -ne $rawFormats) { $rawFormats })
    if ($formats.Count -gt 4096) { throw 'VIDNAP_ANALYSIS_LIMIT: Too many source formats.' }
    $normalized = [Collections.Generic.List[object]]::new()
    $identifiers = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $formats) {
        $format = ConvertTo-VidNapFormat $item
        if (-not $identifiers.Add($format.FormatId)) { throw 'VIDNAP_ANALYSIS_INVALID: Duplicate source format identifiers.' }
        $normalized.Add($format)
    }
    $requested = [Collections.Generic.List[string]]::new()
    $rawRequested = Get-VidNapDataValue $Value 'requested_formats'
    foreach ($item in @($rawRequested)) {
        if ($null -eq $item) { continue }
        $formatId = [string](Get-VidNapDataValue $item 'format_id' '')
        if (-not $identifiers.Contains($formatId) -or $requested.Contains($formatId)) {
            throw 'VIDNAP_ANALYSIS_INVALID: Selected stream evidence does not match available formats.'
        }
        $requested.Add($formatId)
    }
    if ($requested.Count -gt 16) { throw 'VIDNAP_ANALYSIS_LIMIT: Too many selected streams.' }
    if ($requested.Count -eq 0) {
        $combinedId = [string](Get-VidNapDataValue $Value 'format_id' '')
        if ($identifiers.Contains($combinedId)) { $requested.Add($combinedId) }
    }
    $captions = [Collections.Generic.List[object]]::new()
    foreach ($source in @(@{Name='subtitles';Automatic=$false},@{Name='automatic_captions';Automatic=$true})) {
        $tracks = Get-VidNapDataValue $Value $source.Name
        if ($null -eq $tracks) { continue }
        if ($tracks -isnot [Management.Automation.PSCustomObject]) { throw 'VIDNAP_ANALYSIS_INVALID: Caption metadata is invalid.' }
        foreach ($property in $tracks.PSObject.Properties) {
            if ($captions.Count -ge 256 -or $property.Name.Length -gt 64) { throw 'VIDNAP_ANALYSIS_LIMIT: Too many caption tracks.' }
            $types = @($property.Value | ForEach-Object { [string](Get-VidNapDataValue $_ 'ext' '') } | Where-Object { $_ -match '^[A-Za-z0-9]{1,12}$' } | Sort-Object -Unique)
            $captions.Add([pscustomobject]@{Language=$property.Name;Automatic=$source.Automatic;Formats=$types})
        }
    }
    $hostName = ''
    $page = [string](Get-VidNapDataValue $Value 'webpage_url' (Get-VidNapDataValue $Value 'original_url' ''))
    $uri = $null
    if ([Uri]::TryCreate($page,[UriKind]::Absolute,[ref]$uri) -and $uri.Scheme -in @('https','http')) { $hostName=$uri.DnsSafeHost.ToLowerInvariant() }
    $duration = Get-VidNapFiniteNumber (Get-VidNapDataValue $Value 'duration')
    if ($null -ne $duration -and $duration -eq 0) { $duration=$null }
    return [pscustomobject]@{
        SchemaVersion=1;Kind='Media';MediaId=$id;Title=$title;TitleTruncated=$truncated
        DurationSeconds=$duration;SourceHost=$hostName;Formats=@($normalized.ToArray())
        AudioTracks=@($normalized.ToArray()|Where-Object {$null -ne $_.AudioCodec -and $null -eq $_.VideoCodec})
        RequestedFormatIds=@($requested.ToArray());Captions=@($captions.ToArray())
    }
}

function Get-VidNapAnalysisMetadataLimit {
    # Keep within VidNapBackendProcess's existing ceiling. Caption catalogs
    # can exceed 8 MiB even when analyzing a single video.
    return 16MB
}

function ConvertFrom-VidNapAnalysis([string]$Json,[bool]$AllowPlaylist=$false) {
    $limit=Get-VidNapAnalysisMetadataLimit
    if ($null -eq $Json -or $Json.Length -gt $limit -or [Text.Encoding]::UTF8.GetByteCount($Json) -gt $limit) {
        throw 'VIDNAP_ANALYSIS_LIMIT: Source metadata exceeds the supported size.'
    }
    try { $value=ConvertFrom-Json -InputObject $Json -ErrorAction Stop } catch {
        throw 'VIDNAP_ANALYSIS_INVALID: Source metadata is not valid JSON.'
    }
    if ($value -isnot [Management.Automation.PSCustomObject]) { throw 'VIDNAP_ANALYSIS_INVALID: Source metadata must be an object.' }
    $type = [string](Get-VidNapDataValue $value '_type' '')
    if ($type -in @('playlist','multi_video')) {
        if (-not $AllowPlaylist) { throw 'VIDNAP_ANALYSIS_PLAYLIST_CONSENT: Playlist analysis requires explicit consent.' }
        $entries = @(Get-VidNapDataValue $value 'entries')
        if ($entries.Count -gt 500) { throw 'VIDNAP_ANALYSIS_LIMIT: Analyze the playlist in smaller pages.' }
        $items = @($entries|ForEach-Object { ConvertTo-VidNapMediaAnalysis $_ })
        return [pscustomobject]@{SchemaVersion=1;Kind='Playlist';Items=$items;Count=$items.Count}
    }
    return ConvertTo-VidNapMediaAnalysis $value
}

function Get-VidNapSelectionArguments($Analysis,$Selection) {
    if ((Get-VidNapDataValue $Analysis 'Kind') -cne 'Media') { throw 'VIDNAP_ANALYSIS_SELECTION: Select one analyzed media item.' }
    $media=[string](Get-VidNapDataValue $Selection 'Media' '')
    $format=[string](Get-VidNapDataValue $Selection 'Format' '')
    $ffmpeg=Get-VidNapDataValue $Selection 'HasFfmpeg' $false
    if ($ffmpeg -isnot [bool]) { throw 'VIDNAP_ANALYSIS_SELECTION: Tool availability must be explicit.' }
    try { $arguments=@(Get-ExportArguments $media $format $ffmpeg) } catch {
        throw 'VIDNAP_ANALYSIS_SELECTION: This export is unsupported or requires FFmpeg.'
    }
    $rawIds=Get-VidNapDataValue $Selection 'FormatIds'
    $ids=@(if($null -ne $rawIds){$rawIds})
    if ($ids.Count -eq 0) { return $arguments }
    if ($ids.Count -gt 2 -or ($media -eq 'audio' -and $ids.Count -ne 1) -or ($ids.Count -gt 1 -and -not $ffmpeg)) {
        throw 'VIDNAP_ANALYSIS_SELECTION: The selected stream combination is unsupported.'
    }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $chosen=@(foreach($id in $ids){
        if ($id -isnot [string] -or -not $seen.Add($id)) { throw 'VIDNAP_ANALYSIS_SELECTION: Selected format identifiers must be distinct.' }
        $match=@($Analysis.Formats|Where-Object {$_.FormatId -ceq $id})
        if ($match.Count -ne 1) { throw 'VIDNAP_ANALYSIS_SELECTION: A selected format is unavailable. Analyze again.' }
        $match[0]
    })
    $video=@($chosen|Where-Object {$null -ne $_.VideoCodec})
    $audio=@($chosen|Where-Object {$null -ne $_.AudioCodec})
    if ($media -eq 'video') {
        $sourceHasAudio=@($Analysis.Formats|Where-Object {$null -ne $_.AudioCodec}).Count -gt 0
        if ($video.Count -ne 1 -or $audio.Count -gt 1 -or ($sourceHasAudio -and $audio.Count -eq 0)) {
            throw 'VIDNAP_ANALYSIS_SELECTION: The selection would omit or duplicate media tracks.'
        }
        if ($format -eq 'mp4' -and ($video[0].VideoCodec -ne 'h264' -or ($audio.Count -and $audio[0].AudioCodec -ne 'aac'))) {
            throw 'VIDNAP_ANALYSIS_SELECTION: MP4 compatible requires H.264 and AAC sources.'
        }
        if ($format -eq 'webm' -and @($chosen|Where-Object {$_.Extension -ne 'webm'}).Count) {
            throw 'VIDNAP_ANALYSIS_SELECTION: WebM requires WebM source streams.'
        }
    } elseif ($audio.Count -ne 1 -or ($format -eq 'original' -and $video.Count -ne 0)) {
        throw 'VIDNAP_ANALYSIS_SELECTION: Original audio requires an audio-only source.'
    }
    # IDs are restricted to a small alphabet above. Quote them in an
    # equality filter so names such as all/best/mp4 remain literal IDs,
    # not yt-dlp selector keywords or extension aliases.
    $arguments[1]=(@($ids|ForEach-Object {"all[format_id='$_']"})) -join '+'
    return $arguments
}

function Get-VidNapFrameRate($Value) {
    $text=[string]$Value
    if ($text.Contains('/')) {
        $parts=$text.Split('/')
        if ($parts.Count -ne 2) { return $null }
        $a=Get-VidNapFiniteNumber $parts[0];$b=Get-VidNapFiniteNumber $parts[1]
        if ($null -eq $a -or $null -eq $b -or $b -eq 0) { return $null }
        return $a/$b
    }
    return Get-VidNapFiniteNumber $Value
}

function Test-VidNapOutput($Expected,[string]$ProbeJson,[long]$FileBytes) {
    $codes=[Collections.Generic.List[string]]::new()
    $difference=$null;$actualDuration=$null
    $requiresVideo=Get-VidNapDataValue $Expected 'RequireVideo'
    $requiresAudio=Get-VidNapDataValue $Expected 'RequireAudio'
    $expectedInvalid=($requiresVideo -isnot [bool] -or $requiresAudio -isnot [bool])
    if (-not $expectedInvalid) {
        $expectedInvalid=(-not $requiresVideo -and -not $requiresAudio)
        if ($requiresVideo -and -not (Get-VidNapCodecName (Get-VidNapDataValue $Expected 'VideoCodec'))) { $expectedInvalid=$true }
        if ($requiresAudio -and -not (Get-VidNapCodecName (Get-VidNapDataValue $Expected 'AudioCodec'))) { $expectedInvalid=$true }
    }
    $containerPolicy=Get-VidNapDataValue $Expected 'Container'
    if ($containerPolicy -isnot [string] -or $containerPolicy -notin @('best','original','mp4','mkv','webm','mp3','m4a','flac','wav','opus','aac','ogg','mov')) {
        $expectedInvalid=$true
    }
    foreach ($field in @('Width','Height','FrameRate','DurationSeconds')) {
        $raw=Get-VidNapDataValue $Expected $field
        if ($null -ne $raw) {
            $number=Get-VidNapFiniteNumber $raw
            if ($null -eq $number -or $number -le 0) { $expectedInvalid=$true }
            if ($field -in @('Width','Height') -and $null -ne $number -and [Math]::Floor($number) -ne $number) { $expectedInvalid=$true }
        }
    }
    if ($expectedInvalid) { $codes.Add('EXPECTED_INVALID') }
    if ($FileBytes -le 0) { $codes.Add('FILE_EMPTY') }
    if ($null -eq $ProbeJson -or $ProbeJson.Length -gt 1MB -or [Text.Encoding]::UTF8.GetByteCount($ProbeJson) -gt 1MB) {
        $codes.Add('PROBE_LIMIT')
    }
    $probe=$null
    if ($codes.Count -eq 0) {
        try { $probe=ConvertFrom-Json -InputObject $ProbeJson -ErrorAction Stop } catch { $codes.Add('PROBE_INVALID') }
        if ($probe -isnot [Management.Automation.PSCustomObject]) {
            if (-not $codes.Contains('PROBE_INVALID')) { $codes.Add('PROBE_INVALID') }
        }
    }
    if ($codes.Count -eq 0) {
        $streams=@(Get-VidNapDataValue $probe 'streams')
        if ($streams.Count -gt 64) { $codes.Add('PROBE_LIMIT') }
        $video=@($streams|Where-Object {(Get-VidNapDataValue $_ 'codec_type') -ceq 'video'})
        $audio=@($streams|Where-Object {(Get-VidNapDataValue $_ 'codec_type') -ceq 'audio'})
        if ($video.Count -eq 0 -and $audio.Count -eq 0) { $codes.Add('PROBE_NO_MEDIA') }
        if ((Get-VidNapDataValue $Expected 'RequireVideo' $false) -and $video.Count -eq 0) { $codes.Add('VIDEO_MISSING') }
        if ((Get-VidNapDataValue $Expected 'RequireAudio' $false) -and $audio.Count -eq 0) { $codes.Add('AUDIO_MISSING') }
        foreach ($kind in @('Video','Audio')) {
            $expectedCodec=Get-VidNapCodecName (Get-VidNapDataValue $Expected ($kind+'Codec'))
            $actual=@(if($kind -eq 'Video'){$video}else{$audio})
            if ($expectedCodec -and ($actual.Count -eq 0 -or (Get-VidNapCodecName (Get-VidNapDataValue $actual[0] 'codec_name')) -cne $expectedCodec)) {
                $codes.Add(($kind.ToUpperInvariant()+'_CODEC'))
            }
        }
        foreach ($dimension in @('Width','Height')) {
            $wanted=Get-VidNapFiniteNumber (Get-VidNapDataValue $Expected $dimension)
            if ($null -ne $wanted -and $wanted -gt 0) {
                $observed=if($video.Count){Get-VidNapFiniteNumber (Get-VidNapDataValue $video[0] $dimension.ToLowerInvariant())}else{$null}
                if ($null -eq $observed -or $wanted -ne $observed) { $codes.Add(('VIDEO_'+$dimension.ToUpperInvariant())) }
            }
        }
        $wantedRate=Get-VidNapFiniteNumber (Get-VidNapDataValue $Expected 'FrameRate')
        if ($null -ne $wantedRate -and $wantedRate -gt 0) {
            $rate=if($video.Count){Get-VidNapFrameRate (Get-VidNapDataValue $video[0] 'avg_frame_rate')}else{$null}
            if ($null -eq $rate -or [Math]::Abs($rate-$wantedRate) -gt 0.05) { $codes.Add('VIDEO_RATE') }
        }
        $container=[string](Get-VidNapDataValue $Expected 'Container' '')
        $formatInfo=Get-VidNapDataValue $probe 'format'
        $names=([string](Get-VidNapDataValue $formatInfo 'format_name' '')).ToLowerInvariant().Split(',')
        $containerMatches=$true
        switch ($container.ToLowerInvariant()) {
            {$_ -in @('mp4','m4a')} {
                $containerMatches=($names -contains 'mov' -or $names -contains 'mp4')
                $brand=[string](Get-VidNapDataValue (Get-VidNapDataValue $formatInfo 'tags') 'major_brand' '')
                if ($brand.Trim() -ceq 'qt') { $containerMatches=$false }
            }
            'mkv' {$containerMatches=$names -contains 'matroska'}
            'webm' {
                $containerMatches=$names -contains 'webm'
                if (@($video|Where-Object {(Get-VidNapCodecName (Get-VidNapDataValue $_ 'codec_name')) -notin @('vp8','vp9','av1')}).Count -or
                    @($audio|Where-Object {(Get-VidNapCodecName (Get-VidNapDataValue $_ 'codec_name')) -notin @('opus','vorbis')}).Count) {$containerMatches=$false}
            }
            'opus' {$containerMatches=$names -contains 'ogg'}
            {$_ -in @('','best','original')} {}
            default {$containerMatches=$names -contains $container.ToLowerInvariant()}
        }
        if (-not $containerMatches) { $codes.Add('CONTAINER') }
        $sourceDuration=Get-VidNapFiniteNumber (Get-VidNapDataValue $Expected 'DurationSeconds')
        $actualDuration=Get-VidNapFiniteNumber (Get-VidNapDataValue $formatInfo 'duration')
        if ($null -ne $sourceDuration -and $sourceDuration -gt 0) {
            if ($null -eq $actualDuration -or $actualDuration -le 0) { $codes.Add('DURATION_MISSING') } else {
                $difference=[Math]::Abs($sourceDuration-$actualDuration)
                if ($difference -gt [Math]::Max(2,$sourceDuration*0.01)) { $codes.Add('DURATION_MISMATCH') }
            }
        } else { $codes.Add('SOURCE_DURATION_UNKNOWN') }
    }
    $failed=@($codes|Where-Object {$_ -ne 'SOURCE_DURATION_UNKNOWN'}).Count -gt 0
    $status=if($failed){'Failed'}elseif($codes.Contains('SOURCE_DURATION_UNKNOWN')){'Indeterminate'}else{'Validated'}
    return [pscustomobject]@{Status=$status;CanComplete=(-not $failed);Codes=@($codes.ToArray());DurationSeconds=$actualDuration;DurationDifferenceSeconds=$difference}
}

function Get-VidNapProbeArguments([string]$MediaFile) {
    if ([string]::IsNullOrWhiteSpace($MediaFile) -or $MediaFile -notmatch '^[A-Za-z]:[\\/]' -or
        $MediaFile.Substring(2).IndexOfAny([char[]]':*?"<>|') -ge 0 -or $MediaFile.IndexOf([char]0) -ge 0) {
        throw 'VIDNAP_PROBE_PATH: Probe only an absolute local media file.'
    }
    $path=[IO.Path]::GetFullPath($MediaFile)
    return @('-v','error','-protocol_whitelist','file,pipe','-show_entries',
        'format=duration,format_name:format_tags=major_brand:stream=codec_name,codec_type,width,height,avg_frame_rate',
        '-of','json','-i',$path)
}
