import SongforMeKit
import SwiftUI

/// 侧边栏只留和听歌有关的：推荐、我喜欢、最近播放、歌单；管理类的操作在底部的个人资料入口里
struct Sidebar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let selection = Binding<Page?>(get: { app.page }, set: { if let p = $0, p != app.page { app.go(p) } })
        let groups = app.sidebarGroups
        List(selection: selection) {
            Section {
                Label("为你推荐", systemImage: "sparkles").tag(Page.reco)
                if groups.count == 1 { shortcuts(groups[0]) }
            }
            // 只有一个音源时不提它的名字；有好几个才分开列
            if groups.count == 1 {
                lists(groups[0], title: "我的歌单")
                collected(groups[0])
            } else {
                ForEach(groups) { g in lists(g, title: g.name, all: true) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { AccountEntry() }
    }

    private func shortcuts(_ g: SidebarGroup) -> some View {
        ForEach(g.playlists.filter { $0.kind == .liked || $0.kind == .recent }) { p in
            Label(p.title, systemImage: p.kind == .liked ? "heart" : "clock").tag(Page.playlist(p.id))
        }
    }

    @ViewBuilder private func lists(_ g: SidebarGroup, title: String, all: Bool = false) -> some View {
        let own = g.playlists.filter { $0.kind == .own }
        let collected = all ? g.playlists.filter { $0.kind == .collected } : []
        if !own.isEmpty || g.canCreate || all {
            Section {
                if all { shortcuts(g) }
                ForEach(own) { p in Text(p.title).lineLimit(1).tag(Page.playlist(p.id)) }
                ForEach(collected) { p in Text(p.title).lineLimit(1).tag(Page.playlist(p.id)) }
            } header: {
                HStack {
                    Text(title)
                    Spacer()
                    if g.canCreate {
                        Button("新建歌单", systemImage: "plus") { NewPlaylist.prompt(app, in: g.id) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .help("新建歌单")
                            .padding(.trailing, 8)
                    }
                }
            }
        }
    }

    @ViewBuilder private func collected(_ g: SidebarGroup) -> some View {
        let list = g.playlists.filter { $0.kind == .collected }
        if !list.isEmpty {
            Section("收藏的歌单") {
                ForEach(list) { p in Text(p.title).lineLimit(1).tag(Page.playlist(p.id)) }
            }
        }
    }
}

// MARK: - 个人资料

struct AccountEntry: View {
    @Environment(AppModel.self) private var app
    @State private var open = false

    var body: some View {
        let login = app.signedOut.isEmpty ? "更多" : "登录"
        Button {
            open = true
        } label: {
            HStack(spacing: 10) {
                Avatar(profile: app.profile)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.primary.map(app.name) ?? login).lineLimit(1)
                    if app.syncing > 0 {
                        Text("正在同步到账号（\(app.syncing)）").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if Updater.shared.available != nil { Circle().fill(Theme.accent).frame(width: 6, height: 6) }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(MenuRowStyle())
        .padding(10)
        .popover(isPresented: $open, arrowEdge: .trailing) { AccountPanel { open = false }.environment(app) }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugPanel)) { _ in open = true }
        #endif
        .animation(.default, value: app.syncing)
    }
}

private struct Avatar: View {
    let profile: AccountProfile?
    var body: some View {
        ZStack {
            Circle().fill(Theme.accent.opacity(0.14))
            Image(systemName: "person.fill").font(.system(size: 13)).foregroundStyle(Theme.accent)
            if let text = profile?.avatar, let url = URL(string: text) {
                RemoteImage(url: url, pixels: 120).clipShape(.circle)
            }
        }
        .frame(width: 28, height: 28)
    }
}

/// 常用的几项：更新、登录、听歌报告、同步；其余的设置都在设置页里
struct AccountPanel: View {
    let close: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            let updater = Updater.shared
            if let release = updater.available {
                row(updater.status ?? "更新到 \(release.version)", "arrow.down.circle") { Task { await updater.install() } }
                    .disabled(updater.status != nil)
                Divider().padding(.vertical, 4)
            }
            ForEach(app.signedOut, id: \.info.id) { source in
                row("登录\(source.info.spaced)", "person.crop.circle") { Task { await app.login(source) } }
            }
            if !app.signedOut.isEmpty { Divider().padding(.vertical, 4) }
            row("听歌报告", "chart.bar") { app.openReport() }
            if app.loggedIn {
                row("同步曲库", "arrow.triangle.2.circlepath") { Task { await app.sync() } }.disabled(app.busy != nil)
            }
            Divider().padding(.vertical, 4)
            Button {
                close()
                app.go(.settings(.general))
            } label: {
                HStack {
                    Label("设置", systemImage: "gearshape")
                    Spacer()
                    Text("⌘,").foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(MenuRowStyle())
        }
        .padding(10)
        .frame(width: 250)
    }

    private func row(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button {
            close()
            action()
        } label: {
            Label(title, systemImage: icon)
        }
        .buttonStyle(MenuRowStyle())
    }
}
