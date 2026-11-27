import Foundation

// 推荐算法本体：纯函数，不碰网络和数据库，方便单独测试和改。
//
// 思路分四步：
//   1. 喜爱度：由“我喜欢”+ 播放器记录的行为（听完 / 早早切歌 / 不喜欢 / 听腻了）算出每首歌的分
//   2. 口味画像：按喜爱度加权统计语种、流派、年代、歌手的分布
//   3. 候选打分：每首候选歌带着“它是怎么被找到的”证据，结合画像和可调权重打分；
//      推荐出去的歌后来被喜欢还是被嫌弃，会反过来调整当初找到它的那个歌单 / 相似列表的可信度
//   4. 选歌：过滤、去重、限制同一歌手数量，按“探索”分好陌生歌手和熟悉歌手的名额，再混入一定比例的熟歌
//
// 改动前后用 Tests/SongforMeKitTests/RecoEvalTests.swift 在真实曲库的拷贝上比一比。

public struct RecoSettings: Codable, Hashable, Sendable {
    /// 每批推荐多少首
    public var batchSize = 30
    /// 每批新歌里留给没怎么听过的歌手的比例：0 = 只要熟悉的歌手，1 = 尽量推没听过的歌手
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
    /// 这些歌即使刚推荐过也照样参与（重排当前这一批时用）
    public var keep: Set<String> = []
    /// 给了就按歌算固定的随机扰动：同一批推荐重排时，没受影响的歌名次不乱跳
    public var seed: UInt64?
    var tuning = RecoTuning()

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

/// 算法内部的几个系数，平时不用动；离线评估时拿来对比各项改动的效果
struct RecoTuning: Sendable {
    /// 按推荐出去的歌的结果调整每个歌单 / 相似列表的可信度
    var reliability = true
    /// 用名额而不是加分来实现“探索”
    var quota = true
    /// 名额模式下熟悉歌手的加分
    var artistWeight = 0.6
    /// 熟悉程度低于这个值算陌生歌手
    var unknownBelow = 0.2
    /// 口味里语种、流派、年代各占多少
    var language = 0.5, genre = 0.1, decade = 0.4
    /// 很少听的特殊版本扣多少分
    var version = 0.4
    /// 一个公开歌单对一首歌只算一票（以前里面有几首你喜欢的歌就算几票，几百首的热歌合集能把整张单子顶上来），
    /// 而且歌单越大这一票越轻
    var listVote = true
    /// 不超过这么多首的歌单，这一票算满
    var listFull = 100.0
    /// 陌生歌手的推荐总被嫌弃时，自动少给陌生歌手名额
    var adaptExplore = true
    /// 挑陌生歌手时，被越多公开歌单收录的（成名歌手）越靠前，少挑只火了一首的网络歌
    var depth = 0.3

    /// 改动之前的算法
    static let baseline = RecoTuning(
        reliability: false, quota: false, language: 0.5, genre: 0.25, decade: 0.25, version: 0, listVote: false, adaptExplore: false, depth: 0
    )

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

    // MARK: 版本类型

    /// 歌名里看得出来的特殊版本
    enum Version: CaseIterable, Sendable {
        case live, remix, cover, instrumental, altered
    }

    private static let versionPatterns: [(Version, NSRegularExpression)] = ([
        (.live, #"\blive\b|现场|演唱会|音乐会"#),
        (.remix, #"\bdj\b|dj版|remix|混音|电音|\bedm\b|摇滚版"#),
        (.cover, #"翻唱|翻自|\bcover\b|原唱[:：]"#),
        (.instrumental, #"伴奏|纯音乐|\binstrumental\b|\binst\.?\b|钢琴版|吉他版|八音盒|music box|\bkaraoke\b"#),
        (.altered, #"\d(\.\d+)?x\b|倍速|加速|降调|升调|慢速|变速|\bsped up\b|\bslowed\b|女版|男版|抖音|片段|精简版|\bremaster"#),
    ] as [(Version, String)]).map { ($0.0, try! NSRegularExpression(pattern: $0.1, options: [.caseInsensitive])) }

    static func versions(of name: String) -> Set<Version> {
        let range = NSRange(name.startIndex..., in: name)
        return Set(versionPatterns.filter { $0.1.firstMatch(in: name, range: range) != nil }.map(\.0))
    }

    // MARK: 来源靠谱度

    /// 推荐出去的歌后来怎么样了：点喜欢 / 听完是好结果，点不喜欢 / 很快切掉是坏结果
    static func outcomes(_ events: [PlayEvent]) -> [String: Double] {
        var out: [String: Double] = [:]
        for e in events {
            switch e.type {
            case .like: out[e.mid, default: 0] += 1
            case .unlike: out[e.mid, default: 0] -= 1
            case .dislike: out[e.mid, default: 0] -= 1.5
            case .complete where e.source == .reco: out[e.mid, default: 0] += 0.15
            case .skip where e.source == .reco && e.ratio < earlySkipRatio: out[e.mid, default: 0] -= 0.6
            default: break
            }
        }
        return out
    }

    /// 证据来自哪里：某个公开歌单，或者某首歌的“相似歌曲”
    static func origin(_ e: Evidence) -> String { e.via == .playlist ? "p:\(e.ref)" : "\(e.via.rawValue):\(e.seed)" }

    /// 每个来源推荐过的歌的结果合在一起，好结果多就更信它，坏结果多就少信
    static func reliability(evidence: [Evidence], outcomes: [String: Double]) -> [String: Double] {
        var pos: [String: Double] = [:], neg: [String: Double] = [:]
        var seen: Set<String> = []
        for e in evidence {
            guard let o = outcomes[e.mid], o != 0 else { continue }
            let key = origin(e)
            guard seen.insert("\(e.mid)|\(key)").inserted else { continue }
            if o > 0 { pos[key, default: 0] += o } else { neg[key, default: 0] -= o }
        }
        var out: [String: Double] = [:]
        for key in Set(pos.keys).union(neg.keys) {
            out[key] = min(2, max(0.25, (2 + (pos[key] ?? 0)) / (2 + (neg[key] ?? 0))))
        }
        return out
    }

    // MARK: 打分

    /// 打分要用到的东西，一次算好；单独拿出来是为了离线评估能直接给任意一首歌打分
    struct Model {
        var settings: RecoSettings
        var tuning: RecoTuning
        var now: Double
        var affinity: OrderedMap<String, SongAffinity>
        var profile: TasteProfile
        /// 候选歌 → 证据强度
        var raw: OrderedMap<String, Double>
        /// 候选歌 → 被多少个公开歌单收录
        var playlistCount: [String: Int]
        var maxPlaylists: Int
        /// 喜欢的歌里各种特殊版本占多少
        var versionShare: [Version: Double]
        /// 歌手（Singer.key）→ 被多少个公开歌单收录过
        var artistLists: [String: Int]
        /// 探索名额打几折：陌生歌手的推荐结果比熟悉歌手的差得越多，给得越少
        var exploreFactor = 1.0

        init(_ input: RecoInput) {
            settings = input.settings
            tuning = input.tuning
            now = input.now
            affinity = RecoEngine.affinity(likedMids: input.likedMids, events: input.events, now: input.now)
            profile = RecoEngine.profile(songs: input.songs, affinity: affinity)
            let trust = tuning.reliability ? RecoEngine.reliability(evidence: input.evidence, outcomes: outcomes(input.events)) : [:]

            var raw = OrderedMap<String, Double>()
            var lists: [String: Set<String>] = [:]
            /// （歌，歌单）→ 这个歌单里你喜欢的歌加起来多少分；歌单 → 收了多少首候选
            var votes = OrderedMap<Pair, Double>()
            var listSize: [String: Set<String>] = [:]
            for e in input.evidence {
                let seedScore = affinity[e.seed]?.score ?? 0
                if seedScore <= 0 { continue } // 种子歌已经不被喜欢了，这条证据作废
                if e.via == .playlist { lists[e.mid, default: []].insert(e.ref) }
                if tuning.listVote, e.via == .playlist {
                    votes[Pair(mid: e.mid, ref: e.ref), default: 0] += min(seedScore, 2)
                    listSize[e.ref, default: []].insert(e.mid)
                    raw[e.mid, default: 0] += 0 // 先占住先后顺序
                } else {
                    raw[e.mid, default: 0] += weight(e.via) * min(seedScore, 2) * (trust[origin(e)] ?? 1)
                }
            }
            for (k, v) in votes.pairs {
                let size = Double(listSize[k.ref]?.count ?? 1)
                raw[k.mid, default: 0] += weight(.playlist) * min(v, 2) * min(1, (tuning.listFull / size).squareRoot()) * (trust["p:\(k.ref)"] ?? 1)
            }
            self.raw = raw
            playlistCount = lists.mapValues(\.count)
            maxPlaylists = max(1, playlistCount.values.max() ?? 1)

            var share: [Version: Double] = [:]
            var total = 0.0
            for (mid, a) in affinity.pairs where a.score > 0 {
                guard let s = input.songs[mid] else { continue }
                total += 1
                for v in versions(of: s.name) { share[v, default: 0] += 1 }
            }
            versionShare = total > 0 ? share.mapValues { $0 / total } : [:]

            var artistRefs: [String: Set<String>] = [:]
            for e in input.evidence where e.via == .playlist {
                for g in input.songs[e.mid]?.singers ?? [] { artistRefs[g.key, default: []].insert(e.ref) }
            }
            artistLists = artistRefs.mapValues(\.count)

            if tuning.adaptExplore {
                // 推荐出去的歌按歌手熟不熟分两边，各自算“好结果 / 坏结果”的比值
                var pos = [0.0, 0.0], neg = [0.0, 0.0]
                for (mid, o) in outcomes(input.events.filter { $0.source == .reco || $0.type == .dislike }) {
                    guard let song = input.songs[mid] else { continue }
                    let i = known(song) < tuning.unknownBelow ? 1 : 0
                    if o > 0 { pos[i] += o } else { neg[i] -= o }
                }
                let rate = { (i: Int) in (2 + pos[i]) / (2 + neg[i]) }
                exploreFactor = min(1, max(0.15, rate(1) / rate(0)))
            }
        }

        /// 歌手有多“成名”：被多少个公开歌单收录，0~1
        func depth(_ song: Song) -> Double {
            let n = song.singers.map { artistLists[$0.key] ?? 0 }.max() ?? 0
            return min(1, log1p(Double(n)) / log1p(15))
        }

        struct Pair: Hashable { var mid, ref: String }

        /// 这首歌在多大程度上是“熟悉的歌手”，0~1
        func known(_ song: Song) -> Double { song.singers.reduce(0.0) { max($0, profile.artist[$1.key] ?? 0) } }

        /// 不做任何过滤的分数；没有证据的歌返回 nil
        func score(_ song: Song) -> Double? {
            guard let raw = raw[song.mid] else { return nil }
            let (t, settings) = (tuning, settings)
            let relate = 1 - exp(-raw / 2)
            let known = known(song)
            let artist = t.quota ? t.artistWeight * known
                : 0.6 * ((1 - settings.exploration) * known + settings.exploration * (1 - known))
            let d = decade(of: song.publishTime)
            let taste = t.language * (profile.language[song.language] ?? 0)
                + t.genre * (profile.genre[song.genre] ?? 0)
                + t.decade * (d.flatMap { profile.decade[$0] } ?? 0)
            let fresh = published(song.publishTime).map { exp(-max(0, now - $0) / (365 * day)) } ?? 0
            let rarity = 1 - log1p(Double(playlistCount[song.mid] ?? 0)) / log1p(Double(maxPlaylists))

            var penalty = 0.0
            if let a = affinity[song.mid], a.score < 0 { penalty += -a.score * 0.5 } // 这首歌自己被切过
            penalty += song.singers.reduce(0.0) { max($0, profile.artistDislike[$1.key] ?? 0) } * 0.8
            // 你很少听 Live、DJ、伴奏之类的版本，就少推这些
            for v in versions(of: song.name) { penalty += t.version * max(0, 1 - (versionShare[v] ?? 0) / 0.05) }

            return relate
                + artist
                + 0.6 * settings.tasteMatch * taste
                + 0.8 * settings.freshness * fresh
                // 以 0.5 为中点：往右偏冷门，往左偏热门
                + 0.6 * (settings.obscurity - 0.5) * 2 * (rarity - 0.5)
                - penalty
        }
    }

    /// 第 3、4 步：给候选打分并选出一批
    public static func recommend(_ input: RecoInput) -> RecoResult {
        let (songs, settings, now) = (input.songs, input.settings, input.now)
        let noise = { (mid: String) in input.seed.map { RecoEngine.noise(mid, $0) } ?? input.random() }
        let liked = Set(input.likedMids)
        let model = Model(input)
        let affinity = model.affinity

        // 已经喜欢或听过的歌（含它们的其他版本），不再当作“新歌”推荐；它们走“熟歌”通道
        var knownWorks: Set<String> = []
        for mid in input.likedMids { if let s = songs[mid] { knownWorks.insert(workKey(s)) } }
        for (mid, a) in affinity.pairs where a.plays > 0 { if let s = songs[mid] { knownWorks.insert(workKey(s)) } }

        let allowed = { (s: Song) in input.playable(s) && (settings.languages?.contains(s.language) ?? true) }
        var scored: [Recommendation] = []

        for mid in model.raw.keys {
            guard let song = songs[mid] else { continue }
            let a = affinity[mid]
            if let a, a.blocked || a.coolUntil > now { continue }
            if liked.contains(mid) || (a?.plays ?? 0) > 0 || knownWorks.contains(workKey(song)) { continue }
            if !allowed(song) { continue }
            if !input.keep.contains(mid), let last = input.recentlyRecommended[mid], last > 0, now - last < Double(settings.repeatCooldownDays) * day { continue }
            guard let base = model.score(song) else { continue }
            // 加一点随机扰动，让每一批不会一模一样
            scored.append(Recommendation(song: song, score: base * (1 + 0.12 * (noise(mid) - 0.5)), kind: .new))
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

        var fresh: [Recommendation]
        if input.tuning.quota {
            // “探索”决定这一批里有多少名额留给没怎么听过的歌手，其余给熟悉的歌手；哪边不够就用另一边补
            let explore = (Double(newCount) * min(1, max(0, settings.exploration)) * model.exploreFactor).jsRounded
            let isNew = { (r: Recommendation) in model.known(r.song) < input.tuning.unknownBelow }
            let familiarArtists = take(scored.filter { !isNew($0) }, newCount - explore)
            // 陌生歌手里先挑成名歌手的歌
            let unknown = scored.filter(isNew).map { ($0, $0.score + input.tuning.depth * model.depth($0.song)) }
            let newArtists = take(unknown.sorted { $0.1 > $1.1 }.map(\.0), explore)
            fresh = blend(familiarArtists, newArtists)
            fresh += take(scored, newCount - fresh.count)
        } else {
            fresh = take(scored, newCount)
        }
        let familiar = take(familiarPool(songs: songs, liked: liked, affinity: affinity, now: now, allowed: allowed, noise: noise), familiarCount)
        return RecoResult(items: interleave(fresh, familiar), profile: model.profile, candidateCount: model.raw.count)
    }

    /// 由歌和种子决定的 0~1 之间的数
    static func noise(_ mid: String, _ seed: UInt64) -> Double {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325 ^ seed
        for b in mid.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        h ^= h >> 33
        h &*= 0xff51_afd7_ed55_8ccd
        h ^= h >> 33
        return Double(h >> 11) / Double(UInt64(1) << 53)
    }

    /// 按各自的长度比例交错合并两列，保持各自内部的先后
    static func blend<T>(_ a: [T], _ b: [T]) -> [T] {
        var out: [T] = []
        var (i, j) = (0, 0)
        while i < a.count || j < b.count {
            let useA = j >= b.count || (i < a.count && (Double(i) + 0.5) / Double(a.count) <= (Double(j) + 0.5) / Double(b.count))
            if useA { out.append(a[i]); i += 1 } else { out.append(b[j]); j += 1 }
        }
        return out
    }

    /// 熟歌通道：已经喜欢、或者反复听过的歌里，很久没听的那些；越久没听越靠前
    private static func familiarPool(
        songs: [String: Song], liked: Set<String>, affinity: OrderedMap<String, SongAffinity>, now: Double, allowed: (Song) -> Bool, noise: (String) -> Double
    ) -> [Recommendation] {
        var out: [Recommendation] = []
        for (mid, a) in affinity.pairs {
            // 没点过喜欢的歌，要有足够的正反馈（大致相当于完整听过两三次）才算常听
            guard let song = songs[mid], !a.blocked, a.coolUntil <= now, a.score >= (liked.contains(mid) ? 0.01 : 0.5), allowed(song) else { continue }
            let idleDays = a.lastPlayed > 0 ? (now - a.lastPlayed) / day : 365
            if idleDays < 7 { continue }
            out.append(Recommendation(song: song, score: min(1, idleDays / 180) + 0.3 * a.score + 0.5 * noise(mid), kind: .familiar))
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
