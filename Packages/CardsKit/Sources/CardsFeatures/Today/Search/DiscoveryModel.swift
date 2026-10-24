import CardsCore
import Foundation
import Observation

public enum SearchDestination: Equatable, Sendable {
    case card(CardID), deck(DeckID)
}

@MainActor @Observable public final class DiscoveryModel {
    public var searchPresented = false
    public var text = "" { didSet { if text != oldValue { restartSearch(); searchPresented = !text.isEmpty } } }
    public private(set) var searchID = UUID()
    public private(set) var results: GlobalSearchSnapshot?
    public private(set) var searchError: String?
    public private(set) var searching = false
    public var selection = 0
    public private(set) var word: DailyWord?
    public private(set) var wordLoaded = false
    public private(set) var wordError: String?
    public private(set) var wordID = UUID()
    public let audio: AudioPreviewModel?
    private let service: any DiscoveryQueryService
    private let generation: UUID
    private let clock: any CardsCore.Clock
    private var day: Int
    private var excluded: NoteID?
    private var searchObservation: QueryObservation<GlobalSearchSnapshot>?
    private var wordObservation: QueryObservation<DailyWord?>?
    private var active = true

    public init(service: any DiscoveryQueryService, generation: UUID, clock: any CardsCore.Clock, audio: AudioPreviewModel? = nil) {
        self.service = service; self.generation = generation; self.clock = clock; self.audio = audio
        day = DailyWordDay.number(at: clock.now())
    }
    public var destinations: [SearchDestination] {
        (results?.cards.rows.map { .card($0.id) } ?? []) + (results?.decks.rows.map { .deck($0.id) } ?? [])
    }
    public var selected: SearchDestination? { destinations.indices.contains(selection) ? destinations[selection] : nil }
    public func move(_ delta: Int) {
        guard !destinations.isEmpty else { return }
        selection = (selection + delta + destinations.count) % destinations.count
    }
    public func restartSearch() {
        searchObservation?.cancel(); results = nil; searchError = nil; selection = 0
        searching = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        searchID = UUID()
    }
    public func observeSearch() async {
        guard active, searching else { return }
        let request = searchID; let query = text
        var installed: QueryObservation<GlobalSearchSnapshot>?
        defer { installed?.cancel() }
        do {
            guard query.count <= 512 else { throw CollectionQueryError.searchTooLong }
            try await Task.sleep(for: .milliseconds(180))
            let source = try await service.observeGlobalSearch(query, asOf: EpochMilliseconds(date: clock.now()))
            installed = source
            guard active, !Task.isCancelled, request == searchID else { return }
            searchObservation = source
            for try await snapshot in source {
                guard active, !Task.isCancelled, request == searchID else { return }
                guard snapshot.generation == generation else { throw CollectionAccessError.staleContext }
                let previous = selected
                results = snapshot; searching = false
                selection = previous.flatMap { destinations.firstIndex(of: $0) }
                    ?? min(selection, max(0, destinations.count - 1))
            }
        } catch {
            guard active, !Task.isCancelled, request == searchID else { return }
            results = nil; searching = false
            searchError = query.count > 512 ? "Не больше 512 символов. Сократите запрос." : "Не удалось выполнить поиск. Повторите попытку."
        }
    }
    public func refreshDay() {
        let next = DailyWordDay.number(at: clock.now())
        guard next != day else { return }
        day = next; excluded = nil; reloadWord()
    }
    public func anotherWord() {
        guard let word, word.hasAlternative else { return }
        excluded = word.noteID; reloadWord()
    }
    public func reloadWord() {
        audio?.stop(); wordObservation?.cancel(); word = nil; wordLoaded = false; wordError = nil; wordID = UUID()
    }
    public func observeWord() async {
        guard active else { return }
        let request = wordID
        var installed: QueryObservation<DailyWord?>?
        defer { installed?.cancel() }
        do {
            let source = try await service.observeDailyWord(day: day, excluding: excluded)
            installed = source
            guard active, !Task.isCancelled, request == wordID else { return }
            wordObservation = source
            for try await value in source {
                guard active, !Task.isCancelled, request == wordID else { return }
                if let value, value.generation != generation { throw CollectionAccessError.staleContext }
                // The last alternative may have been deleted while observing. Drop the old
                // exclusion and requery rather than claiming the collection has no local words.
                if value == nil, excluded != nil { excluded = nil; reloadWord(); return }
                if word != value { audio?.stop() }
                word = value; wordLoaded = true
            }
        } catch {
            guard active, !Task.isCancelled, request == wordID else { return }
            word = nil; wordLoaded = true; wordError = "Не удалось загрузить слово дня. Повторите попытку."
        }
    }
    public func stop() {
        active = false; searchPresented = false; searchObservation?.cancel(); wordObservation?.cancel(); audio?.close()
        results = nil; word = nil
    }
}
