import CluenoriIngest
import CluenoriTestSupport
import Foundation
import Testing

@testable import Cluenori

struct DeliveryTests {
    @Test func `signals reach the deployment in batches of one installation and release, with the SDK key`()
        async throws
    {
        let world = TestWorld()
        let engine = world.launch()
        engine.foreground()
        for index in 0..<120 { engine.show(screen: "screen.\(index)") }
        await engine.flush()

        let batches = world.deployment.batches
        #expect(world.deployment.signals.count == 121)
        #expect(batches.allSatisfy { $0.signals.count <= 500 })
        let batch = try #require(batches.first)
        #expect(IDMaker.isUUIDv7(batch.installation))
        #expect(batch.environment == "production")
        #expect(batch.release == "0.3.0+20")
        #expect(batch.device.model == "iPhone18,1")
        #expect(batch.sdk == AppSdk(name: "cluenori-swift", version: "0.2.0"))
        #expect(world.deployment.authorizations == ["Bearer cluenori.sdk.notes-ios.secret"])
        #expect(Set(world.deployment.signals.compactMap(\.id)).count == 121)
    }

    @Test func `the installation keeps its ID across launches`() async throws {
        let world = TestWorld()
        let first = world.launch()
        first.foreground()
        await first.flush()
        let second = world.launch()
        second.foreground()
        await second.flush()
        let installations = Set(world.deployment.batches.map(\.installation))
        #expect(installations.count == 1)
    }

    @Test func `signals recorded before an update are sent as the release they were recorded in`() async throws {
        let world = TestWorld()
        world.deployment.setOffline(true)
        let old = world.launch(release: "0.3.0+20")
        old.foreground()
        await old.flush()
        world.deployment.setOffline(false)
        world.clock.advance(3600)

        let updated = world.launch(release: "0.4.0+21")
        updated.foreground()
        await updated.flush()
        await updated.flush()
        let releases = world.deployment.batches.map { ($0.release, $0.signals.map(\.kind)) }
        #expect(releases.map(\.0) == ["0.3.0+20", "0.4.0+21"])
        #expect(releases[0].1 == ["session.started", "session.ended"], "The old session ends as the old release's.")
        #expect(releases[1].1 == ["session.started"])
    }

    @Test func `a failure backs off, and the batch sent again has the same signals and IDs`() async throws {
        let world = TestWorld()
        world.deployment.setOffline(true)
        let engine = world.launch()
        engine.foreground()
        engine.show(screen: "card")
        await engine.flush()
        #expect(world.deployment.batches.isEmpty)

        world.deployment.setOffline(false)
        await engine.flush()
        #expect(world.deployment.batches.isEmpty, "It waits 5 s after the first failure.")

        world.clock.advance(5)
        await engine.flush()
        let sent = world.deployment.signals
        #expect(sent.map(\.kind) == ["session.started", "screen"])

        // Sent again, as when the answer was lost, the same IDs go, so the deployment counts them once.
        world.deployment.answerBatches(status: 503, body: "")
        engine.show(screen: "profile")
        await engine.flush()
        world.deployment.answerBatches { batch in (200, #"{"accepted":\#(batch.signals.count),"duplicates":0}"#) }
        world.clock.advance(5)
        await engine.flush()
        let attempts = world.deployment.attempts
        #expect(attempts.count == 3)
        #expect(attempts[1].signals.map(\.id) == attempts[2].signals.map(\.id))
    }

    @Test func `back-off doubles from 5 s to 15 minutes, spread between half and all of it`() {
        #expect(Delivery.backOff(failures: 1, random: 1) == 5)
        #expect(Delivery.backOff(failures: 2, random: 1) == 10)
        #expect(Delivery.backOff(failures: 3, random: 0) == 10)
        #expect(Delivery.backOff(failures: 9, random: 1) == 900)
        #expect(Delivery.backOff(failures: 40, random: 1) == 900)
    }

    @Test func `429 keeps the batch and sends it after the deployment's wait, whoever asks sooner`() async throws {
        let world = TestWorld()
        world.deployment.answerBatches(status: 429, body: #"{"_tag":"TooManySignals","retryAfterSeconds":120}"#)
        let engine = world.launch()
        engine.foreground()
        await engine.flush()
        #expect(world.deployment.attempts.count == 1)

        world.deployment.answerBatches { batch in (200, #"{"accepted":\#(batch.signals.count),"duplicates":0}"#) }
        world.clock.advance(119)
        await engine.flush()
        #expect(world.deployment.attempts.count == 1)

        world.clock.advance(2)
        await engine.flush()
        #expect(world.deployment.signals.map(\.kind) == ["session.started"])
    }

    @Test func `401 stops sending and recording until the app is updated`() async throws {
        let world = TestWorld()
        world.deployment.answerBatches(status: 401, body: #"{"_tag":"SdkKeyRejected","message":"Revoked."}"#)
        let engine = world.launch()
        engine.foreground()
        await engine.flush()
        #expect(world.deployment.attempts.count == 1)

        world.deployment.answerBatches { batch in (200, #"{"accepted":\#(batch.signals.count),"duplicates":0}"#) }
        engine.show(screen: "card")
        world.clock.advance(3600)
        await engine.flush()
        #expect(world.deployment.attempts.count == 1)

        let again = world.launch()
        again.foreground()
        await again.flush()
        #expect(world.deployment.attempts.count == 1, "The same release with the same key stays stopped.")

        let updated = world.launch(release: "0.4.0+21")
        updated.foreground()
        await updated.flush()
        #expect(world.deployment.batches.map(\.release) == ["0.4.0+21"])
    }

    @Test func `413 splits the batch until it fits, and every signal arrives once`() async throws {
        let world = TestWorld()
        world.deployment.answerBatches { batch in
            batch.signals.count > 2 ? (413, "") : (200, #"{"accepted":\#(batch.signals.count),"duplicates":0}"#)
        }
        let engine = world.launch()
        engine.foreground()
        for index in 0..<6 { engine.show(screen: "screen.\(index)") }
        await engine.flush()

        let attempts = world.deployment.attempts
        let refused = try #require(attempts.first)
        #expect(refused.signals.count == 7)
        #expect(world.deployment.batches.allSatisfy { $0.signals.count <= 2 })
        #expect(world.deployment.signals.compactMap(\.id) == refused.signals.compactMap(\.id))
    }

    @Test func `a signal the deployment refuses alone is dropped, and the rest arrive`() async throws {
        let world = TestWorld()
        world.deployment.answerBatches { batch in
            let refused = batch.signals.contains {
                if case .screen(let screen) = $0 { return screen.screen == "bad" }
                return false
            }
            return refused
                ? (400, #"{"_tag":"HttpApiSchemaError","message":"No."}"#)
                : (200, #"{"accepted":\#(batch.signals.count),"duplicates":0}"#)
        }
        let engine = world.launch()
        engine.foreground()
        engine.show(screen: "good")
        engine.show(screen: "bad")
        engine.show(screen: "fine")
        await engine.flush()
        let screens = world.deployment.signals.compactMap { signal -> String? in
            if case .screen(let screen) = signal { return screen.screen }
            return nil
        }
        #expect(screens == ["good", "fine"])
    }

    @Test func `nothing breaks and nothing is sent when the app never starts Cluenori`() async throws {
        let world = TestWorld()
        let engine = world.launch(start: false)
        engine.foreground()
        engine.show(screen: "card")
        await engine.flush()
        #expect(world.deployment.attempts.isEmpty)
    }
}

struct QueueTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "cluenori-queue-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func screen(_ index: Int, padding: Int = 0) -> AppSignal {
        .screen(
            ScreenShown(
                id: IDMaker().make(at: Date()), at: Date(timeIntervalSince1970: 1_792_000_000 + Double(index)),
                session: "s", screen: "screen.\(index)" + String(repeating: "x", count: padding)))
    }

    @Test func `over its budget the queue drops the oldest signals and keeps the newest`() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = SignalQueue(folder: directory, budgetBytes: 100_000)
        for index in 0..<400 {
            await queue.append(screen(index, padding: 200), release: "1+1", environment: "production")
        }
        let count = await queue.count()
        #expect(count < 400 && count >= 100)
        let head = try #require(await queue.head(limit: 500, maxBytes: 10_000_000))
        guard case .screen(let first) = head.signals.first, case .screen(let last) = head.signals.last else {
            Issue.record("Not screens")
            return
        }
        #expect(first.screen.hasPrefix("screen.") && !first.screen.hasPrefix("screen.0x"))
        #expect(last.screen.hasPrefix("screen.399"))
    }

    @Test func `a batch sent while the queue was emptied and refilled removes nothing new`() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = SignalQueue(folder: directory)
        for index in 0..<3 { await queue.append(screen(index), release: "1+1", environment: "production") }
        let inFlight = try #require(await queue.head(limit: 500, maxBytes: 10_000_000))
        await queue.removeAll()
        await queue.append(screen(3), release: "1+1", environment: "production")
        await queue.remove(inFlight)
        #expect(await queue.count() == 1)
    }

    @Test func `a batch whose signals went over the budget meanwhile removes only what is left of it`() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = SignalQueue(folder: directory, budgetBytes: 100_000)
        for index in 0..<100 {
            await queue.append(screen(index, padding: 200), release: "1+1", environment: "production")
        }
        let inFlight = try #require(await queue.head(limit: 50, maxBytes: 10_000_000))
        for index in 100..<400 {
            await queue.append(screen(index, padding: 200), release: "1+1", environment: "production")
        }
        let before = await queue.count()
        await queue.remove(inFlight)
        #expect(await queue.count() == before)
    }

    @Test func `the queue survives the process: a new one reads what the last one left`() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = SignalQueue(folder: directory)
        for index in 0..<150 { await first.append(screen(index), release: "1+1", environment: "production") }
        let sent = try #require(await first.head(limit: 30, maxBytes: 10_000_000))
        await first.remove(sent)

        let second = SignalQueue(folder: directory)
        #expect(await second.count() == 120)
        let head = try #require(await second.head(limit: 500, maxBytes: 10_000_000))
        guard case .screen(let oldest) = head.signals.first else { Issue.record("Not a screen"); return }
        #expect(oldest.screen == "screen.30")
        await second.append(screen(150), release: "1+1", environment: "production")
        #expect(await second.count() == 121)
    }
}
