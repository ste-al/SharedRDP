#Requires -Version 5.1
<#
.SYNOPSIS
    Checks session identity failures and account selection without querying a
    machine, opening Remote Desktop, or touching a session.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Mocks Start-Process only inside this isolated regression process so no Remote Desktop client is launched.')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'Connect-SharedRdp.ps1')
Initialize-Native

function Assert-EngineEqual {
    param($Expected, $Actual, [string] $Message)
    if ($Expected -ne $Actual) { throw ('{0}: expected "{1}", got "{2}"' -f $Message, $Expected, $Actual) }
}

function New-EngineRaw {
    param([int] $SessionId = 1, [int] $State = 0, [string] $Account = '', [string] $Domain = '', [int] $IdentityError = 0)
    $raw = New-Object SharedRdpV3.SessionRecord
    $raw.SessionId = $SessionId
    $raw.State = $State
    $raw.UserName = $Account
    $raw.DomainName = $Domain
    $raw.IdentityError = $IdentityError
    $raw.CurrentTime = [DateTime]::UtcNow.ToFileTimeUtc()
    return $raw
}

$lab = 'LAB-07'
$ipTarget = '192.0.2.1'
$target = [pscustomobject]@{ Name = 'LAB-07'; QueryHost = 'LAB-07'; TargetUser = 'tester' }
$settings = @{ SkipPortCheck = $true; CheckingAs = 'test'; IdleMinutes = 5; BusyProcess = @() }
$originalSessions = (Get-Item Function:Get-RawSessions).ScriptBlock
try {
    function Get-RawSessions {
        param([string] $ComputerName, [System.Management.Automation.PSCredential] $Credential)
        # Keep the production signature, but return only synthetic records.
        $null = $ComputerName, $Credential
        return $script:EngineMockRaw
    }

    foreach ($state in 0, 1, 2, 3, 4) {
        $script:EngineMockRaw = @(New-EngineRaw -State $state -IdentityError 5)
        $result = Get-HostStatus -Target $target -Settings $settings
        Assert-EngineEqual 'Unknown' $result.Status ('unreadable identity in state {0}' -f $state)
        Assert-EngineEqual 5 $result.ErrorCode 'identity error is preserved'
        Assert-EngineEqual $null $result.SessionId 'unknown identity has no actionable session'
        Assert-EngineEqual 0 @($result.SystemSessions).Count 'an unreadable identity is not labelled as nobody signed in'
        Assert-EngineEqual $false ((Get-AutoAction -Result $result -RecentDisconnectMinutes 15) -eq 'Connect') 'identity failures never connect automatically'
    }

    $script:EngineMockRaw = @(
        (New-EngineRaw -SessionId 0 -State 4 -IdentityError 5),
        (New-EngineRaw -SessionId 65536 -State 6 -IdentityError 5)
    )
    $result = Get-HostStatus -Target $target -Settings $settings
    Assert-EngineEqual 'Free' $result.Status 'services and listener are not human sessions'

    $script:EngineMockRaw = @(New-EngineRaw -State 0)
    $result = Get-HostStatus -Target $target -Settings $settings
    Assert-EngineEqual 'Free' $result.Status 'a successfully read empty user name is free'

    $script:EngineMockRaw = @(New-EngineRaw -Account 'tester' -IdentityError 5)
    $qualifiedTarget = [pscustomobject]@{ Name = 'LAB-07'; QueryHost = 'LAB-07'; TargetUser = 'CORP\tester' }
    $result = Get-HostStatus -Target $qualifiedTarget -Settings $settings
    Assert-EngineEqual 'Unknown' $result.Status 'an unreadable domain cannot make a qualified account look free'
    Assert-EngineEqual $null $result.SessionId 'an unreadable domain has no actionable session'

    $script:EngineMockRaw = @(
        (New-EngineRaw -SessionId 1 -State 0 -Account 'tester' -Domain 'LAB-07'),
        (New-EngineRaw -SessionId 2 -State 4 -IdentityError 1326)
    )
    $result = Get-HostStatus -Target $target -Settings $settings
    Assert-EngineEqual 'Unknown' $result.Status 'another unreadable session keeps the result uncertain'
    Assert-EngineEqual $true (Test-SignInRejected -Code $result.ErrorCode) 'identity sign-in errors can stop polling'

    $script:EngineMockRaw = @(
        (New-EngineRaw -SessionId 1 -State 0 -IdentityError 5),
        (New-EngineRaw -SessionId 2 -State 4 -IdentityError 1326)
    )
    $result = Get-HostStatus -Target $target -Settings $settings
    Assert-EngineEqual 1326 $result.ErrorCode 'a preceding permission error cannot hide a rejected sign-in'
    Assert-EngineEqual $true ($result.Error -match 'session 2 \(error 1326\)') 'the message identifies the session whose sign-in was rejected'
}
finally {
    Set-Item Function:Get-RawSessions -Value $originalSessions
    Remove-Variable EngineMockRaw -Scope Script -ErrorAction SilentlyContinue
}

$local = ConvertTo-SessionView -Raw (New-EngineRaw -SessionId 1 -Account 'tester' -Domain 'LAB-07')
$domain = ConvertTo-SessionView -Raw (New-EngineRaw -SessionId 2 -State 4 -Account 'tester' -Domain 'CORP')
$sessions = @($local, $domain)
foreach ($account in 'LAB-07\tester', '.\tester', 'LAB-07.example.com\tester') {
    $machine = 'LAB-07'
    if ($account -like 'LAB-07.example.com*') { $machine = 'LAB-07.example.com:3390' }
    $result = Resolve-HostStatus -ComputerName $machine -Sessions $sessions -TargetUser $account
    Assert-EngineEqual 1 $result.SessionId ('local qualified account {0}' -f $account)
    Assert-EngineEqual 1 @($result.OtherSessions).Count 'same-name account stays in the other sessions'
}
$result = Resolve-HostStatus -ComputerName $lab -Sessions $sessions -TargetUser 'corp\tester'
Assert-EngineEqual 2 $result.SessionId 'the named domain decides which session to ask or watch'
$result = Resolve-HostStatus -ComputerName $lab -Sessions $sessions -TargetUser 'OTHER\tester'
Assert-EngineEqual 'Free' $result.Status 'a different explicitly named account has no session'
foreach ($account in 'tester', 'tester@corp.example') {
    $result = Resolve-HostStatus -ComputerName $lab -Sessions $sessions -TargetUser $account
    Assert-EngineEqual 'Unknown' $result.Status ('ambiguous account {0}' -f $account)
    Assert-EngineEqual $null $result.SessionId 'an ambiguous account has no actionable session'
}
$result = Resolve-HostStatus -ComputerName $ipTarget -Sessions @($local) -TargetUser '192.0.2.1\tester'
Assert-EngineEqual 1 $result.SessionId 'an unambiguous IP local-account alias still works'
$result = Resolve-HostStatus -ComputerName $lab -Sessions @($domain) -TargetUser 'tester@corp.example'
Assert-EngineEqual 2 $result.SessionId 'an unambiguous UPN still works'
$result = Resolve-HostStatus -ComputerName $lab -Sessions @($local, $local) -TargetUser 'tester'
Assert-EngineEqual 'InUse' $result.Status 'several sessions for one identity are not ambiguous'

foreach ($machine in '.', 'localhost', '127.0.0.1', '::1') {
    $localActual = ConvertTo-SessionView -Raw (New-EngineRaw -Account 'tester' -Domain ([Environment]::MachineName))
    $result = Resolve-HostStatus -ComputerName $machine -Sessions @($localActual) -TargetUser '.\tester'
    Assert-EngineEqual 'InUse' $result.Status ('the local alias {0} resolves to the real machine identity' -f $machine)
}
$result = Resolve-HostStatus -ComputerName $lab -Sessions @($local) -TargetUser 'unrelated.corp\tester'
Assert-EngineEqual 'Unknown' $result.Status 'an unrelated DNS qualifier never selects a same-name account'
Assert-EngineEqual $null $result.SessionId 'an unresolved DNS qualifier has no actionable session'

$originalSessions = (Get-Item Function:Get-RawSessions).ScriptBlock
$originalProcesses = (Get-Item Function:Get-RawProcesses).ScriptBlock
try {
    function Get-RawSessions {
        param([string] $ComputerName, [System.Management.Automation.PSCredential] $Credential)
        $null = $ComputerName, $Credential
        return $script:EngineBusyRaw
    }
    function Get-RawProcesses {
        param([string] $ComputerName, [System.Management.Automation.PSCredential] $Credential)
        $null = $ComputerName, $Credential
        throw (New-Object System.ComponentModel.Win32Exception -ArgumentList $script:EngineProcessError)
    }
    $busySettings = @{ SkipPortCheck = $true; CheckingAs = 'test'; IdleMinutes = 5; BusyProcess = @('automation') }
    $script:EngineBusyRaw = @(New-EngineRaw -Account 'tester' -Domain 'LAB-07' -State 4)
    foreach ($code in 5, 1326) {
        $script:EngineProcessError = $code
        $result = Get-HostStatus -Target $target -Settings $busySettings -WarningAction SilentlyContinue
        Assert-EngineEqual 'Unknown' $result.Status 'a failed requested busy check is uncertain'
        Assert-EngineEqual $code $result.ErrorCode 'busy check keeps the native error for polling'
        Assert-EngineEqual $null $result.SessionId 'an unevaluated busy safeguard has no actionable session'
        Assert-EngineEqual $false ((Get-AutoAction -Result $result -RecentDisconnectMinutes 0) -eq 'Connect') 'busy check failures never connect automatically'
    }
    $script:EngineBusyRaw = @(
        (New-EngineRaw -SessionId 1 -State 0 -IdentityError 5),
        (New-EngineRaw -SessionId 2 -State 4 -IdentityError 1326)
    )
    $script:EngineProcessError = 5
    $result = Get-HostStatus -Target $target -Settings $busySettings -WarningAction SilentlyContinue
    Assert-EngineEqual 1326 $result.ErrorCode 'a busy-check permission error cannot hide an identity sign-in rejection'
    Assert-EngineEqual $true ($result.Error -match 'session 2 \(error 1326\)') 'the rejected identity determines the message as well as the code'
    $script:EngineBusyRaw = @(New-EngineRaw -IdentityError 5)
    $script:EngineProcessError = 1326
    $result = Get-HostStatus -Target $target -Settings $busySettings -WarningAction SilentlyContinue
    Assert-EngineEqual 1326 $result.ErrorCode 'an identity permission error cannot hide a busy-check sign-in rejection'
    Assert-EngineEqual 'the requested busy-process check failed' $result.Detail 'the rejected busy check determines the message'
}
finally {
    Set-Item Function:Get-RawSessions -Value $originalSessions
    Set-Item Function:Get-RawProcesses -Value $originalProcesses
    Remove-Variable EngineProcessError -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable EngineBusyRaw -Scope Script -ErrorAction SilentlyContinue
}

$originalStartProcess = Get-Item Function:Start-Process -ErrorAction SilentlyContinue
$testFolder = Join-Path ([System.IO.Path]::GetTempPath()) ('SharedRdp-test-{0}' -f [guid]::NewGuid().ToString('N'))
$createdFiles = New-Object System.Collections.Generic.List[string]
$null = New-Item -ItemType Directory -Path $testFolder -ErrorAction Stop
try {
    function Start-Process {
        param([string] $FilePath, [string] $ArgumentList)
        Assert-EngineEqual 'mstsc.exe' $FilePath 'the launcher executable'
        $script:EngineLaunchArguments = $ArgumentList
    }
    $template = Join-Path $testFolder 'template.rdp'
    $createdFiles.Add($template)
    Set-Content -LiteralPath $template -Encoding Unicode -Value @(
        'full address:s:OLD-HOST', 'username:s:old-user', 'domain:s:OLD-DOMAIN',
        'password 51:b:old-secret', 'screen mode id:i:2', 'redirectclipboard:i:0'
    )
    $launch = [pscustomobject]@{ Name = 'LAB-07:3390'; QueryHost = 'LAB-07'; TargetUser = 'CORP\tester'; RdpFile = $template; OverrideHost = $true }
    Start-Rdp -Target $launch -ExtraArgument @('/multimon')
    if ($script:EngineLaunchArguments -notmatch '^"(?<path>[^"]+\.rdp)" /v:LAB-07:3390 /multimon$') { throw 'the generated RDP file and arguments were not passed together' }
    $first = $Matches['path']
    $createdFiles.Add($first)
    $lines = @(Get-Content -LiteralPath $first)
    Assert-EngineEqual $true ($lines -contains 'username:s:CORP\tester') 'the checked account reaches mstsc'
    Assert-EngineEqual $true ($lines -contains 'full address:s:LAB-07:3390') 'the checked host reaches mstsc'
    Assert-EngineEqual $true ($lines -contains 'screen mode id:i:2') 'display preferences are preserved'
    Assert-EngineEqual $true ($lines -contains 'redirectclipboard:i:0') 'device preferences are preserved'
    Assert-EngineEqual 0 @($lines | Where-Object { $_ -match '^(domain|password(?: 51)?):' }).Count 'old domain and saved password are removed'
    Start-Rdp -Target $launch
    if ($script:EngineLaunchArguments -notmatch '^"(?<path>[^"]+\.rdp)"') { throw 'a second launch did not receive an RDP file' }
    $second = $Matches['path']
    $createdFiles.Add($second)
    Assert-EngineEqual $false ($first -eq $second) 'concurrent launches have distinct settings files'

    $matching = Join-Path $testFolder 'matching.rdp'
    $createdFiles.Add($matching)
    Set-Content -LiteralPath $matching -Encoding Unicode -Value @('full address:s:LAB-07', 'domain:s:CORP', 'username:s:tester', 'redirectclipboard:i:0')
    $parsed = Read-RdpFile -Path $matching
    Assert-EngineEqual 'CORP\tester' $parsed.UserName 'separate domain and username name the checked account'
    $resolved = @(Resolve-Targets -RdpFile $matching)
    Assert-EngineEqual 'CORP\tester' $resolved[0].TargetUser 'the RDP domain affects session checking'
    Start-Rdp -Target $resolved[0]
    Assert-EngineEqual ('"{0}"' -f $matching) $script:EngineLaunchArguments 'an already matching explicit template is left intact'

    $launch.RdpFile = ''
    $launch.TargetUser = 'tester'
    Start-Rdp -Target $launch
    if ($script:EngineLaunchArguments -notmatch '^"(?<path>[^"]+\.rdp)"') { throw 'a launch with an account but no template did not receive an RDP file' }
    $third = $Matches['path']
    $createdFiles.Add($third)
    Assert-EngineEqual $true (@(Get-Content -LiteralPath $third) -contains 'username:s:LAB-07\tester') 'a bare account is explicitly local to the target'
    $launch.TargetUser = ''
    Start-Rdp -Target $launch
    Assert-EngineEqual '/v:LAB-07:3390' $script:EngineLaunchArguments 'a launch without an account or template keeps its defaults'
}
finally {
    if ($null -ne $originalStartProcess) { Set-Item Function:Start-Process -Value $originalStartProcess.ScriptBlock }
    else { Remove-Item Function:Start-Process }
    Remove-Variable EngineLaunchArguments -Scope Script -ErrorAction SilentlyContinue
    foreach ($file in $createdFiles) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $testFolder -Force -ErrorAction SilentlyContinue
}

Write-Host 'Engine identity and account-selection regression checks passed.'
