import Foundation
import SQLite3

/// Dusk's history: a sample a minute, every manual switch, and every model.
/// SQLite through the system library; one file, no dependencies.
public final class Store: @unchecked Sendable {
    public struct Failure: Error, CustomStringConvertible { public let description: String }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "dusk.store")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = .sortedKeys
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Dusk")
    }

    public let directory: URL
    public var photos: URL { directory.appendingPathComponent("photos") }

    public init(directory: URL = Store.defaultDirectory) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("photos"),
                                                withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("dusk.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw Failure(description: "cannot open \(path)")
        }
        try exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS samples (time REAL PRIMARY KEY, json TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS corrections (
                id TEXT PRIMARY KEY, time REAL NOT NULL, state TEXT NOT NULL, json TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS models (time REAL PRIMARY KEY, json TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS probes (
                time REAL NOT NULL, kind TEXT NOT NULL, source TEXT NOT NULL, json TEXT NOT NULL,
                PRIMARY KEY (time, kind));
            """)
    }

    deinit { sqlite3_close(db) }

    // MARK: writes

    public func add(_ sample: Sample) {
        guard let json = try? encoder.encode(sample) else { return }
        run("INSERT OR REPLACE INTO samples (time, json) VALUES (?, ?)",
            sample.time.timeIntervalSince1970, String(decoding: json, as: UTF8.self))
    }

    public enum CorrectionState: String, Sendable { case pending, confirmed, reverted }

    public func save(_ c: Correction, state: CorrectionState) {
        guard let json = try? encoder.encode(c) else { return }
        run("INSERT OR REPLACE INTO corrections (id, time, state, json) VALUES (?, ?, ?, ?)",
            c.id.uuidString, c.time.timeIntervalSince1970, state.rawValue,
            String(decoding: json, as: UTF8.self))
    }

    public func save(_ m: Model) {
        guard let json = try? encoder.encode(m) else { return }
        run("INSERT OR REPLACE INTO models (time, json) VALUES (?, ?)",
            m.trainedAt.timeIntervalSince1970, String(decoding: json, as: UTF8.self))
    }

    public func add(_ probe: Probe) {
        guard let json = try? encoder.encode(probe) else { return }
        run("INSERT OR REPLACE INTO probes (time, kind, source, json) VALUES (?, ?, ?, ?)",
            probe.time.timeIntervalSince1970, probe.kind.rawValue, probe.source,
            String(decoding: json, as: UTF8.self))
    }

    // MARK: reads

    public func probes(since: Date) -> [Probe] {
        rows("SELECT json FROM probes WHERE time >= ? ORDER BY time", since.timeIntervalSince1970)
            .compactMap { try? decoder.decode(Probe.self, from: Data($0.utf8)) }
    }

    public func samples(since: Date) -> [Sample] {
        rows("SELECT json FROM samples WHERE time >= ? ORDER BY time", since.timeIntervalSince1970)
            .compactMap { try? decoder.decode(Sample.self, from: Data($0.utf8)) }
    }

    /// One sample per hour (the first of each), for "accepted" examples.
    public func hourlySamples(since: Date) -> [Sample] {
        rows("SELECT json FROM samples WHERE time IN (SELECT MIN(time) FROM samples WHERE time >= ? GROUP BY CAST(time / 3600 AS INTEGER)) ORDER BY time",
             since.timeIntervalSince1970)
            .compactMap { try? decoder.decode(Sample.self, from: Data($0.utf8)) }
    }

    public func corrections(_ state: CorrectionState) -> [Correction] {
        rows("SELECT json FROM corrections WHERE state = ? ORDER BY time", state.rawValue)
            .compactMap { try? decoder.decode(Correction.self, from: Data($0.utf8)) }
    }

    public func latestModel() -> Model? {
        rows("SELECT json FROM models ORDER BY time DESC LIMIT 1")
            .first.flatMap { try? decoder.decode(Model.self, from: Data($0.utf8)) }
    }

    public func count(_ table: String) -> Int {
        Int(rows("SELECT COUNT(*) FROM \(table)").first ?? "0") ?? 0
    }

    // MARK: sqlite

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw Failure(description: msg)
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ args: [Any]) -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case let d as Double: sqlite3_bind_double(st, idx, d)
            case let s as String: sqlite3_bind_text(st, idx, s, -1, Self.transient)
            default: sqlite3_bind_null(st, idx)
            }
        }
        return st
    }

    private func run(_ sql: String, _ args: Any...) {
        queue.sync {
            guard let st = prepare(sql, args) else { return }
            sqlite3_step(st)
            sqlite3_finalize(st)
        }
    }

    private func rows(_ sql: String, _ args: Any...) -> [String] {
        queue.sync {
            guard let st = prepare(sql, args) else { return [] }
            defer { sqlite3_finalize(st) }
            var out: [String] = []
            while sqlite3_step(st) == SQLITE_ROW {
                if let c = sqlite3_column_text(st, 0) { out.append(String(cString: c)) }
                else { out.append(String(sqlite3_column_int64(st, 0))) }
            }
            return out
        }
    }
}
