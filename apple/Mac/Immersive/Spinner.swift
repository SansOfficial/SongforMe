import AppKit
import QuartzCore

/// 让一个图层匀速转；停和转都有惯性。全部交给系统合成，主线程忙也不掉帧
final class Spinner {
    private weak var layer: CALayer?
    private let period: Double
    private let ramp = 0.9
    private var running = false

    init(_ layer: CALayer, period: Double) {
        self.layer = layer
        self.period = period
    }

    private var angle: Double { (layer?.presentation() ?? layer)?.value(forKeyPath: "transform.rotation.z") as? Double ?? 0 }

    func set(_ on: Bool) {
        guard on != running, let layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        running = on
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        let from = angle
        let speed = 2 * Double.pi / period
        // 二次曲线加减速，起止速度正好接上匀速
        let glide = speed * ramp / 2
        hold(from)
        layer.removeAnimation(forKey: "spin")
        let ease = CABasicAnimation(keyPath: "transform.rotation.z")
        ease.fromValue = from
        ease.toValue = from + glide
        ease.duration = ramp
        ease.beginTime = now
        ease.fillMode = .both
        ease.isRemovedOnCompletion = false
        ease.timingFunction = on
            ? CAMediaTimingFunction(controlPoints: 1 / 3, 0, 2 / 3, 1 / 3)
            : CAMediaTimingFunction(controlPoints: 1 / 3, 2 / 3, 2 / 3, 1)
        layer.add(ease, forKey: "ramp")
        guard on else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = from + glide
        spin.toValue = from + glide + 2 * Double.pi
        spin.duration = period
        spin.beginTime = now + ramp
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        layer.add(spin, forKey: "spin")
    }

    /// 转回正的位置停住
    func straighten() {
        guard let layer else { return }
        running = false
        let from = angle
        layer.removeAnimation(forKey: "spin")
        layer.removeAnimation(forKey: "ramp")
        hold(0)
        guard abs(from) > 0.001 else { return }
        let back = CASpringAnimation(keyPath: "transform.rotation.z")
        back.fromValue = from
        back.toValue = 0
        back.mass = 1
        back.stiffness = 90
        back.damping = 18
        back.duration = back.settlingDuration
        layer.add(back, forKey: "straighten")
    }

    private func hold(_ angle: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.setValue(angle, forKeyPath: "transform.rotation.z")
        CATransaction.commit()
    }
}

/// 自己管图层的视图：坐标从左上角算起，尺寸变化时不做隐式动画
class LayerView: NSView {
    let root = CALayer()

    init() {
        super.init(frame: .zero)
        layer = root
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrange(bounds.size)
        CATransaction.commit()
    }

    func arrange(_ size: CGSize) {}

    var pixelScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
}

/// 在左上角为原点的坐标里画一张图
nonisolated func drawImage(_ width: Int, _ height: Int, scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage? {
    guard width > 0, height > 0,
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    else { return nil }
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: scale, y: -scale)
    draw(ctx)
    return ctx.makeImage()
}

nonisolated func gray(_ white: CGFloat, _ alpha: CGFloat = 1) -> CGColor { CGColor(srgbRed: white, green: white, blue: white, alpha: alpha) }
nonisolated func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
nonisolated func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}
