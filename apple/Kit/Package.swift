// swift-tools-version: 6.2
// 和界面无关的核心：推荐算法、曲库、音源接口、播放逻辑。Mac 版和 iPhone 版共用。
import PackageDescription

let package = Package(
    name: "SongforMeKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "SongforMeKit", targets: ["SongforMeKit"])],
    targets: [
        .target(name: "SongforMeKit"),
        .testTarget(name: "SongforMeKitTests", dependencies: ["SongforMeKit"]),
    ]
)
