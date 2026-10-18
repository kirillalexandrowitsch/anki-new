import CardsCore
import CardsFeatures
import Foundation
import Testing

private struct FixedClock: CardsCore.Clock {
    let date: Date
    func now() -> Date { date }
}

@Test @MainActor func shellUsesInjectedDateAndKeepsWindowNavigationIndependent() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let first = AppShellModel(clock: FixedClock(date: date))
    let second = AppShellModel(clock: FixedClock(date: date))
    #expect(first.selection == .today)
    #expect(first.currentDate == date)
    first.selection = .library
    #expect(second.selection == .today)
    first.refreshDate()
    #expect(first.currentDate == date)
}

@Test func navigationAndSettingsHaveStableDistinctRoutesAndLocalizedTitles() {
    #expect(MainSection.allCases.map(\.id) == ["today", "decks", "statistics", "library"])
    #expect(SettingsTab.allCases.map(\.id) == ["general", "review", "cards", "data"])
    #expect(MainSection.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty })
    #expect(SettingsTab.allCases.allSatisfy { !$0.title.isEmpty })
}
