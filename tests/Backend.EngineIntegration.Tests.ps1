param([Parameter(Mandatory=$true)][string]$EngineDirectory)
. (Join-Path $PSScriptRoot 'Backend.TestSupport.ps1')
$root=Split-Path $PSScriptRoot -Parent
foreach($name in @('Core','Storage','Analysis','Jobs','Captions','Backend')){. (Join-Path $root ('VidNap.'+$name+'.ps1'))}
$manifestPath=Join-Path $EngineDirectory 'install-manifest.json'
$inventory=ConvertFrom-Json ([IO.File]::ReadAllText($manifestPath));$manifestHash=Get-BackendTestHash $manifestPath
if($inventory.schemaVersion -ne 3){throw 'A schema-3 existing engine inventory is required.'}
$tools=@{
    YtDlp=@{Path=(Join-Path $EngineDirectory 'yt-dlp.exe');Sha256=$inventory.ytDlpSha256}
    Ffmpeg=@{Path=(Join-Path $EngineDirectory 'ffmpeg\ffmpeg.exe');Sha256=$inventory.ffmpegBinarySha256.'ffmpeg.exe'}
    Ffprobe=@{Path=(Join-Path $EngineDirectory 'ffmpeg\ffprobe.exe');Sha256=$inventory.ffmpegBinarySha256.'ffprobe.exe'}
}
foreach($name in $tools.Keys){Get-VidNapTrustedTool $tools $name|Out-Null}
$fixture=New-BackendTestDirectory $root
$adapter=New-VidNapNativeAdapter ([pscustomobject]@{DataRoot=$fixture})
function Wait-EngineFixture($Handle){
    $timer=[Diagnostics.Stopwatch]::StartNew();$lines=[Collections.Generic.List[string]]::new()
    do{
        $result=& $adapter.Poll $Handle
        foreach($line in $result.Lines){$lines.Add($line)}
        if($result.Complete){$result|Add-Member NoteProperty AllLines @($lines.ToArray());return $result}
        Start-Sleep -Milliseconds 25
    }while($timer.Elapsed.TotalSeconds -lt 40)
    & $adapter.Cancel $Handle|Out-Null
    throw 'Owned engine fixture timed out; no installed app was started.'
}
if(-not ('VidNapFixtureHttpServer' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
public sealed class VidNapFixtureHttpServer : IDisposable {
    readonly TcpListener listener; readonly Thread thread; readonly byte[] body;
    volatile bool stopped;
    public int Port { get; private set; }
    public VidNapFixtureHttpServer(byte[] data) {
        body=data; listener=new TcpListener(IPAddress.Loopback,0);listener.Start();
        Port=((IPEndPoint)listener.LocalEndpoint).Port;
        thread=new Thread(Serve);thread.IsBackground=true;thread.Start();
    }
    void Serve() {
        while(!stopped) {
            try { using(TcpClient client=listener.AcceptTcpClient()) using(NetworkStream stream=client.GetStream()) {
                stream.ReadTimeout=2000;stream.WriteTimeout=2000;
                StringBuilder request=new StringBuilder();int b;
                while(request.Length<8192 && (b=stream.ReadByte())>=0) {request.Append((char)b);if(request.ToString().EndsWith("\r\n\r\n"))break;}
                string text=request.ToString();
                if(!text.StartsWith("GET /fixture.mp4 ") && !text.StartsWith("HEAD /fixture.mp4 ")) {
                    byte[] notFound=Encoding.ASCII.GetBytes("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");stream.Write(notFound,0,notFound.Length);continue;
                }
                byte[] header=Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: "+body.Length+"\r\nConnection: close\r\n\r\n");
                stream.Write(header,0,header.Length);if(text.StartsWith("GET ")) stream.Write(body,0,body.Length);
            }} catch { if(stopped)return; }
        }
    }
    public void Dispose() {stopped=true;listener.Stop();thread.Join(3000);}
}
'@
}
$server=$null;$streamServers=[Collections.Generic.List[object]]::new()
try{
    $paths=[pscustomobject]@{DataRoot=$fixture}
    $environment=Get-VidNapRuntimeEnvironment $paths
    $source=Join-Path $fixture 'source.mp4'
    $generate=[pscustomobject]@{Kind='GenerateFixture';ToolPath=$tools.Ffmpeg.Path;ToolSha256=$tools.Ffmpeg.Sha256;WorkingDirectory=$fixture
        Environment=$environment;StandardOutputLimit=65536;StandardErrorLimit=65536;TimeoutMilliseconds=30000
        Arguments=@('-nostdin','-hide_banner','-loglevel','error','-f','lavfi','-i','color=c=blue:s=160x90:r=25','-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','1','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac','-shortest','-n',$source)}
    $handle=& $adapter.Start $generate
    try{$result=Wait-EngineFixture $handle;Assert-Backend ($result.ExitCode -eq 0 -and -not $result.ErrorCode -and [IO.File]::Exists($source)) 'real FFmpeg generates an isolated one-second AV fixture'}finally{& $adapter.Dispose $handle}
    $server=[VidNapFixtureHttpServer]::new([IO.File]::ReadAllBytes($source))
    $url='http://127.0.0.1:'+$server.Port+'/fixture.mp4'
    $info=Join-Path $fixture 'info.json'
    $metadata=@{id='fixture';title='Generated fixture';extractor='generic';extractor_key='Generic';webpage_url=$url;duration=1
        formats=@(@{format_id='one';url=$url;ext='mp4';protocol='http';vcodec='avc1';acodec='mp4a';width=160;height=90;fps=25;filesize=([IO.FileInfo]$source).Length});format_id='one'}
    [IO.File]::WriteAllText($info,($metadata|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    $receivedName='received-'+[char]0x00FC+'.mp4';$received=Join-Path $fixture $receivedName
    $transfer=[pscustomobject]@{Kind='Download';ToolPath=$tools.YtDlp.Path;ToolSha256=$tools.YtDlp.Sha256;WorkingDirectory=$fixture;Environment=$environment
        Arguments=(@(Get-EngineBaseArguments 100 -TrackDownload)+@('--no-cache-dir','--proxy','','--load-info-json',$info,'-f',"all[format_id='one']",'-o',$receivedName))}
    $handle=& $adapter.Start $transfer
    try{$result=Wait-EngineFixture $handle;Assert-Backend ($result.ExitCode -eq 0 -and -not $result.ErrorCode -and [IO.File]::Exists($received)) 'real yt-dlp transfers only generated loopback media'}finally{& $adapter.Dispose $handle}
    Assert-Backend ((Get-BackendTestHash $source) -ceq (Get-BackendTestHash $received)) 'transferred original bytes are preserved exactly'
    $plans=@($result.AllLines|Where-Object {$_.StartsWith('VIDNAP_PLAN|')})
    Assert-Backend ($plans.Count -eq 1) 'the real engine emits one selected plan for one combined stream'
    $tracker=@{PlanSeen=$false;Streams=$null};Set-VidNapTransferPlan $tracker $plans[0]
    Assert-Backend ($null -ne $tracker.Streams -and $tracker.Streams.ContainsKey('one') -and $tracker.Streams['one'].Exact -eq ([IO.FileInfo]$source).Length) ('single stream selection reports its known size: '+$plans[0])
    Assert-Backend (@($result.AllLines|Where-Object {$_.StartsWith('VIDNAP_FILE|')}).Count -eq 1) 'real engine output-file evidence reaches the native adapter'
    $reported=@($result.AllLines|Where-Object {$_.StartsWith('VIDNAP_FILE|')}|ForEach-Object {ConvertFrom-ProgressLine $_})[0].Path
    Assert-Backend ((Assert-VidNapOutputFile $reported $fixture) -ceq $received) 'UTF8 output filenames are decoded without corrupting file evidence'
    $handle=& $adapter.Start (New-VidNapProbeRequest $received $paths $tools)
    try{
        $result=Wait-EngineFixture $handle
        $expected=Get-VidNapExpectedOutput (ConvertFrom-VidNapAnalysis ($metadata|ConvertTo-Json -Depth 5)) @{Media='video';Format='best';FormatIds=@()}
        $verification=Test-VidNapOutput $expected $result.Output ([IO.FileInfo]$received).Length
        Assert-Backend ($result.ExitCode -eq 0 -and $verification.Status -eq 'Validated') 'real bounded ffprobe structurally verifies downloaded AV output'
    }finally{& $adapter.Dispose $handle}
    $pair=@(foreach($track in @(@{Id='v';Map='0:v:0';Ext='mp4'},@{Id='a';Map='0:a:0';Ext='m4a'})){
        $trackPath=Join-Path $fixture ('track-'+$track.Id+'.'+$track.Ext)
        $split=$generate.PSObject.Copy()
        $split.Arguments=@('-nostdin','-hide_banner','-loglevel','error','-i',$source,'-map',$track.Map,'-c','copy','-n',$trackPath)
        $handle=& $adapter.Start $split
        try{
            $result=Wait-EngineFixture $handle
            Assert-Backend ($result.ExitCode -eq 0 -and [IO.File]::Exists($trackPath)) ('FFmpeg stream-copies the '+$track.Id+' fixture')
        }finally{& $adapter.Dispose $handle}
        $trackBody=[IO.File]::ReadAllBytes($trackPath)
        $trackServer=[VidNapFixtureHttpServer]::new($trackBody);$streamServers.Add($trackServer)
        $format=@{format_id=$track.Id;url=('http://127.0.0.1:'+$trackServer.Port+'/fixture.mp4');ext=$track.Ext;protocol='http';filesize=$trackBody.Length}
        if($track.Id -ceq 'v'){$format.vcodec='avc1';$format.acodec='none';$format.width=160;$format.height=90;$format.fps=25}
        else{$format.vcodec='none';$format.acodec='mp4a'}
        $format
    })
    $pairInfo=Join-Path $fixture 'pair-info.json'
    $metadata.formats=$pair;$metadata.Remove('format_id')
    [IO.File]::WriteAllText($pairInfo,($metadata|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    $mergedName='paired.mp4';$merged=Join-Path $fixture $mergedName
    $transfer.Arguments=@(Get-EngineBaseArguments 100 -TrackDownload)+@('--no-cache-dir','--proxy','','--ffmpeg-location',$tools.Ffmpeg.Path,'--load-info-json',$pairInfo,'-f','v+a','-o',$mergedName)
    $handle=& $adapter.Start $transfer
    try{
        $result=Wait-EngineFixture $handle
        Assert-Backend ($result.ExitCode -eq 0 -and -not $result.ErrorCode -and [IO.File]::Exists($merged)) 'real yt-dlp downloads and merges the generated video/audio pair'
    }finally{& $adapter.Dispose $handle}
    $tracker=@{PlanSeen=$false;Streams=$null};$sawAudio=$false
    $transferTotal=$pair[0].filesize+$pair[1].filesize
    foreach($line in $result.AllLines){
        if($line.StartsWith('VIDNAP_PLAN|')){
            Set-VidNapTransferPlan $tracker $line
            $p=Get-VidNapTransferCounts $tracker @{Bytes=0;Total=0;TotalEstimated=$false}
            Assert-Backend ($p.Total -eq $transferTotal -and $p.ByteScope -ceq 'Download' -and -not $p.Estimated) 'actual selected formats give an exact total before either stream transfers'
        }else{
            $progressRecord=ConvertFrom-ProgressLine $line
            if($null -eq $progressRecord -or $progressRecord.Kind -cne 'Downloading'){continue}
            Update-VidNapTransferCounts $tracker $progressRecord
            if($progressRecord.StreamId -ceq 'a' -and $progressRecord.HasByteCount -and -not $sawAudio){
                $p=Get-VidNapTransferCounts $tracker @{Bytes=0;Total=0;TotalEstimated=$false}
                Assert-Backend ($p.Bytes -eq ($pair[0].filesize+$progressRecord.Bytes) -and $p.Total -eq $transferTotal) 'first real audio event retains the completed video bytes'
                $sawAudio=$true
            }
        }
    }
    $p=Get-VidNapTransferCounts $tracker @{Bytes=0;Total=0;TotalEstimated=$false}
    Assert-Backend ($sawAudio -and $p.Bytes -eq $transferTotal -and $p.Total -eq $transferTotal) 'real progress and finish events account for both tracks exactly once'
    $handle=& $adapter.Start (New-VidNapProbeRequest $merged $paths $tools)
    try{
        $result=Wait-EngineFixture $handle
        $verification=Test-VidNapOutput $expected $result.Output ([IO.FileInfo]$merged).Length
        Assert-Backend ($result.ExitCode -eq 0 -and $verification.Status -ceq 'Validated') 'merged fixture retains the expected video and audio quality'
    }finally{& $adapter.Dispose $handle}
    foreach($name in $tools.Keys){Assert-Backend ((Get-BackendTestHash $tools[$name].Path) -ceq $tools[$name].Sha256) ($name+' existing engine unchanged')}
    Assert-Backend ((Get-BackendTestHash $manifestPath) -ceq $manifestHash) 'installed engine inventory unchanged'
    Write-Output "PASS: $script:BackendChecks real-engine checks; generated media, loopback-only transfer, byte equality, bounded structural probe and unchanged vendor tools. No external website or browser access."
}finally{foreach($trackServer in $streamServers){$trackServer.Dispose()};if($server){$server.Dispose()};Remove-BackendTestDirectory $fixture $root}
