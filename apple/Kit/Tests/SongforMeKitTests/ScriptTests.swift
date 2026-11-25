import Foundation
import Network
import Testing
@testable import SongforMeKit

/// 只在本机听的小服务器：/moved 跳到别的主机，其余把请求原样说一遍
private final class Server: Sendable {
    let listener: NWListener
    init() async throws {
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: p)
        listener.newConnectionHandler = { c in
            c.start(queue: .global())
            Self.read(c, Data()) { text in
                let path = text.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let body = ScriptRunner.json(["path": path, "token": text.contains("X-Token: abc"), "end": text.hasSuffix("hello")])
                let head = path == "/moved" ? "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.2:9/secret\r\n" : "HTTP/1.1 200 OK\r\n"
                c.send(content: Data((head + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body).utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
        listener.start(queue: .global())
        while listener.port == nil || listener.port?.rawValue == 0 { try await Task.sleep(for: .milliseconds(10)) }
    }
    /// 读到 hello 结尾（请求里带的内容）或者对方不再发为止
    private static func read(_ c: NWConnection, _ old: Data, _ done: @escaping @Sendable (String) -> Void) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, finished, error in
            let all = old + (data ?? Data())
            let text = String(decoding: all, as: UTF8.self)
            if finished || error != nil || text.hasSuffix("hello") { done(text) } else { read(c, all, done) }
        }
    }
    var address: String { "http://127.0.0.1:\(listener.port!.rawValue)" }
}

private let base = "id: 'my', name: '我的音乐', hosts: ['example.com'],"

private func source(_ body: String, patience: Double = 10) async throws -> ScriptSource {
    try await ScriptSource(script: "source({ \(base) search() { return [] }, stream() { return null }, \(body) })", patience: patience)
}

@Suite("插件")
struct ScriptTests {
    @Test("写法不对的说明哪里不对", arguments: [
        ("", "没有调用 source"),
        ("source({", "脚本有错误"),
        ("throw new Error('坏了')", "坏了"),
        ("source({ id: 'my', name: 'x' })", "至少要有 search 和 stream"),
        ("source({ id: 'My-1', name: 'x', search() {}, stream() {} })", "小写字母"),
        ("source({ id: 'my', search() {}, stream() {} })", "缺少 id、name"),
        ("source({ id: 'my', name: 'x', hosts: ['*'], search() {}, stream() {} })", "不是域名"),
        ("source({ id: 'my', name: 'x', hosts: ['com'], search() {}, stream() {} })", "不是域名"),
    ])
    func broken(_ script: String, _ message: String) async {
        let error = await #expect(throws: (any Error).self) { try await ScriptSource(script: script) }
        #expect(error?.localizedDescription.contains(message) == true, "\(error?.localizedDescription ?? "")")
    }

    @Test("歌、歌手、专辑换成应用里的样子，编号加上前缀；脚本拿到的是自己的编号")
    func shapes() async throws {
        let s = try await ScriptSource(script: """
        source({ \(base)
          async search(q, kind, page) {
            if (kind === 'artist') return { artists: [{ id: 7, name: '甲', avatar: 'https://img.example.com/7.jpg', albumCount: 3 }], total: 1 };
            if (kind === 'album') return [{ id: 'al', name: '专辑', date: '2020-01-02', artists: ['甲'], cover: 'https://evil.test/x.jpg' }];
            return { songs: [{ id: 1, name: q + page, artists: [{ id: 7, name: '甲' }, '乙'], album: { id: 'al', name: '专辑' }, duration: 200, language: '粤语', extra: 'e', cover: 'https://example.com/c.jpg' },
                             { name: '没有编号' }], total: 40, hasMore: true };
          },
          stream(song) { return 'https://cdn.example.com/' + song.id + '/' + song.artists[0].id + '/' + song.album.id + '/' + song.extra; },
          lyrics() { return { lrc: '[00:01.00]hi', trans: '[00:01.00]你好' }; },
          playlistLink: 'example\\\\.com/list/(\\\\d+)',
          playlist(id, max) { return { title: '歌单' + id, songs: [{ id: 'a', name: 'A' }, { id: 'b', name: 'B' }] }; },
          related(song) { return { songs: [{ id: 'r', name: 'R' }], playlists: [{ id: 9, songCount: 20 }] }; },
        })
        """)
        let page = try await s.search("词", .song, page: 2)
        #expect(page.songs.count == 1 && page.total == 40 && page.hasMore)
        let song = try #require(page.songs.first)
        #expect(song.mid == "my:1" && song.name == "词2" && song.artistText == "甲 / 乙" && song.language == 1)
        #expect(song.singers.map(\.mid) == ["my:7", ""] && song.albumMid == "my:al" && song.cover == "https://example.com/c.jpg")
        #expect(try await s.stream(song)?.url == "https://cdn.example.com/1/7/al/e")
        #expect(try await s.lyrics(song) == [LyricLine(t: 1, text: "hi", trans: "你好")])
        let hit = try #require(try await s.search("x", .singer, page: 1).singers.first)
        #expect(hit.mid == "my:7" && hit.albumCount == 3 && s.avatar(of: "my:7", size: 100)?.host() == "img.example.com")
        let album = try #require(try await s.search("x", .album, page: 1).albums.first)
        #expect(album.mid == "my:al" && album.cover == nil, "没声明的主机上的图片不要")
        #expect(s.playlistID(in: "看看 https://example.com/list/88?x=1") == "my:88")
        #expect(s.playlistID(in: "https://other.com/list/88") == nil)
        let list = try await s.playlist("my:88", max: 1)
        #expect(list.title == "歌单88" && list.songs.map(\.mid) == ["my:a"])
        let related = try await s.related(to: song)
        #expect(related.similar.map(\.mid) == ["my:r"] && related.playlists.first?.id == "my:9")
    }

    @Test("没写的方法当作没有；报错带着原因，需要登录的认得出来")
    func missing() async throws {
        let s = try await source("related() { throw { message: '要登录', needsLogin: true }; }, artistAlbums() { throw new Error('服务器坏了'); }")
        #expect(try await s.lyrics(Song(mid: "my:1", name: "a", singers: [])).isEmpty)
        #expect(s.abilities.isEmpty && !s.hasAccount)
        let e = await #expect(throws: SourceError.self) { try await s.related(to: Song(mid: "my:1", name: "a", singers: [])) }
        #expect(e?.needsLogin == true && e?.message == "要登录")
        let f = await #expect(throws: SourceError.self) { try await s.artistAlbums("my:1") }
        #expect(f?.needsLogin == false && f?.message == "服务器坏了")
    }

    @Test("只能连声明过的主机")
    func hosts() async throws {
        var h = ScriptHosts(declared: ["example.com"])
        h.servers = ["http://192.168.1.2:4533"]
        for ok in ["https://example.com/a", "https://a.b.example.com/", "http://192.168.1.2:4533/x"] { #expect(h.allows(URL(string: ok)!), "\(ok)") }
        for no in ["http://example.com/", "https://badexample.com/", "https://example.com.evil.test/", "file:///etc/passwd", "http://192.168.1.2/", "https://192.168.1.2:4533/", "data:text/plain,x"] {
            #expect(!h.allows(URL(string: no)!), "\(no)")
        }
        let s = try await ScriptSource(script: """
        source({ \(base) async search(q) { await fetch(q); return []; }, stream(song) { return song.id === '1' ? 'file:///etc/passwd' : 'https://evil.test/a.mp3'; } })
        """)
        for url in ["https://evil.test/", "http://example.com/", "file:///etc/hosts"] {
            let e = await #expect(throws: SourceError.self) { try await s.search(url, .song, page: 1) }
            #expect(e?.message.contains("没有声明") == true)
        }
        for id in ["my:1", "my:2"] { await #expect(throws: SourceError.self) { try await s.stream(Song(mid: id, name: "a", singers: [])) } }
    }

    @Test("填了服务器之后能连它，跳转不能出去；清掉设置就不能再连")
    func server() async throws {
        let server = try await Server()
        defer { server.listener.cancel() }
        let s = try await ScriptSource(script: """
        source({ \(base)
          settings: [{ key: 'server', title: '服务器', kind: 'server' }, { key: 'user', title: '用户名' }, { key: 'password', title: '密码', kind: 'secret' }, { key: 'note', optional: true }],
          async search(q) {
            const r = await fetch(settings.server + q, { method: 'POST', headers: { 'X-Token': 'abc' }, body: 'hello' });
            if (!r.ok) throw new Error('状态 ' + r.status);
            const d = await r.json();
            return [{ id: 1, name: [d.path, d.token, d.end, settings.user, settings.password, Object.keys(settings).length].join(' ') }];
          },
          stream() { return settings.server + '/a.mp3'; },
          async profile() { await sleep(1); return { name: settings.user }; },
        })
        """)
        #expect(s.hasAccount && s.fields.map(\.key) == ["server", "user", "password", "note"])
        #expect(await !s.account().loggedIn)
        #expect(throws: SourceError.self) { try s.apply(["server": "http://"]) }
        try s.apply(["server": " \(server.address)/ ", "user": "我", "password": " p ", "other": "x"])
        #expect(await s.account() == SourceAccount(loggedIn: true, uid: "我"))
        #expect(try await s.search("/hi", .song, page: 1).songs.first?.name == "/hi true true 我  p  3")
        #expect(try await s.profile().nick == "我")
        #expect(try await s.stream(Song(mid: "my:1", name: "a", singers: []))?.url == server.address + "/a.mp3")
        let e = await #expect(throws: SourceError.self) { try await s.search("/moved", .song, page: 1) }
        #expect(e?.message == "状态 302")
        await s.logout()
        #expect(await !s.account().loggedIn)
        await #expect(throws: SourceError.self) { try await s.search("/hi", .song, page: 1) }
    }

    @Test("脚本里没有文件、进程这些东西，也碰不到内部接口")
    func sandbox() async throws {
        let s = try await ScriptSource(script: """
        source({ \(base) stream() {}, search() {
          const names = ['require', 'process', 'XMLHttpRequest', 'WebSocket', 'ObjC', '__fetch', '__done', '__fail', '__sleep', '__log'];
          return [{ id: 1, name: 'ok' + names.filter(n => typeof globalThis[n] !== 'undefined').join() + atob(btoa('中文')) }];
        } })
        """)
        #expect(try await s.search("", .song, page: 1).songs.first?.name == "ok中文")
    }

    @Test("卡住的脚本不会拖住应用")
    func stuck() async throws {
        let s = try await ScriptSource(script: "source({ \(base) search(q) { if (q === 'ok') return [{ id: 1, name: '好' }]; if (q === 'wait') return new Promise(() => {}); for (;;); }, stream() {} })", patience: 0.3)
        let e = await #expect(throws: SourceError.self) { try await s.search("wait", .song, page: 1) }
        #expect(e?.message == "音源太久没有回应")
        await #expect(throws: SourceError.self) { try await s.search("loop", .song, page: 1) }
        let f = await #expect(throws: SourceError.self) { try await s.search("ok", .song, page: 1) }
        #expect(f?.message.contains("没有响应") == true)
        // 死循环会被掐掉，之后照常能用
        try await Task.sleep(for: .seconds(6.5))
        #expect(try await s.search("ok", .song, page: 1).songs.map(\.name) == ["好"])
    }

    @Test("账号里的歌单、写回账号")
    func account() async throws {
        let s = try await source("""
          myPlaylists() { return [{ id: 1, title: '收藏', liked: true }, { id: 2, title: '跑步', songCount: 3 }]; },
          playlist(id) { return [{ id: 'in' + id, name: 'x' }]; },
          recentPlays() { return [{ song: { id: 5, name: 'y' }, time: 100, count: 2 }]; },
          setLiked(song, liked) { throw new Error(song.id + liked); }, addToPlaylist() {}, createPlaylist() {}, deletePlaylist() {},
        """)
        #expect(s.abilities == [.like, .playlists])
        let store = try Store()
        let library = Library(hub: SourceHub([s]), store: store)
        _ = try await library.sync(s) { _ in }
        #expect(try await store.playlistSongs("my:liked").map(\.mid) == ["my:in1"])
        #expect(try await store.playlistSongs("my:2").map(\.mid) == ["my:in2"])
        #expect(try await store.playlistSongs("my:recent").map(\.mid) == ["my:5"])
        let e = await #expect(throws: SourceError.self) { try await s.perform(.setLiked(Song(mid: "my:8", name: "z", singers: []), true)) }
        #expect(e?.message == "8true")
    }

    @Test("插件和设置存到文件夹里，再打开还在；移除后什么都不留")
    func shelf() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let shelf = ScriptShelf(folder: folder)
        #expect(await shelf.load().sources.isEmpty)
        let text = "source({ \(base) settings: [{ key: 'user', title: '用户名' }], search() { return [{ id: 1, name: settings.user }]; }, stream() {} })"
        let s = try await ScriptSource(script: text)
        try s.apply(["user": "我"])
        try shelf.add(s, script: text)
        try shelf.save(s)
        try Data("坏的".utf8).write(to: folder.appending(path: "zz.js"))
        let mode = try FileManager.default.attributesOfItem(atPath: folder.appending(path: "my.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let loaded = await shelf.load()
        #expect(loaded.sources.map(\.info.id) == ["my"] && loaded.failed.count == 1)
        #expect(try await loaded.sources[0].search("", .song, page: 1).songs.first?.name == "我")
        shelf.remove("my")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["zz.js"])
    }

    @Test("音源随时增减，拿着它的地方马上看到；移除的不再推荐")
    func hub() async throws {
        let a = try await source("version: '1'")
        let hub = SourceHub()
        let store = try Store()
        let library = Library(hub: hub, store: store)
        hub.add(a)
        hub.add(try await source("version: '2'"))
        #expect(library.hub.all.count == 1 && (hub.named("my") as? ScriptSource)?.version == "2")
        #expect(hub.owner(of: "my:1") != nil)
        let song = { (mid: String) in Song(mid: mid, name: mid, singers: []) }
        #expect(try await library.recoInput(RecoSettings(), now: 0).playable(song("my:1")))
        #expect(try await !library.recoInput(RecoSettings(), now: 0).playable(song("gone:1")))
        hub.remove("my")
        #expect(hub.all.isEmpty && library.hub.owner(of: "my:1") == nil)
    }
}
