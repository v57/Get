import Foundation

/// BEP 5 k-bucket routing table: 160 buckets, each holding up to `k` (8)
/// nodes. Bucket `i` holds nodes whose XOR distance from our node id starts
/// with `i` matching bits (i.e. the bucket index is the bit position of the
/// first differing bit from the MSB).
public final class RoutingTable: @unchecked Sendable {
    public static let k = 8
    private static let bucketCount = 160

    // Guarded by `lock`.
    private let lock = NSLock()
    private var buckets: [Int: [DHTNodeInfo]] = [:]
    private var ownID: Data

    public init(ownID: Data) {
        precondition(ownID.count == 20, "ownID must be 20 bytes")
        self.ownID = ownID
    }

    /// The bucket index for a node at a given XOR distance from our id.
    /// Distance is bitwise-XOR of the two 20-byte ids (160 bits).
    static func bucketIndex(forDistance distance: Data) -> Int {
        // Find the first set bit from the MSB (bit 159 → bucket 0).
        for byteIndex in 0..<20 {
            let byte = distance[byteIndex]
            if byte != 0 {
                for bit in 0..<8 {
                    if byte & (0x80 >> bit) != 0 {
                        return byteIndex * 8 + bit
                    }
                }
            }
        }
        return 0 // distance == 0 → own id (never stored)
    }

    static func xor(_ a: Data, _ b: Data) -> Data {
        precondition(a.count == 20 && b.count == 20)
        var out = Data(repeating: 0, count: 20)
        for i in 0..<20 { out[i] = a[i] ^ b[i] }
        return out
    }

    public func insert(_ node: DHTNodeInfo) {
        guard node.id != ownID, node.id.count == 20 else { return }
        lock.lock(); defer { lock.unlock() }
        let distance = Self.xor(ownID, node.id)
        let index = min(Self.bucketIndex(forDistance: distance), Self.bucketCount - 1)
        var bucket = buckets[index] ?? []
        // Replace if present (refresh last-seen position → end).
        if let existing = bucket.firstIndex(where: { $0.id == node.id }) {
            bucket.remove(at: existing)
        }
        if bucket.count < Self.k {
            bucket.append(node)
        } else {
            // Full bucket: drop the node (simple policy). A full nearest bucket
            // is not evicted by distance per the spec; for a minimal client we
            // keep existing entries and just ignore new ones.
            return
        }
        buckets[index] = bucket
    }

    /// Return up to `count` nodes closest to `target`, ordered by increasing
    /// XOR distance. Iterates buckets outward from the target's bucket.
    public func findClosest(to target: Data, count: Int) -> [DHTNodeInfo] {
        lock.lock()
        let snapshot = buckets
        lock.unlock()

        var candidates: [(distance: Data, node: DHTNodeInfo)] = []
        for (_, bucket) in snapshot {
            for node in bucket {
                candidates.append((Self.xor(target, node.id), node))
            }
        }
        candidates.sort { $0.distance.lexicographicallyPrecedes($1.distance) }
        return candidates.prefix(count).map { $0.node }
    }

    public var size: Int {
        lock.lock(); defer { lock.unlock() }
        return buckets.values.reduce(0) { $0 + $1.count }
    }
}
