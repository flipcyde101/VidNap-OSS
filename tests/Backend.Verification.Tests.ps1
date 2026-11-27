$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
$module=Join-Path $root 'VidNap.Analysis.ps1'
if(Test-Path -LiteralPath $module){. $module}
$script:checks=0
function Assert-Verification($condition,[string]$label){if(-not $condition){throw ('FAIL: '+$label)};$script:checks++}
Assert-Verification ($null -ne (Get-Command Test-VidNapOutput -ErrorAction SilentlyContinue)) 'evidence-based output verifier exists'
function New-ProbeFixture {
    param([string]$VideoCodec='h264',[string]$AudioCodec='aac',[string]$Duration='60.02',[int]$Width=1920,[int]$Height=1080,[string]$Rate='30/1',[string]$Container='mov,mp4,m4a,3gp,3g2,mj2',[string]$Brand='isom')
    $streams=@()
    if($VideoCodec){$streams+=@{codec_type='video';codec_name=$VideoCodec;width=$Width;height=$Height;avg_frame_rate=$Rate}}
    if($AudioCodec){$streams+=@{codec_type='audio';codec_name=$AudioCodec}}
    return @{streams=$streams;format=@{format_name=$Container;duration=$Duration;tags=@{major_brand=$Brand}}}|ConvertTo-Json -Depth 6
}
$expected=@{RequireVideo=$true;RequireAudio=$true;VideoCodec='avc1';AudioCodec='mp4a';Container='mp4';DurationSeconds=60;Width=1920;Height=1080;FrameRate=30}
$valid=New-ProbeFixture
$result=Test-VidNapOutput $expected $valid 100
Assert-Verification ($result.Status -eq 'Validated' -and $result.CanComplete) 'valid selected tracks and duration pass'
Assert-Verification ([Math]::Abs($result.DurationDifferenceSeconds-0.02) -lt 0.00001) 'duration difference is measured'
$cases=@(
    @{Name='empty output';Json=$valid;Bytes=0;Code='FILE_EMPTY'},
    @{Name='negative byte count';Json=$valid;Bytes=-1;Code='FILE_EMPTY'},
    @{Name='malformed probe';Json='{bad';Bytes=100;Code='PROBE_INVALID'},
    @{Name='null probe';Json='null';Bytes=100;Code='PROBE_INVALID'},
    @{Name='no selected audio';Json=(New-ProbeFixture -AudioCodec '');Bytes=100;Code='AUDIO_MISSING'},
    @{Name='no selected video';Json=(New-ProbeFixture -VideoCodec '');Bytes=100;Code='VIDEO_MISSING'},
    @{Name='wrong video codec';Json=(New-ProbeFixture -VideoCodec 'hevc');Bytes=100;Code='VIDEO_CODEC'},
    @{Name='wrong audio codec';Json=(New-ProbeFixture -AudioCodec 'opus');Bytes=100;Code='AUDIO_CODEC'},
    @{Name='reduced width';Json=(New-ProbeFixture -Width 1280);Bytes=100;Code='VIDEO_WIDTH'},
    @{Name='reduced height';Json=(New-ProbeFixture -Height 720);Bytes=100;Code='VIDEO_HEIGHT'},
    @{Name='wrong frame rate';Json=(New-ProbeFixture -Rate '24/1');Bytes=100;Code='VIDEO_RATE'},
    @{Name='unknown required rate';Json=(New-ProbeFixture -Rate '0/0');Bytes=100;Code='VIDEO_RATE'},
    @{Name='wrong container';Json=(New-ProbeFixture -Container 'html');Bytes=100;Code='CONTAINER'},
    @{Name='QuickTime is not MP4';Json=(New-ProbeFixture -Brand 'qt  ');Bytes=100;Code='CONTAINER'},
    @{Name='large duration difference';Json=(New-ProbeFixture -Duration '100');Bytes=100;Code='DURATION_MISMATCH'},
    @{Name='just outside tolerance';Json=(New-ProbeFixture -Duration '62.01');Bytes=100;Code='DURATION_MISMATCH'},
    @{Name='missing output timing';Json=(New-ProbeFixture -Duration 'N/A');Bytes=100;Code='DURATION_MISSING'}
)
foreach($case in $cases){
    $actual=Test-VidNapOutput $expected $case.Json $case.Bytes
    Assert-Verification ($actual.Status -eq 'Failed' -and -not $actual.CanComplete -and $actual.Codes -contains $case.Code) $case.Name
}
Assert-Verification ((Test-VidNapOutput $expected (New-ProbeFixture -Duration '61.99') 100).CanComplete) 'documented timing tolerance is accepted'
Assert-Verification ((Test-VidNapOutput $expected (New-ProbeFixture -Rate '30000/1001') 100).CanComplete) 'equivalent nominal frame rate is tolerated'
$noTiming=@{RequireVideo=$true;RequireAudio=$true;VideoCodec='h264';AudioCodec='aac';Container='mp4';DurationSeconds=$null}
$limited=Test-VidNapOutput $noTiming $valid 100
Assert-Verification ($limited.Status -eq 'Indeterminate' -and $limited.CanComplete -and $limited.Codes -contains 'SOURCE_DURATION_UNKNOWN') 'unknown source timing is explicitly limited verification'
Assert-Verification (-not (Test-VidNapOutput $noTiming (New-ProbeFixture -AudioCodec '') 100).CanComplete) 'missing source timing never excuses missing audio'
$audioExpected=@{RequireVideo=$false;RequireAudio=$true;AudioCodec='mp3';Container='mp3';DurationSeconds=60}
$audioProbe=New-ProbeFixture -VideoCodec '' -AudioCodec 'mp3' -Container 'mp3'
Assert-Verification ((Test-VidNapOutput $audioExpected $audioProbe 100).CanComplete) 'explicit audio conversion validates requested output codec'
$oversize=Test-VidNapOutput $expected ('x'*(1MB+1)) 100
Assert-Verification ($oversize.Status -eq 'Failed' -and $oversize.Codes -contains 'PROBE_LIMIT') 'probe payload is bounded'
foreach($invalidExpected in @($null,@{},@{RequireVideo='false';RequireAudio=$true},@{RequireVideo=$false;RequireAudio=$false},@{RequireVideo=$true;RequireAudio=$false;VideoCodec='bad codec'})){
    $invalidResult=Test-VidNapOutput $invalidExpected $valid 100
    Assert-Verification (-not $invalidResult.CanComplete -and $invalidResult.Codes -contains 'EXPECTED_INVALID') 'missing or malformed selection evidence cannot complete'
}
foreach($field in @('Width','Height','FrameRate','DurationSeconds')){
    foreach($bad in @('invalid',-1,[double]::NaN,[double]::PositiveInfinity)){
        $invalidExpected=$expected.Clone();$invalidExpected[$field]=$bad
        $invalidResult=Test-VidNapOutput $invalidExpected $valid 100
        Assert-Verification (-not $invalidResult.CanComplete -and $invalidResult.Codes -contains 'EXPECTED_INVALID') ('malformed '+$field+' cannot disable verification')
    }
}
foreach($missingContainer in @($null,'','not-a-container')){
    $invalidExpected=$expected.Clone();$invalidExpected.Container=$missingContainer
    Assert-Verification (-not (Test-VidNapOutput $invalidExpected $valid 100).CanComplete) 'container policy is explicit'
}
$probeArgs=@(Get-VidNapProbeArguments 'D:\fixture\video.mp4')
Assert-Verification (($probeArgs -join '|') -match '\|-protocol_whitelist\|file,pipe\|') 'probe disables network protocols'
Assert-Verification ($probeArgs[-2] -ceq '-i' -and $probeArgs[-1] -ceq 'D:\fixture\video.mp4') 'probe input is one quoted local argument'
$invalidInput=''
try{Get-VidNapProbeArguments 'https://example.invalid/media.mp4'|Out-Null}catch{$invalidInput=$_.Exception.Message}
Assert-Verification ($invalidInput.StartsWith('VIDNAP_PROBE_PATH')) 'remote probe inputs are rejected'
Write-Output "PASS: $script:checks backend verification checks; selected tracks, codecs, dimensions, frame rate, container, timing and network-disabled probe arguments."
