import Foundation
import os

/// A stand-in for a Cluenori deployment, inside the app: it answers the ingest API's two routes, the
/// manifest with the update decision the launch asked for, and every batch as taken. It reaches the
/// SDK through `URLSession.shared`, which the SDK sends with.
nonisolated final class DemoDeployment: URLProtocol {
    static let address = URL(string: "https://demo.cluenori.invalid")!

    /// Starts the demo when the launch asks for it, `-CluenoriDemoGate require`, and returns its
    /// address; nil otherwise.
    static func startIfAsked() -> URL? {
        guard Launch.value(after: "-CluenoriDemoGate") != nil else { return nil }
        URLProtocol.registerClass(DemoDeployment.self)
        return address
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host() == address.host()
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let body: String
        switch url.path() {
        case "/ingest/v1/app/manifest":
            body = Self.manifest(for: Launch.value(after: "-CluenoriDemoGate") ?? "none")
        case "/ingest/v1/app/batch":
            Self.log(Self.body(of: request))
            body = #"{"accepted":1,"duplicates":0}"#
        default:
            body = "{}"
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Data(body.utf8))
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static let logger = Logger(subsystem: "com.example.cluenori.cards", category: "demo-deployment")

    /// A request's body: URLSession hands a protocol a stream rather than the data.
    private static func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    /// Logs each signal a batch carries, so `log stream` shows what the SDK sent.
    private static func log(_ body: Data) {
        guard let batch = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let signals = batch["signals"] as? [[String: Any]]
        else { return }
        for signal in signals {
            let fields = signal.filter { $0.key != "id" && $0.key != "session" && $0.key != "payload" }
                .map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
            logger.notice("received \(fields, privacy: .public)")
        }
    }

    /// The manifest of each demo: `require`, `recommend`, `unsupported` (required, but the update
    /// needs an iOS no device has), `worded` (required, in the project's own words), or `none`.
    private static func manifest(for gate: String) -> String {
        let update = #"{"version":"0.4.0","minimumOsVersion":"26.0","storeUrl":"https://apps.apple.com/app/id1"}"#
        let policy =
            switch gate {
            case "require": #"{"decision":"require","update":\#(update)}"#
            case "recommend": #"{"decision":"recommend","update":\#(update)}"#
            case "unsupported":
                #"{"decision":"require","update":{"version":"0.4.0","minimumOsVersion":"99.0","storeUrl":"https://apps.apple.com/app/id1"}}"#
            case "worded":
                #"{"decision":"require","update":\#(update),"text":{"title":"Cards has a new home","message":"We moved your cards to faster servers. This version can't reach them any more, so update to keep flipping."}}"#
            default: #"{"decision":"none"}"#
            }
        return #"{"versionPolicy":\#(policy),"maxAgeSeconds":0}"#
    }
}
