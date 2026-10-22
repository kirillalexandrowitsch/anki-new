import CardsCore
import Foundation

@MainActor public final class UserDefaultsPreferences: AppPreferencesStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> AppPreferences {
        AppPreferences(theme: AppTheme(rawValue: defaults.string(forKey: "app.theme") ?? "") ?? .system,
            language: AppLanguage(rawValue: defaults.string(forKey: "app.language") ?? "") ?? .ru)
    }
    public func save(_ value: AppPreferences) throws {
        defaults.set(value.theme.rawValue, forKey: "app.theme")
        defaults.set(value.language.rawValue, forKey: "app.language")
        // Bundle localization is selected at process launch, including native menu titles.
        defaults.set([value.language.rawValue], forKey: "AppleLanguages")
        guard load() == value else { throw CollectionRepositoryError.permissionDenied }
    }
}
