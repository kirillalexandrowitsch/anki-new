import AppKit
import SwiftUI

/// A field editor delegate preserves native typing/IME while routing only search navigation.
struct SearchInput: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    let identifier: String
    let route: (UInt16) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> Input {
        let field = Input()
        field.delegate = context.coordinator
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.placeholderString = "Поиск карточек и колод"
        field.isBezeled = true; field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.setAccessibilityIdentifier(identifier)
        return field
    }
    func updateNSView(_ field: Input, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = isEnabled
        if field.stringValue != text { field.stringValue = text }
    }
    final class Input: NSTextField {}
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchInput
        init(parent: SearchInput) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            let code: UInt16
            switch NSStringFromSelector(selector) {
            case "moveDown:": code = 125
            case "moveUp:": code = 126
            case "insertNewline:": code = 36
            case "cancelOperation:": code = 53
            default: return false
            }
            parent.route(code); return true
        }
    }
}
