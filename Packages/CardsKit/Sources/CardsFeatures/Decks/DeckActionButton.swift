import AppKit
import SwiftUI

/// Explicit responder restoration works even when macOS Keyboard Navigation is off.
/// SwiftUI's focus binding alone does not restore a native button after every sheet.
struct DeckActionButton: NSViewRepresentable {
    let title: String
    let symbol: String
    let identifier: String
    var accessibilityLabel: String? = nil
    var primary = false
    let wantsFocus: Bool
    let action: @MainActor () -> Void

    final class Button: NSButton {
        override var acceptsFirstResponder: Bool { true }
    }

    @MainActor final class Coordinator: NSObject {
        var action: @MainActor () -> Void = {}
        weak var button: Button?
        var wantsFocus = false
        var restored = false
        @objc func performAction() { action() }
        @objc func sheetEnded(_ notification: Notification) {
            guard let window = notification.object as? NSWindow, window === button?.window else { return }
            restoreFocus()
        }
        func restoreFocus() {
            guard wantsFocus, !restored, let button, let window = button.window,
                  window.attachedSheet == nil else { return }
            restored = window.makeFirstResponder(button)
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Button {
        let button = Button()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction)
        context.coordinator.button = button
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.sheetEnded),
                                               name: NSWindow.didEndSheetNotification, object: nil)
        return button
    }

    func updateNSView(_ button: Button, context: Context) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelColor = primary ? .controlAccentColor : nil
        button.contentTintColor = primary ? .white : nil
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(accessibilityLabel ?? title)
        context.coordinator.action = action
        context.coordinator.wantsFocus = wantsFocus
        if !wantsFocus { context.coordinator.restored = false }
        // Native sheet completion and SwiftUI updates can arrive in either order.
        context.coordinator.restoreFocus()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Button, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}
