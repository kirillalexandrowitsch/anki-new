import AppKit
import CardsCore
import CardsDesignSystem
import SwiftUI

struct CollectionExportView: View {
    @Bindable var model: CollectionExportModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.savedURL == nil ? "Экспорт коллекции" : "Экспорт готов").font(.title2.bold())
            if let url = model.savedURL {
                Label("Файл сохранён и готов к использованию", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(url.lastPathComponent).textSelection(.enabled)
                Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Готово") { model.isPresented = false }.keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("export.complete")
                }
            } else {
                Text("Сохраняются данные всей открытой коллекции. Выберите новое имя файла.")
                    .foregroundStyle(.secondary)
                Picker("Формат", selection: $model.format) {
                    Text("CSV — текст (UTF-8, запятая)").tag(CollectionExportFormat.csv)
                    Text("TSV — текст (UTF-8, табуляция)").tag(CollectionExportFormat.tsv)
                    Text("Cardsdeck — записи и вложения").tag(CollectionExportFormat.cardsdeck)
                    Text("Cardsbackup — точная копия").tag(CollectionExportFormat.cardsbackup)
                }.accessibilityIdentifier("export.format")
                Text("Anki (.apkg) — пока недоступно").foregroundStyle(.secondary)
                Toggle("Включить прогресс", isOn: .constant(model.format.includesProgress)).disabled(true)
                Toggle("Включить медиафайлы", isOn: .constant(model.format.includesMedia)).disabled(true)
                Text(capabilities).font(.caption).foregroundStyle(.secondary)
                Toggle("Безопасно для таблиц: добавить апостроф к каждой ячейке", isOn: $model.safeSpreadsheet)
                    .disabled(model.format.includesMedia)
                if let error = model.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("export.error") }
                HStack {
                    Button("Отмена") { model.isPresented = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Button("Сохранить…") { model.save() }.keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("export.save")
                }
            }
        }
        .padding(28).frame(width: 540)
        .disabled(model.busy)
        .interactiveDismissDisabled(model.busy)
    }
    private var capabilities: String {
        switch model.format {
        case .csv, .tsv: "Только текст и теги; без расписания, истории и вложений. Апострофы в безопасном режиме удаляются по одному из начала каждой ячейки при чтении."
        case .cardsdeck: "Версия 1: записи, варианты, теги и медиа. Прогресс не переносится. Это собственный формат приложения."
        case .cardsbackup: "Точная копия коллекции: история, расписание, параметры и медиа включены всегда."
        }
    }
}
