import CardsCore
import Foundation
import Observation

public enum TodayContentState: Equatable, Sendable {
    case noDecks, noCards, ready, futureLearning, dailyLimit, sessionLimit, skipped, allDone
}

@MainActor @Observable
public final class TodayModel {
    public private(set) var snapshot: TodayStudySnapshot?
    public private(set) var errorMessage: String?
    public private(set) var refreshID = UUID()
    private let workspace: TodayWorkspace
    private let clock: any CardsCore.Clock
    private var observation: QueryObservation<TodayStudySnapshot>?
    private var active = true

    public init(workspace: TodayWorkspace, clock: any CardsCore.Clock) {
        self.workspace = workspace; self.clock = clock
    }

    public var contentState: TodayContentState? {
        guard let snapshot else { return nil }
        if snapshot.decks.isEmpty { return .noDecks }
        if snapshot.counts.total > 0 { return .ready }
        if snapshot.futureIsLearning { return .futureLearning }
        if snapshot.emptyReasons.contains(.dailyLimit) { return .dailyLimit }
        if snapshot.emptyReasons.contains(.sessionLimit) { return .sessionLimit }
        if snapshot.emptyReasons.contains(.skipped) { return .skipped }
        if snapshot.emptyReasons.contains(.noCardsInScope) { return .noCards }
        return .allDone
    }
    public var canOpenStudy: Bool {
        guard active, errorMessage == nil, let snapshot else { return false }
        return snapshot.resumableSessionID != nil || snapshot.counts.total > 0
    }
    public var actionTitle: String {
        snapshot?.resumableSessionID == nil ? "Начать занятие" : "Продолжить занятие"
    }
    public func reload() {
        guard active else { return }
        observation?.cancel()
        refreshID = UUID()
    }

    /// A view-owned task; new asOf is installed on timer, foreground and navigation.
    public func observe() async {
        guard active else { return }
        let request = refreshID
        errorMessage = nil
        var installed: QueryObservation<TodayStudySnapshot>?
        defer { installed?.cancel() }
        do {
            let source = try await workspace.queries.observeStudyToday(asOf: clock.now(),
                calendar: StudyDayCalculator(timeZoneID: TimeZone.current.identifier))
            installed = source
            guard active, !Task.isCancelled, request == refreshID else { return }
            observation = source
            for try await value in source {
                guard active, !Task.isCancelled, request == refreshID else { return }
                guard value.generation == workspace.generation else { throw CollectionAccessError.staleContext }
                snapshot = value
            }
        } catch {
            guard active, !Task.isCancelled, request == refreshID else { return }
            snapshot = nil
            errorMessage = "Не удалось загрузить Сегодня. Повторите попытку."
        }
    }
    public func stop() {
        active = false
        observation?.cancel()
        snapshot = nil
    }
}
