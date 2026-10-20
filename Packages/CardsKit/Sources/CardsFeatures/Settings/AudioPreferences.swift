import Foundation
import Observation

/// These preferences autosave; editor drafts continue to require explicit Save.
@MainActor @Observable public final class AudioPreferences {
    private let defaults: UserDefaults
    public var autoplay: Bool { didSet { defaults.set(autoplay, forKey: "audio.autoplay") } }
    public var locale: String { didSet { defaults.set(locale, forKey: "audio.locale") } }
    public var ukVoiceID: String? { didSet { defaults.set(ukVoiceID, forKey: "audio.voice.en-GB") } }
    public var usVoiceID: String? { didSet { defaults.set(usVoiceID, forKey: "audio.voice.en-US") } }
    public var voiceID: String? {
        get { locale == "en-GB" ? ukVoiceID : usVoiceID }
        set { if locale == "en-GB" { ukVoiceID = newValue } else { usVoiceID = newValue } }
    }
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoplay = defaults.bool(forKey: "audio.autoplay")
        locale = defaults.string(forKey: "audio.locale") == "en-US" ? "en-US" : "en-GB"
        ukVoiceID = defaults.string(forKey: "audio.voice.en-GB")
        usVoiceID = defaults.string(forKey: "audio.voice.en-US")
    }
}
