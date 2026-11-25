import Foundation
import Testing
@testable import SongforMeKit

/// 假的音频输出：play 立即成功，end() 模拟放完
@MainActor
final class FakeAudio: AudioOutput {
    var onEvent: ((AudioEvent) -> Void)?
    var currentTime = 0.0
    var duration = 200.0
    var isPaused = true
    var volume = 1.0
    var muted = false
    var urls: [String] = []

    func load(_ url: String, at position: Double) {
        urls.append(url)
        currentTime = position
    }
    func play() {
        isPaused = false
        onEvent?(.playing)
    }
    func pause() {
        isPaused = true
        onEvent?(.paused)
    }
    func seek(_ position: Double) { currentTime = position }
    func end() {
        isPaused = true
        onEvent?(.ended)
    }
}

func item(_ mid: String, _ source: PlaySource = .library) -> QueueItem {
    QueueItem(song: Song(mid: mid, name: mid, singers: [Singer(mid: "s-\(mid)", name: mid)], duration: 200, genre: 1, mediaMid: mid), source: source)
}
func items(_ n: Int) -> [QueueItem] { (0..<n).map { item("m\($0)") } }
func reco(_ mid: String) -> QueueItem { item(mid, .reco) }

@MainActor
@Suite("播放器")
final class PlayerTests {
    let audio = FakeAudio()
    var log: [PlayEvent] = []
    var blocked: Set<String> = []
    var p: Player!

    init() {
        p = Player(audio: audio, resolve: { [weak self] s in
            self?.blocked.contains(s.mid) == false ? StreamInfo(url: "x://\(s.mid)") : nil
        }, log: { [weak self] in self?.log.append($0) })
    }

    var mids: [String] { p.queue.map(\.song.mid) }
    var now: String? { p.current?.song.mid }
    func settle() async { for _ in 0..<40 { await Task.yield() } }

    @Test("单曲循环：放完重放同一首，点下一首照样切歌")
    func repeatOne() async {
        p.setRepeat(.one)
        p.setQueue(items(3))
        await settle()
        audio.end()
        await settle()
        #expect(now == "m0")
        #expect(p.playing)
        p.next()
        await settle()
        #expect(now == "m1")
        #expect(log.filter { $0.mid == "m0" }.map(\.type) == [.play, .complete, .play, .skip])
    }

    @Test("列表循环回到开头，不循环则停下")
    func repeatAll() async {
        p.setRepeat(.all)
        p.setQueue(items(2), startIndex: 1)
        await settle()
        audio.end()
        await settle()
        #expect(now == "m0")
        p.setRepeat(.off)
        p.next()
        await settle()
        audio.end()
        await settle()
        #expect(now == "m1")
        #expect(!p.playing)
    }

    @Test("全都放不了时会停下，不会无限循环")
    func allBlocked() async {
        blocked = ["m0", "m1"]
        p.setQueue(items(2))
        for _ in 0..<10 { await settle() }
        #expect(p.error?.contains("连续多首") == true)
        #expect(!p.loading)
    }

    @Test("跳过放不了的歌时，提示留到下一首放出来为止")
    func skipBlocked() async {
        blocked = ["m0"]
        p.setQueue(items(2))
        await settle()
        #expect(now == "m1")
        #expect(p.playing)
        #expect(p.unplayable == ["m0"])
    }

    @Test("播放地址中途失效会重新取一次，从原来的位置接着放；再失败才换下一首")
    func expired() async {
        p.setQueue(items(2))
        await settle()
        audio.currentTime = 60
        audio.onEvent?(.time(60))
        audio.onEvent?(.failed("x"))
        await settle()
        #expect(now == "m0")
        #expect(audio.urls == ["x://m0", "x://m0"])
        #expect(audio.currentTime == 60)
        audio.onEvent?(.failed("x"))
        await settle()
        #expect(now == "m1")
    }

    @Test("从点的那首开始，后面打乱；关掉后恢复原来的顺序")
    func shuffle() async {
        p.setShuffle(.on)
        p.setQueue(items(30), startIndex: 7)
        await settle()
        #expect(now == "m7")
        #expect(p.index == 0)
        #expect(Set(mids).count == 30)
        #expect(mids != items(30).map(\.song.mid))
        p.setShuffle(.off)
        #expect(mids == items(30).map(\.song.mid))
        #expect(p.index == 7)
    }

    @Test("播放途中打开随机，正在放的歌不中断")
    func shuffleMidway() async {
        p.setQueue(items(10), startIndex: 4)
        await settle()
        p.setShuffle(.on)
        #expect(now == "m4")
        #expect(log.map(\.type) == [.play])
    }

    @Test("移除的歌关掉随机之后不会回来")
    func removed() async {
        p.setShuffle(.on)
        p.setQueue(items(5))
        await settle()
        p.remove("m3")
        p.setShuffle(.off)
        #expect(mids == ["m0", "m1", "m2", "m4"])
    }

    @Test("一轮放完重新打乱，刚放完的那首不会排第一")
    func reshuffle() async {
        p.setShuffle(.on)
        p.setQueue(items(3))
        await settle()
        for _ in 0..<30 {
            let before = now
            p.next()
            await settle()
            #expect(now != before)
        }
    }

    @Test("穿插进来的歌带标记，已在列表里的不重复加，正在放的不动")
    func weaveIn() async {
        p.setShuffle(.smart)
        p.setQueue(items(12), context: "liked")
        await settle()
        p.weaveIn([reco("m5"), reco("r1"), reco("r2")])
        let extras = p.queue.filter(\.extra)
        #expect(extras.map(\.song.mid) == ["r1", "r2"])
        #expect(extras.allSatisfy { $0.source == .reco })
        #expect(p.queue.count == 14)
        #expect(now == "m0")
        // 再补一次会换掉还没放的，不会越积越多
        p.weaveIn([reco("r3")])
        #expect(p.queue.filter(\.extra).map(\.song.mid) == ["r3"])
    }

    @Test("关掉后穿插的歌消失；如果正在放的就是推荐，它会留到放完")
    func smartOff() async {
        p.setShuffle(.smart)
        p.setQueue(items(6), context: "liked")
        await settle()
        p.weaveIn([reco("r1")])
        p.playAt(mids.firstIndex(of: "r1")!)
        p.setShuffle(.off)
        #expect(now == "r1")
        #expect(p.queue.count == 7)
        p.setShuffle(.on)
        #expect(now == "r1")
        p.next()
        await settle()
        p.setShuffle(.off)
        #expect(mids == items(6).map(\.song.mid))
    }

    @Test("重新打乱后会通知外面补推荐")
    func notifies() {
        var count = 0
        p.onReshuffle = { count += 1 }
        p.setQueue(items(3), context: "liked")
        #expect(count == 0)
        p.setShuffle(.on)
        p.setShuffle(.smart)
        #expect(count == 2)
    }

    @Test("静音可以来回切，拖到 0 再取消静音会有声音，设置会保存")
    func volume() {
        var saved: PlaybackPrefs?
        p.onPrefs = { saved = $0 }
        p.setVolume(0.6)
        p.toggleMute()
        #expect(audio.muted)
        p.toggleMute()
        #expect(!p.prefs.muted && p.prefs.volume == 0.6)
        p.setVolume(0)
        p.toggleMute()
        #expect(!p.prefs.muted && p.prefs.volume == 0.5)
        var want = PlaybackPrefs()
        want.volume = 0.5
        #expect(saved == want)
    }

    @Test("听了多久：只算真正出声的部分，拖过去的、暂停的不算")
    func listening() async {
        var heard: [Listen] = []
        p.onListen = { heard.append($1) }
        func play(from a: Double, to b: Double) {
            for t in stride(from: a, through: b, by: 0.25) {
                audio.currentTime = t
                audio.onEvent?(.time(t))
            }
        }
        p.setQueue(items(3))
        await settle()
        play(from: 0, to: 20)
        #expect(heard.map(\.seconds) == [15]) // 听一会儿先存一次
        p.seek(150)
        play(from: 150, to: 160)
        p.toggle()
        #expect(heard.last?.seconds == 30)
        p.toggle()
        play(from: 160, to: 165)
        p.next()
        await settle()
        #expect(heard.last?.seconds == 35 && Set(heard.map(\.ts)).count == 1)
        play(from: 0, to: 4)
        audio.end()
        await settle()
        #expect(heard.last.map { "\($0.mid) \($0.seconds)" } == "m1 4.0")
    }

    @Test("单曲循环每放一遍算一次")
    func listeningLoop() async {
        var heard: [Listen] = []
        p.onListen = { heard.append($1) }
        p.setRepeat(.one)
        p.setQueue(items(1))
        await settle()
        for _ in 0..<2 {
            for t in [0.0, 1, 2] { audio.onEvent?(.time(t)) }
            try? await Task.sleep(for: .milliseconds(5))
            audio.end()
            await settle()
        }
        #expect(heard.map(\.seconds) == [2, 2] && Set(heard.map(\.ts)).count == 2)
    }
}
