. (Join-Path $PSScriptRoot 'Backend.TestSupport.ps1')
$root=Split-Path $PSScriptRoot -Parent
foreach($name in @('Core','Storage','Analysis')){. (Join-Path $root ('VidNap.'+$name+'.ps1'))}
if(Test-Path -LiteralPath (Join-Path $root 'VidNap.Desktop.ps1')){. (Join-Path $root 'VidNap.Desktop.ps1')}
Assert-Backend ($null -ne (Get-Command Read-VidNapDesktopConfiguration -ErrorAction SilentlyContinue)) 'normal shortcut coordinator is implemented'
$fixture=New-BackendTestDirectory $root
$records=[Collections.Generic.List[object]]::new()
$failure=$null
try {
 $app=Join-Path $fixture 'app';$data=Join-Path $fixture 'state';$media=Join-Path $fixture 'media'
 foreach($p in @($app,$data,$media,(Join-Path $app 'preview'))){[IO.Directory]::CreateDirectory($p)|Out-Null}
 Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\desktop-server.mjs') -Destination (Join-Path $app 'preview\server.mjs')
 Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\desktop-worker.ps1') -Destination (Join-Path $app 'VidNap.Preview.ps1')
 $runtime=[ordered]@{schemaVersion=1;applicationRoot=$app;dataRoot=$data;mediaRoot=$media}
 $template=Join-Path $app 'runtime-template.json'
 [IO.File]::WriteAllText($template,($runtime|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 $inventory=Join-Path $app 'desktop-inventory.json'
 [IO.File]::WriteAllText($inventory,(@{files=@(@{file='preview\server.mjs';sha256=(Get-BackendTestHash (Join-Path $app 'preview\server.mjs'))},@{file='VidNap.Preview.ps1';sha256=(Get-BackendTestHash (Join-Path $app 'VidNap.Preview.ps1'))})}|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
 $node=[string]$env:VIDNAP_DESKTOP_TEST_NODE
 if(-not $node -or -not [IO.File]::Exists($node)){throw 'An explicit existing Node test runtime is required.'}
 $config=[ordered]@{schemaVersion=1;applicationRoot=$app;dataRoot=$data;mediaRoot=$media;nodePath=$node;nodeSha256=(Get-BackendTestHash $node);runtimeTemplate=$template;inventory=$inventory;allowedApplicationRoots=@($app)}
 $file=Join-Path $app 'desktop-launch.json'
 [IO.File]::WriteAllText($file,($config|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
 $ctx=Read-VidNapDesktopConfiguration $file
 Assert-Backend ($ctx.MediaRoot -ceq $media -and $ctx.DataRoot -ceq $data) 'explicit private D: roots are retained'
 $config.mediaRoot='C:\Users\Public';[IO.File]::WriteAllText($file,($config|ConvertTo-Json -Depth 5))
 Assert-BackendCode {Read-VidNapDesktopConfiguration $file} 'VIDNAP_DESKTOP_STORAGE'
 $config.mediaRoot=$media;$config.nodeSha256=('0'*64);[IO.File]::WriteAllText($file,($config|ConvertTo-Json -Depth 5))
 Assert-BackendCode {Read-VidNapDesktopConfiguration $file} 'VIDNAP_DESKTOP_RUNTIME'
 $config.nodeSha256=Get-BackendTestHash $node;[IO.File]::WriteAllText($file,($config|ConvertTo-Json -Depth 5))
 [IO.File]::AppendAllText((Join-Path $app 'preview\server.mjs'),'// tampered')
 Assert-BackendCode {Read-VidNapDesktopConfiguration $file} 'VIDNAP_DESKTOP_INTEGRITY'
 Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\desktop-server.mjs') -Destination (Join-Path $app 'preview\server.mjs')
 $ctx=Read-VidNapDesktopConfiguration $file
 $redirect=Join-Path $data 'Runtime';$redirectTarget=Join-Path $fixture 'redirect-target'
 [IO.Directory]::CreateDirectory($redirectTarget)|Out-Null
 New-Item -ItemType Junction -Path $redirect -Target $redirectTarget|Out-Null
 try{
  Assert-BackendCode {Get-OrStartVidNapDesktop $ctx -TimeoutSeconds 2} 'VIDNAP_STORAGE_REPARSE'
  Assert-Backend (@(Get-ChildItem -LiteralPath $redirectTarget -Force).Count -eq 0) 'redirected runtime storage is rejected before any directory is created through it'
 }finally{[IO.Directory]::Delete($redirect)}
 # Both hostile inputs remain inside this disposable test's D: root. A null
 # application root cannot start a child even in the old fixture.
 [IO.Directory]::CreateDirectory((Join-Path $data 'Runtime'))|Out-Null
 foreach($negative in @(
  @{Directory=(Join-Path $fixture 'outside-runtime');Code='VIDNAP_FIXTURE_RUN_PATH';Label='fixture rejects a config outside its run directories before writing'},
  @{Directory=(Join-Path $data ('Runtime\run-'+('0'*32)));Code='VIDNAP_FIXTURE_ROOTS';Label='fixture rejects altered application roots before writing'}
 )){
  [IO.Directory]::CreateDirectory($negative.Directory)|Out-Null
  $negativeConfig=Join-Path $negative.Directory 'preview-config.json'
  [IO.File]::WriteAllText($negativeConfig,(@{schemaVersion=1;applicationRoot=$null;dataRoot=$data;mediaRoot=$media}|ConvertTo-Json))
  $info=[Diagnostics.ProcessStartInfo]::new()
  $info.FileName=$node;$info.Arguments=(Quote-Argument (Join-Path $app 'preview\server.mjs'))+' '+(Quote-Argument $negativeConfig)
  $info.WorkingDirectory=$app;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
  $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
  $negativeChild=[Diagnostics.Process]::Start($info)
  try{
   $negativeOut=$negativeChild.StandardOutput.ReadToEndAsync();$negativeErr=$negativeChild.StandardError.ReadToEndAsync()
   if(-not $negativeChild.WaitForExit(8000)){$negativeChild.Kill();throw 'Invalid desktop fixture did not exit.'}
   $negativeOut.GetAwaiter().GetResult()|Out-Null;$stderr=$negativeErr.GetAwaiter().GetResult()
   Assert-Backend ($negativeChild.ExitCode -ne 0 -and $stderr.Contains($negative.Code) -and @(Get-ChildItem -LiteralPath $negative.Directory -Force).Count -eq 1) $negative.Label
  }finally{$negativeChild.Dispose()}
 }
 $first=Get-OrStartVidNapDesktop $ctx -TimeoutSeconds 10;$records.Add($first)
 Assert-Backend ($first.url -match '^http://127\.0\.0\.1:\d+/$' -and $first.pid -gt 0) 'a real owned loopback process becomes ready'
 $second=Get-OrStartVidNapDesktop $ctx -TimeoutSeconds 10
 Assert-Backend ($second.pid -eq $first.pid -and $second.url -ceq $first.url) 'a second shortcut click reuses the same real worker'
 $lock=[IO.File]::Open((Join-Path $data 'desktop-start.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{Assert-BackendCode {Get-OrStartVidNapDesktop $ctx -TimeoutSeconds 1} 'VIDNAP_DESKTOP_BUSY'}finally{$lock.Dispose()}
 $current=Join-Path $data 'desktop-instance.json'
 $bad=[ordered]@{pid=$PID;url='https://example.com/not-vidnap';configuration='C:\not-vidnap.json'}
 [IO.File]::WriteAllText($current,($bad|ConvertTo-Json))
 Invoke-WebRequest ($first.url+'fixture-stop') -Method Post -UseBasicParsing|Out-Null
 for($i=0;$i -lt 30 -and (Get-Process -Id $first.pid -ErrorAction SilentlyContinue);$i++){[Threading.Thread]::Sleep(50)}
 $third=Get-OrStartVidNapDesktop $ctx -TimeoutSeconds 10;$records.Add($third)
 Assert-Backend ($third.pid -ne $first.pid -and $third.url -match '^http://127\.0\.0\.1:\d+/$') 'a stale or hostile receipt cannot choose the opened URL'
 Invoke-WebRequest ($third.url+'fixture-stop') -Method Post -UseBasicParsing|Out-Null
 for($i=0;$i -lt 30 -and (Get-Process -Id $third.pid -ErrorAction SilentlyContinue);$i++){[Threading.Thread]::Sleep(50)}
 $runtime.fixtureUnready=$true;[IO.File]::WriteAllText($template,($runtime|ConvertTo-Json))
 Assert-BackendCode {Get-OrStartVidNapDesktop $ctx -TimeoutSeconds 3} 'VIDNAP_DESKTOP_NOT_READY'
 $pending=Get-Content -LiteralPath $current -Raw|ConvertFrom-Json
 $records.Add($pending)
 Assert-Backend ($pending.pid -gt 0 -and (Get-Process -Id $pending.pid -ErrorAction SilentlyContinue)) 'an unready live worker retains an ownership receipt'
 Assert-BackendCode {Get-OrStartVidNapDesktop $ctx -TimeoutSeconds 2} 'VIDNAP_DESKTOP_NOT_READY'
 $still=Get-Content -LiteralPath $current -Raw|ConvertFrom-Json
 Assert-Backend ($still.pid -eq $pending.pid) 'an unready matching worker is not duplicated'
 $pendingAddress=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path ([IO.Path]::GetDirectoryName($pending.configuration)) 'preview-address.json')))
 $records.Add($pendingAddress)
 Invoke-WebRequest ($pendingAddress.url+'fixture-stop') -Method Post -UseBasicParsing|Out-Null
 foreach($processId in @($pendingAddress.pid,$pendingAddress.workerPid)){for($i=0;$i -lt 100 -and (Get-Process -Id $processId -ErrorAction SilentlyContinue);$i++){[Threading.Thread]::Sleep(50)}}
 $runtime.fixtureUnready=$false;[IO.File]::WriteAllText($template,($runtime|ConvertTo-Json))
 $orphan=Get-OrStartVidNapDesktop $ctx -TimeoutSeconds 10;$records.Add($orphan)
 $records.Add($orphan.PSObject.Copy())
 # Hold a real signed worker independently to model a delayed shutdown even
 # when Windows automatically closes the proxy's ordinary child process.
 $hostPath=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $held=Start-Process -FilePath $hostPath -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','AllSigned','-WindowStyle','Hidden','-File',('"'+(Join-Path $app 'VidNap.Preview.ps1')+'"'),'-Configuration',('"'+$orphan.configuration+'"')) -WorkingDirectory $app -WindowStyle Hidden -PassThru
 $orphan.workerPid=$held.Id;$held.Dispose()
 [IO.File]::WriteAllText($current,($orphan|ConvertTo-Json))
 $script:DesktopOriginalProbe=(Get-Command Get-VidNapDesktopProbe).ScriptBlock
 $script:DesktopRace=$orphan;$script:DesktopRaceArmed=$true
 function Get-VidNapDesktopProbe($Context,$Record){
  if($script:DesktopRaceArmed -and (Get-VidNapDataValue $Record 'pid' 0) -eq $script:DesktopRace.pid){
   $script:DesktopRaceArmed=$false
   Invoke-WebRequest ($script:DesktopRace.url+'fixture-orphan') -Method Post -UseBasicParsing|Out-Null
   for($j=0;$j -lt 100 -and (Get-Process -Id $script:DesktopRace.pid -ErrorAction SilentlyContinue);$j++){[Threading.Thread]::Sleep(50)}
  }
  & $script:DesktopOriginalProbe $Context $Record
 }
 $raceRuns=@(Get-ChildItem -LiteralPath (Join-Path $data 'Runtime') -Directory).Count
 [IO.File]::WriteAllText($current,(@{pid=0;configuration='C:\not-vidnap.json'}|ConvertTo-Json))
 try{
  Assert-BackendCode {Get-OrStartVidNapDesktop $ctx -TimeoutSeconds 3} 'VIDNAP_DESKTOP_WORKER_ALIVE'
  Assert-Backend (@(Get-ChildItem -LiteralPath (Join-Path $data 'Runtime') -Directory).Count -eq $raceRuns) 'a discovered proxy disappearing during re-probe cannot duplicate its live worker'
 }finally{Set-Item -LiteralPath Function:\Get-VidNapDesktopProbe -Value $script:DesktopOriginalProbe}
 [IO.File]::WriteAllText($current,($orphan|ConvertTo-Json))
 for($i=0;$i -lt 100 -and (Get-Process -Id $orphan.pid -ErrorAction SilentlyContinue);$i++){[Threading.Thread]::Sleep(50)}
 Assert-Backend ($null -ne (Get-Process -Id $orphan.workerPid -ErrorAction SilentlyContinue)) 'the real isolated backend remains alive after its Node proxy exits'
 $runs=@(Get-ChildItem -LiteralPath (Join-Path $data 'Runtime') -Directory).Count
 try {
  Assert-BackendCode {Get-OrStartVidNapDesktop $ctx -TimeoutSeconds 2} 'VIDNAP_DESKTOP_WORKER_ALIVE'
  [IO.File]::WriteAllText($current,(@{pid=0;url='https://example.com/not-vidnap';configuration='C:\not-vidnap.json'}|ConvertTo-Json))
  Assert-BackendCode {Get-OrStartVidNapDesktop $ctx -TimeoutSeconds 2} 'VIDNAP_DESKTOP_WORKER_ALIVE'
  Assert-Backend (@(Get-ChildItem -LiteralPath (Join-Path $data 'Runtime') -Directory).Count -eq $runs) 'a missing or invalid proxy receipt cannot duplicate a live backend'
 }finally{[IO.File]::WriteAllText((Join-Path ([IO.Path]::GetDirectoryName($orphan.configuration)) 'fixture-worker-stop'),'stop')}
 $log=Join-Path $data 'desktop-startup.jsonl'
 Assert-Backend ([IO.File]::Exists($log) -and [IO.File]::ReadAllText($log) -notmatch 'example.com|not-vidnap|runtime-template') 'startup diagnostics use fixed codes, not arbitrary inputs'
 Write-Output "PASS: $script:BackendChecks desktop startup checks; private D: paths, pinned hashes, real startup/reuse, stale receipts, locking and unready-worker recovery."
}catch{$failure=$_}finally{
 $current=Join-Path $fixture 'state\desktop-instance.json'
 if([IO.File]::Exists($current)){try{$records.Add((ConvertFrom-Json ([IO.File]::ReadAllText($current))))}catch{}}
 foreach($r in $records){
  try{[IO.File]::WriteAllText((Join-Path ([IO.Path]::GetDirectoryName($r.configuration)) 'fixture-worker-stop'),'stop')}catch{}
  try{$a=Get-Content -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($r.configuration)) 'preview-address.json') -Raw|ConvertFrom-Json;Invoke-WebRequest ($a.url+'fixture-stop') -Method Post -UseBasicParsing -TimeoutSec 2|Out-Null}catch{}
 }
 $remaining=$false
 foreach($r in $records){foreach($processId in @($r.pid,(Get-VidNapDataValue $r 'workerPid' 0))){if($processId -le 0){continue};for($i=0;$i -lt 100 -and (Get-Process -Id $processId -ErrorAction SilentlyContinue);$i++){[Threading.Thread]::Sleep(50)};if(Get-Process -Id $processId -ErrorAction SilentlyContinue){$remaining=$true}}}
 if(-not $remaining -and -not $failure){Remove-BackendTestDirectory $fixture $root}else{Write-Output ('Retained owned test fixture for failure review: '+$fixture)}
}
if($failure){throw $failure}
