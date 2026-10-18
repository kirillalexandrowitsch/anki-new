import CardsCore
import Foundation
import GRDB

private struct CommandHeader: Decodable {
    let schemaVersion: Int
    let kind: String
    let request: String
}

private struct CommandResult<Value: Codable & Sendable>: Codable, Sendable {
    let schemaVersion: Int
    let kind: String
    let request: String
    let result: Value
}

/// One actor per owned collection. Transaction closures are synchronous and Infrastructure-only.
public actor CollectionWriter {
    private let database: CollectionDatabase
    private let clock: any CardsCore.Clock
    private var accepting = true

    init(database: CollectionDatabase, clock: any CardsCore.Clock) {
        self.database = database
        self.clock = clock
    }

    // Keep the SQL-capable API internal. Future domain repositories reuse this boundary.
    func execute<Request: Encodable & Sendable, Value: Codable & Sendable>(
        commandID: CommandID, kind: String, request: Request,
        mutation: @Sendable (Database) throws -> Value
    ) throws -> Value {
        try requireActive()
        guard !Task.isCancelled else { throw CollectionRepositoryError.cancelled }
        do {
            let requestJSON = try Self.json(request)
            let createdAt = try EpochMilliseconds(date: clock.now()).rawValue
            // The synchronous overload deliberately has no suspension between guard and commit.
            return try database.pool.write { db in
                if let row = try Row.fetchOne(db,
                    sql: "SELECT resultVersion, resultJSON FROM processed_commands WHERE commandID = ?",
                    arguments: [commandID.rawValue.uuidString.lowercased()]) {
                    let version: Int = row["resultVersion"]
                    guard version == 1 else { throw CollectionRepositoryError.unsupportedCommandResult }
                    let data = Data((row["resultJSON"] as String).utf8)
                    let header = try JSONDecoder().decode(CommandHeader.self, from: data)
                    guard header.schemaVersion == 1 else {
                        throw CollectionRepositoryError.unsupportedCommandResult
                    }
                    guard header.kind == kind, header.request == requestJSON else {
                        throw CollectionRepositoryError.commandIDReused
                    }
                    return try JSONDecoder().decode(CommandResult<Value>.self, from: data).result
                }
                let value = try mutation(db)
                let resultJSON = try Self.json(CommandResult(schemaVersion: 1, kind: kind,
                                                            request: requestJSON, result: value))
                try db.execute(sql: """
                    INSERT INTO processed_commands(commandID, resultVersion, resultJSON, createdAt)
                    VALUES (?, 1, ?, ?)
                    """, arguments: [commandID.rawValue.uuidString.lowercased(), resultJSON, createdAt])
                return value
            }
        } catch { throw Self.translate(error) }
    }

    func read<Value: Sendable>(_ query: @escaping @Sendable (Database) throws -> Value) async throws -> Value {
        try requireActive()
        do {
            try Task.checkCancellation()
            let value = try await database.pool.read(query)
            try requireActive() // close can run while the async read is suspended
            return value
        } catch {
            try requireActive()
            throw Self.translate(error)
        }
    }

    func close() throws {
        accepting = false
        try database.close()
    }

    private func requireActive() throws {
        guard accepting else { throw CollectionRepositoryError.staleContext }
    }

    private static func json<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func translate(_ error: any Error) -> CollectionRepositoryError {
        if let error = error as? CollectionRepositoryError { return error }
        if let error = error as? ValidationError { return .validation(error) }
        if error is CancellationError { return .cancelled }
        if let error = error as? DatabaseError {
            switch error.resultCode {
            case .SQLITE_FULL: return .insufficientSpace
            case .SQLITE_PERM, .SQLITE_AUTH, .SQLITE_READONLY: return .permissionDenied
            case .SQLITE_CORRUPT, .SQLITE_NOTADB, .SQLITE_CONSTRAINT: return .integrityFailure
            default: return .storage(code: error.extendedResultCode.rawValue)
            }
        }
        return .integrityFailure
    }
}
