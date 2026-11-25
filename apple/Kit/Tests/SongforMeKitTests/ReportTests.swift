import Foundation
import Testing
@testable import SongforMeKit

@Suite("听歌报告")
struct ReportTests {
    let calendar: Calendar = {
        var c = Calendar.report
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    func at(_ text: String) -> Date {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: text)!
    }
    func heard(_ mid: String, _ text: String, _ seconds: Double = 200, _ source: PlaySource = .library) -> Listen {
        Listen(mid: mid, ts: at(text).timeIntervalSince1970 * 1000, seconds: seconds, source: source)
    }
    func make(_ period: ReportPeriod, _ day: String, _ listens: [Listen], now: String = "2027-06-01 00:00", hearts: Set<String> = [], likes: [PlayEvent] = [], account: [String: (count: Int, last: Double)] = [:]) -> Report {
        let songs = [song("a", "甲"), song("b", "甲"), song("c", "乙", language: 5, date: "1995-03-01"), song("d", "丙", language: 3, date: "2021-03-01")]
        let input = ReportInput(songs: Dictionary(uniqueKeysWithValues: songs.map { ($0.mid, $0) }), listens: listens.sorted { $0.ts < $1.ts }, likes: likes, hearts: hearts, account: account)
        return Report.make(period, at(day + " 12:00"), input, now: at(now), calendar: calendar)
    }

    @Test("日、周、月、年的起止：一周从星期一开始，零点整算新的一天")
    func intervals() {
        let w = ReportPeriod.week.interval(at("2026-11-25 10:00"), calendar)
        #expect(w.start == at("2026-11-23 00:00") && w.end == at("2026-11-30 00:00"))
        #expect(ReportPeriod.month.shift(at("2026-03-31 08:00"), by: -1, calendar) == at("2026-02-01 00:00"))
        #expect(ReportPeriod.year.shift(at("2026-03-31 08:00"), by: 1, calendar) == at("2027-01-01 00:00"))
        let list = [heard("a", "2026-11-24 23:59"), heard("b", "2026-11-25 00:00")]
        #expect(make(.day, "2026-11-24", list).topSongs.map(\.id) == ["a"])
        #expect(make(.day, "2026-11-25", list).topSongs.map(\.id) == ["b"])
        #expect(make(.week, "2026-11-25", list).plays == 2)
        #expect(make(.week, "2026-11-30", list).isEmpty)
    }

    @Test("排行：切走的不算一遍，时长照算；合唱两位歌手都算")
    func ranking() {
        let r = make(.day, "2026-11-25", [
            heard("a", "2026-11-25 09:00"), heard("c", "2026-11-25 09:10"), heard("c", "2026-11-25 10:10"),
            heard("b", "2026-11-25 11:00"), heard("d", "2026-11-25 11:30", 12),
        ])
        #expect(r.plays == 4 && r.songs == 3 && r.artists == 2)
        #expect(r.seconds == 812)
        #expect(r.topSongs.map(\.id) == ["c", "a", "b"])
        #expect(r.topArtists.map(\.name) == ["甲", "乙"])
        #expect(r.bars[9] == 400 && r.bars[11] == 212 && r.bars.count == 24)
        #expect(r.languages.map(\.name) == ["国语", "英语"] && r.languages[0].value == 0.5)
        #expect(r.decades.map(\.name) == ["10 年代", "90 年代"])
    }

    @Test("短歌听了一半也算一遍")
    func shortSong() {
        var s = song("x", "甲")
        s.duration = 40
        #expect(Report.counts(20, s) && !Report.counts(19, s))
    }

    @Test("和上一期比：没过完时只比到同样的位置")
    func previous() {
        let list = [heard("a", "2026-11-24 08:00", 100), heard("a", "2026-11-24 20:00", 500), heard("b", "2026-11-25 08:00", 150)]
        let partial = make(.day, "2026-11-25", list, now: "2026-11-25 10:00")
        #expect(partial.ongoing && partial.previous == 100)
        let whole = make(.day, "2026-11-25", list)
        #expect(!whole.ongoing && whole.previous == 600)
        #expect(make(.day, "2026-11-24", list).previous == nil)
        // 上个月月底才开始记录，不拿来比
        #expect(make(.month, "2026-12-01", list + [heard("a", "2026-12-01 08:00")]).previous == nil)
    }

    @Test("最晚的一首、单日循环、听得最久的一天、连着听了几天")
    func moments() {
        let r = make(.month, "2026-11-25", [
            heard("a", "2026-10-31 20:00"), heard("a", "2026-11-01 23:30"), heard("b", "2026-11-03 02:10"), heard("c", "2026-11-03 06:00"),
            heard("d", "2026-11-04 12:00"), heard("d", "2026-11-04 12:05"), heard("d", "2026-11-04 12:10"), heard("d", "2026-11-05 12:10"),
        ])
        #expect(r.latest?.song.mid == "b" && r.latest?.date == at("2026-11-03 02:10"))
        #expect(r.loop?.song.mid == "d" && r.loop?.plays == 3)
        #expect(r.busiest?.date == at("2026-11-04 00:00") && r.busiest?.seconds == 600)
        #expect(r.activeDays == 4 && r.streak == 3)
        #expect(r.bars.count == 30 && r.bars[3] == 600)
        // 连着的天数可以跨到上一期
        #expect(make(.month, "2026-11-01", [heard("a", "2026-10-31 20:00"), heard("a", "2026-11-01 20:00")]).streak == 2)
    }

    @Test("新发现：推荐来的、第一次听的；以前听过的不算")
    func discovered() {
        let list = [
            heard("a", "2026-10-01 10:00", 200, .reco), heard("a", "2026-11-25 10:00", 200, .reco), heard("b", "2026-11-25 11:00", 200, .reco),
            heard("c", "2026-11-25 12:00", 200, .search), heard("d", "2026-11-25 12:00", 5, .reco),
        ]
        let like = { (type: EventType, text: String) in PlayEvent(mid: "b", type: type, ratio: 0, source: .reco, ts: self.at(text).timeIntervalSince1970 * 1000) }
        let r = make(.month, "2026-11-25", list, hearts: ["b"], likes: [like(.like, "2026-11-25 11:01")])
        #expect(r.discovered.map(\.id) == ["b"] && r.kept == 1 && r.liked == 1)
        #expect(make(.month, "2026-11-25", list, likes: [like(.like, "2026-11-25 11:01"), like(.unlike, "2026-11-25 11:02")]).liked == 0)
    }

    @Test("听歌性格：听得少不下结论，各种类型各给各的")
    func persona() {
        func list(_ mids: [String], hour: Int) -> [Listen] {
            mids.enumerated().map { i, m in heard(m, "2026-11-25 \(hour < 10 ? "0" : "")\(hour):\(10 + i)") }
        }
        #expect(make(.day, "2026-11-25", list(["a", "b", "c"], hour: 12)).persona == nil)
        #expect(make(.day, "2026-11-25", list(["a", "a", "a", "a", "a", "b", "c", "d", "c", "d"], hour: 12)).persona?.title == "单曲循环家")
        #expect(make(.day, "2026-11-25", list(["a", "b", "a", "b", "a", "b", "c", "d", "c", "d", "c"], hour: 12)).persona?.title == "专一的人")
        // 三位歌手、每首都不到两成，要多几首歌才轮得到看时段
        let many = (0..<12).map { song("n\($0)", "歌手\($0)") }
        func persona(hour: Int, _ source: PlaySource = .library) -> String? {
            let listens = many.enumerated().map { i, s in heard(s.mid, "2026-11-25 \(hour < 10 ? "0" : "")\(hour):\(10 + i)", 200, source) }
            let input = ReportInput(songs: Dictionary(uniqueKeysWithValues: many.map { ($0.mid, $0) }), listens: listens)
            return Report.make(.day, at("2026-11-25 12:00"), input, now: at("2027-01-01 00:00"), calendar: calendar).persona?.title
        }
        #expect(persona(hour: 23) == "夜行听众" && persona(hour: 7) == "清晨听众" && persona(hour: 14) == "老朋友")
        #expect(persona(hour: 14, .reco) == "探索者")
    }

    @Test("年报：音源账号里今年还听过的歌")
    func account() {
        let last = at("2024-05-01 10:00").timeIntervalSince1970 * 1000
        let plays: [String: (count: Int, last: Double)] = ["a": (10, last), "b": (30, last), "c": (1, last), "d": (99, 0), "没有": (50, last)]
        #expect(make(.year, "2024-01-01", [], account: plays).account.map(\.id) == ["b", "a"])
        #expect(make(.year, "2025-01-01", [], account: plays).account.isEmpty)
        #expect(make(.month, "2024-05-01", [], account: plays).account.isEmpty)
        #expect(make(.year, "2024-01-01", []).bars.count == 12)
    }

    @Test("旧记录估算时长：听完、切歌、没有结尾、拖到结尾")
    func estimate() {
        let songs = ["a": song("a", "甲"), "b": song("b", "乙")]
        func e(_ mid: String, _ type: EventType, _ second: Double, _ ratio: Double = 0) -> PlayEvent {
            PlayEvent(mid: mid, type: type, ratio: ratio, source: .library, ts: second * 1000)
        }
        let events = [
            e("a", .play, 0), e("a", .complete, 203, 1),
            e("b", .play, 210), e("b", .skip, 260, 0.2),
            e("a", .play, 300), e("b", .play, 350),
            e("b", .complete, 360, 0.95),
            e("a", .play, 1000), e("a", .like, 1001), e("a", .complete, 9000, 1),
            e("b", .play, 9001),
        ]
        #expect(Report.estimate(events, songs: songs).map(\.seconds) == [200, 40, 50, 10, 200])
        #expect(Report.estimate(events, songs: songs, before: 300_000).map(\.mid) == ["a", "b"])
        #expect(Report.estimate([e("不认识", .play, 0), e("不认识", .complete, 200, 1)], songs: songs).isEmpty)
    }

    @Test("有了真实时长之后，估算只用在那之前")
    func input() async throws {
        let store = try Store()
        try await store.putSongs([song("a", "甲")])
        func e(_ type: EventType, _ ts: Double) -> PlayEvent { PlayEvent(mid: "a", type: type, ratio: type == .play ? 0 : 1, source: .library, ts: ts) }
        try await store.addEvents([e(.play, 0), e(.complete, 200_000), e(.play, 500_000), e(.complete, 700_000)])
        try await store.putListen(Listen(mid: "a", ts: 500_000, seconds: 15, source: .library))
        try await store.putListen(Listen(mid: "a", ts: 500_000, seconds: 180, source: .library))
        try await store.putListen(Listen(mid: "a", ts: 500_000, seconds: 30, source: .library))
        let input = try await Library(hub: SourceHub(), store: store).reportInput()
        #expect(input.listens.map(\.seconds) == [200, 180])
    }

    @Test("时长的说法")
    func words() {
        #expect(spoken(0) == "0 分钟" && spoken(20) == "不到 1 分钟" && spoken(59 * 60) == "59 分钟")
        #expect(spoken(3600) == "1 小时" && spoken(3 * 3600 + 42 * 60) == "3 小时 42 分")
        #expect(Report.decadeName(1990) == "90 年代" && Report.decadeName(2000) == "00 年代" && Report.decadeName(2020) == "20 年代")
    }
}
