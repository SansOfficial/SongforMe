import Foundation
@preconcurrency import JavaScriptCore
import Synchronization

/// 能连哪些主机。脚本自己声明的域名（含子域名，只许 https），加上用户在设置里填的服务器（https 或 http）
public struct ScriptHosts: Sendable {
    public var declared: [String] = []
    /// 用户填的服务器，主机名:端口
    var servers: Set<String> = []

    static func valid(_ host: String) -> Bool { host.wholeMatch(of: /([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9-]{2,}/) != nil }

    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }

    public func allows(_ url: URL) -> Bool {
        guard let origin = Self.origin(url) else { return false }
        if servers.contains(origin) { return true }
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return false }
        return declared.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}

/// 在隔离的 JavaScript 环境里运行一个音源脚本。
/// 脚本碰不到文件、系统和应用里的其他东西，只有 fetch 能联网，而且只能连 hosts 允许的主机。
final class ScriptRunner: @unchecked Sendable {
    /// 一次调用最多等多久
    private let patience: Double
    private static let maxResponse = 20 << 20
    private static let maxRequests = 32
    /// 一段脚本最多连续执行几秒
    private static let longest = 5.0

    private let queue = DispatchQueue(label: "songforme.script", qos: .userInitiated)
    /// 只在 queue 上用
    private var context: JSContext?
    private var thrown: String?
    private var script = ""
    /// 换一个环境加一，旧环境里没办完的请求回来时不理会
    private var era = 0
    private var settings = "{}"
    private var signedIn = false
    /// 占位符里的暗号，免得和普通内容撞上
    private let mark = "login" + UUID().uuidString.replacing("-", with: "")

    private struct State {
        var hosts = ScriptHosts()
        var login: (site: ScriptLogin, jar: any ScriptJar)?
        var waiting: [Int: CheckedContinuation<String, any Error>] = [:]
        var next = 0
        var requests = 0
        /// 超时之后脚本还没交还控制权：多半是死循环了
        var stuck = false
    }

    private let state = Mutex(State())

    init(patience: Double = 45) { self.patience = patience }

    var hosts: ScriptHosts {
        get { state.withLock { $0.hosts } }
        set { state.withLock { $0.hosts = newValue } }
    }

    /// 请求发往登录的网站时，带上 jar 里的登录状态
    func use(_ jar: any ScriptJar, for site: ScriptLogin) { state.withLock { $0.login = (site, jar) } }

    private let http: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.httpMaximumConnectionsPerHost = 4
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 30
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    /// 载入脚本，返回它登记的信息（JSON）
    func load(_ script: String, within limit: Double) async throws -> String {
        try await wait(limit) { [self] id in
            self.script = script
            boot()
            if let thrown { return finish(id, .failure(SourceError("脚本有错误：\(thrown)"))) }
            context?.objectForKeyedSubscript("__describe")?.call(withArguments: [id])
        }
    }

    private func boot() {
        era += 1
        let c = JSContext(virtualMachine: JSVirtualMachine())!
        Self.limit(c)
        c.exceptionHandler = { [weak self] _, error in self?.thrown = error?.toString() }
        context = c
        install(in: c)
        c.evaluateScript(Self.prelude)
        c.evaluateScript(script, withSourceURL: URL(string: "source.js"))
        c.objectForKeyedSubscript("__setSettings")?.call(withArguments: [settings])
        c.objectForKeyedSubscript("__setSignedIn")?.call(withArguments: [signedIn])
    }

    /// 进脚本执行一段，只在 queue 上调用。被掐掉的环境不能再用，重新开一个
    private func enter(_ body: () -> Void) {
        let start = SuspendingClock.now
        body()
        guard SuspendingClock.now - start >= .seconds(Self.longest * 0.9) else { return }
        let lost = state.withLock { s in
            defer { s.waiting = [:] }
            return s.waiting.values
        }
        for c in lost { c.resume(throwing: SourceError("音源太久没有回应")) }
        boot()
    }

    /// 一段脚本连续执行太久就掐掉，免得死循环一直占着 CPU。没有公开的接口，找不到就算了
    private static func limit(_ c: JSContext) {
        #if os(macOS)
        typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, UnsafeRawPointer?, UnsafeRawPointer?) -> Void
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return }
        unsafeBitCast(symbol, to: SetLimit.self)(JSContextGetGroup(c.jsGlobalContextRef), longest, nil, nil)
        #endif
    }

    /// 更新脚本里的 settings
    func set(settings json: String) {
        queue.async { [self] in
            settings = json
            context?.objectForKeyedSubscript("__setSettings")?.call(withArguments: [json])
        }
    }

    /// 更新脚本里的 login.signedIn
    func set(signedIn value: Bool) {
        queue.async { [self] in
            guard signedIn != value else { return }
            signedIn = value
            context?.objectForKeyedSubscript("__setSignedIn")?.call(withArguments: [value])
        }
    }

    /// 调用脚本里的一个方法，参数和结果都用 JSON 传
    func call(_ method: String, _ arguments: String) async throws -> String {
        try await wait(patience) { [self] id in
            context?.objectForKeyedSubscript("__call")?.call(withArguments: [id, method, arguments])
        }
    }

    private func wait(_ limit: Double, _ work: @escaping @Sendable (Int) -> Void) async throws -> String {
        if state.withLock({ $0.stuck }) { throw SourceError("音源没有响应，移除后重新添加试试") }
        return try await withCheckedThrowingContinuation { continuation in
            let id = state.withLock { s in
                s.next += 1
                s.waiting[s.next] = continuation
                return s.next
            }
            queue.async { [self] in
                thrown = nil
                enter { work(id) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + limit) { [weak self] in
                guard let self else { return }
                guard state.withLock({ $0.waiting[id] != nil }) else { return }
                finish(id, .failure(SourceError("音源太久没有回应")))
                // 还卡着的话，之后的调用直接报错，不用再等；缓过来了再恢复
                state.withLock { $0.stuck = true }
                queue.async { [self] in state.withLock { $0.stuck = false } }
            }
        }
    }

    private func finish(_ id: Int, _ result: Result<String, any Error>) {
        state.withLock { $0.waiting.removeValue(forKey: id) }?.resume(with: result)
    }

    deinit { http.invalidateAndCancel() }

    // MARK: 给脚本用的东西

    private func install(in c: JSContext) {
        let done: @convention(block) (Int, String) -> Void = { [weak self] id, json in self?.finish(id, .success(json)) }
        let fail: @convention(block) (Int, String, Bool) -> Void = { [weak self] id, message, login in
            self?.finish(id, .failure(SourceError(message.isEmpty ? "音源出错了" : String(message.prefix(200)), needsLogin: login)))
        }
        let fetch: @convention(block) (Int, String, String) -> Void = { [weak self] id, url, options in self?.fetch(id, url, options) }
        let sleep: @convention(block) (Int, Double) -> Void = { [weak self] id, ms in
            guard let self else { return }
            let era = self.era
            queue.asyncAfter(deadline: .now() + min(max(ms.isFinite ? ms : 0, 0), 30000) / 1000) { [weak self] in self?.settle(id, era, "null") }
        }
        let log: @convention(block) (String) -> Void = { text in
            #if DEBUG
            print("[音源] \(text)")
            #endif
        }
        let btoa: @convention(block) (String) -> String = { Data($0.utf8).base64EncodedString() }
        let atob: @convention(block) (String) -> String = { Data(base64Encoded: $0, options: .ignoreUnknownCharacters).map { String(decoding: $0, as: UTF8.self) } ?? "" }
        for (name, block) in [("__done", done as Any), ("__fail", fail), ("__fetch", fetch), ("__sleep", sleep), ("__log", log), ("btoa", btoa), ("atob", atob)] {
            c.setObject(block, forKeyedSubscript: name as NSString)
        }
        c.setObject(mark, forKeyedSubscript: "__mark" as NSString)
    }

    private func settle(_ id: Int, _ era: Int, _ json: String) {
        queue.async { [self] in
            guard era == self.era else { return }
            enter { _ = context?.objectForKeyedSubscript("__settle")?.call(withArguments: [id, json]) }
        }
    }

    private struct Options: Decodable {
        var method: String?
        var headers: [String: String]?
        var body: String?
    }

    private func fetch(_ id: Int, _ address: String, _ options: String) {
        let era = self.era
        func refuse(_ message: String) { settle(id, era, Self.json(["error": message])) }
        guard let url = URL(string: address) else { return refuse("地址不对：\(address)") }
        guard hosts.allows(url) else { return refuse("音源没有声明要连接 \(url.host() ?? address)") }
        guard state.withLock({ s in
            guard s.requests < Self.maxRequests else { return false }
            s.requests += 1
            return true
        }) else { return refuse("同时发出的请求太多") }
        let o = (try? JSONDecoder().decode(Options.self, from: Data(options.utf8))) ?? Options()
        var request = URLRequest(url: url)
        request.httpMethod = (o.method ?? "GET").uppercased()
        request.httpBody = o.body.map { Data($0.utf8) }
        for (k, v) in o.headers ?? [:] { request.setValue(v, forHTTPHeaderField: k) }
        Task { [self] in
            defer { state.withLock { $0.requests -= 1 } }
            do {
                var request = request
                var redirects = Redirects(allow: { [hosts] in hosts.allows($0) })
                if let (site, jar) = state.withLock({ $0.login }), site.covers(url) {
                    try await sign(&request, url, site, jar)
                    // 带着登录状态的请求不跟着跳到别处
                    redirects = Redirects(allow: { $0.scheme == "https" && $0.host() == url.host() && $0.port == url.port })
                }
                let (data, response) = try await http.data(for: request, delegate: redirects)
                guard data.count <= Self.maxResponse else { return refuse("返回的内容太大") }
                let r = response as? HTTPURLResponse
                var headers: [String: String] = [:]
                for (k, v) in r?.allHeaderFields ?? [:] { headers["\(k)".lowercased()] = "\(v)" }
                headers["set-cookie"] = nil
                settle(id, era, Self.json(["status": r?.statusCode ?? 0, "headers": headers, "text": String(decoding: data, as: UTF8.self)]))
            } catch {
                refuse(error.localizedDescription)
            }
        }
    }

    /// 带上登录状态，把占位符换成真的
    func sign(_ request: inout URLRequest, _ url: URL, _ site: ScriptLogin, _ jar: any ScriptJar) async throws {
        let all = await jar.cookies()
        let values = site.values(all)
        let fill = { (text: String, encode: Bool) in ScriptLogin.fill(text, mark: self.mark, values: values, encode: encode) }
        guard let real = URL(string: fill(url.absoluteString, true)), real.host() == url.host(), site.covers(real) else { throw SourceError("地址不对") }
        request.url = real
        for (k, v) in request.allHTTPHeaderFields ?? [:] { request.setValue(fill(v, false), forHTTPHeaderField: k) }
        if let body = request.httpBody {
            let form = request.value(forHTTPHeaderField: "Content-Type")?.contains("urlencoded") == true
            request.httpBody = Data(fill(String(decoding: body, as: UTF8.self), form).utf8)
        }
        let cookie = ScriptLogin.matching(all, real).map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        request.setValue(cookie.isEmpty ? nil : cookie, forHTTPHeaderField: "Cookie")
    }

    /// 跳转的目标也要在允许的主机里
    private final class Redirects: NSObject, URLSessionTaskDelegate {
        let allow: @Sendable (URL) -> Bool
        init(allow: @escaping @Sendable (URL) -> Bool) { self.allow = allow }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
            request.url.map(allow) == true ? request : nil
        }
    }

    static func json(_ value: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    private static let prelude = """
    (() => {
      "use strict";
      const { __done: done, __fail: fail, __fetch: send, __sleep: sleep, __log: log, __mark: mark } = globalThis;
      for (const k of ["__done", "__fail", "__fetch", "__sleep", "__log", "__mark"]) delete globalThis[k];
      let registered = null, next = 0;
      const pending = new Map();
      const ask = start => new Promise((resolve, reject) => { const id = ++next; pending.set(id, { resolve, reject }); start(id); });
      const hidden = (name, value) => Object.defineProperty(globalThis, name, { value, enumerable: false });
      hidden("__settle", (id, json) => {
        const p = pending.get(id);
        pending.delete(id);
        if (!p) return;
        const v = JSON.parse(json);
        if (v && v.error !== undefined) p.reject(new Error(v.error)); else p.resolve(v);
      });
      hidden("__describe", id => {
        if (!registered) return fail(id, "这不是插件：没有调用 source({ … })", false);
        const info = { methods: [] };
        for (const [k, v] of Object.entries(registered)) if (typeof v === "function") info.methods.push(k); else info[k] = v;
        done(id, JSON.stringify(info));
      });
      hidden("__setSettings", json => { globalThis.settings = Object.freeze(JSON.parse(json)); });
      hidden("__call", (id, method, args) => {
        Promise.resolve().then(() => registered[method](...JSON.parse(args)))
          .then(v => done(id, JSON.stringify(v === undefined ? null : v)))
          .catch(e => fail(id, String((e && e.message) || e), !!(e && e.needsLogin)));
      });
      const token = kind => (...names) => `~${mark}~${kind}~${names.join("~")}~~`;
      const login = { cookie: token("cookie"), digits: token("digits"), number: token("number"), hash: token("hash") };
      hidden("__setSignedIn", signedIn => { globalThis.login = Object.freeze({ ...login, signedIn }); });
      globalThis.login = Object.freeze({ ...login, signedIn: false });
      globalThis.settings = Object.freeze({});
      globalThis.source = s => {
        if (!s || typeof s !== "object") throw new Error("source() 要传一个对象");
        registered = s;
      };
      globalThis.fetch = async (url, options = {}) => {
        const o = { method: options.method, headers: {}, body: options.body === undefined || options.body === null ? undefined : String(options.body) };
        for (const [k, v] of Object.entries(options.headers || {})) o.headers[k] = String(v);
        const r = await ask(id => send(id, String(url), JSON.stringify(o)));
        return {
          status: r.status, ok: r.status >= 200 && r.status < 300, headers: r.headers,
          text: async () => r.text, json: async () => JSON.parse(r.text),
        };
      };
      globalThis.sleep = ms => ask(id => sleep(id, Number(ms) || 0));
      const write = (...a) => log(a.map(v => typeof v === "string" ? v : JSON.stringify(v)).join(" "));
      globalThis.console = { log: write, info: write, warn: write, error: write };
    })();
    """
}
