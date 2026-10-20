<#
.SYNOPSIS
    Imports the openDesk root CA into the Windows certificate store after checking its thumbprint.

.DESCRIPTION
    Doc: docs/03-opendesk-deployment.md (section 14.4)
    Run on: Windows workstation, PowerShell as administrator.

    - Checks DNS (portal name -> MetalLB address) and HTTPS reachability first.
    - Stops if the thumbprint of the file does not match the expected one
      (the value printed by automation/03-opendesk/export-ca.sh).
    - Imports the CA into LocalMachine\Root only if it is not there yet.
    - Lists older CAs for the same domain; they are NOT removed automatically.
    - Tests portal and files over HTTPS with curl.exe.

    Scripts downloaded from the internet are blocked by the default execution policy;
    start it for this one run with:
    powershell -ExecutionPolicy Bypass -File .\import-ca.ps1 -CertFile ... -ExpectedThumbprint ...

.EXAMPLE
    .\import-ca.ps1 -CertFile C:\Temp\opendesk-ca.crt -ExpectedThumbprint 72B421CCBE067C69A4D7ABA7FD43BEA7BB1E93E0
#>
param(
    [Parameter(Mandatory = $true)] [string] $CertFile,
    [Parameter(Mandatory = $true)] [string] $ExpectedThumbprint,
    [string] $Domain = "k8s.lab",
    [string] $LoadBalancerIp = "10.240.0.190"
)

$ErrorActionPreference = "Stop"

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script in PowerShell as administrator."
}

# DNS and network first (doc 03, section 14.1)
Clear-DnsClientCache
$resolved = (Resolve-DnsName "portal.$Domain" -Type A -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress }).IPAddress
if ($resolved -contains $LoadBalancerIp) {
    Write-Host "OK: portal.$Domain -> $LoadBalancerIp" -ForegroundColor Green
} else {
    Write-Warning "portal.$Domain resolves to '$resolved', expected $LoadBalancerIp - check the DNS server of this PC"
}
if ((Test-NetConnection $LoadBalancerIp -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded) {
    Write-Host "OK: $LoadBalancerIp port 443 reachable" -ForegroundColor Green
} else {
    Write-Warning "$LoadBalancerIp port 443 not reachable"
}
# An NRPT rule is not needed when the PC already uses the domain controller as DNS (error F9)
if (Get-DnsClientNrptRule | Where-Object { $_.Namespace -eq ".$Domain" }) {
    Write-Warning "NRPT rule for .$Domain found - not needed, remove it with:"
    Write-Warning "  Get-DnsClientNrptRule | Where-Object { `$_.Namespace -eq '.$Domain' } | Remove-DnsClientNrptRule -Force"
}

$expected = ($ExpectedThumbprint -replace '[:\s]', '').ToUpper()
$thumbprint = (Get-PfxCertificate -FilePath $CertFile).Thumbprint
Write-Host "Thumbprint of the file: $thumbprint"
if ($thumbprint -ne $expected) {
    throw "Thumbprint does not match (expected $expected) - do not import this file."
}
Write-Host "OK: thumbprint matches" -ForegroundColor Green

$existing = Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -like "*CN=$Domain*" }
foreach ($cert in $existing) {
    if ($cert.Thumbprint -ne $thumbprint) {
        Write-Warning ("Older CA for {0}: {1} (valid until {2}). Remove it by thumbprint when the new one works:" -f $Domain, $cert.Thumbprint, $cert.NotAfter)
        Write-Warning ("  Remove-Item Cert:\LocalMachine\Root\{0}" -f $cert.Thumbprint)
    }
}

if ($existing | Where-Object { $_.Thumbprint -eq $thumbprint }) {
    Write-Host "OK: CA is already in LocalMachine\Root" -ForegroundColor Green
} else {
    Import-Certificate -FilePath $CertFile -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
    Write-Host "OK: CA imported into LocalMachine\Root" -ForegroundColor Green
}

# curl.exe, not curl (in PowerShell "curl" is an alias for Invoke-WebRequest).
# --ssl-no-revoke: the internal CA has no CRL/OCSP address.
foreach ($test in @(@{ Name = "portal.$Domain"; Code = "301" }, @{ Name = "files.$Domain"; Code = "302" })) {
    $code = & curl.exe --ssl-no-revoke -s -o NUL -w "%{http_code}" ("https://" + $test.Name)
    if ($code -eq $test.Code) {
        Write-Host ("OK: https://{0} -> {1}, no certificate error" -f $test.Name, $code) -ForegroundColor Green
    } else {
        Write-Warning ("https://{0} -> {1} (expected {2}; 000 = certificate or connection error)" -f $test.Name, $code, $test.Code)
    }
}
Write-Host "Close the browser completely and open https://portal.$Domain again."
