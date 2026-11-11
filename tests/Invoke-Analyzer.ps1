#Requires -Version 5.1
<#
.SYNOPSIS
    Runs PSScriptAnalyzer on every script. Errors and warnings fail the run.

.DESCRIPTION
    The rules come from PSScriptAnalyzerSettings.psd1 next to this script, which
    leaves out the few that do not fit these scripts and says why. Informational
    notes are counted but not listed. Installs PSScriptAnalyzer for the current
    user when it is missing.

    pwsh -File .\tests\Invoke-Analyzer.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'

if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    Write-Host 'Installing PSScriptAnalyzer for the current user'
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module -Name PSScriptAnalyzer -Scope CurrentUser
}
Import-Module -Name PSScriptAnalyzer
Write-Host ('PSScriptAnalyzer {0} on PowerShell {1}' -f (Get-Module -Name PSScriptAnalyzer).Version, $PSVersionTable.PSVersion)

# Screenshots and logs of earlier runs live in out\; they hold no scripts of ours.
$files = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]out[\\/]' })
$found = @(foreach ($file in $files) { Invoke-ScriptAnalyzer -Path $file.FullName -Settings $settings })
$problems = @($found | Where-Object { @('Error', 'ParseError', 'Warning') -contains [string] $_.Severity })
$notes = @($found | Where-Object { [string] $_.Severity -eq 'Information' })

foreach ($item in $problems) {
    $relative = $item.ScriptPath.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
    $message = ([string] $item.Message).Replace('%', '%25').Replace("`r", '').Replace("`n", ' ')
    Write-Host ('{0}:{1}  {2} {3}  {4}' -f $relative, $item.Line, $item.Severity, $item.RuleName, $message) -ForegroundColor Red
    if ($env:GITHUB_ACTIONS) {
        Write-Host ('::error file={0},line={1},col={2},title={3}::{4}' -f $relative, $item.Line, $item.Column, $item.RuleName, $message)
    }
}

Write-Host ''
Write-Host ('{0} errors and warnings in {1} files ({2} informational notes not listed)' -f $problems.Count, $files.Count, $notes.Count)
if ($problems.Count -gt 0) { exit 1 }
