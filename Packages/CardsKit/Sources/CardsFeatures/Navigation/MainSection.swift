import Foundation

/// Settings is the fifth sidebar entry, opened using the native Settings scene.
public enum MainSection: String, CaseIterable, Identifiable, Sendable {
    case today, decks, statistics, library

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .today: String(localized: "Сегодня", bundle: .module)
        case .decks: String(localized: "Колоды", bundle: .module)
        case .statistics: String(localized: "Статистика", bundle: .module)
        case .library: String(localized: "Библиотека", bundle: .module)
        }
    }

    public var symbol: String {
        switch self {
        case .today: "house"
        case .decks: "rectangle.on.rectangle"
        case .statistics: "chart.bar"
        case .library: "doc.text"
        }
    }

    var message: String {
        switch self {
        case .today: String(localized: "Здесь появятся задания на сегодня после подключения коллекции.", bundle: .module)
        case .decks: String(localized: "Здесь будут ваши колоды и материалы для повторения.", bundle: .module)
        case .statistics: String(localized: "История занятий появится после первых повторений.", bundle: .module)
        case .library: String(localized: "Здесь будут ваши слова, примеры и карточки.", bundle: .module)
        }
    }
}
