#Requires -Version 5.1
<#
.SYNOPSIS
    Runs Connect-SharedRdp.ps1 -StatusOnly against this computer.

.DESCRIPTION
    Checks this computer the local way (by its own name), then over the network
    through one of its IP addresses, which is how a check of another machine
    works. Only session lists are read.

    -CiSetup is for throw-away CI machines and needs administrator rights. It
    prepares this computer like a shared machine (AllowRemoteRPC=1), creates a
    temporary member of Remote Desktop Users and checks over the network with
    -Credential as that account, once as HOST\name and once as the bare name,
    then removes the account. It also sends a takeover request to this
    computer's session that times out after a few seconds.

    A wrong password cannot be tried here: on a connection to itself, Windows
    signs in with the caller's own account (as runas /netonly does), so this
    computer accepts any password. Test-Scripts.ps1 checks which errors count
    as a rejected sign-in, and that "Notify me" stops at one.

    The local check must work. Network checks that fail are reported as
    warnings, because they depend on how the machine is set up.

    powershell.exe -ExecutionPolicy Bypass -File .\tests\Test-CommandLine.ps1
#>
[CmdletBinding()]
param(
    [switch] $CiSetup,
    [string] $OutputPath
)

$global:ErrorActionPreference = 'Continue'
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$enginePath = Join-Path $root 'Connect-SharedRdp.ps1'
$script:Failed = $false
$script:Transcript = New-Object System.Collections.Generic.List[string]

function Write-Line {
    param([string] $Text = '', [string] $Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    $script:Transcript.Add($Text)
}

function Write-Problem {
    # A must-pass check that fails is an error; one that depends on the setup, a warning.
    param([string] $Title, [string] $Message, [switch] $Warning)
    $kind = 'error'
    $color = 'Red'
    if ($Warning) {
        $kind = 'warning'
        $color = 'Yellow'
    }
    else {
        $script:Failed = $true
    }
    Write-Line ('{0}: {1}: {2}' -f $kind.ToUpper(), $Title, $Message) $color
    if ($env:GITHUB_ACTIONS) {
        $clean = { param($Text) $Text.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A') }
        Write-Host ('::{0} title={1}::{2}' -f $kind, (& $clean $Title).Replace(':', '%3A').Replace(',', '%2C'), (& $clean $Message))
    }
}

function Invoke-StatusCheck {
    # Runs the command line with -StatusOnly -Verbose, shows its log and returns its results.
    param([string] $Title, [hashtable] $Arguments)
    $ErrorActionPreference = 'Continue'
    Write-Line
    Write-Line $Title 'Cyan'
    $records = @(& $enginePath @Arguments -StatusOnly -Verbose 4>&1 3>&1)
    $results = @()
    foreach ($record in $records) {
        if ($record -is [System.Management.Automation.VerboseRecord]) { Write-Line ('  {0}' -f $record.Message) 'DarkGray' }
        elseif ($record -is [System.Management.Automation.WarningRecord]) { Write-Line ('  WARNING: {0}' -f $record.Message) 'Yellow' }
        else { $results += $record }
    }
    foreach ($result in $results) {
        Write-Line ('  Result: {0}, {1}. {2}' -f $result.Status, $result.Detail, $result.Who) 'White'
        foreach ($session in @($result.Sessions)) {
            Write-Line ('    session {0}, {1}: {2} ({3}); client "{4}" {5}' -f $session.SessionId, $session.User, $session.Status, $session.Detail, $session.Client, $session.ClientAddress) 'White'
        }
        foreach ($system in @($result.SystemSessions)) {
            Write-Line ('    session {0} "{1}" {2}: {3}' -f $system.SessionId, $system.Name, $system.State, $system.Meaning) 'White'
        }
    }
    return $results
}

function Invoke-WithCiAccount {
    # Own only the account created here: never remove an existing account when
    # creation fails, or a replacement account that later reuses the same name.
    param(
        [Parameter(Mandatory = $true)] [System.Security.SecureString] $Password,
        [Parameter(Mandatory = $true)] [scriptblock] $Action
    )
    $account = $null
    try {
        # Local account names are limited to 20 characters. A fresh name also
        # lets independent checks run without sharing an account.
        $name = 'srdp-' + [Guid]::NewGuid().ToString('N').Substring(0, 14)
        $account = New-LocalUser -Name $name -Password $Password -AccountNeverExpires -PasswordNeverExpires -Description 'Temporary account for the SharedRDP checks' -ErrorAction Stop
        & $Action $account
    }
    finally {
        if ($null -ne $account) { Remove-LocalUser -SID $account.SID -ErrorAction SilentlyContinue }
    }
}

Write-Line ('PowerShell {0} ({1}), {2}, running as {3}' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, [Environment]::OSVersion.VersionString, [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)

# The engine's functions, for the checks below that call them directly.
$module = New-Module -Name SharedRdpEngine -ArgumentList $enginePath -ScriptBlock {
    param($Path)
    . $Path
    Export-ModuleMember -Function *
}
$null = $module | Import-Module -DisableNameChecking -Force -PassThru
Initialize-Native

# 1. This computer by name: no network involved. This one must work.
$local = @(Invoke-StatusCheck -Title ('This computer by name ({0})' -f $env:COMPUTERNAME) -Arguments @{ ComputerName = $env:COMPUTERNAME })
if ($local.Count -ne 1) {
    Write-Problem -Title 'local check' -Message ('expected one result, got {0}' -f $local.Count)
}
elseif ($local[0].Status -eq 'Unknown') {
    Write-Problem -Title 'local check' -Message $local[0].Error
}
elseif (@($local[0].SystemSessions | Where-Object { $_.Name -eq 'Services' }).Count -ne 1) {
    Write-Problem -Title 'local check' -Message 'session 0 (Services) is missing'
}

if ($CiSetup) {
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name AllowRemoteRPC -Value 1 -Type DWord
    Write-Line
    Write-Line 'Set AllowRemoteRPC=1 here, as on a shared machine.' 'Cyan'
}

# 2. Over the network as the current account, like checking another machine.
$address = @([System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME) |
        Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
        ForEach-Object { $_.IPAddressToString } |
        Where-Object { $_ -notlike '127.*' -and $_ -notlike '169.254.*' }) | Select-Object -First 1
if (-not $address) {
    Write-Problem -Warning -Title 'network check' -Message 'this computer has no IPv4 address to check through'
}
else {
    $remote = @(Invoke-StatusCheck -Title ('This computer over the network ({0})' -f $address) -Arguments @{ ComputerName = $address })
    if ($remote.Count -eq 1 -and $remote[0].Status -eq 'Unknown') {
        Write-Problem -Warning -Title 'network check as the current account' -Message $remote[0].Error
    }
}

# 3. Over the network with -Credential, as a temporary member of Remote Desktop Users.
if ($CiSetup -and $address) {
    $bytes = New-Object byte[] 18
    $random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $random.GetBytes($bytes)
    $random.Dispose()
    $secure = New-Object System.Security.SecureString
    foreach ($character in ('Aa1!' + [Convert]::ToBase64String($bytes)).ToCharArray()) { $secure.AppendChar($character) }
    try {
        Invoke-WithCiAccount -Password $secure -Action {
            param($Account)
            Add-LocalGroupMember -SID 'S-1-5-32-555' -Member $Account
            foreach ($userName in @(('{0}\{1}' -f $env:COMPUTERNAME, $Account.Name), $Account.Name)) {
                $credential = New-Object System.Management.Automation.PSCredential -ArgumentList $userName, $secure
                $checked = @(Invoke-StatusCheck -Title ('This computer over the network as {0}, a member of Remote Desktop Users' -f $userName) -Arguments @{ ComputerName = $address; Credential = $credential })
                if ($checked.Count -eq 1 -and $checked[0].Status -eq 'Unknown') {
                    Write-Problem -Warning -Title ('network check as {0}' -f $userName) -Message $checked[0].Error
                }
            }
        }
    }
    catch {
        Write-Problem -Warning -Title 'temporary account' -Message $_.Exception.Message
    }
    finally {
        $secure.Dispose()
    }
}

# 4. A takeover request to this computer's own session, which nobody answers.
if ($CiSetup -and $local.Count -eq 1 -and $null -ne $local[0].Session) {
    $sessionId = [int] $local[0].Session.SessionId
    Write-Line
    Write-Line ('Asking session {0} to let someone take over, with a 3-second timeout' -f $sessionId) 'Cyan'
    try {
        $ask = Get-AskMessage -TimeoutSeconds 3
        $answer = Send-AskMessage -ComputerName $env:COMPUTERNAME -SessionId $sessionId -Title $ask.Title -Message $ask.Message -TimeoutSeconds 3 -Credential ([System.Management.Automation.PSCredential]::Empty)
        Write-Line ('  Answer code {0}; 32000 means nobody answered in time, as expected here.' -f $answer) 'White'
        if ([int] $answer -ne 32000) { Write-Problem -Warning -Title 'takeover request' -Message ('expected 32000 (timed out), got {0}' -f $answer) }
    }
    catch {
        Write-Problem -Warning -Title 'takeover request' -Message $_.Exception.Message
    }
}

if ($OutputPath) {
    $OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $null = New-Item -ItemType Directory -Path $OutputPath -Force
    Set-Content -LiteralPath (Join-Path $OutputPath 'command-line.txt') -Value $script:Transcript -Encoding UTF8
}
if ($script:Failed) { exit 1 }
Write-Line
Write-Line 'The command line checks passed.' 'Green'
