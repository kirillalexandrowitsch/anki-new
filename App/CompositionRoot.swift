import CardsCore
import CardsFeatures
import CardsInfrastructure
import Foundation

/// One instance is owned by the App scene; windows share its collection lifecycle.
@MainActor
final class CompositionRoot {
    let clock: any CardsCore.Clock
    let collections: CollectionCoordinator
    private let access: any CollectionAccess

    init(clock: any CardsCore.Clock = SystemClock(), collectionAccess: (any CollectionAccess)? = nil) {
        self.clock = clock
        self.access = collectionAccess ?? DefaultCollectionAccess(clock: clock)
        self.collections = CollectionCoordinator(access: access)
    }

    func makeDecksModel(context: CollectionContext) async throws -> DecksModel {
        guard let provider = access as? any DeckWorkspaceAccess else { throw CollectionAccessError.staleContext }
        let workspace = try await provider.deckWorkspace(generation: context.generation)
        return DecksModel(workspace: workspace, clock: clock)
    }

    func makeEditorLauncher(context: CollectionContext) async throws -> EditorLauncherModel {
        guard let provider = access as? any EditorWorkspaceAccess else { throw CollectionAccessError.staleContext }
        let workspace = try await provider.editorWorkspace(generation: context.generation)
        return EditorLauncherModel(workspace: workspace, clock: clock)
    }

    func makeShellModel() -> AppShellModel {
        AppShellModel(clock: clock)
    }
}

/// Resolve sandbox paths lazily, keeping filesystem errors visible in coordinator state.
private actor DefaultCollectionAccess: DeckWorkspaceAccess, EditorWorkspaceAccess {
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

    func deckWorkspace(generation: UUID) async throws -> DeckWorkspace {
        guard let store else { throw CollectionAccessError.staleContext }
        return try await store.deckWorkspace(generation: generation)
    }

    func editorWorkspace(generation: UUID) async throws -> EditorWorkspace {
        guard let store else { throw CollectionAccessError.staleContext }
        return try await store.editorWorkspace(generation: generation)
    }

    func close(generation: UUID) async throws { try await store?.close(generation: generation) }
}
