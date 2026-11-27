Set-StrictMode -Version Latest

function ConvertTo-VidNapLocalDirectory([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:[\\/]') {
        throw 'VIDNAP_STORAGE_PATH: Choose an absolute local folder.'
    }
    if ($Path.Substring(2).IndexOfAny([char[]]':*?"<>|') -ge 0 -or $Path.IndexOf([char]0) -ge 0 -or
        $Path -match '(?i)(^|[\\/])OneDrive(?: - [^\\/]+)?([\\/]|$)') {
        throw 'VIDNAP_STORAGE_PATH: The configured folder is not supported.'
    }
    try { $full = [IO.Path]::GetFullPath($Path) } catch {
        throw 'VIDNAP_STORAGE_PATH: The configured folder is invalid.'
    }
    $drive = [IO.Path]::GetPathRoot($full)
    if ($full.TrimEnd('\') -ieq $drive.TrimEnd('\')) {
        throw 'VIDNAP_STORAGE_PATH: Choose a folder, not a drive root.'
    }
    foreach ($part in $full.Substring(3).Split('\')) {
        if ($part -and ($part.TrimEnd(' ','.') -cne $part -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)')) {
            throw 'VIDNAP_STORAGE_PATH: The configured folder contains an unsupported name.'
        }
    }
    if (-not [IO.Directory]::Exists($drive)) {
        throw 'VIDNAP_STORAGE_DRIVE: The configured drive is unavailable. Reconnect it; no fallback was selected.'
    }
    $cursor = $full
    while ($cursor) {
        if ([IO.File]::Exists($cursor)) { throw 'VIDNAP_STORAGE_PATH: A configured folder is a file.' }
        if ([IO.Directory]::Exists($cursor)) {
            try { $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop } catch {
                throw 'VIDNAP_STORAGE_PATH: A configured folder cannot be inspected.'
            }
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'VIDNAP_STORAGE_REPARSE: Redirected storage requires an explicitly reviewed migration.'
            }
        }
        $parent = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parent) { break }
        $cursor = $parent.FullName
    }
    return $full.TrimEnd('\')
}

function Get-VidNapInstallationPaths {
    param([string]$AppDirectory, [string]$DataOverride='', [string]$MediaOverride='')
    $app = ConvertTo-VidNapLocalDirectory $AppDirectory
    $hasData = -not [string]::IsNullOrWhiteSpace($DataOverride)
    $hasMedia = -not [string]::IsNullOrWhiteSpace($MediaOverride)
    if ($hasData -ne $hasMedia) {
        throw 'VIDNAP_STORAGE_OVERRIDE_PAIR: Supply both explicit data and media overrides.'
    }
    $file = Join-Path $app 'vidnap-installation.json'
    if (-not [IO.File]::Exists($file)) {
        throw 'VIDNAP_STORAGE_CONFIG_MISSING: Installation configuration is missing. No default location was selected.'
    }
    try {
        $item = Get-Item -LiteralPath $file -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or $item.Length -gt 65536) {
            throw 'Invalid configuration file.'
        }
        $encoding = [Text.UTF8Encoding]::new($false,$true)
        $text = $encoding.GetString([IO.File]::ReadAllBytes($file))
        $configuration = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    } catch {
        throw 'VIDNAP_STORAGE_CONFIG_INVALID: Installation configuration cannot be read.'
    }
    if ($configuration -isnot [Management.Automation.PSCustomObject]) {
        throw 'VIDNAP_STORAGE_SCHEMA: Installation configuration must be an object.'
    }
    $names = @($configuration.PSObject.Properties | ForEach-Object { $_.Name })
    if ($names.Count -ne 4 -or
        @($names | Where-Object { $_ -cnotin @('SchemaVersion','ApplicationRoot','DataRoot','MediaRoot') }).Count -gt 0) {
        throw 'VIDNAP_STORAGE_SCHEMA: Installation configuration has unsupported fields.'
    }
    if (($configuration.SchemaVersion -isnot [int] -and $configuration.SchemaVersion -isnot [long]) -or
        $configuration.SchemaVersion -ne 1) {
        throw 'VIDNAP_STORAGE_SCHEMA: Installation configuration version is unsupported.'
    }
    foreach ($name in @('ApplicationRoot','DataRoot','MediaRoot')) {
        if ($configuration.$name -isnot [string]) {
            throw 'VIDNAP_STORAGE_SCHEMA: Installation folders must be strings.'
        }
    }
    $application = ConvertTo-VidNapLocalDirectory $configuration.ApplicationRoot
    if ($app -ine $application -and -not $app.StartsWith(($application+'\'),[StringComparison]::OrdinalIgnoreCase)) {
        throw 'VIDNAP_STORAGE_PATH: This application is outside its configured installation root.'
    }
    $data = ConvertTo-VidNapLocalDirectory $(if ($hasData) { $DataOverride } else { $configuration.DataRoot })
    $media = ConvertTo-VidNapLocalDirectory $(if ($hasMedia) { $MediaOverride } else { $configuration.MediaRoot })
    $roots = @($application,$data,$media)
    for ($i=0; $i -lt $roots.Count; $i++) {
        for ($j=$i+1; $j -lt $roots.Count; $j++) {
            if ($roots[$i] -ieq $roots[$j] -or
                $roots[$i].StartsWith(($roots[$j]+'\'),[StringComparison]::OrdinalIgnoreCase) -or
                $roots[$j].StartsWith(($roots[$i]+'\'),[StringComparison]::OrdinalIgnoreCase)) {
                throw 'VIDNAP_STORAGE_PATH: Application, data and media folders must not overlap.'
            }
        }
    }
    $runtime = Get-VidNapRuntimeEnvironment ([pscustomobject]@{DataRoot=$data})
    return [pscustomobject]@{
        SchemaVersion = 1
        ApplicationRoot = $application
        DataRoot = $data
        MediaRoot = $media
        TempRoot = $runtime.TEMP
        CacheRoot = $runtime.XDG_CACHE_HOME
        DenoRoot = $runtime.DENO_DIR
    }
}

function Assert-VidNapDirectoryWritable([string]$Path, [Guid]$OperationId) {
    $directory = ConvertTo-VidNapLocalDirectory $Path
    if ($OperationId -eq [Guid]::Empty -or -not [IO.Directory]::Exists($directory)) {
        throw 'VIDNAP_STORAGE_WRITE: The configured folder is not ready.'
    }
    $probe = Join-Path $directory ('.vidnap-probe-'+$OperationId.ToString('N')+'.tmp')
    $stream = $null
    try {
        # DeleteOnClose removes only the newly opened file, not a name that
        # another actor could replace between the probe and cleanup.
        $options = [IO.FileOptions]::WriteThrough -bor [IO.FileOptions]::DeleteOnClose
        $stream = [IO.FileStream]::new($probe,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None,1,$options)
        $stream.WriteByte(42)
        $stream.Flush($true)
    } catch {
        throw 'VIDNAP_STORAGE_WRITE: The configured folder could not accept a new file. No fallback was selected.'
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Get-VidNapRuntimeEnvironment($Paths) {
    $data = ConvertTo-VidNapLocalDirectory $Paths.DataRoot
    return @{
        TEMP = ConvertTo-VidNapLocalDirectory (Join-Path $data 'temp')
        TMP = ConvertTo-VidNapLocalDirectory (Join-Path $data 'temp')
        XDG_CACHE_HOME = ConvertTo-VidNapLocalDirectory (Join-Path $data 'cache')
        DENO_DIR = ConvertTo-VidNapLocalDirectory (Join-Path $data 'deno-cache')
    }
}

function Assert-VidNapRegularFile([string]$Path) {
    $directory=ConvertTo-VidNapLocalDirectory ([IO.Path]::GetDirectoryName($Path))
    $name=[IO.Path]::GetFileName($Path)
    if([IO.Path]::GetPathRoot($directory) -ine 'D:\' -or -not [IO.File]::Exists($Path) -or
        ([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -or
        -not $name -or $name.TrimEnd(' ','.') -cne $name -or $name -match '[:*?"<>|\x00-\x1F]|^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){
        throw 'VIDNAP_STORAGE_FILE: A regular local D: file is required.'
    }
    return [IO.Path]::GetFullPath($Path)
}

function Assert-VidNapPrivateDirectory([string]$Path) {
    $directory=ConvertTo-VidNapLocalDirectory $Path
    if(-not [IO.Directory]::Exists($directory)){throw 'VIDNAP_STORAGE_PRIVATE: Existing private storage is required.'}
    $current=[Security.Principal.WindowsIdentity]::GetCurrent()
    try{$owner=$current.User.Value}finally{$current.Dispose()}
    foreach($rule in (Get-Acl -LiteralPath $directory).Access){
        $sid=$rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if($rule.AccessControlType -eq 'Allow' -and -not (Test-VidNapPrivatePrincipal $owner $sid)){
            throw 'VIDNAP_STORAGE_PRIVATE: Storage is accessible to other local users. No permissions were changed.'
        }
    }
}

function Test-VidNapPrivatePrincipal([string]$CurrentUserSid,[string]$PrincipalSid) {
    return ($CurrentUserSid -and $PrincipalSid -and $PrincipalSid -in @($CurrentUserSid,'S-1-5-18','S-1-5-32-544'))
}

function Get-VidNapFileSha256([string]$Path) {
    Assert-VidNapRegularFile $Path|Out-Null
    $hash=[Security.Cryptography.SHA256]::Create();$stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{return [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-','')}finally{$stream.Dispose();$hash.Dispose()}
}
