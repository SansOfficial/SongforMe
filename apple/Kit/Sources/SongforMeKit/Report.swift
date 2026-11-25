import Foundation

/// 听歌报告的时间跨度
public enum ReportPeriod: String, CaseIterable, Codable, Sendable {
    case day, week, month, year

    private var unit: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }

    /// 包含某个时刻的那一天 / 周 / 月 / 年；一周从星期一开始
    public func interval(_ date: Date, _ calendar: Calendar = .report) -> DateInterval {
        calendar.dateInterval(of: unit, for: date) ?? DateInterval(start: date, duration: 0)
    }

    /// 往前（负数）或往后挪几期
    public func shift(_ date: Date, by n: Int, _ calendar: Calendar = .report) -> Date {
        let start = interval(date, calendar).start
        return calendar.date(byAdding: unit, value: n, to: start) ?? start
    }
}

extension Calendar {
    public static var report: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        c.firstWeekday = 2
        return c
    }
}

/// 生成报告要用到的全部数据
public struct ReportInput: Sendable {
    public var songs: [String: Song]
    /// 按时间排好
    public var listens: [Listen]
    public var likes: [PlayEvent]
    public var hearts: Set<String>
    /// 音源账号里的累计播放次数和最后一次听的时间
    public var account: [String: (count: Int, last: Double)]

    public init(songs: [String: Song], listens: [Listen], likes: [PlayEvent] = [], hearts: Set<String> = [], account: [String: (count: Int, last: Double)] = [:]) {
        self.songs = songs
        self.listens = listens
        self.likes = likes
        self.hearts = hearts
        self.account = account
    }
}

public struct Report: Sendable {
    public struct SongRank: Sendable, Identifiable {
        public var song: Song
        public var plays: Int
        public var seconds: Double
        public var id: String { song.mid }
    }
    public struct NameRank: Sendable, Identifiable {
        /// 歌手或专辑的 mid，可能为空
        public var mid: String
        public var name: String
        /// 专辑的歌手
        public var detail: String
        public var plays: Int
        public var seconds: Double
        public var cover: Song
        public var id: String { mid + name }
    }
    public struct Moment: Sendable {
        public var song: Song
        public var date: Date
        public var plays = 1
    }
    public struct Share: Sendable, Identifiable {
        public var name: String
        /// 0~1
        public var value: Double
        public var id: String { name }
    }
    public struct Persona: Sendable, Equatable {
        public var title: String
        public var text: String
    }

    public var period: ReportPeriod
    public var interval: DateInterval
    /// 这一期还没过完
    public var ongoing = false
    public var seconds = 0.0
    public var plays = 0
    public var songs = 0
    public var artists = 0
    /// 上一期（这一期没过完时只算到同样的位置）听了多久；上一期没有记录时为 nil
    public var previous: Double?
    public var activeDays = 0
    /// 到这一期最后一个听歌的日子为止，连着听了多少天
    public var streak = 0
    /// 日报按小时，周报、月报按天，年报按月，单位秒
    public var bars: [Double] = []
    /// 一天 24 小时各听了多久，单位秒
    public var hours = [Double](repeating: 0, count: 24)
    public var topSongs: [SongRank] = []
    public var topArtists: [NameRank] = []
    public var topAlbums: [NameRank] = []
    /// 推荐来的、这一期第一次听的歌
    public var discovered: [SongRank] = []
    /// 其中点了喜欢的
    public var kept = 0
    /// 这一期点了多少首喜欢
    public var liked = 0
    /// 听得最晚的一次，只算晚上十一点到凌晨五点
    public var latest: Moment?
    /// 一天之内听得最多遍的一首，至少三遍
    public var loop: Moment?
    /// 听得最久的一天
    public var busiest: (date: Date, seconds: Double)?
    public var languages: [Share] = []
    public var decades: [Share] = []
    public var persona: Persona?
    /// 年报：在音源自己的应用里听得多、今年还听过的歌。次数是账号里的累计，不是今年的
    public var account: [SongRank] = []
    /// 本应用从什么时候开始有记录
    public var since: Date?
    /// 更早还有没有可看的
    public var hasEarlier = false

    public var isEmpty: Bool { seconds < 1 }

    /// 听够半分钟，或者听了大半首，才算听了一遍
    static func counts(_ seconds: Double, _ song: Song) -> Bool {
        seconds >= 30 || (song.duration > 0 && seconds >= song.duration / 2)
    }

    // MARK: 生成

    public static func make(_ period: ReportPeriod, _ date: Date, _ input: ReportInput, now: Date = Date(), calendar: Calendar = .report) -> Report {
        let interval = period.interval(date, calendar)
        var r = Report(period: period, interval: interval)
        r.ongoing = interval.start <= now && now < interval.end
        r.since = input.listens.first.map(\.date)
        r.hasEarlier = input.listens.first.map { $0.date < interval.start } ?? false
            || period == .year && input.account.values.contains { $0.last > 0 && Date(millis: $0.last) < interval.start }

        let mine = input.listens.filter { interval.holds($0.date) }
        let earlier = Set(input.listens.lazy.filter { $0.date < interval.start }.map(\.mid))
        r.seconds = mine.reduce(0) { $0 + $1.seconds }

        // 和上一期比
        let last = period.interval(period.shift(date, by: -1, calendar), calendar)
        let until = r.ongoing ? min(last.end, last.start + now.timeIntervalSince(interval.start)) : last.end
        let before = input.listens.filter { last.start <= $0.date && $0.date < until }
        // 上一期大半时间还没有开始记录，比了也没有意义
        let covered = input.listens.first.map { $0.date <= last.start + last.duration * 0.2 } ?? false
        if !before.isEmpty, covered || period == .day { r.previous = before.reduce(0) { $0 + $1.seconds } }

        // 时间分布
        r.bars = [Double](repeating: 0, count: barCount(period, interval, calendar))
        var days: [Date: Double] = [:]
        for l in mine {
            let hour = calendar.component(.hour, from: l.date)
            let day = calendar.startOfDay(for: l.date)
            r.hours[hour] += l.seconds
            days[day, default: 0] += l.seconds
            let bar = switch period {
            case .day: hour
            case .week, .month: calendar.dateComponents([.day], from: interval.start, to: day).day ?? 0
            case .year: calendar.component(.month, from: l.date) - 1
            }
            if r.bars.indices.contains(bar) { r.bars[bar] += l.seconds }
        }
        r.activeDays = days.count
        if let top = days.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) { r.busiest = (top.key, top.value) }
        if var day = days.keys.max() {
            let all = Set(input.listens.map { calendar.startOfDay(for: $0.date) })
            while all.contains(day) {
                r.streak += 1
                guard let next = calendar.date(byAdding: .day, value: -1, to: day) else { break }
                day = next
            }
        }

        // 排行
        var songs = OrderedMap<String, SongRank>()
        var artists = OrderedMap<String, NameRank>()
        var albums = OrderedMap<String, NameRank>()
        var perDay = OrderedMap<String, Moment>()
        var firstSource: [String: PlaySource] = [:]
        var lateness = -1
        var weekend = 0
        for l in mine {
            guard let song = input.songs[l.mid] else { continue }
            let counted = counts(l.seconds, song)
            let one = counted ? 1 : 0
            firstSource[l.mid] = firstSource[l.mid] ?? l.source
            var s = songs[l.mid] ?? SongRank(song: song, plays: 0, seconds: 0)
            s.plays += one
            s.seconds += l.seconds
            songs[l.mid, default: s] = s
            for singer in song.singers where !singer.name.isEmpty {
                let key = singer.key
                var a = artists[key] ?? NameRank(mid: singer.mid, name: singer.name, detail: "", plays: 0, seconds: 0, cover: song)
                a.plays += one
                a.seconds += l.seconds
                artists[key, default: a] = a
            }
            if !song.albumMid.isEmpty, !song.albumName.isEmpty {
                var a = albums[song.albumMid] ?? NameRank(mid: song.albumMid, name: song.albumName, detail: song.artistText, plays: 0, seconds: 0, cover: song)
                a.plays += one
                a.seconds += l.seconds
                albums[song.albumMid, default: a] = a
            }
            guard counted else { continue }
            r.plays += 1
            if calendar.isDateInWeekend(l.date) { weekend += 1 }
            let day = calendar.startOfDay(for: l.date)
            let key = "\(day.timeIntervalSince1970) \(l.mid)"
            var m = perDay[key] ?? Moment(song: song, date: day, plays: 0)
            m.plays += 1
            perDay[key, default: m] = m
            // 凌晨接在前一天的深夜后面
            let c = calendar.dateComponents([.hour, .minute], from: l.date)
            let minute = ((c.hour ?? 0) < 5 ? (c.hour ?? 0) + 24 : c.hour ?? 0) * 60 + (c.minute ?? 0)
            if minute >= 23 * 60, minute > lateness {
                lateness = minute
                r.latest = Moment(song: song, date: l.date)
            }
        }
        let heard = songs.values.filter { $0.plays > 0 }
        r.songs = heard.count
        r.artists = artists.values.count { $0.plays > 0 }
        r.topSongs = Array(ranked(heard) { ($0.plays, $0.seconds) }.prefix(50))
        r.topArtists = Array(ranked(artists.values.filter { $0.plays > 0 }) { ($0.plays, $0.seconds) }.prefix(10))
        r.topAlbums = Array(ranked(albums.values.filter { $0.plays > 1 }) { ($0.plays, $0.seconds) }.prefix(10))
        r.loop = ranked(perDay.values.filter { $0.plays >= 3 }) { ($0.plays, 0) }.first
        r.discovered = ranked(heard.filter { firstSource[$0.id] == .reco && !earlier.contains($0.id) }) { ($0.plays, $0.seconds) }
        r.kept = r.discovered.count { input.hearts.contains($0.id) }

        var taps: [String: EventType] = [:]
        for e in input.likes where interval.holds(Date(millis: e.ts)) { taps[e.mid] = e.type }
        r.liked = taps.values.count { $0 == .like }

        // 构成：按遍数算
        r.languages = shares(heard) { s in Languages.all.first { $0.code == s.language }?.name }
        r.decades = shares(heard) { s in RecoEngine.decade(of: s.publishTime).map(decadeName) }
        r.persona = persona(r, weekend: weekend)

        if period == .year {
            let rows = input.account.compactMap { mid, p -> SongRank? in
                guard p.count >= 3, interval.holds(Date(millis: p.last)), let song = input.songs[mid] else { return nil }
                return SongRank(song: song, plays: p.count, seconds: 0)
            }.sorted { $0.id < $1.id }
            r.account = Array(ranked(rows) { ($0.plays, 0) }.prefix(10))
        }
        return r
    }

    private static func barCount(_ period: ReportPeriod, _ interval: DateInterval, _ calendar: Calendar) -> Int {
        switch period {
        case .day: 24
        case .week: 7
        case .month: calendar.range(of: .day, in: .month, for: interval.start)?.count ?? 31
        case .year: 12
        }
    }

    /// 从大到小；一样大时保持原来的先后
    private static func ranked<T>(_ list: [T], by key: (T) -> (Int, Double)) -> [T] {
        list.enumerated().sorted { a, b in
            let (x, y) = (key(a.element), key(b.element))
            return x == y ? a.offset < b.offset : x > y
        }.map(\.element)
    }

    static func decadeName(_ decade: Int) -> String { decade < 2000 ? "\(decade - 1900) 年代" : "\(decade)".replacing("20", with: "", maxReplacements: 1) + " 年代" }

    private static func shares(_ list: [SongRank], _ name: (Song) -> String?) -> [Share] {
        var counts = OrderedMap<String, Int>()
        var total = 0
        for s in list {
            guard let n = name(s.song) else { continue }
            counts[n, default: 0] += s.plays
            total += s.plays
        }
        guard total > 0 else { return [] }
        return ranked(counts.pairs.map { Share(name: $0.0, value: Double($0.1) / Double(total)) }) { (0, $0.value) }
    }

    // MARK: 听歌性格

    /// 听得太少时说不准，不给
    static func persona(_ r: Report, weekend: Int) -> Persona? {
        guard r.plays >= 10, r.seconds > 0 else { return nil }
        let plays = Double(r.plays)
        func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
        if let top = r.topSongs.first, top.plays >= 5, Double(top.plays) / plays >= 0.2 {
            return Persona(title: "单曲循环家", text: "每听五首，就有一首以上是《\(top.song.name)》")
        }
        if let top = r.topArtists.first, Double(top.plays) / plays >= 0.4 {
            return Persona(title: "专一的人", text: "\(percent(Double(top.plays) / plays)) 的时候在听\(top.name)")
        }
        let fresh = r.songs > 0 ? Double(r.discovered.count) / Double(r.songs) : 0
        if fresh >= 0.4 { return Persona(title: "探索者", text: "听过的歌里，\(percent(fresh)) 是第一次遇见") }
        let night = (r.hours[22...].reduce(0, +) + r.hours[..<5].reduce(0, +)) / r.seconds
        if night >= 0.45 { return Persona(title: "夜行听众", text: "\(percent(night)) 的歌在夜里十点以后响起") }
        let morning = r.hours[5..<10].reduce(0, +) / r.seconds
        if morning >= 0.4 { return Persona(title: "清晨听众", text: "\(percent(morning)) 的歌陪你开始新的一天") }
        let old = r.decades.filter { ["60 年代", "70 年代", "80 年代", "90 年代", "00 年代"].contains($0.name) }.reduce(0) { $0 + $1.value }
        if old >= 0.6 { return Persona(title: "怀旧派", text: "\(percent(old)) 的歌来自 2010 年以前") }
        if r.period != .day, Double(weekend) / plays >= 0.6 { return Persona(title: "周末听众", text: "\(percent(Double(weekend) / plays)) 的歌留给了周末") }
        if r.artists >= 15, Double(r.songs) / plays >= 0.8 { return Persona(title: "杂食听众", text: "听了 \(r.artists) 位歌手，几乎不重样") }
        return Persona(title: "老朋友", text: "喜欢的歌，会一遍一遍地听")
    }

    /// 一天里的哪一段听得最多
    public var daypart: Share? {
        let parts: [(String, Range<Int>)] = [("凌晨", 0..<5), ("清晨", 5..<8), ("上午", 8..<12), ("午后", 12..<18), ("傍晚", 18..<20), ("夜晚", 20..<24)]
        let total = hours.reduce(0, +)
        guard total > 0 else { return nil }
        return parts.map { Share(name: $0.0, value: hours[$0.1].reduce(0, +) / total) }.max { $0.value < $1.value }
    }

    // MARK: 以前没有记听了多久

    /// 有听歌时长的记录之前，用“播放 / 听完 / 切歌”这些行为估出每次听了多久
    public static func estimate(_ events: [PlayEvent], songs: [String: Song], before limit: Double = .infinity) -> [Listen] {
        var out: [Listen] = []
        var open: PlayEvent?
        func close(_ p: PlayEvent, _ end: Double, _ ratio: Double) {
            // 实际过去的时间封顶：拖进度直接到结尾的不算听完整首
            let seconds = min((songs[p.mid]?.duration ?? 0) * min(1, ratio), max(0, end - p.ts) / 1000)
            if seconds >= 1 { out.append(Listen(mid: p.mid, ts: p.ts, seconds: seconds, source: p.source)) }
        }
        for e in events.filter({ $0.ts < limit }).sorted(by: { $0.ts < $1.ts }) {
            switch e.type {
            case .play:
                if let p = open { close(p, e.ts, 1) }
                open = e
            case .complete, .skip:
                if let p = open, p.mid == e.mid { close(p, e.ts, e.ratio) }
                open = nil
            default:
                break
            }
        }
        // 最后一次不知道听到了哪里，不算
        return out
    }
}

extension Listen {
    public var date: Date { Date(millis: ts) }
}

extension Date {
    init(millis: Double) { self.init(timeIntervalSince1970: millis / 1000) }
}

extension DateInterval {
    /// 不含结尾那一刻，免得零点整的歌同时算进两天
    func holds(_ date: Date) -> Bool { start <= date && date < end }
}

extension Library {
    /// 从本地数据库取出生成报告要的全部数据
    public func reportInput() async throws -> ReportInput {
        let songs = Dictionary(try await store.allSongs().map { ($0.mid, $0) }, uniquingKeysWith: { $1 })
        let events = try await store.events()
        let listens = try await store.listens()
        let guessed = Report.estimate(events, songs: songs, before: listens.first?.ts ?? .infinity)
        let account = try await accountPlays()
        return ReportInput(
            songs: songs, listens: guessed + listens,
            likes: events.filter { $0.type == .like || $0.type == .unlike },
            hearts: try await hearts(),
            account: account.mapValues { (Int($0.count), $0.last) }
        )
    }
}

/// 口语化的时长：3 小时 42 分、18 分钟
public func spoken(_ seconds: Double) -> String {
    let minutes = Int((max(0, seconds) / 60).rounded())
    if minutes < 1 { return seconds < 1 ? "0 分钟" : "不到 1 分钟" }
    if minutes < 60 { return "\(minutes) 分钟" }
    return minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(minutes % 60) 分"
}

extension Report.NameRank {
    /// 歌手的照片；音源没有时用他的一首歌的封面
    public func portrait(_ size: Int) -> URL? { Artwork.artist(mid, size) ?? cover.artwork(size) }
}
