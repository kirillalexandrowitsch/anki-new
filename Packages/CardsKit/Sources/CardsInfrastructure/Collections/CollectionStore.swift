import CardsCore
import Foundation

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
public actor CollectionStore: CollectionAccess {
    private let root: URL
    private let clock: any CardsCore.Clock
    private var active: OwnedCollection?
    private let mediaFault: MediaFault?

    private final class OwnedCollection {
        let context: CollectionContext
        let database: CollectionDatabase
        let lease: CollectionLease
        let writer: CollectionWriter
        let media: CollectionMediaRepository
        var closing = false

        init(context: CollectionContext, database: CollectionDatabase, lease: CollectionLease,
             clock: any CardsCore.Clock, directory: URL, mediaFault: MediaFault?) {
            self.context = context
            self.database = database
            self.lease = lease
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
    }

    init(root: URL, clock: any CardsCore.Clock = SystemClock(), mediaFault: @escaping MediaFault) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.clock = clock
        self.mediaFault = mediaFault
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
            active = OwnedCollection(context: context, database: database, lease: lease, clock: clock, directory: directory, mediaFault: mediaFault)
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
            active = OwnedCollection(context: context, database: opened, lease: lease, clock: clock, directory: directory, mediaFault: mediaFault)
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

    public func decks(generation: UUID) throws -> any DeckRepository {
        SQLiteDeckRepository(writer: try writer(generation: generation))
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
        owned.closing = true
        await owned.media.close()
        try await owned.writer.close()
        owned.lease.release() // async frame destruction need not precede the caller's next open
        if active === owned { active = nil } // release lease only after the pool has closed
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
