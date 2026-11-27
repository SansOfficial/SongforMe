import SongforMeKit
import SwiftUI

/// 主区域：根据当前页面换内容
struct PageView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                switch app.page {
                case .reco: RecoPage()
                case .settings(let tab): SettingsPage(tab: tab)
                case .playlist(let id): PlaylistPage(id: id)
                case .artist(let a, let tab): ArtistPage(artist: a, tab: tab)
                case .album(let album, let artist): AlbumPage(album: album, artist: artist)
                case .search(let q, let kind, let source): SearchPageView(query: q, kind: kind, source: source)
                case .report(let period, _): ReportPage(period: period)
                }
            }
            .frame(maxWidth: 1080)
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        // 换了页面就回到顶部，不沿用上一页的滚动位置
        .id(app.page.identity)
        .transition(.opacity.combined(with: .offset(y: 8)))
    }
}

// MARK: - 列表

/// 列表为空时显示的那一行：加载中、加载失败（带重试）、或者确实没有内容，三种情况要分清
struct ListHint: View {
    let empty: String
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if app.content.loading {
                ProgressView().controlSize(.small)
            } else if let error = app.content.error {
                VStack(spacing: 12) {
                    Text("没有加载出来：\(error)")
                    Button("重试") { app.retry() }
                }
            } else {
                Text(empty)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 160)
    }
}

struct SongList: View {
    var empty = "这里还没有歌"
    var quietHeart = false
    @Environment(AppModel.self) private var app

    var body: some View {
        let songs = app.content.songs
        if songs.isEmpty {
            ListHint(empty: empty)
        } else {
            ForEach(Array(songs.enumerated()), id: \.element.mid) { i, song in
                SongRow(song: song, number: i + 1, quietHeart: quietHeart) { app.playList(from: song.mid) }
            }
            LoadMore()
        }
    }
}

/// 滚到底自动再加载一页
struct LoadMore: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        if app.hasMore {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 60)
                .task(id: app.content.songs.count + app.content.results.loaded) { await app.loadMore() }
        }
    }
}

struct PlayAllButton: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        PlayButton { app.playList() }.disabled(app.content.songs.isEmpty)
    }
}

// MARK: - 推荐

struct RecoPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let seeded = !app.likedMids.isEmpty && app.hasMusic
        PageHead(title: "为你推荐", covers: covers(of: app.batch.map(\.song))) {
            if seeded {
                if !app.batch.isEmpty { PlayButton { app.playBatch() } }
                Button(app.batch.isEmpty ? "生成推荐" : "换一批", systemImage: "arrow.clockwise") { Task { await app.generate() } }
                    .secondaryButton()
                    .disabled(app.busy != nil)
            }
        }
        if !app.ready {
            EmptyView()
        } else if !seeded {
            VStack(spacing: 14) {
                if !app.hasMusic {
                    NoSource()
                } else {
                    Text("先让它认识你的口味").font(.title3.bold())
                    if app.hub.all.contains(where: \.hasAccount) {
                        Text("登录后会读取你账号里的“我喜欢”、自建歌单和最近播放，全部只保存在这台设备上。").foregroundStyle(.secondary)
                    } else {
                        Text("搜几首喜欢的歌点上红心，就能开始推荐了。").foregroundStyle(.secondary)
                    }
                    if !app.loggedIn { LoginButtons() }
                    if app.localFolders.isEmpty {
                        Button("或者添加本地音乐文件夹…") { app.chooseLocalFolder() }.buttonStyle(.link)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        } else if app.batch.isEmpty {
            VStack(spacing: 10) {
                Text("还没有推荐").font(.title3.bold())
                Text("点上面的“生成推荐”，第一次大约要半分钟。").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        } else {
            ForEach(Array(app.batch.enumerated()), id: \.element.id) { i, r in
                SongRow(song: r.song, number: i + 1, recommended: true) { app.playBatch(from: r.song.mid) }
            }
        }
    }
}

/// 每个能登录的音源一个登录按钮
struct LoginButtons: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        HStack(spacing: 10) {
            ForEach(app.signedOut, id: \.info.id) { source in
                Button("登录\(source.info.spaced)") { Task { await app.login(source) } }
                    .primaryButton()
            }
        }
    }
}

// MARK: - 歌单

struct PlaylistPage: View {
    let id: String
    @Environment(AppModel.self) private var app
    @State private var confirming = false

    var body: some View {
        let meta = app.playlists.first { $0.id == id }
        let songs = app.content.songs
        PageHead(
            title: meta?.title ?? "歌单",
            covers: songs.isEmpty ? [meta?.cover.flatMap(URL.init(string:))].compactMap { $0 } : covers(of: songs),
            subtitle: Text("\(songs.isEmpty ? meta?.songCount ?? 0 : songs.count) 首")
        ) {
            PlayAllButton()
            if Playlist.isLiked(id) {
                Button("智能随机", systemImage: "sparkles") { app.playSmart() }
                    .secondaryButton()
                    .disabled(songs.isEmpty)
            }
            // 删除、移除这类低频又危险的操作收进“更多”菜单
            if meta?.kind == .imported || meta.map(app.canEdit) == true {
                Menu("歌单的更多操作", systemImage: "ellipsis") {
                    if meta?.kind == .imported {
                        Button("移除这个种子歌单", systemImage: "xmark") { Task { await app.removePlaylist(id) } }
                    } else {
                        Button("删除歌单", systemImage: "trash", role: .destructive) { confirming = true }
                    }
                }
                .labelStyle(.iconOnly)
                .menuIndicator(.hidden)
                .secondaryButton()
                .fixedSize()
            }
        }
        .confirmationDialog("确定删除歌单「\(meta?.title ?? "")」吗？", isPresented: $confirming) {
            Button("删除", role: .destructive) { if let meta { Task { await app.deletePlaylist(meta) } } }
        } message: {
            Text("账号里的这个歌单也会被删除。")
        }
        SongList(quietHeart: Playlist.isLiked(id))
    }
}

// MARK: - 歌手、专辑

struct ArtistPage: View {
    let artist: ArtistRef
    let tab: Page.ArtistTab
    @Environment(AppModel.self) private var app

    var body: some View {
        let count = tab == .songs ? max(app.content.total, app.content.songs.count) : app.content.albums.count
        PageHead(
            title: artist.name, covers: [Artwork.artist(artist.mid, 300)].compactMap { $0 }, round: true,
            subtitle: count > 0 ? Text(tab == .songs ? "\(count) 首" : "\(count) 张专辑") : nil
        ) {
            Picker("", selection: Binding(get: { tab }, set: { app.go(.artist(artist, $0)) })) {
                Text("全部歌曲").tag(Page.ArtistTab.songs)
                Text("专辑").tag(Page.ArtistTab.albums)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if tab == .songs { PlayAllButton() }
        }
        if tab == .songs {
            SongList()
        } else if app.content.albums.isEmpty {
            ListHint(empty: "没有找到专辑")
        } else {
            CardGrid {
                ForEach(app.content.albums) { a in
                    Card(url: a.artwork(300), title: a.name, meta: [String(a.date.prefix(4)), a.type].filter { !$0.isEmpty }.joined(separator: " · ")) {
                        app.go(.album(a, artist))
                    }
                }
            }
        }
    }
}

struct AlbumPage: View {
    let album: Album
    let artist: ArtistRef?
    @Environment(AppModel.self) private var app

    var body: some View {
        let count = app.content.songs.count
        PageHead(title: album.name, covers: [album.artwork(300) ?? app.content.songs.first?.artwork(300)].compactMap { $0 }, subtitle: count > 0 ? Text("\(count) 首") : nil) {
            PlayAllButton()
            if let artist, !artist.mid.isEmpty {
                Button(artist.name) { app.go(.artist(artist, .albums)) }.secondaryButton()
            }
        }
        SongList()
    }
}

struct CardGrid<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 220), spacing: 20)], spacing: 22) { content }
    }
}

/// 带封面的卡片：歌手、专辑
struct Card: View {
    let url: URL?
    let title: String
    let meta: String
    var round = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: round ? .center : .leading, spacing: 3) {
                RemoteImage(url: url, pixels: 300)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: round ? 200 : 10))
                    .shadow(color: .black.opacity(hovering ? 0.22 : 0.1), radius: hovering ? 12 : 5, y: hovering ? 6 : 2)
                    .scaleEffect(hovering ? 1.02 : 1)
                    .padding(.bottom, 6)
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(meta).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help(meta.isEmpty ? title : "\(title)\n\(meta)")
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.3), value: hovering)
    }
}

// MARK: - 搜索

/// 应用本身不带音源，一个都没接的时候说明一下
private struct NoSource: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        VStack(spacing: 14) {
            Text("还没有音乐").font(.title3.bold())
            Text("选一个放着 mp3、flac 的文件夹就能听本地音乐；想听在线的，可以添加一个社区插件。").foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("添加音乐文件夹…") { app.chooseLocalFolder() }
                    .primaryButton()
                Button("添加插件…") { app.adding = true }
                    .secondaryButton()
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct SearchPageView: View {
    let query: String
    let kind: SearchKind
    let source: String
    @Environment(AppModel.self) private var app

    private func title(_ k: SearchKind) -> String {
        switch k {
        case .song: "歌曲"
        case .singer: "歌手"
        case .album: "专辑"
        }
    }

    var body: some View {
        let r = app.content.results
        PageHead(title: query, subtitle: r.total > 0 ? Text(r.total >= 999 && kind == .song ? "999+ 个结果" : "\(r.total) 个结果") : nil) {
            if app.hub.all.count > 1 {
                Picker("", selection: Binding(get: { source }, set: { app.search(query, kind, in: $0) })) {
                    ForEach(app.hub.all.map(\.info), id: \.id) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            Picker("", selection: Binding(get: { kind }, set: { app.search(query, $0) })) {
                ForEach(SearchKind.allCases, id: \.self) { Text(title($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        let needsLogin = app.hub.named(source).map { $0.searchNeedsLogin && !app.loggedIn($0) } ?? false
        let empty = needsLogin ? "搜索需要先登录\(app.hub.named(source)?.info.spaced ?? "")" : "没有找到和“\(query)”有关的\(title(kind))"
        if !app.hasMusic {
            NoSource().frame(minHeight: 260)
        } else if kind == .song {
            SongList(empty: empty)
        } else if r.loaded == 0 {
            ListHint(empty: empty)
        } else {
            CardGrid {
                if kind == .singer {
                    ForEach(r.singers) { a in
                        Card(url: URL(string: a.pic), title: a.name, meta: [(a.songCount, "首歌"), (a.albumCount, "张专辑")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · "), round: true) {
                            app.go(.artist(ArtistRef(mid: a.mid, name: a.name), .songs))
                        }
                    }
                } else {
                    ForEach(r.albums) { a in
                        Card(url: a.artwork(300), title: a.name, meta: ([a.singers.map(\.name).joined(separator: " / "), String(a.date.prefix(4))]).filter { !$0.isEmpty }.joined(separator: " · ")) {
                            app.go(.album(a, a.singers.first.map { ArtistRef(mid: $0.mid, name: $0.name) }))
                        }
                    }
                }
            }
            LoadMore()
        }
    }
}

extension SearchResults {
    /// 已经加载出来的条数
    var loaded: Int { songs.count + singers.count + albums.count }
}
