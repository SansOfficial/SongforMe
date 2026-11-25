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

/// 管理类的操作（同步、调校、导入种子歌单、外观、退出）都收在这里
struct AccountPanel: View {
    let close: () -> Void
    @Environment(AppModel.self) private var app
    /// 打开了哪个二级页面
    private enum Sub { case seeds, sources }
    @State private var sub: Sub?
    @State private var appearance = Appearance.current

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch sub {
            case .seeds: seeds
            case .sources: sources
            case nil: main
            }
        }
        .padding(10)
        .frame(width: 250)
        .animation(.snappy(duration: 0.22), value: sub)
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugPanel)) { if $0.object as? String == "sources" { sub = .sources } }
        #endif
    }

    @ViewBuilder private var main: some View {
        ForEach(app.signedOut, id: \.info.id) { source in
            row("登录\(source.info.spaced)", "person.crop.circle") { Task { await app.login(source) } }
        }
        if !app.signedOut.isEmpty { Divider().padding(.vertical, 4) }
        row("听歌报告", "chart.bar") { app.openReport() }
        row("算法调校", "slider.horizontal.3") { app.go(.tuning) }
        Button { sub = .seeds } label: {
            HStack {
                Label("口味种子歌单", systemImage: "leaf")
                Spacer()
                let n = app.playlists.count { $0.kind == .imported }
                if n > 0 { Text("\(n)").foregroundStyle(.tertiary) }
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(MenuRowStyle())
        Button { sub = .sources } label: {
            HStack {
                Label("音源", systemImage: "music.note.house")
                Spacer()
                if !app.hub.all.isEmpty { Text("\(app.hub.all.count)").foregroundStyle(.tertiary) }
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(MenuRowStyle())
        if app.loggedIn {
            row("同步曲库", "arrow.triangle.2.circlepath") { Task { await app.sync() } }.disabled(app.busy != nil)
        }
        Divider().padding(.vertical, 4)
        Picker("外观", selection: $appearance) {
            ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.vertical, 2)
        .onChange(of: appearance) { Appearance.current = appearance }
        let signedIn = app.hub.all.filter { app.loggedIn($0) }
        if !signedIn.isEmpty { Divider().padding(.vertical, 4) }
        ForEach(signedIn, id: \.info.id) { source in
            let title = app.hub.all.count(where: \.hasAccount) > 1 ? "退出\(source.info.spaced)" : "退出登录"
            row(title, "rectangle.portrait.and.arrow.right") { Task { await app.logout(source) } }
        }
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

    // 二级页面：音源文件的添加和移除
    @ViewBuilder private var sources: some View {
        Button { sub = nil } label: { Label("音源", systemImage: "chevron.left").font(.headline) }
            .buttonStyle(MenuRowStyle())
        ForEach(app.hub.all, id: \.info.id) { source in
            HStack(spacing: 0) {
                Text(source.info.name).lineLimit(1)
                Spacer(minLength: 6)
                if let script = source as? ScriptSource {
                    if script.hasAccount {
                        IconButton(icon: "gearshape", label: "设置\(source.info.spaced)", size: 11) {
                            close()
                            app.settingUp = SourceSetup(source: script)
                        }
                    }
                    IconButton(icon: "xmark", label: "移除\(source.info.spaced)", size: 11) {
                        close()
                        app.askRemove(script)
                    }
                } else {
                    Text("自带").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(minHeight: 28)
            .padding(.horizontal, 8)
        }
        row("添加音源…", "plus") { app.chooseSource() }
    }

    // 二级页面：导入公开歌单当口味种子，查看、移除已导入的
    @State private var link = ""

    @ViewBuilder private var seeds: some View {
        let list = app.playlists.filter { $0.kind == .imported }
        Button { sub = nil } label: { Label("口味种子歌单", systemImage: "chevron.left").font(.headline) }
            .buttonStyle(MenuRowStyle())
        Text("导入的歌会计入你的口味。").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
        HStack {
            TextField("粘贴歌单链接或歌单号", text: $link).textFieldStyle(.roundedBorder).onSubmit(submit)
            Button("导入", action: submit).disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || app.busy != nil)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        if list.isEmpty { Text("还没有导入的歌单").foregroundStyle(.secondary).padding(8) }
        ForEach(list) { p in
            HStack(spacing: 0) {
                Button {
                    close()
                    app.go(.playlist(p.id))
                } label: {
                    HStack {
                        Text(p.title).lineLimit(1)
                        Spacer()
                        Text("\(p.songCount)").foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(MenuRowStyle())
                IconButton(icon: "xmark", label: "移除种子歌单「\(p.title)」", size: 11) { Task { await app.removePlaylist(p.id) } }
            }
        }
    }

    private func submit() {
        let text = link
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            await app.importSeed(text)
            link = ""
        }
    }
}
