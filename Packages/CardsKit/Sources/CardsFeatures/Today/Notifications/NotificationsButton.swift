import AppKit
import SwiftUI

/// Assign AX identity to the actual control, not the SwiftUI toolbar/popover
/// wrappers which duplicate Button identifiers on macOS 15.
struct NotificationsButton: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let unreadCount: Int
    let action: @MainActor () -> Void

    final class Button: NSButton {
        override var acceptsFirstResponder: Bool { true }
    }
    final class Coordinator: NSObject {
        var action: @MainActor () -> Void = {}
        @objc @MainActor func performAction() { action() }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> Button {
        let button = Button()
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = "Уведомления"
        button.setAccessibilityIdentifier("notifications.toggle")
        button.setAccessibilityLabel("Уведомления")
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction)
        return button
    }
    func updateNSView(_ button: Button, context: Context) {
        button.isEnabled = isEnabled
        button.image = NSImage(systemSymbolName: unreadCount > 0 ? "bell.badge" : "bell", accessibilityDescription: nil)
        button.setAccessibilityValue("Непрочитанных: \(unreadCount)")
        context.coordinator.action = action
    }
}
