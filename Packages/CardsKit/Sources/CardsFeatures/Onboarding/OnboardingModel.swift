import CardsCore
import Foundation
import Observation

@MainActor @Observable
public final class OnboardingModel {
    public private(set) var isRequired = true
    public private(set) var isLoading = true
    public private(set) var isSaving = false
    public private(set) var showsWelcome = true
    public private(set) var showsCreator = false
    public private(set) var result: OnboardingResult?
    public private(set) var errorMessage: String?
    public var name = ""
    public var includeDemo = false
    private let service: any OnboardingService
    private var active = true
    private var attempt: CompleteOnboardingCommand?

    public init(service: any OnboardingService) { self.service = service }
    public var nameError: String? { (try? EntityName(name)) == nil ? "Введите название колоды." : nil }
    public var canSave: Bool { active && !isLoading && !isSaving && nameError == nil }

    public func load() async {
        guard active, !isSaving else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let required = try await service.isRequired()
            guard active, !Task.isCancelled else { return }
            isRequired = required
        } catch {
            guard active, !Task.isCancelled else { return }
            errorMessage = "Не удалось проверить первый запуск. Повторите попытку."
        }
    }

    public func create() {
        guard active, isRequired, !isLoading, !isSaving, errorMessage == nil else { return }
        name = ""; includeDemo = false; attempt = nil
        showsCreator = true
    }

    public func cancel() {
        guard !isSaving else { return }
        showsCreator = false; showsWelcome = false
        name = ""; includeDemo = false; attempt = nil; errorMessage = nil
    }

    public func save() async -> Bool {
        guard canSave, showsCreator, let validated = try? EntityName(name) else { return false }
        if attempt?.name != validated || attempt?.includeDemo != includeDemo {
            attempt = CompleteOnboardingCommand(commandID: CommandID(), deckID: DeckID(),
                name: validated, includeDemo: includeDemo)
        }
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        do {
            let saved = try await service.complete(attempt!)
            guard active else { return false }
            result = saved; isRequired = false; showsCreator = false
            return true
        } catch {
            guard active else { return false }
            if error as? CollectionRepositoryError == .validation(.invalidField("onboardingAlreadyStarted")) {
                isRequired = false; showsCreator = false
            } else if error as? CollectionRepositoryError == .insufficientSpace {
                errorMessage = "Недостаточно места. Освободите место на диске и повторите создание."
            } else if error as? CollectionRepositoryError == .staleContext {
                errorMessage = "Коллекция закрыта. Откройте её заново, чтобы продолжить."
            } else {
                errorMessage = "Не удалось создать колоду. Данные не добавлены. Повторите попытку или отмените создание."
            }
            return false
        }
    }

    public func dismissSuccess() { result = nil }
    public func stop() { active = false; showsCreator = false; result = nil }
}
