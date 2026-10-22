import CluenoriIngest
import Foundation

/// Where the SDK keeps what it needs between launches: a folder of its own in the app's container,
/// excluded from backups, so a backup restored to another device starts a new installation. Every
/// read and write here runs off the main thread, inside the actor that owns the file.
package struct Folder: Sendable {
    package let url: URL

    package init(url: URL) {
        self.url = url
    }

    func file(_ name: String) -> URL { url.appending(path: name) }

    /// Makes the folder, once, excluded from backups.
    func make() throws {
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var folder = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }

    /// The JSON in `name`, or nil when there is none or it can't be read.
    func read<Value: Decodable>(_ type: Value.Type, _ name: String) -> Value? {
        guard let data = try? Data(contentsOf: file(name)) else { return nil }
        return try? Coding.decoder().decode(type, from: data)
    }

    /// Writes `value` to `name` whole, or not at all.
    func write(_ value: some Encodable, _ name: String) throws {
        try make()
        try Coding.encoder().encode(value).write(to: file(name), options: .atomic)
    }
}

/// How the SDK writes its own files: dates as seconds since 1970, which round-trip exactly.
enum Coding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

/// Whether the person lets the app collect analytics: everything the SDK records, sessions,
/// screens, events, launches, memory and MetricKit's reports. `none` records nothing and drops what
/// wasn't sent; the manifest, and so the update gate, works either way.
public enum AnalyticsConsent: String, Codable, Sendable {
    case none
    case full
}

/// What the SDK keeps between launches, beside the installation's ID and the queue.
struct KeptState: Codable, Equatable, Sendable {
    var user: String?
    /// Until the app chooses, `full`: the app states its legal basis for collecting.
    var consent: AnalyticsConsent = .full
    var session: OpenSession?
    /// A key the deployment refused, with the release it refused it for: that release sends
    /// nothing more with that key.
    var rejected: Rejection?
    /// The update each soft prompt the person closed offered, and until when it stays closed.
    var closedPrompts: [ClosedPrompt] = []

    struct Rejection: Codable, Equatable, Sendable {
        let key: String
        let release: String
    }
}

/// A soft prompt the person closed: which update it offered, and until when it stays closed.
package struct ClosedPrompt: Codable, Equatable, Sendable {
    package let version: String
    package let until: Date
}
