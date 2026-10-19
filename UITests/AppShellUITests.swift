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

    @MainActor func testNoteEditorCreatePreviewValidationCloseChoicesEditAndReopen() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
                               "-ApplePersistenceIgnoreState", "YES",
                               "-CollectionTestID", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        func field(_ name: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: "editor.\(name)").firstMatch
        }
        func replace(_ name: String, _ text: String) {
            let target = field(name)
            XCTAssertTrue(target.waitForExistence(timeout: 5))
            target.click()
            target.typeKey("a", modifierFlags: .command)
            target.typeText(text)
        }
        func library() {
            XCTAssertTrue(app.staticTexts["navigation.library"].waitForExistence(timeout: 10))
            app.staticTexts["navigation.library"].click()
            XCTAssertTrue(app.buttons["editorLauncher.create"].waitForExistence(timeout: 10))
        }
        func assertClosed() {
            let absent = NSPredicate { _, _ in !field("front").exists }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: absent, object: nil)], timeout: 5), .completed)
        }
        // All data belongs to a fresh, disposable collection.
        app.staticTexts["navigation.decks"].click()
        app.buttons["decks.create"].click()
        let deckName = app.textFields["deckEditor.name"]
        XCTAssertTrue(deckName.waitForExistence(timeout: 5))
        deckName.click(); deckName.typeText("Synthetic editor deck")
        app.buttons["deckEditor.save"].click()
        XCTAssertTrue(app.buttons["deck.edit.Synthetic editor deck"].waitForExistence(timeout: 5))
        library()
        app.buttons["editorLauncher.create"].click()
        let save = app.buttons["editor.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled)
        replace("front", "A phrase with spaces 123")
        XCTAssertFalse(save.isEnabled)
        replace("back", "   ")
        XCTAssertFalse(save.isEnabled)
        replace("back", "Synthetic translation")
        replace("pronunciation", "/test/")
        app.buttons["editor.addExample"].click()
        replace("example.0.en", "Example with spaces")
        replace("example.0.ru", "Example translation")
        XCTAssertTrue(save.isEnabled)
        let preview = app.descendants(matching: .any).matching(identifier: "editor.preview.front").firstMatch
        XCTAssertTrue(preview.label.contains("A phrase with spaces 123"))
        // Escape opens the warning; Cancel retains all typed values.
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        let warningCancel = app.buttons["editor.warning.cancel"]
        XCTAssertTrue(warningCancel.waitForExistence(timeout: 5))
        warningCancel.click()
        XCTAssertEqual(field("front").value as? String, "A phrase with spaces 123")
        // Command-W uses the same gate, and Save commits before dismissing.
        app.typeKey("w", modifierFlags: .command)
        let warningSave = app.buttons["editor.warning.save"]
        XCTAssertTrue(warningSave.waitForExistence(timeout: 5))
        warningSave.click()
        assertClosed()
        let edit = app.buttons["note.edit.A phrase with spaces 123"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.click()
        XCTAssertEqual(field("back").value as? String, "Synthetic translation")
        XCTAssertEqual(field("example.0.en").value as? String, "Example with spaces")
        replace("back", "Discarded translation")
        app.buttons["editor.close"].click()
        let discard = app.buttons["editor.warning.discard"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.click()
        assertClosed()
        edit.click()
        XCTAssertEqual(field("back").value as? String, "Synthetic translation")
        replace("back", "Updated translation")
        app.typeKey("s", modifierFlags: .command)
        assertClosed()
        app.terminate(); app.launch()
        library()
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.click()
        XCTAssertEqual(field("back").value as? String, "Updated translation")
        XCTAssertEqual(field("pronunciation").value as? String, "/test/")
        XCTAssertEqual(field("example.0.ru").value as? String, "Example translation")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        assertClosed()
        // Library snapshots, empty search, inspector and stable Card selection.
        XCTAssertEqual(app.staticTexts["library.counts"].label, "Карточек: 1 · Записей: 1")
        let search = app.textFields["library.search"]
        XCTAssertTrue(search.exists)
        search.click(); search.typeText("missingterm")
        XCTAssertTrue(app.staticTexts["Ничего не найдено"].waitForExistence(timeout: 5))
        app.buttons["library.clearSearch"].click()
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        search.click(); search.typeText("Example")
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["library.counts"].label, "Карточек: 1 · Записей: 1")
        app.buttons["library.clearSearch"].click()
        app.buttons["editorLauncher.create"].click()
        replace("front", "Another synthetic row")
        replace("back", "Another answer")
        save.click()
        assertClosed()
        let count = NSPredicate { _, _ in app.staticTexts["library.counts"].label == "Карточек: 2 · Записей: 2" }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: count, object: nil)], timeout: 5), .completed)
        // Saving a different row must not move the user's existing selection.
        XCTAssertTrue(edit.exists)
        let anotherRow = app.descendants(matching: .any).matching(identifier: "library.table").firstMatch
            .outlineRows.firstMatch
        XCTAssertTrue(anotherRow.waitForExistence(timeout: 5))
        anotherRow.click()
        let anotherEdit = app.buttons["note.edit.Another synthetic row"]
        XCTAssertTrue(anotherEdit.waitForExistence(timeout: 5))
        app.buttons["library.inspector"].click()
        let content = app.descendants(matching: .any).matching(identifier: "library.inspector.content").firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        XCTAssertTrue(content.label.contains("Another answer"))
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
