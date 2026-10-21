import Foundation

public struct CompleteOnboardingCommand: Equatable, Codable, Sendable {
    public let commandID: CommandID
    public let deckID: DeckID
    public let name: EntityName
    public let includeDemo: Bool

    public init(commandID: CommandID, deckID: DeckID, name: EntityName, includeDemo: Bool) {
        self.commandID = commandID; self.deckID = deckID; self.name = name; self.includeDemo = includeDemo
    }
}

public struct OnboardingResult: Equatable, Codable, Sendable {
    public let schemaVersion: Int
    public let deck: Deck
    public let demoCount: Int
    public init(deck: Deck, demoCount: Int) {
        schemaVersion = 1; self.deck = deck; self.demoCount = demoCount
    }
}

/// Creation and completion form one atomic command. An existing completion wins across windows.
public protocol OnboardingService: Sendable {
    func isRequired() async throws -> Bool
    func complete(_ command: CompleteOnboardingCommand) async throws -> OnboardingResult
}

public protocol OnboardingWorkspaceAccess: CollectionAccess {
    func onboarding(generation: UUID) async throws -> any OnboardingService
}

public enum OnboardingDemo {
    public static let tag = "Демо"
    public static let notes: [BasicNoteContent] = [
        BasicNoteContent(front: "Hello", back: "Привет"),
        BasicNoteContent(front: "Thank you", back: "Спасибо"),
        BasicNoteContent(front: "Good morning", back: "Доброе утро")
    ]
}
