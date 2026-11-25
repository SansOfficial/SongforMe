import AppKit
import SwiftUI

/// 唱片、反光和唱臂；中间的封面是另一层，切换效果时会飞走
struct VinylDeck: NSViewRepresentable {
    let playing: Bool
    let progress: () -> Double

    func makeNSView(context: Context) -> VinylView { VinylView() }
    func updateNSView(_ view: VinylView, context: Context) { view.update(playing: playing, progress: progress) }
}

final class VinylView: LayerView {
    private let platter = CALayer()
    private let sheen = CAGradientLayer()
    private let shine = CAGradientLayer()
    private let shineMask = CAShapeLayer()
    private let base = CALayer()
    private let swing = CALayer()
    private let cap = CALayer()
    private var spinner: Spinner!

    private var drawn = CGSize.zero
    private var on = false
    private var progress: () -> Double = { 0 }
    private var angle = Tonearm.rest
    private var speed = 0.0
    private var last = 0.0
    private var link: CADisplayLink?

    override init() {
        super.init()
        sheen.type = .conic
        sheen.startPoint = CGPoint(x: 0.5, y: 0.5)
        sheen.endPoint = CGPoint(x: 0.5, y: 0)
        // 轻微的明暗起伏，转起来能看出在动
        sheen.colors = [0.03, 0, 0.022, 0, 0.03, 0, 0.03].map { gray(1, $0) }
        sheen.locations = [0, 0.12, 0.31, 0.47, 0.66, 0.82, 1]
        shine.type = .conic
        shine.startPoint = CGPoint(x: 0.5, y: 0.5)
        shine.endPoint = CGPoint(x: 0.65, y: 0)
        shine.colors = [0, 0, 0.13, 0.05, 0, 0, 0.1, 0.03, 0, 0].map { gray(1, $0) }
        shine.locations = [0, 0.04, 0.11, 0.16, 0.24, 0.52, 0.60, 0.66, 0.74, 1]
        shineMask.fillRule = .evenOdd
        shine.mask = shineMask
        for l in [platter, sheen, shine, base, swing, cap] { root.addSublayer(l) }
        spinner = Spinner(sheen, period: ImmersiveView.spin)
    }

    func update(playing: Bool, progress: @escaping () -> Double) {
        self.progress = progress
        on = playing
        spinner.set(playing)
        nudge()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            link?.invalidate()
            link = nil
        } else {
            needsLayout = true
            nudge()
        }
    }

    // MARK: 唱臂

    private var target: Double { on ? Tonearm.angle(progress: progress()) : Tonearm.rest }

    /// 唱臂用弹簧跟着目标角度走：落针、抬臂、跟着进度往里走、跳转进度，都是同一个连续的动作
    private func nudge() {
        guard window != nil, link == nil, abs(target - angle) > 0.06 else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            angle = target
            return turn()
        }
        last = 0
        let link = displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let dt = last == 0 ? link.duration : min(0.04, link.timestamp - last)
        last = link.timestamp
        let to = target
        speed += ((to - angle) * 16 - speed * 7.6) * dt
        angle += speed * dt
        if abs(to - angle) < 0.01, abs(speed) < 0.02 {
            speed = 0
            link.invalidate()
            self.link = nil
        }
        turn()
    }

    private func turn() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        swing.setValue(angle * .pi / 180, forKeyPath: "transform.rotation.z")
        CATransaction.commit()
    }

    // MARK: 画

    override func arrange(_ size: CGSize) {
        guard size.width > 1, size != drawn else { return }
        drawn = size
        let k = size.width / Tonearm.deck.width
        let r = Tonearm.discRadius * k
        let center = CGPoint(x: Tonearm.disc.x * k, y: Tonearm.disc.y * k)
        let box = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        sheen.bounds = CGRect(origin: .zero, size: box.size)
        sheen.position = center
        sheen.cornerRadius = r
        sheen.masksToBounds = true
        shine.frame = box
        let ring = CGMutablePath()
        ring.addEllipse(in: CGRect(origin: .zero, size: box.size))
        ring.addEllipse(in: CGRect(origin: .zero, size: box.size).insetBy(dx: r * 0.58, dy: r * 0.58))
        shineMask.path = ring

        let pad = r * 0.2
        platter.frame = box.insetBy(dx: -pad, dy: -pad)
        platter.contents = Self.platterImage(r, pad, pixelScale)
        for l in [base, cap] {
            l.frame = CGRect(origin: .zero, size: size)
            l.contentsScale = pixelScale
        }
        // 会转的臂单独一层，画一次之后只由显卡转动
        let full = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        swing.setValue(0, forKeyPath: "transform.rotation.z")
        swing.anchorPoint = CGPoint(x: Tonearm.pivot.x / Tonearm.deck.width, y: Tonearm.pivot.y / Tonearm.deck.height)
        swing.bounds = full
        swing.position = CGPoint(x: Tonearm.pivot.x * k, y: Tonearm.pivot.y * k)
        base.contents = Self.deckImage(size, pixelScale) { Self.drawKnob($0, 78, 0.16) }
        cap.contents = Self.deckImage(size, pixelScale) {
            Self.drawKnob($0, 38, 0.22)
            $0.setFillColor(rgb(0x0E0F12))
            $0.fillEllipse(in: CGRect(x: -13, y: -13, width: 26, height: 26))
        }
        swing.contents = Self.deckImage(size, pixelScale, Self.drawArm)
        turn()
    }

    private static func platterImage(_ r: CGFloat, _ pad: CGFloat, _ scale: CGFloat) -> CGImage? {
        let side = (r + pad) * 2
        return drawImage(Int(side * scale), Int(side * scale), scale: scale) { ctx in
            let c = CGPoint(x: r + pad, y: r + pad)
            func disc(_ radius: CGFloat) -> CGRect { CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2) }
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -r * 0.05 * scale), blur: r * 0.14 * scale, color: gray(0, 0.65))
            ctx.setFillColor(rgb(0x111215))
            ctx.fillEllipse(in: disc(r))
            ctx.restoreGState()
            ctx.addEllipse(in: disc(r))
            ctx.clip()
            ctx.drawRadialGradient(
                gradient([(0, rgb(0x16171A)), (0.40, rgb(0x16171A)), (0.46, rgb(0x111215)), (0.94, rgb(0x15161A)), (0.972, rgb(0x24262B)), (0.984, rgb(0x0C0D0F)), (1, rgb(0x2B2D33))]),
                startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: []
            )
            // 声槽
            ctx.setLineWidth(r * 0.0042)
            ctx.setStrokeColor(gray(1, 0.032))
            for at in stride(from: 0.42, to: 0.965, by: 0.0084) { ctx.strokeEllipse(in: disc(r * at)) }
            // 曲目之间的间隔
            ctx.setLineWidth(r * 0.006)
            ctx.setStrokeColor(gray(0, 0.55))
            for at in [0.571, 0.711, 0.846] { ctx.strokeEllipse(in: disc(r * at)) }
            // 标签外面一圈
            ctx.setLineWidth(r * 0.008)
            ctx.setStrokeColor(rgb(0x0B0C0E))
            ctx.strokeEllipse(in: disc(r * 0.405))
            ctx.setLineWidth(r * 0.004)
            ctx.setStrokeColor(gray(1, 0.09))
            ctx.strokeEllipse(in: disc(r * 0.412))
        }
    }

    /// 以转轴为原点画
    private static func deckImage(_ size: CGSize, _ scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage? {
        drawImage(Int(size.width * scale), Int(size.height * scale), scale: scale * size.width / Tonearm.deck.width) { ctx in
            ctx.translateBy(x: Tonearm.pivot.x, y: Tonearm.pivot.y)
            draw(ctx)
        }
    }

    private static func drawKnob(_ ctx: CGContext, _ r: CGFloat, _ edge: CGFloat) {
        let box = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
        ctx.saveGState()
        ctx.addEllipse(in: box)
        ctx.clip()
        ctx.drawRadialGradient(
            gradient([(0, rgb(0x5B5F69)), (0.6, rgb(0x25272D)), (1, rgb(0x121317))]),
            startCenter: CGPoint(x: -r * 0.24, y: -r * 0.36), startRadius: 0, endCenter: CGPoint(x: -r * 0.24, y: -r * 0.36), endRadius: r * 1.6, options: .drawsAfterEndLocation
        )
        ctx.restoreGState()
        ctx.setStrokeColor(gray(1, edge))
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: box.insetBy(dx: 0.75, dy: 0.75))
    }

    private static func drawArm(_ ctx: CGContext) {
        let length = CGFloat(Tonearm.length)
        let tube = gradient([(0, rgb(0x8B8F98)), (0.4, rgb(0xF4F5F7)), (1, rgb(0x747883))])
        let dark = gradient([(0, rgb(0x17181C)), (0.45, rgb(0x4A4D55)), (1, rgb(0x101114))])
        func fill(_ path: CGPath, _ g: CGGradient) {
            let box = path.boundingBoxOfPath
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.drawLinearGradient(g, start: CGPoint(x: box.minX, y: 0), end: CGPoint(x: box.maxX, y: 0), options: [])
            ctx.restoreGState()
        }
        ctx.setShadow(offset: CGSize(width: -14, height: -22), blur: 34, color: gray(0, 0.5))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: -118))
        path.addCurve(to: CGPoint(x: 46, y: 340), control1: CGPoint(x: 0, y: 60), control2: CGPoint(x: 46, y: 230))
        path.addCurve(to: CGPoint(x: 20, y: length - 88), control1: CGPoint(x: 46, y: 400), control2: CGPoint(x: 36, y: 440))
        fill(path.copy(strokingWithWidth: 15, lineCap: .round, lineJoin: .round, miterLimit: 10), tube)
        ctx.saveGState()
        ctx.translateBy(x: -3, y: 0)
        ctx.addPath(path)
        ctx.setStrokeColor(gray(1, 0.55))
        ctx.setLineWidth(2.5)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.restoreGState()
        // 配重
        fill(CGPath(roundedRect: CGRect(x: -27, y: -142, width: 54, height: 70), cornerWidth: 9, cornerHeight: 9, transform: nil), dark)
        ctx.setFillColor(gray(1, 0.14))
        ctx.fill(CGRect(x: -27, y: -120, width: 54, height: 3))
        // 唱头：针尖在 (0, length)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: length)
        ctx.rotate(by: 13 * .pi / 180)
        let head = CGMutablePath()
        head.move(to: CGPoint(x: -15, y: -96))
        head.addLine(to: CGPoint(x: 15, y: -96))
        head.addLine(to: CGPoint(x: 21, y: -20))
        head.addQuadCurve(to: CGPoint(x: 4, y: 8), control: CGPoint(x: 21, y: 6))
        head.addLine(to: CGPoint(x: -4, y: 8))
        head.addQuadCurve(to: CGPoint(x: -21, y: -20), control: CGPoint(x: -21, y: 6))
        head.closeSubpath()
        fill(head, dark)
        ctx.setFillColor(gray(1, 0.22))
        ctx.fill(CGRect(x: -13, y: -70, width: 26, height: 3))
        ctx.move(to: CGPoint(x: 20, y: -60))
        ctx.addQuadCurve(to: CGPoint(x: 52, y: -42), control: CGPoint(x: 46, y: -58))
        ctx.setStrokeColor(rgb(0xC9CCD3))
        ctx.setLineWidth(5)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.setFillColor(rgb(0xFFD28A))
        ctx.fillEllipse(in: CGRect(x: -3.5, y: -9.5, width: 7, height: 7))
        ctx.restoreGState()
        ctx.endTransparencyLayer()
    }
}
