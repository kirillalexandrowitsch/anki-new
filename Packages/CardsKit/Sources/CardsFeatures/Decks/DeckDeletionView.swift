import CardsCore
import SwiftUI

struct DeckDeletionView: View {
    @Bindable var model: DeckDeletionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Удалить колоду?", systemImage: "trash.circle.fill")
                .font(.title2.bold()).foregroundStyle(.red)
            if model.isLoading { ProgressView("Подсчёт области удаления…") }
            if let target = model.target {
                Text("Колода «\(target.root.name.displayValue)» и всё её поддерево будут удалены.")
                    .accessibilityIdentifier("deckDelete.scope")
                VStack(alignment: .leading, spacing: 8) {
                    Text("Подколод: \(target.decks.count - 1)").accessibilityIdentifier("deckDelete.decks")
                    Text("Карточек: \(target.cards.count)").accessibilityIdentifier("deckDelete.cards")
                    Text("Затронуто записей: \(target.notes.count)").accessibilityIdentifier("deckDelete.notes")
                    Text("Будет удалено записей: \(target.deletedNoteCount)")
                    Text("Общих записей сохранится: \(target.sharedNoteCount)")
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                Text("Варианты в других колодах сохранятся. Это действие нельзя отменить в приложении.")
                    .foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("deckDelete.error")
                Button("Обновить область удаления") { Task { await model.loadTarget() } }
                    .disabled(model.isLoading || model.isCommitting).accessibilityIdentifier("deckDelete.reload")
            }
            HStack {
                if model.isCommitting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Отмена") { model.cancel() }.keyboardShortcut(.cancelAction)
                    .disabled(model.isCommitting).accessibilityIdentifier("deckDelete.cancel")
                Button("Удалить колоду", role: .destructive) { Task { await model.confirm() } }
                    .tint(.red).disabled(model.target == nil || model.isLoading || model.isCommitting)
                    .accessibilityIdentifier("deckDelete.confirm")
            }
        }.padding(24).frame(width: 490).interactiveDismissDisabled()
    }
}
