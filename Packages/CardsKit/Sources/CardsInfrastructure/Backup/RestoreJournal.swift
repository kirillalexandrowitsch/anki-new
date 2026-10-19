import CardsCore
import Foundation

/// External to both the live and rollback containers; only used under .operations.lock.
struct RestoreJournal: Codable {
    let version: Int
    let operation: UUID
    let previous: CollectionRegistry
    let replacement: CollectionID
    var committed: Bool

    static func url(_ root: URL) -> URL { root.appendingPathComponent("restore-journal.json") }
    func workspace(_ root: URL) -> URL {
        root.appendingPathComponent(".restore-" + operation.uuidString.lowercased())
    }
    static func container(_ root: URL, _ id: CollectionID) -> URL {
        root.appendingPathComponent("Collections/" + id.rawValue.uuidString.lowercased())
    }

    func install(root: URL, fault: BackupFault?) throws {
        let work = workspace(root)
        try BackupFiles.write(self, to: Self.url(root))
        try fault?(.journal)
        try BackupFiles.rename(Self.container(root, previous.lastSelected), to: work.appendingPathComponent("rollback"))
        try fault?(.oldRenamed)
        try BackupFiles.rename(work.appendingPathComponent("new"), to: Self.container(root, replacement))
        try fault?(.newRenamed)
        try BackupFiles.write(CollectionRegistry(schemaVersion: 1, collections: [replacement], lastSelected: replacement),
                              to: root.appendingPathComponent("registry.json"))
        try fault?(.registry)
        var final = self
        final.committed = true
        try BackupFiles.write(final, to: Self.url(root))
        try fault?(.committed)
        try Self.recover(root: root)
    }

    static func recover(root: URL, afterRollback: (@Sendable () throws -> Void)? = nil) throws {
        let files = FileManager.default
        let journalURL = url(root)
        guard files.fileExists(atPath: journalURL.path) else { return }
        try MediaFiles.regular(journalURL)
        let journal = try JSONDecoder().decode(Self.self, from: Data(contentsOf: journalURL))
        guard journal.version == 1, journal.previous.schemaVersion == 1,
              journal.previous.collections == [journal.previous.lastSelected] else {
            throw CollectionBackupError.invalidArchive
        }
        let work = journal.workspace(root)
        try MediaFiles.directory(work)
        let old = container(root, journal.previous.lastSelected)
        let new = container(root, journal.replacement)
        let rollback = work.appendingPathComponent("rollback")
        if journal.committed {
            try MediaFiles.directory(new)
        } else {
            if files.fileExists(atPath: rollback.path) {
                try MediaFiles.directory(rollback)
                // Retain rollback until the journal is gone. Recovery itself may crash at any point.
                let candidate = work.appendingPathComponent("recovery")
                if files.fileExists(atPath: candidate.path) { try files.removeItem(at: candidate) }
                try files.copyItem(at: rollback, to: candidate)
                try synchronizeTree(candidate)
                if files.fileExists(atPath: new.path) { try files.removeItem(at: new) }
                if old != new, files.fileExists(atPath: old.path) { try files.removeItem(at: old) }
                try BackupFiles.rename(candidate, to: old)
                try afterRollback?()
            } else {
                // No first rename happened, so only the old container may exist.
                try MediaFiles.directory(old)
                guard old == new || !files.fileExists(atPath: new.path) else {
                    throw CollectionBackupError.invalidArchive
                }
            }
            try BackupFiles.write(journal.previous, to: root.appendingPathComponent("registry.json"))
        }
        try files.removeItem(at: journalURL)
        try MediaFiles.synchronizeDirectory(root)
        try? files.removeItem(at: work) // after durable outcome, orphan workspace is harmless
    }

    static func synchronizeTree(_ directory: URL) throws {
        for child in try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw CollectionBackupError.invalidArchive }
            if values.isDirectory == true { try synchronizeTree(child) }
            else {
                try MediaFiles.regular(child)
                // Copied immutable media may be readonly. fsync requires no content changes.
                let file = try FileHandle(forReadingFrom: child)
                defer { try? file.close() }
                try file.synchronize()
            }
        }
        try MediaFiles.synchronizeDirectory(directory)
    }
}
