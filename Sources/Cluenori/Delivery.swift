import CluenoriIngest
import Foundation
import os

/// What a batch says about where its signals came from, beside the release and environment each
/// signal was recorded in.
struct BatchOrigin: Sendable {
    let installation: String
    let device: AppDevice
    let sdk: AppSdk
}

/// Sends the queue to the deployment, oldest first, one batch at a time, and owns every rule about
/// when it may: a refused key stops sending for good, 429 waits as long as the deployment says,
/// failures back off, and a body too big is split. Whoever asks it to deliver, its own schedule or
/// the app going to the background, gets the same rules.
actor Delivery {
    /// What one delivery did, and so when to try again.
    enum Outcome: Equatable, Sendable {
        /// Nothing waits to be sent.
        case idle
        /// A batch was sent, split in two to send again at once, or refused and dropped; `more` when
        /// signals wait.
        case sent(more: Bool)
        /// Nothing more until then: the deployment asked to wait, or a failure backs off.
        case wait(Duration)
        /// The key was refused: nothing more is sent until the app is updated.
        case stopped
    }

    static let signalsPerBatch = 500
    /// Below the 1 MB the deployment takes, for the JSON around the signals.
    static let batchBytes = 800_000

    private let queue: SignalQueue
    private let client: CluenoriIngestAPI
    private let origin: BatchOrigin
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    /// Told once, when the deployment refuses the key.
    private let keyRejected: @Sendable () async -> Void
    private let logger = Logger(subsystem: "com.cluenori.sdk", category: "delivery")

    private var stopped: Bool
    private var notBefore: Date?
    private var failures = 0
    /// The most signals a batch may have now: halved by each 413, whole again once the queue empties.
    private var limit = signalsPerBatch
    private var inFlight: Task<Outcome, Never>?

    init(
        queue: SignalQueue, client: CluenoriIngestAPI, origin: BatchOrigin, stopped: Bool,
        now: @escaping @Sendable () -> Date, random: @escaping @Sendable () -> Double,
        keyRejected: @escaping @Sendable () async -> Void
    ) {
        self.queue = queue
        self.client = client
        self.origin = origin
        self.stopped = stopped
        self.now = now
        self.random = random
        self.keyRejected = keyRejected
    }

    /// Sends the oldest batch, if it may now. A call while one is under way waits for that one.
    func deliverOnce() async -> Outcome {
        if let inFlight { return await inFlight.value }
        let task = Task { await attempt() }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        return outcome
    }

    /// Stops sending, as when consent is withdrawn and the queue dropped meanwhile: nothing changes
    /// but what an attempt under way finds.
    func stop() {
        stopped = true
    }

    private func attempt() async -> Outcome {
        guard !stopped else { return .stopped }
        let moment = now()
        if let notBefore, moment < notBefore {
            return .wait(.seconds(notBefore.timeIntervalSince(moment)))
        }
        guard let batch = await queue.head(limit: limit, maxBytes: Self.batchBytes) else {
            limit = Self.signalsPerBatch
            return .idle
        }
        guard !batch.signals.isEmpty else {
            await queue.remove(batch)
            return .sent(more: !(await queue.isEmpty))
        }
        let body = AppBatch(
            installation: origin.installation, environment: batch.environment, release: batch.release,
            device: origin.device, sdk: origin.sdk, sentAt: moment, signals: batch.signals)
        do {
            let accepted = try await client.sendBatch(body)
            logger.debug("Sent \(accepted.accepted) signals, \(accepted.duplicates) of them again.")
            failures = 0
            notBefore = nil
            // After a split, batches grow back as they get through.
            limit = min(Self.signalsPerBatch, limit * 2)
            await queue.remove(batch)
            return .sent(more: !(await queue.isEmpty))
        } catch {
            return await failed(error, batch: batch)
        }
    }

    private func failed(_ error: APIError, batch: SignalQueue.Batch) async -> Outcome {
        switch error {
        case .sdkKeyRejected:
            logger.error("The deployment refused the SDK key: nothing more is sent until the app is updated.")
            stopped = true
            await keyRejected()
            return .stopped
        case .tooManySignals(let tooMany):
            return wait(.seconds(Double(tooMany.retryAfterSeconds)))
        case .unreadable(status: 413, _), .unreadable(status: 400, _), .unreadable(status: 422, _), .unwritable:
            // Too big, or refused as it is: sent in halves, and a signal refused alone is dropped.
            if batch.lines > 1 {
                limit = max(1, batch.lines / 2)
                return .sent(more: true)
            }
            logger.error(
                "The deployment refused a signal (\(String(describing: error), privacy: .public)); it is dropped.")
            limit = Self.signalsPerBatch
            await queue.remove(batch)
            return .sent(more: !(await queue.isEmpty))
        case .unreachable, .unreadable:
            // No answer, a server's failure, a 429 without its wait, or a 401 without the
            // deployment's word for a refused key, such as a captive portal's: tried again later.
            return backOff()
        }
    }

    private func wait(_ duration: Duration) -> Outcome {
        notBefore = now().addingTimeInterval(duration.seconds)
        return .wait(duration)
    }

    /// 5 s after the first failure, doubling to 15 minutes, each between half and all of that, so
    /// installations that failed together don't come back together.
    private func backOff() -> Outcome {
        failures += 1
        return wait(.seconds(Self.backOff(failures: failures, random: random())))
    }

    static func backOff(failures: Int, random: Double) -> TimeInterval {
        let ceiling = min(900, 5 * pow(2, Double(min(failures, 20) - 1)))
        return ceiling * (0.5 + 0.5 * min(max(random, 0), 1))
    }
}

extension Duration {
    /// The duration in seconds, as a `TimeInterval`.
    var seconds: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
