import Foundation

/// Stable identity of a media item. On Apple platforms this is `PHAsset.localIdentifier`.
public struct AssetID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public static func < (lhs: AssetID, rhs: AssetID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// Stable identity of an album or folder. On Apple platforms this is `PHCollection.localIdentifier`.
public struct CollectionID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public static func < (lhs: CollectionID, rhs: CollectionID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// Internal SORTLY identity (proposals, rules, plans, clusters ...).
public struct SortlyID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID().uuidString.lowercased() }
    public var description: String { rawValue }

    /// Deterministic identity derived from content. Used so that re-running an analysis
    /// produces the same proposal ids (decisions stay attached to "the same" proposal).
    public static func stable(_ parts: String...) -> SortlyID {
        SortlyID(StableHash.hex(parts.joined(separator: "\u{1F}")))
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// Small, dependency-free, platform-stable hash (FNV-1a 64 bit, two lanes).
/// Swift's `Hasher` is randomly seeded per process and must never be persisted.
public enum StableHash {
    public static func fnv1a64(_ string: String, seed: UInt64 = 0xcbf29ce484222325) -> UInt64 {
        var hash = seed
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }

    public static func hex(_ string: String) -> String {
        let a = fnv1a64(string)
        let b = fnv1a64(string, seed: 0x84222325cbf29ce4)
        return String(format: "%016llx%016llx", a, b)
    }

    /// Order-independent fingerprint of a set of identifiers.
    public static func setFingerprint<S: Sequence>(_ ids: S) -> String where S.Element == String {
        var xorA: UInt64 = 0
        var sumB: UInt64 = 0
        var count: UInt64 = 0
        for id in ids {
            let h = fnv1a64(id)
            xorA ^= h
            sumB &+= fnv1a64(id, seed: 0x84222325cbf29ce4)
            count &+= 1
        }
        return String(format: "%016llx%016llx-%llu", xorA, sumB, count)
    }
}
