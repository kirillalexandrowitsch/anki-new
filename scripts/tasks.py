#!/usr/bin/env python3
"""Local, dependency-free task ledger. Does not execute or certify app tests."""
import argparse
import collections
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LABELS = {'planned': 'Запланировано', 'in_progress': 'В работе', 'blocked': 'Заблокировано', 'done': 'Готово'}


def load(root):
    return json.loads((root / 'docs/backlog.json').read_text())


def report_errors(task, report):
    errors = []
    if report.get('taskID') != task['id']:
        errors.append('taskID отчёта не совпадает')
    if not isinstance(report.get('summary'), str) or not report['summary'].strip():
        errors.append('нужно описать результат summary')
    criteria = report.get('criteria', [])
    if not isinstance(criteria, list) or [c.get('text') for c in criteria if isinstance(c, dict)] != task['acceptance']:
        errors.append('criteria должны точно соответствовать acceptance задачи')
    elif not all(c.get('passed') is True and isinstance(c.get('evidence'), str) and c['evidence'].strip() for c in criteria):
        errors.append('каждый критерий требует passed=true и evidence')
    checks = report.get('checks')
    if not isinstance(checks, list) or not checks or not all(isinstance(c, dict) and isinstance(c.get('command'), str) and c['command'].strip() and c.get('result') == 'passed' and isinstance(c.get('details'), str) and c['details'].strip() for c in checks):
        errors.append('нужна хотя бы одна фактическая проверка command/result=passed/details')
    return errors


def validate(data, root):
    errors = []
    tasks = data.get('tasks', [])
    byid = {t['id']: t for t in tasks}
    if len(byid) != len(tasks):
        errors.append('повторные task IDs')
    visiting, visited = set(), set()
    def visit(tid):
        if tid in visiting:
            errors.append('цикл зависимостей: ' + tid)
            return
        if tid in visited:
            return
        visiting.add(tid)
        for dep in byid[tid]['dependencies']:
            if dep not in byid:
                errors.append(f'{tid}: отсутствует {dep}')
            else:
                visit(dep)
        visiting.remove(tid)
        visited.add(tid)
    for task in tasks:
        tid = task['id']
        visit(tid)
        if task['status'] not in LABELS:
            errors.append(f'{tid}: неизвестный статус')
        if not (root / f'docs/tasks/{tid}.md').is_file():
            errors.append(f'{tid}: нет карточки')
        if task['status'] in ('in_progress', 'done'):
            missing = [dep for dep in task['dependencies'] if dep in byid and byid[dep]['status'] != 'done']
            if missing:
                errors.append(f'{tid}: не завершены {", ".join(missing)}')
        if task['status'] == 'done':
            try:
                report = json.loads((root / f'docs/task-reports/{tid}.json').read_text())
                errors += [f'{tid}: {e}' for e in report_errors(task, report)]
            except (OSError, ValueError):
                errors.append(f'{tid}: нет корректного отчёта')
    if sum(t['status'] == 'in_progress' for t in tasks) > 1:
        errors.append('в общем checkout допускается одна активная задача')
    coverage = data.get('designCoverage', [])
    if len({c['stateID'] for c in coverage}) != len(coverage):
        errors.append('повторное состояние в designCoverage')
    for state in coverage:
        owner = byid.get(state['taskID'])
        if not owner or state['stateID'] not in owner['stateIDs']:
            errors.append('состояние без корректной owner task: ' + state['stateID'])
    return errors


def save(data, root):
    target = root / 'docs/backlog.json'
    with tempfile.NamedTemporaryFile('w', dir=target.parent, encoding='utf-8', delete=False) as f:
        tmp = Path(f.name)
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write('\n')
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, target)


def ready_tasks(data):
    byid = {t['id']: t for t in data['tasks']}
    return [t for t in data['tasks'] if t['status'] == 'planned' and all(byid[d]['status'] == 'done' for d in t['dependencies'])]


def sync(data, root):
    byid = {t['id']: t for t in data['tasks']}
    for t in data['tasks']:
        p = root / f'docs/tasks/{t["id"]}.md'
        text = p.read_text()
        text, count = re.subn(r'\*\*Статус:\*\* [^.]+\.', f'**Статус:** {LABELS[t["status"]].lower()}.', text, count=1)
        if count != 1:
            raise ValueError('не найдена строка статуса: ' + str(p))
        p.write_text(text)
    rows = ['# Реестр задач', '[Оглавление](README.md) · [Состояние](PROJECT_STATUS.md) · [Работа в отдельных чатах](AI_WORKFLOW.md)',
            'Статусы генерируются из backlog.json. S/M/L — относительная сложность, не срок. Полные шаги, зависимости и проверки — в карточке задачи. Номера стабильны; новые исправления могут добавляться без перенумерации.']
    for m in data['milestones']:
        rows += [f'## {m["id"]} · {m["title"]}', m['result'], '| Задача | Статус | Сложность | Зависимости |\n|---|---|---|---|']
        rows += [f'| [{t["id"]} · {t["title"]}](tasks/{t["id"]}.md) | {LABELS[t["status"]]} | {t["size"]} | {", ".join(t["dependencies"]) or "—"} |' for t in data['tasks'] if t['milestone'] == m['id']]
    (root / 'docs/TASKS.md').write_text('\n\n'.join(rows).replace('|\n\n|', '|\n|') + '\n')
    trace = root / 'docs/TRACEABILITY.md'
    text = trace.read_text().replace('«Запланировано» означает отсутствие реализации, а не потерю состояния из объёма.', 'Статусы синхронизируются из основной задачи; фактическая приёмка панели дополнительно отражается в отчёте задачи.')
    for c in data['designCoverage']:
        c['status'] = byid[c['taskID']]['status']
        pattern = r'(\| \[' + re.escape(c['stateID']) + r' · [^\n]+?\| \[' + c['taskID'] + r'\]\(tasks/' + c['taskID'] + r'\.md\) \| )[^|]+(\|)'
        text, count = re.subn(pattern, lambda m: m[1] + LABELS[c['status']] + ' ' + m[2], text)
        if count != 1:
            raise ValueError('строка трассировки не найдена: ' + c['stateID'])
    trace.write_text(text)
    counts = collections.Counter(t['status'] for t in data['tasks'])
    status = ['# Состояние проекта', '[Задачи](TASKS.md) · [Правила чатов](AI_WORKFLOW.md) · [Архитектура](ARCHITECTURE.md)',
              f'Всего задач: **{len(data["tasks"])}**. Готово: **{counts["done"]}**; в работе: **{counts["in_progress"]}**; заблокировано: **{counts["blocked"]}**; запланировано: **{counts["planned"]}**.',
              'Продукт: личное приложение для MacBook владельца, arm64. Обязательной публичной публикации и платной подписи нет. Дизайн и архитектура подготовлены; степень реализации определяется статусами и отчётами ниже.', '## Активные и заблокированные']
    active = [t for t in data['tasks'] if t['status'] in ('in_progress', 'blocked')]
    status += [f'- [{t["id"]} · {t["title"]}](tasks/{t["id"]}.md): {LABELS[t["status"]]}. {t.get("blockedReason", "")}' for t in active] or ['Нет.']
    status += ['## Следующие доступные задачи']
    ready = ready_tasks(data)
    status += [f'- [{t["id"]} · {t["title"]}](tasks/{t["id"]}.md)' for t in ready[:5]] or ['Нет новых готовых к старту задач; проверить активные/заблокированные или завершение плана.']
    status += ['## Контекст передачи', 'Запускать `python3 scripts/tasks.py status` и читать Git log/status перед реализацией. Другая задача in_progress запрещает одновременную правку checkout. Не доверять одному сообщению чата «готово» без отчёта и commit. История настройки репозитория: [PROJECT_SETUP.md](PROJECT_SETUP.md).',
               'Этот файл генерирует `scripts/tasks.py sync`; вручную менять backlog.json и контрактные карточки, затем синхронизировать. Commit hash текущей версии смотреть через `git log -1 --oneline`, чтобы сводка не содержала устаревающий собственный hash.']
    (root / 'docs/PROJECT_STATUS.md').write_text('\n\n'.join(status) + '\n')
    save(data, root)


@contextmanager
def locked(root):
    with (root / '.task-state.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['status', 'check', 'sync', 'start', 'init-report', 'finish', 'block'])
    parser.add_argument('task', nargs='?')
    parser.add_argument('--reason')
    args = parser.parse_args(argv)
    with locked(ROOT):
        data = load(ROOT)
        errors = validate(data, ROOT)
        if errors:
            raise ValueError('\n'.join(errors))
        if args.action == 'check':
            print(f'OK: {len(data["tasks"])} задач; {len(data["designCoverage"])} состояний; зависимости и отчёты корректны.')
            return
        if args.action == 'status':
            print(dict(collections.Counter(t['status'] for t in data['tasks'])))
            for t in data['tasks']:
                if t['status'] in ('in_progress', 'blocked'):
                    print(t['id'], t['status'], t.get('blockedReason', ''))
            print('Следующие доступные:', ', '.join(t['id'] for t in ready_tasks(data)[:5]) or 'нет')
            return
        if args.action == 'sync':
            sync(data, ROOT)
            print('Сводка, реестр, карточки и трассировка обновлены.')
            return
        task = next((t for t in data['tasks'] if t['id'] == args.task), None)
        if not task:
            raise ValueError('укажите существующую задачу, например T001')
        report_path = ROOT / f'docs/task-reports/{task["id"]}.json'
        if args.action == 'init-report':
            report = dict(taskID=task['id'], summary='', criteria=[dict(text=c, passed=False, evidence='') for c in task['acceptance']], checks=[], limitations=[])
            report_path.parent.mkdir(exist_ok=True)
            with report_path.open('x') as f:
                json.dump(report, f, ensure_ascii=False, indent=2)
                f.write('\n')
            print(report_path)
            return
        now = datetime.now(timezone.utc).isoformat()
        if args.action == 'start':
            if task['status'] not in ('planned', 'blocked'):
                raise ValueError('задача уже активна/готова; не захватывайте чужую работу')
            active = [t['id'] for t in data['tasks'] if t['status'] == 'in_progress']
            missing = [d for d in task['dependencies'] if next(t for t in data['tasks'] if t['id'] == d)['status'] != 'done']
            if active or missing:
                raise ValueError(f'активные задачи: {active}; незавершённые зависимости: {missing}')
            task.update(status='in_progress', startedAt=now)
            task.pop('blockedReason', None)
        elif args.action == 'block':
            if task['status'] != 'in_progress' or not args.reason or not args.reason.strip():
                raise ValueError('block требует in_progress и конкретную --reason')
            task.update(status='blocked', blockedReason=args.reason.strip(), updatedAt=now)
        elif args.action == 'finish':
            if task['status'] != 'in_progress':
                raise ValueError('finish требует in_progress')
            report = json.loads(report_path.read_text())
            errors = report_errors(task, report)
            if errors:
                raise ValueError('; '.join(errors))
            task.update(status='done', completedAt=now, report=f'docs/task-reports/{task["id"]}.json')
        errors = validate(data, ROOT)
        if errors:
            raise ValueError('; '.join(errors))
        sync(data, ROOT)
        print(task['id'], task['status'])


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        print('Ошибка:', error, file=sys.stderr)
        sys.exit(1)
