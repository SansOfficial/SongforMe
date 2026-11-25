import Foundation
import Synchronization
import Testing
@testable import SongforMeKit

private final class Jar: ScriptJar {
    let all = Mutex<[HTTPCookie]>([])
    func put(_ name: String, _ value: String, _ domain: String, path: String = "/", expires: Date? = nil) {
        var p: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if let expires { p[.expires] = expires }
        let c = HTTPCookie(properties: p)!
        all.withLock { $0.append(c) }
    }
    func cookies() async -> [HTTPCookie] { all.withLock { $0 } }
    @MainActor func login(until done: @MainActor () async -> Bool) async { put("key", "se~cret", ".site.com") }
    @MainActor func logout() async { all.withLock { $0 = [] } }
}

private func manifest(_ url: String = "https://www.site.com/in", hosts: [String]? = ["api.site.com"], cookies: [String] = ["key"], uid: [String]? = ["uin", "wx"]) throws -> ScriptLogin {
    try ScriptLogin(.init(url: url, hosts: hosts, cookies: cookies, uid: uid))
}

@Suite("插件的网页登录")
struct ScriptLoginTests {
    @Test("登录网页要 https；登录状态只能发给同一个网站")
    func rules() throws {
        #expect(throws: SourceError.self) { try manifest("http://www.site.com/") }
        #expect(throws: SourceError.self) { try manifest("https://u:p@www.site.com/") }
        #expect(throws: SourceError.self) { try manifest("https://www.site.com:8443/") }
        #expect(throws: SourceError.self) { try manifest(hosts: ["evil.com"]) }
        #expect(throws: SourceError.self) { try manifest(hosts: ["notsite.com"]) }
        #expect(throws: SourceError.self) { try manifest(cookies: []) }
        #expect(try manifest(hosts: nil).hosts == ["www.site.com"])
        let m = try manifest()
        #expect(m.covers(URL(string: "https://api.site.com/a")!))
        for other in ["http://api.site.com/a", "https://api.site.com:444/a", "https://x.api.site.com/a", "https://www.site.com/", "https://api.site.com.evil.com/"] {
            #expect(!m.covers(URL(string: other)!), "\(other)")
        }
    }

    @Test("cookie 按浏览器的规则挑：域名、路径、有没有过期")
    func matching() {
        let jar = Jar()
        jar.put("a", "1", ".site.com")
        jar.put("b", "2", "api.site.com")
        jar.put("c", "3", "www.site.com")
        jar.put("d", "4", ".site.com", path: "/only")
        jar.put("e", "5", ".site.com", expires: Date(timeIntervalSinceNow: -10))
        jar.put("f", "6", ".te.com")
        let names = { (u: String) in ScriptLogin.matching(jar.all.withLock { $0 }, URL(string: u)!).map(\.name).sorted() }
        #expect(names("https://api.site.com/x") == ["a", "b"])
        #expect(names("https://api.site.com/only/x") == ["a", "b", "d"])
        #expect(names("https://api.site.com/onlyx") == ["a", "b"])
        #expect(names("https://evil.com/") == [])
    }

    @Test("登录前后：认得出登录了没有、是哪个账号；退出后什么都不留")
    func account() async throws {
        let s = try await ScriptSource(script: "source({ id: 'my', name: 'x', login: { url: 'https://www.site.com/', hosts: ['api.site.com'], cookies: ['key'], uid: ['uin'] }, search() { return [] }, stream() { return null }, profile() { return { name: String(login.signedIn) } } })")
        let jar = Jar()
        s.use(jar)
        #expect(s.hasAccount && s.fields.isEmpty)
        #expect(await s.account() == SourceAccount())
        #expect(try await s.profile().nick == "false")
        jar.put("uin", "o0123456", ".site.com")
        #expect(await s.account().loggedIn == false, "只有编号不算登录")
        await s.login()
        #expect(await s.account() == SourceAccount(loggedIn: true, uid: "123456"))
        #expect(try await s.profile().nick == "true")
        await s.logout()
        #expect(await s.account() == SourceAccount() && jar.all.withLock { $0.isEmpty })
        #expect(try await s.profile().nick == "false")
    }

    @Test("脚本只有占位符，看不到 cookie；发往登录的网站时才换成真的")
    func sign() async throws {
        let runner = ScriptRunner()
        _ = try await runner.load("""
        source({ id: 'my', name: 'x',
          t() { return { body: JSON.stringify({ uin: login.number('none', 'uin'), text: login.digits('uin'), tk: login.hash('key'), long: login.number('wx'), none: login.number('none'), q: 'a"b' }),
                         url: 'https://api.site.com/p?k=' + encodeURIComponent(login.cookie('key')), header: login.cookie('csrf') } },
        })
        """, within: 5)
        let jar = Jar()
        let site = try manifest()
        runner.use(jar, for: site)
        jar.put("uin", "o0123456", ".site.com")
        jar.put("wx", "1152921504606846976", ".site.com")
        jar.put("key", "a&b=c", ".site.com")
        jar.put("csrf", "tok", "www.site.com")
        jar.put("other", "x", ".other.com")
        let text = try await runner.call("t", "[]")
        for secret in ["123456", "a&b", "tok\"", "115292"] { #expect(!text.contains(secret)) }
        let d = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        let url = try #require(URL(string: d["url"]!))
        var r = URLRequest(url: url)
        r.httpBody = Data(d["body"]!.utf8)
        r.setValue(d["header"], forHTTPHeaderField: "X-Csrf")
        r.setValue("fake=1", forHTTPHeaderField: "Cookie")
        try await runner.sign(&r, url, site, jar)
        #expect(r.url?.absoluteString == "https://api.site.com/p?k=a%26b%3Dc")
        #expect(r.value(forHTTPHeaderField: "X-Csrf") == "tok")
        let cookie = r.value(forHTTPHeaderField: "Cookie") ?? ""
        #expect(cookie.contains("uin=o0123456") && cookie.contains("key=a&b=c") && !cookie.contains("csrf") && !cookie.contains("other") && !cookie.contains("fake"))
        let body = try #require(try JSONSerialization.jsonObject(with: r.httpBody!) as? [String: Any])
        #expect(body["uin"] as? Int == 123456 && body["text"] as? String == "123456" && body["tk"] as? Int == ScriptLogin.hash("a&b=c"))
        #expect(body["long"] as? String == "1152921504606846976" && body["none"] as? Int == 0 && body["q"] as? String == "a\"b")
    }

    @Test("没登录时占位符是空的；表单里的值会转义；怪字符不放进请求")
    func fill() {
        let f = { (t: String, v: [String: String], form: Bool) in ScriptLogin.fill(t, mark: "m", values: v, encode: form) }
        #expect(f("{\"a\":\"~m~hash~k~~\",\"b\":\"~m~cookie~k~~\",\"c\":\"~m~digits~k~~\"}", [:], false) == "{\"a\":5381,\"b\":\"\",\"c\":\"\"}")
        #expect(f("a=~m~cookie~k~~&b=1", ["k": "x&y"], true) == "a=x%26y&b=1")
        #expect(f("{\"a\":\"~m~cookie~k~~\"}", ["k": "x\",\"b\":\"y"], false) == "{\"a\":\"\"}")
        #expect(f("~other~cookie~k~~", ["k": "x"], false) == "~other~cookie~k~~")
    }

    @Test("插件链接", arguments: [
        ("https://github.com/a/b/blob/main/x.js", "https://raw.githubusercontent.com/a/b/main/x.js"),
        ("github.com/a/b/raw/main/d/x.js", "https://raw.githubusercontent.com/a/b/main/d/x.js"),
        (" https://example.com/x.js ", "https://example.com/x.js"),
        ("http://example.com/x.js", ""), ("file:///etc/hosts", ""), ("javascript:alert(1)", ""), ("https://localhost/x.js", ""), ("https://a:b@example.com/x.js", ""), ("随便写的", ""),
    ])
    func link(_ text: String, _ expected: String) {
        #expect(ScriptDownload.address(of: text)?.absoluteString ?? "" == expected)
    }

    @Test("下载到网页、太大的、不是文字的都不当插件")
    func content() {
        #expect(throws: SourceError.self) { try ScriptDownload.check(Data("  <!doctype html>".utf8)) }
        #expect(throws: SourceError.self) { try ScriptDownload.check(Data([0xff, 0xfe, 0x00])) }
        #expect(throws: SourceError.self) { try ScriptDownload.check(Data(count: ScriptDownload.maxSize + 1)) }
        #expect((try? ScriptDownload.check(Data("source({})".utf8))) == "source({})")
    }
}
