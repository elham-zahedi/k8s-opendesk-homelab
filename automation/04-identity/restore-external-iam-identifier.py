#!/usr/bin/env python3
# Based on docs/migrations-helper/1.18.0-external-iam-identifier.py of openDesk (ZenDiS, Apache-2.0).
#
# Restores the identifiers of an external IAM AFTER the upgrade to openDesk 1.18:
# migrations-pre (action ldap_entryuuid_to_object_identifier) overwrote univentionObjectIdentifier
# and logged every change as "    <dn>: <old> -> <new>". This script reads the OLD values from that
# log and writes them into reservedLegacyExternalIamIdentifier, through the UDM REST API.
#
# Only objects below --scope-dn (the OU the Directory Importer writes to) are touched.
# Safety checks per object, before anything is written:
#   - the object still carries the NEW value of the log in univentionObjectIdentifier
#     (otherwise it is not the object the log line describes -> conflict, not touched)
#   - reservedLegacyExternalIamIdentifier is empty (-> write), equal to the old value (-> done),
#     or different (-> conflict, not touched; the attribute may only be set once)
#
# Usage (UDM REST API through a port forwarding, see the openDesk instructions):
#   kubectl -n opendesk port-forward service/ums-udm-rest-api 9979:9979 &
#   export UDM_PASSWORD="$(kubectl -n opendesk get secret ums-ldap-server-admin -o jsonpath='{.data.password}' | base64 -d)"
#   python3 restore-external-iam-identifier.py --log <migrations-pre log> --dry-run
#   python3 restore-external-iam-identifier.py --log <migrations-pre log> --limit 1
#   python3 restore-external-iam-identifier.py --log <migrations-pre log>

import argparse
import base64
import json
import logging
import os
import re
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import quote

DEFAULT_UDM_URL = 'http://localhost:9979/univention/udm/'
DEFAULT_UDM_USERNAME = 'cn=admin'
DEFAULT_SCOPE_DN = 'ou=intern-ad,dc=swp-ldap,dc=internal'

SOURCE_PROPERTY = 'univentionObjectIdentifier'
TARGET_PROPERTY = 'reservedLegacyExternalIamIdentifier'
RETRY_STATUS_CODES = (429, 500, 502, 503, 504)

UUID = r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
UUID_VALUE = re.compile(rf'^{UUID}$')
LOG_LINE = re.compile(rf'INFO :\s+(?P<dn>\S.*?): (?P<old>{UUID}) -> (?P<new>{UUID})\s*$')
BLOCK_START = 'ldap_entryuuid_to_object_identifier: Aligning'
BLOCK_END = 'now carry their entryUUID'


class UdmError(RuntimeError):
    """Raised when the UDM REST API returns an unexpected response."""


class UdmClient:
    """Same calls as in the openDesk helper: read an object with its ETag, write it back."""

    def __init__(self, base_url, username, password, timeout=30, retries=3, retry_wait_seconds=5):
        self.base_url = base_url.rstrip('/') + '/'
        credentials = f"{username}:{password}".encode('utf-8')
        self.authorization = 'Basic ' + base64.b64encode(credentials).decode('ascii')
        self.timeout = timeout
        self.retries = retries
        self.retry_wait_seconds = retry_wait_seconds

    def _request(self, method, path, payload=None, etag=None):
        url = self.base_url + path.lstrip('/')
        body = json.dumps(payload).encode('utf-8') if payload is not None else None
        headers = {'Authorization': self.authorization, 'Accept': 'application/json'}
        if body is not None:
            headers['Content-Type'] = 'application/json'
        if etag:
            headers['If-Match'] = etag
        last_error = None
        for attempt in range(1, self.retries + 1):
            request = urllib.request.Request(url, data=body, headers=headers, method=method)
            try:
                with urllib.request.urlopen(request, timeout=self.timeout) as response:
                    content = response.read().decode('utf-8')
                    return (json.loads(content) if content.strip() else None, response.headers)
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    return (None, None)
                detail = e.read().decode('utf-8', errors='replace')
                last_error = UdmError(f"UDM REST API error during {method} {path}: HTTP {e.code} {detail}")
                if e.code not in RETRY_STATUS_CODES:
                    raise last_error from e
            except (urllib.error.URLError, TimeoutError) as e:
                last_error = UdmError(f"UDM REST API unreachable during {method} {path}: {e}")
            if attempt < self.retries:
                logging.warning(f"{last_error} - retrying in {self.retry_wait_seconds}s "
                                f"({attempt}/{self.retries - 1}).")
                time.sleep(self.retry_wait_seconds)
        raise last_error

    @staticmethod
    def _object_path(module, dn):
        return f"{module}/{quote(dn, safe='')}"

    def get(self, module, dn):
        body, headers = self._request('GET', self._object_path(module, dn))
        if body is None:
            return (None, None)
        return (body, headers.get('ETag') if headers else None)

    def put(self, module, representation, etag):
        self._request('PUT', self._object_path(module, representation['dn']), representation, etag=etag)


def read_log(path, scope_dn):
    """(dn, old, new) for every object below scope_dn, from the action's block of the log."""
    entries, inside, seen = [], False, {}
    suffix = ',' + scope_dn.lower()
    stats = {'blocks': 0, 'changes': 0, 'in_scope': 0, 'unparsed': 0, 'outside': 0}
    with open(path, 'r', encoding='utf-8', errors='replace') as log:
        for line in log:
            if BLOCK_START in line:
                inside = True
                stats['blocks'] += 1
                continue
            if inside and BLOCK_END in line:
                inside = False
                continue
            match = LOG_LINE.search(line)
            if not inside:
                if match and match.group('dn').strip().lower().endswith(suffix):
                    stats['outside'] += 1
                continue
            if not match:
                if ' -> ' in line:
                    stats['unparsed'] += 1
                continue
            stats['changes'] += 1
            dn, old, new = match.group('dn').strip(), match.group('old').lower(), match.group('new').lower()
            if not dn.lower().endswith(suffix):
                continue
            stats['in_scope'] += 1
            if dn.lower() in seen and seen[dn.lower()] != (old, new):
                raise UdmError(f"{dn} appears twice in the log with different values.")
            if dn.lower() not in seen:
                seen[dn.lower()] = (old, new)
                entries.append((dn, old, new))
    logging.info(f"LOG: {stats['blocks']} block(s), {stats['changes']} change line(s), "
                 f"{stats['in_scope']} below the scope ({len(entries)} distinct), "
                 f"{stats['unparsed']} unparsed '->' line(s) in the block, "
                 f"{stats['outside']} matching line(s) outside the block.")
    return entries


def module_for(dn):
    first = dn.split('=', 1)[0].strip().lower()
    return {'uid': 'users/user', 'cn': 'groups/group'}.get(first)


def restore(udm, entries, dry_run, limit):
    plan, done, conflicts, missing, skipped = [], 0, [], [], []
    for dn, old, new in entries:
        module = module_for(dn)
        if module is None:
            skipped.append(dn)
            continue
        representation, etag = udm.get(module, dn)
        if representation is None:
            missing.append(dn)
            continue
        properties = representation.get('properties') or {}
        if TARGET_PROPERTY not in properties:
            raise UdmError(f"{module} has no property '{TARGET_PROPERTY}' - the extended attribute "
                           "is missing (step 2 of the openDesk instructions).")
        current = str(properties.get(SOURCE_PROPERTY) or '').lower()
        target = str(properties.get(TARGET_PROPERTY) or '').lower()
        entry_uuid = str(representation.get('uuid') or '').lower()
        if not entry_uuid:
            origin = 'entryUUID unknown'
        elif entry_uuid == new:
            origin = 'same object as in the log'
        else:
            origin = 'object RECREATED after the migration (other entryUUID)'
        # Conflict reasons name no identifier values, so they can be shared.
        if target == old:
            done += 1
        elif target:
            conflicts.append((dn, f"{TARGET_PROPERTY} already carries a DIFFERENT value; {origin}"))
        elif current == old:
            conflicts.append((dn, f"{SOURCE_PROPERTY} carries the OLD value of the log again "
                                  f"(changed back after the migration); {origin}"))
        elif not current:
            conflicts.append((dn, f"{SOURCE_PROPERTY} is empty; {origin}"))
        elif current != new:
            conflicts.append((dn, f"{SOURCE_PROPERTY} carries NEITHER the old nor the new value of the log; {origin}"))
        elif not UUID_VALUE.match(old):
            conflicts.append((dn, f"old value {old!r} is not a UUID"))
        else:
            plan.append((module, dn, representation, etag, old))

    for dn in skipped:
        logging.info(f"not a user or group, skipped: {dn}")
    for dn in missing:
        logging.warning(f"no longer in the IAM, skipped: {dn}")
    for dn, reason in conflicts:
        logging.error(f"CONFLICT, not touched: {dn}: {reason}")

    if limit is not None and len(plan) > limit:
        logging.info(f"limited to the first {limit} of {len(plan)} object(s).")
        plan = plan[:limit]

    written = 0
    for module, dn, representation, etag, old in plan:
        if dry_run:
            logging.info(f"DRY RUN - would write {old} to {TARGET_PROPERTY} of {dn}")
            continue
        representation['properties'][TARGET_PROPERTY] = old
        udm.put(module, representation, etag)
        stored, _ = udm.get(module, dn)
        value = str(((stored or {}).get('properties') or {}).get(TARGET_PROPERTY) or '').lower()
        if value != old:
            raise UdmError(f"{dn} carries {value!r} in {TARGET_PROPERTY} after writing {old!r}. Stopping.")
        logging.info(f"restored {old} to {TARGET_PROPERTY} of {dn}")
        written += 1

    logging.info(f"SUMMARY: {len(entries)} in the log below the scope, "
                 f"{len(plan)} {'to write' if dry_run else 'planned'}, {written} written, "
                 f"{done} already restored, {len(conflicts)} conflict(s), {len(missing)} missing, "
                 f"{len(skipped)} skipped.")
    if missing and not plan and not done:
        logging.error("None of the objects was found - wrong --url or --scope-dn?")
    return 1 if (conflicts or missing) else 0


def main(argv=None):
    logging.basicConfig(level=logging.INFO, format='%(levelname)-8s %(message)s')
    parser = argparse.ArgumentParser(description=f"Restore {TARGET_PROPERTY} from the migrations-pre log.")
    parser.add_argument('--log', required=True, help="Log of the migrations-pre Job of the 1.18 upgrade.")
    parser.add_argument('--scope-dn', default=DEFAULT_SCOPE_DN,
                        help=f"Only objects below this DN (default: {DEFAULT_SCOPE_DN}).")
    parser.add_argument('--url', default=os.environ.get('UDM_URL', DEFAULT_UDM_URL))
    parser.add_argument('--username', default=os.environ.get('UDM_USERNAME', DEFAULT_UDM_USERNAME))
    parser.add_argument('--dry-run', action='store_true', help="Report only, change nothing.")
    parser.add_argument('--limit', type=int, help="Write at most this many objects.")
    arguments = parser.parse_args(argv)
    password = os.environ.get('UDM_PASSWORD')
    if not password:
        parser.error("UDM_PASSWORD is not set.")
    if arguments.limit is not None and arguments.limit < 1:
        parser.error("--limit must be at least 1.")

    entries = read_log(arguments.log, arguments.scope_dn)
    if not entries:
        raise UdmError(f"No object below {arguments.scope_dn} found in the log - wrong file?")
    if arguments.dry_run:
        logging.info("DRY RUN - nothing is written.")
    udm = UdmClient(arguments.url, arguments.username, password)
    return restore(udm, entries, arguments.dry_run, arguments.limit)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (UdmError, OSError) as error:
        logging.error(error)
        sys.exit(1)
