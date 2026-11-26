import AppKit
import SongforMeKit
import SwiftUI

/// 刘海歌词：放歌时从屏幕顶上的刘海里长出一条黑色，显示正在唱的这句，和刘海连成一块。
/// 暂停或没在放就缩回刘海里；指针在上面停一会儿，展开成小播放器，移开就收回去。
/// 没有刘海的屏幕上，在菜单栏中间垂下同样的一块。
@Observable
final class NotchLyrics {
    static let shared = NotchLyrics()

    private(set) var visible: Bool
    /// 全屏时不重复显示歌词
    var suppressed = false { didSet { if suppressed != oldValue { refresh() } } }
    /// 指针停在上面：展开成小播放器
    private(set) var open = false
    /// 刘海的大小；没有刘海时是菜单栏的高度和一个差不多的宽度
    private(set) var housing = CGSize(width: 200, height: 24)

    /// 黑色那块在窗口里的位置（左上角为原点），用来判断指针在不在上面
    @ObservationIgnored fileprivate var shape: CGRect = .zero
    @ObservationIgnored private var panel: NotchPanel?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var screenObserver: Any?
    @ObservationIgnored private var enteredAt: Date?
    @ObservationIgnored private var leftAt: Date?
    @ObservationIgnored private var polling = false
    /// 调试时让它一直展开着，方便截图
    @ObservationIgnored var hold = false
    /// 调试时不放歌也显示一句，看样子和动画
    var preview: String?
    @ObservationIgnored private let defaults = UserDefaults.standard

    static let size = CGSize(width: 560, height: 240)
    static let openWidth: CGFloat = 420

    private init() {
        visible = defaults.bool(forKey: "notch.visible")
    }

    func restore() { refresh() }

    func toggle() {
        visible.toggle()
        defaults.set(visible, forKey: "notch.visible")
        refresh()
    }

    func setOpen(_ on: Bool) {
        guard on != open else { return }
        open = on
        if on { poll() }
    }

    private func refresh() {
        let on = visible && !suppressed
        AppModel.shared.lyrics.watch("notch", on)
        guard on else {
            stopWatching()
            open = false
            panel?.orderOut(nil)
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        place()
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        startWatching()
    }

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // 比菜单栏高，才能盖在刘海那里；所有桌面、全屏的应用上都在
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.title = "刘海歌词"
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = ClickThroughHost(rootView: NotchView(notch: self).environment(AppModel.shared).environment(\.colorScheme, .dark))
        host.sizingOptions = []
        panel.contentView = host
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        return panel
    }

    /// 放在有菜单栏的那块屏幕的正上方，量一下刘海有多大
    private func place() {
        guard let panel, let screen = NSScreen.screens.first else { return }
        let f = screen.frame
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            housing = CGSize(width: f.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            let bar = f.maxY - screen.visibleFrame.maxY
            housing = CGSize(width: 180, height: bar > 0 ? bar : 24)
        }
        panel.setFrame(NSRect(x: f.midX - Self.size.width / 2, y: f.maxY - Self.size.height, width: Self.size.width, height: Self.size.height), display: true)
    }

    // MARK: 指针

    // 刘海总在别的应用上面，只靠窗口自己收不到指针的移动；看全局的移动，指针在黑色那块上时才接住点击
    private func startWatching() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in MainActor.assumeIsolated { self?.poll() }; return e }) { monitors.append(l) }
    }

    private func stopWatching() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func poll() {
        guard let panel, panel.isVisible else { return }
        let f = panel.frame
        let hit = CGRect(x: f.minX + shape.minX, y: f.maxY - shape.maxY, width: shape.width, height: shape.height).insetBy(dx: -6, dy: -6)
        let inside = hit.contains(NSEvent.mouseLocation)
        let now = Date()
        if inside {
            leftAt = nil
            let since = enteredAt ?? now
            enteredAt = since
            // 只是路过去点菜单栏不展开，停一下才展开
            if !open, now.timeIntervalSince(since) >= 0.3 { open = true }
        } else {
            enteredAt = nil
            if open, !hold {
                let since = leftAt ?? now
                leftAt = since
                if now.timeIntervalSince(since) >= 0.3 { open = false }
            }
        }
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        // 指针停着不动时没有事件，在上面或者展开着就自己再看一次
        guard inside || open, !polling else { return }
        polling = true
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            polling = false
            poll()
        }
    }

    /// 调试用：指针要落在哪个范围里（屏幕坐标，左下角为原点）
    var hitArea: CGRect {
        guard let f = panel?.frame else { return .zero }
        return CGRect(x: f.minX + shape.minX, y: f.maxY - shape.maxY, width: shape.width, height: shape.height)
    }

    fileprivate func shapeChanged(_ frame: CGRect) {
        shape = frame
    }
}

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // 不让系统把窗口挪到菜单栏下面
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// 别的应用在前面时，第一下就能点到按钮
private final class ClickThroughHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 刘海往下长出来的样子：顶上两角向外翻，和屏幕边缘接上；底下两角是圆的
private struct NotchShape: Shape {
    var flare: CGFloat
    var foot: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, foot) }
        set { (flare, foot) = (newValue.first, newValue.second) }
    }

    func path(in r: CGRect) -> Path {
        let foot = min(foot, r.height / 2, r.width / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX - flare, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + flare), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - foot))
        p.addQuadCurve(to: CGPoint(x: r.minX + foot, y: r.maxY), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - foot, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - foot), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + flare))
        p.addQuadCurve(to: CGPoint(x: r.maxX + flare, y: r.minY), control: CGPoint(x: r.maxX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

private struct NotchView: View {
    let notch: NotchLyrics
    static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    @Environment(AppModel.self) private var app

    var body: some View {
        let player = app.player
        let lyrics = app.lyrics
        let song = player.current?.song
        let line = lyrics.lines.indices.contains(lyrics.index) ? lyrics.lines[lyrics.index] : nil
        // 还没到第一句、没有歌词时显示歌名
        let text = notch.preview ?? line.map { $0.text.isEmpty ? "♪" : $0.text } ?? song.map { "\($0.name) - \($0.artistText)" } ?? ""
        let singing = (notch.preview != nil || song != nil && player.playing) && !notch.open
        let key = notch.preview ?? "\(song?.mid ?? "")#\(line == nil ? -1 : lyrics.index)"
        let shown = singing || notch.open
        // 黑色正好包住这句：量出宽度再给定，换句时宽度才能跟着弹
        let width = min(500, max(notch.housing.width, (text as NSString).size(withAttributes: [.font: Self.font]).width.rounded(.up) + 40))

        VStack(spacing: 0) {
            Color.clear.frame(width: 0, height: notch.housing.height)
            if notch.open {
                NotchPlayer()
                    .transition(.opacity.combined(with: .offset(y: -10)))
            } else if singing {
                Text(text)
                    .font(Font(Self.font))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .padding(.horizontal, 18)
                    .padding(.top, 3)
                    .padding(.bottom, 9)
                    .frame(width: width)
                    .id(key)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: notch.housing.width)
        .background {
            NotchShape(flare: notch.open ? 14 : 8, foot: notch.open ? 26 : 13).fill(.black)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { notch.shapeChanged($0) }
        .opacity(shown ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(duration: 0.5, bounce: notch.open ? 0.26 : 0.1), value: notch.open)
        .animation(.spring(duration: 0.45, bounce: 0.12), value: key)
        .animation(.spring(duration: 0.45, bounce: 0.1), value: singing)
    }
}

/// 展开后的小播放器
private struct NotchPlayer: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let player = app.player
        let lyrics = app.lyrics
        VStack(spacing: 10) {
            if let item = player.current {
                let song = item.song
                HStack(spacing: 12) {
                    Button { Immersive.shared.toggle() } label: {
                        RemoteImage(url: song.artwork(150), pixels: 150, crossfade: true)
                            .frame(width: 46, height: 46)
                            .clipShape(.rect(cornerRadius: 10))
                    }
                    .buttonStyle(PressStyle())
                    .help("全屏")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                        Text(song.artistText).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HeartButton(song: song, size: 15)
                }
                if lyrics.lines.indices.contains(lyrics.index) {
                    let line = lyrics.lines[lyrics.index]
                    let second = line.trans ?? (lyrics.lines.indices.contains(lyrics.index + 1) ? lyrics.lines[lyrics.index + 1].text : "")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(line.text.isEmpty ? "♪" : line.text).font(.system(size: 14, weight: .bold)).lineLimit(1)
                        Text(second.isEmpty ? " " : second).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(lyrics.index)
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.22), value: lyrics.index)
                }
                ProgressRow(tint: .white, track: .white.opacity(0.18))
            } else {
                Text(player.error ?? "没在放歌")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Transport(big: 0.85, tint: .white, ink: .black, compact: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(width: NotchLyrics.openWidth)
    }
}
