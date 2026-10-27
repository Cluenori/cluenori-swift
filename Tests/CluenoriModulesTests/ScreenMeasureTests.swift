import CluenoriIngest
import CluenoriTestSupport
import Foundation
import Synchronization
import Testing

@testable import Cluenori
@testable import CluenoriAnalytics
@testable import CluenoriPerformance

@MainActor
struct ScreenMeasureTests {
    @Test func `a screen's readiness is timed from its appearing, once of each kind, and its visit as it leaves`() async
    {
        let world = TestWorld()
        let engine = world.launch()
        engine.foreground()
        let monitor = PerformanceMonitor(engine: engine, inForeground: true)
        monitor.watchScreens()
        Analytics.screen("feed", on: engine)
        let feed = engine.screens.current
        world.clock.advance(0.12)
        monitor.screenReady(.kept, of: feed, at: world.clock.now)
        world.clock.advance(0.5)
        monitor.screenReady(.fresh, of: feed, at: world.clock.now)
        monitor.screenReady(.fresh, of: feed, at: world.clock.now)
        Analytics.track("card.flipped", properties: [:], on: engine)
        world.clock.advance(2)
        Analytics.screen("card", on: engine)
        await engine.flush()

        let signals = world.deployment.signals
        #expect(
            signals.map(\.kind) == [
                "session.started", "screen", "screen.ready", "screen.ready", "event", "screen.left", "screen",
            ])
        guard case .screen(let shown) = signals[1], case .screenReady(let kept) = signals[2],
            case .screenReady(let fresh) = signals[3], case .screenLeft(let left) = signals[5]
        else { Issue.record("Not the signals of a visit"); return }
        #expect(kept.visit == shown.id && kept.content == .kept && kept.ms == 120)
        #expect(fresh.content == .fresh && fresh.ms == 620)
        #expect(signals[4].screen == "feed")
        #expect(left.visit == shown.id && left.screen == "feed" && left.visibleMs == 2620)
        #expect(left.cpuMs != nil)
        #expect(signals[6].screen == "card")
    }

    @Test func `time in the background isn't a screen's, and a session that ends there records its visit`() async {
        let world = TestWorld()
        let engine = world.launch()
        engine.foreground()
        let monitor = PerformanceMonitor(engine: engine, inForeground: true)
        monitor.watchScreens()
        Analytics.screen("feed", on: engine)
        world.clock.advance(3)
        monitor.leftForeground(at: world.clock.now)
        engine.background()
        world.clock.advance(10)
        monitor.cameToForeground(at: world.clock.now)
        engine.foreground()
        world.clock.advance(1)
        monitor.leftForeground(at: world.clock.now)
        engine.background()
        world.clock.advance(40)
        engine.tick()
        await engine.flush()

        let signals = world.deployment.signals
        #expect(signals.map(\.kind) == ["session.started", "screen", "screen.left", "session.ended"])
        guard case .screenLeft(let left) = signals[2] else { Issue.record("No visit"); return }
        #expect(left.visibleMs == 4000)
    }

    @Test func `a reset ends the screen's visit in the session that ends, and the screen goes on in the next`() async {
        let world = TestWorld()
        let engine = world.launch()
        engine.foreground()
        let monitor = PerformanceMonitor(engine: engine, inForeground: true)
        monitor.watchScreens()
        Analytics.screen("feed", on: engine)
        world.clock.advance(2)
        engine.reset()
        world.clock.advance(3)
        Analytics.screen("card", on: engine)
        await engine.flush()

        let signals = world.deployment.signals
        #expect(
            signals.map(\.kind) == [
                "session.started", "screen", "screen.left", "session.ended", "session.started", "screen",
                "screen.left", "screen",
            ])
        guard case .screen(let first) = signals[1], case .screenLeft(let firstLeft) = signals[2],
            case .screen(let again) = signals[5], case .screenLeft(let againLeft) = signals[6]
        else { Issue.record("Not the signals of two visits"); return }
        #expect(firstLeft.visit == first.id && firstLeft.session == first.session && firstLeft.visibleMs == 2000)
        #expect(again.screen == "feed" && again.session == signals[4].session && again.session != first.session)
        #expect(againLeft.visit == again.id && againLeft.session == again.session && againLeft.visibleMs == 3000)
    }

    @Test func `screens shown on other threads are measured in the order they were shown`() async {
        let world = TestWorld()
        let engine = world.launch()
        engine.foreground()
        let monitor = PerformanceMonitor(engine: engine, inForeground: true)
        monitor.watchScreens()
        // A screen shown on another thread while the main thread waits, then one on the main thread.
        showOnAnotherThread("feed", on: engine)
        Analytics.screen("card", on: engine)
        #expect(monitor.visits.measure?.visit == engine.screens.current)
        for index in 0..<200 {
            await withTaskGroup { group in
                group.addTask { Analytics.screen("a\(index)", on: engine) }
                group.addTask { Analytics.screen("b\(index)", on: engine) }
            }
        }
        #expect(monitor.visits.measure?.visit == engine.screens.current)
        await engine.flush()
        // Each visit left once, but the one shown now.
        let shown = world.deployment.signals.compactMap { signal -> String? in
            if case .screen(let screen) = signal { return screen.id } else { return nil }
        }
        let left = world.deployment.signals.compactMap { signal -> String? in
            if case .screenLeft(let screen) = signal { return screen.visit } else { return nil }
        }
        #expect(left.count == Set(left).count)
        #expect(Set(left + [engine.screens.current?.id ?? ""]) == Set(shown))
    }

    @Test func `frames while scrolling count their delay beyond their due time as hitches`() {
        let visit = ScreenVisit(id: "v", name: "feed", appearedAt: Date(timeIntervalSince1970: 0))
        var measure = VisitMeasure(
            visit: visit, at: visit.appearedAt, cpu: nil, inForeground: true, measuresScrolling: true)
        for _ in 0..<10 { measure.scrolled(interval: 8.33, expected: 8.33) }
        measure.scrolled(interval: 50, expected: 8.33)
        #expect(measure.scrollMs.rounded() == 133)
        #expect(measure.hitchMs.rounded() == 42)
    }

    @Test func `a main thread that doesn't answer for 250 ms or more is a hang of that long`() async throws {
        let hangs = Mutex<[Double]>([])
        let watch = HangWatch(now: { Date() }) { ms in hangs.withLock { $0.append(ms) } }
        watch.resume()
        try await Task.sleep(for: .milliseconds(150))
        blockMainThread(seconds: 0.45)
        try await Task.sleep(for: .milliseconds(300))
        watch.pause()
        let seen = hangs.withLock { $0 }
        #expect(seen.count == 1)
        #expect((250...700).contains(seen.first ?? 0))
    }
}

/// Shows screen `name` on a thread of its own, holding the caller's until it is shown.
private func showOnAnotherThread(_ name: String, on engine: Engine) {
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        Analytics.screen(name, on: engine)
        done.signal()
    }
    done.wait()
}

/// Holds the main thread, as a slow synchronous call in an app does.
@MainActor
private func blockMainThread(seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
}
