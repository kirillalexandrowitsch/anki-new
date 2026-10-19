import Foundation

public struct EditorWorkspace: Sendable {
    public let generation: UUID
    public let notes: any NoteRepository
    public let queries: any CollectionQueryService
    public init(generation: UUID, notes: any NoteRepository, queries: any CollectionQueryService) {
        self.generation = generation; self.notes = notes; self.queries = queries
    }
}
public protocol EditorWorkspaceAccess: CollectionAccess {
    func editorWorkspace(generation: UUID) async throws -> EditorWorkspace
}
