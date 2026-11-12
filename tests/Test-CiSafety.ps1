#Requires -Version 5.1
<#
.SYNOPSIS
    Checks CI account cleanup without creating or removing Windows accounts.
.DESCRIPTION
    Loads only the CI account helper, replacing the account cmdlets with mocks.
    Covers successful checks, failed creation and failed work after creation.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot 'Test-CommandLine.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $tokens, [ref] $errors)
if ($errors.Count -gt 0) { throw $errors[0] }
$definition = $ast.Find({
    param($Node)
    $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Invoke-WithCiAccount'
}, $true)
if ($null -eq $definition) { throw 'The CI account helper is missing.' }
. ([scriptblock]::Create($definition.Extent.Text))

$script:Names = New-Object System.Collections.Generic.List[string]
$script:Accounts = New-Object System.Collections.Generic.List[object]
$script:Removed = New-Object System.Collections.Generic.List[object]
$script:FailCreation = $false

# These functions shadow the Windows account cmdlets. The script never loads
# or invokes the surrounding command-line tests and never changes this machine.
function New-LocalUser {
    [CmdletBinding()]
    param(
        [string] $Name,
        [System.Security.SecureString] $Password,
        [switch] $AccountNeverExpires,
        [switch] $PasswordNeverExpires,
        [string] $Description
    )
    $script:Names.Add($Name)
    if ($script:FailCreation) { throw 'Simulated account creation failure' }
    if ($null -eq $Password -or -not $AccountNeverExpires -or -not $PasswordNeverExpires -or -not $Description) {
        throw 'The temporary account was not configured as expected.'
    }
    return [pscustomobject]@{ Name = $Name; SID = ('S-1-5-21-100-200-300-{0}' -f $script:Names.Count) }
}

function Remove-LocalUser {
    [CmdletBinding()]
    param([object] $SID, [string] $Name)
    if ($Name -or $null -eq $SID) { throw 'Cleanup must identify the created account by SID.' }
    $script:Removed.Add($SID)
}

$password = New-Object System.Security.SecureString
try {
    for ($i = 0; $i -lt 2; $i++) {
        Invoke-WithCiAccount -Password $password -Action {
            param($Account)
            $script:Accounts.Add($Account)
        }
    }
    if ($script:Names[0] -eq $script:Names[1]) { throw 'Checks shared the same temporary account name.' }
    foreach ($name in $script:Names) {
        if ($name.Length -gt 20 -or $name -notmatch '^srdp-[0-9a-f]+$') { throw ('Invalid temporary account name: {0}' -f $name) }
    }
    if ($script:Accounts.Count -ne 2 -or $script:Removed.Count -ne 2) { throw 'Successful checks did not clean up both accounts.' }
    for ($i = 0; $i -lt 2; $i++) {
        if ($script:Removed[$i] -ne $script:Accounts[$i].SID) { throw 'Cleanup targeted an account other than the created one.' }
    }
    Write-Host 'PASS: each check creates a unique account and removes its exact SID.'

    $script:FailCreation = $true
    $caught = $false
    try {
        Invoke-WithCiAccount -Password $password -Action {
            param($Account)
            $script:Accounts.Add($Account)
        }
    }
    catch { $caught = $_.Exception.Message -eq 'Simulated account creation failure' }
    if (-not $caught) { throw 'The account creation failure was not propagated.' }
    if ($script:Accounts.Count -ne 2 -or $script:Removed.Count -ne 2) { throw 'Failed creation ran the checks or removed an account.' }
    Write-Host 'PASS: failed creation never removes a preexisting account.'

    $script:FailCreation = $false
    $caught = $false
    try {
        Invoke-WithCiAccount -Password $password -Action {
            param($Account)
            $script:Accounts.Add($Account)
            # A name is mutable and may be reused. Cleanup must keep using SID.
            $Account.Name = 'preexisting-account'
            throw 'Simulated check failure'
        }
    }
    catch { $caught = $_.Exception.Message -eq 'Simulated check failure' }
    if (-not $caught) { throw 'The check failure was not propagated.' }
    if ($script:Removed.Count -ne 3 -or $script:Removed[2] -ne $script:Accounts[2].SID) { throw 'Failed checks did not remove their created account by SID.' }
    Write-Host 'PASS: failed checks still remove only the created SID.'
}
finally {
    $password.Dispose()
}
