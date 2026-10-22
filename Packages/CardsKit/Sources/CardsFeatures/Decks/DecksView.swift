import CardsCore
import CardsDesignSystem
import SwiftUI

public struct DecksView: View {
    @Bindable private var model: DecksModel
    @Environment(\.appCommands) private var commands
    @State private var focus: DeckFocus?
    @State private var returnFocus: DeckFocus = .create

    private enum DeckFocus: Hashable { case create, edit(DeckID) }

    public init(model: DecksModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Мои колоды").font(.title2.weight(.semibold))
                Spacer()
                DeckActionButton(title: "Новая колода", symbol: "plus", identifier: "decks.create",
                                 primary: true, wantsFocus: focus == .create) {
                    returnFocus = .create
                    focus = nil
                    if let commands { commands.perform(.newDeck) } else { model.create() }
                }
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                Button("Повторить") { model.reload() }
            } else if model.isLoading {
                ProgressView("Загрузка колод…")
            } else if model.rows.isEmpty {
                ContentUnavailableView("Пока нет колод", systemImage: "rectangle.stack",
                    description: Text("Создайте колоду для своих карточек."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.rows) { row in
                            HStack(spacing: 14) {
                                Image(systemName: row.deck.iconKey)
                                    .font(.title2)
                                    .foregroundStyle(DeckAppearance.color(row.deck.colorKey))
                                    .frame(width: 42, height: 42)
                                    .background(DeckAppearance.color(row.deck.colorKey).opacity(0.12),
                                                in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.deck.name.displayValue).fontWeight(.semibold)
                                        .accessibilityIdentifier("deck.name.\(row.id.rawValue.uuidString)")
                                    if !row.deck.description.isEmpty {
                                        Text(row.deck.description).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                Spacer()
                                Text("Карточек: \(row.counts.cards)").foregroundStyle(.secondary)
                                DeckActionButton(title: "Редактировать", symbol: "pencil",
                                    identifier: "deck.edit.\(row.deck.name.displayValue)",
                                    accessibilityLabel: "Редактировать колоду \(row.deck.name.displayValue)",
                                    wantsFocus: focus == .edit(row.id)) {
                                    returnFocus = .edit(row.id)
                                    focus = nil
                                    model.edit(row.deck)
                                }
                            }
                            .padding(16)
                            .background(CardsColor.surface.color, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            if model.deckCount > 100 {
                HStack {
                    Button("Назад") { model.previousPage() }.disabled(model.pageOffset == 0)
                    Text("\(model.pageOffset + 1)–\(model.pageOffset + model.rows.count) из \(model.deckCount)")
                    Button("Далее") { model.nextPage() }
                        .disabled(model.pageOffset + model.rows.count >= model.deckCount)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(model.pageOffset)-\(model.refreshID)") { await model.observe() }
        .sheet(item: $model.editor, onDismiss: {
            focus = nil
            // Reset even when the same button opened consecutive sheets.
            Task { @MainActor in
                await Task.yield()
                focus = returnFocus
            }
        }) { editor in
            DeckEditorView(model: editor) { model.editor = nil }
        }
    }
}

enum DeckAppearance {
    static let icons: [(key: String, title: String)] = [
        ("rectangle.stack", "Карточки"), ("book.closed", "Книга"), ("briefcase", "Работа"),
        ("airplane", "Путешествия"), ("link", "Связь"), ("star", "Звезда"),
        ("heart", "Сердце"), ("music.note", "Музыка"), ("desktopcomputer", "Технологии")
    ]
    static let colors: [(key: String, title: String)] = [
        ("accent", "Индиго"), ("purple", "Фиолетовый"), ("pink", "Розовый"),
        ("orange", "Оранжевый"), ("green", "Зелёный"), ("teal", "Бирюзовый"), ("gray", "Серый")
    ]
    static func color(_ key: String) -> Color {
        switch key {
        case "purple": .purple
        case "pink": .pink
        case "orange": .orange
        case "green": .green
        case "teal": .teal
        case "gray": .secondary
        default: CardsColor.accent.color
        }
    }
}
