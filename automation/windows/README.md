# windows – Scripts for the Windows machines

Run in PowerShell as administrator. Over SSH the domain controller opens `cmd.exe` – type `powershell` first. Downloaded scripts are blocked by the default execution policy; start them for one run with `powershell -ExecutionPolicy Bypass -File .\<script>.ps1 …`.

| Script | Run on | What it does | Doc |
|---|---|---|---|
| `ad-inventory.ps1 [-ExportCA]` | Domain controller | Users, groups, mail addresses, AD CS, service accounts, service group of the file server, test accounts; `-ExportCA` writes the root CA as PEM | [04](../../docs/04-active-directory-sso.md) sections 3, 5.1 |
| `test-service-accounts.ps1` | Domain controller | LDAP bind with each service account (passwords asked for, hidden) | [04](../../docs/04-active-directory-sso.md) section 5.1 |
| `set-test-passwords.ps1 [-RequireChangeAtLogon]` | Domain controller | One test password for the browser tests; afterwards force a password change again | [04](../../docs/04-active-directory-sso.md) sections 19.1, 24.3 |
| `fs-inventory.ps1` | File server | Shares, folders and share permissions; the service group needs Change | [04](../../docs/04-active-directory-sso.md) section 3 |
| `import-ca.ps1` | Workstation | Checks DNS and port 443, warns about an unnecessary NRPT rule, imports the openDesk root CA only if the thumbprint matches, tests HTTPS | [03](../../docs/03-opendesk-deployment.md) section 14 |

The default names (OUs, groups, service accounts, `C:\testkonten.txt`) are the ones of the documentation; pass your own with the parameters, e.g. `-UserOU "OU=Users,OU=Company"`.

```powershell
# thumbprint: printed by automation/03-opendesk/export-ca.sh on the kubespray VM
powershell -ExecutionPolicy Bypass -File .\import-ca.ps1 -CertFile C:\Temp\opendesk-ca.crt -ExpectedThumbprint <thumbprint>
```

All scripts parse without errors and pass PSScriptAnalyzer (except the rule against `Write-Host`, which is used on purpose for coloured console output).
