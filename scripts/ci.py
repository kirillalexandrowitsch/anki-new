#!/usr/bin/env python3
"""Versioned CI checks; no paid services, third-party Python modules or secrets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import shutil
import tempfile
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]


def validate_generated_state(root):
    import tasks
    with tempfile.TemporaryDirectory() as tmp:
        copy_root = Path(tmp)
        shutil.copytree(root / 'docs', copy_root / 'docs')
        data = tasks.load(copy_root)
        tasks.sync(data, copy_root)
        paths = ['docs/backlog.json', 'docs/TASKS.md', 'docs/PROJECT_STATUS.md', 'docs/TRACEABILITY.md']
        paths += [f'docs/tasks/{t["id"]}.md' for t in data['tasks']]
        for path in paths:
            assert (root / path).read_bytes() == (copy_root / path).read_bytes(), f'Run scripts/tasks.py sync: stale {path}'


def run(*args, cwd=ROOT):
    print('+', ' '.join(map(str, args)), flush=True)
    subprocess.run(args, cwd=cwd, check=True)


def validate_workflow(root):
    policy = json.loads((root / '.github/automation.json').read_text())
    workflow = json.loads((root / '.github/workflows/ci.yml').read_text())
    # JSON is a YAML subset. Keeping this file in JSON makes validation dependency-free.
    assert workflow['name'] == policy['workflowName'] == 'CI'
    assert workflow['permissions'] == {'contents': 'read'}
    assert set(workflow['jobs']) == set(policy['requiredChecks']) == {'quality', 'macos'}
    assert workflow['on']['pull_request']['branches'] == ['dev', 'stage', 'main']
    for name, runner in [('quality', 'ubuntu-24.04'), ('macos', 'macos-15')]:
        job = workflow['jobs'][name]
        assert job['name'] == name and job['runs-on'] == runner
        assert job['if'] == '${{ !github.event.repository.private }}'
        assert job['steps'] == [
            {'uses': 'actions/checkout@' + policy['checkoutSHA'], 'with': {'fetch-depth': 0, 'persist-credentials': False}},
            {'name': job['steps'][1]['name'], 'run': f'python3 scripts/ci.py {name}'}
        ]
        assert 'continue-on-error' not in job and 'permissions' not in job
    assert re.fullmatch('[a-f0-9]{40}', policy['checkoutSHA'])
    assert policy['publicRepositoryRequired'] is True
    assert policy['allowedRunners'] == ['ubuntu-24.04', 'macos-15']
    return policy


def validate_links_and_assets(root):
    count = 0
    for path in [root / 'README.md', root / 'AGENTS.md', *list((root / 'docs').rglob('*.md'))]:
        for href in re.findall(r'\]\(([^)]+)\)', path.read_text()):
            url = urlsplit(href)
            if url.scheme or url.netloc:
                continue
            assert (path.parent / unquote(url.path)).is_file(), f'{path}: {href}'
            count += 1
    manifest = json.loads((root / 'design-references/manifest.json').read_text())
    assets = manifest['base'] + manifest['sheets']
    assert len(assets) == 48 and sum(len(a.get('panels', [])) for a in assets) == 168
    for asset in assets:
        data = (root / 'design-references' / asset['file']).read_bytes()
        assert data[:8] == b'\x89PNG\r\n\x1a\n'
        assert hashlib.sha256(data).hexdigest() == asset['sha256'], asset['file']
    print(f'Local links: {count}; design PNG hashes: 48/48', flush=True)


def validate_pr_route(event, current, baseline, changed_files):
    pr = event['pull_request']
    repo = event['repository']['full_name']
    owner = event['repository']['owner']['login']
    assert repo == 'kirillalexandrowitsch/anki-new'
    assert pr['head']['repo']['full_name'] == repo, 'Automatic promotion is only for this repository'
    assert pr['user']['login'] == owner, 'Only owner-originated PRs use the autonomous route'
    head, base = pr['head']['ref'], pr['base']['ref']
    if (head, base) in [('dev', 'stage'), ('stage', 'main')]:
        return 'promotion'
    assert base == 'dev', f'Unsupported PR route: {head} -> {base}'
    if head.startswith('maintenance/'):
        assert all(p.startswith(('docs/', 'scripts/', '.github/')) or p in ('AGENTS.md', 'README.md', '.gitignore', '.gitattributes') for p in changed_files), 'Maintenance branch cannot implement app sources'
        return 'maintenance'
    match = re.fullmatch(r'task/(T\d{3,})', head)
    assert match, 'Use task/Txxx -> dev'
    tid = match[1]
    old = {t['id']: t for t in baseline['tasks']}
    new = {t['id']: t for t in current['tasks']}
    assert tid in old and tid in new
    assert new[tid]['status'] == 'done', 'Task must meet all criteria before delivery'
    assert new[tid]['acceptance'] == old[tid]['acceptance'], 'Do not weaken acceptance to complete a task'
    assert new[tid]['dependencies'] == old[tid]['dependencies'], 'Do not bypass dependencies'
    assert f'docs/task-reports/{tid}.json' in changed_files
    if old[tid]['status'] != 'done':
        assert 'docs/backlog.json' in changed_files
    for other in old.keys() & new.keys():
        if other != tid:
            assert new[other]['status'] == old[other]['status'], 'One implementation task per PR'
    return tid + (' repair' if old[tid]['status'] == 'done' else '')


def check_pr(root):
    if os.environ.get('GITHUB_EVENT_NAME') != 'pull_request':
        print('PR route validation: not a pull-request event')
        return
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    base = event['pull_request']['base']['sha']
    assert re.fullmatch('[a-f0-9]{40}', base)
    baseline = json.loads(subprocess.check_output(['git', 'show', f'{base}:docs/backlog.json'], cwd=root))
    current = json.loads((root / 'docs/backlog.json').read_text())
    diff = subprocess.check_output(['git', 'diff', '--name-only', f'{base}...HEAD'], cwd=root, text=True).splitlines()
    print('PR route:', validate_pr_route(event, current, baseline, diff))
    if event['pull_request']['head']['ref'].startswith('maintenance/'):
        slug = event['pull_request']['head']['ref'].removeprefix('maintenance/')
        assert re.fullmatch('[a-z0-9-]+', slug)
        report_path = root / f'docs/automation-reports/{slug}.json'
        report = json.loads(report_path.read_text())
        assert report.get('summary') and report.get('checks')
        assert all(c.get('result') == 'passed' and c.get('command') and c.get('details') for c in report['checks'])


def check_app(root, policy):
    data = json.loads((root / 'docs/backlog.json').read_text())
    app = policy['app']
    scaffold_done = next(t for t in data['tasks'] if t['id'] == 'T002')['status'] == 'done'
    projects = list(root.glob('*.xcodeproj'))
    if projects or scaffold_done or app['project']:
        assert app['project'] and app['scheme'], 'T002 must configure project and shared scheme in automation.json'
        assert (root / app['project']).is_dir(), 'Configured Xcode project is missing'
        run('xcodebuild', 'test', '-project', app['project'], '-scheme', app['scheme'], '-destination', 'platform=macOS', '-derivedDataPath', str(root / 'build/ci'), 'CODE_SIGN_IDENTITY=-', 'DEVELOPMENT_TEAM=')
    else:
        print('Current scope: documentation/automation; app target does not exist yet. No app-build success claimed.', flush=True)
    for package in app['packagePaths']:
        assert (root / package / 'Package.swift').is_file()
        run('swift', 'test', cwd=root / package)
    discovered = {str(p.parent.relative_to(root)) for p in (root / 'Packages').glob('*/Package.swift')} if (root / 'Packages').is_dir() else set()
    assert discovered.issubset(set(app['packagePaths'])), 'Register new Swift packages in CI; do not omit tests'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('job', choices=['quality', 'macos'])
    args = parser.parse_args()
    policy = validate_workflow(ROOT)
    validate_generated_state(ROOT)
    run(sys.executable, 'scripts/tasks.py', 'check')
    run(sys.executable, '-m', 'unittest', 'discover', '-s', 'scripts', '-p', 'test_*.py', '-v')
    validate_links_and_assets(ROOT)
    check_pr(ROOT)
    if args.job == 'macos':
        assert sys.platform == 'darwin', 'macos checks must run on a Mac'
        run('xcodebuild', '-version')
        check_app(ROOT, policy)
    print(f'{args.job}: passed', flush=True)


if __name__ == '__main__':
    main()
