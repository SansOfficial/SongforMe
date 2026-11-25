import AppKit
import ImageIO
import SwiftUI

/// 封面、头像：内存里留一份解码好的，磁盘上由系统缓存
final class ImageLoader {
    static let shared = ImageLoader()

    private let memory = NSCache<NSString, NSImage>()
    private var running: [String: Task<NSImage?, Never>] = [:]
    private let http: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 300 << 20)
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    private init() { memory.totalCostLimit = 160 << 20 }

    private func key(_ url: URL, _ pixels: Int) -> String { "\(pixels) \(url.absoluteString)" }

    /// 已经在内存里的，马上就能用
    func cached(_ url: URL?, pixels: Int) -> NSImage? {
        url.flatMap { memory.object(forKey: key($0, pixels) as NSString) }
    }

    func image(_ url: URL?, pixels: Int) async -> NSImage? {
        guard let url else { return nil }
        let k = key(url, pixels)
        if let hit = memory.object(forKey: k as NSString) { return hit }
        if let task = running[k] { return await task.value }
        let task = Task { () -> NSImage? in
            guard let (data, response) = try? await http.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return await Self.decode(data, pixels)
        }
        running[k] = task
        let image = await task.value
        running[k] = nil
        if let image { memory.setObject(image, forKey: k as NSString, cost: Int(image.size.width * image.size.height) * 4) }
        return image
    }

    /// 按要显示的大小解码，不在主线程上做
    @concurrent
    private nonisolated static func decode(_ data: Data, _ pixels: Int) async -> sending NSImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: pixels,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// 一张网络图片：加载好了淡入；换图时旧图留在下面，新图淡入盖上去
struct RemoteImage: View {
    let url: URL?
    var pixels = 300
    /// 换图时是否渐变（列表里快速滚动时不需要）
    var crossfade = false

    @State private var shown: NSImage?
    @State private var shownURL: URL?

    var body: some View {
        // 内存里有的第一帧就画出来，滚动时不闪
        let image = shownURL == url ? shown : (ImageLoader.shared.cached(url, pixels: pixels) ?? (crossfade ? shown : nil))
        ZStack {
            Rectangle().fill(Theme.coverFill)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: crossfade ? 0.45 : 0.2), value: image.map(ObjectIdentifier.init))
        .task(id: url) {
            guard shownURL != url else { return }
            if url == nil {
                shown = nil
                shownURL = nil
                return
            }
            guard let next = await ImageLoader.shared.image(url, pixels: pixels), !Task.isCancelled else { return }
            shown = next
            shownURL = url
        }
    }
}
