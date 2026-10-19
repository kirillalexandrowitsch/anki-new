import CardsCore
import CardsDesignSystem
import SwiftUI

public struct LibraryView: View {
    @Bindable private var model: LibraryModel
    @State private var showsInspector = false
    public init(model: LibraryModel) { self.model = model }

    public var body: some View {
        @Bindable var launcher = model.launcher
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Все ваши слова и выражения").foregroundStyle(.secondary)
                Spacer()
                Button("Добавить карточку", systemImage: "plus") { Task { await launcher.open() } }
                    .buttonStyle(.borderedProminent).disabled(launcher.isLoading)
                    .accessibilityIdentifier("editorLauncher.create")
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Найти слово, перевод или пример", text: $model.search)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("library.search")
                if !model.search.isEmpty {
                    Button("Очистить поиск", systemImage: "xmark.circle") { model.search = "" }
                        .labelStyle(.iconOnly).accessibilityIdentifier("library.clearSearch")
                }
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                Button("Повторить") { model.reload() }
            }
            if let error = launcher.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if launcher.isLoading { ProgressView("Открытие редактора…") }
            if model.isLoading { ProgressView("Загрузка карточек…") }
            else if model.errorMessage == nil && model.rows.isEmpty {
                ContentUnavailableView {
                    Label(model.search.isEmpty ? "У вас пока нет карточек" : "Ничего не найдено",
                          systemImage: model.search.isEmpty ? "rectangle.on.rectangle" : "magnifyingglass")
                } description: {
                    Text(model.search.isEmpty ? "Добавьте первую карточку в свою колоду."
                         : "Попробуйте другое слово или очистите поиск.")
                } actions: {
                    if model.search.isEmpty {
                        Button("Добавить первую карточку") { Task { await launcher.open() } }
                            .accessibilityIdentifier("library.emptyCreate")
                    } else { Button("Очистить поиск") { model.search = "" } }
                }
            } else if !model.rows.isEmpty {
                GeometryReader { geometry in
                    HStack(alignment: .top, spacing: 16) {
                        table
                        if geometry.size.width >= 900 {
                            inspector.frame(width: 300)
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        if geometry.size.width < 900 {
                            HStack {
                                editButton
                                Button("Инспектор", systemImage: "sidebar.right") { showsInspector = true }
                                    .disabled(model.selectedRow == nil)
                                    .accessibilityIdentifier("library.inspector")
                                    .popover(isPresented: $showsInspector) { inspector.frame(width: 300, height: 420).padding() }
                                Spacer()
                            }.padding(.top, 8)
                        }
                    }
                }
            }
            HStack {
                Text(countSummary)
                    .accessibilityLabel(countSummary)
                    .accessibilityIdentifier("library.counts")
                Spacer()
                if model.offset > 0 || model.hasMore {
                    Button("Назад") { model.page(-1) }.disabled(model.offset == 0 || model.isLoading)
                    Text("\(model.offset + 1)–\(model.offset + model.rows.count)")
                    Button("Далее") { model.page(1) }.disabled(!model.hasMore || model.isLoading)
                }
            }.font(.callout).foregroundStyle(.secondary)
        }
        .task(id: model.requestID) { await model.observe() }
        .task(id: model.selectedRow) { await model.inspect() }
        .sheet(item: $launcher.editor) { editor in
            EditorView(model: editor) { launcher.editor = nil }
        }
    }

    private var countSummary: String { "Карточек: \(model.cardCount) · Записей: \(model.noteCount)" }

    private var table: some View {
        Table(model.rows, selection: $model.selection) {
            TableColumn("Слово") { row in
                Button { model.selection = row.id } label: {
                    Text(row.front).fontWeight(.semibold).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Выбрать карточку \(row.front), \(row.directionTitle)")
                .accessibilityIdentifier("library.select.\(row.front)")
            }.width(min: 120, ideal: 180)
            TableColumn("Перевод") { row in Text(row.back).lineLimit(2) }.width(min: 110, ideal: 180)
            TableColumn("Колода") { row in Text(row.deckName.displayValue).lineLimit(2) }.width(min: 90, ideal: 130)
            TableColumn("Статус") { row in Text(row.statusTitle) }.width(min: 105, ideal: 120)
            TableColumn("Направление") { row in Text(row.directionTitle) }.width(min: 140, ideal: 160)
        }
        .accessibilityIdentifier("library.table")
    }

    private var editButton: some View {
        Button("Редактировать", systemImage: "pencil") {
            guard let row = model.selectedRow else { return }
            showsInspector = false
            Task { await model.launcher.open(noteID: row.noteID) }
        }
        .disabled(model.selectedRow == nil || model.launcher.isLoading)
        .accessibilityIdentifier("note.edit.\(model.selectedRow?.front ?? "")")
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Содержимое карточки").font(.headline)
            if let row = model.selectedRow {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(row.directionTitle).font(.caption).foregroundStyle(.secondary)
                        Text(row.front).font(.title2.weight(.semibold))
                        Text(row.back).font(.title3).accessibilityIdentifier("library.inspector.back")
                        Divider()
                        Label(row.deckName.displayValue, systemImage: "rectangle.stack")
                        Text(row.statusTitle).foregroundStyle(.secondary)
                        if let error = model.inspectorError {
                            Text(error).foregroundStyle(.red)
                            Button("Повторить") { Task { await model.inspect() } }
                        } else if let note = model.inspectedNote {
                            if !note.content.pronunciation.isEmpty { Text(note.content.pronunciation).foregroundStyle(.secondary) }
                            ForEach(Array(note.content.examples.enumerated()), id: \.offset) { _, example in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(example.en)
                                    if !example.ru.isEmpty { Text(example.ru).foregroundStyle(.secondary) }
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(CardsColor.secondarySurface.color, in: RoundedRectangle(cornerRadius: 8))
                            }
                            if !note.tags.isEmpty { Text("Теги: " + note.tags.map(\.displayValue).joined(separator: ", ")) }
                            if !note.content.media.isEmpty { Text("Вложений: \(note.content.media.count)") }
                        } else { ProgressView("Загрузка содержимого…") }
                    }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(inspectorDescription(row))
                        .accessibilityIdentifier("library.inspector.content")
                }
                editButton
            } else { Text("Выберите карточку в таблице.").foregroundStyle(.secondary) }
        }.padding(16).background(CardsColor.surface.color, in: RoundedRectangle(cornerRadius: 12))
    }

    private func inspectorDescription(_ row: LibraryRow) -> String {
        var parts = [row.directionTitle, row.front, row.back, row.deckName.displayValue, row.statusTitle]
        if let note = model.inspectedNote {
            parts.append(note.content.pronunciation)
            parts += note.content.examples.flatMap { [$0.en, $0.ru] }
            parts += note.tags.map(\.displayValue)
            if !note.content.media.isEmpty { parts.append("Вложений: \(note.content.media.count)") }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ". ")
    }

}
