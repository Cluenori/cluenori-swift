import Cluenori
import CluenoriIngest
import Foundation
import os

#if canImport(MetricKit)
    import MetricKit

    /// Hands MetricKit's reports to the queue as they arrive, as their JSON: daily metrics (launch
    /// times, hangs, memory, CPU, disk writes, battery) and diagnostics (crashes, hangs, CPU and disk
    /// exceptions). iOS delivers them when it likes, about once a day, on a queue of its own.
    final class MetricKitForwarding: NSObject, MXMetricManagerSubscriber, Sendable {
        private let engine: Engine
        private let logger = Logger(subsystem: "com.cluenori.sdk", category: "metrickit")

        init(engine: Engine) {
            self.engine = engine
        }

        func didReceive(_ payloads: [MXMetricPayload]) {
            for payload in payloads { forward(payload.jsonRepresentation(), as: .metrics) }
        }

        func didReceive(_ payloads: [MXDiagnosticPayload]) {
            for payload in payloads { forward(payload.jsonRepresentation(), as: .diagnostics) }
        }

        private func forward(_ json: Data, as kind: MetricKitKind) {
            guard let payload = try? JSONDecoder().decode(JSONValue.self, from: json) else {
                logger.error("A MetricKit report couldn't be read, and isn't sent.")
                return
            }
            engine.recordUnscoped { id, at in
                .metrickit(MetricKitReport(id: id, at: at, report: kind, payload: payload))
            }
        }
    }
#endif
