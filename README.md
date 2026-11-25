# SongforMe

Mac 上的音乐播放器：听歌、自己定的推荐算法、歌词、听歌报告。原生 Swift（SwiftUI + AppKit），macOS 26 起。

**它不带任何音源。** 歌从哪里来由你自己接，接口很小，见下面的“接入音源”。没有接音源时应用可以正常打开，只是没有歌。

所有数据（曲库、听歌记录、设置）只保存在本机：`~/Library/Application Support/SongforMe/library.sqlite`。

## 编译

需要 Xcode 26 和 `brew install xcodegen`：

```bash
cd apple
xcodegen                          # 由 project.yml 生成 Xcode 工程，改了文件清单要重跑
xcodebuild -scheme SongforMe -configuration Release -derivedDataPath build build
open build/Build/Products/Release/SongforMe.app
(cd Kit && swift test)            # 算法、播放队列、报告、音源接口、存储的测试
```

## 功能

- **推荐**：从你喜欢的歌出发找相似的歌和收录了它们的歌单，打分、去重、限制同一歌手的数量，再混入一些很久没听的熟歌。听完、切歌、喜欢、不喜欢、听腻了都会影响之后的推荐。各项权重在“算法调校”里改，算法本身是一个纯函数（`RecoEngine.swift`）。
- **智能随机**：放“我喜欢”时平均每 3 首穿插 1 首没听过的推荐。
- **听歌报告**：日报、周报、月报、年报。年报有逐页翻的回顾，每份报告都能存成一张分享图。
- **歌词**：桌面歌词可以拖动、缩放、锁定（鼠标穿透），外语歌第二行显示翻译。
- **全屏**：黑胶、歌词、星轨三种效果。
- **多个音源**：接了几个就分组显示几个。同一位歌手在不同音源里算同一个人，推荐和报告合在一起算。
- **快捷键**：空格播放 / 暂停，⌘← ⌘→ 上一首 / 下一首，⌘↑ ⌘↓ 音量，⌘F 搜索，⌘L 喜欢，F 全屏。

## 接入音源

音源是你自己的 Swift 代码，放在仓库根目录的 `local/sources/` 里（这个目录不进 git）。编译时会自动带上，没有这个目录就编译成不带音源的版本。

至少要写两样：一个实现 `MusicSource` 的类型，和一个告诉应用有哪些音源的类。

```swift
// local/sources/MySource.swift
import Foundation
import SongforMeKit

/// 名字固定：应用启动时按这个名字找它
@objc(SongforMeSourcePack)
final class MySources: SourcePack {
    override class func sources() -> [any MusicSource] { [MySource()] }
}

nonisolated struct MySource: MusicSource {
    /// 短名字定了就不要改：所有编号都以“短名字:”开头
    let info = SourceInfo(id: "my", name: "我的音乐")

    func search(_ query: String, _ kind: SearchKind, page: Int) async throws -> SearchPage {
        var result = SearchPage()
        guard kind == .song else { return result }
        result.songs = [
            Song(mid: info.wrap("1"), name: "第一首歌", singers: [Singer(mid: info.wrap("a1"), name: "某位歌手")], duration: 215)
        ]
        result.total = 1
        return result
    }

    func stream(_ song: Song) async throws -> StreamInfo? {
        // 任何 AVPlayer 能放的地址；没有权限播放时返回 nil，播放器会跳过
        StreamInfo(url: "https://example.com/music/\(info.unwrap(song.mid)).mp3")
    }
}
```

改完重新运行 `xcodegen` 和编译。其余的方法都有默认实现，要哪个功能就写哪个：

| 方法 | 写了之后有什么 |
|---|---|
| `related` | 推荐的候选歌曲。没有它就只能推荐已经在曲库里的歌 |
| `playlist`、`playlistID` | 粘贴链接导入歌单，当作推荐的口味种子 |
| `lyrics` | 歌词 |
| `artistSongs`、`artistAlbums`、`albumSongs` | 歌手页、专辑页 |
| `cover`、`avatar` | 封面和歌手头像（`Song.cover`、`Album.cover` 里直接有地址时不用写 `cover`） |
| `hasAccount`、`account`、`login`、`logout`、`profile` | 登录入口、昵称和头像 |
| `myPlaylists`、`likedSongs`、`collectedPlaylists`、`recentPlays` | 同步账号里的歌单、喜欢的歌、最近播放 |
| `perform` 和 `abilities` | 把喜欢、建歌单这些操作写回账号。没有声明 `.like` 时，喜欢只记在本机 |

完整的接口和说明在 `apple/Kit/Sources/SongforMeKit/Source.swift`，`SourceTests.swift` 里有一个用来测试的假音源可以参考。

请只接入你有权使用的内容，并遵守对应服务的条款。本项目不提供、也不接受任何音源的代码。

## 代码

| 路径 | 内容 |
|---|---|
| `apple/Kit/…/RecoEngine.swift` | 推荐算法（纯函数） |
| `apple/Kit/…/Library.swift` | 同步、扩充候选、生成推荐的流程 |
| `apple/Kit/…/Report.swift` | 听歌报告的统计（纯函数） |
| `apple/Kit/…/Source.swift` | 音源接口 |
| `apple/Kit/…/Player.swift`、`PlayOrder.swift` | 播放队列、随机和循环、行为记录；穿插频率 |
| `apple/Kit/…/Store.swift` | 本地曲库（SQLite） |
| `apple/Mac/App/AppModel.swift` | 界面的状态和动作 |
| `apple/Mac/App/SourcePack.swift` | 找到编译进来的音源 |
| `apple/Mac/Audio/` | AVPlayer 播放、系统“正在播放”和媒体键 |
| `apple/Mac/UI/` | 主界面（配色在 `Theme.swift`） |
| `apple/Mac/Report/` | 听歌报告、年度回顾、分享图 |
| `apple/Mac/Lyrics/` | 歌词跟随、桌面歌词窗口 |
| `apple/Mac/Immersive/` | 全屏氛围模式 |

`apple/Kit` 和界面无关，以后的 iPhone 版直接共用；Windows 版照它和它的测试用原生技术重写。
