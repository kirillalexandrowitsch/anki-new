import CardsCore
import SwiftUI

struct CardDeletionView: View {
    @Bindable var model: CardDeletionModel
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "trash.circle.fill").font(.system(size: 44)).foregroundStyle(.red)
            Text("Удалить карточку?").font(.title2.bold())
            if model.isLoading { ProgressView("Загрузка области удаления…") }
            if let target = model.target {
                Text("Карточка «\(target.front)» будет удалена из библиотеки и очереди повторений.")
                Text("Только вариант: \(target.variantKey == BasicNoteType.variantKey ? "Лицевая → оборотная" : target.variantKey).")
                Text("Связанная запись «\(target.front)» и её содержимое сохранятся. Других активных карточек этой записи: \(target.otherCardCount). Их прогресс не изменится.")
                    .foregroundStyle(.secondary)
                Text("После удаления можно отменить действие в течение 5 секунд.")
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("cardDeletion.error")
                Button("Загрузить заново") { Task { await model.loadTarget() } }
                    .disabled(model.isLoading || model.isCommitting)
            }
            HStack {
                Button("Отменить") { model.cancel() }.keyboardShortcut(.cancelAction)
                    .disabled(model.isCommitting).accessibilityIdentifier("cardDeletion.cancel")
                Spacer()
                if model.isCommitting { ProgressView().controlSize(.small) }
                Button("Удалить", role: .destructive) { Task { await model.confirm() } }
                    .disabled(model.target == nil || model.isLoading || model.isCommitting)
                    .accessibilityIdentifier("cardDeletion.confirm")
            }
        }
        .multilineTextAlignment(.center).padding(24).frame(width: 430)
        .interactiveDismissDisabled(model.isCommitting)
    }
}

struct CardDeletionUndoView: View {
    @Bindable var model: CardDeletionModel
    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.pending) { undo in
                HStack {
                    Label("Карточка «\(undo.front)» удалена", systemImage: "checkmark.circle.fill")
                    Spacer()
                    Button("Отменить") { Task { await model.undo(batchID: undo.id) } }
                        .disabled(model.isUndoing || model.isPresented)
                        .accessibilityLabel("Отменить удаление \(undo.front)")
                        .accessibilityIdentifier("cardDeletion.undo.\(undo.front)")
                    Text("\(Int(ceil(undo.remainingSeconds))) с").monospacedDigit().frame(width: 32)
                        .accessibilityLabel("Осталось секунд: \(Int(ceil(undo.remainingSeconds)))")
                }
                .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            if let error = model.undoError {
                HStack {
                    Text(error).foregroundStyle(.red)
                    Button("Повторить проверку") { Task { await model.refreshUndo() } }
                }
            }
        }
        .task { await model.watch() }
    }
}
