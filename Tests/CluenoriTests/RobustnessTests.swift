import CluenoriIngest
import CluenoriTestSupport
import Foundation
import Observation
import Synchronization
import Testing

@testable import Cluenori

private let accepted: FakeDeployment.BatchAnswer = { batch in
    (200, #"{"accepted":\#(batch.signals.count),"duplicates":0}"#)
}

struct RobustnessTests {
    @Test func `a burst of signals never drops a call such as reset, and a flush still returns`() async throws {
        let world = TestWorld()
        let engine = world.launch()
        engine.identify("u_1")
        engine.foreground()
        for index in 0..<3000 { engine.show(screen: "before.\(index)") }
        engine.reset()
        for index in 0..<3000 { engine.show(screen: "after.\(index)") }
        await engine.flush()

        let signals = world.deployment.signals
        let ended = try #require(signals.firstIndex { $0.kind == "session.ended" })
        #expect(signals[ended].user == "u_1")
        #expect(signals[(ended + 1)...].allSatisfy { $0.user == nil })
        #expect(signals.filter { $0.kind == "session.ended" }.count == 1)
    }

    @Test func `after one refused signal, batches grow back instead of going one by one`() async throws {
        let world = TestWorld()
        world.deployment.answerBatches { batch in
            let refused = batch.signals.contains {
                if case .screen(let screen) = $0 { return screen.screen == "bad" }
                return false
            }
            return refused ? (400, "") : accepted(batch)
        }
        let engine = world.launch()
        engine.foreground()
        engine.show(screen: "bad")
        for index in 0..<300 { engine.show(screen: "good.\(index)") }
        await engine.flush()
        #expect(world.deployment.signals.count == 301)
        #expect(world.deployment.attempts.count < 30)
    }

    @Test func `a 401 without the deployment's word for a refused key backs off, and sending goes on`() async throws {
        let world = TestWorld()
        world.deployment.answerBatches(status: 401, body: "<html>Sign in to the Wi-Fi</html>")
        let engine = world.launch()
        engine.foreground()
        await engine.flush()
        world.deployment.answerBatches(accepted)
        world.clock.advance(5)
        await engine.flush()
        #expect(world.deployment.signals.map(\.kind) == ["session.started"])
    }

    @Test func `a signal recorded after its session's 30 s in the background doesn't join it`() async throws {
        let world = TestWorld()
        let engine = world.launch()
        engine.foreground()
        engine.background()
        world.clock.advance(31)
        engine.show(screen: "late")
        await engine.flush()
        #expect(world.deployment.signals.map(\.kind) == ["session.started", "session.ended"])
    }

    @Test func `files that can't be read wait, and never reset the person's consent or the installation`() async throws
    {
        let world = TestWorld()
        let first = world.launch()
        first.foreground()
        await first.flush()
        first.consent(.none)
        await first.flush()
        let installation = try String(contentsOf: world.folder.appending(path: "installation"), encoding: .utf8)
        let state = world.folder.appending(path: "state.json").path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: state)

        let locked = world.launch(wait: { _ in try await Task.sleep(for: .milliseconds(20)) })
        locked.foreground()
        locked.show(screen: "while locked")
        try await Task.sleep(for: .milliseconds(100))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: state)
        await locked.flush()

        #expect(world.deployment.signals.map(\.kind) == ["session.started"])
        let kept = try Coding.decoder().decode(KeptState.self, from: Data(contentsOf: URL(filePath: state)))
        #expect(kept.consent == .none)
        #expect(try String(contentsOf: world.folder.appending(path: "installation"), encoding: .utf8) == installation)
    }

    @Test(arguments: [
        ("https://cluenori.example.com", true), ("http://localhost:8787", true), ("http://192.168.1.10:8787", true),
        ("http://10.0.0.1", true), ("http://notes.local", true), ("http://cluenori.example.com", false),
        ("http://10.0.0.1.example.com", false), ("http://192.168.1", false), ("ftp://10.0.0.1", false),
    ])
    func `a deployment is https, or http on this Mac or its local network`(address: String, allowed: Bool) throws {
        #expect(Engine.isDeploymentURL(try #require(URL(string: address))) == allowed)
    }

    @Test(arguments: [
        ("en-US-u-ca-iso8601-fw-mon-hc-h23-ms-metric-mu-celsius", "en-US"), ("en_US@rg=plzzzz", "en-US"),
        ("uk-UA", "uk-UA"), ("zh-Hans-CN", "zh-Hans-CN"), ("en", "en"),
    ])
    func `the locale sent is the language and region, without the person's settings`(identifier: String, sent: String) {
        #expect(ThisDevice.locale(Locale(identifier: identifier)) == sent)
    }

    @Test @MainActor func `a return to the foreground decides the gate again, so a closed prompt's day can end`() {
        let gate = UpdateGate(
            osVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0), now: { Date() })
        let changed = Changed()
        withObservationTracking {
            _ = gate.prompt
        } onChange: {
            changed.mark()
        }
        gate.resume()
        #expect(changed.happened)
    }
}

/// Whether an observed value changed.
private final class Changed: Sendable {
    private let flag = Atomic(false)
    var happened: Bool { flag.load(ordering: .relaxed) }
    func mark() { flag.store(true, ordering: .relaxed) }
}
