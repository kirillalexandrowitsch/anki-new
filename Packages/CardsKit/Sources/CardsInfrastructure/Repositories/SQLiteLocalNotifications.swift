import CardsCore
import Foundation
import GRDB

struct SQLiteLocalNotifications: LocalNotificationRepository {
    let writer: CollectionWriter
    let clock: any CardsCore.Clock
    private struct Payload: Codable {
        let schemaVersion: Int
        let event: LocalNotificationEvent
    }

    private static func fetch(_ db: Database) throws -> [LocalNotificationMessage] {
        try Row.fetchAll(db, sql: "SELECT * FROM local_notifications ORDER BY createdAt DESC, id DESC LIMIT ?",
                         arguments: [LocalNotificationPolicy.historyLimit]).map { row in
            let payload = try JSONDecoder().decode(Payload.self, from: Data((row["payloadJSON"] as String).utf8))
            guard payload.schemaVersion == 1, payload.event.kind == row["kind"] as String,
                  let id = UUID(uuidString: row["id"]) else { throw CollectionRepositoryError.unsupportedCommandResult }
            let readAt: Int64? = row["readAt"]
            return LocalNotificationMessage(id: id, event: payload.event,
                createdAt: Date(timeIntervalSince1970: Double(row["createdAt"] as Int64) / 1000),
                readAt: readAt.map { Date(timeIntervalSince1970: Double($0) / 1000) })
        }
    }

    func messages() async throws -> [LocalNotificationMessage] { try await writer.read { try Self.fetch($0) } }
    func observe() async throws -> QueryObservation<[LocalNotificationMessage]> {
        try await writer.observe(tables: ["local_notifications"]) { try Self.fetch($0) }
    }

    func record(id: UUID, event: LocalNotificationEvent) async throws {
        if case .reminderScheduled(let date) = event { _ = try EpochMilliseconds(date: date) }
        let now = try EpochMilliseconds(date: clock.now()).rawValue
        let json = String(decoding: try JSONEncoder().encode(Payload(schemaVersion: 1, event: event)), as: UTF8.self)
        // Bounded ephemeral history deliberately has no unbounded processed_commands payload.
        try await writer.mediaAccess { pool in
            try pool.write { db in
                try db.execute(sql: "INSERT INTO local_notifications(id,kind,createdAt,payloadJSON) VALUES (?,?,?,?) ON CONFLICT(id) DO NOTHING",
                    arguments: [id.uuidString.lowercased(), event.kind, now, json])
                try db.execute(sql: "DELETE FROM local_notifications WHERE id NOT IN (SELECT id FROM local_notifications ORDER BY createdAt DESC, id DESC LIMIT ?)",
                    arguments: [LocalNotificationPolicy.historyLimit])
            }
        }
    }

    func markRead(ids: [UUID]) async throws {
        guard ids.count <= LocalNotificationPolicy.historyLimit else { throw ValidationError.outOfRange(field: "notificationIDs") }
        let now = try EpochMilliseconds(date: clock.now()).rawValue
        try await writer.mediaAccess { pool in
            try pool.write { db in
                for id in Set(ids) {
                    try db.execute(sql: "UPDATE local_notifications SET readAt=? WHERE id=? AND readAt IS NULL",
                                   arguments: [now, id.uuidString.lowercased()])
                }
            }
        }
    }
}
