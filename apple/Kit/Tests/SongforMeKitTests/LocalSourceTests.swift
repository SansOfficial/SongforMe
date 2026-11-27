import AVFoundation
import Foundation
import Testing
@testable import SongforMeKit

@Suite("本地音乐")
struct LocalSourceTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "songforme-local-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// 写一段半秒的静音 wav（不带标签）
    func tone(_ relative: String) throws -> URL {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4000)!
        buffer.frameLength = 4000
        try file.write(from: buffer)
        return url
    }

    @Test("从文件名猜歌名和歌手")
    func guess() {
        #expect(LocalSource.guess("03 - 歌手甲 - 第一首").title == "第一首")
        #expect(LocalSource.guess("03 - 歌手甲 - 第一首").artist == "歌手甲")
        #expect(LocalSource.guess("07. 只有歌名") == ("只有歌名", ""))
        #expect(LocalSource.guess("歌手乙 - 歌名 - Live") == ("歌名 - Live", "歌手乙"))
        #expect(LocalSource.splitArtists("甲 / 乙、丙") == ["甲", "乙", "丙"])
    }

    @Test("扫描文件夹：每个文件夹一个歌单，能搜、能放、能读同名歌词，移除后歌也没了")
    func scan() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try tone("一/歌手甲 - 第一首.wav")
        _ = try tone("一/子目录/歌手乙 - 第二首.wav")
        _ = try tone("二/第三首.wav")
        try "x".write(to: root.appending(path: "一/说明.txt"), atomically: true, encoding: .utf8)
        try "[00:01.00]第一行\n[00:02.50]第二行".write(to: a.deletingPathExtension().appendingPathExtension("lrc"), atomically: true, encoding: .utf8)

        let store = try Store()
        let local = LocalSource(covers: root.appending(path: "covers"))
        await local.prepare(store)
        await local.add(root.appending(path: "一"))
        await local.add(root.appending(path: "一/子目录")) // 已经在里面了，不重复加
        await local.add(root.appending(path: "二"))
        #expect(local.folders.count == 2)
        #expect(local.folders.allSatisfy { !$0.hasSuffix("/") })

        let lists = try await local.myPlaylists()
        #expect(lists.map(\.title) == ["一", "二"])
        #expect(lists.map(\.songCount) == [2, 1])
        #expect(lists.allSatisfy { $0.kind == .own && $0.id.hasPrefix("local:") })

        let first = try await local.playlist(lists[0].id, max: 10).songs
        #expect(Set(first.map(\.name)) == ["第一首", "第二首"])
        let song = try #require(first.first { $0.name == "第一首" })
        #expect(song.singers.map(\.name) == ["歌手甲"])
        #expect(abs(song.duration - 0.5) < 0.05)

        #expect(try await local.search("歌手乙", .song, page: 1).songs.map(\.name) == ["第二首"])
        #expect(try await local.search("歌手", .singer, page: 1).singers.count == 2)
        #expect(try await local.artistSongs(song.singers[0].mid, begin: 0, count: 10).songs == [song])

        let url = try #require(try await local.stream(song)?.url)
        #expect(URL(string: url)?.isFileURL == true)
        #expect(try await local.lyrics(song).map(\.text) == ["第一行", "第二行"])

        // 重新打开：不用扫描就有上次的歌
        let again = LocalSource(covers: root.appending(path: "covers"))
        await again.prepare(store)
        #expect(again.songs.count == 3)

        await local.remove(local.folders[0])
        #expect(local.songs.map(\.name) == ["第三首"])
        try FileManager.default.removeItem(at: root.appending(path: "二/第三首.wav"))
        #expect(await local.scan() == 0)
        // 文件不在了，放的时候说清楚
        try FileManager.default.removeItem(at: a)
        await #expect(throws: SourceError.self) { try await local.stream(song) }
    }
}
