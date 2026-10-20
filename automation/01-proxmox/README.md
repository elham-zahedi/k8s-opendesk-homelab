# 01 – Proxmox cloud-init template

Scripts for [docs/01 – Proxmox cloud-init template](../../docs/01-proxmox-cloud-init-template.md).
The document explains every setting; these scripts apply them in one go.

**Run on:** Proxmox host as root

| Script | What it does | Changes something? |
|---|---|---|
| `create-template.sh` | Downloads the Ubuntu 24.04 cloud image, bakes in `qemu-guest-agent` and `chrony`, creates the VM, imports and resizes the disk, sets up cloud-init (user, password, DNS, updates, SSH keys) and converts the VM into a template | Yes |
| `verify-template.sh` | Checks 23 settings of the template against `lab.env` (hardware, network MTU, cloud-init, SSH keys, `template: 1`) | No – read-only |

## Usage

```bash
cd automation
cp lab.env.example lab.env               # once; adjust section "01 Proxmox"
./01-proxmox/create-template.sh --dry-run    # shows every command, changes nothing
./01-proxmox/create-template.sh              # asks for the console password
./01-proxmox/verify-template.sh
```

The console password is asked for at runtime (hidden input) or taken from the variable `CI_PASSWORD`. It is never written to a file.

## Safety

- The script stops if the VM ID already exists – an existing template is never overwritten.
- It stops if the storage or an SSH key file is missing, or if the user is called `kube` (reserved by Kubespray).
- It checks that all SSH keys appear in the cloud-init configuration before converting the VM.
- It asks before the final `qm template` step (skip the question with `--yes`).

## Testing next to an existing template

The template can be rebuilt under a different ID without touching template 9000:

```bash
TEMPLATE_ID=9001 TEMPLATE_NAME=k8s-tpl-test ./01-proxmox/create-template.sh
TEMPLATE_ID=9001 ./01-proxmox/verify-template.sh
qm destroy 9001                          # remove the test template afterwards
```

## Expected result

```
==> Template 9000 – state
  ✔ converted to a template (template: 1)

  ✔ All 23 checks passed
```
