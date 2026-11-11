#Requires -Version 5.1
<#
.SYNOPSIS
    Checks the scripts without opening a window or changing anything.

.DESCRIPTION
    - every .ps1 file parses in this PowerShell
    - the shipped files are ASCII only (Windows PowerShell 5.1 reads a file
      without a byte order mark in the local code page) and the launcher has
      CRLF line ends
    - the engine loads the way the dashboard loads it, and has every function
      the dashboard and its background jobs call, with the parameters they use
    - both C# parts compile
    - the window layout loads and lays out in the light and the dark theme, at
      full size and on a small screen, and has every element the code uses
    - the status logic and the dashboard's wording, on made-up sessions
    - a real check of this computer through a runspace pool, the way the
      dashboard runs checks in the background (it only reads the session list)

    Exits with 1 when a check fails. With -OutputPath, the window layouts are
    also rendered to PNG files there.

    powershell.exe -ExecutionPolicy Bypass -File .\tests\Test-Scripts.ps1
#>
[CmdletBinding()]
param(
    [string] $OutputPath
)

# The engine runs with the default preference, as it does for real; the checks
# themselves stop at the first error.
$global:ErrorActionPreference = 'Continue'
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$enginePath = Join-Path $root 'Connect-SharedRdp.ps1'
$dashboardPath = Join-Path $root 'SharedRdp-Dashboard.ps1'
$launcherPath = Join-Path $root 'SharedRdp-Dashboard.cmd'
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Passed = 0
$script:EngineModule = $null
if ($OutputPath) {
    $OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $null = New-Item -ItemType Directory -Path $OutputPath -Force
}

#region Helpers

function Write-Section {
    param([string] $Title)
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
}

function Write-Annotation {
    # Shows a failure on the GitHub Actions run page; does nothing elsewhere.
    param([string] $Title, [string] $Message)
    if (-not $env:GITHUB_ACTIONS) { return }
    $clean = { param($Text) $Text.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A') }
    $titleText = (& $clean $Title).Replace(':', '%3A').Replace(',', '%2C')
    Write-Host ('::error title={0}::{1}' -f $titleText, (& $clean $Message))
}

function Test-Case {
    # One check. It passes when its script block runs without throwing.
    param([string] $Title, [scriptblock] $Body)
    try {
        $null = & $Body
        $script:Passed++
        Write-Host ('  ok    {0}' -f $Title)
    }
    catch {
        $message = $_.Exception.Message
        $script:Failures.Add(('{0}: {1}' -f $Title, $message))
        Write-Host ('  FAIL  {0}: {1}' -f $Title, $message) -ForegroundColor Red
        Write-Annotation -Title $Title -Message $message
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $What = 'value')
    if (-not ($Expected -eq $Actual)) { throw ('{0}: expected [{1}], got [{2}]' -f $What, $Expected, $Actual) }
}

function Assert-Match {
    param([string] $Pattern, [string] $Actual, [string] $What = 'text')
    if ($Actual -notmatch $Pattern) { throw ('{0}: [{1}] does not match /{2}/' -f $What, $Actual, $Pattern) }
}

function Assert-True {
    param([bool] $Condition, [string] $What)
    if (-not $Condition) { throw $What }
}

function Get-ParsedFile {
    param([string] $Path)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $tokens, [ref] $errors)
    return [pscustomobject]@{ Ast = $ast; Errors = @($errors) }
}

function Find-Ast {
    param($Ast, [type] $Type)
    $wanted = $Type
    return @($Ast.FindAll({ param($node) $node -is $wanted }.GetNewClosure(), $true))
}

function Invoke-InSta {
    # WPF needs a single-threaded apartment, which PowerShell 7 may not use.
    param([scriptblock] $Script, [object[]] $ArgumentList = @())
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = [System.Threading.ApartmentState]::STA
    $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()
    $ps = [powershell]::Create()
    try {
        $ps.Runspace = $runspace
        $null = $ps.AddScript($Script.ToString())
        foreach ($argument in $ArgumentList) { $null = $ps.AddArgument($argument) }
        $output = $ps.Invoke()
        if ($ps.Streams.Error.Count -gt 0) { throw $ps.Streams.Error[0].Exception }
        return $output
    }
    finally {
        $ps.Dispose()
        $runspace.Dispose()
    }
}

#endregion

$dashboardText = [System.IO.File]::ReadAllText($dashboardPath)
$dashboard = Get-ParsedFile -Path $dashboardPath
$assignments = Find-Ast -Ast $dashboard.Ast -Type ([System.Management.Automation.Language.AssignmentStatementAst])
$commandType = [System.Management.Automation.Language.CommandAst]
$parameterType = [System.Management.Automation.Language.CommandParameterAst]

function Get-AssignedExpression {
    # The right-hand side of "$Name = <expression>" in the dashboard script.
    param([string] $Name)
    foreach ($assignment in $assignments) {
        if ($assignment.Left.Extent.Text -ne $Name) { continue }
        if ($assignment.Right -is [System.Management.Automation.Language.CommandExpressionAst]) { $assignment.Right.Expression }
    }
}

Write-Host ('PowerShell {0} ({1}), {2}' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, [Environment]::OSVersion.VersionString)

#region Syntax and text

Write-Section 'Syntax'
# out\ holds the screenshots and logs of earlier runs.
$scriptFiles = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]out[\\/]' })
foreach ($scriptFile in $scriptFiles) {
    Test-Case ('{0} parses' -f $scriptFile.Name) {
        $parsed = Get-ParsedFile -Path $scriptFile.FullName
        if ($parsed.Errors.Count -gt 0) {
            throw (($parsed.Errors | ForEach-Object { 'line {0}: {1}' -f $_.Extent.StartLineNumber, $_.Message }) -join '; ')
        }
    }
}

Write-Section 'Text'
# Filtered by extension here: Windows PowerShell 5.1 ignores -Include next to -LiteralPath.
$textFiles = @($scriptFiles) + @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { @('.psd1', '.cmd') -contains $_.Extension -and $_.FullName -notmatch '[\\/]out[\\/]' })
foreach ($textFile in $textFiles) {
    Test-Case ('{0} is ASCII only' -f $textFile.Name) {
        $text = [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes($textFile.FullName))
        $match = [regex]::Match($text, '[^\x00-\x7F]')
        if ($match.Success) {
            $line = ($text.Substring(0, $match.Index) -split "`n").Count
            throw ('byte 0x{0:X2} on line {1}; Windows PowerShell 5.1 would read it in the local code page' -f [int] [char] $match.Value, $line)
        }
    }
}
Test-Case 'SharedRdp-Dashboard.cmd has CRLF line ends' {
    $text = [System.IO.File]::ReadAllText($launcherPath)
    if ($text -match '(?<!\r)\n') { throw 'LF-only line ends; cmd.exe needs CRLF (see .gitattributes)' }
}

#endregion

#region Engine

Write-Section 'Engine'
Test-Case 'Connect-SharedRdp.ps1 loads as a module, the way the dashboard loads it' {
    $script:EngineModule = New-Module -Name SharedRdpEngine -ArgumentList $enginePath -ScriptBlock {
        param($Path)
        . $Path
        Export-ModuleMember -Function *
    }
    $null = $script:EngineModule | Import-Module -DisableNameChecking -Force -PassThru
}
if ($null -eq $script:EngineModule) {
    Write-Host 'The engine did not load; the other checks need it.' -ForegroundColor Red
    exit 1
}
$exported = $script:EngineModule.ExportedFunctions

Test-Case 'every command the dashboard calls exists' {
    $defined = @(Find-Ast -Ast $dashboard.Ast -Type ([System.Management.Automation.Language.FunctionDefinitionAst]) | ForEach-Object { $_.Name })
    $called = @(Find-Ast -Ast $dashboard.Ast -Type $commandType | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -match '^\w+-\w+$' } | Sort-Object -Unique)
    $unknown = @($called | Where-Object { ($defined -notcontains $_) -and -not $exported.ContainsKey($_) -and -not (Get-Command -Name $_ -CommandType Cmdlet, Function -ErrorAction SilentlyContinue) })
    if ($unknown.Count -gt 0) { throw ('not defined anywhere: {0}' -f ($unknown -join ', ')) }
}

Test-Case 'the dashboard calls engine functions with parameters they have' {
    $problems = @()
    foreach ($command in (Find-Ast -Ast $dashboard.Ast -Type $commandType)) {
        $name = $command.GetCommandName()
        if (-not $name -or -not $exported.ContainsKey($name)) { continue }
        foreach ($element in $command.CommandElements) {
            if ($element -is $parameterType -and -not $exported[$name].Parameters.ContainsKey($element.ParameterName)) {
                $problems += ('line {0}: {1} -{2}' -f $element.Extent.StartLineNumber, $name, $element.ParameterName)
            }
        }
    }
    if ($problems.Count -gt 0) { throw ($problems -join '; ') }
}

Test-Case 'the background job scripts parse and call engine functions correctly' {
    $problems = @()
    foreach ($name in '$script:CheckJobScript', '$script:AskJobScript', '$script:LookupJobScript') {
        $text = [string] @(Get-AssignedExpression -Name $name)[0].Value
        if (-not $text) { $problems += ('{0} not found' -f $name); continue }
        $tokens = $null
        $errors = $null
        $jobAst = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref] $tokens, [ref] $errors)
        if (@($errors).Count -gt 0) { $problems += ('{0}: {1}' -f $name, $errors[0].Message); continue }
        foreach ($command in (Find-Ast -Ast $jobAst -Type $commandType)) {
            $commandName = $command.GetCommandName()
            if (-not $exported.ContainsKey($commandName)) { $problems += ('{0} calls {1}, which the engine lacks' -f $name, $commandName); continue }
            foreach ($element in $command.CommandElements) {
                if ($element -is $parameterType -and -not $exported[$commandName].Parameters.ContainsKey($element.ParameterName)) {
                    $problems += ('{0}: {1} has no -{2}' -f $name, $commandName, $element.ParameterName)
                }
            }
        }
    }
    if ($problems.Count -gt 0) { throw ($problems -join '; ') }
}

Test-Case 'the Remote Desktop Services wrapper compiles' {
    Initialize-Native
    $type = 'SharedRdpV2.Wts' -as [type]
    Assert-True ($null -ne $type) 'type SharedRdpV2.Wts is missing'
    foreach ($method in 'GetSessions', 'GetProcesses', 'AskSession', 'FormatAddress') {
        Assert-True (@($type.GetMethods() | Where-Object { $_.Name -eq $method }).Count -gt 0) ('method {0} is missing' -f $method)
    }
}

Test-Case 'client addresses start two bytes into WTS_CLIENT_ADDRESS, IPv4 and IPv6 alike' {
    $v4 = New-Object byte[] 20
    $v4[2] = 10; $v4[3] = 0; $v4[4] = 0; $v4[5] = 12
    Assert-Equal '10.0.0.12' ([SharedRdpV2.Wts]::FormatAddress(2, $v4)) 'IPv4'
    $v6 = New-Object byte[] 20
    [Array]::Copy([System.Net.IPAddress]::Parse('2001:db8::5').GetAddressBytes(), 0, $v6, 2, 16)
    Assert-Equal '2001:db8::5' ([SharedRdpV2.Wts]::FormatAddress(23, $v6)) 'IPv6'
    Assert-True ($null -eq [SharedRdpV2.Wts]::FormatAddress(23, (New-Object byte[] 20))) 'an empty address should give none'
    Assert-True ($null -eq [SharedRdpV2.Wts]::FormatAddress(0, $v4)) 'an unknown family should give none'
}

Test-Case 'the dashboard window helper compiles' {
    $source = $null
    foreach ($command in (Find-Ast -Ast $dashboard.Ast -Type $commandType)) {
        if ($command.GetCommandName() -ne 'Add-Type') { continue }
        $elements = @($command.CommandElements)
        for ($i = 0; $i -lt $elements.Count - 1; $i++) {
            if ($elements[$i] -is $parameterType -and $elements[$i].ParameterName -eq 'TypeDefinition') { $source = $elements[$i + 1].Value }
        }
    }
    Assert-True ([bool] $source) 'no Add-Type -TypeDefinition found'
    Add-Type -TypeDefinition $source
    Assert-True ($null -ne ('SharedRdpUi.NativeWindow' -as [type])) 'type SharedRdpUi.NativeWindow is missing'
}

#endregion

#region Window layout

Write-Section 'Window layout'
$template = [string] @(Get-AssignedExpression -Name '$script:XamlTemplate')[0].Value
$palettes = @(Get-AssignedExpression -Name '$script:Palette' | ForEach-Object { $_.SafeGetValue() })
# Names inside a control template belong to each control that uses it, not to the window.
$windowXaml = [regex]::Replace($template, '(?s)<ControlTemplate\b.*?</ControlTemplate>', '')
$xamlNames = @([regex]::Matches($windowXaml, 'x:Name="(\w+)"') | ForEach-Object { $_.Groups[1].Value })
$tableMembers = @('ContainsKey', 'Keys', 'Values', 'Count')
$codeNames = @([regex]::Matches($dashboardText, '\$script:ui\.(\w+)') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $tableMembers -notcontains $_ } | Sort-Object -Unique)
$styleNames = @([regex]::Matches($dashboardText, "FindResource\('(\w+)'\)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

Test-Case 'the layout and both themes are found' {
    Assert-True ($template.Length -gt 1000) 'the XAML template was not found'
    Assert-Equal 2 $palettes.Count 'number of themes'
}

Test-Case 'every element the code uses is in the layout' {
    $wanted = @($codeNames) + @(foreach ($i in 1..4) { foreach ($part in 'Label', 'Value', 'Sub') { 'Fact{0}{1}' -f $i, $part } })
    $missing = @($wanted | Where-Object { $xamlNames -notcontains $_ })
    if ($missing.Count -gt 0) { throw ('missing: {0}' -f ($missing -join ', ')) }
}

Test-Case 'both themes have a value for every color in the layout' {
    $tokens = @([regex]::Matches($template, '@(\w+)@') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    foreach ($palette in $palettes) {
        $missing = @($tokens | Where-Object { -not $palette.ContainsKey($_) })
        if ($missing.Count -gt 0) { throw ('the theme with page color {0} lacks {1}' -f $palette.Page, ($missing -join ', ')) }
    }
}

$layoutScript = {
    param($Xaml, $Names, $Styles, $Width, $Height, $PngPath)
    $ErrorActionPreference = 'Stop'
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
    $window = [System.Windows.Markup.XamlReader]::Parse($Xaml)
    $missing = @($Names | Where-Object { $null -eq $window.FindName($_) })
    $noStyle = @($Styles | Where-Object { $null -eq $window.TryFindResource($_) })
    $area = New-Object System.Windows.Rect -ArgumentList 0, 0, $Width, $Height
    $content = $window.Content
    $content.Measure($area.Size)
    $content.Arrange($area)
    $content.UpdateLayout()
    if ($PngPath) {
        $backdrop = New-Object System.Windows.Shapes.Rectangle
        $backdrop.Fill = $window.Background
        $backdrop.Measure($area.Size)
        $backdrop.Arrange($area)
        $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap -ArgumentList ([int] $Width), ([int] $Height), 96.0, 96.0, ([System.Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($backdrop)
        $bitmap.Render($content)
        $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream = [System.IO.File]::Create($PngPath)
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
    }
    [pscustomobject]@{ Missing = $missing; NoStyle = $noStyle }
}

foreach ($palette in $palettes) {
    $theme = 'dark'
    if ([Convert]::ToInt32($palette.Page.Substring(1, 2), 16) -gt 128) { $theme = 'light' }
    $xaml = $template
    foreach ($key in $palette.Keys) { $xaml = $xaml.Replace(('@{0}@' -f $key), $palette[$key]) }
    # The window's inside at its normal size, and on 1366x768 at 125 % scaling.
    foreach ($size in @(@{ Name = 'full'; Width = 1164; Height = 781 }, @{ Name = 'small'; Width = 1077; Height = 575 })) {
        Test-Case ('the layout loads and lays out: {0} theme, {1} size' -f $theme, $size.Name) {
            Assert-True ($xaml -notmatch '@\w+@') 'a color token was left in the layout'
            $png = $null
            if ($OutputPath) { $png = Join-Path $OutputPath ('layout-{0}-{1}.png' -f $theme, $size.Name) }
            $report = @(Invoke-InSta -Script $layoutScript -ArgumentList @($xaml, $xamlNames, $styleNames, $size.Width, $size.Height, $png))[0]
            if (@($report.Missing).Count -gt 0) { throw ('FindName misses {0}' -f (@($report.Missing) -join ', ')) }
            if (@($report.NoStyle).Count -gt 0) { throw ('styles missing: {0}' -f (@($report.NoStyle) -join ', ')) }
        }
    }
}

#endregion

#region Status logic

Write-Section 'Status logic'
$now = [DateTime]::UtcNow
# Made-up machine names, kept in variables: PSScriptAnalyzer rejects literal -ComputerName values.
$lab = 'LAB-07'
$ipName = '192.168.222.225'
$fullName = 'lab07.corp.local'
$shortName = 'lab07'

function New-RawSession {
    # A session the way the native wrapper returns it; times are UTC FILETIMEs.
    param([hashtable] $Values)
    $raw = [ordered]@{
        SessionId = 1; WinStationName = ''; State = 0; UserName = ''; DomainName = ''; ProtocolType = 0
        HasInfoEx = $true; Flags = 1; LogonTime = [long] 0; ConnectTime = [long] 0; DisconnectTime = [long] 0
        LastInputTime = [long] 0; CurrentTime = $now.ToFileTimeUtc(); ClientName = ''; ClientAddress = ''
        HorizontalResolution = 0; VerticalResolution = 0; Problems = ''
    }
    foreach ($key in $Values.Keys) { $raw[$key] = $Values[$key] }
    return [pscustomobject] $raw
}

function Get-FileTime {
    param([double] $MinutesAgo)
    return $now.AddMinutes(-$MinutesAgo).ToFileTimeUtc()
}

Test-Case 'made-up sessions convert' {
    # Windows reports a disconnected session with no station name and protocol 0.
    $script:Disconnected = ConvertTo-SessionView -Raw (New-RawSession @{
            SessionId = 3; State = 4; UserName = 'Administrator'; DomainName = 'LAB-07'
            LogonTime = (Get-FileTime 300); DisconnectTime = (Get-FileTime 120)
        })
    $script:ConsoleUser = ConvertTo-SessionView -Raw (New-RawSession @{
            SessionId = 1; WinStationName = 'Console'; State = 0; UserName = 'tester'; DomainName = 'LAB-07'; LogonTime = (Get-FileTime 60)
        })
    $script:IdleUser = ConvertTo-SessionView -IdleMinutes 5 -Raw (New-RawSession @{
            SessionId = 2; WinStationName = 'RDP-Tcp#7'; ProtocolType = 2; State = 0; UserName = 'tester'; DomainName = 'LAB-07'
            LogonTime = (Get-FileTime 90); ConnectTime = (Get-FileTime 60); LastInputTime = (Get-FileTime 20)
            ClientName = 'DESK-12'; ClientAddress = '10.0.0.12'
        })
    $script:LockedUser = ConvertTo-SessionView -Raw (New-RawSession @{
            SessionId = 4; WinStationName = 'RDP-Tcp#8'; ProtocolType = 2; State = 0; Flags = 0; UserName = 'tester'
        })
    $script:BusyUser = ConvertTo-SessionView -BusyNames @('TestExecute') -Raw (New-RawSession @{
            SessionId = 5; WinStationName = 'RDP-Tcp#9'; ProtocolType = 2; State = 0; UserName = 'robot'
            ConnectTime = (Get-FileTime 30); LastInputTime = (Get-FileTime 1)
        })
}

Test-Case 'a disconnected Remote Desktop session is not taken for the console' {
    Assert-Equal 'Disconnected' $script:Disconnected.Status 'status'
    Assert-Equal '' $script:Disconnected.Protocol 'protocol'
    Assert-Equal 'LAB-07\Administrator' $script:Disconnected.User 'user'
    Assert-Equal 120 ([int] [Math]::Round($script:Disconnected.DisconnectedFor.TotalMinutes)) 'minutes disconnected'
}

Test-Case 'the console without an input time counts as in use' {
    Assert-Equal 'Console' $script:ConsoleUser.Protocol 'protocol'
    Assert-Equal 'InUse' $script:ConsoleUser.Status 'status'
    Assert-True ($null -eq $script:ConsoleUser.IdleTime) 'the idle time should be unknown'
}

Test-Case 'no input for 20 minutes is idle' {
    Assert-Equal 'Idle' $script:IdleUser.Status 'status'
    Assert-Equal 'RDP' $script:IdleUser.Protocol 'protocol'
    Assert-Equal 20 ([int] [Math]::Round($script:IdleUser.IdleTime.TotalMinutes)) 'idle minutes'
}

Test-Case 'a locked screen is locked, and automation is busy' {
    Assert-Equal 'Locked' $script:LockedUser.Status 'locked session'
    Assert-Equal 'Busy' $script:BusyUser.Status 'session with TestExecute'
}

Test-Case 'the shared account''s own session decides' {
    $result = Resolve-HostStatus -ComputerName $lab -Sessions @($script:Disconnected, $script:IdleUser) -TargetUser 'Administrator'
    Assert-Equal 'Disconnected' $result.Status 'status'
    Assert-Equal 3 $result.SessionId 'session'
    Assert-Equal 1 @($result.OtherSessions).Count 'other sessions'
}

Test-Case 'no session for the account is free, with a note about the connected one' {
    $result = Resolve-HostStatus -ComputerName $lab -Sessions @($script:IdleUser) -TargetUser 'Administrator'
    Assert-Equal 'Free' $result.Status 'status'
    Assert-True (@(@($result.Notes) -match 'another account is connected').Count -gt 0) 'the note about the connected account is missing'
}

Test-Case 'without an account the busiest session decides' {
    $result = Resolve-HostStatus -ComputerName $lab -Sessions @($script:Disconnected, $script:BusyUser, $script:IdleUser) -TargetUser ''
    Assert-Equal 'Busy' $result.Status 'status'
    $result = Resolve-HostStatus -ComputerName $lab -Sessions @() -TargetUser ''
    Assert-Equal 'Free' $result.Status 'status with nobody signed in'
}

Test-Case 'sessions with nobody in them are explained' {
    Assert-Match 'services' (Get-SystemSessionMeaning -Name 'Services' -State 4) 'session 0'
    Assert-Match 'listener' (Get-SystemSessionMeaning -Name 'RDP-Tcp' -State 6) 'listener'
    Assert-Match 'sign-in screen' (Get-SystemSessionMeaning -Name 'Console' -State 1) 'console'
    Assert-Match 'has not signed in' (Get-SystemSessionMeaning -Name 'RDP-Tcp#3' -State 1) 'someone arriving'
}

Test-Case 'machine names, ports and account names' {
    Assert-Equal 'LAB-07' (Split-HostPort -Address 'LAB-07').Host 'plain name'
    $split = Split-HostPort -Address 'LAB-07:3390'
    Assert-Equal 'LAB-07' $split.Host 'name with port'
    Assert-Equal '3390' $split.Port 'port'
    Assert-Equal 'fe80::1' (Split-HostPort -Address '[fe80::1]:3389').Host 'IPv6 with port'
    Assert-Equal 'tester' (Get-UserLeaf -Name 'LAB-07\tester') 'HOST\user'
    Assert-Equal 'tester' (Get-UserLeaf -Name 'tester@lab.local') 'user@domain'
}

Test-Case 'mstsc gets IPv6 addresses in brackets' {
    Assert-Equal '[fe80::1]' (Format-MstscHost -Address 'fe80::1') 'bare IPv6'
    Assert-Equal '[fe80::1]:3390' (Format-MstscHost -Address '[fe80::1]:3390') 'IPv6 with port'
    Assert-Equal 'LAB-07:3390' (Format-MstscHost -Address 'LAB-07:3390') 'name with port'
    Assert-Equal $ipName (Format-MstscHost -Address $ipName) 'IPv4'
}

Test-Case 'a rejected sign-in is told apart from other failures' {
    foreach ($code in 86, 1326, 1330, 1331, 1909) { Assert-True (Test-SignInRejected -Code $code) ('error {0} should count as a rejected sign-in' -f $code) }
    foreach ($code in 5, 53, 259, 1722, $null) { Assert-True (-not (Test-SignInRejected -Code $code)) ('error [{0}] should not count as a rejected sign-in' -f $code) }
    Assert-Match 'did not accept this sign-in' (Get-FailureHint -Code 1909 -HasCredential $true -Gui $true) 'advice for a locked-out account'
}

Test-Case 'the port test reaches IPv4 and IPv6 addresses' {
    # Windows PowerShell's default TcpClient is IPv4 only; each address needs a
    # socket of its own family.
    foreach ($loopback in [System.Net.IPAddress]::Loopback, [System.Net.IPAddress]::IPv6Loopback) {
        $listener = $null
        try {
            $listener = New-Object System.Net.Sockets.TcpListener -ArgumentList $loopback, 0
            $listener.Start()
        }
        catch {
            Write-Host ('        {0}: cannot listen here, skipped ({1})' -f $loopback, $_.Exception.GetBaseException().Message)
            continue
        }
        $port = $listener.LocalEndpoint.Port
        try { Assert-Equal 'open' (Test-TcpPort -Address $loopback -Port $port) ('a listening port on {0}' -f $loopback) }
        finally { $listener.Stop() }
        Assert-True ((Test-TcpPort -Address $loopback -Port $port) -ne 'open') ('a closed port on {0} should not count as open' -f $loopback)
    }
    Assert-Equal 'no address to try' (Test-TcpPort -Address $null -Port 445) 'no address'
}

Test-Case '"Notify me" stops at once when the machine rejects the password' {
    # Each try with a wrong password counts toward the account's lockout. The
    # engine is dot-sourced into a scope of its own, so that the check can be
    # replaced there.
    $report = & {
        . $enginePath
        $tries = @{ Count = 0 }
        function Wait-OrQuit {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Seconds', Justification = 'Stands in for the real one, which waits.')]
            param([int] $Seconds)
            return $false
        }
        function Get-HostStatus {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Settings', Justification = 'Stands in for the real check.')]
            param($Target, $Settings)
            $tries.Count++
            if ($tries.Count -gt 3) { throw 'it kept trying the rejected password' }
            New-UnknownResult -Target $Target -Reason 'The user name or password is incorrect (error 1326)' -Text 'wrong password' -Code 1326
        }
        $outcome = Wait-UntilFree -Target ([pscustomobject]@{ Name = 'LAB-07'; QueryHost = 'LAB-07'; TargetUser = 'tester' }) -Settings @{ PollSeconds = 5 }
        [pscustomobject]@{ Outcome = $outcome; Tries = $tries.Count }
    } 3>$null 6>$null
    Assert-Equal 'Quit' $report.Outcome 'outcome'
    Assert-Equal 1 $report.Tries 'tries with the rejected password'
}

Test-Case 'a bare account name means a local account on the target' {
    $secure = New-Object System.Security.SecureString
    $secure.AppendChar('x')
    $credential = New-Object System.Management.Automation.PSCredential -ArgumentList 'Administrator', $secure
    Assert-Equal '192.168.222.225\Administrator' (ConvertTo-TargetCredential -Credential $credential -ComputerName $ipName).UserName 'IP address'
    Assert-Equal 'lab07\Administrator' (ConvertTo-TargetCredential -Credential $credential -ComputerName $fullName).UserName 'full name'
    $credential = New-Object System.Management.Automation.PSCredential -ArgumentList 'CORP\tester', $secure
    Assert-Equal 'CORP\tester' (ConvertTo-TargetCredential -Credential $credential -ComputerName $shortName).UserName 'domain account'
}

Test-Case 'durations' {
    Assert-Equal '40 s' (Format-Duration -Span ([TimeSpan]::FromSeconds(40))) '40 seconds'
    Assert-Equal '23 min' (Format-Duration -Span ([TimeSpan]::FromMinutes(23))) '23 minutes'
    Assert-Equal '6 h 29 min' (Format-Duration -Span ([TimeSpan]::FromMinutes(389))) '389 minutes'
    Assert-Equal '3 d 2 h' (Format-Duration -Span ([TimeSpan]::FromHours(74))) '74 hours'
}

Test-Case 'advice in the dashboard never names command-line switches' {
    foreach ($code in 5, 259, 1326, 1265, 1722, 53, 1219, 2) {
        foreach ($hasCredential in $true, $false) {
            foreach ($operation in 'Query', 'Ask') {
                $hint = Get-FailureHint -Code $code -Operation $operation -HasCredential $hasCredential -CheckingAs 'LAB-07\tester' -Gui $true
                if ($hint -match '-Credential|-SkipPortCheck|-Verbose|-LogPath') { throw ('error {0} ({1}): {2}' -f $code, $operation, $hint) }
            }
        }
    }
    Assert-Match '-Credential' (Get-FailureHint -Code 259 -HasCredential $false -CheckingAs 'PC\me') 'command-line advice for error 259'
}

Test-Case 'an unreachable machine gives advice that fits each window' {
    $target = [pscustomobject]@{ Name = '192.0.2.1'; QueryHost = '192.0.2.1'; RdpFile = ''; OverrideHost = $true; TargetUser = ''; Gateway = '' }
    $settings = @{ Credential = [System.Management.Automation.PSCredential]::Empty; IdleMinutes = 5; BusyProcess = @(); SkipPortCheck = $false; CheckingAs = 'test'; Gui = $true }
    $inDashboard = Get-HostStatus -Target $target -Settings $settings
    Assert-Equal 'Unknown' $inDashboard.Status 'status'
    Assert-True ($inDashboard.Error -notmatch 'SkipPortCheck') ('the dashboard text names -SkipPortCheck: {0}' -f $inDashboard.Error)
    $settings.Gui = $false
    Assert-Match 'SkipPortCheck' (Get-HostStatus -Target $target -Settings $settings).Error 'command-line text'
}

#endregion

#region Dashboard wording

Write-Section 'Dashboard wording'
# These dashboard functions only format text, so they can run without the window.
$wording = @('Format-Span', 'Format-When', 'ConvertTo-Sentence', 'Get-FriendlyText', 'Get-ClientText', 'Get-StateDetail', 'Get-StatusWord', 'New-Fact', 'Get-FactList')
foreach ($definition in (Find-Ast -Ast $dashboard.Ast -Type ([System.Management.Automation.Language.FunctionDefinitionAst]))) {
    if ($wording -contains $definition.Name) { . ([scriptblock]::Create($definition.Extent.Text)) }
}
$script:StatusWord = @(Get-AssignedExpression -Name '$script:StatusWord')[0].SafeGetValue()
$request = [pscustomobject]@{ Host = 'LAB-07'; Account = 'Administrator' }

Test-Case 'disconnected: nobody is watching' {
    $result = Resolve-HostStatus -ComputerName $lab -Sessions @($script:Disconnected) -TargetUser 'Administrator'
    $copy = Get-FriendlyText -Result $result -Request $request
    Assert-Equal "Nobody is watching Administrator's session." $copy.Headline 'headline'
    Assert-Match 'disconnected 2 h 0 min ago' $copy.Advice 'advice'
}

Test-Case 'free while others are signed in: the account has no session' {
    $result = Resolve-HostStatus -ComputerName $lab -Sessions @($script:IdleUser) -TargetUser 'Administrator'
    Assert-Equal 'Administrator has no session on LAB-07.' (Get-FriendlyText -Result $result -Request $request).Headline 'headline'
}

Test-Case 'the console without input times: signed in, not claimed to be working' {
    $result = Resolve-HostStatus -ComputerName $lab -Sessions @($script:ConsoleUser) -TargetUser 'tester'
    $copy = Get-FriendlyText -Result $result -Request ([pscustomobject]@{ Host = 'LAB-07'; Account = 'tester' })
    Assert-Equal 'tester is signed in directly at LAB-07.' $copy.Headline 'headline'
    Assert-Match 'own screen' $copy.Advice 'advice'
    Assert-Equal 'no input time for the console' (Get-StateDetail -Session $script:ConsoleUser) 'state in the table'
}

Test-Case 'unknown: says why' {
    $result = New-UnknownResult -Target ([pscustomobject]@{ Name = 'LAB-07'; TargetUser = 'Administrator' }) -Reason 'no sessions visible to this account (error 259)' -Text 'details'
    $copy = Get-FriendlyText -Result $result -Request $request
    Assert-Equal 'Could not check LAB-07.' $copy.Headline 'headline'
    Assert-Match 'error 259' $copy.Advice 'advice'
}

Test-Case 'where from: the console, a client, and a disconnected session' {
    Assert-Equal 'Its own screen' (Get-ClientText -Session $script:ConsoleUser -Lookup $null).Main 'console'
    $client = Get-ClientText -Session $script:IdleUser -Lookup $null
    Assert-Equal 'DESK-12' $client.Main 'client name'
    Assert-Equal '10.0.0.12' $client.Sub 'client address'
    Assert-Equal 'Not kept' (Get-ClientText -Session $script:Disconnected -Lookup $null).Main 'disconnected, no lookup'
}

Test-Case 'where from: the event log fills in a disconnected session' {
    $entries = New-Object System.Collections.Generic.List[object]
    $entries.Add([pscustomobject]@{ SessionId = 3; Time = (Get-Date).AddMinutes(-121); EventId = 24; User = 'LAB-07\Administrator'; Address = '10.0.0.5' })
    $text = Get-ClientText -Session $script:Disconnected -Lookup @{ Map = @{ 3 = $entries }; Error = '' }
    Assert-Equal '10.0.0.5' $text.Main 'address'
    Assert-Match '^disconnected .+, per the event log$' $text.Sub 'when'
}

Test-Case 'facts: someone else at the machine''s own screen is not "Not in use"' {
    $result = Resolve-HostStatus -ComputerName $lab -Sessions @($script:ConsoleUser) -TargetUser 'Administrator'
    $facts = @(Get-FactList -Result $result -Lookup $null)
    Assert-Equal 4 $facts.Count 'facts'
    Assert-Equal 'Its own screen' $facts[1].Label 'label'
    Assert-Equal 'In use' $facts[1].Value 'value'
    Assert-Equal 'tester, session 1' $facts[1].Sub 'who'
    $result.SystemSessions = @([pscustomobject]@{ SessionId = 1; Name = 'Console'; State = 'Connected'; Meaning = '' })
    $result.Sessions = @()
    Assert-Equal 'Sign-in screen' @(Get-FactList -Result $result -Lookup $null)[1].Value 'nobody at the console'
}

Test-Case 'facts: a session''s state, sign-in, client and protocol' {
    $result = Resolve-HostStatus -ComputerName $lab -Sessions @($script:IdleUser) -TargetUser 'tester'
    $facts = @(Get-FactList -Result $result -Lookup $null)
    Assert-Equal 'No input for' $facts[0].Label 'first label'
    Assert-Equal '20 min' $facts[0].Value 'idle time'
    Assert-Equal 'DESK-12' $facts[2].Value 'client'
    Assert-Equal 'Remote Desktop' $facts[3].Sub 'protocol'
}

#endregion

#region Background check of this computer

Write-Section 'Background check of this computer'
Test-Case 'a check through a runspace pool, the way the dashboard runs it' {
    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($function in $exported.Values) {
        $sessionState.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $function.Name, $function.Definition))
    }
    $pool = [runspacefactory]::CreateRunspacePool(1, 2, $sessionState, $Host)
    $pool.Open()
    $ps = [powershell]::Create()
    try {
        $ps.RunspacePool = $pool
        $null = $ps.AddScript([string] @(Get-AssignedExpression -Name '$script:CheckJobScript')[0].Value)
        $target = [pscustomobject]@{ Name = $env:COMPUTERNAME; QueryHost = $env:COMPUTERNAME; RdpFile = ''; OverrideHost = $true; TargetUser = ''; Gateway = '' }
        $settings = @{
            Credential = [System.Management.Automation.PSCredential]::Empty; IdleMinutes = 5; RecentDisconnectMinutes = 15
            BusyProcess = @(); AskTimeoutSeconds = 60; PollSeconds = 30; NoConsentPrompt = $false; MstscArgument = @()
            SkipPortCheck = $false; CheckingAs = 'test'; Gui = $true
        }
        $null = $ps.AddParameter('JobTarget', $target).AddParameter('JobSettings', $settings)
        $output = @($ps.Invoke())
        Assert-Equal 1 $output.Count 'objects returned'
        if (-not $output[0].Ok) { throw ('the job failed: {0}' -f $output[0].Error) }
        $status = $output[0].Value
        Write-Host ('        {0}: {1}, {2}; {3} signed in, {4} system sessions, {5} log lines' -f $env:COMPUTERNAME, $status.Status, $status.Detail, @($status.Sessions).Count, @($status.SystemSessions).Count, $ps.Streams.Verbose.Count)
        if ($status.Status -eq 'Unknown') { throw $status.Error }
        Assert-True (@($status.SystemSessions | Where-Object { $_.Name -eq 'Services' }).Count -eq 1) 'session 0 (Services) is missing'
    }
    finally {
        $ps.Dispose()
        $pool.Close()
    }
}

Test-Case 'the session event log of this computer can be read' {
    $map = Get-LastClientMap -ComputerName $env:COMPUTERNAME
    Assert-True ($map -is [hashtable]) 'expected a hashtable'
    Write-Host ('        sessions with a client address in the log: {0}' -f ((@($map.Keys) | Sort-Object) -join ', '))
}

#endregion

Write-Host ''
if ($script:Failures.Count -gt 0) {
    Write-Host ('{0} passed, {1} failed:' -f $script:Passed, $script:Failures.Count) -ForegroundColor Red
    foreach ($failure in $script:Failures) { Write-Host ('  {0}' -f $failure) -ForegroundColor Red }
    exit 1
}
Write-Host ('All {0} checks passed.' -f $script:Passed) -ForegroundColor Green
