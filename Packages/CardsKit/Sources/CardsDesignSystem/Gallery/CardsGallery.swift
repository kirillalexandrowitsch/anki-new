import SwiftUI

private func galleryText(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}

public enum CardsGalleryPage: String, CaseIterable, Identifiable {
    case buttons, fields, messages, typography
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .buttons: galleryText("Кнопки")
        case .fields: galleryText("Поля и переключатели")
        case .messages: galleryText("Сообщения и состояния")
        case .typography: galleryText("Типографика и цвета")
        }
    }
}

/// A developer preview surface. State overrides are labelled samples, while the
/// interaction panel contains real buttons/fields with ordinary keyboard behavior.
public struct CardsGallery: View {
    @State private var dark = false
    @State private var enlarged = false
    @State private var highContrast = false
    @State private var page: CardsGalleryPage = .buttons

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: CardsSpacing.large) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: CardsSpacing.panel) { options }
                VStack(alignment: .leading, spacing: CardsSpacing.medium) { options }
            }
            Picker(galleryText("Раздел"), selection: $page) {
                ForEach(CardsGalleryPage.allCases) { page in
                    Text(page.title).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("gallery.pages")
            ScrollView {
                CardsGalleryContent(page: page)
                    .padding(CardsSpacing.small) // room for the outer focus ring
            }
        }
        .padding(CardsSpacing.panel)
        .cardsText()
        .foregroundStyle(CardsColor.text.color)
        .background(CardsColor.window.color)
        .environment(\.cardsTextScale, enlarged ? .enlarged : .standard)
        .preferredColorScheme(dark ? .dark : .light)
        .environment(\.cardsIncreasedContrast, highContrast)
        .tint(CardsColor.accent.color)
    }

    @ViewBuilder private var options: some View {
        Toggle(galleryText("Тёмная тема"), isOn: $dark).accessibilityIdentifier("gallery.dark")
        Toggle(galleryText("Крупный текст"), isOn: $enlarged).accessibilityIdentifier("gallery.enlarged")
        Toggle(galleryText("Повышенный контраст"), isOn: $highContrast)
            .accessibilityIdentifier("gallery.contrast")
    }
}

/// Non-scrolling content can also be rendered for local visual review. No model,
/// collection, database or application service is needed to instantiate it.
public struct CardsGalleryContent: View {
    private let page: CardsGalleryPage
    @State private var value = "Travel English"
    @State private var empty = ""
    @State private var longValue = "Essential English vocabulary / Английские выражения / /ˌser.ənˈdɪp.ə.ti/"
    @State private var enabled = true
    @State private var checked = false
    @State private var segment = 0
    @State private var count = 0

    public init(page: CardsGalleryPage) { self.page = page }

    public var body: some View {
        VStack(alignment: .leading, spacing: CardsSpacing.panel) {
            Text(page.title).cardsText(.windowTitle).accessibilityAddTraits(.isHeader)
            switch page {
            case .buttons: buttons
            case .fields: fields
            case .messages: messages
            case .typography: typography
            }
        }
        .cardsText()
        .foregroundStyle(CardsColor.text.color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var buttons: some View {
        VStack(spacing: CardsSpacing.panel) {
            ForEach(CardsButtonKind.allCases, id: \.self) { kind in
                CardsPanel(buttonTitle(kind)) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 20)], spacing: 20) {
                        ForEach(ButtonPreviewState.allCases, id: \.self) { state in
                            VStack(spacing: CardsSpacing.medium) {
                                Button(buttonTitle(kind)) {}
                                    .buttonStyle(CardsButtonStyle(kind, preview: state))
                                    .disabled(state == .disabled)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                                Text(stateTitle(state)).cardsText(.caption)
                                    .foregroundStyle(CardsColor.secondaryText.color)
                            }
                            .padding(CardsSpacing.xSmall)
                        }
                    }
                }
            }
            CardsPanel(galleryText("Интерактивные контролы")) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: CardsSpacing.large) { interactiveButtons }
                    VStack(alignment: .leading, spacing: CardsSpacing.large) { interactiveButtons }
                }
                Text(count, format: .number).monospacedDigit()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(count, format: .number))
                    .accessibilityIdentifier("gallery.count")
                Text(galleryText("⌘R — нажатие, ⇧⌘R — сброс. Tab и Пробел работают при включённой системной навигации с клавиатуры."))
                    .cardsText(.caption).foregroundStyle(CardsColor.secondaryText.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var interactiveButtons: some View {
        Button(galleryText("Проверить нажатие")) { count += 1 }
            .buttonStyle(CardsButtonStyle(.primary)).accessibilityIdentifier("gallery.action")
            .keyboardShortcut("r", modifiers: .command)
        Button(galleryText("Сбросить счётчик")) { count = 0 }
            .buttonStyle(CardsButtonStyle(.secondary)).accessibilityIdentifier("gallery.reset")
            .keyboardShortcut("r", modifiers: [.command, .shift])
        Button(galleryText("Недоступно")) { count += 100 }
            .buttonStyle(CardsButtonStyle(.destructive)).disabled(true)
            .accessibilityIdentifier("gallery.disabled")
    }

    private var fields: some View {
        VStack(spacing: CardsSpacing.panel) {
            CardsPanel(galleryText("Постоянная подпись, подсказка и ошибка")) {
                CardsField(galleryText("Название"), text: $value,
                           help: galleryText("Кириллица, English и IPA поддерживаются системным шрифтом."))
                    .accessibilityIdentifier("gallery.field")
                CardsField(galleryText("Обязательное поле"), text: $empty,
                           prompt: galleryText("Например: Разговорный английский"),
                           error: empty.isEmpty ? galleryText("Введите название, чтобы продолжить.") : nil)
                CardsField(galleryText("Длинное значение"), text: $longValue,
                           help: galleryText("Стрелки и выделение прокручивают значение внутри поля."))
                CardsField(galleryText("Недоступное поле"), text: $value,
                           help: galleryText("Включите зависимую настройку, чтобы редактировать."))
                    .disabled(true)
            }
            CardsPanel(galleryText("Нативные переключатели")) {
                Toggle(galleryText("Включено"), isOn: $enabled).toggleStyle(.switch)
                Toggle(galleryText("Выбрано"), isOn: $checked).toggleStyle(.checkbox)
                Toggle(galleryText("Недоступно"), isOn: .constant(true)).disabled(true)
                Picker(galleryText("Представление"), selection: $segment) {
                    Text(galleryText("Список")).tag(0)
                    Text(galleryText("Сетка")).tag(1)
                }.pickerStyle(.segmented)
                Button {} label: {
                    Label(galleryText("Воспроизвести произношение"), systemImage: "speaker.wave.2")
                }
                .buttonStyle(CardsButtonStyle(.secondary))
                .disabled(true)
                .help(galleryText("Образец кнопки с SF Symbol; аудио не подключено."))
            }
        }
    }

    private var messages: some View {
        VStack(spacing: CardsSpacing.large) {
            CardsBanner(.information, title: galleryText("Информация"),
                        message: galleryText("Системное сообщение с пояснением следующего действия."))
            CardsBanner(.success, title: galleryText("Готово"), message: galleryText("Изменения сохранены."))
            CardsBanner(.warning, title: galleryText("Внимание"),
                        message: galleryText("Проверьте введённые данные перед продолжением."))
            CardsBanner(.error, title: galleryText("Не удалось сохранить"),
                        message: galleryText("Проверьте доступ к файлу и повторите попытку. Черновик сохранён в окне."))
            CardsPanel {
                CardsEmptyState(galleryText("Здесь пока ничего нет"), symbol: "tray",
                                message: galleryText("После добавления элементов они появятся здесь."))
                CardsLoadingState(galleryText("Загрузка…"))
                CardsLoadingState(galleryText("Обработка элементов…"), progress: 0.42)
            }
        }
    }

    private var typography: some View {
        VStack(spacing: CardsSpacing.panel) {
            CardsPanel(galleryText("Системный шрифт")) {
                Text("Карточки / Cards").cardsText(.windowTitle)
                Text("Заголовок / Section title").cardsText(.sectionTitle)
                Text("serendipity").cardsText(.studyWord)
                Text("/ˌser.ənˈdɪp.ə.ti/ — счастливая случайность").cardsText(.translation)
                Text("Кириллица и English, 0123456789").cardsText()
                Text("Подпись / Caption — 123 456 789").cardsText(.caption).monospacedDigit()
            }
            CardsPanel(galleryText("Семантические цвета")) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], alignment: .leading, spacing: 16) {
                    ForEach(CardsColor.allCases, id: \.self) { token in
                        HStack {
                            RoundedRectangle(cornerRadius: CardsRadius.control)
                                .fill(token.color).frame(width: 28, height: 28)
                                .overlay(RoundedRectangle(cornerRadius: CardsRadius.control)
                                    .strokeBorder(CardsColor.secondaryText.color, lineWidth: 1))
                            Text(token.rawValue).cardsText(.caption)
                        }
                    }
                }
            }
        }
    }

    private func buttonTitle(_ kind: CardsButtonKind) -> String {
        switch kind {
        case .primary: galleryText("Продолжить")
        case .secondary: galleryText("Открыть")
        case .destructive: galleryText("Удалить")
        }
    }

    private func stateTitle(_ state: ButtonPreviewState) -> String {
        switch state {
        case .normal: galleryText("Обычное")
        case .hover: galleryText("Наведение")
        case .pressed: galleryText("Нажатие")
        case .disabled: galleryText("Отключено")
        case .focus: galleryText("Фокус")
        }
    }
}

#Preview("Light") { CardsGallery().frame(width: 1120, height: 900) }
#Preview("Dark") {
    CardsGalleryContent(page: .buttons).padding(32).frame(width: 1120)
        .background(CardsColor.window.color).environment(\.colorScheme, .dark)
}
#Preview("Large text / Light") {
    CardsGalleryContent(page: .fields).padding(32).frame(width: 800)
        .background(CardsColor.window.color).environment(\.cardsTextScale, .enlarged)
}
#Preview("Large text / Dark") {
    CardsGalleryContent(page: .messages).padding(32).frame(width: 800)
        .background(CardsColor.window.color).environment(\.cardsTextScale, .enlarged)
        .environment(\.colorScheme, .dark)
}
