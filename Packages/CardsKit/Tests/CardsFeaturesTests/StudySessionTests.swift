import AppKit
import CardsCore
@testable import CardsFeatures
import CardsTestSupport
import Foundation
import Testing

private actor SessionService: StudySessionService {
    let first = StudyPresentation(cardID: CardID(), question: "Question one", answer: "Answer one")
    let second = StudyPresentation(cardID: CardID(), question: "Question two", answer: "Answer two")
    var commands: [StudyRatingCommand] = []
    var requests: [Set<CardID>] = []
    var rated: Set<CardID> = []
    var failRead = false
    var failRate = false
    var delayedRate = false
    var delayedRead = false
    var rateContinuation: CheckedContinuation<Void, Never>?
    var readContinuation: CheckedContinuation<Void, Never>?
    var final: StudyCompletion = .availableViewed
    func configure(failRead: Bool = false, failRate: Bool = false, delayedRate: Bool = false,
                   delayedRead: Bool = false, final: StudyCompletion = .availableViewed) {
        self.failRead = failRead; self.failRate = failRate; self.delayedRate = delayedRate
        self.delayedRead = delayedRead; self.final = final
    }
    func submitted() -> [StudyRatingCommand] { commands }
    func reads() -> Int { requests.count }
    func waitingRate() -> Bool { rateContinuation != nil }
    func waitingRead() -> Bool { readContinuation != nil }
    func completeRate() { rateContinuation?.resume(); rateContinuation = nil }
    func completeRead() { readContinuation?.resume(); readContinuation = nil }
    func next(skipping: Set<CardID>, preferred: CardID?) async throws -> StudyNext {
        requests.append(skipping)
        if delayedRead { await withCheckedContinuation { readContinuation = $0 } }
        if failRead { throw CollectionAccessError.staleContext }
        let available = [first, second].filter { !rated.contains($0.cardID) && !skipping.contains($0.cardID) }
        if let card = available.first(where: { $0.cardID == preferred }) ?? available.first { return .question(card) }
        return .completed(final)
    }
    func rate(_ command: StudyRatingCommand) async throws {
        commands.append(command)
        if delayedRate { await withCheckedContinuation { rateContinuation = $0 } }
        if failRate { throw CollectionAccessError.staleContext }
        rated.insert(command.cardID)
    }
}

private let studyClock = TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))

@Test @MainActor func studyGuardsRatingsUntilRevealAndWhileCommittingThenHidesNextAnswer() async throws {
    let service = SessionService()
    await service.configure(delayedRate: true)
    let model = StudySessionModel(service: service, clock: studyClock)
    #expect(model.phase == .loading && !model.canRate)
    await model.rate(.easy)
    await model.load()
    let first = try #require(model.presentation)
    #expect(model.phase == .question && !model.canRate)
    for grade in Grade.allCases { await model.rate(grade); #expect(!model.handleKey("\(grade.rawValue)")) }
    #expect(await service.submitted().isEmpty)
    #expect(model.handleKey(" ") && model.phase == .answer)
    let commit = Task { await model.rate(.good) }
    while !(await service.waitingRate()) { await Task.yield() }
    #expect(model.phase == .committing && !model.canRate)
    for grade in Grade.allCases { await model.rate(grade); #expect(!model.handleKey("\(grade.rawValue)")) }
    model.pause(); model.requestExit(); model.confirmExit()
    await model.skip(); await model.undoSkip(); await model.retryRating()
    #expect(model.phase == .committing && !model.showsExitConfirmation && model.confirmedRatings == 0)
    #expect(await service.submitted().count == 1)
    await service.configure()
    await service.completeRate(); await commit.value
    #expect(model.phase == .question && model.presentation?.cardID != first.cardID && !model.canRate)
    #expect(model.confirmedRatings == 1)
}

@Test @MainActor func studyKeyboardSetsCommittingBeforeAnotherQueuedKey() async {
    let service = SessionService()
    await service.configure(delayedRate: true)
    let model = StudySessionModel(service: service, clock: studyClock)
    await model.load(); model.reveal()
    #expect(model.handleKey("4") && model.phase == .committing)
    #expect(!model.handleKey("4") && !model.handleKey(" "))
    while !(await service.waitingRate()) { await Task.yield() }
    #expect(await service.submitted().count == 1)
    await service.configure(); await service.completeRate()
    while model.phase == .committing || model.phase == .loading { await Task.yield() }
    #expect(model.phase == .question && model.confirmedRatings == 1)
}

@Test @MainActor func studyPauseAndEscapePreserveBothHiddenAndRevealedStates() async {
    let model = StudySessionModel(service: SessionService(), clock: studyClock)
    await model.load()
    for phase in [StudyPhase.question, .answer] {
        if phase == .answer { model.reveal() }
        let card = model.presentation
        model.pause()
        #expect(model.phase == .paused && !model.canRate)
        model.reveal(); await model.rate(.good); await model.skip()
        #expect(model.phase == .paused && model.presentation == card)
        model.requestExit()
        #expect(model.showsExitConfirmation)
        model.resume(); model.reveal(); await model.rate(.easy)
        #expect(model.phase == .paused)
        model.escape()
        #expect(!model.showsExitConfirmation && model.phase == .paused)
        model.escape()
        #expect(model.phase == phase && model.presentation == card)
        model.requestExit(); model.escape()
        #expect(model.phase == phase && !model.showsExitConfirmation)
    }
    model.requestExit(); model.confirmExit()
    #expect(model.phase == .completed && model.completion == .endedEarly && model.presentation == nil)
}

@Test @MainActor func studyFailedCommandRetainsIdentityTimeGradeAndAnswerUntilRetrySucceeds() async throws {
    let service = SessionService()
    await service.configure(failRate: true)
    let model = StudySessionModel(service: service, clock: studyClock)
    await model.load(); model.reveal()
    let card = model.presentation
    await model.rate(.hard)
    let command = try #require(model.pendingCommand)
    #expect(model.phase == .answer && model.presentation == card && model.errorMessage != nil)
    #expect(!model.canRate && model.confirmedRatings == 0)
    await model.rate(.easy); #expect(!model.handleKey("1"))
    await model.retryRating()
    let submitted = await service.submitted()
    #expect(submitted == [command, command])
    #expect(command.occurredAt == studyClock.now() && command.grade == .hard)
    await service.configure(); await model.retryRating()
    #expect(await service.submitted() == [command, command, command])
    #expect(model.phase == .question && model.pendingCommand == nil && model.confirmedRatings == 1)
}

@Test @MainActor func studyLoadingFailuresNeverClaimCompletionOrReplayASavedRating() async {
    let service = SessionService()
    await service.configure(failRead: true)
    let model = StudySessionModel(service: service, clock: studyClock)
    await model.load()
    #expect(model.phase == .loading && model.errorMessage != nil && model.completion == nil)
    await service.configure(); await model.load(); model.reveal()
    await service.configure(failRead: true); await model.rate(.good)
    #expect(model.phase == .loading && model.errorMessage != nil && model.confirmedRatings == 1)
    #expect(model.pendingCommand == nil && model.presentation == nil)
    await service.configure(); await model.load()
    #expect(model.phase == .question)
    #expect(await service.submitted().count == 1)
}

@Test @MainActor func studySkipAndUndoNeverRateAndAlwaysReturnHiddenQuestions() async throws {
    let service = SessionService()
    let model = StudySessionModel(service: service, clock: studyClock)
    await model.load()
    let first = try #require(model.presentation)
    await model.skip()
    #expect(model.phase == .question && model.presentation?.cardID != first.cardID)
    model.reveal(); await model.undoSkip()
    #expect(model.phase == .question && model.presentation == first && model.skipped.isEmpty)
    await model.skip(); await model.skip()
    #expect(model.phase == .completed && model.completion == .availableViewed && model.skipped.count == 2)
    #expect(model.confirmedRatings == 0)
    #expect(await service.submitted().isEmpty)
    await model.undoSkip()
    #expect(model.phase == .question && model.skipped.count == 1 && !model.canRate)
}

@Test @MainActor func studyFutureQueueIsExplicitAndCanBeRechecked() async {
    let service = SessionService()
    let due = studyClock.now().addingTimeInterval(60)
    await service.configure(final: .future(due))
    let model = StudySessionModel(service: service, clock: studyClock)
    await model.load(); await model.skip(); await model.skip()
    #expect(model.phase == .completed && model.completion == .future(due) && model.presentation == nil)
    let count = await service.reads()
    await model.checkQueue()
    #expect(await service.reads() == count + 1)
    #expect(model.completion == .future(due))
}

@Test @MainActor func studyStopIgnoresLateReadAndCommitAndLoadingRejectsDoubleRequest() async {
    let service = SessionService()
    await service.configure(delayedRead: true)
    let model = StudySessionModel(service: service, clock: studyClock)
    let read = Task { await model.load() }
    while !(await service.waitingRead()) { await Task.yield() }
    await model.load()
    #expect(await service.reads() == 1)
    model.stop(); await service.completeRead(); await read.value
    #expect(model.isStopped && model.presentation == nil)
    let active = StudySessionModel(service: service, clock: studyClock)
    await service.configure(delayedRate: true)
    await active.load(); active.reveal()
    let write = Task { await active.rate(.again) }
    while !(await service.waitingRate()) { await Task.yield() }
    active.stop(); await service.completeRate(); await write.value
    #expect(active.isStopped && active.presentation == nil && active.confirmedRatings == 0)
    #expect(await service.reads() == 2)
}

@MainActor private final class FailedStudyAudio: StudyAudioPlayer {
    var stops = 0
    func play(_ presentation: StudyPresentation) throws { throw CollectionAccessError.staleContext }
    func stop() { stops += 1 }
}
@Test @MainActor func studyAudioErrorsDoNotBlockRevealOrRatingAndPauseStopsPlayback() async {
    let audio = FailedStudyAudio()
    let model = StudySessionModel(service: SessionService(), clock: studyClock, audio: audio)
    await model.load(); await model.playAudio()
    #expect(model.audioMessage != nil && model.phase == .question)
    model.reveal(); #expect(model.canRate)
    let before = audio.stops
    model.pause(); #expect(audio.stops > before)
    model.resume(); await model.rate(.good)
    #expect(model.phase == .question && model.confirmedRatings == 1)
}

@Test @MainActor func studyKeyboardRouterRespectsTextFocusOtherWindowsModifiersAndRepeat() async throws {
    _ = NSApplication.shared
    let model = StudySessionModel(service: SessionService(), clock: studyClock)
    await model.load()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    let router = StudyKeyRouter.RouterView(model: model)
    let content = NSView()
    content.addSubview(router); window.contentView = content
    func event(_ key: String = " ", flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false,
               number: Int? = nil, keyCode: UInt16 = 49) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: number ?? window.windowNumber, context: nil,
            characters: key, charactersIgnoringModifiers: key, isARepeat: repeatKey, keyCode: keyCode))
    }
    #expect(!router.route(try event(), keyWindow: other))
    #expect(!router.route(try event(number: other.windowNumber), keyWindow: window))
    for flag in [NSEvent.ModifierFlags.command, .control, .option, .shift] {
        #expect(!router.route(try event(flags: flag), keyWindow: window))
    }
    #expect(!router.route(try event(repeatKey: true), keyWindow: window))
    let text = NSTextView()
    content.addSubview(text)
    #expect(window.makeFirstResponder(text))
    #expect(!router.route(try event(), keyWindow: window))
    for key in ["1", "2", "3", "4"] { #expect(!router.route(try event(key), keyWindow: window)) }
    #expect(model.phase == .question)
    // Native text editing receives every key the monitor declines, including spaces.
    for key in [" ", "1", "2", "3", "4"] {
        if !router.route(try event(key), keyWindow: window) { text.keyDown(with: try event(key)) }
    }
    #expect(text.string == " 1234")
    window.makeFirstResponder(nil)
    #expect(router.route(try event(), keyWindow: window))
    #expect(model.phase == .answer)
    window.makeFirstResponder(text)
    #expect(!router.route(try event("3"), keyWindow: window) && model.canRate)
    for key in [" ", "1", "2", "3", "4"] {
        if !router.route(try event(key), keyWindow: window) { text.keyDown(with: try event(key)) }
    }
    #expect(text.string == " 1234 1234" && model.confirmedRatings == 0)
    // A real attached panel must keep all study actions in the underlying window inert.
    window.beginSheet(other, completionHandler: { _ in })
    #expect(!router.route(try event("3"), keyWindow: window))
    #expect(!router.route(try event("w", flags: .command), keyWindow: window))
    #expect(model.canRate)
    window.endSheet(other)
    var closeRequests = 0
    router.requestClose = { closeRequests += 1 }
    #expect(router.route(try event("w", flags: .command), keyWindow: window))
    #expect(closeRequests == 1)
    #expect(router.route(try event("ц", flags: .command, keyCode: 13), keyWindow: window))
    #expect(closeRequests == 2)
    #expect(!router.route(try event("w", flags: [.command, .shift]), keyWindow: window))
    #expect(closeRequests == 2)
    router.removeMonitor()
}

@Test @MainActor func studyRetiringBeforeQueuedKeyboardCommitPreventsTheWrite() async {
    let service = SessionService()
    let model = StudySessionModel(service: service, clock: studyClock)
    await model.load(); model.reveal()
    #expect(model.handleKey("2"))
    model.stop()
    // Let the queued MainActor task attempt the retired operation.
    await Task.yield()
    #expect(await service.submitted().isEmpty)
    #expect(model.confirmedRatings == 0 && model.isStopped)
}

@Test @MainActor func progressActiveTimeExcludesPauseSleepIdleExitConfirmationAndCapsResponse() async throws {
    var elapsed: TimeInterval = 0
    let service = SessionService()
    let clock = TestClock()
    let model = StudySessionModel(service: service, clock: clock, elapsed: { elapsed })
    await model.load()
    elapsed = 2; model.tick()
    #expect(model.activeDurationMs == 2000)
    clock.advance(by: 86_400) // a wall-clock jump has no effect
    elapsed = 3; model.pause()
    elapsed = 300; model.tick(); model.resume()
    elapsed = 301; model.tick()
    #expect(model.activeDurationMs == 4000)
    elapsed = 900; model.tick() // suspended heartbeat / sleep
    #expect(model.activeDurationMs == 4000)
    elapsed = 901; model.tick(systemIdleSeconds: 90)
    #expect(model.activeDurationMs == 4000)
    elapsed = 902; model.requestExit()
    let before = model.activeDurationMs
    elapsed = 1000; model.tick(); model.cancelExit()
    #expect(model.activeDurationMs == before)
    for _ in 0..<70 { elapsed += 1; model.tick() }
    model.reveal(); await model.rate(.good)
    let command = try #require(await service.submitted().first)
    #expect(command.durationMs == 60_000)
}

@Test @MainActor func progressBackgroundDuringCommitPausesTheNextQuestion() async {
    let service = SessionService()
    await service.configure(delayedRate: true)
    var elapsed: TimeInterval = 0
    let model = StudySessionModel(service: service, clock: studyClock, elapsed: { elapsed })
    await model.load(); model.reveal()
    let commit = Task { await model.rate(.easy) }
    while !(await service.waitingRate()) { await Task.yield() }
    model.setForeground(false)
    await service.configure(); await service.completeRate(); await commit.value
    #expect(model.phase == .paused && model.confirmedRatings == 1)
    elapsed = 1000; model.tick()
    #expect(model.activeDurationMs == 0)
    model.setForeground(true); model.resume()
    #expect(model.phase == .question && !model.canRate)
}

@Test @MainActor func studyMenuButtonAndKeyboardShareStateGatesAndPendingCommand() async throws {
    let service = SessionService()
    await service.configure(delayedRate: true)
    let model = StudySessionModel(service: service, clock: studyClock)
    await model.load()
    let context = model.commandContext
    for id in [AppCommandID.again, .hard, .good, .easy] { #expect(!context.perform(id)) }
    #expect(context.perform(.reveal))
    #expect(!context.perform(.reveal))
    model.requestExit()
    #expect(!context.perform(.good))
    model.cancelExit(); model.pause()
    #expect(!context.perform(.good))
    model.resume()
    #expect(context.perform(.good))
    #expect(model.phase == .committing)
    #expect(!context.perform(.easy) && !model.handleKey("4"))
    for _ in 0..<1000 {
        if await service.waitingRate() { break }
        await Task.yield()
    }
    #expect(await service.submitted().count == 1)
    #expect(await service.submitted().first?.grade == .good)
    await service.completeRate()
    for _ in 0..<1000 {
        if model.phase == .question { break }
        await Task.yield()
    }
    #expect(model.confirmedRatings == 1 && model.phase == .question)
    #expect(!context.perform(.good))
    #expect(model.handleKey(" "))
    #expect(model.phase == .answer)
    model.stop()
    #expect(!context.perform(.good))
}
