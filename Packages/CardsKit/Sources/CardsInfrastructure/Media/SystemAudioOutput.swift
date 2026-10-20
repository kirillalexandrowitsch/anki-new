import AVFoundation
import CardsCore
import Foundation

@MainActor final class SystemAudioOutput: AudioOutput {
    private var player: AVAudioPlayer?
    private var synthesizer: AVSpeechSynthesizer?
    private var delegate: SystemAudioDelegate?
    private var token: UUID?
    private var completion: (@MainActor (Result<Void, AudioPlaybackError>) -> Void)?

    var voices: [SpeechVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { ["en-GB", "en-US"].contains($0.language) }
            .map { SpeechVoice(id: $0.identifier, name: $0.name, locale: $0.language) }
            .sorted { ($0.locale, $0.name, $0.id) < ($1.locale, $1.name, $1.id) }
    }
    private func begin(_ completion: @escaping @MainActor (Result<Void, AudioPlaybackError>) -> Void) {
        stop()
        let id = UUID(); token = id; self.completion = completion
        delegate = SystemAudioDelegate(token: id) { [weak self] id, result in
            guard let self, self.token == id else { return }
            let callback = self.completion; self.stop(); callback?(result)
        }
    }
    func startFile(_ url: URL, completion: @escaping @MainActor (Result<Void, AudioPlaybackError>) -> Void) throws {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { throw AudioPlaybackError.missingFile }
        let value: AVAudioPlayer
        do { value = try AVAudioPlayer(contentsOf: url) }
        catch { throw AudioPlaybackError.invalidFile }
        begin(completion); player = value; value.delegate = delegate
        guard value.prepareToPlay(), value.play() else { stop(); throw AudioPlaybackError.failed }
    }
    func startSpeech(_ text: String, voiceID: String,
                     completion: @escaping @MainActor (Result<Void, AudioPlaybackError>) -> Void) throws {
        guard let available = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.identifier == voiceID }) else {
            throw AudioPlaybackError.unavailableVoice
        }
        let value = AVSpeechUtterance(string: text); value.voice = available
        begin(completion)
        let synth = AVSpeechSynthesizer(); synth.delegate = delegate; synthesizer = synth
        synth.speak(value)
    }
    func stop() {
        token = nil; completion = nil
        player?.delegate = nil; player?.stop(); player = nil
        synthesizer?.delegate = nil; synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil; delegate = nil
    }
}

/// Each source gets an immutable token. Delegate callbacks may arrive after stop, even
/// after AVFoundation has recycled a player/utterance address for the next source.
private final class SystemAudioDelegate: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate, Sendable {
    nonisolated let token: UUID
    nonisolated let complete: @MainActor @Sendable (UUID, Result<Void, AudioPlaybackError>) -> Void
    nonisolated init(token: UUID, complete: @escaping @MainActor @Sendable (UUID, Result<Void, AudioPlaybackError>) -> Void) {
        self.token = token; self.complete = complete
    }
    nonisolated private func finish(_ result: Result<Void, AudioPlaybackError>) {
        Task { @MainActor [token, complete] in complete(token, result) }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(flag ? .success(()) : .failure(.failed))
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) { finish(.failure(.invalidFile)) }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finish(.success(())) }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finish(.failure(.failed)) }
}
