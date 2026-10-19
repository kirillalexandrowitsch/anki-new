import XCTest

final class AppShellUITests: XCTestCase {
    @MainActor func testNavigationAndNativeSettingsScene() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
                               "-ApplePersistenceIgnoreState", "YES",
                               "-CollectionTestID", UUID().uuidString]
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

    @MainActor func testDeckCreateDuplicateCancelEscapeEditAndRelaunch() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
                               "-ApplePersistenceIgnoreState", "YES",
                               "-CollectionTestID", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        func openDecks() {
            XCTAssertTrue(app.staticTexts["navigation.decks"].waitForExistence(timeout: 10))
            app.staticTexts["navigation.decks"].click()
            XCTAssertTrue(app.buttons["decks.create"].waitForExistence(timeout: 10))
        }
        func replaceName(_ value: String) {
            let field = app.textFields["deckEditor.name"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.click()
            field.typeKey("a", modifierFlags: .command)
            field.typeText(value)
        }
        func assertFocused(_ element: XCUIElement) {
            let focused = NSPredicate { _, _ in element.value(forKey: "hasKeyboardFocus") as? Bool == true }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: nil)],
                                         timeout: 5), .completed, element.debugDescription)
        }
        openDecks()
        let create = app.buttons["decks.create"]
        create.click()
        let save = app.buttons["deckEditor.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled)
        replaceName("English")
        let description = app.textViews["deckEditor.description"]
        description.click()
        description.typeText("Synthetic description")
        app.popUpButtons["deckEditor.icon"].click()
        app.menuItems["Книга"].click()
        app.popUpButtons["deckEditor.color"].click()
        app.menuItems["Фиолетовый"].click()
        save.click()
        let edit = app.buttons["deck.edit.English"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["deckEditor.name"].exists)

        create.click()
        replaceName(" english ")
        save.click()
        XCTAssertTrue(app.staticTexts["deckEditor.nameError"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["deckEditor.name"].exists)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["deckEditor.name"].exists)
        assertFocused(create)

        edit.click()
        XCTAssertEqual(app.textFields["deckEditor.name"].value as? String, "English")
        XCTAssertEqual(app.textViews["deckEditor.description"].value as? String, "Synthetic description")
        XCTAssertEqual(app.popUpButtons["deckEditor.icon"].value as? String, "Книга")
        XCTAssertEqual(app.popUpButtons["deckEditor.color"].value as? String, "Фиолетовый")
        replaceName("Discarded")
        app.buttons["deckEditor.cancel"].click()
        XCTAssertFalse(app.buttons["deck.edit.Discarded"].exists)
        assertFocused(edit)
        edit.click()
        replaceName("Escaped")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertFalse(app.buttons["deck.edit.Escaped"].exists)
        assertFocused(edit)
        edit.click()
        replaceName("Updated")
        save.click()
        XCTAssertTrue(app.buttons["deck.edit.Updated"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        openDecks()
        let updated = app.buttons["deck.edit.Updated"]
        XCTAssertTrue(updated.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["deck.edit.English"].exists)
        updated.click()
        XCTAssertEqual(app.textFields["deckEditor.name"].value as? String, "Updated")
        XCTAssertEqual(app.textViews["deckEditor.description"].value as? String, "Synthetic description")
        XCTAssertEqual(app.popUpButtons["deckEditor.icon"].value as? String, "Книга")
        XCTAssertEqual(app.popUpButtons["deckEditor.color"].value as? String, "Фиолетовый")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    @MainActor func testDesignGalleryNativeControlsAndAppearances() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
                               "-ApplePersistenceIgnoreState", "YES",
                               "-CollectionTestID", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["section.title"].waitForExistence(timeout: 10))
        app.menuBars.menuBarItems["Окно"].click()
        app.menuItems["Дизайн-система"].click()
        let gallery = app.windows["Дизайн-система"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 5))
        let action = gallery.buttons["gallery.action"]
        XCTAssertTrue(action.exists)
        XCTAssertFalse(gallery.buttons["gallery.disabled"].isEnabled)
        action.click()
        XCTAssertEqual(gallery.otherElements["gallery.count"].label, "1")
        // Shortcuts activate the same native Button actions without changing the
        // owner's system-wide Keyboard Navigation preference.
        gallery.typeKey("r", modifierFlags: .command)
        XCTAssertEqual(gallery.otherElements["gallery.count"].label, "2")
        gallery.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertEqual(gallery.otherElements["gallery.count"].label, "0")
        gallery.checkBoxes["gallery.dark"].click()
        gallery.checkBoxes["gallery.enlarged"].click()

        gallery.radioButtons["Поля и переключатели"].click()
        let field = gallery.textFields.firstMatch
        XCTAssertTrue(field.exists)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Проверка IPA /test/")
        XCTAssertEqual(field.value as? String, "Проверка IPA /test/")
        XCTAssertFalse(gallery.textFields.element(boundBy: 3).isEnabled)
        XCTAssertTrue(gallery.staticTexts["Введите название, чтобы продолжить."].exists)
        gallery.checkBoxes["gallery.dark"].click()
        gallery.checkBoxes["gallery.enlarged"].click()
        gallery.checkBoxes["gallery.contrast"].click()
        field.click()
        field.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [])
        gallery.typeText("Valid name")
        XCTAssertEqual(gallery.textFields.element(boundBy: 1).value as? String, "Valid name")
        XCTAssertFalse(gallery.staticTexts["Введите название, чтобы продолжить."].exists)
        gallery.radioButtons["Сообщения и состояния"].click()
        gallery.checkBoxes["gallery.dark"].click()
        gallery.checkBoxes["gallery.enlarged"].click()
        gallery.radioButtons["Типографика и цвета"].click()
    }
}
