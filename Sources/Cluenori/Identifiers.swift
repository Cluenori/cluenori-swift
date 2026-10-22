import Foundation

/// Makes the IDs of the contract: lowercase UUIDv7s, which sort by when they were made. Signals,
/// sessions and the installation each get one where they are first recorded, so a batch sent again
/// carries the same IDs and is counted once.
package struct IDMaker: Sendable {
    /// Random bits; the system's generator in apps.
    private let random: @Sendable () -> UInt64

    package init(random: @escaping @Sendable () -> UInt64 = { UInt64.random(in: .min ... .max) }) {
        self.random = random
    }

    /// A UUIDv7 for `date`: 48 bits of Unix milliseconds, then the version, 74 random bits and the
    /// variant (RFC 9562).
    package func make(at date: Date) -> String {
        let milliseconds = UInt64(max(0, (date.timeIntervalSince1970 * 1000).rounded(.down)))
        let first = random()
        let second = random()
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<6 {
            bytes[index] = UInt8(truncatingIfNeeded: milliseconds >> UInt64(8 * (5 - index)))
        }
        bytes[6] = 0x70 | UInt8(truncatingIfNeeded: first >> 8) & 0x0f
        bytes[7] = UInt8(truncatingIfNeeded: first)
        bytes[8] = 0x80 | UInt8(truncatingIfNeeded: second >> 56) & 0x3f
        for index in 9..<16 {
            bytes[index] = UInt8(truncatingIfNeeded: second >> UInt64(8 * (15 - index)))
        }
        let uuid = UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
        return uuid.uuidString.lowercased()
    }

    /// Whether `text` is a lowercase UUIDv7, as the contract requires of every ID.
    package static func isUUIDv7(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            switch index {
            case 8, 13, 18, 23:
                guard byte == UInt8(ascii: "-") else { return false }
            case 14:
                guard byte == UInt8(ascii: "7") else { return false }
            case 19:
                guard [UInt8(ascii: "8"), UInt8(ascii: "9"), UInt8(ascii: "a"), UInt8(ascii: "b")].contains(byte) else {
                    return false
                }
            default:
                guard
                    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                        || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                else {
                    return false
                }
            }
        }
        return true
    }
}
