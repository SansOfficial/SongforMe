import AVFoundation
import SongforMeKit

/// 用系统播放器出声
final class AudioEngine: AudioOutput {
    var onEvent: ((AudioEvent) -> Void)?

    private let player = AVPlayer()
    private var pendingSeek = 0.0
    private var watchers: [NSKeyValueObservation] = []
    private var itemWatcher: NSKeyValueObservation?
    private var tokens: [NSObjectProtocol] = []
    private var failedItem: AVPlayerItem?

    init() {
        // 系统的通知可能来自别的线程，也可能在换了一首之后才到：都到主线程上再看一次当前状态
        watchers.append(player.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor in self?.statusChanged() }
        })
        player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.player.timeControlStatus == .playing, t.isNumeric else { return }
                self.onEvent?(.time(t.seconds))
            }
        }
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, item === self.player.currentItem else { return }
                self.onEvent?(.ended)
            }
        })
        tokens.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated { self?.failed(item) }
        })
    }

    private func statusChanged() {
        switch player.timeControlStatus {
        case .playing: onEvent?(.playing)
        case .waitingToPlayAtSpecifiedRate: if player.currentItem != nil { onEvent?(.waiting) }
        default: onEvent?(.paused)
        }
    }

    private func failed(_ item: AVPlayerItem?) {
        guard let item, item === player.currentItem, item !== failedItem else { return }
        failedItem = item
        onEvent?(.failed(item.error?.localizedDescription ?? ""))
    }

    private func itemChanged() {
        guard let item = player.currentItem else { return }
        if item.status == .failed { failed(item) }
        if item.status == .readyToPlay, pendingSeek > 0 {
            seek(pendingSeek)
            pendingSeek = 0
        }
    }

    var currentTime: Double {
        if pendingSeek > 0 { return pendingSeek }
        let t = player.currentTime()
        return t.isNumeric ? t.seconds : 0
    }

    var duration: Double {
        guard let d = player.currentItem?.duration, d.isNumeric else { return 0 }
        return d.seconds
    }

    var isPaused: Bool { player.timeControlStatus == .paused }

    var volume: Double {
        get { Double(player.volume) }
        set { player.volume = Float(newValue) }
    }

    var muted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    func load(_ url: String, at position: Double) {
        guard let url = URL(string: url) else { return }
        pendingSeek = position
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        itemWatcher = item.observe(\.status) { [weak self] _, _ in
            Task { @MainActor in self?.itemChanged() }
        }
        player.replaceCurrentItem(with: item)
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(_ position: Double) {
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
