import AppKit
import CardsCore
import CardsDesignSystem
import CoreGraphics
import SwiftUI

public struct StudyView: View {
    @Bindable private var model: StudySessionModel
    private let title: String
    private let notice: String?
    private let close: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    public init(model: StudySessionModel, title: String, notice: String? = nil, close: @escaping () -> Void) {
        self.model = model; self.title = title; self.notice = notice; self.close = close
    }

    public var body: some View {
        VStack(spacing: 20) {
            HStack {
                Label(title, systemImage: "rectangle.on.rectangle").font(.title2.bold())
                Spacer()
                if model.phase != .completed {
                    Button("Пауза", systemImage: "pause.fill") { model.pause() }
                        .disabled(!model.canPause).accessibilityIdentifier("study.pause")
                    Button("Завершить") { model.requestExit() }
                        .disabled(!model.canExit).accessibilityIdentifier("study.exit")
                }
            }
            if let notice { Text(notice).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Text("Подтверждённых оценок: \(model.confirmedRatings)")
                .foregroundStyle(.secondary).accessibilityIdentifier("study.count")
            // Keep Undo outside the changing card/summary scroll content. It must stay
            // reachable when the summary grows or the window is at its minimum height.
            if model.canUndoRating {
                Button(model.pendingUndo == nil ? "Отменить оценку" : "Повторить отмену") { Task { await model.undoRating() } }
                    .accessibilityIdentifier("study.undoRating")
            }
            ScrollView {
                VStack(spacing: 20) {
                    content
                    if let message = model.checkpointError {
                        Text(message).foregroundStyle(.red).accessibilityIdentifier("study.checkpoint.error")
                        Button("Повторить сохранение прогресса") { Task { await model.retryCheckpoint() } }
                            .accessibilityIdentifier("study.checkpoint.retry")
                    }
                    if let message = model.errorMessage {
                        Text(message).foregroundStyle(.red).accessibilityIdentifier("study.error")
                        if model.pendingCommand != nil {
                            Button("Повторить сохранение") { Task { await model.retryRating() } }
                                .accessibilityIdentifier("study.retryRating")
                        } else if model.phase == .loading {
                            Button("Повторить") { Task { await model.load() } }
                                .accessibilityIdentifier("study.retryLoad")
                        }
                    }
                    if let message = model.reviewMessage {
                        Label(message, systemImage: "arrow.uturn.backward").accessibilityIdentifier("study.undoNotice")
                    }
                    if let message = model.playback?.message ?? model.audioMessage {
                        Text(message).foregroundStyle(.secondary).accessibilityIdentifier("study.audioError")
                    }
                    if model.lastSkipped != nil, model.phase != .committing {
                        HStack {
                            Label("Карточка пропущена. Расписание не изменено.", systemImage: "forward.end")
                            Button("Отменить пропуск") { Task { await model.undoSkip() } }
                                .disabled(![.question, .answer, .completed].contains(model.phase) || model.pendingCommand != nil)
                                .accessibilityIdentifier("study.undoSkip")
                        }.font(.callout).padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                }.frame(maxWidth: .infinity).accessibilityElement(children: .contain)
            }
        }
        .padding(28).frame(minWidth: 680, idealWidth: 850, minHeight: 530, idealHeight: 680)
        .background(CardsColor.window.color)
        .disabled(model.showsExitConfirmation)
        .overlay { if model.showsExitConfirmation { exitConfirmation } }
        .background(StudyKeyRouter(model: model, requestClose: requestClose))
        .background(EditorWindowCloseGuard(requestClose: requestClose))
        .onExitCommand { model.escape() }
        .focusedSceneValue(\.studyCloseAction, StudyCloseAction(
            isEnabled: model.phase != .committing, perform: requestClose))
        .task {
            await model.load()
            while !Task.isCancelled && !model.isStopped {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                await model.heartbeat(systemIdleSeconds: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null))
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in model.setForeground(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in model.setForeground(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.setForeground(true) }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, value in model.setForeground(value == .active) }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            if model.errorMessage == nil { ProgressView("Загрузка карточки…").padding(80) }
        case .question, .answer, .committing:
            if let card = model.presentation {
                CardsPanel {
                    VStack(spacing: 24) {
                        Text("Вспомните перевод").foregroundStyle(.secondary)
                        Text(card.question).cardsText(.studyWord).textSelection(.enabled)
                            .accessibilityIdentifier("study.question")
                        HStack {
                            if !card.pronunciation.isEmpty { Text(card.pronunciation).foregroundStyle(.secondary) }
                            Button("Воспроизвести снова", systemImage: "speaker.wave.2.fill") { Task { await model.playAudio() } }
                                .disabled(model.phase == .committing).accessibilityIdentifier("study.audio")
                            if model.playback?.isPlaying == true {
                                Button("Стоп", systemImage: "stop.fill") { model.stopAudio() }
                                    .accessibilityIdentifier("study.audio.stop")
                            }
                            if card.audioMediaID != nil, let audio = model.playback {
                                Button("Системное произношение") { Task { await audio.preview(text: card.question) } }
                                    .disabled(model.phase == .committing).accessibilityIdentifier("study.audio.speech")
                            }
                        }
                        if !card.example.isEmpty { Text(card.example).textSelection(.enabled) }
                        if model.phase != .question {
                            Divider()
                            Text(card.answer).cardsText(.translation).textSelection(.enabled)
                                .accessibilityIdentifier("study.answer")
                        } else {
                            Text("Попробуйте вспомнить значение, прежде чем открыть ответ.").foregroundStyle(.secondary)
                        }
                    }.padding(24).frame(maxWidth: .infinity).accessibilityElement(children: .contain)
                }
                if model.phase == .question {
                    Button("Показать ответ · Пробел") { model.reveal() }
                        .buttonStyle(CardsButtonStyle(.primary)).accessibilityIdentifier("study.reveal")
                    Button("Пропустить") { Task { await model.skip() } }.accessibilityIdentifier("study.skip")
                } else {
                    HStack(spacing: 12) {
                        rating(.again, "Снова", "arrow.counterclockwise", .red)
                        rating(.hard, "Трудно", "chart.bar.fill", .orange)
                        rating(.good, "Хорошо", "checkmark.circle.fill", .blue)
                        rating(.easy, "Легко", "forward.fill", .green)
                    }
                    if model.phase == .committing { ProgressView("Сохранение оценки…").accessibilityIdentifier("study.committing") }
                }
            }
        case .paused:
            CardsPanel {
                VStack(spacing: 24) {
                    Image(systemName: "pause.circle.fill").font(.system(size: 50)).foregroundStyle(.tint)
                    summary
                    Text("Занятие на паузе").font(.title2.bold()).accessibilityIdentifier("study.paused")
                    Button("Продолжить") { model.resume() }.buttonStyle(CardsButtonStyle(.primary))
                        .accessibilityIdentifier("study.resume")
                    Button("Завершить занятие") { model.requestExit() }.accessibilityIdentifier("study.pausedExit")
                }.padding(40).frame(maxWidth: .infinity).accessibilityElement(children: .contain)
            }
        case .completed:
            CardsPanel {
                VStack(spacing: 24) {
                    Image(systemName: "checkmark.circle").font(.system(size: 50)).foregroundStyle(.tint)
                    Text(completionTitle).font(.title2.bold()).accessibilityIdentifier("study.completed")
                    if case .future(let date) = model.completion {
                        Text("Ближайшая карточка: \(date.formatted(date: .abbreviated, time: .shortened))")
                        Button("Проверить очередь") { Task { await model.checkQueue() } }.accessibilityIdentifier("study.checkQueue")
                    }
                    summary
                    HStack {
                        Text("Снова: \(model.grades[0])")
                        Text("Трудно: \(model.grades[1])")
                        Text("Хорошо: \(model.grades[2])")
                        Text("Легко: \(model.grades[3])")
                    }.accessibilityIdentifier("study.summary.grades")
                    Button("Закрыть") { requestClose() }.disabled(model.isFinishing).buttonStyle(CardsButtonStyle(.primary)).accessibilityIdentifier("study.close")
                }.padding(40).frame(maxWidth: .infinity).accessibilityElement(children: .contain)
            }
        }
    }

    private func rating(_ grade: Grade, _ title: String, _ symbol: String, _ color: Color) -> some View {
        Button { Task { await model.rate(grade) } } label: {
            VStack(spacing: 8) { Label(title, systemImage: symbol); Text("\(grade.rawValue)").font(.caption) }
                .frame(maxWidth: .infinity).padding(12)
        }
        .buttonStyle(.bordered).tint(color).disabled(!model.canRate)
        .accessibilityIdentifier("study.grade.\(grade.rawValue)")
    }

    private var completionTitle: String {
        switch model.completion {
        case .future: "На сейчас всё"
        case .endedEarly: "Занятие завершено раньше"
        case .availableViewed: "Доступные карточки просмотрены"
        default: "Нет доступных карточек"
        }
    }

    private var exitConfirmation: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 24) {
                Label("Завершить занятие?", systemImage: "exclamationmark.triangle").font(.title2.bold())
                Text("Подтверждённых оценок: \(model.confirmedRatings). Пропуск не считается оценкой.")
                HStack {
                    Button("Продолжить занятие") { model.cancelExit() }
                        .keyboardShortcut(.cancelAction).accessibilityIdentifier("study.exit.cancel")
                    Button("Завершить занятие", role: .destructive) { model.confirmExit() }
                        .accessibilityIdentifier("study.exit.confirm")
                }
            }.padding(32).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .accessibilityElement(children: .contain)
    }

    private var summary: some View {
        VStack(spacing: 8) {
            Text("Оценок: \(model.confirmedRatings) · Карточек: \(model.uniqueCards)")
            Text("Активное время: \(model.activeDurationMs / 60_000) мин \((model.activeDurationMs / 1000) % 60) с")
            Text("Пропущено в этом занятии: \(model.skipped.count)")
        }.foregroundStyle(.secondary).accessibilityElement(children: .contain).accessibilityIdentifier("study.summary")
    }

    private func requestClose() {
        if model.phase == .completed {
            Task { if await model.finishSession() { close() } }
        } else { model.requestExit() }
    }
}
