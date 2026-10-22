import Cluenori
import CluenoriIngest
import Foundation
import Synchronization

/// A deployment for tests: answers the ingest API's two routes as the test says, fails like a phone
/// offline when told to, and keeps what it received.
package final class FakeDeployment: Sendable {
    /// How the deployment answers a batch: a status and a body.
    package typealias BatchAnswer = @Sendable (AppBatch) -> (status: Int, body: String)

    private struct State {
        var offline = false
        var batchAnswer: BatchAnswer = { batch in
            (200, #"{"accepted":\#(batch.signals.count),"duplicates":0}"#)
        }
        var manifestAnswer: (status: Int, body: String) = (200, FakeDeployment.manifest(decision: "none"))
        /// Every batch that reached the deployment, whatever it answered.
        var attempts: [AppBatch] = []
        /// The batches it took.
        var batches: [AppBatch] = []
        var manifestQueries: [[String: String]] = []
        var authorizations: Set<String> = []
    }

    private let state = Mutex(State())

    package init() {}

    /// What the SDK sends with: the engine's transport.
    package var transport: CluenoriIngestAPI.Transport {
        { [self] request in try answer(request) }
    }

    package func setOffline(_ offline: Bool) {
        state.withLock { $0.offline = offline }
    }

    package func answerBatches(_ answer: @escaping BatchAnswer) {
        state.withLock { $0.batchAnswer = answer }
    }

    package func answerBatches(status: Int, body: String) {
        answerBatches { _ in (status, body) }
    }

    package func answerManifest(status: Int = 200, _ body: String) {
        state.withLock { $0.manifestAnswer = (status, body) }
    }

    /// The batches the deployment took, in order.
    package var batches: [AppBatch] { state.withLock { $0.batches } }
    /// Every batch sent, taken or not.
    package var attempts: [AppBatch] { state.withLock { $0.attempts } }
    /// Every signal the deployment took, in order.
    package var signals: [AppSignal] { batches.flatMap(\.signals) }
    package var manifestQueries: [[String: String]] { state.withLock { $0.manifestQueries } }
    package var authorizations: Set<String> { state.withLock { $0.authorizations } }

    /// A manifest's JSON: its decision, and an update to `version` needing `minimumOs` when given.
    package static func manifest(
        decision: String, version: String? = nil, minimumOs: String? = nil, title: String? = nil,
        message: String? = nil,
        maxAge: Int = 300
    ) -> String {
        var policy: [String: Any] = ["decision": decision]
        if let version {
            var update: [String: Any] = ["version": version, "storeUrl": "https://apps.apple.com/app/id123"]
            if let minimumOs { update["minimumOsVersion"] = minimumOs }
            policy["update"] = update
        }
        if let title, let message { policy["text"] = ["title": title, "message": message] }
        let manifest: [String: Any] = ["versionPolicy": policy, "maxAgeSeconds": maxAge]
        let data = (try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func answer(_ request: URLRequest) throws -> (Data, URLResponse) {
        let (offline, batchAnswer, manifestAnswer) = state.withLock { ($0.offline, $0.batchAnswer, $0.manifestAnswer) }
        if offline { throw URLError(.notConnectedToInternet) }
        guard let url = request.url else { throw URLError(.badURL) }
        if let authorization = request.value(forHTTPHeaderField: "Authorization") {
            state.withLock { _ = $0.authorizations.insert(authorization) }
        }
        let status: Int
        let body: String
        switch (request.httpMethod ?? "GET", url.path(percentEncoded: false)) {
        case ("POST", "/ingest/v1/app/batch"):
            guard let data = request.httpBody, let batch = try? Self.decoder.decode(AppBatch.self, from: data) else {
                (status, body) = (400, #"{"_tag":"HttpApiSchemaError","message":"Not a batch."}"#)
                break
            }
            (status, body) = batchAnswer(batch)
            state.withLock { state in
                state.attempts.append(batch)
                if (200..<300).contains(status) { state.batches.append(batch) }
            }
        case ("GET", "/ingest/v1/app/manifest"):
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
            state.withLock { $0.manifestQueries.append(query) }
            (status, body) = manifestAnswer
        default:
            (status, body) = (404, "")
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), response)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let instant = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return try instant.parse(text)
        }
        return decoder
    }()
}
