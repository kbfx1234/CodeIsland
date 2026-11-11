import Foundation

/// Memo for text rendered from a reply (parsed blocks, attributed strings),
/// bounded by entry count and by the total size of its keys. The values
/// grow with their source text, so the key size stands in for both.
///
/// A count limit alone let a cache hold a hundred-odd copies of a
/// multi-hundred-kilobyte reply: a streaming reply is a new key on every
/// chunk. Evicts wholesale, which is enough for a cache whose keys are
/// mostly successive versions of one reply; an entry larger than the whole
/// budget is still cached, alone, so re-rendering it stays a lookup.
public struct TextRenderCache<Key: Hashable, Value> {
    public static var defaultByteLimit: Int { 1 << 20 }

    public let countLimit: Int
    public let byteLimit: Int
    private let cost: (Key) -> Int
    private var entries: [Key: Value] = [:]
    /// Total cost of the cached keys.
    public private(set) var byteCount = 0

    public var count: Int { entries.count }

    public init(countLimit: Int, byteLimit: Int = defaultByteLimit, cost: @escaping (Key) -> Int) {
        self.countLimit = countLimit
        self.byteLimit = byteLimit
        self.cost = cost
    }

    public mutating func value(for key: Key, render: () -> Value) -> Value {
        if let hit = entries[key] { return hit }
        let value = render()
        let size = cost(key)
        if entries.count >= countLimit || byteCount + size > byteLimit {
            entries.removeAll(keepingCapacity: true)
            byteCount = 0
        }
        entries[key] = value
        byteCount += size
        return value
    }
}

extension TextRenderCache where Key == String {
    public init(countLimit: Int, byteLimit: Int = defaultByteLimit) {
        self.init(countLimit: countLimit, byteLimit: byteLimit, cost: { $0.utf8.count })
    }
}
