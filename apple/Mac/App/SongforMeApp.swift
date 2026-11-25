import AppKit
import SwiftUI
import WebKit

@main
struct SongforMeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("SongforMe", id: "main") {
            RootView()
                .environment(AppModel.shared)
                .environment(DesktopLyrics.shared)
        }
        .defaultSize(width: 1180, height: 780)
        .commands { PlaybackCommands() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Appearance.current.apply()
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Shortcuts.install()
        DesktopLyrics.shared.restore()
        #if DEBUG
        DebugRemote.install()
        #endif
    }

    // 关掉窗口接着放歌，从程序坞点回来
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct PlaybackCommands: Commands {
    private var app: AppModel { .shared }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(after: .textEditing) {
            Button("搜索") { NotificationCenter.default.post(name: .focusSearch, object: nil) }.keyboardShortcut("f")
        }
        CommandMenu("播放") {
            Button(app.player.playing ? "暂停" : "播放") { app.togglePlay() }.disabled(!app.canPlay)
            Button("下一首") { app.player.next() }.keyboardShortcut(.rightArrow).disabled(app.player.current == nil)
            Button("上一首") { app.player.previous() }.keyboardShortcut(.leftArrow).disabled(app.player.current == nil)
            Divider()
            Button("增大音量") { Shortcuts.nudgeVolume(0.05) }.keyboardShortcut(.upArrow)
            Button("减小音量") { Shortcuts.nudgeVolume(-0.05) }.keyboardShortcut(.downArrow)
            Button(app.player.prefs.muted ? "取消静音" : "静音") { app.player.toggleMute() }
            Divider()
            Button("切换随机播放") { app.cycleShuffle() }
            Button("切换循环方式") { app.cycleRepeat() }
            Divider()
            Button("喜欢 / 取消喜欢") { if let s = app.player.current?.song { app.toggleLike(s) } }.keyboardShortcut("l").disabled(app.player.current == nil)
            Divider()
            Button("全屏") { Immersive.shared.toggle() }.disabled(app.player.current == nil)
            Button(DesktopLyrics.shared.visible ? "关闭桌面歌词" : "打开桌面歌词") { DesktopLyrics.shared.toggle() }
        }
    }
}

/// 空格播放 / 暂停，F 全屏，Esc 退出全屏。在输入文字时一律不拦
enum Shortcuts {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    static func nudgeVolume(_ step: Double) {
        let p = AppModel.shared.player
        p.setVolume((p.prefs.muted ? 0 : p.prefs.volume) + step)
    }

    private static func handle(_ event: NSEvent) -> Bool {
        let app = AppModel.shared
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if let text = event.window?.firstResponder as? NSTextView {
            // 输入框里 ⌘← ⌘→ 是移动光标，不该被菜单的快捷键截走
            if flags == .command, [123, 124, 125, 126].contains(event.keyCode) {
                text.keyDown(with: event)
                return true
            }
            return false
        }
        // 弹窗、登录窗口里的按键不管
        guard event.window?.sheetParent == nil, !(event.window is NSPanel), !(event.window?.contentView is WKWebView) else { return false }
        switch event.keyCode {
        case 49 where flags.isEmpty:
            guard NSApp.modalWindow == nil, event.window?.attachedSheet == nil else { return false }
            if !event.isARepeat { app.togglePlay() }
            return true
        case 3 where flags.isEmpty:
            guard NSApp.modalWindow == nil else { return false }
            if !event.isARepeat { Immersive.shared.toggle() }
            return true
        case 53 where Immersive.shared.isOpen:
            Immersive.shared.close()
            return true
        default:
            return false
        }
    }
}
