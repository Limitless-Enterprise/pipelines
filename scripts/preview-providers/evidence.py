#!/usr/bin/env python3
from __future__ import annotations
import argparse
import json
import os
import subprocess
import tempfile

MARKER = '<!-- pr-preview-provider-lifecycle -->'


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--phase', required=True)
    ap.add_argument('--pr', default=os.environ.get('DEPLOYMENT_PR_NUMBER', ''))
    ap.add_argument('--context-json', default=os.environ.get('PREVIEW_CONTEXT_JSON', '{}'))
    ap.add_argument('--status-json', default=os.environ.get('PREVIEW_STATUS_JSON', '{}'))
    ap.add_argument('--comment', action='store_true')
    args = ap.parse_args()
    ctx = json.loads(args.context_json or '{}')
    status = json.loads(args.status_json or '{}')
    lines = [MARKER, '', f'## PR preview provider {args.phase} evidence', '']
    for key, label in [
        ('deployment_service_root', 'Service root'),
        ('railway_service_name', 'Railway service'),
        ('railway_environment', 'Railway PR environment'),
        ('source_repository', 'Source repo'),
        ('source_pr_number', 'Source PR'),
        ('source_sha', 'Source SHA'),
    ]:
        if ctx.get(key):
            lines.append(f'- {label}: `{ctx[key]}`')
    if status:
        lines += ['', '### Provider status']
        for k in sorted(status):
            lines.append(f'- {k}: `{status[k]}`')
    repo = os.environ.get('GITHUB_REPOSITORY', '')
    run = os.environ.get('GITHUB_RUN_ID', '')
    server = os.environ.get('GITHUB_SERVER_URL', 'https://github.com')
    lines += ['', f'Run: {server}/{repo}/actions/runs/{run}']
    body = '\n'.join(lines) + '\n'
    step = os.environ.get('GITHUB_STEP_SUMMARY')
    if step:
        with open(step, 'a', encoding='utf-8') as f:
            f.write(body + '\n')
    print(body)
    if args.comment and args.pr:
        with tempfile.NamedTemporaryFile('w', delete=False, encoding='utf-8') as f:
            f.write(body)
            p = f.name
        existing = subprocess.run(
            ['gh', 'pr', 'view', args.pr, '--json', 'comments', '--jq', f'.comments[] | select(.body | contains("{MARKER}")) | .id'],
            text=True,
            capture_output=True,
            check=False,
        )
        ids = (existing.stdout or '').strip().splitlines()
        if ids:
            subprocess.run(['gh', 'api', '--method', 'PATCH', f'repos/{repo}/issues/comments/{ids[-1]}', '--raw-field', f'body={body}'], check=True)
        else:
            subprocess.run(['gh', 'pr', 'comment', args.pr, '--body-file', p], check=True)


if __name__ == '__main__':
    main()
