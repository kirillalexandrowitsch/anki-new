import AppKit
import CardsCore
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor public protocol ExportSavePanel {
    func choose(format: CollectionExportFormat) async -> URL?
}

@MainActor public struct NativeExportSavePanel: ExportSavePanel {
    public init() {}
    public func choose(format: CollectionExportFormat) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Сохранить экспорт"
        panel.nameFieldStringValue = "Collection"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let completion: (NSApplication.ModalResponse) -> Void = { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
                if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
                else { panel.begin(completionHandler: completion) }
                if Task.isCancelled { panel.cancel(nil) }
            }
        } onCancel: {
            Task { @MainActor in panel.cancel(nil) }
        }
    }
}

@MainActor @Observable public final class CollectionExportModel {
    public var isPresented = false
    public var format: CollectionExportFormat = .csv
    public var safeSpreadsheet = false
    public private(set) var busy = false
    public private(set) var savedURL: URL?
    public private(set) var error: String?
    private let panel: any ExportSavePanel
    private let export: @Sendable (URL, CollectionExportFormat, Bool) async throws -> Void
    private var work: Task<Void, Never>?
    private var attempt = UUID()

    public init(panel: any ExportSavePanel = NativeExportSavePanel(),
                export: @escaping @Sendable (URL, CollectionExportFormat, Bool) async throws -> Void) {
        self.panel = panel; self.export = export
    }
    public func present() { guard !busy else { return }; savedURL = nil; error = nil; isPresented = true }
    public func save() {
        guard !busy else { return }
        busy = true; error = nil; savedURL = nil
        let id = UUID(); attempt = id
        let selected = format
        let safe = safeSpreadsheet && (selected == .csv || selected == .tsv)
        work = Task {
            let url = await panel.choose(format: selected)
            guard !Task.isCancelled, attempt == id else { return }
            guard let url else { busy = false; return }
            do {
                try await export(url, selected, safe)
                guard !Task.isCancelled, attempt == id else { return }
                savedURL = url
            } catch {
                guard !Task.isCancelled, attempt == id else { return }
                self.error = "Не удалось сохранить файл. Проверьте доступ к папке и выберите новое имя. " + error.localizedDescription
            }
            busy = false
        }
    }
    public func stop() { attempt = UUID(); work?.cancel(); work = nil; busy = false; isPresented = false }
}
