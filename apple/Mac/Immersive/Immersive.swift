import AppKit
import SwiftUI

/// 全屏氛围：一个无边框窗口从主窗口的位置扩开，铺满整个屏幕
@Observable
final class Immersive {
    static let shared = Immersive()

    /// 已经打开（收起的动画一开始就算关了）
    private(set) var isOpen = false
    /// 扩开到一半以后内容才出场
    private(set) var staged = false
    /// 鼠标键盘一会儿没动静，只留画面
    private(set) var idle = false

    @ObservationIgnored private var window: ImmersiveWindow?
    @ObservationIgnored private var clip: NSView?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var stageTask: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?

    private static let idleSeconds = 3.0
    private static let duration = 0.62
    private static let curve = CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.24, 1)

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard !isOpen, AppModel.shared.player.current != nil else { return }
        tearDown()
        let main = NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
        guard let screen = main?.screen ?? NSScreen.main else { return }
        isOpen = true
        staged = false
        idle = false

        let window = ImmersiveWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.acceptsMouseMovedEvents = true
        window.animationBehavior = .none
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = "全屏播放"

        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        root.wantsLayer = true
        let clip = NSView(frame: root.bounds)
        clip.wantsLayer = true
        clip.autoresizingMask = [.width, .height]
        clip.layer?.masksToBounds = true
        let host = NSHostingView(rootView: ImmersiveView().environment(AppModel.shared).environment(self).environment(\.colorScheme, .dark))
        host.sizingOptions = []
        host.frame = root.bounds
        host.autoresizingMask = [.width, .height]
        clip.addSubview(host)
        root.addSubview(clip)
        window.contentView = root
        window.setFrame(screen.frame, display: true)
        self.window = window
        self.clip = clip

        DesktopLyrics.shared.suppressed = true
        NotchLyrics.shared.suppressed = true
        AppModel.shared.lyrics.watch("immersive", true)
        // 先在看不见的时候把第一帧画好，再开始扩开
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window)
        NSApp.activate()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let from = main.map { Self.local($0.frame, in: screen) } ?? root.bounds.insetBy(dx: root.bounds.width * 0.1, dy: root.bounds.height * 0.1)
        DispatchQueue.main.async { [self] in
            guard isOpen, self.window === window else { return }
            // 菜单栏和程序坞一起收走
            NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
            animate(clip, from: from, to: root.bounds, opening: true) {}
            window.alphaValue = 1
        }
        stageTask = Task {
            try? await Task.sleep(for: .seconds(Self.duration * 0.42))
            if !Task.isCancelled, isOpen { staged = true }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .scrollWheel, .keyDown]) { [weak self] event in
            // 画面自己动了也会触发移动事件，鼠标没真的动就不算
            if event.type != .mouseMoved || event.deltaX != 0 || event.deltaY != 0 { self?.wake() }
            return event
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let window = self?.window, let screen = window.screen ?? NSScreen.main else { return }
                window.setFrame(screen.frame, display: true)
            }
        }
        wake()
        keepAwake()
    }

    func close() {
        guard isOpen, let window, let clip else { return }
        isOpen = false
        staged = false
        idleTask?.cancel()
        stageTask?.cancel()
        NSCursor.setHiddenUntilMouseMoves(false)
        NSApp.presentationOptions = []
        keepAwake()
        let main = NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
        let to: NSRect
        if let main, let screen = window.screen, main.screen == screen {
            to = Self.local(main.frame, in: screen)
        } else {
            to = clip.bounds.insetBy(dx: clip.bounds.width * 0.1, dy: clip.bounds.height * 0.1)
        }
        animate(clip, from: clip.superview?.bounds ?? clip.bounds, to: to, opening: false) { [weak self] in
            guard let self, self.window === window, !self.isOpen else { return }
            tearDown()
            main?.makeKeyAndOrderFront(nil)
        }
    }

    private func tearDown() {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        clip = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        AppModel.shared.lyrics.watch("immersive", false)
        DesktopLyrics.shared.suppressed = false
        NotchLyrics.shared.suppressed = false
    }

    /// 裁剪框从一处动到另一处，里面的画面原地不动。整段动画交给系统合成，主线程忙也不卡
    private func animate(_ clip: NSView, from: NSRect, to: NSRect, opening: Bool, done: @escaping @MainActor () -> Void) {
        guard let layer = clip.layer else { return done() }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } }
        let group = CAAnimationGroup()
        var parts: [CABasicAnimation] = []
        func part(_ key: String, _ a: Any, _ b: Any, _ timing: CAMediaTimingFunction? = nil, begin: Double = 0, length: Double? = nil) {
            let x = CABasicAnimation(keyPath: key)
            x.fromValue = a
            x.toValue = b
            x.beginTime = begin
            x.duration = length ?? Self.duration
            x.timingFunction = timing ?? Self.curve
            x.fillMode = .both
            parts.append(x)
        }
        if !reduce {
            let anchor = layer.anchorPoint
            func center(_ r: NSRect) -> CGPoint { CGPoint(x: r.minX + r.width * anchor.x, y: r.minY + r.height * anchor.y) }
            part("position", NSValue(point: center(from)), NSValue(point: center(to)))
            part("bounds", NSValue(rect: from), NSValue(rect: to))
            part("cornerRadius", opening ? 22 : 0, opening ? 0 : 22)
        }
        if opening {
            part("opacity", 0, 1, CAMediaTimingFunction(name: .easeOut), length: reduce ? 0.3 : 0.16)
        } else {
            part("opacity", 1, 0, CAMediaTimingFunction(name: .easeIn), begin: reduce ? 0 : Self.duration * 0.5, length: reduce ? 0.3 : Self.duration * 0.5)
        }
        group.animations = parts
        group.duration = reduce ? 0.3 : Self.duration
        group.fillMode = .both
        group.isRemovedOnCompletion = opening
        layer.add(group, forKey: "reveal")
        CATransaction.commit()
    }

    private static func local(_ frame: NSRect, in screen: NSScreen) -> NSRect {
        frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    }

    private func wake() {
        if idle { idle = false }
        idleTask?.cancel()
        guard isOpen else { return }
        idleTask = Task {
            try? await Task.sleep(for: .seconds(Self.idleSeconds))
            guard !Task.isCancelled, isOpen else { return }
            idle = true
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    /// 放着歌的时候不让屏幕变暗、锁屏
    func keepAwake() {
        let want = isOpen && AppModel.shared.player.playing
        if want, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "全屏播放")
        } else if !want, let held = activity {
            ProcessInfo.processInfo.endActivity(held)
            activity = nil
        }
    }
}

private final class ImmersiveWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    // 系统默认会把窗口挪到菜单栏下面，这里要铺满
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func cancelOperation(_ sender: Any?) { Immersive.shared.close() }
}
