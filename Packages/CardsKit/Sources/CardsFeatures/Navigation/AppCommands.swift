import SwiftUI

/// Native menu shortcuts use focused scene actions. Unmodified Study keys are
/// deliberately handled by StudyKeyRouter, which checks the native responder.
public struct AppCommands: Commands {
    @FocusedValue(\.appCommandContext) private var main
    @FocusedValue(\.studyCommandContext) private var study
    @Environment(\.openSettings) private var openSettings
    public init() {}
    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            item("Новая карточка", .newNote).keyboardShortcut("n")
            item("Новая колода", .newDeck).keyboardShortcut("n", modifiers: [.command, .shift])
            item("Редактировать карточку", .editNote).keyboardShortcut("e")
            Divider()
            item("Импортировать…", .importData).keyboardShortcut("i", modifiers: [.command, .shift])
                .help("Импорт станет доступен после реализации файлового импорта.")
        }
        CommandGroup(replacing: .appSettings) {
            Button("Настройки…") {
                if let main { main.perform(.settings) } else { openSettings() }
            }
            .keyboardShortcut(",")
            .disabled(study != nil || (main != nil && main?.isEnabled(.settings) != true))
        }
        CommandMenu("Переход") {
            item("Сегодня", .today).keyboardShortcut("1")
            item("Колоды", .decks).keyboardShortcut("2")
            item("Статистика", .statistics).keyboardShortcut("3")
            item("Библиотека", .library).keyboardShortcut("4")
        }
        CommandMenu("Занятие") {
            item("Начать занятие", .startStudy)
            Divider()
            studyItem("Показать ответ", .reveal)
            studyItem("Снова", .again)
            studyItem("Трудно", .hard)
            studyItem("Хорошо", .good)
            studyItem("Легко", .easy)
        }
        StudyCommands()
    }
    private func item(_ title: String, _ id: AppCommandID) -> some View {
        Button(title) { main?.perform(id) }
            .disabled(study != nil || main?.isEnabled(id) != true)
    }
    private func studyItem(_ title: String, _ id: AppCommandID) -> some View {
        Button(title) { study?.perform(id) }.disabled(study?.isEnabled(id) != true)
    }
}
