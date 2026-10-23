import CardsCore
import SwiftUI

struct DeckPropertiesView: View {
    @Bindable var model: DecksModel
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Свойства колоды").font(.title2.weight(.semibold))
            if let row = model.inspectedRow {
                Label(row.deck.name.displayValue, systemImage: row.deck.iconKey)
                    .font(.title3.weight(.semibold)).foregroundStyle(DeckAppearance.color(row.deck.colorKey))
                Text(model.hierarchy.path(row.id)).foregroundStyle(.secondary).accessibilityIdentifier("deckProperties.path")
                Text(row.deck.description.isEmpty ? "Описание не задано" : row.deck.description)
                Text("Карточек: \(row.counts.cards) · Записей: \(row.counts.notes)").accessibilityIdentifier("deckProperties.counts")
                Text("Новых: \(row.counts.new) · Изучение: \(row.counts.learning) · Повторение: \(row.counts.review)")
                Text("Приостановлено: \(row.counts.suspended) · Отложено: \(row.counts.buried)")
                Text("Подколод: \(model.rows.filter { model.hierarchy.ancestors(of: $0.id).contains { $0.id == row.id } }.count)")
                Text(row.deck.isFavorite ? "В избранном" : "Не в избранном")
                Text("Счётчики относятся к самой колоде и не учитывают дневные квоты. Доступность занятия проверяется отдельно.")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text("Колода больше недоступна. Закройте свойства и обновите список.") }
            HStack { Spacer(); Button("Закрыть", action: close).keyboardShortcut(.cancelAction).accessibilityIdentifier("deckProperties.close") }
        }.padding(24).frame(width: 560).interactiveDismissDisabled()
    }
}
