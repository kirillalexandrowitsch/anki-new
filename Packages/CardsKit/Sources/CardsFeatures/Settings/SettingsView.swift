import CardsDesignSystem
import SwiftUI

public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general, review, cards, data

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: String(localized: "Основные", bundle: .module)
        case .review: String(localized: "Повторение", bundle: .module)
        case .cards: String(localized: "Карточки", bundle: .module)
        case .data: String(localized: "Данные", bundle: .module)
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .review: "arrow.trianglehead.2.clockwise.rotate.90"
        case .cards: "rectangle.on.rectangle"
        case .data: "externaldrive"
        }
    }
}

public struct SettingsView: View {
    @State private var selection: SettingsTab = .general

    public init() {}

    public var body: some View {
        TabView(selection: $selection) {
            ForEach(SettingsTab.allCases) { tab in
                SectionPlaceholder(
                    title: tab.title, symbol: tab.symbol,
                    message: String(localized: "Параметры этого раздела появятся в следующих версиях.", bundle: .module)
                )
                .accessibilityIdentifier("settings.\(tab.rawValue)")
                .tabItem { Label(tab.title, systemImage: tab.symbol) }
                .tag(tab)
            }
        }
        .padding(20)
        .frame(width: 640, height: 400)
        .tint(.indigo)
    }
}
