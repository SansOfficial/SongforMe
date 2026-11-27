import AVFoundation
import CryptoKit
import Foundation
import Synchronization

// 本地音乐：用户选的文件夹里的 mp3、flac 等文件。不联网、没有账号，应用自己就带着。
// 每个文件夹是一个歌单；歌名、歌手、专辑和封面从文件里的标签读，读不到就看文件名。

public final class LocalSource: MusicSource {
    public static let id = "local"
    public let info = SourceInfo(id: LocalSource.id, name: "本地音乐")
    /// AVFoundation 能放的格式
    public static let extensions: Set<String> = ["mp3", "flac", "m4a", "aac", "alac", "wav", "aif", "aiff", "aifc", "caf"]
    static let pageSize = 50

    private struct State {
        var store: Store?
        var folders: [String] = []
        var songs: [Song] = []
    }

    /// 扫过的文件：改动时间没变就不用再读一遍标签
    private struct Cached: Codable, Sendable {
        var mtime: Double
        var song: Song
    }

    private let state = Mutex(State())
    /// 从文件里取出来的封面放在这里
    private let covers: URL

    public init(covers: URL) { self.covers = covers }

    public var folders: [String] { state.withLock { $0.folders } }
    public var songs: [Song] { state.withLock { $0.songs } }

    // MARK: 文件夹

    public func prepare(_ store: Store) async {
        let folders = (try? await store.get("localFolders", as: [String].self)) ?? []
        let cache = (try? await store.get("localScan", as: [String: Cached].self)) ?? [:]
        // 先用上次扫到的，打开就能看到；之后再在后台重新扫
        let songs = cache.filter { path, _ in folders.contains { Self.inside(path, $0) } }.values.map(\.song)
        state.withLock {
            $0.store = store
            $0.folders = folders
            $0.songs = songs.sorted { $0.mid < $1.mid }
        }
    }

    public func add(_ folder: URL) async {
        var path = folder.standardizedFileURL.path(percentEncoded: false)
        // 文件夹的路径末尾常带“/”，去掉，歌单编号才对得上
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let changed = state.withLock { s in
            // 已经在某个加过的文件夹里面的不重复加；加的是外层的，就换掉里面那些
            if s.folders.contains(where: { Self.inside(path, $0) }) { return false }
            s.folders = s.folders.filter { !Self.inside($0, path) } + [path]
            return true
        }
        if changed { await saveFolders() }
    }

    public func remove(_ path: String) async {
        state.withLock { s in
            s.folders.removeAll { $0 == path }
            s.songs.removeAll { song in !s.folders.contains { Self.inside(unwrapPath(song.mid), $0) } }
        }
        await saveFolders()
    }

    private func saveFolders() async {
        let (store, folders) = state.withLock { ($0.store, $0.folders) }
        try? await store?.set("localFolders", folders)
    }

    /// path 是 folder 本身或者在它里面
    static func inside(_ path: String, _ folder: String) -> Bool {
        let f = folder.hasSuffix("/") ? folder : folder + "/"
        return path == folder || path.hasPrefix(f)
    }

    private func unwrapPath(_ mid: String) -> String { info.unwrap(mid) }

    // MARK: 扫描

    /// 重新扫一遍所有文件夹，返回找到多少首
    @discardableResult
    public func scan() async -> Int {
        let (store, folders) = state.withLock { ($0.store, $0.folders) }
        let old = (try? await store?.get("localScan", as: [String: Cached].self)) ?? [:]
        var files: [(path: String, mtime: Double)] = []
        for folder in folders { files += Self.audioFiles(in: folder) }
        var fresh: [String: Cached] = [:]
        var todo: [(path: String, mtime: Double)] = []
        for f in files {
            if let hit = old[f.path], hit.mtime == f.mtime { fresh[f.path] = hit } else { todo.append(f) }
        }
        // 读标签要打开文件，几个一起读
        await withTaskGroup(of: (String, Cached).self) { group in
            var next = todo.makeIterator()
            func feed() {
                guard let f = next.next() else { return }
                group.addTask { [self] in (f.path, Cached(mtime: f.mtime, song: await read(f.path))) }
            }
            for _ in 0..<8 { feed() }
            for await (path, c) in group {
                fresh[path] = c
                feed()
            }
        }
        // 同一张专辑里有的文件没带封面，借用别的文件的
        var albumCover: [String: String] = [:]
        for c in fresh.values where !c.song.albumMid.isEmpty { if let cover = c.song.cover { albumCover[c.song.albumMid] = cover } }
        let songs = fresh.values.map { c in
            var song = c.song
            if song.cover == nil { song.cover = albumCover[song.albumMid] }
            return song
        }.sorted { $0.mid < $1.mid }
        state.withLock { $0.songs = songs }
        try? await store?.set("localScan", fresh)
        return songs.count
    }

    static func audioFiles(in folder: String) -> [(path: String, mtime: Double)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let walk = FileManager.default.enumerator(at: URL(filePath: folder, directoryHint: .isDirectory), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [(String, Double)] = []
        for case let url as URL in walk where extensions.contains(url.pathExtension.lowercased()) {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            out.append((url.standardizedFileURL.path(percentEncoded: false), v.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        return out
    }

    /// 读一首歌的标签；读不到的从文件名猜：“歌手 - 歌名”
    func read(_ path: String) async -> Song {
        let url = URL(filePath: path)
        let asset = AVURLAsset(url: url)
        var title = "", artist = "", album = "", albumArtist = ""
        var art: Data?
        var items = (try? await asset.load(.commonMetadata)) ?? []
        // flac 的标签有时只在格式自己的那份里
        for format in (try? await asset.load(.availableMetadataFormats)) ?? [] {
            items += (try? await asset.loadMetadata(for: format)) ?? []
        }
        for item in items {
            let key = (item.commonKey?.rawValue ?? (item.key as? String) ?? "").lowercased()
            let id = item.identifier?.rawValue.lowercased() ?? ""
            func text() async -> String { ((try? await item.load(.stringValue)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            switch key {
            case "title": if title.isEmpty { title = await text() }
            case "artist": if artist.isEmpty { artist = await text() }
            case "albumname", "album": if album.isEmpty { album = await text() }
            case "artwork": if art == nil { art = try? await item.load(.dataValue) }
            default:
                if id.hasSuffix("albumartist") || id.hasSuffix("/tpe2") || id.hasSuffix("/aart"), albumArtist.isEmpty { albumArtist = await text() }
            }
        }
        let guess = Self.guess(url.deletingPathExtension().lastPathComponent)
        if title.isEmpty { title = guess.title }
        if artist.isEmpty { artist = guess.artist }
        let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let names = Self.splitArtists(artist)
        let singers = names.map { Singer(mid: info.wrap("artist:\($0)"), name: $0) }
        let owner = albumArtist.isEmpty ? (names.first ?? "") : albumArtist
        return Song(
            mid: info.wrap(path),
            name: title,
            singers: singers.isEmpty ? [Singer(mid: "", name: "未知歌手")] : singers,
            albumMid: album.isEmpty ? "" : info.wrap("album:\(owner)/\(album)"),
            albumName: album,
            duration: seconds.isFinite ? seconds : 0,
            cover: saveCover(art) ?? Self.folderCover(url.deletingLastPathComponent())
        )
    }

    /// 去掉开头的音轨号，“歌手 - 歌名”拆开
    static func guess(_ name: String) -> (title: String, artist: String) {
        let bare = name.replacing(/^\d{1,3}\s*[.\-_ ]\s*/, with: "")
        let parts = bare.components(separatedBy: " - ")
        if parts.count >= 2 {
            return (parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces), parts[0].trimmingCharacters(in: .whitespaces))
        }
        return (bare.isEmpty ? name : bare, "")
    }

    static func splitArtists(_ text: String) -> [String] {
        text.split(whereSeparator: { "/、;；".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 同一张封面只存一份
    private func saveCover(_ data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        let name = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        let file = covers.appending(path: name)
        if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            try? FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
            try? data.write(to: file)
        }
        return file.absoluteString
    }

    /// 文件夹里的 cover.jpg、folder.jpg 之类
    static func folderCover(_ dir: URL) -> String? {
        let names = ["cover", "folder", "front", "album"]
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? []
        let hit = files.first { f in
            let u = URL(filePath: f)
            return names.contains(u.deletingPathExtension().lastPathComponent.lowercased()) && ["jpg", "jpeg", "png", "webp"].contains(u.pathExtension.lowercased())
        }
        return hit.map { dir.appending(path: $0).absoluteString }
    }

    // MARK: 歌单、歌手、专辑

    public func myPlaylists() async throws -> [Playlist] {
        await scan()
        let (folders, songs) = state.withLock { ($0.folders, $0.songs) }
        return folders.map { f in
            Playlist(id: info.wrap("dir:\(f)"), title: URL(filePath: f).lastPathComponent, kind: .own, songCount: songs.count { Self.inside(unwrapPath($0.mid), f) })
        }
    }

    public func playlist(_ id: String, max: Int) async throws -> (title: String, songs: [Song]) {
        let raw = info.unwrap(id)
        guard raw.hasPrefix("dir:") else { return ("", []) }
        let folder = String(raw.dropFirst(4))
        return (URL(filePath: folder).lastPathComponent, Array(songs.filter { Self.inside(unwrapPath($0.mid), folder) }.prefix(max)))
    }

    public func artistSongs(_ mid: String, begin: Int, count: Int) async throws -> (total: Int, songs: [Song]) {
        let all = songs.filter { $0.singers.contains { $0.mid == mid } }
        return (all.count, Array(all.dropFirst(begin).prefix(count)))
    }

    public func artistAlbums(_ mid: String) async throws -> [Album] { Self.albums(of: songs.filter { $0.singers.contains { $0.mid == mid } }) }

    public func albumSongs(_ mid: String) async throws -> [Song] { songs.filter { $0.albumMid == mid } }

    static func albums(of songs: [Song]) -> [Album] {
        var seen: Set<String> = []
        return songs.filter { !$0.albumMid.isEmpty && seen.insert($0.albumMid).inserted }.map {
            Album(mid: $0.albumMid, name: $0.albumName, singers: Array($0.singers.prefix(1)), cover: $0.cover)
        }
    }

    // MARK: 搜索

    public func search(_ query: String, _ kind: SearchKind, page: Int) async throws -> SearchPage {
        let q = query.trimmingCharacters(in: .whitespaces)
        func has(_ s: String) -> Bool { s.localizedStandardContains(q) }
        let all = songs
        var out = SearchPage()
        let from = (page - 1) * Self.pageSize
        switch kind {
        case .song:
            let hits = all.filter { has($0.name) || has($0.artistText) || has($0.albumName) }
            out.songs = Array(hits.dropFirst(from).prefix(Self.pageSize))
            out.total = hits.count
        case .singer:
            var count: [String: (name: String, songs: Int, albums: Set<String>)] = [:]
            for s in all {
                for a in s.singers where !a.mid.isEmpty && has(a.name) {
                    count[a.mid, default: (a.name, 0, [])].songs += 1
                    if !s.albumMid.isEmpty { count[a.mid]!.albums.insert(s.albumMid) }
                }
            }
            let hits = count.sorted { $0.value.songs > $1.value.songs }.map { SingerHit(mid: $0.key, name: $0.value.name, songCount: $0.value.songs, albumCount: $0.value.albums.count, pic: "") }
            out.singers = Array(hits.dropFirst(from).prefix(Self.pageSize))
            out.total = hits.count
        case .album:
            let hits = Self.albums(of: all).filter { has($0.name) || $0.singers.contains { has($0.name) } }
            out.albums = Array(hits.dropFirst(from).prefix(Self.pageSize))
            out.total = hits.count
        }
        out.hasMore = from + Self.pageSize < out.total
        return out
    }

    // MARK: 播放、歌词

    public func stream(_ song: Song) async throws -> StreamInfo? {
        let path = unwrapPath(song.mid)
        guard FileManager.default.fileExists(atPath: path) else {
            throw SourceError("找不到《\(song.name)》的文件，可能已经移动或删除了")
        }
        return StreamInfo(url: URL(filePath: path).absoluteString)
    }

    /// 同名的 .lrc 文件，或者文件里带的歌词
    public func lyrics(_ song: Song) async throws -> [LyricLine] {
        let url = URL(filePath: unwrapPath(song.mid))
        if let data = try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("lrc")), let text = Self.decode(data) {
            return Lyrics.parse(text)
        }
        let asset = AVURLAsset(url: url)
        var items: [AVMetadataItem] = []
        for format in (try? await asset.load(.availableMetadataFormats)) ?? [] {
            items += (try? await asset.loadMetadata(for: format)) ?? []
        }
        for item in items {
            let id = item.identifier?.rawValue.lowercased() ?? ""
            guard id.hasSuffix("lyrics") || id.hasSuffix("/uslt") || id.hasSuffix("/©lyr") else { continue }
            if let text = try? await item.load(.stringValue) {
                let lines = Lyrics.parse(text)
                if !lines.isEmpty { return lines }
            }
        }
        return []
    }

    /// 歌词文件常见的是 UTF-8，老的中文歌词常是 GBK
    static func decode(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: gb))
    }
}
