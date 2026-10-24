import CardsCore
import CardsFeatures
import CardsTestSupport
@testable import CardsInfrastructure
import Foundation
import GRDB
import Testing

@Test func notificationReadSnapshotRetentionAndReopen() async throws {
    let directory = try TestDirectory(), clock = TestClock()
    let store = CollectionStore(root: directory.url, clock: clock)
    let context = try await store.open()
    let repository = try await store.notifications(generation: context.generation)
    let observation = try await repository.observe()
    var iterator = observation.makeAsyncIterator()
    #expect(try await iterator.next() == [])
    let first = UUID(), second = UUID(), arrival = UUID()
    try await repository.record(id: first, event: .backupSucceeded)
    #expect(try await iterator.next()?.first?.id == first)
    clock.advance(by: 1)
    let reminder = LocalNotificationEvent.reminderScheduled(nextFireAt: clock.now().addingTimeInterval(3600))
    try await repository.record(id: second, event: reminder)
    let snapshot = try await repository.messages()
    #expect(snapshot.map(\.id) == [second, first] && snapshot.allSatisfy { $0.readAt == nil })
    clock.advance(by: 1)
    try await repository.record(id: arrival, event: .backupFailed)
    try await repository.markRead(ids: snapshot.map(\.id))
    let readAt = clock.now()
    let saved = try await repository.messages()
    #expect(saved.first?.id == arrival && saved.first?.readAt == nil)
    #expect(saved.dropFirst().allSatisfy { $0.readAt == readAt })
    clock.advance(by: 10)
    try await repository.markRead(ids: [first, second, first, UUID()])
    #expect(try await repository.messages() == saved)
    try await store.close(generation: context.generation)
    await #expect(throws: CollectionRepositoryError.staleContext) { _ = try await iterator.next() }
    await #expect(throws: CollectionRepositoryError.staleContext) { try await repository.markRead(ids: [arrival]) }
    await #expect(throws: CollectionRepositoryError.staleContext) { try await repository.record(id: UUID(), event: .backupFailed) }
    let reopened = try await store.open()
    let fresh = try await store.notifications(generation: reopened.generation)
    #expect(try await fresh.messages() == saved)
    #expect(try await fresh.messages().first(where: { $0.id == second })?.event == reminder)
    for i in 0..<105 {
        clock.advance(by: 1)
        try await fresh.record(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", i))!, event: .backupSucceeded)
    }
    let bounded = try await fresh.messages()
    #expect(bounded.count == 100 && bounded.first?.id.uuidString.hasSuffix("000000000104") == true)
    #expect(bounded.last?.id.uuidString.hasSuffix("000000000005") == true)
    try await fresh.record(id: bounded[0].id, event: .backupFailed)
    #expect(try await fresh.messages() == bounded) // Identical operation ID cannot create a second outcome.
    try await fresh.markRead(ids: bounded.map(\.id))
    #expect(try await fresh.messages().allSatisfy { $0.readAt != nil })
    try await store.close(generation: reopened.generation)
}

@Test func notificationTransactionsRollbackAndEqualTimestampOrder() async throws {
    let directory = try TestDirectory(), clock = TestClock()
    let database = try CollectionDatabase(url: directory.url.appendingPathComponent("notification.sqlite"),
        newCollection: NewCollectionMetadata(id: CollectionID(), name: EntityName("Synthetic"), createdAt: EpochMilliseconds(0)))
    defer { try? database.close() }
    let writer = CollectionWriter(database: database, clock: clock)
    let repository = SQLiteLocalNotifications(writer: writer, clock: clock)
    for i in 0..<101 {
        try await repository.record(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", i))!, event: .backupFailed)
    }
    let before = try await repository.messages()
    #expect(before.count == 100 && before.first?.id.uuidString.hasSuffix("000000000100") == true)
    #expect(before.last?.id.uuidString.hasSuffix("000000000001") == true)
    #expect(try await database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM local_notifications") } == 100)
    try await database.pool.write { db in
        try db.execute(sql: "CREATE TRIGGER fail_notification_prune BEFORE DELETE ON local_notifications BEGIN SELECT RAISE(ABORT,'injected'); END")
    }
    await #expect(throws: (any Error).self) { try await repository.record(id: UUID(), event: .backupSucceeded) }
    #expect(try await repository.messages() == before)
    try await database.pool.write { db in
        try db.execute(sql: "CREATE TRIGGER fail_notification_read BEFORE UPDATE ON local_notifications WHEN old.id LIKE '%002' BEGIN SELECT RAISE(ABORT,'injected'); END")
    }
    await #expect(throws: (any Error).self) { try await repository.markRead(ids: before.map(\.id)) }
    #expect(try await repository.messages() == before)
    #expect(try await database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM processed_commands") } == 0)
    try await writer.close()
}

@Test func notificationBackupActualOutcomesAndSnapshotBoundary() async throws {
    let directory = try TestDirectory()
    let store = CollectionStore(root: directory.url.appendingPathComponent("collection"))
    let context = try await store.open()
    let repository = try await store.notifications(generation: context.generation)
    let destination = directory.url.appendingPathComponent("verified.cardsbackup")
    let reminderID = UUID()
    try await repository.record(id: reminderID, event: .reminderScheduled(nextFireAt: Date(timeIntervalSince1970: 1_792_400_000)))
    try await repository.markRead(ids: [reminderID])
    let before = try await repository.messages()
    try await store.export(to: destination, format: .cardsbackup, generation: context.generation)
    let success = try await repository.messages()
    #expect(success.count == 2 && success.filter { $0.event == .backupSucceeded }.count == 1)
    let contents = try Data(contentsOf: destination)
    let staging = directory.url.appendingPathComponent("verify")
    _ = try BackupArchive.extract(destination, to: staging)
    let reader = try CollectionMigrations.readOnlyQueue(staging.appendingPathComponent("collection.sqlite"))
    #expect(try await reader.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM local_notifications WHERE readAt IS NOT NULL") } == 1)
    try reader.close()
    let restoredStore = CollectionStore(root: directory.url.appendingPathComponent("restored"))
    let empty = try await restoredStore.open()
    let restored = try await restoredStore.restoreBackup(from: destination, generation: empty.generation)
    #expect(try await restoredStore.notifications(generation: restored.generation).messages() == before)
    try await restoredStore.close(generation: restored.generation)
    await #expect(throws: CollectionBackupError.invalidDestination) {
        try await store.createBackup(to: destination, generation: context.generation)
    }
    #expect(try Data(contentsOf: destination) == contents)
    let failed = try await repository.messages()
    #expect(failed.count == 3 && failed.filter { $0.event == .backupFailed }.count == 1)
    let cancel = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await store.createBackup(to: directory.url.appendingPathComponent("cancel.cardsbackup"), generation: context.generation)
    }
    await #expect(throws: (any Error).self) { try await cancel.value }
    #expect(try await repository.messages() == failed)
    try await store.close(generation: context.generation)
    await #expect(throws: CollectionBackupError.staleContext) {
        try await store.createBackup(to: destination, generation: context.generation)
    }
    let reopened = try await store.open()
    #expect(try await store.notifications(generation: reopened.generation).messages() == failed)
    try await store.close(generation: reopened.generation)
}

@MainActor private func notificationWait(_ predicate: () -> Bool) async throws {
    for _ in 0..<500 {
        if predicate() { return }; try await Task.sleep(for: .milliseconds(10))
    }
    throw InjectedFault.triggered
}

@Test @MainActor func notificationModelLiveReadErrorRetryAndStop() async throws {
    let directory = try TestDirectory()
    let database = try CollectionDatabase(url: directory.url.appendingPathComponent("notification.sqlite"),
        newCollection: NewCollectionMetadata(id: CollectionID(), name: EntityName("Synthetic"), createdAt: EpochMilliseconds(0)))
    defer { try? database.close() }
    let writer = CollectionWriter(database: database, clock: TestClock())
    let repository = SQLiteLocalNotifications(writer: writer, clock: TestClock())
    let model = NotificationsModel(repository: repository)
    let task = Task { await model.observe() }
    defer { task.cancel(); model.stop() }
    try await notificationWait { model.loaded }
    #expect(model.messages.isEmpty && model.unreadCount == 0)
    let id = UUID()
    try await repository.record(id: id, event: .backupFailed)
    try await notificationWait { model.unreadCount == 1 }
    model.isPresented = true
    #expect(try await repository.messages().first?.readAt == nil)
    try await database.pool.write { db in
        try db.execute(sql: "CREATE TRIGGER fail_read BEFORE UPDATE ON local_notifications BEGIN SELECT RAISE(ABORT,'injected'); END")
    }
    #expect(await model.markRead(ids: [id]) == false)
    #expect(model.error != nil && model.unreadCount == 1 && model.isPresented)
    try await database.pool.write { try $0.execute(sql: "DROP TRIGGER fail_read") }
    #expect(await model.markRead(ids: [id]))
    try await notificationWait { model.unreadCount == 0 }
    #expect(model.error == nil)
    model.stop()
    try await repository.record(id: UUID(), event: .backupSucceeded)
    #expect(model.messages.isEmpty && !model.isPresented)
    #expect(await model.markRead(ids: [id]) == false)
    try await writer.close()
}
