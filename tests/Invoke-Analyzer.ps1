#Requires -Version 5.1
<#
.SYNOPSIS
    Runs PSScriptAnalyzer on every script. Errors fail the run; warnings are listed.

.DESCRIPTION
    Installs PSScriptAnalyzer for the current user when it is missing.

    pwsh -File .\tests\Invoke-Analyzer.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    Write-Host 'Installing PSScriptAnalyzer for the current user'
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module -Name PSScriptAnalyzer -Scope CurrentUser
}
Import-Module -Name PSScriptAnalyzer
Write-Host ('PSScriptAnalyzer {0} on PowerShell {1}' -f (Get-Module -Name PSScriptAnalyzer).Version, $PSVersionTable.PSVersion)

$files = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -Recurse -File | Where-Object { $_.FullName -notlike '*\out\*' })
$found = @(foreach ($file in $files) { Invoke-ScriptAnalyzer -Path $file.FullName })
$errors = @($found | Where-Object { @('Error', 'ParseError') -contains [string] $_.Severity })
$warnings = @($found | Where-Object { [string] $_.Severity -eq 'Warning' })

foreach ($group in @($warnings | Group-Object -Property RuleName | Sort-Object -Property Count -Descending)) {
    Write-Host ''
    Write-Host ('{0} x {1}' -f $group.Count, $group.Name) -ForegroundColor Yellow
    foreach ($item in $group.Group) {
        Write-Host ('    {0}:{1}  {2}' -f (Split-Path -Leaf $item.ScriptPath), $item.Line, $item.Message)
    }
}

foreach ($item in $errors) {
    $relative = $item.ScriptPath.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
    $message = ([string] $item.Message).Replace('%', '%25').Replace("`r", '').Replace("`n", ' ')
    Write-Host ('{0}:{1}  {2}  {3}' -f $relative, $item.Line, $item.RuleName, $message) -ForegroundColor Red
    if ($env:GITHUB_ACTIONS) {
        Write-Host ('::error file={0},line={1},col={2},title={3}::{4}' -f $relative, $item.Line, $item.Column, $item.RuleName, $message)
    }
}

Write-Host ''
Write-Host ('{0} errors, {1} warnings in {2} files' -f $errors.Count, $warnings.Count, $files.Count)
if ($errors.Count -gt 0) { exit 1 }
