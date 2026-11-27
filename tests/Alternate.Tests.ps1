$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'VidNap.Alternate.ps1') -LibraryOnly
$count = 0
function Assert-Alternate([bool]$Condition, [string]$Label) { if (-not $Condition) { throw $Label }; $script:count++ }
foreach ($ip in @('127.0.0.1','10.0.0.1','172.16.1.1','192.168.1.1','169.254.169.254','100.64.0.1','0.0.0.0','224.0.0.1','198.18.0.1','192.0.2.1','198.51.100.1','203.0.113.1','::1','::ffff:8.8.8.8')) {
    Assert-Alternate (-not (Test-AlternatePublicAddress ([Net.IPAddress]::Parse($ip)))) ('Reject ' + $ip)
}
Assert-Alternate (Test-AlternatePublicAddress ([Net.IPAddress]::Parse('8.8.8.8'))) 'Public IPv4 accepted'
foreach ($url in @('http://example.com/a.mp4','https://localhost/a.mp4','https://127.0.0.1/a.mp4','https://example.com:444/a.mp4','https://user:pass@example.com/a.mp4','https://example.com/a.mp4?token=secret','https://example.com/a.mp4#fragment','https://example.com/page','https://example.com/a.m3u8')) {
    $rejected = $false; try { $null = Get-AlternateUri $url } catch { $rejected = $true }
    Assert-Alternate $rejected ('Reject URL ' + $url)
}
$uri = Get-AlternateUri 'https://example.com/a.mp4'
Assert-Alternate ($uri.Scheme -eq 'https') 'Direct URL accepted'
$argsList = @(Get-AlternateCurlArguments $uri '8.8.8.8' 'C:\Media Folder\unique.part')
Assert-Alternate ($argsList[0] -eq '--disable') 'Ambient config disabled first'
Assert-Alternate ($argsList -contains '--globoff') 'URL glob expansion disabled'
Assert-Alternate ($argsList -contains 'example.com:443:8.8.8.8') 'DNS pinned'
Assert-Alternate ($argsList -notcontains '--location' -and $argsList -notcontains '-L') 'No redirect follow'
Assert-Alternate ($argsList -notcontains '--insecure' -and $argsList -notcontains '-k') 'TLS validation preserved'
Assert-Alternate ($argsList -contains '--proxy' -and $argsList -contains '') 'Ambient proxies disabled'
Assert-Alternate ($argsList -contains '--max-time' -and $argsList -contains '--max-filesize') 'Transfer bounded'
Assert-Alternate ($argsList -contains 'C:\Media Folder\unique.part') 'Path retained as argument'
$badPin = $false; try { $null = Get-AlternateCurlArguments $uri '127.0.0.1' 'C:\part' } catch { $badPin = $true }
Assert-Alternate $badPin 'Private pin rejected'
Assert-Alternate ((Get-AlternateSafeError 'Public host lookup timed out.') -eq 'Public host lookup timed out.') 'Safe specific error retained'
Assert-Alternate ((Get-AlternateSafeError 'secret https://private.example/a?token=secret') -notmatch 'secret|private.example') 'Unknown exception redacted'
Write-Output "Alternate unit checks passed: $count (no network or media downloads)."
