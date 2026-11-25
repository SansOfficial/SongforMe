import AppKit
import SongforMeKit
import SwiftUI
import UniformTypeIdentifiers

/// 分享图：固定大小的一张竖版海报。图片要先取好，导出时才画得出来
struct Poster: View {
    static let size = CGSize(width: 360, height: 640)

    let report: Report
    let nick: String
    let images: [URL: NSImage]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(report.period == .year ? "年度听歌报告" : "听歌\(report.period.title)").font(.system(size: 15, weight: .bold))
                Spacer()
                Text(report.title).font(.system(size: 12, weight: .medium)).opacity(0.85)
            }
            HStack(alignment: .top, spacing: 18) {
                picture(report.topSongs.first?.song.artwork(500), 128, 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text("听了").font(.system(size: 12)).opacity(0.85)
                    BigTime(seconds: report.seconds, size: 38)
                    HStack(spacing: 16) {
                        small("\(report.songs)", "首歌")
                        small("\(report.artists)", "位歌手")
                    }
                    .padding(.top, 10)
                }
                .padding(.top, 4)
            }
            .padding(.top, 18)

            heading("单曲").padding(.top, 22)
            VStack(spacing: 7) {
                ForEach(Array(report.topSongs.prefix(5).enumerated()), id: \.element.id) { i, s in
                    HStack(spacing: 10) {
                        Text("\(i + 1)").font(.system(size: 14, weight: .heavy, design: .rounded)).frame(width: 14)
                        picture(s.song.artwork(150), 34, 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.song.name).font(.system(size: 13, weight: .semibold))
                            Text(s.song.artistText).font(.system(size: 10.5)).opacity(0.75)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(s.plays) 次").font(.system(size: 11)).opacity(0.8).monospacedDigit()
                    }
                }
            }
            .padding(.top, 10)

            if !report.topArtists.isEmpty {
                heading("歌手").padding(.top, 20)
                HStack(alignment: .top, spacing: 0) {
                    ForEach(report.topArtists.prefix(4)) { a in
                        VStack(spacing: 5) {
                            picture(a.portrait(150), 48, 24)
                            Text(a.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.top, 10)
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    if let p = report.persona {
                        Text(p.title).font(.system(size: 17, weight: .heavy))
                        Text(p.text).font(.system(size: 10.5)).opacity(0.8)
                    } else if !nick.isEmpty {
                        Text(nick).font(.system(size: 14, weight: .semibold))
                    }
                }
                .lineLimit(1)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if report.persona != nil, !nick.isEmpty { Text(nick).font(.system(size: 10.5)).opacity(0.8).lineLimit(1) }
                    Text("SongforMe").font(.system(size: 11, weight: .bold, design: .rounded)).opacity(0.9)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(26)
        .frame(width: Self.size.width, height: Self.size.height)
        .background {
            ZStack {
                report.period.gradient
                Circle().fill(.white.opacity(0.18)).frame(width: 260).blur(radius: 60).offset(x: 130, y: -230)
                Circle().fill(.black.opacity(0.2)).frame(width: 300).blur(radius: 70).offset(x: -120, y: 240)
            }
        }
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    private func heading(_ text: String) -> some View { Text(text).font(.system(size: 12, weight: .semibold)).opacity(0.8) }

    private func small(_ n: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(n).font(.system(size: 18, weight: .heavy, design: .rounded))
            Text(unit).font(.system(size: 11)).opacity(0.85)
        }
    }

    private func picture(_ url: URL?, _ size: CGFloat, _ radius: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(.white.opacity(0.16))
            if let image = url.flatMap({ images[$0] }) { Image(nsImage: image).resizable().interpolation(.high).scaledToFill() }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: radius))
    }

    /// 海报上用到的图
    static func urls(_ report: Report) -> [URL] {
        let first = report.topSongs.first.flatMap { $0.song.artwork(500) }
        return [first].compactMap { $0 } + report.topSongs.prefix(5).compactMap { $0.song.artwork(150) } + report.topArtists.prefix(4).compactMap { $0.portrait(150) }
    }

    static func load(_ report: Report) async -> [URL: NSImage] {
        var out: [URL: NSImage] = [:]
        for url in urls(report) { out[url] = await ImageLoader.shared.image(url, pixels: 500) }
        return out
    }

    func render() -> Data? {
        let renderer = ImageRenderer(content: self)
        renderer.scale = 3
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

/// 海报预览，带“存为图片”“拷贝”
struct PosterExport: View {
    let report: Report
    let nick: String
    var height: CGFloat = 560
    @Environment(AppModel.self) private var app
    @State private var images: [URL: NSImage]?
    @State private var copied = false

    var body: some View {
        let scale = height / Poster.size.height
        VStack(spacing: 18) {
            ZStack {
                if let images {
                    Poster(report: report, nick: nick, images: images)
                        .clipShape(.rect(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                        .scaleEffect(scale)
                        .frame(width: Poster.size.width * scale, height: height)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: Poster.size.width * scale, height: height)
            .animation(.spring(duration: 0.5), value: images == nil)
            HStack(spacing: 10) {
                Button { save() } label: { Label("存为图片", systemImage: "arrow.down.to.line").font(.system(size: 13, weight: .semibold)) }
                    .buttonStyle(PillStyle(filled: true))
                Button { copy() } label: {
                    Label(copied ? "已拷贝" : "拷贝", systemImage: copied ? "checkmark" : "doc.on.doc").font(.system(size: 13, weight: .semibold)).contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PillStyle())
            }
            .disabled(images == nil)
        }
        .task { images = await Poster.load(report) }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugPoster)) { note in
            if let path = note.object as? String, !path.isEmpty { try? data?.write(to: URL(filePath: path)) }
        }
        #endif
    }

    private var data: Data? { images.flatMap { Poster(report: report, nick: nick, images: $0).render() } }

    private func copy() {
        guard let data else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func save() {
        guard let data, let window = NSApp.keyWindow else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "听歌\(report.period.title) \(report.title).png"
        panel.beginSheetModal(for: window) { answer in
            guard answer == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url)
                app.say("已存到“\(url.deletingLastPathComponent().lastPathComponent)”")
            } catch {
                app.say("图片没有存下来：\(error.localizedDescription)", error: true)
            }
        }
    }
}

struct PosterSheet: View {
    let report: Report
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PosterExport(report: report, nick: app.profile?.nick ?? "")
            .padding(28)
            .frame(width: 420)
            .background(Color(hex: 0x15181E))
            .overlay(alignment: .topTrailing) {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 26).background(.white.opacity(0.16), in: .circle).contentShape(.circle) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .keyboardShortcut(.cancelAction)
                    .padding(12)
                    .accessibilityLabel("关闭")
            }
            .environment(\.colorScheme, .dark)
    }
}
