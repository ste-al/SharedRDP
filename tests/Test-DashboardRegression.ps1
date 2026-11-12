#Requires -Version 5.1
<#
.SYNOPSIS
    Exercises dashboard scheduling and RDP file generation without UI, network,
    credentials on the machine, or starting Remote Desktop.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Test doubles accept the real functions parameters at UI and dispatch boundaries.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'The two scoped Start-Process test doubles prevent real Remote Desktop windows from opening.')]
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$passed = 0

function Import-SelectedFunction {
    param([string] $Path, [string[]] $Names)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $tokens, [ref] $errors)
    if ($errors.Count) { throw ($errors.Message -join '; ') }
    $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))
    foreach ($name in $Names) {
        $definition = @($functions | Where-Object { $_.Name -eq $name })
        if ($definition.Count -ne 1) { throw ('Expected one definition of {0}.' -f $name) }
        Set-Item -Path ('Function:script:{0}' -f $name) -Value ([scriptblock]::Create($definition[0].Body.Extent.Text.TrimStart('{').TrimEnd('}')))
    }
}

Import-SelectedFunction -Path (Join-Path $root 'SharedRdp-Dashboard.ps1') -Names @(
    'Get-FormKey', 'Get-FormRequest', 'Test-SameRequestCredential', 'Start-Check',
    'Complete-Check', 'Remove-RejectedSecret', 'Start-Watch', 'Start-RdpSession', 'Remove-CompletedRdpFiles'
)
Import-SelectedFunction -Path (Join-Path $root 'Connect-SharedRdp.ps1') -Names @('Format-MstscHost', 'Test-SignInRejected', 'Get-RdpConnectionLines')

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}
function Test-Case {
    param([string] $Name, [scriptblock] $Body)
    & $Body
    $script:passed++
    Write-Host ('  ok    {0}' -f $Name)
}
function New-Request {
    param([int] $Revision, [string] $Machine = 'LAB-07')
    $secret = New-Object System.Security.SecureString
    $secret.AppendChar('x')
    $secret.MakeReadOnly()
    $credential = New-Object System.Management.Automation.PSCredential -ArgumentList 'tester', $secret
    return [pscustomobject]@{
        Key = ('{0}|tester' -f $Machine).ToLowerInvariant(); Host = $Machine; QueryHost = $Machine; Account = 'tester'
        Credential = $credential; Settings = @{ CheckingAs = 'tester' }; Target = [pscustomobject]@{ Name = $Machine }
        PasswordRevision = $Revision
    }
}
function Reset-State {
    $script:Latest = @{}
    $script:Watch = $null
    $script:CheckTask = $null
    $script:QueuedRequest = $null
    $script:Secrets = @{}
    $script:SecretRevisions = @{}
    $script:PasswordRevision = 1
    $script:Options = @{ Refresh = 30; Idle = 5; Busy = @(); AskTimeout = 60 }
    $script:StartedChecks = 0
    $script:BannerText = ''
    $passBox = [pscustomobject]@{ ClearCount = 0 }
    $passBox | Add-Member -MemberType ScriptMethod -Name Clear -Value { $this.ClearCount++ }
    $script:ui = @{ HostBox = @{ Text = 'LAB-07' }; UserBox = @{ Text = 'tester' }; PassBox = $passBox }
}
# The tested functions are real; their UI and work dispatch boundaries are inert.
function Show-Banner {
    param([string] $Text, [string] $Kind, [switch] $Transient, [string] $ActionText, [scriptblock] $Action, $Context)
    $script:BannerText = $Text
}
function Set-Busy { param([bool] $On, [string] $HostName) }
function Show-Result { }
function Update-Recent { param($Request, $Result) }
function Update-Actions { }
function Update-Footer { }
function Update-PassHint { }
function Write-UiLog { param([string] $Text) }
function Test-WatchCondition { param($Request, $Result) }
function Get-CheckingIdentity { param([System.Management.Automation.PSCredential] $Credential) return 'test' }
function ConvertTo-TargetCredential { param([System.Management.Automation.PSCredential] $Credential, [string] $ComputerName) return $Credential }
function Split-HostPort { param([string] $Address) return [pscustomobject]@{ Host = $Address; Port = $null } }
function Start-Background {
    param([string] $Name, [string] $Script, [hashtable] $Arguments, [scriptblock] $OnDone, $Context)
    $script:StartedChecks++
    return @{ Context = $Context }
}

Write-Host 'Dashboard regression checks (no UI or network)'
Test-Case 'repeated reads of an unchanged form reuse one remembered password' {
    Reset-State
    $script:ui.PassBox | Add-Member -MemberType ScriptProperty -Name SecurePassword -Value {
        $copy = New-Object System.Security.SecureString
        $copy.AppendChar('x')
        return $copy
    }
    $first = Get-FormRequest
    $second = Get-FormRequest
    Assert-True ([object]::ReferenceEquals($first.Credential.Password, $second.Credential.Password)) 'An unchanged form created another password snapshot.'
    Assert-True ([object]::ReferenceEquals($script:Secrets[$first.Key], $first.Credential.Password)) 'The cache no longer holds the running check password.'
}
Test-Case 'selecting the running check supersedes an older queued selection' {
    Reset-State
    $request = New-Request -Revision 1
    $script:CheckTask = @{ Context = @{ Request = $request; Shown = $true } }
    $script:QueuedRequest = New-Request -Revision 1 -Machine 'LAB-08'
    Start-Check -Request (New-Request -Revision 1)
    Assert-True ($null -eq $script:QueuedRequest) 'An obsolete queued selection still takes over the dashboard.'
    Assert-True ($script:StartedChecks -eq 0) 'A duplicate background check started.'
}
Test-Case 'a rejected password is never retried from the queue' {
    Reset-State
    $request = New-Request -Revision 1
    $script:QueuedRequest = New-Request -Revision 1
    Complete-Check -Output ([pscustomobject]@{ Ok = $true; Value = [pscustomobject]@{ Status = 'Unknown'; ErrorCode = 1326 } }) -Context @{ Request = $request; Shown = $true }
    Assert-True ($script:StartedChecks -eq 0) 'The rejected credential was retried.'
}
Test-Case 'a corrected queued password is checked after the old password fails' {
    Reset-State
    $request = New-Request -Revision 1
    $corrected = New-Request -Revision 2
    $script:PasswordRevision = 2
    $script:Secrets[$corrected.Key] = $corrected.Credential.Password
    $script:SecretRevisions[$corrected.Key] = 2
    $script:QueuedRequest = $corrected
    Complete-Check -Output ([pscustomobject]@{ Ok = $true; Value = [pscustomobject]@{ Status = 'Unknown'; ErrorCode = 1326 } }) -Context @{ Request = $request; Shown = $true }
    Assert-True ($script:StartedChecks -eq 1) 'The corrected request was lost.'
    Assert-True ($script:ui.PassBox.ClearCount -eq 0) 'The corrected password was erased by the old check.'
    Assert-True ([object]::ReferenceEquals($script:Secrets[$corrected.Key], $corrected.Credential.Password)) 'The corrected remembered password was removed.'
}
Test-Case 'a successful manual check refreshes the watched credential' {
    Reset-State
    $old = New-Request -Revision 1
    $new = New-Request -Revision 2
    $script:Watch = @{ Request = $old; NextAt = Get-Date }
    Complete-Check -Output ([pscustomobject]@{ Ok = $true; Value = [pscustomobject]@{ Status = 'InUse'; ErrorCode = $null } }) -Context @{ Request = $new; Shown = $false }
    Assert-True ([object]::ReferenceEquals($script:Watch.Request, $new)) 'Watching still uses the old credential.'
}
Test-Case 'a stale banner cannot restart watching a rejected sign-in' {
    Reset-State
    $request = New-Request -Revision 1
    $script:Latest[$request.Key] = [pscustomobject]@{ ErrorCode = 1326 }
    Start-Watch -Request $request
    Assert-True ($null -eq $script:Watch) 'The failed sign-in was scheduled again.'
}
Test-Case 'a later success does not let an old banner reuse an obsolete password' {
    Reset-State
    $old = New-Request -Revision 1
    $new = New-Request -Revision 2
    $script:Secrets[$new.Key] = $new.Credential.Password
    $script:SecretRevisions[$new.Key] = 2
    $script:Latest[$new.Key] = [pscustomobject]@{ ErrorCode = $null }
    Start-Watch -Request $old
    Assert-True ($null -eq $script:Watch) 'An old banner restarted watching with the obsolete password.'
    Start-Watch -Request $new
    Assert-True ([object]::ReferenceEquals($script:Watch.Request, $new)) 'The current remembered password could not be watched.'
}
Test-Case 'RDP preferences retain display settings and remove saved credentials and target identity' {
    $request = [pscustomobject]@{ Host = '2001:db8::7'; Account = 'LAB-07\tester' }
    $lines = @(Get-RdpConnectionLines -Request $request -TemplateLines @(
        'screen mode id:i:2', 'full address:s:OLD', 'alternate full address:s:OLD', 'username:s:old',
        'domain:s:OLD', 'password 51:b:deadbeef', 'password:s:old-password', 'redirectclipboard:i:1'
    ))
    Assert-True ($lines.Count -eq 4) ('Unexpected RDP settings: {0}' -f ($lines -join ', '))
    Assert-True ($lines -contains 'screen mode id:i:2') 'Display preference was lost.'
    Assert-True ($lines -contains 'redirectclipboard:i:1') 'Device preference was lost.'
    Assert-True ($lines -contains 'full address:s:[2001:db8::7]') 'IPv6 target was not formatted.'
    Assert-True ($lines -contains 'username:s:LAB-07\tester') 'Requested account was not written.'
}
Test-Case 'RDP values cannot inject another settings line' {
    foreach ($request in @(
        [pscustomobject]@{ Host = "LAB-07`r`nfull address:s:other"; Account = 'tester' },
        [pscustomobject]@{ Host = 'LAB-07'; Account = "tester`r`nremoteapplicationmode:i:1" }
    )) {
        $rejected = $false
        try { $null = Get-RdpConnectionLines -Request $request }
        catch { $rejected = $true }
        Assert-True $rejected 'A multiline RDP value was accepted.'
    }
}
Test-Case 'separate launches get separate connection files' {
    Reset-State
    $script:TempRdpFiles = New-Object System.Collections.ArrayList
    $script:LaunchedFiles = New-Object System.Collections.Generic.List[string]
    function Start-Process {
        param([string] $FilePath, [string] $ArgumentList, [string] $ErrorAction, [switch] $PassThru)
        $script:LaunchedFiles.Add($ArgumentList.Trim('"'))
        $process = [pscustomobject]@{ HasExited = $false }
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
        return $process
    }
    try {
        Start-RdpSession -Request ([pscustomobject]@{ Host = 'LAB-07'; Account = 'first' })
        Start-RdpSession -Request ([pscustomobject]@{ Host = 'LAB-07'; Account = 'second' })
        Assert-True ($script:LaunchedFiles.Count -eq 2) ('Expected two launches; {0}' -f $script:BannerText)
        Assert-True ($script:LaunchedFiles[0] -ne $script:LaunchedFiles[1]) 'Two launches overwrite one connection file.'
        Assert-True ((Get-Content -LiteralPath $script:LaunchedFiles[0]) -contains 'username:s:first') 'The first connection account was overwritten.'
        Assert-True ((Get-Content -LiteralPath $script:LaunchedFiles[1]) -contains 'username:s:second') 'The second connection account is missing.'
        Remove-CompletedRdpFiles
        Assert-True (Test-Path -LiteralPath $script:LaunchedFiles[0]) 'An active client lost its connection file.'
        $script:TempRdpFiles[0].Process.HasExited = $true
        Remove-CompletedRdpFiles
        Assert-True (-not (Test-Path -LiteralPath $script:LaunchedFiles[0])) 'An exited client connection file was not cleaned up.'
        Assert-True (Test-Path -LiteralPath $script:LaunchedFiles[1]) 'Cleaning an exited client removed another clients file.'
    }
    finally {
        foreach ($entry in $script:TempRdpFiles) { Remove-Item -LiteralPath $entry.Path -Force -ErrorAction SilentlyContinue }
    }
}
Test-Case 'a failed client launch removes its unused connection file' {
    Reset-State
    $script:TempRdpFiles = New-Object System.Collections.ArrayList
    $script:FailedLaunchFile = ''
    function Start-Process {
        param([string] $FilePath, [string] $ArgumentList, [string] $ErrorAction, [switch] $PassThru)
        $script:FailedLaunchFile = $ArgumentList.Trim('"')
        throw 'The test client could not start.'
    }
    Start-RdpSession -Request ([pscustomobject]@{ Host = 'LAB-07'; Account = 'tester' })
    Assert-True ([bool] $script:FailedLaunchFile) 'The launch boundary was not reached.'
    Assert-True (-not (Test-Path -LiteralPath $script:FailedLaunchFile)) 'The failed launch left its unused connection file.'
}
Write-Host ('All {0} dashboard regression checks passed.' -f $passed)
