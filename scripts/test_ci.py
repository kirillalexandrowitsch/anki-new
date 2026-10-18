import copy
import json
from pathlib import Path
import tempfile
import unittest

import ci
import deliver
import start_task


class CIPolicyTests(unittest.TestCase):
    def setUp(self):
        self.data = json.loads((ci.ROOT / 'docs/backlog.json').read_text())
        self.event = {'repository': {'full_name': deliver.REPO, 'owner': {'login': 'kirillalexandrowitsch'}}, 'pull_request': {'user': {'login': 'kirillalexandrowitsch'}, 'head': {'repo': {'full_name': deliver.REPO}, 'ref': 'task/T001'}, 'base': {'ref': 'dev'}}}

    def test_task_route_requires_complete_report_and_unchanged_criteria(self):
        new = copy.deepcopy(self.data)
        new['tasks'][0]['status'] = 'done'
        files = ['docs/backlog.json', 'docs/task-reports/T001.json']
        self.assertEqual(ci.validate_pr_route(self.event, new, self.data, files), 'T001')
        new['tasks'][0]['acceptance'] = []
        with self.assertRaises(AssertionError):
            ci.validate_pr_route(self.event, new, self.data, files)

    def test_task_requires_done_and_report_change(self):
        with self.assertRaises(AssertionError):
            ci.validate_pr_route(self.event, self.data, self.data, [])

    def test_foreign_pr_not_eligible_for_autonomous_merge(self):
        self.event['pull_request']['head']['repo']['full_name'] = 'someone/fork'
        with self.assertRaises(AssertionError):
            ci.validate_pr_route(self.event, self.data, self.data, [])

    def test_only_forward_promotions(self):
        for head, base in [('dev', 'stage'), ('stage', 'main')]:
            self.event['pull_request']['head']['ref'] = head
            self.event['pull_request']['base']['ref'] = base
            self.assertEqual(ci.validate_pr_route(self.event, self.data, self.data, []), 'promotion')
        self.event['pull_request']['head']['ref'] = 'dev'
        self.event['pull_request']['base']['ref'] = 'main'
        with self.assertRaises(AssertionError):
            ci.validate_pr_route(self.event, self.data, self.data, [])

    def test_maintenance_cannot_implement_app(self):
        self.event['pull_request']['head']['ref'] = 'maintenance/fix-docs'
        self.assertEqual(ci.validate_pr_route(self.event, self.data, self.data, ['docs/README.md']), 'maintenance')
        with self.assertRaises(AssertionError):
            ci.validate_pr_route(self.event, self.data, self.data, ['App/Main.swift'])

    def test_workflow_disallows_paid_runners_and_error_bypass(self):
        ci.validate_workflow(ci.ROOT)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / '.github/workflows').mkdir(parents=True)
            policy = (ci.ROOT / '.github/automation.json').read_text()
            (root / '.github/automation.json').write_text(policy)
            workflow = json.loads((ci.ROOT / '.github/workflows/ci.yml').read_text())
            workflow['jobs']['macos']['runs-on'] = 'macos-latest-large'
            (root / '.github/workflows/ci.yml').write_text(json.dumps(workflow))
            with self.assertRaises(AssertionError):
                ci.validate_workflow(root)

    def test_merge_requires_both_checks_exact_success(self):
        green = [dict(name=name, workflow='CI', state='SUCCESS', bucket='pass') for name in deliver.REQUIRED]
        self.assertTrue(deliver.check_result(green))
        self.assertFalse(deliver.check_result(green[:1]))
        self.assertFalse(deliver.check_result([]))
        for state, bucket in [('SKIPPED', 'skipping'), ('NEUTRAL', 'pass'), ('FAILURE', 'fail'), ('CANCELLED', 'cancel')]:
            changed = copy.deepcopy(green)
            changed[0].update(state=state, bucket=bucket)
            with self.assertRaises(RuntimeError):
                deliver.check_result(changed)

    def test_pending_is_not_success(self):
        checks = [dict(name=name, workflow='CI', state='PENDING', bucket='pending') for name in deliver.REQUIRED]
        self.assertFalse(deliver.check_result(checks))

    def test_start_selects_ready_dependency_order(self):
        self.assertEqual(start_task.select_task(self.data, 'next')['id'], 'T001')
        with self.assertRaises(AssertionError):
            start_task.select_task(self.data, 'T002')

    def test_start_refuses_parallel_work(self):
        self.data['tasks'][0]['status'] = 'in_progress'
        with self.assertRaises(AssertionError):
            start_task.select_task(self.data, 'next')

    def test_macos_app_not_allowed_to_silently_skip_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'docs').mkdir()
            (root / 'AnkiNew.xcodeproj').mkdir()
            (root / 'docs/backlog.json').write_text(json.dumps(self.data))
            policy = {'app': {'project': None, 'scheme': None, 'packagePaths': []}}
            with self.assertRaises(AssertionError):
                ci.check_app(root, policy)


if __name__ == '__main__':
    unittest.main()
