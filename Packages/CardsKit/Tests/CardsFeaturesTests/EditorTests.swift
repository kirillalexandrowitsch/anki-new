import CardsCore
import CardsFeatures
import Foundation
import Testing

private actor NoteEditorRepository: NoteRepository {
    var requests: [SaveNoteCommand] = []
    var failure: CollectionRepositoryError?
    var saved: SavedBasicNote?
    var delayed = false
    var pending: CheckedContinuation<Void, Never>?
    func configure(failure: CollectionRepositoryError? = nil, delayed: Bool = false) {
        self.failure = failure; self.delayed = delayed
    }
    func note(id: NoteID) -> SavedBasicNote? { saved }
    func commands() -> [SaveNoteCommand] { requests }
    func isWaiting() -> Bool { pending != nil }
    func complete() { pending?.resume(); pending = nil }
    func save(_ command: SaveNoteCommand) async throws -> SavedBasicNote {
        requests.append(command)
        if let failure { throw failure }
        if delayed { await withCheckedContinuation { pending = $0 } }
        let result = SavedBasicNote(note: Note(id: command.noteID, noteTypeID: BasicNoteType.id,
            fields: ["front": command.content.front, "back": command.content.back],
            createdAt: .distantPast, updatedAt: .distantPast, revision: try command.expectedRevision?.advanced() ?? .initial),
            content: command.content, tags: try command.tags.map(EntityName.init),
            card: saved?.card ?? Card(id: CardID(), noteID: command.noteID, deckID: command.initialDeckID,
                variantKey: BasicNoteType.variantKey, templateID: BasicNoteType.templateID, createdAt: .distantPast))
        saved = result
        return result
    }
}
private func syntheticDeck() throws -> Deck { Deck(id: DeckID(), name: try EntityName("Synthetic")) }
@MainActor private func validDraft(_ model: EditorModel) {
    model.draft.front = "A phrase with spaces and 123"
    model.draft.back = "Перевод"
}

@Test @MainActor func emptyAndWhitespaceNoteDraftsNeverWriteAndPreviewUsesValues() async throws {
    let repository = NoteEditorRepository()
    let model = EditorModel(repository: repository, decks: [try syntheticDeck()])
    #expect(model.state == .empty && !model.canSave && !model.isDirty)
    for (front, back) in [(" \n", "Back"), ("Front", "\t"), ("", "")] {
        model.draft.front = front; model.draft.back = back
        #expect(!model.canSave && model.state != .valid)
        #expect(await model.save() == nil)
    }
    #expect(await repository.commands().isEmpty)
    validDraft(model)
    model.draft.examples = [NoteExample(en: "Example", ru: "Пример")]
    model.draft.pronunciation = "/test/"
    #expect(model.state == .valid && model.draft.content.front == model.draft.front)
    #expect(model.draft.content.examples == model.draft.examples)
    let noDeck = EditorModel(repository: repository, decks: [])
    validDraft(noDeck)
    #expect(!noDeck.canSave)
    #expect(await noDeck.save() == nil)
}

@Test @MainActor func closeSaveDiscardCancelHaveDistinctResultsIncludingInvalidSave() async throws {
    let repository = NoteEditorRepository()
    let deck = try syntheticDeck()
    let clean = EditorModel(repository: repository, decks: [deck])
    clean.requestClose()
    #expect(clean.isClosed && !clean.showsUnsavedWarning)
    let cancel = EditorModel(repository: repository, decks: [deck])
    validDraft(cancel)
    let draft = cancel.draft
    cancel.requestClose()
    #expect(cancel.showsUnsavedWarning && !cancel.isClosed)
    await cancel.resolveClose(.cancel)
    #expect(cancel.draft == draft && !cancel.showsUnsavedWarning && !cancel.isClosed)
    cancel.requestClose()
    await cancel.resolveClose(.discard)
    #expect(cancel.isClosed)
    #expect(await cancel.save() == nil)
    #expect(await repository.commands().isEmpty)
    let invalid = EditorModel(repository: repository, decks: [deck])
    invalid.draft.front = "Only front"
    invalid.requestClose()
    await invalid.resolveClose(.save)
    #expect(!invalid.isClosed && invalid.draft.front == "Only front")
    #expect(await repository.commands().isEmpty)
    let save = EditorModel(repository: repository, decks: [deck])
    validDraft(save)
    save.requestClose()
    await save.resolveClose(.save)
    #expect(save.isClosed && !save.isDirty)
    #expect(await repository.commands().count == 1)
}

@Test @MainActor func diskFailureRetainsDraftAndCloseSaveStaysOpenThenRetriesSameCommand() async throws {
    let repository = NoteEditorRepository()
    let model = EditorModel(repository: repository, decks: [try syntheticDeck()])
    validDraft(model)
    let draft = model.draft
    await repository.configure(failure: .insufficientSpace)
    model.requestClose()
    await model.resolveClose(.save)
    #expect(model.state == .failed && !model.isClosed && model.draft == draft)
    #expect(model.errorMessage?.contains("диске") == true && model.canSave)
    #expect(await model.save() == nil)
    await repository.configure()
    #expect(await model.save() != nil && model.isClosed)
    let commands = await repository.commands()
    #expect(commands.count == 3 && commands[0] == commands[1] && commands[1] == commands[2])
}

@Test @MainActor func editsPreserveMediaTagsAndAllExamplesAndUseOriginalRevision() async throws {
    let repository = NoteEditorRepository()
    let deck = try syntheticDeck()
    let create = EditorModel(repository: repository, decks: [deck])
    validDraft(create)
    create.draft.tags = ["Tag"]
    create.draft.media = [NoteMediaReference(mediaID: MediaID(), fieldID: "image", role: .image)]
    create.draft.examples = [NoteExample(en: "One", ru: "Один"), NoteExample(en: "Two")]
    let saved = try #require(await create.save())
    let edit = EditorModel(repository: repository, decks: [deck], original: saved)
    #expect(!edit.isDirty && edit.state == .valid)
    edit.draft.back = "Changed"
    let updated = try #require(await edit.save())
    let command = try #require(await repository.commands().last)
    #expect(command.noteID == saved.note.id && command.expectedRevision == saved.note.revision)
    #expect(command.content.examples == saved.content.examples && command.content.media == saved.content.media)
    #expect(command.tags == ["Tag"] && updated.card == saved.card)
}

@Test @MainActor func savingRejectsDoubleSubmitCloseAndRetiredResponses() async throws {
    let repository = NoteEditorRepository()
    await repository.configure(delayed: true)
    let model = EditorModel(repository: repository, decks: [try syntheticDeck()])
    validDraft(model)
    let task = Task { await model.save() }
    while !(await repository.isWaiting()) { await Task.yield() }
    #expect(model.state == .saving && !model.canSave)
    model.requestClose()
    await model.resolveClose(.discard)
    #expect(!model.isClosed && !model.showsUnsavedWarning)
    #expect(await model.save() == nil)
    #expect(await repository.commands().count == 1)
    model.stop()
    await repository.complete()
    #expect(await task.value == nil && model.isClosed)
}

@Test @MainActor func changedRetryUsesNewCommandButSameNoteIdentityAndStaleContextCannotWrite() async throws {
    let repository = NoteEditorRepository()
    let model = EditorModel(repository: repository, decks: [try syntheticDeck()])
    validDraft(model)
    await repository.configure(failure: .permissionDenied)
    #expect(await model.save() == nil)
    model.draft.back = "Corrected retry"
    #expect(await model.save() == nil)
    let commands = await repository.commands()
    #expect(commands.count == 2 && commands[0].noteID == commands[1].noteID)
    #expect(commands[0].commandID != commands[1].commandID)
    await repository.configure(failure: .staleContext)
    #expect(await model.save() == nil)
    #expect(model.hasConflict && !model.canSave && model.draft.back == "Corrected retry")
    #expect(await model.save() == nil)
    #expect(await repository.commands().count == 3)
}
