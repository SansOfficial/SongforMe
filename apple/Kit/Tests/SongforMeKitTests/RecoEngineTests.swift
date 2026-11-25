import Foundation
import Testing
@testable import SongforMeKit

let NOW = 1_795_478_400_000.0 // 2026-11-24T00:00:00Z
let DAY = 86_400_000.0

func song(_ mid: String, _ artist: String, name: String? = nil, language: Int = 0, date: String = "2015-01-01") -> Song {
    Song(mid: mid, name: name ?? "歌-\(mid)", singers: [Singer(mid: artist, name: artist)], duration: 200, language: language, genre: 1, publishTime: date, mediaMid: mid)
}

func ev(_ mid: String, _ seed: String, _ via: Evidence.Via = .similar, _ ref: String? = nil) -> Evidence {
    Evidence(mid: mid, via: via, ref: ref ?? seed, seed: seed, ts: NOW)
}

func event(_ mid: String, _ type: EventType, _ ratio: Double = 1, _ daysAgo: Double = 1, _ source: PlaySource = .reco) -> PlayEvent {
    PlayEvent(mid: mid, type: type, ratio: ratio, source: source, ts: NOW - daysAgo * DAY)
}

func run(
    _ songs: [Song], liked: [String], _ evidence: [Evidence], events: [PlayEvent] = [], recent: [String: Double] = [:],
    _ tweak: (inout RecoSettings) -> Void = { _ in }
) -> RecoResult {
    var s = RecoSettings()
    s.familiarRatio = 0
    tweak(&s)
    return RecoEngine.recommend(RecoInput(
        songs: Dictionary(uniqueKeysWithValues: songs.map { ($0.mid, $0) }), likedMids: liked, events: events, evidence: evidence,
        recentlyRecommended: recent, settings: s, now: NOW, random: { 0.5 }
    ))
}

extension RecoResult {
    var mids: [String] { items.map(\.song.mid) }
}

@Suite("喜爱度")
struct AffinityTests {
    @Test("听完加分，早早切歌减分，不喜欢直接屏蔽")
    func scores() {
        let a = RecoEngine.affinity(likedMids: ["L1"], events: [event("A", .complete), event("B", .skip, 0.1), event("C", .skip, 0.9), event("D", .dislike)], now: NOW)
        #expect(a["L1"]!.score == 1)
        #expect(a["A"]!.score > 0)
        #expect(a["B"]!.score < 0)
        #expect(a["C"]!.score == 0) // 快听完才切，不算负反馈
        #expect(a["D"]!.blocked)
    }

    @Test("很久以前的行为影响更小")
    func decay() {
        let a = RecoEngine.affinity(likedMids: [], events: [event("A", .complete, 1, 1), event("B", .complete, 1, 360)], now: NOW)
        #expect(a["A"]!.score > a["B"]!.score * 3)
    }

    @Test("没扩充过的喜欢歌曲优先当种子，被屏蔽的不选")
    func seeds() {
        let a = RecoEngine.affinity(likedMids: ["A", "B", "C"], events: [event("C", .dislike)], now: NOW)
        #expect(RecoEngine.pickSeeds(a, expandedAt: ["A": NOW - DAY], count: 1, now: NOW, random: { 0.5 }) == ["B"])
    }
}

@Suite("推荐")
struct RecommendTests {
    let songs = [song("L1", "x"), song("L2", "y"), song("C1", "p"), song("C2", "q"), song("C3", "r")]

    @Test("被更多喜欢的歌指向的候选排在前面，且不推荐已喜欢的歌")
    func ranks() {
        #expect(run(songs, liked: ["L1", "L2"], [ev("C1", "L1"), ev("C1", "L2"), ev("C2", "L1"), ev("L2", "L1")]).mids == ["C1", "C2"])
    }

    @Test("不喜欢、听腻了、最近推荐过的歌都不会出现")
    func excluded() {
        let r = run(
            songs, liked: ["L1"], [ev("C1", "L1"), ev("C2", "L1"), ev("C3", "L1")],
            events: [event("C1", .dislike), event("C2", .tired)], recent: ["C3": NOW - 2 * DAY]
        )
        #expect(r.items.isEmpty)
        #expect(r.candidateCount == 3)
    }

    @Test("种子歌被取消喜欢后，它带来的候选也随之消失")
    func unliked() {
        #expect(run(songs, liked: [], [ev("C1", "L1")], events: [event("L1", .unlike)]).items.isEmpty)
    }

    @Test("“探索”拉满时陌生歌手优先，拉到 0 时熟悉歌手优先")
    func exploration() {
        let pool = [song("L1", "x"), song("K", "x"), song("N", "z")]
        let evidence = [ev("K", "L1"), ev("N", "L1")]
        #expect(run(pool, liked: ["L1"], evidence) { $0.exploration = 1 }.mids.first == "N")
        #expect(run(pool, liked: ["L1"], evidence) { $0.exploration = 0 }.mids.first == "K")
    }

    @Test("语种过滤和同歌手上限生效")
    func limits() {
        let pool = [song("L1", "x"), song("A1", "a"), song("A2", "a"), song("A3", "a"), song("E1", "e", language: 5)]
        let r = run(pool, liked: ["L1"], ["A1", "A2", "A3", "E1"].map { ev($0, "L1") }) {
            $0.maxPerArtist = 2
            $0.languages = [0]
        }
        #expect(r.items.count { $0.song.singers[0].mid == "a" } == 2)
        #expect(!r.mids.contains("E1"))
    }

    @Test("“新歌”权重拉高后新发行的歌排到前面")
    func freshness() {
        let pool = [song("L1", "x"), song("OLD", "p", date: "2001-01-01"), song("NEW", "q", date: "2026-10-01")]
        let r = run(pool, liked: ["L1"], [ev("OLD", "L1"), ev("NEW", "L1")]) {
            $0.freshness = 1
            $0.tasteMatch = 0
        }
        #expect(r.mids.first == "NEW")
    }

    @Test("冷门 / 热门旋钮按“被多少歌单收录”区分")
    func obscurity() {
        let pool = [song("L1", "x"), song("HOT", "p"), song("RARE", "q")]
        let evidence = [
            ev("HOT", "L1", .playlist, "pl1"), ev("HOT", "L1", .playlist, "pl2"), ev("HOT", "L1", .playlist, "pl3"),
            ev("RARE", "L1"), ev("RARE", "L1", .playlist, "pl1"), ev("RARE", "L1", .singer, "sg"),
        ]
        #expect(run(pool, liked: ["L1"], evidence) { $0.obscurity = 1 }.mids.first == "RARE")
        #expect(run(pool, liked: ["L1"], evidence) { $0.obscurity = 0 }.mids.first == "HOT")
    }

    @Test("同一首歌的不同版本只出现一次，已喜欢的歌的其他版本不当新歌推")
    func versions() {
        let pool = [song("L1", "x", name: "晴天"), song("L1b", "x", name: "晴天 (Live)"), song("V1", "p", name: "痴心绝对"), song("V2", "p", name: "痴心绝对（DJ版）")]
        let r = run(pool, liked: ["L1"], [ev("L1b", "L1"), ev("V1", "L1"), ev("V2", "L1")]) { $0.maxPerArtist = 5 }
        #expect(r.mids == ["V1"])
    }

    @Test("听过的歌不当新歌推；没点喜欢但反复听过的歌进入熟歌通道")
    func familiar() {
        let pool = [song("L1", "x"), song("HEARD", "p"), song("OFTEN", "q"), song("NEW", "r")]
        let old = { (mid: String, type: EventType) in event(mid, type, 1, 30, .library) }
        let r = run(
            pool, liked: ["L1"], [ev("HEARD", "L1"), ev("OFTEN", "L1"), ev("NEW", "L1")],
            events: [old("HEARD", .play), old("OFTEN", .play), old("OFTEN", .complete), old("OFTEN", .complete), old("OFTEN", .complete)]
        ) {
            $0.batchSize = 10
            $0.familiarRatio = 0.5
        }
        #expect(r.items.filter { $0.kind == .new }.map(\.song.mid) == ["NEW"])
        #expect(r.items.filter { $0.kind == .familiar }.map(\.song.mid).sorted() == ["L1", "OFTEN"])
    }

    @Test("按比例混入很久没听的熟歌")
    func familiarRatio() {
        let pool = [song("L1", "x"), song("L2", "y")] + (0..<10).map { song("C\($0)", "a\($0)") }
        let r = run(
            pool, liked: ["L1", "L2"], pool.dropFirst(2).map { ev($0.mid, "L1") },
            events: [event("L1", .play, 0, 1)] // L1 昨天刚听过，不该被当熟歌再推
        ) {
            $0.batchSize = 10
            $0.familiarRatio = 0.2
        }
        #expect(r.items.filter { $0.kind == .familiar }.map(\.song.mid) == ["L2"])
        #expect(r.items.count { $0.kind == .new } == 8)
    }

    @Test("发行日期换算")
    func dates() {
        #expect(RecoEngine.published("1970-01-01") == 0)
        #expect(RecoEngine.published("2026-11-24") == NOW)
        #expect(RecoEngine.published("2024-02-29") == 1_709_164_800_000)
        #expect(RecoEngine.published("") == nil)
    }
}
