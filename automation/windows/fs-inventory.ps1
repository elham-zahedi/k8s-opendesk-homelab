<#
.SYNOPSIS
    Inventory of the file server shares used by Nextcloud (read-only).

.DESCRIPTION
    Doc: docs/04-active-directory-sso.md (section 3)
    Run on: file server, PowerShell as administrator.
    Lists the shares below -ShareRoot, their folders and share permissions, and
    checks that the service group of Nextcloud has at least Change on every share.

.EXAMPLE
    .\fs-inventory.ps1
#>
param(
    [string] $ShareRoot = "F:\Shares",
    [string[]] $Shares = @("Allgemein", "Austausch", "Abteilungen", "Projekte"),
    [string] $ServiceGroup = "G-Nextcloud-Dienst"
)

$ErrorActionPreference = "Stop"
$failed = 0
Get-SmbShare | Where-Object Path -like "$ShareRoot*" |
    Format-Table Name, Path, FolderEnumerationMode -AutoSize | Out-String | Write-Host
foreach ($s in $Shares) {
    $share = Get-SmbShare -Name $s -ErrorAction SilentlyContinue
    if (-not $share) { Write-Host "  FAIL  share $s missing" -ForegroundColor Red; $failed++; continue }
    $folders = @(Get-ChildItem $share.Path -Directory -ErrorAction SilentlyContinue).Count
    $access = Get-SmbShareAccess -Name $s
    $svc = $access | Where-Object { $_.AccountName -like "*\$ServiceGroup" -and $_.AccessRight -in @("Change", "Full") }
    if ($svc) { Write-Host ("  OK    {0,-12} {1} folders, {2}: {3}" -f $s, $folders, $ServiceGroup, $svc.AccessRight) -ForegroundColor Green }
    else { Write-Host ("  FAIL  {0,-12} {1} has no Change permission" -f $s, $ServiceGroup) -ForegroundColor Red; $failed++ }
}
if ($failed -gt 0) { exit 1 }
