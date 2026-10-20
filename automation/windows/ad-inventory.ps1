<#
.SYNOPSIS
    Inventory of Active Directory before the openDesk integration (read-only),
    optionally exports the root CA of AD CS as PEM.

.DESCRIPTION
    Doc: docs/04-active-directory-sso.md (sections 3, 5.1 and 24.2)
    Run on: domain controller, PowerShell as domain administrator
    (via SSH the login opens cmd.exe - type "powershell" first, error F1).

    Checks users, groups, mail addresses, AD CS, the service accounts and the
    service group of the file server, and the test accounts. With -ExportCA the
    root CA is written to -CAFile (PEM) for automation/04-identity/fetch-ad-files.sh.

.EXAMPLE
    .\ad-inventory.ps1
    .\ad-inventory.ps1 -ExportCA
#>
param(
    [string] $UserOU = "OU=Benutzer,OU=Firma",
    [string] $GroupOU = "OU=Gruppen,OU=Firma",
    [string] $GroupPrefix = "G-",
    [string[]] $ServiceAccounts = @("svc-nubus-import", "svc-nextcloud", "svc-keycloak"),
    [string] $ServiceGroup = "G-Nextcloud-Dienst",
    [int] $ExpectedServiceGroupMemberships = 22,
    [string] $TestAccountsFile = "C:\testkonten.txt",
    [switch] $ExportCA,
    [string] $CAFile = "C:\intern-root-ca.pem"
)

$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory
$failed = 0
function Ok($text)   { Write-Host "  OK    $text" -ForegroundColor Green }
function Bad($text)  { Write-Host "  FAIL  $text" -ForegroundColor Red; $script:failed++ }
function Info($text) { Write-Host "        $text" }

$domain = Get-ADDomain
$userBase = "$UserOU,$($domain.DistinguishedName)"
$groupBase = "$GroupOU,$($domain.DistinguishedName)"
Write-Host "== Domain $($domain.DNSRoot) (NetBIOS $($domain.NetBIOSName))"

Write-Host "== Users and groups"
$users = @(Get-ADUser -SearchBase $userBase -SearchScope Subtree -Filter * -Properties mail)
$withMail = @($users | Where-Object mail)
$gGroups = @(Get-ADGroup -SearchBase $groupBase -Filter "Name -like '$GroupPrefix*'")
Info ("users in {0}: {1} ({2} with mail)" -f $UserOU, $users.Count, $withMail.Count)
Info ("groups {0}*: {1}" -f $GroupPrefix, $gGroups.Count)
if ($users.Count -gt 0) { Ok "users found" } else { Bad "no users below $userBase" }
if ($withMail.Count -eq $users.Count) { Ok "every user has a mail address" }
else { Info "$($users.Count - $withMail.Count) users without mail get <login>@$($domain.DNSRoot) (importer)" }

Write-Host "== AD CS and certificates"
$adcs = Get-WindowsFeature ADCS-Cert-Authority
if ($adcs.InstallState -eq "Installed") { Ok "ADCS-Cert-Authority installed" } else { Bad "AD CS not installed - LDAPS needs a DC certificate" }
Get-ChildItem Cert:\LocalMachine\My | ForEach-Object { Info ("{0}  valid until {1:yyyy-MM-dd}" -f $_.Subject, $_.NotAfter) }

Write-Host "== Service accounts"
foreach ($n in $ServiceAccounts) {
    $u = Get-ADUser -Filter "SamAccountName -eq '$n'" -Properties Enabled, DistinguishedName
    if ($u -and $u.Enabled) { Ok "$n enabled ($($u.DistinguishedName))" } else { Bad "$n missing or disabled" }
}
$sg = Get-ADGroup -Filter "Name -eq '$ServiceGroup'"
if ($sg) {
    $count = @(Get-ADPrincipalGroupMembership $sg).Count
    if ($count -eq $ExpectedServiceGroupMemberships) { Ok "$ServiceGroup is member of $count groups" }
    else { Bad "$ServiceGroup is member of $count groups (expected $ExpectedServiceGroupMemberships) - file server permissions?" }
} else { Bad "$ServiceGroup not found" }

Write-Host "== Test accounts ($TestAccountsFile)"
if (Test-Path $TestAccountsFile) {
    Get-Content $TestAccountsFile | Where-Object { $_.Trim() } | ForEach-Object {
        $login = ($_ -split ';')[1]
        $u = Get-ADUser $login -Properties pwdLastSet, mail
        Info ("{0,-20} {1,-32} change at logon: {2}" -f $u.SamAccountName, $u.mail, ($u.pwdLastSet -eq 0))
    }
} else { Info "not found - only needed for the browser tests" }

if ($ExportCA) {
    Write-Host "== Export the root CA to $CAFile"
    $cer = [IO.Path]::ChangeExtension($CAFile, ".cer")
    certutil -f "-ca.cert" $cer | Out-Null
    certutil -f -encode $cer $CAFile | Out-Null
    $ca = New-Object Security.Cryptography.X509Certificates.X509Certificate2 $cer
    Ok ("{0}, valid until {1:yyyy-MM-dd}, thumbprint {2}" -f $ca.Subject, $ca.NotAfter, $ca.Thumbprint)
    Info "copy it with automation/04-identity/fetch-ad-files.sh on the kubespray VM"
}

Write-Host ""
if ($failed -eq 0) { Write-Host "All checks passed" -ForegroundColor Green } else { Write-Host "$failed check(s) failed" -ForegroundColor Red; exit 1 }
