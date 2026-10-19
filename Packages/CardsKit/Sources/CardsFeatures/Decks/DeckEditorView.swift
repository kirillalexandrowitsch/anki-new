import CardsCore
import CardsDesignSystem
import SwiftUI

struct DeckEditorView: View {
    @Bindable var model: DeckEditorModel
    let close: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.original == nil ? "Новая колода" : "Редактировать колоду")
                .font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Название (обязательно)").fontWeight(.medium)
                        TextField("Название", text: $model.input.name)
                            .textFieldStyle(.roundedBorder)
                            .focused($nameFocused)
                            .accessibilityIdentifier("deckEditor.name")
                        if let error = model.requiredNameError ?? model.nameError {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.caption).foregroundStyle(.red)
                                .accessibilityIdentifier("deckEditor.nameError")
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Описание (необязательно)").fontWeight(.medium)
                        TextEditor(text: $model.input.description)
                            .frame(minHeight: 70, maxHeight: 100)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                            .accessibilityLabel("Описание")
                            .accessibilityIdentifier("deckEditor.description")
                    }
                    HStack {
                        Image(systemName: model.input.iconKey)
                            .font(.title).foregroundStyle(DeckAppearance.color(model.input.colorKey))
                            .frame(width: 44)
                            .accessibilityHidden(true)
                        Picker("Иконка", selection: $model.input.iconKey) {
                            if !DeckAppearance.icons.contains(where: { $0.key == model.input.iconKey }) {
                                Text("Текущая иконка").tag(model.input.iconKey)
                            }
                            ForEach(DeckAppearance.icons, id: \.key) { icon in
                                Label(icon.title, systemImage: icon.key).tag(icon.key)
                            }
                        }.accessibilityIdentifier("deckEditor.icon")
                        Picker("Цвет", selection: $model.input.colorKey) {
                            if !DeckAppearance.colors.contains(where: { $0.key == model.input.colorKey }) {
                                Text("Текущий цвет").tag(model.input.colorKey)
                            }
                            ForEach(DeckAppearance.colors, id: \.key) { color in
                                Text(color.title).tag(color.key)
                            }
                        }.accessibilityIdentifier("deckEditor.color")
                    }
                    if let message = model.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("deckEditor.error")
                    }
                }
                .padding(4)
            }
            .disabled(model.isSaving)
            HStack {
                if model.isSaving { ProgressView().controlSize(.small); Text("Сохранение…") }
                Spacer()
                Button("Отменить") { cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isSaving)
                    .accessibilityIdentifier("deckEditor.cancel")
                Button(model.original == nil ? "Создать колоду" : "Сохранить изменения") {
                    Task { if await model.save() != nil { close() } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
                .accessibilityIdentifier("deckEditor.save")
            }
        }
        .padding(24)
        .frame(width: 490, height: 460)
        .interactiveDismissDisabled()
        .onAppear { nameFocused = true }
        .onChange(of: model.input.name) { _, _ in model.clearNameError() }
        .onExitCommand { cancel() }
    }

    private func cancel() {
        guard !model.isSaving else { return }
        model.cancel()
        close()
    }
}
