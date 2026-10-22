import CardsCore
import Foundation
import Observation

@MainActor @Observable
public final class StatisticsModel {
    public private(set) var snapshot: StatsSnapshot?
    public private(set) var errorMessage: String?
    public private(set) var refreshID = UUID()
    private let workspace: StatsWorkspace
    private let clock: any CardsCore.Clock
    private var observation: QueryObservation<StatsSnapshot>?
    private var active = true

    public init(workspace: StatsWorkspace, clock: any CardsCore.Clock) {
        self.workspace = workspace; self.clock = clock
    }

    public var period: StatsPeriod = .month {
        didSet { if period != oldValue { snapshot = nil; reload() } }
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
        var installed: QueryObservation<StatsSnapshot>?
        defer { installed?.cancel() }
        do {
            let source = try await workspace.queries.observeStatistics(StatsQuery(asOf: clock.now(), period: period,
                calendar: StudyDayCalculator(timeZoneID: TimeZone.current.identifier)))
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
            errorMessage = "Не удалось загрузить статистику. Повторите попытку."
        }
    }
    public func stop() {
        active = false
        observation?.cancel()
        snapshot = nil
    }
}
