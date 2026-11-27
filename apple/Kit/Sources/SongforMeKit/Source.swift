import Foundation
import Synchronization

// 音源：歌从哪里来。应用自带的只有本地音乐（见 LocalSource），在线的可以在应用里添加插件（见 ScriptSource），
// 也可以编译时把音源的代码放进 local/sources（写法见 README 的“用 Swift 写”）。

public struct SourceInfo: Hashable, Sendable {
    /// 音源的短名字，歌曲、歌手、专辑、歌单的编号都以“短名字:”开头
    public var id: String
    /// 显示给用户看的名字
    public var name: String
    /// 编号里不带前缀的数据归它（每个应用最多一个，给加前缀之前就有的数据用）
    public var bare: Bool

    public init(id: String, name: String, bare: Bool = false) {
        self.id = id
        self.name = name
        self.bare = bare
    }

    /// 夹在中文里的写法：英文开头的前面空一格
    public var spaced: String { name.first?.isASCII == true ? " \(name)" : name }

    private var prefix: String { bare ? "" : "\(id):" }
    public var likedID: String { prefix + Playlist.likedID }
    public var recentID: String { prefix + Playlist.recentID }
    /// 给这个音源的编号加上前缀
    public func wrap(_ raw: String) -> String { prefix + raw }
    /// 去掉前缀，得到音源自己的编号
    public func unwrap(_ id: String) -> String { id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id }
    /// 存在 kv 里、按音源分开的设置
    func key(_ name: String) -> String { bare ? name : "\(name):\(id)" }
}

public struct SourceAccount: Hashable, Sendable {
    public var loggedIn: Bool
    /// 账号在音源那边的编号
    public var uid: String
    public init(loggedIn: Bool = false, uid: String = "") {
        self.loggedIn = loggedIn
        self.uid = uid
    }
}

/// 音源能替用户在账号里做的事
public struct SourceAbilities: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// 把“喜欢”写回账号
    public static let like = SourceAbilities(rawValue: 1)
    /// 新建、删除歌单，把歌加入歌单
    public static let playlists = SourceAbilities(rawValue: 2)
}

public enum AccountAction: Sendable {
    case setLiked(Song, Bool)
    case addToPlaylist(Song, Playlist)
    /// 新建歌单；带歌时同时把这首歌放进去
    case createPlaylist(name: String, song: Song?)
    case deletePlaylist(Playlist)
}

/// 音源报的错。needsLogin 表示需要登录，或者登录已经过期
public protocol SourceFailure: LocalizedError {
    var needsLogin: Bool { get }
}

public struct SourceError: SourceFailure {
    public let message: String
    public let needsLogin: Bool
    public var errorDescription: String? { message }
    public init(_ message: String, needsLogin: Bool = false) {
        self.message = message
        self.needsLogin = needsLogin
    }
}

/// 一个音源。除了 info、搜索和播放地址，其余都有默认实现，用不到的可以不写
public protocol MusicSource: Sendable {
    var info: SourceInfo { get }
    /// 有账号可以登录。没有的不显示登录入口，歌随时都能放
    var hasAccount: Bool { get }
    var abilities: SourceAbilities { get }
    /// 没登录时搜不到东西
    var searchNeedsLogin: Bool { get }
    /// 启动时调用一次，可以在这里读写自己的设置
    func prepare(_ store: Store) async

    // 找歌。search 的 page 从 1 开始
    func search(_ query: String, _ kind: SearchKind, page: Int) async throws -> SearchPage
    func artistSongs(_ mid: String, begin: Int, count: Int) async throws -> (total: Int, songs: [Song])
    func artistAlbums(_ mid: String) async throws -> [Album]
    func albumSongs(_ mid: String) async throws -> [Song]
    /// 歌单里的歌，最多取 max 首
    func playlist(_ id: String, max: Int) async throws -> (title: String, songs: [Song])
    /// 从用户粘贴的文字里认出自己的歌单，返回歌单的编号；认不出来返回 nil
    func playlistID(in text: String) -> String?
    /// 相似的歌和收录了这首歌的歌单，是推荐候选的来源
    func related(to song: Song) async throws -> (similar: [Song], playlists: [RelatedPlaylist])

    // 听歌
    /// 播放地址。账号没有权限播放的返回 nil，播放器会跳过
    func stream(_ song: Song) async throws -> StreamInfo?
    /// 没有歌词时返回空数组
    func lyrics(_ song: Song) async throws -> [LyricLine]

    // 图片
    func cover(of song: Song, size: Int) -> URL?
    func cover(of album: Album, size: Int) -> URL?
    func avatar(of artist: String, size: Int) -> URL?

    // 账号
    func account() async -> SourceAccount
    @MainActor func login() async
    @MainActor func logout() async
    func profile() async throws -> AccountProfile
    /// 账号里自建的歌单，“我喜欢”的 kind 是 liked
    func myPlaylists() async throws -> [Playlist]
    func likedSongs(_ list: Playlist?) async throws -> [Song]
    func collectedPlaylists() async throws -> [Playlist]
    func recentPlays() async throws -> [RecentPlay]
    @MainActor func perform(_ action: AccountAction) async throws
}

extension MusicSource {
    public var hasAccount: Bool { false }
    public var abilities: SourceAbilities { [] }
    public var searchNeedsLogin: Bool { false }
    public func prepare(_ store: Store) async {}
    public func artistSongs(_ mid: String, begin: Int, count: Int) async throws -> (total: Int, songs: [Song]) { (0, []) }
    public func artistAlbums(_ mid: String) async throws -> [Album] { [] }
    public func albumSongs(_ mid: String) async throws -> [Song] { [] }
    public func playlist(_ id: String, max: Int) async throws -> (title: String, songs: [Song]) { ("", []) }
    public func playlistID(in text: String) -> String? { nil }
    public func related(to song: Song) async throws -> (similar: [Song], playlists: [RelatedPlaylist]) { ([], []) }
    public func lyrics(_ song: Song) async throws -> [LyricLine] { [] }
    public func cover(of song: Song, size: Int) -> URL? { song.cover.flatMap(URL.init(string:)) }
    public func cover(of album: Album, size: Int) -> URL? { album.cover.flatMap(URL.init(string:)) }
    public func avatar(of artist: String, size: Int) -> URL? { nil }
    public func account() async -> SourceAccount { SourceAccount() }
    @MainActor public func login() async {}
    @MainActor public func logout() async {}
    public func profile() async throws -> AccountProfile { AccountProfile(nick: "", avatar: "") }
    public func myPlaylists() async throws -> [Playlist] { [] }
    public func likedSongs(_ list: Playlist?) async throws -> [Song] { [] }
    public func collectedPlaylists() async throws -> [Playlist] { [] }
    public func recentPlays() async throws -> [RecentPlay] { [] }
    @MainActor public func perform(_ action: AccountAction) async throws { throw SourceError("\(info.name)不支持这个操作") }
}

/// 装了哪些音源。添加、移除之后，拿着它的地方马上就能看到
public final class SourceHub: Sendable {
    private let list: Mutex<[any MusicSource]>

    public init(_ all: [any MusicSource] = []) { list = Mutex(all) }

    public var all: [any MusicSource] { list.withLock { $0 } }

    /// 已经有同一个短名字的就换掉
    public func add(_ source: any MusicSource) {
        list.withLock { all in
            if let i = all.firstIndex(where: { $0.info.id == source.info.id }) { all[i] = source } else { all.append(source) }
        }
    }

    public func remove(_ id: String) { list.withLock { $0.removeAll { $0.info.id == id } } }

    /// 一个编号（歌、歌手、专辑、歌单都可以）属于哪个音源；那个音源没有装时为 nil
    public func owner(of id: String) -> (any MusicSource)? {
        if let colon = id.firstIndex(of: ":") {
            return all.first { !$0.info.bare && $0.info.id == id[..<colon] }
        }
        return all.first { $0.info.bare }
    }

    public func owner(of song: Song) -> (any MusicSource)? { owner(of: song.mid) }

    public func named(_ id: String) -> (any MusicSource)? { all.first { $0.info.id == id } }

    private static let installed = Mutex(SourceHub())

    /// 应用启动时设一次，图片地址从这里问
    public static var current: SourceHub {
        get { installed.withLock { $0 } }
        set { installed.withLock { $0 = newValue } }
    }
}

public enum Artwork {
    public static func artist(_ mid: String, _ size: Int = 300) -> URL? { mid.isEmpty ? nil : SourceHub.current.owner(of: mid)?.avatar(of: mid, size: size) }
}

extension Song {
    /// 封面，size 是大致的边长
    public func artwork(_ size: Int = 300) -> URL? { SourceHub.current.owner(of: self)?.cover(of: self, size: size) ?? cover.flatMap(URL.init(string:)) }
}

extension Album {
    public func artwork(_ size: Int = 300) -> URL? { SourceHub.current.owner(of: mid)?.cover(of: self, size: size) ?? cover.flatMap(URL.init(string:)) }
}

// MARK: - 音源返回的东西

public struct AccountProfile: Codable, Hashable, Sendable {
    public var nick: String
    public var avatar: String
    public init(nick: String, avatar: String) {
        self.nick = nick
        self.avatar = avatar
    }
}

public struct RelatedPlaylist: Sendable {
    public var id: String
    public var songCount: Int
    public init(id: String, songCount: Int) {
        self.id = id
        self.songCount = songCount
    }
}

public struct Album: Hashable, Sendable, Identifiable {
    public var mid: String
    public var name: String
    /// 发行日期 YYYY-MM-DD
    public var date: String
    /// 录音室专辑 / EP / Single 等
    public var type: String
    public var singers: [Singer]
    public var cover: String?
    public var id: String { mid }

    public init(mid: String, name: String, date: String = "", type: String = "", singers: [Singer] = [], cover: String? = nil) {
        self.mid = mid
        self.name = name
        self.date = date
        self.type = type
        self.singers = singers
        self.cover = cover
    }
}

public struct SingerHit: Hashable, Sendable, Identifiable {
    public var mid: String
    public var name: String
    public var songCount: Int
    public var albumCount: Int
    public var pic: String
    public var id: String { mid }

    public init(mid: String, name: String, songCount: Int, albumCount: Int, pic: String) {
        self.mid = mid
        self.name = name
        self.songCount = songCount
        self.albumCount = albumCount
        self.pic = pic
    }
}

public struct StreamInfo: Hashable, Sendable {
    public var url: String
    public init(url: String) { self.url = url }
}

/// 账号里记录的最近播放
public struct RecentPlay: Sendable {
    public var song: Song
    /// 最后一次听的时间，毫秒；不知道时为 0
    public var lastTime: Double
    /// 累计听了多少次
    public var listenCount: Int

    public init(song: Song, lastTime: Double, listenCount: Int) {
        self.song = song
        self.lastTime = lastTime
        self.listenCount = listenCount
    }
}

// MARK: - 搜索

public enum SearchKind: String, CaseIterable, Sendable {
    case song, singer, album
}

/// 一页搜索结果：只有所搜的那一类有内容，其余为空数组
public struct SearchPage: Sendable {
    public var songs: [Song] = []
    public var singers: [SingerHit] = []
    public var albums: [Album] = []
    /// 音源给出的结果总数
    public var total = 0
    public var hasMore = false

    public init() {}
}

/// 已经加载的搜索结果（可能是好几页拼起来的）
public struct SearchResults: Sendable {
    public var songs: [Song] = []
    public var singers: [SingerHit] = []
    public var albums: [Album] = []
    public var total = 0
    /// 已经加载到第几页
    public var page = 0
    public var hasMore = false

    public init() {}

    /// 把新的一页接到后面，去掉重复的。
    /// 翻页时服务端偶尔会返回和前面重复的条目：这一页一条新的都没有就当作到头了，避免“加载更多”一直出现。
    public func merging(_ next: SearchPage, page number: Int) -> SearchResults {
        var out = number == 1 ? SearchResults() : self
        let before = out.loaded
        func merge<T: Identifiable>(_ old: [T], _ fresh: [T]) -> [T] {
            var seen = Set(old.map(\.id))
            return old + fresh.filter { seen.insert($0.id).inserted }
        }
        out.songs = merge(out.songs, next.songs)
        out.singers = merge(out.singers, next.singers)
        out.albums = merge(out.albums, next.albums)
        out.hasMore = next.hasMore && (number == 1 || out.loaded > before)
        // 到头了就以实际加载到的数量为准（服务端报的总数常常偏大）
        out.total = out.hasMore ? max(next.total, out.loaded) : out.loaded
        out.page = number
        return out
    }

    public var loaded: Int { songs.count + singers.count + albums.count }
}

