import SwiftUI

public struct EditorLauncherView: View {
    @Bindable private var model: EditorLauncherModel
    public init(model: EditorLauncherModel) { self.model = model }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button("Добавить карточку", systemImage: "plus") { Task { await model.open() } }
                .buttonStyle(.borderedProminent).disabled(model.isLoading)
                .accessibilityIdentifier("editorLauncher.create")
            if model.isLoading { ProgressView("Загрузка…") }
            if let message = model.errorMessage {
                Text(message).foregroundStyle(.red)
                Button("Повторить") { Task { await model.load() } }
            }
            if model.rows.isEmpty && !model.isLoading {
                ContentUnavailableView("Пока нет карточек", systemImage: "rectangle.on.rectangle",
                    description: Text("Добавьте первую карточку в свою колоду."))
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.rows) { row in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(row.front).font(.headline)
                                Text(row.back).foregroundStyle(.secondary)
                                Text(row.deckName.displayValue).font(.caption)
                            }
                            Spacer()
                            Button("Редактировать") { Task { await model.open(noteID: row.noteID) } }
                                .accessibilityIdentifier("note.edit.\(row.front)")
                        }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            if model.offset > 0 || model.hasMore {
                HStack {
                    Button("Назад") { Task { await model.page(-1) } }.disabled(model.offset == 0 || model.isLoading)
                    Button("Далее") { Task { await model.page(1) } }.disabled(!model.hasMore || model.isLoading)
                }
            }
        }
        .task { await model.load() }
        .sheet(item: $model.editor, onDismiss: { Task { await model.load() } }) { editor in
            EditorView(model: editor) { model.editor = nil }
        }
    }
}
