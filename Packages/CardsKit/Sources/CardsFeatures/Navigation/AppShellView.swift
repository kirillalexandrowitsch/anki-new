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

    private let onboarding: OnboardingModel?
    private let today: TodayModel?
    private let library: LibraryModel?

    public init(model: AppShellModel, decks: DecksModel? = nil, library: LibraryModel? = nil, today: TodayModel? = nil, onboarding: OnboardingModel? = nil,
                makeStudy: (@MainActor () async throws -> StudySessionModel)? = nil) {
        self.model = model
        self.decks = decks
        self.makeStudy = makeStudy
        self.library = library
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
                    if let decks { DecksView(model: decks) }
                    else { ProgressView("Открытие колод…") }
                } else if model.selection == .library {
                    if let library { LibraryView(model: library) }
                    else { ProgressView("Открытие карточек…") }
                } else if model.selection == .today {
                    if let today {
                        TodayView(model: today, onboarding: onboarding, opening: studyLoading, openingFailed: studyError, start: {
                            commands.perform(.startStudy)
                        }, openDecks: { commands.perform(.decks) }, openLibrary: { commands.perform(.library) },
                           demo: { showsStudyDemo = true })
                    } else { ProgressView("Загрузка Сегодня…") }
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
        .environment(\.appCommands, commands)
        .focusedSceneValue(\.appCommandContext, commands)
        .tint(CardsColor.accent.color)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshDate(); today?.reload() }
        }
    }
    private var isModal: Bool {
        showsStudy || showsStudyDemo || studyLoading || onboarding?.showsCreator == true ||
        decks?.editor != nil || library?.launcher.editor != nil || library?.launcher.isLoading == true
    }

    private var commands: AppCommandContext {
        AppCommandContext(isEnabled: { id in
            guard !isModal else { return false }
            if id.section != nil || id == .settings { return true }
            switch id {
            case .newDeck: return decks != nil
            case .newNote: return library != nil
            case .editNote: return model.selection == .library && library?.selectedRow != nil && library?.isLoading == false
            case .startStudy: return makeStudy != nil && today?.canOpenStudy == true
            default: return false // Import remains unavailable until its actual service exists.
            }
        }, perform: { id in
            if let section = id.section { model.selection = section; return }
            switch id {
            case .settings: openSettings()
            case .newDeck: model.selection = .decks; decks?.create()
            case .newNote: model.selection = .library; library?.createNote()
            case .editNote: library?.editSelectedNote()
            case .startStudy: startStudy()
            default: break
            }
        })
    }

    private func startStudy() {
        guard let makeStudy, !studyLoading else { return }
        studyLoading = true; studyError = false
        Task {
            defer { studyLoading = false }
            do { study = try await makeStudy(); showsStudy = true }
            catch { studyError = true; today?.reload() }
        }
    }

}
