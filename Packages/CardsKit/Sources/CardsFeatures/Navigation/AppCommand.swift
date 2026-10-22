import SwiftUI

/// Stable IDs belong to UI routing, independently of persistence command UUIDs.
public enum AppCommandID: String, CaseIterable, Sendable {
    case today, decks, statistics, library
    case newNote, newDeck, editNote, importData, settings, startStudy
    case reveal, again, hard, good, easy

    var section: MainSection? {
        switch self {
        case .today: .today
        case .decks: .decks
        case .statistics: .statistics
        case .library: .library
        default: nil
        }
    }
    static func navigation(_ section: MainSection) -> Self {
        switch section {
        case .today: .today
        case .decks: .decks
        case .statistics: .statistics
        case .library: .library
        }
    }
}

/// Each focused scene supplies only its currently available actions. Re-evaluate
/// availability at invocation too: a menu may retain an older rendered context.
@MainActor public struct AppCommandContext {
    private let enabled: (AppCommandID) -> Bool
    private let action: (AppCommandID) -> Void
    public init(isEnabled: @escaping (AppCommandID) -> Bool, perform: @escaping (AppCommandID) -> Void) {
        enabled = isEnabled; action = perform
    }
    public func isEnabled(_ id: AppCommandID) -> Bool { enabled(id) }
    @discardableResult public func perform(_ id: AppCommandID) -> Bool {
        guard enabled(id) else { return false }
        action(id)
        return true
    }
}

private struct AppCommandContextKey: FocusedValueKey { typealias Value = AppCommandContext }
private struct StudyCommandContextKey: FocusedValueKey { typealias Value = AppCommandContext }
extension FocusedValues {
    public var appCommandContext: AppCommandContext? {
        get { self[AppCommandContextKey.self] }
        set { self[AppCommandContextKey.self] = newValue }
    }
    var studyCommandContext: AppCommandContext? {
        get { self[StudyCommandContextKey.self] }
        set { self[StudyCommandContextKey.self] = newValue }
    }
}
private struct CommandEnvironmentKey: EnvironmentKey { static let defaultValue: AppCommandContext? = nil }
extension EnvironmentValues {
    var appCommands: AppCommandContext? {
        get { self[CommandEnvironmentKey.self] }
        set { self[CommandEnvironmentKey.self] = newValue }
    }
}
