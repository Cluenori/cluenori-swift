import CluenoriIngest
import CluenoriTestSupport
import Foundation
import Testing

@testable import Cluenori
@testable import CluenoriAnalytics

struct AnalyticsTests {
    @Test func `an event reaches the deployment with its properties, session, person and feature`() async throws {
        let world = TestWorld()
        let engine = world.launch()
        engine.foreground()
        engine.identify("u_1")
        let mark = engine.begin(feature: "cards.sign")
        Analytics.track(
            "autograph.requested", properties: ["card_id": "c_42", "photos": 2, "price": 4.99, "first": true],
            on: engine)
        mark.end()
        await engine.flush()

        let signals = world.deployment.signals
        guard case .event(let event) = signals.last else { Issue.record("No event"); return }
        #expect(event.name == "autograph.requested")
        #expect(
            event.properties == [
                "card_id": .string("c_42"), "photos": .number(2), "price": .number(4.99), "first": .bool(true),
            ])
        #expect(event.user == "u_1")
        #expect(event.feature == "cards.sign")
        #expect(event.session == signals.first?.session)
    }

    @Test func `a property that breaks the rules is left out, and the event still goes`() async throws {
        let world = TestWorld()
        let engine = world.launch()
        engine.foreground()
        Analytics.track(
            "note.saved",
            properties: [
                "Title": "x", "body": .string(String(repeating: "a", count: 257)), "ratio": .number(.infinity),
                "words": 12,
            ],
            on: engine)
        await engine.flush()
        guard case .event(let event) = world.deployment.signals.last else { Issue.record("No event"); return }
        #expect(event.properties == ["words": .number(12)])
        #expect(world.misuses.reported.count == 3)
    }

    @Test func `an event keeps at most 32 properties`() {
        var properties: [String: EventValue] = [:]
        for index in 0..<40 { properties["p\(String(format: "%02d", index))"] = .number(Double(index)) }
        let (kept, problems) = Analytics.checked(properties)
        #expect(kept.count == 32)
        #expect(problems.count == 8)
        #expect(kept["p00"] != nil && kept["p39"] == nil)
    }

    @Test func `a name that isn't one records nothing`() async throws {
        let world = TestWorld()
        let engine = world.launch()
        engine.foreground()
        Analytics.track(" padded ", properties: [:], on: engine)
        Analytics.screen("", on: engine)
        await engine.flush()
        #expect(world.deployment.signals.map(\.kind) == ["session.started"])
        #expect(world.misuses.reported.count == 2)
    }

    @Test func `a screen shown is recorded by its name`() async throws {
        let world = TestWorld()
        let engine = world.launch()
        engine.foreground()
        Analytics.screen("profile.edit", on: engine)
        await engine.flush()
        guard case .screen(let screen) = world.deployment.signals.last else { Issue.record("No screen"); return }
        #expect(screen.screen == "profile.edit")
    }
}
