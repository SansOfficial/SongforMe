import AppKit
import SwiftUI

/// 桌面歌词：浮在所有桌面最上层、不抢焦点的透明小窗
@Observable
final class DesktopLyrics {
    static let shared = DesktopLyrics()
    static let sizes: ClosedRange<Double> = 16...64

    private(set) var visible = false
    /// 锁定后鼠标穿透，不挡下面的窗口，在主窗口里解锁
    var locked: Bool { didSet { defaults.set(locked, forKey: "lyrics.locked"); panel?.ignoresMouseEvents = locked } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: "lyrics.size") } }
    /// 全屏时不重复显示歌词
    var suppressed = false { didSet { if suppressed != oldValue { refresh() } } }

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        locked = defaults.bool(forKey: "lyrics.locked")
        let size = defaults.double(forKey: "lyrics.size")
        fontSize = size == 0 ? 30 : min(max(size, Self.sizes.lowerBound), Self.sizes.upperBound)
    }

    /// 上次退出时开着，就接着开
    func restore() {
        if defaults.bool(forKey: "lyrics.visible") { show() }
    }

    func toggle() { visible ? hide() : show() }

    func show() {
        visible = true
        defaults.set(true, forKey: "lyrics.visible")
        refresh()
    }

    func hide() {
        visible = false
        defaults.set(false, forKey: "lyrics.visible")
        refresh()
    }

    private func refresh() {
        let on = visible && !suppressed
        AppModel.shared.lyrics.watch("desktop", on)
        guard on else {
            panel?.orderOut(nil)
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        place(panel)
        panel.ignoresMouseEvents = locked
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: defaultFrame(), styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 320, height: 70)
        panel.title = "桌面歌词"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = NSHostingView(rootView: DesktopLyricsView().environment(AppModel.shared).environment(self))
        if let saved = defaults.string(forKey: "lyrics.frame") { panel.setFrame(NSRectFromString(saved), display: false) }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self, weak panel] _ in
                MainActor.assumeIsolated {
                    guard let self, let panel, panel.isVisible else { return }
                    self.defaults.set(NSStringFromRect(panel.frame), forKey: "lyrics.frame")
                }
            }
        }
        return panel
    }

    /// 换了显示器，上次的位置可能已经在屏幕外面
    private func place(_ panel: NSPanel) {
        let seen = NSScreen.screens.contains { screen in
            let hit = screen.visibleFrame.intersection(panel.frame)
            return hit.width > 120 && hit.height > 40
        }
        if !seen { panel.setFrame(defaultFrame(), display: true) }
    }

    private func defaultFrame() -> NSRect {
        let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(980, area.width - 80)
        return NSRect(x: area.midX - width / 2, y: area.minY + 58, width: width, height: 132)
    }
}

private struct DesktopLyricsView: View {
    @Environment(AppModel.self) private var app
    @Environment(DesktopLyrics.self) private var desktop
    @State private var hovering = false

    var body: some View {
        let lyrics = app.lyrics
        let song = app.player.current?.song
        let title = song.map { "\($0.name) - \($0.artistText)" } ?? "SongforMe"
        let line = lyrics.lines.indices.contains(lyrics.index) ? lyrics.lines[lyrics.index] : nil
        let next = lyrics.lines.indices.contains(lyrics.index + 1) ? lyrics.lines[lyrics.index + 1].text : ""
        VStack(spacing: 4) {
            text(line?.text ?? title, size: desktop.fontSize, weight: .bold)
                .foregroundStyle(Color(red: 0.875, green: 0.902, blue: 1))
            text(line == nil ? next : (line?.trans ?? next), size: desktop.fontSize * 0.6, weight: .semibold)
                .foregroundStyle(.white.opacity(0.86))
        }
        .id(line == nil ? title : "\(lyrics.index)")
        .transition(.opacity)
        .animation(.easeOut(duration: 0.22), value: lyrics.index)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.07).opacity(hovering ? 0.62 : 0.001))
                .strokeBorder(.white.opacity(hovering ? 0.14 : 0))
        }
        // 窗口里是 SwiftUI，按住背景拖不动窗口，要自己加拖动手势；应用在后台时第一下也要能拖
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 2) {
                IconButton(icon: "textformat.size.smaller", label: "字小一点", size: 12) { resize(-2) }
                IconButton(icon: "textformat.size.larger", label: "字大一点", size: 12) { resize(2) }
                IconButton(icon: "lock", label: "锁定，之后在播放条上解锁", size: 12) { desktop.locked = true }
                IconButton(icon: "xmark", label: "关闭桌面歌词", size: 12) { desktop.hide() }
            }
            .padding(6)
            .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    /// 没有背景也要在任何壁纸上看得清
    private func text(_ s: String, size: Double, weight: Font.Weight) -> some View {
        Text(s.isEmpty ? " " : s)
            .font(.system(size: size, weight: weight))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .shadow(color: .black.opacity(0.9), radius: 1.5)
            .shadow(color: .black.opacity(0.65), radius: 5, y: 2)
    }

    private func resize(_ step: Double) {
        desktop.fontSize = min(max(desktop.fontSize + step, DesktopLyrics.sizes.lowerBound), DesktopLyrics.sizes.upperBound)
    }
}
