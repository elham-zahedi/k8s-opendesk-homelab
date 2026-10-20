# windows – Workstation scripts

**Run on:** Windows workstation, PowerShell as administrator

| Script | What it does | Doc |
|---|---|---|
| `import-ca.ps1` | Checks DNS and port 443 of the MetalLB address, warns about an unnecessary NRPT rule, imports the openDesk root CA only if its thumbprint matches, lists older CAs, tests portal and Nextcloud over HTTPS | [03](../../docs/03-opendesk-deployment.md) section 14 |

```powershell
# thumbprint: printed by automation/03-opendesk/export-ca.sh on the kubespray VM
powershell -ExecutionPolicy Bypass -File .\import-ca.ps1 -CertFile C:\Temp\opendesk-ca.crt -ExpectedThumbprint <thumbprint>
```

`-ExecutionPolicy Bypass` only applies to this one call; Windows blocks downloaded scripts by default.
