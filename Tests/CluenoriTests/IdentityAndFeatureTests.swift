import CluenoriIngest
import CluenoriTestSupport
import Foundation
import Testing

@testable import Cluenori

struct IdentityTests {
    @Test func `signals after identify carry the person, and those before don't`() async throws {
        let world = TestWorld()
        let engine = world.launch()
        engine.foreground()
        engine.show(screen: "sign-in")
        engine.identify("u_123")
        engine.show(screen: "feed")
        await engine.flush()
        #expect(world.deployment.signals.map(\.user) == [nil, nil, "u_123"])
    }

    @Test func `the person signed in stays across launches`() async throws {
        let world = TestWorld()
        let first = world.launch()
        first.identify("u_123")
        await first.flush()
        let second = world.launch()
        second.foreground()
        await second.flush()
        #expect(world.deployment.signals.map(\.user) == ["u_123"])
    }

    @Test func `reset ends the person's session and starts the next without them`() async throws {
        let world = TestWorld()
        let engine = world.launch()
        engine.identify("u_123")
        engine.foreground()
        world.clock.advance(30)
        engine.reset()
        engine.show(screen: "sign-in")
        await engine.flush()
        let signals = world.deployment.signals
        #expect(signals.map(\.kind) == ["session.started", "session.ended", "session.started", "screen"])
        #expect(signals.map(\.user) == ["u_123", "u_123", nil, nil])
        #expect(signals[2].session != signals[0].session)
        #expect(signals[3].session == signals[2].session)
    }

    @Test(arguments: ["", "has space", "ana@example.com", String(repeating: "x", count: 129), "ключ"])
    func `an ID that isn't the app's opaque one identifies no one`(user: String) async throws {
        let world = TestWorld()
        let engine = world.launch()
        engine.identify(user)
        engine.foreground()
        await engine.flush()
        #expect(world.deployment.signals.map(\.user) == [nil])
        #expect(world.misuses.reported.count == 1)
    }
}

struct FeatureTests {
    @Test func `signals belong to the feature shown last, and to the one before once it ends`() async throws {
        let world = TestWorld()
        let engine = world.launch()
        engine.foreground()
        let cards = engine.begin(feature: "cards")
        engine.show(screen: "cards")
        let flip = engine.begin(feature: "cards.flip")
        engine.show(screen: "flip")
        flip.end()
        flip.end()
        engine.show(screen: "cards.again")
        cards.end()
        engine.show(screen: "home")
        await engine.flush()
        #expect(world.deployment.signals.map(\.feature) == [nil, "cards", "cards.flip", "cards", nil])
    }

    @Test func `work done in a feature belongs to it, across awaits, over the screen's`() async throws {
        let world = TestWorld()
        let engine = world.launch()
        engine.foreground()
        let mark = engine.begin(feature: "cards")
        await engine.feature("cards.export") {
            try? await Task.sleep(for: .milliseconds(1))
            engine.show(screen: "export")
        }
        engine.feature("cards.share") { _ = engine.show(screen: "share") }
        mark.end()
        await engine.flush()
        #expect(world.deployment.signals.map(\.feature) == [nil, "cards.export", "cards.share"])
    }

    @Test func `a key that isn't a feature's marks nothing, and the work still runs`() async throws {
        let world = TestWorld()
        let engine = world.launch()
        let mark = engine.begin(feature: "Cards Flip")
        let ran = engine.feature("cards..flip") { true }
        #expect(ran)
        #expect(engine.features.current == nil)
        mark.end()
        #expect(world.misuses.reported.count == 2)
    }

    @Test func `requests carry the release, a new trace, and the feature, component and release as baggage`()
        async throws
    {
        let world = TestWorld()
        let engine = world.launch()
        let mark = engine.begin(feature: "cards.flip")
        defer { mark.end() }
        let headers = engine.requestHeaders()
        #expect(headers["Cluenori-Release"] == "0.3.0+20")
        #expect(
            headers["baggage"]
                == "cluenori.feature=cards.flip,cluenori.origin.component=notes-ios,cluenori.origin.release=0.3.0+20")
        let traceparent = try #require(headers["traceparent"])
        let parts = traceparent.split(separator: "-")
        #expect(
            parts.count == 4 && parts[0] == "00" && parts[1].count == 32 && parts[2].count == 16 && parts[3] == "01")
        #expect(engine.requestHeaders()["traceparent"] != traceparent)
    }

    @Test func `a request's own trace and baggage stay, and Cluenori's entries are its own`() {
        let headers = RequestHeaders.headers(
            release: "0.3.0+20", feature: "cards",
            existing: [
                "Traceparent": "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
                "Baggage": "tenant=acme, cluenori.feature=old",
            ])
        #expect(headers["traceparent"] == nil)
        #expect(headers["baggage"] == "tenant=acme,cluenori.feature=cards,cluenori.origin.release=0.3.0+20")
    }

    @Test func `a key that isn't an SDK key names no component, and the baggage goes without it`() async {
        let world = TestWorld()
        let engine = world.launch(key: "cluenori.sdk.notes-ios.secret")
        #expect(engine.requestHeaders()["baggage"] == "cluenori.origin.release=0.3.0+20")
    }

    @Test(
        arguments: [
            ("cluenori-sdk.notes.notes-ios.R2d2C3poBb8Wq0Lk5Xz7Aa", "notes-ios"),
            ("cluenori-sdk.notes.notes-ios", nil),
            ("cluenori-sdk.notes.Notes.abc", nil),
            ("cluenori-sdk.notes.notes-ios.", nil),
            ("cluenori-sdk.notes.notes-ios.!", nil),
            ("cluenori-sdk.notes.notes-ios.R2d2C3poBb8Wq0Lk5Xz7A", nil),
            ("cluenori-sdk.notes.notes-ios.R2d2C3poBb8Wq0Lk5Xz7Aaa", nil),
            ("cluenori-sdk.notes.\(String(repeating: "c", count: 41)).R2d2C3poBb8Wq0Lk5Xz7Aa", nil),
            (
                "cluenori-sdk.notes.\(String(repeating: "c", count: 40)).R2d2C3poBb8Wq0Lk5Xz7Aa",
                String(repeating: "c", count: 40)
            ),
            ("cluenori-sdk.notes.notes-ios.R2d2-3po_b8Wq0Lk5Xz7Aa", "notes-ios"),
            ("cluenori-key.notes.notes-ios.abc", nil),
            ("cluenori-sdk.notes.notes-ios.abc.def", nil),
        ] as [(String, String?)])
    func `the component is the SDK key's third part`(key: String, component: String?) {
        #expect(TextRules.componentOfKey(key) == component)
    }

    @Test func `a traceparent is never all zeros`() {
        #expect(RequestHeaders.traceparent { 0 } == "00-00000000000000010000000000000000-0000000000000001-01")
    }
}

struct TextRuleTests {
    @Test(arguments: ["cards", "cards.flip", "notes-ios.export", "a1.b2-c3"])
    func `feature keys`(key: String) { #expect(TextRules.isFeatureKey(key)) }

    @Test(arguments: ["", "Cards", "cards.", ".cards", "cards..flip", "cards-", "cards--flip", "1cards", "cards flip"])
    func `not feature keys`(key: String) { #expect(!TextRules.isFeatureKey(key)) }

    @Test func `UUIDv7s are lowercase, version 7, variant 10, and sort by time`() {
        let maker = IDMaker()
        let early = maker.make(at: Date(timeIntervalSince1970: 1_792_000_000))
        let late = maker.make(at: Date(timeIntervalSince1970: 1_792_000_001))
        #expect(IDMaker.isUUIDv7(early) && IDMaker.isUUIDv7(late))
        #expect(early < late)
        #expect(!IDMaker.isUUIDv7(UUID().uuidString))
    }
}
