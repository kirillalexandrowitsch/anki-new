import XCTest

final class AppShellUITests: XCTestCase {
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
