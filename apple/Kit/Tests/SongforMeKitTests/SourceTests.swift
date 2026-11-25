import Foundation
import Testing
@testable import SongforMeKit

/// 假的音源：内容都写死在测试里
struct FakeSource: MusicSource {
    var info: SourceInfo
    var hasAccount = true
    var abilities: SourceAbilities = []
    var loggedIn = true
    var liked: [Song] = []
    var own: [Playlist] = []
    var lists: [String: [Song]] = [:]
    var recent: [RecentPlay] = []
    var similar: [Song] = []
    var relatedLists: [RelatedPlaylist] = []

    func search(_ query: String, _ kind: SearchKind, page: Int) async throws -> SearchPage { SearchPage() }
    func stream(_ song: Song) async throws -> StreamInfo? { nil }
    func account() async -> SourceAccount { SourceAccount(loggedIn: loggedIn, uid: "1") }
    func myPlaylists() async throws -> [Playlist] { own }
    func likedSongs(_ list: Playlist?) async throws -> [Song] { liked }
    func recentPlays() async throws -> [RecentPlay] { recent }
    func playlist(_ id: String, max: Int) async throws -> (title: String, songs: [Song]) { ("歌单名", lists[id] ?? []) }
    func playlistID(in text: String) -> String? { text.hasPrefix("\(info.id)/") ? info.wrap(String(text.dropFirst(info.id.count + 1))) : nil }
    func related(to song: Song) async throws -> (similar: [Song], playlists: [RelatedPlaylist]) { (similar, relatedLists) }
}

private func song(_ mid: String, _ name: String? = nil, by artist: String = "歌手") -> Song {
    Song(mid: mid, name: name ?? mid, singers: [Singer(mid: "s-\(mid)", name: artist)], duration: 200)
}

private let quiet: Library.Progress = { _ in }

@Suite("音源")
struct SourceTests {
    let bare = FakeSource(info: SourceInfo(id: "old", name: "旧", bare: true))
    let other = FakeSource(info: SourceInfo(id: "x", name: "新"))

    @Test("按编号开头认出是哪个音源；不带前缀的归 bare 那个")
    func owner() {
        let hub = SourceHub([bare, other])
        #expect(hub.owner(of: "003abc")?.info.id == "old")
        #expect(hub.owner(of: "x:12")?.info.id == "x")
        #expect(hub.owner(of: "y:12") == nil)
        #expect(hub.owner(of: "old:12") == nil)
        #expect(SourceHub([other]).owner(of: "003abc") == nil)
        #expect(SourceHub().all.isEmpty)
    }

    @Test("加前缀和去前缀；“我喜欢”各有各的")
    func prefix() {
        #expect(other.info.wrap("12") == "x:12" && other.info.unwrap("x:12") == "12")
        #expect(bare.info.wrap("12") == "12" && bare.info.unwrap("12") == "12")
        #expect(bare.info.likedID == "liked" && other.info.likedID == "x:liked")
        #expect(Playlist.liked(for: "x:12") == "x:liked" && Playlist.liked(for: "003abc") == "liked")
        #expect(Playlist.isLiked("liked") && Playlist.isLiked("x:liked") && !Playlist.isLiked("x:recent"))
    }

    @Test("同步只动自己音源的歌单")
    func syncKeepsOthers() async throws {
        let store = try Store()
        var (a, b) = (bare, other)
        a.liked = [song("a")]
        a.own = [Playlist(id: "100", title: "甲", kind: .own, songCount: 1)]
        a.lists = ["100": [song("a")]]
        b.liked = [song("x:1"), song("x:2")]
        b.own = [Playlist(id: "x:100", title: "乙", kind: .own, songCount: 1)]
        b.lists = ["x:100": [song("x:3")]]
        b.recent = [RecentPlay(song: song("x:1"), lastTime: 1_700_000_000, listenCount: 9)]
        let library = Library(hub: SourceHub([a, b]), store: store)
        _ = try await library.sync(a, progress: quiet)
        let r = try await library.sync(b, progress: quiet)
        #expect(r.liked == 2)
        #expect(try await library.hearts() == ["a", "x:1", "x:2"])
        #expect(try await library.accountPlays()["x:1"]?.last == 1_700_000_000_000)
        // 账号里删掉的歌单，本地也去掉；另一个音源的不受影响
        b.own = []
        _ = try await library.sync(b, progress: quiet)
        let ids = Set(try await store.playlists().map(\.id))
        #expect(ids.contains("100") && !ids.contains("x:100"))
    }

    @Test("不支持写回的音源：在这里点的喜欢、取消的喜欢，同步之后还在")
    func localLikes() async throws {
        let store = try Store()
        var s = other
        s.liked = [song("x:1"), song("x:2")]
        let library = Library(hub: SourceHub([s]), store: store)
        _ = try await library.sync(s, progress: quiet)
        try await store.addMember(song("x:9"), to: "x:liked")
        try await store.removeMember("x:2", from: "x:liked")
        try await store.addEvents([
            PlayEvent(mid: "x:9", type: .like, ratio: 0, source: .reco, ts: 1), PlayEvent(mid: "x:2", type: .unlike, ratio: 0, source: .reco, ts: 2),
        ])
        _ = try await library.sync(s, progress: quiet)
        #expect(try await store.members(of: "x:liked") == ["x:9", "x:1"])
        // 能写回的音源，以账号里的为准
        s.abilities = .like
        _ = try await library.sync(s, progress: quiet)
        #expect(try await store.members(of: "x:liked") == ["x:1", "x:2"])
    }

    @Test("用相似歌曲和公开歌单扩充候选；退出登录的音源不再推荐")
    func expand() async throws {
        let store = try Store()
        var (a, b) = (bare, other)
        a.similar = [song("new", by: "甲")]
        b.similar = [song("x:new", by: "乙")]
        b.relatedLists = [RelatedPlaylist(id: "x:88", songCount: 10)]
        b.lists = ["x:88": [song("x:seed", by: "丙"), song("x:more", by: "丁")]]
        try await store.replacePlaylist(Playlist(id: "liked", title: "我喜欢", kind: .liked, songCount: 1), songs: [song("seed", by: "戊")])
        try await store.replacePlaylist(Playlist(id: "x:liked", title: "我喜欢", kind: .liked, songCount: 1), songs: [song("x:seed", by: "丙")])
        let library = Library(hub: SourceHub([a, b]), store: store)
        try await library.expandPool(5, progress: quiet)
        let found = Set(try await store.evidence().map(\.mid))
        #expect(found.isSuperset(of: ["new", "x:new", "x:more"]))

        var settings = RecoSettings()
        settings.familiarRatio = 0
        #expect(Set(try await library.generateBatch(settings).items.map(\.id)) == ["new", "x:new", "x:more"])
        b.loggedIn = false
        let left = Library(hub: SourceHub([a, b]), store: store)
        try await store.remove("recommendedAt")
        #expect(try await left.generateBatch(settings).items.map(\.id) == ["new"])
        // 没有账号这回事的音源一直能放
        b.hasAccount = false
        try await store.remove("recommendedAt")
        #expect(try await Library(hub: SourceHub([a, b]), store: store).generateBatch(settings).items.count == 3)
    }

    @Test("一边喜欢的歌，不会从另一边当新歌推荐")
    func sameWork() {
        let songs = [song("a", "晴天", by: "周杰伦"), song("x:1", "晴天 (Live)", by: "周杰伦"), song("x:2", "别的", by: "周杰伦")]
        let evidence = ["x:1", "x:2"].map { Evidence(mid: $0, via: .similar, ref: "a", seed: "a", ts: 0) }
        var settings = RecoSettings()
        settings.familiarRatio = 0
        let r = RecoEngine.recommend(RecoInput(
            songs: Dictionary(uniqueKeysWithValues: songs.map { ($0.mid, $0) }), likedMids: ["a"], events: [], evidence: evidence, settings: settings, now: 1e12
        ))
        #expect(r.items.map(\.id) == ["x:2"])
    }

    @Test("粘贴的歌单链接由认得它的音源导入")
    func importSeed() async throws {
        let store = try Store()
        var s = other
        s.lists = ["x:77": [song("x:1")]]
        let library = Library(hub: SourceHub([bare, s]), store: store)
        #expect(try await library.importPlaylist("x/77") == "歌单名")
        #expect(try await store.playlists().map(\.id) == ["x:77"])
        await #expect(throws: SourceError.self) { try await library.importPlaylist("认不出来") }
        await #expect(throws: SourceError.self) { try await library.importPlaylist("x/78") }
    }

    @Test("封面地址跟着歌存下来")
    func cover() async throws {
        let store = try Store()
        var s = song("x:1")
        s.cover = "https://example.com/1.jpg"
        try await store.putSongs([s])
        #expect(try await store.song("x:1")?.artwork()?.absoluteString == "https://example.com/1.jpg")
        #expect(song("x:2").artwork() == nil)
    }

    func page(_ mids: [String], more: Bool = true, total: Int = 999) -> SearchPage {
        var p = SearchPage()
        p.songs = mids.map { song($0) }
        p.total = total
        p.hasMore = more
        return p
    }

    @Test("搜索分页：接在后面并去重；一页全是重复的就当作到头了")
    func merge() {
        let first = SearchResults().merging(page(["a", "b"]), page: 1)
        #expect(first.songs.map(\.mid) == ["a", "b"] && first.page == 1 && first.hasMore && first.total == 999)
        let second = first.merging(page(["b", "c", "c"]), page: 2)
        #expect(second.songs.map(\.mid) == ["a", "b", "c"] && second.page == 2 && second.hasMore)
        let same = first.merging(page(["a", "b"]), page: 2)
        #expect(!same.hasMore && same.total == 2)
        let last = SearchResults().merging(page(["a", "b"], total: 17), page: 1).merging(page(["c"], more: false, total: 13), page: 2)
        #expect(!last.hasMore && last.total == 3 && last.page == 2)
    }
}
