import CardsCore
import CardsDesignSystem
import SwiftUI

public struct TodayView: View {
    @Bindable private var model: TodayModel
    private let onboarding: OnboardingModel?
    private let opening: Bool
    private let openingFailed: Bool
    private let start: () -> Void
    private let discovery: DiscoveryModel?
    private let openCard: (CardID) -> Void
    private let openDecks: () -> Void
    private let openLibrary: () -> Void
    private let demo: () -> Void

    public init(model: TodayModel, onboarding: OnboardingModel? = nil, opening: Bool, openingFailed: Bool, start: @escaping () -> Void,
                discovery: DiscoveryModel? = nil, openCard: @escaping (CardID) -> Void = { _ in },
                openDecks: @escaping () -> Void, openLibrary: @escaping () -> Void, demo: @escaping () -> Void) {
        self.onboarding = onboarding
        self.discovery = discovery; self.openCard = openCard
        self.model = model; self.opening = opening; self.openingFailed = openingFailed
        self.start = start; self.openDecks = openDecks; self.openLibrary = openLibrary; self.demo = demo
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error = model.errorMessage {
                    CardsPanel("Сегодня недоступно") {
                        Text(error).foregroundStyle(.red).accessibilityIdentifier("today.error")
                        Button("Повторить") { model.reload() }.accessibilityIdentifier("today.retry")
                    }
                } else if let snapshot = model.snapshot {
                    if snapshot.decks.isEmpty, let onboarding, onboarding.isRequired {
                        OnboardingView(model: onboarding)
                    } else {
                        if let onboarding { OnboardingSuccessView(model: onboarding, openDecks: openDecks) }
                        overview(snapshot)
                        HStack(spacing: 12) {
                            metric("Оценок сегодня", value: "\(snapshot.ratings)", id: "ratings")
                            metric("Карточек сегодня", value: "\(snapshot.uniqueCards)", id: "cards")
                            metric("Время ответов", value: Duration.milliseconds(snapshot.responseDurationMs)
                                .formatted(.time(pattern: .minuteSecond)), id: "duration")
                        }.accessibilityElement(children: .contain).accessibilityIdentifier("today.metrics")
                        CardsPanel("Ваши колоды") {
                            if snapshot.decks.isEmpty {
                                Text("Создайте первую колоду, затем добавьте карточки.").foregroundStyle(.secondary)
                            } else {
                                ForEach(snapshot.decks) { row in
                                    HStack {
                                        Image(systemName: row.deck.iconKey)
                                            .font(.title2).foregroundStyle(DeckAppearance.color(row.deck.colorKey))
                                            .frame(width: 36, height: 36)
                                            .background(DeckAppearance.color(row.deck.colorKey).opacity(0.12),
                                                        in: RoundedRectangle(cornerRadius: 8))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(row.deck.name.displayValue).font(.headline).lineLimit(2)
                                            if !row.deck.description.isEmpty {
                                                Text(row.deck.description).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                        Text("К повторению: \(row.counts.due) · Новых: \(row.counts.new)")
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 6)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityIdentifier("today.deck.\(row.id.rawValue.uuidString)")
                                }
                            }
                            Button("Открыть колоды", action: openDecks).accessibilityIdentifier("today.decks")
                        }
                    }
                } else {
                    ProgressView("Загрузка Сегодня…").accessibilityIdentifier("today.loading")
                }
                if let discovery { DailyWordView(model: discovery, open: openCard) }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Пробное занятие на трёх примерах. Данные вашей коллекции не меняются.")
                        .foregroundStyle(.secondary)
                    Button("Пробное занятие", action: demo)
                        .buttonStyle(CardsButtonStyle(.secondary)).accessibilityIdentifier("study.demo")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: model.refreshID) { await model.observe() }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                model.reload()
            }
        }
    }

    private func overview(_ snapshot: TodayStudySnapshot) -> some View {
        CardsPanel(title) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    queueCount("К повторению", value: snapshot.counts.due, id: "due")
                    queueCount("Новых", value: snapshot.counts.new, id: "new")
                }.font(.title2.weight(.semibold)).accessibilityElement(children: .contain).accessibilityIdentifier("today.counts")
                accessibleText(message, id: "state").foregroundStyle(.secondary)
                if let date = snapshot.nextAvailableAt, snapshot.counts.total == 0 {
                    accessibleText("Следующее повторение: \(date.formatted(date: .abbreviated, time: .shortened))", id: "nextDue")
                }
                if model.canOpenStudy {
                    Button(model.actionTitle, action: start)
                        .buttonStyle(CardsButtonStyle(.primary)).disabled(opening)
                        .accessibilityIdentifier("study.start")
                } else if model.contentState == .noDecks {
                    Button("Создать колоду", action: openDecks).buttonStyle(CardsButtonStyle(.primary))
                } else {
                    Button("Добавить карточки", action: openLibrary).buttonStyle(CardsButtonStyle(.primary))
                }
                if opening { ProgressView("Открытие занятия…") }
                if openingFailed {
                    Text("Не удалось открыть занятие. Повторите попытку.")
                        .foregroundStyle(.red).accessibilityIdentifier("today.startError")
                }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("today.overview")
        }
    }
    private var title: String {
        switch model.contentState {
        case .noDecks: "У вас пока нет колод"
        case .noCards: "В выбранных колодах пока нет карточек"
        case .ready: "Готовы к занятию"
        case .futureLearning: "Следующий шаг обучения позже"
        case .dailyLimit: "Дневной лимит достигнут"
        case .sessionLimit: "Лимит занятия достигнут"
        case .skipped: "Доступные карточки просмотрены"
        default: "На сегодня всё готово!"
        }
    }
    private var message: String {
        switch model.contentState {
        case .noDecks: "Создайте колоду для своей коллекции."
        case .noCards: "Добавьте первую карточку в библиотеке."
        case .ready: "Очередь учитывает дневные лимиты и прогресс занятия."
        case .futureLearning: "Карточки обучения пока не подошли к сроку."
        case .dailyLimit: "Дневные лимиты обновятся в следующий учебный день."
        case .sessionLimit: "Завершите текущее занятие, чтобы начать следующее."
        case .skipped: "Пропущенные карточки исключены из текущего занятия."
        default: "Сейчас нет доступных карточек для занятия."
        }
    }
    private func accessibleText(_ text: String, id: String) -> some View {
        VStack { Text(text) }
            .accessibilityElement(children: .ignore).accessibilityLabel(text)
            .accessibilityIdentifier("today.\(id)")
    }
    private func queueCount(_ title: String, value: Int, id: String) -> some View {
        accessibleText("\(title): \(value)", id: id)
    }
    private func metric(_ title: String, value: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).accessibilityIdentifier("today.\(id)")
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("\(title): \(value)")
        .accessibilityIdentifier("today.\(id)")
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}
