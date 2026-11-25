import Foundation

/// 从改成原生之前的版本搬家：读它导出的 JSON，写进本地数据库
public enum OldLibrary {
    struct Dump: Decodable {
        struct Membership: Decodable {
            var playlistId: String
            var mid: String
            var pos: Double
        }
        struct Event: Decodable {
            var mid: String
            var type: EventType
            var ratio: Double?
            var source: PlaySource
            var ts: Double
        }
        struct Proof: Decodable {
            var mid: String
            var via: Evidence.Via
            var ref: String
            var seed: String
            var ts: Double
        }
        var songs: [Song]
        var playlists: [Playlist]
        var memberships: [Membership]
        var events: [Event]
        var evidence: [Proof]
    }

    public static func load(_ data: Data, into store: Store) async throws {
        let dump = try JSONDecoder().decode(Dump.self, from: data)
        try await store.putSongs(dump.songs)
        let songs = Dictionary(dump.songs.map { ($0.mid, $0) }, uniquingKeysWith: { $1 })
        let members = Dictionary(grouping: dump.memberships, by: \.playlistId)
        for p in dump.playlists {
            let list = (members[p.id] ?? []).sorted { $0.pos < $1.pos }.compactMap { songs[$0.mid] }
            if list.isEmpty { try await store.putPlaylist(p) } else { try await store.replacePlaylist(p, songs: list) }
        }
        try await store.addEvents(dump.events.map { PlayEvent(mid: $0.mid, type: $0.type, ratio: $0.ratio ?? 0, source: $0.source, ts: $0.ts) })
        try await store.putEvidence(dump.evidence.map { Evidence(mid: $0.mid, via: $0.via, ref: $0.ref, seed: $0.seed, ts: $0.ts) })
        // 设置原样搬过去，两边用的是同样的键和结构
        let whole = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        for row in whole?["kv"] as? [[String: Any]] ?? [] {
            guard let key = row["key"] as? String, let value = row["value"], key != "showScores" else { continue }
            let json = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            try await store.setRaw(key, json: String(decoding: json, as: UTF8.self))
        }
    }
}
