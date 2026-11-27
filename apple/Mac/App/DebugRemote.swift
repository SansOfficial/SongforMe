#if DEBUG
import AppKit
import SongforMeKit
import WebKit

extension Notification.Name {
    static let debugStory = Notification.Name("debugStory")
    static let debugPanel = Notification.Name("debugPanel")
    static let debugQueue = Notification.Name("debugQueue")
    static let debugPoster = Notification.Name("debugPoster")
}

/// 只在调试版里有：从命令行换页面、给应用自己的窗口拍照
enum DebugRemote {
    static func install() {
        // 同时开着几份调试版时，用 SONGFORME_DEBUG_CHANNEL 分开
        let channel = ProcessInfo.processInfo.environment["SONGFORME_DEBUG_CHANNEL"] ?? "com.sansofficial.songforme.debug"
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(channel), object: nil, queue: .main) { note in
            let text = note.object as? String ?? ""
            MainActor.assumeIsolated { run(text.split(separator: " ", maxSplits: 1).map(String.init)) }
        }
    }

    private static func run(_ words: [String]) {
        let app = AppModel.shared
        let arg = words.count > 1 ? words[1] : ""
        switch words.first {
        case "reco": app.go(.reco)
        case "tuning": app.go(.settings(.reco))
        case "settings": app.go(.settings(SettingsTab(rawValue: arg) ?? .general))
        case "report":
            let parts = arg.split(separator: " ").map(String.init)
            let date = parts.count > 1 ? try? Date(parts[1] + "T04:00:00Z", strategy: .iso8601) : nil
            app.openReport(ReportPeriod(rawValue: parts.first ?? "") ?? .day, date ?? Date())
        case "story": NotificationCenter.default.post(name: .debugStory, object: arg)
        case "scroll":
            let views = sequence(first: [NSApp.windows.max { $0.frame.width < $1.frame.width }?.contentView].compactMap { $0 }) { level in
                let next = level.flatMap(\.subviews)
                return next.isEmpty ? nil : next
            }
            let scroll = views.joined().compactMap { $0 as? NSScrollView }.max { $0.frame.width < $1.frame.width }
            scroll?.contentView.scroll(to: NSPoint(x: 0, y: Double(arg) ?? 0))
        case "snap-sheet": shoot(NSApp.windows.first { $0.sheetParent != nil }, arg)
        case "panel": NotificationCenter.default.post(name: .debugPanel, object: arg)
        case "snap-popover": shoot(NSApp.windows.first { $0.className.contains("Popover") }, arg)
        case "poster": NotificationCenter.default.post(name: .debugPoster, object: arg)
        case "playlist": app.go(.playlist(arg))
        case "search": app.search(arg)
        // searchin <音源> <分类> <词>
        case "searchin":
            let p = arg.split(separator: " ", maxSplits: 2).map(String.init)
            if p.count == 3 { app.search(p[2], SearchKind(rawValue: p[1]) ?? .song, in: p[0]) }
        case "artist": if let s = app.content.songs.first?.singers.first { app.open(s) }
        case "albums": if case .artist(let a, _) = app.page { app.go(.artist(a, .albums)) }
        case "album": if let s = app.content.songs.first { app.openAlbum(of: s) }
        case "like": if let s = app.content.songs.first { app.toggleLike(s) }
        case "seed": Task { await app.importSeed(arg) }
        case "add-source": Task { await app.addSource(URL(filePath: arg), confirm: false) }
        case "choose-source": app.chooseSource()
        case "adding": app.adding = true
        case "ask-link":
            Task {
                guard let url = ScriptDownload.address(of: arg) else { return app.say("链接不对", error: true) }
                do { await app.addSource(script: try await ScriptDownload.text(of: url), from: url.host()) } catch { app.say(error.localizedDescription, error: true) }
            }
        case "ask-add": Task { await app.addSource(URL(filePath: arg)) }
        case "ask-remove": if let s = app.scripts.first { app.askRemove(s) }
        // 点弹窗里写着这几个字的按钮
        case "click":
            func buttons(_ v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
            NSApp.windows.lazy.filter { $0.sheetParent != nil }.compactMap(\.contentView).flatMap(buttons).first { $0.title == arg }?.performClick(nil)
        // 在弹出的表单里填字、按回车
        case "type":
            func fields(_ v: NSView) -> [NSTextField] { ((v as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []) + v.subviews.flatMap(fields) }
            guard let sheet = NSApp.windows.first(where: { $0.sheetParent != nil }), let field = sheet.contentView.flatMap({ fields($0).first }) else { break }
            sheet.makeFirstResponder(field)
            field.currentEditor()?.insertText(arg)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { field.currentEditor()?.insertNewline(nil) }
        case "remove-source": if let s = app.scripts.first { Task { await app.removeSource(s) } }
        // fill-source 键=值 键=值
        case "fill-source":
            if let s = app.scripts.first {
                let pairs = arg.split(separator: " ").map { $0.split(separator: "=", maxSplits: 1).map(String.init) }.filter { $0.count == 2 }
                Task { if let e = await app.saveSettings(s, Dictionary(pairs.map { ($0[0], $0[1]) }, uniquingKeysWith: { $1 })) { app.say(e, error: true) } }
            }
        case "generate": Task { await app.generate() }
        case "play-batch": app.playBatch()
        case "update": Task { await Updater.shared.install() }
        case "dislike-current": if let s = app.player.current?.song { app.reject(s, .dislike) }
        case "like-current": if let s = app.player.current?.song { app.toggleLike(s) }
        case "batch":
            let p = app.player
            let text = "index=\(p.index) context=\(p.context)\nbatch=\(app.batch.map(\.song.name).joined(separator: ","))\nqueue=\(p.queue.map(\.song.name).joined(separator: ","))"
            try? text.write(toFile: arg, atomically: true, encoding: .utf8)
        case "play": app.playList()
        case "local-add":
            Task {
                await app.local.add(URL(filePath: arg))
                await app.addedLocal()
            }
        case "local-remove": if let f = app.localFolders.first { Task { await app.removeLocalFolder(f) } }
        case "queue-next": if let s = app.content.songs.dropFirst(Int(arg) ?? 0).first { app.enqueue(s, next: true) }
        case "queue-add": if let s = app.content.songs.dropFirst(Int(arg) ?? 0).first { app.enqueue(s, next: false) }
        case "queue-move": app.player.moveUpcoming(fromOffsets: [0], toOffset: Int(arg) ?? 1)
        case "queue": NotificationCenter.default.post(name: .debugQueue, object: nil)
        case "sleep":
            switch arg {
            case "song": SleepTimer.shared.stopAfterSong()
            case "off": SleepTimer.shared.cancel()
            default: SleepTimer.shared.set(minutes: Int(arg) ?? 30)
            }
        case "end": app.player.seek(max(0, app.player.duration - 1))
        case "toggle": app.togglePlay()
        case "mute": app.player.toggleMute()
        case "mode": app.cyclePlayMode()
        case "seek": app.player.seek(Double(arg) ?? 0)
        case "login": if let s = app.hub.named(arg) ?? app.hub.all.first { Task { await app.login(s) } }
        case "next": app.player.next()
        case "immersive": Immersive.shared.toggle()
        case "scene": UserDefaults.standard.set(arg, forKey: "scene")
        case "lyrics": DesktopLyrics.shared.toggle()
        case "notch": NotchLyrics.shared.toggle()
        case "notch-geo": try? "\(NotchLyrics.shared.hitArea) housing=\(NotchLyrics.shared.housing) open=\(NotchLyrics.shared.open)".write(toFile: arg, atomically: true, encoding: .utf8)
        case "notch-line": NotchLyrics.shared.preview = arg.isEmpty ? nil : arg
        case "notch-open":
            NotchLyrics.shared.hold = arg == "1"
            NotchLyrics.shared.setOpen(arg == "1")
        case "look": Appearance.current = Appearance(rawValue: arg) ?? .light
        case "state":
            let p = app.player
            let text = "ready=\(app.ready) login=\(app.accounts.filter(\.value.loggedIn).keys.sorted()) page=\(app.page.identity) songs=\(app.content.songs.count) error=\(app.content.error ?? "-") playing=\(p.playing) loading=\(p.loading) pos=\(p.position) dur=\(p.duration) perr=\(p.error ?? "-") lines=\(app.lyrics.lines.count)/\(app.lyrics.index) toast=\(app.toast?.text ?? "-") batch=\(app.batch.count) full=\(Immersive.shared.isOpen)"
            try? text.write(toFile: arg, atomically: true, encoding: .utf8)
        case "snap":
            let window = NSApp.windows.filter { $0.isVisible }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            shoot(window, arg)
        case "snap-login": shoot(NSApp.windows.first { $0.isVisible && $0.contentView is WKWebView }, arg)
        case "login-js":
            let web = NSApp.windows.lazy.filter(\.isVisible).compactMap { $0.contentView as? WKWebView }.first
            let p = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard let web, p.count == 2 else { break }
            web.evaluateJavaScript(p[1]) { value, error in
                try? "\(value ?? error?.localizedDescription ?? "-")".write(toFile: p[0], atomically: true, encoding: .utf8)
            }
        case "snap-panel": shoot(NSApp.windows.first { $0 is NSPanel && $0.isVisible }, arg)
        default: break
        }
    }

    /// 只拍应用自己的窗口，不需要屏幕录制权限
    private static func shoot(_ window: NSWindow?, _ path: String) {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let window, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        // 8 = 只拍这一个窗口；1 = 不带边框阴影，16 = 普通分辨率
        guard let cg = capture(.null, 8, UInt32(window.windowNumber), 1 | 16)?.takeRetainedValue() else { return }
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
    }
}
#endif
