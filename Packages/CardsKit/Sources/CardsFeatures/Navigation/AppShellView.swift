import CardsDesignSystem
import SwiftUI

public struct AppShellView: View {
    @Bindable private var model: AppShellModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var showsStudyDemo = false

    private let decks: DecksModel?

    private let library: LibraryModel?

    public init(model: AppShellModel, decks: DecksModel? = nil, library: LibraryModel? = nil) {
        self.model = model
        self.decks = decks
        self.library = library
    }

    public var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Label(String(localized: "Карточки", bundle: .module), systemImage: "square.3.layers.3d")
                    .font(.title2.weight(.semibold))
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)

                List(selection: $model.selection) {
                    ForEach(MainSection.allCases) { section in
                        Label(section.title, systemImage: section.symbol)
                            .tag(section)
                            .accessibilityIdentifier("navigation.\(section.rawValue)")
                    }
                }
                .listStyle(.sidebar)

                SettingsLink {
                    Label(String(localized: "Настройки", bundle: .module), systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("navigation.settings")
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 280)
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.selection.title)
                    .cardsText(.windowTitle)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel(model.selection.title)
                    .accessibilityIdentifier("section.title")
                if model.selection == .today {
                    Text(model.currentDate, format: .dateTime.weekday(.wide).day().month(.wide).year())
                        .foregroundStyle(.secondary)
                }
                if model.selection == .decks {
                    if let decks { DecksView(model: decks) }
                    else { ProgressView("Открытие колод…") }
                } else if model.selection == .library {
                    if let library { LibraryView(model: library) }
                    else { ProgressView("Открытие карточек…") }
                } else if model.selection == .today {
                    CardsPanel("Занятие") {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Пробное занятие на трёх примерах. Данные вашей коллекции не меняются.")
                                .foregroundStyle(.secondary)
                            Button("Пробное занятие") { showsStudyDemo = true }
                                .buttonStyle(CardsButtonStyle(.primary))
                                .accessibilityIdentifier("study.demo")
                        }
                    }
                    Spacer()
                } else {
                    SectionPlaceholder(title: String(localized: "Ваша коллекция", bundle: .module),
                                       symbol: model.selection.symbol,
                                       message: model.selection.message)
                }
            }
            .accessibilityElement(children: .contain)
            .padding(CardsSpacing.section)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CardsColor.window.color)
        }
        .sheet(isPresented: $showsStudyDemo) { StudyDemoView(clock: model.studyClock) }
        .tint(CardsColor.accent.color)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshDate() }
        }
    }
}
