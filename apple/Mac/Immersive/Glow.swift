import CoreImage
import SongforMeKit
import SwiftUI

/// 用封面的颜色铺出来的、缓慢流动的背景
struct Glow: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> GlowView { GlowView() }
    func updateNSView(_ view: GlowView, context: Context) { view.show(url) }
}

final class GlowView: LayerView {
    private var url: URL?
    private var started = false
    private var task: Task<Void, Never>?
    private let shade = CAGradientLayer()

    override init() {
        super.init()
        root.backgroundColor = rgb(0x0A0B10)
        shade.type = .radial
        shade.colors = [rgb(0x08090E, 0.36), rgb(0x08090E, 0.82)]
        shade.startPoint = CGPoint(x: 0.5, y: 0.45)
        shade.endPoint = CGPoint(x: 1.2, y: 1.35)
        shade.zPosition = 1
        root.addSublayer(shade)
    }

    func show(_ next: URL?) {
        guard !started || next != url else { return }
        started = true
        url = next
        task?.cancel()
        task = Task {
            guard let image = await ImageLoader.shared.image(next, pixels: 300), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), !Task.isCancelled else { return }
            guard let blob = await Self.blob(cg), !Task.isCancelled else { return }
            put(blob)
        }
    }

    /// 一团封面的颜色：小图上模糊好一次，边缘化开，之后只是放大和移动
    @concurrent
    private nonisolated static func blob(_ cover: CGImage) async -> CGImage? {
        let side = 160.0
        let input = CIImage(cgImage: cover)
        let scaled = input.transformed(by: CGAffineTransform(scaleX: (side - 40) / input.extent.width, y: (side - 40) / input.extent.height))
            .transformed(by: CGAffineTransform(translationX: 20, y: 20))
            .clampedToExtent()
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.7])
            .applyingGaussianBlur(sigma: 20)
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        guard let soft = CIContext(options: [.cacheIntermediates: false]).createCGImage(scaled, from: CGRect(x: 0, y: 0, width: side, height: side)) else { return nil }
        return drawImage(Int(side), Int(side), scale: 1) { ctx in
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            ctx.draw(soft, in: rect)
            ctx.setBlendMode(.destinationIn)
            ctx.drawRadialGradient(
                gradient([(0, gray(0, 1)), (1, gray(0, 0))]), startCenter: CGPoint(x: side / 2, y: side / 2), startRadius: side * 0.16,
                endCenter: CGPoint(x: side / 2, y: side / 2), endRadius: side / 2, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
    }

    private struct Drift {
        let from: (x: Double, y: Double, turn: Double, scale: Double)
        let to: (x: Double, y: Double, turn: Double, scale: Double)
        let seconds: Double
    }
    private static let drifts = [
        Drift(from: (-0.26, -0.18, 0, 1.05), to: (-0.08, 0.16, 150, 1.24), seconds: 47),
        Drift(from: (0.30, 0.22, 60, 1.10), to: (0.10, -0.20, -100, 0.90), seconds: 61),
        Drift(from: (0.06, 0.26, -40, 0.71), to: (0.32, -0.10, 120, 1.00), seconds: 53),
    ]

    private func put(_ blob: CGImage) {
        let old = (root.sublayers ?? []).filter { $0 !== shade }
        let group = CALayer()
        group.backgroundColor = rgb(0x0A0B10)
        for _ in Self.drifts {
            let l = CALayer()
            l.contents = blob
            l.magnificationFilter = .linear
            group.addSublayer(l)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.addSublayer(group)
        arrange(bounds.size)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { old.forEach { $0.removeFromSuperlayer() } } }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = old.isEmpty ? 0.6 : 1.8
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    private var arranged = CGSize.zero

    override func arrange(_ size: CGSize) {
        shade.frame = CGRect(origin: .zero, size: size)
        for group in root.sublayers ?? [] where group !== shade {
            let resized = group.frame.size != size
            group.frame = CGRect(origin: .zero, size: size)
            let side = max(size.width, size.height) * 1.2
            for (l, d) in zip(group.sublayers ?? [], Self.drifts) {
                l.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                l.position = CGPoint(x: size.width / 2, y: size.height / 2)
                if resized || l.animation(forKey: "drift") == nil { drift(l, d, size) }
            }
        }
    }

    private func drift(_ l: CALayer, _ d: Drift, _ size: CGSize) {
        func transform(_ t: (x: Double, y: Double, turn: Double, scale: Double)) -> [String: Any] {
            ["transform.translation.x": t.x * size.width, "transform.translation.y": t.y * size.height, "transform.rotation.z": t.turn * .pi / 180, "transform.scale": t.scale]
        }
        let a = transform(d.from), b = transform(d.to)
        let group = CAAnimationGroup()
        group.animations = a.keys.map { key in
            let x = CABasicAnimation(keyPath: key)
            x.fromValue = a[key]
            x.toValue = b[key]
            x.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            x.duration = d.seconds
            return x
        }
        group.duration = d.seconds
        group.autoreverses = true
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { group.speed = 0 }
        l.add(group, forKey: "drift")
    }
}
