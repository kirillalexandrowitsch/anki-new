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

        Settings {
            SettingsView()
        }
    }
}

/// Each window owns its navigation state; services come from the application root.
private struct MainWindow: View {
    @State private var model: AppShellModel

    init(composition: CompositionRoot) {
        _model = State(initialValue: composition.makeShellModel())
    }

    var body: some View {
        AppShellView(model: model)
            .frame(minWidth: 800, minHeight: 540)
    }
}
