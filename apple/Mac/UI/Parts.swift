import SongforMeKit
import SwiftUI

/// 图标按钮：悬停有底色，按下会缩一下
struct IconButton: View {
    let icon: String
    let label: String
    var size: CGFloat = 14
    var active = false
    var tint: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .contentTransition(.symbolEffect(.replace.downUp))
                .frame(width: size * 2, height: size * 2)
                .contentShape(.circle)
        }
        .buttonStyle(IconButtonStyle(active: active, tint: tint))
        .help(label)
        .accessibilityLabel(label)
    }
}

struct IconButtonStyle: ButtonStyle {
    var active = false
    var tint: Color = Theme.accent
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? AnyShapeStyle(tint) : AnyShapeStyle(hovering ? .primary : .secondary))
            .opacity(enabled ? 1 : 0.35)
            .background(.primary.opacity(hovering && enabled ? 0.07 : 0), in: .circle)
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

struct HeartButton: View {
    let song: Song
    var size: CGFloat = 14
    @Environment(AppModel.self) private var app
    @State private var beat = 0

    var body: some View {
        let liked = app.hearts.contains(song.mid)
        Button {
            if !liked { beat += 1 }
            app.toggleLike(song)
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.system(size: size, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: beat)
                .frame(width: size * 2, height: size * 2)
                .contentShape(.circle)
        }
        .buttonStyle(IconButtonStyle(active: liked, tint: Theme.heart))
        .help(liked ? "取消喜欢" : "喜欢")
        .accessibilityLabel(liked ? "取消喜欢" : "喜欢")
    }
}

struct CoverView: View {
    let song: Song
    var size: CGFloat = 42
    var body: some View {
        RemoteImage(url: song.artwork(size > 90 ? 300 : 150), pixels: Int(size * 2))
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: min(8, size * 0.16)))
            .accessibilityHidden(true)
    }
}

/// 歌手名：每一位都能点开他的作品页
struct ArtistLinks: View {
    let song: Song
    @Environment(AppModel.self) private var app

    var body: some View {
        // 列表行里文字要能省略号截断，所以拼成一段带链接的文字
        Text(text)
            .lineLimit(1)
            .tint(.secondary)
            .environment(\.openURL, OpenURLAction { url in
                if let i = Int(url.lastPathComponent), song.singers.indices.contains(i) { app.open(song.singers[i]) }
                return .handled
            })
    }

    private var text: AttributedString {
        var out = AttributedString()
        for (i, s) in song.singers.enumerated() {
            if i > 0 { out += AttributedString(" / ") }
            var part = AttributedString(s.name)
            if !s.mid.isEmpty { part.link = URL(string: "artist://a/\(i)") }
            out += part
        }
        return out
    }
}

/// 智能随机穿插进来的推荐歌，歌名前的小星星
struct ExtraMark: View {
    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.accent)
            .help("推荐")
            .accessibilityLabel("推荐")
    }
}

/// 每一页的页头：左边封面，右边标题、一行说明，操作按钮跟在标题下面
struct PageHead<Actions: View>: View {
    let title: String
    var covers: [URL] = []
    var round = false
    var subtitle: Text?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            if !covers.isEmpty { CoverStack(urls: covers, round: round) }
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(1)
                    .help(title)
                if let subtitle {
                    subtitle.foregroundStyle(.secondary)
                }
                HStack(spacing: 10) { actions }
                    .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .padding(.bottom, 18)
    }
}

/// 叠在一起的几张封面，放在页头；只有一张时就是一张普通封面
struct CoverStack: View {
    let urls: [URL]
    var round = false
    @State private var spread = false

    var body: some View {
        ZStack {
            ForEach(Array(urls.prefix(3).enumerated().reversed()), id: \.element) { i, url in
                RemoteImage(url: url, pixels: 300)
                    .frame(width: 128, height: 128)
                    .clipShape(.rect(cornerRadius: round ? 64 : 12))
                    .overlay { RoundedRectangle(cornerRadius: round ? 64 : 12).strokeBorder(.black.opacity(0.06)) }
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
                    .scaleEffect(1 - CGFloat(i) * 0.1)
                    .rotationEffect(.degrees(spread ? Double(i) * 4 : 0))
                    .offset(x: spread ? CGFloat(i) * 26 : 0)
            }
        }
        .padding(.trailing, CGFloat(min(urls.count, 3) - 1) * 22)
        .onAppear { withAnimation(.spring(duration: 0.6, bounce: 0.25)) { spread = true } }
        .accessibilityHidden(true)
    }
}

/// 页头的主按钮：播放
struct PlayButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("播放", systemImage: "play.fill").padding(.horizontal, 6)
        }
        .primaryButton()
    }
}

// macOS 26 用玻璃，更早的系统（15）换成毛玻璃材质和普通按钮
extension View {
    /// 页头的次要按钮
    @ViewBuilder func secondaryButton() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glass).controlSize(.large) } else { buttonStyle(.bordered).controlSize(.large) }
    }

    /// 主按钮：强调色
    @ViewBuilder func primaryButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent).controlSize(.large).tint(Theme.accent)
        } else {
            buttonStyle(.borderedProminent).controlSize(.large).tint(Theme.accent)
        }
    }

    /// 浮在内容上的一层
    @ViewBuilder func glass(in shape: some Shape, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        }
    }
}

func covers(of songs: [Song]) -> [URL] {
    var out: [URL] = []
    for s in songs {
        guard let url = s.artwork(300), !out.contains(url) else { continue }
        out.append(url)
        if out.count == 3 { break }
    }
    return out
}

/// 细进度条：悬停变粗，拖动时只动滑块，松手才真的跳过去
struct SeekBar: View {
    let value: Double
    let total: Double
    var tint: Color = Theme.accent
    var track: Color = .primary.opacity(0.12)
    let seek: (Double) -> Void
    /// 拖到哪里了，时间数字跟着变
    @Binding var dragging: Double?
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        GeometryReader { geo in
            let active = (hovering || dragging != nil) && enabled
            let height: CGFloat = active ? 6 : 4
            let at = min(1, max(0, (dragging ?? value) / max(total, 0.01)))
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(tint).frame(width: geo.size.width * at)
            }
            .frame(height: height)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: geo.size.width * at - 6)
                    .opacity(active ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragging = min(1, max(0, $0.location.x / geo.size.width)) * total }
                    .onEnded { g in
                        seek(min(1, max(0, g.location.x / geo.size.width)) * total)
                        dragging = nil
                    }
            )
            .animation(.easeOut(duration: 0.15), value: active)
        }
        .frame(height: 16)
        .onHover { hovering = $0 }
        .opacity(enabled ? 1 : 0.5)
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(clock(value))，共 \(clock(total))")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 5.0 : -5.0
            seek(min(total, max(0, value + step)))
        }
    }
}
