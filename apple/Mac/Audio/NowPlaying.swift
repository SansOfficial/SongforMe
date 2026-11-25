import AppKit
import MediaPlayer
import SongforMeKit

/// 系统的“正在播放”：键盘媒体键、控制中心、AirPods 的控制
final class NowPlaying {
    private let player: Player
    private var artwork: (mid: String, image: NSImage)?
    private var fetching: Task<Void, Never>?

    init(player: Player) {
        self.player = player
        let c = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (Player) -> Void) {
            command.addTarget { [weak player] _ in
                guard let player else { return .commandFailed }
                Task { @MainActor in action(player) }
                return .success
            }
        }
        on(c.playCommand) { if !$0.playing { $0.toggle() } }
        on(c.pauseCommand) { if $0.playing { $0.toggle() } }
        on(c.togglePlayPauseCommand) { $0.toggle() }
        on(c.nextTrackCommand) { $0.next() }
        on(c.previousTrackCommand) { $0.previous() }
        c.changePlaybackPositionCommand.addTarget { [weak player] event in
            guard let player, let at = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor in player.seek(at) }
            return .success
        }
    }

    func update() {
        let center = MPNowPlayingInfoCenter.default()
        guard let song = player.current?.song else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.name,
            MPMediaItemPropertyArtist: song.artistText,
            MPMediaItemPropertyAlbumTitle: song.albumName,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.time,
            MPNowPlayingInfoPropertyPlaybackRate: player.playing ? 1.0 : 0.0,
        ]
        if let artwork, artwork.mid == song.mid { info[MPMediaItemPropertyArtwork] = Self.wrap(artwork.image) }
        center.nowPlayingInfo = info
        center.playbackState = player.playing ? .playing : .paused
        if artwork?.mid != song.mid { fetchArtwork(song) }
    }

    private func fetchArtwork(_ song: Song) {
        fetching?.cancel()
        fetching = Task {
            guard let image = await ImageLoader.shared.image(song.artwork(500), pixels: 500), !Task.isCancelled else { return }
            artwork = (song.mid, image)
            update()
        }
    }

    /// 系统会在别的线程上来要图
    private nonisolated static func wrap(_ image: NSImage) -> MPMediaItemArtwork {
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
