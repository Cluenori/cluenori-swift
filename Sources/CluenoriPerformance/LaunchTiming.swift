import CluenoriIngest
import Darwin
import Foundation

/// One launch, timed from when its process started: to the first frame drawn, and to the app's first
/// useful screen, when it says so with `appReady()`.
struct LaunchTiming: Equatable, Sendable {
    let start: LaunchStart
    let prewarmed: Bool
    let firstFrameMs: Double
    let readyMs: Double?

    /// The launch's times from its moments. `cold` from nothing; `warm` when the process was there
    /// before the person opened the app, prewarmed by iOS or launched in the background, so its
    /// times aren't comparable with a cold launch's. Nil when the clock moved back meanwhile.
    static func measure(
        processStart: Date, firstFrame: Date, ready: Date?, prewarmed: Bool, launchedInBackground: Bool
    ) -> LaunchTiming? {
        let firstFrameMs = firstFrame.timeIntervalSince(processStart) * 1000
        // Not handled: a clock set back during the launch; such a launch isn't recorded.
        guard firstFrameMs >= 0 else { return nil }
        var readyMs: Double?
        if let ready {
            let milliseconds = ready.timeIntervalSince(processStart) * 1000
            if milliseconds >= 0 { readyMs = milliseconds.rounded() }
        }
        return LaunchTiming(
            start: prewarmed || launchedInBackground ? .warm : .cold, prewarmed: prewarmed,
            firstFrameMs: firstFrameMs.rounded(), readyMs: readyMs)
    }

    /// When this process started, from the kernel: `kp_proc.p_starttime`.
    static func processStart() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    /// Whether iOS prewarmed this process before the person opened the app.
    static var isPrewarmed: Bool {
        ProcessInfo.processInfo.environment["ActivePrewarm"] == "1"
    }
}
