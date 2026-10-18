import XCTest

final class AppShellUITests: XCTestCase {
    @MainActor func testNavigationAndNativeSettingsScene() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
                               "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate() }

        let title = app.staticTexts["section.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "Сегодня", title.debugDescription)
        for (route, expected) in [("decks", "Колоды"), ("statistics", "Статистика"),
                                  ("library", "Библиотека"), ("today", "Сегодня")] {
            app.staticTexts["navigation.\(route)"].click()
            XCTAssertEqual(title.label, expected, title.debugDescription)
        }

        app.buttons["navigation.settings"].click()
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        for (route, tab) in [("general", "Основные"), ("review", "Повторение"),
                             ("cards", "Карточки"), ("data", "Данные")] {
            settings.toolbars.buttons[tab].click()
            XCTAssertTrue(settings.staticTexts["settings.\(route)"].exists)
        }
        // Verify the app menu's native Command-comma entry also opens Settings.
        settings.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(settings.exists)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
    }
}
