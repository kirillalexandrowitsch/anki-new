import CardsCore
import CardsFeatures
import Foundation
import Testing

private actor EditorRepository: DeckRepository {
    var requests: [SaveDeckCommand] = []
    var failure: CollectionRepositoryError?
    var delayed = false
    var pending: CheckedContinuation<Deck, any Error>?
    func configure(failure: CollectionRepositoryError? = nil, delayed: Bool = false) {
        self.failure = failure; self.delayed = delayed
    }
    func deck(id: DeckID) -> Deck? { nil }
    func save(_ command: SaveDeckCommand) async throws -> Deck {
        requests.append(command)
        if let failure { throw failure }
        if delayed { return try await withCheckedThrowingContinuation { pending = $0 } }
        return try result(command)
    }
    func result(_ command: SaveDeckCommand) throws -> Deck {
        try Deck(id: command.deckID, parentID: command.parentID, name: command.name,
             description: command.description, iconKey: command.iconKey, colorKey: command.colorKey,
             revision: command.expectedRevision?.advanced() ?? .initial)
    }
    func complete() throws { pending?.resume(returning: try result(requests.last!)); pending = nil }
    func commands() -> [SaveDeckCommand] { requests }
    func isWaiting() -> Bool { pending != nil }
}

@Test @MainActor func cancellingDeckDraftNeverInvokesRepository() async throws {
    let repository = EditorRepository()
    let base = try Deck(id: DeckID(), name: EntityName("Исходное"), description: "До")
    for original in [nil, base] {
        let editor = DeckEditorModel(repository: repository, original: original)
        editor.input = DeckInput(name: "Несохранённое", description: "После", iconKey: "star", colorKey: "pink")
        editor.cancel()
        #expect(!editor.canSave)
        #expect(await editor.save() == nil)
    }
    #expect(await repository.commands().isEmpty)
}

@Test @MainActor func invalidAndDuplicateDeckNameCanBeCorrectedWithoutLosingDraft() async throws {
    let repository = EditorRepository()
    let editor = DeckEditorModel(repository: repository)
    #expect(!editor.canSave && editor.requiredNameError != nil)
    editor.input.name = " \n"
    #expect(await editor.save() == nil)
    #expect(await repository.commands().isEmpty)
    editor.input = DeckInput(name: "Дубликат", description: "Сохранить описание", iconKey: "heart", colorKey: "green")
    let draft = editor.input
    await repository.configure(failure: .validation(.duplicateName(normalized: "дубликат")))
    #expect(await editor.save() == nil)
    #expect(editor.nameError != nil && editor.input == draft && editor.canSave)
    editor.input.name = "Другое"
    editor.clearNameError()
    #expect(editor.nameError == nil)
    await repository.configure()
    #expect(await editor.save()?.name.displayValue == "Другое")
}

@Test @MainActor func revisionConflictRetainsOriginalNameAndUncommittedDraft() async throws {
    let repository = EditorRepository()
    let original = try Deck(id: DeckID(), name: EntityName("Исходное"), description: "Оригинал")
    let editor = DeckEditorModel(repository: repository, original: original)
    editor.input = DeckInput(name: "Мой черновик", description: "Мой текст", iconKey: "star", colorKey: "teal")
    let draft = editor.input
    await repository.configure(failure: .revisionConflict(entity: .deck(original.id), expected: .initial,
                                                         actual: try Revision(1)))
    #expect(await editor.save() == nil)
    #expect(editor.original == original && editor.original?.name.displayValue == "Исходное")
    #expect(editor.input == draft && editor.errorMessage != nil && editor.hasConflict && !editor.canSave)
    #expect(await editor.save() == nil)
    #expect(await repository.commands().count == 1)
}

@Test @MainActor func failedDeckSaveRetriesSameCommandAndChangedInputUsesNewCommand() async throws {
    let repository = EditorRepository()
    await repository.configure(failure: .insufficientSpace)
    let editor = DeckEditorModel(repository: repository)
    editor.input.name = "Повтор"
    #expect(await editor.save() == nil)
    #expect(editor.errorMessage != nil && editor.canSave)
    #expect(await editor.save() == nil)
    editor.input.name = "Изменённый повтор"
    await repository.configure()
    #expect(await editor.save() != nil)
    let commands = await repository.commands()
    #expect(commands.count == 3)
    #expect(commands[0] == commands[1])
    #expect(commands[2].commandID != commands[0].commandID)
    #expect(commands[2].deckID == commands[0].deckID)
}

@Test @MainActor func inFlightDeckSaveDisallowsDoubleSubmitAndCancelAndRejectsRetiredResult() async throws {
    let repository = EditorRepository()
    await repository.configure(delayed: true)
    let editor = DeckEditorModel(repository: repository)
    editor.input.name = "Ожидание"
    let first = Task { await editor.save() }
    while !(await repository.isWaiting()) { await Task.yield() }
    #expect(editor.isSaving && !editor.canSave)
    editor.cancel()
    #expect(await editor.save() == nil)
    #expect(await repository.commands().count == 1)
    editor.stop()
    try await repository.complete()
    #expect(await first.value == nil)
    #expect(!editor.isSaving && !editor.canSave)
}
