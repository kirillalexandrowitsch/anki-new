import Foundation

public struct SpeechVoice: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let locale: String
    public init(id: String, name: String, locale: String) { self.id = id; self.name = name; self.locale = locale }
}

public struct AudioRequest: Sendable {
    public let owner: UUID
    public let generation: UUID?
    public let mediaID: MediaID?
    public let text: String
    public let locale: String
    public let voiceID: String?
    public init(owner: UUID, generation: UUID? = nil, mediaID: MediaID? = nil,
                text: String, locale: String, voiceID: String? = nil) {
        self.owner = owner; self.generation = generation; self.mediaID = mediaID
        self.text = text; self.locale = locale; self.voiceID = voiceID
    }
}

public enum AudioPlaybackError: Error, Equatable, Sendable, LocalizedError {
    case missingFile, invalidFile, unavailableVoice, emptyText, failed, cancelled, staleContext
    public var errorDescription: String? {
        switch self {
        case .missingFile: "Аудиофайл не найден. Повторите попытку или используйте системное произношение."
        case .invalidFile: "Аудиофайл повреждён или недоступен. Проверьте вложение или используйте системное произношение."
        case .unavailableVoice: "Голос для выбранного варианта английского недоступен. Выберите установленный голос в настройках."
        case .emptyText: "Введите английское слово или фразу для произношения."
        case .failed: "Не удалось воспроизвести звук. Повторите попытку."
        case .cancelled: "Воспроизведение остановлено."
        case .staleContext: "Коллекция закрыта. Откройте её заново."
        }
    }
}

/// App-scoped service shared by all windows. Successful return means finished playback.
@MainActor public protocol AudioPlayback: AnyObject {
    var voices: [SpeechVoice] { get }
    func play(_ request: AudioRequest) async throws
    /// A retired owner must not interrupt a newer request from another window.
    func stop(owner: UUID)
}

public protocol AudioMediaAccess: CollectionAccess {
    func media(generation: UUID) async throws -> any MediaRepository
}
