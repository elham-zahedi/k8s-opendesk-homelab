<#
.SYNOPSIS
    Checks the passwords of the AD service accounts with an LDAP bind (input hidden).

.DESCRIPTION
    Doc: docs/04-active-directory-sso.md (section 5.1)
    Run on: domain controller (or any domain member), PowerShell.
    Nothing is changed; the passwords are only kept in memory for the bind.

.EXAMPLE
    .\test-service-accounts.ps1
#>
param(
    [string[]] $ServiceAccounts = @("svc-nubus-import", "svc-nextcloud", "svc-keycloak"),
    [string] $Server = ""
)

$ErrorActionPreference = "Stop"
$dnsRoot = (Get-ADDomain).DNSRoot
if (-not $Server) { $Server = "$env:COMPUTERNAME.$dnsRoot" }
$failed = 0
foreach ($n in $ServiceAccounts) {
    $pw = Read-Host -AsSecureString "Password $n"
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw))
    try {
        $name = (New-Object System.DirectoryServices.DirectoryEntry("LDAP://$Server", "$n@$dnsRoot", $plain)).name
        if ($name) { Write-Host ("  OK    {0}" -f $n) -ForegroundColor Green } else { throw "bind returned no object" }
    } catch {
        Write-Host ("  FAIL  {0}: {1}" -f $n, $_.Exception.Message) -ForegroundColor Red; $failed++
    } finally {
        Remove-Variable plain, pw -ErrorAction SilentlyContinue
    }
}
if ($failed -gt 0) { exit 1 }
