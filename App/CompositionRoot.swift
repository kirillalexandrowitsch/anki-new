import CardsCore
import CardsFeatures
import CardsInfrastructure
import Foundation

/// One instance is owned by the App scene; windows share its collection lifecycle.
@MainActor
final class CompositionRoot {
    let clock: any CardsCore.Clock
    let collections: CollectionCoordinator

    init(clock: any CardsCore.Clock = SystemClock(), collectionAccess: (any CollectionAccess)? = nil) {
        self.clock = clock
        self.collections = CollectionCoordinator(access: collectionAccess ?? DefaultCollectionAccess(clock: clock))
    }

    func makeShellModel() -> AppShellModel {
        AppShellModel(clock: clock)
    }
}

/// Resolve sandbox paths lazily, keeping filesystem errors visible in coordinator state.
private actor DefaultCollectionAccess: CollectionAccess {
    let clock: any CardsCore.Clock
    var store: CollectionStore?

    init(clock: any CardsCore.Clock) { self.clock = clock }

    func open() async throws -> CollectionContext {
        if store == nil {
            let root: URL
            #if DEBUG
            if let value = UserDefaults.standard.string(forKey: "CollectionTestID"),
               let id = UUID(uuidString: value) {
                root = FileManager.default.temporaryDirectory.appendingPathComponent(id.uuidString)
            } else {
                root = try CollectionStore.applicationSupportRoot(bundleIdentifier: Bundle.main.bundleIdentifier!)
            }
            #else
            root = try CollectionStore.applicationSupportRoot(bundleIdentifier: Bundle.main.bundleIdentifier!)
            #endif
            store = CollectionStore(root: root, clock: clock)
        }
        return try await store!.open()
    }

    func close(generation: UUID) async throws { try await store?.close(generation: generation) }
}
