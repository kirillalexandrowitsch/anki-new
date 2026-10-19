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
        }
        .defaultSize(width: 1100, height: 760)

        #if DEBUG
        Window("Дизайн-система", id: "design-system") {
            CardsGallery().frame(minWidth: 700, minHeight: 540)
        }
        .defaultSize(width: 1120, height: 900)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        #endif

        Settings {
            SettingsView()
        }
    }
}

/// Each window owns its navigation state; services come from the application root.
private struct MainWindow: View {
    @State private var model: AppShellModel
    private let collections: CollectionCoordinator
    private let composition: CompositionRoot
    @State private var decks: DecksModel?
    @State private var editorLauncher: EditorLauncherModel?
    @State private var decksError = false
    @State private var decksCloseToken: UUID?

    init(composition: CompositionRoot) {
        _model = State(initialValue: composition.makeShellModel())
        collections = composition.collections
        self.composition = composition
    }

    var body: some View {
        AppShellView(model: model, decks: decks, editorLauncher: editorLauncher)
            .frame(minWidth: 800, minHeight: 540)
            .task { await collections.open() }
            .task(id: collections.context) {
                if let token = decksCloseToken { collections.removeObservation(token) }
                decksCloseToken = nil
                decks?.stop()
                decks = nil
                editorLauncher?.stop()
                editorLauncher = nil
                decksError = false
                guard let context = collections.context else { return }
                do {
                    let loaded = try await composition.makeDecksModel(context: context)
                    guard !Task.isCancelled, collections.context == context else { loaded.stop(); return }
                    let notes = try await composition.makeEditorLauncher(context: context)
                    guard !Task.isCancelled, collections.context == context else { loaded.stop(); notes.stop(); return }
                    editorLauncher = notes
                    decks = loaded
                    decksCloseToken = collections.onClose(context) { loaded.stop(); notes.stop() }
                } catch {
                    if collections.context == context { decksError = true }
                }
            }
            .onDisappear {
                if let token = decksCloseToken { collections.removeObservation(token) }
                decks?.stop()
                editorLauncher?.stop()
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
