import AppKit
@testable import CardsFeatures
import Testing

@MainActor private final class OriginalWindowDelegate: NSObject, NSWindowDelegate {
    func windowDidResize(_ notification: Notification) {}
}

@Test @MainActor func editorWindowGuardPreservesObjectiveCDelegateForwardingAndRestoresIt() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 540),
                          styleMask: [.titled, .closable], backing: .buffered, defer: true)
    let original = OriginalWindowDelegate()
    window.delegate = original
    let gate = EditorWindowCloseGuard.Gate(requestClose: {})
    gate.install(window)
    let selector = #selector(NSWindowDelegate.windowDidResize(_:))
    #expect(window.delegate === gate)
    #expect(gate.responds(to: selector))
    #expect(gate.forwardingTarget(for: selector) as? OriginalWindowDelegate === original)
    #expect(!gate.responds(to: NSSelectorFromString("syntheticUnknownWindowCallback")))
    gate.restore()
    #expect(window.delegate === original)
}
