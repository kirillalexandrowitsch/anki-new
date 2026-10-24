import CardsCore
import CardsDesignSystem
import SwiftUI

public struct GlobalSearchView: View {
    @Bindable var model: DiscoveryModel
    let open: (SearchDestination) -> Void
    let allCards: (String) -> Void
    let allDecks: (String) -> Void
    let create: () -> Void

    public init(model: DiscoveryModel, open: @escaping (SearchDestination) -> Void,
                allCards: @escaping (String) -> Void, allDecks: @escaping (String) -> Void, create: @escaping () -> Void) {
        self.model = model; self.open = open; self.allCards = allCards; self.allDecks = allDecks; self.create = create
    }
    public var body: some View {
        SearchInput(text: $model.text, identifier: "globalSearch.field", route: routeKey)
            .frame(width: 260, height: 26)
    }

    /// An in-window popover keeps the native field editor active while query snapshots change.
    public var resultsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error = model.searchError {
                    Text(error).foregroundStyle(.red)
                    Button("Повторить") { model.restartSearch() }
                } else if model.searching { ProgressView("Поиск…") }
                else if let results = model.results {
                    if model.destinations.isEmpty {
                        Label("Ничего не найдено", systemImage: "magnifyingglass").font(.headline)
                            .accessibilityIdentifier("globalSearch.empty")
                        Text("Нет карточек или колод по этому запросу.").foregroundStyle(.secondary)
                        Button("Очистить запрос") { model.text = ""; model.searchPresented = false }
                        Button("Создать карточку") { model.searchPresented = false; create() }
                            .accessibilityIdentifier("globalSearch.create")
                    } else {
                        HStack {
                            Text("Карточки (\(results.cards.cardCount))").font(.headline)
                            Spacer()
                            Button("Показать все") { model.searchPresented = false; allCards(model.text) }
                        }
                        ForEach(results.cards.rows) { row in
                            result(.card(row.id), title: row.front, subtitle: row.back)
                        }
                        Divider()
                        HStack {
                            Text("Колоды (\(results.decks.deckCount))").font(.headline)
                            Spacer()
                            Button("Показать все колоды") { model.searchPresented = false; allDecks(model.text) }
                        }
                        ForEach(results.decks.rows) { row in
                            result(.deck(row.id), title: row.deck.name.displayValue, subtitle: "Карточек: \(row.counts.cards)")
                        }
                        Text("↑ ↓ — выбор · Return — открыть · Escape — закрыть")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(16)
        }.frame(width: 390).frame(maxHeight: popoverHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(nsColor: .separatorColor)))
        .shadow(radius: 12, y: 5)
        .onKeyPress(.downArrow) { model.move(1); return .handled }
        .onKeyPress(.upArrow) { model.move(-1); return .handled }
        .onKeyPress(.return) { routeKey(36); return .handled }
        .onKeyPress(.escape) { model.searchPresented = false; return .handled }
    }
    private func routeKey(_ code: UInt16) {
        if !model.searchPresented, !model.text.isEmpty, code != 53 { model.searchPresented = true; return }
        switch code {
        case 125: model.move(1)
        case 126: model.move(-1)
        case 53: model.searchPresented = false
        default: if let selected = model.selected { choose(selected) }
        }
    }
    private var popoverHeight: CGFloat {
        if model.searchError != nil { return 140 }
        if model.searching { return 80 }
        if model.destinations.isEmpty { return 210 }
        return min(520, 160 + CGFloat(model.destinations.count) * 64)
    }
    private func choose(_ destination: SearchDestination) { model.searchPresented = false; open(destination) }
    private func result(_ destination: SearchDestination, title: String, subtitle: String) -> some View {
        Button { choose(destination) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.medium).lineLimit(1)
                    Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if model.selected == destination { Image(systemName: "return") }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(model.selected == destination ? Color.accentColor.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityValue(model.selected == destination ? "Выбрано" : "")
            .accessibilityIdentifier("globalSearch.result.\(model.destinations.firstIndex(of: destination) ?? 0)")
    }
}

public struct DailyWordView: View {
    @Bindable var model: DiscoveryModel
    let open: (CardID) -> Void
    public init(model: DiscoveryModel, open: @escaping (CardID) -> Void) { self.model = model; self.open = open }
    public var body: some View {
        CardsPanel("Слово дня") {
            if let error = model.wordError {
                Text(error).foregroundStyle(.red)
                Button("Повторить") { model.reloadWord() }
            } else if let word = model.word {
                HStack {
                    Text(word.content.front).font(.largeTitle.bold()).textSelection(.enabled)
                        .accessibilityIdentifier("dailyWord.front")
                    if let audio = model.audio {
                        Button { Task { await audio.preview(text: word.content.front,
                            mediaID: word.content.media.first { $0.role == .audio }?.mediaID) } } label: {
                            Label(audio.isPlaying ? "Прослушивается…" : "Произнести", systemImage: "speaker.wave.2.fill")
                        }.accessibilityIdentifier("dailyWord.audio")
                    }
                    Spacer()
                    Button("Другое слово", systemImage: "arrow.clockwise") { model.anotherWord() }
                        .disabled(!word.hasAlternative).accessibilityIdentifier("dailyWord.another")
                }
                if !word.content.pronunciation.isEmpty { Text(word.content.pronunciation).foregroundStyle(.secondary) }
                Text(word.content.back).textSelection(.enabled)
                ForEach(Array(word.content.examples.enumerated()), id: \.offset) { _, example in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(example.en)
                        if !example.ru.isEmpty { Text(example.ru).foregroundStyle(.secondary) }
                    }.padding(.vertical, 6)
                }
                if let message = model.audio?.message { Text(message).foregroundStyle(.secondary) }
                Button("Открыть карточку") { open(word.cardID) }.accessibilityIdentifier("dailyWord.open")
            } else if model.wordLoaded {
                Text("Нет подходящих локальных слов. Добавьте карточку с английским словом и переводом.")
                    .foregroundStyle(.secondary).accessibilityIdentifier("dailyWord.empty")
            } else { ProgressView("Загрузка слова дня…") }
        }
        .task(id: model.wordID) { await model.observeWord() }
        .task {
            model.refreshDay()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                model.refreshDay()
            }
        }
        .onDisappear { model.audio?.stop() }
    }
}
