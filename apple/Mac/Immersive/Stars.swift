import AppKit
import SwiftUI

/// 星轨：一张画好的星空整张转（由显卡合成，每一帧都顺），底下是山影，偶尔有流星
struct StarField: NSViewRepresentable {
    let turning: Bool

    /// 星轨的圆心，占画面的比例；封面放在同一个位置
    static let pole = CGPoint(x: 0.5, y: 0.4)

    func makeNSView(context: Context) -> StarsView { StarsView() }
    func updateNSView(_ view: StarsView, context: Context) { view.turning = turning }
}

final class StarsView: LayerView {
    private let wash = CAGradientLayer()
    private let sky = CALayer()
    private let trails = CALayer()
    private let ridges = CALayer()
    private let meteor = CAGradientLayer()
    private var spinner: Spinner!
    private var drawn = CGSize.zero
    private var drawing: Task<Void, Never>?
    private var meteors: Task<Void, Never>?

    var turning = false { didSet { spinner.set(turning) } }

    /// 一闪一闪的亮星：极坐标位置（占边长的比例）、大小、周期
    private let twinkles: [(r: Double, a: Double, d: Double, seconds: Double)] = (0..<26).map { _ in
        (0.12 + 0.34 * .random(in: 0...1), .random(in: 0...(2 * .pi)), 2 + .random(in: 0...1.6), 2.4 + .random(in: 0...3.6))
    }

    override init() {
        super.init()
        root.masksToBounds = true
        wash.colors = [rgb(0x060814, 0.86), rgb(0x0C112A, 0.72), rgb(0x22244A, 0.5)]
        wash.locations = [0, 0.58, 1]
        for l in [wash, sky, meteor, ridges] { root.addSublayer(l) }
        sky.addSublayer(trails)
        for t in twinkles {
            let l = CALayer()
            l.bounds = CGRect(x: 0, y: 0, width: t.d, height: t.d)
            l.cornerRadius = t.d / 2
            l.backgroundColor = gray(1)
            l.shadowColor = rgb(0xC8DCFF)
            l.shadowOpacity = 0.7
            l.shadowRadius = 4
            l.shadowOffset = .zero
            let blink = CABasicAnimation(keyPath: "opacity")
            blink.fromValue = 0.12
            blink.toValue = 0.95
            blink.duration = t.seconds / 2
            blink.autoreverses = true
            blink.repeatCount = .infinity
            blink.timeOffset = .random(in: 0...6)
            blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            blink.isRemovedOnCompletion = false
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { l.add(blink, forKey: "blink") }
            sky.addSublayer(l)
        }
        meteor.colors = [gray(1, 0), gray(1, 1)]
        meteor.startPoint = CGPoint(x: 0, y: 0.5)
        meteor.endPoint = CGPoint(x: 1, y: 0.5)
        meteor.anchorPoint = CGPoint(x: 1, y: 0.5)
        meteor.cornerRadius = 1
        meteor.opacity = 0
        spinner = Spinner(sky, period: 180)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        meteors?.cancel()
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        needsLayout = true
        meteors = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            while !Task.isCancelled {
                self?.shoot()
                try? await Task.sleep(for: .seconds(.random(in: 7...16)))
            }
        }
    }

    override func arrange(_ size: CGSize) {
        guard size.width > 1, size != drawn else { return }
        drawn = size
        let full = CGRect(origin: .zero, size: size)
        wash.frame = full
        ridges.frame = full
        let pole = StarField.pole
        // 正方形的星空要多大，转起来四个角才不会露空
        let side = ceil(2 * hypot(max(pole.x, 1 - pole.x) * size.width, max(pole.y, 1 - pole.y) * size.height))
        sky.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        sky.position = CGPoint(x: pole.x * size.width, y: pole.y * size.height)
        trails.frame = sky.bounds
        for (l, t) in zip((sky.sublayers ?? []).dropFirst(), twinkles) {
            l.position = CGPoint(x: side * (0.5 + cos(t.a) * t.r), y: side * (0.5 + sin(t.a) * t.r))
        }
        meteor.bounds = CGRect(x: 0, y: 0, width: size.width * 0.17, height: 2)
        let scale = pixelScale
        let inner = min(size.width, size.height) * 0.17
        drawing?.cancel()
        drawing = Task {
            // 改窗口大小时别每一帧都重画
            if trails.contents != nil { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled, let (a, b) = await Self.paint(size, side, inner, scale), !Task.isCancelled else { return }
            let first = trails.contents == nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            trails.contents = a
            ridges.contents = b
            if first {
                for (layer, seconds) in [(trails, 1.2), (ridges, 0.6)] {
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0
                    fade.toValue = 1
                    fade.duration = seconds
                    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    layer.add(fade, forKey: "fade")
                }
            }
            CATransaction.commit()
        }
    }

    /// 在后台画好星空和山影
    @concurrent
    private nonisolated static func paint(_ size: CGSize, _ side: CGFloat, _ inner: CGFloat, _ scale: CGFloat) async -> (CGImage, CGImage)? {
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(214, 228, 255), (255, 255, 255), (255, 236, 208), (190, 210, 255), (255, 214, 190)]
        // 再大就太占显存
        let k = min(scale, 4096 / side)
        let sky = drawImage(Int(side * k), Int(side * k), scale: k) { ctx in
            let c = side / 2
            let count = Int(min(1100, 320 + side * side / 7200))
            for _ in 0..<count {
                let r = inner + (c - inner) * pow(.random(in: 0...1), 0.8)
                let head = CGFloat.random(in: 0...(2 * .pi))
                let trail = 0.15 + CGFloat.random(in: 0...0.55)
                let width = 0.6 + pow(.random(in: 0...1), 3) * 1.7
                let alpha = 0.3 + pow(.random(in: 0...1), 2) * 0.7
                let (red, green, blue) = colors.randomElement()!
                func tint(_ a: CGFloat) -> CGColor { CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: a) }
                ctx.setLineWidth(width)
                for i in 0..<10 {
                    let e = CGFloat(i + 1) / 10
                    ctx.setStrokeColor(tint(alpha * 0.62 * e * e))
                    ctx.addArc(center: CGPoint(x: c, y: c), radius: r, startAngle: head - trail * (1 - CGFloat(i) / 10), endAngle: head - trail * (1 - e), clockwise: false)
                    ctx.strokePath()
                }
                ctx.setFillColor(tint(alpha))
                ctx.fillEllipse(in: CGRect(x: c + cos(head) * r - width * 0.8, y: c + sin(head) * r - width * 0.8, width: width * 1.6, height: width * 1.6))
            }
        }
        let land = drawImage(Int(size.width * scale), Int(size.height * scale), scale: scale) { ctx in
            func ridge(_ base: CGFloat, _ height: CGFloat, _ seed: CGFloat, _ color: CGColor) {
                ctx.setFillColor(color)
                ctx.move(to: CGPoint(x: 0, y: size.height))
                for x in stride(from: 0, through: size.width + 6, by: 3) {
                    let e = x / max(size.width, 900)
                    let n = sin(e * 5.1 + seed) * 0.5 + sin(e * 11.7 + seed * 2.3) * 0.28 + sin(e * 29 + seed * 4.1) * 0.1 + sin(e * 71 + seed) * 0.035
                    ctx.addLine(to: CGPoint(x: x, y: size.height * base - n * size.height * height))
                }
                ctx.addLine(to: CGPoint(x: size.width, y: size.height))
                ctx.fillPath()
            }
            ridge(0.8, 0.075, 1.4, rgb(0x101426, 0.72))
            ridge(0.88, 0.06, 4.2, rgb(0x090B16, 0.9))
        }
        guard let sky, let land else { return nil }
        return (sky, land)
    }

    private func shoot() {
        let (w, h) = (bounds.width, bounds.height)
        guard w > 1 else { return }
        let dir: CGFloat = Bool.random() ? 1 : -1
        let start = CGPoint(x: w * (0.5 - dir * .random(in: 0.1...0.45)), y: h * .random(in: 0.04...0.24))
        let d = CGVector(dx: dir * (w * 0.28 + 140), dy: h * 0.15 + 50)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        meteor.setValue(atan2(d.dy, d.dx), forKeyPath: "transform.rotation.z")
        CATransaction.commit()
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: start)
        move.toValue = NSValue(point: CGPoint(x: start.x + d.dx, y: start.y + d.dy))
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.9, 0]
        fade.keyTimes = [0, 0.35, 1]
        let stretch = CABasicAnimation(keyPath: "bounds.size.width")
        stretch.fromValue = w * 0.034
        stretch.toValue = w * 0.17
        let group = CAAnimationGroup()
        group.animations = [move, fade, stretch]
        group.duration = 1
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.1, 0.5, 1)
        meteor.add(group, forKey: "shoot")
    }
}
