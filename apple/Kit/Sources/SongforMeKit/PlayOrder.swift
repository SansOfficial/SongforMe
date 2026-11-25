// 播放顺序：打乱、把推荐穿插进去。纯函数，方便单独测试。

public enum PlayOrder {
    /// 打乱顺序，并尽量不让同一位歌手的歌连着出现（纯随机听起来反而不像随机）
    public static func shuffled<T>(_ list: [T], artistOf: (T) -> String, random: RandomSource = { .random(in: 0..<1) }) -> [T] {
        var out = list
        for i in stride(from: out.count - 1, to: 0, by: -1) {
            out.swapAt(i, Int(random() * Double(i + 1)))
        }
        guard out.count > 1 else { return out }
        for i in 1..<out.count {
            let prev = artistOf(out[i - 1])
            if prev.isEmpty || artistOf(out[i]) != prev { continue }
            guard let j = out.indices.first(where: { $0 > i && artistOf(out[$0]) != prev }) else { break } // 后面全是这位歌手的歌，排不开了
            out.swapAt(i, j)
        }
        return out
    }

    /// 平均隔几首自己的歌穿插一首推荐
    public static let weaveEvery = 3

    /// 一段这么长的队列需要多少首推荐
    public static func weaveCount(_ length: Int) -> Int { (Double(length) / Double(weaveEvery)).jsRounded }

    /// 每隔 2~4 首插一首推荐，间隔随机；推荐不够就插到用完为止
    public static func weave<T>(_ base: [T], _ extras: [T], random: RandomSource = { .random(in: 0..<1) }) -> [T] {
        var out: [T] = []
        out.reserveCapacity(base.count + extras.count)
        func gap() -> Int { weaveEvery - 1 + Int(random() * 3) }
        var left = gap()
        var e = 0
        for item in base {
            out.append(item)
            left -= 1
            if left == 0, e < extras.count {
                out.append(extras[e])
                e += 1
                left = gap()
            }
        }
        return out
    }
}
