$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'VidNap.Core.ps1')
$module=Join-Path $root 'VidNap.Analysis.ps1'
if(Test-Path -LiteralPath $module){. $module}
$script:checks=0
function Assert-Analysis($condition,[string]$label){if(-not $condition){throw ('FAIL: '+$label)};$script:checks++}
function Assert-AnalysisCode([scriptblock]$Action,[string]$Code){
    $message='';try{& $Action|Out-Null}catch{$message=$_.Exception.Message}
    Assert-Analysis ($message.StartsWith($Code,[StringComparison]::Ordinal)) ('rejects with '+$Code)
}
Assert-Analysis ($null -ne (Get-Command ConvertFrom-VidNapAnalysis -ErrorAction SilentlyContinue)) 'bounded analysis parser exists'
$video=@{format_id='v1';ext='mp4';vcodec='avc1.640028';acodec='none';width=1920;height=1080;fps=30;filesize=1000;url='https://media.invalid/private?sig=synthetic'}
$audio=@{format_id='a1';ext='m4a';vcodec='none';acodec='mp4a.40.2';language='en'}
$muxed=@{format_id='mux';ext='mp4';vcodec='h264';acodec='aac';width=1280;height=720;filesize_approx=2500}
$fixture=@{
    id='fixture-id';title='<b>Example</b>';duration=60
    webpage_url='https://www.youtube.com/watch?v=fixture&token=synthetic'
    formats=@($video,$audio,$muxed);requested_formats=@($video,$audio)
    subtitles=@{en=@(@{ext='vtt';url='https://captions.invalid/private'})}
    automatic_captions=@{es=@(@{ext='vtt'})}
    http_headers=@{Authorization='synthetic-secret-must-not-survive'}
}
$json=$fixture|ConvertTo-Json -Depth 10
$result=ConvertFrom-VidNapAnalysis $json
Assert-Analysis ($result.Kind -eq 'Media' -and $result.SchemaVersion -eq 1) 'media schema is explicit'
Assert-Analysis ($result.MediaId -ceq 'fixture-id' -and $result.Title -ceq '<b>Example</b>') 'metadata remains plain data'
Assert-Analysis ($result.DurationSeconds -eq 60) 'duration is retained'
Assert-Analysis ($result.SourceHost -ceq 'www.youtube.com') 'only source host is normalized'
Assert-Analysis ($result.Formats.Count -eq 3) 'available formats are retained'
Assert-Analysis ($result.Formats[0].VideoCodec -eq 'h264' -and $result.Formats[1].AudioCodec -eq 'aac') 'codec aliases are normalized'
Assert-Analysis ($result.Formats[0].SizeKind -eq 'Exact' -and $result.Formats[0].SizeBytes -eq 1000) 'exact size evidence'
Assert-Analysis ($result.Formats[1].SizeKind -eq 'Unknown' -and $null -eq $result.Formats[1].SizeBytes) 'unknown size is not invented'
Assert-Analysis ($result.Formats[2].SizeKind -eq 'Estimated' -and $result.Formats[2].SizeBytes -eq 2500) 'estimated size remains labeled'
Assert-Analysis (($result.RequestedFormatIds -join '+') -ceq 'v1+a1') 'engine selected stream IDs are retained'
Assert-Analysis ($result.Captions.Count -eq 2 -and @($result.Captions|Where-Object Automatic).Count -eq 1) 'caption provenance is explicit'
$normalized=$result|ConvertTo-Json -Depth 12
Assert-Analysis ($normalized -notmatch 'synthetic-secret|sig=|token=|media\.invalid|captions\.invalid|youtube\.com/watch') 'normalized metadata excludes URLs and headers'
$large=$fixture.Clone()
$large.automatic_captions=@{}
$captionUrl='https://captions.invalid/fixture?private-marker='+('x'*11KB)
$captionVariants=@(foreach($ext in @('json3','srv1','srv2','srv3','ttml','vtt')){@{ext=$ext;url=$captionUrl}})
for($i=0;$i -lt 176;$i++){$large.automatic_captions['x-fixture-'+$i]=$captionVariants}
$largeJson=$large|ConvertTo-Json -Depth 10 -Compress
Assert-Analysis ($largeJson.Length -gt 10MB -and $largeJson.Length -lt 16MB) 'fixture reproduces a large but bounded caption catalog'
$largeResult=ConvertFrom-VidNapAnalysis $largeJson
Assert-Analysis ($largeResult.Captions.Count -eq 177 -and ($largeResult.RequestedFormatIds -join '+') -ceq 'v1+a1') 'large analysis retains captions and the original selected streams'
Assert-Analysis (($largeResult|ConvertTo-Json -Depth 12) -notmatch 'private-marker|captions\.invalid') 'large analysis never returns caption URLs'
$selection=@{Media='video';Format='mp4';FormatIds=@('v1','a1');HasFfmpeg=$true}
$selectionArguments=@(Get-VidNapSelectionArguments $result $selection)
Assert-Analysis (($selectionArguments -join '|') -ceq "-f|all[format_id='v1']+all[format_id='a1']|--merge-output-format|mp4|--remux-video|mp4") 'exact selection uses literal format-ID filters'
$best=@(Get-VidNapSelectionArguments $result @{Media='video';Format='best';HasFfmpeg=$true})
Assert-Analysis (($best -join '|') -ceq '-f|bestvideo*+bestaudio/best') 'automatic best preset is preserved'
$combined=@(Get-VidNapSelectionArguments $result @{Media='video';Format='best';HasFfmpeg=$false})
Assert-Analysis (($combined -join '|') -ceq '-f|best') 'existing no-FFmpeg combined fallback stays explicit'
Assert-AnalysisCode {Get-VidNapSelectionArguments $result @{Media='video';Format='best';FormatIds=@('missing');HasFfmpeg=$true}} 'VIDNAP_ANALYSIS_SELECTION'
Assert-AnalysisCode {Get-VidNapSelectionArguments $result @{Media='video';Format='best';FormatIds=@('v1');HasFfmpeg=$true}} 'VIDNAP_ANALYSIS_SELECTION'
Assert-AnalysisCode {Get-VidNapSelectionArguments $result @{Media='video';Format='best';FormatIds=@('v1','a1');HasFfmpeg=$false}} 'VIDNAP_ANALYSIS_SELECTION'
Assert-AnalysisCode {Get-VidNapSelectionArguments $result @{Media='audio';Format='original';FormatIds=@('mux');HasFfmpeg=$true}} 'VIDNAP_ANALYSIS_SELECTION'
$original=@(Get-VidNapSelectionArguments $result @{Media='audio';Format='original';FormatIds=@('a1');HasFfmpeg=$false})
Assert-Analysis (($original -join '|') -ceq "-f|all[format_id='a1']") 'original audio never gains conversion arguments'
foreach($bad in @('null','[]','{}','{invalid')){
    Assert-AnalysisCode {ConvertFrom-VidNapAnalysis $bad} 'VIDNAP_ANALYSIS_INVALID'
}
Assert-AnalysisCode {ConvertFrom-VidNapAnalysis ('x'*(16MB+1))} 'VIDNAP_ANALYSIS_LIMIT'
$largeUnicode='{"id":"unicode","description":"'+(([string][char]0x00e9)*(8MB+1))+'"}'
Assert-AnalysisCode {ConvertFrom-VidNapAnalysis $largeUnicode} 'VIDNAP_ANALYSIS_LIMIT'
$hostile=@{id='x';title='x';formats=@(@{format_id='--exec unsafe';ext='mp4';vcodec='h264';acodec='aac'})}|ConvertTo-Json -Depth 6
Assert-AnalysisCode {ConvertFrom-VidNapAnalysis $hostile} 'VIDNAP_ANALYSIS_INVALID'
$long=@{id='x';title=('x'*1100);formats=@()}|ConvertTo-Json
$bounded=ConvertFrom-VidNapAnalysis $long
Assert-Analysis ($bounded.Title.Length -eq 1024 -and $bounded.TitleTruncated) 'long title is bounded and disclosed'
$playlist=@{_type='playlist';id='playlist-fixture';title='Batch';entries=@(@{id='one';title='One'},@{id='two';title='Two'})}|ConvertTo-Json -Depth 6
Assert-AnalysisCode {ConvertFrom-VidNapAnalysis $playlist} 'VIDNAP_ANALYSIS_PLAYLIST_CONSENT'
$batch=ConvertFrom-VidNapAnalysis $playlist $true
Assert-Analysis ($batch.Kind -eq 'Playlist' -and $batch.Items.Count -eq 2) 'explicitly permitted playlist entries are bounded data'
Assert-Analysis (($batch.Items|ForEach-Object MediaId) -join ',' -ceq 'one,two') 'playlist order is preserved'
$unknown=@{id='x';title='x';duration='NaN';formats=@(@{format_id='a';acodec='opus';vcodec='none';filesize=-1;filesize_approx=0})}|ConvertTo-Json -Depth 6
$unknownResult=ConvertFrom-VidNapAnalysis $unknown
Assert-Analysis ($null -eq $unknownResult.DurationSeconds -and $unknownResult.Formats[0].SizeKind -eq 'Unknown') 'invalid numeric evidence stays unknown'
$hugeSize=@{id='x';title='x';formats=@(@{format_id='a';acodec='opus';vcodec='none';filesize=[double][long]::MaxValue})}|ConvertTo-Json -Depth 6
Assert-Analysis ((ConvertFrom-VidNapAnalysis $hugeSize).Formats[0].SizeKind -eq 'Unknown') 'unrepresentable byte counts do not overflow'
foreach($reserved in @('all','best','bestaudio','worst','mp4','hls:high')){
    $reservedSource=@{id='reserved';title='Fixture';formats=@(
        @{format_id=$reserved;ext='mp4';vcodec='h264';acodec='aac'},
        @{format_id='other';ext='mp4';vcodec='h264';acodec='aac'}
    )}|ConvertTo-Json -Depth 6
    $reservedAnalysis=ConvertFrom-VidNapAnalysis $reservedSource
    $reservedArgs=@(Get-VidNapSelectionArguments $reservedAnalysis @{Media='video';Format='best';FormatIds=@($reserved);HasFfmpeg=$true})
    Assert-Analysis ($reservedArgs[1] -ceq ("all[format_id='"+$reserved+"']")) 'exact ID cannot become a selector command'
}
Write-Output "PASS: $script:checks backend analysis checks; bounded synthetic metadata, quality arguments, privacy, playlist consent and unknown totals."
