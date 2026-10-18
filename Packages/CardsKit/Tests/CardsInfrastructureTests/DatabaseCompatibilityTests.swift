import Foundation
import GRDB
import Testing

private enum ProbeFailure: Error { case rollback }

@Test func grdbAsyncPoolPersistsAndSearchesFTS5() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("probe.sqlite").path
    let pool = try DatabasePool(path: path)
    try await pool.write { db in
        try db.execute(sql: "CREATE VIRTUAL TABLE probe USING fts5(body, tokenize='unicode61')")
        try db.execute(sql: "INSERT INTO probe(body) VALUES (?)", arguments: ["Привет, мир! Temporary fixture"])
    }
    let hits = try await pool.read { db in
        try String.fetchAll(db, sql: "SELECT body FROM probe WHERE probe MATCH ?", arguments: ["привет"])
    }
    #expect(hits == ["Привет, мир! Temporary fixture"])
    let journal = try await pool.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
    #expect(journal == "wal")
    do {
        try await pool.write { db in
            try db.execute(sql: "INSERT INTO probe(body) VALUES ('must rollback')")
            throw ProbeFailure.rollback
        }
        Issue.record("The write should have thrown")
    } catch ProbeFailure.rollback { }
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<12 {
            group.addTask {
                try await pool.write { db in
                    try db.execute(sql: "INSERT INTO probe(body) VALUES (?)", arguments: ["parallel \(index)"])
                }
                let count = try await pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM probe")! }
                #expect(count >= 2)
            }
        }
        try await group.waitForAll()
    }
    let count = try await pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM probe") }
    #expect(count == 13)
    let integrity = try await pool.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }
    #expect(integrity == "ok")
    try pool.close()
    let reopened = try DatabasePool(path: path)
    let persisted = try await reopened.read { db in
        try String.fetchAll(db, sql: "SELECT body FROM probe WHERE probe MATCH ?", arguments: ["temporary"])
    }
    #expect(persisted == hits)
    try reopened.close()
}
