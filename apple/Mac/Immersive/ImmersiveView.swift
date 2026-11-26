import SongforMeKit
import SwiftUI

enum ImmersiveScene: String, CaseIterable {
    case vinyl, lyrics, stars
    var title: String {
        switch self {
        case .vinyl: "黑胶"
        case .lyrics: "歌词"
        case .stars: "星轨"
        }
    }
}

struct ImmersiveView: View {
    /// 唱片转一圈的秒数。真实的 33 转是 1.8 秒，这里放慢，看着安静
    static let spin = 9.0

    @Environment(AppModel.self) private var app
    @Environment(Immersive.self) private var immersive
    @AppStorage("scene") private var scene = ImmersiveScene.vinyl
    /// 换歌时先抬起唱臂，过一会儿再落下
    @State private var swapping = true

    var body: some View {
        GeometryReader { geo in
            let plan = Plan(size: geo.size, hasLyrics: !app.lyrics.lines.isEmpty)
            ZStack(alignment: .topLeading) {
                Glow(url: app.player.current?.song.artwork(300))
                if immersive.staged, let song = app.player.current?.song {
                    stage(song, plan)
                }
                controls
                    .opacity(immersive.staged && !immersive.idle ? 1 : 0)
                    .allowsHitTesting(immersive.staged && !immersive.idle)
                    .animation(.easeInOut(duration: 0.45), value: immersive.idle)
                    .animation(.easeOut(duration: 0.3), value: immersive.staged)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .background(Color(red: 0.04, green: 0.043, blue: 0.063))
        .foregroundStyle(.white)
        .onChange(of: app.player.playing) { immersive.keepAwake() }
        // 队列被清空了就没有可看的了
        .onChange(of: app.player.current == nil) { _, gone in if gone { immersive.close() } }
        .task(id: app.player.current?.song.mid) {
            swapping = true
            try? await Task.sleep(for: .seconds(1.1))
            if !Task.isCancelled { swapping = false }
        }
    }

    @ViewBuilder private func stage(_ song: Song, _ plan: Plan) -> some View {
        let player = app.player
        let turning = player.playing && !swapping
        ZStack(alignment: .topLeading) {
            switch scene {
            case .vinyl:
                VinylDeck(playing: turning, progress: { player.duration > 0 ? player.time / player.duration : 0 })
                    .frame(width: plan.deck.width, height: plan.deck.height)
                    .offset(x: plan.deck.minX, y: plan.deck.minY)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    // 位置有变化时把进度告诉唱臂
                    .id("deck")
            case .lyrics:
                LyricsWall(plan: plan).transition(.opacity.combined(with: .offset(x: 40)))
            case .stars:
                StarField(turning: player.playing).transition(.opacity)
            }

            Cover(song: song, scene: scene, spinning: turning, plan: plan)

            SongTitle(song: song, scene: scene, plan: plan)
                .id(scene)
                .transition(.opacity.combined(with: .offset(y: 18)))
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97)), removal: .opacity))
        .animation(.spring(duration: 0.75, bounce: 0.12), value: scene)
        .animation(.spring(duration: 0.75, bounce: 0.08), value: plan.hasLyrics)
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Spacer()
                ScenePicker(scene: $scene)
                IconButton(icon: "arrow.down.right.and.arrow.up.left", label: "退出全屏（Esc）", size: 15) { immersive.close() }
                    .glass(in: .circle, interactive: true)
            }
            .padding(24)
            Spacer()
            VStack(spacing: 10) {
                ProgressRow(tint: .white, track: .white.opacity(0.2))
                ZStack {
                    Transport(big: 1.35, tint: .white, ink: Color(white: 0.07))
                    HStack {
                        VolumeButton(size: 17)
                        QueueButton(size: 17)
                        Spacer()
                        if let song = app.player.current?.song { HeartButton(song: song, size: 19) }
                    }
                }
            }
            .padding(.horizontal, 56)
            .padding(.top, 50)
            .padding(.bottom, 26)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom))
        }
        .offset(y: immersive.idle ? 8 : 0)
    }
}

private struct ScenePicker: View {
    @Binding var scene: ImmersiveScene
    @Namespace private var space

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ImmersiveScene.allCases, id: \.self) { s in
                Button { scene = s } label: {
                    Text(s.title)
                        .foregroundStyle(.white.opacity(scene == s ? 1 : 0.62))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background {
                            if scene == s { Capsule().fill(.white.opacity(0.18)).matchedGeometryEffect(id: "on", in: space) }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .glass(in: .capsule)
        .animation(.spring(duration: 0.4, bounce: 0.2), value: scene)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("效果")
    }
}

/// 三种效果里封面、唱机、文字各放在哪
struct Plan: Equatable {
    let size: CGSize
    let hasLyrics: Bool

    private var w: CGFloat { size.width }
    private var h: CGFloat { size.height }
    func clamp(_ lo: CGFloat, _ v: CGFloat, _ hi: CGFloat) -> CGFloat { min(hi, max(lo, v)) }

    // 黑胶
    var side: CGFloat { clamp(28, w * 0.05, 110) }
    var deck: CGRect {
        let width = min(w * 0.54, h * 0.94)
        let height = width * Tonearm.deck.height / Tonearm.deck.width
        return CGRect(x: side, y: (h - height) / 2, width: width, height: height)
    }
    var vinylText: CGRect {
        let x = deck.maxX + clamp(24, w * 0.045, 96)
        return CGRect(x: x, y: 0, width: max(120, w - side - x), height: h)
    }

    // 歌词
    var lyricsSide: CGFloat { clamp(32, w * 0.07, 150) }
    var lyricsGap: CGFloat { clamp(32, w * 0.06, 130) }
    var lyricsColumn: CGFloat { (w - lyricsSide * 2 - lyricsGap) * 0.62 / 1.62 }
    var lyricsCover: CGRect {
        let column = hasLyrics ? lyricsColumn : w - lyricsSide * 2
        let s = min(column, h * 0.5)
        return CGRect(x: lyricsSide + (column - s) / 2, y: (h - s) / 2 - h * 0.09, width: s, height: s)
    }
    var lyricsText: CGRect {
        let x = lyricsSide + lyricsColumn + lyricsGap
        return CGRect(x: x, y: 0, width: w - lyricsSide - x, height: h)
    }

    // 星轨
    var moon: CGRect {
        let d = min(w, h) * 0.26
        return CGRect(x: w * StarField.pole.x - d / 2, y: h * StarField.pole.y - d / 2, width: d, height: d)
    }

    func cover(_ scene: ImmersiveScene) -> CGRect {
        switch scene {
        case .vinyl:
            let k = deck.width / Tonearm.deck.width
            let r = Tonearm.labelRadius * k
            return CGRect(x: deck.minX + Tonearm.disc.x * k - r, y: deck.minY + Tonearm.disc.y * k - r, width: r * 2, height: r * 2)
        case .lyrics: return lyricsCover
        case .stars: return moon
        }
    }
}

// MARK: - 封面

/// 三种效果共用一张封面，切换时从一处飞到另一处
private struct Cover: View {
    let song: Song
    let scene: ImmersiveScene
    let spinning: Bool
    let plan: Plan
    @Environment(AppModel.self) private var app

    var body: some View {
        let rect = plan.cover(scene)
        let radius = scene == .lyrics ? plan.clamp(14, plan.size.width * 0.016, 28) : rect.width / 2
        ZStack {
            RoundedRectangle(cornerRadius: radius)
                .fill(.black)
                .shadow(color: scene == .stars ? Color(red: 0.78, green: 0.85, blue: 1).opacity(0.32) : .black.opacity(scene == .lyrics ? 0.5 : 0), radius: rect.width * (scene == .stars ? 0.2 : 0.1), y: scene == .lyrics ? rect.width * 0.05 : 0)
            SpinningArt(url: song.artwork(800), radius: radius, spinning: scene == .vinyl && spinning, upright: scene != .vinyl)
            // 唱片中间的孔
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.95), Color(white: 0.57), Color(white: 0.3)], center: UnitPoint(x: 0.36, y: 0.3), startRadius: 0, endRadius: rect.width * 0.04))
                .overlay { Circle().stroke(.black.opacity(0.45), lineWidth: 2) }
                .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                .frame(width: rect.width * 0.056, height: rect.width * 0.056)
                .opacity(scene == .vinyl ? 1 : 0)
            if scene == .stars {
                Circle().strokeBorder(.white.opacity(0.16))
            }
        }
        .frame(width: rect.width, height: rect.height)
        .contentShape(.rect(cornerRadius: radius))
        .onTapGesture { app.player.toggle() }
        .offset(x: rect.minX, y: rect.minY)
        .accessibilityHidden(true)
    }
}

private struct SpinningArt: View, Animatable {
    let url: URL?
    var radius: CGFloat
    let spinning: Bool
    let upright: Bool

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    var body: some View { ArtLayer(url: url, radius: radius, spinning: spinning, upright: upright) }
}

private struct ArtLayer: NSViewRepresentable {
    let url: URL?
    let radius: CGFloat
    let spinning: Bool
    let upright: Bool

    func makeNSView(context: Context) -> ArtView { ArtView() }
    func updateNSView(_ view: ArtView, context: Context) {
        view.update(url: url, radius: radius)
        view.spin(spinning, upright: upright)
    }
}

private final class ArtView: LayerView {
    private let art = CALayer()
    private var spinner: Spinner!
    private var url: URL?
    private var started = false
    private var upright = true
    private var radius: CGFloat = 0

    override init() {
        super.init()
        art.masksToBounds = true
        art.contentsGravity = .resizeAspectFill
        art.minificationFilter = .trilinear
        art.backgroundColor = rgb(0x23252D)
        root.addSublayer(art)
        spinner = Spinner(art, period: ImmersiveView.spin)
    }

    func update(url next: URL?, radius: CGFloat) {
        if self.radius != radius {
            self.radius = radius
            needsLayout = true
        }
        guard !started || next != url else { return }
        started = true
        url = next
        // 小图先顶上，大图到了再换
        if let hit = ImageLoader.shared.cached(next, pixels: 800) { return put(hit, fade: art.contents != nil) }
        Task {
            guard let image = await ImageLoader.shared.image(next, pixels: 800), url == next else { return }
            put(image, fade: true)
        }
    }

    private func put(_ image: NSImage, fade: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if fade {
            let t = CATransition()
            t.type = .fade
            t.duration = 0.6
            art.add(t, forKey: "swap")
        }
        art.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        CATransaction.commit()
    }

    func spin(_ on: Bool, upright: Bool) {
        if upright {
            if !self.upright { spinner.straighten() }
        } else {
            spinner.set(on)
        }
        self.upright = upright
    }

    override func arrange(_ size: CGSize) {
        art.bounds = CGRect(origin: .zero, size: size)
        art.position = CGPoint(x: size.width / 2, y: size.height / 2)
        art.cornerRadius = min(radius, size.width / 2)
    }
}

// MARK: - 文字

private struct SongTitle: View {
    let song: Song
    let scene: ImmersiveScene
    let plan: Plan
    @Environment(AppModel.self) private var app

    var body: some View {
        let w = plan.size.width
        let note = app.player.error ?? song.artistText
        switch scene {
        case .vinyl:
            VStack(alignment: .leading, spacing: 0) {
                title(note, big: plan.clamp(26, w * 0.034, 60), small: plan.clamp(14, w * 0.0135, 24))
                LyricLineView(peek: true, big: plan.clamp(17, w * 0.019, 34), weight: .regular)
                    .frame(maxWidth: .infinity, minHeight: plan.clamp(17, w * 0.019, 34) * 5.8, alignment: .topLeading)
                    .padding(.top, plan.clamp(28, plan.size.height * 0.07, 84))
            }
            .frame(width: plan.vinylText.width, height: plan.size.height, alignment: .leading)
            .offset(x: plan.vinylText.minX)
        case .lyrics:
            title(note, big: plan.clamp(20, w * 0.02, 34), small: plan.clamp(13, w * 0.0115, 20))
                .frame(width: plan.lyricsCover.width, alignment: .topLeading)
                .offset(x: plan.lyricsCover.minX, y: plan.lyricsCover.maxY + plan.clamp(18, plan.size.height * 0.03, 36))
        case .stars:
            VStack(spacing: plan.clamp(10, w * 0.01, 18)) {
                LyricLineView(peek: false, big: plan.clamp(22, w * 0.026, 46), weight: .semibold)
                    .multilineTextAlignment(.center)
                Text("\(song.name) · \(note)")
                    .font(.system(size: plan.clamp(13, w * 0.0115, 20)))
                    .foregroundStyle(.white.opacity(0.62))
                    .id(song.mid)
                    .transition(.blurReplace)
            }
            .shadow(color: .black.opacity(0.6), radius: 7, y: 1)
            .animation(.smooth(duration: 0.5), value: song.mid)
            .frame(width: w * 0.8, height: plan.size.height - plan.clamp(120, plan.size.height * 0.17, 190), alignment: .bottom)
            .offset(x: w * 0.1)
        }
    }

    private func title(_ note: String, big: CGFloat, small: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: small * 0.5) {
            Text(song.name)
                .font(.system(size: big, weight: .semibold))
                .lineLimit(2)
            Text(note)
                .font(.system(size: small))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(2)
        }
        .id(song.mid)
        .transition(.blurReplace)
        .animation(.smooth(duration: 0.5), value: song.mid)
    }
}

/// 当前这一句歌词；peek 时第二行预告下一句
private struct LyricLineView: View {
    let peek: Bool
    let big: CGFloat
    let weight: Font.Weight
    @Environment(AppModel.self) private var app

    var body: some View {
        let lyrics = app.lyrics
        let line = lyrics.lines.indices.contains(lyrics.index) ? lyrics.lines[lyrics.index] : nil
        let next = lyrics.lines.indices.contains(lyrics.index + 1) ? lyrics.lines[lyrics.index + 1].text : ""
        let sub = line?.trans ?? (peek && line != nil ? next : "")
        ZStack(alignment: .topLeading) {
            VStack(alignment: peek ? .leading : .center, spacing: big * 0.4) {
                Text(line?.text ?? " ").font(.system(size: big, weight: weight))
                if !sub.isEmpty {
                    Text(sub).font(.system(size: big * (peek ? 0.78 : 0.6))).foregroundStyle(.white.opacity(peek ? 0.5 : 0.62))
                }
            }
            .id("\(lyrics.song?.mid ?? "")\(lyrics.index)")
            .transition(.blurReplace)
        }
        .animation(.smooth(duration: 0.45), value: lyrics.index)
    }
}

// MARK: - 歌词墙

private struct LyricsWall: View {
    let plan: Plan
    @Environment(AppModel.self) private var app
    @State private var mids: [Int: CGFloat] = [:]

    var body: some View {
        let lyrics = app.lyrics
        let now = max(0, lyrics.index)
        let size = plan.clamp(22, plan.size.width * 0.029, 52)
        // 让当前这一行停在画面中间偏上的位置
        let shift = plan.size.height * 0.44 - (mids[now] ?? 0)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { i, line in
                WallRow(line: line, far: i - now, current: i == lyrics.index, size: size, shift: shift) { app.player.seek(line.t) }
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("wall")).midY } action: { mids[i] = $0 }
            }
        }
        .coordinateSpace(.named("wall"))
        .frame(width: plan.lyricsText.width, alignment: .topLeading)
        .id(lyrics.song?.mid)
        .transition(.opacity)
        .animation(.smooth(duration: 0.5), value: lyrics.song?.mid)
        .frame(width: plan.lyricsText.width, height: plan.size.height, alignment: .topLeading)
        .clipped()
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0.04), .init(color: .black, location: 0.26), .init(color: .black, location: 0.66), .init(color: .clear, location: 0.92)], startPoint: .top, endPoint: .bottom)
        }
        .offset(x: plan.lyricsText.minX)
        .onChange(of: lyrics.song?.mid) { mids = [:] }
    }
}

private struct WallRow: View {
    let line: LyricLine
    let far: Int
    let current: Bool
    let size: CGFloat
    let shift: CGFloat
    let seek: () -> Void
    @State private var hovering = false

    var body: some View {
        // 看不见的行直接到位，只有附近的行做动画；每一行比上一行晚一点点动，像被带着走
        let near = abs(far) <= 9
        let late = Double(min(8, max(0, far + 2))) * 0.032
        Button(action: seek) {
            VStack(alignment: .leading, spacing: size * 0.14) {
                Text(line.text).font(.system(size: size, weight: .semibold))
                if let trans = line.trans { Text(trans).font(.system(size: size * 0.56)).opacity(0.75) }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, size * 0.36)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(current ? 1 : hovering ? 0.75 : 0.42 - Double(min(5, abs(far))) * 0.055)
        .scaleEffect(current ? 1 : 0.94, anchor: .leading)
        .animation(.easeOut(duration: 0.4), value: current)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .offset(y: shift)
        .animation(near ? .spring(duration: 0.8, bounce: 0.1).delay(late) : nil, value: shift)
        .onHover { hovering = $0 }
    }
}
