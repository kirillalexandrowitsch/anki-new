import Foundation

public struct EditorWorkspace: Sendable {
    public let generation: UUID
    public let notes: any NoteRepository
    public let queries: any CollectionQueryService
    public let deletions: (any CardDeletionService)?
    public init(generation: UUID, notes: any NoteRepository, queries: any CollectionQueryService,
                deletions: (any CardDeletionService)? = nil) {
        self.generation = generation; self.notes = notes; self.queries = queries
        self.deletions = deletions
    }
}
public protocol EditorWorkspaceAccess: CollectionAccess {
    func editorWorkspace(generation: UUID) async throws -> EditorWorkspace
}
