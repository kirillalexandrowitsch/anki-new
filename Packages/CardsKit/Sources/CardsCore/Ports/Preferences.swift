import Foundation

public enum AppTheme: String, Codable, CaseIterable, Sendable { case system, light, dark }
public enum AppLanguage: String, Codable, CaseIterable, Sendable { case ru, en }
public struct AppPreferences: Equatable, Codable, Sendable {
    public var theme: AppTheme
    public var language: AppLanguage
    public init(theme: AppTheme = .system, language: AppLanguage = .ru) {
        self.theme = theme; self.language = language
    }
}

@MainActor public protocol AppPreferencesStore {
    func load() -> AppPreferences
    func save(_ value: AppPreferences) throws
}

public struct StudyPreferences: Equatable, Codable, Sendable {
    public let newLimit: Int
    public let reviewLimit: Int
    public init(newLimit: Int = 20, reviewLimit: Int = 200) throws {
        guard (0...9999).contains(newLimit), (0...9999).contains(reviewLimit) else {
            throw ValidationError.outOfRange(field: "dailyLimits")
        }
        self.newLimit = newLimit; self.reviewLimit = reviewLimit
    }
    public static let standard = try! Self()
    public var limits: StudyQueueLimits { try! StudyQueueLimits(new: newLimit, review: reviewLimit) }
    private enum CodingKeys: CodingKey { case newLimit, reviewLimit }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(newLimit: c.decode(Int.self, forKey: .newLimit), reviewLimit: c.decode(Int.self, forKey: .reviewLimit))
    }
}
public struct StudyPreferencesSnapshot: Equatable, Codable, Sendable {
    public let value: StudyPreferences
    public let revision: Revision
    public init(value: StudyPreferences = .standard, revision: Revision = .initial) {
        self.value = value; self.revision = revision
    }
}
public struct SaveStudyPreferences: Codable, Sendable {
    public let commandID: CommandID
    public let expectedRevision: Revision
    public let value: StudyPreferences
    public init(commandID: CommandID = CommandID(), expectedRevision: Revision, value: StudyPreferences) {
        self.commandID = commandID; self.expectedRevision = expectedRevision; self.value = value
    }
}
public protocol StudyPreferencesRepository: Sendable {
    func load() async throws -> StudyPreferencesSnapshot
    func save(_ command: SaveStudyPreferences) async throws -> StudyPreferencesSnapshot
}
public protocol PreferencesWorkspaceAccess: CollectionAccess {
    func studyPreferences(generation: UUID) async throws -> any StudyPreferencesRepository
}

public enum DeckBrowserLayout: String, Codable, CaseIterable, Sendable { case tree, grid }
public struct DeckBrowserPreferences: Equatable, Codable, Sendable {
    public var layout: DeckBrowserLayout
    public var expanded: Set<DeckID>
    public init(layout: DeckBrowserLayout = .tree, expanded: Set<DeckID> = []) {
        self.layout = layout; self.expanded = expanded
    }
}
@MainActor public protocol DeckBrowserPreferencesStore {
    func loadDeckBrowser() -> DeckBrowserPreferences
    func saveDeckBrowser(_ value: DeckBrowserPreferences) throws
}
