import AppKit
import Observation
import SwiftUI
import SongforMeKit

struct ArtistRef: Hashable {
    var mid: String
    var name: String
}

/// 主区域显示的页面
/// 设置页的三栏
enum PlayMode: CaseIterable {
    case loop, one, shuffle, smart, order
    var title: String {
        switch self {
        case .loop: "列表循环"
        case .one: "单曲循环"
        case .shuffle: "随机播放"
        case .smart: "智能随机"
        case .order: "顺序播放"
        }
    }
    var icon: String {
        switch self {
        case .loop: "repeat"
        case .one: "repeat.1"
        case .shuffle, .smart: "shuffle"
        case .order: "arrow.right"
        }
    }
}

enum SettingsTab: String, CaseIterable, Hashable {
    case general, reco, sources

    var title: String {
        switch self {
        case .general: "通用"
        case .reco: "推荐"
        case .sources: "音源与账号"
        }
    }
}

enum Page: Hashable {
    case reco
    case settings(SettingsTab)
    case playlist(String)
    case artist(ArtistRef, ArtistTab)
    case album(Album, ArtistRef?)
    /// 最后一个是在哪个音源里搜
    case search(String, SearchKind, String)
    case report(ReportPeriod, Date)

    enum ArtistTab: Hashable { case songs, albums }

    /// 是不是同一个页面：歌手页换标签、搜索页换分类都算同一页，不在“返回”里多占一步
    var identity: String {
        switch self {
        case .reco: "reco"
        case .settings: "settings"
        case .playlist(let id): "playlist:\(id)"
        case .artist(let a, _): "artist:\(a.mid)"
        case .album(let a, _): "album:\(a.mid)"
        case .search(let q, _, _): "search:\(q)"
        case .report: "report"
        }
    }
}

/// 当前页面从曲库或网络读来的内容
struct Content {
    var songs: [Song] = []
    /// 服务端的总数（歌手页分页用），0 表示已全部加载
    var total = 0
    var albums: [Album] = []
    var results = SearchResults()
    var loading = false
    /// 没加载出来时的原因；有值时页面显示“重试”而不是“没有结果”
    var error: String?
}

struct SidebarGroup: Identifiable {
    var id: String
    var name: String
    var playlists: [Playlist]
    var canCreate: Bool
}

struct Toast: Equatable {
    let id = UUID()
    var text: String
    var isError: Bool
}

/// 界面只读这里的状态、只调这里的动作
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var ready = false
    /// 每个音源的登录状态
    private(set) var accounts: [String: SourceAccount] = [:]
    /// 每个音源里的昵称和头像；没登录、还没取到的没有
    private(set) var profiles: [String: AccountProfile] = [:]
    /// 上次在哪个音源里搜的
    private(set) var searchSource = ""

    private(set) var page = Page.reco
    private(set) var history: [Page] = []
    private(set) var content = Content()
    private(set) var report: Report?
    var query = ""

    private(set) var playlists: [Playlist] = []
    private(set) var batch: [Recommendation] = []
    private(set) var settings = RecoSettings()
    /// 算法当作“喜欢”的歌：我喜欢 + 自建歌单 + 导入的种子歌单
    private(set) var likedMids: Set<String> = []
    /// 严格在“我喜欢”里的歌，决定爱心是否点亮
    private(set) var hearts: Set<String> = []
    /// 喜欢和歌单操作是否同步到音源账号
    private(set) var syncLikes = true
    /// 还在排队写回账号的操作数
    private(set) var syncing = 0

    private(set) var busy: String?
    private(set) var toast: Toast?

    let player: Player
    let lyrics: LyricsModel
    /// 有哪些音源。界面从这里读，增减之后会跟着刷新
    var hub: SourceHub {
        _ = sourceChanges
        return sources
    }
    private var sourceChanges = 0
    /// 正在填账号的音源，有值时弹出填写的窗口
    var settingUp: SourceSetup?
    /// 正在添加插件
    var adding = false

    @ObservationIgnored private let sources: SourceHub
    /// 添加过的插件
    @ObservationIgnored let shelf = ScriptShelf(folder: AppModel.folder.appending(path: "sources", directoryHint: .isDirectory))
    @ObservationIgnored private let store: Store
    @ObservationIgnored private let library: Library
    @ObservationIgnored private let nowPlaying: NowPlaying
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// 页面每换一次加一，晚到的加载结果据此丢掉
    @ObservationIgnored private var visit = 0
    /// 用户主动打开智能随机时提示一次穿插了几首；之后每一轮自动补推荐就不再打扰
    @ObservationIgnored private var announceSmart = false
    /// 在报告里翻页时用同一份数据，离开报告就丢掉
    @ObservationIgnored private var reportInput: ReportInput?
    /// 这一批推荐的随机种子：跟着反馈重排时没受影响的歌名次不乱跳
    @ObservationIgnored private var batchSeed = UInt64.random(in: 1...UInt64.max)
    @ObservationIgnored private var reshapeTask: Task<Void, Never>?

    private static let artistPage = 60

    private init() {
        let hub = SourcePack.installed()
        SourceHub.current = hub
        let store = Self.openStore()
        sources = hub
        self.store = store
        library = Library(hub: hub, store: store)
        player = Player(
            audio: AudioEngine(),
            resolve: { song in
                guard let source = hub.owner(of: song) else { throw SourceError("没有能播放这首歌的音源") }
                if let stream = try await source.stream(song) { return stream }
                // 没登录时拿不到地址不代表这首歌放不了，别标成不可播放
                if !source.hasAccount { return nil }
                if await source.account().loggedIn { return nil }
                throw SourceError("登录\(source.info.spaced)后才能播放", needsLogin: true)
            },
            log: { event in
                Task {
                    try? await store.addEvents([event])
                    AppModel.shared.heard(event)
                }
            }
        )
        lyrics = LyricsModel(hub: hub, player: player)
        nowPlaying = NowPlaying(player: player)
        player.onChange = { [unowned self] in
            nowPlaying.update()
            lyrics.follow()
        }
        player.onReshuffle = { [unowned self] in Task { await self.fillSmart() } }
        player.onListen = { song, listen in
            Task {
                // 搜索、歌手页里点的歌可能还没存过，报告里要用到歌名和封面
                try? await store.putSongs([song], keepExisting: true)
                try? await store.putListen(listen)
            }
        }
        player.onPrefs = { prefs in Task { try? await store.set("playback", prefs) } }
    }

    static var folder: URL {
        #if DEBUG
        // 调试时用另一份数据，不碰真正的听歌记录
        if let path = ProcessInfo.processInfo.environment["SONGFORME_FOLDER"] { return URL(filePath: path, directoryHint: .isDirectory) }
        #endif
        let url = URL.applicationSupportDirectory.appending(path: "SongforMe", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func openStore() -> Store {
        do {
            return try Store(path: folder.appending(path: "library.sqlite").path(percentEncoded: false))
        } catch {
            let alert = NSAlert()
            alert.messageText = "打不开本地曲库"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            exit(1)
        }
    }

    // MARK: 启动

    func start() async {
        // 从旧版搬家：SongforMe --import 导出的文件
        if let i = CommandLine.arguments.firstIndex(of: "--import"), CommandLine.arguments.indices.contains(i + 1) {
            do {
                try await OldLibrary.load(Data(contentsOf: URL(filePath: CommandLine.arguments[i + 1])), into: store)
            } catch {
                say("旧曲库没有导入：\(error.localizedDescription)", error: true)
            }
        }
        settings = await library.loadSettings()
        syncLikes = await read("syncLikes") ?? true
        player.restore(await read("playback") ?? PlaybackPrefs())
        if let saved: SavedBatch = await read("lastBatch") {
            batch = saved.items
            if let seed = saved.seed { batchSeed = seed }
        }
        searchSource = await read("searchSource") ?? ""
        let found = await shelf.load()
        for s in found.sources where sources.named(s.info.id) == nil {
            attach(s)
            sources.add(s)
        }
        sourceChanges += 1
        dropOrphans()
        for source in hub.all { await source.prepare(store) }
        await refreshLibrary()
        await refreshAccounts()
        ready = true
        Updater.shared.start()
        if let bad = found.failed.first { say("有插件没有载入，\(bad)", error: true) }
    }

    private nonisolated struct SavedBatch: Codable {
        var items: [Recommendation]
        var seed: UInt64?
    }
    private nonisolated struct SavedAccount: Codable {
        var uin: String
        var profile: AccountProfile
    }

    private func read<T: Decodable & Sendable>(_ key: String) async -> T? { try? await store.get(key, as: T.self) }
    private func write<T: Encodable & Sendable>(_ key: String, _ value: T) async { try? await store.set(key, value) }

    func refreshLibrary() async {
        func order(_ k: PlaylistKind) -> Int {
            switch k {
            case .liked: 0
            case .recent: 1
            case .own: 2
            case .imported: 3
            case .collected: 4
            }
        }
        let all = (try? await store.playlists()) ?? []
        playlists = all.enumerated().sorted { (order($0.element.kind), $0.offset) < (order($1.element.kind), $1.offset) }.map(\.element)
        likedMids = Set((try? await store.likedMids()) ?? [])
        hearts = (try? await library.hearts()) ?? []
    }

    // MARK: 提示

    func say(_ text: String, error: Bool = false) {
        toastTask?.cancel()
        toast = Toast(text: text, isError: error)
        toastTask = Task {
            try? await Task.sleep(for: .seconds(error ? 6 : 3))
            if !Task.isCancelled { toast = nil }
        }
    }

    private func describe(_ error: Error) -> String {
        if let e = error as? URLError { return e.code == .notConnectedToInternet ? "没有连上网络" : "网络请求失败，请检查网络后重试" }
        return error.localizedDescription
    }

    /// 包一层：显示进度、统一处理报错和登录过期
    private func whileBusy<T>(_ label: String, _ task: (_ progress: @escaping Library.Progress) async throws -> T) async -> T? {
        if busy != nil { return nil }
        busy = label
        defer { busy = nil }
        do {
            return try await task { text in await MainActor.run { self.busy = text } }
        } catch {
            if (error as? any SourceFailure)?.needsLogin == true {
                await refreshAccounts()
                say("登录状态已失效，请重新登录", error: true)
            } else {
                say(describe(error), error: true)
            }
            return nil
        }
    }

    // MARK: 账号

    func loggedIn(_ source: any MusicSource) -> Bool { accounts[source.info.id]?.loggedIn == true }
    var loggedIn: Bool { hub.all.contains { loggedIn($0) } }
    /// 可以登录但还没登录的
    var signedOut: [any MusicSource] { hub.all.filter { $0.hasAccount && !loggedIn($0) } }

    /// 个人资料入口显示哪个账号：第一个登录了的
    var primary: (any MusicSource)? { hub.all.first { loggedIn($0) } }
    var profile: AccountProfile? { primary.flatMap { profiles[$0.info.id] } }

    /// 有昵称用昵称，没有就只露出账号的头尾两位，比如 11****87
    func name(of source: any MusicSource) -> String {
        if let nick = profiles[source.info.id]?.nick, !nick.isEmpty { return nick }
        let uid = accounts[source.info.id]?.uid ?? ""
        let masked = uid.replacing(/^(\d{2})\d+(\d{2})$/) { "\($0.1)****\($0.2)" }
        return masked.isEmpty ? source.info.name : masked
    }

    private func refreshAccounts() async {
        for source in hub.all { await refreshAccount(source) }
    }

    /// 昵称和头像：先用上次存下的，再到账号里取最新的。取不到就继续用旧的，不打扰听歌
    private func refreshAccount(_ source: any MusicSource) async {
        let id = source.info.id
        let state = await source.account()
        accounts[id] = state
        guard state.loggedIn else {
            profiles[id] = nil
            return
        }
        let saved: SavedAccount? = await read("account:\(id)")
        if saved?.uin == state.uid { profiles[id] = saved?.profile }
        Task {
            // 期间可能退出登录或换了账号
            guard let profile = try? await source.profile(), accounts[id] == state else { return }
            profiles[id] = profile
            await write("account:\(id)", SavedAccount(uin: state.uid, profile: profile))
        }
    }

    func login(_ source: any MusicSource) async {
        if let script = source as? ScriptSource, !script.fields.isEmpty, !script.filled || script.site == nil {
            settingUp = SourceSetup(source: script)
            return
        }
        await source.login()
        await entered(source)
    }

    /// 登录之后：取昵称、同步曲库，第一次还顺便生成一批推荐
    func entered(_ source: any MusicSource) async {
        await refreshAccount(source)
        guard loggedIn(source) else { return }
        let first = likedMids.isEmpty
        await sync(source)
        if first, !likedMids.isEmpty { await generate() }
    }

    func logout(_ source: any MusicSource) async {
        await source.logout()
        if let script = source as? ScriptSource { try? shelf.save(script) }
        try? await store.remove("account:\(source.info.id)")
        await refreshAccount(source)
        say("已退出\(source.info.spaced)，本地的曲库和听歌记录仍然保留")
    }

    func install(_ source: any MusicSource) async {
        sources.add(source)
        sourceChanges += 1
        await source.prepare(store)
        await refreshLibrary()
        await refreshAccount(source)
    }

    func uninstall(_ source: any MusicSource) async {
        let id = source.info.id
        sources.remove(id)
        accounts[id] = nil
        profiles[id] = nil
        try? await store.remove("account:\(id)")
        sourceChanges += 1
        dropOrphans()
        await refreshLibrary()
        if !ready || page != .reco { go(.reco) }
    }

    /// 音源不在了的歌从这批推荐里去掉
    private func dropOrphans() { batch.removeAll { sources.owner(of: $0.song) == nil } }

    func sync() async {
        guard loggedIn else { return say("请先登录", error: true) }
        for source in hub.all where loggedIn(source) { await sync(source) }
    }

    private func sync(_ source: any MusicSource) async {
        await refreshAccount(source)
        let label = hub.all.count > 1 ? "\(source.info.name)：" : ""
        let r = await whileBusy("\(label)同步曲库…") { progress in
            try await library.sync(source) { await progress(label + $0) }
        }
        await refreshLibrary()
        if let r { say("\(label)同步完成，我喜欢 \(r.liked) 首，歌单 \(r.playlists) 个") }
        if case .playlist = page { await show(page) }
    }

    // MARK: 推荐

    @discardableResult
    func expand(_ seeds: Int = 12) async -> Bool {
        await whileBusy("扩充候选池…") { try await library.expandPool(seeds, progress: $0) } != nil
    }

    private func produce() async throws -> RecoResult {
        reshapeTask?.cancel()
        let seed = UInt64.random(in: 1...UInt64.max)
        let result = try await library.generateBatch(settings, seed: seed)
        batch = result.items
        batchSeed = seed
        await write("lastBatch", SavedBatch(items: result.items, seed: seed))
        return result
    }

    /// 正在听这一批推荐时，点了喜欢 / 不喜欢 / 听腻了，或者很快切掉一首，后面还没放的歌跟着重排
    func heard(_ event: PlayEvent) {
        let strong = switch event.type {
        case .like, .unlike, .dislike, .tired: true
        case .skip: event.source == .reco && event.ratio < RecoEngine.earlySkipRatio
        default: false
        }
        guard strong, player.context == Self.recoContext, !batch.isEmpty else { return }
        // 连着切好几首时等手停下来再算
        reshapeTask?.cancel()
        reshapeTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { await reshapeBatch() }
        }
    }

    private func reshapeBatch() async {
        let before = Set(player.queue.prefix(player.index + 1).map(\.song.mid))
        var s = settings
        s.batchSize = max(0, settings.batchSize - batch.count { before.contains($0.song.mid) })
        guard s.batchSize > 0, let result = try? await library.generateBatch(s, keep: Set(batch.map(\.song.mid)), seed: batchSeed),
              !Task.isCancelled, player.context == Self.recoContext else { return }
        // 算的这一会儿可能又放到了下一首
        let played = Set(player.queue.prefix(player.index + 1).map(\.song.mid))
        let rest = result.items.filter { !played.contains($0.song.mid) }
        let next = batch.filter { played.contains($0.song.mid) } + rest
        if next.map(\.id) == batch.map(\.id) { return }
        withAnimation(.smooth) { batch = next }
        player.replaceUpcoming(rest.map { QueueItem(song: $0.song, source: $0.kind == .new ? .reco : .library) })
        await write("lastBatch", SavedBatch(items: next, seed: batchSeed))
    }

    /// 生成一批推荐；候选不够时先自动扩充
    func generate() async {
        if likedMids.isEmpty { return say("还没有任何喜欢的歌。先登录同步，或导入一个歌单当种子", error: true) }
        do {
            var result = try await produce()
            let wanted = Int((Double(settings.batchSize) * (1 - settings.familiarRatio)).rounded())
            if result.items.count(where: { $0.kind == .new }) < wanted, await expand(result.candidateCount == 0 ? 15 : 8) {
                result = try await produce()
            }
            if result.items.isEmpty { say("没有符合条件的歌。试试放宽语种限制，或再扩充一次候选池", error: true) }
        } catch {
            say(describe(error), error: true)
        }
    }

    func update(_ change: (inout RecoSettings) -> Void) {
        change(&settings)
        let value = settings
        Task { await write("settings", value) }
    }

    func setSyncLikes(_ value: Bool) {
        syncLikes = value
        Task { await write("syncLikes", value) }
    }

    // MARK: 页面

    func go(_ next: Page) {
        if next.identity != page.identity { history = Array((history + [page]).suffix(50)) }
        Task { await show(next) }
    }

    /// 回到上一个页面；已经删掉的歌单跳过
    func back() {
        while let last = history.popLast() {
            if case .playlist(let id) = last, !playlists.contains(where: { $0.id == id }) { continue }
            Task { await show(last) }
            return
        }
    }

    func open(_ artist: Singer) {
        if !artist.mid.isEmpty { go(.artist(ArtistRef(mid: artist.mid, name: artist.name), .songs)) }
    }

    func openAlbum(of song: Song) {
        go(.album(Album(mid: song.albumMid, name: song.albumName, cover: song.cover), song.singers.first.map { ArtistRef(mid: $0.mid, name: $0.name) }))
    }

    /// 这些歌都来自哪些音源
    func sourceNames(_ rows: [Report.SongRank]) -> String {
        hub.all.filter { s in rows.contains { hub.owner(of: $0.song)?.info == s.info } }.map(\.info.spaced).joined(separator: "和")
    }

    func search(_ text: String, _ kind: SearchKind = .song) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { go(.search(q, kind, searching?.info.id ?? "")) }
    }

    /// 在哪个音源里搜：上次用的；没有就用登录了的
    var searching: (any MusicSource)? { hub.named(searchSource) ?? primary ?? hub.all.first }

    /// 换一个音源再搜同样的词
    func search(_ text: String, _ kind: SearchKind, in source: String) {
        searchSource = source
        Task { await write("searchSource", source) }
        search(text, kind)
    }

    private func source(of id: String) throws -> any MusicSource {
        guard let source = hub.owner(of: id) else { throw SourceError("没有对应的音源") }
        return source
    }

    private func find(_ q: String, _ kind: SearchKind, in id: String, page: Int) async throws -> SearchPage {
        guard let source = hub.named(id) else { throw SourceError("还没有音源") }
        return try await source.search(q, kind, page: page)
    }

    func retry() { Task { await show(page) } }

    private func show(_ next: Page) async {
        visit += 1
        let mine = visit
        page = next
        if case .report(let period, let date) = next { return await showReport(period, date, mine) }
        reportInput = nil
        content = Content()
        if case .settings = next { return }
        if next == .reco { return }
        content.loading = true
        var loaded = Content()
        do {
            switch next {
            case .playlist(let id):
                loaded.songs = try await store.playlistSongs(id)
                if loaded.songs.isEmpty, playlists.first(where: { $0.id == id })?.kind == .collected {
                    // 收藏的歌单第一次打开时才取歌曲，不计入“喜欢”
                    loaded.songs = try await source(of: id).playlist(id, max: Library.maxPlaylistSongs).songs
                    try await store.putSongs(loaded.songs)
                }
            case .artist(let a, .songs):
                let r = try await source(of: a.mid).artistSongs(a.mid, begin: 0, count: Self.artistPage)
                loaded.songs = unique(r.songs)
                loaded.total = r.total
            case .artist(let a, .albums):
                loaded.albums = unique(try await source(of: a.mid).artistAlbums(a.mid))
            case .album(let a, _):
                loaded.songs = unique(try await source(of: a.mid).albumSongs(a.mid))
            case .search(let q, let kind, let id):
                loaded.results = SearchResults().merging(try await find(q, kind, in: id, page: 1), page: 1)
                loaded.songs = loaded.results.songs
            case .reco, .settings, .report:
                break
            }
        } catch {
            loaded.error = describe(error)
        }
        if mine == visit { content = loaded }
    }

    // MARK: 听歌报告

    func openReport(_ period: ReportPeriod = .day, _ date: Date = Date()) {
        if case .report = page {} else { report = nil }
        go(.report(period, date))
    }

    private func showReport(_ period: ReportPeriod, _ date: Date, _ mine: Int) async {
        content = Content()
        if reportInput == nil {
            content.loading = true
            do {
                reportInput = try await library.reportInput()
            } catch {
                if mine == visit { content = Content(error: describe(error)) }
                return
            }
        }
        guard let input = reportInput else { return }
        let made = await Self.make(period, date, input)
        guard mine == visit else { return }
        content.loading = false
        report = made
    }

    @concurrent
    private nonisolated static func make(_ period: ReportPeriod, _ date: Date, _ input: ReportInput) async -> Report { Report.make(period, date, input) }

    /// 放报告里的一个榜
    func play(_ songs: [Song], from mid: String? = nil) {
        guard !songs.isEmpty else { return }
        let items = songs.map { QueueItem(song: $0, source: .library) }
        player.setQueue(items, startIndex: mid.flatMap { m in items.firstIndex { $0.song.mid == m } }, context: "report")
    }

    private func unique<T: Identifiable>(_ list: [T]) -> [T] {
        var seen: Set<T.ID> = []
        return list.filter { seen.insert($0.id).inserted }
    }

    /// 歌手页、搜索页：后面还有没有
    var hasMore: Bool {
        switch page {
        case .artist(_, .songs): !content.songs.isEmpty && content.songs.count < content.total
        case .search: content.results.hasMore
        default: false
        }
    }

    /// 再加载一页，接在后面
    func loadMore() async {
        guard hasMore, !content.loading else { return }
        let mine = visit
        content.loading = true
        defer { if mine == visit { content.loading = false } }
        do {
            switch page {
            case .artist(let a, _):
                let r = try await source(of: a.mid).artistSongs(a.mid, begin: content.songs.count, count: Self.artistPage)
                guard mine == visit else { return }
                let all = unique(content.songs + r.songs)
                // 这一页没有新歌说明到头了，把总数收到当前长度
                content.total = all.count > content.songs.count ? r.total : all.count
                content.songs = all
            case .search(let q, let kind, let id):
                let number = content.results.page + 1
                let r = try await find(q, kind, in: id, page: number)
                guard mine == visit else { return }
                content.results = content.results.merging(r, page: number)
                content.songs = content.results.songs
            default:
                break
            }
        } catch {
            if mine == visit { say(describe(error), error: true) }
        }
    }

    // MARK: 播放

    /// mid 为 nil：没有指定从哪首开始（点的是“播放”按钮）
    static let recoContext = "reco"

    func playBatch(from mid: String? = nil) {
        let items = batch.map { QueueItem(song: $0.song, source: $0.kind == .new ? .reco : .library) }
        player.setQueue(items, startIndex: mid.flatMap { m in items.firstIndex { $0.song.mid == m } }, context: Self.recoContext)
    }

    func playList(from mid: String? = nil) {
        guard !content.songs.isEmpty else { return }
        // 搜索结果里的歌记成 search：切歌不会被当成对推荐的负反馈
        var source = PlaySource.library
        var context = page.identity
        if case .search = page { source = .search }
        if case .playlist(let id) = page { context = id }
        let items = content.songs.map { QueueItem(song: $0, source: source) }
        player.setQueue(items, startIndex: mid.flatMap { m in items.firstIndex { $0.song.mid == m } }, context: context)
    }

    /// 播放 / 暂停；还没播过歌时从这一批推荐开始
    func togglePlay() {
        if player.queue.isEmpty { playBatch() } else { player.toggle() }
    }

    var canPlay: Bool { !player.queue.isEmpty || !batch.isEmpty }

    /// 智能随机只在“我喜欢”里起作用；别的列表里只有普通随机
    var canSmartShuffle: Bool { Playlist.isLiked(player.context) }

    /// 智能随机记住了但当前列表用不上时，界面上按普通随机显示
    var shuffleLook: ShuffleMode {
        player.prefs.shuffle == .smart && !player.queue.isEmpty && !canSmartShuffle ? .on : player.prefs.shuffle
    }

    /// 播放方式：一个按钮依次切换，底下还是随机和循环两项设置
    var playMode: PlayMode {
        if player.prefs.repeat == .one { return .one }
        switch shuffleLook {
        case .smart: return .smart
        case .on: return .shuffle
        case .off: return player.prefs.repeat == .off ? .order : .loop
        }
    }

    /// 能选的播放方式；智能随机只在“我喜欢”里有
    var playModes: [PlayMode] { PlayMode.allCases.filter { $0 != .smart || canSmartShuffle } }

    func setPlayMode(_ mode: PlayMode) {
        switch mode {
        case .loop, .order, .one:
            player.setShuffle(.off)
            player.setRepeat(mode == .order ? .off : mode == .one ? .one : .all)
        case .shuffle:
            player.setRepeat(.all)
            player.setShuffle(.on)
        case .smart:
            player.setRepeat(.all)
            announceSmart = true
            player.setShuffle(.smart)
        }
    }

    /// 列表循环 → 单曲循环 → 随机播放 →（我喜欢里）智能随机 → 顺序播放 → 列表循环
    func cyclePlayMode() {
        let all = PlayMode.allCases, modes = playModes
        let i = all.firstIndex(of: playMode) ?? 0
        setPlayMode((1...all.count).map { all[(i + $0) % all.count] }.first(where: modes.contains) ?? .loop)
    }

    /// “我喜欢”页上的智能随机：直接打乱开始放，并穿插推荐
    func playSmart() {
        player.setShuffle(.smart)
        announceSmart = true
        playList()
    }

    /// 给智能随机的队列补推荐。先用手头的候选，明显不够再去扩充候选池
    private func fillSmart() async {
        guard player.prefs.shuffle == .smart, canSmartShuffle else { return }
        let epoch = player.epoch
        let wanted = PlayOrder.weaveCount(player.upcomingCount)
        guard wanted > 0 else { return }
        func put() async throws -> Int? {
            let picks = try await library.smartPicks(settings, count: wanted)
            // 取推荐的这一会儿里，用户可能已经换了列表或关掉了智能随机
            guard player.epoch == epoch, player.prefs.shuffle == .smart else { return nil }
            player.weaveIn(picks.map { QueueItem(song: $0.song, source: .reco) })
            return player.queue.count { $0.extra }
        }
        do {
            var n = try await put()
            if let got = n, Double(got) < Double(wanted) / 2, busy == nil {
                try await library.expandPool(8) { _ in }
                n = try await put()
            }
            guard let n, announceSmart else { return }
            announceSmart = false
            say(n > 0 ? "已穿插 \(n) 首推荐" : "暂时没有合适的推荐可以穿插")
        } catch {
            say("推荐没有穿插进来：\(describe(error))", error: true)
        }
    }

    // MARK: 喜欢、歌单

    /// 能不能把改动写回一个音源的账号
    private func writable(_ source: (any MusicSource)?, _ ability: SourceAbilities) -> Bool {
        guard let source else { return false }
        return syncLikes && source.abilities.contains(ability) && loggedIn(source)
    }

    /// 侧边栏里的歌单，按音源分开。什么都没有的音源不占地方
    var sidebarGroups: [SidebarGroup] {
        let groups = hub.all.map { s in
            SidebarGroup(id: s.info.id, name: s.info.name, playlists: playlists.filter { hub.owner(of: $0.id)?.info == s.info }, canCreate: writable(s, .playlists))
        }
        let used = groups.filter { !$0.playlists.isEmpty || $0.canCreate }
        // 一个音源都没有时，喜欢过的歌、以前的歌单照样能看到
        return used.isEmpty ? [SidebarGroup(id: "", name: "", playlists: playlists, canCreate: false)] : used
    }
    /// 设置里要不要显示“同步到账号”
    var canSyncLikes: Bool { hub.all.contains { !$0.abilities.isEmpty } }

    /// 这首歌能不能加入账号里的歌单
    func canEditPlaylists(for song: Song) -> Bool { writable(hub.owner(of: song), .playlists) }
    func canEdit(_ playlist: Playlist) -> Bool { playlist.kind == .own && writable(hub.owner(of: playlist.id), .playlists) }
    /// 这首歌能加入的自建歌单：和它同一个音源的
    func ownPlaylists(for song: Song) -> [Playlist] {
        let owner = hub.owner(of: song)?.info
        return playlists.filter { $0.kind == .own && hub.owner(of: $0.id)?.info == owner }
    }

    /// 把一个操作交给音源去完成；返回是否成功。操作在后台排队，界面不会卡住
    private func writeToAccount(_ source: any MusicSource, _ action: AccountAction, _ what: String) async -> Bool {
        syncing += 1
        defer { syncing -= 1 }
        do {
            try await source.perform(action)
            return true
        } catch {
            say("\(what)没有同步到\(source.info.spaced)账号：\(describe(error))", error: true)
            return false
        }
    }

    private func setLikedLocally(_ song: Song, _ liked: Bool) async {
        let id = Playlist.liked(for: song.mid)
        if liked {
            if !playlists.contains(where: { $0.id == id }) {
                try? await store.putPlaylist(Playlist(id: id, title: "我喜欢", kind: .liked, songCount: 0))
            }
            try? await store.addMember(song, to: id)
        } else {
            try? await store.removeMember(song.mid, from: id)
        }
        let event = PlayEvent(mid: song.mid, type: liked ? .like : .unlike, ratio: 0, source: .reco, ts: nowMillis())
        try? await store.addEvents([event])
        await refreshLibrary()
        heard(event)
    }

    /// 点爱心：本地立刻生效，同时在后台同步到账号的“我喜欢”；同步失败会撤回本地的改动
    func toggleLike(_ song: Song) {
        let liked = !hearts.contains(song.mid)
        if liked { hearts.insert(song.mid) } else { hearts.remove(song.mid) }
        Task {
            await setLikedLocally(song, liked)
            guard let source = hub.owner(of: song), writable(source, .like) else { return }
            let ok = await writeToAccount(source, .setLiked(song, liked), liked ? "“喜欢”" : "“取消喜欢”")
            if !ok { await setLikedLocally(song, !liked) }
        }
    }

    private static let needSync = "需要登录并开启“喜欢和歌单同步到账号”才能修改歌单"

    /// 把歌加入账号里的一个自建歌单
    func add(_ song: Song, to playlist: Playlist) async {
        guard let source = hub.owner(of: song), canEdit(playlist) else { return say(Self.needSync, error: true) }
        if (try? await store.contains(song.mid, in: playlist.id)) == true { return say("《\(song.name)》已经在「\(playlist.title)」里了") }
        guard await writeToAccount(source, .addToPlaylist(song, playlist), "加入歌单") else { return }
        try? await store.addMember(song, to: playlist.id)
        await refreshLibrary()
        say("已加入「\(playlist.title)」")
    }

    /// 新建歌单；传了歌就同时把这首歌放进去（建在这首歌的音源里）
    func createPlaylist(_ name: String, with song: Song? = nil, in id: String? = nil) async {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return }
        if title.utf16.count > 20 { return say("歌单名最多 20 个字", error: true) }
        guard let source = song.flatMap({ hub.owner(of: $0) }) ?? id.flatMap({ hub.named($0) }), writable(source, .playlists) else { return say(Self.needSync, error: true) }
        if playlists.contains(where: { $0.kind == .own && $0.title == title && hub.owner(of: $0.id)?.info == source.info }) {
            return say("已经有一个叫「\(title)」的歌单了", error: true)
        }
        guard await writeToAccount(source, .createPlaylist(name: title, song: song), "新建歌单") else { return }
        do {
            try await library.syncOwnPlaylists(source)
        } catch {
            say("歌单已建好，但没有刷新出来：\(describe(error))", error: true)
        }
        await refreshLibrary()
        say(song.map { "已新建「\(title)」并加入《\($0.name)》" } ?? "已新建歌单「\(title)」")
    }

    func deletePlaylist(_ playlist: Playlist) async {
        guard let source = hub.owner(of: playlist.id), canEdit(playlist) else { return say(Self.needSync, error: true) }
        guard await writeToAccount(source, .deletePlaylist(playlist), "删除歌单") else { return }
        await removePlaylist(playlist.id)
        say("已删除歌单「\(playlist.title)」")
    }

    /// 不喜欢：永不再推荐；听腻了：一个半月内不再出现
    func reject(_ song: Song, _ type: EventType) {
        let event = PlayEvent(mid: song.mid, type: type, ratio: 0, source: .reco, ts: nowMillis())
        Task {
            try? await store.addEvents([event])
            heard(event)
        }
        batch.removeAll { $0.song.mid == song.mid }
        player.remove(song.mid)
        say(type == .dislike ? "不会再推荐这首歌" : "这首歌会休息一个半月")
    }

    // MARK: 种子歌单

    func importSeed(_ input: String) async {
        let title = await whileBusy("导入歌单…") { _ in try await library.importPlaylist(input) }
        await refreshLibrary()
        if let title { say("已导入「\(title)」作为口味种子") }
    }

    func removePlaylist(_ id: String) async {
        try? await store.removePlaylist(id)
        if page == .playlist(id) { await show(.reco) }
        await refreshLibrary()
    }
}
