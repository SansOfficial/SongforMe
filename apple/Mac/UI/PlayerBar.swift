import SongforMeKit
import SwiftUI

struct PlayerBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 16) {
            NowPart().frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 2) {
                Transport()
                ProgressRow()
            }
            .frame(minWidth: 260, idealWidth: 380, maxWidth: 440)
            .layoutPriority(1)
            SideControls().frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glass(in: .rect(cornerRadius: 22))
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }
}

/// 左边：封面、歌名、歌手
private struct NowPart: View {
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        let player = app.player
        HStack(spacing: 12) {
            if let item = player.current {
                let song = item.song
                Button { Immersive.shared.toggle() } label: {
                    RemoteImage(url: song.artwork(150), pixels: 150, crossfade: true)
                        .frame(width: 48, height: 48)
                        .overlay {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.black.opacity(0.4))
                                .opacity(hovering ? 1 : 0)
                        }
                        .clipShape(.rect(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: hovering)
                .help("全屏（F）")
                .accessibilityLabel("全屏")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        if item.extra { ExtraMark() }
                        Text(song.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    }
                    Group {
                        if let error = player.error {
                            Text(error).lineLimit(1).help(error)
                        } else {
                            ArtistLinks(song: song)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                .id(song.mid)
                .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(.tertiary)
                    .frame(width: 48, height: 48)
                    .background(.primary.opacity(0.05), in: .rect(cornerRadius: 9))
                Text(player.error ?? (app.batch.isEmpty ? "选一首歌开始听" : "从这批推荐开始听"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .animation(.easeOut(duration: 0.3), value: player.current?.song.mid)
    }
}

/// 中间：播放方式、上一首、播放、下一首、播放队列（刘海里地方小，只留中间三个）
struct Transport: View {
    var big: CGFloat = 1
    var tint: Color = Theme.accent
    var ink: Color = .white
    var compact = false
    @Environment(AppModel.self) private var app

    var body: some View {
        let player = app.player
        let none = player.current == nil
        HStack(spacing: 10 * big) {
            if !compact { PlayModeButton(size: 14 * big, tint: tint) }
            IconButton(icon: "backward.fill", label: "上一首", size: 16 * big) { player.previous() }.disabled(none)
            Button { app.togglePlay() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 17 * big))
                    .contentTransition(.symbolEffect(.replace.downUp))
                    .frame(width: 38 * big, height: 38 * big)
                    .foregroundStyle(ink)
                    .background(tint, in: .circle)
                    .overlay {
                        if player.loading { LoadingRing(color: ink) }
                    }
            }
            .buttonStyle(PressStyle())
            .disabled(!app.canPlay)
            .help(player.playing ? "暂停" : "播放")
            .accessibilityLabel(player.playing ? "暂停" : "播放")
            IconButton(icon: "forward.fill", label: "下一首", size: 16 * big) { player.next() }.disabled(none)
            if !compact { QueueButton(size: 14 * big) }
        }
    }
}

struct PressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.45), value: configuration.isPressed)
    }
}

private struct LoadingRing: View {
    let color: Color
    @State private var turning = false
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .padding(2)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
    }
}

/// 播放方式：点一下换下一种，右键直接选
struct PlayModeButton: View {
    var size: CGFloat = 14
    var tint: Color = Theme.accent
    @Environment(AppModel.self) private var app
    var body: some View {
        let mode = app.playMode
        IconButton(icon: mode.icon, label: "\(mode.title)（点一下切换）", size: size, active: mode != .order, tint: tint) { app.cyclePlayMode() }
            .overlay(alignment: .topTrailing) {
                if mode == .smart {
                    Image(systemName: "sparkle").font(.system(size: size * 0.6, weight: .bold)).foregroundStyle(tint).allowsHitTesting(false)
                }
            }
            .contextMenu {
                Picker("播放方式", selection: Binding { app.playMode } set: { app.setPlayMode($0) }) {
                    ForEach(app.playModes, id: \.self) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
                .pickerStyle(.inline)
            }
    }
}

struct ProgressRow: View {
    var tint: Color = Theme.accent
    var track: Color = .primary.opacity(0.12)
    @Environment(AppModel.self) private var app
    @State private var dragging: Double?

    var body: some View {
        let player = app.player
        let at = min(dragging ?? player.position, max(player.duration, 0))
        HStack(spacing: 8) {
            Text(clock(at)).frame(width: 36, alignment: .trailing)
            SeekBar(value: player.position, total: player.duration, tint: tint, track: track, seek: { player.seek($0) }, dragging: $dragging)
                .disabled(player.current == nil)
            Text(clock(player.duration)).frame(width: 36, alignment: .leading)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
}

/// 右边：喜欢、更多、音量、桌面歌词
private struct SideControls: View {
    @Environment(AppModel.self) private var app
    @Environment(DesktopLyrics.self) private var desktop
    @State private var adding = false

    var body: some View {
        HStack(spacing: 2) {
            if let item = app.player.current {
                HeartButton(song: item.song, size: 15)
                // 加入歌单、听腻了、不喜欢用得少，收进“更多”
                Menu {
                    if app.canEditPlaylists(for: item.song) { Button("加入歌单…", systemImage: "plus") { adding = true } }
                    if item.source == .reco { Button("听腻了", systemImage: "moon.zzz") { app.reject(item.song, .tired) } }
                    Button("不喜欢", systemImage: "hand.thumbsdown") { app.reject(item.song, .dislike) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium)).frame(width: 28, height: 28).contentShape(.circle)
                }
                .menuStyle(.button)
                .buttonStyle(IconButtonStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .help("这首歌的更多操作")
                .popover(isPresented: $adding, arrowEdge: .top) {
                    AddToPlaylistPanel(song: item.song) { adding = false }.environment(app)
                }
            }
            VolumeButton()
            Button { desktop.toggle() } label: {
                Text("词").font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28).contentShape(.circle)
            }
            .buttonStyle(IconButtonStyle(active: desktop.visible))
            .help(desktop.visible ? "关闭桌面歌词（右键还有刘海歌词）" : "打开桌面歌词（右键还有刘海歌词）")
            .accessibilityLabel("桌面歌词")
            .contextMenu {
                Toggle("桌面歌词", isOn: Binding { desktop.visible } set: { _ in desktop.toggle() })
                Toggle("刘海歌词", isOn: Binding { NotchLyrics.shared.visible } set: { _ in NotchLyrics.shared.toggle() })
            }
            // 锁定在歌词窗口上操作；锁住后鼠标点不到它，只能在这里解锁
            if desktop.visible, desktop.locked {
                IconButton(icon: "lock.fill", label: "解锁桌面歌词", size: 12) { desktop.locked = false }
            }
        }
    }
}

struct VolumeButton: View {
    var size: CGFloat = 14
    @Environment(AppModel.self) private var app
    @State private var open = false

    var body: some View {
        let prefs = app.player.prefs
        let silent = prefs.muted || prefs.volume == 0
        IconButton(icon: silent ? "speaker.slash.fill" : "speaker.wave.2.fill", label: "音量", size: size) { open = true }
            .popover(isPresented: $open, arrowEdge: .top) {
                HStack(spacing: 8) {
                    IconButton(icon: silent ? "speaker.slash.fill" : "speaker.wave.2.fill", label: silent ? "取消静音" : "静音", size: 13) { app.player.toggleMute() }
                    Slider(value: Binding(get: { silent ? 0 : prefs.volume }, set: { app.player.setVolume($0) }), in: 0...1)
                        .tint(Theme.accent)
                        .frame(width: 130)
                        .accessibilityLabel("音量")
                    Text("\(Int(((silent ? 0 : prefs.volume) * 100).rounded()))").monospacedDigit().foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
    }
}

struct QueueButton: View {
    var size: CGFloat = 14
    @Environment(AppModel.self) private var app
    @State private var open = false

    var body: some View {
        IconButton(icon: "list.bullet", label: "播放队列", size: size) { open = true }
            .disabled(app.player.queue.isEmpty)
            .popover(isPresented: $open, arrowEdge: .top) { QueuePanel().environment(app) }
    }
}

private struct QueuePanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let player = app.player
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("播放队列").font(.headline)
                Spacer()
                Text("\(player.queue.count) 首").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // 打开时和切歌后，让正在放的那首留在最上面
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(player.queue.enumerated()), id: \.element.id) { i, item in
                            QueueRow(item: item, current: i == player.index, past: i < player.index) {
                                if i == player.index { player.toggle() } else { player.playAt(i) }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .onAppear { if let id = player.current?.id { proxy.scrollTo(id, anchor: .top) } }
                .onChange(of: player.current?.id) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .top) } }
                }
            }
        }
        .frame(width: 340, height: 440)
    }
}

private struct QueueRow: View {
    let item: QueueItem
    let current: Bool
    let past: Bool
    let play: () -> Void
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: play) {
                HStack(spacing: 10) {
                    CoverView(song: item.song, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if item.extra { ExtraMark() }
                            Text(item.song.name).lineLimit(1)
                        }
                        .foregroundStyle(current ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
                        Text(item.song.artistText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if hovering, !current {
                IconButton(icon: "xmark", label: "从队列移除 \(item.song.name)", size: 11) { app.player.remove(item.song.mid) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.primary.opacity(hovering ? 0.06 : 0), in: .rect(cornerRadius: 8))
        .opacity(past ? 0.5 : 1)
        .onHover { hovering = $0 }
    }
}
