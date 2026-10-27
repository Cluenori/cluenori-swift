import Foundation

/// The headers the SDK adds to the app's requests to its own API, so the API and the jobs it starts
/// belong to the same feature and release as the screen that asked (concept/Foundation.md,
/// "Features: one filter across everything"):
/// - `Cluenori-Release`: the app's release, `0.3.0+20`, by which the API can enforce the version
///   policy;
/// - `traceparent`: a new W3C trace for each request, unless the request has one;
/// - `baggage`: `cluenori.feature`, the feature in effect, `cluenori.origin.component`, the component
///   the SDK key names, and `cluenori.origin.release`, the app's release, after any baggage the
///   request has: the web SDK's keys, in its order (sdks/web/src/request-headers.ts), so a backend
///   can split its work by the client that called it.
///
/// Add them to requests to your own API alone: a third party, such as a payment provider, has no use
/// for them.
enum RequestHeaders {
    static let release = "Cluenori-Release"
    static let traceparent = "traceparent"
    static let baggage = "baggage"
    static let featureKey = "cluenori.feature"
    static let originComponentKey = "cluenori.origin.component"
    static let originReleaseKey = "cluenori.origin.release"

    /// The headers for one request, with a new trace, merged into `existing` ones.
    static func headers(
        release: String?, component: String? = nil, feature: String?, existing: [String: String] = [:],
        random: () -> UInt64 = { UInt64.random(in: .min ... .max) }
    ) -> [String: String] {
        var headers: [String: String] = [:]
        if let release { headers[Self.release] = release }
        if value(Self.traceparent, in: existing) == nil {
            headers[Self.traceparent] = traceparent(random: random)
        }
        var entries: [(String, String)] = []
        if let feature { entries.append((featureKey, feature)) }
        if let component { entries.append((originComponentKey, component)) }
        if let release { entries.append((originReleaseKey, release)) }
        if !entries.isEmpty {
            let ours = Set(entries.map(\.0))
            // The request's own entries stay, but for ours, which this request's state replaces.
            let kept = (value(Self.baggage, in: existing) ?? "").split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { entry in
                guard !entry.isEmpty else { return false }
                let key = entry.split(separator: "=", maxSplits: 1).first.map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                return !ours.contains(key ?? "")
            }
            headers[Self.baggage] = (kept + entries.map { "\($0.0)=\(encoded($0.1))" }).joined(separator: ",")
        }
        return headers
    }

    /// `00-<trace ID>-<span ID>-01`: a sampled trace that starts at this request.
    static func traceparent(random: () -> UInt64) -> String {
        var traceHigh = random()
        let traceLow = random()
        if traceHigh == 0 && traceLow == 0 { traceHigh = 1 }  // An ID of zeros is invalid.
        var span = random()
        if span == 0 { span = 1 }
        return "00-\(hex(traceHigh))\(hex(traceLow))-\(hex(span))-01"
    }

    private static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    /// A header's value by name, whatever its case.
    private static func value(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    // A baggage value: what isn't a baggage octet, percent-encoded (W3C Baggage, "value").
    private static func encoded(_ value: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: Unicode.Scalar(0x21)...Unicode.Scalar(0x7e))
        allowed.remove(charactersIn: "\",;\\%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

extension URLRequest {
    /// Adds Cluenori's headers for a request to your own API: the app's release, a new trace, and the
    /// feature in effect, the component and its release as baggage. Keeps a `traceparent` the request has, and its other baggage.
    public mutating func addCluenoriHeaders() {
        let headers = Engine.shared.requestHeaders(existing: allHTTPHeaderFields ?? [:])
        for (name, value) in headers {
            setValue(value, forHTTPHeaderField: name)
        }
    }
}
