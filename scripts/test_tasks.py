"""Tests of task bookkeeping only; they do not accept any real project task."""
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import shutil
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('task_ledger', Path(__file__).with_name('tasks.py'))
LEDGER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LEDGER)
SOURCE = Path(__file__).resolve().parents[1]


class LedgerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        shutil.copytree(SOURCE / 'docs', self.root / 'docs')
        LEDGER.ROOT = self.root

    def tearDown(self):
        self.temp.cleanup()
        LEDGER.ROOT = SOURCE

    def run_action(self, *args):
        with contextlib.redirect_stdout(io.StringIO()):
            LEDGER.main(list(args))

    def test_unfinished_dependency_rejected_without_change(self):
        before = (self.root / 'docs/backlog.json').read_bytes()
        with self.assertRaises(ValueError):
            self.run_action('start', 'T002')
        self.assertEqual(before, (self.root / 'docs/backlog.json').read_bytes())

    def test_incomplete_report_does_not_finish_task(self):
        self.run_action('start', 'T001')
        self.run_action('init-report', 'T001')
        with self.assertRaises(ValueError):
            self.run_action('finish', 'T001')
        self.assertEqual(LEDGER.load(self.root)['tasks'][0]['status'], 'in_progress')

    def test_completed_report_updates_all_derived_views(self):
        self.run_action('start', 'T001')
        self.run_action('init-report', 'T001')
        path = self.root / 'docs/task-reports/T001.json'
        report = json.loads(path.read_text())
        report['summary'] = 'Synthetic bookkeeping test, not a real app check.'
        for criterion in report['criteria']:
            criterion.update(passed=True, evidence='Synthetic fixture evidence.')
        report['checks'] = [dict(command='synthetic procedure', result='passed', details='test fixture only')]
        path.write_text(json.dumps(report))
        self.run_action('finish', 'T001')
        self.run_action('check')
        data = LEDGER.load(self.root)
        self.assertEqual(data['tasks'][0]['status'], 'done')
        self.assertEqual(LEDGER.ready_tasks(data)[0]['id'], 'T002')
        self.assertIn('**Статус:** готово.', (self.root / 'docs/tasks/T001.md').read_text())
        self.assertIn('Готово: **1**', (self.root / 'docs/PROJECT_STATUS.md').read_text())

    def test_second_active_task_and_duplicate_start_rejected(self):
        self.run_action('start', 'T001')
        with self.assertRaises(ValueError):
            self.run_action('start', 'T001')
        with self.assertRaises(ValueError):
            self.run_action('start', 'T002')

    def test_block_then_resume_and_report_no_overwrite(self):
        self.run_action('start', 'T001')
        self.run_action('block', 'T001', '--reason', 'fixture missing SDK')
        self.assertEqual(LEDGER.load(self.root)['tasks'][0]['status'], 'blocked')
        self.run_action('start', 'T001')
        self.run_action('init-report', 'T001')
        with self.assertRaises(FileExistsError):
            self.run_action('init-report', 'T001')

    def test_cycle_and_fake_pass_report_rejected(self):
        data = LEDGER.load(self.root)
        data['tasks'][0]['dependencies'] = ['T002']
        self.assertTrue(any('цикл' in e for e in LEDGER.validate(data, self.root)))
        task = LEDGER.load(self.root)['tasks'][0]
        report = dict(taskID='T001', summary='x', criteria=[dict(text=c, passed='true', evidence='x') for c in task['acceptance']], checks=[dict(command='x', result='passed', details='x')])
        self.assertTrue(LEDGER.report_errors(task, report))


if __name__ == '__main__':
    unittest.main()
