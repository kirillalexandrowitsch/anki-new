#!/usr/bin/env python3
"""Build and launch a disposable macOS app, without packages or signing accounts."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile


SOURCE = '''import AppKit

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Anki New — environment smoke"
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            guard window.isVisible, self.window != nil else { exit(1) }
            print("ANKI_NEW_WINDOW_VISIBLE")
            NSApplication.shared.terminate(nil)
        }
    }
}

@main
struct EnvironmentSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = Delegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
'''


def run(*args, timeout=60):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{args[0]} exited {result.returncode}:\n{result.stdout}')
    return result.stdout.strip()


def create_project(root):
    """Use Apple's plist format; no project generator dependency is needed."""
    objects = {}

    def add(identifier, isa, **values):
        objects[identifier] = dict(isa=isa, **values)
        return identifier

    source = add('SOURCE', 'PBXFileReference', lastKnownFileType='sourcecode.swift',
                 path='Smoke.swift', sourceTree='<group>')
    product = add('PRODUCT', 'PBXFileReference', explicitFileType='wrapper.application',
                  path='EnvironmentSmoke.app', sourceTree='BUILT_PRODUCTS_DIR')
    build_file = add('BUILD_FILE', 'PBXBuildFile', fileRef=source)
    sources = add('SOURCES', 'PBXSourcesBuildPhase', buildActionMask=2147483647,
                  files=[build_file], runOnlyForDeploymentPostprocessing=0)
    products = add('PRODUCTS', 'PBXGroup', children=[product], name='Products', sourceTree='<group>')
    group = add('GROUP', 'PBXGroup', children=[source, products], sourceTree='<group>')
    settings = dict(SDKROOT='macosx', MACOSX_DEPLOYMENT_TARGET='15.0', ARCHS='arm64',
                    ONLY_ACTIVE_ARCH='YES', SWIFT_VERSION='6.0',
                    PRODUCT_BUNDLE_IDENTIFIER='local.anki-new.environment-smoke',
                    PRODUCT_NAME='EnvironmentSmoke', GENERATE_INFOPLIST_FILE='YES',
                    CODE_SIGN_STYLE='Manual', CODE_SIGN_IDENTITY='-', DEVELOPMENT_TEAM='',
                    ENABLE_HARDENED_RUNTIME='NO', ENABLE_APP_SANDBOX='NO',
                    SWIFT_OPTIMIZATION_LEVEL='-Onone')
    config = add('CONFIG', 'XCBuildConfiguration', name='Debug', buildSettings=settings)
    configs = add('CONFIGS', 'XCConfigurationList', buildConfigurations=[config],
                  defaultConfigurationIsVisible=0, defaultConfigurationName='Debug')
    target = add('TARGET', 'PBXNativeTarget', buildConfigurationList=configs,
                 buildPhases=[sources], buildRules=[], dependencies=[], name='EnvironmentSmoke',
                 productName='EnvironmentSmoke', productReference=product,
                 productType='com.apple.product-type.application')
    project = add('PROJECT', 'PBXProject', buildConfigurationList=configs,
                  compatibilityVersion='Xcode 14.0', developmentRegion='en',
                  hasScannedForEncodings=0, knownRegions=['en'], mainGroup=group,
                  productRefGroup=products, projectDirPath='', targets=[target])
    path = root / 'EnvironmentSmoke.xcodeproj'
    path.mkdir()
    (path / 'project.pbxproj').write_bytes(plistlib.dumps(dict(
        archiveVersion='1', classes={}, objectVersion='56', objects=objects, rootObject=project)))
    (root / 'Smoke.swift').write_text(SOURCE)
    return path


def main():
    if sys.platform != 'darwin' or run('uname', '-m') != 'arm64':
        raise RuntimeError('Run on an Apple Silicon Mac with an active graphical login session')
    developer = os.environ.get('DEVELOPER_DIR') or run('xcode-select', '-p')
    if not (Path(developer) / 'usr/bin/xcodebuild').is_file():
        raise RuntimeError('Select a full Xcode developer directory, not CommandLineTools')
    facts = dict(developerDirectory=developer, xcode=run('xcodebuild', '-version'),
                 swift=run('xcrun', 'swift', '--version'), macOS=run('sw_vers'),
                 sdk=run('xcrun', '--sdk', 'macosx', '--show-sdk-version'),
                 sdkPath=run('xcrun', '--sdk', 'macosx', '--show-sdk-path'))
    run('xcodebuild', '-checkFirstLaunchStatus')
    with tempfile.TemporaryDirectory(prefix='anki-new-environment-') as temporary:
        root = Path(temporary)
        project = create_project(root)
        build_args = ('-project', str(project), '-target', 'EnvironmentSmoke',
                      '-configuration', 'Debug', '-sdk', 'macosx',
                      f'SYMROOT={root / "products"}', f'OBJROOT={root / "intermediates"}')
        log = run('xcodebuild', *build_args, 'clean', 'build', timeout=300)
        if '** BUILD SUCCEEDED **' not in log:
            raise RuntimeError(log)
        settings = json.loads(run('xcodebuild', *build_args, '-showBuildSettings', '-json'))[0]['buildSettings']
        expected = dict(MACOSX_DEPLOYMENT_TARGET='15.0', SWIFT_VERSION='6.0', ARCHS='arm64',
                        CODE_SIGN_IDENTITY='-', DEVELOPMENT_TEAM='')
        for key, value in expected.items():
            if settings.get(key, '') != value:
                raise RuntimeError(f'Unexpected {key}: {settings.get(key)}')
        app = root / 'products/Debug/EnvironmentSmoke.app'
        binary = app / 'Contents/MacOS/EnvironmentSmoke'
        architectures = run('lipo', '-archs', str(binary))
        if architectures != 'arm64':
            raise RuntimeError(f'Unexpected binary architecture: {architectures}')
        run('codesign', '--verify', '--deep', '--strict', str(app))
        signature = run('codesign', '-dvv', str(app))
        if 'Signature=adhoc' not in signature:
            raise RuntimeError(signature)
        output = run(str(binary), timeout=20)
        if 'ANKI_NEW_WINDOW_VISIBLE' not in output:
            raise RuntimeError(f'Window launch was not confirmed: {output}')
        facts.update(build='clean build succeeded', buildSettings=expected,
                     bundleIdentifier=settings['PRODUCT_BUNDLE_IDENTIFIER'],
                     architectures=architectures, signature='adhoc; strict verification passed',
                     launch='ANKI_NEW_WINDOW_VISIBLE; process exited 0',
                     binaryPlatform=run('vtool', '-show-build', str(binary)))
    facts['cleanup'] = 'Temporary project, app and build products removed'
    print(json.dumps(facts, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f'Environment check failed: {error}', file=sys.stderr)
        sys.exit(1)
