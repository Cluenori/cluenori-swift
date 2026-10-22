import Cluenori
import CluenoriIngest
import Foundation
import os

#if canImport(UIKit)
    import UIKit
#endif
#if canImport(MetricKit)
    import MetricKit
#endif

extension Cluenori {
    /// Measures the app's performance: each launch, from its process's start to the first frame and
    /// to `appReady()`; its memory each minute it is open, on memory warnings and as each session
    /// ends; and MetricKit's daily reports. Call it once, right after `start`.
    @MainActor
    public static func measurePerformance() {
        PerformanceMonitor.shared.start()
    }

    /// Says the app's first useful screen shows, such as the feed with its first page: the launch is
    /// timed to here as well as to its first frame. Only the first call of a launch counts; one more
    /// than 30 s after the first frame comes too late, and the launch is recorded without it.
    public static func appReady() {
        let at = Engine.shared.now
        Task { @MainActor in PerformanceMonitor.shared.ready(at: at) }
    }
}

/// Watches the app for its launch, its memory, and MetricKit's reports, and records them in the
/// sessions they belong to. One per process, on the main actor, where UIKit tells it what happens.
@MainActor
final class PerformanceMonitor {
    static let shared = PerformanceMonitor(engine: .shared)

    /// How long after the first frame the launch waits for `appReady()`.
    static let readyWait: Duration = .seconds(30)
    static let memoryInterval: Duration = .seconds(60)

    private let engine: Engine
    private let logger = Logger(subsystem: "com.cluenori.sdk", category: "performance")
    private var started = false
    private var observers: [any NSObjectProtocol] = []

    private let processStart = LaunchTiming.processStart()
    private let prewarmed = LaunchTiming.isPrewarmed
    private var launchedInBackground = false
    private var firstFrame: Date?
    private var readyAt: Date?
    private var launchRecorded = false
    private var readyTimeout: Task<Void, Never>?
    private var sampling: Task<Void, Never>?
    #if canImport(UIKit)
        private var frameWatch: FirstFrameWatch?
    #endif
    #if canImport(MetricKit)
        private var metricKit: MetricKitForwarding?
    #endif

    init(engine: Engine) {
        self.engine = engine
    }

    func start() {
        guard !started else {
            engine.misuse("Cluenori.measurePerformance was called more than once; the first call counts.")
            return
        }
        started = true
        #if canImport(MetricKit)
            let forwarding = MetricKitForwarding(engine: engine)
            MXMetricManager.shared.add(forwarding)
            metricKit = forwarding
        #endif
        #if canImport(UIKit)
            launchedInBackground = UIApplication.shared.applicationState == .background
            observers = [
                observe(UIApplication.didBecomeActiveNotification) { $0.becameActive() },
                observe(UIApplication.didEnterBackgroundNotification) { $0.wentToBackground() },
                observe(UIApplication.didReceiveMemoryWarningNotification) { $0.sampleMemory(.warning) },
            ]
            // Started after the app became active, the first activation already went by.
            if UIApplication.shared.applicationState == .active { becameActive() }
        #endif
    }

    /// Calls `action` on the main actor each time UIKit posts `name`.
    private func observe(_ name: Notification.Name, _ action: @escaping @MainActor (PerformanceMonitor) -> Void)
        -> any NSObjectProtocol
    {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
    }

    func ready(at moment: Date) {
        guard started, readyAt == nil, !launchRecorded else { return }
        readyAt = moment
        if firstFrame != nil { recordLaunch() }
    }

    private func becameActive() {
        logger.debug("The app became active.")
        #if canImport(UIKit)
            if firstFrame == nil && frameWatch == nil {
                frameWatch = FirstFrameWatch { [weak self] at in self?.drewFirstFrame(at: at) }
            }
        #endif
        guard sampling == nil else { return }
        sampling = Task { [weak self] in
            while !Task.isCancelled {
                guard (try? await Task.sleep(for: Self.memoryInterval)) != nil else { return }
                self?.sampleMemory(.interval)
            }
        }
    }

    private func wentToBackground() {
        sampling?.cancel()
        sampling = nil
        if firstFrame != nil && !launchRecorded { recordLaunch() }
        // The session's memory at its end is its memory as it left the foreground, recorded only
        // if the session ends before the app comes back.
        if let memory = MemoryFootprint.now() {
            engine.hold("memory.session_end") { stamp in
                .appMemory(Self.signal(stamp, .session_end, memory))
            }
        }
    }

    private func drewFirstFrame(at moment: Date) {
        logger.debug("The first frame was drawn.")
        #if canImport(UIKit)
            frameWatch = nil
        #endif
        guard firstFrame == nil else { return }
        firstFrame = moment
        if readyAt != nil {
            recordLaunch()
        } else {
            readyTimeout = Task { [weak self] in
                guard (try? await Task.sleep(for: Self.readyWait)) != nil else { return }
                self?.recordLaunch()
            }
        }
    }

    private func recordLaunch() {
        guard !launchRecorded, let processStart, let firstFrame else { return }
        launchRecorded = true
        readyTimeout?.cancel()
        guard
            let timing = LaunchTiming.measure(
                processStart: processStart, firstFrame: firstFrame, ready: readyAt, prewarmed: prewarmed,
                launchedInBackground: launchedInBackground)
        else {
            logger.notice("The launch isn't recorded: the clock moved back while it ran.")
            return
        }
        logger.debug("The launch took \(timing.firstFrameMs) ms to its first frame.")
        engine.record { stamp in
            .appLaunched(
                AppLaunched(
                    id: stamp.id, at: stamp.at, session: stamp.session, user: stamp.user, feature: stamp.feature,
                    start: timing.start, prewarmed: timing.prewarmed, firstFrameMs: timing.firstFrameMs,
                    readyMs: timing.readyMs))
        }
    }

    private func sampleMemory(_ reason: MemoryReason) {
        guard let memory = MemoryFootprint.now() else { return }
        engine.record { stamp in .appMemory(Self.signal(stamp, reason, memory)) }
    }

    private nonisolated static func signal(_ stamp: SignalStamp, _ reason: MemoryReason, _ memory: MemoryFootprint)
        -> AppMemory
    {
        AppMemory(
            id: stamp.id, at: stamp.at, session: stamp.session, user: stamp.user, feature: stamp.feature,
            reason: reason, footprintBytes: memory.footprintBytes, peakBytes: memory.peakBytes)
    }
}

#if canImport(UIKit)
    /// Waits for the next frame the screen draws, once, and says when: after the app's first
    /// activation, that is its first frame.
    @MainActor
    private final class FirstFrameWatch: NSObject {
        private var link: CADisplayLink?
        private let drew: @MainActor (Date) -> Void

        init(drew: @escaping @MainActor (Date) -> Void) {
            self.drew = drew
            super.init()
            let link = CADisplayLink(target: self, selector: #selector(frame))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func frame() {
            let moment = Engine.shared.now
            link?.invalidate()
            link = nil
            drew(moment)
        }
    }
#endif
