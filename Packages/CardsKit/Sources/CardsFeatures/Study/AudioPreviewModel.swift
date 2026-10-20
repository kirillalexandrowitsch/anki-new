import CardsCore
import Foundation
import Observation

@MainActor @Observable public final class AudioPreviewModel: StudyAudioPlayer {
    public let preferences: AudioPreferences
    public private(set) var isPlaying = false
    public private(set) var message: String?
    public private(set) var hasError = false
    public var automaticallyPlays: Bool { preferences.autoplay }
    public var voices: [SpeechVoice] { service.voices }
    private let service: any AudioPlayback
    private let generation: UUID?
    private let owner = UUID()
    private var operation = UUID()
    private var isClosed = false

    public init(service: any AudioPlayback, preferences: AudioPreferences, generation: UUID? = nil) {
        self.service = service; self.preferences = preferences; self.generation = generation
    }
    public func play(_ presentation: StudyPresentation) async throws {
        try await play(text: presentation.question, mediaID: presentation.audioMediaID)
    }
    public func play(text: String, mediaID: MediaID? = nil) async throws {
        guard !isClosed else { return }
        let token = UUID(); operation = token
        isPlaying = true; message = nil; hasError = false
        defer { if operation == token { isPlaying = false } }
        do {
            try await service.play(AudioRequest(owner: owner, generation: generation, mediaID: mediaID,
                text: text, locale: preferences.locale, voiceID: preferences.voiceID))
            guard operation == token else { return }
            message = "Воспроизведено."
        } catch {
            guard operation == token else { return }
            if error is CancellationError || error as? AudioPlaybackError == .cancelled { return }
            hasError = true
            message = (error as? AudioPlaybackError)?.errorDescription ?? AudioPlaybackError.failed.errorDescription
            throw error
        }
    }
    public func preview(text: String, mediaID: MediaID? = nil) async {
        do { try await play(text: text, mediaID: mediaID) } catch { /* message is inline and non-modal */ }
    }
    public func close() { stop(); isClosed = true }
    public func stop() {
        operation = UUID(); service.stop(owner: owner); isPlaying = false; message = nil; hasError = false
    }
}
