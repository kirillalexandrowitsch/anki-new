import CardsCore
import CardsFeatures
import CardsInfrastructure
import Foundation

/// One instance is owned by the App scene; windows share its collection lifecycle.
@MainActor
final class CompositionRoot {
    let clock: any CardsCore.Clock
    let collections: CollectionCoordinator
    let audio = AudioPlaybackCoordinator()
    let audioPreferences = AudioPreferences()
    lazy var audioPreview = AudioPreviewModel(service: audio, preferences: audioPreferences)
    private var audioGenerations: Set<UUID> = []
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

    func makeLibraryModel(context: CollectionContext) async throws -> LibraryModel {
        guard let provider = access as? any EditorWorkspaceAccess else { throw CollectionAccessError.staleContext }
        let workspace = try await provider.editorWorkspace(generation: context.generation)
        try await prepareAudio(context: context)
        return LibraryModel(workspace: workspace, clock: clock, audio: audio, preferences: audioPreferences)
    }

    func makeOnboardingModel(context: CollectionContext) async throws -> OnboardingModel {
        guard let provider = access as? any OnboardingWorkspaceAccess else { throw CollectionAccessError.staleContext }
        let model = OnboardingModel(service: try await provider.onboarding(generation: context.generation))
        await model.load()
        return model
    }

    func makeTodayModel(context: CollectionContext) async throws -> TodayModel {
        guard let provider = access as? any TodayWorkspaceAccess else { throw CollectionAccessError.staleContext }
        return try await TodayModel(workspace: provider.todayWorkspace(generation: context.generation), clock: clock)
    }

    func makeStudyModel(context: CollectionContext) async throws -> StudySessionModel {
        guard let provider = access as? any StudyWorkspaceAccess else { throw CollectionAccessError.staleContext }
        try await prepareAudio(context: context)
        return try await StudySessionModel(service: provider.studySession(generation: context.generation), clock: clock,
            audio: AudioPreviewModel(service: audio, preferences: audioPreferences, generation: context.generation))
    }

    private func prepareAudio(context: CollectionContext) async throws {
        if audioGenerations.contains(context.generation) { return }
        guard let provider = access as? any AudioMediaAccess else { throw CollectionAccessError.staleContext }
        let media = try await provider.media(generation: context.generation)
        guard collections.context == context else { throw CollectionAccessError.staleContext }
        audio.register(generation: context.generation, media: media)
        audioGenerations.insert(context.generation)
        collections.onClose(context) { [weak self] in
            self?.audio.retire(generation: context.generation)
            self?.audioGenerations.remove(context.generation)
        }
    }

    func makeShellModel() -> AppShellModel {
        AppShellModel(clock: clock, audio: audio, preferences: audioPreferences)
    }
}

/// Resolve sandbox paths lazily, keeping filesystem errors visible in coordinator state.
private actor DefaultCollectionAccess: DeckWorkspaceAccess, EditorWorkspaceAccess, StudyWorkspaceAccess, AudioMediaAccess, TodayWorkspaceAccess, OnboardingWorkspaceAccess {
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

    func onboarding(generation: UUID) async throws -> any OnboardingService {
        guard let store else { throw CollectionAccessError.staleContext }
        return try await store.onboarding(generation: generation)
    }

    func todayWorkspace(generation: UUID) async throws -> TodayWorkspace {
        guard let store else { throw CollectionAccessError.staleContext }
        return try await store.todayWorkspace(generation: generation)
    }

    func studySession(generation: UUID) async throws -> any StudyReviewSessionService {
        guard let store else { throw CollectionAccessError.staleContext }
        return try await store.studySession(generation: generation)
    }

    func media(generation: UUID) async throws -> any MediaRepository {
        guard let store else { throw CollectionAccessError.staleContext }
        return try await store.media(generation: generation)
    }

    func close(generation: UUID) async throws { try await store?.close(generation: generation) }
}
