#Requires -Version 5.1
<#
.SYNOPSIS
    A window for checking who is on a shared Remote Desktop machine before you
    connect, without disturbing anyone.

.DESCRIPTION
    Type the machine, the account and its password, and press Check now. The
    window shows, in plain words, whether that account's session is free, in use,
    idle, locked or disconnected, who is connected and from where, everyone else
    signed in, and what the remaining system entries are. From there you can
    connect, ask the person in the session to let you take over, watch their
    screen, or get a notification when the machine is free.

    Keep this file next to Connect-SharedRdp.ps1 (version 1.3 or later): every
    check runs through it, in the background, so the window never freezes.

    The password is kept in memory until the window closes and is never written
    to disk. Machine and account names of recent checks are remembered in
    %APPDATA%\SharedRdp\dashboard.json.

.PARAMETER ComputerName
    Machine to fill in when the window opens (name or IP address, optionally :port).

.PARAMETER UserName
    Account to fill in when the window opens, for example LAB-07\tester.

.PARAMETER RefreshSeconds
    How often "Re-check every ..." and "Tell me when it's free" check again. Default 30.

.PARAMETER IdleMinutes
    No input for this long counts as idle instead of in use. Default 5.

.PARAMETER BusyProcess
    Process names that mean automation is running in a session (wildcards allowed).

.PARAMETER AskTimeoutSeconds
    How long "Ask to take over" waits for an answer. Default 60.

.PARAMETER EnginePath
    Path of Connect-SharedRdp.ps1. Defaults to the folder of this script.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\SharedRdp-Dashboard.ps1

.EXAMPLE
    .\SharedRdp-Dashboard.ps1 -ComputerName 192.168.222.225 -UserName Administrator

.NOTES
    Windows only. Runs in Windows PowerShell 5.1 and PowerShell 7.
    SharedRdp-Dashboard.cmd opens it without a console window.
#>
[CmdletBinding()]
param(
    [string] $ComputerName,

    [string] $UserName,

    [ValidateRange(10, 3600)]
    [int] $RefreshSeconds = 30,

    [ValidateRange(1, 1440)]
    [int] $IdleMinutes = 5,

    [string[]] $BusyProcess = @(),

    [ValidateRange(10, 600)]
    [int] $AskTimeoutSeconds = 60,

    [string] $EnginePath
)

$script:DashboardVersion = '1.1'
$script:Options = @{
    Host       = $ComputerName
    User       = $UserName
    Refresh    = $RefreshSeconds
    Idle       = $IdleMinutes
    Busy       = @($BusyProcess | Where-Object { $_ } | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ })
    AskTimeout = $AskTimeoutSeconds
}

#region Start-up

function Show-StartupError {
    param([string] $Message)
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        $null = [System.Windows.MessageBox]::Show($Message, 'Shared Remote Desktop', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
    catch {
        Write-Error $Message
    }
}

$onWindows = ($PSVersionTable.PSVersion.Major -le 5) -or [bool] (Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
if (-not $onWindows) {
    Write-Error 'The dashboard needs Windows: it uses WPF and the Remote Desktop Services API.'
    exit 1
}

# WPF needs a single-threaded apartment. Windows PowerShell and PowerShell 7 use
# one by default; if this one doesn't, start again with -STA.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    $relaunch = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    foreach ($key in $PSBoundParameters.Keys) {
        $value = $PSBoundParameters[$key]
        if ($value -is [System.Management.Automation.SwitchParameter] -or $value -is [bool]) {
            if ($value) { $relaunch += ('-{0}' -f $key) }
            continue
        }
        if ($value -is [array]) { $value = $value -join ',' }
        $relaunch += @(('-{0}' -f $key), ('"{0}"' -f $value))
    }
    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $relaunch
    exit 0
}

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing -ErrorAction Stop
}
catch {
    Write-Error ("Couldn't load the Windows UI libraries: {0}" -f $_.Exception.Message)
    exit 1
}

if (-not $EnginePath) { $EnginePath = Join-Path $PSScriptRoot 'Connect-SharedRdp.ps1' }
if (-not (Test-Path -LiteralPath $EnginePath -PathType Leaf)) {
    Show-StartupError ("Connect-SharedRdp.ps1 is missing. The dashboard looked for it here:`n{0}`n`nKeep both files in the same folder." -f $EnginePath)
    exit 1
}
$script:EnginePath = (Resolve-Path -LiteralPath $EnginePath).ProviderPath

# The engine is loaded as a module so its parameters don't land in this script's
# variables. Its functions are then copied into the background runspaces.
try {
    $script:Engine = New-Module -Name SharedRdpEngine -ArgumentList $script:EnginePath -ScriptBlock {
        param($Path)
        . $Path
        Export-ModuleMember -Function *
    }
    $null = $script:Engine | Import-Module -DisableNameChecking -PassThru
    $needed = @('Get-HostStatus', 'Get-LastClientMap', 'Find-LastClient', 'Get-AskMessage', 'Get-SystemSessionMeaning', 'New-UnknownResult', 'Send-AskMessage')
    $missing = @($needed | Where-Object { -not $script:Engine.ExportedFunctions.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        throw ('this copy is too old for the dashboard (it lacks {0}); use version 1.3 or later' -f ($missing -join ', '))
    }
    Initialize-Native
    $script:EngineVersion = & $script:Engine { $script:ScriptVersion }
}
catch {
    Show-StartupError ("Couldn't load {0}:`n{1}" -f $script:EnginePath, $_.Exception.Message)
    exit 1
}

if (-not ('SharedRdpUi.NativeWindow' -as [type])) {
    try {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace SharedRdpUi
{
    public static class NativeWindow
    {
        [StructLayout(LayoutKind.Sequential)]
        struct FLASHWINFO
        {
            public uint cbSize;
            public IntPtr hwnd;
            public uint dwFlags;
            public uint uCount;
            public uint dwTimeout;
        }

        [DllImport("dwmapi.dll")]
        static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

        [DllImport("user32.dll")]
        static extern bool FlashWindowEx(ref FLASHWINFO info);

        // Dark title bar: attribute 20 on Windows 10 2004 and later, 19 before that.
        public static void SetDarkTitleBar(IntPtr hwnd, bool dark)
        {
            int value = dark ? 1 : 0;
            if (DwmSetWindowAttribute(hwnd, 20, ref value, 4) != 0)
                DwmSetWindowAttribute(hwnd, 19, ref value, 4);
        }

        // Flash the taskbar button until the window comes to the front.
        public static void Flash(IntPtr hwnd)
        {
            FLASHWINFO info = new FLASHWINFO();
            info.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
            info.hwnd = hwnd;
            info.dwFlags = 3 | 12;  // FLASHW_ALL | FLASHW_TIMERNOFG
            info.uCount = uint.MaxValue;
            info.dwTimeout = 0;
            FlashWindowEx(ref info);
        }
    }
}
'@
    }
    catch {
        Write-Verbose ("Window helpers unavailable: {0}" -f $_.Exception.Message)
    }
}

#endregion

#region Look

function Test-WindowsDarkMode {
    try {
        $value = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop
        return ([int] $value -eq 0)
    }
    catch {
        return $false
    }
}

$script:IsDark = Test-WindowsDarkMode
if ($script:IsDark) {
    $script:Palette = @{
        Page = '#1C1F23'; Surface = '#24282D'; Raised = '#2B3036'; Line = '#3A4047'; Input = '#1F2327'
        Ink = '#EEF0F2'; Ink2 = '#BCC3CC'; Muted = '#959DA8'; Link = '#6EA8F0'; Focus = '#3987E5'
        Hover = '#30363D'; Selected = '#363D45'; Primary = '#EEF0F2'; OnPrimary = '#1C1F23'
    }
    $disconnectedFill = '#3987E5'
    $disconnectedInk = '#1D2125'
}
else {
    $script:Palette = @{
        Page = '#EEF1F4'; Surface = '#FFFFFF'; Raised = '#F4F6F8'; Line = '#D3D9E0'; Input = '#FFFFFF'
        Ink = '#1D2125'; Ink2 = '#4A525C'; Muted = '#646C77'; Link = '#1F63BD'; Focus = '#2A78D6'
        Hover = '#E5E9EE'; Selected = '#DCE2E9'; Primary = '#1D2125'; OnPrimary = '#FFFFFF'
    }
    $disconnectedFill = '#2A78D6'
    $disconnectedInk = '#FFFFFF'
}

# State colors are the fixed status set (good, warning, serious, critical) plus a
# blue for "disconnected" and a slate for "unknown". Every state also carries its
# word and an icon, so nothing depends on color alone. The ink inside each fill is
# whichever of white or near-black contrasts more.
$script:StatusFill = @{
    None = $script:Palette.Raised; Free = '#0CA30C'; Disconnected = $disconnectedFill; Locked = '#FAB219'
    Idle = '#FAB219'; InUse = '#D03B3B'; Busy = '#D03B3B'; Connecting = '#EC835A'; Unknown = '#6B737D'
}
$script:StatusInk = @{
    None = $script:Palette.Ink2; Free = '#1D2125'; Disconnected = $disconnectedInk; Locked = '#1D2125'
    Idle = '#1D2125'; InUse = '#FFFFFF'; Busy = '#FFFFFF'; Connecting = '#1D2125'; Unknown = '#FFFFFF'
}
$script:StatusWord = @{
    None = 'Not checked'; Free = 'Free'; Disconnected = 'Disconnected'; Locked = 'Locked'; Idle = 'Idle'
    InUse = 'In use'; Busy = 'Busy'; Connecting = 'Signing in'; Unknown = 'Unknown'
}
$script:StatusGlyph = @{
    None = [string][char]0xE721; Free = [string][char]0xE73E; Disconnected = [string][char]0xE823
    Locked = [string][char]0xE72E; Idle = [string][char]0xE708; InUse = [string][char]0xE77B
    Busy = [string][char]0xE713; Connecting = [string][char]0xE895; Unknown = [string][char]0xE9CE
}
$script:Ellipsis = [string][char]0x2026

$script:XamlTemplate = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Shared Remote Desktop"
        Width="1180" Height="820" MinWidth="980" MinHeight="660"
        WindowStartupLocation="CenterScreen"
        Background="@Page@" Foreground="@Ink@"
        FontFamily="Segoe UI" FontSize="13"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="@Input@"/>
      <Setter Property="Foreground" Value="@Ink@"/>
      <Setter Property="BorderBrush" Value="@Line@"/>
      <Setter Property="CaretBrush" Value="@Ink@"/>
      <Setter Property="SelectionBrush" Value="@Focus@"/>
      <Setter Property="Padding" Value="8,7"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="PasswordBox">
      <Setter Property="Background" Value="@Input@"/>
      <Setter Property="Foreground" Value="@Ink@"/>
      <Setter Property="BorderBrush" Value="@Line@"/>
      <Setter Property="CaretBrush" Value="@Ink@"/>
      <Setter Property="SelectionBrush" Value="@Focus@"/>
      <Setter Property="Padding" Value="8,7"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="@Ink@"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="@Muted@"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="FactLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="@Ink2@"/>
    </Style>
    <Style x:Key="FactValue" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Bahnschrift, Segoe UI"/>
      <Setter Property="FontSize" Value="20"/>
      <Setter Property="Margin" Value="0,3,0,1"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style x:Key="FactSub" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="@Muted@"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style x:Key="ButtonBase" TargetType="Button">
      <Setter Property="Foreground" Value="@Ink@"/>
      <Setter Property="Background" Value="@Surface@"/>
      <Setter Property="BorderBrush" Value="@Line@"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Ring" BorderThickness="2" BorderBrush="Transparent" CornerRadius="8">
              <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
              </Border>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.86"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.72"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Ring" Property="BorderBrush" Value="@Focus@"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.38"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource ButtonBase}">
      <Setter Property="Background" Value="@Primary@"/>
      <Setter Property="BorderBrush" Value="@Primary@"/>
      <Setter Property="Foreground" Value="@OnPrimary@"/>
    </Style>
    <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource ButtonBase}">
      <Setter Property="Background" Value="#D03B3B"/>
      <Setter Property="BorderBrush" Value="#D03B3B"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
    </Style>
    <Style x:Key="QuietButton" TargetType="Button" BasedOn="{StaticResource ButtonBase}">
      <Setter Property="Background" Value="@Surface@"/>
      <Setter Property="BorderBrush" Value="@Line@"/>
      <Setter Property="Foreground" Value="@Ink@"/>
    </Style>
    <Style x:Key="LinkButton" TargetType="Button" BasedOn="{StaticResource ButtonBase}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Foreground" Value="@Link@"/>
      <Setter Property="Padding" Value="2,1"/>
      <Setter Property="FontWeight" Value="Normal"/>
    </Style>
    <Style x:Key="RecentItem" TargetType="ListBoxItem">
      <Setter Property="Foreground" Value="@Ink@"/>
      <Setter Property="Padding" Value="8,7"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Bd" Background="Transparent" BorderBrush="Transparent" BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="@Hover@"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="@Selected@"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="@Focus@"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="28,20,28,14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <DockPanel Grid.Row="0" Margin="0,0,0,22">
      <TextBlock x:Name="IdentityText" DockPanel.Dock="Right" VerticalAlignment="Bottom" Foreground="@Muted@" FontSize="12"/>
      <StackPanel>
        <TextBlock Text="Shared Remote Desktop" FontSize="20" FontWeight="SemiBold"/>
        <TextBlock Text="See who is using a machine before you connect. Checking never disturbs anyone." Foreground="@Ink2@" Margin="0,3,0,0"/>
      </StackPanel>
    </DockPanel>

    <ScrollViewer x:Name="PageScroll" Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">
    <Grid MinHeight="{Binding ViewportHeight, ElementName=PageScroll}">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="280"/>
        <ColumnDefinition Width="32"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <DockPanel Grid.Column="0">
        <StackPanel DockPanel.Dock="Top">
          <TextBlock Text="Machine" Style="{StaticResource FieldLabel}"/>
          <TextBox x:Name="HostBox" ToolTip="Name or IP address, optionally with :port"/>
          <TextBlock Text="Account" Style="{StaticResource FieldLabel}" Margin="0,16,0,6"/>
          <TextBox x:Name="UserBox" ToolTip="For example LAB-07\tester, DOMAIN\user or Administrator"/>
          <TextBlock x:Name="UserHint" Style="{StaticResource Hint}" Margin="0,6,0,0" Text="The shared account you connect as. Leave it empty to check as yourself."/>
          <TextBlock Text="Password" Style="{StaticResource FieldLabel}" Margin="0,16,0,6"/>
          <PasswordBox x:Name="PassBox"/>
          <TextBlock x:Name="PassHint" Style="{StaticResource Hint}" Margin="0,6,0,0" Text="Kept in memory until you close this window."/>
          <Button x:Name="CheckButton" Style="{StaticResource PrimaryButton}" IsDefault="True" Margin="0,20,0,0" Padding="14,10">
            <TextBlock x:Name="CheckButtonText" Text="Check now"/>
          </Button>
          <CheckBox x:Name="AutoBox" Margin="2,14,0,0" Content="Re-check every 30 s"/>
          <TextBlock Text="Recent machines" Style="{StaticResource FieldLabel}" Margin="0,30,0,6"/>
          <TextBlock x:Name="RecentEmpty" Style="{StaticResource Hint}" Text="Machines you check appear here. Click one to check it again."/>
        </StackPanel>
        <ListBox x:Name="RecentList" Background="Transparent" BorderThickness="0" Margin="-8,0,-8,0" ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
      </DockPanel>

      <Grid Grid.Column="2">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border x:Name="Banner" Grid.Row="0" Visibility="Collapsed" Margin="0,0,0,14" CornerRadius="8" Padding="14,10" BorderThickness="1" Background="@Raised@" BorderBrush="@Line@">
          <DockPanel>
            <Button x:Name="BannerClose" DockPanel.Dock="Right" Style="{StaticResource LinkButton}" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="@Muted@" Content="&#xE711;" VerticalAlignment="Center" Margin="10,0,0,0" ToolTip="Dismiss" AutomationProperties.Name="Dismiss"/>
            <Button x:Name="BannerAction" DockPanel.Dock="Right" Style="{StaticResource PrimaryButton}" Visibility="Collapsed" VerticalAlignment="Center" Margin="12,0,0,0" Padding="12,6"/>
            <TextBlock x:Name="BannerGlyph" DockPanel.Dock="Left" FontFamily="Segoe MDL2 Assets" FontSize="16" VerticalAlignment="Center" Margin="0,0,10,0" Text="&#xE946;"/>
            <TextBlock x:Name="BannerText" TextWrapping="Wrap" VerticalAlignment="Center"/>
          </DockPanel>
        </Border>

        <Border x:Name="SignPanel" Grid.Row="1" Background="@Surface@" BorderBrush="@Line@" BorderThickness="1" CornerRadius="12">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="220"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Border x:Name="SignBlock" Grid.Column="0" CornerRadius="11,0,0,11" Background="@Raised@" Padding="22,20,18,20" MinHeight="150">
              <DockPanel>
                <TextBlock x:Name="SignGlyph" DockPanel.Dock="Top" FontFamily="Segoe MDL2 Assets" FontSize="26" Foreground="@Muted@" Text="&#xE721;"/>
                <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left" VerticalAlignment="Bottom" Margin="0,24,0,0">
                  <TextBlock x:Name="SignWord" FontFamily="Bahnschrift, Segoe UI" FontSize="34" Foreground="@Ink2@" Text="Not checked"/>
                </Viewbox>
              </DockPanel>
            </Border>
            <StackPanel Grid.Column="1" Margin="26,20,24,20">
              <ProgressBar x:Name="BusyBar" Height="3" IsIndeterminate="True" Visibility="Collapsed" Margin="0,0,0,12" Foreground="@Focus@" Background="Transparent" BorderThickness="0"/>
              <TextBlock x:Name="HostLine" Foreground="@Muted@" FontSize="12" Text="No machine checked yet"/>
              <TextBlock x:Name="Headline" FontSize="22" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,6,0,8" Text="Type a machine, then press Check now."/>
              <TextBlock x:Name="Advice" Foreground="@Ink2@" FontSize="14" TextWrapping="Wrap" Text="A check only reads the machine's list of sessions. Nobody is disconnected or asked anything."/>
              <TextBlock x:Name="NotesText" Style="{StaticResource Hint}" Margin="0,8,0,0" Visibility="Collapsed"/>
              <Border x:Name="ErrorBox" Visibility="Collapsed" Margin="0,14,0,0" Background="@Raised@" BorderBrush="@Line@" BorderThickness="1" CornerRadius="6" Padding="12,10">
                <TextBox x:Name="ErrorText" IsReadOnly="True" TextWrapping="Wrap" Background="Transparent" BorderThickness="0" Padding="0" FontSize="13"/>
              </Border>
            </StackPanel>
            <!-- The facts run under both the sign and the text, so they have room at 1024 pixels. -->
            <Border x:Name="Facts" Grid.Row="1" Grid.ColumnSpan="2" Visibility="Collapsed" Padding="22,14,12,8" BorderBrush="@Line@" BorderThickness="0,1,0,0">
              <UniformGrid x:Name="FactsGrid" Columns="4">
                <StackPanel Margin="0,0,12,8">
                  <TextBlock x:Name="Fact1Label" Style="{StaticResource FactLabel}"/>
                  <TextBlock x:Name="Fact1Value" Style="{StaticResource FactValue}"/>
                  <TextBlock x:Name="Fact1Sub" Style="{StaticResource FactSub}"/>
                </StackPanel>
                <StackPanel Margin="0,0,12,8">
                  <TextBlock x:Name="Fact2Label" Style="{StaticResource FactLabel}"/>
                  <TextBlock x:Name="Fact2Value" Style="{StaticResource FactValue}"/>
                  <TextBlock x:Name="Fact2Sub" Style="{StaticResource FactSub}"/>
                </StackPanel>
                <StackPanel Margin="0,0,12,8">
                  <TextBlock x:Name="Fact3Label" Style="{StaticResource FactLabel}"/>
                  <TextBlock x:Name="Fact3Value" Style="{StaticResource FactValue}"/>
                  <TextBlock x:Name="Fact3Sub" Style="{StaticResource FactSub}"/>
                </StackPanel>
                <StackPanel Margin="0,0,12,8">
                  <TextBlock x:Name="Fact4Label" Style="{StaticResource FactLabel}"/>
                  <TextBlock x:Name="Fact4Value" Style="{StaticResource FactValue}"/>
                  <TextBlock x:Name="Fact4Sub" Style="{StaticResource FactSub}"/>
                </StackPanel>
              </UniformGrid>
            </Border>
          </Grid>
        </Border>

        <WrapPanel x:Name="Actions" Grid.Row="2" Margin="0,14,0,0">
          <Button x:Name="ConnectButton" Style="{StaticResource PrimaryButton}" Margin="0,0,10,8" IsEnabled="False" ToolTipService.ShowOnDisabled="True" ToolTip="Check a machine first.">
            <StackPanel Orientation="Horizontal">
              <TextBlock FontFamily="Segoe MDL2 Assets" FontSize="14" VerticalAlignment="Center" Margin="0,0,8,0" Text="&#xE7F4;"/>
              <TextBlock x:Name="ConnectText" VerticalAlignment="Center" Text="Connect"/>
            </StackPanel>
          </Button>
          <Button x:Name="AskButton" Style="{StaticResource QuietButton}" Margin="0,0,10,8" IsEnabled="False" ToolTipService.ShowOnDisabled="True" ToolTip="Check a machine first.">
            <StackPanel Orientation="Horizontal">
              <TextBlock FontFamily="Segoe MDL2 Assets" FontSize="14" VerticalAlignment="Center" Margin="0,0,8,0" Text="&#xE8BD;"/>
              <TextBlock VerticalAlignment="Center" Text="Ask to take over"/>
            </StackPanel>
          </Button>
          <Button x:Name="WatchButton" Style="{StaticResource QuietButton}" Margin="0,0,10,8" IsEnabled="False" ToolTipService.ShowOnDisabled="True" ToolTip="Check a machine first.">
            <StackPanel Orientation="Horizontal">
              <TextBlock FontFamily="Segoe MDL2 Assets" FontSize="14" VerticalAlignment="Center" Margin="0,0,8,0" Text="&#xE7B3;"/>
              <TextBlock VerticalAlignment="Center" Text="Watch (view only)"/>
            </StackPanel>
          </Button>
          <Button x:Name="NotifyButton" Style="{StaticResource QuietButton}" Margin="0,0,10,8" IsEnabled="False" ToolTipService.ShowOnDisabled="True" ToolTip="Check a machine first.">
            <StackPanel Orientation="Horizontal">
              <TextBlock FontFamily="Segoe MDL2 Assets" FontSize="14" VerticalAlignment="Center" Margin="0,0,8,0" Text="&#xEA8F;"/>
              <TextBlock x:Name="NotifyText" VerticalAlignment="Center" Text="Tell me when it's free"/>
            </StackPanel>
          </Button>
        </WrapPanel>

        <DockPanel Grid.Row="3" Margin="0,22,0,0">
          <DockPanel DockPanel.Dock="Top" Margin="0,0,0,10">
            <Button x:Name="LookupButton" DockPanel.Dock="Right" Style="{StaticResource LinkButton}" VerticalAlignment="Bottom" Visibility="Collapsed" Content="Look up their last client in the event log" ToolTip="Reads the machine's Remote Desktop session log. Needs an administrator account there and its Remote Event Log Management firewall rules."/>
            <StackPanel>
              <TextBlock x:Name="SessionsTitle" FontSize="15" FontWeight="SemiBold" Text="People signed in"/>
              <TextBlock x:Name="SessionsHint" Style="{StaticResource Hint}" Margin="0,2,0,0" Text="Everyone signed in to the machine appears here after a check."/>
            </StackPanel>
          </DockPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel x:Name="SessionsPanel"/>
          </ScrollViewer>
        </DockPanel>

        <DockPanel Grid.Row="4" Margin="0,12,0,0">
          <DockPanel DockPanel.Dock="Top" LastChildFill="False">
            <Button x:Name="LogToggle" DockPanel.Dock="Left" Style="{StaticResource LinkButton}" Content="Show the step-by-step log"/>
            <Button x:Name="LogSave" DockPanel.Dock="Right" Style="{StaticResource LinkButton}" Margin="16,0,0,0" Visibility="Collapsed" Content="Save to a file"/>
            <Button x:Name="LogCopy" DockPanel.Dock="Right" Style="{StaticResource LinkButton}" Visibility="Collapsed" Content="Copy"/>
          </DockPanel>
          <TextBox x:Name="LogBox" Visibility="Collapsed" Height="180" Margin="0,8,0,0" IsReadOnly="True" FontFamily="Cascadia Mono, Consolas" FontSize="12" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" VerticalContentAlignment="Top"/>
        </DockPanel>
      </Grid>
    </Grid>
    </ScrollViewer>

    <DockPanel Grid.Row="2" Margin="0,14,0,0">
      <TextBlock x:Name="VersionText" DockPanel.Dock="Right" Foreground="@Muted@" FontSize="12"/>
      <TextBlock x:Name="FooterText" Foreground="@Muted@" FontSize="12" Text="Not checked yet."/>
    </DockPanel>
  </Grid>
</Window>
'@

#endregion

#region Window

$xaml = $script:XamlTemplate
foreach ($key in $script:Palette.Keys) {
    $xaml = $xaml.Replace(('@{0}@' -f $key), $script:Palette[$key])
}
if ($xaml -match '@\w+@') {
    Show-StartupError ('Internal error: the theme has no value for {0}.' -f $Matches[0])
    exit 1
}
try {
    $script:Window = [System.Windows.Markup.XamlReader]::Parse($xaml)
}
catch {
    Show-StartupError ("The window layout could not be loaded:`n{0}" -f $_.Exception.Message)
    exit 1
}
$script:ui = @{}
foreach ($match in [regex]::Matches($xaml, 'x:Name="(\w+)"')) {
    $element = $script:Window.FindName($match.Groups[1].Value)
    if ($null -ne $element) { $script:ui[$match.Groups[1].Value] = $element }
}

# Fit small or scaled screens (1366x768 at 125 %, 1920x1080 at 150 %). If the
# window gets shorter than its content, the page scrolls instead of cutting off.
$workArea = [System.Windows.SystemParameters]::WorkArea
if ($workArea.Width -gt 0 -and $workArea.Height -gt 0) {
    $script:Window.Width = [Math]::Min($script:Window.Width, $workArea.Width)
    $script:Window.Height = [Math]::Min($script:Window.Height, $workArea.Height)
    $script:Window.MinWidth = [Math]::Min($script:Window.MinWidth, $script:Window.Width)
    $script:Window.MinHeight = [Math]::Min($script:Window.MinHeight, $script:Window.Height)
}

#endregion

#region State

$script:Current = $null          # @{ Request; Result } on screen
$script:LastRequest = $null      # what auto re-check repeats
$script:NextCheckAt = Get-Date
$script:CheckTask = $null
$script:AskTask = $null
$script:LookupTask = $null
$script:AskDeadline = Get-Date
$script:AskUser = ''
$script:NotifyKey = $null
$script:AutoBeforeNotify = $false
$script:Secrets = @{}            # request key -> SecureString, this run only
$script:ClientMaps = @{}         # request key -> @{ Map; Error; Time }
$script:Recent = New-Object System.Collections.ArrayList
$script:UpdatingRecent = $false
$script:BannerBlock = $null
$script:BannerTransient = $false
$script:Completing = $false
$script:TrayIcon = $null
$script:AppIcon = $null
$script:BrushCache = @{}
$script:LogLines = New-Object System.Collections.Generic.List[string]
$script:SettingsPath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'SharedRdp\dashboard.json'
$script:Jobs = New-Object System.Collections.ArrayList

$script:TableColumns = @(
    @{ Width = 18; Unit = 'Pixel' },    # dot
    @{ Width = 2.1; Unit = 'Star' },    # account
    @{ Width = 2.2; Unit = 'Star' },    # state
    @{ Width = 1.4; Unit = 'Star' },    # signed in
    @{ Width = 1.8; Unit = 'Star' },    # connected from
    @{ Width = 64; Unit = 'Pixel' }     # session
)

#endregion

#region Small helpers

function Get-Brush {
    # A frozen brush for a palette name ('Ink') or a color ('#D03B3B', '#26D03B3B').
    param([string] $Name)
    $hex = $Name
    if ($script:Palette.ContainsKey($Name)) { $hex = $script:Palette[$Name] }
    if (-not $script:BrushCache.ContainsKey($hex)) {
        $brush = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex)
        $brush.Freeze()
        $script:BrushCache[$hex] = $brush
    }
    return $script:BrushCache[$hex]
}

function Get-StatusFill {
    param([string] $Status)
    if ($script:StatusFill.ContainsKey($Status)) { return $script:StatusFill[$Status] }
    return $script:StatusFill['Unknown']
}

function Get-StatusInk {
    param([string] $Status)
    if ($script:StatusInk.ContainsKey($Status)) { return $script:StatusInk[$Status] }
    return $script:StatusInk['Unknown']
}

function Get-StatusWord {
    param([string] $Status)
    if ($script:StatusWord.ContainsKey($Status)) { return $script:StatusWord[$Status] }
    return $Status
}

function New-Thickness {
    param([double] $Left, [double] $Top, [double] $Right, [double] $Bottom)
    return (New-Object System.Windows.Thickness -ArgumentList $Left, $Top, $Right, $Bottom)
}

function New-Text {
    param(
        [string] $Text,
        [double] $Size = 13,
        [string] $Brush = 'Ink',
        [switch] $SemiBold,
        [switch] $Wrap
    )
    $block = New-Object System.Windows.Controls.TextBlock
    $block.Text = $Text
    $block.FontSize = $Size
    $block.Foreground = Get-Brush $Brush
    if ($SemiBold) { $block.FontWeight = [System.Windows.FontWeights]::SemiBold }
    if ($Wrap) {
        $block.TextWrapping = [System.Windows.TextWrapping]::Wrap
    }
    else {
        # One line, cut with an ellipsis when narrow; the tooltip shows it whole.
        $block.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        if ($Text) { $block.ToolTip = $Text }
    }
    return $block
}

function New-Dot {
    param([string] $Status, [double] $Size = 9)
    $dot = New-Object System.Windows.Shapes.Ellipse
    $dot.Width = $Size
    $dot.Height = $Size
    if ($Status -eq 'None' -or $Status -eq 'System') {
        $dot.Stroke = Get-Brush 'Muted'
        $dot.StrokeThickness = 1.5
    }
    else {
        $dot.Fill = Get-Brush (Get-StatusFill $Status)
    }
    $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
    $dot.Margin = New-Thickness 0 5 0 0
    return $dot
}

function Add-Cell {
    param($Grid, [int] $Column, $Element, [int] $Span = 1)
    [System.Windows.Controls.Grid]::SetColumn($Element, $Column)
    if ($Span -gt 1) { [System.Windows.Controls.Grid]::SetColumnSpan($Element, $Span) }
    $null = $Grid.Children.Add($Element)
}

function New-Stack {
    param([object[]] $Children)
    $stack = New-Object System.Windows.Controls.StackPanel
    foreach ($child in $Children) {
        if ($null -ne $child) { $null = $stack.Children.Add($child) }
    }
    return $stack
}

function Format-Span {
    # "40 s", "23 min", "6 h 29 min", "3 days".
    param($Span)
    if ($null -eq $Span) { return '' }
    $value = [TimeSpan] $Span
    if ($value.TotalDays -ge 2) { return ('{0} days' -f [int] [Math]::Floor($value.TotalDays)) }
    return (Format-Duration -Span $value)
}

function Format-When {
    param($Time)
    if ($null -eq $Time) { return '' }
    $t = [DateTime] $Time
    $today = (Get-Date).Date
    if ($t.Date -eq $today) { return ('today {0:HH:mm}' -f $t) }
    if ($t.Date -eq $today.AddDays(-1)) { return ('yesterday {0:HH:mm}' -f $t) }
    return ('{0:yyyy-MM-dd HH:mm}' -f $t)
}

function ConvertTo-Sentence {
    param([string] $Text)
    if (-not $Text) { return '' }
    $sentence = $Text.Substring(0, 1).ToUpper() + $Text.Substring(1)
    if ($sentence -notmatch '[.!?]$') { $sentence += '.' }
    return $sentence
}

function Write-UiLog {
    param([string] $Text, [ValidateSet('Info', 'Trace', 'Warning', 'Error')] [string] $Kind = 'Info')
    $tag = '     '
    if ($Kind -eq 'Warning') { $tag = 'WARN ' }
    elseif ($Kind -eq 'Error') { $tag = 'ERROR' }
    $line = '{0:HH:mm:ss}  {1}  {2}' -f (Get-Date), $tag, $Text
    $script:LogLines.Add($line)
    if ($null -eq $script:ui -or -not $script:ui.ContainsKey('LogBox')) { return }
    if ($script:LogLines.Count -gt 5000) {
        $script:LogLines.RemoveRange(0, 1000)
        $script:ui.LogBox.Text = ($script:LogLines -join [Environment]::NewLine) + [Environment]::NewLine
    }
    else {
        $script:ui.LogBox.AppendText($line + [Environment]::NewLine)
    }
    if ($script:ui.LogBox.IsVisible) { $script:ui.LogBox.ScrollToEnd() }
}

function Show-Banner {
    param(
        [string] $Text,
        [ValidateSet('Info', 'Good', 'Warning', 'Error')] [string] $Kind = 'Info',
        [string] $ActionText = '',
        [scriptblock] $Action = $null,
        [switch] $Transient
    )
    $tint = $script:StatusFill.Disconnected
    $glyph = [string][char]0xE946
    $logKind = 'Info'
    switch ($Kind) {
        'Good'    { $tint = $script:StatusFill.Free; $glyph = [string][char]0xE73E }
        'Warning' { $tint = $script:StatusFill.Locked; $glyph = [string][char]0xE7BA; $logKind = 'Warning' }
        'Error'   { $tint = $script:StatusFill.InUse; $glyph = [string][char]0xE783; $logKind = 'Error' }
    }
    $rgb = $tint.TrimStart('#')
    $script:ui.Banner.Background = Get-Brush ('#26' + $rgb)
    $script:ui.Banner.BorderBrush = Get-Brush ('#80' + $rgb)
    $script:ui.BannerGlyph.Text = $glyph
    $script:ui.BannerText.Text = $Text
    if ($ActionText -and $null -ne $Action) {
        $script:ui.BannerAction.Content = $ActionText
        $script:ui.BannerAction.Visibility = [System.Windows.Visibility]::Visible
        $script:BannerBlock = $Action
    }
    else {
        $script:ui.BannerAction.Visibility = [System.Windows.Visibility]::Collapsed
        $script:BannerBlock = $null
    }
    $script:BannerTransient = [bool] $Transient
    $script:ui.Banner.Visibility = [System.Windows.Visibility]::Visible
    Write-UiLog -Text $Text -Kind $logKind
}

function Hide-Banner {
    $script:ui.Banner.Visibility = [System.Windows.Visibility]::Collapsed
    $script:BannerBlock = $null
    $script:BannerTransient = $false
}

function Invoke-Safely {
    # Event handlers must never throw into WPF; anything unexpected goes to the
    # log and the banner instead.
    param([scriptblock] $Action)
    try {
        & $Action
    }
    catch {
        $problem = $_
        try {
            Write-UiLog -Text ('Unexpected error: {0}' -f (Format-ExceptionChain -ErrorRecord $problem)) -Kind Error
            Show-Banner -Text ('Something went wrong: {0}' -f $problem.Exception.Message) -Kind Error
        }
        catch {
            Write-Verbose $problem.Exception.Message
        }
    }
}

#endregion

#region Background work

# Checks, takeover requests and event log reads run in a small runspace pool, so
# the window stays responsive. The pool gets the engine's functions directly.
$sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
foreach ($function in $script:Engine.ExportedFunctions.Values) {
    $entry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $function.Name, $function.Definition
    $sessionState.Commands.Add($entry)
}
$script:Pool = [runspacefactory]::CreateRunspacePool(1, 3, $sessionState, $Host)
$script:Pool.Open()

$script:CheckJobScript = @'
param($JobTarget, $JobSettings)
$VerbosePreference = 'Continue'
try { [pscustomobject]@{ Ok = $true; Value = (Get-HostStatus -Target $JobTarget -Settings $JobSettings); Error = $null } }
catch { [pscustomobject]@{ Ok = $false; Value = $null; Error = $_ } }
'@

$script:AskJobScript = @'
param($JobHost, $JobSessionId, $JobTitle, $JobMessage, $JobTimeout, $JobCredential)
$VerbosePreference = 'Continue'
try { [pscustomobject]@{ Ok = $true; Value = (Send-AskMessage -ComputerName $JobHost -SessionId $JobSessionId -Title $JobTitle -Message $JobMessage -TimeoutSeconds $JobTimeout -Credential $JobCredential); Error = $null } }
catch { [pscustomobject]@{ Ok = $false; Value = $null; Error = $_ } }
'@

$script:LookupJobScript = @'
param($JobHost, $JobCredential)
$VerbosePreference = 'Continue'
try { [pscustomobject]@{ Ok = $true; Value = (Get-LastClientMap -ComputerName $JobHost -Credential $JobCredential); Error = $null } }
catch { [pscustomobject]@{ Ok = $false; Value = $null; Error = $_ } }
'@

function Start-Background {
    param([string] $Name, [string] $Script, [hashtable] $Arguments, [scriptblock] $OnDone, $Context = $null)
    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:Pool
    $null = $ps.AddScript($Script)
    foreach ($key in $Arguments.Keys) { $null = $ps.AddParameter($key, $Arguments[$key]) }
    $task = @{ Name = $Name; PowerShell = $ps; Handle = $ps.BeginInvoke(); OnDone = $OnDone; Context = $Context }
    $null = $script:Jobs.Add($task)
    Write-UiLog -Text ('{0}{1}' -f $Name, $script:Ellipsis)
    return $task
}

function Complete-Background {
    # Called by a timer on the window's thread: hands finished work to its OnDone.
    if ($script:Completing) { return }
    $script:Completing = $true
    try {
        for ($i = $script:Jobs.Count - 1; $i -ge 0; $i--) {
            if ($i -ge $script:Jobs.Count) { continue }
            $task = $script:Jobs[$i]
            if (-not $task.Handle.IsCompleted) { continue }
            $script:Jobs.RemoveAt($i)
            $output = @()
            $failure = $null
            try { $output = @($task.PowerShell.EndInvoke($task.Handle)) }
            catch { $failure = $_ }
            $streams = $task.PowerShell.Streams
            foreach ($record in @($streams.Verbose)) { Write-UiLog -Text $record.Message -Kind Trace }
            foreach ($record in @($streams.Warning)) { Write-UiLog -Text $record.Message -Kind Warning }
            foreach ($record in @($streams.Error)) {
                Write-UiLog -Text ([string] $record) -Kind Error
                if ($null -eq $failure) { $failure = $record }
            }
            $task.PowerShell.Dispose()
            $result = $null
            if ($output.Count -gt 0) { $result = $output[0] }
            if ($null -ne $result -and -not $result.Ok -and $null -ne $result.Error) { $failure = $result.Error }
            try {
                & $task.OnDone $result $failure $task.Context
            }
            catch {
                Write-UiLog -Text ('Showing the result of "{0}" failed: {1}' -f $task.Name, (Format-ExceptionChain -ErrorRecord $_)) -Kind Error
            }
        }
    }
    finally {
        $script:Completing = $false
    }
}

#endregion

#region Checking

function Get-FormRequest {
    # Reads the form into a request; $null (with a hint) if something is missing.
    $hostText = ([string] $script:ui.HostBox.Text).Trim()
    if (-not $hostText) {
        Show-Banner -Text 'Type the machine name or IP address first.' -Kind Warning -Transient
        $null = $script:ui.HostBox.Focus()
        return $null
    }
    $account = ([string] $script:ui.UserBox.Text).Trim()
    $key = ('{0}|{1}' -f $hostText, $account).ToLowerInvariant()
    $split = Split-HostPort -Address $hostText
    $credential = [System.Management.Automation.PSCredential]::Empty
    $checkingAs = Get-CheckingIdentity -Credential $null
    if ($account) {
        $secure = $script:ui.PassBox.SecurePassword
        if ($secure.Length -eq 0 -and $script:Secrets.ContainsKey($key)) { $secure = $script:Secrets[$key] }
        if ($secure.Length -eq 0) {
            Show-Banner -Text ('Type the password for {0}, or clear Account to check as yourself.' -f $account) -Kind Warning -Transient
            $null = $script:ui.PassBox.Focus()
            return $null
        }
        if (-not $secure.IsReadOnly()) { $secure.MakeReadOnly() }
        $script:Secrets[$key] = $secure
        $credential = New-Object System.Management.Automation.PSCredential -ArgumentList $account, $secure
        # Show the account the way the machine sees it: a bare name is one of its
        # local accounts (HOST\name).
        $checkingAs = $account
        $signIn = ConvertTo-TargetCredential -Credential $credential -ComputerName $split.Host
        if ($null -ne $signIn) { $checkingAs = $signIn.UserName }
    }
    $target = [pscustomobject]@{
        Name = $hostText; QueryHost = $split.Host; RdpFile = ''; OverrideHost = $true; TargetUser = $account; Gateway = ''
    }
    $settings = @{
        Credential              = $credential
        IdleMinutes             = $script:Options.Idle
        RecentDisconnectMinutes = 15
        BusyProcess             = $script:Options.Busy
        AskTimeoutSeconds       = $script:Options.AskTimeout
        PollSeconds             = $script:Options.Refresh
        NoConsentPrompt         = $false
        MstscArgument           = @()
        SkipPortCheck           = $false
        CheckingAs              = $checkingAs
        Gui                     = $true
    }
    return [pscustomobject]@{
        Key = $key; Host = $hostText; QueryHost = $split.Host; Account = $account
        Credential = $credential; Target = $target; Settings = $settings
    }
}

function Invoke-CheckFromForm {
    $request = Get-FormRequest
    if ($null -eq $request) { return }
    if ($script:BannerTransient) { Hide-Banner }
    Start-Check -Request $request
}

function Set-Busy {
    param([bool] $On, [string] $HostName = '')
    if ($On) {
        $script:ui.BusyBar.Visibility = [System.Windows.Visibility]::Visible
        $script:ui.CheckButton.IsEnabled = $false
        $script:ui.CheckButtonText.Text = 'Checking' + $script:Ellipsis
        $script:ui.HostLine.Text = 'Checking {0}{1}' -f $HostName, $script:Ellipsis
    }
    else {
        $script:ui.BusyBar.Visibility = [System.Windows.Visibility]::Collapsed
        $script:ui.CheckButton.IsEnabled = $true
        $script:ui.CheckButtonText.Text = 'Check now'
    }
}

function Start-Check {
    param($Request)
    if ($null -ne $script:CheckTask) { return }
    Set-Busy -On $true -HostName $Request.Host
    $arguments = @{ JobTarget = $Request.Target; JobSettings = $Request.Settings }
    $script:CheckTask = Start-Background -Name ('Checking {0} as {1}' -f $Request.Host, $Request.Settings.CheckingAs) -Script $script:CheckJobScript -Arguments $arguments -Context $Request -OnDone {
        param($Output, $Failure, $Context)
        Complete-Check -Output $Output -Failure $Failure -Request $Context
    }
    Update-Footer
}

function Complete-Check {
    param($Output, $Failure, $Request)
    $script:CheckTask = $null
    Set-Busy -On $false
    $result = $null
    if ($null -ne $Output -and $Output.Ok) { $result = $Output.Value }
    if ($null -eq $result) {
        $reason = [pscustomobject]@{ Reason = 'no result'; Text = 'The background check ended without a result; the log below has the details.'; Code = $null }
        if ($null -ne $Failure) { $reason = Get-FailureText -ErrorRecord $Failure -Settings $Request.Settings }
        $result = New-UnknownResult -Target $Request.Target -Reason $reason.Reason -Text $reason.Text -Code $reason.Code
    }
    $script:Current = @{ Request = $Request; Result = $result }
    $script:LastRequest = $Request
    $script:NextCheckAt = (Get-Date).AddSeconds($script:Options.Refresh)
    Show-Result
    Update-Recent -Request $Request -Result $result
    Test-NotifyCondition -Request $Request -Result $result
}

#endregion

#region Showing a result

function Get-FriendlyText {
    param($Result, $Request)
    $s = $Result.Session
    $hostName = $Request.Host
    $name = 'Someone'
    if ($null -ne $s) { $name = Get-UserLeaf -Name $s.User }
    $account = Get-UserLeaf -Name $Request.Account
    $headline = ''
    $advice = ''
    switch ([string] $Result.Status) {
        'Free' {
            $others = @($Result.OtherSessions)
            if ($account -and $others.Count -gt 0) {
                $headline = '{0} has no session on {1}.' -f $account, $hostName
                $advice = 'Connecting starts a new session for {0}. Other accounts are signed in; they are listed below.' -f $account
            }
            elseif ($account) {
                $headline = 'Nobody is signed in on {0}.' -f $hostName
                $advice = 'You can connect as {0} right away; nobody will be disconnected.' -f $account
            }
            else {
                $headline = 'Nobody is signed in on {0}.' -f $hostName
                $advice = 'You can connect right away; nobody will be disconnected.'
            }
        }
        'Disconnected' {
            $headline = 'Nobody is watching {0}''s session.' -f $name
            $since = Format-Span $s.DisconnectedFor
            if ($since) { $advice = 'It was disconnected {0} ago and its apps are still running. Connecting picks up that desktop where it was left.' -f $since }
            else { $advice = 'It is disconnected and its apps are still running. Connecting picks up that desktop where it was left.' }
            if ($null -ne $s.DisconnectedFor -and $s.DisconnectedFor.TotalMinutes -lt 15) { $advice += ' They left only recently and may come back.' }
        }
        'Locked' {
            $headline = '{0} is connected, but the screen is locked.' -f $name
            $advice = 'They probably stepped away. Connecting cuts their window off; their apps keep running.'
            if ($null -ne $s.IdleTime) { $advice = 'They probably stepped away; no input for {0}. Connecting cuts their window off; their apps keep running.' -f (Format-Span $s.IdleTime) }
        }
        'Idle' {
            $headline = '{0} is connected but has not touched it for {1}.' -f $name, (Format-Span $s.IdleTime)
            $advice = 'The screen is not locked, so they may be reading or waiting for something. Ask before you take over.'
        }
        'InUse' {
            $headline = '{0} is working on {1} right now.' -f $name, $hostName
            if ($null -ne $s.IdleTime) {
                $advice = 'Last keyboard or mouse input {0} ago. Connecting would cut them off without warning; ask first, or wait.' -f (Format-Span $s.IdleTime)
            }
            elseif ($s.Protocol -eq 'Console') {
                # Windows never reports input times for the console, so "working" would be a guess.
                $headline = '{0} is signed in directly at {1}.' -f $name, $hostName
                $advice = 'Windows does not report keyboard or mouse input for the machine''s own screen, so they may be working right now. Connecting would cut them off; ask first, or wait.'
            }
            elseif ($s.IdleNote -and $s.IdleNote -ne 'idle time not reported') {
                $advice = 'Windows gives no input time for this session: {0}. Connecting would cut them off; ask first, or wait.' -f $s.IdleNote
            }
            else {
                $advice = 'Windows gives no input time for this session. Connecting would cut them off; ask first, or wait.'
            }
        }
        'Busy' {
            $headline = 'Automation is running in {0}''s session.' -f $name
            $advice = '{0} is running there. Connecting may break it; wait, or ask whoever started it.' -f (@($s.BusyProcesses) -join ', ')
        }
        'Connecting' {
            $headline = 'Someone is signing in to {0} right now.' -f $hostName
            $advice = 'Wait a few seconds and check again.'
        }
        default {
            $headline = 'Could not check {0}.' -f $hostName
            $advice = 'Reason: {0}.' -f $Result.Detail
        }
    }
    return @{ Headline = $headline; Advice = $advice }
}

function Get-ClientText {
    # Where a session is (or was last) connected from, as a main line and a sub line.
    param($Session, $Lookup)
    if ($Session.Protocol -eq 'Console') {
        $sub = 'at the machine itself'
        if ($Session.Resolution) { $sub = '{0} display' -f $Session.Resolution }
        return @{ Main = 'Its own screen'; Sub = $sub }
    }
    if ($Session.Client -or $Session.ClientAddress) {
        $main = [string] $Session.Client
        if (-not $main) { $main = [string] $Session.ClientAddress }
        $parts = @()
        if ($Session.Client -and $Session.ClientAddress) { $parts += $Session.ClientAddress }
        if ($Session.Resolution) { $parts += $Session.Resolution }
        return @{ Main = $main; Sub = ($parts -join ', ') }
    }
    if ($null -ne $Lookup -and $null -ne $Lookup.Map) {
        $entry = Find-LastClient -Map $Lookup.Map -Session $Session
        if ($null -ne $entry) {
            $verb = 'connected'
            switch ([int] $entry.EventId) {
                21 { $verb = 'signed in' }
                24 { $verb = 'disconnected' }
                25 { $verb = 'reconnected' }
            }
            $main = [string] $entry.Address
            if ($main -eq 'LOCAL') { $main = 'Its own screen' }
            return @{ Main = $main; Sub = ('{0} {1}, per the event log' -f $verb, (Format-When $entry.Time)) }
        }
        return @{ Main = 'Not in the event log'; Sub = 'no entry since this sign-in' }
    }
    if ($null -ne $Lookup -and $Lookup.Error) { return @{ Main = 'Not known'; Sub = 'the event log could not be read' } }
    if ($Session.Status -eq 'Disconnected') { return @{ Main = 'Not kept'; Sub = 'Windows forgets it on disconnect' } }
    return @{ Main = 'Not reported'; Sub = '' }
}

function Get-StateDetail {
    param($Session)
    switch ([string] $Session.Status) {
        'Disconnected' {
            if ($null -ne $Session.DisconnectedFor) { return ('for {0}' -f (Format-Span $Session.DisconnectedFor)) }
            return ''
        }
        'Locked' {
            if ($null -ne $Session.IdleTime) { return ('idle for {0}' -f (Format-Span $Session.IdleTime)) }
            return 'screen locked'
        }
        'Idle' { return ('no input for {0}' -f (Format-Span $Session.IdleTime)) }
        'InUse' {
            if ($null -ne $Session.IdleTime) { return ('last input {0} ago' -f (Format-Span $Session.IdleTime)) }
            return [string] $Session.IdleNote
        }
        'Busy' { return (@($Session.BusyProcesses) -join ', ') }
    }
    return [string] $Session.State
}

function Set-Fact {
    param([int] $Index, [string] $Label, [string] $Value, [string] $Sub = '')
    $script:ui[('Fact{0}Label' -f $Index)].Text = $Label
    $valueBlock = $script:ui[('Fact{0}Value' -f $Index)]
    $subBlock = $script:ui[('Fact{0}Sub' -f $Index)]
    $valueBlock.Text = $Value
    $subBlock.Text = $Sub
    if ($Value) { $valueBlock.ToolTip = $Value } else { $valueBlock.ToolTip = $null }
    if ($Sub) { $subBlock.ToolTip = $Sub } else { $subBlock.ToolTip = $null }
}

function Show-Facts {
    param($Result, $Request, $Lookup)
    $s = $Result.Session
    if ($null -eq $s) {
        $people = @($Result.Sessions).Count
        $peopleSub = 'nobody else either'
        if ($people -gt 0) { $peopleSub = 'other accounts, listed below' }
        Set-Fact -Index 1 -Label 'People signed in' -Value ([string] $people) -Sub $peopleSub
        $console = @($Result.SystemSessions | Where-Object { $_.Name -like 'Console*' }) | Select-Object -First 1
        $consoleValue = 'Not in use'
        $consoleSub = ''
        if ($null -ne $console) {
            if ($console.State -eq 'Connected') { $consoleValue = 'Sign-in screen' }
            $consoleSub = 'session {0}' -f $console.SessionId
        }
        Set-Fact -Index 2 -Label 'Its own screen' -Value $consoleValue -Sub $consoleSub
        Set-Fact -Index 3 -Label 'Checked as' -Value (Get-UserLeaf -Name ([string] $Result.CheckedAs)) -Sub ([string] $Result.CheckedAs)
        $took = ''
        if ($null -ne $Result.DurationMs) { $took = '{0} ms' -f $Result.DurationMs }
        Set-Fact -Index 4 -Label 'Check took' -Value $took -Sub ('at {0:HH:mm:ss}' -f $Result.CheckedAt)
        return
    }
    switch ([string] $s.Status) {
        'Disconnected' {
            $since = Format-Span $s.DisconnectedFor
            $value = 'Yes'
            if ($since) { $value = '{0} ago' -f $since }
            Set-Fact -Index 1 -Label 'Disconnected' -Value $value -Sub (Format-When $s.DisconnectTime)
        }
        'Locked' {
            $sub = ''
            if ($null -ne $s.IdleTime) { $sub = 'no input for {0}' -f (Format-Span $s.IdleTime) }
            Set-Fact -Index 1 -Label 'Screen' -Value 'Locked' -Sub $sub
        }
        'Idle' { Set-Fact -Index 1 -Label 'No input for' -Value (Format-Span $s.IdleTime) -Sub 'keyboard and mouse untouched' }
        'InUse' {
            if ($null -eq $s.IdleTime) {
                $sub = ''
                if ($s.Protocol -eq 'Console') { $sub = 'not for the console' }
                elseif ($s.IdleNote -ne 'idle time not reported') { $sub = [string] $s.IdleNote }
                Set-Fact -Index 1 -Label 'Last input' -Value 'Not reported' -Sub $sub
            }
            elseif ($s.IdleTime.TotalSeconds -lt 60) { Set-Fact -Index 1 -Label 'Last input' -Value 'Just now' -Sub 'keyboard or mouse' }
            else { Set-Fact -Index 1 -Label 'Last input' -Value ('{0} ago' -f (Format-Span $s.IdleTime)) -Sub 'keyboard or mouse' }
        }
        'Busy' { Set-Fact -Index 1 -Label 'Running' -Value (@($s.BusyProcesses) -join ', ') -Sub (Get-StateDetail -Session $s) }
        default { Set-Fact -Index 1 -Label 'State' -Value ([string] $s.State) -Sub '' }
    }
    $signedIn = 'Not reported'
    if ($null -ne $s.SignedInFor) { $signedIn = '{0} ago' -f (Format-Span $s.SignedInFor) }
    Set-Fact -Index 2 -Label 'Signed in' -Value $signedIn -Sub (Format-When $s.LogonTime)
    $client = Get-ClientText -Session $s -Lookup $Lookup
    $label = 'Connected from'
    if ($s.Status -eq 'Disconnected') { $label = 'Last connected from' }
    Set-Fact -Index 3 -Label $label -Value $client.Main -Sub $client.Sub
    $how = ([string] $s.State).ToLower()
    switch ([string] $s.Protocol) {
        'RDP'     { $how = 'Remote Desktop' }
        'Console' { $how = 'physical console' }
        'ICA'     { $how = 'Citrix' }
    }
    Set-Fact -Index 4 -Label 'Session' -Value ([string] $s.SessionId) -Sub $how
}

function Show-Result {
    $current = $script:Current
    if ($null -eq $current) { return }
    $request = $current.Request
    $result = $current.Result
    $status = [string] $result.Status
    $lookup = $script:ClientMaps[$request.Key]

    $script:ui.SignBlock.Background = Get-Brush (Get-StatusFill $status)
    $ink = Get-Brush (Get-StatusInk $status)
    $script:ui.SignGlyph.Text = $script:StatusGlyph[$status]
    $script:ui.SignGlyph.Foreground = $ink
    $script:ui.SignWord.Text = Get-StatusWord $status
    $script:ui.SignWord.Foreground = $ink

    $script:ui.HostLine.Text = '{0}, checked at {1:HH:mm:ss}' -f $request.Host, $result.CheckedAt
    $copy = Get-FriendlyText -Result $result -Request $request
    $script:ui.Headline.Text = $copy.Headline
    $script:ui.Advice.Text = $copy.Advice

    $notes = @($result.Notes | Where-Object { $_ } | ForEach-Object { ConvertTo-Sentence $_ })
    if ($notes.Count -gt 0) {
        $script:ui.NotesText.Text = $notes -join ' '
        $script:ui.NotesText.Visibility = [System.Windows.Visibility]::Visible
    }
    else {
        $script:ui.NotesText.Visibility = [System.Windows.Visibility]::Collapsed
    }

    if ($status -eq 'Unknown') {
        $script:ui.ErrorText.Text = [string] $result.Error
        $script:ui.ErrorBox.Visibility = [System.Windows.Visibility]::Visible
        $script:ui.Facts.Visibility = [System.Windows.Visibility]::Collapsed
    }
    else {
        $script:ui.ErrorBox.Visibility = [System.Windows.Visibility]::Collapsed
        $script:ui.Facts.Visibility = [System.Windows.Visibility]::Visible
        Show-Facts -Result $result -Request $request -Lookup $lookup
    }
    # The sign's lower corner is square when the facts strip runs under it.
    $lower = 11
    if ($script:ui.Facts.Visibility -eq [System.Windows.Visibility]::Visible) { $lower = 0 }
    $script:ui.SignBlock.CornerRadius = New-Object System.Windows.CornerRadius -ArgumentList 11, 0, 0, $lower
    $script:ui.IdentityText.Text = 'Checked as {0}' -f $request.Settings.CheckingAs
    Update-Actions
    Show-Sessions
    Update-Footer
}

function Update-Actions {
    $current = $script:Current
    $hasResult = ($null -ne $current)
    $status = 'None'
    $s = $null
    $lookup = $null
    if ($hasResult) {
        $status = [string] $current.Result.Status
        $s = $current.Result.Session
        $lookup = $script:ClientMaps[$current.Request.Key]
    }
    $risky = @('InUse', 'Idle', 'Locked', 'Busy', 'Connecting') -contains $status
    $active = ($null -ne $s -and $s.State -eq 'Active')

    $script:ui.ConnectButton.IsEnabled = $hasResult
    if ($risky) {
        $script:ui.ConnectButton.Style = $script:Window.FindResource('DangerButton')
        $script:ui.ConnectText.Text = 'Connect anyway' + $script:Ellipsis
        $script:ui.ConnectButton.ToolTip = 'Disconnects the person in the session; asks you to confirm first.'
    }
    elseif ($status -eq 'Unknown') {
        $script:ui.ConnectButton.Style = $script:Window.FindResource('QuietButton')
        $script:ui.ConnectText.Text = 'Connect anyway'
        $script:ui.ConnectButton.ToolTip = 'The check failed, so this may disconnect someone.'
    }
    else {
        $script:ui.ConnectButton.Style = $script:Window.FindResource('PrimaryButton')
        $script:ui.ConnectText.Text = 'Connect'
        if ($hasResult) { $script:ui.ConnectButton.ToolTip = 'Opens Remote Desktop with this machine and account filled in.' }
        else { $script:ui.ConnectButton.ToolTip = 'Check a machine first.' }
    }

    $script:ui.AskButton.IsEnabled = ($active -and $null -eq $script:AskTask)
    if ($null -ne $script:AskTask) { $script:ui.AskButton.ToolTip = 'Waiting for the answer to your request.' }
    elseif ($active) { $script:ui.AskButton.ToolTip = 'Shows a Yes/No box in their session. If they click Yes, Remote Desktop opens for you.' }
    else { $script:ui.AskButton.ToolTip = 'Only possible while someone is connected to the session.' }

    $script:ui.WatchButton.IsEnabled = $active
    if ($active) { $script:ui.WatchButton.ToolTip = 'Opens a view-only copy of their screen. Needs administrator rights there; by default they are asked first.' }
    else { $script:ui.WatchButton.ToolTip = 'Only possible while someone is connected to the session.' }

    $waitable = $hasResult -and ($status -ne 'Free') -and ($status -ne 'Disconnected')
    $script:ui.NotifyButton.IsEnabled = ($waitable -or $null -ne $script:NotifyKey)
    if ($null -ne $script:NotifyKey) {
        $script:ui.NotifyText.Text = 'Stop watching'
        $script:ui.NotifyButton.ToolTip = 'Stops the automatic checks for this machine.'
    }
    else {
        $script:ui.NotifyText.Text = "Tell me when it's free"
        if ($waitable) { $script:ui.NotifyButton.ToolTip = ('Checks every {0} s and notifies you when the session is free or disconnected. Keep this window open.' -f $script:Options.Refresh) }
        else { $script:ui.NotifyButton.ToolTip = 'The machine is already free.' }
    }

    $needsLookup = $false
    if ($hasResult -and $status -ne 'Unknown') {
        $unknownClients = @($current.Result.Sessions | Where-Object { $_.Protocol -ne 'Console' -and -not $_.Client -and -not $_.ClientAddress })
        $needsLookup = ($unknownClients.Count -gt 0) -and ($null -eq $lookup -or $lookup.Error)
    }
    if ($null -ne $script:LookupTask) {
        $script:ui.LookupButton.Visibility = [System.Windows.Visibility]::Visible
        $script:ui.LookupButton.IsEnabled = $false
        $script:ui.LookupButton.Content = 'Reading the event log' + $script:Ellipsis
    }
    elseif ($needsLookup) {
        $script:ui.LookupButton.Visibility = [System.Windows.Visibility]::Visible
        $script:ui.LookupButton.IsEnabled = $true
        if ($null -ne $lookup -and $lookup.Error) { $script:ui.LookupButton.Content = 'Try the event log again' }
        else { $script:ui.LookupButton.Content = 'Look up their last client in the event log' }
    }
    else {
        $script:ui.LookupButton.Visibility = [System.Windows.Visibility]::Collapsed
    }
}

function New-TableGrid {
    $grid = New-Object System.Windows.Controls.Grid
    foreach ($column in $script:TableColumns) {
        $definition = New-Object System.Windows.Controls.ColumnDefinition
        $definition.Width = New-Object System.Windows.GridLength -ArgumentList ([double] $column.Width), ([System.Windows.GridUnitType] $column.Unit)
        $grid.ColumnDefinitions.Add($definition)
    }
    return $grid
}

function New-TableHeader {
    $grid = New-TableGrid
    $titles = @('', 'Account', 'State', 'Signed in', 'Connected from', 'Session')
    for ($i = 1; $i -lt $titles.Count; $i++) {
        $title = New-Text -Text $titles[$i] -Size 12 -Brush 'Muted'
        if ($i -eq 5) { $title.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right }
        Add-Cell -Grid $grid -Column $i -Element $title
    }
    $grid.Margin = New-Thickness 8 0 8 6
    return $grid
}

function New-SessionRow {
    param($Session, [bool] $IsFocus, [bool] $ShowFocusLabel, $Lookup)
    $grid = New-TableGrid
    Add-Cell -Grid $grid -Column 0 -Element (New-Dot -Status ([string] $Session.Status))

    $focusLine = $null
    if ($IsFocus -and $ShowFocusLabel) { $focusLine = New-Text -Text 'Your account' -Size 12 -Brush 'Muted' }
    Add-Cell -Grid $grid -Column 1 -Element (New-Stack @((New-Text -Text $Session.User -Size 14 -SemiBold), $focusLine))

    $stateLines = @((New-Text -Text (Get-StatusWord ([string] $Session.Status)) -Size 13), (New-Text -Text (Get-StateDetail -Session $Session) -Size 12 -Brush 'Muted'))
    Add-Cell -Grid $grid -Column 2 -Element (New-Stack $stateLines)

    $signedIn = ''
    if ($null -ne $Session.SignedInFor) { $signedIn = '{0} ago' -f (Format-Span $Session.SignedInFor) }
    Add-Cell -Grid $grid -Column 3 -Element (New-Stack @((New-Text -Text $signedIn -Size 13), (New-Text -Text (Format-When $Session.LogonTime) -Size 12 -Brush 'Muted')))

    $client = Get-ClientText -Session $Session -Lookup $Lookup
    Add-Cell -Grid $grid -Column 4 -Element (New-Stack @((New-Text -Text $client.Main -Size 13), (New-Text -Text $client.Sub -Size 12 -Brush 'Muted')))

    $id = New-Text -Text ([string] $Session.SessionId) -Size 13 -Brush 'Ink2'
    $id.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $id.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
    Add-Cell -Grid $grid -Column 5 -Element $id

    $row = New-Object System.Windows.Controls.Border
    $row.Child = $grid
    $row.Padding = New-Thickness 8 10 8 10
    $row.BorderBrush = Get-Brush 'Line'
    $row.BorderThickness = New-Thickness 0 1 0 0
    if ($IsFocus) { $row.Background = Get-Brush 'Surface' }
    return $row
}

function New-SystemRow {
    param($Entry)
    $grid = New-TableGrid
    Add-Cell -Grid $grid -Column 0 -Element (New-Dot -Status 'System')
    $name = [string] $Entry.Name
    if (-not $name) { $name = 'Unnamed' }
    Add-Cell -Grid $grid -Column 1 -Element (New-Text -Text $name -Size 13 -Brush 'Ink2')
    Add-Cell -Grid $grid -Column 2 -Element (New-Text -Text (ConvertTo-Sentence $Entry.Meaning) -Size 13 -Brush 'Ink2') -Span 3
    $id = New-Text -Text ([string] $Entry.SessionId) -Size 13 -Brush 'Muted'
    $id.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    Add-Cell -Grid $grid -Column 5 -Element $id
    $row = New-Object System.Windows.Controls.Border
    $row.Child = $grid
    $row.Padding = New-Thickness 8 8 8 8
    $row.BorderBrush = Get-Brush 'Line'
    $row.BorderThickness = New-Thickness 0 1 0 0
    return $row
}

function Show-Sessions {
    $panel = $script:ui.SessionsPanel
    $panel.Children.Clear()
    $current = $script:Current
    if ($null -eq $current) { return }
    $result = $current.Result
    if ([string] $result.Status -eq 'Unknown') {
        $script:ui.SessionsTitle.Text = 'People signed in'
        $script:ui.SessionsHint.Text = 'Not known: the check did not get through.'
        return
    }
    $people = @($result.Sessions)
    $lookup = $script:ClientMaps[$current.Request.Key]
    $focusId = $result.SessionId
    $ordered = @($people | Sort-Object -Property @{ Expression = { if ($_.SessionId -eq $focusId) { 0 } else { 1 } } }, @{ Expression = { $_.Rank }; Descending = $true }, @{ Expression = { $_.SessionId } })

    $script:ui.SessionsTitle.Text = 'People signed in ({0})' -f $people.Count
    if ($people.Count -eq 0) { $script:ui.SessionsHint.Text = 'Nobody is signed in to this machine.' }
    else { $script:ui.SessionsHint.Text = 'Everyone with a session on {0}. Disconnected sessions keep their apps running.' -f $current.Request.Host }

    if ($people.Count -gt 0) {
        $null = $panel.Children.Add((New-TableHeader))
        foreach ($s in $ordered) {
            $null = $panel.Children.Add((New-SessionRow -Session $s -IsFocus ($s.SessionId -eq $focusId) -ShowFocusLabel ([bool] $current.Request.Account) -Lookup $lookup))
        }
    }

    $system = @($result.SystemSessions)
    if ($system.Count -gt 0) {
        $title = New-Text -Text ('Not people ({0})' -f $system.Count) -Size 13 -SemiBold
        $title.Margin = New-Thickness 0 20 0 2
        $null = $panel.Children.Add($title)
        $explain = New-Text -Text 'Windows keeps these sessions for itself. Nobody is signed in to them, so they never block a connection.' -Size 12 -Brush 'Muted' -Wrap
        $explain.Margin = New-Thickness 0 0 0 6
        $null = $panel.Children.Add($explain)
        foreach ($entry in @($system | Sort-Object -Property SessionId)) {
            $null = $panel.Children.Add((New-SystemRow -Entry $entry))
        }
    }
}

function Update-Footer {
    $parts = @()
    if ($null -ne $script:Current) {
        $result = $script:Current.Result
        $took = ''
        if ($null -ne $result.DurationMs) { $took = ' in {0} ms' -f $result.DurationMs }
        $parts += ('Checked {0} at {1:HH:mm:ss}{2}.' -f $script:Current.Request.Host, $result.CheckedAt, $took)
    }
    else {
        $parts += 'Not checked yet.'
    }
    if ($null -ne $script:CheckTask) {
        $parts += ('Checking now{0}' -f $script:Ellipsis)
    }
    elseif ($script:ui.AutoBox.IsChecked -and $null -ne $script:LastRequest) {
        $left = [int] [Math]::Max(0, [Math]::Ceiling(($script:NextCheckAt - (Get-Date)).TotalSeconds))
        $parts += ('Next check of {0} in {1} s.' -f $script:LastRequest.Host, $left)
    }
    if ($null -ne $script:NotifyKey) { $parts += 'You will get a notification when it is free.' }
    $script:ui.FooterText.Text = $parts -join ' '
}

#endregion

#region Recent machines

function Update-Recent {
    param($Request, $Result)
    for ($i = $script:Recent.Count - 1; $i -ge 0; $i--) {
        if ($script:Recent[$i].Key -eq $Request.Key) { $script:Recent.RemoveAt($i) }
    }
    $entry = @{ Key = $Request.Key; Host = $Request.Host; Account = $Request.Account; Status = [string] $Result.Status; Time = Get-Date }
    $script:Recent.Insert(0, $entry)
    while ($script:Recent.Count -gt 12) { $script:Recent.RemoveAt($script:Recent.Count - 1) }
    Show-RecentList
    Save-DashboardSettings
}

function Show-RecentList {
    $script:UpdatingRecent = $true
    try {
        $list = $script:ui.RecentList
        $list.Items.Clear()
        foreach ($entry in $script:Recent) {
            $grid = New-Object System.Windows.Controls.Grid
            $first = New-Object System.Windows.Controls.ColumnDefinition
            $first.Width = New-Object System.Windows.GridLength -ArgumentList 18.0, ([System.Windows.GridUnitType]::Pixel)
            $grid.ColumnDefinitions.Add($first)
            $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
            Add-Cell -Grid $grid -Column 0 -Element (New-Dot -Status ([string] $entry.Status))
            $who = 'as yourself'
            if ($entry.Account) { $who = 'as {0}' -f $entry.Account }
            $state = 'not checked yet'
            if ($entry.Status -ne 'None' -and $null -ne $entry.Time) { $state = '{0} at {1:HH:mm}' -f (Get-StatusWord $entry.Status).ToLower(), $entry.Time }
            $texts = New-Stack @((New-Text -Text $entry.Host -Size 13 -SemiBold), (New-Text -Text ('{0}, {1}' -f $who, $state) -Size 12 -Brush 'Muted'))
            Add-Cell -Grid $grid -Column 1 -Element $texts
            $item = New-Object System.Windows.Controls.ListBoxItem
            $item.Style = $script:Window.FindResource('RecentItem')
            $item.Content = $grid
            $item.Tag = $entry
            $null = $list.Items.Add($item)
        }
        if ($script:Recent.Count -gt 0) { $script:ui.RecentEmpty.Visibility = [System.Windows.Visibility]::Collapsed }
        else { $script:ui.RecentEmpty.Visibility = [System.Windows.Visibility]::Visible }
    }
    finally {
        $script:UpdatingRecent = $false
    }
}

function Select-RecentEntry {
    param($Entry)
    $script:ui.HostBox.Text = $Entry.Host
    $script:ui.UserBox.Text = $Entry.Account
    $script:ui.PassBox.Clear()
    Update-PassHint
    if (-not $Entry.Account -or $script:Secrets.ContainsKey($Entry.Key)) {
        Invoke-CheckFromForm
        return
    }
    $null = $script:ui.PassBox.Focus()
    Show-Banner -Text ('Type the password for {0}, then press Check now.' -f $Entry.Account) -Kind Info -Transient
}

function Update-PassHint {
    $key = ('{0}|{1}' -f ([string] $script:ui.HostBox.Text).Trim(), ([string] $script:ui.UserBox.Text).Trim()).ToLowerInvariant()
    if ($script:ui.PassBox.SecurePassword.Length -eq 0 -and $script:Secrets.ContainsKey($key)) {
        $script:ui.PassHint.Text = 'The password you typed earlier for this account is used.'
    }
    else {
        $script:ui.PassHint.Text = 'Kept in memory until you close this window.'
    }
}

function Read-DashboardSettings {
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return }
    try {
        $data = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
        foreach ($item in @($data.recent)) {
            if ($null -eq $item -or -not $item.host) { continue }
            $account = [string] $item.account
            $key = ('{0}|{1}' -f $item.host, $account).ToLowerInvariant()
            $null = $script:Recent.Add(@{ Key = $key; Host = [string] $item.host; Account = $account; Status = 'None'; Time = $null })
        }
        if ($null -ne $data.autoRefresh) { $script:ui.AutoBox.IsChecked = [bool] $data.autoRefresh }
    }
    catch {
        Write-UiLog -Text ("Couldn't read {0}: {1}" -f $script:SettingsPath, $_.Exception.Message) -Kind Warning
    }
}

function Save-DashboardSettings {
    try {
        $folder = Split-Path -Parent $script:SettingsPath
        if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
        $recent = @(foreach ($entry in $script:Recent) { [ordered]@{ host = $entry.Host; account = $entry.Account } })
        $autoRefresh = $false
        if ($script:ui.AutoBox.IsChecked) { $autoRefresh = $true }
        if ($null -ne $script:NotifyKey) { $autoRefresh = $script:AutoBeforeNotify }
        $data = [ordered]@{ recent = $recent; autoRefresh = $autoRefresh }
        Set-Content -LiteralPath $script:SettingsPath -Value (ConvertTo-Json -InputObject $data -Depth 4) -Encoding UTF8
    }
    catch {
        Write-UiLog -Text ("Couldn't save {0}: {1}" -f $script:SettingsPath, $_.Exception.Message) -Kind Warning
    }
}

#endregion

#region Actions

function Start-RdpSession {
    # Remote Desktop with the machine and account filled in, keeping the person's
    # own defaults (Default.rdp) for screen size, drives and so on.
    param($Request)
    try {
        $folder = Join-Path ([System.IO.Path]::GetTempPath()) 'SharedRdp'
        if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
        $file = Join-Path $folder ('{0}.rdp' -f ($Request.Host -replace '[^\w.-]', '_'))
        $lines = New-Object System.Collections.Generic.List[string]
        $template = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Default.rdp'
        if (Test-Path -LiteralPath $template) {
            foreach ($line in @(Get-Content -LiteralPath $template)) {
                if (-not $line -or $line -match '^\s*(full address|alternate full address|username)\s*:') { continue }
                $lines.Add($line)
            }
        }
        $lines.Add(('full address:s:{0}' -f $Request.Host))
        if ($Request.Account) { $lines.Add(('username:s:{0}' -f $Request.Account)) }
        Set-Content -LiteralPath $file -Value $lines -Encoding Unicode
        Write-UiLog -Text ('Starting Remote Desktop: mstsc "{0}"' -f $file)
        Start-Process -FilePath 'mstsc.exe' -ArgumentList ('"{0}"' -f $file)
    }
    catch {
        Show-Banner -Text ("Couldn't start Remote Desktop: {0}" -f $_.Exception.Message) -Kind Error
    }
}

function Invoke-Connect {
    param([switch] $SkipConfirm)
    $current = $script:Current
    if ($null -eq $current) { return }
    $status = [string] $current.Result.Status
    $s = $current.Result.Session
    $risky = @('InUse', 'Idle', 'Locked', 'Busy', 'Connecting') -contains $status
    if ($risky -and -not $SkipConfirm) {
        $who = 'Someone'
        if ($null -ne $s) { $who = $s.User }
        $what = 'is connected'
        switch ($status) {
            'InUse'      { $what = 'is working on it right now' }
            'Idle'       { $what = 'is connected but idle' }
            'Locked'     { $what = 'is connected with the screen locked' }
            'Busy'       { $what = 'has automation running' }
            'Connecting' { $what = 'is signing in right now' }
        }
        $message = "{0} {1} on {2}.`n`nConnecting now disconnects them without warning; their apps keep running.`n`nConnect anyway?" -f $who, $what, $current.Request.Host
        $answer = [System.Windows.MessageBox]::Show($script:Window, $message, 'Connect anyway?', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning, [System.Windows.MessageBoxResult]::No)
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }
    Start-RdpSession -Request $current.Request
}

function Invoke-Watch {
    $current = $script:Current
    if ($null -eq $current -or $null -eq $current.Result.Session) { return }
    $arguments = '/v:{0} /shadow:{1}' -f $current.Request.QueryHost, $current.Result.Session.SessionId
    if ($current.Request.Account) { $arguments += ' /prompt' }
    Write-UiLog -Text ('Starting a view-only window: mstsc {0}' -f $arguments)
    try {
        Start-Process -FilePath 'mstsc.exe' -ArgumentList $arguments
        Show-Banner -Text 'Opened a view-only window. Watching needs administrator rights on that machine, and by default the other person is asked first.' -Kind Info -Transient
    }
    catch {
        Show-Banner -Text ("Couldn't start Remote Desktop: {0}" -f $_.Exception.Message) -Kind Error
    }
}

function Invoke-Ask {
    $current = $script:Current
    if ($null -eq $current -or $null -eq $current.Result.Session -or $null -ne $script:AskTask) { return }
    $s = $current.Result.Session
    $ask = Get-AskMessage -TimeoutSeconds $script:Options.AskTimeout
    $script:AskDeadline = (Get-Date).AddSeconds($script:Options.AskTimeout)
    $script:AskUser = $s.User
    $arguments = @{
        JobHost = $current.Request.QueryHost; JobSessionId = [int] $s.SessionId; JobTitle = $ask.Title
        JobMessage = $ask.Message; JobTimeout = $script:Options.AskTimeout; JobCredential = $current.Request.Credential
    }
    $context = @{ Request = $current.Request; User = $s.User; Status = [string] $current.Result.Status }
    $script:AskTask = Start-Background -Name ('Asking {0} on {1}' -f $s.User, $current.Request.Host) -Script $script:AskJobScript -Arguments $arguments -Context $context -OnDone {
        param($Output, $Failure, $Context)
        Complete-Ask -Output $Output -Failure $Failure -Context $Context
    }
    $text = 'Asked {0} to let you take over.' -f $s.User
    if ($current.Result.Status -eq 'Locked') { $text += ' Their screen is locked, so they may not see it until they are back.' }
    Show-Banner -Text $text -Kind Info
    Update-AskBanner
    Update-Actions
}

function Update-AskBanner {
    if ($null -eq $script:AskTask) { return }
    $left = [int] [Math]::Max(0, [Math]::Ceiling(($script:AskDeadline - (Get-Date)).TotalSeconds))
    $script:ui.BannerText.Text = 'Asked {0} to let you take over. Waiting for an answer, {1} s left.' -f $script:AskUser, $left
}

function Complete-Ask {
    param($Output, $Failure, $Context)
    $script:AskTask = $null
    Update-Actions
    if ($null -ne $Output -and $Output.Ok) {
        switch ([int] $Output.Value) {
            6 {
                Show-Banner -Text ('{0} said yes. Opening Remote Desktop.' -f $Context.User) -Kind Good -Transient
                Start-RdpSession -Request $Context.Request
                return
            }
            7 {
                Show-Banner -Text ('{0} wants to keep working.' -f $Context.User) -Kind Warning -ActionText "Tell me when it's free" -Action { Switch-Notify }
                return
            }
            32000 {
                Show-Banner -Text ('No answer from {0} within {1} s.' -f $Context.User, $script:Options.AskTimeout) -Kind Warning -ActionText ('Connect anyway' + $script:Ellipsis) -Action { Invoke-Connect }
                return
            }
        }
        Show-Banner -Text ('The request came back with an unexpected answer (code {0}).' -f $Output.Value) -Kind Warning
        return
    }
    $text = 'the request could not be sent'
    if ($null -ne $Failure) { $text = (Get-FailureText -ErrorRecord $Failure -Operation Ask -Settings $Context.Request.Settings).Text }
    Show-Banner -Text ("Couldn't ask: {0}" -f $text) -Kind Error
}

function Switch-Notify {
    $current = $script:Current
    if ($null -ne $script:NotifyKey) {
        $script:NotifyKey = $null
        $script:ui.AutoBox.IsChecked = $script:AutoBeforeNotify
        Show-Banner -Text 'Stopped watching for a free session.' -Kind Info -Transient
        Update-Actions
        Update-Footer
        return
    }
    if ($null -eq $current) { return }
    $script:NotifyKey = $current.Request.Key
    $script:AutoBeforeNotify = [bool] $script:ui.AutoBox.IsChecked
    $script:ui.AutoBox.IsChecked = $true
    $script:LastRequest = $current.Request
    $script:NextCheckAt = (Get-Date).AddSeconds($script:Options.Refresh)
    Show-Banner -Text ('Watching {0}: checking every {1} s. You get a notification when it is free; keep this window open.' -f $current.Request.Host, $script:Options.Refresh) -Kind Info -ActionText 'Stop watching' -Action { Switch-Notify }
    Update-Actions
    Update-Footer
}

function Test-NotifyCondition {
    param($Request, $Result)
    if ($null -eq $script:NotifyKey -or $script:NotifyKey -ne $Request.Key) { return }
    $status = [string] $Result.Status
    if ($status -ne 'Free' -and $status -ne 'Disconnected') { return }
    $script:NotifyKey = $null
    $script:ui.AutoBox.IsChecked = $script:AutoBeforeNotify
    $text = '{0} is free.' -f $Request.Host
    if ($status -eq 'Disconnected') { $text = '{0} is free: the session is disconnected.' -f $Request.Host }
    Show-Banner -Text ('{0} Connect now?' -f $text) -Kind Good -ActionText 'Connect' -Action { Invoke-Connect -SkipConfirm }
    Send-Notification -Title 'Shared Remote Desktop' -Text $text
    Update-Actions
    Update-Footer
}

function Send-Notification {
    param([string] $Title, [string] $Text)
    try { [System.Media.SystemSounds]::Asterisk.Play() } catch { Write-Verbose 'No sound.' }
    try {
        $handle = (New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $script:Window).Handle
        if ('SharedRdpUi.NativeWindow' -as [type]) { [SharedRdpUi.NativeWindow]::Flash($handle) }
    }
    catch {
        Write-UiLog -Text ("Couldn't flash the taskbar button: {0}" -f $_.Exception.Message) -Kind Trace
    }
    try {
        if ($null -eq $script:TrayIcon) {
            $script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
            if ($null -ne $script:AppIcon) { $script:TrayIcon.Icon = $script:AppIcon }
            else { $script:TrayIcon.Icon = [System.Drawing.SystemIcons]::Information }
            $script:TrayIcon.Text = 'Shared Remote Desktop'
            $script:TrayIcon.Add_BalloonTipClicked({ Invoke-Safely { $null = $script:Window.Activate() } })
            $script:TrayIcon.Add_MouseClick({ Invoke-Safely { $null = $script:Window.Activate() } })
        }
        $script:TrayIcon.Visible = $true
        $script:TrayIcon.ShowBalloonTip(10000, $Title, $Text, [System.Windows.Forms.ToolTipIcon]::Info)
    }
    catch {
        Write-UiLog -Text ("Couldn't show a notification: {0}" -f $_.Exception.Message) -Kind Warning
    }
}

function Get-LookupFailureText {
    param($Failure)
    if ($null -eq $Failure) { return 'the lookup ended without a result' }
    $message = ([string] $Failure.Exception.Message).Trim()
    $ex = $Failure.Exception
    while ($null -ne $ex) {
        $type = $ex.GetType().FullName
        if ($ex -is [System.UnauthorizedAccessException]) {
            return ('{0} The account may not read that machine''s event logs; use an administrator there, or a member of its Event Log Readers group.' -f $message)
        }
        if ($type -like '*EventLogNotFoundException') {
            return ('{0} That machine has no Remote Desktop session log.' -f $message)
        }
        if ($type -like '*EventLogException') {
            return ('{0} If it says the RPC server is unavailable, enable the "Remote Event Log Management" firewall rules on that machine; if access is denied, use an administrator account there.' -f $message)
        }
        $ex = $ex.InnerException
    }
    return $message
}

function Invoke-Lookup {
    $current = $script:Current
    if ($null -eq $current -or $null -ne $script:LookupTask) { return }
    $arguments = @{ JobHost = $current.Request.QueryHost; JobCredential = $current.Request.Credential }
    $script:LookupTask = Start-Background -Name ('Reading the session event log of {0}' -f $current.Request.Host) -Script $script:LookupJobScript -Arguments $arguments -Context $current.Request -OnDone {
        param($Output, $Failure, $Context)
        Complete-Lookup -Output $Output -Failure $Failure -Request $Context
    }
    Update-Actions
}

function Complete-Lookup {
    param($Output, $Failure, $Request)
    $script:LookupTask = $null
    $entry = @{ Map = $null; Error = ''; Time = Get-Date }
    if ($null -ne $Output -and $Output.Ok) { $entry.Map = $Output.Value }
    else { $entry.Error = Get-LookupFailureText -Failure $Failure }
    $script:ClientMaps[$Request.Key] = $entry
    if ($entry.Error) {
        Show-Banner -Text ("Couldn't read the event log of {0}: {1}" -f $Request.Host, $entry.Error) -Kind Warning
    }
    if ($null -ne $script:Current -and $script:Current.Request.Key -eq $Request.Key) { Show-Result }
    else { Update-Actions }
}

#endregion

#region Wiring

$script:ui.VersionText.Text = 'Dashboard {0}, engine {1}' -f $script:DashboardVersion, $script:EngineVersion
$script:ui.AutoBox.Content = 'Re-check every {0} s' -f $script:Options.Refresh
$script:ui.IdentityText.Text = 'You are {0}' -f (Get-CheckingIdentity -Credential $null)

try {
    $script:AppIcon = [System.Drawing.Icon]::ExtractAssociatedIcon((Join-Path $env:SystemRoot 'System32\mstsc.exe'))
    $script:Window.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($script:AppIcon.Handle, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
}
catch {
    Write-UiLog -Text ("No window icon: {0}" -f $_.Exception.Message) -Kind Trace
}

$script:ui.CheckButton.Add_Click({ Invoke-Safely { Invoke-CheckFromForm } })
$script:ui.ConnectButton.Add_Click({ Invoke-Safely { Invoke-Connect } })
$script:ui.AskButton.Add_Click({ Invoke-Safely { Invoke-Ask } })
$script:ui.WatchButton.Add_Click({ Invoke-Safely { Invoke-Watch } })
$script:ui.NotifyButton.Add_Click({ Invoke-Safely { Switch-Notify } })
$script:ui.LookupButton.Add_Click({ Invoke-Safely { Invoke-Lookup } })
$script:ui.BannerClose.Add_Click({ Invoke-Safely { Hide-Banner } })
$script:ui.BannerAction.Add_Click({
    Invoke-Safely {
        $block = $script:BannerBlock
        Hide-Banner
        if ($null -ne $block) { & $block }
    }
})
$script:ui.AutoBox.Add_Click({
    Invoke-Safely {
        $script:NextCheckAt = (Get-Date).AddSeconds($script:Options.Refresh)
        Update-Footer
        Save-DashboardSettings
    }
})
$script:ui.FactsGrid.Add_SizeChanged({
    Invoke-Safely {
        # Four facts side by side need about 560 pixels; narrower, they go two by two.
        $columns = 4
        if ($script:ui.FactsGrid.ActualWidth -lt 560) { $columns = 2 }
        if ($script:ui.FactsGrid.Columns -ne $columns) { $script:ui.FactsGrid.Columns = $columns }
    }
})
$script:ui.HostBox.Add_TextChanged({ Invoke-Safely { Update-PassHint } })
$script:ui.UserBox.Add_TextChanged({ Invoke-Safely { Update-PassHint } })
$script:ui.PassBox.Add_PasswordChanged({ Invoke-Safely { Update-PassHint } })
$script:ui.RecentList.Add_SelectionChanged({
    Invoke-Safely {
        if ($script:UpdatingRecent) { return }
        $item = $script:ui.RecentList.SelectedItem
        if ($null -eq $item) { return }
        # Clear the selection so the same machine can be clicked again.
        $script:UpdatingRecent = $true
        try { $script:ui.RecentList.SelectedIndex = -1 }
        finally { $script:UpdatingRecent = $false }
        Select-RecentEntry -Entry $item.Tag
    }
})
$script:ui.LogToggle.Add_Click({
    Invoke-Safely {
        $show = ($script:ui.LogBox.Visibility -ne [System.Windows.Visibility]::Visible)
        $visibility = [System.Windows.Visibility]::Collapsed
        if ($show) { $visibility = [System.Windows.Visibility]::Visible }
        $script:ui.LogBox.Visibility = $visibility
        $script:ui.LogCopy.Visibility = $visibility
        $script:ui.LogSave.Visibility = $visibility
        if ($show) {
            $script:ui.LogToggle.Content = 'Hide the log'
            $script:ui.LogBox.ScrollToEnd()
        }
        else {
            $script:ui.LogToggle.Content = 'Show the step-by-step log'
        }
    }
})
$script:ui.LogCopy.Add_Click({
    Invoke-Safely {
        [System.Windows.Clipboard]::SetText(($script:LogLines -join [Environment]::NewLine))
        Show-Banner -Text 'Copied the log to the clipboard.' -Kind Good -Transient
    }
})
$script:ui.LogSave.Add_Click({
    Invoke-Safely {
        $dialog = New-Object Microsoft.Win32.SaveFileDialog
        $dialog.FileName = 'SharedRdp-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date)
        $dialog.Filter = 'Log files (*.log)|*.log|All files (*.*)|*.*'
        if ($dialog.ShowDialog($script:Window)) {
            Set-Content -LiteralPath $dialog.FileName -Value $script:LogLines -Encoding UTF8
            Show-Banner -Text ('Saved the log to {0}.' -f $dialog.FileName) -Kind Good -Transient
        }
    }
})

$script:Window.Add_PreviewKeyDown({
    if ($_.Key -eq [System.Windows.Input.Key]::F5) {
        $_.Handled = $true
        Invoke-Safely { Invoke-CheckFromForm }
    }
})
$script:Window.Add_SourceInitialized({
    Invoke-Safely {
        if ('SharedRdpUi.NativeWindow' -as [type]) {
            $handle = (New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $script:Window).Handle
            [SharedRdpUi.NativeWindow]::SetDarkTitleBar($handle, $script:IsDark)
        }
    }
})
$script:Window.Add_Loaded({
    Invoke-Safely {
        Read-DashboardSettings
        Show-RecentList
        Update-Actions
        Update-Footer
        if ($script:Options.Host) { $script:ui.HostBox.Text = $script:Options.Host }
        if ($script:Options.User) { $script:ui.UserBox.Text = $script:Options.User }
        Update-PassHint
        if ($script:Options.Host -and -not $script:Options.User) { Invoke-CheckFromForm }
        elseif ($script:Options.Host) { $null = $script:ui.PassBox.Focus() }
        else { $null = $script:ui.HostBox.Focus() }
        Write-UiLog -Text ('Dashboard {0} with engine {1} ({2}), PowerShell {3}' -f $script:DashboardVersion, $script:EngineVersion, $script:EnginePath, $PSVersionTable.PSVersion)
    }
})
$script:Window.Dispatcher.Add_UnhandledException({
    try { Write-UiLog -Text ('Unhandled error: {0}' -f $_.Exception.Message) -Kind Error } catch { Write-Verbose 'Log unavailable.' }
    $_.Handled = $true
})

$script:JobTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:JobTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$script:JobTimer.Add_Tick({ Invoke-Safely { Complete-Background } })
$script:JobTimer.Start()

$script:Clock = New-Object System.Windows.Threading.DispatcherTimer
$script:Clock.Interval = [TimeSpan]::FromSeconds(1)
$script:Clock.Add_Tick({
    Invoke-Safely {
        if ($script:ui.AutoBox.IsChecked -and $null -ne $script:LastRequest -and $null -eq $script:CheckTask -and (Get-Date) -ge $script:NextCheckAt) {
            Start-Check -Request $script:LastRequest
        }
        if ($null -ne $script:AskTask) { Update-AskBanner }
        Update-Footer
    }
})
$script:Clock.Start()

$script:Window.Add_Closing({ Invoke-Safely { Save-DashboardSettings } })
$script:Window.Add_Closed({
    $script:Clock.Stop()
    $script:JobTimer.Stop()
    if ($null -ne $script:TrayIcon) {
        $script:TrayIcon.Visible = $false
        $script:TrayIcon.Dispose()
    }
    try { $null = $script:Pool.BeginClose($null, $null) } catch { Write-Verbose 'The background pool was already closed.' }
})

$null = $script:Window.ShowDialog()

#endregion
