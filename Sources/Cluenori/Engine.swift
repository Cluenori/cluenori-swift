import CluenoriIngest
import Foundation
import Synchronization
import os

/// What the engine needs from the world, so tests give it a fake deployment, clock and folder.
package struct Dependencies: Sendable {
    package var folder: Folder
    /// How requests reach the deployment; `URLSession.shared` when nil.
    package var transport: CluenoriIngestAPI.Transport?
    package var now: @Sendable () -> Date
    /// Waits, as `Task.sleep` does, throwing when cancelled.
    package var wait: @Sendable (Duration) async throws -> Void
    /// A number from 0 to 1, for spreading retries.
    package var random: @Sendable () -> Double
    package var ids: IDMaker
    /// The app's release, `0.3.0+20`; nil when its Info.plist has none.
    package var release: String?
    package var device: @Sendable () -> AppDevice
    package var locale: String
    package var osVersion: OperatingSystemVersion
    /// Whether the engine keeps its own time: sending every 30 s and when enough waits, and the
    /// session's ticks. Tests turn it off and call `flush()` and `tick()`.
    package var schedules: Bool
    package var misuse: Misuse

    package static func live() -> Dependencies {
        Dependencies(
            // A folder of the app's own: on iOS the container is the app's, and a Mac app outside
            // the sandbox shares Application Support with every other app.
            folder: Folder(
                url: URL.applicationSupportDirectory.appending(path: "Cluenori", directoryHint: .isDirectory)
                    .appending(path: Bundle.main.bundleIdentifier ?? "app", directoryHint: .isDirectory)),
            transport: nil,
            now: { Date() },
            wait: { try await Task.sleep(for: $0) },
            random: { Double.random(in: 0...1) },
            ids: IDMaker(),
            release: ThisDevice.release(),
            device: { ThisDevice.device() },
            locale: ThisDevice.locale(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersion,
            schedules: true,
            misuse: .live)
    }

    package init(
        folder: Folder, transport: CluenoriIngestAPI.Transport?, now: @escaping @Sendable () -> Date,
        wait: @escaping @Sendable (Duration) async throws -> Void, random: @escaping @Sendable () -> Double,
        ids: IDMaker, release: String?, device: @escaping @Sendable () -> AppDevice, locale: String,
        osVersion: OperatingSystemVersion, schedules: Bool, misuse: Misuse
    ) {
        self.folder = folder
        self.transport = transport
        self.now = now
        self.wait = wait
        self.random = random
        self.ids = ids
        self.release = release
        self.device = device
        self.locale = locale
        self.osVersion = osVersion
        self.schedules = schedules
        self.misuse = misuse
    }
}

/// Where the SDK sends, and as which component and environment.
package struct Configuration: Sendable {
    package let key: String
    package let environment: String
    package let deployment: URL

    package init(key: String, environment: String, deployment: URL) {
        self.key = key
        self.environment = environment
        self.deployment = deployment
    }
}

/// The SDK at work: takes the app's calls without blocking it, and puts them in order through the
/// recorder, while delivery, the manifest and the update gate run beside it. One per process in an
/// app (`shared`); tests make their own.
///
/// Calls made before `start` wait for it and are recorded once it has. Only signals are bounded: past
/// 1,000 waiting, a new one is dropped; a control call, such as `reset` or a consent, is never
/// dropped.
package final class Engine: Sendable {
    package static let shared = Engine(dependencies: .live())

    package let dependencies: Dependencies
    let features = Features()
    package let screens = Screens()
    @MainActor package let gate: UpdateGate

    /// The parts made by `start`, once there.
    private struct Parts {
        let recorder: Recorder
        let delivery: Delivery
        let manifests: Manifests
    }

    private struct Running {
        var parts: Parts?
        var tasks: [Task<Void, Never>] = []
        /// A pause of the delivery loop that a nudge may end early.
        var pause: Task<Void, any Error>?
        /// The tick 30 s after the app went to the background.
        var backgroundTick: Task<Void, Never>?
        /// A nudge that came while the delivery loop wasn't pausing: its next pause is skipped.
        var nudged = false
    }

    private let inbox: AsyncStream<Command>
    private let continuation: AsyncStream<Command>.Continuation
    private let running = Mutex<Running?>(nil)
    private let ready = Mutex<[CheckedContinuation<Void, Never>]?>([])
    /// Signals given to the inbox and not yet recorded: what bounds the memory waiting calls take.
    private let waitingSignals = Atomic<Int>(0)
    static let waitingSignalsLimit = 1_000
    private let logger = Logger(subsystem: "com.cluenori.sdk", category: "engine")

    package static let sdk = AppSdk(name: "cluenori-swift", version: "0.2.0")

    package init(dependencies: Dependencies) {
        self.dependencies = dependencies
        (inbox, continuation) = AsyncStream.makeStream(of: Command.self, bufferingPolicy: .unbounded)
        gate = UpdateGate(osVersion: dependencies.osVersion, now: dependencies.now)
    }

    /// The app's release, for the version header.
    package var release: String? { dependencies.release }

    package var misuse: Misuse { dependencies.misuse }

    package var now: Date { dependencies.now() }

    /// The feature in effect where this is called.
    package var currentFeature: String? { features.current }

    // MARK: - Starting

    /// Starts recording and sending to `configuration`'s deployment. Returns at once: files are read,
    /// and the deployment asked, off the calling thread. A second call does nothing.
    package func start(_ configuration: Configuration) {
        guard let release = dependencies.release else {
            misuse(
                "The app's Info.plist needs CFBundleShortVersionString and CFBundleVersion, which name its release; Cluenori doesn't start without them."
            )
            return
        }
        guard Self.isDeploymentURL(configuration.deployment) else {
            misuse(
                "\(configuration.deployment) isn't a deployment's address: an https URL, or http on this Mac or its local network."
            )
            return
        }
        guard TextRules.isEnvironmentKey(configuration.environment) else {
            misuse(
                "\"\(configuration.environment)\" isn't an environment: lowercase letters, digits and single hyphens, such as production."
            )
            return
        }
        guard !configuration.key.isEmpty, configuration.key.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
            misuse("The SDK key is empty, or has characters a key doesn't.")
            return
        }
        let first = running.withLock { running in
            guard running == nil else { return false }
            running = Running()
            return true
        }
        guard first else {
            misuse("Cluenori.start was called more than once; the first call counts.")
            return
        }
        let task = Task { await run(configuration, release: release) }
        running.withLock { $0?.tasks.append(task) }
    }

    private func run(_ configuration: Configuration, release: String) async {
        let folder = dependencies.folder
        let queue = SignalQueue(folder: folder.file("queue"))
        let recorder = Recorder(
            folder: folder, queue: queue, ids: dependencies.ids, key: configuration.key, release: release,
            environment: configuration.environment)
        // Before the first unlock after a restart, an app launched in the background can't read its
        // files; it waits until it can, rather than start from nothing.
        var booted = await recorder.boot(at: dependencies.now())
        while booted == nil {
            logger.notice("Cluenori's files can't be read yet; it tries again in 10 s.")
            guard (try? await dependencies.wait(.seconds(10))) != nil else { return }
            booted = await recorder.boot(at: dependencies.now())
        }
        guard let boot = booted else { return }
        let client = CluenoriIngestAPI(
            baseURL: configuration.deployment, bearerToken: configuration.key,
            userAgent: "\(Self.sdk.name)/\(Self.sdk.version)", transport: dependencies.transport)
        let gate = self.gate
        let manifests = Manifests(
            folder: folder, client: client, release: release, environment: configuration.environment,
            locale: dependencies.locale, now: dependencies.now,
            show: { manifest in await MainActor.run { gate.show(manifest?.versionPolicy) } })
        let continuation = self.continuation
        let delivery = Delivery(
            queue: queue, client: client,
            origin: BatchOrigin(installation: boot.installation, device: dependencies.device(), sdk: Self.sdk),
            stopped: boot.rejected, now: dependencies.now, random: dependencies.random,
            keyRejected: {
                continuation.yield(.keyRejected)
                await manifests.stop()
            })
        await MainActor.run {
            gate.restore(boot.closedPrompts)
            gate.keepClosed = { continuation.yield(.closePrompt($0)) }
        }
        await manifests.showKept()
        if boot.rejected {
            await manifests.stop()
        } else {
            await manifests.beginRefresh()
        }
        running.withLock { $0?.parts = Parts(recorder: recorder, delivery: delivery, manifests: manifests) }
        if dependencies.schedules {
            let loop = Task { await deliver(delivery) }
            let ticks = Task { await tickEveryMinute() }
            running.withLock { $0?.tasks += [loop, ticks] }
        }
        for continuation in ready.withLock({ waiting in
            defer { waiting = nil }; return waiting ?? []
        }) {
            continuation.resume()
        }
        for await command in inbox {
            let nudge = await recorder.handle(command)
            switch command {
            case .record, .recordUnscoped, .hold: waitingSignals.subtract(1, ordering: .relaxed)
            default: break
            }
            if case .lifecycle(let event) = command {
                switch event {
                case .foreground:
                    await manifests.beginRefresh()
                    await MainActor.run { gate.resume() }
                    self.nudge()
                case .background:
                    self.nudge()
                    scheduleBackgroundTick()
                case .tick, .launch, .end:
                    break
                }
            }
            if nudge { self.nudge() }
        }
    }

    // An https deployment, or http on this Mac or its local network, for `./run` while developing.
    static func isDeploymentURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host(percentEncoded: false)?.lowercased() else {
            return false
        }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = labels.compactMap { UInt8($0) }
        guard labels.count == 4, octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    // MARK: - Taking the app's calls

    func send(_ command: Command) {
        continuation.yield(command)
    }

    /// Hands a signal to the inbox, unless 1,000 already wait, as when the recorder is far behind or
    /// `start` was never called: then it is dropped, and the calls before it stay.
    private func sendSignal(_ command: Command) {
        let (_, waiting) = waitingSignals.add(1, ordering: .relaxed)
        guard waiting <= Self.waitingSignalsLimit else {
            waitingSignals.subtract(1, ordering: .relaxed)
            logger.notice("A signal is dropped: 1,000 wait to be recorded.")
            return
        }
        continuation.yield(command)
    }

    /// Records a signal of the session open now, stamped in the order of the app's calls. Without a
    /// session, as when the app was launched in the background, it is dropped.
    package func record(_ build: @escaping SignalBuilder) {
        sendSignal(
            .record(at: dependencies.now(), feature: features.current, screen: screens.current?.name, build: build))
    }

    /// Records a signal of no session, such as MetricKit's report.
    package func recordUnscoped(_ build: @escaping @Sendable (_ id: String, _ at: Date) -> AppSignal) {
        sendSignal(.recordUnscoped(at: dependencies.now(), build: build))
    }

    /// Keeps a signal of the session open now, to record when it ends; a later one for `key`
    /// replaces it.
    package func hold(_ key: String, _ build: @escaping SignalBuilder) {
        sendSignal(
            .hold(
                key: key, at: dependencies.now(), feature: features.current, screen: screens.current?.name, build: build
            ))
    }

    func foreground() { send(.lifecycle(.foreground(dependencies.now()))) }
    func background() { send(.lifecycle(.background(dependencies.now()))) }
    func tick() { send(.lifecycle(.tick(dependencies.now()))) }

    func identify(_ user: String) {
        guard TextRules.isUserID(user) else {
            misuse(
                "\"\(user)\" isn't a user ID: 1 to 128 printable ASCII characters without spaces, the app's own opaque ID, never an email."
            )
            return
        }
        send(.identify(user))
    }

    /// The person signed out: the session ends and the next starts. The screen in sight ends its visit
    /// in the session that ends, and goes on as a new visit in the next.
    // Not handled: a reset while the app is in the background, which signing out isn't; the visit's
    // measures then go on into the next session, which takes the screens knowing the foreground.
    func reset() {
        let visit = screens.current.map { newVisit(of: $0.name) }
        if let visit { _ = screens.show(visit) }
        send(.reset(at: dependencies.now()))
        if let visit { recordShown(visit) }
    }

    func consent(_ analytics: AnalyticsConsent) { send(.consent(analytics, at: dependencies.now())) }

    /// Marks `key` the screens' feature until the mark ends; an invalid key marks nothing.
    func begin(feature key: String) -> FeatureMark {
        guard TextRules.isFeatureKey(key) else {
            misuse("\"\(key)\" isn't a feature key: keys joined by dots, such as cards.flip.")
            return FeatureMark(features: nil, mark: 0)
        }
        return FeatureMark(features: features, mark: features.begin(key))
    }

    /// Runs `operation` in feature `key`; an invalid key runs it in the feature around it.
    func feature<Result>(_ key: String, _ operation: () throws -> Result) rethrows -> Result {
        guard TextRules.isFeatureKey(key) else {
            misuse("\"\(key)\" isn't a feature key: keys joined by dots, such as cards.flip.")
            return try operation()
        }
        return try Features.$working.withValue(key, operation: operation)
    }

    func feature<Result>(_ key: String, _ operation: () async throws -> Result) async rethrows -> Result {
        guard TextRules.isFeatureKey(key) else {
            misuse("\"\(key)\" isn't a feature key: keys joined by dots, such as cards.flip.")
            return try await operation()
        }
        return try await Features.$working.withValue(key, operation: operation)
    }

    /// Headers for a request to the app's own API (`RequestHeaders`).
    func requestHeaders(existing: [String: String] = [:]) -> [String: String] {
        RequestHeaders.headers(release: release, feature: features.current, existing: existing)
    }

    // MARK: - Sending

    /// Takes every call made so far, then sends what waits, as far as the rules allow now. For the
    /// app going to the background, and for tests, which drive the engine by it.
    package func flush() async {
        guard running.withLock({ $0 != nil }) else { return }
        await whenStarted()
        await withCheckedContinuation { send(.barrier($0)) }
        guard let parts = running.withLock({ $0?.parts }) else { return }
        await parts.manifests.idle()
        for _ in 0..<50 {
            guard case .sent(more: true) = await parts.delivery.deliverOnce() else { return }
        }
    }

    /// Waits until `start` has read what the last process left; at once when it has.
    private func whenStarted() async {
        await withCheckedContinuation { continuation in
            let resumeNow = ready.withLock { waiting -> Bool in
                guard waiting != nil else { return true }
                waiting?.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Sends while there is something to send, then waits 30 s, or less when nudged; waits as long
    /// as delivery says after a failure or a 429, which no nudge shortens.
    private func deliver(_ delivery: Delivery) async {
        while !Task.isCancelled {
            let pause: Duration
            let nudgeable: Bool
            switch await delivery.deliverOnce() {
            case .sent(more: true):
                continue
            case .idle, .sent(more: false):
                (pause, nudgeable) = (.seconds(30), true)
            case .wait(let duration):
                (pause, nudgeable) = (duration, false)
            case .stopped:
                return
            }
            if nudgeable && takeNudge() { continue }
            let wait = dependencies.wait
            let sleeper = Task { try await wait(pause) }
            if nudgeable { running.withLock { $0?.pause = sleeper } }
            await withTaskCancellationHandler {
                _ = await sleeper.result
            } onCancel: {
                sleeper.cancel()
            }
            running.withLock { $0?.pause = nil }
        }
    }

    /// Ends the delivery loop's idle pause, so what waits is sent now.
    private func nudge() {
        running.withLock { running in
            running?.nudged = true
            running?.pause?.cancel()
        }
    }

    /// Whether a nudge came since the last pause, forgetting it.
    private func takeNudge() -> Bool {
        running.withLock { running in
            defer { running?.nudged = false }
            return running?.nudged ?? false
        }
    }

    private func tickEveryMinute() async {
        while !Task.isCancelled {
            do {
                try await dependencies.wait(.seconds(60))
            } catch {
                return
            }
            tick()
        }
    }

    /// Ticks just after a session in the background reaches 30 s, for an app that keeps running
    /// there, so its session ends on time.
    private func scheduleBackgroundTick() {
        guard dependencies.schedules else { return }
        let wait = dependencies.wait
        let tick = Task { [weak self] in
            guard (try? await wait(.seconds(sessionTimeout + 1))) != nil else { return }
            self?.tick()
        }
        running.withLock { running in
            running?.backgroundTick?.cancel()
            running?.backgroundTick = tick
        }
    }

    /// Marks screen `name` shown now, a new visit of it: tells the screens' observers, then records
    /// its `screen` signal. Nil, with what is wrong said, for a name that isn't one.
    @discardableResult
    package func show(screen name: String) -> ScreenVisit? {
        guard TextRules.isName(name) else {
            misuse("\"\(name)\" isn't a screen's name: 1 to 256 characters, such as profile.edit.")
            return nil
        }
        let visit = screens.show(newVisit(of: name))
        recordShown(visit)
        return visit
    }

    private func newVisit(of name: String) -> ScreenVisit {
        let now = dependencies.now()
        return ScreenVisit(id: dependencies.ids.make(at: now), name: name, appearedAt: now)
    }

    /// The `screen` signal of `visit`, whose ID is the visit's.
    private func recordShown(_ visit: ScreenVisit) {
        record { stamp in
            .screen(
                ScreenShown(
                    id: visit.id, at: stamp.at, session: stamp.session, user: stamp.user, feature: stamp.feature,
                    screen: visit.name))
        }
    }

    /// Cancels the engine's work, for tests that are done with it.
    package func stop() {
        continuation.finish()
        running.withLock { running in
            running?.tasks.forEach { $0.cancel() }
            running?.backgroundTick?.cancel()
            running?.pause?.cancel()
        }
    }
}
