import Foundation
import Testing
@testable import SongforMeKit

// 离线评估：拿一份真实曲库的拷贝，看算法改动是让推荐变好了还是变差了。
// 平时不跑；指定曲库拷贝的路径才会跑（不要直接指向正在用的曲库）：
//   SONGFORME_EVAL_DB=/path/to/copy/library.sqlite swift test --filter RecoEval
//
// 两个指标：
//   推荐结果  推荐出去的歌里，后来点了喜欢的是不是比点了不喜欢 / 很快切掉的分更高（AUC，0.5 等于瞎猜）
//   藏起来的喜欢  把“我喜欢”分成 5 份，每次藏起一份，看藏起来的歌在候选里排多靠前
//                （这个指标偏爱热门歌，只用来确认口味没跑偏）

private let evalDB = ProcessInfo.processInfo.environment["SONGFORME_EVAL_DB"]

@Suite("离线评估", .enabled(if: evalDB != nil))
struct RecoEval {
    struct Data {
        var songs: [String: Song]
        var liked: [String]
        var events: [PlayEvent]
        var accountEvents: [PlayEvent]
        var evidence: [Evidence]
        var settings: RecoSettings
    }

    static func load() async throws -> Data {
        let store = try Store(path: evalDB!)
        var accountEvents: [PlayEvent] = []
        // 和 Library.allEvents 一样，把各个音源账号里的播放次数换算成行为
        var plays: [String: Library.AccountPlay] = [:]
        for key in try await store.keys(prefix: "accountPlays:") {
            plays.merge(try await store.get(key, as: [String: Library.AccountPlay].self) ?? [:]) { a, _ in a }
        }
        for (mid, p) in plays.sorted(by: { $0.key < $1.key }) {
            accountEvents.append(PlayEvent(mid: mid, type: .play, ratio: 0, source: .library, ts: p.last))
            let positives = p.count < 2 ? 0 : min(8, (1.7 * log(p.count)).jsRounded)
            for _ in 0..<positives { accountEvents.append(PlayEvent(mid: mid, type: .complete, ratio: 1, source: .library, ts: p.last)) }
        }
        return Data(
            songs: Dictionary(try await store.allSongs().map { ($0.mid, $0) }, uniquingKeysWith: { $1 }),
            liked: try await store.likedMids(), events: try await store.events(), accountEvents: accountEvents,
            evidence: try await store.evidence(), settings: try await store.get("settings", as: RecoSettings.self) ?? RecoSettings()
        )
    }

    static func auc(_ pos: [Double], _ neg: [Double]) -> Double {
        guard !pos.isEmpty, !neg.isEmpty else { return .nan }
        var wins = 0.0
        for p in pos { for n in neg { wins += p > n ? 1 : p == n ? 0.5 : 0 } }
        return wins / Double(pos.count * neg.count)
    }

    enum Label { case good, okay, bad }

    /// 每首推荐出去的歌最后的结果：不喜欢 > 喜欢 > 很快切掉 > 听完
    static func labels(_ d: Data) -> [(mid: String, label: Label, ts: Double)] {
        var out: [String: (Label, Double, Int)] = [:]
        func put(_ mid: String, _ l: Label, _ ts: Double, _ rank: Int) {
            if let old = out[mid], old.2 >= rank { return }
            out[mid] = (l, ts, rank)
        }
        for e in d.events.sorted(by: { $0.ts < $1.ts }) {
            switch e.type {
            case .dislike: put(e.mid, .bad, e.ts, 4)
            case .like where e.source == .reco: put(e.mid, .good, e.ts, 3)
            case .skip where e.source == .reco && e.ratio < RecoEngine.earlySkipRatio: put(e.mid, .bad, e.ts, 2)
            case .complete where e.source == .reco: put(e.mid, .okay, e.ts, 1)
            default: break
            }
        }
        return out.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.ts < $1.ts }
    }

    /// 某个时刻之前能看到的输入
    static func input(_ d: Data, before t: Double, hiding: Set<String>, tuning: RecoTuning) -> RecoInput {
        var likedAt: [String: Double] = [:]
        for e in d.events where e.type == .like { likedAt[e.mid] = min(likedAt[e.mid] ?? .infinity, e.ts) }
        let liked = d.liked.filter { !hiding.contains($0) && (likedAt[$0] ?? 0) < t }
        let events = d.accountEvents.filter { !hiding.contains($0.mid) } + d.events.filter { $0.ts < t && !hiding.contains($0.mid) }
        var input = RecoInput(songs: d.songs, likedMids: liked, events: events, evidence: d.evidence, settings: d.settings, now: min(t, NOW_EVAL))
        input.tuning = tuning
        return input
    }

    static let NOW_EVAL = Date().timeIntervalSince1970 * 1000

    struct Result {
        var goodBad = 0.0, okayBad = 0.0, goodOkay = 0.0
        var heldAUC = 0.0, recall100 = 0.0
        var topPlaylists = 0.0, topDecades: [Int: Int] = [:], topVersions = 0
    }

    static func evaluate(_ d: Data, _ tuning: RecoTuning) -> Result {
        var r = Result()
        var scores: [Label: [Double]] = [:]
        for (mid, label, ts) in labels(d) {
            guard let song = d.songs[mid] else { continue }
            let model = RecoEngine.Model(input(d, before: ts, hiding: [mid], tuning: tuning))
            guard let s = model.score(song) else { continue }
            scores[label, default: []].append(s)
        }
        r.goodBad = auc(scores[.good] ?? [], scores[.bad] ?? [])
        r.okayBad = auc(scores[.okay] ?? [], scores[.bad] ?? [])
        r.goodOkay = auc(scores[.good] ?? [], scores[.okay] ?? [])

        var aucs: [Double] = []
        var (hit, total) = (0, 0)
        for fold in 0..<5 {
            // 按“同一首歌”分份：曲库里同一首歌可能有新旧两个编号，要一起藏
            let work = { (mid: String) in d.songs[mid].map(RecoEngine.workKey) ?? mid }
            let hidden = Set(d.liked.filter { work($0).unicodeScalars.reduce(0) { $0 + Int($1.value) } % 5 == fold })
            let model = RecoEngine.Model(input(d, before: .infinity, hiding: hidden, tuning: tuning))
            let liked = Set(d.liked).subtracting(hidden)
            let knownWorks = Set(liked.compactMap { d.songs[$0].map(RecoEngine.workKey) })
            var ranked: [(mid: String, score: Double)] = []
            for mid in model.raw.keys {
                guard let song = d.songs[mid], !liked.contains(mid), (model.affinity[mid]?.plays ?? 0) == 0,
                      !knownWorks.contains(RecoEngine.workKey(song)), d.settings.languages?.contains(song.language) ?? true,
                      let s = model.score(song) else { continue }
                ranked.append((mid, s))
            }
            ranked.sort { $0.score > $1.score }
            let pos = ranked.filter { hidden.contains($0.mid) }.map(\.score)
            let neg = ranked.filter { !hidden.contains($0.mid) }.map(\.score)
            aucs.append(auc(pos, neg))
            hit += ranked.prefix(100).filter { hidden.contains($0.mid) }.count
            total += pos.count
            if fold == 0 {
                let top = ranked.filter { !hidden.contains($0.mid) }.prefix(100)
                r.topPlaylists = Double(top.map { model.playlistCount[$0.mid] ?? 0 }.reduce(0, +)) / Double(max(1, top.count))
                for t in top {
                    guard let s = d.songs[t.mid] else { continue }
                    if let dec = RecoEngine.decade(of: s.publishTime) { r.topDecades[dec, default: 0] += 1 }
                    if !RecoEngine.versions(of: s.name).isEmpty { r.topVersions += 1 }
                }
            }
        }
        r.heldAUC = aucs.reduce(0, +) / Double(aucs.count)
        r.recall100 = Double(hit) / Double(max(1, total))
        return r
    }

    @Test("各项改动的效果")
    func report() async throws {
        let d = try await Self.load()
        let counts = Dictionary(grouping: Self.labels(d), by: \.label).mapValues(\.count)
        print("样本：喜欢 \(counts[.good] ?? 0)，听完 \(counts[.okay] ?? 0)，不喜欢或很快切掉 \(counts[.bad] ?? 0)；我喜欢 \(d.liked.count) 首")

        var configs: [(String, RecoTuning)] = [("改之前", .baseline)]
        func with(_ name: String, _ f: (inout RecoTuning) -> Void) {
            var t = RecoTuning.baseline
            f(&t)
            configs.append((name, t))
        }
        with("+来源靠谱度") { $0.reliability = true }
        with("+版本类型") { $0.version = 0.4 }
        with("+年代加重") { $0.genre = 0.1; $0.decade = 0.4 }
        with("+探索改名额") { $0.quota = true }
        with("+歌单一票") { $0.listVote = true }
        configs.append(("全部", RecoTuning()))
        func without(_ name: String, _ f: (inout RecoTuning) -> Void) {
            var t = RecoTuning()
            f(&t)
            configs.append((name, t))
        }
        without("全部−来源靠谱度") { $0.reliability = false }
        without("全部−探索改名额") { $0.quota = false }
        without("全部−年代加重") { $0.genre = 0.25; $0.decade = 0.25 }
        without("全部−歌单一票") { $0.listVote = false }
        // 例：SONGFORME_EVAL_GRID="decade=0.3;listVote=1,playSeed=0.5"，分号隔开几组，每组里逗号隔开几项
        for group in (ProcessInfo.processInfo.environment["SONGFORME_EVAL_GRID"] ?? "").split(separator: ";") {
            var t = RecoTuning()
            for v in group.split(separator: ",").map({ $0.split(separator: "=") }) where v.count == 2 {
                let (k, x) = (v[0], Double(v[1]) ?? 0)
                switch k {
                case "decade": t.decade = x
                case "version": t.version = x
                case "artist": t.artistWeight = x
                case "listVote": t.listVote = x > 0
                case "listFull": t.listVote = true; t.listFull = x
                case "adapt": t.adaptExplore = x > 0
                case "depth": t.depth = x
                default: continue
                }
            }
            configs.append(("全部 \(group)", t))
        }

        func f(_ x: Double) -> String { String(format: "%.3f", x) }
        print("配置\t喜欢>差\t听完>差\t喜欢>听完\t藏起AUC\t藏起@100\tTop100 收录数\t特殊版本\t年代分布")
        for (name, t) in configs {
            let r = Self.evaluate(d, t)
            let dec = r.topDecades.sorted { $0.key < $1.key }.map { "\($0.key % 100)s:\($0.value)" }.joined(separator: " ")
            print("\(name)\t\(f(r.goodBad))\t\(f(r.okayBad))\t\(f(r.goodOkay))\t\(f(r.heldAUC))\t\(f(r.recall100))\t\(String(format: "%.1f", r.topPlaylists))\t\(r.topVersions)\t\(dec)")
        }
    }
}
