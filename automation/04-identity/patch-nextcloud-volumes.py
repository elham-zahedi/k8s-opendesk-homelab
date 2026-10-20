#!/usr/bin/env python3
"""Replace the CA block of values-nextcloud.yaml.gotmpl with a block that also mounts the SMB volumes.

Doc: docs/04-active-directory-sso.md (section 12). Called by patch-nextcloud-volumes.sh.
Usage: patch-nextcloud-volumes.py FILE SNIPPET   (FILE is changed in place)

The original block looks like this (the condition wraps both lists):
    {{- if .Values.certificate.selfSigned }}
      extraVolumes:
        - name: "trusted-cert-secret-volume"  ...
      extraVolumeMounts:
        - name: "trusted-cert-secret-volume"  ...
    {{- end }}
It is found by its content, not by line numbers, and the script stops if it does
not look exactly like that.
"""
import re
import sys

path, snippet_path = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().split("\n")

IF = re.compile(r"^\s*\{\{-?\s*if \.Values\.certificate\.selfSigned\s*-?\}\}\s*$")
END = re.compile(r"^\s*\{\{-?\s*end\s*-?\}\}\s*$")
NESTED = re.compile(r"^\s*\{\{-?\s*(if|range|with)\b")

start = next((i for i, l in enumerate(lines[:-1])
              if IF.match(l) and re.match(r"^\s*extraVolumes:\s*$", lines[i + 1])), None)
if start is None:
    sys.exit("ERROR: block '{{- if .Values.certificate.selfSigned }}' followed by 'extraVolumes:' not found")

mounts = end = None
for j in range(start + 1, len(lines)):
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

snippet = open(snippet_path, encoding="utf-8").read().rstrip("\n").split("\n")
open(path, "w", encoding="utf-8").write("\n".join(lines[:start] + snippet + lines[end + 1:]))
print(f"replaced lines {start + 1}-{end + 1} with {len(snippet)} lines")
