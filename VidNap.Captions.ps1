Set-StrictMode -Version Latest

function ConvertFrom-VidNapCaptionTime([string]$Time) {
    if($Time -notmatch '^(?:(\d{2,3}):)?([0-5]\d):([0-5]\d)[,.](\d{3})$'){throw 'VIDNAP_CAPTION_TIMING: Invalid cue timestamp.'}
    $hours=if($Matches[1]){[long]$Matches[1]}else{0}
    return (($hours*3600+[long]$Matches[2]*60+[long]$Matches[3])*1000+[long]$Matches[4])
}

function ConvertTo-VidNapCaptionTime([long]$Milliseconds,[string]$Separator='.') {
    return ('{0:00}:{1:00}:{2:00}{3}{4:000}' -f [Math]::Floor($Milliseconds/3600000),([Math]::Floor($Milliseconds/60000)%60),([Math]::Floor($Milliseconds/1000)%60),$Separator,($Milliseconds%1000))
}

function ConvertFrom-VidNapCaption {
    param([string]$Text,[ValidateSet('srt','vtt')][string]$Format,[ValidateSet('SourceManual','SourceAutomatic','LocalGenerated')][string]$Provenance)
    if([Text.Encoding]::UTF8.GetByteCount($Text) -gt 4MB){throw 'VIDNAP_CAPTION_LIMIT: Caption text exceeds 4 MiB.'}
    $textValue=$Text.TrimStart([char]0xFEFF).Replace("`r`n","`n").Replace("`r","`n")
    if($Format -eq 'vtt'){
        if($textValue -notmatch '^WEBVTT(?:[^\n]*)\n'){throw 'VIDNAP_CAPTION_PARSE: Missing WEBVTT header.'}
        $textValue=$textValue.Substring($textValue.IndexOf("`n")+1)
    }
    $count=0
    foreach($block in [regex]::Split($textValue.Trim(),"\n[\t ]*\n+")){
        if(-not $block.Trim()){continue}
        if($Format -eq 'vtt' -and $block -match '^(NOTE(?:\s|$)|STYLE(?:\s|$)|REGION(?:\s|$))'){continue}
        $lines=$block.Split("`n")
        $index=if($lines[0] -match '-->'){0}else{1}
        if($lines.Count -le $index -or $lines[$index] -notmatch '^([^\s]+)\s+-->\s+([^\s]+)(?:[\t ].*)?$'){throw 'VIDNAP_CAPTION_PARSE: Invalid cue block.'}
        $start=ConvertFrom-VidNapCaptionTime $Matches[1];$end=ConvertFrom-VidNapCaptionTime $Matches[2]
        if($end -le $start){throw 'VIDNAP_CAPTION_TIMING: Cue end must follow its start.'}
        if($lines.Count -le $index+1){throw 'VIDNAP_CAPTION_PARSE: Empty cue text.'}
        $content=($lines[($index+1)..($lines.Count-1)] -join "`n")
        # Cue markup is never rendered as HTML or XAML. Decode once only.
        $content=[regex]::Replace($content,'<[^>]*>','')
        $content=[Net.WebUtility]::HtmlDecode($content).Trim()
        if($content.Length -gt 16384 -or $content -match '[\x00-\x08\x0B\x0C\x0E-\x1F]'){throw 'VIDNAP_CAPTION_LIMIT: Cue text is unsupported or too large.'}
        if(-not $content){continue}
        if(++$count -gt 20000){throw 'VIDNAP_CAPTION_LIMIT: Too many cues.'}
        [pscustomobject]@{StartMs=$start;EndMs=$end;Text=$content;Provenance=$Provenance}
    }
}

function ConvertTo-VidNapCaption {
    param([object[]]$Cues,[ValidateSet('txt','srt','vtt')][string]$Format,[bool]$IncludeTimestamps=$false)
    if($Cues.Count -gt 20000){throw 'VIDNAP_CAPTION_LIMIT: Too many cues.'}
    $builder=[Text.StringBuilder]::new()
    if($Format -eq 'vtt'){[void]$builder.Append("WEBVTT`n`n")}
    $number=0
    foreach($cue in $Cues){
        $start=Get-VidNapDataValue $cue 'StartMs' $null;$end=Get-VidNapDataValue $cue 'EndMs' $null
        $textValue=Get-VidNapDataValue $cue 'Text' $null
        if($start -isnot [ValueType] -or $end -isnot [ValueType] -or $null -eq (Get-VidNapFiniteNumber $start) -or
            $null -eq (Get-VidNapFiniteNumber $end) -or [double]$start -ne [Math]::Floor([double]$start) -or
            [double]$end -ne [Math]::Floor([double]$end) -or $end -le $start -or $end -gt 3599999999 -or
            $textValue -isnot [string] -or $textValue.Length -gt 16384 -or $textValue -match '[\x00-\x08\x0B\x0C\x0E-\x1F]|\n[\t ]*\r?\n|-->' -or -not $textValue.Trim()){
            throw 'VIDNAP_CAPTION_CUE: Invalid export cue.'
        }
        $number++
        if($Format -eq 'txt'){
            if($IncludeTimestamps){[void]$builder.Append('['+(ConvertTo-VidNapCaptionTime $start)+'] ')}
            [void]$builder.Append($textValue+"`n")
        }else{
            $separator=if($Format -eq 'srt'){','}else{'.'}
            if($Format -eq 'srt'){[void]$builder.Append($number.ToString()+"`n")}
            [void]$builder.Append((ConvertTo-VidNapCaptionTime $start $separator)+' --> '+(ConvertTo-VidNapCaptionTime $end $separator)+"`n")
            # Escape literal text so reopening never interprets it as cue markup.
            [void]$builder.Append([Net.WebUtility]::HtmlEncode($textValue).Replace('&#39;',"'").Replace('&quot;','"')+"`n`n")
        }
        if($builder.Length -gt 4MB){throw 'VIDNAP_CAPTION_LIMIT: Export exceeds its bounded size.'}
    }
    return $builder.ToString()
}

function Export-VidNapCaption([object[]]$Cues,[string]$Format,[string]$Path,[bool]$IncludeTimestamps=$false) {
    $directory=ConvertTo-VidNapLocalDirectory ([IO.Path]::GetDirectoryName($Path))
    if([IO.Path]::GetPathRoot($directory) -ine 'D:\' -or [IO.Path]::GetExtension($Path) -ine ('.'+$Format) -or
        [IO.Path]::GetFileName($Path) -match '[:*?"<>|]' -or -not [IO.Directory]::Exists($directory)){throw 'VIDNAP_CAPTION_PATH: Choose a local D: output file with the matching extension.'}
    $textValue=ConvertTo-VidNapCaption $Cues $Format $IncludeTimestamps
    $stream=$null
    try{
        $stream=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
        $bytes=[Text.UTF8Encoding]::new($false,$true).GetBytes($textValue);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)
    }catch [IO.IOException]{
        if($null -eq $stream -and [IO.File]::Exists($Path)){throw 'VIDNAP_CAPTION_EXISTS: Choose a different filename; existing output was preserved.'}
        throw 'VIDNAP_CAPTION_WRITE: Export could not finish. Inspect the destination; no fallback was selected.'
    }finally{if($stream){$stream.Dispose()}}
    return $Path
}

function Get-VidNapCaptionArguments([object[]]$Tracks,[string]$Language,[bool]$AllowAutomatic=$false) {
    if($Language -notmatch '^[A-Za-z0-9_-]{1,40}$'){throw 'VIDNAP_CAPTION_LANGUAGE: Invalid language identifier.'}
    $manual=@($Tracks|Where-Object {$_.Language -ceq $Language -and -not $_.Automatic})
    $auto=@($Tracks|Where-Object {$_.Language -ceq $Language -and $_.Automatic})
    if(-not $manual.Count -and -not $auto.Count){throw 'VIDNAP_CAPTION_LANGUAGE: The selected language is unavailable.'}
    if(-not $manual.Count -and -not $AllowAutomatic){throw 'VIDNAP_CAPTION_CONSENT: Source automatic captions require explicit consent.'}
    $flag=if($manual.Count){'--write-subs'}else{'--write-auto-subs'}
    return @('--skip-download',$flag,'--sub-langs',('^'+[regex]::Escape($Language)+'$'),'--sub-format','vtt/srt','--no-overwrites')
}

function New-VidNapTranscriptionRequest([string]$MediaFile,[string]$ModelFile,[string]$OutputDirectory,$Policy) {
    if((Get-VidNapDataValue $Policy 'Approved' $false) -cne $true){throw 'VIDNAP_TRANSCRIPTION_APPROVAL: A separately approved local tool/model is required.'}
    $tool=[string](Get-VidNapDataValue $Policy 'ToolPath' '')
    foreach($path in @($MediaFile,$ModelFile,$tool)){
        if(-not [IO.File]::Exists($path)){throw 'VIDNAP_TRANSCRIPTION_PREREQUISITE: Local media, model or tool is missing. Nothing will be downloaded.'}
        try{Assert-VidNapRegularFile $path|Out-Null}catch{throw 'VIDNAP_TRANSCRIPTION_PREREQUISITE: Local prerequisite is not a supported regular D: file.'}
    }
    foreach($pair in @(@($tool,'ToolSha256'),@($ModelFile,'ModelSha256'))){
        $expected=[string](Get-VidNapDataValue $Policy $pair[1] '')
        if($expected -notmatch '^[A-Fa-f0-9]{64}$' -or (Get-VidNapFileSha256 $pair[0]) -ine $expected){throw 'VIDNAP_TRANSCRIPTION_HASH: Local prerequisite does not match its approved hash.'}
    }
    if(-not (Get-VidNapDataValue $Policy 'ModelLicense' '') -or -not (Get-VidNapDataValue $Policy 'ModelSource' '')){throw 'VIDNAP_TRANSCRIPTION_PREREQUISITE: Model source and license must be disclosed.'}
    if((Get-VidNapDataValue $Policy 'HasAudio' $false) -cne $true){throw 'VIDNAP_TRANSCRIPTION_AUDIO: No verified audio track is available.'}
    $folder=ConvertTo-VidNapLocalDirectory $OutputDirectory
    if([IO.Path]::GetPathRoot($folder) -ine 'D:\' -or -not [IO.Directory]::Exists($folder)){throw 'VIDNAP_TRANSCRIPTION_PREREQUISITE: Choose an existing D: output folder.'}
    $duration=Get-VidNapFiniteNumber (Get-VidNapDataValue $Policy 'DurationSeconds' $null)
    $available=Get-VidNapFiniteNumber (Get-VidNapDataValue $Policy 'AvailableBytes' $null)
    # Mono 16-kHz PCM scratch is 32 kB/s; reserve an additional 64 MiB.
    $required=64MB
    if($duration){$required+=[Math]::Ceiling($duration*32000)}
    if($null -eq $available -or $available -lt $required){throw 'VIDNAP_TRANSCRIPTION_SPACE: Insufficient verified scratch capacity.'}
    $scratch=Join-Path $folder ('.vidnap-transcription-'+[Guid]::NewGuid().ToString('N'))
    $wav=Join-Path $scratch 'audio.wav';$prefix=Join-Path $scratch 'transcript'
    return [pscustomobject]@{
        ToolPath=$tool;ToolSha256=[string]$Policy.ToolSha256;ModelFile=$ModelFile;ModelSha256=[string]$Policy.ModelSha256
        ModelLicense=[string]$Policy.ModelLicense;ModelSource=[string]$Policy.ModelSource
        Threads=2;ScratchDirectory=$scratch;OutputDirectory=$folder;AudioFile=$wav;OutputPrefix=$prefix;RequiredBytes=$required
        DurationSeconds=$duration;Provenance='LocalGenerated';StartsWork=$false;DownloadsModel=$false
        PrepareAudioArguments=@('-nostdin','-hide_banner','-loglevel','error','-protocol_whitelist','file,pipe','-i',$MediaFile,'-vn','-ac','1','-ar','16000','-c:a','pcm_s16le','-n',$wav)
        Arguments=@('-m',$ModelFile,'-f',$wav,'-t','2','-osrt','-of',$prefix)
    }
}
