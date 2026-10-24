import AppKit
import Carbon
import XCTest

final class AppShellUITests: XCTestCase {
    private var originalInputSource: TISInputSource?

    override func setUpWithError() throws {
        try super.setUpWithError()
        // XCTest synthesizes Latin keystrokes against the active system layout.
        // Keep synthetic English fixtures reliable on the owner's Russian keyboard,
        // and restore the exact input source after each test without changing preferences.
        originalInputSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let sources = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
        let latin = try XCTUnwrap(sources.first { source in
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return false }
            let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
            return ["com.apple.keylayout.ABC", "com.apple.keylayout.US"].contains(id)
        })
        XCTAssertEqual(TISSelectInputSource(latin), noErr)
    }

    override func tearDownWithError() throws {
        if let originalInputSource { XCTAssertEqual(TISSelectInputSource(originalInputSource), noErr) }
        originalInputSource = nil
        try super.tearDownWithError()
    }

    @MainActor private func pasteUnicode(_ text: String, into field: XCUIElement) {
        // Native Paste accepts Unicode without XCTest mapping Cyrillic to a Latin layout.
        // Keep the user's clipboard in memory only and restore all items/types immediately.
        let clipboard = NSPasteboard.general
        let saved = (clipboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer { clipboard.clearContents(); clipboard.writeObjects(saved) }
        clipboard.clearContents()
        XCTAssertTrue(clipboard.setString(text, forType: .string))
        field.click()
        let focused = NSPredicate { _, _ in field.value(forKey: "hasKeyboardFocus") as? Bool == true }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: nil)], timeout: 5), .completed)
        field.typeKey("a", modifierFlags: .command)
        field.typeKey("v", modifierFlags: .command)
    }

    @MainActor func testDeckDeletionNamesScopeCancelEscapeNestedCommitAndRelaunch() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
                               "-ApplePersistenceIgnoreState", "YES", "-CollectionTestID", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        dismissWelcome(in: app)
        app.buttons["onboarding.create"].click()
        let name = app.textFields["onboarding.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        app.activate(); name.click(); name.typeText("Delete Root")
        XCTAssertEqual(name.value as? String, "Delete Root")
        app.checkBoxes["onboarding.demo"].click()
        app.buttons["onboarding.save"].click()
        XCTAssertTrue(name.waitForNonExistence(timeout: 10))
        app.staticTexts["navigation.decks"].click()
        XCTAssertTrue(app.buttons["decks.grid"].waitForExistence(timeout: 10))
        app.buttons["decks.grid"].click()
        func action(_ deck: String, _ title: String) {
            let menu = app.descendants(matching: .any).matching(identifier: "deck.actions." + deck).firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.click()
            XCTAssertTrue(app.menuItems[title].waitForExistence(timeout: 5)); app.menuItems[title].click()
        }
        func saveDeck(_ value: String) {
            let field = app.textFields["deckEditor.name"]
            XCTAssertTrue(field.waitForExistence(timeout: 5)); field.click(); field.typeText(value)
            app.buttons["deckEditor.save"].click()
            XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        }
        action("Delete Root", "Добавить подколоду"); saveDeck("Delete Child")
        action("Delete Child", "Добавить подколоду"); saveDeck("Delete Leaf")
        app.buttons["decks.create"].click(); saveDeck("Keep Outside")
        action("Delete Root", "Удалить колоду…")
        let confirm = app.buttons["deckDelete.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        let ready = NSPredicate { _, _ in confirm.isEnabled }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 10), .completed)
        XCTAssertTrue((app.staticTexts["deckDelete.scope"].value as? String ?? "").contains("Delete Root"))
        XCTAssertEqual(app.staticTexts["deckDelete.decks"].value as? String, "Подколод: 2")
        XCTAssertEqual(app.staticTexts["deckDelete.cards"].value as? String, "Карточек: 3")
        XCTAssertEqual(app.staticTexts["deckDelete.notes"].value as? String, "Затронуто записей: 3")
        let confirmation = XCTAttachment(screenshot: app.screenshot())
        confirmation.name = "T033 deletion scope confirmation"; confirmation.lifetime = .keepAlways
        add(confirmation)
        app.menuBars.menuBarItems["Файл"].click()
        XCTAssertFalse(app.menuItems["Новая колода"].isEnabled)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["deck.edit.Delete Root"].exists)
        action("Delete Root", "Удалить колоду…")
        XCTAssertTrue(app.buttons["deckDelete.cancel"].waitForExistence(timeout: 5))
        app.buttons["deckDelete.cancel"].click()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        action("Delete Root", "Удалить колоду…")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 10), .completed)
        confirm.click()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["deck.edit.Keep Outside"].waitForExistence(timeout: 5))
        for deck in ["Delete Root", "Delete Child", "Delete Leaf"] { XCTAssertFalse(app.buttons["deck.edit." + deck].exists) }
        app.staticTexts["navigation.library"].click()
        XCTAssertTrue(app.buttons["library.emptyCreate"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["library.counts"].value as? String, "Карточек: 0 · Записей: 0")
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["navigation.decks"].waitForExistence(timeout: 10))
        app.staticTexts["navigation.decks"].click()
        XCTAssertTrue(app.buttons["deck.edit.Keep Outside"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["deck.edit.Delete Root"].exists)
    }

    @MainActor func testDeckMenuPropertiesSetupCancelAndScopedStart() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
                               "-ApplePersistenceIgnoreState", "YES", "-CollectionTestID", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        dismissWelcome(in: app)
        app.buttons["onboarding.create"].click()
        let name = app.textFields["onboarding.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        app.activate(); name.click(); name.typeText("Setup Root")
        XCTAssertEqual(name.value as? String, "Setup Root")
        app.checkBoxes["onboarding.demo"].click()
        app.buttons["onboarding.save"].click()
        XCTAssertTrue(name.waitForNonExistence(timeout: 10))
        app.staticTexts["navigation.decks"].click()
        func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
        func action(_ deck: String, _ title: String) {
            let menu = element("deck.actions." + deck)
            XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.click()
            XCTAssertTrue(app.menuItems[title].waitForExistence(timeout: 5)); app.menuItems[title].click()
        }
        action("Setup Root", "Свойства колоды")
        let counts = app.staticTexts["deckProperties.counts"]
        XCTAssertTrue(counts.waitForExistence(timeout: 5))
        XCTAssertEqual(counts.value as? String, "Карточек: 3 · Записей: 3")
        app.menuBars.menuBarItems["Файл"].click()
        XCTAssertFalse(app.menuItems["Новая колода"].isEnabled)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        app.buttons["deckProperties.close"].click()
        action("Setup Root", "Настроить занятие…")
        let new = app.textFields["deckStudy.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 5))
        let loaded = NSPredicate { _, _ in new.value as? String == "20" && app.buttons["deckStudy.start"].isEnabled }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: loaded, object: nil)], timeout: 10), .completed)
        new.click(); new.typeKey("a", modifierFlags: .command); new.typeText("1")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(new.waitForNonExistence(timeout: 5))
        action("Setup Root", "Настроить занятие…")
        XCTAssertTrue(new.waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: loaded, object: nil)], timeout: 10), .completed)
        app.buttons["deckStudy.cancel"].click()
        action("Setup Root", "Добавить подколоду")
        let child = app.textFields["deckEditor.name"]
        XCTAssertTrue(child.waitForExistence(timeout: 5)); child.click(); child.typeText("Setup Child")
        app.buttons["deckEditor.save"].click()
        XCTAssertTrue(child.waitForNonExistence(timeout: 5))
        app.buttons["deck.disclosure.Setup Root"].click()
        action("Setup Child", "Настроить занятие…")
        XCTAssertTrue(app.staticTexts["deckStudy.reason"].waitForExistence(timeout: 5))
        let empty = NSPredicate { _, _ in
            let text = app.staticTexts["deckStudy.reason"]
            return ((text.value as? String) ?? text.label).contains("нет карточек")
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: empty, object: nil)], timeout: 10), .completed)
        XCTAssertFalse(app.buttons["deckStudy.start"].isEnabled)
        app.buttons["deckStudy.cancel"].click()
        action("Setup Child", "Добавить карточку")
        let front = element("editor.front"), back = element("editor.back")
        XCTAssertTrue(front.waitForExistence(timeout: 5))
        front.click(); front.typeText("Scoped child question")
        back.click(); back.typeText("Scoped child answer")
        app.buttons["editor.save"].click()
        XCTAssertTrue(front.waitForNonExistence(timeout: 5))
        app.staticTexts["navigation.decks"].click()
        action("Setup Child", "Настроить занятие…")
        let start = app.buttons["deckStudy.start"]
        let ready = NSPredicate { _, _ in start.exists && start.isEnabled }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 10), .completed)
        start.click()
        XCTAssertTrue(app.buttons["study.reveal"].waitForExistence(timeout: 10))
        let question = app.staticTexts["study.question"]
        XCTAssertEqual(question.value as? String, "Scoped child question")
        XCTAssertFalse(app.staticTexts["study.answer"].exists)
        app.buttons["study.reveal"].click()
        app.buttons["study.grade.4"].click()
        XCTAssertTrue(app.buttons["study.close"].waitForExistence(timeout: 10))
        app.buttons["study.close"].click()
        XCTAssertTrue(start.waitForNonExistence(timeout: 5))
        action("Setup Root", "Редактировать")
        XCTAssertTrue(app.textFields["deckEditor.name"].waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        let menu = element("deck.actions.Setup Root")
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.click()
        XCTAssertFalse(app.menuItems["Экспорт колоды — пока недоступен"].isEnabled)
        XCTAssertTrue(app.menuItems["Удалить колоду…"].isEnabled)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        action("Setup Root", "В избранное")
        let favorite = app.buttons["deck.favorite.Setup Root"]
        let committed = NSPredicate { _, _ in favorite.label == "Убрать из избранного" && favorite.isEnabled }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: committed, object: nil)], timeout: 10), .completed)
    }

    @MainActor func testDeckTreeGridFavoriteMoveUndoAndPersistedLayout() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
                               "-ApplePersistenceIgnoreState", "YES", "-CollectionTestID", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        dismissWelcome(in: app)
        app.staticTexts["navigation.decks"].click()
        func element(_ id: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: id).firstMatch
        }
        func reveal(_ target: XCUIElement) {
            XCTAssertTrue(target.waitForExistence(timeout: 10))
            let scroll = app.scrollViews["decks.scroll"]
            for _ in 0..<6 {
                if scroll.frame.contains(target.frame) { break }
                scroll.scroll(byDeltaX: 0, deltaY: target.frame.midY > scroll.frame.maxY ? -160 : 160)
            }
            XCTAssertTrue(scroll.frame.contains(target.frame))
            XCTAssertTrue(target.isHittable)
        }
        func action(_ name: String, _ action: String) {
            let menu = element("deck.actions." + name)
            reveal(menu); menu.click()
            XCTAssertTrue(app.menuItems[action].waitForExistence(timeout: 5))
            app.menuItems[action].click()
        }
        func saveDeck(_ name: String) {
            let input = app.textFields["deckEditor.name"]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            app.activate(); input.click(); input.typeText(name)
            XCTAssertEqual(input.value as? String, name)
            XCTAssertTrue(app.buttons["deckEditor.save"].isEnabled)
            app.buttons["deckEditor.save"].click()
            XCTAssertTrue(input.waitForNonExistence(timeout: 5))
        }
        for name in ["Root", "Other"] { app.buttons["decks.create"].click(); saveDeck(name) }
        action("Root", "Добавить подколоду"); saveDeck("Child")
        let rootDisclosure = app.buttons["deck.disclosure.Root"]
        XCTAssertTrue(rootDisclosure.waitForExistence(timeout: 5)); rootDisclosure.click()
        XCTAssertTrue(app.buttons["deck.edit.Child"].waitForExistence(timeout: 5))
        action("Child", "Добавить подколоду"); saveDeck("Leaf")
        app.buttons["deck.disclosure.Child"].click()
        XCTAssertTrue(app.buttons["deck.edit.Leaf"].waitForExistence(timeout: 5))
        rootDisclosure.click()
        XCTAssertTrue(app.buttons["deck.edit.Leaf"].waitForNonExistence(timeout: 5))
        rootDisclosure.click()
        XCTAssertTrue(app.buttons["deck.edit.Leaf"].waitForExistence(timeout: 5))
        action("Root", "Переместить колоду")
        XCTAssertTrue(app.buttons["deckMove.root"].waitForExistence(timeout: 5))
        for invalid in ["Root", "Child", "Leaf"] {
            XCTAssertFalse(app.buttons["deckMove.destination." + invalid].exists)
        }
        XCTAssertFalse(app.buttons["deckMove.save"].isEnabled)
        app.menuBars.menuBarItems["Файл"].click()
        XCTAssertFalse(app.menuItems["Новая колода"].isEnabled)
        XCTAssertFalse(app.menuItems["Новая карточка"].isEnabled)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        app.menuBars.menuBarItems["Переход"].click()
        XCTAssertFalse(app.menuItems["Сегодня"].isEnabled)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(app.buttons["deckMove.save"].exists)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(app.buttons["deckMove.save"].waitForNonExistence(timeout: 10))
        let favorite = app.buttons["deck.favorite.Leaf"]
        reveal(favorite); favorite.click()
        let committedFavorite = NSPredicate { _, _ in favorite.label == "Убрать из избранного" && favorite.isEnabled }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: committedFavorite, object: nil)],
                                     timeout: 10), .completed)
        element("decks.favorites").click()
        XCTAssertTrue(app.buttons["deck.edit.Leaf"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["deck.edit.Root"].exists)
        let treeCounts = element("deck.counts.Leaf").value as? String ?? element("deck.counts.Leaf").label
        XCTAssertTrue(treeCounts.contains("Карточек: 0"))
        app.buttons["decks.grid"].click()
        XCTAssertTrue(element("decks.gridContent").waitForExistence(timeout: 5))
        XCTAssertEqual(element("deck.counts.Leaf").value as? String ?? element("deck.counts.Leaf").label, treeCounts)
        let search = app.textFields["decks.search"]
        search.click(); search.typeText("missing")
        XCTAssertTrue(app.staticTexts["Нет подходящих колод"].waitForExistence(timeout: 5))
        app.buttons["decks.reset"].click()
        app.buttons["decks.tree"].click()
        action("Leaf", "Переместить колоду")
        app.buttons["deckMove.destination.Other"].click()
        app.buttons["deckMove.save"].click()
        let undo = app.buttons["decks.undoMove"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5)); undo.click()
        XCTAssertTrue(undo.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["deck.edit.Leaf"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        app.staticTexts["navigation.decks"].click()
        XCTAssertTrue(app.buttons["deck.edit.Leaf"].waitForExistence(timeout: 10))
        app.buttons["decks.grid"].click()
        app.terminate(); app.launch()
        app.staticTexts["navigation.decks"].click()
        XCTAssertTrue(element("decks.gridContent").waitForExistence(timeout: 10))
        element("decks.favorites").click()
        XCTAssertTrue(app.buttons["deck.edit.Leaf"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["deck.edit.Root"].exists)
    }

    /// M1 acceptance uses real editor-created Notes and persisted scheduled reviews.
    @MainActor func testFirstVerticalCreateFourGradesStatisticsAndReopen() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
                               "-ApplePersistenceIgnoreState", "YES", "-CollectionTestID", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        dismissWelcome(in: app)
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "T030-" + name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        func value(_ id: String) -> String {
            let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 10))
            return (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
        }
        app.staticTexts["navigation.decks"].click()
        app.buttons["decks.create"].click()
        let deck = app.textFields["deckEditor.name"]
        XCTAssertTrue(deck.waitForExistence(timeout: 5))
        deck.click(); deck.typeText("Synthetic M1 acceptance")
        app.buttons["deckEditor.save"].click()
        XCTAssertTrue(app.buttons["deck.edit.Synthetic M1 acceptance"].waitForExistence(timeout: 5))
        capture("decks")
        app.staticTexts["navigation.library"].click()
        for index in 1...4 {
            let create = app.buttons["editorLauncher.create"]
            XCTAssertTrue(create.waitForExistence(timeout: 5)); create.click()
            for (field, text) in [("front", "Synthetic word \(index)"), ("back", "Synthetic answer \(index)")] {
                let input = app.descendants(matching: .any).matching(identifier: "editor.\(field)").firstMatch
                XCTAssertTrue(input.waitForExistence(timeout: 5))
                input.click(); input.typeText(text)
            }
            if index == 1 { capture("editor") }
            app.buttons["editor.save"].click()
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "editor.front").firstMatch.waitForNonExistence(timeout: 5))
        }
        XCTAssertEqual(value("library.counts"), "Карточек: 4 · Записей: 4")
        capture("library")
        app.staticTexts["navigation.today"].click()
        let start = app.buttons["study.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10)); capture("today"); start.click()
        for grade in 1...4 {
            let reveal = app.buttons["study.reveal"]
            XCTAssertTrue(reveal.waitForExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["study.answer"].exists)
            for hiddenGrade in 1...4 { XCTAssertFalse(app.buttons["study.grade.\(hiddenGrade)"].exists) }
            // A repeated grade key on the next hidden question cannot rate it.
            app.typeKey("\(grade)", modifierFlags: [])
            XCTAssertEqual(value("study.count"), "Подтверждённых оценок: \(grade - 1)")
            if grade == 1 { capture("question") }
            reveal.click()
            XCTAssertTrue(app.staticTexts["study.answer"].waitForExistence(timeout: 5))
            for visibleGrade in 1...4 { XCTAssertTrue(app.buttons["study.grade.\(visibleGrade)"].isEnabled) }
            if grade == 1 { capture("answer") }
            app.buttons["study.grade.\(grade)"].click()
            let count = NSPredicate { _, _ in
                app.staticTexts["study.count"].value as? String == "Подтверждённых оценок: \(grade)"
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: count, object: nil)], timeout: 10), .completed)
        }
        // Again may become due while a slow machine is running the smoke. End
        // explicitly in that case; four grades do not mean every Card is learned.
        if !app.buttons["study.close"].waitForExistence(timeout: 2) {
            app.buttons["study.exit"].click()
            XCTAssertTrue(app.buttons["study.exit.confirm"].waitForExistence(timeout: 5))
            app.buttons["study.exit.confirm"].click()
        }
        XCTAssertTrue(app.buttons["study.close"].waitForExistence(timeout: 10))
        capture("summary")
        app.buttons["study.close"].click()
        func checkStats() {
            app.staticTexts["navigation.statistics"].click()
            XCTAssertEqual(value("statistics.ratings"), "4")
            XCTAssertEqual(value("statistics.cards"), "4")
            for (grade, title) in [(1, "Снова"), (2, "Трудно"), (3, "Хорошо"), (4, "Легко")] {
                XCTAssertEqual(value("statistics.grade.\(grade)"), "\(title): 1")
            }
        }
        checkStats(); capture("statistics")
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["navigation.statistics"].waitForExistence(timeout: 10))
        checkStats(); capture("statistics-reopened")
        app.staticTexts["navigation.library"].click()
        XCTAssertEqual(value("library.counts"), "Карточек: 4 · Записей: 4")
    }

    @MainActor func testCardDeletionCancelUndoTimeoutAndReopen() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
                               "-ApplePersistenceIgnoreState", "YES", "-CollectionTestID", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        dismissWelcome(in: app)
        app.buttons["onboarding.create"].click()
        let name = app.textFields["onboarding.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click(); name.typeText("Synthetic Deletion")
        app.checkBoxes["onboarding.demo"].click()
        app.buttons["onboarding.save"].click()
        app.staticTexts["navigation.library"].click()
        func counts(_ expected: String) {
            let value = app.staticTexts["library.counts"]
            XCTAssertTrue(value.waitForExistence(timeout: 10))
            let matches = NSPredicate { _, _ in value.value as? String == expected }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: nil)], timeout: 10), .completed)
        }
        func helloRow() -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier == %@ OR label BEGINSWITH %@",
                "library.select.Hello", "Выбрать карточку Hello,")).firstMatch
        }
        func request() {
            let select = helloRow()
            XCTAssertTrue(select.waitForExistence(timeout: 10)); select.click()
            if !app.buttons["cardDeletion.request"].exists { app.buttons["library.inspector"].click() }
            app.buttons["cardDeletion.request"].click()
            XCTAssertTrue(app.buttons["cardDeletion.confirm"].waitForExistence(timeout: 5))
        }
        counts("Карточек: 3 · Записей: 3")
        request()
        app.buttons["cardDeletion.cancel"].click()
        counts("Карточек: 3 · Записей: 3")
        request(); app.buttons["cardDeletion.confirm"].click()
        let undo = app.buttons["cardDeletion.undo.Hello"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5)); undo.click()
        counts("Карточек: 3 · Записей: 3")
        request(); app.buttons["cardDeletion.confirm"].click()
        counts("Карточек: 2 · Записей: 2")
        XCTAssertTrue(undo.waitForNonExistence(timeout: 8))
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["navigation.library"].waitForExistence(timeout: 10))
        app.staticTexts["navigation.library"].click()
        counts("Карточек: 2 · Записей: 2")
        XCTAssertFalse(helloRow().exists)
        XCTAssertFalse(undo.exists)
    }

    @MainActor func testStatisticsEmptyPeriodAndRealRatingPersistAfterRelaunch() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
                               "-ApplePersistenceIgnoreState", "YES", "-CollectionTestID", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        dismissWelcome(in: app)
        func stats(_ id: String) -> String {
            let element = app.descendants(matching: .any).matching(identifier: "statistics.\(id)").firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 10))
            return (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
        }
        app.staticTexts["navigation.statistics"].click()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "statistics.empty").firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(stats("ratings"), "0")
        XCTAssertEqual(stats("success"), "Нет данных")
        app.radioButtons["7 дней"].click()
        XCTAssertEqual(stats("cards"), "0")
        app.staticTexts["navigation.today"].click()
        app.buttons["onboarding.create"].click()
        let name = app.textFields["onboarding.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click(); name.typeText("Synthetic Statistics")
        app.checkBoxes["onboarding.demo"].click()
        app.buttons["onboarding.save"].click()
        let start = app.buttons["study.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10)); start.click()
        XCTAssertTrue(app.buttons["study.reveal"].waitForExistence(timeout: 5))
        app.buttons["study.reveal"].click()
        app.buttons["study.grade.4"].click()
        XCTAssertTrue(app.buttons["study.undoRating"].waitForExistence(timeout: 5))
        app.buttons["study.undoRating"].click()
        XCTAssertTrue(app.staticTexts["study.answer"].waitForExistence(timeout: 5))
        app.buttons["study.grade.3"].click()
        XCTAssertTrue(app.buttons["study.reveal"].waitForExistence(timeout: 5))
        app.buttons["study.exit"].click()
        XCTAssertTrue(app.buttons["study.exit.confirm"].waitForExistence(timeout: 5))
        app.buttons["study.exit.confirm"].click()
        XCTAssertTrue(app.buttons["study.close"].waitForExistence(timeout: 5))
        app.buttons["study.close"].click()
        app.staticTexts["navigation.statistics"].click()
        XCTAssertEqual(stats("ratings"), "1")
        XCTAssertEqual(stats("cards"), "1")
        XCTAssertEqual(stats("grade.3"), "Хорошо: 1")
        XCTAssertEqual(stats("grade.4"), "Легко: 0")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "statistics.activity").firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "statistics.empty").firstMatch.exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["navigation.statistics"].waitForExistence(timeout: 10))
        app.staticTexts["navigation.statistics"].click()
        XCTAssertEqual(stats("ratings"), "1")
        XCTAssertEqual(stats("grade.3"), "Хорошо: 1")
    }

    @MainActor func testExportNativeSavePanelCancelAndVerifiedCSVSuccess() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { app.terminate(); try? FileManager.default.removeItem(at: temporary) }
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
                               "-ApplePersistenceIgnoreState", "YES", "-CollectionTestID", UUID().uuidString]
        app.launch()
        dismissWelcome(in: app)
        app.menuBars.menuBarItems["Файл"].click()
        let export = app.menuItems["Экспортировать…"]
        XCTAssertTrue(export.isEnabled)
        export.click()
        let save = app.buttons["export.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(app.checkBoxes["Включить прогресс"].isEnabled)
        XCTAssertFalse(app.checkBoxes["Включить медиафайлы"].isEnabled)
        save.click()
        let name = app.textFields["saveAsNameTextField"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "export.complete").firstMatch.exists)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
        save.click()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        let folder = app.textFields["PathTextField"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        folder.click()
        folder.typeKey("a", modifierFlags: .command)
        folder.typeText(temporary.path + "/")
        folder.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        // Go To may first accept its path completion. Await the actual modal
        // transition before addressing the Save Panel underneath it.
        if !folder.waitForNonExistence(timeout: 2) {
            folder.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        }
        XCTAssertTrue(folder.waitForNonExistence(timeout: 5))
        let nativeSave = app.buttons["OKButton"]
        XCTAssertTrue(nativeSave.waitForExistence(timeout: 10))
        XCTAssertTrue(nativeSave.isEnabled)
        nativeSave.click()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "export.complete").firstMatch.waitForExistence(timeout: 15))
        let file = temporary.appendingPathComponent("Collection.csv")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("\"note_id\",\"front\",\"back\""))
        XCTAssertEqual(text.components(separatedBy: "\r\n").count, 2) // Empty collection: header only.
        app.buttons["Готово"].click()
        XCTAssertFalse(save.exists)
    }

    @MainActor func testMainCommandsKeyboardMenusAndButtonsShareRoutesAndModalGates() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
                               "-ApplePersistenceIgnoreState", "YES", "-CollectionTestID", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        dismissWelcome(in: app)
        func menu(_ name: String) { app.menuBars.menuBarItems[name].click() }
        func closeMenu() { app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: []) }
        func field(_ id: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: "editor.\(id)").firstMatch
        }
        menu("Файл")
        XCTAssertFalse(app.menuItems["Импортировать…"].isEnabled)
        XCTAssertFalse(app.menuItems["Редактировать карточку"].isEnabled)
        closeMenu()
        // Global create also mounts the correct section's presenter from Today.
        app.typeKey("n", modifierFlags: [.command, .shift])
        let name = app.textFields["deckEditor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        menu("Переход")
        XCTAssertFalse(app.menuItems["Сегодня"].isEnabled)
        closeMenu()
        name.click(); name.typeText("Synthetic command deck 1234")
        XCTAssertEqual(name.value as? String, "Synthetic command deck 1234")
        app.buttons["deckEditor.save"].click()
        XCTAssertTrue(app.buttons["deck.edit.Synthetic command deck 1234"].waitForExistence(timeout: 5))
        for (key, title) in [("1", "Сегодня"), ("2", "Колоды"), ("3", "Статистика"), ("4", "Библиотека")] {
            app.typeKey(key, modifierFlags: .command)
            XCTAssertEqual(app.staticTexts["section.title"].label, title)
        }
        // Button and menu must open the same blank editor, with no implicit save.
        app.buttons["editorLauncher.create"].click()
        XCTAssertTrue(field("front").waitForExistence(timeout: 5))
        XCTAssertEqual(field("front").value as? String, "")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(app.buttons["editorLauncher.create"].waitForExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .command)
        menu("Файл"); app.menuItems["Новая карточка"].click()
        XCTAssertTrue(field("front").waitForExistence(timeout: 5))
        XCTAssertEqual(field("front").value as? String, "")
        field("front").click(); field("front").typeText("Words with spaces 1234")
        field("back").click(); field("back").typeText("Answer 1234 with spaces")
        XCTAssertEqual(field("front").value as? String, "Words with spaces 1234")
        menu("Файл")
        XCTAssertFalse(app.menuItems["Новая карточка"].isEnabled)
        XCTAssertFalse(app.menuItems["Новая колода"].isEnabled)
        closeMenu()
        app.buttons["editor.save"].click()
        let edit = app.buttons["note.edit.Words with spaces 1234"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.click()
        XCTAssertTrue(field("front").waitForExistence(timeout: 5))
        XCTAssertEqual(field("front").value as? String, "Words with spaces 1234")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        app.typeKey("e", modifierFlags: .command)
        XCTAssertTrue(field("front").waitForExistence(timeout: 5))
        XCTAssertEqual(field("front").value as? String, "Words with spaces 1234")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.buttons["study.start"].waitForExistence(timeout: 5))
        menu("Занятие"); app.menuItems["Начать занятие"].click()
        XCTAssertTrue(app.buttons["study.reveal"].waitForExistence(timeout: 5))
        menu("Занятие")
        XCTAssertFalse(app.menuItems["Хорошо"].isEnabled)
        app.menuItems["Показать ответ"].click()
        XCTAssertTrue(app.staticTexts["study.answer"].waitForExistence(timeout: 5))
        menu("Файл"); XCTAssertFalse(app.menuItems["Новая карточка"].isEnabled); closeMenu()
        menu("Занятие"); app.menuItems["Хорошо"].click()
        let count = app.staticTexts["study.count"]
        let rated = NSPredicate { _, _ in (count.value as? String) == "Подтверждённых оценок: 1" }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: rated, object: nil)], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["study.close"].waitForExistence(timeout: 5))
        app.buttons["study.close"].click()
        XCTAssertTrue(app.buttons["navigation.settings"].waitForExistence(timeout: 5))
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(field("front").waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(app.buttons["editorLauncher.create"].waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        menu("Файл"); XCTAssertFalse(app.menuItems["Новая карточка"].isEnabled); closeMenu()
    }

    @MainActor func testSettingsAutosaveValidationThemeAndRelaunch() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
                               "-ApplePersistenceIgnoreState", "YES", "-CollectionTestID", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        func openSettings() -> XCUIElement {
            XCTAssertTrue(app.buttons["navigation.settings"].waitForExistence(timeout: 10))
            app.buttons["navigation.settings"].click()
            let window = app.windows["com_apple_SwiftUI_Settings_window"]
            XCTAssertTrue(window.waitForExistence(timeout: 5))
            return window
        }
        let settings = openSettings()
        let theme = settings.descendants(matching: .any).matching(identifier: "settings.theme").firstMatch
        XCTAssertTrue(theme.exists)
        settings.radioButtons["Тёмная"].click()
        settings.toolbars.buttons["Повторение"].click()
        let field = settings.textFields["settings.newLimit"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        func replace(_ text: String) {
            field.click(); field.typeKey("a", modifierFlags: .command); field.typeText(text)
        }
        replace("7")
        let saved = NSPredicate { _, _ in
            let status = settings.staticTexts["settings.savedLimits"]
            return status.label == "Сохранено: новых 7, повторений 200" || (status.value as? String) == "Сохранено: новых 7, повторений 200"
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: saved, object: nil)], timeout: 5), .completed, settings.debugDescription)
        // Wait past debounce by moving through another real tab and back.
        settings.toolbars.buttons["Данные"].click()
        XCTAssertTrue(settings.descendants(matching: .any).matching(identifier: "settings.data").firstMatch.waitForExistence(timeout: 5))
        settings.toolbars.buttons["Повторение"].click()
        replace("-")
        XCTAssertTrue(settings.descendants(matching: .any).matching(identifier: "settings.invalidNumber").firstMatch.waitForExistence(timeout: 5))
        settings.toolbars.buttons["Основные"].click()
        settings.typeKey("w", modifierFlags: .command)
        app.terminate(); app.launch()
        let reopened = openSettings()
        XCTAssertEqual(reopened.radioButtons["Тёмная"].value as? Int, 1)
        reopened.toolbars.buttons["Повторение"].click()
        XCTAssertTrue(reopened.textFields["settings.newLimit"].waitForExistence(timeout: 5))
        XCTAssertEqual(reopened.textFields["settings.newLimit"].value as? String, "7")
        XCTAssertEqual(reopened.textFields["settings.reviewLimit"].value as? String, "200")
    }

    @MainActor func testOnboardingCancelDemoRelaunchAndRealStudy() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
                               "-ApplePersistenceIgnoreState", "YES", "-CollectionTestID", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        let create = app.buttons["onboarding.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["onboarding.import"].isEnabled)
        XCTAssertTrue(app.staticTexts["onboarding.importUnavailable"].exists)
        create.click()
        let name = app.textFields["onboarding.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["onboarding.save"].isEnabled)
        name.click(); name.typeText("Discarded onboarding")
        app.checkBoxes["onboarding.demo"].click()
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["study.start"].exists)
        create.click()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "")
        XCTAssertEqual(app.checkBoxes["onboarding.demo"].value as? Int, 0)
        name.click(); name.typeText("Synthetic first deck")
        app.checkBoxes["onboarding.demo"].click()
        app.buttons["onboarding.save"].click()
        let start = app.buttons["study.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertEqual(todayText("new", in: app), "Новых: 3")
        XCTAssertEqual(todayText("ratings", in: app), "Оценок сегодня: 0")
        app.staticTexts["navigation.library"].click()
        let counts = app.staticTexts["library.counts"]
        XCTAssertTrue(counts.waitForExistence(timeout: 5))
        XCTAssertEqual(counts.value as? String, "Карточек: 3 · Записей: 3")
        app.terminate(); app.launch()
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertFalse(create.exists)
        XCTAssertEqual(todayText("new", in: app), "Новых: 3")
        app.staticTexts["navigation.library"].click()
        XCTAssertTrue(counts.waitForExistence(timeout: 5))
        XCTAssertEqual(counts.value as? String, "Карточек: 3 · Записей: 3")
        app.staticTexts["navigation.today"].click()
        start.click()
        XCTAssertTrue(app.buttons["study.reveal"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["study.grade.3"].exists)
        app.buttons["study.reveal"].click()
        XCTAssertTrue(app.buttons["study.grade.3"].waitForExistence(timeout: 5))
    }

    @MainActor func testOnboardingEmptyDeckHasNoHiddenDemoAfterRelaunch() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
                               "-ApplePersistenceIgnoreState", "YES", "-CollectionTestID", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["onboarding.create"].waitForExistence(timeout: 10))
        app.buttons["onboarding.create"].click()
        let name = app.textFields["onboarding.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click(); name.typeText("Synthetic empty deck")
        app.buttons["onboarding.save"].click()
        XCTAssertTrue(app.buttons["onboarding.openDecks"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["study.start"].exists)
        app.terminate(); app.launch()
        XCTAssertEqual(todayText("new", in: app), "Новых: 0")
        XCTAssertFalse(app.buttons["onboarding.create"].exists)
        XCTAssertFalse(app.buttons["study.start"].exists)
        app.staticTexts["navigation.decks"].click()
        XCTAssertTrue(app.buttons["deck.edit.Synthetic empty deck"].waitForExistence(timeout: 5))
        app.staticTexts["navigation.library"].click()
        XCTAssertTrue(app.staticTexts["library.counts"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["library.counts"].value as? String, "Карточек: 0 · Записей: 0")
    }

    @MainActor private func dismissWelcome(in app: XCUIApplication) {
        let skip = app.buttons["onboarding.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        skip.click()
        let title = app.descendants(matching: .any).matching(identifier: "onboarding.title").firstMatch
        let empty = NSPredicate { _, _ in title.label == "У вас пока нет колод" }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: empty, object: nil)], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["study.start"].exists)
        XCTAssertFalse(app.buttons["onboarding.import"].isEnabled)
    }

    @MainActor private func todayText(_ id: String, in app: XCUIApplication) -> String {
        let element = app.descendants(matching: .any).matching(identifier: "today.\(id)").firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        // Today declares an explicit accessibilityLabel on these semantic groups.
        // AXValue can be an empty string on macOS 15 even when the label is present.
        return element.label
    }

    @MainActor func testPersistentRatingUndoAndReratingSurviveRelaunch() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
                               "-ApplePersistenceIgnoreState", "YES", "-CollectionTestID", UUID().uuidString,
                               "-audio.autoplay", "YES", "-audio.locale", "en-GB",
                               "-audio.voice.en-GB", "SyntheticMissingVoice"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["navigation.decks"].waitForExistence(timeout: 10))
        app.staticTexts["navigation.decks"].click()
        app.buttons["decks.create"].click()
        let name = app.textFields["deckEditor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click(); name.typeText("Synthetic review deck")
        app.buttons["deckEditor.save"].click()
        XCTAssertTrue(app.buttons["deck.edit.Synthetic review deck"].waitForExistence(timeout: 5))
        app.staticTexts["navigation.library"].click()
        XCTAssertTrue(app.buttons["editorLauncher.create"].waitForExistence(timeout: 5))
        app.buttons["editorLauncher.create"].click()
        let front = app.descendants(matching: .any).matching(identifier: "editor.front").firstMatch
        XCTAssertTrue(front.waitForExistence(timeout: 5))
        front.click(); front.typeText("Synthetic review question")
        let back = app.descendants(matching: .any).matching(identifier: "editor.back").firstMatch
        back.click(); back.typeText("Synthetic review answer")
        app.buttons["editor.audio.speech"].click()
        let editorAudioError = app.staticTexts["editor.audio.message"]
        XCTAssertTrue(editorAudioError.waitForExistence(timeout: 5))
        XCTAssertTrue((editorAudioError.value as? String)?.contains("Голос") == true)
        app.buttons["editor.save"].click()
        XCTAssertTrue(app.buttons["note.edit.Synthetic review question"].waitForExistence(timeout: 5))
        app.staticTexts["navigation.today"].click()
        let start = app.buttons["study.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertEqual(start.label, "Начать занятие")
        XCTAssertEqual(todayText("new", in: app), "Новых: 1")
        XCTAssertEqual(todayText("due", in: app), "К повторению: 0")
        start.click()
        let reveal = app.buttons["study.reveal"], answer = app.staticTexts["study.answer"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 5)); XCTAssertFalse(answer.exists)
        let studyAudioError = app.staticTexts["study.audioError"]
        XCTAssertTrue(studyAudioError.waitForExistence(timeout: 5)) // autoplay uses the selected voice
        XCTAssertTrue((studyAudioError.value as? String)?.contains("Голос") == true)
        app.buttons["study.audio"].click()
        XCTAssertTrue(reveal.isEnabled) // retrying audio must not block reveal or rating
        reveal.click(); XCTAssertTrue(answer.waitForExistence(timeout: 5))
        // Pause keeps a revealed answer in this process; restart conservatively hides it.
        app.buttons["study.pause"].click()
        XCTAssertTrue(app.buttons["study.resume"].waitForExistence(timeout: 5))
        app.buttons["study.resume"].click()
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        app.buttons["study.pause"].click()
        XCTAssertTrue(app.buttons["study.resume"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertEqual(start.label, "Продолжить занятие")
        start.click()
        XCTAssertTrue(app.buttons["study.resume"].waitForExistence(timeout: 5))
        XCTAssertFalse(answer.exists)
        app.buttons["study.resume"].click()
        XCTAssertTrue(reveal.waitForExistence(timeout: 5)); XCTAssertFalse(answer.exists)
        reveal.click(); XCTAssertTrue(answer.waitForExistence(timeout: 5))
        app.buttons["study.grade.4"].click()
        let undo = app.buttons["study.undoRating"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertTrue(undo.isHittable)
        undo.click()
        let restoredAnswer = answer.waitForExistence(timeout: 5)
        if !restoredAnswer {
            // Separate source locations survive the privacy-preserving CI diagnostics.
            XCTAssertFalse(app.staticTexts["study.checkpoint.error"].exists)
            let error = app.staticTexts["study.error"]
            if error.exists {
                let text = (error.value as? String) ?? error.label
                if text.contains("данные уже изменились") { XCTFail("Undo revision conflict") }
                else { XCTFail("Undo persistence failure") }
            }
            XCTAssertFalse(app.staticTexts["study.paused"].exists)
            XCTAssertFalse(start.exists)
        }
        XCTAssertTrue(restoredAnswer)
        XCTAssertFalse(reveal.exists)
        XCTAssertEqual(app.staticTexts["study.count"].value as? String, "Подтверждённых оценок: 0")
        XCTAssertTrue(app.buttons["study.grade.1"].isEnabled)
        app.buttons["study.grade.1"].click()
        XCTAssertTrue(app.buttons["study.close"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["study.count"].value as? String, "Подтверждённых оценок: 1")
        // Abrupt termination after the rating must retain the same session's effective count.
        app.terminate(); app.launch()
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertEqual(start.label, "Продолжить занятие")
        start.click()
        XCTAssertTrue(app.staticTexts["study.completed"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["study.count"].value as? String, "Подтверждённых оценок: 1")
        let summary = app.descendants(matching: .any).matching(identifier: "study.summary").firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(summary.descendants(matching: .staticText).count, 0)
        XCTAssertFalse(reveal.exists); XCTAssertFalse(answer.exists)
        XCTAssertTrue(app.buttons["study.checkQueue"].exists) // persisted learning due is still in the future
        app.buttons["study.close"].click()
        XCTAssertEqual(todayText("ratings", in: app), "Оценок сегодня: 1")
        XCTAssertEqual(todayText("cards", in: app), "Карточек сегодня: 1")
        XCTAssertEqual(todayText("new", in: app), "Новых: 0")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "today.nextDue").firstMatch.exists)
        // After durable completion there is no resumable session, also after relaunch.
        app.terminate(); app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "today.nextDue").firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(start.exists)
    }

    @MainActor func testStudyRevealKeyboardPauseSkipAndEscapeExit() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
                               "-ApplePersistenceIgnoreState", "YES",
                               "-CollectionTestID", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        dismissWelcome(in: app)
        let start = app.buttons["study.demo"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.click()
        let question = app.staticTexts["study.question"]
        let answer = app.staticTexts["study.answer"]
        let reveal = app.buttons["study.reveal"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 5))
        XCTAssertFalse(answer.exists)
        for grade in 1...4 {
            XCTAssertFalse(app.buttons["study.grade.\(grade)"].exists)
            app.typeKey("\(grade)", modifierFlags: [])
        }
        XCTAssertTrue(reveal.exists)
        app.buttons["study.pause"].click()
        XCTAssertTrue(app.buttons["study.resume"].waitForExistence(timeout: 5))
        XCTAssertFalse(answer.exists)
        app.buttons["study.resume"].click()
        XCTAssertTrue(reveal.waitForExistence(timeout: 5))
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        XCTAssertFalse(reveal.exists)
        for grade in 1...4 { XCTAssertTrue(app.buttons["study.grade.\(grade)"].isEnabled) }
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "study.grade.")).count, 4)
        app.buttons["study.pause"].click()
        XCTAssertTrue(app.buttons["study.resume"].waitForExistence(timeout: 5))
        XCTAssertFalse(answer.exists)
        app.buttons["study.resume"].click()
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        app.buttons["study.exit"].click()
        XCTAssertTrue(app.buttons["study.exit.confirm"].waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertFalse(app.buttons["study.exit.confirm"].exists)
        XCTAssertTrue(answer.exists)
        let first = question.value as? String
        app.typeKey("3", modifierFlags: [])
        XCTAssertTrue(reveal.waitForExistence(timeout: 5))
        XCTAssertFalse(answer.exists)
        XCTAssertNotEqual(question.value as? String, first)
        XCTAssertEqual(app.staticTexts["study.count"].value as? String, "Подтверждённых оценок: 1")
        app.buttons["study.skip"].click()
        XCTAssertTrue(app.buttons["study.undoSkip"].waitForExistence(timeout: 5))
        XCTAssertTrue(reveal.exists)
        app.buttons["study.undoSkip"].click()
        XCTAssertTrue(reveal.waitForExistence(timeout: 5))
        XCTAssertFalse(answer.exists)
        // Both the native menu and its shortcut use the confirmation gate.
        app.menuBars.menuBarItems["Файл"].click()
        app.menuItems["Закрыть занятие"].click()
        XCTAssertTrue(app.buttons["study.exit.confirm"].waitForExistence(timeout: 5))
        app.buttons["study.exit.cancel"].click()
        app.activate()
        app.sheets.firstMatch.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.buttons["study.exit.confirm"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["study.exit.cancel"].click()
        XCTAssertTrue(reveal.exists)
        app.buttons["study.exit"].click()
        app.buttons["study.exit.confirm"].click()
        XCTAssertTrue(app.buttons["study.close"].waitForExistence(timeout: 5))
        app.buttons["study.close"].click()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
    }

    @MainActor func testStudyButtonsCompleteAndReopenWithoutPersistingDemoProgress() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
                               "-ApplePersistenceIgnoreState", "YES",
                               "-CollectionTestID", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        dismissWelcome(in: app)
        let start = app.buttons["study.demo"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.click()
        let reveal = app.buttons["study.reveal"]
        for grade in [1, 2, 4] {
            XCTAssertTrue(reveal.waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["study.answer"].exists)
            reveal.click()
            XCTAssertTrue(app.staticTexts["study.answer"].waitForExistence(timeout: 5))
            app.buttons["study.grade.\(grade)"].click()
        }
        let close = app.buttons["study.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["study.count"].value as? String, "Подтверждённых оценок: 3")
        XCTAssertFalse(app.staticTexts["study.question"].exists)
        close.click()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.click()
        XCTAssertTrue(reveal.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["study.count"].value as? String, "Подтверждённых оценок: 0")
        XCTAssertFalse(app.staticTexts["study.answer"].exists)
        app.buttons["study.pause"].click()
        app.buttons["study.pausedExit"].click()
        XCTAssertTrue(app.buttons["study.exit.confirm"].waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(app.buttons["study.resume"].waitForExistence(timeout: 5))
        app.buttons["study.resume"].click()
        XCTAssertTrue(reveal.waitForExistence(timeout: 5))
        app.buttons["study.exit"].click()
        app.buttons["study.exit.confirm"].click()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.click()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
    }

    @MainActor func testEmptyLibraryOffersCreationAndDistinctCounts() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
                               "-ApplePersistenceIgnoreState", "YES",
                               "-CollectionTestID", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["navigation.library"].waitForExistence(timeout: 10))
        // First launch now has an explicit welcome/empty state, with no hidden cards.
        dismissWelcome(in: app)
        XCTAssertFalse(app.buttons["study.start"].exists)
        app.staticTexts["navigation.library"].click()
        XCTAssertTrue(app.buttons["library.emptyCreate"].waitForExistence(timeout: 10))
        // macOS AXStaticText exposes its displayed text as AXValue, not AXLabel.
        XCTAssertEqual(app.staticTexts["library.counts"].value as? String, "Карточек: 0 · Записей: 0")
    }

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
            switch route {
            case "general": XCTAssertTrue(settings.descendants(matching: .any).matching(identifier: "settings.theme").firstMatch.exists)
            case "review": XCTAssertTrue(settings.textFields["settings.newLimit"].waitForExistence(timeout: 5))
            case "cards":
                XCTAssertTrue(settings.descendants(matching: .any).matching(identifier: "settings.audio.autoplay").firstMatch.exists)
                XCTAssertTrue(settings.buttons["settings.audio.preview"].exists)
            default: XCTAssertTrue(settings.descendants(matching: .any).matching(identifier: "settings.data").firstMatch.exists)
            }
        }
        // Verify the app menu's native Command-comma entry also opens Settings.
        settings.typeKey("w", modifierFlags: .command)
        let closed = NSPredicate { _, _ in !settings.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: closed, object: nil)], timeout: 5), .completed, settings.debugDescription)
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
        XCTAssertEqual(app.staticTexts["library.counts"].value as? String, "Карточек: 1 · Записей: 1")
        let search = app.textFields["library.search"]
        XCTAssertTrue(search.exists)
        search.click(); search.typeText("missingterm")
        XCTAssertTrue(app.staticTexts["Ничего не найдено"].waitForExistence(timeout: 5))
        app.buttons["library.clearSearch"].click()
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        search.click(); search.typeText("Example")
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["library.counts"].value as? String, "Карточек: 1 · Записей: 1")
        app.buttons["library.clearSearch"].click()
        app.buttons["editorLauncher.create"].click()
        replace("front", "Another synthetic row")
        replace("back", "Another answer")
        save.click()
        assertClosed()
        let count = NSPredicate { _, _ in app.staticTexts["library.counts"].value as? String == "Карточек: 2 · Записей: 2" }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: count, object: nil)], timeout: 5), .completed)
        // Saving a different row must not move the user's existing selection.
        XCTAssertTrue(edit.exists)
        // Native Table may expose the hosted action as a row label or as a Button.
        let anotherRow = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR label BEGINSWITH %@",
            "library.select.Another synthetic row", "Выбрать карточку Another synthetic row,")).firstMatch
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
        pasteUnicode("Проверка IPA /test/", into: field)
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
