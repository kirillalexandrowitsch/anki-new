import CardsCore
import SwiftUI

/// Shares the proven in-window presentation of global search, with explicit
/// collection state observation and no native toolbar popover lifecycle.
struct NotificationsPopover: View {
    @Bindable var model: NotificationsModel
    let open: (LocalNotificationEvent) -> Void
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                Color.clear.contentShape(Rectangle()).onTapGesture { model.isPresented = false }
                NotificationsView(model: model, maxListHeight: max(100, min(360, geometry.size.height - 168)), open: open)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(nsColor: .separatorColor)))
                    .shadow(radius: 12, y: 5)
                    .padding(.top, 8).padding(.trailing, 16)
            }
        }
    }
}

struct NotificationsView: View {
    @Bindable var model: NotificationsModel
    var maxListHeight: CGFloat = 360
    let open: (LocalNotificationEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Уведомления").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Text(model.unreadCount == 0 ? "Все прочитаны" : "Непрочитанных: \(model.unreadCount)")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("notifications.status")
                Button("Закрыть", systemImage: "xmark") { model.isPresented = false }
                    .labelStyle(.iconOnly).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("notifications.close")
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("notifications.error")
                Button("Повторить загрузку") { model.reload() }
            }
            if !model.loaded { ProgressView("Загрузка уведомлений…") }
            else if model.messages.isEmpty && model.error == nil {
                VStack(spacing: 12) {
                    Image(systemName: "bell").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Пока нет уведомлений").font(.headline).accessibilityIdentifier("notifications.empty")
                    Text("Здесь появятся результаты локальных операций и запланированные напоминания.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 24)
            } else if !model.messages.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.messages) { message in
                            Button {
                                Task {
                                    if await model.markRead(ids: [message.id]), model.isPresented {
                                        model.isPresented = false; open(message.event)
                                    }
                                }
                            } label: { row(message) }
                            .buttonStyle(.plain).disabled(model.saving)
                            .accessibilityIdentifier("notifications.row.\(message.event.kind)")
                            .accessibilityValue(message.readAt == nil ? "Не прочитано" : "Прочитано")
                            Divider()
                        }
                    }
                }.frame(height: min(maxListHeight, CGFloat(model.messages.count) * 154))
            }
            Button {
                let ids = model.messages.filter { $0.readAt == nil }.map(\.id)
                Task { await model.markRead(ids: ids) }
            } label: {
                Label("Отметить все прочитанными", systemImage: "checkmark").frame(maxWidth: .infinity)
            }.disabled(model.unreadCount == 0 || model.saving)
                .accessibilityIdentifier("notifications.markAll")
            Text("Последние \(LocalNotificationPolicy.historyLimit) сообщений этой коллекции")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(16).frame(width: 370)
    }

    private func row(_ message: LocalNotificationMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.event.symbol)
                .foregroundStyle(message.event == .backupSucceeded ? .green : .orange)
                .font(.title3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(message.event.title).font(.subheadline.weight(.semibold))
                Text(message.event.detail).font(.caption).foregroundStyle(.secondary)
                if case .reminderScheduled(let date) = message.event {
                    Text(date, format: .dateTime.day().month().hour().minute()).font(.caption)
                }
                Text(message.createdAt, format: .dateTime.day().month().hour().minute())
                    .font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if message.readAt == nil {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.blue)
                    .accessibilityLabel("Не прочитано")
            }
        }.padding(.vertical, 12).padding(.horizontal, 2).contentShape(Rectangle())
    }
}
