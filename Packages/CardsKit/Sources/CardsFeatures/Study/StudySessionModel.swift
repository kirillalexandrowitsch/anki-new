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
    private let service: any StudySessionService
    private let clock: any CardsCore.Clock
    private let audio: (any StudyAudioPlayer)?
    private var pausedPhase: StudyPhase = .question
    private var operation = UUID()
    private var isReading = false
    private var audioOperation = UUID()

    public init(service: any StudySessionService, clock: any CardsCore.Clock, audio: (any StudyAudioPlayer)? = nil) {
        self.service = service; self.clock = clock; self.audio = audio
    }

    public var playback: AudioPreviewModel? { audio as? AudioPreviewModel }

    public var canRate: Bool { phase == .answer && pendingCommand == nil && pendingUndo == nil && acceptsInput }
    public var canUndoRating: Bool {
        service is any StudyReviewSessionService && lastRatingID != nil && pendingCommand == nil &&
        [.question, .answer, .completed].contains(phase) && acceptsInput
    }
    public var canPause: Bool { [.question, .answer].contains(phase) && acceptsInput }
    public var canExit: Bool { phase != .committing && phase != .completed && acceptsInput }
    private var acceptsInput: Bool { !isStopped && !showsExitConfirmation }

    public func load() async {
        guard phase == .loading, acceptsInput, !isReading else { return }
        await readNext()
    }

    private func readNext(preferred: CardID? = nil) async {
        stopAudio()
        phase = .loading; presentation = nil; completion = nil; errorMessage = nil
        isReading = true
        let token = UUID(); operation = token
        do {
            let next = try await service.next(skipping: skipped, preferred: preferred)
            guard !isStopped, operation == token else { return }
            isReading = false
            switch next {
            case .question(let value):
                presentation = value; phase = .question
                if audio?.automaticallyPlays == true { await playAudio() }
            case .completed(let reason): completion = reason; phase = .completed
            }
        } catch {
            guard !isStopped, operation == token else { return }
            isReading = false
            errorMessage = "Не удалось загрузить карточку. Повторите попытку."
        }
    }

    public func reveal() {
        guard phase == .question, acceptsInput else { return }
        phase = .answer
    }

    public func rate(_ grade: Grade) async {
        guard canRate, let presentation else { return }
        pendingCommand = StudyRatingCommand(cardID: presentation.cardID, expectedRevision: presentation.revision,
                                            grade: grade, occurredAt: clock.now(), scheduleEpoch: presentation.scheduleEpoch)
        await commitPending()
    }

    public func retryRating() async {
        guard phase == .answer, acceptsInput, pendingCommand != nil else { return }
        await commitPending()
    }

    private func commitPending() async {
        guard !isStopped, let command = pendingCommand else { return }
        phase = .committing; errorMessage = nil; lastSkipped = nil; stopAudio()
        let token = UUID(); operation = token
        do {
            try await service.rate(command)
            guard !isStopped, operation == token else { return }
            confirmedRatings += 1; lastRatingID = command.id; pendingCommand = nil; reviewMessage = nil
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
        let previousPhase = phase
        phase = .committing; errorMessage = nil; stopAudio()
        let token = UUID(); operation = token
        do {
            let result = try await service.undoRating(command)
            guard !isStopped, operation == token else { return }
            pendingUndo = nil; lastRatingID = nil; lastSkipped = nil
            confirmedRatings = max(0, confirmedRatings - 1)
            presentation = result.presentation; completion = nil; phase = .answer
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
        lastSkipped = presentation.cardID; skipped.insert(presentation.cardID)
        await readNext()
    }

    public func undoSkip() async {
        guard [.question, .answer, .completed].contains(phase), acceptsInput,
              pendingCommand == nil, pendingUndo == nil, let id = lastSkipped else { return }
        skipped.remove(id); lastSkipped = nil
        await readNext(preferred: id)
    }

    public func checkQueue() async {
        guard phase == .completed, acceptsInput, case .future = completion else { return }
        await readNext()
    }

    public func pause() {
        guard canPause else { return }
        pausedPhase = phase; phase = .paused; stopAudio()
    }

    public func resume() {
        guard phase == .paused, acceptsInput else { return }
        phase = pausedPhase
    }

    public func requestExit() {
        guard canExit else { return }
        showsExitConfirmation = true; stopAudio()
    }

    public func cancelExit() { showsExitConfirmation = false }

    public func confirmExit() {
        guard showsExitConfirmation, phase != .committing, !isStopped else { return }
        operation = UUID(); isReading = false; showsExitConfirmation = false
        presentation = nil; phase = .completed; completion = .endedEarly; stopAudio()
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
            pendingCommand = StudyRatingCommand(cardID: presentation.cardID, expectedRevision: presentation.revision,
                                                grade: grade, occurredAt: clock.now(), scheduleEpoch: presentation.scheduleEpoch)
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

    public func stop() {
        isStopped = true; operation = UUID(); stopAudio(); playback?.close()
        presentation = nil; showsExitConfirmation = false
    }
}
