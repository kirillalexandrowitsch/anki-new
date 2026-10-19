import AppKit
import SwiftUI

/// Preserve SwiftUI's window delegate; intercept the parent window's red close button
/// while the sheet owns a draft. Removing the sheet restores the original delegate.
struct EditorWindowCloseGuard: NSViewRepresentable {
    let requestClose: () -> Void
    func makeNSView(context: Context) -> GuardView {
        let view = GuardView()
        view.gate = context.coordinator
        return view
    }
    func updateNSView(_ view: GuardView, context: Context) { context.coordinator.requestClose = requestClose }
    func makeCoordinator() -> Gate { Gate(requestClose: requestClose) }
    static func dismantleNSView(_ view: GuardView, coordinator: Gate) { coordinator.restore() }

    final class GuardView: NSView {
        var gate: Gate?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { gate?.install(window.sheetParent ?? window) }
        }
    }
    @MainActor final class Gate: NSObject, NSWindowDelegate {
        var requestClose: () -> Void
        weak var previous: (any NSWindowDelegate)?
        weak var guarded: NSWindow?
        init(requestClose: @escaping () -> Void) { self.requestClose = requestClose }
        func install(_ window: NSWindow) {
            guard guarded !== window else { return }
            restore(); guarded = window; previous = window.delegate; window.delegate = self
        }
        func restore() {
            if let guarded, guarded.delegate === self { guarded.delegate = previous }
            guarded = nil; previous = nil
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool { requestClose(); return false }
        // Older SDKs expose NSObject forwarding as nonisolated. NSWindow queries
        // and invokes its delegate on the AppKit main thread; assert that contract.
        nonisolated override func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            return MainActor.assumeIsolated { previous?.responds(to: selector) == true }
        }
        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
            MainActor.assumeIsolated { ForwardedDelegate(value: previous) }.value
        }
    }
}

/// Synchronous Objective-C forwarding only, after assumeIsolated asserted the main
/// thread. This box never leaves the callback or transfers the delegate to a task.
private struct ForwardedDelegate: @unchecked Sendable {
    let value: (any NSWindowDelegate)?
}
