import SongforMeKit
import SwiftUI

struct SongRow: View {
    let song: Song
    let number: Int
    /// 推荐页才有：听腻了 / 不喜欢
    var recommended = false
    /// “我喜欢”里每首都是点亮的爱心，常驻显示只是噪音，只在鼠标经过时出现
    var quietHeart = false
    let play: () -> Void

    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        let current = app.player.current?.song.mid == song.mid
        let blocked = app.player.unplayable.contains(song.mid)
        HStack(spacing: 12) {
            Button {
                if current { app.player.toggle() } else { play() }
            } label: {
                ZStack {
                    if hovering {
                        Image(systemName: current && app.player.playing ? "pause.fill" : "play.fill").foregroundStyle(.primary)
                    } else if current {
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative, isActive: app.player.playing)
                            .foregroundStyle(Theme.accent)
                    } else {
                        Text("\(number)").monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 13))
                .frame(width: 34, height: 34)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("播放 \(song.name)")

            CoverView(song: song)

            VStack(alignment: .leading, spacing: 3) {
                Text(song.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(current ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                ArtistLinks(song: song)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                if hovering {
                    if recommended {
                        IconButton(icon: "hand.thumbsdown", label: "不喜欢", size: 13) { app.reject(song, .dislike) }
                        IconButton(icon: "moon.zzz", label: "听腻了", size: 13) { app.reject(song, .tired) }
                    }
                    if app.canEditPlaylists(for: song) { AddToPlaylistButton(song: song) }
                }
                if hovering || !quietHeart { HeartButton(song: song) }
            }
            .animation(.easeOut(duration: 0.12), value: hovering)

            Text(clock(song.duration))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .opacity(blocked ? 0.4 : 1)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(current ? AnyShapeStyle(Theme.accent.opacity(0.09)) : AnyShapeStyle(.primary.opacity(hovering ? 0.045 : 0)))
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: play)
        .contextMenu { SongMenu(song: song, play: play) }
        .help(blocked ? "当前账号无法播放" : "")
    }
}

/// 右键菜单
struct SongMenu: View {
    let song: Song
    var play: (() -> Void)?
    @Environment(AppModel.self) private var app

    var body: some View {
        if let play { Button("播放", systemImage: "play", action: play) }
        Button(app.hearts.contains(song.mid) ? "取消喜欢" : "喜欢", systemImage: "heart") { app.toggleLike(song) }
        if app.canEditPlaylists(for: song) {
            Menu("加入歌单", systemImage: "plus") {
                ForEach(app.ownPlaylists(for: song)) { p in
                    Button(p.title) { Task { await app.add(song, to: p) } }
                }
                Divider()
                Button("新建歌单…") { NewPlaylist.prompt(app, with: song) }
            }
        }
        Divider()
        ForEach(song.singers.filter { !$0.mid.isEmpty }, id: \.mid) { s in
            Button("查看 \(s.name)", systemImage: "person") { app.open(s) }
        }
        if !song.albumMid.isEmpty {
            Button("查看专辑", systemImage: "opticaldisc") {
                app.openAlbum(of: song)
            }
        }
        Divider()
        Button("听腻了", systemImage: "moon.zzz") { app.reject(song, .tired) }
        Button("不喜欢", systemImage: "hand.thumbsdown") { app.reject(song, .dislike) }
    }
}

struct AddToPlaylistButton: View {
    let song: Song
    @Environment(AppModel.self) private var app
    @State private var open = false

    var body: some View {
        IconButton(icon: "plus", label: "加入歌单", size: 13) { open = true }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                AddToPlaylistPanel(song: song) { open = false }.environment(app)
            }
    }
}

struct AddToPlaylistPanel: View {
    let song: Song
    let close: () -> Void
    @Environment(AppModel.self) private var app
    @State private var name = ""

    var body: some View {
        let own = app.ownPlaylists(for: song)
        VStack(alignment: .leading, spacing: 8) {
            Text("加入歌单").font(.headline)
            if own.isEmpty {
                Text("还没有自建歌单").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(own) { p in
                            Button {
                                close()
                                Task { await app.add(song, to: p) }
                            } label: {
                                HStack {
                                    Text(p.title).lineLimit(1)
                                    Spacer()
                                    Text("\(p.songCount)").foregroundStyle(.tertiary).monospacedDigit()
                                }
                            }
                            .buttonStyle(MenuRowStyle())
                        }
                    }
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: own.count < 7)
            }
            HStack {
                TextField("新建歌单并加入", text: $name).textFieldStyle(.roundedBorder).onSubmit(create)
                Button("新建", action: create).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 250)
    }

    private func create() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        close()
        Task { await app.createPlaylist(name, with: song) }
    }
}

/// 弹出面板里的一行
struct MenuRowStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.primary.opacity(hovering && enabled ? (configuration.isPressed ? 0.12 : 0.07) : 0), in: .rect(cornerRadius: 7))
            .contentShape(.rect)
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovering = $0 }
    }
}

enum NewPlaylist {
    /// 问一个名字，建好（可以顺便放进一首歌）
    static func prompt(_ app: AppModel, with song: Song? = nil, in source: String? = nil) {
        let alert = NSAlert()
        alert.messageText = song.map { "新建歌单并加入《\($0.name)》" } ?? "新建歌单"
        alert.addButton(withTitle: "新建")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "歌单名"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        Task { await app.createPlaylist(name, with: song, in: source) }
    }
}
