import CardsCore
import Foundation

@MainActor protocol AudioOutput: AnyObject {
    var voices: [SpeechVoice] { get }
    func startFile(_ url: URL, completion: @escaping @MainActor (Result<Void, AudioPlaybackError>) -> Void) throws
    func startSpeech(_ text: String, voiceID: String,
                     completion: @escaping @MainActor (Result<Void, AudioPlaybackError>) -> Void) throws
    func stop()
}

/// Resolves media asynchronously, serializes output on MainActor and rejects stale completions.
@MainActor public final class AudioPlaybackCoordinator: AudioPlayback {
    private let output: any AudioOutput
    private var repositories: [UUID: any MediaRepository] = [:]
    private var retired: Set<UUID> = []
    private var current: (id: UUID, request: AudioRequest)?
    private var completion: CheckedContinuation<Void, any Error>?
    public var voices: [SpeechVoice] { output.voices }

    public convenience init() { self.init(output: SystemAudioOutput()) }
    init(output: any AudioOutput) { self.output = output }

    public func register(generation: UUID, media: any MediaRepository) {
        guard !retired.contains(generation) else { return }
        repositories[generation] = media
    }
    public func retire(generation: UUID) {
        retired.insert(generation); repositories[generation] = nil
        if current?.request.generation == generation { cancelCurrent() }
    }
    public func stop(owner: UUID) {
        if current?.request.owner == owner { cancelCurrent() }
    }
    private func cancelCurrent() {
        current = nil
        let pending = completion; completion = nil
        output.stop()
        pending?.resume(throwing: AudioPlaybackError.cancelled)
    }
    private func finish(_ id: UUID, _ result: Result<Void, AudioPlaybackError>) {
        guard current?.id == id else { return }
        current = nil
        let pending = completion; completion = nil
        output.stop()
        pending?.resume(with: result.mapError { $0 as any Error })
    }
    private func requireCurrent(_ id: UUID) throws {
        guard !Task.isCancelled, current?.id == id else { throw AudioPlaybackError.cancelled }
    }
    public func play(_ request: AudioRequest) async throws {
        // Reject obsolete requests before interrupting a current valid source.
        if let generation = request.generation, repositories[generation] == nil { throw AudioPlaybackError.staleContext }
        try Task.checkCancellation()
        cancelCurrent()
        let id = UUID(); current = (id, request)
        try await withTaskCancellationHandler {
            do {
                let url: URL?
                if let mediaID = request.mediaID {
                    guard let generation = request.generation, let media = repositories[generation] else {
                        throw AudioPlaybackError.staleContext
                    }
                    do { url = try await media.fileURL(id: mediaID) }
                    catch MediaStorageError.notFound { throw AudioPlaybackError.missingFile }
                    catch MediaStorageError.staleContext { throw AudioPlaybackError.staleContext }
                    catch { throw AudioPlaybackError.invalidFile }
                } else { url = nil }
                try requireCurrent(id)
                let voice: SpeechVoice?
                if url == nil {
                    guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw AudioPlaybackError.emptyText
                    }
                    guard ["en-GB", "en-US"].contains(request.locale),
                          let selected = voices.first(where: {
                              $0.locale == request.locale && (request.voiceID == nil || $0.id == request.voiceID)
                          }) else { throw AudioPlaybackError.unavailableVoice }
                    voice = selected
                } else { voice = nil }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    completion = continuation
                    do {
                        let done: @MainActor (Result<Void, AudioPlaybackError>) -> Void = { [weak self] result in
                            self?.finish(id, result)
                        }
                        if let url { try output.startFile(url, completion: done) }
                        else if let voice { try output.startSpeech(request.text, voiceID: voice.id, completion: done) }
                    } catch { finish(id, .failure(error as? AudioPlaybackError ?? .failed)) }
                }
            } catch {
                if current?.id == id { cancelCurrent() }
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.current?.id == id { self?.cancelCurrent() }
            }
        }
    }
}
