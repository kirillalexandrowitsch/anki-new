import CardsCore
import Foundation
import Darwin

struct CollectionManifest: Codable {
    let schemaVersion: Int
    let containerVersion: Int
    let id: CollectionID
    let name: EntityName
}

struct CollectionRegistry: Codable {
    let schemaVersion: Int
    let collections: [CollectionID]
    let lastSelected: CollectionID
}

/// All filesystem/SQLite work runs on this actor, never on the UI actor.
public actor CollectionStore: CollectionExportAccess, DeckWorkspaceAccess, EditorWorkspaceAccess, StudyWorkspaceAccess, DeckStudyWorkspaceAccess, TodayWorkspaceAccess, OnboardingWorkspaceAccess, PreferencesWorkspaceAccess {
    private let root: URL
    private let clock: any CardsCore.Clock
    private var active: OwnedCollection?
    private let mediaFault: MediaFault?
    private let backupFault: BackupFault?
    private var operationInProgress = false

    private final class OwnedCollection {
        let context: CollectionContext
        let database: CollectionDatabase
        let lease: CollectionLease
        let operationLease: CollectionLease
        let writer: CollectionWriter
        let media: CollectionMediaRepository
        var closing = false

        init(context: CollectionContext, database: CollectionDatabase, lease: CollectionLease,
             clock: any CardsCore.Clock, directory: URL, mediaFault: MediaFault?, operationLease: CollectionLease) {
            self.context = context
            self.database = database
            self.lease = lease
            self.operationLease = operationLease
            let writer = CollectionWriter(database: database, clock: clock)
            self.writer = writer
            self.media = CollectionMediaRepository(root: directory, writer: writer, fault: mediaFault)
        }

        deinit {
            try? database.close()
            withExtendedLifetime(lease) {}
        }
    }

    public init(root: URL, clock: any CardsCore.Clock = SystemClock()) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.clock = clock
        self.mediaFault = nil
        self.backupFault = nil
    }

    init(root: URL, clock: any CardsCore.Clock = SystemClock(), mediaFault: @escaping MediaFault) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.clock = clock
        self.mediaFault = mediaFault
        self.backupFault = nil
    }

    init(root: URL, backupFault: @escaping BackupFault) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.clock = SystemClock()
        self.mediaFault = nil
        self.backupFault = backupFault
    }

    public static func applicationSupportRoot(bundleIdentifier: String) throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    public func open() throws -> CollectionContext {
        guard active == nil else { throw CollectionAccessError.alreadyOpen }
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let operationLease = try CollectionLease(url: root.appendingPathComponent(".operations.lock"))
        try RestoreJournal.recover(root: root)
        return try openLocked(operationLease: operationLease)
    }

    private func openLocked(operationLease: CollectionLease) throws -> CollectionContext {
        let files = FileManager.default
        let registryLease = try CollectionLease(url: root.appendingPathComponent(".registry.lock"))
        defer { registryLease.release() }
        let registryURL = root.appendingPathComponent("registry.json")
        if files.fileExists(atPath: registryURL.path) {
            let registry = try JSONDecoder().decode(CollectionRegistry.self, from: Data(contentsOf: registryURL))
            guard registry.schemaVersion == 1 else { throw CollectionAccessError.unsupportedVersion }
            guard registry.collections == [registry.lastSelected] else {
                throw CollectionAccessError.invalidContainer
            }
            let directory = containerURL(registry.lastSelected)
            let lease = try CollectionLease(url: directory.appendingPathComponent("collection.lock"))
            let manifest = try JSONDecoder().decode(CollectionManifest.self,
                from: Data(contentsOf: directory.appendingPathComponent("collection.json")))
            guard manifest.schemaVersion == 1, manifest.containerVersion == 1 else {
                throw CollectionAccessError.unsupportedVersion
            }
            guard manifest.id == registry.lastSelected,
                  files.fileExists(atPath: directory.appendingPathComponent("collection.sqlite").path) else {
                throw CollectionAccessError.invalidContainer
            }
            let databaseURL = directory.appendingPathComponent("collection.sqlite")
            // Existing containers may never take the creation path, even for an empty file.
            let reader = try CollectionMigrations.readOnlyQueue(databaseURL)
            let metadata: CollectionMetadata
            do {
                metadata = try reader.read { try CollectionMetadata.fetch($0) }
                try reader.close()
            } catch {
                try? reader.close()
                throw error
            }
            guard metadata.id == manifest.id else { throw CollectionDatabaseError.collectionIdentityMismatch }
            let database = try CollectionDatabase(url: databaseURL)
            do {
                try MediaJournal.recover(pool: database.pool, root: directory)
            } catch {
                try? database.close()
                lease.release()
                throw error
            }
            let context = CollectionContext(id: manifest.id, name: metadata.name)
            active = OwnedCollection(context: context, database: database, lease: lease, clock: clock, directory: directory, mediaFault: mediaFault, operationLease: operationLease)
            return context
        }

        let id = CollectionID()
        let name = try EntityName("Моя коллекция")
        let directory = containerURL(id)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let lease = try CollectionLease(url: directory.appendingPathComponent("collection.lock"))
        defer { withExtendedLifetime(lease) {} }
        var database: CollectionDatabase?
        do {
            for child in ["Media", "Staging", "Trash"] {
                try files.createDirectory(at: directory.appendingPathComponent(child), withIntermediateDirectories: true)
            }
            let opened = try CollectionDatabase(url: directory.appendingPathComponent("collection.sqlite"),
                newCollection: NewCollectionMetadata(id: id, name: name,
                    createdAt: EpochMilliseconds(date: clock.now())))
            database = opened
            try write(CollectionManifest(schemaVersion: 1, containerVersion: 1, id: id, name: name),
                      to: directory.appendingPathComponent("collection.json"))
            try write(CollectionRegistry(schemaVersion: 1, collections: [id], lastSelected: id), to: registryURL)
            let context = CollectionContext(id: id, name: name)
            active = OwnedCollection(context: context, database: opened, lease: lease, clock: clock, directory: directory, mediaFault: mediaFault, operationLease: operationLease)
            return context
        } catch {
            try? database?.close()
            // The unpublished UUID is private to this attempt. Never remove an existing collection.
            try? files.removeItem(at: directory)
            throw error
        }
    }

    public func metadata(generation: UUID) async throws -> CollectionMetadata {
        guard let owned = active, !owned.closing, owned.context.generation == generation else {
            throw CollectionAccessError.staleContext
        }
        let result = try await owned.database.metadata()
        guard active?.context.generation == generation, active?.closing == false else {
            throw CollectionAccessError.staleContext
        }
        return result
    }

    public func deckWorkspace(generation: UUID) throws -> DeckWorkspace {
        try DeckWorkspace(generation: generation, repository: decks(generation: generation),
                          queries: queries(generation: generation),
                          deletions: SQLiteDeckDeletion(writer: writer(generation: generation), clock: clock))
    }

    public func decks(generation: UUID) throws -> any DeckRepository {
        SQLiteDeckRepository(writer: try writer(generation: generation))
    }

    public func editorWorkspace(generation: UUID) throws -> EditorWorkspace {
        try EditorWorkspace(generation: generation, notes: notes(generation: generation),
                            queries: queries(generation: generation),
                            deletions: SQLiteCardDeletion(writer: writer(generation: generation), clock: clock))
    }

    public func studyPreferences(generation: UUID) throws -> any StudyPreferencesRepository {
        SQLiteStudyPreferences(writer: try writer(generation: generation))
    }

    public func onboarding(generation: UUID) throws -> any OnboardingService {
        SQLiteOnboardingService(writer: try writer(generation: generation), clock: clock)
    }

    public func statsWorkspace(generation: UUID) throws -> StatsWorkspace {
        StatsWorkspace(generation: generation,
            queries: SQLiteCollectionQueries(writer: try writer(generation: generation), generation: generation))
    }

    public func todayWorkspace(generation: UUID) throws -> TodayWorkspace {
        TodayWorkspace(generation: generation,
            queries: SQLiteCollectionQueries(writer: try writer(generation: generation), generation: generation))
    }

    public func deckStudy(generation: UUID) throws -> any DeckStudyService {
        SQLiteDeckStudy(writer: try writer(generation: generation), generation: generation, clock: clock)
    }

    public func studySession(generation: UUID) async throws -> any StudyReviewSessionService {
        let ownedWriter = try writer(generation: generation)
        let configuration = try StudyQueueConfiguration(generation: generation,
            calendar: StudyDayCalculator(timeZoneID: TimeZone.current.identifier))
        return try await SQLiteStudySession.open(writer: ownedWriter, configuration: configuration, clock: clock, useCollectionPreferences: true)
    }

    public func notes(generation: UUID) throws -> any NoteRepository {
        SQLiteNoteRepository(writer: try writer(generation: generation), clock: clock)
    }

    public func collectionInfo(generation: UUID) throws -> any CollectionInfoRepository {
        SQLiteCollectionInfoRepository(writer: try writer(generation: generation))
    }

    public func queries(generation: UUID) throws -> any CollectionQueryService {
        SQLiteCollectionQueries(writer: try writer(generation: generation), generation: generation)
    }

    public func media(generation: UUID) throws -> any MediaRepository {
        guard let owned = active, !owned.closing, owned.context.generation == generation else {
            throw MediaStorageError.staleContext
        }
        return owned.media
    }

    private func writer(generation: UUID) throws -> CollectionWriter {
        guard let owned = active, !owned.closing, owned.context.generation == generation else {
            throw CollectionRepositoryError.staleContext
        }
        return owned.writer
    }

    public func close(generation: UUID) async throws {
        guard let owned = active, owned.context.generation == generation else { return }
        guard !operationInProgress else { throw CollectionBackupError.operationInProgress }
        owned.closing = true
        await owned.media.close()
        try await owned.writer.close()
        owned.lease.release() // async frame destruction need not precede the caller's next open
        owned.operationLease.release()
        if active === owned { active = nil } // release lease only after the pool has closed
    }

    /// Publishes only a verified archive, never replaces an existing backup.
    public func createBackup(to destination: URL, generation: UUID) async throws {
        guard let owned = active, !owned.closing, owned.context.generation == generation else {
            throw CollectionBackupError.staleContext
        }
        guard !operationInProgress else { throw CollectionBackupError.operationInProgress }
        guard BackupFiles.outside(destination, root: root),
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw CollectionBackupError.invalidDestination
        }
        operationInProgress = true
        defer { operationInProgress = false }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        let work = try BackupFiles.exportWorkDirectory(for: destination)
        defer { try? FileManager.default.removeItem(at: work) }
        let source = containerURL(owned.context.id)
        let now = clock.now()
        try await owned.writer.mediaAccess { pool in
            try BackupArchive.snapshot(pool: pool, source: source, staging: work.appendingPathComponent("snapshot"), now: now)
        }
        let archive = work.appendingPathComponent("backup.cardsbackup")
        try BackupArchive.create(staging: work.appendingPathComponent("snapshot"), archiveURL: archive)
        _ = try BackupArchive.extract(archive, to: work.appendingPathComponent("verify"))
        try BackupFiles.publishExport(archive, to: destination)
    }

    public func export(to destination: URL, format: CollectionExportFormat, safeSpreadsheet: Bool = false, generation: UUID) async throws {
        guard destination.pathExtension.lowercased() == format.fileExtension else {
            throw CollectionExportError.invalidDestination
        }
        if format == .cardsbackup {
            try await createBackup(to: destination, generation: generation)
            return
        }
        guard let owned = active, !owned.closing, owned.context.generation == generation else {
            throw CollectionAccessError.staleContext
        }
        guard !operationInProgress else { throw CollectionBackupError.operationInProgress }
        guard BackupFiles.outside(destination, root: root),
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw CollectionExportError.invalidDestination
        }
        operationInProgress = true
        defer { operationInProgress = false }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        let work = try BackupFiles.exportWorkDirectory(for: destination)
        defer { try? FileManager.default.removeItem(at: work) }
        let snapshot = work.appendingPathComponent("snapshot")
        let source = containerURL(owned.context.id)
        let now = clock.now()
        try await owned.writer.mediaAccess { pool in
            try BackupArchive.snapshot(pool: pool, source: source, staging: snapshot, now: now)
        }
        let candidate = work.appendingPathComponent("export." + format.fileExtension)
        try CollectionExporter.create(snapshot: snapshot, destination: candidate, format: format, safe: safeSpreadsheet)
        try BackupFiles.publishExport(candidate, to: destination)
    }

    /// Full validation precedes invalidation of the old generation. Startup recovers any interrupted swap.
    public func restoreBackup(from archive: URL, generation: UUID) async throws -> CollectionContext {
        guard let owned = active, !owned.closing, owned.context.generation == generation else {
            throw CollectionBackupError.staleContext
        }
        guard !operationInProgress else { throw CollectionBackupError.operationInProgress }
        operationInProgress = true
        defer { operationInProgress = false }
        let scoped = archive.startAccessingSecurityScopedResource()
        defer { if scoped { archive.stopAccessingSecurityScopedResource() } }
        let operation = UUID()
        let previous = CollectionRegistry(schemaVersion: 1, collections: [owned.context.id], lastSelected: owned.context.id)
        let work = root.appendingPathComponent(".restore-" + operation.uuidString.lowercased())
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        defer {
            if !FileManager.default.fileExists(atPath: RestoreJournal.url(root).path) {
                try? FileManager.default.removeItem(at: work)
            }
        }
        let staging = work.appendingPathComponent("new")
        let manifest = try BackupArchive.extract(archive, to: staging)
        let target = containerURL(manifest.collectionID)
        guard manifest.collectionID == owned.context.id || !FileManager.default.fileExists(atPath: target.path) else {
            throw CollectionBackupError.invalidDestination
        }
        try FileManager.default.removeItem(at: staging.appendingPathComponent("manifest.json"))
        for entry in manifest.files where entry.path.hasPrefix("Media/") {
            try FileManager.default.setAttributes([.posixPermissions: 0o444],
                ofItemAtPath: staging.appendingPathComponent(entry.path).path)
        }
        for name in ["Staging", "Trash"] {
            try FileManager.default.createDirectory(at: staging.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        try RestoreJournal.synchronizeTree(staging)
        try MediaFiles.synchronizeDirectory(work)
        try MediaFiles.synchronizeDirectory(root)
        try Task.checkCancellation()
        owned.closing = true
        await owned.media.close()
        try await owned.writer.close()
        owned.lease.release()
        active = nil
        // Keep the stable external lease throughout both renames, registry commit and reopen.
        do {
            let journal = RestoreJournal(version: 1, operation: operation, previous: previous,
                replacement: manifest.collectionID, committed: false)
            try journal.install(root: root, fault: backupFault)
            return try openLocked(operationLease: owned.operationLease)
        } catch {
            owned.operationLease.release()
            throw error
        }
    }

    private func containerURL(_ id: CollectionID) -> URL {
        root.appendingPathComponent("Collections", isDirectory: true)
            .appendingPathComponent(id.rawValue.uuidString.lowercased(), isDirectory: true)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
