import Foundation

/// Lexicographically-sortable 128-bit identifier (Crockford base32, 26 chars).
/// Spec: https://github.com/ulid/spec
public struct ULID: Hashable, Sendable, CustomStringConvertible {
    public let value: String

    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public init() {
        self.init(timestamp: Date(), randomness: Self.randomness())
    }

    init(timestamp: Date, randomness: [UInt8]) {
        precondition(randomness.count == 10)
        let ms = UInt64(max(0, timestamp.timeIntervalSince1970 * 1000))
        var chars = [Character](repeating: "0", count: 26)
        for i in 0..<10 {
            let shift = (9 - i) * 5
            chars[i] = Self.alphabet[Int((ms >> shift) & 0x1F)]
        }
        var bits = 0
        var buffer: UInt32 = 0
        var idx = 10
        for byte in randomness {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                chars[idx] = Self.alphabet[Int((buffer >> bits) & 0x1F)]
                idx += 1
            }
        }
        self.value = String(chars)
    }

    private static func randomness() -> [UInt8] {
        (0..<10).map { _ in UInt8.random(in: 0...255) }
    }

    public var description: String { value }
}
