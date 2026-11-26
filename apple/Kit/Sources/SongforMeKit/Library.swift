import Foundation

// 把接口、本地数据库、推荐算法串起来的业务流程：同步曲库、扩充候选池、生成一批推荐。
public struct Library: Sendable {
    public typealias Progress = @Sendable (String) async -> Void

    public let hub: SourceHub
    public let store: Store

    /// 太大的公开歌单多半是大杂烩，对口味判断没帮助
    private static let maxPlaylistSize = 400
    /// 一个公开歌单里最多取多少首作为候选
    private static let maxSongsPerPlaylist = 200
    /// 每首种子歌最多展开几个相关歌单
    private static let playlistsPerSeed = 2
    private static let maxOwnPlaylists = 40
    public static let maxPlaylistSongs = 2000

    public init(hub: SourceHub, store: Store) {
        self.hub = hub
        self.store = store
    }

    struct AccountPlay: Codable, Sendable {
        var count: Double
        var last: Double
    }

    public func loadSettings() async -> RecoSettings {
        (try? await store.get("settings", as: RecoSettings.self)) ?? RecoSettings()
    }

    // MARK: 同步

    /// 从一个音源的账号同步“我喜欢”和自建、收藏的歌单
    public func sync(_ source: any MusicSource, progress: Progress) async throws -> (liked: Int, playlists: Int) {
        let info = source.info
        await progress("读取歌单列表…")
        let own = try await source.myPlaylists()

        await progress("读取“我喜欢”…")
        let list = own.first { $0.kind == .liked }
        var liked = try await source.likedSongs(list)
        // 音源不支持写回时，在这里点过的爱心只存在本地，别被账号里的内容冲掉
        if !source.abilities.contains(.like) { liked = try await withLocalLikes(liked, in: info) }
        try await store.replacePlaylist(Playlist(id: info.likedID, title: "我喜欢", kind: .liked, songCount: liked.count, dirId: list?.dirId), songs: liked)

        await progress("读取最近播放…")
        do {
            let recent = try await source.recentPlays()
            if !recent.isEmpty {
                try await store.replacePlaylist(Playlist(id: info.recentID, title: "最近播放", kind: .recent, songCount: recent.count), songs: recent.map(\.song))
            }
            var plays: [String: AccountPlay] = [:]
            for r in recent {
                // 时间有时是秒、有时是毫秒，统一成毫秒
                plays[r.song.mid] = AccountPlay(count: Double(r.listenCount), last: r.lastTime < 1e12 ? r.lastTime * 1000 : r.lastTime)
            }
            try await store.set(info.key("accountPlays"), plays)
        } catch {
            log("最近播放读取失败", error)
        }

        let others = try await syncOwnDetails(source, own, progress: progress)

        await progress("读取收藏的歌单…")
        var collected = 0
        do {
            let fav = try await source.collectedPlaylists()
            collected = fav.count
            // 收藏的歌单只存目录，点开时再取歌曲
            let known = Set(try await store.playlists().map(\.id))
            for p in fav where !known.contains(p.id) { try await store.putPlaylist(p) }
        } catch {
            log("收藏歌单读取失败", error)
        }
        try await store.set("lastSync", nowMillis())
        return (liked.count, others + collected)
    }

    private func withLocalLikes(_ songs: [Song], in info: SourceInfo) async throws -> [Song] {
        var taps: [String: EventType] = [:]
        for e in try await store.events() where e.type == .like || e.type == .unlike { taps[e.mid] = e.type }
        let fetched = Set(songs.map(\.mid))
        let kept = try await store.playlistSongs(info.likedID).filter { taps[$0.mid] == .like && !fetched.contains($0.mid) }
        return kept + songs.filter { taps[$0.mid] != .unlike }
    }

    /// 只同步自建歌单（新建、删除歌单之后用，比完整同步快得多）
    public func syncOwnPlaylists(_ source: any MusicSource) async throws {
        _ = try await syncOwnDetails(source, source.myPlaylists()) { _ in }
    }

    /// 把账号里的自建歌单（不含“我喜欢”）的内容同步到本地，并清掉账号里已经删除的
    private func syncOwnDetails(_ source: any MusicSource, _ own: [Playlist], progress: Progress) async throws -> Int {
        let others = own.filter { $0.kind == .own }.prefix(Self.maxOwnPlaylists)
        for (i, p) in others.enumerated() {
            await progress("读取自建歌单 \(i + 1)/\(others.count)：\(p.title)")
            do {
                try await store.replacePlaylist(p, songs: source.playlist(p.id, max: Self.maxPlaylistSongs).songs)
            } catch {
                log("歌单读取失败", error)
            }
        }
        let keep = Set(others.map(\.id))
        for p in try await store.playlists() where p.kind == .own && !keep.contains(p.id) && hub.owner(of: p.id)?.info == source.info {
            try await store.removePlaylist(p.id)
        }
        return others.count
    }

    /// 严格在“我喜欢”里的歌（每个音源各有一个）
    public func hearts() async throws -> Set<String> {
        var out: Set<String> = []
        for p in try await store.playlists() where Playlist.isLiked(p.id) { out.formUnion(try await store.members(of: p.id)) }
        return out
    }

    func accountPlays() async throws -> [String: AccountPlay] {
        var out: [String: AccountPlay] = [:]
        for source in hub.all {
            out.merge(try await store.get(source.info.key("accountPlays"), as: [String: AccountPlay].self) ?? [:]) { a, _ in a }
        }
        return out
    }

    // MARK: 推荐的输入

    /// 本应用记录的行为，加上账号“最近播放”里的播放次数换算出的行为。
    /// 在音源自己的应用里反复听的歌（哪怕没点喜欢）也会被当成正反馈。播放次数按对数折算：
    /// 听 2 次算 1 次正反馈，5 次算 3 次，20 次算 5 次，上限 8 次，避免个别循环了上百遍的歌把口味带偏。
    public func allEvents() async throws -> [PlayEvent] {
        let plays = try await accountPlays()
        var out: [PlayEvent] = []
        for (mid, p) in plays.sorted(by: { $0.key < $1.key }) {
            let ts = p.last > 0 ? p.last : nowMillis()
            out.append(PlayEvent(mid: mid, type: .play, ratio: 0, source: .library, ts: ts))
            let positives = p.count < 2 ? 0 : min(8, (1.7 * log(p.count)).jsRounded)
            for _ in 0..<positives { out.append(PlayEvent(mid: mid, type: .complete, ratio: 1, source: .library, ts: ts)) }
        }
        return out + (try await store.events())
    }

    /// 从本地数据库取出推荐算法要的全部输入
    public func recoInput(_ settings: RecoSettings, now: Double) async throws -> RecoInput {
        var active: Set<String> = []
        for source in hub.all where await source.account().loggedIn { active.insert(source.info.id) }
        var input = RecoInput(
            songs: Dictionary(try await store.allSongs().map { ($0.mid, $0) }, uniquingKeysWith: { $1 }),
            likedMids: try await store.likedMids(),
            events: try await allEvents(),
            evidence: try await store.evidence(),
            recentlyRecommended: try await store.get("recommendedAt", as: [String: Double].self) ?? [:],
            settings: settings,
            now: now
        )
        // 一个都没登录时不挑，先让人看到推荐
        var open = active
        for source in hub.all where active.isEmpty || !source.hasAccount { open.insert(source.info.id) }
        // 音源已经移除的歌放不了
        if !open.isEmpty { input.playable = { [open] in hub.owner(of: $0).map { open.contains($0.info.id) } ?? false } }
        return input
    }

    // MARK: 扩充候选池

    /// 挑一批种子歌，为每首取“相似歌曲”和“收录它的公开歌单”。
    /// 公开歌单里如果同时出现了多首你喜欢的歌，说明整理者的口味和你接近，歌单里其余的歌会得到更强的证据。
    @concurrent
    public func expandPool(_ seedCount: Int, progress: Progress) async throws {
        let now = nowMillis()
        let affinity = RecoEngine.affinity(likedMids: try await store.likedMids(), events: try await allEvents(), now: now)
        var expandedAt = try await store.get("expandedAt", as: [String: Double].self) ?? [:]
        var fetched = Set(try await store.get("fetchedPlaylists", as: [String].self) ?? [])
        let seeds = RecoEngine.pickSeeds(affinity, expandedAt: expandedAt, count: seedCount, now: now)

        for (n, seedMid) in seeds.enumerated() {
            guard let seed = try await store.song(seedMid), let source = hub.owner(of: seed) else { continue }
            await progress("扩充候选 \(n + 1)/\(seeds.count)：\(seed.name)")
            do {
                let (similar, playlists) = try await source.related(to: seed)
                var rows = similar.map { Evidence(mid: $0.mid, via: .similar, ref: seedMid, seed: seedMid, ts: now) }
                try await store.putSongs(similar, keepExisting: true)

                let fresh = playlists.filter { !fetched.contains($0.id) && $0.songCount > 5 && $0.songCount <= Self.maxPlaylistSize }.prefix(Self.playlistsPerSeed)
                for p in fresh {
                    let detail = try await source.playlist(p.id, max: Self.maxSongsPerPlaylist)
                    fetched.insert(p.id)
                    try await store.putSongs(detail.songs, keepExisting: true)
                    // 这个歌单里有哪些你喜欢的歌（至少包含种子歌本身），最多取 5 首作为证据来源
                    let others = detail.songs.map(\.mid).filter { $0 != seedMid && (affinity[$0]?.score ?? 0) > 0 }
                    for s in detail.songs {
                        for a in ([seedMid] + others).prefix(5) where a != s.mid {
                            rows.append(Evidence(mid: s.mid, via: .playlist, ref: p.id, seed: a, ts: now))
                        }
                    }
                }
                try await store.putEvidence(rows)
                expandedAt[seedMid] = now
            } catch {
                // 整个网络都断了就不用一首首试下去
                if error is URLError { throw error }
                log("扩充失败", error)
            }
        }
        try await store.set("expandedAt", expandedAt)
        try await store.set("fetchedPlaylists", fetched.sorted())
    }

    // MARK: 生成推荐

    /// 用当前设置生成一批推荐，并记下这批歌，冷却期内不再重复
    @concurrent
    /// keep：重排当前这一批时，这批里的歌不受“最近推荐过”的限制
    public func generateBatch(_ settings: RecoSettings, keep: Set<String> = [], seed: UInt64? = nil) async throws -> RecoResult {
        let now = nowMillis()
        var input = try await recoInput(settings, now: now)
        input.keep = keep
        input.seed = seed
        let result = RecoEngine.recommend(input)
        var recent = input.recentlyRecommended.filter { $0.value > now - 90 * RecoEngine.day }
        for r in result.items where r.kind == .new { recent[r.song.mid] = now }
        try await store.set("recommendedAt", recent)
        return result
    }

    /// 给智能随机挑几首没听过的推荐。用的是同一套算法和调校设置，只是不要熟歌。
    /// 从多一半的高分候选里随机取，免得每次穿插的都是那几首；放没放到都不占冷却期
    /// （真正放出来的会留下播放记录，自然不会再当新歌推荐）。
    @concurrent
    public func smartPicks(_ settings: RecoSettings, count: Int) async throws -> [Recommendation] {
        guard count > 0 else { return [] }
        var s = settings
        s.batchSize = Int((Double(count) * 1.5).rounded(.up))
        s.familiarRatio = 0
        let items = RecoEngine.recommend(try await recoInput(s, now: nowMillis())).items
        return Array(PlayOrder.shuffled(items, artistOf: { $0.song.singers.first?.mid ?? "" }).prefix(count))
    }

    // MARK: 种子歌单

    /// 手动导入一个公开歌单当作口味种子；参数可以是歌单号，也可以是歌单分享链接
    public func importPlaylist(_ input: String) async throws -> String {
        guard let (source, id) = hub.all.lazy.compactMap({ s in s.playlistID(in: input).map { (s, $0) } }).first else {
            throw SourceError("没认出歌单号，请粘贴歌单链接或纯数字的歌单号")
        }
        let detail = try await source.playlist(id, max: Self.maxPlaylistSongs)
        guard !detail.songs.isEmpty else { throw SourceError("这个歌单是空的，或者不是公开歌单") }
        let title = detail.title.isEmpty ? "歌单 \(source.info.unwrap(id))" : detail.title
        try await store.replacePlaylist(Playlist(id: id, title: title, kind: .imported, songCount: detail.songs.count), songs: detail.songs)
        return title
    }
}

func log(_ message: String, _ error: Error) {
    #if DEBUG
    print(message, error.localizedDescription)
    #endif
}
