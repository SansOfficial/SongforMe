import Foundation
import SQLite3

/// 所有数据都只存在本机的一个 SQLite 文件里
public actor Store {
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { "本地数据库出错：\(message)" }
    }

    private let database: Connection

    /// path 为 nil 时只存在内存里（测试用）
    public init(path: String? = nil) throws {
        database = try Connection(path: path ?? ":memory:")
        try database.exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS songs (
              mid TEXT PRIMARY KEY, id INTEGER, name TEXT, singers TEXT, albumMid TEXT, albumName TEXT,
              duration REAL, language INTEGER, genre INTEGER, publishTime TEXT, payPlay INTEGER, mediaMid TEXT
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS playlists (
              id TEXT PRIMARY KEY, title TEXT, kind TEXT, songCount INTEGER, cover TEXT, dirId INTEGER, syncedAt REAL
            );
            CREATE TABLE IF NOT EXISTS memberships (
              playlistId TEXT, mid TEXT, pos REAL, PRIMARY KEY (playlistId, mid)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS events (
              id INTEGER PRIMARY KEY, mid TEXT, type TEXT, ratio REAL, source TEXT, ts REAL
            );
            CREATE TABLE IF NOT EXISTS listens (ts REAL PRIMARY KEY, mid TEXT, seconds REAL, source TEXT);
            CREATE TABLE IF NOT EXISTS evidence (
              key TEXT PRIMARY KEY, mid TEXT, via TEXT, ref TEXT, seed TEXT, ts REAL
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID;
            """)
        // 早先的库里没有这一列
        let columns = try database.prepare("SELECT name FROM pragma_table_info('songs')").all { $0.text(0) }
        if !columns.contains("cover") { try database.exec("ALTER TABLE songs ADD COLUMN cover TEXT") }
    }

    // MARK: 歌曲

    private static let songColumns = "mid, id, name, singers, albumMid, albumName, duration, language, genre, publishTime, payPlay, mediaMid, cover"

    public func putSongs(_ songs: [Song], keepExisting: Bool = false) throws {
        try database.transaction {
            // 已经在库里的歌不覆盖时：曲库同步得到的信息更完整
            let verb = keepExisting ? "INSERT OR IGNORE" : "INSERT OR REPLACE"
            let st = try database.prepare("\(verb) INTO songs (\(Self.songColumns)) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)")
            for s in songs {
                let singers = s.singers.map { "\($0.mid)\t\($0.name)" }.joined(separator: "\n")
                try st.run(s.mid, s.songID, s.name, singers, s.albumMid, s.albumName, s.duration, s.language, s.genre, s.publishTime, s.payPlay, s.mediaMid, s.cover)
            }
        }
    }

    private static func song(_ r: Row) -> Song {
        let singers = r.text(3).split(separator: "\n").map { line -> Singer in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            return Singer(mid: String(parts[0]), name: parts.count > 1 ? String(parts[1]) : "")
        }
        return Song(
            mid: r.text(0), songID: r.int(1), name: r.text(2), singers: singers, albumMid: r.text(4), albumName: r.text(5),
            duration: r.double(6), language: r.int(7), genre: r.int(8), publishTime: r.text(9), payPlay: r.int(10), mediaMid: r.text(11),
            cover: r.isNull(12) ? nil : r.text(12)
        )
    }

    public func song(_ mid: String) throws -> Song? {
        try database.prepare("SELECT \(Self.songColumns) FROM songs WHERE mid = ?").all(mid, map: Self.song).first
    }

    public func allSongs() throws -> [Song] {
        try database.prepare("SELECT \(Self.songColumns) FROM songs ORDER BY mid").all(map: Self.song)
    }

    // MARK: 歌单

    private static func playlist(_ r: Row) -> Playlist? {
        guard let kind = PlaylistKind(rawValue: r.text(2)) else { return nil }
        return Playlist(
            id: r.text(0), title: r.text(1), kind: kind, songCount: r.int(3),
            cover: r.isNull(4) ? nil : r.text(4), dirId: r.isNull(5) ? nil : r.int(5), syncedAt: r.double(6)
        )
    }

    public func playlists() throws -> [Playlist] {
        try database.prepare("SELECT id, title, kind, songCount, cover, dirId, syncedAt FROM playlists ORDER BY rowid").all(map: Self.playlist).compactMap { $0 }
    }

    public func putPlaylist(_ p: Playlist) throws {
        // 已有的歌单原地更新，保持它在列表里的位置
        try database.prepare("""
            INSERT INTO playlists (id, title, kind, songCount, cover, dirId, syncedAt) VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, kind=excluded.kind, songCount=excluded.songCount,
              cover=excluded.cover, dirId=excluded.dirId, syncedAt=excluded.syncedAt
            """).run(p.id, p.title, p.kind.rawValue, p.songCount, p.cover, p.dirId, p.syncedAt)
    }

    public func removePlaylist(_ id: String) throws {
        try database.transaction {
            try database.prepare("DELETE FROM memberships WHERE playlistId = ?").run(id)
            try database.prepare("DELETE FROM playlists WHERE id = ?").run(id)
        }
    }

    /// 把一个歌单的歌曲整体替换成最新内容
    public func replacePlaylist(_ playlist: Playlist, songs: [Song]) throws {
        try database.transaction {
            try database.prepare("DELETE FROM memberships WHERE playlistId = ?").run(playlist.id)
            try putSongs(songs)
            let st = try database.prepare("INSERT OR REPLACE INTO memberships (playlistId, mid, pos) VALUES (?,?,?)")
            for (i, s) in songs.enumerated() { try st.run(playlist.id, s.mid, Double(i)) }
            var p = playlist
            p.songCount = songs.count
            p.syncedAt = nowMillis()
            try putPlaylist(p)
        }
    }

    public func playlistSongs(_ id: String) throws -> [Song] {
        let columns = Self.songColumns.split(separator: ", ").map { "s.\($0)" }.joined(separator: ", ")
        return try database.prepare("SELECT \(columns) FROM memberships m JOIN songs s ON s.mid = m.mid WHERE m.playlistId = ? ORDER BY m.pos").all(id, map: Self.song)
    }

    public func members(of id: String) throws -> [String] {
        try database.prepare("SELECT mid FROM memberships WHERE playlistId = ? ORDER BY pos").all(id) { $0.text(0) }
    }

    public func contains(_ mid: String, in id: String) throws -> Bool {
        try !database.prepare("SELECT 1 FROM memberships WHERE playlistId = ? AND mid = ?").all(id, mid) { _ in true }.isEmpty
    }

    /// 放到歌单的最前面
    public func addMember(_ song: Song, to id: String) throws {
        try database.transaction {
            try putSongs([song])
            try database.prepare("INSERT OR REPLACE INTO memberships (playlistId, mid, pos) VALUES (?,?,?)").run(id, song.mid, -nowMillis())
            try recount(id)
        }
    }

    public func removeMember(_ mid: String, from id: String) throws {
        try database.transaction {
            try database.prepare("DELETE FROM memberships WHERE playlistId = ? AND mid = ?").run(id, mid)
            try recount(id)
        }
    }

    private func recount(_ id: String) throws {
        try database.prepare("UPDATE playlists SET songCount = (SELECT COUNT(*) FROM memberships WHERE playlistId = ?1) WHERE id = ?1").run(id)
    }

    /// “我喜欢”、自建歌单、手动导入的种子歌单里的歌，都算作明确喜欢的歌
    public func likedMids() throws -> [String] {
        var seen: Set<String> = []
        return try database.prepare("""
            SELECT m.mid FROM memberships m JOIN playlists p ON p.id = m.playlistId
            WHERE p.kind IN ('liked', 'own', 'imported') ORDER BY p.rowid, m.pos
            """).all { $0.text(0) }.filter { seen.insert($0).inserted }
    }

    // MARK: 行为和证据

    public func addEvents(_ events: [PlayEvent]) throws {
        try database.transaction {
            let st = try database.prepare("INSERT INTO events (mid, type, ratio, source, ts) VALUES (?,?,?,?,?)")
            for e in events { try st.run(e.mid, e.type.rawValue, e.ratio, e.source.rawValue, e.ts) }
        }
    }

    public func events() throws -> [PlayEvent] {
        try database.prepare("SELECT mid, type, ratio, source, ts FROM events ORDER BY id").all { r -> PlayEvent? in
            guard let type = EventType(rawValue: r.text(1)), let source = PlaySource(rawValue: r.text(3)) else { return nil }
            return PlayEvent(mid: r.text(0), type: type, ratio: r.double(2), source: source, ts: r.double(4))
        }.compactMap { $0 }
    }

    /// 同一次播放会随着听的进度反复存，只会越来越长
    public func putListen(_ l: Listen) throws {
        try database.prepare("""
            INSERT INTO listens (ts, mid, seconds, source) VALUES (?,?,?,?)
            ON CONFLICT(ts) DO UPDATE SET seconds = MAX(seconds, excluded.seconds)
            """).run(l.ts, l.mid, l.seconds, l.source.rawValue)
    }

    public func listens() throws -> [Listen] {
        try database.prepare("SELECT mid, ts, seconds, source FROM listens ORDER BY ts").all { r in
            PlaySource(rawValue: r.text(3)).map { Listen(mid: r.text(0), ts: r.double(1), seconds: r.double(2), source: $0) }
        }.compactMap { $0 }
    }

    public func putEvidence(_ rows: [Evidence]) throws {
        try database.transaction {
            let st = try database.prepare("INSERT OR REPLACE INTO evidence (key, mid, via, ref, seed, ts) VALUES (?,?,?,?,?,?)")
            for e in rows { try st.run(e.key, e.mid, e.via.rawValue, e.ref, e.seed, e.ts) }
        }
    }

    public func evidence() throws -> [Evidence] {
        try database.prepare("SELECT mid, via, ref, seed, ts FROM evidence ORDER BY key").all { r -> Evidence? in
            guard let via = Evidence.Via(rawValue: r.text(1)) else { return nil }
            return Evidence(mid: r.text(0), via: via, ref: r.text(2), seed: r.text(3), ts: r.double(4))
        }.compactMap { $0 }
    }

    public func count(_ table: Table) throws -> Int {
        try database.prepare("SELECT COUNT(*) FROM \(table.rawValue)").all { $0.int(0) }.first ?? 0
    }

    public enum Table: String, Sendable {
        case songs, playlists, memberships, events, listens, evidence
    }

    // MARK: 零散的设置

    public func get<T: Decodable & Sendable>(_ key: String, as type: T.Type = T.self) throws -> T? {
        guard let text = try database.prepare("SELECT value FROM kv WHERE key = ?").all(key, map: { $0.text(0) }).first else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    public func set<T: Encodable & Sendable>(_ key: String, _ value: T) throws {
        try setRaw(key, json: String(decoding: JSONEncoder().encode(value), as: UTF8.self))
    }

    /// 以 prefix 开头的键（离线评估时找各个音源存的东西）
    func keys(prefix: String) throws -> [String] {
        try database.prepare("SELECT key FROM kv WHERE substr(key, 1, ?) = ? ORDER BY key").all(prefix.count, prefix, map: { $0.text(0) })
    }

    public func setRaw(_ key: String, json: String) throws {
        try database.prepare("INSERT OR REPLACE INTO kv (key, value) VALUES (?,?)").run(key, json)
    }

    public func remove(_ key: String) throws {
        try database.prepare("DELETE FROM kv WHERE key = ?").run(key)
    }
}

// MARK: - SQLite 的薄封装。只在 Store 这个 actor 里使用

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class Connection {
    private var handle: OpaquePointer?
    private var cache: [String: Statement] = [:]
    private var depth = 0

    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw Store.Failure(message: "打不开 \(path)")
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit {
        for st in cache.values { st.finalize() }
        sqlite3_close_v2(handle)
    }

    var error: Store.Failure { Store.Failure(message: String(cString: sqlite3_errmsg(handle))) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error }
    }

    func prepare(_ sql: String) throws -> Statement {
        if let st = cache[sql] { return st }
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &raw, nil) == SQLITE_OK, let raw else { throw error }
        let st = Statement(raw, self)
        cache[sql] = st
        return st
    }

    /// 可以嵌套，只有最外层真正开始和提交
    func transaction(_ body: () throws -> Void) throws {
        if depth == 0 { try exec("BEGIN IMMEDIATE") }
        depth += 1
        do {
            try body()
            depth -= 1
            if depth == 0 { try exec("COMMIT") }
        } catch {
            if depth > 0 { depth -= 1 }
            if depth == 0 { try? exec("ROLLBACK") }
            throw error
        }
    }
}

private final class Statement {
    private let raw: OpaquePointer
    private unowned let connection: Connection

    init(_ raw: OpaquePointer, _ connection: Connection) {
        self.raw = raw
        self.connection = connection
    }

    func finalize() { sqlite3_finalize(raw) }

    private func bind(_ args: [Any?]) {
        sqlite3_reset(raw)
        for (i, arg) in args.enumerated() {
            let n = Int32(i + 1)
            switch arg {
            case let v as String: sqlite3_bind_text(raw, n, v, -1, transient)
            case let v as Int: sqlite3_bind_int64(raw, n, Int64(v))
            case let v as Double: sqlite3_bind_double(raw, n, v)
            default: sqlite3_bind_null(raw, n)
            }
        }
    }

    func run(_ args: Any?...) throws {
        bind(args)
        defer { sqlite3_reset(raw) }
        guard sqlite3_step(raw) == SQLITE_DONE else { throw connection.error }
    }

    func all<T>(_ args: Any?..., map: (Row) -> T) throws -> [T] {
        bind(args)
        defer { sqlite3_reset(raw) }
        var out: [T] = []
        while true {
            switch sqlite3_step(raw) {
            case SQLITE_ROW: out.append(map(Row(raw: raw)))
            case SQLITE_DONE: return out
            default: throw connection.error
            }
        }
    }
}

private struct Row {
    let raw: OpaquePointer
    func text(_ i: Int32) -> String { sqlite3_column_text(raw, i).map { String(cString: $0) } ?? "" }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(raw, i)) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(raw, i) }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(raw, i) == SQLITE_NULL }
}
