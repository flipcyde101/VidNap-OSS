Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Windows.Forms

. (Join-Path $PSScriptRoot 'VidNap.Core.ps1')
function Assert-LegacyRegularPath([string]$Path) {
    $current=[IO.Path]::GetFullPath($Path)
    while($current) {
        if(Test-Path -LiteralPath $current) {
            if(([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Reparse traversal rejected.'}
        }
        $current=[IO.Path]::GetDirectoryName($current)
    }
}

function New-LegacyAttempt([string]$Root,[string]$Destination) {
    $rootPath=[IO.Path]::GetFullPath($Root)
    if([IO.Path]::GetPathRoot($rootPath) -ine 'D:\'){throw 'Legacy staging requires D:.'}
    Assert-LegacyRegularPath $rootPath
    Assert-LegacyRegularPath $Destination
    if([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Destination)) -ine 'D:\'){throw 'Legacy destination must be on D:.'}
    if(-not [IO.Directory]::Exists($rootPath)){throw 'Choose an existing private staging root.'}
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    foreach($entry in (Get-Acl -LiteralPath $rootPath).Access){
        if($entry.AccessControlType -eq 'Allow'){
            try{$ident=$entry.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value}
            catch{throw 'Staging root ACL contains an identity that cannot be resolved. Remove or reassign it and try again.'}
            if($ident -notin @($sid,'S-1-5-18','S-1-5-32-544')){throw 'Staging root has unexpected access.'}
        }
    }
    $stage=Join-Path $rootPath ('legacy-attempt-'+[guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    Assert-LegacyRegularPath $stage
    foreach($entry in (Get-Acl -LiteralPath $stage).Access){
        if($entry.AccessControlType -eq 'Allow'){
            try{$ident=$entry.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value}
            catch{throw 'Stage ACL contains an identity that cannot be resolved; retained without execution.'}
            if($ident -notin @($sid,'S-1-5-18','S-1-5-32-544')){throw 'Stage inherited unexpected access; retained without execution.'}
        }
    }
    [pscustomobject]@{Stage=$stage;Destination=[IO.Path]::GetFullPath($Destination)}
}

function Publish-LegacyOutput($Attempt,[string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    if([IO.Path]::GetDirectoryName($full) -ine $Attempt.Stage){throw 'Output outside owned attempt.'}
    Assert-LegacyRegularPath $full
    Assert-LegacyRegularPath $Attempt.Destination
    $item=Get-Item -LiteralPath $full -Force
    if($item.PSIsContainer -or $item.Length -le 0 -or $item.Name -match '\.(part|ytdl|temp|tmp)$'){throw 'Invalid attempt output.'}
    $target=Join-Path $Attempt.Destination $item.Name
    Assert-LegacyRegularPath $target
    [IO.File]::Move($full,$target)
    return $target
}
if (-not ('VidNapProcessRunner' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'VidNap.ProcessRunner.cs')
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="VidNap 0.3.2" Width="900" Height="800" MinWidth="700" MinHeight="560"
        WindowStartupLocation="CenterScreen" Background="#0C111B" Foreground="#E8EEF8"
        FontFamily="Segoe UI" UseLayoutRounding="True" ToolTipService.InitialShowDelay="350" ToolTipService.ShowDuration="15000">
    <Window.Resources>
        <SolidColorBrush x:Key="Panel" Color="#151D2B"/>
        <SolidColorBrush x:Key="Panel2" Color="#1C2738"/>
        <SolidColorBrush x:Key="Accent" Color="#67E8C6"/>
        <SolidColorBrush x:Key="Muted" Color="#93A4BA"/>
        <Style TargetType="ToolTip">
            <Setter Property="Background" Value="#253248"/><Setter Property="Foreground" Value="#F7FAFC"/>
            <Setter Property="Padding" Value="12,9"/><Setter Property="MaxWidth" Value="360"/>
        </Style>
        <Style x:Key="MetricLabel" TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="FontSize" Value="11"/>
            <Setter Property="Margin" Value="0,0,0,5"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#0F1623"/><Setter Property="Foreground" Value="#F7FAFC"/>
            <Setter Property="BorderBrush" Value="#314058"/><Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="12,9"/><Setter Property="FontSize" Value="14"/>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="#E8EEF8"/><Setter Property="Foreground" Value="#0C111B"/>
            <Setter Property="BorderBrush" Value="#314058"/><Setter Property="Padding" Value="8"/>
            <Setter Property="FontSize" Value="14"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#C8D3E2"/><Setter Property="FontSize" Value="13"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>
        <Style x:Key="PrimaryButton" TargetType="Button">
            <Setter Property="Background" Value="#67E8C6"/><Setter Property="Foreground" Value="#09221D"/>
            <Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="22,11"/>
            <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="FontSize" Value="14"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value><ControlTemplate TargetType="Button">
                    <Border x:Name="Surface" Background="{TemplateBinding Background}" CornerRadius="9" Padding="{TemplateBinding Padding}" BorderBrush="#7893AD" BorderThickness="0">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Surface" Property="Opacity" Value="0.85"/></Trigger>
                        <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Surface" Property="BorderThickness" Value="2"/></Trigger>
                        <Trigger Property="IsPressed" Value="True"><Setter TargetName="Surface" Property="Opacity" Value="0.65"/></Trigger>
                        <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Surface" Property="Opacity" Value="0.4"/></Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate></Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="SecondaryButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}">
            <Setter Property="Background" Value="#253248"/><Setter Property="Foreground" Value="#E8EEF8"/>
        </Style>
    </Window.Resources>

    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
    <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="18"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="18"/><RowDefinition Height="Auto"/><RowDefinition Height="18"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="18"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="14"/><RowDefinition Height="Auto"/><RowDefinition Height="16"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel Orientation="Horizontal">
                <Border Background="#67E8C6" CornerRadius="8" Width="42" Height="42" Margin="0,0,12,0">
                    <TextBlock Text="V" Foreground="#09221D" FontWeight="Bold" FontSize="23" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <StackPanel>
                    <TextBlock Text="VidNap" Foreground="#E8EEF8" FontSize="27" FontWeight="Bold"/>
                    <TextBlock Text="Your media. Your format." Foreground="{StaticResource Muted}" FontSize="13"/>
                </StackPanel>
            </StackPanel>
            <CheckBox x:Name="ReduceMotionBox" Grid.Column="1" Content="Reduce motion" ToolTip="Disable the activity pulse and indeterminate progress animation. Starts with your Windows animation preference." AutomationProperties.Name="Reduce motion"/>
        </Grid>

        <StackPanel Grid.Row="2">
            <TextBlock Text="01 / ADD YOUR MEDIA" Foreground="{StaticResource Accent}" FontSize="11" FontWeight="SemiBold" Margin="0,0,0,7"/>
            <TextBox x:Name="UrlBox" Height="42" AutomationProperties.Name="Media URL" ToolTip="Paste an http:// or https:// media page URL"/>
        </StackPanel>

        <Grid Grid.Row="4">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
                <TextBlock Text="SAVE TO" Foreground="{StaticResource Muted}" FontSize="11" FontWeight="SemiBold" Margin="0,0,0,7"/>
                <TextBox x:Name="FolderBox" Height="42" IsReadOnly="True" AutomationProperties.Name="Save destination" ToolTip="Your media stays in this folder (D: drive required). Use Browse to choose another destination."/>
            </StackPanel>
            <Button x:Name="BrowseButton" Grid.Column="2" Content="Browse" Style="{StaticResource SecondaryButton}" Height="42" VerticalAlignment="Bottom" ToolTip="Choose a destination folder"/>
        </Grid>

        <Grid Grid.Row="6">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Grid Grid.Column="0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="145"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                    <TextBlock Text="02 / CHOOSE OUTPUT" Foreground="{StaticResource Accent}" FontSize="11" FontWeight="SemiBold" Margin="0,0,0,7"/>
                    <ComboBox x:Name="MediaTypeBox" Height="42" SelectedIndex="0" AutomationProperties.Name="Media type" ToolTip="Save video or an audio-only stream">
                        <ComboBoxItem Content="Video" Tag="video"/>
                        <ComboBoxItem Content="Audio" Tag="audio"/>
                    </ComboBox>
                </StackPanel>
                <StackPanel Grid.Column="2">
                    <TextBlock Text="EXPORT FORMAT" Foreground="{StaticResource Muted}" FontSize="11" FontWeight="SemiBold" Margin="0,0,0,7"/>
                    <ComboBox x:Name="ExportFormatBox" Height="42" AutomationProperties.Name="Export format" ToolTip="Best available keeps source quality. A specific format may require compatible source codecs or audio conversion."/>
                </StackPanel>
            </Grid>
            <TextBlock Grid.Row="1" Margin="0,8,0,8" TextWrapping="Wrap" Foreground="{StaticResource Muted}" FontSize="12" Text="Original formats preserve source quality. MP4 uses compatible source codecs; conversion cannot improve source quality."/>
            <Expander Grid.Row="2" Header="Sign-in and download options" Foreground="#C8D3E2">
            <StackPanel Margin="0,10,0,0">
                <CheckBox x:Name="AlternateBox" Content="Alternate transfer (direct file)" Margin="0,0,0,6" ToolTip="Explicit alternative transport for a public direct HTTPS video file only. MP4, WebM, MKV or MOV; HTTPS port 443, no query strings or redirects. Not a webpage extractor or automatic retry."/>
                <TextBlock Text="Alternate mode: public direct HTTPS MP4/WebM/MKV/MOV file only (no query strings or redirects). Use Video / Best available; turn off sign-in, playlist and Embed metadata, and clear cookies. Original bytes; no conversion or resume. Requires ffprobe." TextWrapping="Wrap" FontSize="12" Foreground="{StaticResource Muted}" Margin="0,0,0,12"/>
                <WrapPanel Margin="0,0,0,7">
                    <CheckBox x:Name="UseBrowserBox" Content="Use browser sign-in" Margin="0,0,10,0" ToolTip="Optional: use your browser session for media you are authorized to access. Cookie-file mode takes precedence."/>
                    <ComboBox x:Name="BrowserBox" Width="220" Height="30" SelectedIndex="2" IsEnabled="True" Padding="5" AutomationProperties.Name="Browser" ToolTip="Select the browser in which you are signed in">
                        <ComboBoxItem Content="Chrome (Windows may block)" Tag="chrome"/>
                        <ComboBoxItem Content="Edge (Windows may block)" Tag="edge"/>
                        <ComboBoxItem Content="Firefox (recommended)" Tag="firefox"/>
                    </ComboBox>
                </WrapPanel>
                <TextBlock Text="Browser profile (optional; blank uses the default)" Foreground="{StaticResource Muted}" FontSize="12"/>
                <TextBox x:Name="ProfileBox" Height="36" Margin="0,4,0,7" AutomationProperties.Name="Browser profile" ToolTip="Optional profile name, such as Default or Profile 1. Leave blank for the engine default."/>
                <StackPanel Orientation="Horizontal">
                    <CheckBox x:Name="PlaylistBox" Content="Allow playlist" Margin="0,0,18,0" ToolTip="A playlist may download many files. Leave off to request a single item."/>
                    <CheckBox x:Name="MetadataBox" Content="Embed metadata" IsChecked="True" ToolTip="Add source tags when FFmpeg is available; this does not increase media quality."/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,7,0,0">
                    <TextBox x:Name="CookieFileBox" Width="175" Height="30" IsReadOnly="True" Padding="7,4" ToolTip="Optional Netscape-format cookies.txt; used instead of browser sign-in"/>
                    <Button x:Name="CookieFileButton" Content="Cookie file" Style="{StaticResource SecondaryButton}" Padding="10,4" Margin="7,0,0,0"/>
                    <Button x:Name="ClearCookieButton" Content="Clear" Style="{StaticResource SecondaryButton}" Padding="8,4" Margin="5,0,0,0"/>
                </StackPanel>
            </StackPanel>
            </Expander>
        </Grid>

        <Border Grid.Row="8" Background="{StaticResource Panel}" CornerRadius="16" BorderBrush="#26354A" BorderThickness="1" Padding="18">
        <Grid>
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="14"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="10"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Grid Grid.Row="0" Grid.ColumnSpan="5" Margin="0,0,0,4">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <StackPanel><TextBlock Text="ACTIVITY" Style="{StaticResource MetricLabel}"/><StackPanel Orientation="Horizontal"><Ellipse x:Name="ActivityDot" Width="8" Height="8" Fill="{StaticResource Accent}" Margin="0,0,8,0"/><TextBlock x:Name="PhaseText" Text="Ready" FontSize="16" FontWeight="SemiBold"/></StackPanel></StackPanel>
                <StackPanel Grid.Column="1"><TextBlock Text="TRANSFER SPEED" Style="{StaticResource MetricLabel}"/><TextBlock x:Name="SpeedText" Text="Not started" FontSize="16" ToolTip="Measured speed for the current stream, not your connection's maximum speed."/></StackPanel>
                <StackPanel Grid.Column="2"><TextBlock Text="TIME REMAINING" Style="{StaticResource MetricLabel}"/><TextBlock x:Name="EtaText" Text="Not available" FontSize="16" ToolTip="Engine estimate for the current stream. Merging or additional streams can take extra time."/></StackPanel>
            </Grid>
            <Grid Grid.Row="2" Grid.Column="0" VerticalAlignment="Center">
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="5"/><RowDefinition Height="18"/></Grid.RowDefinitions>
                <TextBlock x:Name="ProgressText" Text="0%" HorizontalAlignment="Right" Foreground="{StaticResource Muted}" FontSize="12" FontWeight="SemiBold"/>
                <ProgressBar x:Name="ProgressBar" Grid.Row="2" Height="10" Minimum="0" Maximum="100" Value="0" Foreground="{StaticResource Accent}" Background="#253248" AutomationProperties.Name="Current stream progress" ToolTip="Progress is per stream; separate audio and video may each start at zero."/>
            </Grid>
            <Button x:Name="DownloadButton" Grid.Row="2" Grid.Column="2" Content="Download" Style="{StaticResource PrimaryButton}" ToolTip="Download media you have permission to save"/>
            <Button x:Name="CancelButton" Grid.Row="2" Grid.Column="4" Content="Cancel" Style="{StaticResource SecondaryButton}" IsEnabled="False" ToolTip="Cancel a download or setup before install commit. Once commit starts, setup must finish safely."/>
        </Grid>
        </Border>

        <Border Grid.Row="10" Background="{StaticResource Panel}" BorderBrush="#26354A" BorderThickness="1" CornerRadius="12" Padding="14">
            <Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                <TextBlock x:Name="StatusText" Text="Ready" TextWrapping="Wrap" Foreground="{StaticResource Accent}" FontWeight="SemiBold"/>
                <Expander Grid.Row="2" Header="Activity details" Foreground="{StaticResource Muted}" ToolTip="Expand to inspect errors and engine output">
                <TextBox x:Name="LogBox" Height="150" Margin="0,10,0,0" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap"
                         VerticalScrollBarVisibility="Auto" Background="Transparent" BorderThickness="0" Padding="0"
                         Foreground="#AEBED1" FontFamily="Consolas" FontSize="11"/>
                </Expander>
            </Grid>
        </Border>

        <Grid Grid.Row="12">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="10"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock x:Name="EngineText" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,10,0" Foreground="{StaticResource Muted}" FontSize="12"/>
            <Button x:Name="SetupButton" Grid.Column="1" Content="Install engine" Style="{StaticResource SecondaryButton}" Padding="14,7"/>
            <Button x:Name="OpenFolderButton" Grid.Column="3" Content="Open folder" Style="{StaticResource SecondaryButton}" Padding="14,7"/>
        </Grid>
    </Grid>
    </ScrollViewer>
</Window>
'@

$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$names = @('UrlBox','FolderBox','BrowseButton','MediaTypeBox','ExportFormatBox','UseBrowserBox','BrowserBox','ProfileBox','CookieFileBox','CookieFileButton','ClearCookieButton','PlaylistBox','MetadataBox','ProgressBar','ProgressText','DownloadButton','CancelButton','StatusText','LogBox','EngineText','SetupButton','OpenFolderButton','ReduceMotionBox','ActivityDot','PhaseText','SpeedText','EtaText','AlternateBox')
foreach ($name in $names) { Set-Variable -Name $name -Value $window.FindName($name) }
$script:isRunning = $false
$script:unknownProgress = $false
$ReduceMotionBox.IsChecked = -not [System.Windows.SystemParameters]::ClientAreaAnimation

function Update-Motion {
    $ActivityDot.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
    $ActivityDot.Opacity = 1
    $ProgressBar.IsIndeterminate = $script:unknownProgress -and -not $ReduceMotionBox.IsChecked
    if ($script:isRunning -and -not $ReduceMotionBox.IsChecked) {
        $pulse = [Windows.Media.Animation.DoubleAnimation]::new(0.35, 1.0, [Windows.Duration]::new([TimeSpan]::FromSeconds(0.9)))
        $pulse.AutoReverse = $true
        $pulse.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $ActivityDot.BeginAnimation([Windows.UIElement]::OpacityProperty, $pulse)
    }
}
function Set-UnknownProgress([bool]$unknown) {
    $script:unknownProgress = $unknown
    $ProgressBar.IsIndeterminate = $unknown -and -not $ReduceMotionBox.IsChecked
}
$ReduceMotionBox.Add_Checked({ Update-Motion })
$ReduceMotionBox.Add_Unchecked({ Update-Motion })

$defaultFolder = Get-DefaultDownloadFolder ([Environment]::GetFolderPath('MyVideos')) ([Environment]::GetFolderPath('UserProfile'))
$FolderBox.Text = $defaultFolder
$script:process = $null
$script:cancelRequested = $false
$script:drainTimedOut = $false
$script:legacyAttempt = $null
$script:setupReady = $false
$script:setupFinishing = $false
$script:failureHint = $null
$script:operation = 'download'
$script:alternateTransfer = $false
$script:lastFile = $null
$script:savedFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$stateDirectory = Join-Path $env:LOCALAPPDATA 'VidNap'
$setupDecisionPath = Join-Path $stateDirectory '.vidnap-setup-decision'
$settingsPath = Join-Path $stateDirectory 'settings.json'

function Find-Program([string]$localPath, [string]$commandName) {
    if (Test-Path -LiteralPath $localPath -PathType Leaf) {
        $file = Get-Item -LiteralPath $localPath
        if ($file.Length -gt 1MB) {
            $stream=$null
            try {
                $stream=[IO.File]::OpenRead($file.FullName)
                if ($stream.ReadByte() -eq 77 -and $stream.ReadByte() -eq 90) { return $file.FullName }
            } catch {} finally { if ($stream) { $stream.Dispose() } }
        }
    }
    $command = Get-Command $commandName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}

function Get-Tools {
    $ytDlp = Find-Program (Join-Path $stateDirectory 'tools\yt-dlp.exe') 'yt-dlp'
    $ffmpeg = Find-Program (Join-Path $stateDirectory 'tools\ffmpeg\ffmpeg.exe') 'ffmpeg'
    $ffprobe = Find-Program (Join-Path $stateDirectory 'tools\ffmpeg\ffprobe.exe') 'ffprobe'
    $deno = Find-Program (Join-Path $stateDirectory 'tools\deno.exe') 'deno'
    if (-not $ffprobe) { $ffmpeg=$null }
    return @{ YtDlp = $ytDlp; Ffmpeg = $ffmpeg; Ffprobe=$ffprobe; Deno=$deno }
}

function Update-EngineStatus {
    $tools = Get-Tools
    if ($tools.YtDlp -and $tools.Ffmpeg) {
        $EngineText.Text = if ($tools.Deno) { 'Engine ready: yt-dlp + FFmpeg + Deno' } else { 'yt-dlp + FFmpeg ready; update engine to add Deno for YouTube' }
        $SetupButton.Content = 'Update engine'
    } elseif ($tools.YtDlp) {
        $EngineText.Text = 'FFmpeg / ffprobe missing; best video uses a combined stream'
        $SetupButton.Content = 'Install FFmpeg'
    } else {
        $EngineText.Text = 'Download engine is not installed'
        $SetupButton.Content = 'Install engine'
    }
    $EngineText.ToolTip = "Managed tools: $(Join-Path $stateDirectory 'tools')"
}

function Add-Log([string]$line) {
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    $safeLine = Protect-LogText $line.TrimEnd()
    if ($safeLine.Length -gt 4096) { $safeLine = $safeLine.Substring(0,4096) + ' [truncated]' }
    $LogBox.AppendText($safeLine + [Environment]::NewLine)
    if ($LogBox.Text.Length -gt 64000) { $LogBox.Text = $LogBox.Text.Substring($LogBox.Text.Length - 48000) }
    $LogBox.ScrollToEnd()
}

function Handle-OperationError([string]$message) {
    try { Add-Log "VidNap operation error: $message" } catch {}
    if ($script:process -and $script:operation -eq 'setup') {
        # Until READY, setup may still reset the decision file. Never kill a
        # setup whose cancellation claim cannot yet be made safely.
        $won=$false
        if ($script:setupReady) {
            try { $won=Try-ClaimSetupDecision $setupDecisionPath 'cancel' }
            catch { try { Add-Log ('Setup cancellation could not be confirmed: ' + $_.Exception.Message) } catch {} }
        }
        if (-not $won) {
            $StatusText.Text='Setup is still running. Waiting for it to finish safely after an interface error.'
            $ProgressText.Text='Waiting for setup...'
            # Retain the runner and timer so completion can still be observed.
            return
        }
        $script:cancelRequested=$true
    }
    if ($script:process) {
        try { $script:process.Stop() } catch {}
        try { $script:process.Dispose() } catch {}
        $script:process=$null
    }
    Set-Running $false
    $StatusText.Text='The operation stopped. Review the error and retry.'
    $ProgressText.Text='Error'
}

$window.Dispatcher.add_UnhandledException({
    param($sender, $eventArgs)
    $message = $eventArgs.Exception.ToString()
    try {
        New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
        $errorLog = Join-Path $stateDirectory 'VidNap-error.log'
        if ((Test-Path $errorLog) -and (Get-Item $errorLog).Length -gt 256KB) { Clear-Content -LiteralPath $errorLog }
        Add-Content -LiteralPath $errorLog -Value (Protect-LogText ("[{0}] {1}" -f [DateTime]::Now.ToString('s'), $message)) -Encoding UTF8
    } catch {}
    try {
        Handle-OperationError $eventArgs.Exception.Message
    } catch {}
    $eventArgs.Handled = $true
})

function Set-Running([bool]$running) {
    $AlternateBox.IsEnabled = -not $running
    $script:isRunning = $running
    if (-not $running) {
        Set-UnknownProgress $false
        $SpeedText.Text = 'Not active'
        $EtaText.Text = 'Not available'
        $PhaseText.Text = 'Stopped'
    }
    Update-Motion
    $DownloadButton.IsEnabled = -not $running
    $CancelButton.IsEnabled = $running
    $BrowseButton.IsEnabled = -not $running
    $SetupButton.IsEnabled = -not $running
    $MediaTypeBox.IsEnabled = -not $running
    $ExportFormatBox.IsEnabled = -not $running
    $UrlBox.IsEnabled = -not $running
    $UseBrowserBox.IsEnabled = -not $running
    $BrowserBox.IsEnabled = -not $running
    $ProfileBox.IsEnabled = -not $running
    $PlaylistBox.IsEnabled = -not $running
    $MetadataBox.IsEnabled = -not $running
    $CookieFileButton.IsEnabled = -not $running
    $ClearCookieButton.IsEnabled = (-not $running) -and -not [string]::IsNullOrWhiteSpace($CookieFileBox.Text)
}

function Add-ExportFormat([string]$label, [string]$tag) {
    $item = [System.Windows.Controls.ComboBoxItem]::new()
    $item.Content = $label
    $item.Tag = $tag
    $ExportFormatBox.Items.Add($item) | Out-Null
}

function Update-ExportFormatOptions {
    $mediaItem = [System.Windows.Controls.ComboBoxItem]$MediaTypeBox.SelectedItem
    $mediaType = [string]$mediaItem.Tag
    $ExportFormatBox.Items.Clear()
    if ($mediaType -eq 'audio') {
        Add-ExportFormat 'Original codec (no conversion)' 'original'
        Add-ExportFormat 'MP3' 'mp3'
        Add-ExportFormat 'M4A / AAC' 'm4a'
        Add-ExportFormat 'FLAC (lossless encoding)' 'flac'
        Add-ExportFormat 'WAV (uncompressed)' 'wav'
        Add-ExportFormat 'Opus' 'opus'
    } else {
        Add-ExportFormat 'Best available (automatic container)' 'best'
        Add-ExportFormat 'MP4 (compatible)' 'mp4'
        Add-ExportFormat 'MKV' 'mkv'
        Add-ExportFormat 'WebM' 'webm'
    }
    $ExportFormatBox.SelectedIndex = 0
}

function Get-BrowserSessionInfo {
    $item = [System.Windows.Controls.ComboBoxItem]$BrowserBox.SelectedItem
    $source = [string]$item.Tag
    switch ($source) {
        'chrome' { return @{ DisplayName = 'Google Chrome'; CookieSource = 'chrome'; ProcessName = 'chrome' } }
        'edge' { return @{ DisplayName = 'Microsoft Edge'; CookieSource = 'edge'; ProcessName = 'msedge' } }
        'firefox' { return @{ DisplayName = 'Mozilla Firefox'; CookieSource = 'firefox'; ProcessName = 'firefox' } }
        default { throw 'Choose a supported browser session.' }
    }
}

function Save-Preferences {
    try {
        New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
        # Never persist media URLs, cookies, profiles, or authentication enablement.
        $preferences = @{ Folder=$FolderBox.Text; Media=[string]$MediaTypeBox.SelectedItem.Tag; Format=[string]$ExportFormatBox.SelectedItem.Tag; Browser=[string]$BrowserBox.SelectedItem.Tag }
        $preferences | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    } catch { Add-Log 'Preferences could not be saved. Downloads can still run.' }
}

function Get-AlternateSelectionError([string]$media, [string]$format, [bool]$browser, [string]$cookies, [bool]$playlist, [bool]$metadata) {
    if ($media -ne 'video' -or $format -ne 'best' -or $browser -or $cookies -or $playlist -or $metadata) {
        return 'Alternate transfer requires Video / Best available. Turn off browser sign-in, Allow playlist and Embed metadata, and clear any cookie file. Only a public direct HTTPS file is supported.'
    }
    return $null
}

function New-AlternateStartInfo([string]$url, [string]$folder, [string]$ffprobe, [string]$helperPath) {
    $uri=$null
    if (-not [Uri]::TryCreate($url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo) { throw 'Alternate transfer requires a public HTTPS URL without embedded credentials.' }
    if (-not $ffprobe) { throw 'Alternate transfer requires ffprobe. Use Install engine first.' }
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $info.Arguments=(@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$helperPath,'-Url',$url,'-Folder',$folder,'-Ffprobe',$ffprobe) | ForEach-Object { Quote-Argument $_ }) -join ' '
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.Encoding]::UTF8; $info.StandardErrorEncoding=[Text.Encoding]::UTF8
    return $info
}

function Get-LegacyTransferArguments {
    return @('--retries','0','--abort-on-unavailable-fragments')
}

function Start-Download {
    if ($script:process) { return }
    $script:legacyAttempt = $null
    try {
        if($FolderBox.Text -notmatch '^[Dd]:[\\/]' -or [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($FolderBox.Text)) -ine 'D:\'){throw 'Choose an explicit D: destination.'}
    } catch { $StatusText.Text='Choose an explicit D: destination. No files were accessed.'; return }
    $rawUrl = $UrlBox.Text.Trim()
    $uri = $null
    if (-not [Uri]::TryCreate($rawUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http','https')) {
        [System.Windows.MessageBox]::Show($window, 'Enter a complete http:// or https:// media URL.', 'VidNap', 'OK', 'Warning') | Out-Null
        return
    }

    $tools = Get-Tools
    $alternate=[bool]$AlternateBox.IsChecked
    if (-not $alternate -and -not $tools.YtDlp) {
        [System.Windows.MessageBox]::Show($window, 'Install the download engine first.', 'VidNap', 'OK', 'Information') | Out-Null
        return
    }

    $mediaItem = [System.Windows.Controls.ComboBoxItem]$MediaTypeBox.SelectedItem
    $formatItem = [System.Windows.Controls.ComboBoxItem]$ExportFormatBox.SelectedItem
    $mediaType = [string]$mediaItem.Tag
    $format = [string]$formatItem.Tag
    if ($alternate) {
        $selectionError=Get-AlternateSelectionError $mediaType $format ([bool]$UseBrowserBox.IsChecked) $CookieFileBox.Text ([bool]$PlaylistBox.IsChecked) ([bool]$MetadataBox.IsChecked)
        if ($selectionError) { $StatusText.Text=$selectionError; return }
        try { $alternateInfo=New-AlternateStartInfo $rawUrl $FolderBox.Text $tools.Ffprobe (Join-Path $PSScriptRoot 'VidNap.Alternate.ps1') }
        catch { $StatusText.Text=$_.Exception.Message; return }
    }
    $needsFfmpeg = ($mediaType -eq 'audio' -and $format -ne 'original') -or ($mediaType -eq 'video' -and $format -ne 'best')
    if ($needsFfmpeg -and -not $tools.Ffmpeg) {
        [System.Windows.MessageBox]::Show($window, 'This mode requires FFmpeg. Use Install engine first.', 'VidNap', 'OK', 'Information') | Out-Null
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($CookieFileBox.Text)) {
        if (-not (Test-Path -LiteralPath $CookieFileBox.Text -PathType Leaf)) {
            [System.Windows.MessageBox]::Show($window, 'The selected cookie file no longer exists.', 'VidNap', 'OK', 'Warning') | Out-Null
            return
        }
        try { $cookieHeader = Get-Content -LiteralPath $CookieFileBox.Text -TotalCount 1 }
        catch { $StatusText.Text='Cannot read the selected cookie file. Choose another file.'; return }
        if ($cookieHeader -notin @('# HTTP Cookie File','# Netscape HTTP Cookie File')) {
            [System.Windows.MessageBox]::Show($window, 'Choose a Netscape-format cookies.txt file. Its first line must be # HTTP Cookie File or # Netscape HTTP Cookie File.', 'VidNap', 'OK', 'Warning') | Out-Null
            return
        }
    }

    $folder = $FolderBox.Text
    try { $outputTemplate = Get-OutputTemplate $folder }
    catch { $StatusText.Text=$_.Exception.Message; return }
    try { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
    catch { $StatusText.Text = 'Cannot create the destination. Choose another folder.'; Add-Log $_.Exception.Message; return }
    try { $filenameBudget=Get-FilenameBudget $folder }
    catch { $StatusText.Text=$_.Exception.Message; return }
    $browserSession = $null
    if ($alternate) {
        $startInfo=$alternateInfo
        $startInfo.WorkingDirectory=$stateDirectory
    } else {
    try {
        $script:legacyAttempt=New-LegacyAttempt $folder $folder
        $outputTemplate=Get-OutputTemplate $script:legacyAttempt.Stage
        $filenameBudget=[Math]::Min((Get-FilenameBudget $folder),(Get-FilenameBudget $script:legacyAttempt.Stage))
    } catch { $StatusText.Text=$_.Exception.Message; return }
    $arguments = [System.Collections.Generic.List[string]]::new()
    Get-EngineBaseArguments $filenameBudget | ForEach-Object { $arguments.Add($_) }
    Get-PlaylistArguments ([bool]$PlaylistBox.IsChecked) | ForEach-Object { $arguments.Add($_) }
    if ($MetadataBox.IsChecked -and $tools.Ffmpeg) { $arguments.Add('--embed-metadata') }
    $browserSession = $null
    if (-not [string]::IsNullOrWhiteSpace($CookieFileBox.Text)) {
        $arguments.Add('--cookies')
        $arguments.Add($CookieFileBox.Text)
    } elseif ($UseBrowserBox.IsChecked) {
        $browserSession = Get-BrowserSessionInfo
        $arguments.Add('--cookies-from-browser')
        $profile = $ProfileBox.Text.Trim()
        if ($profile -and $profile -match '[\r\n]') { $StatusText.Text = 'Enter a single browser profile name or path.'; return }
        $cookieSource = $browserSession.CookieSource
        if ($profile) { $cookieSource += ':' + $profile }
        $arguments.Add($cookieSource)
    }
    if ($tools.Ffmpeg) {
        $arguments.Add('--ffmpeg-location')
        $arguments.Add((Split-Path -Parent $tools.Ffmpeg))
    }
    if ($tools.Deno) {
        $arguments.Add('--no-js-runtimes')
        $arguments.Add('--js-runtimes')
        $arguments.Add('deno:' + $tools.Deno)
    }
    Get-ExportArguments $mediaType $format ([bool]$tools.Ffmpeg) | ForEach-Object { $arguments.Add($_) }
    Get-LegacyTransferArguments | ForEach-Object { $arguments.Add($_) }
    $arguments.Add('-o'); $arguments.Add($outputTemplate); $arguments.Add('--'); $arguments.Add($rawUrl)

    $argumentLine = ($arguments | ForEach-Object { Quote-Argument $_ }) -join ' '
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $tools.YtDlp
    $startInfo.WorkingDirectory = $stateDirectory
    $startInfo.Arguments = $argumentLine
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
    }

    $script:process = [VidNapProcessRunner]::new()
    $script:operation = 'download'
    $script:drainTimedOut = $false
    $script:alternateTransfer = $alternate
    $script:lastFile = $null
    $script:reportedFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $script:savedFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $script:cancelRequested = $false
    $script:failureHint = $null
    $LogBox.Clear()
    Add-Log "Export selection: $($mediaItem.Content) - $($formatItem.Content)"
    if ($alternate) { Add-Log 'Engine: Alternate direct-file transfer. Original bytes; no webpage extraction, conversion or resume.' }
    else { Add-Log 'Engine: yt-dlp' }
    New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
    Save-Preferences
    if ($browserSession) {
        Add-Log "Using the saved $($browserSession.DisplayName) sign-in session. VidNap does not export or retain a cookie file."
    }
    if ($CookieFileBox.Text) { Add-Log 'Cookie file mode: yt-dlp may update the selected cookie file. Keep it private.' }
    $ProgressBar.Value = 0
    Set-UnknownProgress $true
    $PhaseText.Text = if ($alternate) { 'Alternate: preparing' } else { 'Preparing' }
    $SpeedText.Text = 'Waiting for data'
    $EtaText.Text = 'Not available'
    $ProgressText.Text = 'Preparing...'
    $StatusText.Text = 'Checking media and preparing download...'
    Set-Running $true
    try {
        $script:process.Start($startInfo)
    } catch {
        Set-Running $false
        $StatusText.Text = 'Could not start'
        Add-Log $_.Exception.Message
        Add-Log 'VidNap result: Download failed before the engine completed'
        if ($script:process) { $script:process.Dispose(); $script:process = $null }
    }
}

function Receive-OperationLine([string]$line) {
    if ($script:operation -eq 'setup') {
        Add-Log $line
        if ($script:cancelRequested -or $script:setupFinishing) { return }
        if ($line -eq 'VIDNAP_SETUP_READY') {
            $script:setupReady=$true; $CancelButton.IsEnabled=$true
            return
        }
        if ($line -match '^\[(\d)/6\]\s*(.*)') {
            Set-UnknownProgress $false
            $PhaseText.Text = 'Installing'
            $ProgressBar.Value = ([int]$Matches[1] - 1) * 100 / 6
            $StatusText.Text = $Matches[2]
            $ProgressText.Text = "Step $($Matches[1]) of 6"
        }
        return
    }
    $progress = ConvertFrom-ProgressLine $line
    if ($progress) {
        # Drain queued output after cancellation without making the UI appear
        # to resume transferring. Retain final file records for diagnostics.
        if ($script:cancelRequested -and $progress.Kind -ne 'File') { return }
        switch ($progress.Kind) {
            'File' {
                if (-not [string]::IsNullOrWhiteSpace($progress.Path)) {
                    if (-not $script:alternateTransfer) {
                        [void]$script:reportedFiles.Add($progress.Path)
                        return
                    }
                    $script:lastFile = $progress.Path
                    if ($script:savedFiles.Add($progress.Path)) { Add-Log "File reported: $($progress.Path)" }
                }
            }
            'Finishing' {
                Set-UnknownProgress $true; $ProgressText.Text='Finishing...'
                $StatusText.Text=if ($script:alternateTransfer) { 'Verifying the downloaded file...' } else { 'Merging, extracting or adding metadata...' }
                $PhaseText.Text=if ($script:alternateTransfer) { 'Verifying file' } else { 'Finishing' }
                $SpeedText.Text='Not transferring'; $EtaText.Text='Not available'
            }
            'Downloading' {
                Set-UnknownProgress (-not $progress.KnownTotal)
                $ProgressBar.Value = $progress.Percent
                $speed = if ($progress.Speed -gt 0) { '{0:0.0} MiB/s' -f ($progress.Speed / 1MB) } else { 'Waiting for data' }
                $eta = if ($progress.Eta -gt 0) { ' | {0:0}s remaining' -f $progress.Eta } else { '' }
                $ProgressText.Text = if ($progress.KnownTotal) { '{0:0.0}% of current stream' -f $progress.Percent } else { 'Downloading (size unknown)' }
                $StatusText.Text = "Downloading | $speed$eta"
                $PhaseText.Text = if ($script:alternateTransfer) { 'Alternate transfer' } else { 'Downloading' }
                $SpeedText.Text = $speed
                $EtaText.Text = if ($progress.Eta -gt 0) { '{0:0} seconds' -f $progress.Eta } else { 'Not available' }
            }
        }
        return
    }
    Add-Log $line
    $hint = Get-DownloadFailureHint $line
    if ($hint) { $script:failureHint = $hint }
}

function Complete-Operation([int]$exitCode) {
    if ($script:operation -eq 'download' -and -not $script:alternateTransfer -and -not $script:cancelRequested -and $exitCode -eq 0) {
        foreach ($path in $script:reportedFiles) {
            try {
                $promoted=Publish-LegacyOutput $script:legacyAttempt $path
                $script:lastFile=$promoted
                [void]$script:savedFiles.Add($promoted)
                Add-Log "File saved: $promoted"
            } catch { $exitCode=1; Add-Log $_.Exception.Message }
        }
        if ($exitCode -eq 0 -and $script:savedFiles.Count -gt 0 -and $script:legacyAttempt) {
            try {
                $stage = [IO.Path]::GetFullPath($script:legacyAttempt.Stage)
                if ([IO.Path]::GetFileName($stage) -cmatch '^legacy-attempt-[0-9a-f]{32}$' -and
                    [IO.Path]::GetDirectoryName($stage) -ieq $script:legacyAttempt.Destination) {
                    Assert-LegacyRegularPath $stage
                    [IO.Directory]::Delete($stage, $false)
                }
            } catch { }
        }
    }
    if ($script:operation -eq 'download' -and -not $script:alternateTransfer -and $script:legacyAttempt -and
        ($script:cancelRequested -or $exitCode -ne 0) -and [IO.Directory]::Exists($script:legacyAttempt.Stage)) {
        Add-Log ('Staged files retained at: ' + $script:legacyAttempt.Stage)
    }
    $state=Get-TerminalState -Operation $script:operation -CancelRequested $script:cancelRequested -ExitCode $exitCode -FailureHint $script:failureHint -SavedCount $script:savedFiles.Count -Alternate $script:alternateTransfer
    Set-UnknownProgress $false
    Set-Running $false
    if ($script:operation -eq 'setup') { Update-EngineStatus }
    if ($null -ne $state.ProgressValue) { $ProgressBar.Value=$state.ProgressValue }
    $PhaseText.Text=$state.Phase
    $ProgressText.Text=$state.ProgressText
    $StatusText.Text=$state.Status
    foreach ($line in $state.LogLines) { Add-Log $line }
}

$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(120)
$timer.Add_Tick({
    try {
        if (-not $script:process) { return }
        $completion=$script:process.CompletionState
        if($completion -ceq 'TimedOut'){$script:drainTimedOut=$true}
        $line = $null
        $batch = 0
        while ($batch -lt 100 -and $script:process.Output.TryDequeue([ref]$line)) {
            Receive-OperationLine $line
            $batch++
        }

        if ($completion -cne 'Pending' -and $script:process.Output.IsEmpty) {
            $exitCode = $script:process.ExitCode
            if($script:drainTimedOut){$exitCode=1; Add-Log 'Incomplete output drain.'}
            $script:process.Dispose()
            $script:process = $null
            Complete-Operation $exitCode
        }
    } catch {
        Handle-OperationError $_.Exception.Message
    }
})
$timer.Start()

$BrowseButton.Add_Click({
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = 'Choose a destination folder on D: drive. VidNap requires D: for safe atomic staging.'
    $dialog.SelectedPath = $FolderBox.Text
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $FolderBox.Text = $dialog.SelectedPath }
    $dialog.Dispose()
})

$DownloadButton.Add_Click({ Start-Download })
$MediaTypeBox.Add_SelectionChanged({ Update-ExportFormatOptions })
# Browser choice is only a preference. Credential use requires the explicit
# Use browser sign-in checkbox; changing the choice also preserves cookie mode.
$CookieFileButton.Add_Click({
    $dialog = [System.Windows.Forms.OpenFileDialog]::new()
    $dialog.Title = 'Choose a Netscape-format cookies.txt file'
    $dialog.Filter = 'Cookie text files (*.txt)|*.txt|All files (*.*)|*.*'
    $dialog.CheckFileExists = $true
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $CookieFileBox.Text = $dialog.FileName
        $UseBrowserBox.IsChecked = $false
        $StatusText.Text = 'Cookie file selected. The engine can update this file; treat it as a password.'
        $ClearCookieButton.IsEnabled = $true
    }
    $dialog.Dispose()
})
$ClearCookieButton.Add_Click({ $CookieFileBox.Clear(); $ClearCookieButton.IsEnabled = $false })
function Request-OperationCancel {
    if ($script:process -and $script:process.IsRunning) {
        if ($script:operation -eq 'setup') {
            if (-not $script:setupReady -or $script:setupFinishing -or $script:cancelRequested) { return }
            try { $won = Try-ClaimSetupDecision $setupDecisionPath 'cancel' }
            catch {
                Add-Log ('Could not claim setup cancellation: ' + $_.Exception.Message)
                $StatusText.Text='Cancellation could not be confirmed. Waiting for setup to finish safely.'
                return
            }
            if (-not $won) {
                $script:setupFinishing=$true; $CancelButton.IsEnabled=$false
                $StatusText.Text='Install commit has started. Waiting for setup to finish safely.'
                $ProgressText.Text='Finishing installation...'; $PhaseText.Text='Finishing'
                return
            }
        }
        $script:cancelRequested = $true
        $StatusText.Text = 'Cancelling...'
        $ProgressText.Text = 'Cancelling...'
        $PhaseText.Text = 'Cancelling'
        try { $script:process.Stop() } catch { Add-Log $_.Exception.Message }
    }
}
$CancelButton.Add_Click({ Request-OperationCancel })

$SetupButton.Add_Click({
    if ($script:process) { return }
    $setup = Join-Path $PSScriptRoot 'Setup-VidNap.ps1'
    $answer = [System.Windows.MessageBox]::Show(
        $window,
        "VidNap will download yt-dlp, FFmpeg and Deno into Local AppData, verify their checksums, and install them. Your window will show setup progress. Continue?",
        'Install VidNap engine',
        'YesNo',
        'Question'
    )
    if ($answer -ne 'Yes') { return }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $startInfo.Arguments = (@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$setup,'-Channel','nightly') | ForEach-Object { Quote-Argument $_ }) -join ' '
    $startInfo.UseShellExecute=$false; $startInfo.CreateNoWindow=$true
    $startInfo.RedirectStandardOutput=$true; $startInfo.RedirectStandardError=$true
    $script:process = [VidNapProcessRunner]::new()
    $script:operation='setup'; $script:cancelRequested=$false; $script:drainTimedOut=$false
    $script:setupReady=$false; $script:setupFinishing=$false
    $LogBox.Clear(); $ProgressBar.Value=0; Set-UnknownProgress $true
    $PhaseText.Text='Installing'; $SpeedText.Text='Not available'; $EtaText.Text='Not available'
    $ProgressText.Text='Installing...'; $StatusText.Text='Preparing engine setup...'
    Set-Running $true
    # Wait for this child's READY after lock acquisition and decision reset.
    $CancelButton.IsEnabled=$false
    try { $script:process.Start($startInfo) }
    catch { $script:process.Dispose(); $script:process=$null; Set-Running $false; Set-UnknownProgress $false; $StatusText.Text='Setup could not start'; Add-Log $_.Exception.Message }
})

$OpenFolderButton.Add_Click({
    New-Item -ItemType Directory -Force -Path $FolderBox.Text | Out-Null
    Start-Process explorer.exe -ArgumentList (Quote-Argument $FolderBox.Text)
})

$window.Add_Closing({
    param($sender,$eventArgs)
    if ($script:process -and $script:operation -eq 'setup') {
        $eventArgs.Cancel=$true; $StatusText.Text='Use Cancel to stop setup before commit, then close once setup has stopped.'; return
    }
    if ($script:process -and -not $script:process.IsComplete) {
        $answer = [System.Windows.MessageBox]::Show($window, 'A download is running. Cancel it and close VidNap?', 'VidNap', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { $eventArgs.Cancel = $true; return }
        try { $script:process.Stop() } catch {}
    }
    if ($script:process) { $script:process.Dispose(); $script:process=$null }
    Save-Preferences
    $timer.Stop()
    $ActivityDot.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
})

Update-ExportFormatOptions
if (Test-Path -LiteralPath $settingsPath) {
    try {
        $saved = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
        # Validate the whole record before changing any controls. A partial
        # record must not apply some values and then falsely report defaults.
        Assert-Preferences $saved
        if ($saved.Folder -and [IO.Path]::IsPathRooted([string]$saved.Folder)) { $FolderBox.Text=[string]$saved.Folder }
        foreach ($item in $MediaTypeBox.Items) { if ($item.Tag -eq $saved.Media) { $MediaTypeBox.SelectedItem=$item; break } }
        foreach ($item in $ExportFormatBox.Items) { if ($item.Tag -eq $saved.Format) { $ExportFormatBox.SelectedItem=$item; break } }
        foreach ($item in $BrowserBox.Items) { if ($item.Tag -eq $saved.Browser) { $BrowserBox.SelectedItem=$item; break } }
    } catch { Add-Log 'Saved preferences were invalid. Default settings are in use.' }
}
Update-EngineStatus
if ($env:VIDNAP_SMOKE_TEST -eq '1') {
    $timer.Stop()
    Write-Output "VidNap WPF initialization OK - $($EngineText.Text)"
    return
}
$UrlBox.Focus() | Out-Null
$window.ShowDialog() | Out-Null
