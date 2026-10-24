import CardsCore
import CardsDesignSystem
import SwiftUI

public struct AppShellView: View {
    @Bindable private var model: AppShellModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openSettings) private var openSettings

    @State private var showsStudyDemo = false

    @State private var study: StudySessionModel?
    @State private var showsStudy = false
    @State private var studyError = false
    @State private var studyLoading = false
    private let makeStudy: (@MainActor () async throws -> StudySessionModel)?
    private let decks: DecksModel?
    private let exporter: CollectionExportModel?

    private let onboarding: OnboardingModel?
    private let statistics: StatisticsModel?
    private let today: TodayModel?
    private let library: LibraryModel?

    public init(model: AppShellModel, decks: DecksModel? = nil, library: LibraryModel? = nil, today: TodayModel? = nil, statistics: StatisticsModel? = nil, onboarding: OnboardingModel? = nil,
                makeStudy: (@MainActor () async throws -> StudySessionModel)? = nil, exporter: CollectionExportModel? = nil) {
        self.exporter = exporter
        self.model = model
        self.decks = decks
        self.makeStudy = makeStudy
        self.library = library
        self.statistics = statistics
        self.today = today
        self.onboarding = onboarding
    }

    public var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Label(String(localized: "Карточки", bundle: .module), systemImage: "square.3.layers.3d")
                    .font(.title2.weight(.semibold))
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)

                List(selection: Binding(get: { model.selection }, set: { commands.perform(.navigation($0)) })) {
                    ForEach(MainSection.allCases) { section in
                        Label(section.title, systemImage: section.symbol)
                            .tag(section)
                            .accessibilityIdentifier("navigation.\(section.rawValue)")
                    }
                }
                .listStyle(.sidebar)

                Button { commands.perform(.settings) } label: {
                    Label(String(localized: "Настройки", bundle: .module), systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .buttonStyle(.plain)
                .disabled(!commands.isEnabled(.settings))
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
                    Text(today?.snapshot?.asOf ?? model.currentDate, format: .dateTime.weekday(.wide).day().month(.wide).year())
                        .foregroundStyle(.secondary)
                }
                if model.selection == .decks {
                    if let decks { DecksView(model: decks, addNote: library.map { library in { id in
                        model.selection = .library
                        Task { await library.launcher.open(initialDeckID: id) }
                    } }) }
                    else { ProgressView("Открытие колод…") }
                } else if model.selection == .library {
                    if let library { LibraryView(model: library) }
                    else { ProgressView("Открытие карточек…") }
                } else if model.selection == .today {
                    if let today {
                        TodayView(model: today, onboarding: onboarding, opening: studyLoading, openingFailed: studyError, start: {
                            commands.perform(.startStudy)
                        }, discovery: library?.discovery, openCard: { id in openResult(.card(id)) },
                           openDecks: { commands.perform(.decks) }, openLibrary: { commands.perform(.library) },
                           demo: { showsStudyDemo = true })
                    } else { ProgressView("Загрузка Сегодня…") }
                } else if model.selection == .statistics {
                    if let statistics { StatisticsView(model: statistics) }
                    else { ProgressView("Загрузка статистики…") }
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
        .task(id: library?.discovery?.searchID) { await library?.discovery?.observeSearch() }
        .toolbar {
            if let discovery = library?.discovery {
                ToolbarItem(placement: .primaryAction) {
                    searchView(discovery).disabled(isModal)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let discovery = library?.discovery, discovery.searchPresented, !isModal {
                ZStack(alignment: .topTrailing) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { discovery.searchPresented = false }
                    searchView(discovery).resultsPanel.padding(.top, 8).padding(.trailing, 16)
                }
            }
        }
        .onChange(of: isModal) { _, value in if value { library?.discovery?.searchPresented = false } }
        // Keep modal presenters at the window root; a welcome child must not compete
        // with the study sheets on macOS 15.
        .sheet(isPresented: Binding(get: { onboarding?.showsCreator ?? false },
                                   set: { if !$0 { onboarding?.cancel() } })) {
            if let onboarding { OnboardingCreatorView(model: onboarding, completed: { today?.reload() }) }
        }
        .sheet(isPresented: $showsStudyDemo) { StudyDemoView(clock: model.studyClock, audio: model.makeDemoAudio()) }
        .sheet(isPresented: $showsStudy, onDismiss: { today?.reload() }) {
            if let study { StudyView(model: study, title: "Занятие") { showsStudy = false } }
        }
        .sheet(isPresented: Binding(get: { exporter?.isPresented ?? false }, set: { exporter?.isPresented = $0 })) {
            if let exporter { CollectionExportView(model: exporter) }
        }
        .environment(\.appCommands, commands)
        .safeAreaInset(edge: .bottom) {
            if let deletion = library?.deletion { CardDeletionUndoView(model: deletion).padding(.horizontal, 24).padding(.bottom, 8) }
        }
        .focusedSceneValue(\.appCommandContext, commands)
        .tint(CardsColor.accent.color)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshDate(); today?.reload(); statistics?.reload(); library?.discovery?.refreshDay() }
        }
    }
    private var isModal: Bool {
        showsStudy || showsStudyDemo || studyLoading || exporter?.isPresented == true || onboarding?.showsCreator == true ||
        decks?.deletion?.isPresented == true || decks?.editor != nil || decks?.moveEditor != nil || decks?.inspectedID != nil || decks?.studySetup != nil || library?.launcher.editor != nil || library?.launcher.isLoading == true || library?.deletion?.isPresented == true
    }

    private var commands: AppCommandContext {
        AppCommandContext(isEnabled: { id in
            guard !isModal else { return false }
            if id.section != nil || id == .settings { return true }
            switch id {
            case .exportData: return exporter != nil
            case .newDeck: return decks != nil
            case .newNote: return library != nil
            case .editNote: return model.selection == .library && library?.selectedRow != nil && library?.isLoading == false
            case .startStudy: return makeStudy != nil && today?.canOpenStudy == true
            default: return false // Import remains unavailable until its actual service exists.
            }
        }, perform: { id in
            if let section = id.section { model.selection = section; return }
            switch id {
            case .exportData: exporter?.present()
            case .settings: openSettings()
            case .newDeck: model.selection = .decks; decks?.create()
            case .newNote: model.selection = .library; library?.createNote()
            case .editNote: library?.editSelectedNote()
            case .startStudy: startStudy()
            default: break
            }
        })
    }

    private func searchView(_ discovery: DiscoveryModel) -> GlobalSearchView {
        GlobalSearchView(model: discovery, open: openResult, allCards: { text in
            model.selection = .library; library?.showAll(search: text)
        }, allDecks: { text in
            model.selection = .decks; decks?.resetFilters(); decks?.search = text
        }, create: { commands.perform(.newNote) })
    }

    private func openResult(_ destination: SearchDestination) {
        guard !isModal else { return }
        switch destination {
        case .card(let id): model.selection = .library; library?.showCard(id)
        case .deck(let id): model.selection = .decks; decks?.showDeck(id)
        }
    }

    private func startStudy() {
        guard let makeStudy, !studyLoading else { return }
        studyLoading = true; studyError = false
        Task {
            defer { studyLoading = false }
            do { study = try await makeStudy(); showsStudy = true }
            catch { studyError = true; today?.reload(); statistics?.reload() }
        }
    }

}
