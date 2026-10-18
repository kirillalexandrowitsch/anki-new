import CardsCore
@testable import CardsInfrastructure
import Darwin
import Foundation
import Testing

private struct ContainerFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    func remove() { try? FileManager.default.removeItem(at: root) }
    func directory(_ context: CollectionContext) -> URL {
        root.appendingPathComponent("Collections/\(context.id.rawValue.uuidString.lowercased())")
    }
    func store() -> CollectionStore { CollectionStore(root: root) }
}

@Test func containerCreatesRegistryManifestAndDatabaseWithOneIdentity() async throws {
    let fixture = ContainerFixture()
    defer { fixture.remove() }
    let first = fixture.store()
    let context = try await first.open()
    let directory = fixture.directory(context)
    let decoder = JSONDecoder()
    let manifest = try decoder.decode(CollectionManifest.self,
        from: Data(contentsOf: directory.appendingPathComponent("collection.json")))
    let registry = try decoder.decode(CollectionRegistry.self,
        from: Data(contentsOf: fixture.root.appendingPathComponent("registry.json")))
    let metadata = try await first.metadata(generation: context.generation)
    #expect(registry.collections == [context.id] && registry.lastSelected == context.id)
    #expect(manifest.id == context.id && metadata.id == context.id)
    #expect(manifest.name == context.name && metadata.name == context.name)
    #expect(manifest.containerVersion == metadata.containerVersion && manifest.schemaVersion == 1)
    for path in ["Media", "Staging", "Trash", "collection.lock", "collection.sqlite"] {
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path))
    }
    await #expect(throws: CollectionAccessError.alreadyOpen) { try await first.open() }
    let competitor = fixture.store()
    await #expect(throws: CollectionAccessError.locked) { try await competitor.open() }
    try await first.close(generation: context.generation)
    let reopened = try await competitor.open()
    #expect(reopened.id == context.id && reopened.generation != context.generation)
    // An old close and old read cannot affect the new context.
    try await competitor.close(generation: context.generation)
    await #expect(throws: CollectionAccessError.staleContext) {
        try await competitor.metadata(generation: context.generation)
    }
    #expect(try await competitor.metadata(generation: reopened.generation).id == context.id)
    try await competitor.close(generation: reopened.generation)
}

/// Runs a genuinely separate owner. Pipe handshake avoids a sleep-based lock race.
private func python(_ script: String, path: URL) throws -> (Process, Pipe) {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-c", script, path.path]
    process.standardOutput = output
    try process.run()
    return (process, output)
}

@Test func anotherProcessCannotAcquireLiveLeaseAndCrashReleasesStaleLock() async throws {
    let fixture = ContainerFixture()
    defer { fixture.remove() }
    let store = fixture.store()
    let context = try await store.open()
    let lock = fixture.directory(context).appendingPathComponent("collection.lock")
    let (contender, output) = try python("""
        import fcntl, sys
        with open(sys.argv[1], 'r+') as f:
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print('blocked', flush=True)
                sys.exit(0)
            sys.exit(2)
        """, path: lock)
    contender.waitUntilExit()
    #expect(contender.terminationStatus == 0)
    #expect(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) == "blocked\n")
    try await store.close(generation: context.generation)

    let (owner, ready) = try python("""
        import fcntl, sys, time
        with open(sys.argv[1], 'r+') as f:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            print('R', end='', flush=True)
            time.sleep(30)
        """, path: lock)
    defer { if owner.isRunning { kill(owner.processIdentifier, SIGKILL); owner.waitUntilExit() } }
    #expect(try ready.fileHandleForReading.read(upToCount: 1) == Data("R".utf8))
    let databaseURL = fixture.directory(context).appendingPathComponent("collection.sqlite")
    let before = try Data(contentsOf: databaseURL)
    await #expect(throws: CollectionAccessError.locked) { try await store.open() }
    #expect(try Data(contentsOf: databaseURL) == before)
    kill(owner.processIdentifier, SIGKILL)
    owner.waitUntilExit()
    #expect(owner.terminationReason == .uncaughtSignal)
    #expect(FileManager.default.fileExists(atPath: lock.path))
    let recovered = try await store.open()
    #expect(recovered.id == context.id)
    try await store.close(generation: recovered.generation)
}

@Test func identityMismatchIsRejectedBeforeWritableOpenAndReleasesLease() async throws {
    let fixture = ContainerFixture()
    defer { fixture.remove() }
    let store = fixture.store()
    let context = try await store.open()
    try await store.close(generation: context.generation)
    let directory = fixture.directory(context)
    let manifestURL = directory.appendingPathComponent("collection.json")
    let databaseURL = directory.appendingPathComponent("collection.sqlite")
    let original = try Data(contentsOf: manifestURL)
    let before = try Data(contentsOf: databaseURL)
    // Change registry and manifest together, keeping a foreign database in the selected container.
    let foreignID = CollectionID()
    let renamed = fixture.root.appendingPathComponent("Collections/\(foreignID.rawValue.uuidString.lowercased())")
    try FileManager.default.moveItem(at: directory, to: renamed)
    try JSONEncoder().encode(CollectionRegistry(schemaVersion: 1, collections: [foreignID], lastSelected: foreignID))
        .write(to: fixture.root.appendingPathComponent("registry.json"))
    try JSONEncoder().encode(CollectionManifest(schemaVersion: 1, containerVersion: 1,
        id: foreignID, name: context.name)).write(to: renamed.appendingPathComponent("collection.json"))
    await #expect(throws: CollectionDatabaseError.collectionIdentityMismatch) { try await store.open() }
    #expect(try Data(contentsOf: renamed.appendingPathComponent("collection.sqlite")) == before)
    // Fix the fixture; the failed attempt must not hold either lock.
    try FileManager.default.moveItem(at: renamed, to: directory)
    try original.write(to: manifestURL)
    try JSONEncoder().encode(CollectionRegistry(schemaVersion: 1, collections: [context.id], lastSelected: context.id))
        .write(to: fixture.root.appendingPathComponent("registry.json"))
    let recovered = try await fixture.store().open()
    #expect(recovered.id == context.id)
    // Releasing the owning actor also closes its pool before releasing the lease.
}

@Test func invalidManifestAndMissingDatabaseAreNotRecreated() async throws {
    let fixture = ContainerFixture()
    defer { fixture.remove() }
    let store = fixture.store()
    let context = try await store.open()
    try await store.close(generation: context.generation)
    let directory = fixture.directory(context)
    let manifestURL = directory.appendingPathComponent("collection.json")
    let original = try Data(contentsOf: manifestURL)
    try JSONEncoder().encode(CollectionManifest(schemaVersion: 99, containerVersion: 1,
        id: context.id, name: context.name)).write(to: manifestURL)
    await #expect(throws: CollectionAccessError.unsupportedVersion) { try await store.open() }
    try JSONEncoder().encode(CollectionManifest(schemaVersion: 1, containerVersion: 1,
        id: CollectionID(), name: context.name)).write(to: manifestURL)
    await #expect(throws: CollectionAccessError.invalidContainer) { try await store.open() }
    try original.write(to: manifestURL)
    try FileManager.default.removeItem(at: directory.appendingPathComponent("collection.sqlite"))
    await #expect(throws: CollectionAccessError.invalidContainer) { try await store.open() }
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("collection.sqlite").path))
    try Data().write(to: directory.appendingPathComponent("collection.sqlite"))
    await #expect(throws: (any Error).self) { try await store.open() }
    #expect(try Data(contentsOf: directory.appendingPathComponent("collection.sqlite")).isEmpty)
}

@Test func concurrentFirstOpenPublishesOnlyOneCollection() async throws {
    let fixture = ContainerFixture()
    defer { fixture.remove() }
    let first = fixture.store()
    let second = fixture.store()
    let attempts = await withTaskGroup(of: Result<CollectionContext, any Error>.self) { group in
        for store in [first, second] {
            group.addTask {
                do { return .success(try await store.open()) }
                catch { return .failure(error) }
            }
        }
        var results: [Result<CollectionContext, any Error>] = []
        for await value in group { results.append(value) }
        return results
    }
    let opened = attempts.compactMap { try? $0.get() }
    #expect(opened.count == 1)
    for attempt in attempts {
        if case .failure(let error) = attempt { #expect(error as? CollectionAccessError == .locked) }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("Collections").path).count == 1)
    let context = try #require(opened.first)
    try await first.close(generation: context.generation)
    try await second.close(generation: context.generation)
}

@Test func failedCreationDoesNotPublishRegistryAndCanRetry() async throws {
    struct InvalidClock: CardsCore.Clock { func now() -> Date { Date(timeIntervalSince1970: .nan) } }
    let fixture = ContainerFixture()
    defer { fixture.remove() }
    let invalid = CollectionStore(root: fixture.root, clock: InvalidClock())
    await #expect(throws: ValidationError.self) { try await invalid.open() }
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("registry.json").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("Collections").path).isEmpty)
    let valid = fixture.store()
    let context = try await valid.open()
    try await valid.close(generation: context.generation)
}
