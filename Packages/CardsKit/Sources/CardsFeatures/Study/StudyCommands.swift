import SwiftUI

struct StudyCloseAction {
    let isEnabled: Bool
    let perform: () -> Void
}
private struct StudyCloseActionKey: FocusedValueKey {
    typealias Value = StudyCloseAction
}
extension FocusedValues {
    var studyCloseAction: StudyCloseAction? {
        get { self[StudyCloseActionKey.self] }
        set { self[StudyCloseActionKey.self] = newValue }
    }
}

/// Native menu routing also handles accessibility-invoked commands that bypass NSEvent monitors.
public struct StudyCommands: Commands {
    @FocusedValue(\.studyCloseAction) private var action
    public init() {}
    public var body: some Commands {
        CommandGroup(before: .saveItem) {
            if let action {
                Button("Закрыть занятие") { action.perform() }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(!action.isEnabled)
            }
        }
    }
}
