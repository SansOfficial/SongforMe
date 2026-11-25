import Foundation

/// 接口返回的结构不固定，用它按路径取值，取不到就是空
public struct JSON: @unchecked Sendable {
    // 解析出来的对象都是不可变的，跨线程读是安全的
    private let raw: Any?

    public init(_ raw: Any?) { self.raw = raw is NSNull ? nil : raw }

    public init(parsing text: String) throws {
        raw = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    public subscript(_ key: String) -> JSON { JSON((raw as? [String: Any])?[key]) }

    public var exists: Bool { raw != nil }
    public var array: [JSON] { (raw as? [Any])?.map { JSON($0) } ?? [] }
    public var isArray: Bool { raw is [Any] }
    /// 严格是字符串才有值
    public var string: String? { raw as? String }
    /// 数字或写成字符串的数字
    public var double: Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        return (raw as? String).flatMap(Double.init)
    }
    public var int: Int { double.flatMap { Int(exactly: $0.rounded(.towardZero)) } ?? 0 }
    /// 数字也转成字符串，歌单号等标识用
    public var idText: String {
        if let s = raw as? String { return s }
        return (raw as? NSNumber)?.stringValue ?? ""
    }
    public var text: String { string ?? "" }
    /// 非空字符串
    public var filled: String? { string.flatMap { $0.isEmpty ? nil : $0 } }
}
