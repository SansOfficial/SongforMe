import Foundation

/// 插件里声明的网页登录：应用打开官方网页，用户自己登录。
/// 登录状态（cookie）留在应用这一侧，请求发往 hosts 时由应用带上，脚本拿不到。
public struct ScriptLogin: Hashable, Sendable {
    /// 登录网页
    public var url: URL
    /// 登录状态只发给这些域名，都要和登录网页是同一个网站
    public var hosts: [String]
    /// 有其中任何一个 cookie 就算登录了
    var cookies: [String]
    /// 账号编号在哪个 cookie 里，用来区分账号
    var uid: [String]

    struct Manifest: Decodable {
        var url: String
        var hosts: [String]?
        var cookies: [String]
        var uid: [String]?
    }

    init(_ m: Manifest) throws {
        guard let url = URL(string: m.url), url.scheme?.lowercased() == "https", url.port == nil, url.user() == nil, let home = url.host()?.lowercased(), ScriptHosts.valid(home) else {
            throw SourceError("login 里的 url 要写 https 开头的网址")
        }
        self.url = url
        hosts = (m.hosts ?? [home]).map { $0.lowercased() }
        if let bad = hosts.first(where: { !ScriptHosts.valid($0) || Self.site($0) != Self.site(home) }) { throw SourceError("login 里的“\(bad)”和登录网页不是同一个网站") }
        guard !m.cookies.isEmpty else { throw SourceError("login 里要写 cookies，用来判断有没有登录") }
        cookies = m.cookies
        uid = m.uid ?? []
    }

    private static func site(_ host: String) -> [Substring] { host.split(separator: ".").suffix(2) }

    /// 能不能把登录状态发到这个地址
    func covers(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && (url.port ?? 443) == 443 && url.host().map { hosts.contains($0.lowercased()) } == true
    }

    /// 浏览器访问这个地址时会带上的 cookie
    static func matching(_ all: [HTTPCookie], _ url: URL) -> [HTTPCookie] {
        guard let host = url.host()?.lowercased() else { return [] }
        let path = url.path().isEmpty ? "/" : url.path()
        return all.filter { c in
            let domain = c.domain.lowercased()
            let here = domain.hasPrefix(".") ? host == domain.dropFirst() || host.hasSuffix(domain) : host == domain
            let under = path == c.path || path.hasPrefix(c.path.hasSuffix("/") ? c.path : c.path + "/")
            return here && under && (c.expiresDate.map { $0 > Date() } ?? true)
        }
    }

    /// 登录网页和 hosts 上的 cookie，同名的以前面的域名为准
    func values(_ all: [HTTPCookie]) -> [String: String] {
        var out: [String: String] = [:]
        for host in [url.host() ?? ""] + hosts {
            guard let page = URL(string: "https://\(host)/") else { continue }
            for c in Self.matching(all, page) where !c.value.isEmpty && out[c.name] == nil { out[c.name] = c.value }
        }
        return out
    }

    func signedIn(_ values: [String: String]) -> Bool { cookies.contains { values[$0] != nil } }
    func account(_ values: [String: String]) -> String { Self.digits(uid.lazy.compactMap { values[$0] }.first ?? "") }

    // MARK: 占位符

    // 有的接口要把账号编号、防伪值写进请求里。脚本里写的是占位符，发往 hosts 时才换成真的：
    // cookie 原样；digits 只要数字；number 同 digits，在 JSON 里写成数字；hash 是网站常用的 5381 哈希防伪值，在 JSON 里写成数字

    static func fill(_ text: String, mark: String, values: [String: String], encode: Bool) -> String {
        guard text.contains(mark), let re = try? Regex("(\"?)~\(mark)~(cookie|digits|number|hash)((?:~[A-Za-z0-9_.-]+)+)~~(\"?)", as: (Substring, Substring, Substring, Substring, Substring).self) else { return text }
        return text.replacing(re) { m in
            let raw = m.output.3.split(separator: "~").lazy.compactMap { values[String($0)] }.first ?? ""
            var value: String
            var bare = false
            switch m.output.2 {
            case "digits": value = digits(raw)
            case "number":
                value = digits(raw)
                bare = value.count <= 15
                if value.isEmpty { value = "0" }
            case "hash":
                value = String(hash(raw))
                bare = true
            default: value = raw
            }
            // 正常的 cookie 里没有这些字符，有的话不放进请求，免得改了请求的意思
            if value.contains(where: { $0 == "\"" || $0 == "\\" || !$0.isASCII || $0.asciiValue.map { $0 < 32 } == true }) { value = "" }
            if encode { value = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.intersection(.urlQueryAllowed)) ?? "" }
            let quoted = !m.output.1.isEmpty && !m.output.4.isEmpty
            return quoted && bare ? value : "\(m.output.1)\(value)\(m.output.4)"
        }
    }

    private static func digits(_ text: String) -> String { String(text.drop { !("1"..."9").contains($0) }.prefix { ("0"..."9").contains($0) }) }

    static func hash(_ text: String) -> Int {
        var h: Int32 = 5381
        for unit in text.utf16 { h = h &+ (h << 5) &+ Int32(unit) }
        return Int(h & 0x7fff_ffff)
    }
}

/// 存登录状态的地方，由应用提供
public protocol ScriptJar: Sendable {
    func cookies() async -> [HTTPCookie]
    /// 打开登录网页，等到登录成功或者用户把窗口关掉
    @MainActor func login(until done: @MainActor () async -> Bool) async
    @MainActor func logout() async
}
