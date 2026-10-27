import CluenoriIngest
import CluenoriTestSupport
import Foundation
import Testing

@testable import Cluenori

private let ios27 = OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0)
private let ios18 = OperatingSystemVersion(majorVersion: 18, minorVersion: 4, patchVersion: 0)

private func policy(
    _ decision: UpdateDecision, minimumOs: String? = nil, storeUrl: String = "https://apps.apple.com/app/id123"
)
    -> VersionPolicy
{
    VersionPolicy(
        decision: decision, update: AvailableUpdate(version: "0.4.0", minimumOsVersion: minimumOs, storeUrl: storeUrl),
        text: UpdateText(title: "Update Notes", message: "This version is no longer supported."))
}

private let offer = UpdateOffer(
    version: "0.4.0", storeURL: URL(string: "https://apps.apple.com/app/id123")!, minimumOSVersion: "26.0",
    title: "Update Notes", message: "This version is no longer supported.")

struct UpdateDecisionTests {
    @Test func `require blocks, recommend offers, and none shows nothing`() {
        #expect(UpdatePrompt.decide(policy(.require, minimumOs: "26.0"), osVersion: ios27) == .required(offer))
        #expect(UpdatePrompt.decide(policy(.recommend, minimumOs: "26.0"), osVersion: ios27) == .recommended(offer))
        #expect(UpdatePrompt.decide(VersionPolicy(decision: .none), osVersion: ios27) == .none)
    }

    @Test func `without a manifest the app is never blocked`() {
        #expect(UpdatePrompt.decide(nil, osVersion: ios27) == .none)
    }

    @Test func `a device whose OS is too old for the update is never blocked: it gets a notice, or nothing`() {
        #expect(UpdatePrompt.decide(policy(.require, minimumOs: "26.0"), osVersion: ios18) == .deviceUnsupported(offer))
        #expect(UpdatePrompt.decide(policy(.recommend, minimumOs: "26.0"), osVersion: ios18) == .none)
    }

    @Test func `a policy the SDK can't act on shows nothing`() {
        #expect(
            UpdatePrompt.decide(VersionPolicy(decision: UpdateDecision(rawValue: "sunset")), osVersion: ios27) == .none)
        #expect(UpdatePrompt.decide(VersionPolicy(decision: .require), osVersion: ios27) == .none)
        #expect(UpdatePrompt.decide(policy(.require, storeUrl: "http://example.com"), osVersion: ios27) == .none)
    }

    @Test(arguments: [
        ("26.0", true), ("27", true), ("27.2", true), ("27.2.1", false), ("27.10", false), ("28.0", false), ("9", true),
    ])
    func `OS versions compare by number`(minimum: String, installable: Bool) {
        #expect(UpdatePrompt.isAtLeast(ios27, minimum) == installable)
    }
}

@MainActor
struct UpdateGateTests {
    @Test func `a recommendation the person closes stays closed for a day for its version`() {
        let clock = ManualClock()
        let gate = UpdateGate(osVersion: ios27, now: { clock.now })
        gate.show(policy(.recommend))
        #expect(gate.prompt.offer?.version == "0.4.0")
        gate.dismiss()
        #expect(gate.prompt == .none)
        clock.advance(23 * 3600)
        #expect(gate.prompt == .none)
        clock.advance(3600)
        #expect(gate.prompt.offer?.version == "0.4.0")
    }

    @Test func `a required update can't be dismissed`() {
        let gate = UpdateGate(osVersion: ios27, now: { Date() })
        gate.show(policy(.require))
        gate.dismiss()
        #expect(
            gate.prompt
                == .required(
                    UpdateOffer(
                        version: "0.4.0", storeURL: URL(string: "https://apps.apple.com/app/id123")!,
                        title: "Update Notes",
                        message: "This version is no longer supported.")))
    }

    @Test func `a closed recommendation stays closed after the next launch, and a newer one shows`() async throws {
        let world = TestWorld()
        world.deployment.answerManifest(FakeDeployment.manifest(decision: "recommend", version: "0.4.0"))
        let first = world.launch()
        await first.flush()
        #expect(first.gate.prompt.offer?.version == "0.4.0")
        first.gate.dismiss()
        await first.flush()

        let second = world.launch()
        await second.flush()
        #expect(second.gate.prompt == .none)

        world.deployment.answerManifest(FakeDeployment.manifest(decision: "recommend", version: "0.5.0"))
        world.clock.advance(301)
        let third = world.launch()
        await third.flush()
        #expect(third.gate.prompt.offer?.version == "0.5.0")
    }
}

@MainActor
struct ManifestTests {
    @Test func `the manifest is asked for at launch, for this release, environment and language`() async throws {
        let world = TestWorld()
        world.deployment.answerManifest(
            FakeDeployment.manifest(decision: "require", version: "0.4.0", minimumOs: "26.0"))
        let engine = world.launch()
        await engine.flush()
        #expect(
            world.deployment.manifestQueries == [
                ["environment": "production", "release": "0.3.0+20", "locale": "uk-UA"]
            ])
        #expect(engine.gate.prompt.offer?.version == "0.4.0")
        guard case .required = engine.gate.prompt else { Issue.record("Not required"); return }
    }

    @Test func `offline, the last manifest is used; with none, the app is never blocked`() async throws {
        let world = TestWorld()
        world.deployment.setOffline(true)
        let never = world.launch()
        await never.flush()
        #expect(never.gate.prompt == .none)

        world.deployment.setOffline(false)
        world.deployment.answerManifest(FakeDeployment.manifest(decision: "require", version: "0.4.0"))
        let online = world.launch()
        await online.flush()

        world.deployment.setOffline(true)
        world.clock.advance(3600)
        let offline = world.launch()
        await offline.flush()
        guard case .required = offline.gate.prompt else { Issue.record("The kept manifest wasn't used"); return }
    }

    @Test func `a manifest kept for the release before isn't used after an update`() async throws {
        let world = TestWorld()
        world.deployment.answerManifest(FakeDeployment.manifest(decision: "require", version: "0.4.0"))
        let old = world.launch(release: "0.3.0+20")
        await old.flush()
        world.deployment.setOffline(true)
        let updated = world.launch(release: "0.4.0+21")
        await updated.flush()
        #expect(updated.gate.prompt == .none)
    }

    @Test func `on resume it is asked for again once its max age has passed`() async throws {
        let world = TestWorld()
        world.deployment.answerManifest(FakeDeployment.manifest(decision: "none", maxAge: 300))
        let engine = world.launch()
        await engine.flush()
        engine.foreground()
        world.clock.advance(299)
        engine.background()
        engine.foreground()
        await engine.flush()
        #expect(world.deployment.manifestQueries.count == 1)

        world.deployment.answerManifest(FakeDeployment.manifest(decision: "recommend", version: "0.4.0"))
        world.clock.advance(2)
        engine.background()
        engine.foreground()
        await engine.flush()
        #expect(world.deployment.manifestQueries.count == 2)
        #expect(engine.gate.prompt.offer?.version == "0.4.0")
    }

    @Test func `a refused key keeps the last manifest`() async throws {
        let world = TestWorld()
        world.deployment.answerManifest(FakeDeployment.manifest(decision: "require", version: "0.4.0", maxAge: 0))
        let first = world.launch()
        await first.flush()
        world.deployment.answerManifest(status: 401, #"{"_tag":"SdkKeyRejected","message":"Revoked."}"#)
        let second = world.launch()
        await second.flush()
        guard case .required = second.gate.prompt else { Issue.record("The last manifest wasn't kept"); return }
    }
}

struct ConsentTests {
    @Test func `none drops what wasn't sent and records nothing more, across launches`() async throws {
        let world = TestWorld()
        world.deployment.setOffline(true)
        let engine = world.launch()
        engine.foreground()
        engine.show(screen: "card")
        await engine.flush()
        engine.consent(.none)
        engine.show(screen: "profile")
        world.deployment.setOffline(false)
        world.clock.advance(3600)
        await engine.flush()
        #expect(world.deployment.attempts.isEmpty)

        let next = world.launch()
        next.foreground()
        next.show(screen: "feed")
        await next.flush()
        #expect(world.deployment.attempts.isEmpty)
    }

    @Test func `full again starts a session in the foreground, and signals flow`() async throws {
        let world = TestWorld()
        let engine = world.launch()
        engine.consent(.none)
        engine.foreground()
        engine.show(screen: "dropped")
        engine.consent(.full)
        engine.show(screen: "card")
        await engine.flush()
        #expect(world.deployment.signals.map(\.kind) == ["session.started", "screen"])
    }

    @Test func `the update gate works without consent`() async throws {
        let world = TestWorld()
        world.deployment.answerManifest(FakeDeployment.manifest(decision: "require", version: "0.4.0", maxAge: 0))
        let first = world.launch()
        first.consent(.none)
        await first.flush()
        let engine = world.launch()
        await engine.flush()
        await MainActor.run {
            guard case .required = engine.gate.prompt else { Issue.record("No gate"); return }
        }
        #expect(world.deployment.manifestQueries.count == 2)
        #expect(world.deployment.attempts.isEmpty)
    }
}
