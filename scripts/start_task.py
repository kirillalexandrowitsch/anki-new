#!/usr/bin/env python3
"""Select one ready task from origin/dev and create its isolated Git branch."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()


def select_task(data, requested):
    byid = {t['id']: t for t in data['tasks']}
    active = [t['id'] for t in data['tasks'] if t['status'] == 'in_progress']
    assert not active, 'An active task must be resumed first: ' + ', '.join(active)
    available = [t for t in data['tasks'] if t['status'] == 'planned' and all(byid[d]['status'] == 'done' for d in t['dependencies'])]
    if requested == 'next':
        assert available, 'No ready planned task; inspect blocked tasks or project completion'
        return available[0]
    assert re.fullmatch(r'T\d{3,}', requested)
    assert requested in byid
    assert any(t['id'] == requested for t in available), 'Task is done, blocked or has unfinished dependencies'
    return byid[requested]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('task', nargs='?', default='next')
    args = parser.parse_args()
    assert not git('status', '--porcelain'), 'Save/commit current work before starting another task'
    subprocess.run(['git', 'fetch', 'origin', 'dev', 'stage', 'main'], cwd=ROOT, check=True)
    data = json.loads(git('show', 'origin/dev:docs/backlog.json'))
    task = select_task(data, args.task)
    branch = 'task/' + task['id']
    assert not git('branch', '--list', branch), 'Task branch already exists: inspect/resume it instead of overwriting'
    subprocess.run(['git', 'switch', '-c', branch, 'origin/dev'], cwd=ROOT, check=True)
    subprocess.run([sys.executable, 'scripts/tasks.py', 'start', task['id']], cwd=ROOT, check=True)
    print(f'Read docs/tasks/{task["id"]}.md, implement and verify. Do not stop after branch creation.')


if __name__ == '__main__':
    try:
        main()
    except (AssertionError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print('Task start stopped:', error, file=sys.stderr)
        sys.exit(1)
