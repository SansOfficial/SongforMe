import Foundation
import SongforMeKit

/// 音源从这里接进来。应用本身不带音源；放在 local/sources 里的代码会一起编译，
/// 其中写一个继承它、名叫 SongforMeSourcePack 的类（要加 @objc(SongforMeSourcePack)），返回要用的音源。
class SourcePack: NSObject {
    class func sources() -> [any MusicSource] { [] }

    static func installed() -> SourceHub {
        let pack = NSClassFromString("SongforMeSourcePack") as? SourcePack.Type
        return SourceHub(pack?.sources() ?? [])
    }
}
