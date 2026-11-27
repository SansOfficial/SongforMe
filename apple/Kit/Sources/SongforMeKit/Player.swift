import Foundation
import Observation

// 播放器：管理播放队列和音频输出，并把“听完 / 切歌”等行为记下来喂给推荐算法。

public struct QueueItem: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var song: Song
    public var source: PlaySource
    /// 智能随机穿插进来的推荐，不在原来的列表里
    public var extra = false

    public init(song: Song, source: PlaySource) {
        self.song = song
        self.source = source
    }

    public static func == (a: QueueItem, b: QueueItem) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// smart：随机播放的同时穿插推荐，只在支持的列表（我喜欢）里起作用，别的列表里等同于 on
public enum ShuffleMode: String, Codable, Sendable {
    case off, on, smart
}

public enum RepeatMode: String, Codable, Sendable {
    case off, all, one
}

/// 记在本机、下次打开还在的播放设置
public struct PlaybackPrefs: Codable, Equatable, Sendable {
    public var shuffle = ShuffleMode.off
    public var `repeat` = RepeatMode.all
    /// 0~1，界面上滑块的位置
    public var volume = 1.0
    public var muted = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PlaybackPrefs()
        shuffle = try c.decodeIfPresent(ShuffleMode.self, forKey: .shuffle) ?? d.shuffle
        `repeat` = try c.decodeIfPresent(RepeatMode.self, forKey: .repeat) ?? d.repeat
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? d.volume
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? d.muted
    }
}

public enum AudioEvent: Sendable {
    case playing, paused, waiting, ended
    case time(Double)
    case failed(String)
}

/// 真正出声的部分，由平台实现
@MainActor
public protocol AudioOutput: AnyObject {
    var onEvent: ((AudioEvent) -> Void)? { get set }
    var currentTime: Double { get }
    /// 还不知道总时长时为 0
    var duration: Double { get }
    var isPaused: Bool { get }
    var volume: Double { get set }
    var muted: Bool { get set }
    func load(_ url: String, at position: Double)
    func play()
    func pause()
    func seek(_ position: Double)
}

@MainActor
@Observable
public final class Player {
    /// 听到这个比例以上再切歌，算作听完
    static let completeRatio = 0.9
    static let maxConsecutiveFailures = 5

    public private(set) var queue: [QueueItem] = []
    public private(set) var index = -1
    /// 这个队列是从哪个列表来的，比如 liked
    public private(set) var context = ""
    public private(set) var playing = false
    public private(set) var loading = false
    public private(set) var position = 0.0
    public private(set) var duration = 0.0
    public private(set) var error: String?
    /// 账号无权播放的歌，界面上置灰
    public private(set) var unplayable: Set<String> = []
    public private(set) var prefs = PlaybackPrefs()

    @ObservationIgnored private let audio: any AudioOutput
    @ObservationIgnored private let resolve: (Song) async throws -> StreamInfo?
    @ObservationIgnored private let log: (PlayEvent) -> Void
    /// 当前这首是否真的出过声（出过声才记行为）
    @ObservationIgnored private var started = false
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var ticket = 0
    /// 列表原来的顺序（不含穿插的推荐），关掉随机时恢复用
    @ObservationIgnored private var origin: [QueueItem] = []
    /// 队列每重排一次加一，异步穿插推荐时用来判断队列有没有变过
    @ObservationIgnored public private(set) var epoch = 0
    /// 队列按随机重新排过之后通知外面（智能随机在这里补推荐）
    @ObservationIgnored public var onReshuffle: (() -> Void)?
    @ObservationIgnored public var onPrefs: ((PlaybackPrefs) -> Void)?
    /// 换歌、播放暂停、跳转之后通知外面（系统的“正在播放”用）
    @ObservationIgnored public var onChange: (() -> Void)?
    /// 这次播放真正听了多久，每听一会儿报一次，离开这首歌时再报一次
    @ObservationIgnored public var onListen: ((Song, Listen) -> Void)?
    @ObservationIgnored private var listen: Listen?
    @ObservationIgnored private var lastTick: Double?
    @ObservationIgnored private var reported = 0.0
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var retried = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    public init(audio: any AudioOutput, resolve: @escaping (Song) async throws -> StreamInfo?, log: @escaping (PlayEvent) -> Void) {
        self.audio = audio
        self.resolve = resolve
        self.log = log
        audio.onEvent = { [weak self] in self?.handle($0) }
    }

    public var current: QueueItem? { queue.indices.contains(index) ? queue[index] : nil }
    /// 此刻放到哪里，比 position（每秒更新几次）精细
    public var time: Double { loading ? position : audio.currentTime }
    /// 后面还有多少首（不含穿插的推荐）
    public var upcomingCount: Int { queue.dropFirst(index + 1).count { !$0.extra } }

    private func handle(_ event: AudioEvent) {
        switch event {
        case .playing:
            if let cur = current, !started {
                started = true
                failures = 0
                record(cur, .play, 0)
                listen = Listen(mid: cur.song.mid, ts: nowMillis(), seconds: 0, source: cur.source)
                reported = 0
                lastTick = nil
            }
            playing = true
            loading = false
            error = nil
            onChange?()
        case .paused:
            playing = false
            lastTick = nil
            reportListen()
            onChange?()
        case .waiting:
            loading = true
        case .time(let t):
            guard !loading else { return }
            position = t
            heard(t)
            if audio.duration > 0, abs(audio.duration - duration) > 0.01 { duration = audio.duration }
        case .ended:
            if let cur = current, started { record(cur, .complete, 1) }
            endListen()
            if stopAfterCurrent {
                stopAfterCurrent = false
                hold = true
            }
            advance(auto: true)
        case .failed:
            // 播放地址有时效，中途失效时重新取一次
            if !retried, current != nil {
                retried = true
                load(index, resumeAt: position)
            } else {
                failAndAdvance("这首歌播放失败")
            }
        }
    }

    private func record(_ item: QueueItem, _ type: EventType, _ ratio: Double) {
        log(PlayEvent(mid: item.song.mid, type: type, ratio: ratio, source: item.source, ts: nowMillis()))
    }

    /// 离开当前这首歌之前，按已播放的比例记一条“听完”或“切歌”
    private func settleCurrent() {
        if let cur = current, started, audio.duration > 0 {
            let ratio = min(1, audio.currentTime / audio.duration)
            record(cur, ratio >= Self.completeRatio ? .complete : .skip, ratio)
        }
        endListen()
    }

    // MARK: 听了多久

    /// 每隔多少秒存一次，应用突然退出时最多少记这么久
    static let reportEvery = 15.0
    /// 播放器每秒报好几次进度；两次之间跳得比这还远，说明是拖过去的
    static let tickLimit = 2.0

    private func heard(_ t: Double) {
        defer { lastTick = t }
        guard listen != nil, let last = lastTick, t > last, t - last <= Self.tickLimit else { return }
        listen!.seconds += t - last
        if listen!.seconds - reported >= Self.reportEvery { reportListen() }
    }

    private func reportListen() {
        guard let l = listen, l.seconds > reported, let song = current?.song, song.mid == l.mid else { return }
        reported = l.seconds
        onListen?(song, l)
    }

    private func endListen() {
        reportListen()
        listen = nil
        lastTick = nil
        started = false
    }

    // MARK: 队列

    /// 换一个列表来放。startIndex 为 nil 表示没有指定从哪首开始：随机播放时随便挑一首，否则从头
    public func setQueue(_ items: [QueueItem], startIndex: Int? = 0, context: String = "") {
        settleCurrent()
        origin = items
        epoch += 1
        self.context = context
        index = -1
        if prefs.shuffle == .off {
            queue = items
            playAt(startIndex ?? 0, settle: false)
            return
        }
        queue = shuffleFrom(startIndex.map { items[$0] })
        playAt(0, settle: false)
        onReshuffle?()
    }

    private func shuffleFrom(_ first: QueueItem? = nil) -> [QueueItem] {
        let rest = PlayOrder.shuffled(origin.filter { $0 != first }, artistOf: { $0.song.singers.first?.mid ?? "" })
        return first.map { [$0] + rest } ?? rest
    }

    /// 切换随机方式。正在放的歌不受影响，只重排后面的
    public func setShuffle(_ mode: ShuffleMode) {
        let before = prefs.shuffle
        if mode == before { return }
        prefs.shuffle = mode
        onPrefs?(prefs)
        guard !queue.isEmpty else { return }
        let cur = current
        if mode == .off {
            var next = origin
            if let cur, cur.extra {
                // 正在放的是穿插进来的推荐：放回它前面那首自己的歌后面
                let mine = queue[..<index].last { !$0.extra }
                next.insert(cur, at: mine.flatMap { next.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
            }
            epoch += 1
            queue = next
            index = cur.flatMap { next.firstIndex(of: $0) } ?? -1
            return
        }
        if before == .off {
            epoch += 1
            queue = shuffleFrom(cur)
            index = cur == nil ? -1 : 0
        }
        onReshuffle?()
    }

    public func setRepeat(_ mode: RepeatMode) {
        prefs.repeat = mode
        onPrefs?(prefs)
    }

    /// 把推荐穿插到还没放的歌里；之前穿插的、还没放到的会被换掉
    public func weaveIn(_ extras: [QueueItem]) {
        let have = Set(origin.map(\.song.mid))
        let head = Array(queue.prefix(index + 1))
        let played = Set(head.map(\.song.mid))
        let fresh = extras.filter { !have.contains($0.song.mid) && !played.contains($0.song.mid) }.map { item in
            var x = item
            x.extra = true
            return x
        }
        queue = head + PlayOrder.weave(queue.dropFirst(index + 1).filter { !$0.extra }, fresh)
    }

    /// 换掉还没放的歌（推荐跟着反馈重排时用）；放过的和正在放的不动
    public func replaceUpcoming(_ items: [QueueItem]) {
        let head = Array(queue.prefix(index + 1))
        let played = Set(head.map(\.song.mid))
        let rest = items.filter { !played.contains($0.song.mid) }
        origin = origin.filter { played.contains($0.song.mid) } + rest
        epoch += 1
        queue = head + (prefs.shuffle == .off ? rest : PlayOrder.shuffled(rest, artistOf: { $0.song.singers.first?.mid ?? "" }))
    }

    public func restore(_ saved: PlaybackPrefs) {
        prefs = saved
        applyVolume()
    }

    /// 把歌从队列里拿掉（比如点了“不喜欢”）
    public func remove(_ mid: String) {
        origin.removeAll { $0.song.mid == mid }
        guard let at = queue.firstIndex(where: { $0.song.mid == mid }) else { return }
        if at == index {
            settleCurrent()
            queue.remove(at: at)
            index = -1
            playAt(min(at, queue.count - 1), settle: false)
        } else {
            queue.remove(at: at)
            if at < index { index -= 1 }
        }
    }

    // MARK: 插队、排序

    /// 接在正在放的这首后面放。队列里还没放到的同一首会挪过来，不会出现两次；队列是空的就直接开始放
    public func playNext(_ items: [QueueItem]) {
        guard !items.isEmpty else { return }
        guard current != nil else { return start(items) }
        let cur = current
        let mids = Set(items.map(\.song.mid))
        dropUpcoming(mids)
        queue.insert(contentsOf: items, at: index + 1)
        // 关掉随机时按原来的顺序排，这几首也要紧跟在正在放的这首后面
        let anchor = cur.flatMap { origin.firstIndex(of: $0) }
            ?? queue[..<index].last { !$0.extra }.flatMap { origin.firstIndex(of: $0) }
        origin.insert(contentsOf: items, at: anchor.map { $0 + 1 } ?? 0)
        epoch += 1
    }

    /// 加到队列最后
    public func enqueue(_ items: [QueueItem]) {
        guard !items.isEmpty else { return }
        guard current != nil else { return start(items) }
        dropUpcoming(Set(items.map(\.song.mid)))
        queue += items
        origin += items
        epoch += 1
    }

    /// 调整还没放的歌的顺序。offsets 和 to 都从正在放的下一首算起
    public func moveUpcoming(fromOffsets offsets: IndexSet, toOffset to: Int) {
        let base = index + 1
        var rest = Array(queue[base...])
        let moving = offsets.filter { rest.indices.contains($0) }.map { rest[$0] }
        guard !moving.isEmpty else { return }
        let target = to - offsets.count { $0 < to }
        rest = rest.indices.filter { !offsets.contains($0) }.map { rest[$0] }
        rest.insert(contentsOf: moving, at: min(max(0, target), rest.count))
        queue = Array(queue[..<base]) + rest
        if prefs.shuffle == .off { origin = queue.filter { !$0.extra } }
        epoch += 1
    }

    /// 队列空着的时候插队，就把这几首当成新的队列来放
    private func start(_ items: [QueueItem]) {
        settleCurrent()
        origin = items
        queue = items
        context = ""
        index = -1
        epoch += 1
        playAt(0, settle: false)
    }

    /// 拿掉还没放到的这些歌（正在放的和放过的不动）
    private func dropUpcoming(_ mids: Set<String>) {
        let keep = Set(queue.prefix(index + 1).map(\.id))
        queue = Array(queue.prefix(index + 1)) + queue.dropFirst(index + 1).filter { !mids.contains($0.song.mid) }
        origin.removeAll { mids.contains($0.song.mid) && !keep.contains($0.id) }
    }

    // MARK: 睡眠定时

    /// 放完这首就停。停下时已经换到下一首，再按播放从下一首开始
    public var stopAfterCurrent = false {
        didSet { if stopAfterCurrent != oldValue { onChange?() } }
    }
    /// 这首放完、该停的时候置上，接下来那次换歌只摆好不出声
    @ObservationIgnored private var hold = false
    /// 放完这首停下之后通知外面
    @ObservationIgnored public var onStopped: (() -> Void)?

    /// 停在第 i 首：显示出来，但不取地址、不出声，按播放时才开始
    private func cue(_ i: Int) {
        ticket += 1
        loadTask?.cancel()
        audio.pause()
        loaded = false
        lastTick = nil
        index = i
        loading = false
        playing = false
        position = 0
        duration = queue[i].song.duration
        error = nil
        onChange?()
        onStopped?()
    }

    public func playAt(_ i: Int, settle: Bool = true) {
        if settle { settleCurrent() }
        let hold = self.hold
        self.hold = false
        if hold, queue.indices.contains(i) { return cue(i) }
        guard queue.indices.contains(i) else {
            if hold { onStopped?() }
            ticket += 1
            audio.pause()
            playing = false
            loading = false
            return
        }
        retried = false
        load(i, resumeAt: 0)
    }

    /// 放下一首。auto 表示是自己放完的：这时单曲循环会重放同一首；
    /// 用户主动点“下一首”则不受单曲循环限制。
    private func advance(auto: Bool) {
        if auto, prefs.repeat == .one, loaded {
            retried = false
            audio.seek(0)
            position = 0
            if hold {
                hold = false
                audio.pause()
                onStopped?()
            } else {
                audio.play()
            }
            return
        }
        // 已经知道放不了的歌直接跳过
        var next = index + 1
        while next < queue.count, unplayable.contains(queue[next].song.mid) { next += 1 }
        if next < queue.count || prefs.repeat == .off {
            playAt(next, settle: false)
            return
        }
        // 一轮放完，从头再来；随机播放时重新打乱，并避免刚放完的那首又排在第一
        if prefs.shuffle != .off, origin.count > 1 {
            let last = current
            var order = shuffleFrom()
            if let last, order.first == last { order = Array(order.dropFirst()) + [last] }
            epoch += 1
            queue = order
            index = -1
            playAt(0, settle: false)
            onReshuffle?()
        } else {
            playAt(0, settle: false)
        }
    }

    // MARK: 取地址、出声

    private func load(_ i: Int, resumeAt: Double) {
        let item = queue[i]
        ticket += 1
        let mine = ticket
        audio.pause()
        loaded = false
        lastTick = nil
        index = i
        loading = true
        position = resumeAt
        duration = item.song.duration
        error = nil
        onChange?()
        loadTask?.cancel()
        loadTask = Task {
            do {
                let stream = try await resolve(item.song)
                guard mine == ticket else { return } // 期间用户又切了歌
                guard let stream else {
                    unplayable.insert(item.song.mid)
                    failAndAdvance("《\(item.song.name)》当前账号无法播放，已跳过")
                    return
                }
                loaded = true
                audio.load(stream.url, at: resumeAt)
                audio.play()
            } catch {
                guard mine == ticket, !(error is CancellationError) else { return }
                fail(error.localizedDescription)
            }
        }
    }

    private func fail(_ message: String) {
        audio.pause()
        loading = false
        playing = false
        error = message
        onChange?()
    }

    private func failAndAdvance(_ message: String) {
        failures += 1
        if failures >= Self.maxConsecutiveFailures {
            fail("连续多首无法播放，已停止。请检查登录状态或网络")
            failures = 0
            return
        }
        endListen()
        advance(auto: false)
        error = message
    }

    // MARK: 控制

    public func toggle() {
        if index < 0 {
            if !queue.isEmpty { playAt(0, settle: false) }
        } else if loaded {
            if audio.isPaused { audio.play() } else { audio.pause() }
        } else if !loading {
            // 上次没取到地址就停下了，再试一次
            retried = false
            load(index, resumeAt: position)
        }
    }

    public func next() {
        settleCurrent()
        advance(auto: false)
    }

    public func previous() {
        if audio.currentTime > 5 { seek(0) } else if !queue.isEmpty { playAt(max(0, index - 1)) }
    }

    public func seek(_ seconds: Double) {
        guard seconds.isFinite, loaded else { return }
        audio.seek(seconds)
        lastTick = nil
        // 不等播放器回报，界面立刻到位
        position = seconds
        onChange?()
    }

    public func setVolume(_ v: Double) {
        prefs.volume = min(1, max(0, v))
        prefs.muted = prefs.volume == 0
        applyVolume()
        onPrefs?(prefs)
    }

    public func toggleMute() {
        // 音量拖到 0 之后再点喇叭，给一个听得见的音量
        if prefs.muted, prefs.volume == 0 { prefs.volume = 0.5 }
        prefs.muted.toggle()
        applyVolume()
        onPrefs?(prefs)
    }

    private func applyVolume() {
        // 人耳对响度的感觉不是线性的，平方之后滑块拖起来更均匀
        audio.volume = prefs.volume * prefs.volume
        audio.muted = prefs.muted
    }
}
