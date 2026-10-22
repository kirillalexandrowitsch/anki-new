import CardsCore
import CardsDesignSystem
import Charts
import SwiftUI

public struct StatisticsView: View {
    @Bindable private var model: StatisticsModel
    public init(model: StatisticsModel) { self.model = model }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Все колоды").foregroundStyle(.secondary)
                    Spacer()
                    Picker("Период", selection: $model.period) {
                        Text("7 дней").tag(StatsPeriod.week)
                        Text("30 дней").tag(StatsPeriod.month)
                        Text("365 дней").tag(StatsPeriod.year)
                    }.pickerStyle(.segmented).frame(maxWidth: 320).accessibilityIdentifier("statistics.period")
                }
                if let error = model.errorMessage {
                    CardsPanel("Статистика недоступна") {
                        Text(error).accessibilityIdentifier("statistics.error")
                        Button("Повторить") { model.reload() }.accessibilityIdentifier("statistics.retry")
                    }
                } else if let snapshot = model.snapshot {
                    content(snapshot)
                } else { ProgressView("Загрузка статистики…").accessibilityIdentifier("statistics.loading") }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: model.refreshID) { await model.observe() }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                model.reload()
            }
        }
        .onDisappear { model.reload() }
    }

    private func content(_ value: StatsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if let first = value.days.first, let last = value.days.last {
                Text("\(first.day.key.rawValue) — \(last.day.key.rawValue) · \(last.day.timeZoneID)")
                    .foregroundStyle(.secondary).accessibilityIdentifier("statistics.range")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), alignment: .top)], alignment: .leading, spacing: 12) {
                metric("Оценок", value: "\(value.totals.ratings)", id: "ratings")
                metric("Уникальных карточек", value: "\(value.totals.uniqueCards)", id: "cards")
                metric("Успешных ответов", value: value.totals.successRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "Нет данных", id: "success")
                metric("Активное время сессий", value: Duration.milliseconds(value.startedSessionActiveDurationMs)
                    .formatted(.time(pattern: .hourMinuteSecond)), id: "activeDuration")
            }
            Text("Оценки включают повторные ответы одной карточки. Успешные: Трудно + Хорошо + Легко / все оценки. Отменённые оценки исключены.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Активное время — сохранённое время сессий, начатых в периоде, целиком; пауза, сон и простой исключены. Отмена оценки не вычитает затраченное время.")
                .font(.callout).foregroundStyle(.secondary)
            if value.totals.ratings == 0 {
                CardsPanel("Нет данных за выбранный период") {
                    Label("За этот период нет ни одной действующей оценки.", systemImage: "chart.bar.xaxis")
                        .accessibilityIdentifier("statistics.empty")
                    Text("Выберите другой период или начните занятие на экране Сегодня.").foregroundStyle(.secondary)
                }
            } else {
                CardsPanel("Активность по учебным дням") {
                    Chart(value.days) { row in
                        BarMark(x: .value("Учебный день", row.day.start, unit: .day), y: .value("Оценок", row.totals.ratings))
                            .foregroundStyle(CardsColor.accent.color)
                            .accessibilityLabel(row.day.key.rawValue)
                            .accessibilityValue("Оценок: \(row.totals.ratings), карточек: \(row.totals.uniqueCards)")
                    }
                    .chartYScale(domain: 0...max(1, value.days.map(\.totals.ratings).max() ?? 1))
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 7)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.day().month()) } }
                    .environment(\.timeZone, TimeZone(identifier: value.days.last!.day.timeZoneID)!)
                    .frame(height: 240).accessibilityIdentifier("statistics.activity")
                    Text("Каждый столбец — количество оценок, включая повторные ответы. Границы учебного дня совпадают с занятием.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            CardsPanel("Распределение оценок") {
                ForEach(Array(["Снова", "Трудно", "Хорошо", "Легко"].enumerated()), id: \.offset) { index, title in
                    HStack { Text(title); Spacer(); Text("\(value.totals.grades[index])").monospacedDigit() }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(title): \(value.totals.grades[index])")
                        .accessibilityIdentifier("statistics.grade.\(index + 1)")
                }
                Text("Время ответов: " + Duration.milliseconds(value.totals.responseDurationMs).formatted(.time(pattern: .hourMinuteSecond)))
                    .foregroundStyle(.secondary).accessibilityIdentifier("statistics.responseDuration")
            }
        }
    }
    private func metric(_ title: String, value: String, id: String) -> some View {
        CardsPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                    .frame(height: 40, alignment: .topLeading)
                Text(value).font(.title2.bold()).monospacedDigit().accessibilityIdentifier("statistics.\(id)")
            }.frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
        }
    }
}
