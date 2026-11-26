import CryptoKit
import Foundation
import Testing
@testable import SongforMeKit

@Suite("检查新版本")
struct UpdatesTests {
    func payload(tag: String = "v1.4", url: String = "https://github.com/SansOfficial/SongforMe/releases/download/v1.4/SongforMe-1.4.zip",
                 digest: String? = "sha256:" + String(repeating: "ab", count: 32), prerelease: Bool = false) -> Data {
        var asset: [String: Any] = ["name": "SongforMe-1.4.zip", "browser_download_url": url, "size": 123]
        if let digest { asset["digest"] = digest }
        return try! JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "html_url": "https://github.com/SansOfficial/SongforMe/releases/tag/\(tag)", "body": "说明",
            "draft": false, "prerelease": prerelease, "assets": [["name": "SongforMe-1.4.dmg", "browser_download_url": url, "size": 1], asset],
        ])
    }

    @Test("版本号按数字比")
    func compare() {
        #expect(Updates.isNewer("1.4", than: "1.3"))
        #expect(Updates.isNewer("1.10", than: "1.9"))
        #expect(Updates.isNewer("2", than: "1.9.9"))
        #expect(!Updates.isNewer("1.4", than: "1.4.0"))
        #expect(!Updates.isNewer("1.3", than: "1.4"))
        #expect(!Updates.isNewer("1.4-beta", than: "1.3"))
    }

    @Test("挑出压缩包；不是这个仓库的地址、没有校验值、预发布的都不自动装")
    func parse() throws {
        let r = try #require(try Updates.parse(payload()))
        #expect(r.version == "1.4" && r.notes == "说明")
        #expect(r.asset?.name == "SongforMe-1.4.zip" && r.asset?.size == 123 && r.asset?.sha256 == String(repeating: "ab", count: 32))
        #expect(try Updates.parse(payload(url: "https://example.com/SongforMe-1.4.zip"))?.asset == nil)
        #expect(try Updates.parse(payload(url: "https://example.com/SongforMe-1.4.zip"), allowAnyURL: true)?.asset != nil)
        #expect(try Updates.parse(payload(digest: nil))?.asset == nil)
        #expect(try Updates.parse(payload(digest: "md5:abc"))?.asset == nil)
        #expect(try Updates.parse(payload(prerelease: true)) == nil)
        #expect(try Updates.parse(payload(tag: "nightly")) == nil)
    }

    @Test("下载的文件按大小和 SHA-256 核对")
    func verify() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "update-\(UUID().uuidString).bin")
        let data = Data("安装包".utf8)
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let asset = AppRelease.Asset(name: "a.dmg", url: file, size: data.count, sha256: hex)
        #expect(Updates.matches(file, asset))
        var wrong = asset
        wrong.sha256 = String(repeating: "0", count: 64)
        #expect(!Updates.matches(file, wrong))
        wrong = asset
        wrong.size += 1
        #expect(!Updates.matches(file, wrong))
    }
}
