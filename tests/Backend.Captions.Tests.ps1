. (Join-Path $PSScriptRoot 'Backend.TestSupport.ps1')
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'VidNap.Storage.ps1')
. (Join-Path $root 'VidNap.Analysis.ps1')
if(Test-Path -LiteralPath (Join-Path $root 'VidNap.Captions.ps1')){. (Join-Path $root 'VidNap.Captions.ps1')}
Assert-Backend ($null -ne (Get-Command ConvertFrom-VidNapCaption -ErrorAction SilentlyContinue)) 'caption backend exists'
$fixture=New-BackendTestDirectory $root
try{
    $srt="1`r`n00:00:01,000 --> 00:00:02,500`r`nHello <b>world</b> &amp; friends`r`n`r`n2`r`n00:00:02,000 --> 00:00:04,000`r`nUnicode: $([char]0x4E2D)$([char]0x6587)`r`n"
    $cues=@(ConvertFrom-VidNapCaption $srt 'srt' 'SourceManual')
    Assert-Backend ($cues.Count -eq 2 -and $cues[0].StartMs -eq 1000 -and $cues[0].EndMs -eq 2500) 'SRT timing is preserved and overlapping cues are allowed'
    Assert-Backend ($cues[0].Text -ceq 'Hello world & friends' -and $cues[0].Provenance -ceq 'SourceManual') 'markup is text-normalized with provenance'
    foreach($format in @('srt','vtt')){
        $rendered=ConvertTo-VidNapCaption $cues $format
        $round=@(ConvertFrom-VidNapCaption $rendered $format 'SourceManual')
        Assert-Backend ($round.Count -eq 2 -and $round[0].StartMs -eq 1000 -and $round[0].EndMs -eq 2500 -and $round[1].Text -ceq $cues[1].Text) ($format+' round trip')
    }
    $vtt="WEBVTT`n`nNOTE ignored comment`nnot a cue`n`nlabel`n00:01.000 --> 00:02.500 align:start`n<v Speaker>Hello <00:01.500>again</v>`n"
    $web=@(ConvertFrom-VidNapCaption $vtt 'vtt' 'SourceAutomatic')
    Assert-Backend ($web.Count -eq 1 -and $web[0].Text -ceq 'Hello again') 'VTT labels, cue settings and inline timestamps parsed safely'
    Assert-Backend ((ConvertTo-VidNapCaption $cues 'txt') -match 'Hello world & friends') 'TXT export keeps readable words'
    Assert-BackendCode {ConvertFrom-VidNapCaption "1`n00:00:03,000 --> 00:00:02,000`nx" 'srt' 'SourceManual'} 'VIDNAP_CAPTION_TIMING'
    Assert-BackendCode {ConvertFrom-VidNapCaption "1`n00:61:00,000 --> 00:62:00,000`nx" 'srt' 'SourceManual'} 'VIDNAP_CAPTION_TIMING'
    Assert-BackendCode {ConvertFrom-VidNapCaption 'not captions' 'srt' 'SourceManual'} 'VIDNAP_CAPTION_PARSE'
    Assert-BackendCode {ConvertFrom-VidNapCaption ('x'*(4MB+1)) 'vtt' 'SourceManual'} 'VIDNAP_CAPTION_LIMIT'
    Assert-BackendCode {ConvertTo-VidNapCaption @([pscustomobject]@{StartMs=0;EndMs=1;Text="x`n`n1`n00:00:05,000 --> 00:00:06,000`ninjected"}) 'srt'} 'VIDNAP_CAPTION_CUE'
    $file=Join-Path $fixture 'transcript.vtt'
    Export-VidNapCaption $cues 'vtt' $file|Out-Null
    $hash=Get-BackendTestHash $file
    Assert-BackendCode {Export-VidNapCaption $cues 'vtt' $file} 'VIDNAP_CAPTION_EXISTS'
    Assert-Backend ((Get-BackendTestHash $file) -ceq $hash) 'export never overwrites existing bytes'
    Assert-BackendCode {Get-VidNapCaptionArguments @([pscustomobject]@{Language='en';Automatic=$true}) 'en' $false} 'VIDNAP_CAPTION_CONSENT'
    $captionArguments=Get-VidNapCaptionArguments @([pscustomobject]@{Language='en';Automatic=$true}) 'en' $true
    Assert-Backend ($captionArguments -contains '--write-auto-subs' -and $captionArguments -notcontains '--cookies-from-browser') 'automatic caption consent is explicit, no browser consent inferred'
    Assert-BackendCode {Get-VidNapCaptionArguments @() 'en' $false} 'VIDNAP_CAPTION_LANGUAGE'
    Write-Output "PASS: $script:BackendChecks caption checks; parsing, Unicode, provenance, timing, round trips, consent and no-overwrite export."
}finally{Remove-BackendTestDirectory $fixture $root}
