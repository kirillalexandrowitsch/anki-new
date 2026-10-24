#!/usr/bin/env python3
"""Local synthetic checks. Resolve explicitly once; subsequent runs never update pins.

Only allowlisted technical diagnostics survive a subprocess. Raw stdout/stderr,
SQLite rows, assertion values, user paths and xcresults are not exported or saved.
"""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = 'Packages/CardsKit'
DERIVED = 'build/check-derived'
CLONES = 'build/check-packages'
FIXTURE = ROOT / PACKAGE / 'Tests/CardsInfrastructureTests/Fixtures/synthetic-v1'
OFFLINE_PROFILE = '(version 1)(allow default)(deny network*)'


def source_inventory(root=ROOT):
    files, tests = set(), set()
    for folder in ['App', 'AppTests', 'UITests', 'Packages/CardsKit/Tests', 'Packages/CardsKit/Sources', 'scripts']:
        for path in (root / folder).rglob('*'):
            if path.suffix not in ('.swift', '.py'):
                continue
            files.add(path.name)
            tests.update(re.findall(r'\bfunc\s+([A-Za-z_][A-Za-z_0-9]*)\s*\(', path.read_text()))
            tests.update(re.findall(r'\bdef\s+(test_[A-Za-z_0-9]+)\s*\(', path.read_text()))
    return files, tests


class Diagnostics:
    def __init__(self, inventory=None):
        self.files, self.tests = inventory or source_inventory()
        self.locations = set()
        self.failed_tests = set()
        self.categories = set()
        self.test_counts = set()
        self.fingerprints = set()
        self.notification_controls = set()

    def consume(self, output):
        # No redaction heuristic: free-form messages/values never enter the result.
        for line in output.splitlines():
            failure = 'error:' in line or re.search(r'\bfailed\b', line.lower()) or 'recorded an issue' in line
            if failure:
                for name, row, column in re.findall(r'([A-Za-z_][A-Za-z_0-9]*\.(?:swift|py)):(\d+):(?:(\d+):)?', line):
                    if name in self.files:
                        self.locations.add((name, int(row), int(column or 0)))
                for name in re.findall(r'\b([A-Za-z_][A-Za-z_0-9]*)\(', line):
                    if name in self.tests:
                        self.failed_tests.add(name)
                for name in re.findall(r'\b(test[A-Za-z_0-9]+)\b', line):
                    if name in self.tests:
                        self.failed_tests.add(name)
            for token, category in [('error:', 'compiler-or-tool-error'), ('recorded an issue', 'test-issue'),
                                    ('Operation not permitted', 'permission'),
                                    ('Could not resolve', 'dependency-resolution'), ('timed out', 'timeout')]:
                if token in line:
                    self.categories.add(category)
            if re.search(r'\bfailed\b', line):
                self.categories.add('failure')
            for count in re.findall(r'Test run with (\d+) tests?', line):
                self.test_counts.add(int(count))
            for count in re.findall(r'Executed (\d+) tests?, with \d+ failures?', line):
                self.test_counts.add(int(count))
            digest = re.fullmatch(r'ANKI_FIXTURE_V1_SHA256=([a-f0-9]{64})', line.strip())
            if digest:
                self.fingerprints.add(digest[1])
            control = re.fullmatch(r'ANKI_UI_NOTIFICATIONS matches=(\d{1,3}) hittable=(\d{1,3}) frames=(\d{1,3})', line.strip())
            if control:
                self.notification_controls.add(tuple(map(int, control.groups())))

    def result(self):
        return dict(locations=[dict(file=f, line=r, column=c) for f, r, c in sorted(self.locations)],
                    failedTests=sorted(self.failed_tests), categories=sorted(self.categories),
                    testCounts=sorted(self.test_counts), fixtureFingerprints=sorted(self.fingerprints),
                    notificationControls=[dict(matches=m, hittable=h, frames=f)
                                          for m, h, f in sorted(self.notification_controls)])


def run_stage(phase, command, *, deny_network=False, timeout=1200, inventory=None):
    diagnostics = Diagnostics(inventory)
    environment = {key: value for key, value in os.environ.items() if not key.startswith('ANKI_')}
    actual = command
    if deny_network:
        actual = ['/usr/bin/sandbox-exec', '-p', OFFLINE_PROFILE, *command]
    record = dict(phase=phase, status='failed', command=command, exitCode=None)
    try:
        with subprocess.Popen(actual, cwd=ROOT, env=environment, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, start_new_session=True) as child:
            try:
                output, _ = child.communicate(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                output, _ = child.communicate()
                diagnostics.categories.add('timeout')
            diagnostics.consume(output.decode('utf-8', errors='replace'))
            record['exitCode'] = child.returncode
            if child.returncode == 0 and 'timeout' not in diagnostics.categories:
                record['status'] = 'passed'
    except OSError:
        diagnostics.categories.add('tool-unavailable')
    record.update(diagnostics.result())
    return record


def require_resolved_checkouts(resolved, checkouts):
    """Fail before tool launch if a pinned checkout is missing or has another HEAD."""
    pins = json.loads(resolved.read_text())['pins']
    if not checkouts.is_dir():
        raise ValueError('missing-checkouts-run-resolve')
    directories = {p.name.lower(): p for p in checkouts.iterdir() if p.is_dir()}
    for pin in pins:
        directory = directories.get(pin['identity'])
        if directory is None:
            raise ValueError('missing-checkouts-run-resolve')
        revision = subprocess.run(['git', '-C', str(directory), 'rev-parse', 'HEAD'],
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False).stdout.decode().strip()
        if revision != pin['state']['revision']:
            raise ValueError('checkout-revision-mismatch-run-resolve')


def execute(args, summary):
    policy = json.loads((ROOT / '.github/automation.json').read_text())
    app = policy['app']
    assert app['packagePaths'] == [PACKAGE], 'Register additional packages in local checks'
    base = ['xcodebuild', '-project', app['project'], '-scheme', app['scheme'],
            '-clonedSourcePackagesDirPath', CLONES]

    def stage(phase, command, deny=False):
        print(f'{phase}: running', flush=True)
        result = run_stage(phase, command, deny_network=deny)
        summary['checks'].append(result)
        print(f'{phase}: {result["status"]} (exit {result["exitCode"]})', flush=True)
        return result['status'] == 'passed'

    if args.resolve:
        if not stage('resolve-package', ['swift', 'package', '--package-path', PACKAGE, 'resolve']):
            return False
        if not stage('resolve-app', [*base, '-resolvePackageDependencies', '-onlyUsePackageVersionsFromResolvedFile']):
            return False
    require_resolved_checkouts(ROOT / PACKAGE / 'Package.resolved', ROOT / PACKAGE / '.build/checkouts')
    require_resolved_checkouts(ROOT / 'AnkiNew.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
                               ROOT / CLONES / 'checkouts')
    swift = ['swift', 'test', '--package-path', PACKAGE, '--skip-update', '--disable-automatic-resolution']
    if args.deny_network:
        # SwiftPM otherwise nests sandbox-exec for manifests, forbidden by macOS.
        # The outer profile still denies network to the entire compiler/test process tree.
        swift += ['--disable-sandbox', '-Xswiftc', '-disable-sandbox']
    if not stage('package-tests', swift, args.deny_network):
        return False
    expected = (FIXTURE / 'fingerprint.sha256').read_text().strip()
    if summary['checks'][-1]['fixtureFingerprints'] != [expected]:
        summary['failure'] = 'fixture-fingerprint-missing-or-changed'
        return False
    # xcresult can contain assertion values/screenshots. Keep it only in a disposable
    # directory during testing; only the allowlisted summary persists on failure.
    with tempfile.TemporaryDirectory(prefix='anki-new-check-results-') as temporary:
        app_command = [*base, 'test' if args.app_tests else 'build',
                       '-destination', 'platform=macOS,arch=arm64', '-derivedDataPath', DERIVED,
                       '-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile',
                       '-skipPackageUpdates', 'CODE_SIGN_IDENTITY=-', 'DEVELOPMENT_TEAM=']
        if args.deny_network:
            # Same nesting restriction as SwiftPM; the enclosing OS sandbox
            # applies to Xcode, manifest executables and build/test children.
            app_command += ['-IDEPackageSupportDisableManifestSandbox=YES',
                            'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox']
        app_command += ['-resultBundlePath', str(Path(temporary) / 'app.xcresult')]
        passed = stage('app-tests' if args.app_tests else 'app-build', app_command, args.deny_network)
        # Do not persist even the temporary result path.
        summary['checks'][-1]['command'] = [arg.replace(temporary, '$TEMP') for arg in app_command]
    return passed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resolve', action='store_true', help='Explicit online preparation of pinned dependencies')
    parser.add_argument('--app-tests', action='store_true', help='Also run app unit/UI tests; requires graphical login')
    parser.add_argument('--deny-network', action='store_true', help='Enforce OS network denial during package tests/app check')
    args = parser.parse_args()
    # A fresh directory preserves prior failures; no raw tool output is written here.
    (ROOT / 'build/checks').mkdir(parents=True, exist_ok=True)
    report = Path(tempfile.mkdtemp(prefix='run-', dir=ROOT / 'build/checks')) / 'summary.json'
    summary = dict(schemaVersion=1, fixtureSeed=12, status='failed', networkDenied=args.deny_network, checks=[])
    try:
        if sys.platform != 'darwin':
            summary['failure'] = 'macos-required'
        elif execute(args, summary):
            summary['status'] = 'passed'
    except (OSError, ValueError, AssertionError):
        # No exception strings: they may contain source data or absolute paths.
        summary['failure'] = 'preflight-failed-check-pinned-caches-and-run-with-resolve'
    finally:
        report.write_text(json.dumps(summary, indent=2) + '\n')
        # CI runners are disposable and budget policy forbids artifact uploads.
        # Print the same allowlisted summary so failed checks remain diagnosable.
        print(json.dumps(summary, indent=2), flush=True)
        print(f'{summary["status"]}: {report.relative_to(ROOT)}', flush=True)
    return 0 if summary['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
