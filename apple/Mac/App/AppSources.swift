import AppKit
import SongforMeKit
import UniformTypeIdentifiers

/// 正在填哪个音源的服务器、账号
struct SourceSetup: Identifiable {
    var source: ScriptSource
    var id: String { source.info.id }
}

// 在应用里添加、移除插件
extension AppModel {
    /// 添加进来的插件（不含编译时带上的）
    var scripts: [ScriptSource] { hub.all.compactMap { $0 as? ScriptSource } }

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.javaScript]
        panel.message = "选择插件文件（.js）"
        panel.prompt = "添加"
        Task {
            guard await panel.begin() == .OK, let url = panel.url else { return }
            await addSource(url)
        }
    }

    func addSource(_ url: URL, confirm: Bool = true) async {
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= ScriptDownload.maxSize else { throw SourceError("这个文件太大，不像插件") }
            await addSource(script: try ScriptDownload.check(Data(contentsOf: url)), confirm: confirm)
        } catch {
            say("没有添加：\(error.localizedDescription)", error: true)
        }
    }

    /// from 是从哪个网站下载的
    func addSource(script text: String, from host: String? = nil, confirm: Bool = true) async {
        do {
            let source = try await ScriptSource(script: text)
            let old = hub.named(source.info.id)
            if let old, !(old is ScriptSource) { throw SourceError("已经自带\(old.info.spaced)了") }
            if confirm { guard await agree(source, replacing: old?.info.name, from: host) else { return } }
            // 更新时，连的地方和要填的都没变才沿用填过的账号，免得换了个文件就把密码带走
            attach(source)
            if let old = old as? ScriptSource, old.hosts == source.hosts, old.fields == source.fields, old.site == source.site {
                try source.apply(old.settings)
            } else {
                shelf.remove(source.info.id)
                await source.logout()
            }
            try shelf.add(source, script: text)
            await install(source)
            say("已\(old == nil ? "添加" : "更新")\(source.info.spaced)")
            if source.hasAccount, !loggedIn(source) { await login(source) }
        } catch {
            say("没有添加：\(error.localizedDescription)", error: true)
        }
    }

    /// 给要打开网页登录的音源一个存登录状态的地方
    func attach(_ source: ScriptSource) {
        guard let site = source.site else { return }
        source.use(WebSession(script: source.info.id, name: source.info.name, home: site.url))
    }

    private func agree(_ source: ScriptSource, replacing old: String?, from host: String?) async -> Bool {
        var places = source.hosts
        for host in source.site?.hosts ?? [] where !places.contains(host) { places.append(host) }
        if source.fields.contains(where: { $0.kind == .server }) { places.append("你填写的服务器") }
        return await ask(
            old.map { "用“\(source.info.name)”替换“\($0)”？" } ?? "添加插件“\(source.info.name)”？",
            (host.map { "来自 \($0)。" } ?? "") + (places.isEmpty ? "它不会联网。" : "它会连接：\(places.joined(separator: "、"))。")
                + (source.site.map { "\n\n它会打开 \($0.url.host() ?? "") 让你登录，登录后能以你的身份访问 \($0.hosts.joined(separator: "、"))。" } ?? "")
                + "\n\n插件是别人写的程序，只添加你信任的。",
            button: old == nil ? "添加" : "替换"
        )
    }

    func askRemove(_ source: ScriptSource) {
        Task {
            guard await ask("移除插件“\(source.info.name)”？", "登录状态和填过的账号会一起删除，听歌记录会保留。", button: "移除") else { return }
            await removeSource(source)
        }
    }

    /// 挂在窗口上问，不用 runModal：那会占住主线程，弹着的时候歌放完了也切不了
    private func ask(_ title: String, _ text: String, button: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        // 同意要点按钮：刚在表单里按过回车，连按一下不能就算同意了
        alert.addButton(withTitle: button).keyEquivalent = ""
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }) else {
            return alert.runModal() == .alertFirstButtonReturn
        }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    func removeSource(_ source: ScriptSource) async {
        shelf.remove(source.info.id)
        await source.logout()
        await uninstall(source)
        say("已移除\(source.info.spaced)")
    }

    /// 存下填好的设置并检查能不能用；不行时返回原因，原来的设置不变
    func saveSettings(_ source: ScriptSource, _ values: [String: String]) async -> String? {
        let old = source.settings
        do {
            try source.apply(values)
            guard source.filled else { throw SourceError("还有没填的") }
            if source.site == nil { _ = try await source.profile() }
            try shelf.save(source)
        } catch {
            try? source.apply(old)
            return error.localizedDescription
        }
        settingUp = nil
        Task { if source.site == nil { await entered(source) } else { await login(source) } }
        return nil
    }
}
