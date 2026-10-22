import Foundation

public struct DelimitedTextDiagnostic: Error, Equatable, Sendable, LocalizedError {
    public enum Reason: String, Sendable { case invalidUTF8, unexpectedQuote, unclosedQuote, columnCount, limitExceeded }
    public let line: Int
    public let column: Int
    public let reason: Reason
    public var errorDescription: String? { "Строка \(line), поле \(column): \(reason.rawValue)" }
}

/// Byte state machine: ASCII delimiters never split a UTF-8 scalar. Decode each
/// bounded cell strictly, so chunk boundaries may occur inside scalars or CRLF.
public struct DelimitedTextParser {
    private enum State { case start, plain, quoted, closed }
    private var state = State.start
    private let separator: UInt8
    private let expectedColumns: Int?
    private var width: Int?
    private var cell = Data()
    private var row: [String] = []
    private var prefix: [UInt8] = []
    private var started = false
    private var pendingCR = false
    private var line = 1
    private var rows = 0
    private var bytes = 0
    private var touched = false
    private var finished = false

    public init(tabSeparated: Bool = false, expectedColumns: Int? = nil) {
        separator = tabSeparated ? 9 : 44
        self.expectedColumns = expectedColumns
    }

    public mutating func feed(_ data: Data, emit: ([String]) throws -> Void) throws {
        guard !finished else { throw diagnostic(.unexpectedQuote) }
        bytes += data.count
        guard bytes <= 256 * 1024 * 1024 else { throw diagnostic(.limitExceeded) }
        for byte in data {
            if !started {
                prefix.append(byte)
                if prefix.count < 3 { continue }
                started = true
                if prefix != [0xef, 0xbb, 0xbf] { for value in prefix { try consume(value, emit: emit) } }
                prefix.removeAll()
            } else { try consume(byte, emit: emit) }
        }
    }

    public mutating func finish(emit: ([String]) throws -> Void) throws {
        guard !finished else { return }
        if !started { for byte in prefix { try consume(byte, emit: emit) }; prefix.removeAll() }
        guard state != .quoted else { throw diagnostic(.unclosedQuote) }
        if touched || !row.isEmpty || !cell.isEmpty { try endRow(emit) }
        finished = true
    }

    public static func read(_ url: URL, tabSeparated: Bool = false, emit: ([String]) throws -> Void) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var parser = Self(tabSeparated: tabSeparated)
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            try parser.feed(data, emit: emit)
        }
        try parser.finish(emit: emit)
    }

    private mutating func consume(_ byte: UInt8, emit: ([String]) throws -> Void) throws {
        let afterCR = pendingCR
        pendingCR = byte == 13
        if byte == 10 && afterCR {
            if state == .quoted { try append(byte) }
            return
        }
        if state == .quoted {
            if byte == 34 { state = .closed } else { try append(byte) }
            if byte == 13 || byte == 10 { line += 1 }
            return
        }
        if byte == 13 || byte == 10 {
            try endRow(emit)
            line += 1
        } else if byte == separator {
            try endCell(); state = .start; touched = true
        } else if byte == 34 {
            if state == .start { state = .quoted; touched = true }
            else if state == .closed { try append(34); state = .quoted }
            else { throw diagnostic(.unexpectedQuote) }
        } else {
            guard state != .closed else { throw diagnostic(.unexpectedQuote) }
            try append(byte); state = .plain; touched = true
        }
    }

    private mutating func append(_ byte: UInt8) throws {
        guard cell.count < 1024 * 1024 else { throw diagnostic(.limitExceeded) }
        cell.append(byte)
    }
    private mutating func endCell() throws {
        guard row.count < 256 else { throw diagnostic(.limitExceeded) }
        guard let text = String(data: cell, encoding: .utf8) else { throw diagnostic(.invalidUTF8) }
        row.append(text); cell.removeAll(keepingCapacity: true)
    }
    private mutating func endRow(_ emit: ([String]) throws -> Void) throws {
        try endCell()
        let count = expectedColumns ?? width ?? row.count
        guard row.count == count else { throw diagnostic(.columnCount) }
        width = count; rows += 1
        guard rows <= 100_001 else { throw diagnostic(.limitExceeded) }
        try emit(row)
        row.removeAll(keepingCapacity: true); state = .start; touched = false
    }
    private func diagnostic(_ reason: DelimitedTextDiagnostic.Reason) -> DelimitedTextDiagnostic {
        DelimitedTextDiagnostic(line: line, column: row.count + 1, reason: reason)
    }
}

public enum DelimitedTextWriter {
    public static func record(_ fields: [String], tabSeparated: Bool = false, safeSpreadsheet: Bool = false) -> Data {
        let separator = tabSeparated ? "\t" : ","
        let cells = fields.map { value in
            let text = (safeSpreadsheet ? "'" : "") + value
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return Data((cells.joined(separator: separator) + "\r\n").utf8)
    }
}
