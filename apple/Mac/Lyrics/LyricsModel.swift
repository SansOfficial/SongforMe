import Foundation
import Observation
import SongforMeKit

/// 当前这首歌的歌词和唱到哪一行；桌面歌词和全屏页都看这里
@Observable
final class LyricsModel {
    private(set) var lines: [LyricLine] = []
    /// 还没到第一句时为 -1
    private(set) var index = -1
    private(set) var loading = false
    /// 这份歌词属于哪首歌
    private(set) var song: Song?

    @ObservationIgnored private let hub: SourceHub
    @ObservationIgnored private unowned let player: Player
    @ObservationIgnored private var cache: [String: [LyricLine]] = [:]
    @ObservationIgnored private var watchers: Set<String> = []
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(hub: SourceHub, player: Player) {
        self.hub = hub
        self.player = player
    }

    /// 有地方在显示歌词时才去取、才跟着走
    func watch(_ who: String, _ on: Bool) {
        if on { watchers.insert(who) } else { watchers.remove(who) }
        follow()
    }

    /// 换歌、播放暂停、拖动进度之后调用
    func follow() {
        ticker?.cancel()
        guard !watchers.isEmpty else { return }
        let current = player.current?.song
        if current?.mid != song?.mid { load(current) }
        tick()
    }

    private func load(_ next: Song?) {
        song = next
        lines = next.flatMap { cache[$0.mid] } ?? []
        index = -1
        guard let next, cache[next.mid] == nil else {
            loading = false
            return
        }
        loading = true
        Task {
            let got = try? await hub.owner(of: next)?.lyrics(next)
            if let got { cache[next.mid] = got }
            guard song?.mid == next.mid else { return }
            lines = got ?? []
            loading = false
            follow()
        }
    }

    /// 定位到当前行，并在下一行开始的那一刻再来一次
    private func tick() {
        // 提前一点点换行，看起来才和声音同步
        let now = player.time + 0.25
        let at = Lyrics.index(in: lines, at: now)
        if at != index { index = at }
        guard player.playing, lines.indices.contains(at + 1) else { return }
        let wait = max(0.03, lines[at + 1].t - now)
        ticker = Task {
            try? await Task.sleep(for: .seconds(wait))
            if !Task.isCancelled { tick() }
        }
    }
}
