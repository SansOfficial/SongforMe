import Foundation
import Observation
import SongforMeKit

/// 睡眠定时：到点暂停，或者放完这首就停
@MainActor
@Observable
final class SleepTimer {
    static let shared = SleepTimer()
    static let choices = [15, 30, 45, 60, 90]

    /// 到这个时间暂停；没定时为 nil
    private(set) var end: Date?
    /// 选的是几分钟，菜单里打勾用
    private(set) var minutes: Int?
    @ObservationIgnored private var task: Task<Void, Never>?

    private var player: Player { AppModel.shared.player }

    /// 放完这首就停（记在播放器上，换歌时它自己判断）
    var afterSong: Bool { player.stopAfterCurrent }
    var active: Bool { end != nil || afterSong }

    func set(minutes m: Int) {
        clear()
        minutes = m
        let until = Date.now.addingTimeInterval(Double(m) * 60)
        end = until
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(until.timeIntervalSinceNow))
            guard !Task.isCancelled else { return }
            self?.fire()
        }
        AppModel.shared.say("\(m) 分钟后暂停")
    }

    func stopAfterSong() {
        clear()
        player.stopAfterCurrent = true
        AppModel.shared.say(player.current == nil ? "下一首放完后停" : "放完这首后停")
    }

    func cancel() {
        let was = active
        clear()
        if was { AppModel.shared.say("已关闭睡眠定时") }
    }

    private func clear() {
        task?.cancel()
        task = nil
        end = nil
        minutes = nil
        player.stopAfterCurrent = false
    }

    private func fire() {
        task = nil
        end = nil
        minutes = nil
        if player.playing { player.toggle() }
        AppModel.shared.say("睡眠定时到了，已暂停")
    }

    /// 放完一首停下时播放器会通知这里
    func stoppedAfterSong() { AppModel.shared.say("这首放完了，已按睡眠定时停下") }

    /// 还剩多久，比如 “29:41”；放完这首停时是 “放完这首”
    func remaining(at now: Date) -> String? {
        if afterSong { return "放完这首" }
        guard let end else { return nil }
        let s = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
