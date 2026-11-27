. (Join-Path $PSScriptRoot 'Backend.TestSupport.ps1')
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'VidNap.Storage.ps1')
. (Join-Path $root 'VidNap.Analysis.ps1')
if(Test-Path -LiteralPath (Join-Path $root 'VidNap.Captions.ps1')){. (Join-Path $root 'VidNap.Captions.ps1')}
Assert-Backend ($null -ne (Get-Command New-VidNapTranscriptionRequest -ErrorAction SilentlyContinue)) 'local transcription request backend exists'
$fixture=New-BackendTestDirectory $root
try{
    $media=Join-Path $fixture 'media.wav';$model=Join-Path $fixture 'model.bin';$tool=Join-Path $fixture 'whisper-cli.exe'
    foreach($file in @($media,$model,$tool)){[IO.File]::WriteAllText($file,'synthetic fixture, never executed')}
    $policy=@{ToolPath=$tool;ToolSha256=(Get-BackendTestHash $tool);ModelSha256=(Get-BackendTestHash $model);ModelLicense='fixture-only';ModelSource='local fixture';HasAudio=$true;Approved=$true;AvailableBytes=1GB}
    $request=New-VidNapTranscriptionRequest $media $model $fixture $policy
    Assert-Backend ($request.Threads -eq 2 -and $request.Provenance -eq 'LocalGenerated' -and $request.Arguments -contains '-osrt') 'request is local, bounded and labeled generated'
    Assert-Backend ($request.ToolPath -ceq $tool -and -not $request.StartsWork -and -not $request.DownloadsModel) 'building a request never starts inference or downloads a model'
    Assert-Backend ($request.ScratchDirectory.StartsWith($fixture+'\') -and $request.PrepareAudioArguments -contains 'file,pipe') 'audio scratch is task-owned and media protocols are local only'
    $bad=$policy.Clone();$bad.Approved=$false
    Assert-BackendCode {New-VidNapTranscriptionRequest $media $model $fixture $bad} 'VIDNAP_TRANSCRIPTION_APPROVAL'
    $bad=$policy.Clone();$bad.ModelSha256='0'*64
    Assert-BackendCode {New-VidNapTranscriptionRequest $media $model $fixture $bad} 'VIDNAP_TRANSCRIPTION_HASH'
    $bad=$policy.Clone();$bad.HasAudio=$false
    Assert-BackendCode {New-VidNapTranscriptionRequest $media $model $fixture $bad} 'VIDNAP_TRANSCRIPTION_AUDIO'
    $bad=$policy.Clone();$bad.AvailableBytes=1
    Assert-BackendCode {New-VidNapTranscriptionRequest $media $model $fixture $bad} 'VIDNAP_TRANSCRIPTION_SPACE'
    Assert-BackendCode {New-VidNapTranscriptionRequest $media (Join-Path $fixture 'missing.bin') $fixture $policy} 'VIDNAP_TRANSCRIPTION_PREREQUISITE'
    Assert-Backend (-not [IO.Directory]::Exists($request.ScratchDirectory)) 'request validation has no scratch creation side effects'
    Write-Output "PASS: $script:BackendChecks transcription adapter checks; synthetic prerequisites only, no model installation or inference."
}finally{Remove-BackendTestDirectory $fixture $root}
