import CardsCore
import Foundation
import Observation

@MainActor @Observable
public final class DeckStudySetupModel: Identifiable {
    public let id = UUID()
    public let root: Deck
    public let scopes: [DeckQueryRow]
    public var scopeID: DeckID { didSet { invalidate() } }
    public var newText = "" { didSet { invalidate() } }
    public var reviewText = "" { didSet { invalidate() } }
    public var sessionText = "" { didSet { invalidate() } }
    public private(set) var requestID = UUID()
    public private(set) var preview: DeckStudyPreview?
    public private(set) var isLoaded = false
    public private(set) var isRefreshing = false
    public private(set) var isStarting = false
    public private(set) var errorMessage: String?
    public private(set) var study: StudySessionModel?
    private let service: any DeckStudyService
    private let makeStudy: @MainActor (any StudyReviewSessionService) -> StudySessionModel
    private var active = true

    public init(root: Deck, rows: [DeckQueryRow], service: any DeckStudyService,
                makeStudy: @escaping @MainActor (any StudyReviewSessionService) -> StudySessionModel) {
        self.root = root; self.scopeID = root.id; self.service = service; self.makeStudy = makeStudy
        let hierarchy = DeckHierarchy(rows: rows)
        scopes = rows.filter { $0.id == root.id || hierarchy.ancestors(of: $0.id).contains { $0.id == root.id } }
    }
    private func number(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(text), (0...9999).contains(value) else { return nil }
        return value
    }
    public var request: DeckStudyRequest? {
        guard let new = number(newText), let review = number(reviewText),
              sessionText.isEmpty || number(sessionText) != nil else { return nil }
        return try? DeckStudyRequest(rootID: root.id, scopeID: scopeID, new: new, review: review,
                                    sessionLimit: number(sessionText))
    }
    public var canStart: Bool { active && isLoaded && !isRefreshing && !isStarting && request != nil && preview?.canStart == true }
    public var unavailableReason: String? {
        if let errorMessage { return errorMessage }
        if !isLoaded { return "Загрузка постоянных настроек…" }
        if request == nil { return "Введите целые числа от 0 до 9999. Общий предел можно оставить пустым." }
        if isRefreshing || preview == nil { return "Проверка доступных карточек…" }
        guard let preview else { return nil }
        if preview.hasActiveSession { return "Уже есть незавершённое занятие. Продолжите его в разделе «Сегодня»." }
        if preview.canStart { return nil }
        if preview.reasons.contains(.noCardsInScope) { return "В выбранной области нет карточек. Добавьте карточки или выберите подколоду." }
        if preview.reasons.contains(.sessionLimit) { return "Общий предел занятия равен нулю." }
        if preview.reasons.contains(.dailyLimit) { return "Дневная квота исчерпана или равна нулю. Увеличьте временные лимиты." }
        if preview.reasons.contains(.futureOnly) { return "Сейчас нет доступных карточек: срок следующего повторения ещё не наступил." }
        return "Сейчас нет доступных карточек: проверьте приостановку, откладывание и сроки повторения."
    }
    private func invalidate() { requestID = UUID(); preview = nil; isRefreshing = false; errorMessage = nil }
    public func load() async {
        guard active, !isLoaded else { return }
        do {
            let saved = try await service.defaults()
            guard active, !Task.isCancelled else { return }
            newText = String(saved.newLimit); reviewText = String(saved.reviewLimit); isLoaded = true; requestID = UUID()
        } catch { if active { errorMessage = "Не удалось загрузить настройки. Повторите попытку." } }
    }
    public func refresh() async {
        guard active, isLoaded, let request else { return }
        let token = requestID
        isRefreshing = true; errorMessage = nil
        do {
            let result = try await service.preview(request)
            guard active, !Task.isCancelled, token == requestID else { return }
            preview = result
        } catch {
            guard active, !Task.isCancelled, token == requestID else { return }
            errorMessage = "Не удалось проверить область занятия. Колода могла быть перемещена или удалена. Обновите список и повторите."
        }
        if token == requestID { isRefreshing = false }
    }
    public func start() async {
        guard canStart, let request else { return }
        isStarting = true; errorMessage = nil
        defer { isStarting = false }
        do {
            let service = try await service.start(request)
            guard active else { return }
            study = makeStudy(service)
        } catch {
            guard active else { return }
            preview = nil
            if error as? DeckStudyError == .activeSession {
                errorMessage = "Уже есть незавершённое занятие. Продолжите его в разделе «Сегодня»."
            } else {
                errorMessage = "Не удалось начать занятие: очередь или область изменились. Обновите проверку и повторите."
            }
        }
    }
    public func stop() { active = false; requestID = UUID(); study?.stop() }
}
