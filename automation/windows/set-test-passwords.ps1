<#
.SYNOPSIS
    Sets one shared password for the test accounts, or forces a password change
    at the next logon again when the tests are finished.

.DESCRIPTION
    Doc: docs/04-active-directory-sso.md (sections 19.1 and 24.3)
    Run on: domain controller, PowerShell as domain administrator (not on FS - error F3).
    The accounts are read from the second column of the test accounts file
    (role;login;groups). The password is asked for with hidden input.

.EXAMPLE
    .\set-test-passwords.ps1                         # new test password, no forced change
    .\set-test-passwords.ps1 -RequireChangeAtLogon   # after the tests
#>
param(
    [string] $TestAccountsFile = "C:\testkonten.txt",
    [switch] $RequireChangeAtLogon
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path $TestAccountsFile)) { throw "$TestAccountsFile not found" }
$logins = Get-Content $TestAccountsFile | Where-Object { $_.Trim() } | ForEach-Object { ($_ -split ';')[1] }
Write-Host "Test accounts: $($logins -join ', ')"

if ($RequireChangeAtLogon) {
    foreach ($l in $logins) { Set-ADUser $l -ChangePasswordAtLogon $true; Write-Host "  change at next logon: $l" }
    exit 0
}

$pw = Read-Host -AsSecureString "New test password"
foreach ($l in $logins) {
    Set-ADAccountPassword $l -Reset -NewPassword $pw
    Set-ADUser $l -ChangePasswordAtLogon $false
    Write-Host "  set: $l" -ForegroundColor Green
}
Remove-Variable pw
Write-Host "Store the password in a password manager."
