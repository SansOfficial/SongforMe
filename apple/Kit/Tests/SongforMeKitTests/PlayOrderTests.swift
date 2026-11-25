import Testing
@testable import SongforMeKit

/// 固定种子的随机数，测试结果可重复
func seeded(_ start: Int) -> RandomSource {
    var seed = start
    return {
        seed = (seed * 1_664_525 + 1_013_904_223) % 4_294_967_296
        return Double(seed) / 4_294_967_296
    }
}

@Suite("播放顺序")
struct PlayOrderTests {
    @Test("打乱：不丢歌、不重复")
    func keepsAll() {
        let list = Array(0..<50)
        let out = PlayOrder.shuffled(list, artistOf: { String($0) }, random: seeded(1))
        #expect(out != list)
        #expect(out.sorted() == list)
    }

    @Test("打乱：能排开的时候，同一位歌手不连着出现")
    func spreads() {
        var adjacent = 0
        for s in 1...200 {
            let out = PlayOrder.shuffled(Array(0..<50), artistOf: { String($0 % 5) }, random: seeded(s))
            for i in 1..<50 where out[i] % 5 == out[i - 1] % 5 { adjacent += 1 }
        }
        // 只有末尾剩下同一位歌手的歌时才可能连着
        #expect(Double(adjacent) / 200 < 1)
    }

    @Test("打乱：只有一位歌手时也能正常返回")
    func single() {
        #expect(PlayOrder.shuffled(Array(0..<6), artistOf: { _ in "a" }, random: seeded(3)).count == 6)
        #expect(PlayOrder.shuffled([Int](), artistOf: { String($0) }).isEmpty)
    }

    @Test("穿插：自己的歌顺序不变，推荐之间隔 2~4 首")
    func weave() {
        let base = Array(0..<60)
        for s in 1...50 {
            let out = PlayOrder.weave(base, (0..<PlayOrder.weaveCount(60)).map { 1000 + $0 }, random: seeded(s))
            #expect(out.filter { $0 < 1000 } == base)
            var since = 0
            var seen = 0
            for x in out {
                if x < 1000 { since += 1; continue }
                #expect((PlayOrder.weaveEvery - 1...PlayOrder.weaveEvery + 1).contains(since))
                since = 0
                seen += 1
            }
            #expect(seen > 12)
        }
    }

    @Test("穿插：推荐不够就插到用完为止，没有推荐就原样返回")
    func weaveShort() {
        #expect(PlayOrder.weave(Array(0..<30), [100, 101], random: seeded(2)).filter { $0 >= 100 } == [100, 101])
        #expect(PlayOrder.weave(Array(0..<5), []) == Array(0..<5))
    }
}

@Suite("歌词")
struct LyricsTests {
    @Test("跳过信息行和空行，一行多个时间戳会展开，结果按时间排序")
    func parse() {
        let lines = Lyrics.parse("[ti:测试]\n[offset:0]\n[00:00.00]标题\r\n[00:29.26]第一句\n[00:32.70]\n[00:32.75]第二句\n[01:05.5][02:10.50]重复的一句")
        #expect(lines.map(\.text) == ["标题", "第一句", "第二句", "重复的一句", "重复的一句"])
        #expect(abs(lines[1].t - 29.26) < 0.001)
        #expect(abs(lines[3].t - 65.5) < 0.001)
        #expect(abs(lines[4].t - 130.5) < 0.001)
    }

    @Test("翻译按时间戳对齐，占位符不算翻译")
    func trans() {
        let lines = Lyrics.parse("[00:01.00]Hello\n[00:05.00]La la\n[00:09.00]Bye", trans: "[00:01.00]你好\n[00:05.00]//\n[00:09.00]再见")
        #expect(lines.map(\.trans) == ["你好", nil, "再见"])
    }

    @Test("按播放位置找当前行")
    func index() {
        let lines = Lyrics.parse("[00:10.00]一\n[00:20.00]二\n[00:30.00]三")
        #expect([3, 10, 29.9, 999].map { Lyrics.index(in: lines, at: $0) } == [-1, 0, 1, 2])
        #expect(Lyrics.index(in: [], at: 5) == -1)
    }
}
