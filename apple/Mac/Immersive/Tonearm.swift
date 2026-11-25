import Foundation

/// 黑胶唱臂的几何：唱片、转轴、唱针都在同一个 1160×1000 的坐标系里
enum Tonearm {
    static let deck = CGSize(width: 1160, height: 1000)
    static let disc = CGPoint(x: 480, y: 500)
    static let discRadius = 460.0
    /// 唱片中间标签的半径
    static let labelRadius = 184.0
    static let pivot = CGPoint(x: 1040, y: 150)
    /// 转轴到唱针的距离
    static let length = 570.0
    /// 第一条和最后一条声槽的半径
    static let groove = (outer: 436.0, inner: 208.0)
    /// 停在唱片外面时的角度。0 度是垂直向下，顺时针为正
    static let rest = -3.0

    /// 唱针落在半径 r 的声槽上时，唱臂要转多少度
    static func angle(at r: Double) -> Double {
        let dx = disc.x - pivot.x, dy = disc.y - pivot.y
        let d = hypot(dx, dy)
        let between = acos((length * length + d * d - r * r) / (2 * length * d))
        return (atan2(dy, dx) - between) * 180 / .pi - 90
    }

    /// 歌放到 progress（0~1）时唱臂的角度：从最外圈慢慢走到最里圈
    static func angle(progress: Double) -> Double {
        let p = progress.isFinite ? min(1, max(0, progress)) : 0
        return angle(at: groove.outer + (groove.inner - groove.outer) * p)
    }
}
