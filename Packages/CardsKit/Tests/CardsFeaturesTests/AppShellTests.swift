import CardsCore
import CardsFeatures
import CardsTestSupport
import Foundation
import Testing

@Test @MainActor func shellUsesInjectedDateAndKeepsWindowNavigationIndependent() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let clock = TestClock(date: date)
    let first = AppShellModel(clock: clock)
    let second = AppShellModel(clock: clock)
    #expect(first.selection == .today)
    #expect(first.currentDate == date)
    first.selection = .library
    #expect(second.selection == .today)
    clock.advance(by: 60)
    first.refreshDate()
    #expect(first.currentDate == date.addingTimeInterval(60))
    #expect(second.currentDate == date)
}

@Test func navigationAndSettingsHaveStableDistinctRoutesAndLocalizedTitles() {
    #expect(MainSection.allCases.map(\.id) == ["today", "decks", "statistics", "library"])
    #expect(SettingsTab.allCases.map(\.id) == ["general", "review", "cards", "data"])
    #expect(MainSection.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty })
    #expect(SettingsTab.allCases.allSatisfy { !$0.title.isEmpty })
}
