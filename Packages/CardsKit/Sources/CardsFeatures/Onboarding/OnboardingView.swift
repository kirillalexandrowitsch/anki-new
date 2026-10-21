import CardsCore
import CardsDesignSystem
import SwiftUI

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    let completed: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 68)).foregroundStyle(CardsColor.accent.color)
                .padding(20).accessibilityHidden(true)
            Text(model.showsWelcome ? "Добро пожаловать в Карточки" : "У вас пока нет колод")
                .font(.largeTitle.weight(.bold)).multilineTextAlignment(.center)
                .accessibilityIdentifier("onboarding.title")
            Text("Запоминайте английские слова и фразы. Создайте первую колоду и добавьте свой материал.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.isLoading {
                ProgressView("Подготовка…")
            } else if let error = model.errorMessage, !model.showsCreator {
                Text(error).foregroundStyle(.red)
                Button("Повторить") { Task { await model.load() } }
            } else {
                Button("Создать первую колоду") { model.create() }
                    .buttonStyle(CardsButtonStyle(.primary)).accessibilityIdentifier("onboarding.create")
                Button("Импортировать карточки") {}
                    .buttonStyle(CardsButtonStyle(.secondary)).disabled(true)
                    .accessibilityIdentifier("onboarding.import")
                    .help("Импорт станет доступен после подключения мастера импорта (T051).")
                Text("Импорт пока недоступен. Мастер импорта появится в следующем этапе.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("onboarding.importUnavailable")
                if model.showsWelcome {
                    Button("Пока пропустить") { model.cancel() }
                        .accessibilityIdentifier("onboarding.skip")
                }
            }
        }
        .padding(32).frame(maxWidth: .infinity, minHeight: 400)
        .background(CardsColor.surface.color, in: RoundedRectangle(cornerRadius: 16))
        .sheet(isPresented: Binding(get: { model.showsCreator }, set: { if !$0 { model.cancel() } })) {
            OnboardingCreatorView(model: model, completed: completed)
        }
    }
}

private struct OnboardingCreatorView: View {
    @Bindable var model: OnboardingModel
    let completed: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Первая колода").font(.title2.weight(.semibold))
            Text("Название можно изменить позже. Карточки добавляются только по вашему выбору.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Название колоды (обязательно)")
                TextField("Например, Мой английский", text: $model.name)
                    .textFieldStyle(.roundedBorder).focused($nameFocused)
                    .accessibilityLabel("Название колоды").accessibilityIdentifier("onboarding.name")
                if let error = model.nameError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Toggle("Добавить три демо-карточки", isOn: $model.includeDemo)
                .accessibilityIdentifier("onboarding.demo")
            Text("Английский → Русский · Basic")
                .font(.caption).foregroundStyle(.secondary)
            if model.includeDemo {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(OnboardingDemo.notes, id: \.front) { note in
                        HStack { Text(note.front); Spacer(); Text(note.back).foregroundStyle(.secondary) }
                    }
                    Text("Эти записи получат тег «Демо». Их можно изменить в библиотеке.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            } else {
                Text("Будет создана пустая колода. Добавьте свои карточки в библиотеке.")
                    .foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("onboarding.error")
            }
            HStack {
                if model.isSaving { ProgressView().controlSize(.small); Text("Создание…") }
                Spacer()
                Button("Отмена") { model.cancel() }.keyboardShortcut(.cancelAction)
                    .disabled(model.isSaving).accessibilityIdentifier("onboarding.cancel")
                Button("Создать") { Task { if await model.save() { completed() } } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave).accessibilityIdentifier("onboarding.save")
            }
        }
        .padding(24).frame(width: 470)
        .disabled(model.isSaving)
        .interactiveDismissDisabled()
        .onAppear { nameFocused = true }
        .onExitCommand { model.cancel() }
    }
}

struct OnboardingSuccessView: View {
    @Bindable var model: OnboardingModel
    let openDecks: () -> Void
    var body: some View {
        if let result = model.result {
            CardsPanel("Колода «\(result.deck.name.displayValue)» создана") {
                HStack(alignment: .top) {
                    Label(result.demoCount == 0 ? "Добавьте первую карточку в библиотеке." : "Добавлены 3 демо-карточки. Можно начинать занятие.",
                          systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Закрыть", systemImage: "xmark") { model.dismissSuccess() }.labelStyle(.iconOnly)
                        .accessibilityIdentifier("onboarding.dismissSuccess")
                }
                if result.demoCount > 0 {
                    ForEach(OnboardingDemo.notes, id: \.front) { note in
                        HStack { Text(note.front); Spacer(); Text(note.back).foregroundStyle(.secondary) }
                    }
                }
                Button("Перейти к колодам", action: openDecks).accessibilityIdentifier("onboarding.openDecks")
            }.accessibilityElement(children: .contain).accessibilityIdentifier("onboarding.success")
        }
    }
}
