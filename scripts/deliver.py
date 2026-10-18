#!/usr/bin/env python3
"""Deliver one completed task through protected PRs. Uses existing local gh login."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
REPO = 'kirillalexandrowitsch/anki-new'
REQUIRED = {'quality', 'macos'}


def command(*args, json_output=False, allow_error=False):
    result = subprocess.run(args, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode and not allow_error:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    if json_output:
        try:
            return json.loads(result.stdout)
        except ValueError:
            raise RuntimeError(result.stderr.strip() or 'Expected JSON from ' + args[0])
    return result.stdout.strip()


def api(path):
    return command('gh', 'api', f'repos/{REPO}' + ('/' + path if path else ''), json_output=True)


def branch_info(branch):
    return api('branches/' + quote(branch, safe=''))


def require_public_and_protection():
    repo = api('')
    assert not repo['private'] and not repo['disabled'], 'Public repository required for zero-cost hosted CI'
    for branch in ('dev', 'stage', 'main'):
        protection = api(f'branches/{branch}/protection')
        contexts = set(protection['required_status_checks']['contexts'])
        assert REQUIRED.issubset(contexts), 'Required checks are missing from branch protection'
        assert protection['enforce_admins']['enabled'], 'Branch protection must also apply to the owner'
        assert protection['allow_force_pushes']['enabled'] is False


def check_result(checks):
    selected = [c for c in checks if c.get('workflow') == 'CI']
    byname = {c['name']: c for c in selected}
    failed = [c['name'] for c in selected if c.get('bucket') in ('fail', 'cancel', 'skipping') or c.get('state') in ('SKIPPED', 'NEUTRAL', 'CANCELLED', 'TIMED_OUT', 'ACTION_REQUIRED', 'FAILURE')]
    if failed:
        raise RuntimeError('CI is not strictly green: ' + ', '.join(failed))
    return REQUIRED.issubset(byname) and all(c.get('bucket') == 'pass' and c.get('state') == 'SUCCESS' for c in selected)


def wait_pr(number, timeout):
    original = api(f'pulls/{number}')
    candidate = original['head']['sha']
    base = original['base']['sha']
    end = time.monotonic() + timeout
    last = None
    while time.monotonic() < end:
        pr = api(f'pulls/{number}')
        assert pr['head']['sha'] == candidate, 'PR changed while waiting; rerun on the new candidate'
        assert pr['base']['sha'] == base, 'Target branch changed; refresh and rerun the PR checks'
        try:
            checks = command('gh', 'pr', 'checks', str(number), '--repo', REPO, '--json', 'name,state,bucket,link,workflow', json_output=True, allow_error=True)
        except RuntimeError as error:
            if 'no checks reported' not in str(error).lower():
                raise
            checks = []
        summary = [(c['name'], c['state']) for c in checks if c.get('workflow') == 'CI']
        if summary != last:
            print(f'PR #{number}: {summary or "waiting for CI"}', flush=True)
            last = summary
        if check_result(checks):
            # Refuse to reuse obsolete checks if the target moved during a run.
            assert branch_info(pr['base']['ref'])['commit']['sha'] == base
            return pr
        time.sleep(10)
    raise TimeoutError(f'CI timeout for PR #{number}; do not bypass required checks')


def wait_branch(branch, timeout):
    sha = branch_info(branch)['commit']['sha']
    end = time.monotonic() + timeout
    last = None
    while time.monotonic() < end:
        runs = api(f'actions/runs?event=push&head_sha={sha}&per_page=30')['workflow_runs']
        candidates = [r for r in runs if r['name'] == 'CI' and r['head_branch'] == branch]
        if candidates:
            run = max(candidates, key=lambda r: r['id'])
            state = (run['id'], run['status'], run['conclusion'])
            if state != last:
                print(f'{branch}: CI {state}', flush=True)
                last = state
            if run['status'] == 'completed':
                assert run['conclusion'] == 'success', f'{branch}: push pipeline failed'
                jobs = api(f'actions/runs/{run["id"]}/jobs?per_page=100')['jobs']
                assert REQUIRED.issubset({j['name'] for j in jobs})
                assert all(j['conclusion'] == 'success' for j in jobs), 'Skipped/neutral jobs do not count as success'
                return run
        time.sleep(10)
    raise TimeoutError(f'{branch}: post-merge CI timeout')


def ensure_pr(head, base, title, body):
    source_sha = branch_info(head)['commit']['sha']
    existing = api(f'pulls?state=all&head={REPO.split("/")[0]}:{head}&base={base}&per_page=100')
    for pr in existing:
        if pr['head']['sha'] == source_sha and (pr['state'] == 'open' or pr.get('merged_at')):
            print('PR:', pr['html_url'], flush=True)
            return pr
    with tempfile.NamedTemporaryFile('w', encoding='utf-8') as file:
        file.write(body)
        file.flush()
        url = command('gh', 'pr', 'create', '--repo', REPO, '--base', base, '--head', head, '--title', title, '--body-file', file.name)
    print('Created PR:', url, flush=True)
    return api(f'pulls/{url.rsplit("/", 1)[1]}')


def merge_checked(pr, timeout):
    number = pr['number']
    if pr.get('merged_at'):
        print(f'PR #{number} is already merged; continuing safely', flush=True)
        return
    candidate = wait_pr(number, timeout)
    assert candidate['head']['repo']['full_name'] == REPO
    assert candidate['user']['login'] == REPO.split('/')[0]
    require_public_and_protection()
    print(f'Merging #{number} at {candidate["head"]["sha"]}', flush=True)
    command('gh', 'pr', 'merge', str(number), '--repo', REPO, '--merge', '--match-head-commit', candidate['head']['sha'])
    merged = api(f'pulls/{number}')
    assert merged['merged_at'], 'GitHub did not confirm the merge'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    kind = parser.add_mutually_exclusive_group(required=True)
    kind.add_argument('--task')
    kind.add_argument('--maintenance')
    parser.add_argument('--timeout', type=int, default=1800)
    args = parser.parse_args()
    assert not command('git', 'status', '--porcelain'), 'Commit the complete result first; working tree must be clean'
    require_public_and_protection()
    if args.task:
        assert re.fullmatch(r'T\d{3,}', args.task)
        head = 'task/' + args.task
        data = json.loads((ROOT / 'docs/backlog.json').read_text())
        task = next(t for t in data['tasks'] if t['id'] == args.task)
        assert task['status'] == 'done'
        command(sys.executable, 'scripts/tasks.py', 'check')
        title = f'{args.task}: {task["title"]}'
        report = f'docs/task-reports/{args.task}.json'
    else:
        assert re.fullmatch('[a-z0-9-]+', args.maintenance)
        head = 'maintenance/' + args.maintenance
        title = 'Maintenance: ' + args.maintenance
        report = f'docs/automation-reports/{args.maintenance}.json'
        assert (ROOT / report).is_file()
    branch = command('git', 'branch', '--show-current')
    assert branch == head, f'Expected {head}; current branch is {branch}'
    command('git', 'push', '-u', 'origin', head)
    evidence = json.loads((ROOT / report).read_text())
    validation = '\n'.join(f'- `{c["command"]}` — {c["result"]}: {c["details"]}' for c in evidence['checks'])
    body = f'{evidence["summary"]}\n\nEvidence: `{report}`.\n\nValidation:\n{validation}\n\nMerge requires quality and macos to succeed. Skipped, neutral and failed checks are not accepted.\n'
    pr = ensure_pr(head, 'dev', title, body)
    merge_checked(pr, args.timeout)
    wait_branch('dev', args.timeout)
    for source, target in [('dev', 'stage'), ('stage', 'main')]:
        pr = ensure_pr(source, target, f'Promote {source} to {target}: {title}', body)
        merge_checked(pr, args.timeout)
        wait_branch(target, args.timeout)
    command('git', 'fetch', 'origin', 'dev', 'stage', 'main')
    print('Delivered through dev -> stage -> main. Next task must start from origin/dev.', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (AssertionError, RuntimeError, OSError, ValueError, TimeoutError) as error:
        print('Delivery stopped:', error, file=sys.stderr)
        sys.exit(1)
