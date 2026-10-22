import CardsDesignSystem
import Foundation
import CardsCore
import CardsFeatures
import SwiftUI

@main
struct AnkiNewApp: App {
    private let composition = CompositionRoot()

    var body: some Scene {
        WindowGroup {
            MainWindow(composition: composition)
                .preferredColorScheme(composition.appearance.colorScheme)
        }
        .defaultSize(width: 1100, height: 760)
        .commands { AppCommands() }

        #if DEBUG
        Window("Дизайн-система", id: "design-system") {
            CardsGallery().frame(minWidth: 700, minHeight: 540)
                .preferredColorScheme(composition.appearance.colorScheme)
        }
        .defaultSize(width: 1120, height: 900)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        #endif

        Settings {
            PreferencesWindow(composition: composition)
        }
    }
}

/// Each window owns its navigation state; services come from the application root.
private struct MainWindow: View {
    @State private var model: AppShellModel
    private let collections: CollectionCoordinator
    private let composition: CompositionRoot
    @State private var decks: DecksModel?
    @State private var today: TodayModel?
    @State private var onboarding: OnboardingModel?
    @State private var library: LibraryModel?
    @State private var exporter: CollectionExportModel?
    @State private var decksError = false
    @State private var decksCloseToken: UUID?
    @State private var studyCloseToken: UUID?

    init(composition: CompositionRoot) {
        _model = State(initialValue: composition.makeShellModel())
        collections = composition.collections
        self.composition = composition
    }

    var body: some View {
        AppShellView(model: model, decks: decks, library: library, today: today, onboarding: onboarding, makeStudy: {
            guard let context = collections.context else { throw CollectionAccessError.staleContext }
            let study = try await composition.makeStudyModel(context: context)
            guard collections.context == context else { study.stop(); throw CollectionAccessError.staleContext }
            if let token = studyCloseToken { collections.removeObservation(token) }
            studyCloseToken = collections.onClose(context) { study.stop() }
            return study
        }, exporter: exporter)
            .frame(minWidth: 800, minHeight: 540)
            .task { await collections.open() }
            .task(id: collections.context) {
                if let token = decksCloseToken { collections.removeObservation(token) }
                decksCloseToken = nil
                decks?.stop()
                decks = nil
                library?.stop()
                library = nil
                onboarding?.stop()
                onboarding = nil
                today?.stop()
                today = nil
                exporter?.stop()
                exporter = nil
                decksError = false
                guard let context = collections.context else { return }
                do {
                    let loaded = try await composition.makeDecksModel(context: context)
                    guard !Task.isCancelled, collections.context == context else { loaded.stop(); return }
                    let notes = try await composition.makeLibraryModel(context: context)
                    guard !Task.isCancelled, collections.context == context else { loaded.stop(); notes.stop(); return }
                    let dashboard = try await composition.makeTodayModel(context: context)
                    guard !Task.isCancelled, collections.context == context else { loaded.stop(); notes.stop(); dashboard.stop(); return }
                    let firstRun = try await composition.makeOnboardingModel(context: context)
                    guard !Task.isCancelled, collections.context == context else {
                        loaded.stop(); notes.stop(); dashboard.stop(); firstRun.stop(); return
                    }
                    let exportModel = try composition.makeExportModel(context: context)
                    exporter = exportModel
                    onboarding = firstRun
                    today = dashboard
                    library = notes
                    decks = loaded
                    decksCloseToken = collections.onClose(context) { loaded.stop(); notes.stop(); dashboard.stop(); firstRun.stop(); exportModel.stop() }
                } catch {
                    if collections.context == context { decksError = true }
                }
            }
            .onDisappear {
                if let token = studyCloseToken { collections.removeObservation(token) }
                if let token = decksCloseToken { collections.removeObservation(token) }
                exporter?.stop()
                decks?.stop()
                onboarding?.stop()
                library?.stop()
                today?.stop()
            }
            .overlay {
                if collections.isOpening {
                    ProgressView("Открытие коллекции…")
                        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                } else if decksError {
                    VStack(spacing: 16) {
                        Text("Не удалось открыть колоды")
                        Button("Повторить") { Task { await collections.close(); await collections.open() } }
                    }.padding(24).background(.regularMaterial)
                } else if let error = collections.error {
                    VStack(spacing: 16) {
                        Image(systemName: "lock.trianglebadge.exclamationmark").font(.largeTitle)
                        Text(error as? CollectionAccessError == .locked
                             ? "Коллекция уже открыта" : "Не удалось открыть коллекцию")
                            .font(.headline)
                        Text("Закройте коллекцию в другом экземпляре приложения и повторите попытку. Если ошибка сохраняется, проверьте доступ к папке коллекции.")
                            .multilineTextAlignment(.center)
                        Button("Повторить") { Task { await collections.open() } }
                    }
                    .padding(32).frame(maxWidth: 460).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
    }
}

/// Settings owns a generation-bound model independently from the main window's drafts.
private struct PreferencesWindow: View {
    let composition: CompositionRoot
    @State private var model: StudyPreferencesModel?
    @State private var closeToken: UUID?
    var body: some View {
        SettingsView(appearance: composition.appearance, study: model,
            collectionName: composition.collections.context?.name.displayValue, audio: composition.audioPreview)
            .task { await composition.collections.open() }
            .task(id: composition.collections.context) {
                if let closeToken { composition.collections.removeObservation(closeToken) }
                model?.stop(); model = nil
                guard let context = composition.collections.context else { return }
                do {
                    let loaded = try await composition.makePreferencesModel(context: context)
                    guard !Task.isCancelled, composition.collections.context == context else { loaded.stop(); return }
                    model = loaded
                    closeToken = composition.collections.onClose(context) { loaded.stop() }
                } catch { model = nil }
            }
    }
}
