import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import check
import ci


class LocalCheckTests(unittest.TestCase):
    def test_failure_keeps_location_and_test_id_without_assertion_values_or_paths(self):
        # Real failing subprocess, including deliberately sensitive-looking payloads.
        source = """import sys
print('/Users/private/Collection.sqlite: SELECT front FROM notes: Секретный текст')
print('/Users/private/SyntheticFixtureTests.swift:42:7: error: secret token=abcd')
print('Test syntheticFailure() recorded an issue: (actual → личный ответ) != expected')
sys.exit(17)
"""
        result = check.run_stage('failure-probe', [sys.executable, '-c', source],
            inventory=({'SyntheticFixtureTests.swift'}, {'syntheticFailure'}))
        # The saved command in a production check is fixed tool arguments, never -c
        # with source text. Remove the probe command before testing diagnostics.
        result.pop('command')
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'summary.json'
            path.write_text(json.dumps(result))
            text = path.read_text()
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['exitCode'], 17)
        self.assertEqual(result['locations'], [dict(file='SyntheticFixtureTests.swift', line=42, column=7)])
        self.assertEqual(result['failedTests'], ['syntheticFailure'])
        for private in ['Секретный', 'личный', '/Users', 'Collection.sqlite', 'abcd', 'actual']:
            self.assertNotIn(private, text)

    def test_xctest_line_without_column_keeps_only_allowlisted_source_location(self):
        diagnostics = check.Diagnostics(({'AppShellUITests.swift'}, {'testLibrary'}))
        diagnostics.consume('/Users/private/AppShellUITests.swift:234: error: -[Tests testLibrary]: '
                            'XCTAssertTrue failed - private collection text\n'
                            '/Users/private/Unknown.swift:99: error: secret\n')
        result = diagnostics.result()
        self.assertEqual(result['locations'], [dict(file='AppShellUITests.swift', line=234, column=0)])
        self.assertEqual(result['failedTests'], ['testLibrary'])
        for private in ['private', '/Users', 'collection', 'Unknown', 'secret']:
            self.assertNotIn(private, json.dumps(result))

    def test_timeout_preserves_failure_without_raw_output(self):
        result = check.run_stage('timeout', [sys.executable, '-c', 'import time; time.sleep(30)'], timeout=0.05)
        self.assertEqual(result['status'], 'failed')
        self.assertIn('timeout', result['categories'])

    def test_missing_tool_is_a_technical_failure(self):
        result = check.run_stage('missing', ['/nonexistent/anki-new-check-tool'])
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['categories'], ['tool-unavailable'])

    def test_diagnostics_allowlist_rejects_unknown_names_and_freeform_messages(self):
        diagnostics = check.Diagnostics(({'Known.swift'}, {'knownTest'}))
        diagnostics.consume('Private.swift:1:2: error: secret\nTest privateText() failed\n'
                            'Test knownTest() failed\n✔ Test run with 89 tests passed\n')
        result = diagnostics.result()
        self.assertEqual(result['locations'], [])
        self.assertEqual(result['failedTests'], ['knownTest'])
        self.assertEqual(result['testCounts'], [89])

    def test_offline_preflight_rejects_missing_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            resolved = root / 'Package.resolved'
            resolved.write_text(json.dumps({'pins': []}))
            with self.assertRaisesRegex(ValueError, 'missing-checkouts'):
                check.require_resolved_checkouts(resolved, root / 'missing')

    def test_ui_control_diagnostics_keep_only_bounded_numeric_counts(self):
        diagnostics = check.Diagnostics((set(), set()))
        diagnostics.consume('ANKI_UI_NOTIFICATIONS matches=2 hittable=1 frames=1\n'
                            'ANKI_UI_NOTIFICATIONS matches=2 hittable=1 frames=1 private text\n'
                            'ANKI_UI_NOTIFICATIONS matches=1000 hittable=1 frames=1\n'
                            'AX label=private collection contents\n')
        result = diagnostics.result()
        self.assertEqual(result['notificationControls'], [dict(matches=2, hittable=1, frames=1)])
        self.assertNotIn('private', json.dumps(result))

    def test_ci_uses_shared_check_with_app_tests(self):
        with patch.object(ci, 'run') as run:
            ci.check_app(ci.ROOT, ci.validate_workflow(ci.ROOT))
        run.assert_called_once_with(sys.executable, 'scripts/check.py', '--resolve', '--app-tests')


if __name__ == '__main__':
    unittest.main()
