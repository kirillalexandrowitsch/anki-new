import CardsCore
import CardsFeatures
import Foundation
import Testing

@MainActor private final class StubExportPanel: ExportSavePanel {
    var result: URL?
    var calls = 0
    func choose(format: CollectionExportFormat) async -> URL? { calls += 1; return result }
}
private actor ExportRecorder {
    var requests: [(URL, CollectionExportFormat, Bool)] = []
    var fail = false
    func write(_ url: URL, _ format: CollectionExportFormat, _ safe: Bool) throws {
        requests.append((url, format, safe))
        if fail { throw CocoaError(.fileWriteNoPermission) }
    }
    func setFailure() { fail = true }
    func count() -> Int { requests.count }
    func last() -> (URL, CollectionExportFormat, Bool)? { requests.last }
}

@Test @MainActor func exportCancelNeverCallsServiceFailureHasNoSuccessAndFormatsGateOptions() async throws {
    let panel = StubExportPanel()
    let recorder = ExportRecorder()
    let model = CollectionExportModel(panel: panel) { try await recorder.write($0, $1, $2) }
    func settle() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    }
    model.present(); model.save(); model.save()
    try await settle()
    #expect(!model.busy && model.savedURL == nil && model.error == nil)
    #expect(panel.calls == 1)
    #expect(await recorder.count() == 0)
    panel.result = URL(fileURLWithPath: "/tmp/synthetic.cardsdeck")
    model.format = .cardsdeck; model.safeSpreadsheet = true
    model.save()
    try await settle()
    #expect(model.savedURL == panel.result && model.error == nil)
    let request = try #require(await recorder.last())
    #expect(request.1 == .cardsdeck && request.2 == false)
    #expect(!CollectionExportFormat.csv.includesMedia && !CollectionExportFormat.tsv.includesProgress)
    #expect(CollectionExportFormat.cardsdeck.includesMedia && !CollectionExportFormat.cardsdeck.includesProgress)
    #expect(CollectionExportFormat.cardsbackup.includesProgress && CollectionExportFormat.cardsbackup.includesMedia)
    model.present(); await recorder.setFailure(); model.save()
    try await settle()
    #expect(model.savedURL == nil && model.error != nil && !model.busy)
    model.stop()
    #expect(!model.isPresented)
}

@MainActor private final class PendingExportPanel: ExportSavePanel {
    var continuation: CheckedContinuation<URL?, Never>?
    func choose(format: CollectionExportFormat) async -> URL? {
        await withCheckedContinuation { continuation = $0 }
    }
}

@Test @MainActor func retiringCollectionWhilePanelIsOpenIgnoresLateSelection() async throws {
    let panel = PendingExportPanel()
    let recorder = ExportRecorder()
    let model = CollectionExportModel(panel: panel) { try await recorder.write($0, $1, $2) }
    model.present(); model.save()
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while panel.continuation == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    let pending = try #require(panel.continuation)
    model.stop()
    pending.resume(returning: URL(fileURLWithPath: "/tmp/retired.csv"))
    await Task.yield()
    #expect(await recorder.count() == 0)
    #expect(model.savedURL == nil && !model.isPresented && !model.busy)
}
