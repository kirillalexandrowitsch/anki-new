import CardsCore
import CardsDesignSystem
import SwiftUI

struct DeckStudySetupView: View {
    @Bindable var model: DeckStudySetupModel
    let close: () -> Void
    var body: some View {
        Group {
            if let study = model.study {
                StudyView(model: study, title: model.root.name.displayValue, close: close)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Настроить занятие").font(.title2.weight(.semibold))
                    Label(model.root.name.displayValue, systemImage: model.root.iconKey).font(.headline)
                    Text("Только это занятие. Постоянные настройки останутся прежними.").foregroundStyle(.secondary)
                    Form {
                        Picker("Область с подколодами", selection: $model.scopeID) {
                            ForEach(model.scopes) { row in Text(row.deck.name.displayValue).tag(row.id) }
                        }.accessibilityIdentifier("deckStudy.scope")
                        TextField("Дневная квота новых", text: $model.newText).accessibilityIdentifier("deckStudy.new")
                        TextField("Дневная квота повторений", text: $model.reviewText).accessibilityIdentifier("deckStudy.review")
                        TextField("Общий предел (пусто — без ограничения)", text: $model.sessionText).accessibilityIdentifier("deckStudy.session")
                    }.disabled(!model.isLoaded || model.isStarting)
                    Text("Квоты учитывают уже выполненное сегодня во всей коллекции. Общий предел считает уникальные новые/review карточки; изучение и переучивание проходят без этих ограничений.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let preview = model.preview {
                        Text("Готово сейчас: новых \(preview.new), повторений \(preview.review), изучение \(preview.learning)")
                            .accessibilityIdentifier("deckStudy.counts")
                        Text(preview.asOf, format: .dateTime.hour().minute().second()).font(.caption).foregroundStyle(.secondary)
                    }
                    if let reason = model.unavailableReason {
                        Text(reason).foregroundStyle(.secondary).accessibilityIdentifier("deckStudy.reason")
                    }
                    HStack {
                        Button("Обновить проверку") { Task { await model.load(); await model.refresh() } }
                            .disabled(model.isStarting || model.isRefreshing).accessibilityIdentifier("deckStudy.refresh")
                        Spacer()
                        Button("Отмена", action: close).keyboardShortcut(.cancelAction).disabled(model.isStarting)
                            .accessibilityIdentifier("deckStudy.cancel")
                        Button("Начать занятие") { Task { await model.start() } }
                            .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                            .disabled(!model.canStart).accessibilityIdentifier("deckStudy.start")
                    }
                }.padding(24).frame(width: 600)
                    .task { await model.load() }
                    .task(id: model.requestID) { await model.refresh() }
            }
        }.interactiveDismissDisabled()
    }
}
