import CardsCore
import Foundation
import XCTest
@testable import AnkiNew

final class CompositionRootTests: XCTestCase {
    @MainActor func testRootInjectsServicesAndCreatesIndependentWindowModels() {
        struct FixedClock: CardsCore.Clock {
            func now() -> Date { Date(timeIntervalSince1970: 123) }
        }
        let root = CompositionRoot(clock: FixedClock())
        let first = root.makeShellModel()
        let second = root.makeShellModel()
        XCTAssertEqual(first.currentDate, Date(timeIntervalSince1970: 123))
        first.selection = .decks
        XCTAssertEqual(second.selection, .today)
    }
}

private actor TestCollectionAccess: CollectionAccess {
    let id = CollectionID()
    var closed: [UUID] = []
    var waiting: [CheckedContinuation<CollectionContext, any Error>] = []
    var delayed = false
    var failClose = false

    func configure(delayed: Bool = false, failClose: Bool = false) {
        self.delayed = delayed
        self.failClose = failClose
    }

    func open() async throws -> CollectionContext {
        if delayed {
            return try await withCheckedThrowingContinuation { waiting.append($0) }
        }
        return CollectionContext(id: id, name: try EntityName("Fixture"))
    }

    func close(generation: UUID) throws {
        if failClose { throw CollectionAccessError.fileSystem(5) }
        closed.append(generation)
    }

    func count() -> Int { waiting.count }
    func complete(_ context: CollectionContext) { waiting.removeFirst().resume(returning: context) }
    func closedGenerations() -> [UUID] { closed }
}

final class CollectionCoordinatorTests: XCTestCase {
    @MainActor func testCloseStopsObservationsAndRejectsDelayedResultAfterReopen() async throws {
        let access = TestCollectionAccess()
        let root = CompositionRoot(collectionAccess: access)
        let coordinator = root.collections
        await coordinator.open()
        let old = try XCTUnwrap(coordinator.context)
        var cancelled = false
        coordinator.onClose(old) { cancelled = true }
        var windowValue = "old"
        await coordinator.close()
        XCTAssertTrue(cancelled)
        XCTAssertNil(coordinator.context)
        await coordinator.open()
        let new = try XCTUnwrap(coordinator.context)
        XCTAssertEqual(old.id, new.id)
        XCTAssertNotEqual(old.generation, new.generation)
        XCTAssertFalse(coordinator.accept(old) { windowValue = "late result" })
        XCTAssertEqual(windowValue, "old")
        XCTAssertTrue(coordinator.accept(new) { windowValue = "new" })
        XCTAssertEqual(windowValue, "new")
        var obsoleteObservationStopped = false
        XCTAssertNil(coordinator.onClose(old) { obsoleteObservationStopped = true })
        XCTAssertTrue(obsoleteObservationStopped)
        let removed = try XCTUnwrap(coordinator.onClose(new) { XCTFail("Removed observation must not fire") })
        coordinator.removeObservation(removed)
        await coordinator.close()
        let closed = await access.closedGenerations()
        XCTAssertEqual(closed, [old.generation, new.generation])
    }

    @MainActor func testPendingOpenCannotReplaceNewWindowAndReleasesItsLease() async throws {
        let access = TestCollectionAccess()
        await access.configure(delayed: true)
        let coordinator = CollectionCoordinator(access: access)
        let old = CollectionContext(id: CollectionID(), name: try EntityName("Old"))
        let new = CollectionContext(id: CollectionID(), name: try EntityName("New"))
        let first = Task { await coordinator.open() }
        while await access.count() < 1 { await Task.yield() }
        await coordinator.close()
        let second = Task { await coordinator.open() }
        while await access.count() < 2 { await Task.yield() }
        await access.complete(old)
        await first.value
        XCTAssertNil(coordinator.context)
        await access.complete(new)
        await second.value
        XCTAssertEqual(coordinator.context, new)
        XCTAssertNil(coordinator.error)
        let closed = await access.closedGenerations()
        XCTAssertEqual(closed, [old.generation])
        await coordinator.close()
    }

    @MainActor func testFailedCloseIsRetriedBeforeOpeningAnotherContext() async throws {
        let access = TestCollectionAccess()
        let coordinator = CollectionCoordinator(access: access)
        await coordinator.open()
        let old = try XCTUnwrap(coordinator.context)
        await access.configure(failClose: true)
        await coordinator.close()
        XCTAssertNil(coordinator.context)
        XCTAssertNotNil(coordinator.error)
        XCTAssertFalse(coordinator.accept(old) { XCTFail("Closed context updated UI") })
        await access.configure()
        await coordinator.open()
        let closed = await access.closedGenerations()
        XCTAssertEqual(closed, [old.generation])
        XCTAssertNotEqual(coordinator.context?.generation, old.generation)
        XCTAssertNil(coordinator.error)
        await coordinator.close()
    }
}
