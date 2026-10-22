import CluenoriIngest
import CluenoriTestSupport
import Foundation
import Testing

@testable import Cluenori

private let t0 = Date(timeIntervalSince1970: 1_792_000_000)

private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private let origin = SessionOrigin(release: "0.3.0+20", environment: "production")

struct SessionRulesTests {
    @Test func `a session starts when the app comes to the foreground`() {
        var session: OpenSession?
        let change = SessionRules.apply(.foreground(at(0)), to: &session, origin: origin) { _ in "s1" }
        #expect(change.started?.id == "s1")
        #expect(change.ended == nil)
        #expect(session?.foregroundSince == at(0))
    }

    @Test func `coming back within 30 s continues the session, and its foreground time adds up`() {
        var session: OpenSession?
        _ = SessionRules.apply(.foreground(at(0)), to: &session, origin: origin) { _ in "s1" }
        _ = SessionRules.apply(.background(at(60)), to: &session, origin: origin) { _ in "s2" }
        let back = SessionRules.apply(.foreground(at(89)), to: &session, origin: origin) { _ in "s2" }
        #expect(back == SessionChange())
        #expect(session?.id == "s1")
        let ended = SessionRules.apply(.end(at(100)), to: &session, origin: origin) { _ in "s3" }
        #expect(ended.ended?.foregroundSeconds == 71)
    }

    @Test func `30 s in the background ends the session at its 30th second, and coming back starts another`() {
        var session: OpenSession?
        _ = SessionRules.apply(.foreground(at(0)), to: &session, origin: origin) { _ in "s1" }
        _ = SessionRules.apply(.background(at(45)), to: &session, origin: origin) { _ in "unused" }
        let change = SessionRules.apply(.foreground(at(45 + 600)), to: &session, origin: origin) { _ in "s2" }
        #expect(change.ended?.session.id == "s1")
        #expect(change.ended?.at == at(75))
        #expect(change.ended?.foregroundSeconds == 45)
        #expect(change.started?.id == "s2")
        #expect(session?.id == "s2")
    }

    @Test func `coming back at exactly 30 s starts a new session`() {
        var session: OpenSession?
        _ = SessionRules.apply(.foreground(at(0)), to: &session, origin: origin) { _ in "s1" }
        _ = SessionRules.apply(.background(at(10)), to: &session, origin: origin) { _ in "unused" }
        let change = SessionRules.apply(.foreground(at(40)), to: &session, origin: origin) { _ in "s2" }
        #expect(change.ended?.session.id == "s1")
        #expect(change.started?.id == "s2")
    }

    @Test func `a tick ends a session 30 s in the background, and not before`() {
        var session: OpenSession?
        _ = SessionRules.apply(.foreground(at(0)), to: &session, origin: origin) { _ in "s1" }
        _ = SessionRules.apply(.background(at(20)), to: &session, origin: origin) { _ in "unused" }
        #expect(SessionRules.apply(.tick(at(49)), to: &session, origin: origin) { _ in "unused" } == SessionChange())
        let change = SessionRules.apply(.tick(at(51)), to: &session, origin: origin) { _ in "unused" }
        #expect(change.ended?.at == at(50))
        #expect(session == nil)
    }

    @Test func `becoming active again in the foreground changes nothing`() {
        var session: OpenSession?
        _ = SessionRules.apply(.foreground(at(0)), to: &session, origin: origin) { _ in "s1" }
        let again = SessionRules.apply(.foreground(at(5)), to: &session, origin: origin) { _ in "s2" }
        #expect(again == SessionChange())
        #expect(session?.id == "s1")
    }

    @Test func `a launch ends the session left in the background, at its 30 s or at the launch if sooner`() {
        var session: OpenSession?
        _ = SessionRules.apply(.foreground(at(0)), to: &session, origin: origin) { _ in "s1" }
        _ = SessionRules.apply(.background(at(20)), to: &session, origin: origin) { _ in "unused" }
        var later = session
        let late = SessionRules.apply(.launch(at(3600)), to: &later, origin: origin) { _ in "unused" }
        #expect(late.ended?.at == at(50))
        #expect(late.ended?.foregroundSeconds == 20)
        let soon = SessionRules.apply(.launch(at(25)), to: &session, origin: origin) { _ in "unused" }
        #expect(soon.ended?.at == at(25))
        #expect(session == nil)
    }

    @Test func `a launch ends a session whose app was terminated in the foreground, when it was last seen`() {
        var session: OpenSession?
        _ = SessionRules.apply(.foreground(at(0)), to: &session, origin: origin) { _ in "s1" }
        _ = SessionRules.apply(.tick(at(120)), to: &session, origin: origin) { _ in "unused" }
        let change = SessionRules.apply(.launch(at(900)), to: &session, origin: origin) { _ in "unused" }
        #expect(change.ended?.at == at(120))
        #expect(change.ended?.foregroundSeconds == 120)
    }
}

struct EngineSessionTests {
    @Test func `the app's sessions reach the deployment: one start, and its end with its foreground time`() async throws
    {
        let world = TestWorld()
        let engine = world.launch()
        engine.foreground()
        world.clock.advance(40)
        engine.background()
        world.clock.advance(10)
        engine.foreground()
        world.clock.advance(20)
        engine.background()
        await engine.flush()
        #expect(world.deployment.signals.map(\.kind) == ["session.started"])

        world.clock.advance(31)
        engine.foreground()
        await engine.flush()
        let signals = world.deployment.signals
        #expect(signals.map(\.kind) == ["session.started", "session.ended", "session.started"])
        guard case .sessionEnded(let ended) = signals[1] else { Issue.record("Not an end"); return }
        #expect(ended.foregroundMs == 60_000)
        #expect(ended.at == world.clock.now.addingTimeInterval(-1))
        #expect(signals[0].session == ended.session)
        #expect(signals[2].session != ended.session)
    }

    @Test func `a session the app left in the background ends at the next launch`() async throws {
        let world = TestWorld()
        let first = world.launch()
        first.foreground()
        world.clock.advance(12)
        first.background()
        await first.flush()

        world.clock.advance(3600)
        let second = world.launch()
        second.foreground()
        await second.flush()
        #expect(world.deployment.signals.map(\.kind) == ["session.started", "session.ended", "session.started"])
    }

    @Test func `signals recorded in a session carry its ID, and none are recorded without one`() async throws {
        let world = TestWorld()
        let engine = world.launch()
        engine.recordScreen("before")
        engine.foreground()
        engine.recordScreen("card")
        await engine.flush()
        let signals = world.deployment.signals
        #expect(signals.map(\.kind) == ["session.started", "screen"])
        #expect(signals[1].session == signals[0].session)
        #expect(signals.allSatisfy { IDMaker.isUUIDv7($0.id ?? "") })
    }

    @Test func `a held signal is recorded as its session ends, and dropped when the session continues`() async throws {
        let world = TestWorld()
        let engine = world.launch()
        engine.foreground()
        engine.background()
        engine.hold("memory") { stamp in
            .appMemory(
                AppMemory(
                    id: stamp.id, at: stamp.at, session: stamp.session, reason: .session_end, footprintBytes: 1,
                    peakBytes: 2))
        }
        engine.foreground()
        world.clock.advance(5)
        engine.background()
        engine.hold("memory") { stamp in
            .appMemory(
                AppMemory(
                    id: stamp.id, at: stamp.at, session: stamp.session, reason: .session_end, footprintBytes: 3,
                    peakBytes: 4))
        }
        world.clock.advance(31)
        engine.tick()
        await engine.flush()
        let signals = world.deployment.signals
        #expect(signals.map(\.kind) == ["session.started", "app.memory", "session.ended"])
        guard case .appMemory(let memory) = signals[1] else { Issue.record("Not memory"); return }
        #expect(memory.footprintBytes == 3)
    }
}
