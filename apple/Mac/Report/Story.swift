import SongforMeKit
import SwiftUI

/// 年度、月度回顾：一页一页翻的竖版故事
struct StoryView: View {
    let report: Report
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    @State private var progress = 0.0
    @State private var paused = false

    static let size = CGSize(width: 420, height: 720)
    private static let perPage = 7.0

    private enum Scene: Hashable { case cover, total, hours, song, artists, moments, discovered, taste, account, persona, poster }

    private var scenes: [Scene] {
        var out: [Scene] = [.cover, .total, .hours]
        if !report.topSongs.isEmpty { out.append(.song) }
        if report.topArtists.count > 1 { out.append(.artists) }
        if report.loop != nil || report.latest != nil { out.append(.moments) }
        if report.discovered.count > 2 { out.append(.discovered) }
        if report.languages.count > 1 || report.decades.count > 1 { out.append(.taste) }
        if report.account.count > 2 { out.append(.account) }
        if report.persona != nil { out.append(.persona) }
        return out + [.poster]
    }

    var body: some View {
        let all = scenes
        let scene = all[min(index, all.count - 1)]
        ZStack {
            Backdrop(colors: palette(index), moving: !reduceMotion)
            page(scene)
                .padding(.horizontal, 34)
                .padding(.top, 70)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(scene)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 24)), removal: .opacity))
            // 点左边往回翻，点右边往后翻；最后一页上有按钮，只留左边
            HStack(spacing: 0) {
                Color.clear.contentShape(.rect).frame(width: 110).onTapGesture { step(-1) }
                Color.clear.contentShape(.rect).onTapGesture { step(1) }.allowsHitTesting(scene != .poster)
            }
            .padding(.top, 60)
            .padding(.bottom, scene == .poster ? 90 : 0)
            VStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(all.indices, id: \.self) { i in
                        Capsule()
                            .fill(.white.opacity(0.28))
                            .overlay(alignment: .leading) {
                                GeometryReader { geo in
                                    Capsule().fill(.white).frame(width: geo.size.width * (i < index ? 1 : i == index ? (i == all.count - 1 ? 1 : progress) : 0))
                                }
                            }
                            .frame(height: 3)
                    }
                }
                HStack {
                    Text(report.title).font(.system(size: 12, weight: .semibold)).opacity(0.8)
                    Spacer()
                    if scene != .poster { control(paused ? "play.fill" : "pause.fill", paused ? "继续" : "暂停") { paused.toggle() } }
                    control("xmark", "关闭") { dismiss() }
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            shortcuts
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
        .task(id: index) { await run(last: index >= all.count - 1) }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugStory)) { note in
            paused = true
            if let i = Int(note.object as? String ?? "") { withAnimation(.smooth(duration: 0.5)) { index = min(max(0, i), all.count - 1) } }
        }
        #endif
    }

    /// 这一页停几秒，然后自己翻到下一页
    private func run(last: Bool) async {
        progress = 0
        guard !last, !reduceMotion else {
            progress = 1
            return
        }
        let tick = 0.05
        while progress < 1 {
            try? await Task.sleep(for: .seconds(tick))
            if Task.isCancelled { return }
            if !paused { progress = min(1, progress + tick / Self.perPage) }
        }
        step(1)
    }

    private func step(_ n: Int) {
        let next = index + n
        guard scenes.indices.contains(next) else { return }
        withAnimation(.smooth(duration: 0.5)) { index = next }
    }

    private func control(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold)).frame(width: 26, height: 26).background(.white.opacity(0.16), in: .circle).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var shortcuts: some View {
        Group {
            Button("上一页") { step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("下一页") { step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("暂停") { paused.toggle() }.keyboardShortcut(.space, modifiers: [])
            Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func palette(_ i: Int) -> [Color] {
        let sets: [[UInt32]] = [
            [0x23206B, 0x7B2A8C, 0xD4485F], [0xB8362F, 0xD0306A, 0x6A2A8C], [0x101B4D, 0x2C3E9A, 0x6B3FA0], [0x5B2A86, 0xC23A7A, 0xD9602F],
            [0x0D5E6B, 0x2352B8, 0x5B45D6], [0x241A4F, 0x4B2E83, 0x8E3B76], [0x0B6B5B, 0x0D8A82, 0x2E6FB5], [0x8C3A1E, 0xC2562F, 0xB8368F],
        ]
        return sets[i % sets.count].map { Color(hex: $0) }
    }

    // MARK: 每一页

    @ViewBuilder private func page(_ scene: Scene) -> some View {
        let when = report.period == .year ? "这一年" : "这个月"
        switch scene {
        case .cover:
            VStack(spacing: 0) {
                Spacer()
                Collage(songs: report.topSongs.prefix(9).map(\.song)).frame(height: 300).reveal(0)
                Spacer()
                Text(report.period == .year ? "年度听歌回顾" : "月度听歌回顾").font(.system(size: 38, weight: .heavy)).reveal(1)
                Text(report.title).font(.system(size: 20, weight: .semibold, design: .rounded)).opacity(0.85).padding(.top, 8).reveal(2)
                if let nick = app.profile?.nick, !nick.isEmpty { Text(nick).font(.system(size: 15)).opacity(0.7).padding(.top, 6).reveal(3) }
                Spacer()
            }
        case .total:
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                line("\(when)，你听了").reveal(0)
                CountUp(to: (report.seconds / 60).rounded()).padding(.top, 6).reveal(1)
                Text("分钟").font(.system(size: 26, weight: .bold)).reveal(1)
                if report.seconds >= 3600 * 24 {
                    line("相当于不眠不休地听了 \((report.seconds / 86400).formatted(.number.precision(.fractionLength(1)))) 天").padding(.top, 18).reveal(2)
                } else {
                    line("也就是 \(spoken(report.seconds))").padding(.top, 18).reveal(2)
                }
                HStack(spacing: 28) {
                    number(report.plays, "次播放")
                    number(report.songs, "首歌")
                    number(report.artists, "位歌手")
                }
                .padding(.top, 44)
                .reveal(3)
                if let text = report.comparison { line(text).padding(.top, 26).reveal(4) }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .hours:
            VStack(spacing: 0) {
                Spacer()
                if let part = report.daypart {
                    line("最属于你的时间").reveal(0)
                    Text(part.name).font(.system(size: 58, weight: .heavy)).padding(.top, 4).reveal(1)
                }
                Dial(hours: report.hours).frame(width: 290, height: 290).padding(.top, 26).reveal(2)
                if let part = report.daypart { line("\(percent(part.value)) 的歌在这时候响起").padding(.top, 26).reveal(3) }
                Spacer()
            }
        case .song:
            if let top = report.topSongs.first {
                VStack(spacing: 0) {
                    Spacer()
                    line(report.period == .year ? "你的年度单曲" : "这个月的单曲").reveal(0)
                    RemoteImage(url: top.song.artwork(500), pixels: 500)
                        .frame(width: 236, height: 236)
                        .clipShape(.rect(cornerRadius: 18))
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                        .padding(.top, 22)
                        .reveal(1)
                    Text(top.song.name).font(.system(size: 28, weight: .heavy)).multilineTextAlignment(.center).lineLimit(2).padding(.top, 24).reveal(2)
                    Text(top.song.artistText).font(.system(size: 15)).opacity(0.8).lineLimit(1).padding(.top, 4).reveal(2)
                    Text("\(top.plays) 遍").font(.system(size: 20, weight: .bold, design: .rounded)).padding(.top, 10).reveal(3)
                    VStack(spacing: 8) {
                        ForEach(Array(report.topSongs.dropFirst().prefix(4).enumerated()), id: \.element.id) { i, s in
                            HStack {
                                Text("\(i + 2)").font(.system(size: 14, weight: .heavy, design: .rounded)).frame(width: 20)
                                Text(s.song.name).lineLimit(1)
                                Spacer()
                                Text("\(s.plays) 遍").opacity(0.75).monospacedDigit()
                            }
                            .font(.system(size: 14, weight: .medium))
                        }
                    }
                    .padding(.top, 22)
                    .reveal(4)
                    Spacer()
                }
            }
        case .artists:
            VStack(spacing: 0) {
                Spacer()
                line("陪你最久的声音").reveal(0)
                if let top = report.topArtists.first {
                    RemoteImage(url: top.portrait(300), pixels: 400)
                        .frame(width: 190, height: 190)
                        .clipShape(.circle)
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                        .padding(.top, 22)
                        .reveal(1)
                    Text(top.name).font(.system(size: 34, weight: .heavy)).lineLimit(1).padding(.top, 20).reveal(2)
                    Text("\(top.plays) 次 · \(spoken(top.seconds))").font(.system(size: 15)).opacity(0.8).padding(.top, 4).reveal(2)
                }
                VStack(spacing: 10) {
                    ForEach(Array(report.topArtists.dropFirst().prefix(4).enumerated()), id: \.element.id) { i, a in
                        HStack(spacing: 12) {
                            Text("\(i + 2)").font(.system(size: 14, weight: .heavy, design: .rounded)).frame(width: 20)
                            RemoteImage(url: a.portrait(150), pixels: 80).frame(width: 34, height: 34).clipShape(.circle)
                            Text(a.name).lineLimit(1)
                            Spacer()
                            Text("\(a.plays) 次").opacity(0.75).monospacedDigit()
                        }
                        .font(.system(size: 15, weight: .medium))
                    }
                }
                .padding(.top, 28)
                .reveal(3)
                Spacer()
            }
        case .moments:
            VStack(alignment: .leading, spacing: 40) {
                Spacer()
                if let m = report.latest {
                    VStack(alignment: .leading, spacing: 6) {
                        line(m.date.formatted(.dateTime.month().day().locale(.zh))).reveal(0)
                        Text(hourMinute(m.date)).font(.system(size: 64, weight: .heavy, design: .rounded)).reveal(0)
                        line("夜已经深了，你还在听《\(m.song.name)》").reveal(1)
                    }
                }
                if let m = report.loop {
                    VStack(alignment: .leading, spacing: 6) {
                        line(m.date.formatted(.dateTime.month().day().locale(.zh))).reveal(2)
                        Text("\(m.plays) 遍").font(.system(size: 64, weight: .heavy, design: .rounded)).reveal(2)
                        line("这一天，《\(m.song.name)》停不下来").reveal(3)
                    }
                }
                if report.streak > 1 { line("你连着听了 \(report.streak) 天歌").reveal(4) }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .discovered:
            VStack(spacing: 0) {
                Spacer()
                line("\(when)遇见了").reveal(0)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    CountUp(to: Double(report.discovered.count))
                    Text("首新歌").font(.system(size: 26, weight: .bold))
                }
                .reveal(1)
                Collage(songs: report.discovered.prefix(9).map(\.song)).frame(height: 300).padding(.top, 24).reveal(2)
                if report.kept > 0 { line("其中 \(report.kept) 首，你留在了“我喜欢”里").padding(.top, 24).reveal(3) }
                Spacer()
            }
        case .taste:
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                if let top = report.languages.first {
                    line("听得最多的是").reveal(0)
                    Text(top.name).font(.system(size: 52, weight: .heavy)).reveal(0)
                    ShareBars(rows: Array(report.languages.prefix(4)), color: .white).padding(.top, 18).reveal(1)
                }
                if let top = report.decades.first {
                    line("最常回到的是").padding(.top, 48).reveal(2)
                    Text(top.name).font(.system(size: 52, weight: .heavy)).reveal(2)
                    ShareBars(rows: Array(report.decades.prefix(4)), color: .white).padding(.top, 18).reveal(3)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .account:
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                line("在\(app.sourceNames(report.account))里，你还常听").reveal(0)
                VStack(spacing: 14) {
                    ForEach(Array(report.account.prefix(7).enumerated()), id: \.element.id) { i, s in
                        HStack(spacing: 12) {
                            CoverView(song: s.song, size: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.song.name).font(.system(size: 15, weight: .semibold))
                                Text(s.song.artistText).font(.system(size: 12)).opacity(0.75)
                            }
                            .lineLimit(1)
                            Spacer()
                            Text("\(s.plays)").font(.system(size: 18, weight: .heavy, design: .rounded))
                        }
                        .reveal(Double(i) * 0.5 + 1)
                    }
                }
                .padding(.top, 24)
                Text("账号里的累计次数").font(.system(size: 12)).opacity(0.6).padding(.top, 18).reveal(5)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .persona:
            VStack(spacing: 0) {
                Spacer()
                line("所以，你是一位").reveal(0)
                Text(report.persona?.title ?? "").font(.system(size: 54, weight: .heavy)).minimumScaleFactor(0.6).lineLimit(1).padding(.top, 10).reveal(2)
                line(report.persona?.text ?? "").multilineTextAlignment(.center).padding(.top, 18).reveal(3)
                Spacer()
            }
        case .poster:
            PosterExport(report: report, nick: app.profile?.nick ?? "", height: 520)
        }
    }

    private func line(_ text: String) -> some View { Text(text).font(.system(size: 17, weight: .medium)).opacity(0.9).lineSpacing(4) }

    private func number(_ n: Int, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(n.formatted(.number.grouping(.never))).font(.system(size: 30, weight: .heavy, design: .rounded)).monospacedDigit()
            Text(unit).font(.system(size: 13)).opacity(0.8)
        }
    }
}

// MARK: - 零件

/// 依次浮现
private struct Reveal: ViewModifier {
    let order: Double
    @State private var shown = false
    func body(content: Self.Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 18)
            .onAppear { withAnimation(.smooth(duration: 0.7).delay(0.15 + order * 0.28)) { shown = true } }
    }
}

extension View {
    fileprivate func reveal(_ order: Double) -> some View { modifier(Reveal(order: order)) }
}

/// 缓缓流动的渐变底
private struct Backdrop: View {
    let colors: [Color]
    let moving: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !moving)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let a = Float(sin(t * 0.5) * 0.14), b = Float(cos(t * 0.4) * 0.14)
            MeshGradient(
                width: 3, height: 3,
                points: [[0, 0], [0.5 + a, 0], [1, 0], [0, 0.5 + b], [0.5 + b, 0.5 + a], [1, 0.5 - a], [0, 1], [0.5 - b, 1], [1, 1]],
                colors: [colors[0], colors[0], colors[1], colors[0], colors[1], colors[2], colors[1], colors[2], colors[2]]
            )
        }
        .animation(.easeInOut(duration: 0.8), value: colors)
        .accessibilityHidden(true)
    }
}

/// 从 0 数上去的大数字
private struct CountUp: View {
    let to: Double
    @State private var value = 0.0
    var body: some View {
        Rolling(value: value)
            .onAppear { withAnimation(.easeOut(duration: 1.4).delay(0.4)) { value = to } }
            .accessibilityLabel("\(Int(to))")
    }

    private struct Rolling: View, Animatable {
        var value: Double
        var animatableData: Double {
            get { value }
            set { value = newValue }
        }
        var body: some View {
            Text(Int(value).formatted(.number)).font(.system(size: 76, weight: .heavy, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
        }
    }
}

/// 24 小时的圆盘，哪个钟点听得多哪根就长
struct Dial: View {
    let hours: [Double]
    @State private var grown = false

    private static func spot(_ hour: Int, _ radius: CGFloat) -> CGSize {
        let angle = Double(hour) * Double.pi / 12
        let x = CGFloat(Darwin.sin(angle)), y = CGFloat(Darwin.cos(angle))
        return CGSize(width: radius * x, height: radius * y * -1)
    }

    var body: some View {
        let top = max(hours.max() ?? 0, 1)
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let inner = side * 0.2
            ZStack {
                ForEach(0..<24, id: \.self) { h in
                    let share = hours[h] / top
                    let reach: CGFloat = grown ? CGFloat(share) : 0
                    let length: CGFloat = 6 + (side / 2 - inner - 30) * reach
                    let lift: CGFloat = inner + length / 2
                    Capsule()
                        .fill(.white.opacity(0.35 + 0.65 * share))
                        .frame(width: 8, height: length)
                        .offset(x: 0, y: 0 - lift)
                        .rotationEffect(.degrees(Double(h) * 15))
                }
                ForEach([0, 6, 12, 18], id: \.self) { h in
                    Text("\(h)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .opacity(0.75)
                        .offset(Self.spot(h, side / 2 - 8))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear { withAnimation(.spring(duration: 1.1, bounce: 0.2).delay(0.6)) { grown = true } }
        .accessibilityHidden(true)
    }
}

/// 封面拼贴，轻轻浮动
private struct Collage: View {
    let songs: [Song]
    @State private var floating = false

    private func drift(_ i: Int) -> CGFloat { (floating == (i % 2 == 0)) ? 5 : -5 }

    private static let spots: [(CGFloat, CGFloat, CGFloat)] = [
        (0, 0, 132), (-118, -78, 88), (112, -88, 96), (-112, 84, 98), (120, 76, 86), (0, -124, 72), (4, 126, 76), (-160, 6, 60), (164, -4, 60),
    ]

    var body: some View {
        ZStack {
            ForEach(Array(songs.prefix(Self.spots.count).enumerated().reversed()), id: \.element.mid) { i, s in
                let (x, y, size) = Self.spots[i]
                RemoteImage(url: s.artwork(300), pixels: 300)
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: size * 0.14))
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                    .offset(x: x, y: y + drift(i))
                    .animation(.easeInOut(duration: 2.6 + Double(i) * 0.2).repeatForever(autoreverses: true), value: floating)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { floating = true }
        .accessibilityHidden(true)
    }
}
