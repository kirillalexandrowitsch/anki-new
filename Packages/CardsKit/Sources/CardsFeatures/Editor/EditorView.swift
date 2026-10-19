import CardsCore
import CardsDesignSystem
import SwiftUI

struct EditorView: View {
    @Bindable var model: EditorModel
    let close: () -> Void
    @FocusState private var frontFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(model.original == nil ? "Новая карточка" : "Редактировать карточку").font(.title2.bold())
                Spacer()
                if model.isDirty { Label("Есть несохранённые изменения", systemImage: "circle.fill").font(.caption).foregroundStyle(.orange) }
            }
            if model.original != nil {
                Text("Общие поля записи применяются ко всем её карточкам.").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Тип карточки: Базовая").font(.headline)
                        Picker("Колода", selection: $model.draft.deckID) {
                            if model.draft.deckID == nil { Text("Выберите колоду").tag(nil as DeckID?) }
                            ForEach(model.decks) { Text($0.name.displayValue).tag(Optional($0.id)) }
                        }
                        .disabled(model.original != nil)
                        .accessibilityIdentifier("editor.deck")
                        if model.decks.isEmpty {
                            Text("Сначала создайте колоду в разделе «Колоды».").foregroundStyle(.red)
                        }
                        if model.original != nil { Text("Колода существующей карточки сохраняется.").font(.caption).foregroundStyle(.secondary) }
                        field("Лицевая сторона (обязательно)", text: $model.draft.front, id: "front")
                            .focused($frontFocused)
                        if let error = model.draft.frontError { validation(error, id: "front") }
                        field("Обратная сторона (обязательно)", text: $model.draft.back, id: "back")
                        if let error = model.draft.backError { validation(error, id: "back") }
                        field("Произношение (необязательно)", text: $model.draft.pronunciation, id: "pronunciation")
                        ForEach(model.draft.examples.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 6) {
                                field("Пример", text: exampleBinding(index, english: true), id: "example.\(index).en")
                                field("Перевод примера", text: exampleBinding(index, english: false), id: "example.\(index).ru")
                                Button("Удалить пример") { model.draft.examples.remove(at: index) }
                            }
                        }
                        Button("Добавить пример") { model.draft.examples.append(NoteExample(en: "")) }
                            .accessibilityIdentifier("editor.addExample")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Предпросмотр карточки").font(.headline)
                        preview(title: "Сторона 1", text: model.draft.front, pronunciation: model.draft.pronunciation)
                        preview(title: "Сторона 2", text: model.draft.back)
                        ForEach(Array(model.draft.examples.enumerated()), id: \.offset) { _, example in
                            Text(example.en).font(.callout)
                            Text(example.ru).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(16).frame(width: 230)
                        .background(CardsColor.surface.color, in: RoundedRectangle(cornerRadius: 12))
                }
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).textSelection(.enabled)
                        .accessibilityIdentifier("editor.error")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top)
                }
                if let latest = model.latest {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Актуальная сохранённая версия").font(.headline)
                        Text(latest.content.front)
                        Text(latest.content.back)
                        Text(latest.content.pronunciation)
                        ForEach(Array(latest.content.examples.enumerated()), id: \.offset) { _, example in
                            Text(example.en + "\n" + example.ru)
                        }
                        Button("Подготовить отдельную копию моего текста") { model.prepareSeparateCopy() }
                            .accessibilityIdentifier("editor.separateCopy")
                    }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top)
                }
            }.disabled(model.isSaving)
            HStack {
                if model.isSaving { ProgressView().controlSize(.small); Text("Сохранение…") }
                Spacer()
                Button("Отменить") { model.requestClose() }
                    .keyboardShortcut(.cancelAction).disabled(model.isSaving)
                    .accessibilityIdentifier("editor.close")
                Button("Сохранить") { Task { await model.save() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.canSave).accessibilityIdentifier("editor.save")
            }
        }
        .padding(24).frame(width: 720, height: 500)
        .interactiveDismissDisabled()
        .background(EditorWindowCloseGuard { model.requestClose() })
        .background {
            Button("Закрыть редактор") { model.requestClose() }
                .keyboardShortcut("w", modifiers: .command).hidden().accessibilityHidden(true)
        }
        .onAppear { frontFocused = true }
        .onChange(of: model.isClosed) { _, value in if value { close() } }
        .onExitCommand { model.requestClose() }
        .alert("Несохранённые изменения", isPresented: $model.showsUnsavedWarning) {
            Button("Сохранить") { Task { await model.resolveClose(.save) } }
                .disabled(!model.canSave).accessibilityIdentifier("editor.warning.save")
            Button("Не сохранять", role: .destructive) { Task { await model.resolveClose(.discard) } }
                .accessibilityIdentifier("editor.warning.discard")
            Button("Отмена", role: .cancel) { Task { await model.resolveClose(.cancel) } }
                .accessibilityIdentifier("editor.warning.cancel")
        } message: { Text("Сохранить изменения карточки перед выходом?") }
    }
    private func field(_ title: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout)
            TextField(title, text: text, axis: .vertical)
                .lineLimit(1...4).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("editor.\(id)")
        }
    }
    private func validation(_ message: String, id: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
            .accessibilityIdentifier("editor.\(id)Error")
    }
    private func preview(title: String, text: String, pronunciation: String = "") -> some View {
        VStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text.isEmpty ? "…" : text).font(.title3.bold()).textSelection(.enabled)
            if !pronunciation.isEmpty { Text(pronunciation).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity).padding(12)
            .background(CardsColor.window.color, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title): \(text). \(pronunciation)")
            .accessibilityIdentifier(title == "Сторона 1" ? "editor.preview.front" : "editor.preview.back")
    }
    private func exampleBinding(_ index: Int, english: Bool) -> Binding<String> {
        Binding(get: {
            guard model.draft.examples.indices.contains(index) else { return "" }
            return english ? model.draft.examples[index].en : model.draft.examples[index].ru
        }, set: { value in
            guard model.draft.examples.indices.contains(index) else { return }
            let old = model.draft.examples[index]
            model.draft.examples[index] = NoteExample(en: english ? value : old.en, ru: english ? old.ru : value)
        })
    }
}
