import SongforMeKit
import SwiftUI

/// 听歌报告：日报、周报、月报、年报
struct ReportPage: View {
    let period: ReportPeriod
    @Environment(AppModel.self) private var app
    @State private var telling = false
    @State private var sharing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            head
            if let r = app.report {
                Group {
                    if r.isEmpty { ReportEmpty(report: r) } else { full(r) }
                    if !r.account.isEmpty { AccountList(rows: r.account, year: r.interval.start) }
                    if let since = r.since, r.interval.start < since, since < r.interval.end, !r.isEmpty {
                        Text("从 \(since.formatted(.dateTime.month().day().locale(.zh))) 开始记录")
                            .font(.caption).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .id(r.interval.start.timeIntervalSince1970 + r.interval.duration)
                .transition(.opacity.combined(with: .offset(y: 10)))
            } else {
                ListHint(empty: "")
            }
        }
        .padding(.top, 8)
        .animation(.smooth(duration: 0.3), value: app.report.map { $0.interval })
        .sheet(isPresented: $telling) { if let r = app.report { StoryView(report: r).environment(app) } }
        .sheet(isPresented: $sharing) { if let r = app.report { PosterSheet(report: r).environment(app) } }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugStory)) { _ in telling = true }
        .onReceive(NotificationCenter.default.publisher(for: .debugPoster)) { _ in sharing = true }
        #endif
    }

    private var head: some View {
        HStack(spacing: 16) {
            Text("听歌报告").font(.system(size: 28, weight: .bold))
            Spacer()
            Picker("", selection: Binding(get: { period }, set: { app.openReport($0, anchor) })) {
                ForEach(ReportPeriod.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    /// 换一种报告时停在同一段时间；现在这一期就停在今天
    private var anchor: Date {
        guard let r = app.report, !r.ongoing else { return Date() }
        return r.interval.start
    }

    @ViewBuilder private func full(_ r: Report) -> some View {
        ReportHero(report: r, telling: $telling, sharing: $sharing)
        ReportTiles(report: r)
        HStack(alignment: .top, spacing: 18) {
            ReportCard(period == .day ? "这一天" : "每\(period == .year ? "月" : "天")") { BarChart(values: r.bars, label: r.barLabel, tip: r.barTip) }
            if period != .day {
                ReportCard("一天里的时段") { BarChart(values: r.hours, label: { $0 % 6 == 0 ? "\($0) 点" : nil }, tip: { "\($0) 点" }) }
            }
        }
        ReportMoments(report: r)
        HStack(alignment: .top, spacing: 18) {
            ReportCard("单曲榜") { SongBoard(rows: Array(r.topSongs.prefix(10))) }
            if !r.topArtists.isEmpty {
                VStack(spacing: 18) {
                    ReportCard("歌手榜") { ArtistBoard(rows: Array(r.topArtists.prefix(5))) }
                    if !r.topAlbums.isEmpty { ReportCard("专辑榜") { AlbumBoard(rows: Array(r.topAlbums.prefix(4))) } }
                }
                .frame(width: 330)
            }
        }
        if r.languages.count > 1 || r.decades.count > 1 {
            HStack(alignment: .top, spacing: 18) {
                if !r.languages.isEmpty { ReportCard("语种") { ShareBars(rows: Array(r.languages.prefix(5))) } }
                if !r.decades.isEmpty { ReportCard("年代") { ShareBars(rows: Array(r.decades.prefix(5))) } }
            }
        }
        if !r.discovered.isEmpty {
            ReportCard("这一\(period.unitName)遇见的新歌") {
                CardGrid {
                    ForEach(r.discovered.prefix(5)) { s in
                        Card(url: s.song.artwork(300), title: s.song.name, meta: s.song.artistText) {
                            app.play(r.discovered.map(\.song), from: s.id)
                        }
                    }
                }
            }
        }
    }
}

/// 翻到上一期 / 下一期
struct PeriodPager: View {
    let report: Report
    var light = false
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 4) {
            arrow("chevron.left", "上一\(report.period.unitName)", -1).disabled(!report.hasEarlier)
            Text(report.title).font(.system(size: 14, weight: .semibold)).monospacedDigit().contentTransition(.numericText())
            arrow("chevron.right", "下一\(report.period.unitName)", 1).disabled(report.ongoing || report.interval.start > Date())
        }
        .foregroundStyle(light ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    }

    private func arrow(_ icon: String, _ label: String, _ step: Int) -> some View {
        Button { app.openReport(report.period, report.period.shift(report.interval.start, by: step)) } label: {
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).frame(width: 26, height: 26).contentShape(.circle)
        }
        .buttonStyle(PagerStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct PagerStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.primary.opacity(hovering && enabled ? 0.12 : 0), in: .circle)
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.3)
            .onHover { hovering = $0 }
    }
}

// MARK: - 头图

private struct ReportHero: View {
    let report: Report
    @Binding var telling: Bool
    @Binding var sharing: Bool
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                PeriodPager(report: report, light: true).padding(.leading, -6)
                BigTime(seconds: report.seconds, size: 58).padding(.top, 14)
                Text(report.comparison ?? "一共听了这么久")
                    .font(.system(size: 14, weight: .medium))
                    .opacity(0.9)
                    .padding(.top, 2)
                HStack(spacing: 10) {
                    if report.hasStory {
                        pill("回顾", "sparkles", filled: true) { telling = true }
                    }
                    pill("播放", "play.fill", filled: !report.hasStory) { app.play(report.topSongs.map(\.song)) }
                        .disabled(report.topSongs.isEmpty)
                    pill("分享", "square.and.arrow.up") { sharing = true }
                }
                .padding(.top, 20)
            }
            Spacer(minLength: 0)
            CoverFan(songs: report.topSongs.prefix(3).map(\.song)).padding(.trailing, 14)
        }
        .foregroundStyle(.white)
        .padding(26)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                report.period.gradient
                // 光斑，让渐变不死板
                Circle().fill(.white.opacity(0.22)).frame(width: 300).blur(radius: 70).offset(x: 330, y: -120)
                Circle().fill(.black.opacity(0.18)).frame(width: 340).blur(radius: 80).offset(x: -300, y: 170)
            }
        }
        .clipShape(.rect(cornerRadius: 22))
        // 头图在深色、浅色里都是彩底白字
        .environment(\.colorScheme, .dark)
    }

    private func pill(_ title: String, _ icon: String, filled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold)) }
            .buttonStyle(PillStyle(filled: filled))
    }
}

struct PillStyle: ButtonStyle {
    var filled = false
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(filled ? Color.black.opacity(0.85) : .white)
            .background(.white.opacity(filled ? (hovering ? 1 : 0.92) : (hovering ? 0.28 : 0.18)), in: .capsule)
            .contentShape(.capsule)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// 大号的时长，数字大、单位小
struct BigTime: View {
    let seconds: Double
    var size: CGFloat = 58

    var body: some View {
        Text(text)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityLabel(spoken(seconds))
    }

    private var text: AttributedString {
        let minutes = Int((seconds / 60).rounded())
        var out = AttributedString()
        func add(_ n: Int, _ unit: String) {
            var a = AttributedString(n.formatted(.number.grouping(.never)))
            a.font = .system(size: size, weight: .heavy, design: .rounded).monospacedDigit()
            var b = AttributedString(" \(unit) ")
            b.font = .system(size: size * 0.32, weight: .semibold)
            out += a + b
        }
        if minutes >= 60 { add(minutes / 60, "小时") }
        if minutes < 60 || minutes % 60 > 0 { add(minutes % 60, minutes >= 60 ? "分" : "分钟") }
        return out
    }
}

/// 扇形摆开的三张封面
struct CoverFan: View {
    let songs: [Song]
    var size: CGFloat = 132
    @State private var open = false

    var body: some View {
        ZStack {
            ForEach(Array(songs.enumerated().reversed()), id: \.element.mid) { i, s in
                RemoteImage(url: s.artwork(300), pixels: 300)
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
                    .scaleEffect(1 - CGFloat(i) * 0.1)
                    .rotationEffect(.degrees(open ? Double(i) * 8 - 4 : 0))
                    .offset(x: open ? CGFloat(i) * size * 0.34 : 0, y: open ? CGFloat(i) * 5 : 0)
            }
        }
        .padding(.trailing, CGFloat(max(0, songs.count - 1)) * size * 0.34)
        .onAppear { withAnimation(.spring(duration: 0.7, bounce: 0.3).delay(0.1)) { open = true } }
        .accessibilityHidden(true)
    }
}

// MARK: - 数字、时刻

struct ReportCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 15, weight: .semibold))
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: .rect(cornerRadius: 18))
    }
}

private struct ReportTiles: View {
    let report: Report
    var body: some View {
        HStack(spacing: 12) {
            tile(report.plays, "播放", "次")
            tile(report.songs, "歌曲", "首")
            tile(report.artists, "歌手", "位")
            if report.period == .day { tile(report.liked, "点了喜欢", "首") } else { tile(report.activeDays, "听歌", "天") }
        }
    }

    private func tile(_ n: Int, _ title: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(n.formatted(.number.grouping(.never))).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                Text(unit).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}

private struct ReportMoments: View {
    let report: Report

    private struct Item: Identifiable {
        var id: String { label }
        var label: String
        var value: String
        var detail: String
        var song: Song?
        var icon: String
        var tint: Color
    }

    var body: some View {
        let list = items
        if !list.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                ForEach(list) { item in
                    HStack(spacing: 14) {
                        if let song = item.song {
                            CoverView(song: song, size: 54)
                        } else {
                            Image(systemName: item.icon)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 54, height: 54)
                                .background(item.tint.gradient, in: .rect(cornerRadius: 9))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label).font(.system(size: 12)).foregroundStyle(.secondary)
                            Text(item.value).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                            Text(item.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).help(item.detail)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .background(.primary.opacity(0.035), in: .rect(cornerRadius: 18))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var items: [Item] {
        var out: [Item] = []
        if let p = report.persona { out.append(Item(label: "听歌性格", value: p.title, detail: p.text, icon: "person.wave.2.fill", tint: .purple)) }
        if let m = report.loop { out.append(Item(label: report.period == .day ? "循环最多" : "单日循环", value: "\(m.plays) 遍", detail: m.song.name, song: m.song, icon: "repeat.1", tint: .pink)) }
        if let m = report.latest { out.append(Item(label: "最晚的一首", value: hourMinute(m.date), detail: m.song.name, song: m.song, icon: "moon.stars.fill", tint: .indigo)) }
        if report.period != .day, report.activeDays > 1, let b = report.busiest {
            out.append(Item(label: "听得最久的一天", value: b.date.formatted(.dateTime.month().day().locale(.zh)), detail: spoken(b.seconds), icon: "flame.fill", tint: .orange))
        }
        if report.period != .day, report.streak > 1 { out.append(Item(label: "连着听歌", value: "\(report.streak) 天", detail: "没有断过", icon: "calendar", tint: .teal)) }
        if !report.discovered.isEmpty {
            out.append(Item(label: "推荐来的新歌", value: "\(report.discovered.count) 首", detail: report.kept > 0 ? "留下了 \(report.kept) 首" : "第一次听", icon: "sparkles", tint: .blue))
        }
        return out
    }
}

// MARK: - 图

/// 柱状图：一个颜色，最高的一根标出来，悬停看数值
struct BarChart: View {
    let values: [Double]
    let label: (Int) -> String?
    let tip: (Int) -> String
    var color: Color = Theme.accent
    @State private var hovered: Int?
    @State private var grown = false

    var body: some View {
        let top = max(values.max() ?? 0, 1)
        let peak = values.firstIndex(of: values.max() ?? 0)
        VStack(spacing: 6) {
            HStack {
                // 没有悬停时说最高的那一根
                if let i = hovered ?? peak, values[i] > 0 {
                    Text(tip(i)).foregroundStyle(.secondary)
                    Text(spoken(values[i])).fontWeight(.semibold)
                }
                Spacer()
            }
            .font(.system(size: 12))
            .monospacedDigit()
            .frame(height: 16)
            GeometryReader { geo in
                let slot = geo.size.width / CGFloat(max(1, values.count))
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(values.indices, id: \.self) { i in
                        let share = values[i] / top
                        ZStack(alignment: .bottom) {
                            Color.clear.contentShape(.rect)
                            UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                                .fill(values[i] > 0 ? AnyShapeStyle(color.opacity((hovered ?? peak) == i ? 1 : 0.45)) : AnyShapeStyle(.primary.opacity(0.08)))
                                .frame(width: min(26, max(3, slot - max(2, slot * 0.28))), height: values[i] > 0 ? max(4, geo.size.height * share * (grown ? 1 : 0)) : 2)
                        }
                        .frame(width: slot)
                        .onHover { inside in
                            if inside { hovered = i } else if hovered == i { hovered = nil }
                        }
                        .accessibilityElement()
                        .accessibilityLabel(tip(i))
                        .accessibilityValue(spoken(values[i]))
                    }
                }
            }
            .frame(height: 120)
            GeometryReader { geo in
                let slot = geo.size.width / CGFloat(max(1, values.count))
                ForEach(values.indices, id: \.self) { i in
                    if let text = label(i) {
                        Text(text)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                            .position(x: min(geo.size.width - 14, max(14, slot * (CGFloat(i) + 0.5))), y: 7)
                    }
                }
            }
            .frame(height: 14)
            .accessibilityHidden(true)
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onAppear { withAnimation(.spring(duration: 0.7, bounce: 0.2).delay(0.1)) { grown = true } }
    }
}

struct ShareBars: View {
    let rows: [Report.Share]
    var color: Color = Theme.accent
    @State private var grown = false

    var body: some View {
        VStack(spacing: 11) {
            ForEach(rows) { r in
                HStack(spacing: 10) {
                    Text(r.name).font(.system(size: 13)).frame(width: 60, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.07))
                            Capsule().fill(color).frame(width: max(6, geo.size.width * r.value * (grown ? 1 : 0)))
                        }
                    }
                    .frame(height: 8)
                    Text(percent(r.value)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .onAppear { withAnimation(.smooth(duration: 0.7).delay(0.1)) { grown = true } }
    }
}

func hourMinute(_ date: Date) -> String {
    let c = Calendar.report.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}

func percent(_ v: Double) -> String { v > 0 && v < 0.01 ? "<1%" : "\(Int((v * 100).rounded()))%" }

// MARK: - 榜单

/// 名次：前三名醒目一点
private struct RankNumber: View {
    let n: Int
    var body: some View {
        Text("\(n)")
            .font(.system(size: 16, weight: .heavy, design: .rounded))
            .foregroundStyle(n <= 3 ? AnyShapeStyle(Theme.heart) : AnyShapeStyle(.tertiary))
            .frame(width: 24)
    }
}

private struct BoardRow<Cover: View>: View {
    let rank: Int
    let title: String
    let detail: String
    let plays: Int
    var playing = false
    var song: Song?
    let action: () -> Void
    @ViewBuilder let cover: Cover
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RankNumber(n: rank)
                cover.overlay {
                    if hovering, song != nil {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7).fill(.black.opacity(0.4))
                            Image(systemName: "play.fill").foregroundStyle(.white)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(playing ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
                    if !detail.isEmpty { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(plays) 次").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(.primary.opacity(hovering ? 0.05 : 0), in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .onHover { hovering = $0 }
        .contextMenu { if let song { SongMenu(song: song, play: action) } }
    }
}

private struct SongBoard: View {
    let rows: [Report.SongRank]
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                BoardRow(rank: i + 1, title: r.song.name, detail: r.song.artistText, plays: r.plays, playing: app.player.current?.song.mid == r.id, song: r.song) {
                    app.play(rows.map(\.song), from: r.id)
                } cover: {
                    CoverView(song: r.song, size: 42)
                }
            }
        }
    }
}

private struct ArtistBoard: View {
    let rows: [Report.NameRank]
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                BoardRow(rank: i + 1, title: r.name, detail: "", plays: r.plays) {
                    app.open(Singer(mid: r.mid, name: r.name))
                } cover: {
                    RemoteImage(url: r.portrait(150), pixels: 90).frame(width: 40, height: 40).clipShape(.circle)
                }
            }
        }
    }
}

private struct AlbumBoard: View {
    let rows: [Report.NameRank]
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                BoardRow(rank: i + 1, title: r.name, detail: r.detail, plays: r.plays) {
                    app.openAlbum(of: r.cover)
                } cover: {
                    CoverView(song: r.cover, size: 40)
                }
            }
        }
    }
}

private struct AccountList: View {
    let rows: [Report.SongRank]
    let year: Date
    @Environment(AppModel.self) private var app

    var body: some View {
        ReportCard("在\(app.sourceNames(rows))里常听的") {
            Text("这一年还听过的歌，次数是账号里的累计。").font(.caption).foregroundStyle(.secondary).padding(.top, -8)
            SongBoard(rows: rows)
        }
    }
}

// MARK: - 空

private struct ReportEmpty: View {
    let report: Report
    var body: some View {
        VStack(spacing: 14) {
            PeriodPager(report: report)
            Image(systemName: "headphones").font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary).padding(.top, 26)
            Text(report.ongoing ? "还没有开始听歌" : "这一\(report.period.unitName)没有听歌记录").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .background(.primary.opacity(0.035), in: .rect(cornerRadius: 22))
    }
}

// MARK: - 说法

extension Locale {
    static let zh = Locale(identifier: "zh_CN")
}

extension ReportPeriod {
    var title: String {
        switch self {
        case .day: "日报"
        case .week: "周报"
        case .month: "月报"
        case .year: "年报"
        }
    }

    var unitName: String {
        switch self {
        case .day: "天"
        case .week: "周"
        case .month: "月"
        case .year: "年"
        }
    }

    var colors: [Color] {
        switch self {
        case .day: [Color(hex: 0xE8622F), Color(hex: 0xD0306A)]
        case .week: [Color(hex: 0x0D8A82), Color(hex: 0x2352B8)]
        case .month: [Color(hex: 0x5B45D6), Color(hex: 0xB8368F)]
        case .year: [Color(hex: 0x23206B), Color(hex: 0x7B2A8C), Color(hex: 0xD4485F)]
        }
    }

    var gradient: LinearGradient { LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing) }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

extension Report {
    /// 11月25日 星期三 / 11月23日 – 11月29日 / 2026年11月 / 2026年
    var title: String {
        let start = interval.start
        let calendar = Calendar.report
        let sameYear = calendar.isDate(start, equalTo: Date(), toGranularity: .year)
        let day = sameYear ? Date.FormatStyle.dateTime.month().day().locale(.zh) : Date.FormatStyle.dateTime.year().month().day().locale(.zh)
        switch period {
        case .day:
            let name = calendar.isDateInToday(start) ? "今天" : calendar.isDateInYesterday(start) ? "昨天" : start.formatted(.dateTime.weekday(.wide).locale(.zh))
            return "\(start.formatted(day)) \(name)"
        case .week:
            let end = interval.end.addingTimeInterval(-1)
            return "\(start.formatted(day)) – \(end.formatted(.dateTime.month().day().locale(.zh)))"
        case .month: return start.formatted(.dateTime.year().month().locale(.zh))
        case .year: return start.formatted(.dateTime.year().locale(.zh))
        }
    }

    /// 和上一期比多了还是少了
    var comparison: String? {
        guard let previous else { return nil }
        let name = switch period {
        case .day: ongoing ? "昨天这时候" : "前一天"
        case .week: ongoing ? "上周同期" : "前一周"
        case .month: ongoing ? "上月同期" : "上个月"
        case .year: ongoing ? "去年同期" : "前一年"
        }
        let diff = seconds - previous
        if abs(diff) < 60 { return "和\(name)差不多" }
        return "比\(name)\(diff > 0 ? "多" : "少") \(spoken(abs(diff)))"
    }

    /// 内容够讲一段回顾
    var hasStory: Bool { (period == .month || period == .year) && plays >= 10 }

    func barLabel(_ i: Int) -> String? {
        switch period {
        case .day: i % 6 == 0 ? "\(i) 点" : nil
        case .week: ["一", "二", "三", "四", "五", "六", "日"][i]
        case .month: i == 0 || (i + 1) % 5 == 0 ? "\(i + 1)" : nil
        case .year: "\(i + 1)"
        }
    }

    func barTip(_ i: Int) -> String {
        switch period {
        case .day: return "\(i) 点"
        case .week, .month:
            let day = Calendar.report.date(byAdding: .day, value: i, to: interval.start) ?? interval.start
            return day.formatted(.dateTime.month().day().weekday().locale(.zh))
        case .year: return "\(i + 1) 月"
        }
    }
}
