import CardsDesignSystem
import SwiftUI

public struct AppShellView: View {
    @Bindable private var model: AppShellModel
    @Environment(\.scenePhase) private var scenePhase

    public init(model: AppShellModel) {
        self.model = model
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
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel(model.selection.title)
                    .accessibilityIdentifier("section.title")
                if model.selection == .today {
                    Text(model.currentDate, format: .dateTime.weekday(.wide).day().month(.wide).year())
                        .foregroundStyle(.secondary)
                }
                SectionPlaceholder(title: String(localized: "Ваша коллекция", bundle: .module),
                                   symbol: model.selection.symbol,
                                   message: model.selection.message)
            }
            .accessibilityElement(children: .contain)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.background)
        }
        .tint(.indigo)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshDate() }
        }
    }
}
