import CryptoKit
import Foundation

// 检查新版本：读 GitHub 上最新一次发布的信息，挑出里面的压缩包，下载后核对大小和 SHA-256。
// 这里只做和界面无关的部分，方便测试；下载、装上和重开在 Mac 版里。

public struct AppRelease: Sendable, Equatable {
    public var version: String
    public var page: URL
    public var notes: String
    /// 自动更新用的压缩包（.zip，里面是程序本身；.dmg 要挂载成磁盘才能读，系统会另外要权限）。
    /// 发布里没有压缩包、或者没有校验值时为 nil，这时只能打开发布页手动下载
    public var asset: Asset?

    public struct Asset: Sendable, Equatable {
        public var name: String
        public var url: URL
        public var size: Int
        public var sha256: String
    }
}

public enum Updates {
    public static let latestURL = URL(string: "https://api.github.com/repos/SansOfficial/SongforMe/releases/latest")!
    /// 只从这个仓库的发布里下载
    static let downloadPrefix = "https://github.com/SansOfficial/SongforMe/releases/download/"

    struct Payload: Decodable {
        var tag_name: String
        var html_url: String
        var body: String?
        var draft: Bool?
        var prerelease: Bool?
        var assets: [Item]

        struct Item: Decodable {
            var name: String
            var browser_download_url: String
            var size: Int
            var digest: String?
        }
    }

    /// allowAnyURL：测试时压缩包可以放在本机
    public static func parse(_ data: Data, allowAnyURL: Bool = false) throws -> AppRelease? {
        let p = try JSONDecoder().decode(Payload.self, from: data)
        guard p.draft != true, p.prerelease != true, let page = URL(string: p.html_url) else { return nil }
        let version = p.tag_name.hasPrefix("v") ? String(p.tag_name.dropFirst()) : p.tag_name
        guard parts(version) != nil else { return nil }
        var release = AppRelease(version: version, page: page, notes: p.body ?? "", asset: nil)
        if let a = p.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }),
           allowAnyURL || a.browser_download_url.hasPrefix(downloadPrefix),
           let url = URL(string: a.browser_download_url),
           let digest = a.digest, digest.hasPrefix("sha256:"), a.size > 0 {
            let hex = String(digest.dropFirst("sha256:".count)).lowercased()
            if hex.count == 64, hex.allSatisfy(\.isHexDigit) { release.asset = .init(name: a.name, url: url, size: a.size, sha256: hex) }
        }
        return release
    }

    private static func parts(_ version: String) -> [Int]? {
        let p = version.split(separator: ".").map { Int($0) }
        return p.isEmpty || p.contains(nil) ? nil : p.compactMap { $0 }
    }

    /// 1.10 比 1.9 新；1.4 和 1.4.0 一样
    public static func isNewer(_ version: String, than current: String) -> Bool {
        guard var a = parts(version), var b = parts(current) else { return false }
        let n = max(a.count, b.count)
        a += Array(repeating: 0, count: n - a.count)
        b += Array(repeating: 0, count: n - b.count)
        return b.lexicographicallyPrecedes(a)
    }

    /// 下载下来的文件和发布信息里写的大小、SHA-256 是否一致
    public static func matches(_ file: URL, _ asset: AppRelease.Asset) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        var hash = SHA256()
        var size = 0
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
            size += chunk.count
        }
        let hex = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return size == asset.size && hex == asset.sha256
    }
}
