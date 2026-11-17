#!/usr/bin/env python3
"""Add the SMB volumes to the CA block of values-nextcloud.yaml.gotmpl.

Doc: docs/04-active-directory-sso.md (section 12). Called by patch-nextcloud-volumes.sh.
Usage: patch-nextcloud-volumes.py FILE SHARE...   (FILE is changed in place; SHARE in lower case)

The original block looks like this (the condition wraps both lists):
    {{- if .Values.certificate.selfSigned }}      up to openDesk 1.18
    {{- if .Values.trust.secret.mount }}          from openDesk 1.19
      extraVolumes:
        - name: "trusted-cert-secret-volume"  ...
      extraVolumeMounts:
        - name: "trusted-cert-secret-volume"  ...
    {{- end }}
It becomes two lists that are always there: the CA entries keep their original
condition and lines, one volume and one mount per share follow without a condition.
The block is found by its content, not by line numbers, and the script stops if it
does not look exactly like that.
"""
import re
import sys

path, shares = sys.argv[1], sys.argv[2:]
if not shares:
    sys.exit("ERROR: no shares given")
lines = open(path, encoding="utf-8").read().split("\n")

IF = re.compile(r"^\s*\{\{-?\s*if \.Values\.(certificate\.selfSigned|trust\.secret\.mount)\s*-?\}\}\s*$")
END = re.compile(r"^\s*\{\{-?\s*end\s*-?\}\}\s*$")
NESTED = re.compile(r"^\s*\{\{-?\s*(if|range|with)\b")

start = next((i for i, l in enumerate(lines[:-1])
              if IF.match(l) and re.match(r"^\s*extraVolumes:\s*$", lines[i + 1])), None)
if start is None:
    sys.exit("ERROR: block '{{- if .Values.certificate.selfSigned }}' or '{{- if .Values.trust.secret.mount }}'"
             " followed by 'extraVolumes:' not found")

mounts = end = None
for j in range(start + 2, len(lines)):
    if NESTED.match(lines[j]):
        sys.exit(f"ERROR: unexpected template block in line {j + 1} - change the file by hand")
    if re.match(r"^\s*extraVolumeMounts:\s*$", lines[j]):
        mounts = j
    if mounts is not None and END.match(lines[j]):
        end = j
        break
if end is None:
    sys.exit("ERROR: end of the block ('extraVolumeMounts:' ... '{{- end }}') not found")
if not any("trusted-cert-secret-volume" in l for l in lines[start:end + 1]):
    sys.exit("ERROR: the block does not contain trusted-cert-secret-volume - change the file by hand")

key_indent = re.match(r"^(\s*)", lines[start + 1]).group(1)   # indentation of "extraVolumes:"
item = key_indent + "  "
cond, endif = item + lines[start].strip(), item + lines[end].strip()
ca_volumes, ca_mounts = lines[start + 2:mounts], lines[mounts + 1:end]

block = [key_indent + "extraVolumes:", cond, *ca_volumes, endif]
for s in shares:
    block += [f'{item}- name: "fs-{s}"', f"{item}  persistentVolumeClaim:", f'{item}    claimName: "pvc-fs-{s}"']
block += [key_indent + "extraVolumeMounts:", cond, *ca_mounts, endif]
for s in shares:
    block += [f'{item}- name: "fs-{s}"', f'{item}  mountPath: "/mnt/fs-{s}"']

open(path, "w", encoding="utf-8").write("\n".join(lines[:start] + block + lines[end + 1:]))
print(f"replaced lines {start + 1}-{end + 1} with {len(block)} lines (condition: {lines[start].strip()})")
