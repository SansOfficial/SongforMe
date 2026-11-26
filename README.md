# SongforMe

Mac 上的音乐播放器：听歌、自己定的推荐算法、歌词、听歌报告。原生 Swift（SwiftUI + AppKit），macOS 15（Sequoia）起；在 macOS 26 上用新的玻璃效果。

**它不带任何音源。** 歌从哪里来由你自己接：在应用里添加一个社区插件，或者自己写一个，见下面的“插件”。没有插件时应用可以正常打开，只是没有歌。

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

- **推荐**：从你喜欢的歌出发找相似的歌和收录了它们的歌单，打分、去重、限制同一歌手的数量，按“探索”的比例给没听过的歌手留名额，再混入一些很久没听的熟歌。听完、切歌、喜欢、不喜欢、听腻了都会影响之后的推荐；推荐出去的歌被喜欢还是被嫌弃，也会反过来调整当初找到它的那个歌单的可信度。正在听这一批推荐时点了喜欢、不喜欢或者很快切掉一首，后面还没放的歌马上跟着重排。各项权重在“算法调校”里改，算法本身是一个纯函数（`RecoEngine.swift`）；改完可以用 `RecoEvalTests.swift` 在自己曲库的拷贝上比一比效果。
- **智能随机**：放“我喜欢”时平均每 3 首穿插 1 首没听过的推荐。
- **听歌报告**：日报、周报、月报、年报。年报有逐页翻的回顾，每份报告都能存成一张分享图。
- **歌词**：桌面歌词可以拖动、缩放、锁定（鼠标穿透），外语歌第二行显示翻译。刘海歌词从屏幕顶上的刘海里长出来，显示正在唱的这句；指针停在上面展开成小播放器（右键播放条上的“词”打开，没有刘海的屏幕挂在菜单栏中间）。
- **全屏**：黑胶、歌词、星轨三种效果。
- **多个音源**：接了几个就分组显示几个。同一位歌手在不同音源里算同一个人，推荐和报告合在一起算。
- **自动更新**：打开时和之后每天向 GitHub（`api.github.com`）问一次有没有新版本，有的话左下角菜单里出现“更新到 x.y”，点了确认后才下载，核对过大小和 SHA-256、签名和版本号再替换、重新打开。检查时只发这一个请求，不带任何个人信息。不想让它联网检查：`defaults write com.sansofficial.songforme autoCheckUpdates -bool false`。自己编译、带着本机音源的版本不检查。
- **快捷键**：空格播放 / 暂停，⌘← ⌘→ 上一首 / 下一首，⌘↑ ⌘↓ 音量，⌘F 搜索，⌘L 喜欢，F 全屏。

## 插件

一个插件就是一个 JavaScript 文件，负责从某个地方搜歌、放歌。在应用左下角的“音源 → 添加插件…”里粘贴它的链接（https，GitHub 的文件页面也行）或者选本机的文件，不用重新编译。添加前会列出它要连哪些地方、登录哪个网站。

本仓库不包含任何插件，插件由各自的作者编写和维护，和本项目无关。在 GitHub 上搜话题 [songforme-plugin](https://github.com/topics/songforme-plugin) 能找到一些，自己写的也可以加上这个话题。插件是别人写的程序，只添加你信任的。

### 写一个插件

```js
// my.js：接自己的音乐服务器
const api = async path => {
  const r = await fetch(settings.server + path, {
    headers: { Authorization: "Basic " + btoa(settings.user + ":" + settings.password) },
  });
  if (r.status === 401) throw { message: "用户名或密码不对", needsLogin: true };
  return r.json();
};

source({
  id: "my",             // 定了就不要改，小写字母和数字
  name: "我的音乐",
  settings: [           // 要用户填的，没有就不写
    { key: "server", title: "服务器地址", kind: "server" },
    { key: "user", title: "用户名" },
    { key: "password", title: "密码", kind: "secret" },
  ],
  async search(query, kind, page) {   // kind 是 song、artist、album，page 从 1 开始
    if (kind !== "song") return [];
    const list = await api("/search?q=" + encodeURIComponent(query));
    return list.map(s => ({ id: s.id, name: s.title, artists: [{ id: s.artistId, name: s.artist }], duration: s.seconds }));
  },
  stream(song) {                      // 播放地址；没有权限播放时返回 null
    return settings.server + "/file/" + song.id;
  },
});
```

`search` 和 `stream` 必须有，其余要哪个写哪个，都可以是 async：

| 方法 | 返回 |
|---|---|
| `search(query, kind, page)` | 数组，或 `{ songs / artists / albums, total, hasMore }` |
| `stream(song)` | 地址，或 `null` |
| `lyrics(song)` | LRC 文本，或 `{ lrc, trans }` |
| `related(song)` | `{ songs, playlists: [{ id, songCount }] }`，推荐的候选歌曲从这里来 |
| `playlist(id, max)` | `{ title, songs }`。再写上 `playlistLink`（正则，第一个括号是编号），就能粘贴链接导入歌单 |
| `artistSongs(id, begin, count)`、`artistAlbums(id)`、`albumSongs(id)` | `{ total, songs }`、专辑数组、歌曲数组 |
| `profile()` | `{ name, avatar }`，用户填完设置时也用它检查对不对 |
| `likedSongs()`、`myPlaylists()`、`collectedPlaylists()`、`recentPlays()` | 同步账号里的内容。歌单是 `{ id, title, songCount }`，“我喜欢”加 `liked: true`；最近播放是 `{ song, time, count }` |
| `setLiked(song, liked)` | 把喜欢写回账号。没有就只记在本机 |
| `addToPlaylist(song, id)`、`createPlaylist(name, song)`、`deletePlaylist(id)` | 三个都写了才能编辑账号里的歌单 |

- 歌曲：`{ id, name, artists, album, duration, cover, date, language, vip, extra }`，只有 `id` 和 `name` 必填。`artists` 的每一项是名字或 `{ id, name, avatar }`，`album` 是名字或 `{ id, name }`，`duration` 是秒，`language` 写“国语”“英语”这样的名字，`extra` 是你自己要用的一段文字。歌手是 `{ id, name, avatar, songCount, albumCount }`，专辑是 `{ id, name, artists, cover, date }`。
- 能用的东西：`fetch`（返回 `status`、`ok`、`headers`、`text()`、`json()`）、`settings`、`login`（见下）、`sleep(毫秒)`、`btoa`、`atob`、`console.log`。
- **只能连声明过的主机**：在 `hosts: ["example.com"]` 里写域名（包含子域名，只许 https），用户填的 `kind: "server"` 的地址会自动算上（局域网可以用 http）。接口、播放地址和图片都受这个限制。
- 脚本在隔离的环境里运行，碰不到文件和应用里的其他东西；连续执行超过 5 秒会被中断。
- 出错时 `throw new Error("原因")`；需要重新登录时 `throw { message, needsLogin: true }`。

插件和填过的设置存在 `~/Library/Application Support/SongforMe/sources/`，设置文件只有你自己能读，但没有加密。

### 网页登录

要登录某个网站才能用时，声明 `login`，应用会打开官方网页让用户自己登录：

```js
source({
  // …
  hosts: ["api.example.com"],
  login: {
    url: "https://www.example.com/",    // 登录网页
    hosts: ["api.example.com"],         // 登录状态只发给这些域名（不含子域名），要和登录网页同一个网站，不写就是登录网页的域名
    cookies: ["session"],               // 有其中任何一个就算登录了
    uid: ["user_id"],                   // 账号编号在哪个 cookie 里，可以不写
  },
});
```

- 发往 `login.hosts` 的请求由应用带上登录状态，**脚本读不到 cookie**，响应里的 `Set-Cookie` 也会去掉。
- `login.signedIn`：有没有登录。
- 接口要求把账号编号、防伪值写进请求时，用占位符，应用发往 `login.hosts` 时才换成真的：`login.cookie(名字…)` 原样，`login.digits(名字…)` 只取数字，`login.number(名字…)` 同前但在 JSON 里写成数字，`login.hash(名字…)` 是 5381 哈希。写几个名字就取第一个有的。
- 写了 `profile()` 会显示账号的名字和头像；退出登录或移除插件时，登录状态一起删除。
- 脚本虽然读不到 cookie，登录后却**能以你的身份访问 `login.hosts`**，所以更要只添加信任的插件。

### 用 Swift 写

要用到 JavaScript 里没有的能力时，可以用 Swift 实现 `MusicSource`，放在仓库根目录的 `local/sources/`（不进 git），编译时自动带上：

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
        StreamInfo(url: "https://example.com/music/\(info.unwrap(song.mid)).mp3")
    }
}
```

改完重新运行 `xcodegen` 和编译。方法和插件的基本一一对应，完整的接口和说明在 `apple/Kit/Sources/SongforMeKit/Source.swift`。

请只接入你有权使用的内容，并遵守对应服务的条款。本仓库不提供、也不接受任何音源的代码。

## 代码

| 路径 | 内容 |
|---|---|
| `apple/Kit/…/RecoEngine.swift` | 推荐算法（纯函数） |
| `apple/Kit/…/Library.swift` | 同步、扩充候选、生成推荐的流程 |
| `apple/Kit/…/Report.swift` | 听歌报告的统计（纯函数） |
| `apple/Kit/…/Source.swift` | 音源接口 |
| `apple/Kit/…/ScriptSource.swift`、`ScriptRunner.swift` | 插件：数据转换；隔离的运行环境 |
| `apple/Kit/…/ScriptLogin.swift`、`ScriptDownload.swift` | 插件的网页登录；从链接下载插件 |
| `apple/Kit/…/Player.swift`、`PlayOrder.swift` | 播放队列、随机和循环、行为记录；穿插频率 |
| `apple/Kit/…/Store.swift` | 本地曲库（SQLite） |
| `apple/Kit/…/Updates.swift`、`apple/Mac/App/Updater.swift` | 检查新版本；下载、核对、替换 |
| `apple/Mac/App/AppModel.swift` | 界面的状态和动作 |
| `apple/Mac/App/SourcePack.swift`、`AppSources.swift` | 找到编译进来的音源；添加、移除插件 |
| `apple/Mac/App/WebSession.swift` | 登录窗口和登录状态 |
| `apple/Mac/Audio/` | AVPlayer 播放、系统“正在播放”和媒体键 |
| `apple/Mac/UI/` | 主界面（配色在 `Theme.swift`） |
| `apple/Mac/Report/` | 听歌报告、年度回顾、分享图 |
| `apple/Mac/Lyrics/` | 歌词跟随、桌面歌词窗口、刘海歌词 |
| `apple/Mac/Immersive/` | 全屏氛围模式 |

`apple/Kit` 和界面无关，以后的 iPhone 版直接共用；Windows 版照它和它的测试用原生技术重写。

## 许可证

[MIT](LICENSE)
