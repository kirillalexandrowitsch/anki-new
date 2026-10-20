import CardsCore
import Foundation
import Observation

public enum StudyPhase: Equatable, Sendable {
    case loading, question, answer, committing, paused, completed
}

@MainActor public protocol StudyAudioPlayer: AnyObject {
    func play(_ presentation: StudyPresentation) async throws
    func stop()
    var automaticallyPlays: Bool { get }
}

extension StudyAudioPlayer {
    public var automaticallyPlays: Bool { false }
}

@MainActor @Observable public final class StudySessionModel {
    public private(set) var phase: StudyPhase = .loading
    public private(set) var presentation: StudyPresentation?
    public private(set) var completion: StudyCompletion?
    public private(set) var showsExitConfirmation = false
    public private(set) var errorMessage: String?
    public private(set) var audioMessage: String?
    public private(set) var confirmedRatings = 0
    public private(set) var skipped: Set<CardID> = []
    public private(set) var lastSkipped: CardID?
    public private(set) var isStopped = false
    public private(set) var pendingCommand: StudyRatingCommand?
    public private(set) var lastRatingID: CommandID?
    public private(set) var pendingUndo: UndoRatingCommand?
    public private(set) var reviewMessage: String?
    public private(set) var checkpointError: String?
    public private(set) var activeDurationMs: Int64 = 0
    public private(set) var uniqueCards = 0
    public private(set) var grades = [0, 0, 0, 0]
    public private(set) var isFinished = false
    public private(set) var isFinishing = false
    private var checkpointTask: Task<Void, Never>?
    private var checkpointValue: StudyCheckpoint?
    private var restored = false
    private var retryPreferred: CardID?
    private var restoringPaused = false
    private var foreground = true
    private var demoRatedCards: Set<CardID> = []
    private let elapsed: @MainActor () -> TimeInterval
    private var lastTick: TimeInterval?
    private var cardStartedMs: Int64 = 0
    private let service: any StudySessionService
    private let clock: any CardsCore.Clock
    private let audio: (any StudyAudioPlayer)?
    private var pausedPhase: StudyPhase = .question
    private var operation = UUID()
    private var isReading = false
    private var audioOperation = UUID()

    public init(service: any StudySessionService, clock: any CardsCore.Clock, audio: (any StudyAudioPlayer)? = nil,
                elapsed: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.service = service; self.clock = clock; self.audio = audio; self.elapsed = elapsed
    }

    public var playback: AudioPreviewModel? { audio as? AudioPreviewModel }

    public var canRate: Bool { phase == .answer && pendingCommand == nil && pendingUndo == nil && acceptsInput }
    public var canUndoRating: Bool {
        service is any StudyReviewSessionService && lastRatingID != nil && pendingCommand == nil &&
        [.question, .answer, .completed].contains(phase) && acceptsInput
    }
    public var canPause: Bool { [.question, .answer].contains(phase) && acceptsInput }
    public var canExit: Bool { phase != .committing && phase != .completed && acceptsInput }
    private var acceptsInput: Bool { !isStopped && !isFinished && !showsExitConfirmation && !isFinishing && checkpointError == nil }

    public func load() async {
        guard phase == .loading, acceptsInput, !isReading else { return }
        isReading = true
        defer { isReading = false }
        if !restored, let progressService = service as? any StudyProgressService {
            do {
                let progress = try await progressService.progress()
                guard !isStopped else { return }
                apply(progress)
                skipped = progress.checkpoint?.skipped ?? []
                lastSkipped = progress.checkpoint?.lastSkipped
                restored = true
                if progress.checkpoint?.endedEarly == true {
                    completion = .endedEarly; phase = .completed
                    _ = await finishSession()
                    return
                }
                restoringPaused = progress.checkpoint?.phase == .paused
                await readNext()
                restoringPaused = false
                if progress.checkpoint?.phase == .paused, phase == .question {
                    // Restart always hides a previously revealed answer, including within pause.
                    pausedPhase = .question; phase = .paused; lastTick = nil; saveCheckpoint()
                }
            } catch { errorMessage = "Не удалось восстановить занятие. Повторите попытку." }
        } else { restored = true; await readNext(preferred: retryPreferred) }
    }

    private func readNext(preferred: CardID? = nil) async {
        retryPreferred = preferred
        lastTick = nil
        stopAudio()
        phase = .loading; presentation = nil; completion = nil; errorMessage = nil
        guard await flushCheckpoint(), !isStopped else { return }
        isReading = true
        let token = UUID(); operation = token
        do {
            let next = try await service.next(skipping: skipped, preferred: preferred)
            guard !isStopped, operation == token else { return }
            switch next {
            case .question(let value):
                presentation = value; phase = .question
                cardStartedMs = activeDurationMs; lastTick = elapsed()
            case .completed(let reason): completion = reason; phase = .completed
            }
            if let progressService = service as? any StudyProgressService { apply(try await progressService.progress()) }
            guard !isStopped, operation == token else { return }
            if !foreground, phase == .question { pausedPhase = .question; phase = .paused; lastTick = nil }
            saveCheckpoint()
            _ = await flushCheckpoint()
            isReading = false
            if phase == .question, !restoringPaused, audio?.automaticallyPlays == true { await playAudio() }
        } catch {
            guard !isStopped, operation == token else { return }
            isReading = false; phase = .loading; presentation = nil
            errorMessage = "Не удалось загрузить карточку. Повторите попытку."
        }
    }

    public func reveal() {
        guard phase == .question, acceptsInput else { return }
        tick(); phase = .answer; saveCheckpoint()
    }

    public func rate(_ grade: Grade) async {
        guard canRate, let presentation else { return }
        tick()
        pendingCommand = StudyRatingCommand(cardID: presentation.cardID, expectedRevision: presentation.revision,
                                            grade: grade, occurredAt: clock.now(), scheduleEpoch: presentation.scheduleEpoch,
                                            durationMs: min(60_000, max(0, activeDurationMs - cardStartedMs)))
        await commitPending()
    }

    public func retryRating() async {
        guard phase == .answer, acceptsInput, pendingCommand != nil else { return }
        await commitPending()
    }

    private func commitPending() async {
        guard !isStopped, let command = pendingCommand else { return }
        saveCheckpoint()
        phase = .committing; lastTick = nil; errorMessage = nil; lastSkipped = nil; stopAudio()
        guard await flushCheckpoint(), !isStopped else {
            phase = .answer
            errorMessage = "Не удалось подготовить оценку. Сохраните прогресс и повторите ту же оценку."
            return
        }
        let token = UUID(); operation = token
        do {
            try await service.rate(command)
            guard !isStopped, operation == token else { return }
            confirmedRatings += 1; lastRatingID = command.id; pendingCommand = nil; reviewMessage = nil
            if !(service is any StudyProgressService) {
                demoRatedCards.insert(command.cardID); uniqueCards = demoRatedCards.count
                grades[command.grade.rawValue - 1] += 1
            }
            await readNext()
        } catch {
            guard !isStopped, operation == token else { return }
            phase = .answer
            errorMessage = "Не удалось сохранить оценку. Повторите ту же команду."
        }
    }

    public func undoRating() async {
        guard canUndoRating, let service = service as? any StudyReviewSessionService, let ratingID = lastRatingID else { return }
        if pendingUndo == nil {
            pendingUndo = UndoRatingCommand(ratingID: ratingID, sessionID: service.sessionID, occurredAt: clock.now())
        }
        guard let command = pendingUndo else { return }
        tick(); saveCheckpoint()
        guard await flushCheckpoint() else { return }
        let previousPhase = phase
        phase = .committing; lastTick = nil; errorMessage = nil; stopAudio()
        let token = UUID(); operation = token
        do {
            let result = try await service.undoRating(command)
            guard !isStopped, operation == token else { return }
            pendingUndo = nil; lastRatingID = nil; lastSkipped = nil
            confirmedRatings = max(0, confirmedRatings - 1)
            presentation = result.presentation; completion = nil; phase = .answer
            skipped.remove(result.presentation.cardID)
            cardStartedMs = activeDurationMs; lastTick = elapsed()
            saveCheckpoint(); _ = await flushCheckpoint()
            if let progressService = self.service as? any StudyProgressService { apply(try await progressService.progress()) }
            reviewMessage = "Оценка отменена. Карточка и расписание восстановлены."
        } catch {
            guard !isStopped, operation == token else { return }
            phase = previousPhase
            if error as? CollectionRepositoryError == .undoConflict {
                pendingUndo = nil; lastRatingID = nil
                errorMessage = "Не удалось отменить оценку: данные уже изменились."
            } else { errorMessage = "Не удалось отменить оценку. Повторите ту же команду отмены." }
        }
    }

    public func skip() async {
        guard phase == .question, acceptsInput, pendingUndo == nil, let presentation else { return }
        tick(); lastSkipped = presentation.cardID; skipped.insert(presentation.cardID)
        saveCheckpoint()
        await readNext()
    }

    public func undoSkip() async {
        guard [.question, .answer, .completed].contains(phase), acceptsInput,
              pendingCommand == nil, pendingUndo == nil, let id = lastSkipped else { return }
        tick(); skipped.remove(id); lastSkipped = nil; saveCheckpoint()
        await readNext(preferred: id)
    }

    public func checkQueue() async {
        guard phase == .completed, acceptsInput, case .future = completion else { return }
        await readNext()
    }

    public func pause() {
        guard canPause else { return }
        tick(); pausedPhase = phase; phase = .paused; lastTick = nil; stopAudio(); saveCheckpoint()
    }

    public func resume() {
        guard phase == .paused, acceptsInput else { return }
        phase = pausedPhase; lastTick = elapsed(); saveCheckpoint()
    }

    public func requestExit() {
        guard canExit else { return }
        tick(); showsExitConfirmation = true; lastTick = nil; stopAudio(); saveCheckpoint()
    }

    public func cancelExit() { showsExitConfirmation = false; lastTick = elapsed() }

    public func confirmExit() {
        guard showsExitConfirmation, phase != .committing, !isStopped else { return }
        operation = UUID(); isReading = false; showsExitConfirmation = false
        presentation = nil; phase = .completed; completion = .endedEarly; lastTick = nil; stopAudio()
        saveCheckpoint()
        Task { _ = await finishSession() }
    }

    public func escape() {
        if showsExitConfirmation { cancelExit() }
        else if phase == .paused { resume() }
        else if phase != .completed { requestExit() }
    }

    /// True only when this session consumes the key. Text input and repeat are filtered by the router.
    public func handleKey(_ key: String) -> Bool {
        guard acceptsInput else { return false }
        if key == " ", phase == .question { reveal(); return true }
        if let raw = Int(key), let grade = Grade(rawValue: raw), canRate {
            // Enter committing synchronously before scheduling work: queued key events cannot submit twice.
            guard let presentation else { return false }
            tick()
            pendingCommand = StudyRatingCommand(cardID: presentation.cardID, expectedRevision: presentation.revision,
                                                grade: grade, occurredAt: clock.now(), scheduleEpoch: presentation.scheduleEpoch,
                                            durationMs: min(60_000, max(0, activeDurationMs - cardStartedMs)))
            phase = .committing
            Task { await commitPending() }
            return true
        }
        return false
    }

    public func playAudio() async {
        guard [.question, .answer].contains(phase), acceptsInput, let presentation else { return }
        guard let audio else { audioMessage = "Звук недоступен. Можно продолжить занятие."; return }
        let token = UUID(); audioOperation = token; audioMessage = nil
        do { try await audio.play(presentation) }
        catch {
            guard !isStopped, audioOperation == token else { return }
            if error is CancellationError || error as? AudioPlaybackError == .cancelled { return }
            audioMessage = ((error as? AudioPlaybackError)?.errorDescription ?? "Не удалось воспроизвести звук.") + " Можно продолжить занятие."
        }
    }

    public func stopAudio() { audioOperation = UUID(); audio?.stop(); audioMessage = nil }

    private func apply(_ progress: StudyProgress) {
        confirmedRatings = progress.ratings; uniqueCards = progress.uniqueCards
        grades = progress.grades; lastRatingID = progress.lastRatingID
        activeDurationMs = max(activeDurationMs, progress.activeDurationMs)
    }

    /// Discard long heartbeat gaps, sleep and idle. Wall-clock changes cannot add study time.
    public func tick(systemIdleSeconds: TimeInterval = 0) {
        let now = elapsed()
        defer { lastTick = [.question, .answer].contains(phase) && !showsExitConfirmation ? now : nil }
        guard foreground, [.question, .answer].contains(phase), !showsExitConfirmation, !isStopped,
              checkpointError == nil, systemIdleSeconds < 60, let previous = lastTick else { return }
        let delta = now - previous
        guard delta >= 0, delta <= 5 else { return }
        activeDurationMs += Int64(delta * 1000)
    }

    public func setForeground(_ active: Bool) {
        if !active { pause() }
        foreground = active
        if !active { lastTick = nil }
    }

    public func heartbeat(systemIdleSeconds: TimeInterval) async {
        guard !isStopped, !isFinished, !isFinishing else { return }
        tick(systemIdleSeconds: systemIdleSeconds)
        guard [.question, .answer].contains(phase), checkpointError == nil else { return }
        saveCheckpoint(); _ = await flushCheckpoint()
    }

    private func saveCheckpoint() {
        guard let progressService = service as? any StudyProgressService, !isFinished else { return }
        let state: StudyCheckpointPhase
        switch phase {
        case .paused: state = .paused
        case .answer: state = .answer
        case .completed: state = .summary
        default: state = .question
        }
        let value = StudyCheckpoint(cardID: presentation?.cardID, phase: state,
            priorToPause: pausedPhase == .answer ? .answer : .question, skipped: skipped,
            lastSkipped: lastSkipped, activeDurationMs: activeDurationMs, endedEarly: completion == .endedEarly)
        checkpointValue = value
        let previous = checkpointTask
        checkpointTask = Task { [self] in
            await previous?.value
            do { try await progressService.checkpoint(value); checkpointError = nil }
            catch { checkpointError = "Не удалось сохранить прогресс. Повторите сохранение перед продолжением." }
        }
    }

    @discardableResult public func flushCheckpoint() async -> Bool {
        await checkpointTask?.value
        return checkpointError == nil
    }

    public func retryCheckpoint() async {
        guard let value = checkpointValue, let progressService = service as? any StudyProgressService else { return }
        await checkpointTask?.value
        do {
            try await progressService.checkpoint(value)
            checkpointError = nil
            if phase == .loading, !isStopped { await readNext(preferred: retryPreferred) }
        } catch { checkpointError = "Не удалось сохранить прогресс. Повторите сохранение перед продолжением." }
    }

    /// Summary is reviewable before closing; never dismiss on a storage error.
    @discardableResult public func finishSession() async -> Bool {
        guard phase == .completed, !isFinishing else { return isFinished }
        if isFinished { return true }
        isFinishing = true
        defer { isFinishing = false }
        guard await flushCheckpoint() else { return false }
        do {
            if let progressService = service as? any StudyProgressService {
                try await progressService.finish(early: completion == .endedEarly)
                apply(try await progressService.progress())
            }
            isFinished = true; lastRatingID = nil; lastSkipped = nil
            return true
        } catch {
            errorMessage = "Не удалось завершить занятие. Повторите закрытие итогов."
            return false
        }
    }

    public func stop() {
        if [.question, .answer].contains(phase) { pause() }
        isStopped = true; operation = UUID(); stopAudio(); playback?.close()
        presentation = nil; showsExitConfirmation = false
    }
}
