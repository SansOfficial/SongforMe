import AppKit
import CryptoKit
import SongforMeKit
import WebKit

/// 登录态：让用户在音源的官方页面里自己登录，再带着登录态代发请求。
/// 登录用的 cookie 存在系统 WebKit 的独立数据区里，不写进项目文件，也不打印。
final class WebSession {
    struct Site {
        /// 数据区的编号，换了就等于退出登录
        var id: UUID
        var name: String
        var home: URL
        /// 取哪些域名的 cookie
        var cookieHosts: [String]
        /// 只允许把登录态发给这些域名（含子域名）
        var allowedHosts: [String]
        /// 登录页加载完后执行的脚本，比如帮用户点开“登录”
        var onLoad = ""
    }

    let site: Site
    let dataStore: WKWebsiteDataStore
    private var loginWindow: LoginWindow?
    /// 数据区刚打开时 cookie 还没从磁盘读进来，直接取是空的；先查一次数据就会读
    private var loaded = false

    init(_ site: Site) {
        self.site = site
        dataStore = WKWebsiteDataStore(forIdentifier: site.id)
    }

    /// 登录窗口和后台窗口共用的网页配置
    func configuration() -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = dataStore
        c.applicationNameForUserAgent = Self.safari
        return c
    }

    private static let safari = "Version/26.0 Safari/605.1.15"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(safari)"

    /// 只取这个网站的网页会用到的那部分 cookie
    func jar() async -> [String: String] {
        var out: [String: String] = [:]
        for c in await cookies() {
            let domain = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
            if site.cookieHosts.contains(where: { $0 == domain || $0.hasSuffix(".\(domain)") }) { out[c.name] = c.value }
        }
        return out
    }

    // MARK: 登录、退出

    /// 打开官方网页，由用户自己扫码或输入；等到登录成功，或者用户把窗口关掉
    func login(until done: @MainActor () async -> Bool) async {
        if let loginWindow { return loginWindow.show() }
        let window = LoginWindow(session: self)
        loginWindow = window
        window.show()
        defer {
            window.close()
            loginWindow = nil
        }
        while window.isOpen {
            try? await Task.sleep(for: .seconds(1))
            if await done() { return }
        }
    }

    func cookies() async -> [HTTPCookie] {
        if !loaded {
            await withCheckedContinuation { done in dataStore.fetchDataRecords(ofTypes: [WKWebsiteDataTypeCookies]) { _ in done.resume() } }
            loaded = true
        }
        return await dataStore.httpCookieStore.allCookies()
    }

    func logout() async {
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    // MARK: 请求

    func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return site.allowedHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private let http: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 20
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    func send(_ url: URL, body: Data, type: String) async throws -> (status: Int, text: String) {
        guard isAllowed(url) else { throw SourceError("不允许的请求地址：\(url.host() ?? "")") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(site.home.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("https://\(site.home.host() ?? "")", forHTTPHeaderField: "Origin")
        let cookie = await jar().map { "\($0)=\($1)" }.joined(separator: "; ")
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }

        // 应用闲置一阵后，之前保持的连接可能已经被服务器关掉，第一次请求会直接失败。
        // 经这里发出的都是只读请求（写操作走官方网页），所以可以放心重试。
        for attempt in 0... {
            do {
                let (data, response) = try await http.data(for: request)
                return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
            } catch let error as URLError {
                if attempt >= 2 || [.timedOut, .cancelled, .notConnectedToInternet].contains(error.code) { throw error }
                try await Task.sleep(for: .milliseconds(300 * (attempt + 1)))
            }
        }
        throw URLError(.unknown)
    }
}

// MARK: - 插件的登录

extension WebSession: ScriptJar {
    /// 每个插件一个数据区，互相看不到
    convenience init(script id: String, name: String, home: URL) {
        let h = Array(SHA256.hash(data: Data("songforme.source.\(id)".utf8)).prefix(16))
        let uuid = h.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
        self.init(Site(id: UUID(uuid: uuid), name: name, home: home, cookieHosts: [], allowedHosts: []))
    }
}

// MARK: - 登录窗口

private final class LoginWindow: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private let window: NSWindow
    private let web: WKWebView
    private let site: WebSession.Site
    private var popups: [NSWindow] = []
    private(set) var isOpen = true

    init(session: WebSession) {
        site = session.site
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        web = WKWebView(frame: .zero, configuration: session.configuration())
        super.init()
        window.title = "登录\(SourceInfo(id: "", name: site.name).spaced)"
        // 让人看得到现在在哪个网站上
        window.subtitle = site.home.host() ?? ""
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.delegate = self
        window.center()
        web.navigationDelegate = self
        web.uiDelegate = self
        web.load(URLRequest(url: site.home))
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() {
        isOpen = false
        popups.forEach { $0.close() }
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === window { isOpen = false }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView === web { window.subtitle = web.url?.host() ?? "" }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === web, !site.onLoad.isEmpty { webView.evaluateJavaScript(site.onLoad) }
    }

    // 扫码等登录方式会另开一个小窗口
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let size = NSSize(width: windowFeatures.width?.doubleValue ?? 720, height: windowFeatures.height?.doubleValue ?? 560)
        let popup = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        popup.isReleasedWhenClosed = false
        popup.title = window.title
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.uiDelegate = self
        popup.contentView = view
        popup.center()
        popup.makeKeyAndOrderFront(nil)
        popups.append(popup)
        return view
    }

    func webViewDidClose(_ webView: WKWebView) {
        popups.first { $0.contentView === webView }?.close()
    }
}
