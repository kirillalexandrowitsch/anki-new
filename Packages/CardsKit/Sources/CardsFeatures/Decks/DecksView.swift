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
                VStack(alignment: .leading) {
                    Text("Мои колоды").font(.title2.weight(.semibold))
                    Text("Колод: \(model.deckCount)").foregroundStyle(.secondary)
                }
                Spacer()
                DeckActionButton(title: "Новая колода", symbol: "plus", identifier: "decks.create",
                                 primary: true, wantsFocus: focus == .create) {
                    returnFocus = .create; focus = nil
                    if let commands { commands.perform(.newDeck) } else { model.create() }
                }
            }
            HStack {
                TextField("Поиск колод…", text: $model.search).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("decks.search")
                Toggle("Избранные", isOn: $model.favoritesOnly).toggleStyle(.button)
                    .accessibilityIdentifier("decks.favorites")
                Button { model.setLayout(.tree) } label: { Image(systemName: "list.bullet") }
                    .accessibilityLabel("Дерево колод").accessibilityIdentifier("decks.tree")
                    .tint(model.browser.layout == .tree ? .accentColor : .secondary)
                Button { model.setLayout(.grid) } label: { Image(systemName: "square.grid.2x2") }
                    .accessibilityLabel("Сетка колод").accessibilityIdentifier("decks.grid")
                    .tint(model.browser.layout == .grid ? .accentColor : .secondary)
                if model.hasFilter {
                    Button("Сбросить фильтры") { model.resetFilters() }.accessibilityIdentifier("decks.reset")
                }
            }
            if let error = model.actionError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                Button("Обновить список") { model.reload() }
            }
            if model.canUndoMove {
                HStack {
                    Text("Колода перемещена")
                    Button("Отменить перенос") { Task { await model.undoLastMove() } }
                        .disabled(model.isMutating).accessibilityIdentifier("decks.undoMove")
                }
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                Button("Повторить") { model.reload() }
            } else if model.isLoading {
                ProgressView("Загрузка колод…")
            } else if model.visibleRows.isEmpty {
                if model.hasFilter {
                    ContentUnavailableView {
                        Label("Нет подходящих колод", systemImage: "magnifyingglass")
                    } description: { Text("Попробуйте другой поиск или сбросьте фильтры.") }
                    actions: { Button("Сбросить фильтры") { model.resetFilters() } }
                } else {
                    ContentUnavailableView("Пока нет колод", systemImage: "rectangle.stack",
                        description: Text("Создайте колоду для своих карточек."))
                }
            } else {
                ScrollView {
                    if model.browser.layout == .grid {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 12)], spacing: 12) {
                            ForEach(model.visibleRows) { row in deckCard(row, grid: true) }
                        }.accessibilityIdentifier("decks.gridContent")
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(model.visibleRows) { row in
                                deckCard(row, grid: false)
                                    .padding(.leading, model.hasFilter ? 0 : CGFloat(min(8, model.hierarchy.ancestors(of: row.id).count)) * 20)
                            }
                        }.accessibilityIdentifier("decks.treeContent")
                    }
                }.accessibilityIdentifier("decks.scroll")
                Text("Счётчики — карточки самой колоды. Новые и к повторению — без дневных лимитов.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: model.refreshID) { await model.observe() }
        .sheet(item: $model.editor, onDismiss: restoreFocus) { editor in
            DeckEditorView(model: editor) { model.editor = nil }
        }
        .sheet(item: $model.moveEditor, onDismiss: restoreFocus) { move in
            DeckMoveView(model: move, cancel: { move.stop(); model.moveEditor = nil }) { result in
                model.completeMove(result, from: move.original.parentID)
            }
        }
    }

    private func restoreFocus() {
        focus = nil
        Task { @MainActor in await Task.yield(); focus = returnFocus }
    }

    private func deckCard(_ row: DeckQueryRow, grid: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if !grid && !model.hasFilter && !model.hierarchy.children(of: row.id).isEmpty {
                    Button { model.toggleExpanded(row.id) } label: {
                        Image(systemName: model.browser.expanded.contains(row.id) ? "chevron.down" : "chevron.right")
                    }
                    .accessibilityLabel("Раскрыть или свернуть \(row.deck.name.displayValue)")
                    .accessibilityIdentifier("deck.disclosure.\(row.deck.name.displayValue)")
                }
                Image(systemName: row.deck.iconKey).font(.title2)
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
                    if row.deck.parentID != nil && (grid || model.hasFilter) {
                        Text(model.hierarchy.ancestors(of: row.id).map(\.deck.name.displayValue).joined(separator: " / "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Button { Task { await model.toggleFavorite(row.deck) } } label: {
                    Image(systemName: row.deck.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(row.deck.isFavorite ? Color.orange : Color.secondary)
                }
                .accessibilityLabel(row.deck.isFavorite ? "Убрать из избранного" : "В избранное")
                .accessibilityIdentifier("deck.favorite.\(row.deck.name.displayValue)")
                .disabled(model.isMutating)
            }
            HStack {
                Text("Карточек: \(row.counts.cards) · К повторению: \(row.counts.due) · Новых: \(row.counts.availableNew)")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("deck.counts.\(row.deck.name.displayValue)")
                Spacer(minLength: 0)
            }
            HStack {
                DeckActionButton(title: "Редактировать", symbol: "pencil",
                    identifier: "deck.edit.\(row.deck.name.displayValue)",
                    accessibilityLabel: "Редактировать колоду \(row.deck.name.displayValue)",
                    wantsFocus: focus == .edit(row.id)) {
                    returnFocus = .edit(row.id); focus = nil; model.edit(row.deck)
                }
                Spacer()
                Menu {
                    Button("Добавить подколоду") { model.create(parentID: row.id) }
                        .accessibilityIdentifier("deck.addChild")
                    Button("Переместить колоду") {
                        returnFocus = .edit(row.id); focus = nil; model.move(row.deck)
                    }.accessibilityIdentifier("deck.move")
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Действия с колодой \(row.deck.name.displayValue)")
                .accessibilityIdentifier("deck.actions.\(row.deck.name.displayValue)")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardsColor.surface.color, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct DeckMoveView: View {
    @Bindable var model: DeckMoveModel
    let cancel: () -> Void
    let complete: (Deck) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Переместить колоду").font(.title2.weight(.semibold))
            Text(model.original.name.displayValue).fontWeight(.medium)
            Text("Выберите новое расположение. Колода и её поддерево недоступны для выбора.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    destination("Без родителя (в корне)", id: nil, identifier: "deckMove.root")
                    ForEach(model.destinations) { row in
                        destination(model.hierarchy.path(row.id), id: row.id,
                                    identifier: "deckMove.destination.\(row.deck.name.displayValue)")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(model.isSaving)
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            HStack {
                if model.isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Отмена", action: cancel).keyboardShortcut(.cancelAction).disabled(model.isSaving)
                    .accessibilityIdentifier("deckMove.cancel")
                Button("Переместить") { Task { if let result = await model.save() { complete(result) } } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave).accessibilityIdentifier("deckMove.save")
            }
        }
        .padding(24).frame(width: 490, height: 440).interactiveDismissDisabled()
    }
    private func destination(_ title: String, id: DeckID?, identifier: String) -> some View {
        Button { model.parentID = id } label: {
            HStack {
                Image(systemName: model.parentID == id ? "checkmark.circle.fill" : "circle")
                Text(title).multilineTextAlignment(.leading)
                Spacer()
            }.padding(8).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(identifier)
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
