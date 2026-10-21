import CardsCore
import CardsDesignSystem
import SwiftUI

public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general, review, cards, data

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: String(localized: "Основные", bundle: .module)
        case .review: String(localized: "Повторение", bundle: .module)
        case .cards: String(localized: "Карточки", bundle: .module)
        case .data: String(localized: "Данные", bundle: .module)
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .review: "arrow.trianglehead.2.clockwise.rotate.90"
        case .cards: "rectangle.on.rectangle"
        case .data: "externaldrive"
        }
    }
}

public struct SettingsView: View {
    @State private var selection: SettingsTab = .general
    private let audio: AudioPreviewModel?
    @Bindable private var appearance: AppearanceModel
    private let study: StudyPreferencesModel?
    private let collectionName: String?
    @State private var showsKeys = false

    public init(appearance: AppearanceModel, study: StudyPreferencesModel?, collectionName: String?, audio: AudioPreviewModel? = nil) {
        self.appearance = appearance; self.study = study; self.collectionName = collectionName; self.audio = audio
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Настройки").font(.largeTitle.bold())
            TabView(selection: $selection) {
                general.tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.symbol) }.tag(SettingsTab.general)
                review.tabItem { Label(SettingsTab.review.title, systemImage: SettingsTab.review.symbol) }.tag(SettingsTab.review)
                cards.tabItem { Label(SettingsTab.cards.title, systemImage: SettingsTab.cards.symbol) }.tag(SettingsTab.cards)
                data.tabItem { Label(SettingsTab.data.title, systemImage: SettingsTab.data.symbol) }.tag(SettingsTab.data)
            }
            Label("Изменения сохраняются автоматически после проверки", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 720, height: 560)
        .tint(CardsColor.accent.color)
        .preferredColorScheme(appearance.colorScheme)
        .onDisappear { study?.endEditing() }
        .sheet(isPresented: $showsKeys) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Горячие клавиши").font(.title2.bold())
                Text("Пробел — показать ответ\n1 / 2 / 3 / 4 — оценка после раскрытия\n⌘ , — настройки\nEscape — отменить диалог")
                Text("В активном текстовом поле клавиши используются для ввода.").foregroundStyle(.secondary)
                Button("Готово") { showsKeys = false }.keyboardShortcut(.cancelAction)
            }.padding(28).frame(width: 440)
        }
    }
    private var general: some View {
        Form {
            Section("Внешний вид") {
                Picker("Тема", selection: Binding(get: { appearance.value.theme }, set: { appearance.set(theme: $0) })) {
                    Text("Как в системе").tag(AppTheme.system)
                    Text("Светлая").tag(AppTheme.light)
                    Text("Тёмная").tag(AppTheme.dark)
                }.pickerStyle(.segmented).accessibilityIdentifier("settings.theme")
                Picker("Язык интерфейса", selection: Binding(get: { appearance.value.language }, set: { appearance.set(language: $0) })) {
                    Text("Русский").tag(AppLanguage.ru)
                    Text("English").tag(AppLanguage.en)
                }.accessibilityIdentifier("settings.language")
                Text("Язык применяется после повторного запуска приложения. Полный перевод интерфейса будет дополнен в следующих версиях.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = appearance.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            Section("Горячие клавиши") {
                Button("Посмотреть сочетания…") { showsKeys = true }.accessibilityIdentifier("settings.shortcuts")
            }
        }.formStyle(.grouped).accessibilityIdentifier("settings.general")
    }
    @ViewBuilder private var review: some View {
        if let study {
            StudyPreferencesForm(model: study)
        } else {
            ContentUnavailableView("Коллекция недоступна", systemImage: "externaldrive.badge.exclamationmark",
                description: Text("Откройте коллекцию в главном окне, чтобы изменить учебные параметры."))
        }
    }
    private var cards: some View {
        VStack(alignment: .leading) {
            if let audio { PronunciationSettingsView(audio: audio, preferences: audio.preferences) }
            Text("Вид карточек и целевое удержание появятся в расширенных настройках. Сейчас используется Basic и сохранённая политика FSRS.")
                .font(.caption).foregroundStyle(.secondary).padding()
        }.accessibilityIdentifier("settings.cards")
    }
    private var data: some View {
        Form {
            Section("Хранилище данных") {
                LabeledContent("Коллекция", value: collectionName ?? "Не открыта")
                Text("Карточки, история и учебные настройки хранятся локально в SQLite. Внешний вид и язык хранятся отдельно в настройках приложения.")
            }
            Section("Резервные копии и перенос") {
                Text("Управление копиями, экспортом и импортом будет подключено в следующих задачах. Автоматические копии пока не включены.")
                    .foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).accessibilityIdentifier("settings.data")
    }
}

private struct StudyPreferencesForm: View {
    @Bindable var model: StudyPreferencesModel
    @FocusState private var focused: StudyPreferencesModel.Field?
    var body: some View {
        Form {
            Section("Параметры повторения") {
                field("Новых карточек в день", kind: .new, value: model.newText, id: "settings.newLimit")
                field("Повторений в день", kind: .review, value: model.reviewText, id: "settings.reviewLimit")
                Text("Целое число от 0 до 9999. Ноль отключает новые задания соответствующего вида.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Изменения применяются к следующему занятию. Продолженное занятие использует сохранённые лимиты.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(model.saved == nil || model.isSaving)
            if let saved = model.saved {
                Section {
                    Text("Сохранено: новых \(saved.value.newLimit), повторений \(saved.value.reviewLimit)")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Сохранено: новых \(saved.value.newLimit), повторений \(saved.value.reviewLimit)")
                        .accessibilityIdentifier("settings.savedLimits")
                }.accessibilityElement(children: .contain)
            }
            if model.saved != nil && !model.isValid {
                Section {
                    Label("Введите целое число от 0 до 9999. Это значение ещё не сохранено.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).accessibilityIdentifier("settings.invalidNumber")
                }.accessibilityElement(children: .contain)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).accessibilityIdentifier("settings.error")
                if model.saved == nil { Button("Повторить загрузку") { Task { await model.load() } } }
            }
            if model.isSaving { ProgressView("Сохранение…") }
        }.formStyle(.grouped).accessibilityIdentifier("settings.review")
        .onChange(of: focused) { old, _ in if old != nil { model.endEditing() } }
    }
    private func field(_ title: LocalizedStringKey, kind: StudyPreferencesModel.Field, value: String, id: String) -> some View {
        TextField(title, text: Binding(get: { value }, set: { model.edit(kind, text: $0) }))
            .focused($focused, equals: kind).accessibilityIdentifier(id)
    }
}
