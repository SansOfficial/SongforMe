import Foundation
import Testing
@testable import SongforMeKit

@Suite("本地数据库")
struct StoreTests {
    @Test("歌单整体替换、加歌、删歌、算作喜欢的歌")
    func playlists() async throws {
        let store = try Store()
        let a = song("a", "x", name: "带\"引号\"和'单引号'"), b = song("b", "y"), c = song("c", "z")
        try await store.replacePlaylist(Playlist(id: Playlist.likedID, title: "我喜欢", kind: .liked, songCount: 0, dirId: 201), songs: [b, a])
        #expect(try await store.playlistSongs(Playlist.likedID) == [b, a])
        try await store.addMember(c, to: Playlist.likedID)
        #expect(try await store.members(of: Playlist.likedID) == ["c", "b", "a"])
        #expect(try await store.playlists().first?.songCount == 3)
        try await store.removeMember("b", from: Playlist.likedID)
        try await store.replacePlaylist(Playlist(id: "9", title: "收藏", kind: .collected, songCount: 0), songs: [b])
        #expect(try await store.likedMids() == ["c", "a"])
        #expect(try await store.contains("a", in: Playlist.likedID))
        try await store.removePlaylist("9")
        #expect(try await store.playlists().map(\.id) == [Playlist.likedID])
        #expect(try await store.song("b") == b)
    }

    @Test("行为、证据和设置存得进、读得出")
    func rows() async throws {
        let store = try Store()
        try await store.addEvents([event("a", .skip, 0.2), event("b", .like)])
        #expect(try await store.events() == [event("a", .skip, 0.2), event("b", .like)])
        try await store.putEvidence([ev("a", "s"), ev("a", "s"), ev("b", "s", .playlist, "1")])
        #expect(try await store.count(.evidence) == 2)
        try await store.set("expandedAt", ["a": 1.5])
        #expect(try await store.get("expandedAt", as: [String: Double].self) == ["a": 1.5])
        #expect(try await store.get("none", as: String.self) == nil)
        // 已经在库里的歌不被覆盖
        try await store.putSongs([song("a", "x", name: "旧")])
        try await store.putSongs([song("a", "x", name: "新")], keepExisting: true)
        #expect(try await store.song("a")?.name == "旧")
    }

    @Test("从旧版导出的数据搬家")
    func migrate() async throws {
        let dump = #"""
        {"songs":[{"mid":"a","id":7,"name":"歌","singers":[{"mid":"s","name":"手"}],"albumMid":"","albumName":"","duration":200,"language":0,"genre":1,"publishTime":"2015-01-01","payPlay":0,"mediaMid":"a"}],
         "playlists":[{"id":"liked","title":"我喜欢","kind":"liked","songCount":1,"dirId":201,"syncedAt":1},{"id":"8","title":"空","kind":"collected","songCount":30,"syncedAt":0}],
         "memberships":[{"playlistId":"liked","mid":"a","pos":0}],
         "events":[{"id":1,"mid":"a","type":"play","ratio":0,"source":"reco","ts":5}],
         "evidence":[{"key":"k","mid":"a","via":"similar","ref":"r","seed":"r","ts":5}],
         "kv":[{"key":"settings","value":{"batchSize":40,"languages":null}},{"key":"guid","value":"abc"}]}
        """#
        let store = try Store()
        try await OldLibrary.load(Data(dump.utf8), into: store)
        #expect(try await store.playlistSongs("liked").first?.songID == 7)
        #expect(try await store.playlists().map(\.songCount) == [1, 30])
        #expect(try await store.events().count == 1)
        #expect(try await store.get("guid", as: String.self) == "abc")
        let settings = try await store.get("settings", as: RecoSettings.self)
        #expect(settings?.batchSize == 40 && settings?.exploration == 0.5 && settings?.languages == nil)
    }
}
