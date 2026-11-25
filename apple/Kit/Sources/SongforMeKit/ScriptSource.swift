import Foundation
import Synchronization

/// 用 JavaScript 写的音源，应用装好之后也能添加。写法见 README 的“接入音源”
public final class ScriptSource: MusicSource {
    /// 要用户填的一项，比如服务器地址、用户名、密码
    public struct Field: Decodable, Hashable, Sendable, Identifiable {
        public enum Kind: String, Decodable, Sendable { case text, secret, server }
        public var key: String
        public var title: String
        public var kind: Kind
        public var optional: Bool
        public var id: String { key }

        enum CodingKeys: String, CodingKey { case key, title, kind, optional }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? key
            kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
            optional = try c.decodeIfPresent(Bool.self, forKey: .optional) ?? false
        }
    }

    private struct Manifest: Decodable {
        var id: String
        var name: String
        var version: String?
        var hosts: [String]?
        var settings: [Field]?
        /// 认歌单链接的正则，第一个括号里是歌单的编号
        var playlistLink: String?
        var searchNeedsLogin: Bool?
        var methods: [String]
    }

    public let info: SourceInfo
    public let version: String
    public let hosts: [String]
    public let fields: [Field]
    public let searchNeedsLogin: Bool
    public let abilities: SourceAbilities
    public var hasAccount: Bool { !fields.isEmpty }

    private let methods: Set<String>
    private let playlistLink: String?
    private let runner: ScriptRunner
    private let values = Mutex<[String: String]>([:])
    /// 歌手头像，从接口返回的内容里顺手记下的
    private let avatars = Mutex<[String: String]>([:])

    public convenience init(script: String) async throws { try await self.init(script: script, patience: 45) }

    init(script: String, patience: Double) async throws {
        runner = ScriptRunner(patience: patience)
        let json = try await runner.load(script, within: min(patience, 5))
        let m: Manifest
        do { m = try JSONDecoder().decode(Manifest.self, from: Data(json.utf8)) } catch { throw SourceError("音源文件缺少 id、name，或者写法不对") }
        guard m.id.wholeMatch(of: /[a-z][a-z0-9]{1,19}/) != nil else { throw SourceError("音源的 id 只能用小写字母和数字，2 到 20 个，字母开头") }
        let name = m.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 30 else { throw SourceError("音源的名字要在 30 个字以内") }
        guard m.methods.contains("search"), m.methods.contains("stream") else { throw SourceError("音源至少要有 search 和 stream") }
        let hosts = (m.hosts ?? []).map { $0.lowercased() }
        if let bad = hosts.first(where: { !ScriptHosts.valid($0) }) { throw SourceError("hosts 里的“\(bad)”不是域名") }
        info = SourceInfo(id: m.id, name: name)
        version = m.version ?? ""
        self.hosts = hosts
        fields = m.settings ?? []
        searchNeedsLogin = m.searchNeedsLogin ?? false
        methods = Set(m.methods)
        playlistLink = m.playlistLink
        var can: SourceAbilities = []
        if methods.contains("setLiked") { can.insert(.like) }
        if methods.isSuperset(of: ["addToPlaylist", "createPlaylist", "deletePlaylist"]) { can.insert(.playlists) }
        abilities = can
        runner.hosts = ScriptHosts(declared: hosts)
    }

    // MARK: 设置

    public var settings: [String: String] { values.withLock { $0 } }

    /// 换一组设置。服务器地址不对时报错
    public func apply(_ new: [String: String]) throws {
        var clean: [String: String] = [:]
        var servers: Set<String> = []
        for f in fields {
            var v = new[f.key] ?? ""
            if f.kind != .secret { v = v.trimmingCharacters(in: .whitespacesAndNewlines) }
            if f.kind == .server, !v.isEmpty {
                if !v.contains("://") { v = "https://" + v }
                while v.hasSuffix("/") { v.removeLast() }
                guard let url = URL(string: v), let origin = ScriptHosts.origin(url) else { throw SourceError("“\(f.title)”不是有效的地址") }
                servers.insert(origin)
            }
            if !v.isEmpty { clean[f.key] = v }
        }
        values.withLock { $0 = clean }
        runner.hosts = ScriptHosts(declared: hosts, servers: servers)
        runner.set(settings: ScriptRunner.json(clean))
    }

    public func account() async -> SourceAccount {
        let v = settings
        let filled = !fields.isEmpty && fields.allSatisfy { $0.optional || v[$0.key] != nil }
        let shown = fields.first { $0.kind == .text }.flatMap { v[$0.key] }
        return SourceAccount(loggedIn: filled, uid: filled ? shown ?? "" : "")
    }

    @MainActor public func logout() async { try? apply([:]) }

    /// 有 profile 时顺便检查设置对不对
    public func profile() async throws -> AccountProfile {
        guard let d = try await call("profile") as? [String: Any] else { return AccountProfile(nick: "", avatar: "") }
        return AccountProfile(nick: text(d["name"]), avatar: link(d["avatar"]) ?? "")
    }

    // MARK: 找歌

    public func search(_ query: String, _ kind: SearchKind, page: Int) async throws -> SearchPage {
        let word = switch kind {
        case .song: "song"
        case .singer: "artist"
        case .album: "album"
        }
        let result = try await call("search", query, word, page)
        var out = SearchPage()
        let d = result as? [String: Any] ?? [:]
        func list(_ key: String) -> [Any] { d[key] as? [Any] ?? result as? [Any] ?? [] }
        switch kind {
        case .song: out.songs = songs(list("songs"))
        case .singer: out.singers = list("artists").compactMap(artist)
        case .album: out.albums = list("albums").compactMap(album)
        }
        out.total = int(d["total"])
        if out.total == 0 { out.total = out.songs.count + out.singers.count + out.albums.count }
        out.hasMore = d["hasMore"] as? Bool ?? false
        return out
    }

    public func artistSongs(_ mid: String, begin: Int, count: Int) async throws -> (total: Int, songs: [Song]) {
        let r = try await call("artistSongs", info.unwrap(mid), begin, count)
        let d = r as? [String: Any]
        let list = songs(d?["songs"] ?? r)
        return (max(int(d?["total"]), begin + list.count), list)
    }

    public func artistAlbums(_ mid: String) async throws -> [Album] { (try await call("artistAlbums", info.unwrap(mid)) as? [Any] ?? []).compactMap(album) }
    public func albumSongs(_ mid: String) async throws -> [Song] { songs(try await call("albumSongs", info.unwrap(mid))) }

    public func playlist(_ id: String, max: Int) async throws -> (title: String, songs: [Song]) {
        let r = try await call("playlist", info.unwrap(id), max)
        let d = r as? [String: Any]
        return (text(d?["title"]), Array(songs(d?["songs"] ?? r).prefix(max)))
    }

    public func playlistID(in text: String) -> String? {
        guard let playlistLink, let re = try? NSRegularExpression(pattern: playlistLink) else { return nil }
        let s = text as NSString
        guard s.length < 2000, let m = re.firstMatch(in: text, range: NSRange(location: 0, length: s.length)), m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
        return info.wrap(s.substring(with: m.range(at: 1)))
    }

    public func related(to song: Song) async throws -> (similar: [Song], playlists: [RelatedPlaylist]) {
        let r = try await call("related", json(song))
        let d = r as? [String: Any]
        let lists = (d?["playlists"] as? [Any] ?? []).compactMap { v -> RelatedPlaylist? in
            guard let p = v as? [String: Any], let id = wrapped(p["id"]) else { return nil }
            return RelatedPlaylist(id: id, songCount: int(p["songCount"]))
        }
        return (songs(d?["songs"] ?? r), lists)
    }

    // MARK: 听歌

    public func stream(_ song: Song) async throws -> StreamInfo? {
        let r = try await call("stream", json(song))
        let address = r as? String ?? text((r as? [String: Any])?["url"])
        if address.isEmpty { return nil }
        guard let url = URL(string: address), runner.hosts.allows(url) else { throw SourceError("音源没有声明要连接 \(URL(string: address)?.host() ?? "这个地址")") }
        return StreamInfo(url: address)
    }

    public func lyrics(_ song: Song) async throws -> [LyricLine] {
        let r = try await call("lyrics", json(song))
        if let s = r as? String { return Lyrics.parse(s) }
        let d = r as? [String: Any]
        return Lyrics.parse(text(d?["lrc"]), trans: text(d?["trans"]))
    }

    public func avatar(of artist: String, size: Int) -> URL? { avatars.withLock { $0[artist] }.flatMap(URL.init(string:)) }

    // MARK: 账号里的东西

    public func myPlaylists() async throws -> [Playlist] { (try await call("myPlaylists") as? [Any] ?? []).compactMap { list($0, .own) } }
    public func collectedPlaylists() async throws -> [Playlist] { (try await call("collectedPlaylists") as? [Any] ?? []).compactMap { list($0, .collected) } }

    public func likedSongs(_ list: Playlist?) async throws -> [Song] {
        if methods.contains("likedSongs") { return songs(try await call("likedSongs")) }
        guard let list else { return [] }
        return try await playlist(list.id, max: Library.maxPlaylistSongs).songs
    }

    public func recentPlays() async throws -> [RecentPlay] {
        (try await call("recentPlays") as? [Any] ?? []).compactMap { v in
            guard let d = v as? [String: Any], let s = song(d["song"] ?? d) else { return nil }
            return RecentPlay(song: s, lastTime: number(d["time"]), listenCount: max(int(d["count"]), 1))
        }
    }

    @MainActor public func perform(_ action: AccountAction) async throws {
        switch action {
        case .setLiked(let song, let liked): _ = try await runner.call("setLiked", encode([json(song), liked]))
        case .addToPlaylist(let song, let playlist): _ = try await runner.call("addToPlaylist", encode([json(song), info.unwrap(playlist.id)]))
        case .createPlaylist(let name, let song): _ = try await runner.call("createPlaylist", encode([name, song.map(json) as Any? ?? NSNull()]))
        case .deletePlaylist(let playlist): _ = try await runner.call("deletePlaylist", encode([info.unwrap(playlist.id)]))
        }
    }

    // MARK: 和脚本来回传的数据

    /// 脚本没写这个方法时返回 nil
    private func call(_ method: String, _ arguments: Any...) async throws -> Any? {
        guard methods.contains(method) else { return nil }
        return try await run(method, encode(arguments))
    }

    private func encode(_ arguments: [Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self) }

    private func run(_ method: String, _ arguments: String) async throws -> Any? {
        guard methods.contains(method) else { throw SourceError("\(info.name)不支持这个操作") }
        let out = try await runner.call(method, arguments)
        let value = try JSONSerialization.jsonObject(with: Data(out.utf8), options: .fragmentsAllowed)
        return value is NSNull ? nil : value
    }

    private func text(_ v: Any?) -> String { v as? String ?? (v as? NSNumber)?.stringValue ?? "" }
    private func number(_ v: Any?) -> Double {
        let n = (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) ?? 0
        return n.isFinite ? n : 0
    }
    private func int(_ v: Any?) -> Int { Int(min(max(number(v), -1e15), 1e15)) }

    /// 图片地址，只要允许连接的主机上的
    private func link(_ v: Any?) -> String? {
        let s = text(v)
        guard !s.isEmpty, let url = URL(string: s), runner.hosts.allows(url) else { return nil }
        return s
    }

    private func wrapped(_ v: Any?) -> String? {
        let s = text(v)
        return s.isEmpty ? nil : info.wrap(s)
    }

    /// 歌手写成名字，或者 { id, name, avatar }
    private func singer(_ v: Any) -> Singer? {
        if let name = v as? String { return name.isEmpty ? nil : Singer(mid: "", name: name) }
        guard let d = v as? [String: Any], !text(d["name"]).isEmpty else { return nil }
        let mid = wrapped(d["id"]) ?? ""
        remember(mid, link(d["avatar"]))
        return Singer(mid: mid, name: text(d["name"]))
    }

    private func remember(_ mid: String, _ avatar: String?) {
        guard !mid.isEmpty, let avatar else { return }
        avatars.withLock { $0[mid] = avatar }
    }

    private func singers(_ v: Any?) -> [Singer] {
        if let list = v as? [Any] { return list.compactMap(singer) }
        return v.flatMap(singer).map { [$0] } ?? []
    }

    private func songs(_ v: Any?) -> [Song] { (v as? [Any] ?? []).compactMap(song) }

    private func song(_ v: Any) -> Song? {
        guard let d = v as? [String: Any], let mid = wrapped(d["id"]), !text(d["name"]).isEmpty else { return nil }
        let album = d["album"] as? [String: Any]
        return Song(
            mid: mid, name: text(d["name"]), singers: singers(d["artists"] ?? d["artist"]),
            albumMid: wrapped(album?["id"]) ?? "", albumName: album.map { text($0["name"]) } ?? text(d["album"]),
            duration: number(d["duration"]), language: Languages.all.first { $0.name == text(d["language"]) }?.code ?? Self.unknown,
            publishTime: text(d["date"]), payPlay: d["vip"] as? Bool == true ? 1 : 0, mediaMid: text(d["extra"]), cover: link(d["cover"])
        )
    }

    /// 语种没写时算“其他”
    private static let unknown = Languages.all.first { $0.name == "其他" }?.code ?? 0

    private func json(_ s: Song) -> [String: Any] {
        [
            "id": info.unwrap(s.mid), "name": s.name,
            "artists": s.singers.map { ["id": $0.mid.isEmpty ? "" : info.unwrap($0.mid), "name": $0.name] },
            "album": ["id": s.albumMid.isEmpty ? "" : info.unwrap(s.albumMid), "name": s.albumName],
            "duration": s.duration, "date": s.publishTime, "extra": s.mediaMid, "cover": s.cover ?? "",
        ]
    }

    private func artist(_ v: Any) -> SingerHit? {
        guard let d = v as? [String: Any], let mid = wrapped(d["id"]), !text(d["name"]).isEmpty else { return nil }
        let pic = link(d["avatar"])
        remember(mid, pic)
        return SingerHit(mid: mid, name: text(d["name"]), songCount: int(d["songCount"]), albumCount: int(d["albumCount"]), pic: pic ?? "")
    }

    private func album(_ v: Any) -> Album? {
        guard let d = v as? [String: Any], let mid = wrapped(d["id"]), !text(d["name"]).isEmpty else { return nil }
        return Album(mid: mid, name: text(d["name"]), date: text(d["date"]), type: text(d["type"]), singers: singers(d["artists"] ?? d["artist"]), cover: link(d["cover"]))
    }

    private func list(_ v: Any, _ kind: PlaylistKind) -> Playlist? {
        guard let d = v as? [String: Any], let id = wrapped(d["id"]) else { return nil }
        let liked = kind == .own && d["liked"] as? Bool == true
        return Playlist(id: id, title: text(d["title"]), kind: liked ? .liked : kind, songCount: int(d["songCount"]), cover: link(d["cover"]))
    }
}

/// 添加过的音源文件放在哪里：<文件夹>/<id>.js，用户填的设置在 <id>.json（只有本人能读）
public struct ScriptShelf: Sendable {
    public let folder: URL
    public init(folder: URL) { self.folder = folder }

    private func script(_ id: String) -> URL { folder.appending(path: "\(id).js") }
    private func settings(_ id: String) -> URL { folder.appending(path: "\(id).json") }

    /// 载入全部。坏了的跳过，连同原因一起返回
    public func load() async -> (sources: [ScriptSource], failed: [String]) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var out: [ScriptSource] = []
        var failed: [String] = []
        for file in files.filter({ $0.pathExtension == "js" }).sorted(by: { $0.path < $1.path }) {
            do {
                let source = try await ScriptSource(script: String(contentsOf: file, encoding: .utf8))
                restore(source)
                out.append(source)
            } catch {
                failed.append("\(file.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return (out, failed)
    }

    /// 套上以前填过的设置
    public func restore(_ source: ScriptSource) {
        guard let data = try? Data(contentsOf: settings(source.info.id)), let saved = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        try? source.apply(saved)
    }

    public func add(_ source: ScriptSource, script text: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(text.utf8).write(to: script(source.info.id), options: .atomic)
    }

    public func remove(_ id: String) {
        try? FileManager.default.removeItem(at: script(id))
        try? FileManager.default.removeItem(at: settings(id))
    }

    /// 保存设置；空的就删掉
    public func save(_ source: ScriptSource) throws {
        let file = settings(source.info.id)
        let values = source.settings
        if values.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        // 先建一个只有本人能读的空文件，再写内容
        let data = try JSONEncoder().encode(values)
        FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
    }
}
