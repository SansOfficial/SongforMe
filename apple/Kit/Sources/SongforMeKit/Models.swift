import Foundation

public struct Singer: Codable, Hashable, Sendable {
    public var mid: String
    public var name: String
    /// 同一位歌手在不同音源里编号不同，名字相同就当作同一个人
    var key: String { name.isEmpty ? mid : name.lowercased() }
    public init(mid: String, name: String) {
        self.mid = mid
        self.name = name
    }
}

/// 本地保存的歌曲元数据
public struct Song: Codable, Hashable, Sendable, Identifiable {
    /// 全局唯一的编号，开头是音源的短名字（见 SourceInfo）
    public var mid: String
    /// 音源自己的数字编号，没有就是 0
    public var songID: Int
    public var name: String
    public var singers: [Singer]
    public var albumMid: String
    public var albumName: String
    /// 秒
    public var duration: Double
    /// 语种编号，见 Languages
    public var language: Int
    public var genre: Int
    /// 发行日期 YYYY-MM-DD，可能为空
    public var publishTime: String
    /// 1 表示需要会员才能完整播放
    public var payPlay: Int
    /// 音源取播放地址时用的编号，没有就留空
    public var mediaMid: String
    /// 封面地址；音源能从 albumMid 推出来时可以不存
    public var cover: String?

    public var id: String { mid }
    public var artistText: String { singers.map(\.name).joined(separator: " / ") }

    enum CodingKeys: String, CodingKey {
        case mid, name, singers, albumMid, albumName, duration, language, genre, publishTime, payPlay, mediaMid, cover
        case songID = "id"
    }

    public init(
        mid: String, songID: Int = 0, name: String, singers: [Singer], albumMid: String = "", albumName: String = "",
        duration: Double = 0, language: Int = 0, genre: Int = 0, publishTime: String = "", payPlay: Int = 0, mediaMid: String = "", cover: String? = nil
    ) {
        self.mid = mid
        self.songID = songID
        self.name = name
        self.singers = singers
        self.albumMid = albumMid
        self.albumName = albumName
        self.duration = duration
        self.language = language
        self.genre = genre
        self.publishTime = publishTime
        self.payPlay = payPlay
        self.mediaMid = mediaMid
        self.cover = cover
    }
}

/// imported：手动导入、当作口味种子的公开歌单（只存在本地）
public enum PlaylistKind: String, Codable, Sendable {
    case liked, own, collected, imported, recent
}

public struct Playlist: Codable, Hashable, Sendable, Identifiable {
    /// 歌单的编号，开头是音源的短名字（见 SourceInfo）
    public var id: String
    public var title: String
    public var kind: PlaylistKind
    public var songCount: Int
    public var cover: String?
    /// 自建歌单在账号里的目录号，写回歌单时要用
    public var dirId: Int?
    public var syncedAt: Double

    public init(id: String, title: String, kind: PlaylistKind, songCount: Int, cover: String? = nil, dirId: Int? = nil, syncedAt: Double = 0) {
        self.id = id
        self.title = title
        self.kind = kind
        self.songCount = songCount
        self.cover = cover
        self.dirId = dirId
        self.syncedAt = syncedAt
    }

    public static let likedID = "liked"
    public static let recentID = "recent"

    /// 是不是某个音源的“我喜欢”
    public static func isLiked(_ id: String) -> Bool { id == likedID || id.hasSuffix(":\(likedID)") }
    /// 一首歌所在的音源的“我喜欢”
    public static func liked(for mid: String) -> String {
        guard let colon = mid.firstIndex(of: ":") else { return likedID }
        return String(mid[...colon]) + likedID
    }
}

public enum EventType: String, Codable, Sendable {
    case play, complete, skip, like, unlike, dislike, tired
}

/// 这首歌是从哪来的
public enum PlaySource: String, Codable, Sendable {
    case reco, library, search
}

/// 播放器记录的行为，是推荐算法最重要的输入
public struct PlayEvent: Codable, Hashable, Sendable {
    public var mid: String
    public var type: EventType
    /// 事件发生时已播放的比例 0~1（skip / complete 时有意义）
    public var ratio: Double
    public var source: PlaySource
    /// 毫秒时间戳
    public var ts: Double

    public init(mid: String, type: EventType, ratio: Double, source: PlaySource, ts: Double) {
        self.mid = mid
        self.type = type
        self.ratio = ratio
        self.source = source
        self.ts = ts
    }
}

/// 候选歌曲是怎么被找到的：每条记录是一条“证据”
public struct Evidence: Codable, Hashable, Sendable {
    public enum Via: String, Codable, Sendable {
        /// 某首种子歌的相似歌曲 / 和种子歌出现在同一个公开歌单 / 相似歌手的歌
        case similar, playlist, singer
    }

    /// `mid|via|ref|seed`
    public var key: String
    public var mid: String
    public var via: Via
    /// 种子歌 mid / 歌单 id / 歌手 mid
    public var ref: String
    /// 这条证据关联的种子歌 mid（用来把种子歌的喜爱程度传给候选）
    public var seed: String
    public var ts: Double

    public init(mid: String, via: Via, ref: String, seed: String, ts: Double) {
        self.key = "\(mid)|\(via.rawValue)|\(ref)|\(seed)"
        self.mid = mid
        self.via = via
        self.ref = ref
        self.seed = seed
        self.ts = ts
    }
}

/// 听了一次歌：听歌报告用它统计。推荐算法不看这个，只看 PlayEvent
public struct Listen: Codable, Hashable, Sendable {
    public var mid: String
    /// 开始听的时间，毫秒
    public var ts: Double
    /// 真正出声听了多少秒：暂停、拖过去的部分不算
    public var seconds: Double
    public var source: PlaySource

    public init(mid: String, ts: Double, seconds: Double, source: PlaySource) {
        self.mid = mid
        self.ts = ts
        self.seconds = seconds
        self.source = source
    }
}

public enum Languages {
    public static let all: [(code: Int, name: String)] = [
        (0, "国语"), (1, "粤语"), (2, "闽南语"), (3, "日语"), (4, "韩语"),
        (5, "英语"), (6, "法语"), (7, "其他"), (8, "德语"), (9, "纯音乐"),
    ]
}

public typealias RandomSource = () -> Double

/// 现在的毫秒时间戳
public func nowMillis() -> Double { Date().timeIntervalSince1970 * 1000 }

extension Double {
    /// 和 JavaScript 的 Math.round 一致（.5 向上取整）
    var jsRounded: Int { Int((self + 0.5).rounded(.down)) }
}
