import AppKit
import SwiftUI

/// A window-scoped local monitor preserves native typing and modal keyboard routing.
struct StudyKeyRouter: NSViewRepresentable {
    let model: StudySessionModel
    var requestClose: () -> Void = {}
    func makeNSView(context: Context) -> RouterView { RouterView(model: model, requestClose: requestClose) }
    func updateNSView(_ view: RouterView, context: Context) { view.model = model; view.requestClose = requestClose }
    static func dismantleNSView(_ view: RouterView, coordinator: ()) { view.removeMonitor() }

    final class RouterView: NSView {
        var model: StudySessionModel
        var requestClose: () -> Void
        private var monitor: Any?
        init(model: StudySessionModel, requestClose: @escaping () -> Void = {}) {
            self.model = model; self.requestClose = requestClose; super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    self?.route(event, keyWindow: NSApp.keyWindow) ?? false
                }
                return consumed ? nil : event
            }
        }
        func route(_ event: NSEvent, keyWindow: NSWindow?) -> Bool {
            guard let window, event.window === window, keyWindow === window,
                  window.attachedSheet == nil, !event.isARepeat else { return false }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if flags == .command, event.keyCode == 13 || event.charactersIgnoringModifiers?.lowercased() == "w" {
                requestClose(); return true
            }
            guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  !(window.firstResponder is any NSTextInputClient) else { return false }
            return model.handleKey(event.characters ?? "")
        }
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
