import Foundation

// 歌词解析：把 LRC 文本变成按时间排序的行，并能按播放位置找到当前行。

public struct LyricLine: Hashable, Sendable {
    /// 这一行开始的时间，秒
    public var t: Double
    public var text: String
    /// 翻译（外语歌才有）
    public var trans: String?
}

public enum Lyrics {
    private static func parseOne(_ lrc: String) -> [(t: Double, text: String)] {
        let stamp = /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/
        var out: [(t: Double, text: String)] = []
        for raw in lrc.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let stamps = raw.matches(of: stamp)
            if stamps.isEmpty { continue } // [ti:] [ar:] 这类信息行没有时间戳
            let text = raw.replacing(stamp, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            for m in stamps {
                var t = Double(m.1)! * 60 + Double(m.2)!
                if let frac = m.3 { t += Double(frac)! / pow(10, Double(frac.count)) }
                out.append((t, text))
            }
        }
        return out.sorted { $0.t < $1.t }
    }

    public static func parse(_ lrc: String, trans: String = "") -> [LyricLine] {
        var lines = parseOne(lrc).filter { !$0.text.isEmpty }.map { LyricLine(t: $0.t, text: $0.text) }
        guard !trans.isEmpty else { return lines }
        // 翻译和原文靠时间戳对齐；“//”是翻译里表示“这一行不翻译”的占位符
        let slot = { (t: Double) in Int((t * 100).rounded()) }
        let byTime = Dictionary(parseOne(trans).map { (slot($0.t), $0.text) }, uniquingKeysWith: { $1 })
        for i in lines.indices {
            if let tr = byTime[slot(lines[i].t)], !tr.isEmpty, tr != "//", tr != lines[i].text { lines[i].trans = tr }
        }
        return lines
    }

    /// 播放到 position 秒时应该显示第几行；还没到第一行时返回 -1
    public static func index(in lines: [LyricLine], at position: Double) -> Int {
        var lo = 0
        var hi = lines.count - 1
        var found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].t <= position {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return found
    }
}
