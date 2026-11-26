import AppKit
import Observation
import SongforMeKit

/// 新版本：打开应用时、之后每天问一次 GitHub 有没有新发布。有的话左下角菜单里出现“更新到 x.y”，
/// 点了并确认后才下载；核对过大小和 SHA-256、签名、标识和版本号，替换掉自己再重新打开。
/// 带着本机音源编译的版本不检查，免得被不带音源的公开版换掉。
/// 不想让它联网检查：defaults write com.sansofficial.songforme autoCheckUpdates -bool false
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    private(set) var available: AppRelease?
    /// 正在下载或安装时的说明
    private(set) var status: String?

    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// 调试时指向本机的一份假发布信息，替换的也是别处的一份程序（而且不重新打开），不碰真正装着的那份
    private let test: (feed: URL, target: URL)? = {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let feed = env["SONGFORME_UPDATE_FEED"].flatMap(URL.init(string:)), let target = env["SONGFORME_UPDATE_TARGET"] {
            return (feed, URL(filePath: target, directoryHint: .isDirectory))
        }
        #endif
        return nil
    }()

    private var enabled: Bool {
        if test != nil { return true }
        #if DEBUG
        return false
        #else
        return !SourcePack.bundled && (UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true)
        #endif
    }

    func start() {
        guard enabled else { return }
        Task {
            while available == nil {
                await check()
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    private func check() async {
        var request = URLRequest(url: test?.feed ?? Updates.latestURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SongforMe", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode ?? 200 == 200,
              let release = try? Updates.parse(data, allowAnyURL: test != nil),
              Updates.isNewer(release.version, than: current) else { return }
        available = release
        AppModel.shared.say("SongforMe \(release.version) 可以更新了，在左下角的菜单里")
    }

    func install() async {
        guard let release = available, status == nil else { return }
        let target = test?.target ?? Bundle.main.bundleURL
        let folder = target.deletingLastPathComponent()
        // 发布里没有压缩包、放在只读位置或者是从下载文件夹里直接打开的（系统会挪到一个临时的只读位置），只能手动更新
        guard let asset = release.asset, FileManager.default.isWritableFile(atPath: folder.path(percentEncoded: false)),
              !target.path(percentEncoded: false).contains("/AppTranslocation/") else {
            NSWorkspace.shared.open(release.page)
            return
        }

        let size = String(format: "%.1f", Double(asset.size) / 1_000_000)
        guard await AppModel.shared.ask("更新到 SongforMe \(release.version)？", "会从 GitHub 下载 \(size) MB，装好后自动重新打开。", button: "更新") else { return }

        status = "正在下载更新…"
        defer { status = nil }
        do {
            let staged = try await Self.prepare(asset, version: release.version, replacing: target)
            // 下载和解压用的临时文件夹，换好之后删掉
            defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent().deletingLastPathComponent()) }
            status = "正在安装更新…"
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
            if test != nil { return AppModel.shared.say("已换成 \(release.version)（调试，不重新打开）") }
            relaunch(target)
        } catch {
            AppModel.shared.say("更新没有装上：\(error.localizedDescription)", error: true)
        }
    }

    private func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let helper = Process()
        helper.executableURL = URL(filePath: "/bin/sh")
        helper.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path(percentEncoded: false)]
        try? helper.run()
        NSApp.terminate(nil)
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// 下载、核对、解压出新的程序，放在和旧的同一个磁盘上，等着替换
    @concurrent
    private static func prepare(_ asset: AppRelease.Asset, version: String, replacing target: URL) async throws -> URL {
        let fm = FileManager.default
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        do { return try await unpack(asset, version: version, replacing: target, in: work) } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    @concurrent
    private static func unpack(_ asset: AppRelease.Asset, version: String, replacing target: URL, in work: URL) async throws -> URL {
        let fm = FileManager.default
        let zip = work.appending(path: "update.zip")
        let (downloaded, response) = try await URLSession.shared.download(from: asset.url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure("下载失败（\(http.statusCode)）") }
        try fm.moveItem(at: downloaded, to: zip)
        guard Updates.matches(zip, asset) else { throw Failure("下载的文件和发布信息对不上") }

        let unpacked = work.appending(path: "unpacked", directoryHint: .isDirectory)
        try await run("/usr/bin/ditto", "-x", "-k", zip.path(percentEncoded: false), unpacked.path(percentEncoded: false))
        guard let app = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }),
              let bundle = Bundle(url: app) else { throw Failure("压缩包里没有找到程序") }
        guard bundle.bundleIdentifier == Bundle(url: target)?.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else { throw Failure("压缩包里的程序不对") }
        do { try await run("/usr/bin/codesign", "--verify", "--deep", "--strict", app.path(percentEncoded: false)) } catch { throw Failure("程序的签名不完整") }
        return app
    }

    @concurrent
    private static func run(_ tool: String, _ args: String...) async throws {
        let p = Process()
        p.executableURL = URL(filePath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            p.terminationHandler = { p in
                p.terminationStatus == 0 ? done.resume() : done.resume(throwing: Failure("\(URL(filePath: tool).lastPathComponent) 出错（\(p.terminationStatus)）"))
            }
            do { try p.run() } catch { done.resume(throwing: error) }
        }
    }
}
