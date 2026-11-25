/// 记住插入顺序的字典。算法要求同样的输入得到同样的结果，普通字典的遍历顺序每次启动都不一样。
public struct OrderedMap<Key: Hashable, Value> {
    private var slots: [Key: Int] = [:]
    public private(set) var keys: [Key] = []
    public private(set) var values: [Value] = []

    public init() {}

    public var count: Int { keys.count }

    public subscript(key: Key) -> Value? { slots[key].map { values[$0] } }

    public subscript(key: Key, default fallback: @autoclosure () -> Value) -> Value {
        get { self[key] ?? fallback() }
        set {
            if let i = slots[key] {
                values[i] = newValue
            } else {
                slots[key] = keys.count
                keys.append(key)
                values.append(newValue)
            }
        }
        _modify {
            let i: Int
            if let found = slots[key] {
                i = found
            } else {
                i = keys.count
                slots[key] = i
                keys.append(key)
                values.append(fallback())
            }
            yield &values[i]
        }
    }

    public var pairs: Zip2Sequence<[Key], [Value]> { zip(keys, values) }

    /// 原地修改每一个值
    public mutating func updateEach(_ body: (inout Value) -> Void) {
        for i in values.indices { body(&values[i]) }
    }
}

extension OrderedMap: Sendable where Key: Sendable, Value: Sendable {}
