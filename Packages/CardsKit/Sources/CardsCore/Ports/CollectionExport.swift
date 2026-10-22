import Foundation

public enum CollectionExportFormat: String, CaseIterable, Sendable {
    case csv, tsv, cardsdeck, cardsbackup
    public var includesMedia: Bool { self == .cardsdeck || self == .cardsbackup }
    public var includesProgress: Bool { self == .cardsbackup }
    public var fileExtension: String { rawValue }
}

public protocol CollectionExportAccess: CollectionAccess {
    func export(to destination: URL, format: CollectionExportFormat, safeSpreadsheet: Bool, generation: UUID) async throws
}
