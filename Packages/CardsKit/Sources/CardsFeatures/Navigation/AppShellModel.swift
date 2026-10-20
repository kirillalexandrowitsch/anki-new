import CardsCore
import Foundation
import Observation

@MainActor @Observable
public final class AppShellModel {
    public var selection: MainSection = .today
    public private(set) var currentDate: Date
    private let clock: any CardsCore.Clock
    private let audio: (any AudioPlayback)?
    private let preferences: AudioPreferences?

    public init(clock: any CardsCore.Clock, audio: (any AudioPlayback)? = nil, preferences: AudioPreferences? = nil) {
        self.audio = audio; self.preferences = preferences
        self.clock = clock
        self.currentDate = clock.now()
    }

    func makeDemoAudio() -> AudioPreviewModel? {
        guard let audio, let preferences else { return nil }
        return AudioPreviewModel(service: audio, preferences: preferences)
    }

    var studyClock: any CardsCore.Clock { clock }

    public func refreshDate() {
        currentDate = clock.now()
    }
}
