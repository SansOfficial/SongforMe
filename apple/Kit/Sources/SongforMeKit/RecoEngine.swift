import Foundation

// 推荐算法本体：纯函数，不碰网络和数据库，方便单独测试和改。
//
// 思路分四步：
//   1. 喜爱度：由“我喜欢”+ 播放器记录的行为（听完 / 早早切歌 / 不喜欢 / 听腻了）算出每首歌的分
//   2. 口味画像：按喜爱度加权统计语种、流派、年代、歌手的分布
//   3. 候选打分：每首候选歌带着“它是怎么被找到的”证据，结合画像和可调权重打分
//   4. 选歌：过滤、去重、限制同一歌手数量，再混入一定比例的熟歌

public struct RecoSettings: Codable, Hashable, Sendable {
    /// 每批推荐多少首
    public var batchSize = 30
    /// 0 = 只要熟悉的歌手，1 = 尽量推没听过的歌手
    public var exploration = 0.5
    /// 0 = 不在乎新旧，1 = 明显偏向新发行的歌
    public var freshness = 0.2
    /// 0 = 偏向大众热门，1 = 偏向冷门
    public var obscurity = 0.5
    /// 0 = 不管我平时听什么语种 / 流派 / 年代，1 = 严格贴合
    public var tasteMatch = 0.6
    /// 每批里有多大比例是“已经喜欢、但很久没听”的熟歌，0~0.5
    public var familiarRatio = 0.2
    /// 同一歌手每批最多几首
    public var maxPerArtist = 2
    /// 只推这些语种（编号见 Languages）；nil 表示不限
    public var languages: [Int]?
    /// 推荐过的歌多少天内不再重复出现
    public var repeatCooldownDays = 14

    public init() {}

    /// 存下来的设置可能是旧版本的，缺的项用默认值
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RecoSettings()
        batchSize = try c.decodeIfPresent(Int.self, forKey: .batchSize) ?? d.batchSize
        exploration = try c.decodeIfPresent(Double.self, forKey: .exploration) ?? d.exploration
        freshness = try c.decodeIfPresent(Double.self, forKey: .freshness) ?? d.freshness
        obscurity = try c.decodeIfPresent(Double.self, forKey: .obscurity) ?? d.obscurity
        tasteMatch = try c.decodeIfPresent(Double.self, forKey: .tasteMatch) ?? d.tasteMatch
        familiarRatio = try c.decodeIfPresent(Double.self, forKey: .familiarRatio) ?? d.familiarRatio
        maxPerArtist = try c.decodeIfPresent(Int.self, forKey: .maxPerArtist) ?? d.maxPerArtist
        languages = try c.decodeIfPresent([Int].self, forKey: .languages)
        repeatCooldownDays = try c.decodeIfPresent(Int.self, forKey: .repeatCooldownDays) ?? d.repeatCooldownDays
    }
}

public struct SongAffinity: Sendable {
    /// >0 表示喜欢，可作为种子；<0 表示不喜欢
    public var score = 0.0
    /// 明确点了不喜欢：永不推荐
    public var blocked = false
    /// 听腻了：在这个时间之前不推荐
    public var coolUntil = 0.0
    public var lastPlayed = 0.0
    public var plays = 0
}

public struct TasteProfile: Sendable {
    public var language: [Int: Double] = [:]
    public var genre: [Int: Double] = [:]
    public var decade: [Int: Double] = [:]
    /// 歌手（Singer.key）→ 权重（已归一化，最喜欢的歌手为 1）
    public var artist: [String: Double] = [:]
    /// 被明确讨厌的歌手（Singer.key）→ 惩罚强度 0~1
    public var artistDislike: [String: Double] = [:]
    public var seedCount = 0
}

public struct Recommendation: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case new, familiar
    }

    public var song: Song
    public var score: Double
    public var kind: Kind
    public var id: String { song.mid }

    public init(song: Song, score: Double, kind: Kind) {
        self.song = song
        self.score = score
        self.kind = kind
    }
}

public struct RecoInput {
    public var songs: [String: Song]
    /// 有先后顺序，不重复
    public var likedMids: [String]
    public var events: [PlayEvent]
    public var evidence: [Evidence]
    /// 最近推荐过的歌 mid → 上次推荐时间
    public var recentlyRecommended: [String: Double]
    public var settings: RecoSettings
    public var now: Double
    /// 传入固定的随机源可以让结果可复现（测试用）
    public var random: RandomSource
    /// 现在放得了的歌才推荐（比如它的音源已经退出登录就不推）
    public var playable: (Song) -> Bool = { _ in true }

    public init(
        songs: [String: Song], likedMids: [String], events: [PlayEvent], evidence: [Evidence], recentlyRecommended: [String: Double] = [:],
        settings: RecoSettings, now: Double, random: @escaping RandomSource = { .random(in: 0..<1) }
    ) {
        self.songs = songs
        self.likedMids = likedMids
        self.events = events
        self.evidence = evidence
        self.recentlyRecommended = recentlyRecommended
        self.settings = settings
        self.now = now
        self.random = random
    }
}

public struct RecoResult: Sendable {
    public var items: [Recommendation]
    public var profile: TasteProfile
    /// 过滤前的候选总数，候选池太小时需要扩充
    public var candidateCount: Int
}

public enum RecoEngine {
    static let day = 86_400_000.0
    /// 行为的影响随时间减半的周期
    static let halfLifeDays = 180.0
    /// “听腻了”之后多久不再出现
    static let tiredCooldownDays = 45.0
    /// 播放不到这个比例就切歌，算作负反馈
    public static let earlySkipRatio = 0.3

    /// 第 1 步：每首歌的喜爱度
    public static func affinity(likedMids: [String], events: [PlayEvent], now: Double) -> OrderedMap<String, SongAffinity> {
        var out = OrderedMap<String, SongAffinity>()
        for mid in likedMids { out[mid, default: SongAffinity()].score += 1 }

        for e in events.sorted(by: { $0.ts < $1.ts }) {
            let w = pow(0.5, max(0, now - e.ts) / (halfLifeDays * day))
            var a = out[e.mid, default: SongAffinity()]
            switch e.type {
            case .play:
                a.plays += 1
                a.lastPlayed = max(a.lastPlayed, e.ts)
            case .complete:
                a.score += 0.3 * w
            case .skip:
                // 只有推荐队列里的早切才算负反馈；在自己的歌单里翻找时切歌不代表不喜欢
                if e.ratio < earlySkipRatio, e.source == .reco { a.score -= 0.4 * w }
            case .like:
                a.score += 1
                a.blocked = false
            case .unlike:
                a.score -= 1
            case .dislike:
                a.blocked = true
                a.score -= 2
            case .tired:
                a.coolUntil = max(a.coolUntil, e.ts + tiredCooldownDays * day)
            }
            out[e.mid, default: SongAffinity()] = a
        }
        out.updateEach { $0.score = max(-3, min(3, $0.score)) }
        return out
    }

    static func decade(of publishTime: String) -> Int? {
        guard let year = Int(publishTime.prefix(4)), year > 1900 else { return nil }
        return year / 10 * 10
    }

    /// 发行日期的毫秒时间戳（按 UTC 零点）
    static func published(_ text: String) -> Double? {
        let parts = text.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]), (1...12).contains(m), (1...31).contains(d) else { return nil }
        // 公历日期换算成距 1970-01-01 的天数
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return Double(era * 146_097 + doe - 719_468) * day
    }

    private static func normalized<K>(_ m: [K: Double]) -> [K: Double] {
        let top = m.values.max() ?? 0
        return top > 0 ? m.mapValues { $0 / top } : [:]
    }

    /// 第 2 步：口味画像
    public static func profile(songs: [String: Song], affinity: OrderedMap<String, SongAffinity>) -> TasteProfile {
        var p = TasteProfile()
        var artist: [String: Double] = [:]
        var disliked: [String: Double] = [:]
        for (mid, a) in affinity.pairs {
            guard let s = songs[mid] else { continue }
            if a.score > 0 {
                p.seedCount += 1
                p.language[s.language, default: 0] += a.score
                p.genre[s.genre, default: 0] += a.score
                if let d = decade(of: s.publishTime) { p.decade[d, default: 0] += a.score }
                for sg in s.singers { artist[sg.key, default: 0] += a.score }
            } else if a.score < 0 {
                for sg in s.singers { disliked[sg.key, default: 0] -= a.score }
            }
        }
        for (k, v) in disliked {
            // 同一歌手累计负反馈足够多、且没有与之相当的正反馈时才算讨厌这个歌手
            let net = v - (artist[k] ?? 0)
            if net >= 1.5 { p.artistDislike[k] = min(1, net / 4) }
        }
        p.language = normalized(p.language)
        p.genre = normalized(p.genre)
        p.decade = normalized(p.decade)
        // 用开方压一压，避免某个歌手的歌特别多时把画像完全带偏
        p.artist = normalized(artist.mapValues { $0.squareRoot() })
        return p
    }

    /// 同一首歌常有多个版本（原版、Live、DJ 版、不同专辑收录），编号各不相同。
    /// 用“去掉括号内容的歌名 + 第一位歌手”当作同一首歌的标识，用来去重。
    public static func workKey(_ song: Song) -> String {
        let open: Set<Character> = ["（", "(", "【", "["]
        let close: Set<Character> = ["）", ")", "】", "]"]
        let chars = Array(song.name)
        var name = ""
        var i = 0
        while i < chars.count {
            if open.contains(chars[i]), let j = chars[(i + 1)...].firstIndex(where: close.contains) {
                i = j + 1
                continue
            }
            if !chars[i].isWhitespace { name.append(chars[i]) }
            i += 1
        }
        name = name.lowercased()
        return "\(name.isEmpty ? song.name : name)|\(song.singers.first?.key ?? "")"
    }

    private static func weight(_ via: Evidence.Via) -> Double {
        switch via {
        case .similar: 1
        case .playlist: 0.6
        case .singer: 0.4
        }
    }

    private struct Aggregate {
        var raw = 0.0
        var playlists: Set<String> = []
    }

    /// 第 3、4 步：给候选打分并选出一批
    public static func recommend(_ input: RecoInput) -> RecoResult {
        let (songs, settings, now, random) = (input.songs, input.settings, input.now, input.random)
        let liked = Set(input.likedMids)
        let affinity = affinity(likedMids: input.likedMids, events: input.events, now: now)
        let profile = profile(songs: songs, affinity: affinity)

        // 把证据按候选歌聚合
        var aggs = OrderedMap<String, Aggregate>()
        for e in input.evidence {
            let seedScore = affinity[e.seed]?.score ?? 0
            if seedScore <= 0 { continue } // 种子歌已经不被喜欢了，这条证据作废
            aggs[e.mid, default: Aggregate()].raw += weight(e.via) * min(seedScore, 2)
            if e.via == .playlist { aggs[e.mid, default: Aggregate()].playlists.insert(e.ref) }
        }

        // 热门程度的近似：一首歌被越多不同的公开歌单收录，就越大众
        let maxPlaylists = max(1, aggs.values.map(\.playlists.count).max() ?? 1)

        // 已经喜欢或听过的歌（含它们的其他版本），不再当作“新歌”推荐；它们走“熟歌”通道
        var knownWorks: Set<String> = []
        for mid in input.likedMids { if let s = songs[mid] { knownWorks.insert(workKey(s)) } }
        for (mid, a) in affinity.pairs where a.plays > 0 { if let s = songs[mid] { knownWorks.insert(workKey(s)) } }

        let allowed = { (s: Song) in input.playable(s) && (settings.languages?.contains(s.language) ?? true) }
        var scored: [Recommendation] = []

        for (mid, g) in aggs.pairs {
            guard let song = songs[mid] else { continue }
            let a = affinity[mid]
            if let a, a.blocked || a.coolUntil > now { continue }
            if liked.contains(mid) || (a?.plays ?? 0) > 0 || knownWorks.contains(workKey(song)) { continue }
            if !allowed(song) { continue }
            if let last = input.recentlyRecommended[mid], last > 0, now - last < Double(settings.repeatCooldownDays) * day { continue }

            let relate = 1 - exp(-g.raw / 2)
            let known = song.singers.reduce(0.0) { max($0, profile.artist[$1.key] ?? 0) }
            let artist = (1 - settings.exploration) * known + settings.exploration * (1 - known)
            let d = decade(of: song.publishTime)
            let taste = 0.5 * (profile.language[song.language] ?? 0)
                + 0.25 * (profile.genre[song.genre] ?? 0)
                + 0.25 * (d.flatMap { profile.decade[$0] } ?? 0)
            let fresh = published(song.publishTime).map { exp(-max(0, now - $0) / (365 * day)) } ?? 0
            let rarity = 1 - log1p(Double(g.playlists.count)) / log1p(Double(maxPlaylists))

            var penalty = 0.0
            if let a, a.score < 0 { penalty += -a.score * 0.5 } // 这首歌自己被切过
            penalty += song.singers.reduce(0.0) { max($0, profile.artistDislike[$1.key] ?? 0) } * 0.8

            let base = relate
                + 0.6 * artist
                + 0.6 * settings.tasteMatch * taste
                + 0.8 * settings.freshness * fresh
                // 以 0.5 为中点：往右偏冷门，往左偏热门
                + 0.6 * (settings.obscurity - 0.5) * 2 * (rarity - 0.5)
                - penalty
            // 加一点随机扰动，让每一批不会一模一样
            scored.append(Recommendation(song: song, score: base * (1 + 0.12 * (random() - 0.5)), kind: .new))
        }
        scored.sort { $0.score > $1.score }

        let familiarCount = (Double(settings.batchSize) * min(0.5, max(0, settings.familiarRatio))).jsRounded
        let newCount = settings.batchSize - familiarCount

        var perArtist: [String: Int] = [:]
        var pickedWorks: Set<String> = []
        func take(_ list: [Recommendation], _ n: Int) -> [Recommendation] {
            var picked: [Recommendation] = []
            for r in list {
                if picked.count >= n { break }
                let work = workKey(r.song)
                if pickedWorks.contains(work) { continue } // 同一首歌的另一个版本
                if r.song.singers.contains(where: { (perArtist[$0.key] ?? 0) >= settings.maxPerArtist }) { continue }
                pickedWorks.insert(work)
                for s in r.song.singers { perArtist[s.key, default: 0] += 1 }
                picked.append(r)
            }
            return picked
        }

        let fresh = take(scored, newCount)
        let familiar = take(familiarPool(songs: songs, liked: liked, affinity: affinity, now: now, allowed: allowed, random: random), familiarCount)
        return RecoResult(items: interleave(fresh, familiar), profile: profile, candidateCount: aggs.count)
    }

    /// 熟歌通道：已经喜欢、或者反复听过的歌里，很久没听的那些；越久没听越靠前
    private static func familiarPool(
        songs: [String: Song], liked: Set<String>, affinity: OrderedMap<String, SongAffinity>, now: Double, allowed: (Song) -> Bool, random: RandomSource
    ) -> [Recommendation] {
        var out: [Recommendation] = []
        for (mid, a) in affinity.pairs {
            // 没点过喜欢的歌，要有足够的正反馈（大致相当于完整听过两三次）才算常听
            guard let song = songs[mid], !a.blocked, a.coolUntil <= now, a.score >= (liked.contains(mid) ? 0.01 : 0.5), allowed(song) else { continue }
            let idleDays = a.lastPlayed > 0 ? (now - a.lastPlayed) / day : 365
            if idleDays < 7 { continue }
            out.append(Recommendation(song: song, score: min(1, idleDays / 180) + 0.3 * a.score + 0.5 * random(), kind: .familiar))
        }
        return out.sorted { $0.score > $1.score }
    }

    /// 把熟歌均匀地插进新歌里，而不是堆在最后
    private static func interleave(_ fresh: [Recommendation], _ familiar: [Recommendation]) -> [Recommendation] {
        if familiar.isEmpty { return fresh }
        var out: [Recommendation] = []
        let step = max(1, fresh.count / familiar.count)
        var f = 0
        for (i, r) in fresh.enumerated() {
            out.append(r)
            if (i + 1) % step == 0, f < familiar.count {
                out.append(familiar[f])
                f += 1
            }
        }
        out += familiar[f...]
        return out
    }

    /// 选哪些歌作为种子去扩充候选池：喜爱度高、最近有正反馈的优先，
    /// 已经扩充过的往后排，保证候选池随着使用逐渐覆盖整个曲库口味。
    public static func pickSeeds(
        _ affinity: OrderedMap<String, SongAffinity>, expandedAt: [String: Double], count: Int, now: Double, random: RandomSource = { .random(in: 0..<1) }
    ) -> [String] {
        var ranked: [(mid: String, rank: Double)] = []
        for (mid, a) in affinity.pairs where a.score > 0 && !a.blocked {
            let staleness = expandedAt[mid].map { min(1, (now - $0) / (30 * day)) } ?? 1.5
            ranked.append((mid, a.score * staleness * (0.5 + random())))
        }
        return ranked.sorted { $0.rank > $1.rank }.prefix(count).map(\.mid)
    }
}
