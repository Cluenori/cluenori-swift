import Foundation

// The text rules of the ingest contract (product/foundation, product/engines/signals/src/app-batch.ts),
// checked where the app hands text to the SDK, so a signal the server would refuse is never made.
// Lengths count UTF-16 units, as the server does.

package enum TextRules {
    /// A feature key: keys joined by dots, up to 100 characters, such as `cards.flip`.
    package static func isFeatureKey(_ text: String) -> Bool {
        text.utf16.count <= 100 && !text.isEmpty
            && text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { isKey(Substring($0)) }
    }

    /// An environment key: one key of up to 40 characters, such as `production`.
    package static func isEnvironmentKey(_ text: String) -> Bool {
        text.utf16.count <= 40 && isKey(Substring(text))
    }

    /// The app's ID of the person signed in: 1 to 128 printable ASCII characters without spaces,
    /// and not an email address, which the contract keeps out.
    package static func isUserID(_ text: String) -> Bool {
        guard (1...128).contains(text.utf8.count), text.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
            return false
        }
        return !looksLikeEmail(text)
    }

    /// An event's or a screen's name: 1 to 256 characters, without control characters or space at
    /// either end, such as `autograph.requested` or `profile.edit`.
    package static func isName(_ text: String) -> Bool {
        guard (1...256).contains(text.utf16.count), let first = text.unicodeScalars.first,
            let last = text.unicodeScalars.last
        else {
            return false
        }
        return !first.properties.isWhitespace && !last.properties.isWhitespace
            && !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// A release version: letters, digits, `.`, `_`, `+` and `-`, starting with a letter or a
    /// digit, up to 64 characters, such as `0.3.0+20`.
    package static func isReleaseVersion(_ text: String) -> Bool {
        guard (1...64).contains(text.utf8.count), let first = text.utf8.first, isAlphanumeric(first) else {
            return false
        }
        return text.utf8.allSatisfy {
            isAlphanumeric($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "+")
                || $0 == UInt8(ascii: "-")
        }
    }

    /// An event property's key: snake_case words joined by dots, up to 64 characters, such as
    /// `card_id`.
    package static func isPropertyKey(_ text: String) -> Bool {
        guard (1...64).contains(text.utf8.count) else { return false }
        return text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            guard let first = part.utf8.first, isLowercaseLetter(first) else { return false }
            return part.utf8.allSatisfy { isLowercaseLetter($0) || isDigit($0) || $0 == UInt8(ascii: "_") }
        }
    }

    /// Device and locale text as the contract takes it: 1 to 64 characters without control
    /// characters. Longer text is cut, and none at all is `unknown`: a device field the server would
    /// refuse would refuse every batch.
    package static func shortText(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        var units = 0
        for scalar in text.unicodeScalars where scalar.properties.generalCategory != .control {
            units += scalar.utf16.count
            if units > 64 { break }
            kept.append(scalar)
        }
        let result = String(kept)
        return result.isEmpty ? "unknown" : result
    }

    // One word of a key: lowercase letters and digits, starting with a letter, with single hyphens
    // between parts: `cards`, `notes-ios`.
    private static func isKey(_ text: Substring) -> Bool {
        guard let first = text.utf8.first, isLowercaseLetter(first), text.utf8.last != UInt8(ascii: "-") else {
            return false
        }
        var previous: UInt8 = 0
        for byte in text.utf8 {
            if byte == UInt8(ascii: "-") {
                if previous == UInt8(ascii: "-") { return false }
            } else if !isLowercaseLetter(byte) && !isDigit(byte) {
                return false
            }
            previous = byte
        }
        return true
    }

    private static func looksLikeEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !parts[1].hasPrefix(".")
            && !parts[1].hasSuffix(".")
    }

    private static func isLowercaseLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }
    private static func isDigit(_ byte: UInt8) -> Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) }
    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        isLowercaseLetter(byte) || isDigit(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }
}
