import AppKit
import SongforMeKit
import UniformTypeIdentifiers

/// 正在填哪个音源的服务器、账号
struct SourceSetup: Identifiable {
    var source: ScriptSource
    var id: String { source.info.id }
}

// 在应用里添加、移除音源文件
extension AppModel {
    /// 添加进来的音源文件（不含编译时带上的）
    var scripts: [ScriptSource] { hub.all.compactMap { $0 as? ScriptSource } }

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.javaScript]
        panel.message = "选择音源文件（.js）"
        panel.prompt = "添加"
        Task {
            guard await panel.begin() == .OK, let url = panel.url else { return }
            await addSource(url)
        }
    }

    func addSource(_ url: URL, confirm: Bool = true) async {
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 2 << 20 else { throw SourceError("这个文件太大，不像音源文件") }
            let text = String(decoding: data, as: UTF8.self)
            let source = try await ScriptSource(script: text)
            let old = hub.named(source.info.id)
            if let old, !(old is ScriptSource) { throw SourceError("已经自带\(old.info.spaced)了") }
            if confirm { guard await agree(source, replacing: old?.info.name) else { return } }
            // 更新时，连的地方和要填的都没变才沿用填过的账号，免得换了个文件就把密码带走
            if let old = old as? ScriptSource, old.hosts == source.hosts, old.fields == source.fields {
                try source.apply(old.settings)
            } else {
                shelf.remove(source.info.id)
            }
            try shelf.add(source, script: text)
            await install(source)
            if source.hasAccount, !loggedIn(source) {
                settingUp = SourceSetup(source: source)
            } else {
                say("已\(old == nil ? "添加" : "更新")\(source.info.spaced)")
            }
        } catch {
            say("没有添加：\(error.localizedDescription)", error: true)
        }
    }

    private func agree(_ source: ScriptSource, replacing old: String?) async -> Bool {
        var places = source.hosts
        if source.fields.contains(where: { $0.kind == .server }) { places.append("你填写的服务器") }
        return await ask(
            old.map { "用“\(source.info.name)”替换“\($0)”？" } ?? "添加音源“\(source.info.name)”？",
            (places.isEmpty ? "它不会联网。" : "它会连接：\(places.joined(separator: "、"))。") + "\n\n音源是别人写的程序，只添加你信任的。",
            button: old == nil ? "添加" : "替换"
        )
    }

    func askRemove(_ source: ScriptSource) {
        Task {
            guard await ask("移除音源“\(source.info.name)”？", "填过的账号会一起删除，听歌记录会保留。", button: "移除") else { return }
            await removeSource(source)
        }
    }

    /// 挂在窗口上问，不用 runModal：那会占住主线程，弹着的时候歌放完了也切不了
    private func ask(_ title: String, _ text: String, button: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "取消")
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }) else {
            return alert.runModal() == .alertFirstButtonReturn
        }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    func removeSource(_ source: ScriptSource) async {
        shelf.remove(source.info.id)
        await uninstall(source)
        say("已移除\(source.info.spaced)")
    }

    /// 存下填好的设置并检查能不能用；不行时返回原因，原来的设置不变
    func saveSettings(_ source: ScriptSource, _ values: [String: String]) async -> String? {
        let old = source.settings
        do {
            try source.apply(values)
            guard await source.account().loggedIn else { throw SourceError("还有没填的") }
            _ = try await source.profile()
            try shelf.save(source)
        } catch {
            try? source.apply(old)
            return error.localizedDescription
        }
        settingUp = nil
        Task { await entered(source) }
        return nil
    }
}
