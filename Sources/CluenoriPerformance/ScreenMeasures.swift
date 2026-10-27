import Cluenori
import CluenoriIngest
import Darwin
import Foundation
import Synchronization

/// How a screen's content came, for `Cluenori.screenReady(_:)`.
public enum ScreenReadiness: Sendable {
    /// Drawn from what the device kept, such as a cache or a database: what the person sees at once.
    case kept
    /// Brought up to date from the network.
    case fresh

    var content: ScreenContent {
        switch self {
        case .kept: .kept
        case .fresh: .fresh
        }
    }
}

/// One screen's visit as it is measured: how long it showed with the app in the foreground, the CPU
/// time the process used meanwhile, how long the person scrolled and how much of that frames came
/// late, and which readiness it said. Pure, so each rule is tested with the times given.
struct VisitMeasure: Equatable, Sendable {
    let visit: ScreenVisit
    /// The process's CPU time as the visit began, in ms; nil where it can't be read.
    let cpuAtStart: Double?
    /// Whether this platform measures scrolling: iOS's, where scroll views track touches.
    let measuresScrolling: Bool
    var visibleMs: Double = 0
    var visibleSince: Date?
    var scrollMs: Double = 0
    var hitchMs: Double = 0
    var ready: Set<ScreenContent> = []

    init(visit: ScreenVisit, at moment: Date, cpu: Double?, inForeground: Bool, measuresScrolling: Bool) {
        self.visit = visit
        cpuAtStart = cpu
        self.measuresScrolling = measuresScrolling
        visibleSince = inForeground ? moment : nil
    }

    mutating func hide(at moment: Date) {
        guard let since = visibleSince else { return }
        visibleMs += max(0, moment.timeIntervalSince(since) * 1000)
        visibleSince = nil
    }

    mutating func show(at moment: Date) {
        if visibleSince == nil { visibleSince = moment }
    }

    /// A frame drawn while scrolling, `interval` ms after the one before, when it was due after
    /// `expected` ms: its delay beyond that is a hitch.
    mutating func scrolled(interval: Double, expected: Double) {
        guard interval > 0, expected > 0 else { return }
        scrollMs += interval
        hitchMs += max(0, interval - expected)
    }

    /// The first time this visit says `content` is ready: how long after it appeared; nil after that.
    mutating func readied(_ content: ScreenContent, at moment: Date) -> Double? {
        guard ready.insert(content).inserted else { return nil }
        return max(0, (moment.timeIntervalSince(visit.appearedAt) * 1000).rounded())
    }

    /// The visit's measures as of `moment`, the process's CPU time being `cpu` ms then.
    func left(_ stamp: SignalStamp, at moment: Date, cpu: Double?) -> ScreenLeft {
        var visible = visibleMs
        if let since = visibleSince { visible += max(0, moment.timeIntervalSince(since) * 1000) }
        var cpuMs: Double?
        if let cpuAtStart, let cpu { cpuMs = max(0, (cpu - cpuAtStart).rounded()) }
        return ScreenLeft(
            id: stamp.id, at: stamp.at, session: stamp.session, user: stamp.user, feature: stamp.feature,
            screen: visit.name, visit: visit.id, visibleMs: visible.rounded(), cpuMs: cpuMs,
            scrollMs: measuresScrolling ? scrollMs.rounded() : nil, hitchMs: measuresScrolling ? hitchMs.rounded() : nil
        )
    }

    /// The CPU time the process used so far, user and system, in ms, from `getrusage`.
    static func processCPU() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let user = Double(usage.ru_utime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec) / 1000
        let system = Double(usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_stime.tv_usec) / 1000
        return user + system
    }
}

/// The visit of the screen shown now, as it is measured, from any thread. A screen shown ends the
/// visit before it, recorded then, on the thread that showed it, so its `screen.left` comes before
/// any signal recorded after the change: a reset's end of session included. Changes come in the
/// order the screens were shown (Screens).
final class ScreenVisits: Sendable {
    private struct State {
        /// Nil before the first screen, or once its session ended.
        var measure: VisitMeasure?
        var inForeground: Bool
    }

    private let state: Mutex<State>
    private let engine: Engine
    /// Whether this platform measures scrolling: iOS's, where scroll views track touches.
    private let measuresScrolling: Bool

    init(engine: Engine, inForeground: Bool, measuresScrolling: Bool) {
        self.engine = engine
        self.measuresScrolling = measuresScrolling
        state = Mutex(State(inForeground: inForeground))
    }

    /// The visit as measured now.
    var measure: VisitMeasure? { state.withLock { $0.measure } }

    /// `shown` appeared: `left`, the visit before it, is recorded with its measures, and `shown`'s
    /// begins. In the background, where a session's last visit is held for its end, the new visit is
    /// held in its place, so the one recorded now isn't recorded again.
    func shown(left: ScreenVisit?, shown: ScreenVisit) {
        let moment = shown.appearedAt
        let cpu = VisitMeasure.processCPU()
        let measuresScrolling = self.measuresScrolling
        let (ended, begun, inForeground) = state.withLock { state in
            let ended = state.measure.flatMap { $0.visit == left ? $0 : nil }
            let begun = VisitMeasure(
                visit: shown, at: moment, cpu: cpu, inForeground: state.inForeground,
                measuresScrolling: measuresScrolling)
            state.measure = begun
            return (ended, begun, state.inForeground)
        }
        if let ended {
            engine.record { stamp in .screenLeft(ended.left(stamp, at: moment, cpu: cpu)) }
        }
        if !inForeground {
            engine.hold("screen.left") { stamp in .screenLeft(begun.left(stamp, at: moment, cpu: cpu)) }
        }
    }

    /// `visit`'s content of this kind shows: how long after it appeared, the first time; nil after
    /// that, or once another visit began.
    func readied(_ content: ScreenContent, of visit: ScreenVisit, at moment: Date) -> Double? {
        state.withLock { state in
            guard state.measure?.visit == visit else { return nil }
            return state.measure?.readied(content, at: moment)
        }
    }

    func scrolled(interval: Double, expected: Double) {
        state.withLock { $0.measure?.scrolled(interval: interval, expected: expected) }
    }

    /// The app came to the foreground: the visit goes on, unless its session ended meanwhile.
    func cameToForeground(at moment: Date, sessionEnded: Bool) {
        state.withLock { state in
            state.inForeground = true
            // Not handled: a screen still shown in the session after; it is measured again from the
            // next screen shown, which takes recording a new visit of it.
            if sessionEnded { state.measure = nil }
            state.measure?.show(at: moment)
        }
    }

    /// The app left the foreground: the visit as it is now is held, recorded if its session ends.
    func leftForeground(at moment: Date) {
        let cpu = VisitMeasure.processCPU()
        let held: VisitMeasure? = state.withLock { state in
            state.inForeground = false
            state.measure?.hide(at: moment)
            return state.measure
        }
        guard let held else { return }
        engine.hold("screen.left") { stamp in .screenLeft(held.left(stamp, at: moment, cpu: cpu)) }
    }
}

/// Watches the main thread from another, while the app is in the foreground: every 100 ms it asks the
/// main thread to answer, and an answer 250 ms or more late is a hang of that long. A ping from before
/// the app last left the foreground is never counted, so a process iOS suspended isn't a hang.
final class HangWatch: Sendable {
    static let threshold: TimeInterval = 0.25
    static let interval: Duration = .milliseconds(100)

    private struct State {
        var pingedAt: Date?
        var generation = 0
        var task: Task<Void, Never>?
    }

    private let state = Mutex(State())
    private let now: @Sendable () -> Date
    private let hung: @Sendable (_ ms: Double) -> Void

    init(now: @escaping @Sendable () -> Date, hung: @escaping @Sendable (_ ms: Double) -> Void) {
        self.now = now
        self.hung = hung
    }

    func resume() {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard (try? await Task.sleep(for: Self.interval)) != nil else { return }
                self?.ping()
            }
        }
        state.withLock { state in
            state.task?.cancel()
            state.generation += 1
            state.pingedAt = nil
            state.task = task
        }
    }

    func pause() {
        state.withLock { state in
            state.task?.cancel()
            state.task = nil
            state.generation += 1
            state.pingedAt = nil
        }
    }

    private func ping() {
        let moment = now()
        let generation: Int? = state.withLock { state in
            guard state.pingedAt == nil else { return nil }
            state.pingedAt = moment
            return state.generation
        }
        guard let generation else { return }
        Task { @MainActor [weak self] in self?.answer(generation) }
    }

    // Not handled: a debugger paused on a breakpoint looks like a hang; such a build is the
    // developer's, and its hangs are theirs to ignore.
    private func answer(_ generation: Int) {
        let answered = now()
        let since: Date? = state.withLock { state in
            guard state.generation == generation, let since = state.pingedAt else { return nil }
            state.pingedAt = nil
            return since
        }
        guard let since else { return }
        let late = answered.timeIntervalSince(since)
        if late >= Self.threshold { hung((late * 1000).rounded()) }
    }
}
