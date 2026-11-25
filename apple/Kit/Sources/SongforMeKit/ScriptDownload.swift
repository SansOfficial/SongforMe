import Foundation

/// 从链接取插件文件
public enum ScriptDownload {
    public static let maxSize = 2 << 20

    /// 认出链接，只许 https。GitHub 上看文件的网页换成文件本身的地址
    public static func address(of text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), url.scheme?.lowercased() == "https", url.user() == nil, let host = url.host()?.lowercased(), ScriptHosts.valid(host) else { return nil }
        if host == "github.com", let m = url.path().wholeMatch(of: /\/([^\/]+\/[^\/]+)\/(?:blob|raw)\/(.+)/) {
            return URL(string: "https://raw.githubusercontent.com/\(m.1)/\(m.2)")
        }
        return url
    }

    public static func text(of url: URL) async throws -> String {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 30
        c.urlCache = nil
        let http = URLSession(configuration: c)
        defer { http.finishTasksAndInvalidate() }
        let (data, response) = try await http.data(from: url, delegate: SecureOnly())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SourceError(status == 404 ? "这个链接没有内容" : "链接打不开（\(status)）") }
        return try check(data)
    }

    public static func check(_ data: Data) throws -> String {
        guard data.count <= maxSize else { throw SourceError("这个文件太大，不像插件") }
        guard let text = String(data: data, encoding: .utf8) else { throw SourceError("这不是插件文件") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") else { throw SourceError("这是一个网页，要用插件文件本身的链接") }
        return text
    }

    private final class SecureOnly: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
            request.url?.scheme?.lowercased() == "https" ? request : nil
        }
    }
}
