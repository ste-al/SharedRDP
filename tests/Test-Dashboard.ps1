#Requires -Version 5.1
<#
.SYNOPSIS
    Opens the dashboard through SharedRdp-Dashboard.cmd, lets it check this
    computer, reads what it shows, saves screenshots, and closes it again.

.DESCRIPTION
    Needs an interactive desktop; GitHub's Windows runners have one. The window
    is driven with UI Automation: wait for the first check, open the log, check
    again, read every text, take screenshots, close the window. With -Dark it
    runs a second time with the dark app theme (it sets AppsUseLightTheme for the
    current user and restores it afterwards).

    Fails when the window does not open, shows a start-up error, logs an error,
    shows Unknown, or does not close.

    powershell.exe -ExecutionPolicy Bypass -File .\tests\Test-Dashboard.ps1 -OutputPath .\out
#>
[CmdletBinding()]
param(
    [string] $OutputPath = 'out',
    [string] $ComputerName = 'localhost',
    [ValidateRange(10, 600)]
    [int] $TimeoutSeconds = 60,
    [switch] $Dark
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $root 'SharedRdp-Dashboard.cmd'
$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$null = New-Item -ItemType Directory -Path $OutputPath -Force
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing, System.Windows.Forms

$texts = @(
    'SignWord', 'HostLine', 'Headline', 'Advice', 'NotesText', 'ErrorText',
    'Fact1Label', 'Fact1Value', 'Fact1Sub', 'Fact2Label', 'Fact2Value', 'Fact2Sub',
    'Fact3Label', 'Fact3Value', 'Fact3Sub', 'Fact4Label', 'Fact4Value', 'Fact4Sub',
    'SessionsTitle', 'SessionsHint', 'IdentityText', 'FooterText', 'VersionText', 'BannerText'
)

function Write-Problem {
    param([string] $Message)
    Write-Host ('ERROR: {0}' -f $Message) -ForegroundColor Red
    if ($env:GITHUB_ACTIONS) {
        Write-Host ('::error title=Dashboard::{0}' -f $Message.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A'))
    }
}

function Find-ById {
    param($Parent, [string] $Id)
    $condition = New-Object System.Windows.Automation.PropertyCondition -ArgumentList ([System.Windows.Automation.AutomationElement]::AutomationIdProperty), $Id
    return $Parent.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Get-Text {
    # A text block's text is its name; a text box's is its value.
    param($Parent, [string] $Id)
    $element = Find-ById -Parent $Parent -Id $Id
    if ($null -eq $element) { return $null }
    $pattern = $null
    if ($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref] $pattern)) { return $pattern.Current.Value }
    return $element.Current.Name
}

function Invoke-Button {
    param($Parent, [string] $Id)
    $element = Find-ById -Parent $Parent -Id $Id
    if ($null -eq $element) { throw ('button {0} not found' -f $Id) }
    $element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Wait-For {
    param([string] $What, [int] $Seconds, [scriptblock] $Condition)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $value = & $Condition
        if ($value) { return $value }
        Start-Sleep -Milliseconds 400
    }
    throw ('waited {0} s for {1}' -f $Seconds, $What)
}

function Find-DashboardWindow {
    # The dashboard, or a start-up error box, which has the same title.
    $condition = New-Object System.Windows.Automation.PropertyCondition -ArgumentList ([System.Windows.Automation.AutomationElement]::NameProperty), 'Shared Remote Desktop'
    return [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $condition)
}

function Save-Screen {
    # The whole screen, or just one window.
    param([string] $Path, $Window = $null)
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    if ($null -ne $Window) {
        try { $Window.SetFocus() } catch { Write-Host ('  Could not bring the window to the front: {0}' -f $_.Exception.Message) }
        Start-Sleep -Milliseconds 700
        $rect = $Window.Current.BoundingRectangle
        $bounds = New-Object System.Drawing.Rectangle -ArgumentList ([int] $rect.X), ([int] $rect.Y), ([int] $rect.Width), ([int] $rect.Height)
    }
    $bitmap = New-Object System.Drawing.Bitmap -ArgumentList $bounds.Width, $bounds.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $bitmap.Size)
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-Host ('  Saved {0} ({1}x{2})' -f (Split-Path -Leaf $Path), $bounds.Width, $bounds.Height)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Get-Snapshot {
    param($Window)
    $snapshot = [ordered]@{}
    foreach ($id in $texts) { $snapshot[$id] = Get-Text -Parent $Window -Id $id }
    return $snapshot
}

function Test-DashboardRun {
    param([string] $Theme)
    $prefix = Join-Path $OutputPath ('dashboard-{0}' -f $Theme)
    Write-Host ''
    Write-Host ('Dashboard, {0} theme: opening it through SharedRdp-Dashboard.cmd -ComputerName {1}' -f $Theme, $ComputerName) -ForegroundColor Cyan
    $null = Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c ""{0}" -ComputerName {1}"' -f $launcher, $ComputerName) -WindowStyle Hidden
    $processId = $null
    try {
        $window = Wait-For -What 'the window' -Seconds $TimeoutSeconds -Condition { Find-DashboardWindow }
        $processId = $window.Current.ProcessId
        Write-Host ('  Window open: process {0}, class {1}, {2}' -f $processId, $window.Current.ClassName, $window.Current.BoundingRectangle)
        if ($window.Current.ClassName -eq '#32770') {
            $all = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
            $message = @($all | ForEach-Object { $_.Current.Name } | Where-Object { $_ }) -join ' | '
            throw ('the dashboard showed a start-up error: {0}' -f $message)
        }

        $null = Wait-For -What 'the first check' -Seconds $TimeoutSeconds -Condition {
            $button = Find-ById -Parent $window -Id 'CheckButton'
            $word = Get-Text -Parent $window -Id 'SignWord'
            ($null -ne $button -and $button.Current.IsEnabled -and $word -and $word -ne 'Not checked')
        }
        $first = Get-Snapshot -Window $window
        foreach ($key in $first.Keys) { if ($first[$key]) { Write-Host ('  {0,-14} {1}' -f $key, $first[$key]) } }
        Save-Screen -Path ($prefix + '.png') -Window $window

        Invoke-Button -Parent $window -Id 'LogToggle'
        $log = [string] (Wait-For -What 'the log' -Seconds 10 -Condition { Get-Text -Parent $window -Id 'LogBox' })
        $checksBefore = [regex]::Matches($log, 'Checking \S+ as ').Count
        Invoke-Button -Parent $window -Id 'CheckButton'
        $null = Wait-For -What 'the second check' -Seconds $TimeoutSeconds -Condition {
            $button = Find-ById -Parent $window -Id 'CheckButton'
            $current = [string] (Get-Text -Parent $window -Id 'LogBox')
            ([regex]::Matches($current, 'Checking \S+ as ').Count -gt $checksBefore) -and $button.Current.IsEnabled
        }
        Save-Screen -Path ($prefix + '-log.png') -Window $window
        $log = [string] (Get-Text -Parent $window -Id 'LogBox')
        Set-Content -LiteralPath ($prefix + '-log.txt') -Value $log -Encoding UTF8
        $second = Get-Snapshot -Window $window
        $lines = @(foreach ($key in $second.Keys) { '{0}: {1}' -f $key, $second[$key] })
        Set-Content -LiteralPath ($prefix + '.txt') -Value $lines -Encoding UTF8

        $problems = @()
        $logErrors = @($log -split "`r?`n" | Where-Object { $_ -match '^\d\d:\d\d:\d\d  ERROR' })
        if ($logErrors.Count -gt 0) { $problems += ('the log has errors: {0}' -f ($logErrors -join ' / ')) }
        if ($second.SignWord -eq 'Unknown') { $problems += ('the check failed: {0}' -f $second.ErrorText) }
        if ($second.SessionsTitle -notmatch '^People signed in \(\d+\)$') { $problems += ('unexpected sessions title: {0}' -f $second.SessionsTitle) }
        if ($second.VersionText -notmatch '^Dashboard \S+, engine \S+$') { $problems += ('unexpected version line: {0}' -f $second.VersionText) }
        if ($problems.Count -gt 0) { throw ($problems -join '; ') }

        $window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -ne $process -and -not $process.WaitForExit(20000)) { throw 'the window closed, but the dashboard process did not end within 20 s' }
        $processId = $null
        Write-Host '  Closed cleanly.' -ForegroundColor Green
    }
    catch {
        $failure = $_
        try { Save-Screen -Path ($prefix + '-failure-screen.png') }
        catch { Write-Host ('  No screenshot of the failure: {0}' -f $_.Exception.Message) }
        throw $failure
    }
    finally {
        if ($null -ne $processId) { Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue }
    }
}

$personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$themes = @('light')
if ($Dark) { $themes += 'dark' }
$failures = 0
foreach ($theme in $themes) {
    $previous = $null
    if (Test-Path -LiteralPath $personalize) { $previous = (Get-ItemProperty -LiteralPath $personalize -ErrorAction SilentlyContinue).AppsUseLightTheme }
    else { $null = New-Item -Path $personalize -Force }
    $light = 1
    if ($theme -eq 'dark') { $light = 0 }
    Set-ItemProperty -LiteralPath $personalize -Name AppsUseLightTheme -Value $light -Type DWord
    try {
        Test-DashboardRun -Theme $theme
    }
    catch {
        $failures++
        Write-Problem -Message ('{0} theme: {1}' -f $theme, $_.Exception.Message)
    }
    finally {
        if ($null -eq $previous) { Remove-ItemProperty -LiteralPath $personalize -Name AppsUseLightTheme -ErrorAction SilentlyContinue }
        else { Set-ItemProperty -LiteralPath $personalize -Name AppsUseLightTheme -Value $previous -Type DWord }
    }
}
if ($failures -gt 0) { exit 1 }
Write-Host ''
Write-Host 'The dashboard checks passed.' -ForegroundColor Green
