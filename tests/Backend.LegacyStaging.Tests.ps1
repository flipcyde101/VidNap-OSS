$ErrorActionPreference='Stop'
$sourcePath=Join-Path (Split-Path $PSScriptRoot -Parent) 'VidNap.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Entrypoint parse failed'}
foreach($name in @('Assert-LegacyRegularPath','New-LegacyAttempt','Publish-LegacyOutput','Get-LegacyTransferArguments','Start-Download','Receive-OperationLine','Complete-Operation')){
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true)
    if(-not $node){throw "Missing entrypoint function: $name"}
    . ([scriptblock]::Create($node.Extent.Text))
}
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'VidNap.Core.ps1')
$root=Join-Path $PSScriptRoot ('legacy-fixture-'+[guid]::NewGuid().ToString('N'))
$final=Join-Path $root 'final'
[IO.Directory]::CreateDirectory($final) | Out-Null
$sentinel=[byte[]](0,255,13,10,42)
[IO.File]::WriteAllBytes((Join-Path $final 'old.part'),$sentinel)
$a=New-LegacyAttempt $root $final
$b=New-LegacyAttempt $root $final
if($a.Stage -eq $b.Stage){throw 'Retry reused staging'}
$file=Join-Path $a.Stage 'result.mp4'
[IO.File]::WriteAllBytes($file,$sentinel)
# Cancel and failure deliberately do not invoke promotion.
if(-not [IO.File]::Exists($file)){throw 'Attempt not retained'}
$target=Publish-LegacyOutput $a $file
if([Convert]::ToBase64String([IO.File]::ReadAllBytes($target)) -cne [Convert]::ToBase64String($sentinel)){throw 'Promotion changed bytes'}
$collision=Join-Path $b.Stage 'result.mp4'
[IO.File]::WriteAllBytes($collision,[byte[]](99))
$rejected=$false
try { Publish-LegacyOutput $b $collision } catch { $rejected=$true }
if(-not $rejected -or -not [IO.File]::Exists($collision)){throw 'Collision did not retain stage'}
if([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $final 'old.part'))) -cne [Convert]::ToBase64String($sentinel)){throw 'Old partial changed'}
$script:lines = [Collections.Generic.List[string]]::new()
function Add-Log($Line) { $script:lines.Add([string]$Line) }
function Set-UnknownProgress($Value) {}
function Set-Running($Value) {}
foreach($name in @('PhaseText','ProgressText','StatusText','ProgressBar')){Set-Variable $name ([pscustomobject]@{Text='';Value=0})}
foreach($case in @('cancel','failure')){
    $script:legacyAttempt=New-LegacyAttempt $root $final
    $retained=Join-Path $script:legacyAttempt.Stage ($case+'.mp4')
    [IO.File]::WriteAllBytes($retained,$sentinel)
    $script:operation='download';$script:alternateTransfer=$false;$script:cancelRequested=($case -eq 'cancel');$script:failureHint=$null
    $script:reportedFiles=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $script:savedFiles=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    Receive-OperationLine ('VIDNAP_FILE|'+$retained)
    Receive-OperationLine ('VIDNAP_FILE|'+$retained)
    Complete-Operation $(if($case -eq 'cancel'){0}else{1})
    if($script:reportedFiles.Count -ne 1 -or $script:savedFiles.Count -ne 0 -or -not [IO.File]::Exists($retained) -or [IO.File]::Exists((Join-Path $final ($case+'.mp4')))){throw 'Terminal event flow published or lost retained staging'}
    if(-not $script:lines.Contains(('Staged files retained at: '+$script:legacyAttempt.Stage))){throw 'ASSERT: recovery location absent'}
}
Write-Output 'PASS: legacy isolated staging and promotion (fixtures retained)'
$script:cancelRequested=$false;$script:failureHint=$null
foreach($case in @('success','collision')){
    $script:legacyAttempt=New-LegacyAttempt $final $final
    $candidate=Join-Path $script:legacyAttempt.Stage 'event-success.mp4'
    [IO.File]::WriteAllBytes($candidate,$sentinel)
    $script:reportedFiles=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $script:savedFiles=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    Receive-OperationLine ('VIDNAP_FILE|'+$candidate)
    Complete-Operation 0
    if($case -eq 'success'){
        if($script:savedFiles.Count -ne 1 -or [IO.Directory]::Exists($script:legacyAttempt.Stage) -or $PhaseText.Text -cne 'Complete'){throw 'ASSERT: non-Alternate success did not publish and remove its empty stage'}
    }else{
        if($script:savedFiles.Count -ne 0 -or -not [IO.File]::Exists($candidate) -or $PhaseText.Text -cne 'Failed'){throw 'ASSERT: event collision did not fail and retain stage'}
    }
    if([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $final 'event-success.mp4'))) -cne [Convert]::ToBase64String($sentinel)){throw 'ASSERT: event promotion changed destination bytes'}
}
Write-Output 'PASS: non-Alternate Complete-Operation success and collision'
$script:process=$null;$FolderBox=[pscustomobject]@{Text='C:\synthetic-not-accessed'}
function Get-Tools {throw 'ASSERT: tool lookup preceded destination rejection'}
Start-Download
if($StatusText.Text -notmatch 'D:'){throw 'ASSERT: non-D destination was not rejected first'}
Write-Output 'PASS: non-D rejected before tool or file lookup'
$flags=@(Get-LegacyTransferArguments)
if($flags.Count -ne 3 -or $flags[0] -cne '--retries' -or $flags[1] -cne '0' -or $flags[2] -cne '--abort-on-unavailable-fragments'){throw 'ASSERT: legacy unsafe transfer flags'}
$script:legacyAttempt=New-LegacyAttempt $root $final
$held=Join-Path $script:legacyAttempt.Stage 'timeout.mp4';[IO.File]::WriteAllBytes($held,$sentinel)
$script:reportedFiles=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:savedFiles=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:process=[pscustomobject]@{Output=[Collections.Concurrent.ConcurrentQueue[string]]::new();ExitCode=0;Reads=0;Marker=$held;Disposed=$false}
$script:process | Add-Member ScriptProperty CompletionState { $this.Reads++;$this.Output.Enqueue('VIDNAP_FILE|'+$this.Marker);if($this.Reads -eq 1){return 'TimedOut'};return 'Complete' }
$script:process | Add-Member ScriptProperty OutputComplete {throw 'ASSERT: mutable EOF reread'}
$script:process | Add-Member ScriptMethod Dispose {$this.Disposed=$true}
$worker=$script:process
$tick=$ast.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -ceq 'Add_Tick'},$true)
if(-not $tick){throw 'ASSERT: timer callback missing'}
& ($tick.Arguments[0].ScriptBlock.GetScriptBlock())
if($worker.Reads -ne 1 -or -not $worker.Disposed -or $PhaseText.Text -cne 'Failed' -or $script:savedFiles.Count -ne 0 -or -not [IO.File]::Exists($held)){throw 'ASSERT: WPF timer late EOF promoted incomplete output'}
Write-Output 'PASS: legacy transfer flags and real timer snapshot retain timeout output'
foreach($cancel in @($false,$true)){
    $script:legacyAttempt=New-LegacyAttempt $root $final
    $held=Join-Path $script:legacyAttempt.Stage ('late-'+$cancel+'.mp4');[IO.File]::WriteAllBytes($held,$sentinel)
    $script:reportedFiles=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $script:savedFiles=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $script:drainTimedOut=$false;$script:cancelRequested=$cancel
    $script:process=[pscustomobject]@{Output=[Collections.Concurrent.ConcurrentQueue[string]]::new();ExitCode=0;Reads=0;Disposed=$false}
    for($j=0;$j -lt 110;$j++){$script:process.Output.Enqueue('synthetic queued output')}
    $script:process.Output.Enqueue('VIDNAP_FILE|'+$held)
    $script:process | Add-Member ScriptProperty CompletionState {$this.Reads++;if($this.Reads -eq 1){return 'TimedOut'};return 'Complete'}
    $script:process | Add-Member ScriptMethod Dispose {$this.Disposed=$true}
    $worker=$script:process
    & ($tick.Arguments[0].ScriptBlock.GetScriptBlock())
    if($worker.Disposed -or $worker.Output.Count -ne 11){throw 'ASSERT: first tick did not retain bounded residual queue'}
    & ($tick.Arguments[0].ScriptBlock.GetScriptBlock())
    $expected=if($cancel){'Cancelled'}else{'Failed'}
    if(-not $worker.Disposed -or $worker.Reads -ne 2 -or $PhaseText.Text -cne $expected -or $script:savedFiles.Count -ne 0 -or -not [IO.File]::Exists($held)){throw 'ASSERT: late EOF across two ticks erased timeout or cancellation'}
}
Write-Output 'PASS: 111 queued lines retain timeout across two ticks and preserve cancellation'
