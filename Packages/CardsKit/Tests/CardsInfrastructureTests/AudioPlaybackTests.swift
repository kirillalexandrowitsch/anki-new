import AVFoundation
import CardsCore
import CardsFeatures
@testable import CardsInfrastructure
import CardsTestSupport
import Foundation
import Testing

@MainActor private final class ControlledAudioOutput: AudioOutput {
    var voices = [SpeechVoice(id: "uk", name: "UK", locale: "en-GB"), SpeechVoice(id: "us", name: "US", locale: "en-US")]
    var events: [String] = []
    var callbacks: [@MainActor (Result<Void, AudioPlaybackError>) -> Void] = []
    var active = 0
    var maximumActive = 0
    var failStart = false
    func startFile(_ url: URL, completion: @escaping @MainActor (Result<Void, AudioPlaybackError>) -> Void) throws {
        try start("file", completion)
    }
    func startSpeech(_ text: String, voiceID: String, completion: @escaping @MainActor (Result<Void, AudioPlaybackError>) -> Void) throws {
        try start("\(voiceID):\(text)", completion)
    }
    private func start(_ event: String, _ callback: @escaping @MainActor (Result<Void, AudioPlaybackError>) -> Void) throws {
        if failStart { throw AudioPlaybackError.failed }
        events.append(event); callbacks.append(callback); active += 1; maximumActive = max(active, maximumActive)
    }
    func stop() { active = 0 }
}

private actor AudioMediaStub: MediaRepository {
    let url = URL(fileURLWithPath: "/tmp/synthetic.wav")
    var failure: MediaStorageError?
    var delayed = false
    var continuation: CheckedContinuation<Void, Never>?
    func configure(_ failure: MediaStorageError? = nil, delayed: Bool = false) { self.failure = failure; self.delayed = delayed }
    func waiting() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
    func importFile(_ source: URL) throws -> MediaAsset { throw MediaStorageError.unsupportedFormat }
    func asset(id: MediaID) -> MediaAsset? { nil }
    func fileURL(id: MediaID) async throws -> URL {
        if delayed { await withCheckedContinuation { continuation = $0 } }
        if let failure { throw failure }
        return url
    }
    func thumbnail(id: MediaID, maxPixelSize: Int) throws -> Data { throw MediaStorageError.unsupportedFormat }
}

@MainActor private func result(_ coordinator: AudioPlaybackCoordinator, _ request: AudioRequest) -> Task<AudioPlaybackError?, Never> {
    Task { do { try await coordinator.play(request); return nil } catch { return error as? AudioPlaybackError ?? .failed } }
}

@Test @MainActor func audioCoordinatorSerializesOwnersReplayAndIgnoresOldCompletion() async {
    let output = ControlledAudioOutput(), first = UUID(), second = UUID()
    let coordinator = AudioPlaybackCoordinator(output: output)
    let a = result(coordinator, AudioRequest(owner: first, text: "first", locale: "en-GB"))
    while output.callbacks.count < 1 { await Task.yield() }
    let b = result(coordinator, AudioRequest(owner: second, text: "second", locale: "en-US"))
    while output.callbacks.count < 2 { await Task.yield() }
    #expect(await a.value == .cancelled)
    coordinator.stop(owner: first)
    output.callbacks[0](.success(())) // late delegate from interrupted source
    #expect(output.active == 1)
    let replay = result(coordinator, AudioRequest(owner: second, text: "second", locale: "en-US"))
    while output.callbacks.count < 3 { await Task.yield() }
    #expect(await b.value == .cancelled)
    output.callbacks[1](.failure(.invalidFile))
    #expect(output.active == 1 && output.maximumActive == 1)
    output.callbacks[2](.success(()))
    #expect(await replay.value == nil && output.active == 0)
    #expect(output.events == ["uk:first", "us:second", "us:second"])
}

@Test @MainActor func audioCoordinatorMissingVoiceNeverStartsOrClaimsSuccess() async {
    let output = ControlledAudioOutput(), coordinator = AudioPlaybackCoordinator(output: ControlledAudioOutput())
    let noVoices = AudioPlaybackCoordinator(output: output)
    output.voices = []
    #expect(await result(noVoices, AudioRequest(owner: UUID(), text: "hello", locale: "en-GB")).value == .unavailableVoice)
    #expect(await result(coordinator, AudioRequest(owner: UUID(), text: "hello", locale: "en-GB", voiceID: "deleted")).value == .unavailableVoice)
    #expect(await result(coordinator, AudioRequest(owner: UUID(), text: "hello", locale: "ru-RU")).value == .unavailableVoice)
    #expect(await result(coordinator, AudioRequest(owner: UUID(), text: "  ", locale: "en-US")).value == .emptyText)
    #expect(output.events.isEmpty)
}

@Test @MainActor func audioCoordinatorResolvesFilePriorityMissingCorruptAndDecodeFailureWithoutSilentFallback() async {
    let output = ControlledAudioOutput(), media = AudioMediaStub(), generation = UUID()
    let coordinator = AudioPlaybackCoordinator(output: output)
    coordinator.register(generation: generation, media: media)
    let request = AudioRequest(owner: UUID(), generation: generation, mediaID: MediaID(), text: "hello", locale: "en-GB")
    for (source, expected) in [(MediaStorageError.notFound, AudioPlaybackError.missingFile), (.integrityFailure, .invalidFile), (.staleContext, .staleContext)] {
        await media.configure(source)
        #expect(await result(coordinator, request).value == expected)
        #expect(output.events.isEmpty)
    }
    await media.configure()
    output.voices = [] // attached audio does not require a voice
    let good = result(coordinator, request)
    while output.callbacks.isEmpty { await Task.yield() }
    #expect(output.events == ["file"])
    output.callbacks[0](.failure(.invalidFile))
    #expect(await good.value == .invalidFile)
    output.failStart = true
    #expect(await result(coordinator, request).value == .failed)
    #expect(output.active == 0 && output.events == ["file"])
}

@Test @MainActor func audioCoordinatorCollectionChangeCancelsLookupAndCannotInterruptNewCollection() async {
    let output = ControlledAudioOutput(), media = AudioMediaStub(), old = UUID(), new = UUID()
    let coordinator = AudioPlaybackCoordinator(output: output)
    coordinator.register(generation: old, media: media)
    await media.configure(delayed: true)
    let request = AudioRequest(owner: UUID(), generation: old, mediaID: MediaID(), text: "old", locale: "en-GB")
    let pending = result(coordinator, request)
    while !(await media.waiting()) { await Task.yield() }
    coordinator.retire(generation: old)
    coordinator.register(generation: new, media: media)
    let fresh = result(coordinator, AudioRequest(owner: UUID(), generation: new, text: "new", locale: "en-US"))
    while output.callbacks.isEmpty { await Task.yield() }
    await media.release()
    #expect(await pending.value == .cancelled)
    coordinator.register(generation: old, media: media) // cannot resurrect retired collection
    #expect(await result(coordinator, request).value == .staleContext)
    #expect(output.active == 1 && output.events == ["us:new"])
    output.callbacks[0](.success(()))
    #expect(await fresh.value == nil)
}

@Test @MainActor func audioCoordinatorTaskCancellationStopsCurrentOutput() async {
    let output = ControlledAudioOutput()
    let active = AudioPlaybackCoordinator(output: output)
    let task = result(active, AudioRequest(owner: UUID(), text: "cancel", locale: "en-GB"))
    while output.callbacks.isEmpty { await Task.yield() }
    task.cancel()
    #expect(await task.value == .cancelled)
    #expect(output.active == 0)
}

private actor AudioStudyService: StudySessionService {
    var presentations = [StudyPresentation(cardID: CardID(), question: "first", answer: "one"),
                         StudyPresentation(cardID: CardID(), question: "second", answer: "two")]
    var ratings = 0
    func next(skipping: Set<CardID>, preferred: CardID?) -> StudyNext {
        presentations.first(where: { !skipping.contains($0.cardID) }).map(StudyNext.question) ?? .completed(.availableViewed)
    }
    func rate(_ command: StudyRatingCommand) { ratings += 1; presentations.removeAll { $0.cardID == command.cardID } }
}

@MainActor private func preferences() -> AudioPreferences {
    // Isolate each preference consumer from the owner's standard defaults.
    let defaults = UserDefaults(suiteName: "audio-tests-\(UUID())")!
    return AudioPreferences(defaults: defaults)
}

@Test @MainActor func audioStudyAutoplayStopsOnCardChangePauseAndEditorPreemptionAndErrorsAllowRating() async throws {
    let output = ControlledAudioOutput(), coordinator = AudioPlaybackCoordinator(output: output)
    let prefs = preferences(), service = AudioStudyService()
    let audio = AudioPreviewModel(service: coordinator, preferences: prefs)
    let model = StudySessionModel(service: service, clock: TestClock(date: Date()), audio: audio)
    await model.load()
    #expect(output.events.isEmpty) // autoplay defaults off
    prefs.autoplay = true
    let play = Task { await model.playAudio() }
    while output.callbacks.isEmpty { await Task.yield() }
    #expect(audio.isPlaying && model.phase == .question)
    model.reveal(); #expect(model.canRate)
    model.pause(); await play.value
    #expect(!audio.isPlaying && output.active == 0 && model.phase == .paused)
    model.resume()
    #expect(output.events.count == 1) // reveal and resume never autoplay
    let rate = Task { await model.rate(.good) }
    while output.callbacks.count < 2 { await Task.yield() }
    #expect(model.phase == .question && model.presentation?.question == "second")
    let editor = AudioPreviewModel(service: coordinator, preferences: prefs)
    let preview = Task { await editor.preview(text: "draft") }
    while output.callbacks.count < 3 { await Task.yield() }
    await rate.value
    model.stopAudio() // old Study owner must not stop Editor
    #expect(output.active == 1 && editor.isPlaying)
    output.callbacks[2](.failure(.failed)); await preview.value
    #expect(editor.hasError && editor.message != nil)
    output.voices = []
    await model.playAudio()
    #expect(model.audioMessage?.contains("Голос") == true)
    model.reveal(); #expect(model.canRate)
    prefs.autoplay = false
    await model.rate(.good)
    #expect(model.confirmedRatings == 2 && model.phase == .completed)
}

@Test @MainActor func audioPreferencesPersistImmediatelyAndKeepLocaleSpecificVoiceSelections() {
    let name = "audio-settings-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let initial = AudioPreferences(defaults: defaults)
    initial.autoplay = true; initial.voiceID = "uk"
    initial.locale = "en-US"; initial.voiceID = "us"
    let reopened = AudioPreferences(defaults: defaults)
    #expect(reopened.autoplay && reopened.locale == "en-US" && reopened.voiceID == "us")
    reopened.locale = "en-GB"
    #expect(reopened.voiceID == "uk")
}

/// Generated silence only; no recording or personal media.
private func syntheticWAV(_ url: URL) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410))
    buffer.frameLength = 4410
    buffer.floatChannelData![0].initialize(repeating: 0, count: 4410)
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

@Test @MainActor func audioSystemDecodesGeneratedGoodMissingAndCorruptFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let good = root.appendingPathComponent("good.wav"), missing = root.appendingPathComponent("missing.wav")
    let corrupt = root.appendingPathComponent("corrupt.wav")
    try syntheticWAV(good); try Data("invalid audio".utf8).write(to: corrupt)
    let output = SystemAudioOutput()
    #expect(throws: AudioPlaybackError.missingFile) { try output.startFile(missing) { _ in } }
    #expect(throws: AudioPlaybackError.invalidFile) { try output.startFile(corrupt) { _ in } }
    var completed: Result<Void, AudioPlaybackError>?
    try output.startFile(good) { completed = $0 }
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while completed == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    output.stop()
    #expect(completed != nil)
    if let completed { try completed.get() }
}

@Test @MainActor func audioSystemInstalledVoiceActuallyFinishesOfflineOrReportsUnavailable() async throws {
    let coordinator = AudioPlaybackCoordinator(), owner = UUID()
    guard let voice = coordinator.voices.first else {
        #expect(await result(coordinator, AudioRequest(owner: owner, text: "hello", locale: "en-GB")).value == .unavailableVoice)
        return
    }
    var finished = false
    let task = Task {
        defer { finished = true }
        try await coordinator.play(AudioRequest(owner: owner, text: "Hello", locale: voice.locale, voiceID: voice.id))
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    while !finished && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    if !finished { coordinator.stop(owner: owner) }
    #expect(finished, "An available installed voice must finish; absence must never report success")
    try await task.value
    print("ANKI_AUDIO_INSTALLED_VOICE_COMPLETED=1")
}

@Test @MainActor func audioPersistedNoteAttachmentFlowsThroughStudyAndEditorWithoutMutatingDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("synthetic.wav")
    try syntheticWAV(source)
    let store = CollectionStore(root: root), context = try await store.open()
    let media = try await store.media(generation: context.generation)
    let asset = try await media.importFile(source)
    let decks = try await store.decks(generation: context.generation)
    let deck = try await CreateDeck(repository: decks).execute(DeckInput(name: "Audio test"), id: DeckID(), commandID: CommandID())
    let notes = try await store.notes(generation: context.generation)
    let saved = try await notes.save(SaveNoteCommand(commandID: CommandID(), noteID: NoteID(), expectedRevision: nil,
        initialDeckID: deck.id, content: BasicNoteContent(front: "hello", back: "answer", pronunciation: "/test/",
        media: [NoteMediaReference(mediaID: asset.id, fieldID: "audio", role: .audio)])))
    let session = try await store.studySession(generation: context.generation)
    guard case .question(let presentation) = try await session.next(skipping: [], preferred: nil) else {
        Issue.record("Expected persisted question"); return
    }
    #expect(presentation.audioMediaID == asset.id && presentation.question == "hello")
    let output = ControlledAudioOutput(), coordinator = AudioPlaybackCoordinator(output: output)
    coordinator.register(generation: context.generation, media: media)
    let preview = AudioPreviewModel(service: coordinator, preferences: preferences(), generation: context.generation)
    let editor = EditorModel(repository: notes, decks: [deck], original: saved, audio: preview)
    editor.draft.front = "unsaved draft"
    let playing = Task { await preview.preview(text: editor.draft.front, mediaID: editor.draft.media.first?.mediaID) }
    while output.callbacks.isEmpty { await Task.yield() }
    #expect(output.events == ["file"] && editor.isDirty)
    editor.requestClose(); #expect(editor.showsUnsavedWarning)
    await editor.resolveClose(.discard); await playing.value
    #expect(!preview.isPlaying && output.active == 0)
    await preview.preview(text: "late queued preview")
    #expect(output.callbacks.count == 1) // closed editor cannot restart audio
    #expect(try await notes.note(id: saved.note.id)?.content.front == "hello")
    coordinator.retire(generation: context.generation)
    try await store.close(generation: context.generation)
}
