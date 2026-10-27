#!/usr/bin/env python3
"""Scan release inputs without printing secret values or reading the keychain.

Optionally compare exact credentials from a local file in memory. Reports contain
only filenames, categories, and counts. This is a guard, not a secret manager.
"""
import argparse
import pathlib
import re
import sys

SIGNATURES = re.compile(rb"sk-(?:proj-)?[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN(?: [A-Z]+)? PRIVATE KEY-----")
SENSITIVE_ASSIGNMENT = re.compile(r"(?im)^\s*[\w.-]*(?:api[_-]?key|secret|token|password)[\w.-]*\s*[:=]\s*([^\r\n]+)")
FORBIDDEN_PARTS = {'.git', '.dsh', '.swiftpm', 'node_modules', '__pycache__'}
FORBIDDEN_NAMES = {'.DS_Store', '.env', '.env.local', '.env.production', 'credentials.yaml', '.credentials.yaml', 'ai.configuration', 'workspace-state.json'}


def secrets_from(paths):
    values = set()
    for path in paths:
        p = pathlib.Path(path).expanduser()
        if not p.is_file():
            continue
        text = p.read_text(errors='replace')
        for match in SENSITIVE_ASSIGNMENT.finditer(text):
            value = match.group(1).split(' #', 1)[0].strip().strip('"\'')
            if len(value) >= 12 and not value.startswith(('$', '${', '<')):
                values.add(value.encode())
        # JSON credentials are also supported without ever printing contents.
        try:
            import json
            def walk(value):
                if isinstance(value, dict):
                    for key, item in value.items():
                        if re.search(r'api.?key|secret|token|password', key, re.I) and isinstance(item, str) and len(item) >= 12:
                            values.add(item.encode())
                        walk(item)
                elif isinstance(value, list):
                    for item in value:
                        walk(item)
            walk(json.loads(text))
        except (ValueError, TypeError):
            pass
    return values


def scan(root, secrets):
    findings = []
    count = 0
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root)
        if path.is_symlink():
            findings.append((str(relative), 'unexpected symlink'))
            continue
        if not path.is_file():
            continue
        count += 1
        if any(part in FORBIDDEN_PARTS for part in relative.parts) or path.name in FORBIDDEN_NAMES or path.name.startswith('.env.') or path.suffix in {'.key', '.p12', '.pfx', '.pem', '.keychain', '.keychain-db'}:
            findings.append((str(relative), 'private/configuration file'))
        tail = b''
        with path.open('rb') as stream:
            while chunk := stream.read(1024 * 1024):
                block = tail + chunk
                if SIGNATURES.search(block):
                    findings.append((str(relative), 'credential-shaped token'))
                    break
                if any(value in block for value in secrets):
                    findings.append((str(relative), 'exact local credential match'))
                    break
                tail = block[-max(1024, max(map(len, secrets), default=0)):]
    return count, findings


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('roots', nargs='+', type=pathlib.Path)
    parser.add_argument('--secrets-file', action='append', default=[])
    args = parser.parse_args()
    secrets = secrets_from(args.secrets_file)
    total = 0
    failed = False
    for root in args.roots:
        if not root.is_dir():
            parser.error('Scan roots must be existing directories')
        count, findings = scan(root, secrets)
        total += count
        for path, category in findings:
            print(f'FAIL {root.name}/{path}: {category}')
            failed = True
        print(f'{root.name}: {count} files, {len(findings)} findings')
    print(f'Checked {total} files; compared {len(secrets)} local credential values in memory. Secret values are never logged.')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
